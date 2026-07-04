module lsp;

import std::core::dstring;
import std::core::mem;
import std::io::file;
import std::io::path;
import c3::lexer;

// Encode document highlights (same-file occurrences of the symbol under cursor).
// Output: JSON array of DocumentHighlight objects, or empty string if none.
fn void encode_document_highlights(String content, sz offset, DString* out, TokenStream* cached = null)
{
	TokenStream owned;
	TokenStream* stream;
	if (cached != null) { stream = cached; }
	else { owned = token_stream_tokenize(content); stream = &owned; }
	defer { if (cached == null) owned.free(); }

	Token cursor_tok;
	sz cursor_idx;
	if (!stream.tokens.find_token_at(offset, &cursor_tok, &cursor_idx)) return;

	TokenType ct = cursor_tok.type;
	if (!is_ident(ct) && ct != TYPE_IDENT && ct != CONST_IDENT) return;

	LineOffsets* lo = stream.get_line_offsets();

	// Detect if cursor is on a member access (preceded by DOT)
	bool is_member = cursor_idx > 0 && stream.tokens.entries[cursor_idx - 1].type == DOT;
	String member_receiver = "";
	if (is_member && cursor_idx >= 2)
	{
		Token recv = stream.tokens.entries[cursor_idx - 2];
		if (is_ident(recv.type) || recv.type == TYPE_IDENT || recv.type == CONST_IDENT)
		{
			member_receiver = recv.text;
		}
	}

	bool first = true;
	out.append("[");
	for (sz i = 0; i < stream.tokens.size; i++)
	{
		Token tok = stream.tokens.entries[i];
		if (tok.type == ct && tok.text == cursor_tok.text)
		{
			// Filter: member access tokens only match other member access tokens
			bool tok_is_member = i > 0 && stream.tokens.entries[i - 1].type == DOT;
			if (is_member != tok_is_member) continue;

			// For member accesses, require the receiver (ident before DOT) to match
			if (is_member && member_receiver.len > 0 && i >= 2)
			{
				Token recv = stream.tokens.entries[i - 2];
				if (recv.text != member_receiver) continue;
			}

			if (!first) out.append(",");
			first = false;

			sz line = lo.find_line(tok.offset);
			sz col = tok.offset - lo.entries[line];
			sz end_col = col + tok.len;

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
fn void encode_references(String uri, String content, sz offset, DocumentList* docs, String stdlib_path, bool include_decl, DString* out)
{
	// Reuse the open document's cached token stream when available.
	TokenStream owned;
	bool owns;
	TokenStream* stream = token_stream_for_doc(uri, content, docs, &owned, &owns);
	defer { if (owns) owned.free(); }

	Token cursor_tok;
	sz cursor_idx;
	if (!stream.tokens.find_token_at(offset, &cursor_tok, &cursor_idx)) return;

	TokenType ct = cursor_tok.type;
	if (!is_ident(ct) && ct != TYPE_IDENT && ct != CONST_IDENT) return;

	// Detect if cursor is on a member access (preceded by DOT).
	// For member accesses, find the receiver name (IDENT before DOT) and restrict
	// matching to same receiver.member patterns. This avoids false positives where
	// e.g. `.type` on one struct matches `.type` on a completely different struct.
	bool is_member = cursor_idx > 0 && stream.tokens.entries[cursor_idx - 1].type == DOT;
	String member_receiver = "";
	if (is_member && cursor_idx >= 2)
	{
		Token recv = stream.tokens.entries[cursor_idx - 2];
		if (is_ident(recv.type) || recv.type == TYPE_IDENT || recv.type == CONST_IDENT)
		{
			member_receiver = recv.text;
		}
	}

	bool first = true;
	out.append("[");

	// 1. Current file — collect all matching tokens
	stream.tokens.collect_refs(uri, content, cursor_tok, out, &first, is_member, member_receiver);

	if (!is_member)
	{
		// Only search cross-file for non-member identifiers.
		// Member accesses (e.g. .tokens, .type) cannot be resolved without type
		// information, so cross-file matches would be false positives.

		// 2. Open documents (reuse their cached token streams)
		for (sz d = 0; d < docs.size; d++)
		{
			if (docs.entries[d].uri == uri) continue;

			TokenStream* other_stream = docs.entries[d].get_tokens();
			other_stream.tokens.collect_refs(docs.entries[d].uri, docs.entries[d].content, cursor_tok, out, &first);
		}

		// 3 + 4. Scan project files on disk, then stdlib
		String file_path = uri_to_path(uri);
		RefsScan scan = { cursor_tok, out, &first };
		scan_project_then_stdlib(file_path, stdlib_path, &scan);
	}

	out.append("]");

	if (first)
	{
		out.clear();
	}
}

// Collect all tokens matching target name+type from a pre-tokenized stream, emitting Location JSON.
// When member_access is true, only matches tokens preceded by DOT with the same receiver name.
fn void TokenList.collect_refs(&self, String uri, String content, Token target, DString* out, bool* first, bool member_access = false, String member_receiver = "")
{
	LineOffsets lo;
	lo.init(mem);
	defer lo.free();
	lo.build(content);

	for (sz i = 0; i < self.size; i++)
	{
		Token tok = self.entries[i];
		if (tok.type == target.type && tok.text == target.text)
		{
			bool tok_is_member = i > 0 && self.entries[i - 1].type == DOT;
			if (member_access != tok_is_member) continue;

			// For member accesses, require the receiver (ident before DOT) to match
			if (member_access && member_receiver.len > 0 && i >= 2)
			{
				Token recv = self.entries[i - 2];
				if (recv.text != member_receiver) continue;
			}

			if (!*first) out.append(",");
			*first = false;

			sz line = lo.find_line(tok.offset);
			sz col = tok.offset - lo.entries[line];
			sz end_col = col + tok.len;

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
fn sz[2] TokenList.find_function_scope(&self, sz offset)
{
	for (sz i = 0; i < self.size; i++)
	{
		TokenType tt = self.entries[i].type;
		if (tt == FUNC || tt == MACRO)
		{
			sz brace_end = self.find_brace_end(i + 1);
			if (brace_end == 0) continue;

			// Find the opening paren and brace offsets
			sz paren_start = 0;
			sz brace_start = 0;
			for (sz j = i + 1; j < self.size; j++)
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
fn void encode_rename(String uri, String content, sz offset, DocumentList* docs, String stdlib_path, String new_name, DString* out)
{
	// Reuse the open document's cached token stream when available.
	TokenStream owned;
	bool owns;
	TokenStream* stream = token_stream_for_doc(uri, content, docs, &owned, &owns);
	defer { if (owns) owned.free(); }

	Token cursor_tok;
	sz cursor_idx;
	if (!stream.tokens.find_ident_token_at(offset, &cursor_tok, &cursor_idx))
	{
		return;
	}

	TokenType ct = cursor_tok.type;
	if (!is_ident(ct) && ct != TYPE_IDENT && ct != CONST_IDENT) return;

	// Check if cursor is inside a function body — if so, restrict rename to that scope
	sz[2] scope = stream.tokens.find_function_scope(offset);

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

		// 2. Open documents (reuse their cached token streams)
		for (sz d = 0; d < docs.size; d++)
		{
			if (docs.entries[d].uri == uri) continue;

			TokenStream* other_stream = docs.entries[d].get_tokens();
			other_stream.tokens.collect_rename_edits(docs.entries[d].uri, docs.entries[d].content, cursor_tok, new_name, out, &first_uri);
		}

		// 3. Scan project files on disk (skip stdlib — should not rename stdlib symbols)
		String file_path = uri_to_path(uri);
		if (file_path.len > 0)
		{
			RenameScan scan = { cursor_tok, new_name, out, &first_uri };
			scan_project_dirs(file_path, &scan);
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

			sz line = lo.find_line(tok.offset);
			sz col = tok.offset - lo.entries[line];
			sz end_col = col + tok.len;

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
	String new_name, DString* out, bool* first_uri, sz scope_start, sz scope_end)
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

			sz line = lo.find_line(tok.offset);
			sz col = tok.offset - lo.entries[line];
			sz end_col = col + tok.len;

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

// On-disk rename-edit collection, driven through the shared scan engine.
struct RenameScan (FileVisitor) @private
{
	Token target;
	String new_name;
	DString* out;
	bool* first_uri;
}

fn bool RenameScan.visit(&self, String path, String content, TokenStream* stream) @dynamic
{
	DString uri = dstring::temp();
	append_file_uri(&uri, path);
	stream.tokens.collect_rename_edits(uri.str_view(), content, self.target, self.new_name, self.out, self.first_uri);
	return false; // collect-all: never stop early
}

// On-disk reference collection, driven through the shared scan engine.
struct RefsScan (FileVisitor) @private
{
	Token target;
	DString* out;
	bool* first;
}

fn bool RefsScan.visit(&self, String path, String content, TokenStream* stream) @dynamic
{
	DString uri = dstring::temp();
	append_file_uri(&uri, path);
	stream.tokens.collect_refs(uri.str_view(), content, self.target, self.out, self.first);
	return false; // collect-all: never stop early
}
