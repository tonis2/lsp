module lsp;

import std::core::dstring;
import std::core::mem;
import std::collections::list;
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

	// A local variable or parameter: only the uses that resolve to the same
	// declaration, so a sibling block's own `abc` stays unmarked.
	LocalScope scope;
	if (try decl = stream.tokens.local_target(cursor_idx, &scope))
	{
		bool first = true;
		out.append("[");
		for (sz i = scope.lparen + 1; i < scope.end; i++)
		{
			if (stream.tokens.refers_to_local(i, decl, scope)) append_highlight(stream.tokens.entries[i], lo, out, &first);
		}
		out.append("]");
		if (first) out.clear();
		return;
	}

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

			append_highlight(tok, lo, out, &first);
		}
	}
	out.append("]");

	// If we only wrote "[]", clear output to signal nothing found
	if (first)
	{
		out.clear();
	}
}

// Append one DocumentHighlight, handling the JSON comma between entries.
fn void append_highlight(Token tok, LineOffsets* lo, DString* out, bool* first) @private
{
	if (!*first) out.append(",");
	*first = false;

	sz line = lo.find_line(tok.offset);
	sz col = tok.offset - lo.entries[line];

	DocumentHighlight highlight = {
		.range = {
			.start = {.line = line, .character = col},
			.end = {.line = line, .character = col + tok.len},
		},
		.kind = 1,
	};
	highlight.encode(out);
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

	// A local variable or parameter never leaves its fn/macro: report the uses
	// that resolve to the same declaration and skip the cross-file search.
	LocalScope scope;
	if (try decl = stream.tokens.local_target(cursor_idx, &scope))
	{
		LineOffsets* lo = stream.get_line_offsets();
		bool first = true;
		out.append("[");
		for (sz i = scope.lparen + 1; i < scope.end; i++)
		{
			if (i == decl && !include_decl) continue;
			if (stream.tokens.refers_to_local(i, decl, scope)) append_ref_location(uri, stream.tokens.entries[i], lo, out, &first);
		}
		out.append("]");
		if (first) out.clear();
		return;
	}

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
	if (is_member)
	{
		// A method declaration writes `Shape.run`, its calls write `s.run`: the
		// receivers never match textually, which is why the declaration and its
		// calls used to be reported as two disjoint sets. Matching on the type the
		// receiver resolves to joins them, and still keeps `other.run()` on an
		// unrelated type out. Without a resolvable type, fall back to the literal
		// receiver rather than over-report.
		String owner = stream.tokens.member_owner_type(cursor_idx, uri, docs, stdlib_path);
		if (owner.len > 0)
		{
			stream.tokens.collect_member_refs(uri, content, cursor_tok, owner, docs, stdlib_path, out, &first);
		}
		else
		{
			stream.tokens.collect_refs(uri, content, cursor_tok, out, &first, true, member_receiver);
		}
	}
	else
	{
		stream.tokens.collect_refs(uri, content, cursor_tok, out, &first);
	}

	if (!is_member)
	{
		// Only search cross-file for non-member identifiers.
		// Member accesses (e.g. .tokens, .type) cannot be resolved without type
		// information, so cross-file matches would be false positives.

		// Occurrences in another file only count when that file can see the
		// module declaring the symbol (same module tree, an import, or the
		// implicit std::core) — a same-named symbol in an unrelated module is
		// a different symbol. Unknown module ("") keeps the old name-only match.
		String target_module = find_symbol_module(&stream.tokens, cursor_tok, uri, docs, stdlib_path);

		// 2. Open documents (reuse their cached token streams)
		for (sz d = 0; d < docs.size; d++)
		{
			if (docs.entries[d].uri == uri) continue;

			TokenStream* other_stream = docs.entries[d].get_tokens();
			if (!file_can_see(&other_stream.tokens, target_module)) continue;
			other_stream.tokens.collect_refs(docs.entries[d].uri, docs.entries[d].content, cursor_tok, out, &first);
		}

		// 3 + 4. Scan project files on disk, then stdlib
		String file_path = uri_to_path(uri);
		RefsScan scan = { cursor_tok, out, &first, target_module, uri, docs };
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

			append_ref_location(uri, tok, &lo, out, first);
		}
	}
}

// The type that owns the member named at `idx`, or "" when it cannot be resolved.
// A method declaration writes its receiver outright (`fn void Shape.run(&self)`), as
// does a namespaced access (`Color.RED`); anything else is an expression whose type
// has to be inferred.
fn String TokenList.member_owner_type(&self, sz idx, String uri, DocumentList* docs, String stdlib_path)
{
	if (idx < 2 || self.entries[idx - 1].type != DOT) return "";
	if (self.entries[idx - 2].type == TYPE_IDENT) return self.entries[idx - 2].text;
	return self.resolve_receiver_type(idx, uri, docs, stdlib_path);
}

// Occurrences of `target` that are members of `owner_type` — the declaration
// `fn void Shape.run(&self)` together with every `x.run()` whose receiver resolves to
// Shape. Same-file only: resolving a receiver in another file needs that file's own
// scope, which this pass does not carry.
fn void TokenList.collect_member_refs(
	&self,
	String uri,
	String content,
	Token target,
	String owner_type,
	DocumentList* docs,
	String stdlib_path,
	DString* out,
	bool* first
)
{
	LineOffsets lo;
	lo.init(mem);
	defer lo.free();
	lo.build(content);

	for (sz i = 0; i < self.size; i++)
	{
		Token tok = self.entries[i];
		if (tok.type != target.type || tok.text != target.text) continue;
		if (i == 0 || self.entries[i - 1].type != DOT) continue;
		if (self.member_owner_type(i, uri, docs, stdlib_path) != owner_type) continue;
		append_ref_location(uri, tok, &lo, out, first);
	}
}

// Append one Location, handling the JSON comma between entries.
fn void append_ref_location(String uri, Token tok, LineOffsets* lo, DString* out, bool* first) @private
{
	if (!*first) out.append(",");
	*first = false;

	sz line = lo.find_line(tok.offset);
	sz col = tok.offset - lo.entries[line];

	Location loc = {
		.uri = uri,
		.range = {
			.start = {.line = line, .character = col},
			.end = {.line = line, .character = col + tok.len},
		},
	};
	loc.encode(out);
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

	bool first_uri = true;
	out.append(`{"changes":{`);

	LocalScope scope;
	sz decl;
	RenameReach reach = stream.tokens.rename_reach(cursor_idx, uri, docs, &scope, &decl);
	if (reach == LOCAL || reach == FUNCTION)
	{
		List{Token} toks;
		toks.tinit();
		for (sz i = scope.lparen + 1; i < scope.end; i++)
		{
			Token tok = stream.tokens.entries[i];
			bool hit = reach == LOCAL
				? stream.tokens.refers_to_local(i, decl, scope)
				: tok.type == ct && tok.text == cursor_tok.text;
			if (hit) toks.push(tok);
		}
		emit_rename_edits(uri, stream.get_line_offsets(), toks.array_view(), new_name, out, &first_uri);
	}
	else if (reach == GLOBAL)
	{
		// Module-level symbol — rename globally across all files
		// 1. Current file
		stream.tokens.collect_rename_edits(uri, content, cursor_tok, new_name, out, &first_uri);

		// Same visibility rule as find-references: only touch files that can see
		// the symbol's module, so a same-named symbol in an unrelated module is
		// not silently renamed along with it.
		String target_module = find_symbol_module(&stream.tokens, cursor_tok, uri, docs, stdlib_path);

		// 2. Open documents (reuse their cached token streams)
		for (sz d = 0; d < docs.size; d++)
		{
			if (docs.entries[d].uri == uri) continue;

			TokenStream* other_stream = docs.entries[d].get_tokens();
			if (!file_can_see(&other_stream.tokens, target_module)) continue;
			other_stream.tokens.collect_rename_edits(docs.entries[d].uri, docs.entries[d].content, cursor_tok, new_name, out, &first_uri);
		}

		// 3. Scan project files on disk (skip stdlib — should not rename stdlib symbols)
		String file_path = uri_to_path(uri);
		if (file_path.len > 0)
		{
			RenameScan scan = { cursor_tok, new_name, out, &first_uri, target_module, uri, docs };
			scan_project_dirs(file_path, &scan);
		}
	}

	out.append(`}}`);

	if (first_uri)
	{
		out.clear();
	}
}

// How far a rename from the token at `idx` reaches.
enum RenameReach
{
	LOCAL,    // a local or parameter: the uses resolving to its declaration (`decl`)
	FUNCTION, // an unresolved name inside a fn/macro: every same-named token there
	GLOBAL,   // a module-level symbol: every file that can see it
	NONE,     // declared outside the project (the stdlib): renaming it would break the code
}

// Renaming `helper` from a call inside some function body must still rename its
// declaration and every other caller, so being inside a function is not enough to
// make a name local: it has to resolve to a local declaration.
fn RenameReach TokenList.rename_reach(&self, sz idx, String uri, DocumentList* docs, LocalScope* scope, sz* decl)
{
	Token tok = self.entries[idx];
	if (tok.type == TYPE_IDENT || tok.type == CONST_IDENT)
	{
		return has_project_declaration(self, tok, uri, docs) ? GLOBAL : NONE;
	}
	if (try d = self.local_target(idx, scope))
	{
		*decl = d;
		return LOCAL;
	}
	LocalScope? around = self.callable_around(idx);
	if (catch around) return GLOBAL;
	*scope = around;

	TokenType prev = idx > 0 ? self.entries[idx - 1].type : EOS;
	// Members keep the old function-wide rename: matching them up needs the
	// receiver's type.
	if (prev == DOT) return FUNCTION;
	// A trailing body parameter (`macro @each(list; @body)`).
	for (sz j = around.lparen + 1; j < around.rparen; j++)
	{
		if (self.entries[j].text == tok.text) return FUNCTION;
	}
	if (has_project_declaration(self, tok, uri, docs)) return GLOBAL;
	// A call or qualified name with no declaration in the project lives in the
	// stdlib or another library.
	if (prev == SCOPE || (idx + 1 < self.size && self.entries[idx + 1].type == LPAREN)) return NONE;
	// A local written in a form the declaration matcher does not know.
	return FUNCTION;
}

// True when `tok` has a module-level declaration in this file, an open document or
// a project file (the stdlib is not searched).
fn bool has_project_declaration(TokenList* tokens, Token tok, String uri, DocumentList* docs) @private
{
	if (tokens.declares_globally(tok)) return true;
	for (sz d = 0; d < docs.size; d++)
	{
		if (docs.entries[d].uri == uri) continue;
		if (docs.entries[d].get_tokens().tokens.declares_globally(tok)) return true;
	}
	String path = uri_to_path(uri);
	if (path.len == 0) return false;
	GlobalDeclScan scan = { tok };
	return scan_project_dirs(path, &scan);
}

// Types and constants are never locals, so the cursor-less declaration search
// is exact for them; plain names have to skip locals and parameters.
fn bool TokenList.declares_globally(&self, Token tok)
{
	if (tok.type == TYPE_IDENT || tok.type == CONST_IDENT) return @ok(self.find_declaration_in(tok));
	return @ok(self.find_global_declaration(tok.text));
}

struct GlobalDeclScan (FileVisitor) @private
{
	Token target;
}

fn bool GlobalDeclScan.visit(&self, String path, String content, TokenStream* stream) @dynamic
{
	return stream.tokens.declares_globally(self.target);
}

// Rename edits for `toks` in one file, as a URI-keyed TextEdit array.
fn void emit_rename_edits(String uri, LineOffsets* lo, Token[] toks, String new_name, DString* out, bool* first_uri) @private
{
	if (toks.len == 0) return;
	if (!*first_uri) out.append(",");
	*first_uri = false;
	out.append(`"`);
	json_escape_into(out, uri);
	out.append(`":[`);
	foreach (i, tok : toks)
	{
		if (i > 0) out.append(",");
		sz line = lo.find_line(tok.offset);
		sz col = tok.offset - lo.entries[line];
		TextEdit edit = {
			.range = {
				.start = {.line = line, .character = col},
				.end = {.line = line, .character = col + tok.len},
			},
			.new_text = new_name,
		};
		edit.encode(out);
	}
	out.append("]");
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

// True when `path` was already collected from an in-memory buffer — either the
// request's own document or another open document. The on-disk scan covers the
// same project directories those files live in, so without this every hit in an
// open file is emitted a second time (and from staler content).
fn bool already_collected(String path, String origin_uri, DocumentList* docs) @private
{
	if (origin_uri.len > 0 && path_matches_uri(path, origin_uri)) return true;
	if (docs == null) return false;
	for (sz d = 0; d < docs.size; d++)
	{
		if (path_matches_uri(path, docs.entries[d].uri)) return true;
	}
	return false;
}

// On-disk rename-edit collection, driven through the shared scan engine.
struct RenameScan (FileVisitor) @private
{
	Token target;
	String new_name;
	DString* out;
	bool* first_uri;
	String target_module;
	String origin_uri;
	DocumentList* docs;
}

fn bool RenameScan.visit(&self, String path, String content, TokenStream* stream) @dynamic
{
	if (already_collected(path, self.origin_uri, self.docs)) return false;
	if (!file_can_see(&stream.tokens, self.target_module)) return false;
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
	String target_module;
	String origin_uri;
	DocumentList* docs;
}

fn bool RefsScan.visit(&self, String path, String content, TokenStream* stream) @dynamic
{
	if (already_collected(path, self.origin_uri, self.docs)) return false;
	if (!file_can_see(&stream.tokens, self.target_module)) return false;
	DString uri = dstring::temp();
	append_file_uri(&uri, path);
	stream.tokens.collect_refs(uri.str_view(), content, self.target, self.out, self.first);
	return false; // collect-all: never stop early
}
