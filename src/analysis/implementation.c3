module lsp;

import std::core::dstring;
import std::core::mem;
import c3::lexer;

// textDocument/implementation — navigate from an abstraction to the concrete code
// behind it. C3 expresses that with interfaces, so there are two useful directions:
//
//   * cursor on an interface name  -> the types whose conformance clause lists it,
//                                     e.g. `struct RefsScan (FileVisitor)`
//   * cursor on a method name      -> the `fn ... Type.method(...) @dynamic`
//                                     definitions that provide it, whether the cursor
//                                     sits on the interface's declaration of the
//                                     method or on a call through the interface
//
// Method lookup keys on the name plus `@dynamic` rather than proving that the owning
// type implements the interface in question: @dynamic exists precisely to mark
// interface dispatch, and confirming conformance would mean resolving every candidate
// type's declaration across the project for each hit.

// Type declarations that can carry a conformance clause.
fn bool is_type_decl_keyword(TokenType t)
{
	return t == STRUCT || t == UNION || t == BITSTRUCT || t == ENUM || t == TYPEDEF || t == ALIAS;
}

// Index of the `(` opening the parameter list of the fn/macro whose keyword sits at
// keyword_idx, or 0 when there is none. A `{...}` before it is a generic return type
// (`fn List{int} foo()`), not the body, so it is stepped over.
fn sz TokenList.find_callable_lparen(&self, sz keyword_idx)
{
	for (sz j = keyword_idx + 1; j < self.size && j < keyword_idx + MAX_LOOKAHEAD; j++)
	{
		TokenType t = self.entries[j].type;
		if (t == LPAREN) return j;
		if (t == LBRACE)
		{
			j = self.match_rbrace(j);
			if (j >= self.size) return 0;
			continue;
		}
		if (t == EOS) return 0;
	}
	return 0;
}

// True when the declaration whose parameter list opens at lparen_idx carries @dynamic,
// the attribute C3 requires on a method implementing an interface. Attributes sit
// between the parameter list and the body, so the search stops at `{` or `;`.
fn bool TokenList.has_dynamic_attribute(&self, sz lparen_idx)
{
	sz rparen = self.match_rparen(lparen_idx);
	if (rparen >= self.size) return false;
	for (sz j = rparen + 1; j < self.size; j++)
	{
		TokenType t = self.entries[j].type;
		if (t == LBRACE || t == EOS) return false;
		// The lexeme keeps its leading '@'.
		if (t == AT_IDENT && self.entries[j].text == "@dynamic") return true;
	}
	return false;
}

// True when the type named at name_idx lists `iface` among the interfaces it implements.
//
// The conformance clause is a parenthesised list of bare type names after the type's
// name: `struct Foo (Printable, Hashable)`. Enums spell their associated-value list with
// the same parentheses (`enum E : int (String desc)`), so an entry only counts when the
// type name stands alone — followed by a comma or the closing paren, never by a
// parameter name.
fn bool TokenList.type_implements(&self, sz name_idx, String iface)
{
	for (sz j = name_idx + 1; j < self.size; j++)
	{
		TokenType t = self.entries[j].type;
		if (t == LBRACE || t == EOS) return false;
		if (t != LPAREN) continue;

		sz rparen = self.match_rparen(j);
		if (rparen >= self.size) return false;
		for (sz k = j + 1; k + 1 <= rparen && k + 1 < self.size; k++)
		{
			if (self.entries[k].type != TYPE_IDENT) continue;
			TokenType next = self.entries[k + 1].type;
			if (next != COMMA && next != RPAREN) continue;
			if (self.entries[k].text == iface) return true;
		}
		return false;
	}
	return false;
}

// Append a Location for every implementation found in one token stream. Exactly one of
// `iface` / `method` is set by the caller.
fn void TokenList.collect_implementations(&self, String uri, String content, String iface,
	String method, DString* out, bool* first)
{
	if (method.len > 0)
	{
		for (sz i = 0; i < self.size; i++)
		{
			TokenType t = self.entries[i].type;
			if (t != FUNC && t != MACRO) continue;

			sz lparen = self.find_callable_lparen(i);
			// Need at least `TYPE_IDENT DOT name (` between the keyword and the paren.
			if (lparen < i + 4) continue;

			Token name_tok = self.entries[lparen - 1];
			if (!is_ident(name_tok.type) || name_tok.text != method) continue;
			if (self.entries[lparen - 2].type != DOT) continue;
			if (self.entries[lparen - 3].type != TYPE_IDENT) continue;
			if (!self.has_dynamic_attribute(lparen)) continue;

			if (!*first) out.append_char(',');
			*first = false;
			emit_location(uri, content, name_tok, out);
		}
		return;
	}

	if (iface.len == 0) return;
	for (sz i = 0; i + 1 < self.size; i++)
	{
		if (!is_type_decl_keyword(self.entries[i].type)) continue;
		if (self.entries[i + 1].type != TYPE_IDENT) continue;
		if (!self.type_implements(i + 1, iface)) continue;

		if (!*first) out.append_char(',');
		*first = false;
		emit_location(uri, content, self.entries[i + 1], out);
	}
}

// On-disk implementation collection, driven through the shared scan engine.
struct ImplScan (FileVisitor) @private
{
	String iface;
	String method;
	DString* out;
	bool* first;
	String origin_uri;
	DocumentList* docs;
}

fn bool ImplScan.visit(&self, String path, String content, TokenStream* stream) @dynamic
{
	if (already_collected(path, self.origin_uri, self.docs)) return false;
	DString uri = dstring::temp();
	append_file_uri(&uri, path);
	stream.tokens.collect_implementations(uri.str_view(), content, self.iface, self.method, self.out, self.first);
	return false; // collect-all: never stop early
}

// Encode a textDocument/implementation response: a JSON array of Locations, or an
// empty string when there is nothing to report (the handler answers `null` then).
fn void encode_implementation(String uri, String content, sz offset, DocumentList* docs,
	String stdlib_path, DString* out)
{
	// Reuse the open document's cached token stream when available.
	TokenStream owned;
	bool owns;
	TokenStream* stream = token_stream_for_doc(uri, content, docs, &owned, &owns);
	defer { if (owns) owned.free(); }

	Token cursor_tok;
	sz cursor_idx;
	if (!stream.tokens.find_token_at(offset, &cursor_tok, &cursor_idx)) return;

	// A type name asks "who implements this interface"; a plain identifier asks "which
	// @dynamic method bodies provide this call".
	String iface  = "";
	String method = "";
	if (cursor_tok.type == TYPE_IDENT)
	{
		iface = cursor_tok.text;
	}
	else if (is_ident(cursor_tok.type))
	{
		method = cursor_tok.text;
	}
	else
	{
		return;
	}

	bool first = true;
	out.append("[");

	// 1. Current file.
	stream.tokens.collect_implementations(uri, content, iface, method, out, &first);

	// 2. Open documents (their unsaved content wins over the copy on disk).
	for (sz d = 0; d < docs.size; d++)
	{
		if (docs.entries[d].uri == uri) continue;
		TokenStream* other = docs.entries[d].get_tokens();
		other.tokens.collect_implementations(docs.entries[d].uri, docs.entries[d].content,
			iface, method, out, &first);
	}

	// 3 + 4. Project files on disk, then the stdlib.
	ImplScan scan = { iface, method, out, &first, uri, docs };
	scan_project_then_stdlib(uri_to_path(uri), stdlib_path, &scan);

	out.append("]");

	if (first)
	{
		out.clear();
	}
}
