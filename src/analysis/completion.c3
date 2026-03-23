module lsp;

import std::core::dstring;
import std::core::mem;
import c3::lexer;

const String[*] KEYWORDS = {
	"alias",
	"asm",
	"assert",
	"attrdef",
	"bitstruct",
	"break",
	"case",
	"catch",
	"const",
	"constdef",
	"continue",
	"default",
	"defer",
	"do",
	"else",
	"enum",
	"extern",
	"false",
	"faultdef",
	"fn",
	"for",
	"foreach",
	"foreach_r",
	"if",
	"import",
	"inline",
	"interface",
	"lengthof",
	"macro",
	"module",
	"nextcase",
	"null",
	"return",
	"static",
	"struct",
	"switch",
	"tlocal",
	"true",
	"try",
	"typedef",
	"union",
	"var",
	"while",
	};

const String[*] BUILTIN_TYPES = {
	"void",
	"bool",
	"char",
	"ichar",
	"short",
	"ushort",
	"int",
	"uint",
	"long",
	"ulong",
	"int128",
	"uint128",
	"float",
	"double",
	"float16",
	"bfloat16",
	"float128",
	"iptr",
	"uptr",
	"isz",
	"usz",
	"fault",
	"any",
	"typeid",
	};

const String[*] CT_KEYWORDS = {
	"$alignof",
	"$assert",
	"$assignable",
	"$case",
	"$default",
	"$defined",
	"$echo",
	"$else",
	"$endfor",
	"$endforeach",
	"$endif",
	"$endswitch",
	"$error",
	"$eval",
	"$evaltype",
	"$exec",
	"$extnameof",
	"$feature",
	"$for",
	"$foreach",
	"$if",
	"$is_const",
	"$include",
	"$kindof",
	"$nameof",
	"$offsetof",
	"$qnameof",
	"$sizeof",
	"$stringify",
	"$switch",
	"$typefrom",
	"$typeof",
	"$vaarg",
	"$vaconst",
	"$vacount",
	"$vaexpr",
	"$varef",
	"$vasplat",
	"$vatype",
	};

const usz MAX_DOC_IDENTS = 512;

fn void encode_completions(String content, usz offset, DString* out)
{
	// Find prefix by scanning backwards from offset
	usz prefix_start = offset;
	while (prefix_start > 0)
	{
		char c = content[prefix_start - 1];
		if (is_ident_char(c) || c == '$' || c == '@' || c == '#')
		{
			prefix_start--;
		}
		else
		{
			break;
		}
	}

	String prefix = "";
	if (offset > prefix_start)
	{
		prefix = content[prefix_start..offset - 1];
	}

	out.append(`{"isIncomplete":false,"items":[`);
	bool first = true;

	// Static keywords
	if (prefix.len == 0 || (prefix[0] != '$' && prefix[0] != '@' && prefix[0] != '#'))
	{
		foreach (kw : KEYWORDS)
		{
			if (prefix.len == 0 || starts_with_ci(kw, prefix))
			{
				emit_completion_item(out, kw, 14, &first); // Keyword
			}
		}
		foreach (bt : BUILTIN_TYPES)
		{
			if (prefix.len == 0 || starts_with_ci(bt, prefix))
			{
				emit_completion_item(out, bt, 22, &first); // Struct (for types)
			}
		}
	}

	// CT keywords when prefix starts with $
	if (prefix.len == 0 || prefix[0] == '$')
	{
		foreach (ct : CT_KEYWORDS)
		{
			if (prefix.len == 0 || starts_with_ci(ct, prefix))
			{
				emit_completion_item(out, ct, 14, &first); // Keyword
			}
		}
	}

	// Document identifiers
	collect_doc_identifiers(content, prefix, out, &first);

	out.append("]}");
}

fn void emit_completion_item(DString* out, String label, int kind, bool* first) @private
{
	if (!*first) out.append_char(',');
	CompletionItem item = {
		.label = label,
		.kind = kind,
	};
	item.encode(out);
	*first = false;
}

fn bool is_ident_char(char c) @private
{
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_';
}

fn bool starts_with_ci(String s, String prefix) @private
{
	if (prefix.len > s.len) return false;
	for (usz i = 0; i < prefix.len; i++)
	{
		char a = s[i];
		char b = prefix[i];
		// Simple lowercase for ASCII letters
		if (a >= 'A' && a <= 'Z') a += 32;
		if (b >= 'A' && b <= 'Z') b += 32;
		if (a != b) return false;
	}
	return true;
}

fn void collect_doc_identifiers(String content, String prefix, DString* out, bool* first) @private
{
	Lexer lex;
	lex.init(content);

	String[MAX_DOC_IDENTS] seen;
	usz seen_count = 0;

	while (true)
	{
		if (try tok = lex.next())
		{
			int kind = 0;
			switch (tok.type)
			{
				case IDENT:
					kind = 6; // Variable
				case TYPE_IDENT:
					kind = 22; // Struct (type)
				case CONST_IDENT:
					kind = 21; // Constant
				default:
					continue;
			}

			if (tok.text.len == 0) continue;
			if (prefix.len > 0 && !starts_with_ci(tok.text, prefix)) continue;

			// Skip if same as prefix (don't suggest what's already typed)
			if (tok.text == prefix) continue;

			// Dedup with linear scan
			bool dup = false;
			for (usz j = 0; j < seen_count; j++)
			{
				if (seen[j] == tok.text)
				{
					dup = true;
					break;
				}
			}
			if (dup) continue;

			if (seen_count < MAX_DOC_IDENTS)
			{
				seen[seen_count] = tok.text;
				seen_count++;
			}

			emit_completion_item(out, tok.text, kind, first);
		}
		else
		{
			if (lex.at_end()) break;
			lex.pos++;
			lex.col++;
		}
	}
}
