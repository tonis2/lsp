module lsp;

import std::core::dstring;
import std::core::mem;
import c3::lexer;

// Encodes a signatureHelp response.
// Finds the function being called at cursor position by walking backwards
// to find the function name, then searches the file for its declaration
// to extract the full signature.
fn void encode_signature_help(String content, usz offset, DString* out)
{
	TokenList tokens;
	tokens.init(mem);
	defer tokens.free();
	tokenize_content(content, &tokens);

	// Find which token the cursor is at or after
	// Walk backwards to find the function call context:
	// We need to find IDENT LPAREN ... cursor
	// Handle nested parens by tracking depth
	usz call_name_idx = tokens.size; // sentinel = not found
	usz active_param = 0;

	// Find the token index at or just before cursor
	usz cursor_tok_idx = 0;
	for (usz i = 0; i < tokens.size; i++)
	{
		if (tokens.entries[i].offset <= offset)
		{
			cursor_tok_idx = i;
		}
		else
		{
			break;
		}
	}

	// Walk backwards from cursor, tracking paren depth
	usz depth = 0;
	usz comma_count = 0;
	for (usz ii = 0; ii <= cursor_tok_idx; ii++)
	{
		usz i = cursor_tok_idx - ii;
		TokenType tt = tokens.entries[i].type;
		if (tt == RPAREN)
		{
			depth++;
		}
		else if (tt == LPAREN)
		{
			if (depth > 0)
			{
				depth--;
			}
			else
			{
				// This is the opening paren of our call
				if (i > 0 && is_ident(tokens.entries[i - 1].type))
				{
					call_name_idx = i - 1;
					active_param = comma_count;
				}
				break;
			}
		}
		else if (tt == COMMA && depth == 0)
		{
			comma_count++;
		}
		if (i == 0) break;
	}

	if (call_name_idx == tokens.size) return;

	String fn_name = tokens.entries[call_name_idx].text;

	// Search for the function declaration in the file
	// Pattern: FUNC ... fn_name LPAREN params RPAREN
	for (usz i = 0; i < tokens.size; i++)
	{
		if (tokens.entries[i].type != FUNC) continue;

		// Find LPAREN after FUNC
		usz lparen_idx = 0;
		for (usz j = i + 1; j < tokens.size && j < i + 64; j++)
		{
			if (tokens.entries[j].type == LPAREN)
			{
				lparen_idx = j;
				break;
			}
			if (tokens.entries[j].type == LBRACE || tokens.entries[j].type == EOS) break;
		}
		if (lparen_idx == 0) continue;

		// Check if the IDENT before LPAREN matches
		if (!is_ident(tokens.entries[lparen_idx - 1].type) || tokens.entries[lparen_idx - 1].text != fn_name) continue;

		// Found the declaration. Extract signature from FUNC to closing RPAREN or LBRACE
		usz sig_start = tokens.entries[i].offset;
		usz sig_end = sig_start;
		usz paren_depth = 0;
		bool found_sig_end = false;

		for (usz j = lparen_idx; j < tokens.size; j++)
		{
			if (tokens.entries[j].type == LPAREN)
			{
				paren_depth++;
			}
			else if (tokens.entries[j].type == RPAREN)
			{
				paren_depth--;
				if (paren_depth == 0)
				{
					sig_end = tokens.entries[j].offset + tokens.entries[j].len;
					found_sig_end = true;
					break;
				}
			}
			else if (tokens.entries[j].type == LBRACE || tokens.entries[j].type == EOS)
			{
				sig_end = tokens.entries[j].offset;
				found_sig_end = true;
				break;
			}
		}
		if (!found_sig_end) continue;

		String sig_text = content[sig_start..sig_end - 1];

		// Extract parameter info by finding commas within the outermost parens
		// Parameters are between LPAREN and matching RPAREN
		DString params_json = dstring::temp();
		params_json.append_char('[');
		bool first_param = true;
		usz param_start_offset = tokens.entries[lparen_idx].offset + 1; // after '('
		paren_depth = 1;

		for (usz j = lparen_idx + 1; j < tokens.size; j++)
		{
			if (tokens.entries[j].type == LPAREN)
			{
				paren_depth++;
			}
			else if (tokens.entries[j].type == RPAREN)
			{
				paren_depth--;
				if (paren_depth == 0)
				{
					// Emit last parameter
					usz param_end_offset = tokens.entries[j].offset;
					if (param_end_offset > param_start_offset)
					{
						String param_text = content[param_start_offset..param_end_offset - 1].trim();
						if (param_text.len > 0)
						{
							if (!first_param) params_json.append_char(',');
							params_json.append(`{"label":"`);
							json_escape_into(&params_json, param_text);
							params_json.append(`"}`);
							first_param = false;
						}
					}
					break;
				}
			}
			else if (tokens.entries[j].type == COMMA && paren_depth == 1)
			{
				// Emit parameter
				usz param_end_offset = tokens.entries[j].offset;
				if (param_end_offset > param_start_offset)
				{
					String param_text = content[param_start_offset..param_end_offset - 1].trim();
					if (param_text.len > 0)
					{
						if (!first_param) params_json.append_char(',');
						params_json.append(`{"label":"`);
						json_escape_into(&params_json, param_text);
						params_json.append(`"}`);
						first_param = false;
					}
				}
				param_start_offset = tokens.entries[j].offset + 1; // after ','
			}
		}
		params_json.append_char(']');

		// Build signatureHelp response
		out.append(`{"signatures":[{"label":"`);
		json_escape_into(out, sig_text);
		out.append(`","parameters":`);
		out.append(params_json.str_view());
		out.appendf(`}],"activeSignature":0,"activeParameter":%d}`, active_param);
		return;
	}

	// Also search for macro declarations: macro fn_name(
	for (usz i = 0; i + 1 < tokens.size; i++)
	{
		if (tokens.entries[i].type != MACRO) continue;
		if (!is_ident(tokens.entries[i + 1].type) || tokens.entries[i + 1].text != fn_name) continue;
		if (i + 2 >= tokens.size || tokens.entries[i + 2].type != LPAREN) continue;

		usz sig_start = tokens.entries[i].offset;
		usz sig_end = sig_start;
		usz paren_depth = 0;

		for (usz j = i + 2; j < tokens.size; j++)
		{
			if (tokens.entries[j].type == LPAREN)
			{
				paren_depth++;
			}
			else if (tokens.entries[j].type == RPAREN)
			{
				paren_depth--;
				if (paren_depth == 0)
				{
					sig_end = tokens.entries[j].offset + tokens.entries[j].len;
					break;
				}
			}
			else if (tokens.entries[j].type == LBRACE || tokens.entries[j].type == EOS)
			{
				sig_end = tokens.entries[j].offset;
				break;
			}
		}

		String sig_text = content[sig_start..sig_end - 1];

		// Simple parameter extraction for macros
		DString params_json = dstring::temp();
		params_json.append_char('[');
		bool first_param = true;
		usz param_start_offset = tokens.entries[i + 2].offset + 1;
		paren_depth = 1;

		for (usz j = i + 3; j < tokens.size; j++)
		{
			if (tokens.entries[j].type == LPAREN)
			{
				paren_depth++;
			}
			else if (tokens.entries[j].type == RPAREN)
			{
				paren_depth--;
				if (paren_depth == 0)
				{
					usz param_end_offset = tokens.entries[j].offset;
					if (param_end_offset > param_start_offset)
					{
						String param_text = content[param_start_offset..param_end_offset - 1].trim();
						if (param_text.len > 0)
						{
							if (!first_param) params_json.append_char(',');
							params_json.append(`{"label":"`);
							json_escape_into(&params_json, param_text);
							params_json.append(`"}`);
							first_param = false;
						}
					}
					break;
				}
			}
			else if (tokens.entries[j].type == COMMA && paren_depth == 1)
			{
				usz param_end_offset = tokens.entries[j].offset;
				if (param_end_offset > param_start_offset)
				{
					String param_text = content[param_start_offset..param_end_offset - 1].trim();
					if (param_text.len > 0)
					{
						if (!first_param) params_json.append_char(',');
						params_json.append(`{"label":"`);
						json_escape_into(&params_json, param_text);
						params_json.append(`"}`);
						first_param = false;
					}
				}
				param_start_offset = tokens.entries[j].offset + 1;
			}
		}
		params_json.append_char(']');

		out.append(`{"signatures":[{"label":"`);
		json_escape_into(out, sig_text);
		out.append(`","parameters":`);
		out.append(params_json.str_view());
		out.appendf(`}],"activeSignature":0,"activeParameter":%d}`, active_param);
		return;
	}
}
