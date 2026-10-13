module lsp;

import std::core::dstring;
import std::core::mem;
import std::collections::list;
import c3::lexer;

// Cursor-based rewrites offered in the code-action menu next to the quick fixes:
// filling a switch with the enum cases it misses, filling an initializer with the
// struct fields it leaves out, generating a `<* @param *>` contract, and toggling a
// function between a `=> expr` body and a block. Each one checks the syntax around
// the cursor first, and runs type inference or a cross-file scan only once that
// matches — clients ask for code actions on every cursor move.

const String REWRITE = "refactor.rewrite";

// Everything a rewrite needs to know about the request.
struct RefactorCtx
{
	TokenStream* stream;
	String uri;
	DocumentList* docs;
	String stdlib_path;
	sz cursor; // byte offset
}

// ---------------------------------------------------------------------------
// Fill switch
// ---------------------------------------------------------------------------

// `switch (color) { case RED: ... }` → add `case GREEN: break;` for every value of
// the enum that has no case yet. c3c rejects an enum switch that misses a value
// unless it has a `default`.
fn void RefactorCtx.add_fill_switch(&self, CodeActionList* out)
{
	TokenList* t = &self.stream.tokens;
	if (t.size == 0) return;
	sz cur = self.cursor_token();

	// The innermost switch whose header or body holds the cursor.
	sz sw = t.size;
	sz rparen;
	sz body;
	sz close;
	for (sz i = cur + 1; i-- > 0;)
	{
		if (t.entries[i].type != SWITCH || i + 2 >= t.size || t.entries[i + 1].type != LPAREN) continue;
		sz rp = t.match_rparen(i + 1);
		if (rp >= t.size || rp == i + 2) continue;
		sz lb = rp + 1;
		while (lb < t.size && t.entries[lb].type != LBRACE && t.entries[lb].type != EOS) lb++;
		if (lb >= t.size || t.entries[lb].type != LBRACE) continue;
		sz rb = t.match_rbrace(lb);
		if (rb >= t.size || cur > rb) continue;
		sw = i;
		rparen = rp;
		body = lb;
		close = rb;
		break;
	}
	if (sw == t.size) return;

	TypeInfo type = t.expr_type(rparen - 1, self.uri, self.docs, self.stdlib_path);
	if (!type.known() || type.is_array || type.is_slice || type.is_pointer) return;
	TypeInfo canon = t.canonical_type(type.name, self.uri, self.docs, self.stdlib_path);
	if (canon.is_array || canon.is_slice || canon.is_pointer) return;
	if (!canon.known()) canon = type;

	String[] members = self.enum_members(canon);
	if (members.len == 0) return;

	// The values already handled: `case RED:`, `case Color.RED:`, `case RED..BLUE:`.
	List{String} covered;
	covered.tinit();
	sz first_case = t.size;
	sz default_at = t.size;
	sz depth = 0;
	for (sz j = body + 1; j < close; j++)
	{
		TokenType tt = t.entries[j].type;
		if (tt == LBRACE) depth++;
		if (tt == RBRACE && depth > 0) depth--;
		if (depth > 0) continue;
		if (tt == DEFAULT && default_at == t.size) default_at = j;
		if (tt != CASE) continue;
		if (first_case == t.size) first_case = j;
		for (sz k = j + 1; k < close && t.entries[k].type != COLON; k++)
		{
			Token lt = t.entries[k];
			if (lt.type == CONST_IDENT)
			{
				covered.push(lt.text);
			}
			else if (lt.type == DOTDOT && k > j + 1 && k + 1 < close)
			{
				cover_range(members, t.entries[k - 1].text, t.entries[k + 1].text, &covered);
			}
		}
	}

	List{String} missing;
	missing.tinit();
	foreach (m : members)
	{
		if (!list_has(&covered, m)) missing.push(m);
	}
	if (missing.size == 0) return;

	String unit = self.indent_unit();
	String case_ind = first_case < t.size && self.starts_line(first_case)
		? self.line_indent(t.entries[first_case].offset)
		: string::tformat("%s%s", self.line_indent(t.entries[sw].offset), unit);
	DString text = dstring::temp();
	foreach (m : missing)
	{
		text.appendf("%scase %s:\n%s%sbreak;\n", case_ind, m, case_ind, unit);
	}

	// Before `default:` when there is one, else before the closing brace.
	sz anchor = default_at < t.size ? default_at : close;
	Position at;
	String new_text;
	if (self.starts_line(anchor))
	{
		at = self.position(self.line_start(t.entries[anchor].offset));
		new_text = text.str_view();
	}
	else
	{
		// A one-line switch: break the line before the anchor.
		at = self.position(t.entries[anchor].offset);
		new_text = string::tformat("\n%s%s", text.str_view(), self.line_indent(t.entries[sw].offset));
	}

	CodeAction action = {
		.title = missing.size == 1 ? string::tformat("Add missing case '%s'", missing[0]) : string::tformat("Add %d missing cases", missing.size),
		.kind = REWRITE,
		.edit_count = 1,
	};
	action.edits[0] = { .range = { at, at }, .new_text = new_text };
	out.add_unique(action);
}

// The values of enum `type`, in declaration order. Visible modules are searched first,
// so another module's same-named enum does not merge in.
fn String[] RefactorCtx.enum_members(&self, TypeInfo type)
{
	CompletionSink* sink = mem::tnew(CompletionSink);
	ModuleCtx ctx;
	ctx.build(&self.stream.tokens);
	ModuleCtx*[2] passes = { &ctx, null };
	foreach (pass_ctx : passes)
	{
		sink.init("");
		collect_enum_members(type, self.uri, self.stream.content, self.docs, self.stdlib_path, sink, pass_ctx);
		if (sink.count > 0) break;
	}
	String[] names = mem::talloc_array(String, sink.count);
	foreach (i, &item : sink.items[:sink.count]) names[i] = item.label;
	return names;
}

// Mark every member from `first` to `last` (declaration order) as covered.
fn void cover_range(String[] members, String first, String last, List{String}* covered) @private
{
	bool inside = false;
	foreach (m : members)
	{
		if (m == first) inside = true;
		if (inside) covered.push(m);
		if (m == last) return;
	}
}

fn bool list_has(List{String}* list, String s) @private
{
	foreach (e : *list)
	{
		if (e == s) return true;
	}
	return false;
}

// ---------------------------------------------------------------------------
// Fill struct fields
// ---------------------------------------------------------------------------

// `Foo f = { .a = 1 }` → `{ .a = 1, .b = 0, .name = "" }`: add every field the
// designated initializer leaves out, set to the value it would get anyway.
fn void RefactorCtx.add_fill_fields(&self, CodeActionList* out)
{
	TokenList* t = &self.stream.tokens;
	if (t.size == 0) return;
	sz cur = self.cursor_token();
	sz lb = t.entries[cur].type == RBRACE ? t.match_lbrace_back(cur) : t.enclosing_lbrace_back(cur);
	if (lb >= t.size || !t.is_initializer_brace(lb)) return;
	sz rb = t.match_rbrace(lb);
	if (rb >= t.size) return;

	// Designated entries only: `{ 1, 2 }` sets fields by position.
	sz last = lb;      // the last token inside the braces
	sz last_code = lb; // ... that is not a comment
	sz depth = 0;
	bool entry_start = true;
	for (sz j = lb + 1; j < rb; j++)
	{
		TokenType tt = t.entries[j].type;
		if (tt == LINE_COMMENT || tt == BLOCK_COMMENT)
		{
			last = j;
			continue;
		}
		if (depth == 0 && entry_start && tt != DOT) return;
		entry_start = false;
		switch (tt)
		{
			case LBRACE:
			case LPAREN:
			case LBRACKET:
				depth++;
			case RBRACE:
			case RPAREN:
			case RBRACKET:
				if (depth > 0) depth--;
			case COMMA:
				if (depth == 0) entry_start = true;
			default:
				break;
		}
		last = j;
		last_code = j;
	}
	if (last_code == lb && last != lb) return; // only a comment inside: keep it as written
	// The written type of a declaration `Foo f = {` first: the general lookup can pick
	// up a same-named variable of another function there.
	TypeInfo type;
	bool declared = lb >= 2 && t.entries[lb - 1].type == EQ && (lb < 3 || t.entries[lb - 3].type != DOT)
		&& t.read_field_decl(lb - 2, &type);
	if (!declared) type = t.initializer_type_at(lb, self.uri, self.docs, self.stdlib_path, 0);
	if (!type.known() || type.is_array || type.is_slice || type.is_pointer) return;
	TypeInfo canon = t.canonical_type(type.name, self.uri, self.docs, self.stdlib_path);
	if (canon.is_array || canon.is_slice || canon.is_pointer) return;
	if (!canon.known()) canon = type;

	// Missing fields with their filler values, in declaration order.
	CompletionSink* sink = mem::tnew(CompletionSink);
	ModuleCtx ctx;
	ctx.build(t);
	ModuleCtx*[2] passes = { &ctx, null };
	foreach (pass_ctx : passes)
	{
		sink.init("");
		t.seed_assigned_fields(lb, t.size, sink);
		collect_members_all(&TokenList.collect_fill_fields_into, canon, self.uri, self.stream.content, self.docs, self.stdlib_path, sink, pass_ctx);
		if (sink.count > 0) break;
	}
	if (sink.count == 0) return;

	String unit = self.indent_unit();
	String ind = self.line_indent(t.entries[lb].offset);
	CodeAction action = {
		.title = sink.count == 1
			? string::tformat("Fill missing field '%s' of '%s'", sink.items[0].label, type.name)
			: string::tformat("Fill %d missing fields of '%s'", sink.count, type.name),
		.kind = REWRITE,
	};
	DString text = dstring::temp();
	if (last == lb)
	{
		// `{}` → one field per line.
		foreach (&item : sink.items[:sink.count]) text.appendf("\n%s%s.%s = %s,", ind, unit, item.label, item.detail);
		text.appendf("\n%s", ind);
		action.edits[0] = { .range = { self.position(t.end_of(lb)), self.position(t.entries[rb].offset) }, .new_text = text.str_view() };
		action.edit_count = 1;
		out.add_unique(action);
		return;
	}

	bool comma = t.entries[last_code].type == COMMA;
	if (self.position(t.entries[lb].offset).line == self.position(t.entries[rb].offset).line)
	{
		// Single line: append inline.
		foreach (i, &item : sink.items[:sink.count])
		{
			text.appendf("%s .%s = %s", i == 0 && comma ? "" : ",", item.label, item.detail);
		}
		Position at = self.position(t.end_of(last_code));
		action.edits[0] = { .range = { at, at }, .new_text = text.str_view() };
		action.edit_count = 1;
		out.add_unique(action);
		return;
	}

	// Multi-line: one field per line, indented like the first entry, after the last
	// entry and any comment trailing it.
	String entry_ind = self.starts_line(lb + 1) ? self.line_indent(t.entries[lb + 1].offset) : string::tformat("%s%s", ind, unit);
	foreach (&item : sink.items[:sink.count]) text.appendf("\n%s.%s = %s,", entry_ind, item.label, item.detail);
	if (!comma)
	{
		Position at = self.position(t.end_of(last_code));
		action.edits[action.edit_count++] = { .range = { at, at }, .new_text = "," };
	}
	Position at = self.position(t.end_of(last));
	action.edits[action.edit_count++] = { .range = { at, at }, .new_text = text.str_view() };
	out.add_unique(action);
}

// Collect the fields of `type` declared in this token list, each with the value it
// is filled with as the detail. Members of a union are left out: only one of them
// may be set.
fn void TokenList.collect_fill_fields_into(&self, TypeInfo type, CompletionSink* sink, ModuleCtx* ctx)
{
	self.@each_struct_member(type.name, ctx; sz j)
	{
		if (!self.member_in_union(j))
		{
			// `int a, b;`: only the first name carries the type.
			sz first = j;
			while (first >= 2 && self.entries[first - 1].type == COMMA && self.entries[first - 2].type == IDENT) first -= 2;
			TypeInfo ft;
			sink.add(self.entries[j].text, 5, self.read_field_decl(first, &ft) ? filler_value(ft) : "{}");
		}
	};
}

// True when the member named at `j` sits in a union, the type's own body included.
fn bool TokenList.member_in_union(&self, sz j)
{
	sz depth = 0;
	for (sz k = j; k-- > 0;)
	{
		TokenType tt = self.entries[k].type;
		if (tt == RBRACE)
		{
			depth++;
			continue;
		}
		if (tt != LBRACE) continue;
		if (depth > 0)
		{
			depth--;
			continue;
		}
		// An enclosing brace: find the keyword opening it, past attributes and a name.
		for (sz b = k; b-- > 0 && b + 8 > k;)
		{
			TokenType bt = self.entries[b].type;
			if (bt == UNION) return true;
			if (bt == STRUCT || bt == BITSTRUCT)
			{
				// A named struct is the type itself; an anonymous one is inlined.
				if (self.entries[b + 1].type == TYPE_IDENT) return false;
				break;
			}
			if (bt == EOS || bt == LBRACE || bt == RBRACE) break;
		}
	}
	return false;
}

// The value a field of type `t` holds when an initializer leaves it out.
fn String filler_value(TypeInfo t) @private
{
	if (t.is_pointer) return "null";
	if (t.is_array || t.is_slice) return "{}";
	switch (t.name)
	{
		case "bool":
			return "false";
		case "String":
		case "ZString":
			return `""`;
		case "any":
			return "null";
		case "char":
		case "ichar":
		case "short":
		case "ushort":
		case "int":
		case "uint":
		case "long":
		case "ulong":
		case "int128":
		case "uint128":
		case "iptr":
		case "uptr":
		case "isz":
		case "usz":
		case "sz":
		case "float":
		case "double":
		case "float16":
		case "bfloat16":
		case "float128":
			return "0";
		default:
			return "{}"; // structs, enums, typedefs, typeid
	}
}

// True when the `{` at `lb` opens an initializer rather than a block: it follows
// `=`, `return`, `,`, `(`, a `(Type)` cast or another initializer's `{`.
fn bool TokenList.is_initializer_brace(&self, sz lb)
{
	if (lb == 0) return false;
	switch (self.entries[lb - 1].type)
	{
		case EQ:
		case RETURN:
		case COMMA:
		case LPAREN:
			return true;
		case LBRACE:
			return self.is_initializer_brace(lb - 1);
		case RPAREN:
			sz? lp = self.match_paren_backward(lb - 1);
			if (catch lp) return false;
			sz first = lp + 1;
			while (first + 1 < lb && self.entries[first].type == IDENT && self.entries[first + 1].type == SCOPE) first += 2;
			TypeInfo cast;
			sz after;
			return self.read_type_at(first, &cast, &after) && after == lb - 1;
		default:
			return false;
	}
}

// ---------------------------------------------------------------------------
// Generate contract
// ---------------------------------------------------------------------------

// On a fn/macro header without a contract: insert `<* @param ... @return *>` above it.
fn void RefactorCtx.add_contract(&self, CodeActionList* out)
{
	TokenList* t = &self.stream.tokens;
	sz? kw = self.header_keyword();
	if (catch kw) return;
	sz start = self.declaration_start(kw);
	if (start >= t.size) return;
	if (start > 0 && t.entries[start - 1].type == CONTRACT) return;

	sz? lp = t.fn_lparen_after(kw);
	if (catch lp) return;
	sz rp = t.match_rparen(lp);
	if (rp >= t.size) return;

	List{String} names;
	names.tinit();
	sz depth = 0;
	sz name = t.size;
	bool in_default = false;
	for (sz j = lp + 1; j <= rp; j++)
	{
		TokenType tt = t.entries[j].type;
		if (depth == 0 && (j == rp || tt == COMMA || tt == EOS))
		{
			if (name < t.size && t.entries[name].text != "self") names.push(t.entries[name].text);
			name = t.size;
			in_default = false;
			if (tt == EOS) break; // the trailing `@body` parameters
			continue;
		}
		switch (tt)
		{
			case LPAREN:
			case LBRACE:
			case LBRACKET:
				depth++;
			case RPAREN:
			case RBRACE:
			case RBRACKET:
				if (depth > 0) depth--;
			case EQ:
				if (depth == 0) in_default = true;
			case IDENT:
			case HASH_IDENT:
			case CT_IDENT:
			case CT_TYPE_IDENT:
				if (depth == 0 && !in_default) name = j;
			default:
				break;
		}
	}

	bool has_return = t.returns_value(kw, lp);
	if (names.size == 0 && !has_return) return;

	String ind = self.line_indent(t.entries[start].offset);
	DString text = dstring::temp();
	text.appendf("%s<*\n", ind);
	foreach (n : names) text.appendf("%s @param %s\n", ind, n);
	if (has_return) text.appendf("%s @return\n", ind);
	text.appendf("%s*>\n", ind);

	Position at = self.position(self.line_start(t.entries[start].offset));
	CodeAction action = { .title = "Generate doc contract", .kind = REWRITE, .edit_count = 1 };
	action.edits[0] = { .range = { at, at }, .new_text = text.str_view() };
	out.add_unique(action);
}

// True when the fn/macro at `kw` (parameter list at `lp`) returns a value: it writes
// a return type other than plain `void`. A macro may write none at all.
fn bool TokenList.returns_value(&self, sz kw, sz lp)
{
	// The name sits right before the `(`, after a `Type.` receiver for a method.
	sz name = lp - 1;
	if (self.entries[name].type == RBRACE)
	{
		// generic parameters
		sz open = self.match_lbrace_back(name);
		if (open >= self.size || open == 0) return false;
		name = open - 1;
	}
	if (name >= 2 && self.entries[name - 1].type == DOT) name -= 2;
	if (name <= kw + 1) return false;
	return self.entries[kw + 1].type != VOID || self.entries[kw + 2].type == QUESTION;
}

// ---------------------------------------------------------------------------
// Toggle body
// ---------------------------------------------------------------------------

// `fn int f() => x * 2;` ↔ `fn int f() { return x * 2; }`
fn void RefactorCtx.add_toggle_body(&self, CodeActionList* out)
{
	TokenList* t = &self.stream.tokens;
	if (t.size == 0) return;
	sz kw = self.header_keyword() ?? t.size;
	if (kw >= t.size)
	{
		LocalScope? around = t.callable_around(self.cursor_token());
		if (catch around) return;
		kw = around.kw;
	}
	if (self.declaration_start(kw) >= t.size) return;
	LocalScope? span = t.callable_span(kw);
	if (catch span) return;

	sz open = span.rparen + 1;
	while (open < span.end && t.entries[open].type != LBRACE && t.entries[open].type != IMPLIES) open++;
	if (open >= span.end) return;
	for (sz j = span.rparen + 1; j <= span.end; j++)
	{
		if (t.entries[j].type == LINE_COMMENT || t.entries[j].type == BLOCK_COMMENT) return; // would be lost
	}
	// Anything but a plain `void` function hands its expression back.
	bool returns = t.entries[kw + 1].type != VOID || t.entries[kw + 2].type == QUESTION;

	CodeAction action = { .kind = REWRITE, .edit_count = 1 };
	if (t.entries[open].type == IMPLIES)
	{
		// `=> expr;` → a block.
		if (t.entries[span.end].type != EOS || span.end <= open + 1) return;
		String expr = self.slice(open + 1, span.end - 1);
		String ind = self.line_indent(t.entries[kw].offset);
		action.title = "Convert to block body";
		action.edits[0] = {
			.range = { self.position(t.end_of(open - 1)), self.position(t.end_of(span.end)) },
			.new_text = string::tformat("\n%s{\n%s%s%s%s;\n%s}", ind, ind, self.indent_unit(), returns ? "return " : "", expr, ind),
		};
		out.add_unique(action);
		return;
	}

	// `{ return expr; }` → `=> expr;`: a single statement only.
	sz first = open + 1;
	sz last = span.end - 1; // the statement's `;`
	if (last <= first || t.entries[last].type != EOS) return;
	sz depth = 0;
	for (sz j = first; j < last; j++)
	{
		switch (t.entries[j].type)
		{
			case LPAREN:
			case LBRACE:
			case LBRACKET:
				depth++;
			case RPAREN:
			case RBRACE:
			case RBRACKET:
				if (depth > 0) depth--;
			case EOS:
				if (depth == 0) return;
			default:
				break;
		}
	}
	if (t.entries[first].type == RETURN)
	{
		first++;
		if (first >= last) return; // `return;`
	}
	else
	{
		// A void function's lone call or assignment.
		if (returns) return;
		TokenType lead = t.entries[first].type;
		if (lead != IDENT && lead != AT_IDENT && lead != HASH_IDENT && lead != CT_IDENT) return;
	}
	action.title = "Convert to expression body (=>)";
	action.edits[0] = {
		.range = { self.position(t.end_of(open - 1)), self.position(t.end_of(span.end)) },
		.new_text = string::tformat(" => %s;", self.slice(first, last - 1)),
	};
	out.add_unique(action);
}

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

// The fn/macro keyword of the declaration header holding the cursor: between the
// keyword and its body, with no `{`, `}` or `;` in between.
fn sz? RefactorCtx.header_keyword(&self)
{
	TokenList* t = &self.stream.tokens;
	if (t.size == 0) return TOKEN_NOT_FOUND~;
	for (sz i = self.cursor_token() + 1; i-- > 0;)
	{
		switch (t.entries[i].type)
		{
			case FUNC:
			case MACRO:
				return i;
			case LBRACE:
			case RBRACE:
			case EOS:
			case IMPLIES:
			case CONTRACT:
				return TOKEN_NOT_FOUND~;
			default:
				break;
		}
	}
	return TOKEN_NOT_FOUND~;
}

// The first token of the top-level declaration whose fn/macro keyword is at `kw`
// (an `extern` in front of it), or self.size for a lambda or a function type.
fn sz RefactorCtx.declaration_start(&self, sz kw)
{
	TokenList* t = &self.stream.tokens;
	sz start = kw;
	if (start > 0 && t.entries[start - 1].type == EXTERN) start--;
	sz p = start;
	while (p > 0 && (t.entries[p - 1].type == LINE_COMMENT || t.entries[p - 1].type == BLOCK_COMMENT)) p--;
	if (p > 0)
	{
		// A function type or lambda sits in an expression: `alias F = fn void();`.
		switch (t.entries[p - 1].type)
		{
			case EQ:
			case LPAREN:
			case LBRACKET:
			case COMMA:
			case RETURN:
			case IMPLIES:
			case QUESTION:
			case ELVIS:
				return t.size;
			default:
				break;
		}
	}

	// Not nested in anything but an interface.
	sz depth = 0;
	for (sz k = start; k-- > 0;)
	{
		TokenType tt = t.entries[k].type;
		if (tt == RBRACE) depth++;
		if (tt != LBRACE) continue;
		if (depth > 0)
		{
			depth--;
			continue;
		}
		for (sz b = k; b-- > 0 && b + 8 > k;)
		{
			if (t.entries[b].type == INTERFACE) return start;
			if (t.entries[b].type == EOS || t.entries[b].type == RBRACE || t.entries[b].type == LBRACE) break;
		}
		return t.size;
	}
	return start;
}

// The last token starting at or before the cursor.
fn sz RefactorCtx.cursor_token(&self)
{
	TokenList* t = &self.stream.tokens;
	sz found = 0;
	for (sz i = 0; i < t.size && t.entries[i].offset <= self.cursor; i++) found = i;
	return found;
}

fn Position RefactorCtx.position(&self, sz offset)
{
	LineOffsets* lo = self.stream.get_line_offsets();
	sz line = lo.find_line(offset);
	return { line, offset - lo.entries[line] };
}

fn sz RefactorCtx.line_start(&self, sz offset)
{
	LineOffsets* lo = self.stream.get_line_offsets();
	return lo.entries[lo.find_line(offset)];
}

// The leading whitespace of the line holding `offset`.
fn String RefactorCtx.line_indent(&self, sz offset)
{
	String content = self.stream.content;
	sz start = self.line_start(offset);
	sz end = start;
	while (end < content.len && (content[end] == ' ' || content[end] == '\t')) end++;
	return content[start:end - start];
}

// True when only whitespace precedes token `idx` on its line.
fn bool RefactorCtx.starts_line(&self, sz idx)
{
	sz offset = self.stream.tokens.entries[idx].offset;
	return self.line_start(offset) + self.line_indent(offset).len == offset;
}

// One level of indentation as the file writes it: a tab, or the narrowest run of
// two or more spaces starting a line. Tabs when nothing is indented yet.
fn String RefactorCtx.indent_unit(&self)
{
	String content = self.stream.content;
	sz best = 0;
	sz line = 0;
	while (line < content.len)
	{
		sz spaces = 0;
		while (line + spaces < content.len && content[line + spaces] == ' ') spaces++;
		if (spaces == 0 && line < content.len && content[line] == '\t') return "\t";
		if (spaces >= 2 && (best == 0 || spaces < best)) best = spaces;
		sz? nl = content[line..].index_of_char('\n');
		if (catch nl) break;
		line += nl + 1;
	}
	if (best == 0) return "\t";
	return "        "[:best > 8 ? 8 : best];
}

// The source text from the start of token `from` to the end of token `to`.
fn String RefactorCtx.slice(&self, sz from, sz to)
{
	TokenList* t = &self.stream.tokens;
	sz start = t.entries[from].offset;
	return self.stream.content[start:t.end_of(to) - start];
}

fn sz TokenList.end_of(&self, sz i) => self.entries[i].offset + self.entries[i].len;
