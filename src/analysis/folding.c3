module lsp;

import std::core::dstring;
import std::core::mem;
import c3::lexer;

const usz MAX_BRACE_DEPTH = 256;

fn void encode_folding_ranges(String content, DString* out)
{
	LineOffsets* lo = mem::new(LineOffsets);
	defer mem::free(lo);
	lo.build(content);

	Lexer lex;
	lex.init(content);

	// Brace stack for tracking { } folding
	usz[MAX_BRACE_DEPTH] brace_lines;
	usz brace_depth = 0;

	// Import tracking for consecutive imports
	usz import_start_line = 0;
	usz import_count = 0;
	usz last_import_line = 0;

	bool first = true;

	while (true)
	{
		if (try tok = lex.next())
		{
			usz line = lo.find_line(tok.offset);

			switch (tok.type)
			{
				case LBRACE:
					if (brace_depth < MAX_BRACE_DEPTH)
					{
						brace_lines[brace_depth] = line;
						brace_depth++;
					}
				case RBRACE:
					if (brace_depth > 0)
					{
						brace_depth--;
						usz start_line = brace_lines[brace_depth];
						if (start_line != line)
						{
							if (!first) out.append_char(',');
							FoldingRange fr = { .start_line = start_line, .end_line = line };
							fr.encode(out);
							first = false;
						}
					}
				case BLOCK_COMMENT:
				case CONTRACT:
					// Multi-line comment/contract folding
					usz end_offset = tok.offset + tok.len;
					usz end_line = lo.find_line(end_offset > 0 ? end_offset - 1 : 0);
					if (line != end_line)
					{
						if (!first) out.append_char(',');
						FoldingRange fr = { .start_line = line, .end_line = end_line, .kind = "comment" };
						fr.encode(out);
						first = false;
					}
				case IMPORT:
					// Track consecutive imports
					if (import_count == 0)
					{
						import_start_line = line;
						import_count = 1;
						last_import_line = line;
					}
					else if (line == last_import_line + 1 || line == last_import_line)
					{
						import_count++;
						last_import_line = line;
					}
					else
					{
						// Emit previous import range if 2+
						if (import_count >= 2)
						{
							if (!first) out.append_char(',');
							FoldingRange fr = { .start_line = import_start_line, .end_line = last_import_line, .kind = "imports" };
							fr.encode(out);
							first = false;
						}
						import_start_line = line;
						import_count = 1;
						last_import_line = line;
					}
				case EOS:
					// After a semicolon on a different line from last import, flush imports
					if (import_count > 0 && line == last_import_line)
					{
						// Still on the import line, keep going
					}
				default:
					// Non-import token on a new line — flush import range
					if (import_count > 0 && tok.type != EOS)
					{
						if (line > last_import_line)
						{
							if (import_count >= 2)
							{
								if (!first) out.append_char(',');
								FoldingRange fr = { .start_line = import_start_line, .end_line = last_import_line, .kind = "imports" };
								fr.encode(out);
								first = false;
							}
							import_count = 0;
						}
					}
			}
		}
		else
		{
			if (lex.at_end()) break;
			lex.pos++;
			lex.col++;
		}
	}

	// Flush trailing import range
	if (import_count >= 2)
	{
		if (!first) out.append_char(',');
		FoldingRange fr = { .start_line = import_start_line, .end_line = last_import_line, .kind = "imports" };
		fr.encode(out);
	}
}
