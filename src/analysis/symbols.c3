module lsp;

import std::core::dstring;
import std::core::mem;
import c3::lexer;

const usz MAX_LOOKAHEAD = 64;

fn void encode_document_symbols(String content, DString* out)
{
	LineOffsets lo;
	lo.init(mem);
	defer lo.free();
	build_line_offsets(content, &lo);

	TokenList tokens;
	tokens.init(mem);
	defer tokens.free();
	tokenize_content(content, &tokens);

	bool first = true;

	for (usz i = 0; i < tokens.size; i++)
	{
		Token tok = tokens.entries[i];
		String name = "";
		int kind = 0;
		usz name_offset = 0;
		usz name_len = 0;
		usz decl_offset = tok.offset;
		usz end_offset = 0;
		bool has_braces = false;

		switch (tok.type)
		{
			case MODULE:
				// module IDENT
				if (i + 1 < tokens.size && tokens.entries[i + 1].type == IDENT)
				{
					Token nt = tokens.entries[i + 1];
					name = nt.text;
					name_offset = nt.offset;
					name_len = nt.len;
					kind = 2; // Module
					end_offset = find_eos_end(&tokens, i + 2);
				}
			case IMPORT:
				// import IDENT
				if (i + 1 < tokens.size && tokens.entries[i + 1].type == IDENT)
				{
					Token nt = tokens.entries[i + 1];
					name = nt.text;
					name_offset = nt.offset;
					name_len = nt.len;
					kind = 2; // Module
					end_offset = find_eos_end(&tokens, i + 2);
				}
			case FUNC:
				// fn ... IDENT LPAREN — the IDENT before LPAREN is the name
				// If preceded by TYPE_IDENT DOT, combine as Type.method
				usz lparen_idx = 0;
				for (usz j = i + 1; j < tokens.size && j < i + MAX_LOOKAHEAD; j++)
				{
					if (tokens.entries[j].type == LPAREN)
					{
						lparen_idx = j;
						break;
					}
					// Stop on LBRACE/EOS (malformed)
					if (tokens.entries[j].type == LBRACE || tokens.entries[j].type == EOS) break;
				}
				if (lparen_idx > 0 && lparen_idx > i + 1)
				{
					Token fn_name = tokens.entries[lparen_idx - 1];
					if (is_ident(fn_name.type))
					{
						// Check for Type.method pattern
						if (lparen_idx >= 3 + i && tokens.entries[lparen_idx - 2].type == DOT && tokens.entries[lparen_idx - 3].type == TYPE_IDENT)
						{
							DString combined = dstring::temp();
							combined.append(tokens.entries[lparen_idx - 3].text);
							combined.append_char('.');
							combined.append(fn_name.text);
							name = combined.str_view();
							name_offset = tokens.entries[lparen_idx - 3].offset;
							name_len = (fn_name.offset + fn_name.len) - tokens.entries[lparen_idx - 3].offset;
						}
						else
						{
							name = fn_name.text;
							name_offset = fn_name.offset;
							name_len = fn_name.len;
						}
						kind = 12; // Function
						has_braces = true;
					}
				}
			case STRUCT:
			case UNION:
			case BITSTRUCT:
				// struct/union/bitstruct TYPE_IDENT
				if (i + 1 < tokens.size && tokens.entries[i + 1].type == TYPE_IDENT)
				{
					Token nt = tokens.entries[i + 1];
					name = nt.text;
					name_offset = nt.offset;
					name_len = nt.len;
					kind = 23; // Struct
					has_braces = true;
				}
			case ENUM:
			case FAULTDEF:
				// enum/faultdef TYPE_IDENT
				if (i + 1 < tokens.size && tokens.entries[i + 1].type == TYPE_IDENT)
				{
					Token nt = tokens.entries[i + 1];
					name = nt.text;
					name_offset = nt.offset;
					name_len = nt.len;
					kind = 10; // Enum
					has_braces = true;
				}
			case INTERFACE:
				// interface TYPE_IDENT
				if (i + 1 < tokens.size && tokens.entries[i + 1].type == TYPE_IDENT)
				{
					Token nt = tokens.entries[i + 1];
					name = nt.text;
					name_offset = nt.offset;
					name_len = nt.len;
					kind = 11; // Interface
					has_braces = true;
				}
			case MACRO:
				// macro IDENT or macro TYPE_IDENT
				if (i + 1 < tokens.size)
				{
					Token nt = tokens.entries[i + 1];
					if (is_ident(nt.type) || nt.type == TYPE_IDENT)
					{
						name = nt.text;
						name_offset = nt.offset;
						name_len = nt.len;
						kind = 12; // Function
						has_braces = true;
					}
				}
			case CONSTDEF:
			case TYPEDEF:
			case ALIAS:
				if (i + 1 < tokens.size)
				{
					Token nt = tokens.entries[i + 1];
					if (nt.type == TYPE_IDENT)
					{
						name = nt.text;
						name_offset = nt.offset;
						name_len = nt.len;
						kind = 26; // TypeParameter
					}
					else if (nt.type == CONST_IDENT)
					{
						name = nt.text;
						name_offset = nt.offset;
						name_len = nt.len;
						kind = 14; // Constant
					}
					if (kind != 0)
					{
						end_offset = find_eos_end(&tokens, i + 2);
					}
				}
			default:
				continue;
		}

		if (name.len == 0 || kind == 0) continue;

		// Find end of declaration for braced declarations
		if (has_braces && end_offset == 0)
		{
			end_offset = find_brace_end(&tokens, i + 1);
		}
		if (end_offset == 0)
		{
			end_offset = name_offset + name_len;
		}

		// Build range and selectionRange using line offsets
		usz decl_line = find_line(&lo, decl_offset);
		usz decl_char = decl_offset - lo.entries[decl_line];
		usz end_line = find_line(&lo, end_offset > 0 ? end_offset - 1 : 0);
		usz end_char = (end_offset > 0 ? end_offset : 1) - lo.entries[end_line];

		usz sel_line = find_line(&lo, name_offset);
		usz sel_char = name_offset - lo.entries[sel_line];
		usz sel_end_line = sel_line;
		usz sel_end_char = sel_char + name_len;

		if (!first) out.append_char(',');
		out.append(`{"name":"`);
		json_escape_into(out, name);
		out.appendf(`","kind":%d`, kind);
		out.appendf(`,"range":{"start":{"line":%d,"character":%d},"end":{"line":%d,"character":%d}}`, decl_line, decl_char, end_line, end_char);
		out.appendf(`,"selectionRange":{"start":{"line":%d,"character":%d},"end":{"line":%d,"character":%d}}`, sel_line, sel_char, sel_end_line, sel_end_char);
		out.append_char('}');
		first = false;
	}
}

fn usz find_eos_end(TokenList* tokens, usz start) @private
{
	for (usz j = start; j < tokens.size; j++)
	{
		if (tokens.entries[j].type == EOS)
		{
			return tokens.entries[j].offset + tokens.entries[j].len;
		}
	}
	return 0;
}

fn usz find_brace_end(TokenList* tokens, usz start) @private
{
	usz depth = 0;
	bool found_brace = false;
	for (usz j = start; j < tokens.size; j++)
	{
		if (tokens.entries[j].type == LBRACE)
		{
			depth++;
			found_brace = true;
		}
		else if (tokens.entries[j].type == RBRACE)
		{
			if (depth > 0) depth--;
			if (depth == 0 && found_brace)
			{
				return tokens.entries[j].offset + tokens.entries[j].len;
			}
		}
	}
	return 0;
}
