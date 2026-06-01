module lsp;

import std::core::dstring;
import std::core::mem;
import std::io::file;
import std::io::path;
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
	"sz",
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

const sz MAX_DOC_IDENTS = 512;

fn void encode_completions(String uri, String content, sz offset, DocumentList* docs, String stdlib_path, DString* out)
{
	// Find prefix by scanning backwards from offset
	sz prefix_start = offset;
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

	// Check for DOT context: "foo." or "foo.ba" (partial member)
	bool is_dot_context = prefix_start > 0 && content[prefix_start - 1] == '.';

	// Check for module scope context: "args::" or "args::h" or "std::io::"
	String module_scope = "";
	bool is_scope_context = false;
	if (!is_dot_context && prefix_start >= 2 && content[prefix_start - 1] == ':' && content[prefix_start - 2] == ':')
	{
		// Scan backwards past "::" to find the module path (may include nested :: like std::io)
		sz mod_end = prefix_start - 2;
		sz mod_start = mod_end;
		while (mod_start > 0)
		{
			char c = content[mod_start - 1];
			if (is_ident_char(c) || c == ':')
			{
				mod_start--;
			}
			else
			{
				break;
			}
		}
		if (mod_start < mod_end)
		{
			module_scope = content[mod_start..mod_end - 1];
			is_scope_context = true;
		}
	}

	// Emit an explicit replacement range covering the typed prefix so the client
	// overwrites it instead of inserting after it. Without this, VS Code's default
	// "current word" range excludes leading $/@/# (e.g. "$str" + "$stringify" → "$$stringify").
	// prefix_start..offset never crosses a newline (the backward scan stops at non-ident chars).
	LineOffsets lo;
	lo.init(mem);
	defer lo.free();
	lo.build(content);
	sz cur_line   = lo.find_line(offset);
	sz line_start = lo.entries[cur_line];
	Range edit_range = {
		.start = { .line = cur_line, .character = prefix_start - line_start },
		.end   = { .line = cur_line, .character = offset - line_start },
	};

	// Emit editRange as an explicit InsertReplaceEdit ({insert, replace}) rather than a
	// bare Range. Both ranges are identical (prefix_start..cursor), but the insert/replace
	// form gives VS Code unambiguous edit semantics so completions still show when a
	// closing bracket sits right after the cursor (editor.autoClosingBrackets inserts one,
	// e.g. "foo(|)"). With a bare Range VS Code suppresses the popup in that position.
	out.append(`{"isIncomplete":false,"itemDefaults":{"editRange":{"insert":`);
	edit_range.encode(out);
	out.append(`,"replace":`);
	edit_range.encode(out);
	out.append(`}},"items":[`);
	bool first = true;

	if (is_dot_context)
	{
		collect_dot_completions(uri, content, offset, docs, stdlib_path, prefix, out, &first);
	}
	else if (is_scope_context)
	{
		collect_module_completions(uri, content, module_scope, prefix, docs, stdlib_path, out, &first);
	}
	else
	{
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

		// Document identifiers (current file + open docs + project files)
		collect_all_identifiers(uri, content, prefix, docs, stdlib_path, out, &first);
	}

	out.append("]}");
}

fn void emit_completion_item(DString* out, String label, int kind, bool* first) @private
{
	if (!*first) out.append_char(',');
	CompletionItem item = { .label = label, .kind = kind, };
	if (kind == 2 || kind == 3) // Method / Function (incl. macros)
	{
		// Insert "label($0)" as a snippet and trigger the parameter-hints popup so
		// accepting a callable drops the cursor inside the parens with signatures shown.
		// The label stays the plain name (filtering/display unchanged); only inserted text differs.
		item.insert_text = snippet_call_text(label);
		item.insert_text_format = 2; // Snippet
		item.trigger_signature_help = true;
	}
	item.encode(out);
	*first = false;
}

// Build a snippet insert text of the form "name($0)", backslash-escaping the snippet
// metacharacters $ } \ in the name (identifiers are normally safe; defensive only).
fn String snippet_call_text(String name) @private
{
	// Built in the request's temp pool (like mod_path elsewhere); the view stays valid
	// through item.encode and is released when the completion pool is freed.
	DString s = dstring::temp();
	foreach (c : name)
	{
		switch (c)
		{
			case '$':
			case '}':
			case '\\':
				s.append_char('\\');
				s.append_char(c);
			default:
				s.append_char(c);
		}
	}
	s.append("($0)");
	return s.str_view();
}

fn void emit_completion_item_detail(DString* out, String label, int kind, String detail, bool* first) @private
{
	if (!*first) out.append_char(',');
	CompletionItem item = { .label = label, .kind = kind, .detail = detail, };
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
	for (sz i = 0; i < prefix.len; i++)
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

// Module-scoped completion: "args::h" → only declarations from the args module starting with h
// The module_name may be a short name like "process" — resolve to full path via imports.
fn void collect_module_completions(String uri, String content, String module_name, String prefix, DocumentList* docs, String stdlib_path, DString* out, bool* first) @private
{
	String[MAX_DOC_IDENTS] seen;
	sz seen_count = 0;

	// Resolve short module name to full path via imports.
	// e.g. "process" → "std::os::process" if file has "import std::os::process;"
	String full_module = resolve_module_name(content, module_name);

	// 1. Search open documents for files declaring this module
	for (sz d = 0; d < docs.size; d++)
	{
		collect_declarations_from_content(docs.entries[d].content, prefix, out, first, &seen, &seen_count, docs.entries[d].get_tokens(), module_name, full_module);
	}

	// 2. Search project files on disk
	String file_path = uri_to_path(uri);
	if (file_path.len > 0)
	{
		ProjectDirs pdirs;
		pdirs.get_search_dirs(file_path);
		if (pdirs.project_root.len > 0)
		{
			for (sz i = 0; i < pdirs.count; i++)
			{
				DString search_path = dstring::temp();
				search_path.appendf("%s/%s", pdirs.project_root, pdirs.dirs[i]);
				scan_dir_module_decls(search_path.str_view(), module_name, full_module, prefix, out, first, &seen, &seen_count, 0);
			}
		}
	}

	// 3. Search stdlib
	if (stdlib_path.len > 0)
	{
		scan_dir_module_decls(stdlib_path, module_name, full_module, prefix, out, first, &seen, &seen_count, 0);
	}
}

// Collect only top-level declarations (functions, types, constants, macros) with proper kinds.
// When short_name/full_name are given, only declarations inside a matching `module` section
// are collected — a single C3 file may declare several modules (e.g. std/io/file.c3 opens with
// `module std::io;` and later `module std::io::file;`). When both are empty, collect from all.
fn void collect_declarations_from_content(String content, String prefix, DString* out, bool* first, String[MAX_DOC_IDENTS]* seen, sz* seen_count, TokenStream* cached = null, String short_name = "", String full_name = "") @private
{
	TokenStream owned;
	TokenStream* stream;
	if (cached != null) { stream = cached; }
	else { owned = token_stream_tokenize(content); stream = &owned; }
	defer { if (cached == null) owned.free(); }

	bool filter_module = short_name.len > 0 || full_name.len > 0;
	bool in_target = !filter_module; // when not filtering, everything is in scope

	for (sz i = 0; i < stream.tokens.size; i++)
	{
		TokenType tt = stream.tokens.entries[i].type;
		String name = "";
		int kind = 0;

		switch (tt)
		{
			case MODULE:
				// Track the current module section so later declarations are gated by it.
				if (filter_module)
				{
					DString mod_path = dstring::temp();
					bool first_part = true;
					for (sz j = i + 1; j < stream.tokens.size; j++)
					{
						TokenType jt = stream.tokens.entries[j].type;
						if (is_ident(jt) || jt == TYPE_IDENT || jt == CONST_IDENT)
						{
							if (!first_part) mod_path.append("::");
							mod_path.append(stream.tokens.entries[j].text);
							first_part = false;
						}
						else if (jt == SCOPE)
						{
							continue;
						}
						else
						{
							break;
						}
					}
					in_target = module_path_matches(mod_path.str_view(), short_name, full_name);
				}
				continue;
			case FUNC:
			case MACRO:
				// fn [RetType] name( or fn [RetType] Type.name(
				// Find the LPAREN and take the IDENT before it
				for (sz j = i + 1; j < stream.tokens.size && j < i + 64; j++)
				{
					if (stream.tokens.entries[j].type == LPAREN)
					{
						if (j > 0 && is_ident(stream.tokens.entries[j - 1].type))
						{
							// Skip methods (Type.name) — those are accessed via DOT, not module scope
							if (j >= 2 && stream.tokens.entries[j - 2].type == DOT) break;
							name = stream.tokens.entries[j - 1].text;
							kind = 3; // Function
						}
						break;
					}
					if (stream.tokens.entries[j].type == LBRACE || stream.tokens.entries[j].type == EOS) break;
				}
				// macro name (no parens)
				if (name.len == 0 && tt == MACRO && i + 1 < stream.tokens.size && is_ident(stream.tokens.entries[i + 1].type))
				{
					name = stream.tokens.entries[i + 1].text;
					kind = 3; // Function
				}
			case STRUCT:
			case BITSTRUCT:
			case UNION:
			case INTERFACE:
				if (i + 1 < stream.tokens.size && stream.tokens.entries[i + 1].type == TYPE_IDENT)
				{
					name = stream.tokens.entries[i + 1].text;
					kind = 22; // Struct
				}
			case ENUM:
			case FAULTDEF:
				if (i + 1 < stream.tokens.size && stream.tokens.entries[i + 1].type == TYPE_IDENT)
				{
					name = stream.tokens.entries[i + 1].text;
					kind = 13; // Enum
				}
			case ALIAS:
				if (i + 1 < stream.tokens.size && stream.tokens.entries[i + 1].type == TYPE_IDENT)
				{
					name = stream.tokens.entries[i + 1].text;
					kind = 22; // Struct (type alias)
				}
			case CONSTDEF:
				if (i + 1 < stream.tokens.size && stream.tokens.entries[i + 1].type == CONST_IDENT)
				{
					name = stream.tokens.entries[i + 1].text;
					kind = 21; // Constant
				}
			case CONST:
				// const [Type] NAME = ...
				if (i + 1 < stream.tokens.size)
				{
					if (stream.tokens.entries[i + 1].type == CONST_IDENT)
					{
						name = stream.tokens.entries[i + 1].text;
						kind = 21; // Constant
					}
					else if (i + 2 < stream.tokens.size && stream.tokens.entries[i + 2].type == CONST_IDENT)
					{
						name = stream.tokens.entries[i + 2].text;
						kind = 21; // Constant
					}
				}
			default:
				continue;
		}

		if (!in_target) continue; // declaration belongs to a non-matching module section
		if (name.len == 0 || kind == 0) continue;
		if (prefix.len > 0 && !starts_with_ci(name, prefix)) continue;
		if (name == prefix) continue;

		// Dedup
		bool dup = false;
		for (sz k = 0; k < *seen_count; k++)
		{
			if ((*seen)[k] == name) { dup = true; break; }
		}
		if (dup) continue;
		if (*seen_count < MAX_DOC_IDENTS)
		{
			(*seen)[*seen_count] = name;
			(*seen_count)++;
		}

		emit_completion_item(out, name, kind, first);
	}
}

// Resolve a short module name to its full path using imports.
// e.g. if content has "import std::os::process;" and module_name is "process",
// returns "std::os::process". Returns "" if no matching import found.
fn String resolve_module_name(String content, String module_name) @private
{
	String[MAX_IMPORTS] imports;
	sz import_count = parse_imports(content, &imports);

	for (sz i = 0; i < import_count; i++)
	{
		// Check if full path matches directly
		if (imports[i] == module_name) return imports[i];

		// Check if last segment matches (e.g. "process" matches "std::os::process")
		String last_seg = last_module_segment(imports[i]);
		if (last_seg == module_name) return imports[i];
	}
	return "";
}

// Extract the last segment of a module path: "std::os::process" → "process"
fn String last_module_segment(String mod_path) @private
{
	// Find last "::" and return everything after it
	sz last_colon = 0;
	bool found = false;
	for (sz i = 0; i + 1 < mod_path.len; i++)
	{
		if (mod_path[i] == ':' && mod_path[i + 1] == ':')
		{
			last_colon = i + 2;
			found = true;
		}
	}
	if (found && last_colon < mod_path.len)
	{
		return mod_path[last_colon..];
	}
	return mod_path;
}

// Does a declared module path match the requested module? Matches on the full path,
// the bare short name, or the last segment (e.g. "std::os::process" matches "process").
fn bool module_path_matches(String declared, String short_name, String full_name) @private
{
	if (declared == short_name) return true;
	if (full_name.len > 0 && declared == full_name) return true;
	if (last_module_segment(declared) == short_name) return true;
	return false;
}

// Scan directory recursively, collecting declarations from files that declare the given module.
// When short_name and full_name are both empty, collects from all files (for stdlib dir scanning).
fn void scan_dir_module_decls(String dir_path, String short_name, String full_name, String prefix, DString* out, bool* first, String[MAX_DOC_IDENTS]* seen, sz* seen_count, int depth) @private
{
	if (depth > COMPLETION_MAX_SCAN_DEPTH) return;
	if (*seen_count >= MAX_DOC_IDENTS) return;

	Path p;
	if (try pp = path::tnew(dir_path)) { p = pp; } else { return; }
	PathList entries;
	if (try el = path::ls(mem, p)) { entries = el; } else { return; }
	defer { foreach (&e : entries) e.free(mem); entries.free(); }

	foreach (entry : entries)
	{
		String entry_name = (String)entry;
		char[] path_buf = mem::new_array(char, dir_path.len + 1 + entry_name.len);
		defer mem::free(path_buf);
		path_buf[:dir_path.len] = dir_path[:dir_path.len];
		path_buf[dir_path.len] = '/';
		path_buf[dir_path.len + 1..] = entry_name[:entry_name.len];
		String full_path = (String)path_buf;

		if (entry_name.ends_with(".c3") || entry_name.ends_with(".c3i"))
		{
			TokenStream owned;
			String fc;
			bool owns;
			TokenStream* stream = file_token_stream(full_path, &owned, &fc, &owns);
			if (stream != null)
			{
				// collect_declarations_from_content gates by module section internally.
				collect_declarations_from_content(fc, prefix, out, first, seen, seen_count, stream, short_name, full_name);
				if (owns) { owned.free(); mem::free((char*)fc.ptr); }
			}
		}
		else
		{
			scan_dir_module_decls(full_path, short_name, full_name, prefix, out, first, seen, seen_count, depth + 1);
		}
	}
}

const sz MAX_IMPORTS = 32;

// Parse import statements from file content, returns module paths like "std::io", "c3::lexer"
fn sz parse_imports(String content, String[MAX_IMPORTS]* imports) @private
{
	Lexer lex;
	lex.init(content);
	sz count = 0;

	while (count < MAX_IMPORTS)
	{
		if (try tok = lex.next())
		{
			if (tok.type == IMPORT)
			{
				// Collect the module path: ident (SCOPE ident)*
				DString mod_path = dstring::temp();
				bool first_part = true;
				while (true)
				{
					if (try next = lex.next())
					{
						if (is_ident(next.type) || next.type == TYPE_IDENT || next.type == CONST_IDENT)
						{
							if (!first_part) mod_path.append("::");
							mod_path.append(next.text);
							first_part = false;
						}
						else if (next.type == SCOPE) // ::
						{
							continue;
						}
						else
						{
							break;
						}
					}
					else
					{
						if (lex.at_end()) break;
						lex.pos++;
						lex.col++;
						break;
					}
				}
				if (mod_path.len() > 0)
				{
					(*imports)[count] = mod_path.str_view();
					count++;
				}
			}
			// Stop after module-level declarations end (fn, struct, etc.)
			if (tok.type == FUNC || tok.type == STRUCT || tok.type == MACRO ||
				tok.type == BITSTRUCT || tok.type == UNION || tok.type == ENUM ||
				tok.type == FAULTDEF)
			{
				break;
			}
		}
		else
		{
			if (lex.at_end()) break;
			lex.pos++;
			lex.col++;
		}
	}
	return count;
}

// Convert a module path to a directory path: "std::io" → "std/io"
fn String module_to_dir_path(String mod_path, DString* buf) @private
{
	buf.clear();
	foreach (c : mod_path)
	{
		if (c == ':') continue; // skip both colons in ::
		buf.append_char(c);
	}
	// Replace remaining double-removed colons: "stdio" → need actual slashes
	// Actually, since we skip ':', "std::io" becomes "stdio" which is wrong.
	// Let's redo: replace "::" with "/"
	buf.clear();
	sz i = 0;
	while (i < mod_path.len)
	{
		if (i + 1 < mod_path.len && mod_path[i] == ':' && mod_path[i + 1] == ':')
		{
			buf.append_char('/');
			i += 2;
		}
		else
		{
			buf.append_char(mod_path[i]);
			i++;
		}
	}
	return buf.str_view();
}

// Collect identifiers from current file, open docs, project files, and imported stdlib modules
fn void collect_all_identifiers(String uri, String content, String prefix, DocumentList* docs, String stdlib_path, DString* out, bool* first) @private
{
	String[MAX_DOC_IDENTS] seen;
	sz seen_count = 0;

	// 1. Current file
	collect_idents_from_content(content, prefix, out, first, &seen, &seen_count);

	// Only search cross-file when there's a prefix (avoid flooding with every identifier)
	if (prefix.len == 0) return;

	// 2. Open documents
	for (sz d = 0; d < docs.size; d++)
	{
		if (docs.entries[d].uri == uri) continue;
		collect_idents_from_content(docs.entries[d].content, prefix, out, first, &seen, &seen_count);
	}

	// 3. Project files on disk
	String file_path = uri_to_path(uri);
	if (file_path.len > 0)
	{
		ProjectDirs pdirs;
		pdirs.get_search_dirs(file_path);
		if (pdirs.project_root.len > 0)
		{
			for (sz i = 0; i < pdirs.count; i++)
			{
				DString search_path = dstring::temp();
				search_path.appendf("%s/%s", pdirs.project_root, pdirs.dirs[i]);
				scan_dir_idents(search_path.str_view(), prefix, out, first, &seen, &seen_count, 0);
			}
		}
	}

	// 4. Imported stdlib modules
	if (stdlib_path.len > 0)
	{
		String[MAX_IMPORTS] imports;
		sz import_count = parse_imports(content, &imports);

		for (sz i = 0; i < import_count; i++)
		{
			// Strip "std::" prefix since stdlib_path already points to the std/ directory
			String mod = imports[i];
			if (mod.len > 5 && mod[:5] == "std::")
			{
				mod = mod[5..];
			}

			DString dir_buf = dstring::temp();
			String mod_dir = module_to_dir_path(mod, &dir_buf);

			DString full_dir = dstring::temp();
			full_dir.appendf("%s/%s", stdlib_path, mod_dir);
			scan_dir_idents(full_dir.str_view(), prefix, out, first, &seen, &seen_count, 0);
		}
	}
}

// Collect free function / macro declaration names from a token stream. Mirrors the
// FUNC/MACRO -> LPAREN -> preceding-IDENT logic in collect_declarations_from_content,
// so identifier completions can tag those names as callable (kind 3) and emit the
// "name($0)" snippet + parameter-hints command. Methods (Type.name) are skipped — they
// surface through the dot-completion path instead.
fn void collect_callable_names(TokenStream* stream, String[MAX_DOC_IDENTS]* names, sz* count) @private
{
	for (sz i = 0; i < stream.tokens.size; i++)
	{
		TokenType tt = stream.tokens.entries[i].type;
		if (tt != FUNC && tt != MACRO) continue;

		String name = "";
		for (sz j = i + 1; j < stream.tokens.size && j < i + 64; j++)
		{
			if (stream.tokens.entries[j].type == LPAREN)
			{
				if (j > 0 && is_ident(stream.tokens.entries[j - 1].type))
				{
					if (j >= 2 && stream.tokens.entries[j - 2].type == DOT) break; // method
					name = stream.tokens.entries[j - 1].text;
				}
				break;
			}
			if (stream.tokens.entries[j].type == LBRACE || stream.tokens.entries[j].type == EOS) break;
		}
		// macro name (no parens)
		if (name.len == 0 && tt == MACRO && i + 1 < stream.tokens.size && is_ident(stream.tokens.entries[i + 1].type))
		{
			name = stream.tokens.entries[i + 1].text;
		}
		if (name.len == 0) continue;

		bool dup = false;
		for (sz k = 0; k < *count; k++) { if ((*names)[k] == name) { dup = true; break; } }
		if (!dup && *count < MAX_DOC_IDENTS) { (*names)[*count] = name; (*count)++; }
	}
}

fn void collect_idents_from_content(String content, String prefix, DString* out, bool* first, String[MAX_DOC_IDENTS]* seen, sz* seen_count) @private
{
	TokenStream ts = token_stream_tokenize(content);
	defer ts.free();

	// Pre-pass: names declared as free functions/macros, so they complete as callables.
	String[MAX_DOC_IDENTS] callables;
	sz callable_count = 0;
	collect_callable_names(&ts, &callables, &callable_count);

	for (sz i = 0; i < ts.tokens.size; i++)
	{
		String text = ts.tokens.entries[i].text;
		int kind = 0;
		switch (ts.tokens.entries[i].type)
		{
			case IDENT:
				kind = 6; // Variable
				// Promote known free functions/macros to Function so they get the call snippet.
				for (sz k = 0; k < callable_count; k++)
				{
					if (callables[k] == text) { kind = 3; break; }
				}
			case TYPE_IDENT:
				kind = 22; // Struct (type)
			case CONST_IDENT:
				kind = 21; // Constant
			default:
				continue;
		}

		if (text.len == 0) continue;
		if (prefix.len > 0 && !starts_with_ci(text, prefix)) continue;

		// Skip if same as prefix (don't suggest what's already typed)
		if (text == prefix) continue;

		// Dedup with linear scan
		bool dup = false;
		for (sz j = 0; j < *seen_count; j++)
		{
			if ((*seen)[j] == text)
			{
				dup = true;
				break;
			}
		}
		if (dup) continue;

		if (*seen_count < MAX_DOC_IDENTS)
		{
			(*seen)[*seen_count] = text;
			(*seen_count)++;
		}

		emit_completion_item(out, text, kind, first);
	}
}

fn void scan_dir_idents(String dir_path, String prefix, DString* out, bool* first, String[MAX_DOC_IDENTS]* seen, sz* seen_count, int depth) @private
{
	if (depth > COMPLETION_MAX_SCAN_DEPTH) return;
	if (*seen_count >= MAX_DOC_IDENTS) return;

	Path p;
	if (try pp = path::tnew(dir_path)) { p = pp; } else { return; }
	PathList entries;
	if (try el = path::ls(mem, p)) { entries = el; } else { return; }
	defer { foreach (&e : entries) e.free(mem); entries.free(); }

	foreach (entry : entries)
	{
		String entry_name = (String)entry;
		char[] path_buf = mem::new_array(char, dir_path.len + 1 + entry_name.len);
		defer mem::free(path_buf);
		path_buf[:dir_path.len] = dir_path[:dir_path.len];
		path_buf[dir_path.len] = '/';
		path_buf[dir_path.len + 1..] = entry_name[:entry_name.len];
		String full_path = (String)path_buf;

		if (entry_name.ends_with(".c3") || entry_name.ends_with(".c3i"))
		{
			TokenStream owned;
			String fc;
			bool owns;
			TokenStream* stream = file_token_stream(full_path, &owned, &fc, &owns);
			if (stream != null)
			{
				collect_idents_from_content(fc, prefix, out, first, seen, seen_count);
				if (owns) { owned.free(); mem::free((char*)fc.ptr); }
			}
		}
		else
		{
			scan_dir_idents(full_path, prefix, out, first, seen, seen_count, depth + 1);
		}
	}
}

// DOT-expression completion: resolve receiver type and collect fields + methods
fn void collect_dot_completions(String uri, String content, sz offset, DocumentList* docs, String stdlib_path, String prefix, DString* out, bool* first) @private
{
	TokenStream owned;
	bool owns;
	TokenStream* stream = token_stream_for_doc(uri, content, docs, &owned, &owns);
	defer { if (owns) owned.free(); }

	// Find the token at cursor offset
	Token cursor_tok;
	sz cursor_idx;
	if (!stream.tokens.find_token_at(offset, &cursor_tok, &cursor_idx)) return;

	// If we landed on the DOT itself (cursor right after "foo."),
	// resolve_receiver_type expects cursor_idx to be the token AFTER the DOT
	if (cursor_tok.type == DOT)
	{
		cursor_idx = cursor_idx + 1;
	}

	// Resolve receiver type
	String recv_type = stream.tokens.resolve_receiver_type(cursor_idx, uri, docs);
	if (recv_type.len == 0) return;

	// Resolve alias (e.g. LineOffsets → List)
	String resolved_type = stream.tokens.resolve_type_alias_across(recv_type, docs);
	if (resolved_type.len == 0)
	{
		String file_path = uri_to_path(uri);
		if (file_path.len > 0)
		{
			resolved_type = resolve_alias_in_project(file_path, recv_type);
		}
	}

	String struct_type = resolved_type.len > 0 ? resolved_type : recv_type;

	String[MAX_DOC_IDENTS] seen;
	sz seen_count = 0;

	// Collect struct fields (use resolved alias for struct lookup)
	collect_struct_fields(struct_type, uri, content, docs, stdlib_path, prefix, out, first, &seen, &seen_count);
	// Also try unresolved name for struct fields
	if (struct_type != recv_type)
	{
		collect_struct_fields(recv_type, uri, content, docs, stdlib_path, prefix, out, first, &seen, &seen_count);
	}

	// Collect methods (try original alias name first, then resolved)
	collect_type_methods(recv_type, uri, content, docs, stdlib_path, prefix, out, first, &seen, &seen_count);
	if (resolved_type.len > 0 && resolved_type != recv_type)
	{
		collect_type_methods(resolved_type, uri, content, docs, stdlib_path, prefix, out, first, &seen, &seen_count);
	}

	// Collect enum members (Type.MEMBER) — for an enum/faultdef receiver
	collect_enum_members(recv_type, uri, content, docs, stdlib_path, prefix, out, first, &seen, &seen_count);
	if (resolved_type.len > 0 && resolved_type != recv_type)
	{
		collect_enum_members(resolved_type, uri, content, docs, stdlib_path, prefix, out, first, &seen, &seen_count);
	}
}

// Collect all struct fields matching prefix from a TokenList
fn void TokenList.collect_struct_fields_into(&self, String type_name, String prefix, DString* out, bool* first, String[MAX_DOC_IDENTS]* seen, sz* seen_count)
{
	for (sz i = 0; i + 1 < self.size; i++)
	{
		TokenType kw = self.entries[i].type;
		if (kw != STRUCT && kw != BITSTRUCT && kw != UNION) continue;
		if (self.entries[i + 1].type != TYPE_IDENT || self.entries[i + 1].text != type_name) continue;

		sz brace = i + 2;
		while (brace < self.size && self.entries[brace].type != LBRACE) brace++;
		if (brace >= self.size) continue;

		sz depth = 1;
		for (sz j = brace + 1; j < self.size && depth > 0; j++)
		{
			if (self.entries[j].type == LBRACE) { depth++; continue; }
			if (self.entries[j].type == RBRACE) { depth--; continue; }

			if (depth == 1 && is_ident(self.entries[j].type))
			{
				String field_name = self.entries[j].text;
				if (prefix.len > 0 && !starts_with_ci(field_name, prefix)) continue;

				// Dedup
				bool dup = false;
				for (sz k = 0; k < *seen_count; k++)
				{
					if ((*seen)[k] == field_name) { dup = true; break; }
				}
				if (dup) continue;
				if (*seen_count < MAX_DOC_IDENTS)
				{
					(*seen)[*seen_count] = field_name;
					(*seen_count)++;
				}

				// Get field type for detail
				String detail = "";
				if (j > 0 && self.entries[j - 1].type == TYPE_IDENT)
				{
					detail = self.entries[j - 1].text;
				}
				else if (j > 1 && self.entries[j - 1].type == STAR && self.entries[j - 2].type == TYPE_IDENT)
				{
					detail = self.entries[j - 2].text;
				}

				emit_completion_item_detail(out, field_name, 5, detail, first); // 5 = Field
			}
		}
	}
}

// Collect all methods matching prefix from a TokenList (fn Type.method_name( patterns)
fn void TokenList.collect_methods_into(&self, String type_name, String prefix, DString* out, bool* first, String[MAX_DOC_IDENTS]* seen, sz* seen_count)
{
	for (sz i = 0; i < self.size; i++)
	{
		if (self.entries[i].type != FUNC && self.entries[i].type != MACRO) continue;

		// Look for Type.method_name( pattern
		for (sz j = i + 1; j < self.size && j < i + 64; j++)
		{
			if (self.entries[j].type == LPAREN)
			{
				// Check for Type.name( pattern: [j-3]=TYPE_IDENT, [j-2]=DOT, [j-1]=IDENT
				if (j >= 3 && self.entries[j - 2].type == DOT
					&& self.entries[j - 3].type == TYPE_IDENT
					&& self.entries[j - 3].text == type_name
					&& is_ident(self.entries[j - 1].type))
				{
					String method_name = self.entries[j - 1].text;
					if (prefix.len > 0 && !starts_with_ci(method_name, prefix)) break;

					// Dedup
					bool dup = false;
					for (sz k = 0; k < *seen_count; k++)
					{
						if ((*seen)[k] == method_name) { dup = true; break; }
					}
					if (!dup)
					{
						if (*seen_count < MAX_DOC_IDENTS)
						{
							(*seen)[*seen_count] = method_name;
							(*seen_count)++;
						}
						emit_completion_item(out, method_name, 2, first); // 2 = Method
					}
				}
				break;
			}
			if (self.entries[j].type == LBRACE || self.entries[j].type == EOS) break;
		}
	}
}

// Collect enum/faultdef members matching prefix from a TokenList (enum Type { MEMBER, ... } patterns)
fn void TokenList.collect_enum_members_into(&self, String type_name, String prefix, DString* out, bool* first, String[MAX_DOC_IDENTS]* seen, sz* seen_count)
{
	for (sz i = 0; i + 1 < self.size; i++)
	{
		TokenType kw = self.entries[i].type;
		if (kw != ENUM && kw != FAULTDEF) continue;
		if (self.entries[i + 1].type != TYPE_IDENT || self.entries[i + 1].text != type_name) continue;

		sz brace = i + 2;
		while (brace < self.size && self.entries[brace].type != LBRACE) brace++;
		if (brace >= self.size) continue;

		// Members are the first CONST_IDENT after the opening brace or after each
		// top-level comma; the expect_member flag skips associated-value initializers
		// like `A = SOME_CONST`.
		sz depth = 1;
		bool expect_member = true;
		for (sz j = brace + 1; j < self.size && depth > 0; j++)
		{
			TokenType tt = self.entries[j].type;
			if (tt == LBRACE) { depth++; continue; }
			if (tt == RBRACE) { depth--; continue; }
			if (depth != 1) continue;
			if (tt == COMMA) { expect_member = true; continue; }
			if (!expect_member) continue;
			expect_member = false;

			if (tt != CONST_IDENT) continue;
			String member_name = self.entries[j].text;
			if (prefix.len > 0 && !starts_with_ci(member_name, prefix)) continue;

			// Dedup
			bool dup = false;
			for (sz k = 0; k < *seen_count; k++)
			{
				if ((*seen)[k] == member_name) { dup = true; break; }
			}
			if (dup) continue;
			if (*seen_count < MAX_DOC_IDENTS)
			{
				(*seen)[*seen_count] = member_name;
				(*seen_count)++;
			}

			emit_completion_item(out, member_name, 20, first); // 20 = EnumMember
		}
	}
}

// Collect struct fields across current file, open docs, project files, and stdlib
fn void collect_struct_fields(String type_name, String uri, String content, DocumentList* docs, String stdlib_path, String prefix, DString* out, bool* first, String[MAX_DOC_IDENTS]* seen, sz* seen_count) @private
{
	// 1. Current file
	{
		TokenStream owned;
		bool owns;
		TokenStream* stream = token_stream_for_doc(uri, content, docs, &owned, &owns);
		defer { if (owns) owned.free(); }
		stream.tokens.collect_struct_fields_into(type_name, prefix, out, first, seen, seen_count);
	}

	// 2. Open documents (reuse their cached token streams)
	for (sz d = 0; d < docs.size; d++)
	{
		if (docs.entries[d].uri == uri) continue;
		TokenStream* other_stream = docs.entries[d].get_tokens();
		other_stream.tokens.collect_struct_fields_into(type_name, prefix, out, first, seen, seen_count);
	}

	// 3. Project files on disk
	String file_path = uri_to_path(uri);
	if (file_path.len > 0)
	{
		ProjectDirs pdirs;
		pdirs.get_search_dirs(file_path);
		if (pdirs.project_root.len > 0)
		{
			for (sz i = 0; i < pdirs.count; i++)
			{
				DString search_path = dstring::temp();
				search_path.appendf("%s/%s", pdirs.project_root, pdirs.dirs[i]);
				scan_dir_fields(search_path.str_view(), type_name, prefix, out, first, seen, seen_count, 0);
			}
		}
	}

	// 4. Stdlib
	if (stdlib_path.len > 0)
	{
		scan_dir_fields(stdlib_path, type_name, prefix, out, first, seen, seen_count, 0);
	}
}

// Collect methods across current file, open docs, project files, and stdlib
fn void collect_type_methods(String type_name, String uri, String content, DocumentList* docs, String stdlib_path, String prefix, DString* out, bool* first, String[MAX_DOC_IDENTS]* seen, sz* seen_count) @private
{
	// 1. Current file
	{
		TokenStream owned;
		bool owns;
		TokenStream* stream = token_stream_for_doc(uri, content, docs, &owned, &owns);
		defer { if (owns) owned.free(); }
		stream.tokens.collect_methods_into(type_name, prefix, out, first, seen, seen_count);
	}

	// 2. Open documents (reuse their cached token streams)
	for (sz d = 0; d < docs.size; d++)
	{
		if (docs.entries[d].uri == uri) continue;
		TokenStream* other_stream = docs.entries[d].get_tokens();
		other_stream.tokens.collect_methods_into(type_name, prefix, out, first, seen, seen_count);
	}

	// 3. Project files on disk
	String file_path = uri_to_path(uri);
	if (file_path.len > 0)
	{
		ProjectDirs pdirs;
		pdirs.get_search_dirs(file_path);
		if (pdirs.project_root.len > 0)
		{
			for (sz i = 0; i < pdirs.count; i++)
			{
				DString search_path = dstring::temp();
				search_path.appendf("%s/%s", pdirs.project_root, pdirs.dirs[i]);
				scan_dir_methods(search_path.str_view(), type_name, prefix, out, first, seen, seen_count, 0);
			}
		}
	}

	// 4. Stdlib
	if (stdlib_path.len > 0)
	{
		scan_dir_methods(stdlib_path, type_name, prefix, out, first, seen, seen_count, 0);
	}
}

// Collect enum/faultdef members across current file, open docs, project files, and stdlib
fn void collect_enum_members(String type_name, String uri, String content, DocumentList* docs, String stdlib_path, String prefix, DString* out, bool* first, String[MAX_DOC_IDENTS]* seen, sz* seen_count) @private
{
	// 1. Current file
	{
		TokenStream owned;
		bool owns;
		TokenStream* stream = token_stream_for_doc(uri, content, docs, &owned, &owns);
		defer { if (owns) owned.free(); }
		stream.tokens.collect_enum_members_into(type_name, prefix, out, first, seen, seen_count);
	}

	// 2. Open documents (reuse their cached token streams)
	for (sz d = 0; d < docs.size; d++)
	{
		if (docs.entries[d].uri == uri) continue;
		TokenStream* other_stream = docs.entries[d].get_tokens();
		other_stream.tokens.collect_enum_members_into(type_name, prefix, out, first, seen, seen_count);
	}

	// 3. Project files on disk
	String file_path = uri_to_path(uri);
	if (file_path.len > 0)
	{
		ProjectDirs pdirs;
		pdirs.get_search_dirs(file_path);
		if (pdirs.project_root.len > 0)
		{
			for (sz i = 0; i < pdirs.count; i++)
			{
				DString search_path = dstring::temp();
				search_path.appendf("%s/%s", pdirs.project_root, pdirs.dirs[i]);
				scan_dir_enum_members(search_path.str_view(), type_name, prefix, out, first, seen, seen_count, 0);
			}
		}
	}

	// 4. Stdlib
	if (stdlib_path.len > 0)
	{
		scan_dir_enum_members(stdlib_path, type_name, prefix, out, first, seen, seen_count, 0);
	}
}

const int COMPLETION_MAX_SCAN_DEPTH = 5;

fn void scan_dir_fields(String dir_path, String type_name, String prefix, DString* out, bool* first, String[MAX_DOC_IDENTS]* seen, sz* seen_count, int depth) @private
{
	if (depth > COMPLETION_MAX_SCAN_DEPTH) return;

	Path p;
	if (try pp = path::tnew(dir_path)) { p = pp; } else { return; }
	PathList entries;
	if (try el = path::ls(mem, p)) { entries = el; } else { return; }
	defer { foreach (&e : entries) e.free(mem); entries.free(); }

	foreach (entry : entries)
	{
		String entry_name = (String)entry;
		char[] path_buf = mem::new_array(char, dir_path.len + 1 + entry_name.len);
		defer mem::free(path_buf);
		path_buf[:dir_path.len] = dir_path[:dir_path.len];
		path_buf[dir_path.len] = '/';
		path_buf[dir_path.len + 1..] = entry_name[:entry_name.len];
		String full_path = (String)path_buf;

		if (entry_name.ends_with(".c3") || entry_name.ends_with(".c3i"))
		{
			TokenStream owned;
			String fc;
			bool owns;
			TokenStream* stream = file_token_stream(full_path, &owned, &fc, &owns);
			if (stream != null)
			{
				stream.tokens.collect_struct_fields_into(type_name, prefix, out, first, seen, seen_count);
				if (owns) { owned.free(); mem::free((char*)fc.ptr); }
			}
		}
		else
		{
			scan_dir_fields(full_path, type_name, prefix, out, first, seen, seen_count, depth + 1);
		}
	}
}

fn void scan_dir_methods(String dir_path, String type_name, String prefix, DString* out, bool* first, String[MAX_DOC_IDENTS]* seen, sz* seen_count, int depth) @private
{
	if (depth > COMPLETION_MAX_SCAN_DEPTH) return;

	Path p;
	if (try pp = path::tnew(dir_path)) { p = pp; } else { return; }
	PathList entries;
	if (try el = path::ls(mem, p)) { entries = el; } else { return; }
	defer { foreach (&e : entries) e.free(mem); entries.free(); }

	foreach (entry : entries)
	{
		String entry_name = (String)entry;
		char[] path_buf = mem::new_array(char, dir_path.len + 1 + entry_name.len);
		defer mem::free(path_buf);
		path_buf[:dir_path.len] = dir_path[:dir_path.len];
		path_buf[dir_path.len] = '/';
		path_buf[dir_path.len + 1..] = entry_name[:entry_name.len];
		String full_path = (String)path_buf;

		if (entry_name.ends_with(".c3") || entry_name.ends_with(".c3i"))
		{
			TokenStream owned;
			String fc;
			bool owns;
			TokenStream* stream = file_token_stream(full_path, &owned, &fc, &owns);
			if (stream != null)
			{
				stream.tokens.collect_methods_into(type_name, prefix, out, first, seen, seen_count);
				if (owns) { owned.free(); mem::free((char*)fc.ptr); }
			}
		}
		else
		{
			scan_dir_methods(full_path, type_name, prefix, out, first, seen, seen_count, depth + 1);
		}
	}
}

fn void scan_dir_enum_members(String dir_path, String type_name, String prefix, DString* out, bool* first, String[MAX_DOC_IDENTS]* seen, sz* seen_count, int depth) @private
{
	if (depth > COMPLETION_MAX_SCAN_DEPTH) return;

	Path p;
	if (try pp = path::tnew(dir_path)) { p = pp; } else { return; }
	PathList entries;
	if (try el = path::ls(mem, p)) { entries = el; } else { return; }
	defer { foreach (&e : entries) e.free(mem); entries.free(); }

	foreach (entry : entries)
	{
		String entry_name = (String)entry;
		char[] path_buf = mem::new_array(char, dir_path.len + 1 + entry_name.len);
		defer mem::free(path_buf);
		path_buf[:dir_path.len] = dir_path[:dir_path.len];
		path_buf[dir_path.len] = '/';
		path_buf[dir_path.len + 1..] = entry_name[:entry_name.len];
		String full_path = (String)path_buf;

		if (entry_name.ends_with(".c3") || entry_name.ends_with(".c3i"))
		{
			TokenStream owned;
			String fc;
			bool owns;
			TokenStream* stream = file_token_stream(full_path, &owned, &fc, &owns);
			if (stream != null)
			{
				stream.tokens.collect_enum_members_into(type_name, prefix, out, first, seen, seen_count);
				if (owns) { owned.free(); mem::free((char*)fc.ptr); }
			}
		}
		else
		{
			scan_dir_enum_members(full_path, type_name, prefix, out, first, seen, seen_count, depth + 1);
		}
	}
}
