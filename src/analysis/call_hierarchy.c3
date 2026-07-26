module lsp;

import std::core::dstring;
import std::core::mem;
import std::collections::list;
import c3::lexer;

// Call hierarchy: prepareCallHierarchy pins down one callable, then incomingCalls
// ("who calls this") and outgoingCalls ("what does this call") walk one step out.
//
// Resolution is name-based, as everywhere else in this server: a call site is an
// identifier followed by `(`, and it is matched to a declaration by that identifier.
// Method calls therefore resolve by method name without proving the receiver's type,
// so two types with a same-named method share one hierarchy node. Getting that exact
// would mean running receiver-type inference for every call site in the project.

// Cap on callees reported for one function, and on entries in one response.
const sz MAX_CALL_HIERARCHY_ITEMS = 128;

// A callable declaration plus the byte span of its whole declaration, so a call site's
// offset can be attributed to the function that contains it.
struct CallableSpan
{
	String name;        // display name: "Type.method" or "func"
	String bare;        // the identifier a call site spells
	String module_name; // shown as the item's detail
	sz start;           // offset of the fn/macro keyword
	sz end;             // offset just past the body (or past the name if unparsable)
	sz name_offset;
	sz name_len;
}

// Convert a byte span to an LSP range.
fn Range offsets_to_range(LineOffsets* lo, sz start, sz end)
{
	if (end < start) end = start;
	sz start_line = lo.find_line(start);
	sz end_line   = lo.find_line(end > 0 ? end - 1 : 0);
	return {
		.start = { .line = start_line, .character = start - lo.entries[start_line] },
		.end   = { .line = end_line,   .character = end - lo.entries[end_line] },
	};
}

// Collect every fn/macro declaration in the stream, in ascending offset order.
fn void TokenList.collect_callables(&self, List{CallableSpan}* out)
{
	String current_module = "";

	for (sz i = 0; i < self.size; i++)
	{
		TokenType t = self.entries[i].type;
		if (t == MODULE)
		{
			current_module = self.module_path_at(i);
			continue;
		}
		if (t != FUNC && t != MACRO) continue;

		sz lparen = self.find_callable_lparen(i);
		if (lparen <= i) continue;

		Token name_tok = self.entries[lparen - 1];
		if (!is_ident(name_tok.type) && !(t == MACRO && name_tok.type == TYPE_IDENT)) continue;

		// `fn ret Type.method(` — qualify the display name with the receiver type.
		String display = name_tok.text;
		if (lparen >= i + 4 && self.entries[lparen - 2].type == DOT
			&& self.entries[lparen - 3].type == TYPE_IDENT)
		{
			DString qualified = dstring::temp();
			qualified.appendf("%s.%s", self.entries[lparen - 3].text, name_tok.text);
			display = qualified.str_view();
		}

		sz end = self.find_callable_end(lparen);
		if (end == 0) end = name_tok.offset + name_tok.len;

		out.push(
			{
				.name        = display,
				.bare        = name_tok.text,
				.module_name = current_module,
				.start       = self.entries[i].offset,
				.end         = end,
				.name_offset = name_tok.offset,
				.name_len    = name_tok.len,
			}
		);
	}
}

// Emit one CallHierarchyItem. Kind 12 is Function — C3 macros are callables too, and
// the protocol has no better kind for them.
fn void encode_call_hierarchy_item(DString* out, CallableSpan* span, String uri, LineOffsets* lo)
{
	out.append(`{"name":"`);
	json_escape_into(out, span.name);
	out.append(`","kind":12`);
	if (span.module_name.len > 0)
	{
		out.append(`,"detail":"`);
		json_escape_into(out, span.module_name);
		out.append_char('"');
	}
	out.append(`,"uri":"`);
	json_escape_into(out, uri);
	out.append(`","range":`);
	Range range = offsets_to_range(lo, span.start, span.end);
	range.encode(out);
	out.append(`,"selectionRange":`);
	Range sel = offsets_to_range(lo, span.name_offset, span.name_offset + span.name_len);
	sel.encode(out);
	out.append_char('}');
}

// True when the token at `idx` is a call: an identifier followed by `(`, or by a generic
// instantiation and then `(` (`foo{int}(...)`). Declaration names look identical here, so
// callers exclude those separately by offset.
fn bool TokenList.is_call_site(&self, sz idx)
{
	if (!is_ident(self.entries[idx].type)) return false;
	sz next = idx + 1;
	if (next >= self.size) return false;
	if (self.entries[next].type == LBRACE)
	{
		next = self.match_rbrace(next);
		if (next >= self.size) return false;
		next++;
	}
	return next < self.size && self.entries[next].type == LPAREN;
}

// The bare identifier a call site spells, given an item name that may be "Type.method".
fn String call_hierarchy_bare_name(String name)
{
	for (sz i = name.len; i > 0; i--)
	{
		if (name[i - 1] == '.') return name[i..];
	}
	return name;
}

// Token stream and content for `uri`: the open document when there is one, otherwise the
// file on disk. A client expands hierarchy nodes pointing at files the user never opened,
// so neither direction can assume an open buffer. When `*owns` comes back true the caller
// must free both the stream and the content.
fn bool load_stream_for_uri(String uri, DocumentList* docs, TokenStream* owned,
	TokenStream** stream, String* content, bool* owns)
{
	*owns = false;
	if (try doc = docs.find(uri))
	{
		*content = doc.content;
		*stream  = doc.get_tokens();
		return true;
	}

	String path = uri_to_path(uri);
	if (path.len == 0) return false;
	if (try s = file_token_stream(path, owned, content, owns))
	{
		*stream = s;
		return true;
	}
	return false;
}

// --- prepareCallHierarchy ---------------------------------------------------

// Find the callable whose declaration span contains `offset`.
fn bool find_span_at(List{CallableSpan}* spans, sz offset, sz* index)
{
	for (sz i = 0; i < spans.size; i++)
	{
		if (offset >= spans.entries[i].start && offset < spans.entries[i].end)
		{
			*index = i;
			return true;
		}
	}
	return false;
}

// Find a callable declared with this bare name.
fn bool find_span_named(List{CallableSpan}* spans, String bare, sz* index)
{
	for (sz i = 0; i < spans.size; i++)
	{
		if (spans.entries[i].bare == bare)
		{
			*index = i;
			return true;
		}
	}
	return false;
}

// On-disk lookup of a callable declaration by name. Encodes the item during the visit:
// the span's strings point into the visited file's content, which is freed afterwards.
struct PrepareScan (FileVisitor) @private
{
	String bare;
	DString* out;
	bool* found;
}

fn bool PrepareScan.visit(&self, String path, String content, TokenStream* stream) @dynamic
{
	List{CallableSpan} spans;
	spans.init(mem);
	defer spans.free();
	stream.tokens.collect_callables(&spans);

	sz idx;
	if (!find_span_named(&spans, self.bare, &idx)) return false;

	DString uri = dstring::temp();
	append_file_uri(&uri, path);
	encode_call_hierarchy_item(self.out, &spans.entries[idx], uri.str_view(), stream.get_line_offsets());
	*self.found = true;
	return true; // first declaration wins
}

// Encode a textDocument/prepareCallHierarchy response: an array holding the one
// callable the cursor identifies, or an empty string for none.
fn void encode_prepare_call_hierarchy(String uri, String content, sz offset, DocumentList* docs,
	String stdlib_path, DString* out)
{
	TokenStream owned;
	bool owns;
	TokenStream* stream = token_stream_for_doc(uri, content, docs, &owned, &owns);
	defer { if (owns) owned.free(); }

	List{CallableSpan} spans;
	spans.init(mem);
	defer spans.free();
	stream.tokens.collect_callables(&spans);

	LineOffsets* lo = stream.get_line_offsets();

	// 1. Cursor sitting on a declaration's own name in this file.
	for (sz i = 0; i < spans.size; i++)
	{
		if (offset < spans.entries[i].name_offset) continue;
		if (offset > spans.entries[i].name_offset + spans.entries[i].name_len) continue;
		out.append_char('[');
		encode_call_hierarchy_item(out, &spans.entries[i], uri, lo);
		out.append_char(']');
		return;
	}

	// 2. Cursor on an identifier elsewhere — a call site, most likely. Resolve it to the
	// callable it names, searching this file, then open documents, then disk.
	Token cursor_tok;
	sz cursor_idx;
	if (stream.tokens.find_token_at(offset, &cursor_tok, &cursor_idx) && is_ident(cursor_tok.type))
	{
		String bare = cursor_tok.text;

		sz idx;
		if (find_span_named(&spans, bare, &idx))
		{
			out.append_char('[');
			encode_call_hierarchy_item(out, &spans.entries[idx], uri, lo);
			out.append_char(']');
			return;
		}

		for (sz d = 0; d < docs.size; d++)
		{
			if (docs.entries[d].uri == uri) continue;
			TokenStream* other = docs.entries[d].get_tokens();
			List{CallableSpan} other_spans;
			other_spans.init(mem);
			defer other_spans.free();
			other.tokens.collect_callables(&other_spans);
			if (find_span_named(&other_spans, bare, &idx))
			{
				out.append_char('[');
				encode_call_hierarchy_item(out, &other_spans.entries[idx], docs.entries[d].uri,
					other.get_line_offsets());
				out.append_char(']');
				return;
			}
		}

		DString item = dstring::temp();
		bool found = false;
		PrepareScan scan = { bare, &item, &found };
		scan_project_then_stdlib(uri_to_path(uri), stdlib_path, &scan);
		if (found)
		{
			out.appendf("[%s]", item.str_view());
			return;
		}
	}

	// 3. Nothing named at the cursor — fall back to the function the cursor is inside.
	sz enclosing;
	if (find_span_at(&spans, offset, &enclosing))
	{
		out.append_char('[');
		encode_call_hierarchy_item(out, &spans.entries[enclosing], uri, lo);
		out.append_char(']');
	}
}

// --- incomingCalls ---------------------------------------------------------

// Append one incoming-call entry per function in this file that calls `bare`.
//
// Token offsets ascend and declaration spans are non-overlapping and also ascend, so
// every call site inside one function is contiguous in token order: a single pass with
// a monotonically advancing span cursor groups them without rescanning.
fn void collect_incoming_calls_in(String uri, String content, TokenStream* stream, String bare,
	String target_module, DString* out, bool* first, sz* count)
{
	if (*count >= MAX_CALL_HIERARCHY_ITEMS) return;

	// A call in a file that cannot see the callee's module is a call to some other
	// same-named function, not to this one. Same rule as find-references; an unknown
	// module ("") keeps the permissive name-only match.
	if (!file_can_see(&stream.tokens, target_module)) return;

	List{CallableSpan} spans;
	spans.init(mem);
	defer spans.free();
	stream.tokens.collect_callables(&spans);
	if (spans.size == 0) return;

	LineOffsets* lo = stream.get_line_offsets();

	sz span_idx = 0;
	bool open_entry = false;
	DString ranges = dstring::temp();
	bool first_range = true;

	for (sz i = 0; i < stream.tokens.size; i++)
	{
		Token tok = stream.tokens.entries[i];
		if (tok.text != bare) continue;
		if (!stream.tokens.is_call_site(i)) continue;

		// Advance to the span containing this call, flushing the previous one.
		while (span_idx < spans.size && tok.offset >= spans.entries[span_idx].end)
		{
			if (open_entry)
			{
				out.appendf(`,"fromRanges":[%s]}`, ranges.str_view());
				open_entry = false;
			}
			span_idx++;
		}
		if (span_idx >= spans.size) break;

		CallableSpan* span = &spans.entries[span_idx];
		if (tok.offset < span.start) continue;            // between declarations
		if (tok.offset == span.name_offset) continue;     // the declaration itself

		if (!open_entry)
		{
			if (*count >= MAX_CALL_HIERARCHY_ITEMS) break;
			if (!*first) out.append_char(',');
			*first = false;
			out.append(`{"from":`);
			encode_call_hierarchy_item(out, span, uri, lo);
			open_entry = true;
			first_range = true;
			ranges.clear();
			(*count)++;
		}

		if (!first_range) ranges.append_char(',');
		first_range = false;
		Range r = offsets_to_range(lo, tok.offset, tok.offset + tok.len);
		r.encode(&ranges);
	}

	if (open_entry)
	{
		out.appendf(`,"fromRanges":[%s]}`, ranges.str_view());
	}
}

// On-disk incoming-call collection, driven through the shared scan engine.
struct IncomingScan (FileVisitor) @private
{
	String bare;
	String target_module;
	DString* out;
	bool* first;
	sz* count;
	String origin_uri;
	DocumentList* docs;
}

fn bool IncomingScan.visit(&self, String path, String content, TokenStream* stream) @dynamic
{
	if (already_collected(path, self.origin_uri, self.docs)) return false;
	DString uri = dstring::temp();
	append_file_uri(&uri, path);
	collect_incoming_calls_in(uri.str_view(), content, stream, self.bare, self.target_module,
		self.out, self.first, self.count);
	return *self.count >= MAX_CALL_HIERARCHY_ITEMS;
}

// Encode a callHierarchy/incomingCalls response for the item named `item_name` in
// `item_uri`: a JSON array of CallHierarchyIncomingCall, or an empty string for none.
fn void encode_incoming_calls(String item_uri, String item_name, int line, int character,
	DocumentList* docs, String stdlib_path, DString* out)
{
	String bare = call_hierarchy_bare_name(item_name);
	if (bare.len == 0) return;

	// Which module declares the item, so unrelated same-named functions are not reported
	// as callers. Resolved from the item's own file, at its selectionRange.
	String target_module = "";
	{
		TokenStream owned;
		TokenStream* stream = null;
		String content = "";
		bool owns = false;
		if (load_stream_for_uri(item_uri, docs, &owned, &stream, &content, &owns))
		{
			defer
			{
				if (owns)
				{
					owned.free();
					mem::free((char*)content.ptr);
				}
			}
			List{CallableSpan} spans;
			spans.init(mem);
			defer spans.free();
			stream.tokens.collect_callables(&spans);

			sz idx;
			if (find_span_at(&spans, position_to_offset(content, line, character), &idx)
				|| find_span_named(&spans, bare, &idx))
			{
				// module_path_at builds into the temp allocator, not the file buffer, so
				// this outlives the content above.
				target_module = spans.entries[idx].module_name;
			}
		}
	}

	bool first = true;
	sz count = 0;
	out.append_char('[');

	// Open documents first: their unsaved content wins over the copy on disk.
	for (sz d = 0; d < docs.size; d++)
	{
		collect_incoming_calls_in(docs.entries[d].uri, docs.entries[d].content,
			docs.entries[d].get_tokens(), bare, target_module, out, &first, &count);
	}

	// Then the project on disk, then the stdlib. The anchor is the item's own file, so
	// the project containing the callee is the one searched.
	IncomingScan scan = { bare, target_module, out, &first, &count, "", docs };
	scan_project_then_stdlib(uri_to_path(item_uri), stdlib_path, &scan);

	out.append_char(']');

	if (first)
	{
		out.clear();
	}
}

// --- outgoingCalls ---------------------------------------------------------

// One distinct callee of the function being expanded. The `to` item is encoded as soon
// as the declaration is found, because the span's strings point into a file buffer that
// the scan frees when the visit returns.
struct OutgoingCallee
{
	String bare;
	DString ranges;    // call-site ranges inside the caller
	DString item_json; // encoded CallHierarchyItem, empty until resolved
	// How good the current match is, so a later, better-placed declaration can replace
	// it: -1 none yet, 0 a module the caller cannot see, 1 visible, 2 the caller's own
	// module. Without this a call to `out.clear()` can land on any `clear` in the
	// stdlib rather than the DString one the caller imports.
	int rank;
	bool first_range;
}

// Find or append the callee entry for `bare`.
fn OutgoingCallee* find_or_add_callee(List{OutgoingCallee}* callees, String bare)
{
	for (sz i = 0; i < callees.size; i++)
	{
		if (callees.entries[i].bare == bare) return &callees.entries[i];
	}
	if (callees.size >= MAX_CALL_HIERARCHY_ITEMS) return null;
	callees.push({ .bare = bare, .ranges = dstring::temp(), .item_json = dstring::temp(), .rank = -1, .first_range = true });
	return &callees.entries[callees.size - 1];
}

// How well a declaration in `decl_module` fits a call made from `caller_ctx`: 2 for the
// caller's own module, 1 for anything else it can see, 0 otherwise. C3 visibility means a
// call can only reach ranks 1 and 2, so a rank-0 match is a same-named symbol elsewhere
// and is kept only until something visible turns up.
fn int callee_rank(ModuleCtx* caller_ctx, String decl_module)
{
	for (sz i = 0; i < caller_ctx.own_count; i++)
	{
		if (caller_ctx.own[i] == decl_module) return 2;
	}
	return caller_ctx.can_see(decl_module) ? 1 : 0;
}

// Improve the callees' declarations from one file. `need_visible` counts the callees that
// still have no match the caller could actually reach; the scan stops when it hits zero.
fn void resolve_callees_in(String uri, String content, TokenStream* stream,
	List{OutgoingCallee}* callees, ModuleCtx* caller_ctx, sz* need_visible)
{
	List{CallableSpan} spans;
	spans.init(mem);
	defer spans.free();
	stream.tokens.collect_callables(&spans);
	if (spans.size == 0) return;

	LineOffsets* lo = stream.get_line_offsets();

	for (sz c = 0; c < callees.size; c++)
	{
		OutgoingCallee* callee = &callees.entries[c];
		if (callee.rank >= 2) continue; // already the best possible

		sz idx;
		if (!find_span_named(&spans, callee.bare, &idx)) continue;

		int rank = callee_rank(caller_ctx, spans.entries[idx].module_name);
		if (rank <= callee.rank) continue;

		callee.item_json.clear();
		encode_call_hierarchy_item(&callee.item_json, &spans.entries[idx], uri, lo);
		if (callee.rank < 1 && rank >= 1) (*need_visible)--;
		callee.rank = rank;
	}
}

// On-disk callee resolution, driven through the shared scan engine.
struct OutgoingResolveScan (FileVisitor) @private
{
	List{OutgoingCallee}* callees;
	ModuleCtx* caller_ctx;
	sz* need_visible;
}

fn bool OutgoingResolveScan.visit(&self, String path, String content, TokenStream* stream) @dynamic
{
	DString uri = dstring::temp();
	append_file_uri(&uri, path);
	resolve_callees_in(uri.str_view(), content, stream, self.callees, self.caller_ctx, self.need_visible);
	return *self.need_visible == 0; // stop once every callee has a reachable declaration
}

// Encode a callHierarchy/outgoingCalls response for the item at (line, character) of
// `item_uri`: a JSON array of CallHierarchyOutgoingCall, or an empty string for none.
//
// The item's file may not be open — a client expands hierarchy nodes pointing at files
// the user never visited — so it is read from disk when necessary.
fn void encode_outgoing_calls(String item_uri, int line, int character, DocumentList* docs,
	String stdlib_path, DString* out)
{
	String content = "";
	TokenStream owned;
	TokenStream* stream = null;
	bool owns = false;

	if (!load_stream_for_uri(item_uri, docs, &owned, &stream, &content, &owns)) return;
	defer
	{
		if (owns)
		{
			owned.free();
			mem::free((char*)content.ptr);
		}
	}

	List{CallableSpan} spans;
	spans.init(mem);
	defer spans.free();
	stream.tokens.collect_callables(&spans);

	sz offset = position_to_offset(content, line, character);
	sz caller;
	if (!find_span_at(&spans, offset, &caller)) return;

	sz caller_start = spans.entries[caller].start;
	sz caller_end   = spans.entries[caller].end;
	sz caller_name  = spans.entries[caller].name_offset;

	LineOffsets* lo = stream.get_line_offsets();

	List{OutgoingCallee} callees;
	callees.init(mem);
	defer callees.free();

	for (sz i = 0; i < stream.tokens.size; i++)
	{
		Token tok = stream.tokens.entries[i];
		if (tok.offset < caller_start) continue;
		if (tok.offset >= caller_end) break;
		if (tok.offset == caller_name) continue;
		if (!stream.tokens.is_call_site(i)) continue;

		OutgoingCallee* callee = find_or_add_callee(&callees, tok.text);
		if (callee == null) break;

		if (!callee.first_range) callee.ranges.append_char(',');
		callee.first_range = false;
		Range r = offsets_to_range(lo, tok.offset, tok.offset + tok.len);
		r.encode(&callee.ranges);
	}

	if (callees.size == 0) return;

	// Resolve each callee's declaration: this file, then open documents, then one pass
	// over the project and stdlib for whatever is still missing.
	ModuleCtx caller_ctx;
	caller_ctx.build(&stream.tokens);

	sz need_visible = callees.size;
	resolve_callees_in(item_uri, content, stream, &callees, &caller_ctx, &need_visible);

	for (sz d = 0; d < docs.size && need_visible > 0; d++)
	{
		if (docs.entries[d].uri == item_uri) continue;
		resolve_callees_in(docs.entries[d].uri, docs.entries[d].content,
			docs.entries[d].get_tokens(), &callees, &caller_ctx, &need_visible);
	}

	if (need_visible > 0)
	{
		OutgoingResolveScan scan = { &callees, &caller_ctx, &need_visible };
		scan_project_then_stdlib(uri_to_path(item_uri), stdlib_path, &scan);
	}

	bool first = true;
	out.append_char('[');
	for (sz c = 0; c < callees.size; c++)
	{
		// A callee with no declaration anywhere in reach (a builtin, or a name this
		// token-level search cannot place) is left out rather than reported half-built.
		if (callees.entries[c].item_json.len() == 0) continue;
		if (!first) out.append_char(',');
		first = false;
		out.appendf(`{"to":%s,"fromRanges":[%s]}`,
			callees.entries[c].item_json.str_view(), callees.entries[c].ranges.str_view());
	}
	out.append_char(']');

	if (first)
	{
		out.clear();
	}
}
