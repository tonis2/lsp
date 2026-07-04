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

						// Regular (non-method) hover if method resolution didn't find anything.
						// If the token was written module-qualified (`foo::bar`), restrict the
						// doc search to that module to disambiguate same-named symbols.
						if (doc.str_view().len == 0)
						{
							String module_filter = "";
							if (have_idx)
							{
								String mod_prefix = hover_stream.tokens.resolve_module_prefix(hover_idx);
								if (mod_prefix.len > 0)
								{
									module_filter = resolve_module_name(content, mod_prefix);
									if (module_filter.len == 0) module_filter = mod_prefix;
								}
							}
							find_hover_docs(uri, content, tok, docs, stdlib_path, &doc, "", module_filter);
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
fn void find_hover_docs(String uri, String content, Token cursor_tok, DocumentList* docs, String stdlib_path, DString* out, String method_type = "", String module_filter = "") @private
{
	// Cached token stream for the current document (reused across the searches below).
	TokenStream cur_owned;
	bool cur_owns;
	TokenStream* cur_stream = token_stream_for_doc(uri, content, docs, &cur_owned, &cur_owns);
	defer { if (cur_owns) cur_owned.free(); }

	// If method type specified, try method-specific search first with each type candidate
	if (method_type.len > 0)
	{
		if (try_extract_docs_from(content, cursor_tok, out, method_type, cur_stream, module_filter)) return;
		for (sz d = 0; d < docs.size; d++)
		{
			if (docs.entries[d].uri == uri) continue;
			if (try_extract_docs_from(docs.entries[d].content, cursor_tok, out, method_type, docs.entries[d].get_tokens(), module_filter)) return;
		}
		String file_path = uri_to_path(uri);
		DocsScan scan = { cursor_tok, method_type, module_filter, out };
		scan_project_then_stdlib(file_path, stdlib_path, &scan);
		return;
	}

	// 1. Current file
	if (try_extract_docs_from(content, cursor_tok, out, "", cur_stream, module_filter)) return;

	// 2. Open documents
	for (sz d = 0; d < docs.size; d++)
	{
		if (docs.entries[d].uri == uri) continue;
		if (try_extract_docs_from(docs.entries[d].content, cursor_tok, out, "", docs.entries[d].get_tokens(), module_filter)) return;
	}

	// 3 + 4. Project files on disk, then stdlib
	String file_path = uri_to_path(uri);
	DocsScan scan = { cursor_tok, "", module_filter, out };
	scan_project_then_stdlib(file_path, stdlib_path, &scan);
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

	// 3 + 4. Project files on disk, then stdlib
	String file_path = uri_to_path(uri);
	FieldDocsScan scan = { type_name, field_name, out };
	scan_project_then_stdlib(file_path, stdlib_path, &scan);
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
fn bool try_extract_docs_from(String content, Token target, DString* out, String method_type = "", TokenStream* cached = null, String module_filter = "") @private
{
	TokenStream owned;
	TokenStream* stream;
	if (cached != null) { stream = cached; }
	else { owned = token_stream_tokenize(content); stream = &owned; }
	defer { if (cached == null) owned.free(); }

	if (try decl_idx = stream.tokens.find_declaration_in(target, method_type, module_filter))
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

// On-disk hover-doc lookup, driven through the shared scan engine.
struct DocsScan (FileVisitor) @private
{
	Token target;
	String method_type;
	String module_filter;
	DString* out;
}

fn bool DocsScan.visit(&self, String path, String content, TokenStream* stream) @dynamic
{
	return try_extract_docs_from(content, self.target, self.out, self.method_type, stream, self.module_filter);
}

// On-disk struct-field hover-doc lookup, driven through the shared scan engine.
struct FieldDocsScan (FileVisitor) @private
{
	String type_name;
	String field_name;
	DString* out;
}

fn bool FieldDocsScan.visit(&self, String path, String content, TokenStream* stream) @dynamic
{
	return try_extract_field_docs_from(content, self.type_name, self.field_name, self.out, stream);
}
