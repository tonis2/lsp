module lsp;

import std::core::dstring;
import std::core::mem;
import std::io::file;
import std::io::path;
import std::encoding::json;
import std::collections::object;
import c3::lexer;

// Encode document highlights (same-file occurrences of the symbol under cursor).
// Output: JSON array of DocumentHighlight objects, or empty string if none.
fn void encode_document_highlights(String content, usz offset, DString* out)
{
	Token[] tokens = mem::new_array(Token, DEF_MAX_TOKENS);
	defer mem::free(tokens);
	usz token_count = tokenize_content(content, tokens);

	Token cursor_tok;
	usz cursor_idx;
	if (!find_token_at(tokens, token_count, offset, &cursor_tok, &cursor_idx)) return;

	TokenType ct = cursor_tok.type;
	if (ct != IDENT && ct != TYPE_IDENT && ct != CONST_IDENT) return;

	LineOffsets* lo = mem::new(LineOffsets);
	defer mem::free(lo);
	build_line_offsets(content, lo);

	bool first = true;
	out.append("[");
	for (usz i = 0; i < token_count; i++)
	{
		if (tokens[i].type == ct && tokens[i].text == cursor_tok.text)
		{
			if (!first) out.append(",");
			first = false;

			usz line = find_line(lo, tokens[i].offset);
			usz col = tokens[i].offset - lo.offsets[line];
			usz end_col = col + tokens[i].len;

			out.appendf(`{"range":{"start":{"line":%d,"character":%d},"end":{"line":%d,"character":%d}},"kind":1}`, line, col, line, end_col);
		}
	}
	out.append("]");

	// If we only wrote "[]", clear output to signal nothing found
	if (first)
	{
		out.clear();
	}
}

// Encode references (cross-file occurrences of the symbol under cursor).
// Output: JSON array of Location objects, or empty string if none.
fn void encode_references(String uri, String content, usz offset, DocumentList* docs, String stdlib_path, bool include_decl, DString* out)
{
	Token[] tokens = mem::new_array(Token, DEF_MAX_TOKENS);
	defer mem::free(tokens);
	usz token_count = tokenize_content(content, tokens);

	Token cursor_tok;
	usz cursor_idx;
	if (!find_token_at(tokens, token_count, offset, &cursor_tok, &cursor_idx)) return;

	TokenType ct = cursor_tok.type;
	if (ct != IDENT && ct != TYPE_IDENT && ct != CONST_IDENT) return;

	bool first = true;
	out.append("[");

	// 1. Current file — collect all matching tokens
	collect_refs_in_tokens(uri, content, tokens, token_count, cursor_tok, out, &first);

	// 2. Open documents
	for (usz d = 0; d < docs.size; d++)
	{
		if (docs.entries[d].uri == uri) continue;

		Token[] other_tokens = mem::new_array(Token, DEF_MAX_TOKENS);
		usz other_count = tokenize_content(docs.entries[d].content, other_tokens);
		collect_refs_in_tokens(docs.entries[d].uri, docs.entries[d].content, other_tokens, other_count, cursor_tok, out, &first);
		mem::free(other_tokens);
	}

	// 3. Scan project files on disk
	String file_path = uri_to_path(uri);
	if (file_path.len > 0)
	{
		scan_project_files_refs(file_path, cursor_tok, out, &first);
	}

	// 4. Scan stdlib
	if (stdlib_path.len > 0)
	{
		scan_dir_recursive_refs(stdlib_path, cursor_tok, out, &first, 0);
	}

	out.append("]");

	if (first)
	{
		out.clear();
	}
}

// Collect all tokens matching target name+type from a pre-tokenized stream, emitting Location JSON.
fn void collect_refs_in_tokens(String uri, String content, Token[] tokens, usz count, Token target, DString* out, bool* first) @private
{
	LineOffsets* lo = mem::new(LineOffsets);
	defer mem::free(lo);
	build_line_offsets(content, lo);

	for (usz i = 0; i < count; i++)
	{
		if (tokens[i].type == target.type && tokens[i].text == target.text)
		{
			if (!*first) out.append(",");
			*first = false;

			usz line = find_line(lo, tokens[i].offset);
			usz col = tokens[i].offset - lo.offsets[line];
			usz end_col = col + tokens[i].len;

			out.append(`{"uri":"`);
			json_escape_into(out, uri);
			out.appendf(`","range":{"start":{"line":%d,"character":%d},"end":{"line":%d,"character":%d}}}`, line, col, line, end_col);
		}
	}
}

// Scan project directories for all references on disk.
fn void scan_project_files_refs(String file_path, Token target, DString* out, bool* first) @private
{
	String dir = parent_dir(file_path);
	String project_root = "";
	String check_dir = dir;
	char[]? project_json_data;
	for (int depth = 0; depth < 10; depth++)
	{
		if (check_dir.len == 0 || check_dir == "/") break;
		DString pj = dstring::temp();
		pj.appendf("%s/project.json", check_dir);
		if (try data = file::load(mem, pj.str_view()))
		{
			project_root = check_dir;
			project_json_data = data;
			break;
		}
		check_dir = parent_dir(check_dir);
	}

	if (project_root.len == 0) return;

	const int MAX_SEARCH_DIRS = 32;
	String[MAX_SEARCH_DIRS] search_dirs;
	usz search_count = 0;

	if (try data = project_json_data)
	{
		defer mem::free(data);
		if (try pjson = json::tparse_string((String)data))
		{
			if (try deps = pjson.get("dependency-search-paths"))
			{
				usz deps_len = deps.get_len();
				for (usz i = 0; i < deps_len && search_count < MAX_SEARCH_DIRS; i++)
				{
					Object* item = deps.get_at(i);
					if (item == null) break;
					if (item.is_string())
					{
						search_dirs[search_count++] = item.s;
					}
				}
			}

			if (try srcs = pjson.get("sources"))
			{
				usz srcs_len = srcs.get_len();
				for (usz i = 0; i < srcs_len && search_count < MAX_SEARCH_DIRS; i++)
				{
					Object* item = srcs.get_at(i);
					if (item == null) break;
					if (item.is_string())
					{
						String src = item.s;
						usz dir_end = src.len;
						for (usz j = 0; j < src.len; j++)
						{
							if (src[j] == '*')
							{
								dir_end = j;
								break;
							}
						}
						if (dir_end > 0 && src[dir_end - 1] == '/') dir_end--;
						if (dir_end > 0)
						{
							String src_dir = src[:dir_end];
							bool dup = false;
							for (usz k = 0; k < search_count; k++)
							{
								if (search_dirs[k] == src_dir)
								{
									dup = true;
									break;
								}
							}
							if (!dup)
							{
								search_dirs[search_count++] = src_dir;
							}
						}
					}
				}
			}
		}
	}

	if (search_count == 0)
	{
		search_dirs[0] = "src";
		search_dirs[1] = "lib";
		search_count = 2;
	}

	for (usz i = 0; i < search_count; i++)
	{
		DString search_path = dstring::temp();
		search_path.appendf("%s/%s", project_root, search_dirs[i]);
		scan_dir_recursive_refs(search_path.str_view(), target, out, first, 0);
	}
}

// Recursively scan directories for all references.
fn void scan_dir_recursive_refs(String dir_path, Token target, DString* out, bool* first, int depth) @private
{
	if (depth > MAX_SCAN_DEPTH) return;

	Path p;
	if (try pp = path::temp(dir_path))
	{
		p = pp;
	}
	else
	{
		return;
	}
	PathList entries;
	if (try el = path::ls(mem, p))
	{
		entries = el;
	}
	else
	{
		return;
	}
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
				String content = (String)file_content;
				Token[] tokens = mem::new_array(Token, DEF_MAX_TOKENS);
				usz count = tokenize_content(content, tokens);

				DString uri = dstring::temp();
				uri.appendf("file://%s", full_path);
				collect_refs_in_tokens(uri.str_view(), content, tokens, count, target, out, first);

				mem::free(tokens);
				mem::free(file_content);
			}
		}
		else
		{
			scan_dir_recursive_refs(full_path, target, out, first, depth + 1);
		}
	}
}
