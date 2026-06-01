module lsp;

import std::core::dstring;
import std::core::mem;
import c3::lexer;

// Encodes a signatureHelp response.
// Finds the function being called at cursor position by walking backwards
// to find the function name, then searches the file for its declaration
// to extract the full signature.
fn void encode_signature_help(String content, sz offset, DString* out, TokenStream* cached = null)
{
	TokenStream owned;
	TokenStream* stream;
	if (cached != null) { stream = cached; }
	else { owned = token_stream_tokenize(content); stream = &owned; }
	defer { if (cached == null) owned.free(); }

	// Find which token the cursor is at or after
	// Walk backwards to find the function call context:
	// We need to find IDENT LPAREN ... cursor
	// Handle nested parens by tracking depth
	sz call_name_idx = stream.tokens.size; // sentinel = not found
	sz active_param = 0;

	// Find the token index at or just before cursor
	sz cursor_tok_idx = 0;
	for (sz i = 0; i < stream.tokens.size; i++)
	{
		if (stream.tokens[i].offset <= offset)
		{
			cursor_tok_idx = i;
		}
		else
		{
			break;
		}
	}

	// Walk backwards from cursor, tracking paren depth
	sz depth = 0;
	sz comma_count = 0;
	for (sz ii = 0; ii <= cursor_tok_idx; ii++)
	{
		sz i = cursor_tok_idx - ii;
		TokenType tt = stream.tokens[i].type;
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
				if (i > 0 && is_ident(stream.tokens[i - 1].type))
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

	if (call_name_idx == stream.tokens.size) return;

	String fn_name = stream.tokens[call_name_idx].text;

	// Search for the function declaration in the file
	// Pattern: FUNC ... fn_name LPAREN params RPAREN
	for (sz i = 0; i < stream.tokens.size; i++)
	{
		if (stream.tokens[i].type != FUNC) continue;

		// Find LPAREN after FUNC
		sz lparen_idx = 0;
		for (sz j = i + 1; j < stream.tokens.size && j < i + 64; j++)
		{
			if (stream.tokens[j].type == LPAREN)
			{
				lparen_idx = j;
				break;
			}
			if (stream.tokens[j].type == LBRACE || stream.tokens[j].type == EOS) break;
		}
		if (lparen_idx == 0) continue;

		// Check if the IDENT before LPAREN matches
		if (!is_ident(stream.tokens[lparen_idx - 1].type) || stream.tokens[lparen_idx - 1].text != fn_name) continue;

		// Found the declaration. Extract signature from FUNC to closing RPAREN or LBRACE
		sz sig_start = stream.tokens[i].offset;
		sz sig_end = sig_start;
		sz paren_depth = 0;
		bool found_sig_end = false;

		for (sz j = lparen_idx; j < stream.tokens.size; j++)
		{
			if (stream.tokens[j].type == LPAREN)
			{
				paren_depth++;
			}
			else if (stream.tokens[j].type == RPAREN)
			{
				paren_depth--;
				if (paren_depth == 0)
				{
					sig_end = stream.tokens[j].offset + stream.tokens[j].len;
					found_sig_end = true;
					break;
				}
			}
			else if (stream.tokens[j].type == LBRACE || stream.tokens[j].type == EOS)
			{
				sig_end = stream.tokens[j].offset;
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
		sz param_start_offset = stream.tokens[lparen_idx].offset + 1; // after '('
		paren_depth = 1;

		for (sz j = lparen_idx + 1; j < stream.tokens.size; j++)
		{
			if (stream.tokens[j].type == LPAREN)
			{
				paren_depth++;
			}
			else if (stream.tokens[j].type == RPAREN)
			{
				paren_depth--;
				if (paren_depth == 0)
				{
					// Emit last parameter
					sz param_end_offset = stream.tokens[j].offset;
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
			else if (stream.tokens[j].type == COMMA && paren_depth == 1)
			{
				// Emit parameter
				sz param_end_offset = stream.tokens[j].offset;
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
				param_start_offset = stream.tokens[j].offset + 1; // after ','
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
	for (sz i = 0; i + 1 < stream.tokens.size; i++)
	{
		if (stream.tokens[i].type != MACRO) continue;
		if (!is_ident(stream.tokens[i + 1].type) || stream.tokens[i + 1].text != fn_name) continue;
		if (i + 2 >= stream.tokens.size || stream.tokens[i + 2].type != LPAREN) continue;

		sz sig_start = stream.tokens[i].offset;
		sz sig_end = sig_start;
		sz paren_depth = 0;

		for (sz j = i + 2; j < stream.tokens.size; j++)
		{
			if (stream.tokens[j].type == LPAREN)
			{
				paren_depth++;
			}
			else if (stream.tokens[j].type == RPAREN)
			{
				paren_depth--;
				if (paren_depth == 0)
				{
					sig_end = stream.tokens[j].offset + stream.tokens[j].len;
					break;
				}
			}
			else if (stream.tokens[j].type == LBRACE || stream.tokens[j].type == EOS)
			{
				sig_end = stream.tokens[j].offset;
				break;
			}
		}

		String sig_text = content[sig_start..sig_end - 1];

		// Simple parameter extraction for macros
		DString params_json = dstring::temp();
		params_json.append_char('[');
		bool first_param = true;
		sz param_start_offset = stream.tokens[i + 2].offset + 1;
		paren_depth = 1;

		for (sz j = i + 3; j < stream.tokens.size; j++)
		{
			if (stream.tokens[j].type == LPAREN)
			{
				paren_depth++;
			}
			else if (stream.tokens[j].type == RPAREN)
			{
				paren_depth--;
				if (paren_depth == 0)
				{
					sz param_end_offset = stream.tokens[j].offset;
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
			else if (stream.tokens[j].type == COMMA && paren_depth == 1)
			{
				sz param_end_offset = stream.tokens[j].offset;
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
				param_start_offset = stream.tokens[j].offset + 1;
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
