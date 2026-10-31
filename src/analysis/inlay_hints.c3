module lsp;

import std::core::dstring;
import std::collections::list;
import std::collections::map;
import c3::lexer;

// Encodes a textDocument/inlayHint response: the parameter name before each argument
// of a call, `move(x: 1, y: 2)`. The callee is resolved the way signature help resolves
// it (callee_lookup): current file -> open documents -> project files -> stdlib.
//
// An argument gets no hint when it already says what it is: a named argument, a spread
// `...args`, or an argument spelled like the parameter (`tformat(format, ...)`).
// Variadic arguments get none either, since they all share one name.

const MAX_PARAM_NAMES = 32;

// The parameter names of one callable declaration.
struct ParamNames
{
	String[MAX_PARAM_NAMES] names; // "" for an unnamed parameter (`fn void f(int, int)`)
	sz count;
	bool has_self;                 // names[0] is a method's receiver
	sz variadic_at;                // index of the variadic parameter, or count
	bool found;
}

// The parameter names of the function or macro whose NAME token is at `name_idx`.
// A macro's trailing body parameters (after `;`) are not passed in the argument list
// and end it. False when `name_idx` is not a callable declaration.
fn bool TokenList.param_names_at(&self, sz name_idx, ParamNames* out)
{
	sz kw_idx;
	sz lparen;
	if (!self.callable_lparen(name_idx, &kw_idx, &lparen)) return false;
	*out = { .found = true };
	bool has_variadic = false;
	// The parameter being read: its name so far, whether it is variadic, and whether its
	// default value has started (whose identifiers are not the name).
	String name = "";
	bool variadic = false;
	bool in_default = false;
	bool empty = true;
	sz depth = 0;
	for (sz j = lparen + 1; j < self.size; j++)
	{
		TokenType t = self.entries[j].type;
		if (t == LPAREN || t == LBRACE || t == LBRACKET) { depth++; empty = false; continue; }
		bool close = t == RPAREN || t == RBRACE || t == RBRACKET;
		if (close && depth > 0) { depth--; continue; }
		if (depth > 0) continue;
		if (close || t == COMMA || t == EOS)
		{
			if (empty && out.count == 0) break; // `()`, `(;@body)`
			if (out.count < MAX_PARAM_NAMES)
			{
				if (variadic && !has_variadic)
				{
					has_variadic = true;
					out.variadic_at = out.count;
				}
				if (out.count == 0 && name == "self") out.has_self = true;
				out.names[out.count++] = name.tcopy();
			}
			if (close || t == EOS) break;
			name = "";
			variadic = false;
			in_default = false;
			empty = true;
			continue;
		}
		empty = false;
		switch (t)
		{
			case ELLIPSIS:
				variadic = true;
			case EQ:
				in_default = true;
			case IDENT:
			case CT_IDENT:
			case HASH_IDENT:
			case CT_TYPE_IDENT:
				// The name is the last identifier before the parameter ends or its default.
				if (!in_default) name = self.entries[j].text;
			default:
				break;
		}
	}
	if (!has_variadic) out.variadic_at = out.count;
	return true;
}

// Whether the identifier at `idx` names the function or macro being declared rather
// than one being called: `fn T name(`, `fn T Type.name(`, `fn T List{Type}.name(`,
// `macro @name(`. Walks back over the return and receiver types to the keyword.
fn bool TokenList.is_callable_decl_name(&self, sz idx)
{
	for (sz k = idx; k > 0; k--)
	{
		TokenType t = self.entries[k - 1].type;
		if (t == FUNC || t == MACRO) return true;
		if (t == RBRACE)
		{
			sz open = self.match_lbrace_back(k - 1);
			if (open >= self.size) return false;
			k = open + 1;
			continue;
		}
		if (t == EOS || t == LBRACE || t == EQ || t == LPAREN || t == RPAREN || t == COMMA
			|| t == RETURN || t == COLON) return false;
	}
	return false;
}

// One call in the requested range and how to look up its callee.
struct InlayCall
{
	sz name_idx;
	sz lparen;
	sz rparen;
	CalleeLookup lookup;
}

// A declaration search not answered by the current file or the open documents yet.
struct PendingLookup
{
	Token target;
	String method_type;
	String module_filter;
	String key;
}

// Per-request state. Calls are resolved in batches: every declaration the open files
// don't answer is searched for in one walk over the project and the stdlib, instead
// of one walk per callee.
struct InlayQuery
{
	TokenStream* stream;
	String content;
	String uri;
	DocumentList* docs;
	String stdlib_path;
	HashMap{String, ParamNames} memo; // a declaration search -> its result, misses included
	List{PendingLookup} pending;
	HashMap{String, bool} pending_names;
}

fn String lookup_key(Token target, String method_type, String module_filter) @private
{
	return string::tformat("%s|%s|%s", method_type, module_filter, target.text);
}

// Look `target` up in the current file and the open documents now; queue it for the
// next `flush` when they don't declare it.
fn void InlayQuery.request(&self, Token target, String method_type, String module_filter)
{
	String key = lookup_key(target, method_type, module_filter);
	if (self.memo.has_key(key)) return;
	ParamNames found;
	if (!self.stream.tokens.find_params(target, method_type, module_filter, &found) && self.docs != null)
	{
		for (sz d = 0; d < self.docs.size; d++)
		{
			if (self.docs.entries[d].uri == self.uri) continue;
			if (self.docs.entries[d].get_tokens().tokens.find_params(target, method_type, module_filter, &found)) break;
		}
	}
	// A queued key stays a miss unless `flush` finds it.
	self.memo.set(key, found);
	if (found.found) return;
	self.pending.push({ target, method_type, module_filter, key });
	self.pending_names.set(target.text, true);
}

// Search the project, then the stdlib, for every queued declaration in one walk.
fn void InlayQuery.flush(&self)
{
	if (self.pending.len() == 0) return;
	String file_path = self.uri.len > 0 ? uri_to_path(self.uri) : "";
	BatchParamScan scan = { self, self.pending.len() };
	scan_project_then_stdlib(file_path, self.stdlib_path, &scan);
	self.pending.clear();
	self.pending_names.clear();
}

fn ParamNames InlayQuery.answer(&self, Token target, String method_type, String module_filter)
{
	return self.memo.get(lookup_key(target, method_type, module_filter)) ?? {};
}

fn bool TokenList.find_params(&self, Token target, String method_type, String module_filter, ParamNames* out)
{
	if (try idx = self.find_declaration_in(target, method_type, module_filter))
	{
		return self.param_names_at(idx, out);
	}
	return false;
}

struct BatchParamScan (FileVisitor) @private
{
	InlayQuery* query;
	sz unresolved;
}

fn bool BatchParamScan.visit(&self, String path, String content, TokenStream* stream) @dynamic
{
	InlayQuery* q = self.query;
	// One pass over the file for the queued names it mentions at all; only those are
	// searched for, so a file costs one walk however many lookups are queued.
	HashMap{String, bool} present;
	present.tinit();
	foreach (tok : stream.tokens.entries[:stream.tokens.size])
	{
		if (is_ident(tok.type) && q.pending_names.has_key(tok.text)) present.set(tok.text, true);
	}
	if (present.len() == 0) return false;
	foreach (&p : q.pending)
	{
		if (!present.has_key(p.target.text)) continue;
		if (q.memo.get(p.key)!!.found) continue;
		// param_names_at copies the names, which slice into the file content.
		ParamNames found;
		if (!stream.tokens.find_params(p.target, p.method_type, p.module_filter, &found)) continue;
		q.memo.set(p.key, found);
		if (--self.unresolved == 0) return true;
	}
	return false;
}

// Whether the argument tokens [start, end) are spelled like the parameter `name`:
// `name`, `&name`, `self.name`, `*ptr.name`.
fn bool TokenList.arg_spells(&self, sz start, sz end, String name)
{
	if (end <= start || self.entries[end - 1].text != name) return false;
	for (sz k = start; k < end; k++)
	{
		TokenType t = self.entries[k].type;
		if (t != IDENT && t != DOT && t != AMP && t != STAR) return false;
	}
	return true;
}

// Write the hints of `call`'s arguments that start within [from, to].
fn void InlayQuery.encode_call(&self, InlayCall* call, sz from, sz to, LineOffsets* lo, DString* out, bool* first)
{
	TokenList* toks = &self.stream.tokens;
	Token target = toks.entries[call.name_idx];
	ParamNames params;
	for (sz ci = 0; ci < call.lookup.count && !params.found; ci++)
	{
		params = self.answer(target, call.lookup.method_types[ci], call.lookup.module_filter);
	}
	if (!params.found) return;
	sz name_idx = call.name_idx;
	sz lparen = call.lparen;
	sz rparen = call.rparen;
	CalleeLookup* lookup = &call.lookup;

	// `x.method(a)` passes the receiver implicitly; `Type.method(x, a)` spells it out.
	sz param = 0;
	if (params.has_self)
	{
		bool explicit_self = lookup.is_method && name_idx >= 2 && toks.entries[name_idx - 2].type == TYPE_IDENT;
		if (!explicit_self) param = 1;
	}

	sz depth = 0;
	sz arg_start = lparen + 1;
	for (sz j = lparen + 1; j <= rparen; j++)
	{
		TokenType t = toks.entries[j].type;
		if (j < rparen && (t == LPAREN || t == LBRACE || t == LBRACKET)) { depth++; continue; }
		if (j < rparen && (t == RPAREN || t == RBRACE || t == RBRACKET)) { depth--; continue; }
		if (j < rparen && (depth > 0 || t != COMMA)) continue;

		// One argument: [arg_start, j).
		if (param >= params.count || param >= params.variadic_at) return;
		String name = params.names[param];
		if (arg_start < j && name.len > 0) self.encode_arg(arg_start, j, name, from, to, lo, out, first);
		param++;
		arg_start = j + 1;
	}
}

fn void InlayQuery.encode_arg(&self, sz start, sz end, String name, sz from, sz to, LineOffsets* lo, DString* out, bool* first)
{
	TokenList* toks = &self.stream.tokens;
	Token tok = toks.entries[start];
	if (tok.offset < from || tok.offset > to) return;
	if (tok.type == ELLIPSIS) return;                                                // ...args
	if (start + 1 < end && is_ident(tok.type) && toks.entries[start + 1].type == COLON) return; // name: value
	if (tok.type == DOT && start + 2 < end && toks.entries[start + 2].type == EQ) return;       // .name = value
	if (toks.arg_spells(start, end, name)) return;

	if (!*first) out.append_char(',');
	*first = false;
	out.append(`{"position":`);
	offset_to_position(self.content, lo, tok.offset).encode(out);
	out.append(`,"label":"`);
	json_escape_into(out, name);
	out.append(`:","kind":2,"paddingRight":true}`);
}

// The inlay hints for the calls whose arguments start between byte offsets `from` and
// `to` of `content`, as a JSON array.
fn void encode_inlay_hints(
	String uri,
	String content,
	sz from,
	sz to,
	DString* out,
	TokenStream* cached = null,
	DocumentList* docs = null,
	String stdlib_path = ""
)
{
	TokenStream owned;
	TokenStream* stream = cached;
	if (stream == null)
	{
		owned = token_stream_tokenize(content);
		stream = &owned;
	}
	defer if (cached == null) owned.free();

	InlayQuery q = { .stream = stream, .content = content, .uri = uri, .docs = docs, .stdlib_path = stdlib_path };
	q.memo.tinit();
	q.pending.tinit();
	q.pending_names.tinit();
	TokenList* toks = &stream.tokens;

	// The calls with an argument list in range, and their callees' first candidates.
	List{InlayCall} calls;
	calls.tinit();
	for (sz i = 0; i < toks.size; i++)
	{
		if (toks.entries[i].offset > to) break;
		if (!toks.is_call_site(i) || toks.is_callable_decl_name(i)) continue;
		if (toks.entries[i].type == AT_IDENT && toks.is_attribute_at(i)) continue; // `@operator(+)`
		sz lparen = i + 1;
		if (toks.entries[lparen].type == LBRACE) lparen = toks.match_rbrace(lparen) + 1;
		sz rparen = toks.match_rparen(lparen);
		if (rparen >= toks.size || rparen == lparen + 1) continue;
		if (toks.entries[rparen].offset < from) continue;
		InlayCall call = { i, lparen, rparen, toks.callee_lookup(i, content, uri, docs, stdlib_path) };
		q.request(toks.entries[i], call.lookup.method_types[0], call.lookup.module_filter);
		calls.push(call);
	}
	q.flush();

	// A method its receiver's type doesn't declare: try the alias base and the type it
	// takes the method from. Widened once per receiver type and name.
	HashMap{String, CalleeLookup} widened;
	widened.tinit();
	foreach (&call : calls)
	{
		Token target = toks.entries[call.name_idx];
		if (q.answer(target, call.lookup.method_types[0], call.lookup.module_filter).found) continue;
		String key = lookup_key(target, call.lookup.method_types[0], call.lookup.module_filter);
		if (try w = widened.get(key))
		{
			call.lookup = w;
			continue;
		}
		call.lookup.widen(toks, uri, docs, stdlib_path);
		widened.set(key, call.lookup);
		for (sz ci = 1; ci < call.lookup.count; ci++) q.request(target, call.lookup.method_types[ci], call.lookup.module_filter);
	}
	q.flush();

	LineOffsets lo;
	lo.init(mem);
	defer lo.free();
	lo.build(content);
	bool first = true;
	out.append_char('[');
	foreach (&call : calls) q.encode_call(call, from, to, &lo, out, &first);
	out.append_char(']');
}
