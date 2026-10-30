module lsp;

import std::core::dstring;
import std::core::mem;
import std::collections::list;
import c3::lexer;

alias LineOffsets = List{sz};

fn void LineOffsets.build(&self, String content)
{
	self.push(0); // Line 0 starts at byte 0

	for (sz i = 0; i < content.len; i++)
	{
		if (content[i] == '\n')
		{
			self.push(i + 1);
		}
	}
}

fn sz LineOffsets.find_line(&self, sz offset)
{
	sz low = 0;
	sz high = self.size;
	while (low < high)
	{
		sz mid = (low + high) / 2;
		if (self.entries[mid] <= offset)
		{
			low = mid + 1;
		}
		else
		{
			high = mid;
		}
	}
	return low > 0 ? low - 1 : 0;
}

// Assigns a semantic role to every token using grammatical context, so that
// tokens sharing a lexical kind can still be colored by the role they play
// (a return type vs. the receiver type of a method, a parameter name vs. a
// local, a field access vs. a call). Roles are written into `roles` and modifier
// bits (MOD_*) into `mods`, one per token, indexed the same as `stream.tokens`.
fn void classify_roles(TokenStream* stream, SemanticCategory[] roles, int[] mods)
{
	TokenList* toks = &stream.tokens;
	sz n = toks.size;

	// Pass 1 — baseline from lexical kind, refined by adjacent tokens:
	//   foo(        → call        → FUNCTION
	//   foo{Bar}(   → generic call → FUNCTION
	//   foo::       → module path → NAMESPACE
	//   .foo        → field access → PROPERTY
	//   @foo(...)   → macro call (MACRO) or attribute (DECORATOR) by position
	for (sz i = 0; i < n; i++)
	{
		Token tok = toks.entries[i];
		SemanticCategory c = map_token_type(tok.type);
		int m = 0;

		if (c == VARIABLE && tok.type == IDENT)
		{
			if (i + 1 < n)
			{
				switch (toks.entries[i + 1].type)
				{
					case LPAREN: c = FUNCTION;
					case LBRACE:
						// Only `name{Args}(` is a call; `struct inner {` is not.
						sz rb = toks.match_rbrace(i + 1);
						if (rb + 1 < n && toks.entries[rb + 1].type == LPAREN) c = FUNCTION;
					case SCOPE:  c = NAMESPACE;
					default:     break;
				}
			}
			if (c == VARIABLE && i > 0 && toks.entries[i - 1].type == DOT)
			{
				c = PROPERTY;
			}
		}
		if (tok.type == AT_IDENT && !toks.is_attribute_at(i)) c = MACRO_CAT;
		if (is_builtin_type_token(tok.type)) m |= MOD_DEFAULT_LIBRARY;
		if (c == ENUM_MEMBER) m |= MOD_READONLY;

		roles[i] = c;
		mods[i] = m;
	}

	// Pass 2 — structural overrides for declarations.
	for (sz i = 0; i < n; i++)
	{
		TokenType tt = toks.entries[i].type;

		if (tt == FUNC || tt == MACRO)
		{
			classify_signature(stream, roles, mods, i);
		}
		else if (is_type_declaration_keyword(tt) && i + 1 < n
			&& toks.entries[i + 1].type == TYPE_IDENT)
		{
			// The declared type name: struct Foo, enum Bar, alias Baz, ...
			roles[i + 1] = CLASS;
			mods[i + 1] |= MOD_DECLARATION;

			if (tt == STRUCT || tt == UNION || tt == BITSTRUCT)
			{
				classify_struct_fields(stream, roles, mods, i);
			}
			if (tt == ENUM || tt == CONSTSET || tt == CONSTDEF) mark_member_declarations(toks, mods, i);
		}
		else if ((tt == ATTRDEF || tt == ATTRMACRO) && i + 1 < n && toks.entries[i + 1].type == AT_TYPE_IDENT)
		{
			// The declared attribute: `attrdef @Component(name) = @tag(...)`.
			mods[i + 1] |= MOD_DECLARATION;
			// Its parameters, and their uses in the attribute list.
			if (try span = toks.attribute_span(i))
			{
				for (sz j = span.lparen + 1; j < span.end; j++)
				{
					if (!is_local_name(toks.entries[j].type)) continue;
					if (try decl = toks.local_declaration_of(j, span))
					{
						roles[j] = PARAMETER;
						if (decl == j) mods[j] |= MOD_DECLARATION;
					}
				}
			}
		}
		else if (tt == FAULTDEF || tt == CONSTDEF)
		{
			// Braceless: `faultdef A, B;` / `constdef NAME = 1;`.
			mark_member_declarations(toks, mods, i);
		}
		else if (tt == CONST)
		{
			// `const [Type] NAME = ...`: the name is the last constant before `=`.
			for (sz j = i + 1; j < n && j < i + 64; j++)
			{
				TokenType t = toks.entries[j].type;
				if (t == EQ || t == EOS) break;
				if (t == CONST_IDENT && j + 1 < n && (toks.entries[j + 1].type == EQ || toks.entries[j + 1].type == AT_IDENT))
				{
					mods[j] |= MOD_DECLARATION;
					break;
				}
			}
		}
		else if ((tt == AT_IDENT && toks.entries[i].text == "@feat") || tt == CT_FEAT || tt == CT_FEATURE)
		{
			// Feature flags: `@feat(POSIX, !WIN32)`, `$feat(LIBC)`.
			if (i + 1 >= n || toks.entries[i + 1].type != LPAREN) continue;
			sz close = toks.match_rparen(i + 1);
			for (sz j = i + 2; j < close && j < n; j++)
			{
				if (toks.entries[j].type != CONST_IDENT) continue;
				roles[j] = MACRO_CAT;
				mods[j] = 0;
			}
		}
	}
}

// Whether the `@name` at `i` is an attribute (`fn void f() @inline`, `int x @noinit`)
// rather than a macro call (`@foo(x);`, `y = @foo();`). Compiler attributes are known
// by name; for any other the position decides: an attribute follows a declaration's
// head, while a call sits in a statement or expression.
fn bool TokenList.is_attribute_at(&self, sz i)
{
	String name = self.entries[i].text;
	foreach (attr : BUILTIN_ATTRIBUTES)
	{
		if (attr == name) return true;
	}
	// Walk back to the start of the declaration or statement holding `i`.
	sz depth = 0;
	for (sz k = i; k > 0; k--)
	{
		TokenType t = self.entries[k - 1].type;
		if (t == RPAREN || t == RBRACKET)
		{
			depth++;
			continue;
		}
		if (t == LPAREN || t == LBRACKET)
		{
			if (depth == 0) return false; // an argument: a call
			depth--;
			continue;
		}
		if (depth > 0) continue;
		switch (t)
		{
			case EOS:
			case LBRACE:
			case RBRACE:
			case EQ:
				return false;
			case FUNC:
			case MACRO:
			case STRUCT:
			case UNION:
			case BITSTRUCT:
			case ENUM:
			case CONSTSET:
			case CONSTDEF:
			case FAULTDEF:
			case INTERFACE:
			case ALIAS:
			case TYPEDEF:
			case MODULE:
			case IMPORT:
			case CONST:
			case EXTERN:
			case ATTRDEF:
			case ATTRMACRO:
				return true;
			default:
				break;
		}
	}
	return false;
}

// Mark the members declared by the enum/constset/constdef/faultdef at `kw_idx` as
// declarations: the constants in declaration position (first in the body or after a
// top-level comma), not those in value expressions.
fn void mark_member_declarations(TokenList* toks, int[] mods, sz kw_idx)
{
	sz n = toks.size;
	sz j = kw_idx + 1;
	while (j < n && toks.entries[j].type != LBRACE && toks.entries[j].type != EOS) j++;
	bool braced = j < n && toks.entries[j].type == LBRACE;
	sz from = braced ? j + 1 : kw_idx + 1;
	sz end = braced ? toks.match_rbrace(j) : j;
	bool decl_pos = true;
	sz depth = 0;
	for (sz k = from; k < end && k < n; k++)
	{
		TokenType t = toks.entries[k].type;
		if (t == LPAREN || t == LBRACE || t == LBRACKET) depth++;
		if ((t == RPAREN || t == RBRACE || t == RBRACKET) && depth > 0) depth--;
		if (depth > 0) continue;
		if (t == COMMA || t == EOS)
		{
			decl_pos = true;
			continue;
		}
		if (t == LINE_COMMENT || t == BLOCK_COMMENT || t == CONTRACT) continue;
		if (decl_pos && t == CONST_IDENT) mods[k] |= MOD_DECLARATION;
		decl_pos = false;
	}
}

// Classify the members of a struct/union/bitstruct body beginning at `kw_idx`:
// field names are properties (`int count;`, `bool flag : 3;`, a named nested
// `struct inner { ... }`), like the `.count` that reads them.
fn void classify_struct_fields(TokenStream* stream, SemanticCategory[] roles, int[] mods, sz kw_idx)
{
	TokenList* toks = &stream.tokens;
	sz n = toks.size;

	// Find the '{' that opens the body.
	sz brace = n;
	for (sz j = kw_idx + 1; j < n; j++)
	{
		TokenType t = toks.entries[j].type;
		if (t == LBRACE) { brace = j; break; }
		if (t == EOS) return;
	}
	if (brace >= n) return;

	sz end = toks.match_rbrace(brace);
	for (sz j = brace + 1; j < end && j + 1 < n; j++)
	{
		if (toks.entries[j].type != IDENT) continue;
		switch (toks.entries[j + 1].type)
		{
			case EOS:
			case COLON:
			case AT_IDENT:
			case LBRACE:
				roles[j] = PROPERTY;
				mods[j] |= MOD_DECLARATION;
			default:
				break;
		}
	}
}

// Classify the signature of a fn/macro declaration beginning at `kw_idx`:
// the function/method name, the receiver type (for methods), the parameter
// names inside the parameter list, and the parameters' uses in the body.
fn void classify_signature(TokenStream* stream, SemanticCategory[] roles, int[] mods, sz kw_idx)
{
	TokenList* toks = &stream.tokens;
	sz n = toks.size;

	// Find the '(' that opens the parameter list, stopping at the body. A `{...}`
	// right after a type is a generic return type (`fn List{int} make(...)`).
	sz paren = n;
	for (sz j = kw_idx + 1; j < n; j++)
	{
		TokenType t = toks.entries[j].type;
		if (t == LPAREN) { paren = j; break; }
		if (t == LBRACE && j > kw_idx + 1 && toks.entries[j - 1].type == TYPE_IDENT)
		{
			j = toks.match_rbrace(j);
			continue;
		}
		if (t == LBRACE || t == EOS || t == RBRACE) return;
	}
	if (paren >= n || paren <= kw_idx + 1) return;

	// The token right before '(' is the function / method / macro name.
	sz name_idx = paren - 1;
	if (is_ident(toks.entries[name_idx].type))
	{
		roles[name_idx] = toks.entries[kw_idx].type == MACRO ? MACRO_CAT : FUNCTION;
		mods[name_idx] |= MOD_DECLARATION;

		// Receiver type of a method:  Name preceded by  "Type ."
		if (name_idx >= kw_idx + 3 && toks.entries[name_idx - 1].type == DOT)
		{
			Token recv = toks.entries[name_idx - 2];
			if (recv.type == TYPE_IDENT || is_type_token(recv.type)) roles[name_idx - 2] = CLASS;
		}
	}

	// Parameter names inside the (...) list (depth 1 only). A macro's trailing body
	// parameter comes after a `;`: `macro @m(x; @body)`.
	String[32] params;
	sz param_count = 0;
	sz depth = 0;
	sz rparen = n;
	bool after_semicolon = false;
	for (sz j = paren; j < n; j++)
	{
		TokenType t = toks.entries[j].type;
		if (t == LPAREN) { depth++; continue; }
		if (t == RPAREN)
		{
			depth--;
			if (depth == 0) { rparen = j; break; }
			continue;
		}
		if (depth != 1) continue;
		if (t == EOS) { after_semicolon = true; continue; }
		if (t == AT_IDENT && after_semicolon)
		{
			roles[j] = PARAMETER;
			mods[j] |= MOD_DECLARATION;
			continue;
		}
		if (t != IDENT && t != CT_IDENT && t != HASH_IDENT) continue;
		if (j + 1 >= n) continue;

		// A name ends with ',', ')', '=' (default value) or ';'.
		switch (toks.entries[j + 1].type)
		{
			case COMMA:
			case RPAREN:
			case EQ:
			case EOS:
				roles[j] = PARAMETER;
				mods[j] |= MOD_DECLARATION;
				if (param_count < params.len) params[param_count++] = toks.entries[j].text;
			default:
				break;
		}
	}
	if (param_count == 0 || rparen >= n) return;

	// The body: after the attributes, a `{...}` block or a `=> expr`. C3 has no
	// shadowing, so inside it a parameter's name always means the parameter.
	sz body = rparen + 1;
	while (body < n && toks.entries[body].type != LBRACE && toks.entries[body].type != IMPLIES && toks.entries[body].type != EOS)
	{
		if (toks.entries[body].type == LPAREN) body = toks.match_rparen(body);
		body++;
	}
	if (body >= n || toks.entries[body].type == EOS) return;
	sz body_end = toks.entries[body].type == LBRACE ? toks.match_rbrace(body) : toks.expression_end(body + 1);
	for (sz j = body + 1; j < body_end && j < n; j++)
	{
		TokenType t = toks.entries[j].type;
		if (t != IDENT && t != CT_IDENT && t != HASH_IDENT) continue;
		TokenType prev = toks.entries[j - 1].type;
		if (prev == DOT || prev == SCOPE) continue;
		if (j + 1 < n && toks.entries[j + 1].type == SCOPE) continue;
		foreach (p : params[:param_count])
		{
			if (p != toks.entries[j].text) continue;
			roles[j] = PARAMETER;
			break;
		}
	}
}

// Count UTF-16 code units in content[start:end] (a UTF-8 byte range).
// The LSP protocol expresses token `character` and `length` in UTF-16 units,
// not bytes — every non-ASCII byte would otherwise push positions past the
// end of the line and make VS Code reject the whole batch.
fn sz utf16_len(String content, sz start, sz end)
{
	sz count = 0;
	for (sz i = start; i < end && i < content.len; i++)
	{
		char b = content[i];
		if ((b & 0xC0) == 0x80) continue; // UTF-8 continuation byte
		count++;                          // leading byte → 1 code point
		if (b >= 0xF0) count++;           // 4-byte seq → surrogate pair (+1)
	}
	return count;
}

// No line limit / no line yet.
const sz SZ_NONE = (sz)(~(usz)0 >> 1);

// Delta-encoding state shared by every emitted token segment: LSP semantic
// tokens are relative to the previous token, so all emission must go through
// one ordered stream of calls.
struct SemanticEmitState
{
	sz prev_line;
	sz prev_start_char;
	bool first;
	// Only lines in [range_start, range_end] are emitted (semanticTokens/range).
	sz range_start;
	sz range_end;
	// The UTF-16 column of byte `col_byte` on line `col_line`: tokens come in order,
	// so each column is counted on from the previous one instead of from the start of
	// the line, which would be quadratic on a very long line.
	sz col_line;
	sz col_byte;
	sz col_units;
}

fn SemanticEmitState semantic_emit_state(sz range_start = 0, sz range_end = SZ_NONE)
{
	return { .first = true, .range_start = range_start, .range_end = range_end, .col_line = SZ_NONE };
}

// UTF-16 column of byte `at` on line `ln` (starting at byte `line_start`).
fn sz SemanticEmitState.column(&self, String content, sz ln, sz line_start, sz at)
{
	if (self.col_line != ln || at < self.col_byte)
	{
		self.col_line = ln;
		self.col_byte = line_start;
		self.col_units = 0;
	}
	self.col_units += utf16_len(content, self.col_byte, at);
	self.col_byte = at;
	return self.col_units;
}

// Emit one colored byte range [seg_start, seg_end), split per line (the LSP
// data format has no multi-line tokens) with positions in UTF-16 units.
fn void SemanticEmitState.emit(&self, String content, LineOffsets* lo, DString* out,
	SemanticCategory category, int modifiers, sz tok_start, sz tok_end)
{
	sz start_line = lo.find_line(tok_start);
	sz end_line = lo.find_line(tok_end > 0 ? tok_end - 1 : 0);
	if (end_line < self.range_start || start_line > self.range_end) return;

	for (sz ln = start_line; ln <= end_line; ln++)
	{
		if (ln < self.range_start || ln > self.range_end) continue;
		sz seg_start;
		sz seg_end;

		if (ln == start_line)
		{
			seg_start = tok_start;
		}
		else
		{
			seg_start = lo.entries[ln];
		}

		if (ln == end_line)
		{
			seg_end = tok_end;
		}
		else
		{
			// End at the newline (or next line's offset)
			seg_end = ln + 1 < lo.size ? lo.entries[ln + 1] : tok_end;
			// Don't include the newline character itself
			if (seg_end > seg_start && seg_end <= content.len && content[seg_end - 1] == '\n')
			{
				seg_end--;
			}
			if (seg_end > seg_start && seg_end <= content.len && content[seg_end - 1] == '\r')
			{
				seg_end--;
			}
		}

		if (seg_end <= seg_start) continue;

		sz seg_char = self.column(content, ln, lo.entries[ln], seg_start);
		sz seg_len = utf16_len(content, seg_start, seg_end);
		sz delta_line = ln - self.prev_line;
		sz delta_start_char = delta_line == 0 ? seg_char - self.prev_start_char : seg_char;

		if (!self.first) out.append_char(',');
		out.appendf("%d,%d,%d,%d,%d", delta_line, delta_start_char, seg_len, category.index, modifiers);
		self.first = false;

		self.prev_line = ln;
		self.prev_start_char = seg_char;
	}
}

// A contract block `<* ... *>` is a single lexer token, but coloring it all as
// one comment paints over the directive lines that should read as code. Split
// it instead: the `<*`/`*>` delimiters and the leading prose stay comment-
// colored, while the directive section is re-lexed so `@require`-style names
// get the decorator color and their arguments highlight like ordinary code.
fn void SemanticEmitState.emit_contract(&self, String content, LineOffsets* lo, DString* out, Token tok)
{
	sz tok_end = tok.offset + tok.len;
	if (tok.len < 5 || tok.unterminated)
	{
		// Degenerate/unterminated contract — keep it a plain comment.
		self.emit(content, lo, out, COMMENT, 0, tok.offset, tok_end);
		return;
	}

	ContractLexer cl;
	cl.init(content[tok.offset : tok.len]);
	TokenList ctoks;
	ctoks.init(mem);
	defer ctoks.free();
	while (try t = cl.next())
	{
		if (t.type == EOL || t.type == EOF) continue;
		ctoks.push(t);
	}

	// `<*` plus the prose intro (everything before the first @directive line).
	// Token offsets are relative to the directive section, which starts after
	// the 2-char `<*` delimiter and the intro.
	sz code_base = ctoks.size > 0 ? tok.offset + 2 + cl.intro.len : tok_end - 2;
	sz intro_end = code_base;
	while (intro_end > tok.offset
		&& (content[intro_end - 1] == '\n' || content[intro_end - 1] == '\r'))
	{
		intro_end--;
	}
	self.emit(content, lo, out, COMMENT, 0, tok.offset, intro_end);

	for (sz k = 0; k < ctoks.size; k++)
	{
		Token t = ctoks.entries[k];
		SemanticCategory c = map_token_type(t.type);
		int m = is_builtin_type_token(t.type) ? MOD_DEFAULT_LIBRARY : 0;
		// Same refinements as pass 1 of classify_roles.
		if (c == VARIABLE && t.type == IDENT)
		{
			if (k + 1 < ctoks.size)
			{
				switch (ctoks.entries[k + 1].type)
				{
					case LPAREN: c = FUNCTION;
					case SCOPE:  c = NAMESPACE;
					default:     break;
				}
			}
			if (c == VARIABLE && k > 0 && ctoks.entries[k - 1].type == DOT)
			{
				c = PROPERTY;
			}
		}
		// Prose in a directive (`@return the caller's id`) lexes as junk or as a
		// literal that never closes; it reads as the comment it is.
		if (t.type == INVALID || t.unterminated) c = COMMENT;
		if (c == SKIP) continue;
		self.emit(content, lo, out, c, m, code_base + t.offset, code_base + t.offset + t.len);
	}

	// Closing `*>`.
	self.emit(content, lo, out, COMMENT, 0, tok_end - 2, tok_end);
}

// Encode the semantic tokens of `content` (the body of the "data" array). With a
// line range, only tokens on lines [range_start, range_end] are included.
fn void encode_semantic_tokens(String content, DString* out, TokenStream* cached = null, sz range_start = 0, sz range_end = SZ_NONE)
{
	TokenStream owned;
	TokenStream* stream;
	if (cached != null) { stream = cached; }
	else { owned = token_stream_tokenize(content); stream = &owned; }
	defer { if (cached == null) owned.free(); }
	LineOffsets* lo = stream.get_line_offsets();

	sz n = stream.tokens.size;
	if (n == 0) return;

	SemanticCategory[] roles = mem::new_array(SemanticCategory, n);
	defer mem::free(roles);
	int[] mods = mem::new_array(int, n);
	defer mem::free(mods);
	classify_roles(stream, roles, mods);

	SemanticEmitState st = semantic_emit_state(range_start, range_end);

	for (sz i = 0; i < n; i++)
	{
		Token tok = stream.tokens.entries[i];
		if (tok.type == CONTRACT)
		{
			st.emit_contract(content, lo, out, tok);
			continue;
		}
		SemanticCategory category = roles[i];
		if (category == SKIP) continue;
		st.emit(content, lo, out, category, mods[i], tok.offset, tok.offset + tok.len);
	}
}
