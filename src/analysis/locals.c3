module lsp;

import c3::lexer;

// Scope resolution for local variables and parameters, shared by go-to-definition,
// rename, document highlight and find-references. A local is visible from its
// declaration to the end of the block holding it, so two sibling blocks may each
// declare their own `abc`. C3 forbids shadowing, which keeps the rule simple: the
// nearest preceding declaration that is not inside an already-closed block is the
// one a use refers to.

// A fn/macro (or lambda) in the token list: its keyword, its parameter list and
// where its body ends.
struct LocalScope
{
	sz kw;
	sz lparen;
	sz rparen;
	sz end; // the body's closing `}`, or the token ending a `=> expr` body
}

// True when `idx` is in the parameter list or the body.
fn bool LocalScope.contains(&self, sz idx) => idx > self.lparen && idx < self.end;

// The span of the fn/macro whose keyword is at `kw`. Fails for a declaration
// without a body (extern, interface method, function pointer type).
fn LocalScope? TokenList.callable_span(&self, sz kw)
{
	sz lparen = self.fn_lparen_after(kw)!;
	sz rparen = self.match_rparen(lparen);
	if (rparen >= self.size) return TOKEN_NOT_FOUND~;
	for (sz j = rparen + 1; j < self.size; j++)
	{
		switch (self.entries[j].type)
		{
			case LBRACE:
				sz rbrace = self.match_rbrace(j);
				if (rbrace >= self.size) return TOKEN_NOT_FOUND~;
				return (LocalScope){ kw, lparen, rparen, rbrace };
			case IMPLIES:
				return (LocalScope){ kw, lparen, rparen, self.expression_end(j + 1) };
			case EOS:
				return TOKEN_NOT_FOUND~;
			default:
				break;
		}
	}
	return TOKEN_NOT_FOUND~;
}

// Index of the token ending the expression starting at `from`: its `;`, or the
// `,`/`)`/`}`/`]` closing whatever the expression sits in (a lambda passed as an
// argument).
fn sz TokenList.expression_end(&self, sz from)
{
	sz depth = 0;
	for (sz j = from; j < self.size; j++)
	{
		switch (self.entries[j].type)
		{
			case LPAREN:
			case LBRACE:
			case LBRACKET:
				depth++;
			case RPAREN:
			case RBRACE:
			case RBRACKET:
				if (depth == 0) return j;
				depth--;
			case EOS:
			case COMMA:
				if (depth == 0) return j;
			default:
				break;
		}
	}
	return self.size;
}

// The innermost fn/macro whose parameter list or body holds `idx`.
fn LocalScope? TokenList.callable_around(&self, sz idx)
{
	LocalScope? found = TOKEN_NOT_FOUND~;
	for (sz i = 0; i < idx && i < self.size; i++)
	{
		TokenType t = self.entries[i].type;
		if (t != FUNC && t != MACRO) continue;
		LocalScope? span = self.callable_span(i);
		if (catch span) continue;
		if (span.contains(idx))
		{
			found = span;
			i = span.lparen; // a lambda inside may hold idx more closely
		}
		else if (span.end > i)
		{
			i = span.end;
		}
	}
	return found;
}

// True when the IDENT at `i` declares a local of `span`: a typed variable or
// parameter, a `try`/`catch` binding, a foreach variable, or a macro parameter
// written without a type.
fn bool TokenList.declares_local_at(&self, sz i, LocalScope span)
{
	if (i == 0 || i + 1 >= self.size || self.entries[i].type != IDENT) return false;
	TokenType prev = self.entries[i - 1].type;
	TokenType next = self.entries[i + 1].type;

	// `try x = ...` / `catch err = ...`. Without the `=` it tests an existing name.
	if ((prev == TRY || prev == CATCH) && next == EQ) return true;

	if (i > span.lparen && i < span.rparen && self.is_parameter_name(i, span)) return true;
	if ((next == COLON || next == COMMA) && self.in_foreach_bindings(i)) return true;

	if (next != EOS && next != EQ && next != COMMA && next != RPAREN && next != AT_IDENT) return false;
	return self.has_type_before(i, span.lparen + 1);
}

// A parameter name at the top level of the list: `int x`, an untyped macro
// parameter `x`, `&self`, or `int... rest`.
fn bool TokenList.is_parameter_name(&self, sz i, LocalScope span)
{
	sz depth = 0;
	for (sz j = span.lparen + 1; j < i; j++)
	{
		switch (self.entries[j].type)
		{
			case LPAREN:
			case LBRACE:
			case LBRACKET:
				depth++;
			case RPAREN:
			case RBRACE:
			case RBRACKET:
				if (depth > 0) depth--;
			default:
				break;
		}
	}
	if (depth > 0) return false; // inside a default value

	TokenType prev = self.entries[i - 1].type;
	TokenType next = self.entries[i + 1].type;
	if (next != COMMA && next != RPAREN && next != EQ && next != EOS) return false;
	if (i - 1 == span.lparen || prev == COMMA || prev == EOS || prev == AMP || prev == ELLIPSIS) return true;
	return self.has_type_before(i, span.lparen + 1);
}

// The bindings of `foreach (i, x : list)`, `foreach (&x : list)` or
// `foreach (int i, Foo x : list)`.
fn bool TokenList.in_foreach_bindings(&self, sz i)
{
	sz p = i;
	while (p > 0)
	{
		TokenType t = self.entries[p - 1].type;
		if (t == LPAREN) break;
		if (t != COMMA && t != AMP && t != IDENT && t != STAR && t != QUESTION && !is_type_token(t)) return false;
		p--;
	}
	if (p < 2) return false;
	TokenType kw = self.entries[p - 2].type;
	return kw == FOREACH || kw == FOREACH_R;
}

// True when a type is written right before the name at `i`, across `*`/`?`
// suffixes, `[N]`/`[]`/`[<N>]` suffixes and a generic `{...}` block. The type may
// start no earlier than index `lowest`.
fn bool TokenList.has_type_before(&self, sz i, sz lowest)
{
	sz p = i; // the type ends at p - 1
	while (p > lowest)
	{
		TokenType t = self.entries[p - 1].type;
		if (t == STAR || t == QUESTION)
		{
			p--;
			continue;
		}
		if (t == RBRACKET)
		{
			sz open = self.match_lbracket_back(p - 1);
			if (open >= self.size || open < lowest) return false;
			p = open;
			continue;
		}
		if (t == RVEC)
		{
			// A vector suffix: `int[<4>] v`.
			sz open = p - 1;
			while (open > lowest && self.entries[open].type != LVEC) open--;
			if (self.entries[open].type != LVEC) return false;
			p = open;
			continue;
		}
		if (t == RBRACE)
		{
			// Only a generic argument block follows a type name: `List{int} x`.
			sz open = self.match_lbrace_back(p - 1);
			if (open >= self.size || open == 0 || open - 1 < lowest || self.entries[open - 1].type != TYPE_IDENT) return false;
			p = open;
			continue;
		}
		break;
	}
	return p > lowest && is_type_token(self.entries[p - 1].type);
}

// The local declaration the identifier at `idx` refers to: `idx` itself when it is
// one, else the nearest declaration of the same name before it in `span` that is
// still in scope (not inside a block that has already closed).
fn sz? TokenList.local_declaration_of(&self, sz idx, LocalScope span)
{
	if (idx >= self.size || self.entries[idx].type != IDENT) return TOKEN_NOT_FOUND~;
	if (self.declares_local_at(idx, span)) return idx;

	String name = self.entries[idx].text;
	sz depth = 0;
	for (sz i = idx; i-- > span.lparen + 1;)
	{
		switch (self.entries[i].type)
		{
			case RBRACE:
				depth++;
			case LBRACE:
				if (depth > 0) depth--;
			case IDENT:
				if (depth == 0 && self.entries[i].text == name && self.declares_local_at(i, span)
					&& !self.in_nested_callable(i, span)) return i;
			default:
				break;
		}
	}
	return TOKEN_NOT_FOUND~;
}

// The local declaration the plain identifier at `idx` refers to, together with
// the fn/macro holding it. Member accesses (`.x`) and qualified names (`m::x`)
// are never locals.
fn sz? TokenList.local_target(&self, sz idx, LocalScope* span)
{
	if (idx == 0 || idx >= self.size || self.entries[idx].type != IDENT) return TOKEN_NOT_FOUND~;
	TokenType prev = self.entries[idx - 1].type;
	if (prev == DOT || prev == SCOPE) return TOKEN_NOT_FOUND~;
	*span = self.callable_around(idx)!;
	return self.local_declaration_of(idx, *span);
}

// True when the token at `j` is a use (or the declaration) of the local at `decl`.
fn bool TokenList.refers_to_local(&self, sz j, sz decl, LocalScope span)
{
	Token tok = self.entries[j];
	if (tok.type != IDENT || tok.text != self.entries[decl].text) return false;
	TokenType prev = self.entries[j - 1].type;
	if (prev == DOT || prev == SCOPE) return false;
	// C3 lambdas do not capture: a name inside one is never the outer local.
	if (self.in_nested_callable(j, span)) return false;
	if (try found = self.local_declaration_of(j, span)) return found == decl;
	return false;
}

// True when `i` is inside a lambda nested in `span` (its parameters or body).
fn bool TokenList.in_nested_callable(&self, sz i, LocalScope span)
{
	for (sz k = span.rparen + 1; k < i; k++)
	{
		TokenType t = self.entries[k].type;
		if (t != FUNC && t != MACRO) continue;
		LocalScope? inner = self.callable_span(k);
		if (catch inner) continue;
		if (inner.contains(i)) return true;
		if (inner.end > k) k = inner.end;
	}
	return false;
}

// Scope-aware local-variable lookup for go-to-definition: the declaration the
// identifier at target_idx refers to, if it is a local or parameter of the
// enclosing fn/macro. Returns empty when target_idx carries no cursor
// (find_declaration_in passes self.size) or sits outside any fn/macro.
fn sz? TokenList.find_local_declaration(&self, String name, sz target_idx)
{
	if (target_idx == 0 || target_idx >= self.size) return TOKEN_NOT_FOUND~;
	if (self.entries[target_idx].text != name) return TOKEN_NOT_FOUND~;
	LocalScope span;
	return self.local_target(target_idx, &span);
}

// Index of a module-level declaration of `name`: a fn/macro, a global variable or
// an alias. Locals, parameters, struct members and methods never match.
fn sz? TokenList.find_global_declaration(&self, String name)
{
	sz depth = 0;
	for (sz i = 0; i < self.size; i++)
	{
		Token tok = self.entries[i];
		switch (tok.type)
		{
			case LBRACE:
				depth++;
			case RBRACE:
				if (depth > 0) depth--;
			case FUNC:
			case MACRO:
				if (depth > 0) break; // a lambda
				if (try j = self.fn_lparen_after(i))
				{
					if (j >= 2 && is_ident(self.entries[j - 1].type) && self.entries[j - 1].text == name
						&& self.entries[j - 2].type != DOT) return j - 1;
				}
			case ALIAS:
				if (depth == 0 && i + 1 < self.size && self.entries[i + 1].text == name) return i + 1;
			case IDENT:
				if (depth > 0 || tok.text != name || i == 0 || i + 1 >= self.size) break;
				TokenType next = self.entries[i + 1].type;
				if (next != EQ && next != EOS && next != AT_IDENT) break;
				if (self.has_type_before(i, 0)) return i;
			default:
				break;
		}
	}
	return TOKEN_NOT_FOUND~;
}
