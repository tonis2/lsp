module lsp;

import std::core::dstring;
import std::core::mem;
import std::collections::list;
import c3::lexer;

alias LineOffsets = List{usz};

fn void LineOffsets.build(&self, String content)
{
	self.push(0); // Line 0 starts at byte 0

	for (usz i = 0; i < content.len; i++)
	{
		if (content[i] == '\n')
		{
			self.push(i + 1);
		}
	}
}

fn usz LineOffsets.find_line(&self, usz offset)
{
	usz low = 0;
	usz high = self.size;
	while (low < high)
	{
		usz mid = (low + high) / 2;
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

fn void encode_semantic_tokens(String content, DString* out)
{
	TokenStream stream = token_stream_tokenize(content);
	defer stream.free();
	LineOffsets* lo = stream.get_line_offsets();

	usz prev_line = 0;
	usz prev_start_char = 0;
	bool first = true;

	for (usz i = 0; i < stream.tokens.size; i++)
	{
		Token tok = stream.tokens.entries[i];
		SemanticCategory category = map_token_type(tok.type);
		if (category == SKIP) continue;

		// Detect function calls: IDENT immediately followed by LPAREN
		if (category == VARIABLE && tok.type == IDENT)
		{
			if (i + 1 < stream.tokens.size && stream.tokens.entries[i + 1].type == LPAREN)
			{
				category = FUNCTION;
			}
		}

		usz tok_start = tok.offset;
		usz tok_end = tok.offset + tok.len;
		usz start_line = lo.find_line(tok_start);
		usz end_line = lo.find_line(tok_end > 0 ? tok_end - 1 : 0);

		if (start_line == end_line)
		{
			// Single-line token — emit directly
			usz start_char = tok_start - lo.entries[start_line];
			usz delta_line = start_line - prev_line;
			usz delta_start_char = delta_line == 0 ? start_char - prev_start_char : start_char;

			if (!first) out.append_char(',');
			out.appendf("%d,%d,%d,%d,0", delta_line, delta_start_char, tok.len, category.index);
			first = false;

			prev_line = start_line;
			prev_start_char = start_char;
		}
		else
		{
			// Multi-line token — split into one entry per line
			for (usz ln = start_line; ln <= end_line; ln++)
			{
				usz seg_start;
				usz seg_end;

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

				usz seg_char = seg_start - lo.entries[ln];
				usz seg_len = seg_end - seg_start;
				usz delta_line = ln - prev_line;
				usz delta_start_char = delta_line == 0 ? seg_char - prev_start_char : seg_char;

				if (!first) out.append_char(',');
				out.appendf("%d,%d,%d,%d,0", delta_line, delta_start_char, seg_len, category.index);
				first = false;

				prev_line = ln;
				prev_start_char = seg_char;
			}
		}
	}
}
