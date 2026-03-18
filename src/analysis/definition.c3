module lsp;

import std::core::dstring;
import std::core::mem;
import std::io::file;
import std::io::path;
import std::encoding::json;
import std::collections::object;
import c3::lexer;

const usz DEF_MAX_TOKENS = 16384;

// Tokenize content into a heap-allocated token array. Caller must free.
fn usz tokenize_content(String content, Token[] tokens) {
	Lexer lex;
	lex.init(content);
	usz count = 0;
	while (count < tokens.len) {
		if (try tok = lex.next()) {
			tokens[count] = tok;
			count++;
		} else {
			if (lex.at_end()) break;
			lex.pos++;
			lex.col++;
		}
	}
	return count;
}

// Find the token at a byte offset in a token stream.
fn bool find_token_at(Token[] tokens, usz count, usz offset, Token* result, usz* idx) @private {
	for (usz i = 0; i < count; i++) {
		usz tok_end = tokens[i].offset + tokens[i].len;
		if (tokens[i].offset <= offset && offset < tok_end) {
			*result = tokens[i];
			*idx = i;
			return true;
		}
	}
	return false;
}

// Build a Location JSON for a token found in a file.
fn void emit_location(String uri, String content, Token tok, DString* out) @private {
	LineOffsets* lo = mem::new(LineOffsets);
	defer mem::free(lo);
	build_line_offsets(content, lo);

	usz line = find_line(lo, tok.offset);
	usz col = tok.offset - lo.offsets[line];
	usz end_col = col + tok.len;

	out.append(`{"uri":"`);
	json_escape_into(out, uri);
	out.appendf(`","range":{"start":{"line":%d,"character":%d},"end":{"line":%d,"character":%d}}}`, line, col, line, end_col);
}

// Encodes a go-to-definition / go-to-declaration response.
// Searches: current file -> open documents -> project files on disk -> stdlib.
fn void encode_definition(String uri, String content, usz offset, DocumentStore* docs, String stdlib_path, DString* out) {
	Token[] tokens = mem::new_array(Token, DEF_MAX_TOKENS);
	defer mem::free(tokens);
	usz token_count = tokenize_content(content, tokens);

	// Find the token at cursor
	Token cursor_tok;
	usz cursor_idx;
	if (!find_token_at(tokens, token_count, offset, &cursor_tok, &cursor_idx)) return;

	// Only navigate for identifier-like tokens
	TokenType ct = cursor_tok.type;
	if (ct != IDENT && ct != TYPE_IDENT && ct != CONST_IDENT) return;

	// 1. Search current file
	usz decl_idx = find_declaration(tokens[..token_count > 0 ? token_count - 1 : 0], token_count, cursor_tok, cursor_idx);
	if (decl_idx < token_count && decl_idx != cursor_idx) {
		emit_location(uri, content, tokens[decl_idx], out);
		return;
	}

	// 2. Search all other open documents
	for (usz d = 0; d < docs.count; d++) {
		if (docs.docs[d].uri == uri) continue;

		Token[] other_tokens = mem::new_array(Token, DEF_MAX_TOKENS);
		usz other_count = tokenize_content(docs.docs[d].content, other_tokens);

		usz found = find_declaration_in(other_tokens[..other_count > 0 ? other_count - 1 : 0], other_count, cursor_tok);
		if (found < other_count) {
			emit_location(docs.docs[d].uri, docs.docs[d].content, other_tokens[found], out);
			mem::free(other_tokens);
			return;
		}
		mem::free(other_tokens);
	}

	// 3. Scan project files on disk (src/ and lib/ relative to file)
	String file_path = uri_to_path(uri);
	if (file_path.len > 0) {
		if (try found = scan_project_files(file_path, cursor_tok, out)) {
			if (found) return;
		}
	}

	// 4. Scan stdlib path
	if (stdlib_path.len > 0) {
		if (scan_dir_recursive(stdlib_path, cursor_tok, out, 0)) {
			return;
		}
	}
}

// Search for a declaration in a token stream (not tied to a cursor position).
fn usz find_declaration_in(Token[] tokens, usz token_count, Token target) @private {
	return find_declaration(tokens, token_count, target, token_count); // pass impossible cursor_idx
}

// Searches for the declaration of a token in the token stream.
// Returns the index of the name token at the declaration site,
// or token_count if not found.
fn usz find_declaration(Token[] tokens, usz token_count, Token target, usz target_idx) @private {
	String name = target.text;

	switch (target.type) {
		case TYPE_IDENT:
			for (usz i = 0; i + 1 < token_count; i++) {
				TokenType kw = tokens[i].type;
				if (is_type_declaration_keyword(kw)) {
					if (tokens[i + 1].type == TYPE_IDENT && tokens[i + 1].text == name) {
						return i + 1;
					}
				}
			}
		case CONST_IDENT:
			// constdef NAME
			for (usz i = 0; i + 1 < token_count; i++) {
				if (tokens[i].type == CONSTDEF && tokens[i + 1].type == CONST_IDENT && tokens[i + 1].text == name) {
					return i + 1;
				}
			}
			// enum member: enum Foo { NAME, ... }
			for (usz i = 0; i + 1 < token_count; i++) {
				if (tokens[i].type != ENUM && tokens[i].type != FAULTDEF) continue;
				// Find the opening brace
				usz brace = i + 1;
				while (brace < token_count && tokens[brace].type != LBRACE) brace++;
				if (brace >= token_count) continue;
				// Scan enum body for matching CONST_IDENT
				usz depth = 1;
				for (usz j = brace + 1; j < token_count && depth > 0; j++) {
					if (tokens[j].type == LBRACE) { depth++; continue; }
					if (tokens[j].type == RBRACE) { depth--; continue; }
					if (depth == 1 && tokens[j].type == CONST_IDENT && tokens[j].text == name) {
						return j;
					}
				}
			}
		case IDENT:
			// fn ... name(
			for (usz i = 0; i < token_count; i++) {
				if (tokens[i].type != FUNC) continue;
				for (usz j = i + 1; j < token_count && j < i + 64; j++) {
					if (tokens[j].type == LPAREN) {
						if (j > 0 && tokens[j - 1].type == IDENT && tokens[j - 1].text == name) {
							return j - 1;
						}
						break;
					}
					if (tokens[j].type == LBRACE || tokens[j].type == EOS) break;
				}
			}
			// macro name
			for (usz i = 0; i + 1 < token_count; i++) {
				if (tokens[i].type == MACRO && tokens[i + 1].type == IDENT && tokens[i + 1].text == name) {
					return i + 1;
				}
			}
			// type IDENT = ...
			for (usz i = 0; i + 1 < token_count; i++) {
				if (is_type_token(tokens[i].type) && tokens[i + 1].type == IDENT && tokens[i + 1].text == name) {
					if (i + 2 < token_count) {
						TokenType next = tokens[i + 2].type;
						if (next == EQ || next == EOS || next == COMMA) {
							return i + 1;
						}
					}
				}
			}
		default:
			return token_count;
	}

	return token_count;
}

// Scan project directories for a declaration on disk.
// Reads project.json for dependency-search-paths and sources, then scans those dirs.
fn bool? scan_project_files(String file_path, Token target, DString* out) @private {
	// Find project root by looking for project.json
	String dir = parent_dir(file_path);
	String project_root = "";
	String check_dir = dir;
	char[]? project_json_data;
	for (int depth = 0; depth < 10; depth++) {
		if (check_dir.len == 0 || check_dir == "/") break;
		DString pj = dstring::temp();
		pj.appendf("%s/project.json", check_dir);
		if (try data = file::load(mem, pj.str_view())) {
			project_root = check_dir;
			project_json_data = data;
			break;
		}
		check_dir = parent_dir(check_dir);
	}

	if (project_root.len == 0) return false;

	// Parse project.json to find search paths
	const int MAX_SEARCH_DIRS = 32;
	String[MAX_SEARCH_DIRS] search_dirs;
	usz search_count = 0;

	if (try data = project_json_data) {
		defer mem::free(data);
		if (try pjson = json::tparse_string((String)data)) {
			// Extract dependency-search-paths (e.g. ["lib"])
			if (try deps = pjson.get("dependency-search-paths")) {
				usz deps_len = deps.get_len();
				for (usz i = 0; i < deps_len && search_count < MAX_SEARCH_DIRS; i++) {
					Object* item = deps.get_at(i);
					if (item == null) break;
					if (item.is_string()) {
						search_dirs[search_count++] = item.s;
					}
				}
			}

			// Extract source directories from sources (e.g. ["src/**"])
			if (try srcs = pjson.get("sources")) {
				usz srcs_len = srcs.get_len();
				for (usz i = 0; i < srcs_len && search_count < MAX_SEARCH_DIRS; i++) {
					Object* item = srcs.get_at(i);
					if (item == null) break;
					if (item.is_string()) {
						// Strip glob suffixes like /** or /*.c3
						String src = item.s;
						// Find the directory part before any glob
						usz dir_end = src.len;
						for (usz j = 0; j < src.len; j++) {
							if (src[j] == '*') {
								dir_end = j;
								break;
							}
						}
						// Remove trailing slash
						if (dir_end > 0 && src[dir_end - 1] == '/') dir_end--;
						if (dir_end > 0) {
							String src_dir = src[:dir_end];
							// Avoid duplicates
							bool dup = false;
							for (usz k = 0; k < search_count; k++) {
								if (search_dirs[k] == src_dir) { dup = true; break; }
							}
							if (!dup) {
								search_dirs[search_count++] = src_dir;
							}
						}
					}
				}
			}
		}
	}

	// Fallback if nothing was found in project.json
	if (search_count == 0) {
		search_dirs[0] = "src";
		search_dirs[1] = "lib";
		search_count = 2;
	}

	// Scan each search directory
	for (usz i = 0; i < search_count; i++) {
		DString search_path = dstring::temp();
		search_path.appendf("%s/%s", project_root, search_dirs[i]);
		if (scan_dir_recursive(search_path.str_view(), target, out, 0)) {
			return true;
		}
	}
	return false;
}

const int MAX_SCAN_DEPTH = 5;

fn bool scan_dir_recursive(String dir_path, Token target, DString* out, int depth) @private {
	if (depth > MAX_SCAN_DEPTH) return false;

	Path p;
	if (try pp = path::temp(dir_path)) {
		p = pp;
	} else {
		return false;
	}
	PathList entries;
	if (try el = path::ls(mem, p)) {
		entries = el;
	} else {
		// Not a directory or can't read — silently skip
		return false;
	}
	defer {
		foreach (&e : entries) e.free();
		entries.free();
	}

	foreach (entry : entries) {
		String entry_name = entry.str_view();
		// Build full path: dir_path/entry_name
		char[] path_buf = mem::new_array(char, dir_path.len + 1 + entry_name.len);
		defer mem::free(path_buf);
		path_buf[:dir_path.len] = dir_path[:dir_path.len];
		path_buf[dir_path.len] = '/';
		path_buf[dir_path.len + 1..] = entry_name[:entry_name.len];
		String full_path = (String)path_buf;

		if (entry_name.ends_with(".c3") || entry_name.ends_with(".c3i")) {
			// Read and tokenize this file
			if (try file_content = file::load(mem, full_path)) {
				String content = (String)file_content;
				Token[] tokens = mem::new_array(Token, DEF_MAX_TOKENS);
				usz count = tokenize_content(content, tokens);

				usz found = find_declaration_in(tokens[..count > 0 ? count - 1 : 0], count, target);
				if (found < count) {
					// Build file:// URI from path
					DString uri = dstring::temp();
					uri.appendf("file://%s", full_path);
					emit_location(uri.str_view(), content, tokens[found], out);
					mem::free(tokens);
					mem::free(file_content);
					return true;
				}
				mem::free(tokens);
				mem::free(file_content);
			}
		} else {
			// Try to recurse into subdirectories
			if (scan_dir_recursive(full_path, target, out, depth + 1)) {
				return true;
			}
		}
	}
	return false;
}

fn String parent_dir(String path) @private {
	if (path.len == 0) return "";
	usz end = path.len;
	// Remove trailing slash
	if (end > 1 && path[end - 1] == '/') end--;
	// Find last slash
	while (end > 0 && path[end - 1] != '/') {
		end--;
	}
	if (end == 0) return "";
	if (end == 1) return "/";
	return path[:end - 1];
}
