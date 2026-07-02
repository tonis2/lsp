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
// local, a field access vs. a call). Roles are written into `roles`, one per
// token, indexed the same as `stream.tokens`.
fn void classify_roles(TokenStream* stream, SemanticCategory[] roles)
{
	sz n = stream.tokens.size;

	// Pass 1 — baseline from lexical kind, refined by adjacent tokens:
	//   foo(  → call        → FUNCTION
	//   foo:: → module path → NAMESPACE
	//   .foo  → field access → PROPERTY
	for (sz i = 0; i < n; i++)
	{
		Token tok = stream.tokens.entries[i];
		SemanticCategory c = map_token_type(tok.type);

		if (c == VARIABLE && tok.type == IDENT)
		{
			if (i + 1 < n)
			{
				switch (stream.tokens.entries[i + 1].type)
				{
					case LPAREN: c = FUNCTION;
					case SCOPE:  c = NAMESPACE;
					default:     break;
				}
			}
			if (c == VARIABLE && i > 0 && stream.tokens.entries[i - 1].type == DOT)
			{
				c = PROPERTY;
			}
		}

		roles[i] = c;
	}

	// Pass 2 — structural overrides for declarations.
	for (sz i = 0; i < n; i++)
	{
		TokenType tt = stream.tokens.entries[i].type;

		if (tt == FUNC || tt == MACRO)
		{
			classify_signature(stream, roles, i);
		}
		else if (is_type_declaration_keyword(tt) && i + 1 < n
			&& stream.tokens.entries[i + 1].type == TYPE_IDENT)
		{
			// The declared type name: struct Foo, enum Bar, alias Baz, ...
			roles[i + 1] = CLASS;

			if (tt == STRUCT || tt == UNION || tt == BITSTRUCT)
			{
				classify_struct_fields(stream, roles, i);
			}
		}
	}
}

// Classify field declarations inside a struct/union/bitstruct body beginning
// at `kw_idx`: a field's leading type gets the primitive declaration-accent
// color if it's a builtin type (int, bool, ...), same treatment as a
// primitive function return type. A class field type is left as TYPE —
// regular type green, same as every other type reference.
fn void classify_struct_fields(TokenStream* stream, SemanticCategory[] roles, sz kw_idx)
{
	sz n = stream.tokens.size;

	// Find the '{' that opens the body.
	sz brace = -1;
	for (sz j = kw_idx + 1; j < n; j++)
	{
		TokenType t = stream.tokens.entries[j].type;
		if (t == LBRACE) { brace = j; break; }
		if (t == EOS || t == EOF) return;
	}
	if (brace < 0) return;

	sz depth = 0;
	bool at_field_start = false;
	for (sz j = brace; j < n; j++)
	{
		TokenType t = stream.tokens.entries[j].type;
		if (t == LBRACE) { depth++; at_field_start = (depth == 1); continue; }
		if (t == RBRACE)
		{
			depth--;
			if (depth == 0) break;
			at_field_start = false;
			continue;
		}
		if (depth != 1) continue;

		if (t == EOS) { at_field_start = true; continue; }

		// Comments don't count as the start of a declaration — skip over
		// them without losing the "at start of field" state.
		if (t == LINE_COMMENT || t == BLOCK_COMMENT || t == CONTRACT) continue;

		if (!at_field_start) continue;
		at_field_start = false;

		if (is_builtin_type_token(t)) roles[j] = DECL_ACCENT;
	}
}

// Classify the signature of a fn/macro declaration beginning at `kw_idx`:
// the function/method name, the receiver type (for methods), and the
// parameter names inside the parameter list.
fn void classify_signature(TokenStream* stream, SemanticCategory[] roles, sz kw_idx)
{
	sz n = stream.tokens.size;

	// Find the '(' that opens the parameter list, stopping at the body.
	sz paren = -1;
	for (sz j = kw_idx + 1; j < n; j++)
	{
		TokenType t = stream.tokens.entries[j].type;
		if (t == LPAREN) { paren = j; break; }
		if (t == LBRACE || t == EOS || t == RBRACE) return;
	}
	if (paren <= kw_idx + 1) return;

	// The fn/macro keyword itself is part of the declaration accent.
	roles[kw_idx] = DECL_ACCENT;

	// The token right before '(' is the function / method name.
	sz name_idx = paren - 1;
	sz return_type_end = name_idx;
	if (is_ident(stream.tokens.entries[name_idx].type))
	{
		roles[name_idx] = FUNCTION;

		// Receiver type of a method:  Name preceded by  "Type ."
		if (name_idx >= kw_idx + 3 && stream.tokens.entries[name_idx - 1].type == DOT)
		{
			Token recv = stream.tokens.entries[name_idx - 2];
			if (recv.type == TYPE_IDENT || is_type_token(recv.type))
			{
				roles[name_idx - 2] = CLASS;
				return_type_end = name_idx - 2;
			}
		}
	}

	// Primitive return type(s) (void, int, bool, ...) share the accent color
	// with the fn/macro keyword. A class return type is left as TYPE —
	// regular type green, same as every other type reference.
	for (sz j = kw_idx + 1; j < return_type_end; j++)
	{
		if (roles[j] == TYPE && is_builtin_type_token(stream.tokens.entries[j].type))
		{
			roles[j] = DECL_ACCENT;
		}
	}

	// Parameter names inside the (...) list (depth 1 only).
	sz depth = 0;
	for (sz j = paren; j < n; j++)
	{
		TokenType t = stream.tokens.entries[j].type;
		if (t == LPAREN) { depth++; continue; }
		if (t == RPAREN)
		{
			depth--;
			if (depth == 0) break;
			continue;
		}
		if (depth != 1) continue;
		if (roles[j] != VARIABLE || stream.tokens.entries[j].type != IDENT) continue;
		if (j + 1 >= n) continue;

		// A name ends with ',', ')' or '=' (default value).
		switch (stream.tokens.entries[j + 1].type)
		{
			case COMMA:
			case RPAREN:
			case EQ:
				roles[j] = PARAMETER;
			default:
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

fn void encode_semantic_tokens(String content, DString* out, TokenStream* cached = null)
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
	classify_roles(stream, roles);

	sz prev_line = 0;
	sz prev_start_char = 0;
	bool first = true;

	for (sz i = 0; i < n; i++)
	{
		Token tok = stream.tokens.entries[i];
		SemanticCategory category = roles[i];
		if (category == SKIP) continue;

		sz tok_start = tok.offset;
		sz tok_end = tok.offset + tok.len;
		sz start_line = lo.find_line(tok_start);
		sz end_line = lo.find_line(tok_end > 0 ? tok_end - 1 : 0);

		if (start_line == end_line)
		{
			// Single-line token — emit directly (positions in UTF-16 units)
			sz start_char = utf16_len(content, lo.entries[start_line], tok_start);
			sz tok_u16_len = utf16_len(content, tok_start, tok_end);
			sz delta_line = start_line - prev_line;
			sz delta_start_char = delta_line == 0 ? start_char - prev_start_char : start_char;

			if (!first) out.append_char(',');
			out.appendf("%d,%d,%d,%d,0", delta_line, delta_start_char, tok_u16_len, category.index);
			first = false;

			prev_line = start_line;
			prev_start_char = start_char;
		}
		else
		{
			// Multi-line token — split into one entry per line
			for (sz ln = start_line; ln <= end_line; ln++)
			{
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

				sz seg_char = utf16_len(content, lo.entries[ln], seg_start);
				sz seg_len = utf16_len(content, seg_start, seg_end);
				sz delta_line = ln - prev_line;
				sz delta_start_char = delta_line == 0 ? seg_char - prev_start_char : seg_char;

				if (!first) out.append_char(',');
				out.appendf("%d,%d,%d,%d,0", delta_line, delta_start_char, seg_len, category.index);
				first = false;

				prev_line = ln;
				prev_start_char = seg_char;
			}
		}
	}
}
