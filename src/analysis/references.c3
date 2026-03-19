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
	TokenList tokens;
	tokens.init(mem);
	defer tokens.free();
	tokenize_content(content, &tokens);

	Token cursor_tok;
	usz cursor_idx;
	if (!find_token_at(&tokens, offset, &cursor_tok, &cursor_idx)) return;

	TokenType ct = cursor_tok.type;
	if (!is_ident(ct) && ct != TYPE_IDENT && ct != CONST_IDENT) return;

	LineOffsets lo;
	lo.init(mem);
	defer lo.free();
	build_line_offsets(content, &lo);

	bool first = true;
	out.append("[");
	foreach (tok : tokens)
	{
		if (tok.type == ct && tok.text == cursor_tok.text)
		{
			if (!first) out.append(",");
			first = false;

			usz line = find_line(&lo, tok.offset);
			usz col = tok.offset - lo.entries[line];
			usz end_col = col + tok.len;

			out.appendf(`{"range":{"start":{"line":%d,"character":%d},"end":{"line":%d,"character":%d}},"kind":1}`, line, col, line, end_col);
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
	TokenList tokens;
	tokens.init(mem);
	defer tokens.free();
	tokenize_content(content, &tokens);

	Token cursor_tok;
	usz cursor_idx;
	if (!find_token_at(&tokens, offset, &cursor_tok, &cursor_idx)) return;

	TokenType ct = cursor_tok.type;
	if (!is_ident(ct) && ct != TYPE_IDENT && ct != CONST_IDENT) return;

	bool first = true;
	out.append("[");

	// 1. Current file — collect all matching tokens
	collect_refs_in_tokens(uri, content, &tokens, cursor_tok, out, &first);

	// 2. Open documents
	for (usz d = 0; d < docs.size; d++)
	{
		if (docs.entries[d].uri == uri) continue;

		TokenList other_tokens;
		other_tokens.init(mem);
		tokenize_content(docs.entries[d].content, &other_tokens);
		collect_refs_in_tokens(docs.entries[d].uri, docs.entries[d].content, &other_tokens, cursor_tok, out, &first);
		other_tokens.free();
	}

	// 3. Scan project files on disk
	String file_path = uri_to_path(uri);
	if (file_path.len > 0)
	{
		scan_project_files_refs(file_path, cursor_tok, out, &first);
	}

	// 4. Scan stdlib
	if (stdlib_path.len > 0)
	{
		scan_dir_recursive_refs(stdlib_path, cursor_tok, out, &first, 0);
	}

	out.append("]");

	if (first)
	{
		out.clear();
	}
}

// Collect all tokens matching target name+type from a pre-tokenized stream, emitting Location JSON.
fn void collect_refs_in_tokens(String uri, String content, TokenList* tokens, Token target, DString* out, bool* first) @private
{
	LineOffsets lo;
	lo.init(mem);
	defer lo.free();
	build_line_offsets(content, &lo);

	foreach (tok : tokens)
	{
		if (tok.type == target.type && tok.text == target.text)
		{
			if (!*first) out.append(",");
			*first = false;

			usz line = find_line(&lo, tok.offset);
			usz col = tok.offset - lo.entries[line];
			usz end_col = col + tok.len;

			out.append(`{"uri":"`);
			json_escape_into(out, uri);
			out.appendf(`","range":{"start":{"line":%d,"character":%d},"end":{"line":%d,"character":%d}}}`, line, col, line, end_col);
		}
	}
}

// Encode rename (cross-file symbol rename).
// Output: JSON WorkspaceEdit object, or empty string if none.
fn void encode_rename(String uri, String content, usz offset, DocumentList* docs, String stdlib_path, String new_name, DString* out)
{
	TokenList tokens;
	tokens.init(mem);
	defer tokens.free();
	tokenize_content(content, &tokens);

	Token cursor_tok;
	usz cursor_idx;
	if (!find_token_at(&tokens, offset, &cursor_tok, &cursor_idx))
	{
		return;
	}

	TokenType ct = cursor_tok.type;
	if (!is_ident(ct) && ct != TYPE_IDENT && ct != CONST_IDENT) return;

	bool first_uri = true;
	out.append(`{"changes":{`);

	// 1. Current file
	collect_rename_edits(uri, content, &tokens, cursor_tok, new_name, out, &first_uri);

	// 2. Open documents
	for (usz d = 0; d < docs.size; d++)
	{
		if (docs.entries[d].uri == uri) continue;

		TokenList other_tokens;
		other_tokens.init(mem);
		tokenize_content(docs.entries[d].content, &other_tokens);
		collect_rename_edits(docs.entries[d].uri, docs.entries[d].content, &other_tokens, cursor_tok, new_name, out, &first_uri);
		other_tokens.free();
	}

	// 3. Scan project files on disk (skip stdlib — should not rename stdlib symbols)
	String file_path = uri_to_path(uri);
	if (file_path.len > 0)
	{
		scan_project_files_rename(file_path, cursor_tok, new_name, out, &first_uri);
	}

	out.append(`}}`);

	if (first_uri)
	{
		out.clear();
	}
}

// Collect rename edits for matching tokens in a single file, emitting a URI-keyed TextEdit array.
fn void collect_rename_edits(String uri, String content, TokenList* tokens, Token target, String new_name, DString* out, bool* first_uri) @private
{
	LineOffsets lo;
	lo.init(mem);
	defer lo.free();
	build_line_offsets(content, &lo);

	bool found_any = false;
	bool first_edit = true;

	foreach (tok : tokens)
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

			usz line = find_line(&lo, tok.offset);
			usz col = tok.offset - lo.entries[line];
			usz end_col = col + tok.len;

			out.appendf(`{"range":{"start":{"line":%d,"character":%d},"end":{"line":%d,"character":%d}},"newText":"`, line, col, line, end_col);
			json_escape_into(out, new_name);
			out.append(`"}`);
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
	get_project_search_dirs(file_path, &pdirs);
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
				TokenList tokens;
				tokens.init(mem);
				tokenize_content(content, &tokens);

				DString uri = dstring::temp();
				append_file_uri(&uri, full_path);
				collect_rename_edits(uri.str_view(), content, &tokens, target, new_name, out, first_uri);

				tokens.free();
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
fn void scan_project_files_refs(String file_path, Token target, DString* out, bool* first) @private
{
	ProjectDirs pdirs;
	get_project_search_dirs(file_path, &pdirs);
	if (pdirs.project_root.len == 0) return;

	for (usz i = 0; i < pdirs.count; i++)
	{
		DString search_path = dstring::temp();
		search_path.appendf("%s/%s", pdirs.project_root, pdirs.dirs[i]);
		scan_dir_recursive_refs(search_path.str_view(), target, out, first, 0);
	}
}

// Recursively scan directories for all references.
fn void scan_dir_recursive_refs(String dir_path, Token target, DString* out, bool* first, int depth) @private
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
				TokenList tokens;
				tokens.init(mem);
				tokenize_content(content, &tokens);

				DString uri = dstring::temp();
				append_file_uri(&uri, full_path);
				collect_refs_in_tokens(uri.str_view(), content, &tokens, target, out, first);

				tokens.free();
				mem::free(file_content);
			}
		}
		else
		{
			scan_dir_recursive_refs(full_path, target, out, first, depth + 1);
		}
	}
}
