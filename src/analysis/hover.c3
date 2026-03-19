module lsp;

import std::core::dstring;
import std::core::mem;
import std::io::file;
import std::io::path;
import c3::lexer;

fn void encode_hover(String uri, String content, usz offset, DocumentList* docs, String stdlib_path, DString* out)
{
	LineOffsets lo;
	lo.init(mem);
	defer lo.free();
	build_line_offsets(content, &lo);

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
				if (is_ident(ct) || ct == TYPE_IDENT || ct == CONST_IDENT)
				{
					DString doc = dstring::temp();

					// Detect method call context for hover
					if (is_ident(ct))
					{
						TokenList hover_tokens;
						hover_tokens.init(mem);
						tokenize_content(content, &hover_tokens);
						Token hover_tok;
						usz hover_idx;
						if (find_token_at(&hover_tokens, offset, &hover_tok, &hover_idx))
						{
							String method_type = resolve_method_type(&hover_tokens, hover_idx, uri, docs);
							if (method_type.len > 0)
							{
								find_hover_docs(uri, content, tok, docs, stdlib_path, &doc, method_type);
							}
						}
						hover_tokens.free();
					}

					// Regular (non-method) hover if method resolution didn't find anything
					if (doc.str_view().len == 0)
					{
						find_hover_docs(uri, content, tok, docs, stdlib_path, &doc);
					}

					if (doc.str_view().len > 0)
					{
						usz line = find_line(&lo, tok.offset);
						usz start_char = tok.offset - lo.entries[line];
						usz end_line = find_line(&lo, tok_end > 0 ? tok_end - 1 : 0);
						usz end_char = tok_end - lo.entries[end_line];

						out.append(`{"contents":{"kind":"markdown","value":"`);
						json_escape_into(out, doc.str_view());
						out.appendf(`"},"range":{"start":{"line":%d,"character":%d},"end":{"line":%d,"character":%d}}}`, line, start_char, end_line, end_char);
						return;
					}
				}

				// Fallback to basic token description
				String desc = get_token_description(tok.type, tok.text);
				if (desc.len == 0) return;

				usz line = find_line(&lo, tok.offset);
				usz start_char = tok.offset - lo.entries[line];
				usz end_line = find_line(&lo, tok_end > 0 ? tok_end - 1 : 0);
				usz end_char = tok_end - lo.entries[end_line];

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
fn void find_hover_docs(String uri, String content, Token cursor_tok, DocumentList* docs, String stdlib_path, DString* out, String method_type = "") @private
{
	// If method type specified, try method-specific search first with each type candidate
	if (method_type.len > 0)
	{
		if (try_extract_docs_from(content, cursor_tok, out, method_type)) return;
		for (usz d = 0; d < docs.size; d++)
		{
			if (docs.entries[d].uri == uri) continue;
			if (try_extract_docs_from(docs.entries[d].content, cursor_tok, out, method_type)) return;
		}
		String file_path = uri_to_path(uri);
		if (file_path.len > 0)
		{
			if (scan_project_docs(file_path, cursor_tok, out, method_type)) return;
		}
		if (stdlib_path.len > 0)
		{
			if (scan_dir_docs(stdlib_path, cursor_tok, out, 0, method_type)) return;
		}
		return;
	}

	// 1. Current file
	if (try_extract_docs_from(content, cursor_tok, out)) return;

	// 2. Open documents
	for (usz d = 0; d < docs.size; d++)
	{
		if (docs.entries[d].uri == uri) continue;
		if (try_extract_docs_from(docs.entries[d].content, cursor_tok, out)) return;
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
fn bool try_extract_docs_from(String content, Token target, DString* out, String method_type = "") @private
{
	TokenList tokens;
	tokens.init(mem);
	defer tokens.free();
	tokenize_content(content, &tokens);

	usz decl_idx = find_declaration_in(&tokens, target, method_type);
	if (decl_idx >= tokens.size) return false;

	extract_docs_at(content, &tokens, decl_idx, out);
	return out.str_view().len > 0;
}

// Extract doc comment and signature from the declaration site.
fn void extract_docs_at(String content, TokenList* tokens, usz decl_idx, DString* out) @private
{
	// Find the start of the declaration (fn, struct, macro, constdef, etc.)
	usz decl_start_idx = decl_idx;
	if (decl_idx > 0)
	{
		// Walk back to find the keyword that starts this declaration
		for (usz i = decl_idx; i > 0; i--)
		{
			TokenType t = tokens.entries[i - 1].type;
			if (t == FUNC || t == MACRO || t == STRUCT || t == UNION || t == ENUM || t == BITSTRUCT || t == INTERFACE || t == FAULTDEF || t == CONSTDEF || t == TYPEDEF || t == ALIAS || t == ATTRDEF)
			{
				decl_start_idx = i - 1;
				break;
			}
			// Don't walk back past other declarations or braces
			if (t == RBRACE || t == EOS || t == LBRACE) break;
		}
	}

	// Extract the signature line from source
	usz sig_start = tokens.entries[decl_start_idx].offset;
	// Find the end: up to '{' or ';' or end of token stream
	usz sig_end = sig_start;
	for (usz i = decl_start_idx; i < tokens.size; i++)
	{
		if (tokens.entries[i].type == LBRACE || tokens.entries[i].type == EOS)
		{
			sig_end = tokens.entries[i].offset;
			break;
		}
		sig_end = tokens.entries[i].offset + tokens.entries[i].len;
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
			TokenType t = tokens.entries[i - 1].type;
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
			if (tokens.entries[i].type == LINE_COMMENT || tokens.entries[i].type == BLOCK_COMMENT || tokens.entries[i].type == CONTRACT)
			{
				String text = content[tokens.entries[i].offset:tokens.entries[i].len];
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
fn bool scan_project_docs(String file_path, Token target, DString* out, String method_type = "") @private
{
	ProjectDirs pdirs;
	get_project_search_dirs(file_path, &pdirs);
	if (pdirs.project_root.len == 0) return false;

	for (usz i = 0; i < pdirs.count; i++)
	{
		DString search_path = dstring::temp();
		search_path.appendf("%s/%s", pdirs.project_root, pdirs.dirs[i]);
		if (scan_dir_docs(search_path.str_view(), target, out, 0, method_type)) return true;
	}
	return false;
}

fn bool scan_dir_docs(String dir_path, Token target, DString* out, int depth, String method_type = "") @private
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
				if (try_extract_docs_from((String)file_content, target, out, method_type)) return true;
			}
		}
		else
		{
			if (scan_dir_docs(full_path, target, out, depth + 1, method_type)) return true;
		}
	}
	return false;
}
