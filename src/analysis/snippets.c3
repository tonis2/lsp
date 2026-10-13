module lsp;

import c3::lexer;

// Keyword templates offered as snippet completions: typing `for` offers the plain
// keyword and, next to it, a `for` item that expands into a whole loop with tab stops.
// Templates are offered only where their construct can start, so `x = fo` gets none.

enum SnippetPlace
{
	STATEMENT,    // inside a fn/macro body, where a statement may start
	TOP_LEVEL,    // at module level, where a declaration may start
	COMPILE_TIME, // either of the above, once `$` has been typed
}

struct Snippet
{
	String label;
	String detail;
	String body; // LSP snippet syntax: $1 / ${1:default} tab stops, $0 the final cursor
	SnippetPlace place;
}

// Brace style follows the stdlib: the opening brace on its own line.
const Snippet[*] SNIPPETS = {
	{ "for", "for (int i = 0; i < len; i++)", "for (${1:int i = 0}; ${2:i < len}; ${3:i++})\n{\n\t$0\n}", STATEMENT },
	{ "foreach", "foreach (x : list)", "foreach (${1:x} : ${2:list})\n{\n\t$0\n}", STATEMENT },
	{ "foreach_r", "foreach_r (x : list)", "foreach_r (${1:x} : ${2:list})\n{\n\t$0\n}", STATEMENT },
	{ "while", "while (cond)", "while (${1:cond})\n{\n\t$0\n}", STATEMENT },
	{ "do", "do { } while (cond);", "do\n{\n\t$0\n}\nwhile (${1:cond});", STATEMENT },
	{ "if", "if (cond)", "if (${1:cond})\n{\n\t$0\n}", STATEMENT },
	{ "else", "else { }", "else\n{\n\t$0\n}", STATEMENT },
	{ "switch", "switch (value)", "switch (${1:value})\n{\n\tcase ${2:A}:\n\t\t$0\n}", STATEMENT },
	{ "iftry", "if (try v = call())", "if (try ${1:v} = ${2:call()})\n{\n\t$0\n}", STATEMENT },
	{ "ifcatch", "if (catch err = call())", "if (catch ${1:err} = ${2:call()})\n{\n\t$0\n}", STATEMENT },
	{ "defer", "defer { }", "defer\n{\n\t$0\n}", STATEMENT },

	{ "fn", "fn void name()", "fn ${1:void} ${2:name}($3)\n{\n\t$0\n}", TOP_LEVEL },
	{ "main", "fn void main()", "fn void main()\n{\n\t$0\n}", TOP_LEVEL },
	{ "macro", "macro name()", "macro ${1:name}($2)\n{\n\t$0\n}", TOP_LEVEL },
	{ "struct", "struct Name { }", "struct ${1:Name}\n{\n\t$0\n}", TOP_LEVEL },
	{ "enum", "enum Name { }", "enum ${1:Name}\n{\n\t${2:VALUE},$0\n}", TOP_LEVEL },
	{ "faultdef", "faultdef NAME;", "faultdef ${1:NAME};", TOP_LEVEL },
	{ "module", "module name;", "module ${1:name};", TOP_LEVEL },

	{ "$if", "$if cond: … $endif", "\\$if ${1:cond}:\n\t$0\n\\$endif", COMPILE_TIME },
	{ "$foreach", "$foreach $x : $list: … $endforeach", "\\$foreach ${1:\\$x} : ${2:\\$list}:\n\t$0\n\\$endforeach", COMPILE_TIME },
	{ "$for", "$for var $i = 0; $i < n; $i++: … $endfor", "\\$for var ${1:\\$i} = 0; ${1:\\$i} < ${2:n}; ${1:\\$i}++:\n\t$0\n\\$endfor", COMPILE_TIME },
	{ "$switch", "$switch value: … $endswitch", "\\$switch ${1:\\$value}:\n\t\\$case ${2:1}:\n\t\t$0\n\\$endswitch", COMPILE_TIME },
};

// Offer the templates that fit the cursor position. The keyword templates need a
// plain prefix, the compile-time ones a `$` prefix.
fn void add_snippets(String uri, String content, DocumentList* docs, sz prefix_start, String prefix, CompletionSink* sink)
{
	if (!sink.snippets) return;
	bool ct = prefix.len > 0 && prefix[0] == '$';
	if (prefix.len > 0 && !ct && !is_ident_char(prefix[0])) return; // `@attr`, `#expr`

	TokenStream owned;
	bool owns;
	TokenStream* stream = token_stream_for_doc(uri, content, docs, &owned, &owns);
	defer { if (owns) owned.free(); }

	SnippetPlace? place = stream.tokens.snippet_place(prefix_start);
	if (catch place) return;
	foreach (s : SNIPPETS)
	{
		if (ct ? s.place != COMPILE_TIME : s.place != place) continue;
		sink.add_snippet(s.label, s.detail, s.body);
	}
}

// Where a construct typed at `prefix_start` would land: at the start of a statement in
// a fn/macro body, or at the start of a top-level declaration. Fails anywhere else,
// including inside comments, strings, parentheses and struct bodies.
fn SnippetPlace? TokenList.snippet_place(&self, sz prefix_start)
{
	sz prev = -1; // the last token before the prefix, comments skipped
	sz braces = 0;
	for (sz i = 0; i < self.size; i++)
	{
		Token t = self.entries[i];
		if (t.offset >= prefix_start) break;
		if (t.offset + t.len > prefix_start) return TOKEN_NOT_FOUND~; // inside a string or comment
		switch (t.type)
		{
			case LINE_COMMENT:
				// A line comment runs to the end of its line, so the cursor right after
				// its last character is still inside it.
				if (t.offset + t.len == prefix_start) return TOKEN_NOT_FOUND~;
				continue;
			case BLOCK_COMMENT:
				continue;
			case LBRACE:
				braces++;
			case RBRACE:
				if (braces > 0) braces--;
			default:
				break;
		}
		prev = i;
	}

	if (prev < 0) return TOP_LEVEL;
	sz p = prev;
	TokenType pt = self.entries[p].type;
	if (braces == 0)
	{
		if (pt == EOS || pt == RBRACE || pt == CONTRACT) return TOP_LEVEL;
		return TOKEN_NOT_FOUND~;
	}

	// The innermost and outermost braces still open at the cursor. Counted backwards
	// rather than through the function's span, which needs a closing brace the user
	// may not have typed yet.
	sz inner = self.size;
	sz outer = self.size;
	sz depth = 0;
	for (sz i = p + 1; i-- > 0;)
	{
		TokenType t = self.entries[i].type;
		if (t == RBRACE) depth++;
		if (t != LBRACE) continue;
		if (depth > 0)
		{
			depth--;
			continue;
		}
		if (inner == self.size) inner = i;
		outer = i;
	}
	if (outer == self.size || !self.opens_callable_body(outer)) return TOKEN_NOT_FOUND~;
	if (self.is_initializer_brace(inner)) return TOKEN_NOT_FOUND~;

	// Not inside the parentheses of `for (...;` or a call.
	sz parens = 0;
	for (sz j = inner + 1; j <= p; j++)
	{
		TokenType t = self.entries[j].type;
		if (t == LPAREN) parens++;
		if (t == RPAREN && parens > 0) parens--;
	}
	if (parens > 0) return TOKEN_NOT_FOUND~;

	switch (pt)
	{
		case EOS:
		case RBRACE:
		case LBRACE:
			return STATEMENT;
		case COLON:
			if (self.is_case_colon(p)) return STATEMENT;
			return TOKEN_NOT_FOUND~;
		default:
			return TOKEN_NOT_FOUND~;
	}
}

// True when the `{` at `lb` opens a fn/macro body, not a struct, enum or interface.
fn bool TokenList.opens_callable_body(&self, sz lb)
{
	for (sz i = lb; i-- > 0;)
	{
		switch (self.entries[i].type)
		{
			case FUNC:
			case MACRO:
				return true;
			case EOS:
			case LBRACE:
			case RBRACE:
			case STRUCT:
			case UNION:
			case BITSTRUCT:
			case ENUM:
			case INTERFACE:
			case FAULTDEF:
			case CONSTDEF:
				return false;
			default:
				break;
		}
	}
	return false;
}

// True when the `:` at `colon` ends a `case`/`default` label rather than a ternary.
fn bool TokenList.is_case_colon(&self, sz colon)
{
	for (sz i = colon; i-- > 0;)
	{
		switch (self.entries[i].type)
		{
			case CASE:
			case DEFAULT:
			case CT_CASE:
			case CT_DEFAULT:
				return true;
			case EOS:
			case LBRACE:
			case RBRACE:
			case COLON:
				return false;
			default:
				break;
		}
	}
	return false;
}
