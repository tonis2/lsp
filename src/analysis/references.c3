module lsp;

import std::core::dstring;
import std::core::mem;
import std::io::file;
import std::io::path;
import c3::lexer;

// Encode document highlights (same-file occurrences of the symbol under cursor).
// Output: JSON array of DocumentHighlight objects, or empty string if none.
fn void encode_document_highlights(String content, usz offset, DString* out)
{
	TokenStream stream = token_stream_tokenize(content);
	defer stream.free();

	Token cursor_tok;
	usz cursor_idx;
	if (!stream.tokens.find_token_at(offset, &cursor_tok, &cursor_idx)) return;

	TokenType ct = cursor_tok.type;
	if (!is_ident(ct) && ct != TYPE_IDENT && ct != CONST_IDENT) return;

	LineOffsets* lo = stream.get_line_offsets();

	// Detect if cursor is on a member access (preceded by DOT)
	bool is_member = cursor_idx > 0 && stream.tokens.entries[cursor_idx - 1].type == DOT;

	bool first = true;
	out.append("[");
	for (usz i = 0; i < stream.tokens.size; i++)
	{
		Token tok = stream.tokens.entries[i];
		if (tok.type == ct && tok.text == cursor_tok.text)
		{
			// Filter: member access tokens only match other member access tokens
			bool tok_is_member = i > 0 && stream.tokens.entries[i - 1].type == DOT;
			if (is_member != tok_is_member) continue;

			if (!first) out.append(",");
			first = false;

			usz line = lo.find_line(tok.offset);
			usz col = tok.offset - lo.entries[line];
			usz end_col = col + tok.len;

			DocumentHighlight highlight = {
				.range = {
					.start = {.line = line, .character = col},
					.end = {.line = line, .character = end_col},
				},
				.kind = 1,
			};
			highlight.encode(out);
		}
	}
	out.append("]");

	// If we only wrote "[]", clear output to signal nothing found
	if (first)
	{
		out.clear();
	}
}

// Encode references (cross-file occurrences of the symbol under cursor).
// Output: JSON array of Location objects, or empty string if none.
fn void encode_references(String uri, String content, usz offset, DocumentList* docs, String stdlib_path, bool include_decl, DString* out)
{
	TokenStream stream = token_stream_tokenize(content);
	defer stream.free();

	Token cursor_tok;
	usz cursor_idx;
	if (!stream.tokens.find_token_at(offset, &cursor_tok, &cursor_idx)) return;

	TokenType ct = cursor_tok.type;
	if (!is_ident(ct) && ct != TYPE_IDENT && ct != CONST_IDENT) return;

	// Detect if cursor is on a member access (preceded by DOT)
	bool is_member = cursor_idx > 0 && stream.tokens.entries[cursor_idx - 1].type == DOT;

	bool first = true;
	out.append("[");

	// 1. Current file — collect all matching tokens
	stream.tokens.collect_refs(uri, content, cursor_tok, out, &first, is_member);

	// 2. Open documents
	for (usz d = 0; d < docs.size; d++)
	{
		if (docs.entries[d].uri == uri) continue;

		TokenStream other_stream = token_stream_tokenize(docs.entries[d].content);
		other_stream.tokens.collect_refs(docs.entries[d].uri, docs.entries[d].content, cursor_tok, out, &first, is_member);
		other_stream.free();
	}

	// 3. Scan project files on disk
	String file_path = uri_to_path(uri);
	if (file_path.len > 0)
	{
		scan_project_files_refs(file_path, cursor_tok, out, &first, is_member);
	}

	// 4. Scan stdlib
	if (stdlib_path.len > 0)
	{
		scan_dir_recursive_refs(stdlib_path, cursor_tok, out, &first, 0, is_member);
	}

	out.append("]");

	if (first)
	{
		out.clear();
	}
}

// Collect all tokens matching target name+type from a pre-tokenized stream, emitting Location JSON.
// When member_access is true, only matches tokens preceded by DOT; when false, only non-DOT tokens.
fn void TokenList.collect_refs(&self, String uri, String content, Token target, DString* out, bool* first, bool member_access = false)
{
	LineOffsets lo;
	lo.init(mem);
	defer lo.free();
	lo.build(content);

	for (usz i = 0; i < self.size; i++)
	{
		Token tok = self.entries[i];
		if (tok.type == target.type && tok.text == target.text)
		{
			bool tok_is_member = i > 0 && self.entries[i - 1].type == DOT;
			if (member_access != tok_is_member) continue;

			if (!*first) out.append(",");
			*first = false;

			usz line = lo.find_line(tok.offset);
			usz col = tok.offset - lo.entries[line];
			usz end_col = col + tok.len;

			Location loc = {
				.uri = uri,
				.range = {
					.start = {.line = line, .character = col},
					.end = {.line = line, .character = end_col},
				},
			};
			loc.encode(out);
		}
	}
}

// Returns the byte offset range (start, end) of the function scope containing `offset`,
// or (0, 0) if offset is not inside any function.
// The scope includes the parameter list so that renaming a parameter also covers
// its occurrences in the function body.
fn usz[2] TokenList.find_function_scope(&self, usz offset)
{
	for (usz i = 0; i < self.size; i++)
	{
		TokenType tt = self.entries[i].type;
		if (tt == FUNC || tt == MACRO)
		{
			usz brace_end = self.find_brace_end(i + 1);
			if (brace_end == 0) continue;

			// Find the opening paren and brace offsets
			usz paren_start = 0;
			usz brace_start = 0;
			for (usz j = i + 1; j < self.size; j++)
			{
				if (paren_start == 0 && self.entries[j].type == LPAREN)
				{
					paren_start = self.entries[j].offset;
				}
				if (self.entries[j].type == LBRACE)
				{
					brace_start = self.entries[j].offset;
					break;
				}
			}
			if (brace_start == 0) continue;

			// Cursor inside function body
			if (offset >= brace_start && offset < brace_end)
			{
				return { brace_start, brace_end };
			}

			// Cursor inside parameter list — scope covers params + body
			if (paren_start != 0 && offset >= paren_start && offset < brace_start)
			{
				return { paren_start, brace_end };
			}
		}
	}
	return { 0, 0 };
}

// Encode rename (cross-file symbol rename).
// Output: JSON WorkspaceEdit object, or empty string if none.
fn void encode_rename(String uri, String content, usz offset, DocumentList* docs, String stdlib_path, String new_name, DString* out)
{
	TokenStream stream = token_stream_tokenize(content);
	defer stream.free();

	Token cursor_tok;
	usz cursor_idx;
	if (!stream.tokens.find_ident_token_at(offset, &cursor_tok, &cursor_idx))
	{
		return;
	}

	TokenType ct = cursor_tok.type;
	if (!is_ident(ct) && ct != TYPE_IDENT && ct != CONST_IDENT) return;

	// Check if cursor is inside a function body — if so, restrict rename to that scope
	usz[2] scope = stream.tokens.find_function_scope(offset);

	bool first_uri = true;
	out.append(`{"changes":{`);

	if (scope[0] != 0 || scope[1] != 0)
	{
		// Local variable — only rename within this function's scope in current file
		stream.tokens.collect_rename_edits_scoped(uri, content, cursor_tok, new_name, out, &first_uri, scope[0], scope[1]);
	}
	else
	{
		// Module-level symbol — rename globally across all files
		// 1. Current file
		stream.tokens.collect_rename_edits(uri, content, cursor_tok, new_name, out, &first_uri);

		// 2. Open documents
		for (usz d = 0; d < docs.size; d++)
		{
			if (docs.entries[d].uri == uri) continue;

			TokenStream other_stream = token_stream_tokenize(docs.entries[d].content);
			other_stream.tokens.collect_rename_edits(docs.entries[d].uri, docs.entries[d].content, cursor_tok, new_name, out, &first_uri);
			other_stream.free();
		}

		// 3. Scan project files on disk (skip stdlib — should not rename stdlib symbols)
		String file_path = uri_to_path(uri);
		if (file_path.len > 0)
		{
			scan_project_files_rename(file_path, cursor_tok, new_name, out, &first_uri);
		}
	}

	out.append(`}}`);

	if (first_uri)
	{
		out.clear();
	}
}

// Collect rename edits for matching tokens in a single file, emitting a URI-keyed TextEdit array.
fn void TokenList.collect_rename_edits(&self, String uri, String content, Token target, String new_name, DString* out, bool* first_uri)
{
	LineOffsets lo;
	lo.init(mem);
	defer lo.free();
	lo.build(content);

	bool found_any = false;
	bool first_edit = true;

	foreach (tok : self)
	{
		if (tok.type == target.type && tok.text == target.text)
		{
			if (!found_any)
			{
				if (!*first_uri) out.append(",");
				out.append(`"`);
				json_escape_into(out, uri);
				out.append(`":[`);
				found_any = true;
			}

			if (!first_edit) out.append(",");
			first_edit = false;

			usz line = lo.find_line(tok.offset);
			usz col = tok.offset - lo.entries[line];
			usz end_col = col + tok.len;

			TextEdit edit = {
				.range = {
					.start = {.line = line, .character = col},
					.end = {.line = line, .character = end_col},
				},
				.new_text = new_name,
			};
			edit.encode(out);
		}
	}

	if (found_any)
	{
		out.append("]");
		*first_uri = false;
	}
}

// Collect rename edits for matching tokens within a specific offset range in a single file.
fn void TokenList.collect_rename_edits_scoped(&self, String uri, String content, Token target,
	String new_name, DString* out, bool* first_uri, usz scope_start, usz scope_end)
{
	LineOffsets lo;
	lo.init(mem);
	defer lo.free();
	lo.build(content);

	bool found_any = false;
	bool first_edit = true;

	foreach (tok : self)
	{
		if (tok.offset < scope_start || tok.offset >= scope_end) continue;
		if (tok.type == target.type && tok.text == target.text)
		{
			if (!found_any)
			{
				if (!*first_uri) out.append(",");
				out.append(`"`);
				json_escape_into(out, uri);
				out.append(`":[`);
				found_any = true;
			}

			if (!first_edit) out.append(",");
			first_edit = false;

			usz line = lo.find_line(tok.offset);
			usz col = tok.offset - lo.entries[line];
			usz end_col = col + tok.len;

			TextEdit edit = {
				.range = {
					.start = {.line = line, .character = col},
					.end = {.line = line, .character = end_col},
				},
				.new_text = new_name,
			};
			edit.encode(out);
		}
	}

	if (found_any)
	{
		out.append("]");
		*first_uri = false;
	}
}

// Scan project directories for rename edits on disk.
fn void scan_project_files_rename(String file_path, Token target, String new_name, DString* out, bool* first_uri) @private
{
	ProjectDirs pdirs;
	pdirs.get_search_dirs(file_path);
	if (pdirs.project_root.len == 0) return;

	for (usz i = 0; i < pdirs.count; i++)
	{
		DString search_path = dstring::temp();
		search_path.appendf("%s/%s", pdirs.project_root, pdirs.dirs[i]);
		scan_dir_recursive_rename(search_path.str_view(), target, new_name, out, first_uri, 0);
	}
}

// Recursively scan directories for rename edits.
fn void scan_dir_recursive_rename(String dir_path, Token target, String new_name, DString* out, bool* first_uri, int depth) @private
{
	if (depth > MAX_SCAN_DEPTH) return;

	Path p;
	if (try pp = path::temp(dir_path))
	{
		p = pp;
	}
	else
	{
		return;
	}
	PathList entries;
	if (try el = path::ls(mem, p))
	{
		entries = el;
	}
	else
	{
		return;
	}
	defer
	{
		foreach (&e : entries) e.free();
		entries.free();
	}

	foreach (entry : entries)
	{
		String entry_name = entry.str_view();
		char[] path_buf = mem::new_array(char, dir_path.len + 1 + entry_name.len);
		defer mem::free(path_buf);
		path_buf[:dir_path.len] = dir_path[:dir_path.len];
		path_buf[dir_path.len] = '/';
		path_buf[dir_path.len + 1..] = entry_name[:entry_name.len];
		String full_path = (String)path_buf;

		if (entry_name.ends_with(".c3") || entry_name.ends_with(".c3i"))
		{
			if (try file_content = file::load(mem, full_path))
			{
				String content = (String)file_content;
				TokenStream stream = token_stream_tokenize(content);

				DString uri = dstring::temp();
				append_file_uri(&uri, full_path);
				stream.tokens.collect_rename_edits(uri.str_view(), content, target, new_name, out, first_uri);

				stream.free();
				mem::free(file_content);
			}
		}
		else
		{
			scan_dir_recursive_rename(full_path, target, new_name, out, first_uri, depth + 1);
		}
	}
}

// Scan project directories for all references on disk.
fn void scan_project_files_refs(String file_path, Token target, DString* out, bool* first, bool member_access = false) @private
{
	ProjectDirs pdirs;
	pdirs.get_search_dirs(file_path);
	if (pdirs.project_root.len == 0) return;

	for (usz i = 0; i < pdirs.count; i++)
	{
		DString search_path = dstring::temp();
		search_path.appendf("%s/%s", pdirs.project_root, pdirs.dirs[i]);
		scan_dir_recursive_refs(search_path.str_view(), target, out, first, 0, member_access);
	}
}

// Recursively scan directories for all references.
fn void scan_dir_recursive_refs(String dir_path, Token target, DString* out, bool* first, int depth, bool member_access = false) @private
{
	if (depth > MAX_SCAN_DEPTH) return;

	Path p;
	if (try pp = path::temp(dir_path))
	{
		p = pp;
	}
	else
	{
		return;
	}
	PathList entries;
	if (try el = path::ls(mem, p))
	{
		entries = el;
	}
	else
	{
		return;
	}
	defer
	{
		foreach (&e : entries) e.free();
		entries.free();
	}

	foreach (entry : entries)
	{
		String entry_name = entry.str_view();
		char[] path_buf = mem::new_array(char, dir_path.len + 1 + entry_name.len);
		defer mem::free(path_buf);
		path_buf[:dir_path.len] = dir_path[:dir_path.len];
		path_buf[dir_path.len] = '/';
		path_buf[dir_path.len + 1..] = entry_name[:entry_name.len];
		String full_path = (String)path_buf;

		if (entry_name.ends_with(".c3") || entry_name.ends_with(".c3i"))
		{
			if (try file_content = file::load(mem, full_path))
			{
				String content = (String)file_content;
				TokenStream stream = token_stream_tokenize(content);

				DString uri = dstring::temp();
				append_file_uri(&uri, full_path);
				stream.tokens.collect_refs(uri.str_view(), content, target, out, first, member_access);

				stream.free();
				mem::free(file_content);
			}
		}
		else
		{
			scan_dir_recursive_refs(full_path, target, out, first, depth + 1, member_access);
		}
	}
}
