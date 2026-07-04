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
fn void encode_signature_help(
	String content,
	sz offset,
	DString* out,
	TokenStream* cached = null,
	String uri = "",
	DocumentList* docs = null,
	String stdlib_path = ""
)
{
	TokenStream owned;
	TokenStream* stream;
	if (cached != null)
	{
		stream = cached;
	}
	else
	{
		owned = token_stream_tokenize(content);
		stream = &owned;
	}
	defer
	{
		if (cached == null) owned.free();
	}

	sz call_name_idx     = stream.tokens.size; // sentinel = not found
	sz active_param      = 0;
	// True when the cursor is inside a generic argument list `name{ ... }` (type
	// params) rather than a regular call argument list `name( ... )` (value params).
	bool is_generic_help = false;

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

	// Walk backwards from the cursor, tracking paren and brace depth, to find the call's
	// opening `(` (value args) or `{` (generic type args) and the callee name before it.
	sz paren_depth = 0;
	sz brace_depth = 0;
	sz comma_count = 0;
	for (sz ii = 0; ii <= cursor_tok_idx; ii++)
	{
		sz i         = cursor_tok_idx - ii;
		TokenType tt = stream.tokens[i].type;
		if (tt == RPAREN)
		{
			paren_depth++;
		}
		else if (tt == LPAREN)
		{
			if (paren_depth > 0)
			{
				paren_depth--;
			}
			else
			{
				// Opening paren of our call. The callee may be a generic instantiation
				// `name{Args}(` — then the token before `(` is `}`; step back over the
				// `{...}` block to reach the name.
				sz nidx = i;
				if (i > 0 && stream.tokens[i - 1].type == RBRACE)
				{
					sz lbrace = stream.tokens.match_lbrace_back(i - 1);
					if (lbrace < stream.tokens.size) nidx = lbrace;
				}
				if (nidx > 0 && is_ident(stream.tokens[nidx - 1].type))
				{
					call_name_idx = nidx - 1;
					active_param = comma_count;
					is_generic_help = false;
				}
				break;
			}
		}
		else if (tt == RBRACE)
		{
			brace_depth++;
		}
		else if (tt == LBRACE)
		{
			if (brace_depth > 0)
			{
				brace_depth--;
			}
			else
			{
				// Opening brace of a generic argument list `name{ | }`.
				if (i > 0 && is_ident(stream.tokens[i - 1].type))
				{
					call_name_idx = i - 1;
					active_param = comma_count;
					is_generic_help = true;
				}
				break;
			}
		}
		else if (tt == COMMA && paren_depth == 0 && brace_depth == 0)
		{
			comma_count++;
		}
		if (i == 0) break;
	}

	if (call_name_idx == stream.tokens.size) return;

	Token target   = stream.tokens[call_name_idx];
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

	// For a module-qualified free call (`mod::fn(`), restrict the declaration search
	// to that module so a same-named function elsewhere isn't matched.
	String module_filter = "";
	if (!is_method)
	{
		String mod_prefix = stream.tokens.resolve_module_prefix(call_name_idx);
		if (mod_prefix.len > 0)
		{
			module_filter = resolve_module_name(content, mod_prefix);
			if (module_filter.len == 0) module_filter = mod_prefix;
		}
	}

	for (sz ci = 0; ci < mt_count; ci++)
	{
		if (search_signature_all(
			stream,
			target,
			active_param,
			is_method,
			method_types[ci],
			content,
			uri,
			docs,
			stdlib_path,
			is_generic_help,
			module_filter,
			out
		))
		{
			return;
		}
	}
}

// 4-step declaration search mirroring try_find_definition, but extracting the signature
// instead of a location. Returns true once the signature JSON is written to `out`.
fn bool search_signature_all(
	TokenStream* cur,
	Token target,
	sz active_param,
	bool is_method,
	String method_type,
	String content,
	String uri,
	DocumentList* docs,
	String stdlib_path,
	bool is_generic_help,
	String module_filter,
	DString* out
) @private
{
	// 1. Current file.
	if (cur.tokens.find_signature(
		target,
		active_param,
		is_method,
		method_type,
		content,
		out,
		is_generic_help,
		module_filter
	)) return true;

	// 2. Other open documents.
	if (docs != null)
	{
		for (sz d = 0; d < docs.size; d++)
		{
			if (docs.entries[d].uri == uri) continue;
			TokenStream* other = docs.entries[d].get_tokens();
			if (other.tokens.find_signature(
				target,
				active_param,
				is_method,
				method_type,
				docs.entries[d].content,
				out,
				is_generic_help,
				module_filter
			)) return true;
		}
	}

	// 3 + 4. Project files on disk, then stdlib.
	String file_path = uri.len > 0 ? uri_to_path(uri) : "";
	SignatureScan scan = { target, active_param, is_method, method_type, is_generic_help, module_filter, out };
	return scan_project_then_stdlib(file_path, stdlib_path, &scan);
}

// Find `target`'s declaration in this token list and, if found, write its signature JSON.
fn bool TokenList.find_signature(
	&self,
	Token target,
	sz active_param,
	bool is_method,
	String method_type,
	String content,
	DString* out,
	bool is_generic_help = false,
	String module_filter = ""
)
{
	if (try idx = self.find_declaration_in(target, method_type, module_filter))
	{
		return self.extract_signature_at(idx, content, active_param, is_method, out, is_generic_help);
	}
	return false;
}

// Given the index of a function/macro NAME token in a declaration, build the
// signatureHelp JSON. The implicit `self` receiver of a method is dropped from the
// emitted parameter list so the active-parameter index lines up with the call's args.
// Returns false (writing nothing) if `name_idx` is not actually a callable declaration.
fn bool TokenList.extract_signature_at(
	&self,
	sz name_idx,
	String content,
	sz active_param,
	bool is_method,
	DString* out,
	bool is_generic_help = false
)
{
	// Locate the `fn`/`macro` keyword that introduces this declaration.
	sz kw_idx     = 0;
	bool found_kw = false;
	for (sz back = 0; back <= name_idx && back < 16; back++)
	{
		sz i        = name_idx - back;
		TokenType t = self.entries[i].type;
		if (t == FUNC || t == MACRO)
		{
			kw_idx = i;
			found_kw = true;
			break;
		}
		if (i == 0) break;
	}
	if (!found_kw) return false;

	// Opening paren of the parameter list.
	sz lparen_idx = 0;
	for (sz j = name_idx + 1; j < self.size && j < name_idx + 8; j++)
	{
		if (self.entries[j].type == LPAREN)
		{
			lparen_idx = j;
			break;
		}
		if (self.entries[j].type == LBRACE || self.entries[j].type == EOS) break;
	}
	if (lparen_idx == 0) return false;

	// Signature label spans keyword .. matching ')' of the value list (or '{'/';' for
	// paren-less forms). Remember the ')' index so a trailing generic `<...>` can extend it.
	sz sig_start   = self.entries[kw_idx].offset;
	sz sig_end     = sig_start;
	sz rparen_idx  = 0;
	sz pdepth      = 0;
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
			if (pdepth == 0)
			{
				rparen_idx = j;
				sig_end = self.entries[j].offset + self.entries[j].len;
				found_end = true;
				break;
			}
		}
		else if (t == LBRACE || t == EOS)
		{
			sig_end = self.entries[j].offset;
			found_end = true;
			break;
		}
	}
	if (!found_end) return false;

	// A generic function declares its type params in `<...>` right after `)`
	// (e.g. `fn void foo(int a)<T, U>`). Find that block so its params can be shown
	// for generic help, and so the signature label covers it in either mode.
	sz less_idx    = 0;
	sz greater_idx = 0;
	if (rparen_idx > 0)
	{
		for (sz j = rparen_idx + 1; j < self.size && j < rparen_idx + 8; j++)
		{
			TokenType t = self.entries[j].type;
			if (t == LESS)
			{
				less_idx = j;
				break;
			}
			if (t == LBRACE || t == EOS) break;
		}
		if (less_idx > 0)
		{
			sz gdepth = 1;
			for (sz j = less_idx + 1; j < self.size; j++)
			{
				TokenType t = self.entries[j].type;
				if (t == LESS)
				{
					gdepth++;
				}
				else if (t == GREATER)
				{
					gdepth--;
					if (gdepth == 0)
					{
						greater_idx = j;
						sig_end = self.entries[j].offset + self.entries[j].len;
						break;
					}
				}
				else if (t == LBRACE || t == EOS) break;
			}
		}
	}

	String sig_text = content[sig_start..sig_end - 1];

	// Collect the parameter set to display: generic type params from `<...>` when the
	// cursor is inside a `name{...}` list, otherwise value params from `(...)`.
	String[64] params;
	sz pcount;
	if (is_generic_help && less_idx > 0 && greater_idx > 0)
	{
		pcount = self.collect_params_between(content, less_idx, greater_idx, LESS, GREATER, &params);
	}
	else
	{
		pcount = self.collect_params_between(content, lparen_idx, 0, LPAREN, RPAREN, &params);
	}

	// Drop the implicit receiver of a method so activeParameter aligns with the call
	// args — only for value-param help, never for generic type-param help.
	sz pstart = 0;
	if (!is_generic_help && is_method && pcount > 0 && is_self_param(params[0])) pstart = 1;

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

// Split the top-level parameters between the opening bracket at open_idx and its
// matching close bracket into trimmed strings written to `params` (max 64). open_tt/
// close_tt are the bracket token types (LPAREN/RPAREN for value args, LESS/GREATER for
// generic args). When close_idx is 0 the close bracket is found by depth-matching;
// otherwise it bounds the scan. Returns the number of parameters collected.
fn sz TokenList.collect_params_between(
	&self,
	String content,
	sz open_idx,
	sz close_idx,
	TokenType open_tt,
	TokenType close_tt,
	String[64]* params
)
{
	sz pcount      = 0;
	sz param_start = self.entries[open_idx].offset + 1; // just after the opening bracket
	sz depth       = 1;
	for (sz j = open_idx + 1; j < self.size; j++)
	{
		if (close_idx > 0 && j > close_idx) break;
		TokenType t = self.entries[j].type;
		if (t == open_tt)
		{
			depth++;
		}
		else if (t == close_tt)
		{
			depth--;
			if (depth == 0)
			{
				sz param_end = self.entries[j].offset;
				if (param_end > param_start)
				{
					String pt = content[param_start..param_end - 1].trim();
					if (pt.len > 0 && pcount < 64) (*params)[pcount++] = pt;
				}
				break;
			}
		}
		else if (t == COMMA && depth == 1)
		{
			sz param_end = self.entries[j].offset;
			if (param_end > param_start)
			{
				String pt = content[param_start..param_end - 1].trim();
				if (pt.len > 0 && pcount < 64) (*params)[pcount++] = pt;
			}
			param_start = self.entries[j].offset + 1; // after ','
		}
	}
	return pcount;
}

// True if a parameter declaration is a method's implicit receiver (`self`, `&self`,
// `*self`, or a typed form ending in `self`).
fn bool is_self_param(String p) @private
{
	if (p == "self" || p == "&self" || p == "*self") return true;
	if (p.ends_with(" self") || p.ends_with("*self") || p.ends_with("&self")) return true;
	return false;
}

// On-disk signature lookup, driven through the shared scan engine.
struct SignatureScan (FileVisitor) @private
{
	Token target;
	sz active_param;
	bool is_method;
	String method_type;
	bool is_generic_help;
	String module_filter;
	DString* out;
}

fn bool SignatureScan.visit(&self, String path, String content, TokenStream* stream) @dynamic
{
	// Extract into a temp buffer and copy out before the file content is freed — the label
	// and parameter strings slice directly into the file content.
	DString local = dstring::temp();
	bool hit = stream.tokens.find_signature(
		self.target,
		self.active_param,
		self.is_method,
		self.method_type,
		content,
		&local,
		self.is_generic_help,
		self.module_filter
	);
	if (hit) self.out.append(local.str_view());
	return hit;
}
