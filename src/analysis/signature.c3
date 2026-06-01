module lsp;

import std::core::dstring;
import std::core::mem;
import std::io::path;
import c3::lexer;

// Encodes a signatureHelp response.
//
// Finds the function/method being called at the cursor by walking backwards to the
// opening '(' and its callee name, then resolves that callee's declaration to extract
// the signature. The declaration is searched the same way go-to-definition searches:
// current file -> open documents -> project files on disk -> stdlib. For a method call
// (`recv.method(`) the receiver type is resolved first so the right `fn Ret Type.method(`
// is matched — this is what makes stdlib methods like `str.starts_with(` show hints.
//
// `uri`, `docs`, and `stdlib_path` are optional; when omitted only the current file is
// searched (used by unit tests). The handler always passes them.
fn void encode_signature_help(String content, sz offset, DString* out, TokenStream* cached = null, String uri = "", DocumentList* docs = null, String stdlib_path = "")
{
	TokenStream owned;
	TokenStream* stream;
	if (cached != null) { stream = cached; }
	else { owned = token_stream_tokenize(content); stream = &owned; }
	defer { if (cached == null) owned.free(); }

	sz call_name_idx = stream.tokens.size; // sentinel = not found
	sz active_param = 0;

	// Find the token index at or just before the cursor. A token that *starts* exactly at the
	// cursor offset sits to the right of the cursor (e.g. the ')' in "foo(|)") and must be
	// excluded — otherwise it inflates paren depth below and hides the call's opening '('.
	sz cursor_tok_idx = 0;
	for (sz i = 0; i < stream.tokens.size; i++)
	{
		if (stream.tokens[i].offset < offset)
		{
			cursor_tok_idx = i;
		}
		else
		{
			break;
		}
	}

	// Walk backwards from the cursor, tracking paren depth, to find `IDENT (` ... cursor.
	sz depth = 0;
	sz comma_count = 0;
	for (sz ii = 0; ii <= cursor_tok_idx; ii++)
	{
		sz i = cursor_tok_idx - ii;
		TokenType tt = stream.tokens[i].type;
		if (tt == RPAREN)
		{
			depth++;
		}
		else if (tt == LPAREN)
		{
			if (depth > 0)
			{
				depth--;
			}
			else
			{
				// This is the opening paren of our call.
				if (i > 0 && is_ident(stream.tokens[i - 1].type))
				{
					call_name_idx = i - 1;
					active_param = comma_count;
				}
				break;
			}
		}
		else if (tt == COMMA && depth == 0)
		{
			comma_count++;
		}
		if (i == 0) break;
	}

	if (call_name_idx == stream.tokens.size) return;

	Token target = stream.tokens[call_name_idx];
	bool is_method = call_name_idx > 0 && stream.tokens[call_name_idx - 1].type == DOT;

	// Build the list of receiver types to try when matching the declaration. For a method
	// call we resolve the receiver type (and its alias base); for a free function the single
	// empty candidate triggers the `fn Ret name(` / `macro name(` scan.
	String[2] method_types;
	sz mt_count = 0;
	if (is_method && docs != null)
	{
		String recv = stream.tokens.resolve_receiver_type(call_name_idx, uri, docs);
		if (recv.len > 0)
		{
			method_types[mt_count++] = recv;
			String resolved = stream.tokens.resolve_type_alias_across(recv, docs);
			if (resolved.len == 0 && uri.len > 0)
			{
				String fp = uri_to_path(uri);
				if (fp.len > 0) resolved = resolve_alias_in_project(fp, recv);
			}
			if (resolved.len > 0 && resolved != recv) method_types[mt_count++] = resolved;
		}
	}
	if (mt_count == 0) method_types[mt_count++] = "";

	for (sz ci = 0; ci < mt_count; ci++)
	{
		if (search_signature_all(stream, target, active_param, is_method, method_types[ci], content, uri, docs, stdlib_path, out))
		{
			return;
		}
	}
}

// 4-step declaration search mirroring try_find_definition, but extracting the signature
// instead of a location. Returns true once the signature JSON is written to `out`.
fn bool search_signature_all(TokenStream* cur, Token target, sz active_param, bool is_method, String method_type, String content, String uri, DocumentList* docs, String stdlib_path, DString* out) @private
{
	// 1. Current file.
	if (cur.tokens.find_signature(target, active_param, is_method, method_type, content, out)) return true;

	// 2. Other open documents.
	if (docs != null)
	{
		for (sz d = 0; d < docs.size; d++)
		{
			if (docs.entries[d].uri == uri) continue;
			TokenStream* other = docs.entries[d].get_tokens();
			if (other.tokens.find_signature(target, active_param, is_method, method_type, docs.entries[d].content, out)) return true;
		}
	}

	// 3. Project files on disk.
	if (uri.len > 0)
	{
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
					if (scan_dir_for_signature(search_path.str_view(), target, active_param, is_method, method_type, out, 0)) return true;
				}
			}
		}
	}

	// 4. Stdlib.
	if (stdlib_path.len > 0)
	{
		if (scan_dir_for_signature(stdlib_path, target, active_param, is_method, method_type, out, 0)) return true;
	}

	return false;
}

// Find `target`'s declaration in this token list and, if found, write its signature JSON.
fn bool TokenList.find_signature(&self, Token target, sz active_param, bool is_method, String method_type, String content, DString* out)
{
	if (try idx = self.find_declaration_in(target, method_type))
	{
		return self.extract_signature_at(idx, content, active_param, is_method, out);
	}
	return false;
}

// Given the index of a function/macro NAME token in a declaration, build the
// signatureHelp JSON. The implicit `self` receiver of a method is dropped from the
// emitted parameter list so the active-parameter index lines up with the call's args.
// Returns false (writing nothing) if `name_idx` is not actually a callable declaration.
fn bool TokenList.extract_signature_at(&self, sz name_idx, String content, sz active_param, bool is_method, DString* out)
{
	// Locate the `fn`/`macro` keyword that introduces this declaration.
	sz kw_idx = 0;
	bool found_kw = false;
	for (sz back = 0; back <= name_idx && back < 16; back++)
	{
		sz i = name_idx - back;
		TokenType t = self.entries[i].type;
		if (t == FUNC || t == MACRO) { kw_idx = i; found_kw = true; break; }
		if (i == 0) break;
	}
	if (!found_kw) return false;

	// Opening paren of the parameter list.
	sz lparen_idx = 0;
	for (sz j = name_idx + 1; j < self.size && j < name_idx + 8; j++)
	{
		if (self.entries[j].type == LPAREN) { lparen_idx = j; break; }
		if (self.entries[j].type == LBRACE || self.entries[j].type == EOS) break;
	}
	if (lparen_idx == 0) return false;

	// Signature label spans keyword .. matching ')' (or '{'/';' for paren-less forms).
	sz sig_start = self.entries[kw_idx].offset;
	sz sig_end = sig_start;
	sz pdepth = 0;
	bool found_end = false;
	for (sz j = lparen_idx; j < self.size; j++)
	{
		TokenType t = self.entries[j].type;
		if (t == LPAREN)
		{
			pdepth++;
		}
		else if (t == RPAREN)
		{
			pdepth--;
			if (pdepth == 0) { sig_end = self.entries[j].offset + self.entries[j].len; found_end = true; break; }
		}
		else if (t == LBRACE || t == EOS)
		{
			sig_end = self.entries[j].offset;
			found_end = true;
			break;
		}
	}
	if (!found_end) return false;
	String sig_text = content[sig_start..sig_end - 1];

	// Collect parameters by splitting on top-level commas between the outermost parens.
	String[64] params;
	sz pcount = 0;
	sz param_start = self.entries[lparen_idx].offset + 1; // after '('
	pdepth = 1;
	for (sz j = lparen_idx + 1; j < self.size; j++)
	{
		TokenType t = self.entries[j].type;
		if (t == LPAREN)
		{
			pdepth++;
		}
		else if (t == RPAREN)
		{
			pdepth--;
			if (pdepth == 0)
			{
				sz param_end = self.entries[j].offset;
				if (param_end > param_start)
				{
					String pt = content[param_start..param_end - 1].trim();
					if (pt.len > 0 && pcount < 64) params[pcount++] = pt;
				}
				break;
			}
		}
		else if (t == COMMA && pdepth == 1)
		{
			sz param_end = self.entries[j].offset;
			if (param_end > param_start)
			{
				String pt = content[param_start..param_end - 1].trim();
				if (pt.len > 0 && pcount < 64) params[pcount++] = pt;
			}
			param_start = self.entries[j].offset + 1; // after ','
		}
	}

	// Drop the implicit receiver of a method so activeParameter aligns with the call args.
	sz pstart = 0;
	if (is_method && pcount > 0 && is_self_param(params[0])) pstart = 1;

	out.append(`{"signatures":[{"label":"`);
	json_escape_into(out, sig_text);
	out.append(`","parameters":[`);
	bool first = true;
	for (sz i = pstart; i < pcount; i++)
	{
		if (!first) out.append_char(',');
		out.append(`{"label":"`);
		json_escape_into(out, params[i]);
		out.append(`"}`);
		first = false;
	}
	out.appendf(`]}],"activeSignature":0,"activeParameter":%d}`, active_param);
	return true;
}

// True if a parameter declaration is a method's implicit receiver (`self`, `&self`,
// `*self`, or a typed form ending in `self`).
fn bool is_self_param(String p) @private
{
	if (p == "self" || p == "&self" || p == "*self") return true;
	if (p.ends_with(" self") || p.ends_with("*self") || p.ends_with("&self")) return true;
	return false;
}

// Recursively scan a directory for `target`'s declaration; on the first match, write its
// signature JSON (extracted from that file's content) and return true.
fn bool scan_dir_for_signature(String dir_path, Token target, sz active_param, bool is_method, String method_type, DString* out, int depth) @private
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
				// Extract into a temp buffer and copy out before freeing fc — the label and
				// parameter strings slice directly into the file content.
				DString local = dstring::temp();
				bool hit = stream.tokens.find_signature(target, active_param, is_method, method_type, fc, &local);
				if (hit) out.append(local.str_view());
				if (owns) { owned.free(); mem::free((char*)fc.ptr); }
				if (hit) return true;
			}
		}
		else
		{
			if (scan_dir_for_signature(full_path, target, active_param, is_method, method_type, out, depth + 1)) return true;
		}
	}
	return false;
}
