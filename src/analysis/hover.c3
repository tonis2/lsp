module lsp;

import std::core::dstring;
import std::core::mem;
import std::io::file;
import std::io::path;
import c3::lexer;

fn void encode_hover(String uri, String content, sz offset, DocumentList* docs, String stdlib_path, DString* out)
{
	LineOffsets lo;
	lo.init(mem);
	defer lo.free();
	lo.build(content);

	Lexer lex;
	lex.init(content);

	while (true)
	{
		if (try tok = lex.next())
		{
			sz tok_end = tok.offset + tok.len;
			if (tok.offset <= offset && offset < tok_end)
			{
				// For identifiers, try to find the declaration and extract doc comments
				TokenType ct = tok.type;
				if (is_ident(ct) || ct == TYPE_IDENT || ct == CONST_IDENT)
				{
					DString doc = dstring::temp();

					// Tokenize to get cursor index for DOT detection (reuse the open
					// document's cached token stream when available).
					TokenStream hover_owned;
					bool hover_owns;
					TokenStream* hover_stream = token_stream_for_doc(uri, content, docs, &hover_owned, &hover_owns);
					Token hover_tok;
					sz hover_idx;
					bool have_idx = hover_stream.tokens.find_token_at(offset, &hover_tok, &hover_idx);

					// Check if this is a DOT-preceded token (field/method access)
					bool is_member = have_idx && hover_idx > 0 && hover_stream.tokens.entries[hover_idx - 1].type == DOT;

					if (is_member && is_ident(ct))
					{
						// Resolve receiver type and search for method or struct field
						String recv_type = hover_stream.tokens.resolve_receiver_type(hover_idx, uri, docs);
						if (recv_type.len > 0)
						{
							// Try method docs with original type first (methods declared on alias name)
							find_hover_docs(uri, content, tok, docs, stdlib_path, &doc, recv_type);

							// Resolve alias for fallback
							String resolved_type = hover_stream.tokens.resolve_type_alias_across(recv_type, docs);
							if (resolved_type.len == 0)
							{
								String file_path = uri_to_path(uri);
								if (file_path.len > 0)
								{
									resolved_type = resolve_alias_in_project(file_path, recv_type);
								}
							}

							// Try method docs with resolved alias
							if (doc.str_view().len == 0 && resolved_type.len > 0 && resolved_type != recv_type)
							{
								find_hover_docs(uri, content, tok, docs, stdlib_path, &doc, resolved_type);
							}

							// Try struct field docs (use resolved alias for struct lookup)
							if (doc.str_view().len == 0)
							{
								String field_type = resolved_type.len > 0 ? resolved_type : recv_type;
								find_hover_field_docs(uri, content, field_type, tok.text, docs, stdlib_path, &doc);
								if (doc.str_view().len == 0 && field_type != recv_type)
								{
									find_hover_field_docs(uri, content, recv_type, tok.text, docs, stdlib_path, &doc);
								}
							}
						}
					}
					else
					{
						// Detect method call context for hover
						if (is_ident(ct) && have_idx)
						{
							String method_type = hover_stream.tokens.resolve_method_type(hover_idx, uri, docs);
							if (method_type.len > 0)
							{
								find_hover_docs(uri, content, tok, docs, stdlib_path, &doc, method_type);
							}
						}

						// Regular (non-method) hover if method resolution didn't find anything
						if (doc.str_view().len == 0)
						{
							find_hover_docs(uri, content, tok, docs, stdlib_path, &doc);
						}
					}
					if (hover_owns) hover_owned.free();

					if (doc.str_view().len > 0)
					{
						sz line = lo.find_line(tok.offset);
						sz start_char = tok.offset - lo.entries[line];
						sz end_line = lo.find_line(tok_end > 0 ? tok_end - 1 : 0);
						sz end_char = tok_end - lo.entries[end_line];

						Range range = {
							.start = {.line = line, .character = start_char},
							.end = {.line = end_line, .character = end_char},
						};
						encode_hover_response(out, doc.str_view(), range);
						return;
					}
				}

				// Fallback to basic token description
				String desc = get_token_description(tok.type, tok.text);
				if (desc.len == 0) return;

				sz line = lo.find_line(tok.offset);
				sz start_char = tok.offset - lo.entries[line];
				sz end_line = lo.find_line(tok_end > 0 ? tok_end - 1 : 0);
				sz end_char = tok_end - lo.entries[end_line];

				Range range = {
					.start = {.line = line, .character = start_char},
					.end = {.line = end_line, .character = end_char},
				};
				encode_hover_response(out, desc, range);
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
	// Cached token stream for the current document (reused across the searches below).
	TokenStream cur_owned;
	bool cur_owns;
	TokenStream* cur_stream = token_stream_for_doc(uri, content, docs, &cur_owned, &cur_owns);
	defer { if (cur_owns) cur_owned.free(); }

	// If method type specified, try method-specific search first with each type candidate
	if (method_type.len > 0)
	{
		if (try_extract_docs_from(content, cursor_tok, out, method_type, cur_stream)) return;
		for (sz d = 0; d < docs.size; d++)
		{
			if (docs.entries[d].uri == uri) continue;
			if (try_extract_docs_from(docs.entries[d].content, cursor_tok, out, method_type, docs.entries[d].get_tokens())) return;
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
	if (try_extract_docs_from(content, cursor_tok, out, "", cur_stream)) return;

	// 2. Open documents
	for (sz d = 0; d < docs.size; d++)
	{
		if (docs.entries[d].uri == uri) continue;
		if (try_extract_docs_from(docs.entries[d].content, cursor_tok, out, "", docs.entries[d].get_tokens())) return;
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

// Search for a struct field declaration and extract its doc comment + signature.
// Searches: current file -> open documents -> project files -> stdlib.
fn void find_hover_field_docs(String uri, String content, String type_name, String field_name, DocumentList* docs, String stdlib_path, DString* out) @private
{
	// Cached token stream for the current document.
	TokenStream cur_owned;
	bool cur_owns;
	TokenStream* cur_stream = token_stream_for_doc(uri, content, docs, &cur_owned, &cur_owns);
	defer { if (cur_owns) cur_owned.free(); }

	// 1. Current file
	if (try_extract_field_docs_from(content, type_name, field_name, out, cur_stream)) return;

	// 2. Open documents
	for (sz d = 0; d < docs.size; d++)
	{
		if (docs.entries[d].uri == uri) continue;
		if (try_extract_field_docs_from(docs.entries[d].content, type_name, field_name, out, docs.entries[d].get_tokens())) return;
	}

	// 3. Project files on disk
	String file_path = uri_to_path(uri);
	if (file_path.len > 0)
	{
		if (scan_project_field_docs(file_path, type_name, field_name, out)) return;
	}

	// 4. Stdlib
	if (stdlib_path.len > 0)
	{
		if (scan_dir_field_docs(stdlib_path, type_name, field_name, out, 0)) return;
	}
}

// Tokenize content, find a struct field declaration, and extract doc comment + signature.
fn bool try_extract_field_docs_from(String content, String type_name, String field_name, DString* out, TokenStream* cached = null) @private
{
	TokenStream owned;
	TokenStream* stream;
	if (cached != null) { stream = cached; }
	else { owned = token_stream_tokenize(content); stream = &owned; }
	defer { if (cached == null) owned.free(); }

	if (try found = stream.tokens.find_struct_field(type_name, field_name))
	{
		stream.tokens.extract_docs_at(content, found, out);
		return out.str_view().len > 0;
	}
	return false;
}

// Tokenize content, find the declaration of target, and extract doc comment + signature.
fn bool try_extract_docs_from(String content, Token target, DString* out, String method_type = "", TokenStream* cached = null) @private
{
	TokenStream owned;
	TokenStream* stream;
	if (cached != null) { stream = cached; }
	else { owned = token_stream_tokenize(content); stream = &owned; }
	defer { if (cached == null) owned.free(); }

	if (try decl_idx = stream.tokens.find_declaration_in(target, method_type))
	{
		stream.tokens.extract_docs_at(content, decl_idx, out);
		return out.str_view().len > 0;
	}
	return false;
}

// Extract doc comment and signature from the declaration site.
fn void TokenList.extract_docs_at(&self, String content, sz decl_idx, DString* out)
{
	// Find the start of the declaration (fn, struct, macro, constdef, etc.)
	sz decl_start_idx = decl_idx;
	if (decl_idx > 0)
	{
		// Walk back to find the keyword that starts this declaration
		for (sz i = decl_idx; i > 0; i--)
		{
			TokenType t = self.entries[i - 1].type;
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
	sz sig_start = self.entries[decl_start_idx].offset;
	// Find the end: up to '{' or ';' or end of token stream
	sz sig_end = sig_start;
	for (sz i = decl_start_idx; i < self.size; i++)
	{
		if (self.entries[i].type == LBRACE || self.entries[i].type == EOS)
		{
			sig_end = self.entries[i].offset;
			break;
		}
		sig_end = self.entries[i].offset + self.entries[i].len;
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
		sz first_comment = decl_start_idx;
		for (sz i = decl_start_idx; i > 0; i--)
		{
			TokenType t = self.entries[i - 1].type;
			if (t == LINE_COMMENT || t == BLOCK_COMMENT || t == CONTRACT)
			{
				first_comment = i - 1;
			}
			else
			{
				break;
			}
		}

		for (sz i = first_comment; i < decl_start_idx; i++)
		{
			if (self.entries[i].type == LINE_COMMENT || self.entries[i].type == BLOCK_COMMENT || self.entries[i].type == CONTRACT)
			{
				String text = content[self.entries[i].offset:self.entries[i].len];
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
	pdirs.get_search_dirs(file_path);
	if (pdirs.project_root.len == 0) return false;

	for (sz i = 0; i < pdirs.count; i++)
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
	if (try pp = path::tnew(dir_path))
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
		foreach (&e : entries) e.free(mem);
		entries.free();
	}

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
				bool found = try_extract_docs_from(fc, target, out, method_type, stream);
				if (owns) { owned.free(); mem::free((char*)fc.ptr); }
				if (found) return true;
			}
		}
		else
		{
			if (scan_dir_docs(full_path, target, out, depth + 1, method_type)) return true;
		}
	}
	return false;
}

// Scan project dirs for struct field hover docs.
fn bool scan_project_field_docs(String file_path, String type_name, String field_name, DString* out) @private
{
	ProjectDirs pdirs;
	pdirs.get_search_dirs(file_path);
	if (pdirs.project_root.len == 0) return false;

	for (sz i = 0; i < pdirs.count; i++)
	{
		DString search_path = dstring::temp();
		search_path.appendf("%s/%s", pdirs.project_root, pdirs.dirs[i]);
		if (scan_dir_field_docs(search_path.str_view(), type_name, field_name, out, 0)) return true;
	}
	return false;
}

fn bool scan_dir_field_docs(String dir_path, String type_name, String field_name, DString* out, int depth) @private
{
	if (depth > MAX_SCAN_DEPTH) return false;

	Path p;
	if (try pp = path::tnew(dir_path)) { p = pp; } else { return false; }
	PathList entries;


	if (try el = path::ls(mem, p)) { entries = el; } else { return false; }
	defer
	{
		foreach (&e : entries) e.free(mem);
		entries.free();
	}

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
				bool found = try_extract_field_docs_from(fc, type_name, field_name, out, stream);
				if (owns) { owned.free(); mem::free((char*)fc.ptr); }
				if (found) return true;
			}
		}
		else
		{
			if (scan_dir_field_docs(full_path, type_name, field_name, out, depth + 1)) return true;
		}
	}
	return false;
}
