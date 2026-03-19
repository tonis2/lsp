module lsp;

import std::core::dstring;
import std::core::mem;
import std::io::file;
import std::io::path;
import std::encoding::json;
import std::collections::object;
import c3::lexer;

const int MAX_SEARCH_DIRS = 32;

struct ProjectDirs
{
	String project_root;
	String[MAX_SEARCH_DIRS] dirs;
	usz count;
}

// Extract a directory from a source path and add it to search dirs.
// Handles globs ("src/**"), individual files ("./helpers/context.c3"), and plain dirs ("src").
fn void add_source_dir(String src, ProjectDirs* result) @private
{
	if (result.count >= MAX_SEARCH_DIRS) return;

	usz dir_end = src.len;
	for (usz j = 0; j < src.len; j++)
	{
		if (src[j] == '*') { dir_end = j; break; }
	}
	if (dir_end > 0 && src[dir_end - 1] == '/') dir_end--;

	// If path ends with .c3 or .c3i, extract the parent directory
	if (dir_end >= 3)
	{
		String s = src[:dir_end];
		if (s.ends_with(".c3") || s.ends_with(".c3i"))
		{
			// Find last '/'
			usz last_slash = 0;
			bool found_slash = false;
			for (usz j = s.len; j > 0; j--)
			{
				if (s[j - 1] == '/') { last_slash = j - 1; found_slash = true; break; }
			}
			if (found_slash && last_slash > 0)
			{
				dir_end = last_slash;
			}
			else
			{
				// File in project root (e.g. "main.c3") — use "." as the dir
				src = ".";
				dir_end = 1;
			}
		}
	}

	if (dir_end == 0) return;
	String src_dir = src[:dir_end];

	// Dedup
	for (usz k = 0; k < result.count; k++)
	{
		if (result.dirs[k] == src_dir) return;
	}
	result.dirs[result.count++] = src_dir;
}

// Find project root and collect all search directories from project.json.
// Includes dependency-search-paths, sources dirs, and build/unpacked_c3l.
fn void get_project_search_dirs(String file_path, ProjectDirs* result)
{
	result.project_root = "";
	result.count = 0;

	String check_dir = parent_dir(file_path);
	char[]? project_json_data;
	for (int depth = 0; depth < 10; depth++)
	{
		if (check_dir.len == 0 || check_dir == "/") break;
		DString pj = dstring::temp();
		pj.appendf("%s/project.json", check_dir);
		if (try data = file::load(mem, pj.str_view()))
		{
			result.project_root = check_dir;
			project_json_data = data;
			break;
		}
		check_dir = parent_dir(check_dir);
	}

	if (result.project_root.len == 0) return;

	if (try data = project_json_data)
	{
		defer mem::free(data);
		if (try pjson = json::tparse_string((String)data))
		{
			if (try deps = pjson.get("dependency-search-paths"))
			{
				usz deps_len = deps.get_len();
				for (usz i = 0; i < deps_len && result.count < MAX_SEARCH_DIRS; i++)
				{
					Object* item = deps.get_at(i);
					if (item == null) break;
					if (item.is_string()) result.dirs[result.count++] = item.s;
				}
			}
			if (try srcs = pjson.get("sources"))
			{
				usz srcs_len = srcs.get_len();
				for (usz i = 0; i < srcs_len && result.count < MAX_SEARCH_DIRS; i++)
				{
					Object* item = srcs.get_at(i);
					if (item == null) break;
					if (item.is_string())
					{
						String src = item.s;
						add_source_dir(src, result);
					}
				}
			}
			// Also collect sources from build targets (targets is a JSON object/map)
			if (try targets = pjson.get("targets"))
			{
				if (targets.is_map())
				{
					targets.map.@each(; String key, Object* tgt) {
						if (result.count >= MAX_SEARCH_DIRS) return;
						if (try tgt_srcs = tgt.get("sources"))
						{
							usz ts_len = tgt_srcs.get_len();
							for (usz i = 0; i < ts_len && result.count < MAX_SEARCH_DIRS; i++)
							{
								Object* item = tgt_srcs.get_at(i);
								if (item == null) break;
								if (item.is_string()) add_source_dir(item.s, result);
							}
						}
					};
				}
			}
		}
	}

	if (result.count == 0)
	{
		result.dirs[0] = "src";
		result.dirs[1] = "lib";
		result.count = 2;
	}

	// Always include unpacked c3l libraries
	if (result.count < MAX_SEARCH_DIRS)
	{
		result.dirs[result.count++] = "build/unpacked_c3l";
	}
}

// Tokenize content into a token list.
fn void tokenize_content(String content, TokenList* tokens)
{
	Lexer lex;
	lex.init(content);
	while (true)
	{
		if (try tok = lex.next())
		{
			tokens.push(tok);
		}
		else
		{
			if (lex.at_end()) break;
			lex.pos++;
			lex.col++;
		}
	}
}

// Find the token at a byte offset in a token stream.
// If the offset lands between tokens (e.g. cursor at end of word),
// also checks offset-1 to match the preceding token.
fn bool find_token_at(TokenList* tokens, usz offset, Token* result, usz* idx)
{
	for (usz i = 0; i < tokens.size; i++)
	{
		usz tok_end = tokens.entries[i].offset + tokens.entries[i].len;
		if (tokens.entries[i].offset <= offset && offset < tok_end)
		{
			*result = tokens.entries[i];
			*idx = i;
			return true;
		}
	}
	// Retry with offset-1: cursor may be right after the token end
	if (offset > 0)
	{
		usz adj = offset - 1;
		for (usz i = 0; i < tokens.size; i++)
		{
			usz tok_end = tokens.entries[i].offset + tokens.entries[i].len;
			if (tokens.entries[i].offset <= adj && adj < tok_end)
			{
				*result = tokens.entries[i];
				*idx = i;
				return true;
			}
		}
	}
	return false;
}

// Build a Location JSON for a token found in a file.
fn void emit_location(String uri, String content, Token tok, DString* out)
{
	LineOffsets lo;
	lo.init(mem);
	defer lo.free();
	build_line_offsets(content, &lo);

	usz line = find_line(&lo, tok.offset);
	usz col = tok.offset - lo.entries[line];
	usz end_col = col + tok.len;

	out.append(`{"uri":"`);
	json_escape_into(out, uri);
	out.appendf(`","range":{"start":{"line":%d,"character":%d},"end":{"line":%d,"character":%d}}}`, line, col, line, end_col);
}

// Find the type name of a variable by scanning for TYPE_IDENT var_name patterns.
fn String find_variable_type(TokenList* tokens, String var_name) @private
{
	for (usz i = 0; i + 1 < tokens.size; i++)
	{
		if (tokens.entries[i].type == TYPE_IDENT &&
			is_ident(tokens.entries[i + 1].type) && tokens.entries[i + 1].text == var_name)
		{
			if (i + 2 < tokens.size)
			{
				TokenType next = tokens.entries[i + 2].type;
				if (next == EOS || next == EQ || next == COMMA || next == DOT)
				{
					return tokens.entries[i].text;
				}
			}
		}
	}
	return "";
}

// Resolve a type alias to its base type name.
// e.g. alias TokenList = List{Token} → "List"
fn String resolve_type_alias(TokenList* tokens, String type_name) @private
{
	for (usz i = 0; i + 3 < tokens.size; i++)
	{
		if (tokens.entries[i].type == ALIAS &&
			tokens.entries[i + 1].type == TYPE_IDENT && tokens.entries[i + 1].text == type_name &&
			tokens.entries[i + 2].type == EQ &&
			tokens.entries[i + 3].type == TYPE_IDENT)
		{
			return tokens.entries[i + 3].text;
		}
	}
	return "";
}

// Resolve a type alias searching current tokens + all open documents.
fn String resolve_type_alias_across(TokenList* tokens, String type_name, DocumentList* docs) @private
{
	String resolved = resolve_type_alias(tokens, type_name);
	if (resolved.len > 0) return resolved;

	for (usz d = 0; d < docs.size; d++)
	{
		TokenList doc_tokens;
		doc_tokens.init(mem);
		tokenize_content(docs.entries[d].content, &doc_tokens);
		resolved = resolve_type_alias(&doc_tokens, type_name);
		doc_tokens.free();
		if (resolved.len > 0) return resolved;
	}
	return "";
}

// Recursively scan a directory for an alias definition.
fn String resolve_alias_in_dir(String dir_path, String type_name, int depth) @private
{
	if (depth > MAX_SCAN_DEPTH) return "";

	Path p;
	if (try pp = path::temp(dir_path)) { p = pp; } else { return ""; }
	PathList entries;
	if (try el = path::ls(mem, p)) { entries = el; } else { return ""; }
	defer
	{
		foreach (&e : entries) e.free();
		entries.free();
	}

	foreach (entry : entries)
	{
		String entry_name = entry.str_view();
		char[] path_buf = mem::new_array(char, dir_path.len + 1 + entry_name.len);
		defer mem::free(path_buf);
		path_buf[:dir_path.len] = dir_path[:dir_path.len];
		path_buf[dir_path.len] = '/';
		path_buf[dir_path.len + 1..] = entry_name[:entry_name.len];
		String full_path = (String)path_buf;

		if (entry_name.ends_with(".c3") || entry_name.ends_with(".c3i"))
		{
			if (try file_content = file::load(mem, full_path))
			{
				TokenList tokens;
				tokens.init(mem);
				tokenize_content((String)file_content, &tokens);
				String resolved = resolve_type_alias(&tokens, type_name);
				if (resolved.len > 0)
				{
					// Copy before freeing — resolved points into file_content
					DString copy = dstring::temp();
					copy.append(resolved);
					tokens.free();
					mem::free(file_content);
					return copy.str_view();
				}
				tokens.free();
				mem::free(file_content);
			}
		}
		else
		{
			String resolved = resolve_alias_in_dir(full_path, type_name, depth + 1);
			if (resolved.len > 0) return resolved;
		}
	}
	return "";
}

// Resolve alias by scanning project files on disk.
fn String resolve_alias_in_project(String file_path, String type_name) @private
{
	ProjectDirs pdirs;
	get_project_search_dirs(file_path, &pdirs);
	if (pdirs.project_root.len == 0) return "";

	for (usz i = 0; i < pdirs.count; i++)
	{
		DString search_path = dstring::temp();
		search_path.appendf("%s/%s", pdirs.project_root, pdirs.dirs[i]);
		String resolved = resolve_alias_in_dir(search_path.str_view(), type_name, 0);
		if (resolved.len > 0) return resolved;
	}
	return "";
}

// Detect method call context (IDENT DOT IDENT) and resolve the receiver type.
// Returns the resolved type name (e.g. "List"), or empty string if not a method call.
fn String resolve_method_type(TokenList* tokens, usz cursor_idx, String uri, DocumentList* docs)
{
	if (cursor_idx < 2) return "";
	if (tokens.entries[cursor_idx - 1].type != DOT) return "";
	if (!is_ident(tokens.entries[cursor_idx - 2].type)) return "";

	String receiver_name = tokens.entries[cursor_idx - 2].text;
	String type_name = find_variable_type(tokens, receiver_name);
	if (type_name.len == 0) return "";

	String resolved = resolve_type_alias_across(tokens, type_name, docs);
	if (resolved.len == 0)
	{
		String file_path = uri_to_path(uri);
		if (file_path.len > 0)
		{
			resolved = resolve_alias_in_project(file_path, type_name);
		}
	}
	if (resolved.len > 0 && resolved != type_name) return resolved;
	return type_name;
}

// 4-step definition search: current file -> open docs -> project files -> stdlib.
// Returns true if a definition was found and emitted.
fn bool try_find_definition(
	TokenList* tokens, Token cursor_tok, usz cursor_idx,
	String uri, String content, DocumentList* docs, String stdlib_path,
	DString* out, String method_type = "") @private
{
	// 1. Search current file
	usz decl_idx = find_declaration(tokens, cursor_tok, cursor_idx, method_type);
	if (decl_idx < tokens.size && decl_idx != cursor_idx)
	{
		emit_location(uri, content, tokens.entries[decl_idx], out);
		return true;
	}

	// 2. Search all other open documents
	for (usz d = 0; d < docs.size; d++)
	{
		if (docs.entries[d].uri == uri) continue;

		TokenList other_tokens;
		other_tokens.init(mem);
		tokenize_content(docs.entries[d].content, &other_tokens);

		usz found = find_declaration_in(&other_tokens, cursor_tok, method_type);
		if (found < other_tokens.size)
		{
			emit_location(docs.entries[d].uri, docs.entries[d].content, other_tokens.entries[found], out);
			other_tokens.free();
			return true;
		}
		other_tokens.free();
	}

	// 3. Scan project files on disk (src/ and lib/ relative to file)
	String file_path = uri_to_path(uri);
	if (file_path.len > 0)
	{
		if (try found = scan_project_files(file_path, cursor_tok, out, method_type))
		{
			if (found) return true;
		}
	}

	// 4. Scan stdlib path
	if (stdlib_path.len > 0)
	{
		if (scan_dir_recursive(stdlib_path, cursor_tok, out, 0, method_type))
		{
			return true;
		}
	}

	return false;
}

// Encodes a go-to-definition / go-to-declaration response.
// Searches: current file -> open documents -> project files on disk -> stdlib.
fn void encode_definition(String uri, String content, usz offset, DocumentList* docs, String stdlib_path, DString* out)
{
	TokenList tokens;
	tokens.init(mem);
	defer tokens.free();
	tokenize_content(content, &tokens);

	// Find the token at cursor
	Token cursor_tok;
	usz cursor_idx;
	if (!find_token_at(&tokens, offset, &cursor_tok, &cursor_idx)) return;

	// Only navigate for identifier-like tokens
	TokenType ct = cursor_tok.type;
	if (!is_ident(ct) && ct != TYPE_IDENT && ct != CONST_IDENT) return;

	// Method call resolution: variable.method(
	if (is_ident(ct))
	{
		String method_type = resolve_method_type(&tokens, cursor_idx, uri, docs);
		if (method_type.len > 0)
		{
			if (try_find_definition(&tokens, cursor_tok, cursor_idx, uri, content, docs, stdlib_path, out, method_type))
			{
				return;
			}
		}
	}

	// Regular search (non-method)
	try_find_definition(&tokens, cursor_tok, cursor_idx, uri, content, docs, stdlib_path, out);
}

// Search for a declaration in a token stream (not tied to a cursor position).
fn usz find_declaration_in(TokenList* tokens, Token target, String method_type = "") @private
{
	return find_declaration(tokens, target, tokens.size, method_type); // pass impossible cursor_idx
}

// Searches for the declaration of a token in the token stream.
// Returns the index of the name token at the declaration site,
// or tokens.size if not found.
// When method_type is non-empty, searches for fn Type.name( pattern only.
fn usz find_declaration(TokenList* tokens, Token target, usz target_idx, String method_type = "") @private
{
	String name = target.text;

	switch (target.type)
	{
		case TYPE_IDENT:
			for (usz i = 0; i + 1 < tokens.size; i++)
			{
				TokenType kw = tokens.entries[i].type;
				if (is_type_declaration_keyword(kw))
				{
					if (tokens.entries[i + 1].type == TYPE_IDENT && tokens.entries[i + 1].text == name)
					{
						return i + 1;
					}
				}
			}
		case CONST_IDENT:
			// constdef NAME
			for (usz i = 0; i + 1 < tokens.size; i++)
			{
				if (tokens.entries[i].type == CONSTDEF && tokens.entries[i + 1].type == CONST_IDENT && tokens.entries[i + 1].text == name)
				{
					return i + 1;
				}
			}
			// enum member: enum Foo { NAME, ... }
			for (usz i = 0; i + 1 < tokens.size; i++)
			{
				if (tokens.entries[i].type != ENUM && tokens.entries[i].type != FAULTDEF) continue;
				// Find the opening brace
				usz brace = i + 1;
				while (brace < tokens.size && tokens.entries[brace].type != LBRACE) brace++;
				if (brace >= tokens.size) continue;
				// Scan enum body for matching CONST_IDENT
				usz depth = 1;
				for (usz j = brace + 1; j < tokens.size && depth > 0; j++)
				{
					if (tokens.entries[j].type == LBRACE)
					{
						depth++;
						continue;
					}
					if (tokens.entries[j].type == RBRACE)
					{
						depth--;
						continue;
					}
					if (depth == 1 && tokens.entries[j].type == CONST_IDENT && tokens.entries[j].text == name)
					{
						return j;
					}
				}
			}
		case IDENT:
		case AT_IDENT:
			if (method_type.len > 0)
			{
				// Search for fn ... Type.method( pattern only
				for (usz i = 0; i < tokens.size; i++)
				{
					if (tokens.entries[i].type != FUNC && tokens.entries[i].type != MACRO) continue;
					for (usz j = i + 1; j < tokens.size && j < i + 64; j++)
					{
						if (tokens.entries[j].type == LPAREN)
						{
							if (j >= 3 &&
								is_ident(tokens.entries[j - 1].type) && tokens.entries[j - 1].text == name &&
								tokens.entries[j - 2].type == DOT &&
								tokens.entries[j - 3].type == TYPE_IDENT && tokens.entries[j - 3].text == method_type)
							{
								return j - 1;
							}
							break;
						}
						if (tokens.entries[j].type == LBRACE || tokens.entries[j].type == EOS) break;
					}
				}
				return tokens.size;
			}
			// fn ... name( or macro ... name(
			for (usz i = 0; i < tokens.size; i++)
			{
				if (tokens.entries[i].type != FUNC && tokens.entries[i].type != MACRO) continue;
				for (usz j = i + 1; j < tokens.size && j < i + 64; j++)
				{
					if (tokens.entries[j].type == LPAREN)
					{
						if (j > 0 && is_ident(tokens.entries[j - 1].type) && tokens.entries[j - 1].text == name)
						{
							return j - 1;
						}
						break;
					}
					if (tokens.entries[j].type == LBRACE || tokens.entries[j].type == EOS) break;
				}
			}
			// macro name (no parens)
			for (usz i = 0; i + 1 < tokens.size; i++)
			{
				if (tokens.entries[i].type == MACRO && is_ident(tokens.entries[i + 1].type) && tokens.entries[i + 1].text == name)
				{
					return i + 1;
				}
			}
			// type IDENT = ...
			for (usz i = 0; i + 1 < tokens.size; i++)
			{
				if (is_type_token(tokens.entries[i].type) && is_ident(tokens.entries[i + 1].type) && tokens.entries[i + 1].text == name)
				{
					if (i + 2 < tokens.size)
					{
						TokenType next = tokens.entries[i + 2].type;
						if (next == EQ || next == EOS || next == COMMA)
						{
							return i + 1;
						}
					}
				}
			}
		default:
			return tokens.size;
	}

	return tokens.size;
}

// Scan project directories for a declaration on disk.
fn bool? scan_project_files(String file_path, Token target, DString* out, String method_type = "") @private
{
	ProjectDirs pdirs;
	get_project_search_dirs(file_path, &pdirs);
	if (pdirs.project_root.len == 0) return false;

	for (usz i = 0; i < pdirs.count; i++)
	{
		DString search_path = dstring::temp();
		search_path.appendf("%s/%s", pdirs.project_root, pdirs.dirs[i]);
		if (scan_dir_recursive(search_path.str_view(), target, out, 0, method_type))
		{
			return true;
		}
	}
	return false;
}

const int MAX_SCAN_DEPTH = 5;

fn bool scan_dir_recursive(String dir_path, Token target, DString* out, int depth, String method_type = "") @private
{
	if (depth > MAX_SCAN_DEPTH) return false;

	Path p;
	if (try pp = path::temp(dir_path))
	{
		p = pp;
	}
	else
	{
		return false;
	}
	PathList entries;
	if (try el = path::ls(mem, p))
	{
		entries = el;
	}
	else
	{
		// Not a directory or can't read — silently skip
		return false;
	}
	defer
	{
		foreach (&e : entries) e.free();
		entries.free();
	}

	foreach (entry : entries)
	{
		String entry_name = entry.str_view();
		// Build full path: dir_path/entry_name
		char[] path_buf = mem::new_array(char, dir_path.len + 1 + entry_name.len);
		defer mem::free(path_buf);
		path_buf[:dir_path.len] = dir_path[:dir_path.len];
		path_buf[dir_path.len] = '/';
		path_buf[dir_path.len + 1..] = entry_name[:entry_name.len];
		String full_path = (String)path_buf;

		if (entry_name.ends_with(".c3") || entry_name.ends_with(".c3i"))
		{
			// Read and tokenize this file
			if (try file_content = file::load(mem, full_path))
			{
				String content = (String)file_content;
				TokenList tokens;
				tokens.init(mem);
				tokenize_content(content, &tokens);

				usz found = find_declaration_in(&tokens, target, method_type);
				if (found < tokens.size)
				{
					// Build file:// URI from path
					DString uri = dstring::temp();
					uri.appendf("file://%s", full_path);
					emit_location(uri.str_view(), content, tokens.entries[found], out);
					tokens.free();
					mem::free(file_content);
					return true;
				}
				tokens.free();
				mem::free(file_content);
			}
		}
		else
		{
			// Try to recurse into subdirectories
			if (scan_dir_recursive(full_path, target, out, depth + 1, method_type))
			{
				return true;
			}
		}
	}
	return false;
}

fn String parent_dir(String path) @private
{
	if (path.len == 0) return "";
	usz end = path.len;
	// Remove trailing slash
	if (end > 1 && path[end - 1] == '/') end--;
	// Find last slash
	while (end > 0 && path[end - 1] != '/')
	{
		end--;
	}
	if (end == 0) return "";
	if (end == 1) return "/";
	return path[:end - 1];
}
