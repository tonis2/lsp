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

// Strip // and /* */ comments from JSON, respecting quoted strings.
fn String strip_json_comments(String input) @private
{
	DString out = dstring::temp();
	usz i = 0;
	bool in_string = false;
	while (i < input.len)
	{
		char c = input[i];
		if (in_string)
		{
			if (c == '\\' && i + 1 < input.len)
			{
				out.append_char(c);
				out.append_char(input[i + 1]);
				i += 2;
				continue;
			}
			if (c == '"') in_string = false;
			out.append_char(c);
			i++;
		}
		else
		{
			if (c == '"')
			{
				in_string = true;
				out.append_char(c);
				i++;
			}
			else if (c == '/' && i + 1 < input.len && input[i + 1] == '/')
			{
				// Skip to end of line
				i += 2;
				while (i < input.len && input[i] != '\n') i++;
			}
			else if (c == '/' && i + 1 < input.len && input[i + 1] == '*')
			{
				// Skip to */
				i += 2;
				while (i + 1 < input.len && !(input[i] == '*' && input[i + 1] == '/')) i++;
				if (i + 1 < input.len) i += 2; // skip */
			}
			else
			{
				out.append_char(c);
				i++;
			}
		}
	}
	return out.str_view();
}

// Extract a directory from a source path and add it to search dirs.
// Handles globs ("src/**"), individual files ("./helpers/context.c3"), and plain dirs ("src").
fn void ProjectDirs.add_source_dir(&self, String src)
{
	if (self.count >= MAX_SEARCH_DIRS) return;

	usz dir_end = src.len;
	for (usz j = 0; j < src.len; j++)
	{
		if (src[j] == '*') { dir_end = j; break; }
	}
	if (dir_end > 0 && is_path_separator(src[dir_end - 1])) dir_end--;

	// If path ends with .c3 or .c3i, extract the parent directory
	if (dir_end >= 3)
	{
		String s = src[:dir_end];
		if (s.ends_with(".c3") || s.ends_with(".c3i"))
		{
			// Find last separator
			usz last_slash = 0;
			bool found_slash = false;
			for (usz j = s.len; j > 0; j--)
			{
				if (is_path_separator(s[j - 1])) { last_slash = j - 1; found_slash = true; break; }
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
	for (usz k = 0; k < self.count; k++)
	{
		if (self.dirs[k] == src_dir) return;
	}
	self.dirs[self.count++] = src_dir;
}

// Find project root and collect all search directories from project.json.
// Includes dependency-search-paths, sources dirs, and build/unpacked_c3l.
fn void ProjectDirs.get_search_dirs(&self, String file_path)
{
	self.project_root = "";
	self.count = 0;

	String check_dir = parent_dir(file_path);
	char[]? project_json_data;
	for (int depth = 0; depth < 10; depth++)
	{
		if (check_dir.len == 0 || check_dir == "/" || (is_windows_drive_path(check_dir) && check_dir.len == 3)) break;
		DString pj = dstring::temp();
		pj.appendf("%s/project.json", check_dir);
		if (try data = file::load(mem, pj.str_view()))
		{
			self.project_root = check_dir;
			project_json_data = data;
			break;
		}
		check_dir = parent_dir(check_dir);
	}

	if (self.project_root.len == 0) return;

	if (try data = project_json_data)
	{
		defer mem::free(data);
		String clean_json = strip_json_comments((String)data);
		if (try pjson = json::tparse_string(clean_json))
		{
			if (try deps = pjson.get("dependency-search-paths"))
			{
				usz deps_len = deps.get_len();
				for (usz i = 0; i < deps_len && self.count < MAX_SEARCH_DIRS; i++)
				{
					Object* item = deps.get_at(i);
					if (item == null) break;
					if (item.is_string()) self.dirs[self.count++] = item.s;
				}
			}
			if (try srcs = pjson.get("sources"))
			{
				usz srcs_len = srcs.get_len();
				for (usz i = 0; i < srcs_len && self.count < MAX_SEARCH_DIRS; i++)
				{
					Object* item = srcs.get_at(i);
					if (item == null) break;
					if (item.is_string())
					{
						String src = item.s;
						self.add_source_dir(src);
					}
				}
			}
			// Also collect sources from build targets (targets is a JSON object/map)
			if (try targets = pjson.get("targets"))
			{
				if (targets.is_map())
				{
					targets.map.@each(; String key, Object* tgt) {
						if (self.count >= MAX_SEARCH_DIRS) return;
						if (try tgt_srcs = tgt.get("sources"))
						{
							usz ts_len = tgt_srcs.get_len();
							for (usz i = 0; i < ts_len && self.count < MAX_SEARCH_DIRS; i++)
							{
								Object* item = tgt_srcs.get_at(i);
								if (item == null) break;
								if (item.is_string()) self.add_source_dir(item.s);
							}
						}
					};
				}
			}
		}
	}

	if (self.count == 0)
	{
		self.dirs[0] = "src";
		self.dirs[1] = "lib";
		self.count = 2;
	}

	// Always include unpacked c3l libraries
	if (self.count < MAX_SEARCH_DIRS)
	{
		self.dirs[self.count++] = "build/unpacked_c3l";
	}
}

// Tokenize content into a token list.
fn void TokenList.tokenize(&self, String content)
{
	Lexer lex;
	lex.init(content);
	while (true)
	{
		if (try tok = lex.next())
		{
			self.push(tok);
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
fn bool TokenList.find_token_at(&self, usz offset, Token* result, usz* idx)
{
	for (usz i = 0; i < self.size; i++)
	{
		usz tok_end = self.get(i).offset + self.get(i).len;
		if (self.get(i).offset <= offset && offset < tok_end)
		{
			*result = self.get(i);
			*idx = i;
			return true;
		}
	}
	// Retry with offset-1: cursor may be right after the token end
	// (editors place the cursor at one-past-the-end of a word)
	if (offset > 0)
	{
		usz adj = offset - 1;
		for (usz i = 0; i < self.size; i++)
		{
			usz tok_end = self.get(i).offset + self.get(i).len;
			if (self.get(i).offset <= adj && adj < tok_end)
			{
				*result = self.get(i);
				*idx = i;
				return true;
			}
		}
	}
	return false;
}

// Like find_token_at, but if the token at offset is a single-char punctuation
// (comma, paren, etc.), prefer the adjacent identifier token instead.
// This handles the case where editors place the cursor right after a word,
// landing on the following punctuation.
fn bool TokenList.find_ident_token_at(&self, usz offset, Token* result, usz* idx)
{
	Token tok;
	usz tok_idx;
	if (!self.find_token_at(offset, &tok, &tok_idx)) return false;

	// If we found an identifier-like token, use it directly
	if (is_ident(tok.type) || tok.type == TYPE_IDENT || tok.type == CONST_IDENT)
	{
		*result = tok;
		*idx = tok_idx;
		return true;
	}

	// Found punctuation — try offset-1 to find the preceding identifier
	if (offset > 0)
	{
		Token prev;
		usz prev_idx;
		if (self.find_token_at(offset - 1, &prev, &prev_idx))
		{
			if (is_ident(prev.type) || prev.type == TYPE_IDENT || prev.type == CONST_IDENT)
			{
				*result = prev;
				*idx = prev_idx;
				return true;
			}
		}
	}

	// Also try offset+1 for when cursor is on space before a word
	if (offset + 1 < self.entries[self.size - 1].offset + self.entries[self.size - 1].len)
	{
		Token next;
		usz next_idx;
		if (self.find_token_at(offset + 1, &next, &next_idx))
		{
			if (is_ident(next.type) || next.type == TYPE_IDENT || next.type == CONST_IDENT)
			{
				*result = next;
				*idx = next_idx;
				return true;
			}
		}
	}

	// Fall back to original token
	*result = tok;
	*idx = tok_idx;
	return true;
}

// Build a Location JSON for a token found in a file.
fn void emit_location(String uri, String content, Token tok, DString* out)
{
	LineOffsets lo;
	lo.init(mem);
	defer lo.free();
	lo.build(content);

	usz line = lo.find_line(tok.offset);
	usz col = tok.offset - lo.entries[line];
	usz end_col = col + tok.len;

	out.append(`{"uri":"`);
	json_escape_into(out, uri);
	out.appendf(`","range":{"start":{"line":%d,"character":%d},"end":{"line":%d,"character":%d}}}`, line, col, line, end_col);
}

// Find the type name of a variable by scanning for TYPE_IDENT var_name patterns.
fn String TokenList.find_variable_type(&self, String var_name)
{
	for (usz i = 0; i + 1 < self.size; i++)
	{
		if (self.get(i).type == TYPE_IDENT &&
			is_ident(self.entries[i + 1].type) && self.entries[i + 1].text == var_name)
		{
			if (i + 2 < self.size)
			{
				TokenType next = self.entries[i + 2].type;
				if (next == EOS || next == EQ || next == COMMA || next == DOT)
				{
					return self.get(i).text;
				}
			}
		}
	}
	return "";
}

// Resolve a type alias to its base type name.
// e.g. alias TokenList = List{Token} → "List"
fn String TokenList.resolve_type_alias(&self, String type_name)
{
	for (usz i = 0; i + 3 < self.size; i++)
	{
		if (self.get(i).type == ALIAS &&
			self.entries[i + 1].type == TYPE_IDENT && self.entries[i + 1].text == type_name &&
			self.entries[i + 2].type == EQ &&
			self.entries[i + 3].type == TYPE_IDENT)
		{
			return self.entries[i + 3].text;
		}
	}
	return "";
}

// Resolve a type alias searching current tokens + all open documents.
fn String TokenList.resolve_type_alias_across(&self, String type_name, DocumentList* docs)
{
	String resolved = self.resolve_type_alias(type_name);
	if (resolved.len > 0) return resolved;

	for (usz d = 0; d < docs.size; d++)
	{
		TokenList doc_tokens;
		doc_tokens.init(mem);
		doc_tokens.tokenize(docs.entries[d].content);
		resolved = doc_tokens.resolve_type_alias(type_name);
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
				tokens.tokenize((String)file_content);
				String resolved = tokens.resolve_type_alias(type_name);
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
	pdirs.get_search_dirs(file_path);
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
fn String TokenList.resolve_method_type(&self, usz cursor_idx, String uri, DocumentList* docs)
{
	if (cursor_idx < 2) return "";
	if (self.entries[cursor_idx - 1].type != DOT) return "";
	if (!is_ident(self.entries[cursor_idx - 2].type)) return "";

	String receiver_name = self.entries[cursor_idx - 2].text;
	String type_name = self.find_variable_type(receiver_name);
	if (type_name.len == 0) return "";

	String resolved = self.resolve_type_alias_across(type_name, docs);
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
fn bool TokenList.try_find_definition(
	&self, Token cursor_tok, usz cursor_idx,
	String uri, String content, DocumentList* docs, String stdlib_path,
	DString* out, String method_type = "")
{
	// 1. Search current file
	usz decl_idx = self.find_declaration(cursor_tok, cursor_idx, method_type);
	if (decl_idx < self.size && decl_idx != cursor_idx)
	{
		emit_location(uri, content, self.entries[decl_idx], out);
		return true;
	}

	// 2. Search all other open documents
	for (usz d = 0; d < docs.size; d++)
	{
		if (docs.entries[d].uri == uri) continue;

		TokenList other_tokens;
		other_tokens.init(mem);
		other_tokens.tokenize(docs.entries[d].content);

		usz found = other_tokens.find_declaration_in(cursor_tok, method_type);
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
	tokens.tokenize(content);

	// Find the token at cursor
	Token cursor_tok;
	usz cursor_idx;
	if (!tokens.find_token_at(offset, &cursor_tok, &cursor_idx)) return;

	// Only navigate for identifier-like tokens
	TokenType ct = cursor_tok.type;
	if (!is_ident(ct) && ct != TYPE_IDENT && ct != CONST_IDENT) return;

	// Method call resolution: variable.method(
	if (is_ident(ct))
	{
		String method_type = tokens.resolve_method_type(cursor_idx, uri, docs);
		if (method_type.len > 0)
		{
			if (tokens.try_find_definition(cursor_tok, cursor_idx, uri, content, docs, stdlib_path, out, method_type))
			{
				return;
			}
		}
	}

	// Regular search (non-method)
	tokens.try_find_definition(cursor_tok, cursor_idx, uri, content, docs, stdlib_path, out);
}

// Search for a declaration in a token stream (not tied to a cursor position).
fn usz TokenList.find_declaration_in(&self, Token target, String method_type = "")
{
	return self.find_declaration(target, self.size, method_type); // pass impossible cursor_idx
}

// Searches for the declaration of a token in the token stream.
// Returns the index of the name token at the declaration site,
// or self.size if not found.
// When method_type is non-empty, searches for fn Type.name( pattern only.
fn usz TokenList.find_declaration(&self, Token target, usz target_idx, String method_type = "")
{
	String name = target.text;

	switch (target.type)
	{
		case TYPE_IDENT:
			for (usz i = 0; i + 1 < self.size; i++)
			{
				TokenType kw = self.get(i).type;
				if (is_type_declaration_keyword(kw))
				{
					if (self.entries[i + 1].type == TYPE_IDENT && self.entries[i + 1].text == name)
					{
						return i + 1;
					}
				}
			}
		case CONST_IDENT:
			// constdef NAME
			for (usz i = 0; i + 1 < self.size; i++)
			{
				if (self.get(i).type == CONSTDEF && self.entries[i + 1].type == CONST_IDENT && self.entries[i + 1].text == name)
				{
					return i + 1;
				}
			}
			// const [Type] NAME = ...
			for (usz i = 0; i + 1 < self.size; i++)
			{
				if (self.get(i).type != CONST) continue;
				// const NAME = ... (no type)
				if (self.entries[i + 1].type == CONST_IDENT && self.entries[i + 1].text == name)
				{
					return i + 1;
				}
				// const Type NAME = ... (with type)
				if (i + 2 < self.size && is_type_token(self.entries[i + 1].type) && self.entries[i + 2].type == CONST_IDENT && self.entries[i + 2].text == name)
				{
					return i + 2;
				}
			}
			// enum member: enum Foo { NAME, ... }
			for (usz i = 0; i + 1 < self.size; i++)
			{
				if (self.get(i).type != ENUM && self.get(i).type != FAULTDEF) continue;
				// Find the opening brace
				usz brace = i + 1;
				while (brace < self.size && self.entries[brace].type != LBRACE) brace++;
				if (brace >= self.size) continue;
				// Scan enum body for matching CONST_IDENT
				usz depth = 1;
				for (usz j = brace + 1; j < self.size && depth > 0; j++)
				{
					if (self.entries[j].type == LBRACE)
					{
						depth++;
						continue;
					}
					if (self.entries[j].type == RBRACE)
					{
						depth--;
						continue;
					}
					if (depth == 1 && self.entries[j].type == CONST_IDENT && self.entries[j].text == name)
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
				for (usz i = 0; i < self.size; i++)
				{
					if (self.get(i).type != FUNC && self.get(i).type != MACRO) continue;
					for (usz j = i + 1; j < self.size && j < i + 64; j++)
					{
						if (self.entries[j].type == LPAREN)
						{
							if (j >= 3 &&
								is_ident(self.entries[j - 1].type) && self.entries[j - 1].text == name &&
								self.entries[j - 2].type == DOT &&
								self.entries[j - 3].type == TYPE_IDENT && self.entries[j - 3].text == method_type)
							{
								return j - 1;
							}
							break;
						}
						if (self.entries[j].type == LBRACE || self.entries[j].type == EOS) break;
					}
				}
				return self.size;
			}
			// fn ... name( or macro ... name(
			for (usz i = 0; i < self.size; i++)
			{
				if (self.get(i).type != FUNC && self.get(i).type != MACRO) continue;
				for (usz j = i + 1; j < self.size && j < i + 64; j++)
				{
					if (self.entries[j].type == LPAREN)
					{
						if (j > 0 && is_ident(self.entries[j - 1].type) && self.entries[j - 1].text == name)
						{
							return j - 1;
						}
						break;
					}
					if (self.entries[j].type == LBRACE || self.entries[j].type == EOS) break;
				}
			}
			// macro name (no parens)
			for (usz i = 0; i + 1 < self.size; i++)
			{
				if (self.get(i).type == MACRO && is_ident(self.entries[i + 1].type) && self.entries[i + 1].text == name)
				{
					return i + 1;
				}
			}
			// type IDENT = ...
			for (usz i = 0; i + 1 < self.size; i++)
			{
				if (is_type_token(self.get(i).type) && is_ident(self.entries[i + 1].type) && self.entries[i + 1].text == name)
				{
					if (i + 2 < self.size)
					{
						TokenType next = self.entries[i + 2].type;
						if (next == EQ || next == EOS || next == COMMA)
						{
							return i + 1;
						}
					}
				}
			}
		default:
			return self.size;
	}

	return self.size;
}

// Scan project directories for a declaration on disk.
fn bool? scan_project_files(String file_path, Token target, DString* out, String method_type = "") @private
{
	ProjectDirs pdirs;
	pdirs.get_search_dirs(file_path);
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
				tokens.tokenize(content);

				usz found = tokens.find_declaration_in(target, method_type);
				if (found < tokens.size)
				{
					// Build file:// URI from path
					DString uri = dstring::temp();
					append_file_uri(&uri, full_path);
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
	// Remove trailing separator
	if (end > 1 && is_path_separator(path[end - 1])) end--;
	// Find last separator
	while (end > 0 && !is_path_separator(path[end - 1]))
	{
		end--;
	}
	if (end == 0) return "";
	if (end == 1) return "/";
	// Don't strip the trailing / from a drive root like C:/
	if (end == 3 && is_windows_drive_path(path)) return path[:3];
	return path[:end - 1];
}
