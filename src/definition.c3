module lsp;

import std::core::dstring;
import std::core::mem;
import c3::lexer;

// Encodes a go-to-definition / go-to-declaration response.
// Both use the same logic: find the token at cursor, then locate its
// declaration site in the same file by scanning for declaration patterns.
// Returns a Location JSON object, or empty string if not found.
fn void encode_definition(String uri, String content, usz offset, DString* out) {
	const usz MAX_TOKENS = 16384;
	Token[] tokens = mem::new_array(Token, MAX_TOKENS);
	defer mem::free(tokens);
	usz token_count = 0;

	Lexer lex;
	lex.init(content);

	while (token_count < MAX_TOKENS) {
		if (try tok = lex.next()) {
			tokens[token_count] = tok;
			token_count++;
		} else {
			if (lex.at_end()) break;
			lex.pos++;
			lex.col++;
		}
	}

	// Find the token at cursor
	usz cursor_idx = 0;
	bool found_cursor = false;
	for (usz i = 0; i < token_count; i++) {
		usz tok_end = tokens[i].offset + tokens[i].len;
		if (tokens[i].offset <= offset && offset < tok_end) {
			cursor_idx = i;
			found_cursor = true;
			break;
		}
	}
	if (!found_cursor) return;

	Token cursor_tok = tokens[cursor_idx];

	// Only navigate for identifier-like tokens
	TokenType ct = cursor_tok.type;
	if (ct != IDENT && ct != TYPE_IDENT && ct != CONST_IDENT) return;

	// Find declaration site
	usz decl_idx = find_declaration(tokens[..token_count - 1], token_count, cursor_tok, cursor_idx);
	if (decl_idx == token_count) return; // Not found
	if (decl_idx == cursor_idx) return; // Already at declaration

	// Build Location response
	LineOffsets* lo = mem::new(LineOffsets);
	defer mem::free(lo);
	build_line_offsets(content, lo);

	Token decl_tok = tokens[decl_idx];
	usz line = find_line(lo, decl_tok.offset);
	usz col = decl_tok.offset - lo.offsets[line];
	usz end_col = col + decl_tok.len;

	out.append(`{"uri":"`);
	json_escape_into(out, uri);
	out.appendf(`","range":{"start":{"line":%d,"character":%d},"end":{"line":%d,"character":%d}}}`, line, col, line, end_col);
}

// Searches for the declaration of a token in the token stream.
// Returns the index of the name token at the declaration site,
// or token_count if not found.
fn usz find_declaration(Token[] tokens, usz token_count, Token target, usz target_idx) @private {
	String name = target.text;

	switch (target.type) {
		case TYPE_IDENT:
			// Look for: struct/union/bitstruct/enum/faultdef/interface TYPE_IDENT
			// or: typedef/constdef/alias TYPE_IDENT
			for (usz i = 0; i + 1 < token_count; i++) {
				TokenType kw = tokens[i].type;
				if (kw == STRUCT || kw == UNION || kw == BITSTRUCT ||
					kw == ENUM || kw == FAULTDEF || kw == INTERFACE ||
					kw == TYPEDEF || kw == CONSTDEF || kw == ALIAS) {
					if (tokens[i + 1].type == TYPE_IDENT && tokens[i + 1].text == name) {
						return i + 1;
					}
				}
			}
		case CONST_IDENT:
			// Look for: constdef CONST_IDENT
			for (usz i = 0; i + 1 < token_count; i++) {
				if (tokens[i].type == CONSTDEF && tokens[i + 1].type == CONST_IDENT && tokens[i + 1].text == name) {
					return i + 1;
				}
			}
		case IDENT:
			// Look for function declarations: fn ... name(
			// The IDENT immediately before LPAREN after a FUNC keyword
			for (usz i = 0; i < token_count; i++) {
				if (tokens[i].type != FUNC) continue;
				// Scan forward to find LPAREN
				for (usz j = i + 1; j < token_count && j < i + 64; j++) {
					if (tokens[j].type == LPAREN) {
						if (j > 0 && tokens[j - 1].type == IDENT && tokens[j - 1].text == name) {
							return j - 1;
						}
						break;
					}
					if (tokens[j].type == LBRACE || tokens[j].type == EOS) break;
				}
			}
			// Look for macro declarations: macro name
			for (usz i = 0; i + 1 < token_count; i++) {
				if (tokens[i].type == MACRO && tokens[i + 1].type == IDENT && tokens[i + 1].text == name) {
					return i + 1;
				}
			}
			// Look for variable/const declarations using var or type followed by ident
			// Pattern: (any_type | VAR) IDENT EQ  — simple heuristic
			for (usz i = 0; i + 1 < token_count; i++) {
				if (is_type_token(tokens[i].type) && tokens[i + 1].type == IDENT && tokens[i + 1].text == name) {
					// Make sure it's not just a usage — check if followed by EQ or EOS
					if (i + 2 < token_count) {
						TokenType next = tokens[i + 2].type;
						if (next == EQ || next == EOS || next == COMMA) {
							return i + 1;
						}
					}
				}
			}
		default:
			return token_count;
	}

	return token_count;
}

fn bool is_type_token(TokenType t) @private {
	switch (t) {
		case VOID: case BOOL: case CHAR: case ICHAR:
		case SHORT: case USHORT: case INT: case UINT:
		case LONG: case ULONG: case INT128: case UINT128:
		case FLOAT: case DOUBLE: case FLOAT16: case BFLOAT16: case FLOAT128:
		case IPTR: case UPTR: case ISZ: case USZ:
		case FAULT: case ANY: case TYPEID:
		case TYPE_IDENT: case VAR:
			return true;
		default:
			return false;
	}
}
