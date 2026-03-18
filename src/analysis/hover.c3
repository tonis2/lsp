module lsp;

import std::core::dstring;
import std::core::mem;
import std::io::file;
import std::io::path;
import std::encoding::json;
import std::collections::object;
import c3::lexer;

fn void encode_hover(String uri, String content, usz offset, DocumentStore* docs, String stdlib_path, DString* out)
{
	LineOffsets* lo = mem::new(LineOffsets);
	defer mem::free(lo);
	build_line_offsets(content, lo);

	Lexer lex;
	lex.init(content);

	while (true)
	{
		if (try tok = lex.next())
		{
			usz tok_end = tok.offset + tok.len;
			if (tok.offset <= offset && offset < tok_end)
			{
				// For identifiers, try to find the declaration and extract doc comments
				TokenType ct = tok.type;
				if (ct == IDENT || ct == TYPE_IDENT || ct == CONST_IDENT)
				{
					DString doc = dstring::temp();
					find_hover_docs(uri, content, tok, docs, stdlib_path, &doc);

					if (doc.str_view().len > 0)
					{
						usz line = find_line(lo, tok.offset);
						usz start_char = tok.offset - lo.offsets[line];
						usz end_line = find_line(lo, tok_end > 0 ? tok_end - 1 : 0);
						usz end_char = tok_end - lo.offsets[end_line];

						out.append(`{"contents":{"kind":"markdown","value":"`);
						json_escape_into(out, doc.str_view());
						out.appendf(`"},"range":{"start":{"line":%d,"character":%d},"end":{"line":%d,"character":%d}}}`, line, start_char, end_line, end_char);
						return;
					}
				}

				// Fallback to basic token description
				String desc = get_token_description(tok.type, tok.text);
				if (desc.len == 0) return;

				usz line = find_line(lo, tok.offset);
				usz start_char = tok.offset - lo.offsets[line];
				usz end_line = find_line(lo, tok_end > 0 ? tok_end - 1 : 0);
				usz end_char = tok_end - lo.offsets[end_line];

				out.append(`{"contents":{"kind":"markdown","value":"`);
				json_escape_into(out, desc);
				out.appendf(`"},"range":{"start":{"line":%d,"character":%d},"end":{"line":%d,"character":%d}}}`, line, start_char, end_line, end_char);
				return;
			}
			if (tok.offset > offset) return;
		}
		else
		{
			if (lex.at_end()) break;
			lex.pos++;
			lex.col++;
		}
	}
}

// Search for the declaration of a token and extract its doc comment + signature.
// Searches: current file -> open documents -> project files -> stdlib.
fn void find_hover_docs(String uri, String content, Token cursor_tok, DocumentStore* docs, String stdlib_path, DString* out) @private
{
	// 1. Current file
	if (try_extract_docs_from(content, cursor_tok, out)) return;

	// 2. Open documents
	for (usz d = 0; d < docs.count; d++)
	{
		if (docs.docs[d].uri == uri) continue;
		if (try_extract_docs_from(docs.docs[d].content, cursor_tok, out)) return;
	}

	// 3. Project files on disk
	String file_path = uri_to_path(uri);
	if (file_path.len > 0)
	{
		if (scan_project_docs(file_path, cursor_tok, out)) return;
	}

	// 4. Stdlib
	if (stdlib_path.len > 0)
	{
		if (scan_dir_docs(stdlib_path, cursor_tok, out, 0)) return;
	}
}

// Tokenize content, find the declaration of target, and extract doc comment + signature.
fn bool try_extract_docs_from(String content, Token target, DString* out) @private
{
	Token[] tokens = mem::new_array(Token, DEF_MAX_TOKENS);
	defer mem::free(tokens);
	usz count = tokenize_content(content, tokens);

	usz decl_idx = find_decl_for_hover(tokens, count, target);
	if (decl_idx >= count) return false;

	extract_docs_at(content, tokens, count, decl_idx, out);
	return out.str_view().len > 0;
}

// Find the declaration index — similar to find_declaration but also checks same-name at cursor.
fn usz find_decl_for_hover(Token[] tokens, usz count, Token target) @private
{
	String name = target.text;

	switch (target.type)
	{
		case TYPE_IDENT:
			for (usz i = 0; i + 1 < count; i++)
			{
				if (is_type_declaration_keyword(tokens[i].type))
				{
					if (tokens[i + 1].type == TYPE_IDENT && tokens[i + 1].text == name)
					{
						return i + 1;
					}
				}
			}
		case CONST_IDENT:
			for (usz i = 0; i + 1 < count; i++)
			{
				if (tokens[i].type == CONSTDEF && tokens[i + 1].type == CONST_IDENT && tokens[i + 1].text == name)
				{
					return i + 1;
				}
			}
		case IDENT:
			// fn ... name(
			for (usz i = 0; i < count; i++)
			{
				if (tokens[i].type != FUNC) continue;
				for (usz j = i + 1; j < count && j < i + 64; j++)
				{
					if (tokens[j].type == LPAREN)
					{
						if (j > 0 && tokens[j - 1].type == IDENT && tokens[j - 1].text == name)
						{
							return j - 1;
						}
						break;
					}
					if (tokens[j].type == LBRACE || tokens[j].type == EOS) break;
				}
			}
			// macro name
			for (usz i = 0; i + 1 < count; i++)
			{
				if (tokens[i].type == MACRO && tokens[i + 1].type == IDENT && tokens[i + 1].text == name)
				{
					return i + 1;
				}
			}
		default:
			return count;
	}

	return count;
}

// Extract doc comment and signature from the declaration site.
fn void extract_docs_at(String content, Token[] tokens, usz count, usz decl_idx, DString* out) @private
{
	// Find the start of the declaration (fn, struct, macro, constdef, etc.)
	usz decl_start_idx = decl_idx;
	if (decl_idx > 0)
	{
		// Walk back to find the keyword that starts this declaration
		for (usz i = decl_idx; i > 0; i--)
		{
			TokenType t = tokens[i - 1].type;
			if (t == FUNC || t == MACRO || t == STRUCT || t == UNION || t == ENUM ||
				t == BITSTRUCT || t == INTERFACE || t == FAULTDEF || t == CONSTDEF ||
				t == TYPEDEF || t == ALIAS || t == ATTRDEF)
			{
				decl_start_idx = i - 1;
				break;
			}
			// Don't walk back past other declarations or braces
			if (t == RBRACE || t == EOS || t == LBRACE) break;
		}
	}

	// Extract the signature line from source
	usz sig_start = tokens[decl_start_idx].offset;
	// Find the end: up to '{' or ';' or end of token stream
	usz sig_end = sig_start;
	for (usz i = decl_start_idx; i < count; i++)
	{
		if (tokens[i].type == LBRACE || tokens[i].type == EOS)
		{
			sig_end = tokens[i].offset;
			break;
		}
		sig_end = tokens[i].offset + tokens[i].len;
	}
	// Trim trailing whitespace
	while (sig_end > sig_start && (content[sig_end - 1] == ' ' || content[sig_end - 1] == '\t' || content[sig_end - 1] == '\n' || content[sig_end - 1] == '\r'))
	{
		sig_end--;
	}
	String signature = content[sig_start:sig_end - sig_start];

	// Extract doc comments above the declaration
	DString comment = dstring::temp();
	if (decl_start_idx > 0)
	{
		// Collect comment tokens immediately before the declaration
		usz first_comment = decl_start_idx;
		for (usz i = decl_start_idx; i > 0; i--)
		{
			TokenType t = tokens[i - 1].type;
			if (t == LINE_COMMENT || t == BLOCK_COMMENT || t == CONTRACT)
			{
				first_comment = i - 1;
			}
			else
			{
				break;
			}
		}

		for (usz i = first_comment; i < decl_start_idx; i++)
		{
			if (tokens[i].type == LINE_COMMENT || tokens[i].type == BLOCK_COMMENT || tokens[i].type == CONTRACT)
			{
				String text = content[tokens[i].offset:tokens[i].len];
				String cleaned = strip_comment_markers(text);
				if (cleaned.len > 0)
				{
					if (comment.str_view().len > 0) comment.append("\n");
					comment.append(cleaned);
				}
			}
		}
	}

	// Build the hover content
	out.append("```c3\n");
	out.append(signature);
	out.append("\n```");

	if (comment.str_view().len > 0)
	{
		out.append("\n\n---\n\n");
		out.append(comment.str_view());
	}
}

// Strip comment markers (// or /* ... */) from a comment string.
fn String strip_comment_markers(String text) @private
{
	if (text.len >= 2 && text[0] == '/' && text[1] == '/')
	{
		String rest = text[2..];
		// Strip leading space
		if (rest.len > 0 && rest[0] == ' ') rest = rest[1..];
		// Trim trailing newline
		while (rest.len > 0 && (rest[rest.len - 1] == '\n' || rest[rest.len - 1] == '\r'))
		{
			rest = rest[:rest.len - 1];
		}
		return rest;
	}
	if (text.len >= 4 && text[0] == '/' && text[1] == '*')
	{
		// Remove /* and */
		String rest = text[2..];
		if (rest.len >= 2 && rest[rest.len - 2] == '*' && rest[rest.len - 1] == '/')
		{
			rest = rest[:rest.len - 2]; // Remove trailing */
		}
		// Trim whitespace
		while (rest.len > 0 && (rest[0] == ' ' || rest[0] == '\t' || rest[0] == '\n' || rest[0] == '\r'))
		{
			rest = rest[1..];
		}
		while (rest.len > 0 && (rest[rest.len - 1] == ' ' || rest[rest.len - 1] == '\t' || rest[rest.len - 1] == '\n' || rest[rest.len - 1] == '\r'))
		{
			rest = rest[:rest.len - 1];
		}
		return rest;
	}
	// Contract/doc comment: <* ... *>
	if (text.len >= 4 && text[0] == '<' && text[1] == '*')
	{
		// Remove <* and *>
		String rest = text[2..];
		if (rest.len >= 2 && rest[rest.len - 2] == '*' && rest[rest.len - 1] == '>')
		{
			rest = rest[:rest.len - 2];
		}
		// Trim leading/trailing whitespace
		while (rest.len > 0 && (rest[0] == ' ' || rest[0] == '\t' || rest[0] == '\n' || rest[0] == '\r'))
		{
			rest = rest[1..];
		}
		while (rest.len > 0 && (rest[rest.len - 1] == ' ' || rest[rest.len - 1] == '\t' || rest[rest.len - 1] == '\n' || rest[rest.len - 1] == '\r'))
		{
			rest = rest[:rest.len - 1];
		}
		return rest;
	}
	return text;
}

// Scan project dirs for hover docs (mirrors scan_project_files pattern).
fn bool scan_project_docs(String file_path, Token target, DString* out) @private
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

	if (project_root.len == 0) return false;

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
					if (item.is_string()) search_dirs[search_count++] = item.s;
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
							if (src[j] == '*') { dir_end = j; break; }
						}
						if (dir_end > 0 && src[dir_end - 1] == '/') dir_end--;
						if (dir_end > 0)
						{
							String src_dir = src[:dir_end];
							bool dup = false;
							for (usz k = 0; k < search_count; k++)
							{
								if (search_dirs[k] == src_dir) { dup = true; break; }
							}
							if (!dup) search_dirs[search_count++] = src_dir;
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
		if (scan_dir_docs(search_path.str_view(), target, out, 0)) return true;
	}
	return false;
}

fn bool scan_dir_docs(String dir_path, Token target, DString* out, int depth) @private
{
	if (depth > MAX_SCAN_DEPTH) return false;

	Path p;
	if (try pp = path::temp(dir_path)) { p = pp; } else { return false; }
	PathList entries;
	if (try el = path::ls(mem, p)) { entries = el; } else { return false; }
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
				defer mem::free(file_content);
				if (try_extract_docs_from((String)file_content, target, out)) return true;
			}
		}
		else
		{
			if (scan_dir_docs(full_path, target, out, depth + 1)) return true;
		}
	}
	return false;
}
