module lsp;

import std::core::dstring;
import std::core::mem;
import std::collections::list;
import c3::lexer;

const sz MAX_LOOKAHEAD = 64;
const sz MAX_SYMBOLS = 512;

struct SymbolEntry
{
	DocumentSymbol sym;
	String parent_type;  // For "Type.method", this is "Type"; empty otherwise
	bool is_child;
}

fn void encode_document_symbols(String content, DString* out, TokenStream* cached = null)
{
	TokenStream owned;
	TokenStream* stream;
	if (cached != null) { stream = cached; }
	else { owned = token_stream_tokenize(content); stream = &owned; }
	defer { if (cached == null) owned.free(); }
	LineOffsets* lo = stream.get_line_offsets();

	// Collect all symbols first. Heap-backed lists (not fixed stack arrays) so large
	// files aren't silently truncated at MAX_SYMBOLS and don't put ~130KB on the stack.
	List{SymbolEntry} syms;
	syms.init(mem);
	defer syms.free();

	for (sz i = 0; i < stream.tokens.size; i++)
	{
		Token tok = stream.tokens.entries[i];
		String name = "";
		String parent_type = "";
		int kind = 0;
		sz name_offset = 0;
		sz name_len = 0;
		sz decl_offset = tok.offset;
		sz end_offset = 0;
		bool has_braces = false;

		switch (tok.type)
		{
			case MODULE:
				// module IDENT (SCOPE IDENT)*  — capture the full scoped path
				if (i + 1 < stream.tokens.size && stream.tokens.entries[i + 1].type == IDENT)
				{
					Token first = stream.tokens.entries[i + 1];
					sz path_end = stream.tokens.scope_path_end(i + 1);
					push_module_symbol(&syms, lo, content,
						first.offset, path_end - first.offset, tok.offset,
						stream.tokens.find_eos_end(i + 2));
				}
				continue;
			case IMPORT:
				// import IDENT (SCOPE IDENT)* (COMMA IDENT (SCOPE IDENT)*)*
				// Full scoped paths, plus one symbol per comma-separated module.
				sz eos_end = stream.tokens.find_eos_end(i + 1);
				sz j = i + 1;
				while (j < stream.tokens.size && stream.tokens.entries[j].type == IDENT)
				{
					Token first = stream.tokens.entries[j];
					sz path_end = stream.tokens.scope_path_end(j);
					push_module_symbol(&syms, lo, content,
						first.offset, path_end - first.offset, tok.offset, eos_end);
					// advance past this path
					sz k = j + 1;
					while (k + 1 < stream.tokens.size
						&& stream.tokens.entries[k].type == SCOPE
						&& stream.tokens.entries[k + 1].type == IDENT) k += 2;
					// skip a separating comma, else stop
					if (k < stream.tokens.size && stream.tokens.entries[k].type == COMMA) { j = k + 1; }
					else { break; }
				}
				continue;
			case FUNC:
				// fn ... IDENT LPAREN — the IDENT before LPAREN is the name
				// If preceded by TYPE_IDENT DOT, it's a method
				sz lparen_idx = 0;
				for (sz j = i + 1; j < stream.tokens.size && j < i + MAX_LOOKAHEAD; j++)
				{
					if (stream.tokens.entries[j].type == LPAREN)
					{
						lparen_idx = j;
						break;
					}
					// Stop on LBRACE/EOS (malformed)
					if (stream.tokens.entries[j].type == LBRACE || stream.tokens.entries[j].type == EOS) break;
				}
				if (lparen_idx > 0 && lparen_idx > i + 1)
				{
					Token fn_name = stream.tokens.entries[lparen_idx - 1];
					if (is_ident(fn_name.type))
					{
						// Check for Type.method pattern
						if (lparen_idx >= 3 + i && stream.tokens.entries[lparen_idx - 2].type == DOT && stream.tokens.entries[lparen_idx - 3].type == TYPE_IDENT)
						{
							parent_type = stream.tokens.entries[lparen_idx - 3].text;
							name = fn_name.text;
							name_offset = fn_name.offset;
							name_len = fn_name.len;
							decl_offset = stream.tokens.entries[lparen_idx - 3].offset;
						}
						else
						{
							name = fn_name.text;
							name_offset = fn_name.offset;
							name_len = fn_name.len;
						}
						kind = 6; // Method for all functions, will be nested if has parent
						has_braces = true;
					}
				}
			case STRUCT:
			case UNION:
			case BITSTRUCT:
				// struct/union/bitstruct TYPE_IDENT
				if (i + 1 < stream.tokens.size && stream.tokens.entries[i + 1].type == TYPE_IDENT)
				{
					Token nt = stream.tokens.entries[i + 1];
					name = nt.text;
					name_offset = nt.offset;
					name_len = nt.len;
					kind = 23; // Struct
					has_braces = true;
				}
			case ENUM:
			case FAULTDEF:
				// enum/faultdef TYPE_IDENT
				if (i + 1 < stream.tokens.size && stream.tokens.entries[i + 1].type == TYPE_IDENT)
				{
					Token nt = stream.tokens.entries[i + 1];
					name = nt.text;
					name_offset = nt.offset;
					name_len = nt.len;
					kind = 10; // Enum
					has_braces = true;
				}
			case INTERFACE:
				// interface TYPE_IDENT
				if (i + 1 < stream.tokens.size && stream.tokens.entries[i + 1].type == TYPE_IDENT)
				{
					Token nt = stream.tokens.entries[i + 1];
					name = nt.text;
					name_offset = nt.offset;
					name_len = nt.len;
					kind = 11; // Interface
					has_braces = true;
				}
			case MACRO:
				// macro IDENT or macro TYPE_IDENT
				if (i + 1 < stream.tokens.size)
				{
					Token nt = stream.tokens.entries[i + 1];
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
				if (i + 1 < stream.tokens.size)
				{
					Token nt = stream.tokens.entries[i + 1];
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
						end_offset = stream.tokens.find_eos_end(i + 2);
					}
				}
			default:
				continue;
		}

		if (name.len == 0 || kind == 0) continue;

		// Find end of declaration for braced declarations
		if (has_braces && end_offset == 0)
		{
			end_offset = stream.tokens.find_brace_end(i + 1);
		}
		if (end_offset == 0)
		{
			end_offset = name_offset + name_len;
		}

		// Build range and selectionRange using line offsets
		sz decl_line = lo.find_line(decl_offset);
		sz decl_char = decl_offset - lo.entries[decl_line];
		sz end_line = lo.find_line(end_offset > 0 ? end_offset - 1 : 0);
		sz end_char = (end_offset > 0 ? end_offset : 1) - lo.entries[end_line];

		sz sel_line = lo.find_line(name_offset);
		sz sel_char = name_offset - lo.entries[sel_line];
		sz sel_end_line = sel_line;
		sz sel_end_char = sel_char + name_len;

		syms.push({
			.sym = {
				.name = name,
				.kind = kind,
				.range = {
					.start = {.line = decl_line, .character = decl_char},
					.end = {.line = end_line, .character = end_char},
				},
				.selection_range = {
					.start = {.line = sel_line, .character = sel_char},
					.end = {.line = sel_end_line, .character = sel_end_char},
				},
			},
			.parent_type = parent_type,
		});
	}

	// Second pass: nest methods under their parent type symbols.
	// Reserve the pool to the symbol count up front so it never reallocates — the
	// children slices assigned below point into its backing buffer and must stay valid
	// until the symbols are encoded. Total children across all parents <= syms.size.
	List{DocumentSymbol} children_pool;
	children_pool.init(mem, syms.size > 0 ? syms.size : 1);
	defer children_pool.free();

	for (sz i = 0; i < syms.size; i++)
	{
		int k = syms.entries[i].sym.kind;
		// Only types can have children (struct, enum, interface)
		if (k != 23 && k != 10 && k != 11) continue;
		String type_name = syms.entries[i].sym.name;

		sz start = children_pool.size;
		for (sz j = 0; j < syms.size; j++)
		{
			if (syms.entries[j].parent_type.len > 0 && syms.entries[j].parent_type == type_name)
			{
				children_pool.push(syms.entries[j].sym);
				syms.entries[j].is_child = true;
			}
		}

		if (children_pool.size > start)
		{
			syms.entries[i].sym.children = children_pool.entries[start..children_pool.size - 1];
		}
	}

	// Encode: output top-level symbols only
	bool first = true;
	for (sz i = 0; i < syms.size; i++)
	{
		if (syms.entries[i].is_child) continue;

		if (syms.entries[i].sym.kind == 6)
		{
			if (syms.entries[i].parent_type.len > 0)
			{
				// Orphan method (no matching struct in this file) — show as Type.method
				DString combined = dstring::temp();
				combined.append(syms.entries[i].parent_type);
				combined.append_char('.');
				combined.append(syms.entries[i].sym.name);
				syms.entries[i].sym.name = combined.str_view();
			}
			syms.entries[i].sym.kind = 12; // Function
		}

		if (!first) out.append_char(',');
		syms.entries[i].sym.encode(out);
		first = false;
	}
}

// Emit a Module (kind 2) symbol whose name is the full scoped path
// content[name_offset:name_len]. Mirrors the inline entry-build for other kinds.
fn void push_module_symbol(List{SymbolEntry}* syms, LineOffsets* lo, String content,
                           sz name_offset, sz name_len, sz decl_offset, sz end_offset)
{
	if (end_offset == 0) end_offset = name_offset + name_len;

	sz decl_line = lo.find_line(decl_offset);
	sz decl_char = decl_offset - lo.entries[decl_line];
	sz end_line  = lo.find_line(end_offset > 0 ? end_offset - 1 : 0);
	sz end_char  = (end_offset > 0 ? end_offset : 1) - lo.entries[end_line];
	sz sel_line  = lo.find_line(name_offset);
	sz sel_char  = name_offset - lo.entries[sel_line];

	syms.push({
		.sym = {
			.name = content[name_offset : name_len],
			.kind = 2, // Module
			.range = {
				.start = {.line = decl_line, .character = decl_char},
				.end   = {.line = end_line,  .character = end_char},
			},
			.selection_range = {
				.start = {.line = sel_line, .character = sel_char},
				.end   = {.line = sel_line, .character = sel_char + name_len},
			},
		},
	});
}

// Given the index of the first IDENT of a module path, walk (IDENT (SCOPE IDENT)*)
// and return the end offset (offset+len) of the LAST IDENT in the path.
fn sz TokenList.scope_path_end(&self, sz first_ident_idx)
{
	sz last = first_ident_idx;
	sz j = first_ident_idx + 1;
	while (j + 1 < self.size
		&& self.entries[j].type == SCOPE
		&& self.entries[j + 1].type == IDENT)
	{
		last = j + 1;
		j += 2;
	}
	return self.entries[last].offset + self.entries[last].len;
}

fn sz TokenList.find_eos_end(&self, sz start)
{
	for (sz j = start; j < self.size; j++)
	{
		if (self.entries[j].type == EOS)
		{
			return self.entries[j].offset + self.entries[j].len;
		}
	}
	return 0;
}

fn sz TokenList.find_brace_end(&self, sz start)
{
	sz depth = 0;
	bool found_brace = false;
	for (sz j = start; j < self.size; j++)
	{
		if (self.entries[j].type == LBRACE)
		{
			depth++;
			found_brace = true;
		}
		else if (self.entries[j].type == RBRACE)
		{
			if (depth > 0) depth--;
			if (depth == 0 && found_brace)
			{
				return self.entries[j].offset + self.entries[j].len;
			}
		}
	}
	return 0;
}
