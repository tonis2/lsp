module lsp;

import c3::lexer;

// LSP positions are a line plus a column counted in UTF-16 code units, while
// everything here works on UTF-8 byte offsets. Every position that crosses the
// protocol goes through these conversions, in both directions: otherwise any
// non-ASCII text earlier on a line (a string, a comment) shifts the column of
// everything after it.

// Byte offset of the UTF-16 column `units` on the line starting at `line_start`.
// Clamped to the end of that line, so a column past it never spills onto the next.
fn sz utf16_to_byte(String content, sz line_start, sz units)
{
	sz i = line_start;
	sz u = 0;
	while (i < content.len && content[i] != '\n' && u < units)
	{
		char b = content[i];
		sz n = b >= 0xF0 ? 4 : b >= 0xE0 ? 3 : b >= 0xC0 ? 2 : 1;
		u += n == 4 ? 2 : 1; // a 4-byte sequence is a surrogate pair
		i += n;
	}
	return i < content.len ? i : content.len;
}

// The LSP position of byte `offset` in `content`.
fn Position offset_to_position(String content, LineOffsets* lo, sz offset)
{
	sz line = lo.find_line(offset);
	return { line, utf16_len(content, lo.entries[line], offset) };
}

// The LSP range of the byte span [start, end) in `content`. An end right after a
// line's newline stays on that line, so a span never ends on an empty next line.
fn Range span_to_range(String content, LineOffsets* lo, sz start, sz end)
{
	if (end < start) end = start;
	sz start_line = lo.find_line(start);
	sz end_line   = lo.find_line(end > start ? end - 1 : end);
	return {
		{ start_line, utf16_len(content, lo.entries[start_line], start) },
		{ end_line, utf16_len(content, lo.entries[end_line], end) },
	};
}

// The LSP range of `tok`, where `lo` holds the line offsets of the text the token
// was lexed from. The token's own text is a slice of that text, so the line it
// starts on is read back through it; callers that only carry line offsets don't
// also need the content.
fn Range token_range(Token tok, LineOffsets* lo)
{
	sz line = lo.find_line(tok.offset);
	sz col = tok.offset - lo.entries[line];
	String before = (String)(tok.text.ptr - col)[:col];
	sz start = utf16_len(before, 0, col);
	sz end_line = line;
	sz end = start + utf16_len(tok.text, 0, tok.len);
	// A multi-line token (block comment, raw string) ends on a later line.
	if (try nl = tok.text.rindex_of_char('\n'))
	{
		end_line = lo.find_line(tok.offset + nl + 1);
		end = utf16_len(tok.text, nl + 1, tok.len);
	}
	return { { line, start }, { end_line, end } };
}
