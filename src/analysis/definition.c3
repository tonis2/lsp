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
	sz count;
}

// Strip // and /* */ comments from JSON, respecting quoted strings.
fn String strip_json_comments(String input) @private
{
	DString out = dstring::temp();
	sz i = 0;
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

	sz dir_end = src.len;
	for (sz j = 0; j < src.len; j++)
	{
		if (src[j] == '*')
		{
			dir_end = j;
			break;
		}
	}
	if (dir_end > 0 && is_path_separator(src[dir_end - 1])) dir_end--;

	// If path ends with .c3 or .c3i, extract the parent directory
	if (dir_end >= 3)
	{
		String s = src[:dir_end];
		if (s.ends_with(".c3") || s.ends_with(".c3i"))
		{
			// Find last separator
			sz last_slash = 0;
			bool found_slash = false;
			for (sz j = s.len; j > 0; j--)
			{
				if (is_path_separator(s[j - 1]))
				{
					last_slash = j - 1;
					found_slash = true;
					break;
				}
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
	for (sz k = 0; k < self.count; k++)
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
		if (try pjson = json::tparse(clean_json))
		{
			if (try deps = pjson.get("dependency-search-paths"))
			{
				sz deps_len = deps.get_len();
				for (sz i = 0; i < deps_len && self.count < MAX_SEARCH_DIRS; i++)
				{
					Object* item = deps.get_at(i);
					if (item == null) break;
					if (item.is_string()) self.dirs[self.count++] = item.s;
				}
			}
			if (try srcs = pjson.get("sources"))
			{
				sz srcs_len = srcs.get_len();
				for (sz i = 0; i < srcs_len && self.count < MAX_SEARCH_DIRS; i++)
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
					targets.map.@each(; String key, Object* tgt)
					{
						if (self.count >= MAX_SEARCH_DIRS) return;
						if (try tgt_srcs = tgt.get("sources"))
						{
							sz ts_len = tgt_srcs.get_len();
							for (sz i = 0; i < ts_len && self.count < MAX_SEARCH_DIRS; i++)
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
fn bool TokenList.find_token_at(&self, sz offset, Token* result, sz* idx)
{
	for (sz i = 0; i < self.size; i++)
	{
		sz tok_end = self.get(i).offset + self.get(i).len;
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
		sz adj = offset - 1;
		for (sz i = 0; i < self.size; i++)
		{
			sz tok_end = self.get(i).offset + self.get(i).len;
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
fn bool TokenList.find_ident_token_at(&self, sz offset, Token* result, sz* idx)
{
	Token tok;
	sz tok_idx;
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
		sz prev_idx;
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
		sz next_idx;
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

	sz line = lo.find_line(tok.offset);
	sz col = tok.offset - lo.entries[line];
	sz end_col = col + tok.len;

	Location loc = { .uri = uri, .range = { .start = { .line = line, .character = col }, .end = { .line = line, .character = end_col }, }, };
	loc.encode(out);
}

// Find the type name of a variable by scanning for `TYPE_IDENT var`, `TYPE_IDENT* var`,
// or the generic forms `TYPE_IDENT{...} var` / `TYPE_IDENT{...}* var`.
// Array declarations (`TYPE_IDENT[4] var`, `TYPE_IDENT[] var`, vectors `TYPE_IDENT[<4>] var`)
// only match when the caller passes is_array to receive the flag — the element type is
// not the variable's type, so callers that cannot handle arrays must not see it.
fn String TokenList.find_variable_type(&self, String var_name, bool* is_array = null)
{
	for (sz i = 0; i + 1 < self.size; i++)
	{
		if (self.get(i).type != TYPE_IDENT) continue;

		// Skip an optional generic instantiation block: TYPE_IDENT{...}
		sz after = i + 1;
		if (self.entries[after].type == LBRACE)
		{
			after = self.match_rbrace(after);
			if (after >= self.size) continue;
			after++; // position just past the closing '}'
		}

		// Pointer/optional/array suffixes in any combination: TYPE_IDENT{...}[*][?][[N]] var
		bool arr = false;
		while (after < self.size)
		{
			TokenType at = self.entries[after].type;
			if (at == STAR || at == QUESTION)
			{
				after++;
				continue;
			}
			if (at == LBRACKET)
			{
				sz close = self.match_rbracket(after);
				if (close >= self.size) break;
				arr = true;
				after = close + 1;
				continue;
			}
			break;
		}

		if (after < self.size && is_ident(self.entries[after].type) && self.entries[after].text == var_name)
		{
			if (arr && is_array == null) continue;
			if (after + 1 < self.size)
			{
				TokenType next = self.entries[after + 1].type;
				if (next == EOS || next == EQ || next == COMMA || next == DOT || next == RPAREN)
				{
					if (is_array) *is_array = arr;
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
	for (sz i = 0; i + 3 < self.size; i++)
	{
		if (self.get(i).type == ALIAS && self.entries[i + 1].type == TYPE_IDENT && self.entries[i + 1].text == type_name && self.entries[i + 2].type == EQ && self.entries[i + 3].type == TYPE_IDENT)
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

	for (sz d = 0; d < docs.size; d++)
	{
		TokenStream* doc_stream = docs.entries[d].get_tokens();
		resolved = doc_stream.tokens.resolve_type_alias(type_name);
		if (resolved.len > 0) return resolved;
	}
	return "";
}

// A per-file TokenList query returning a slice of the file content ("" = miss).
// Used with StringScan to run type-resolution lookups through the scan engine.
alias StringQueryFn = fn String(TokenList*, String a, String b);

struct StringScan (FileVisitor) @private
{
	StringQueryFn query;
	String a;
	String b;
	String result;
}

fn bool StringScan.visit(&self, String path, String content, TokenStream* stream) @dynamic
{
	String r = self.query(&stream.tokens, self.a, self.b);
	if (r.len == 0) return false;
	// Copy before any free — the result points into the file content.
	DString copy = dstring::temp();
	copy.append(r);
	self.result = copy.str_view();
	return true;
}

fn String query_type_alias(TokenList* tokens, String type_name, String unused) @private
{
	return tokens.resolve_type_alias(type_name);
}

// Resolve alias by scanning project files on disk.
fn String resolve_alias_in_project(String file_path, String type_name)
{
	StringScan scan = { &query_type_alias, type_name, "", "" };
	scan_project_dirs(file_path, &scan);
	return scan.result;
}

// Resolve the type of a receiver in a DOT expression at cursor_idx.
// cursor_idx is the token AFTER the DOT. The token at cursor_idx-2 must be an IDENT.
// Handles chained access: for stream.tokens.method(), resolves stream→TokenStream,
// then TokenStream.tokens→TokenList, returning "TokenList".
// Returns the type name (e.g. "TokenStream"), or empty string if not resolvable.
fn String TokenList.resolve_receiver_type(&self, sz cursor_idx, String uri, DocumentList* docs, int depth = 0)
{
	if (cursor_idx < 2) return "";
	if (depth > 32) return ""; // bound recursion on pathological chains
	if (self.entries[cursor_idx - 1].type != DOT) return "";

	Token recv = self.entries[cursor_idx - 2];

	// Receiver is a call expression: `foo(...).` or `recv.method(...).`. Resolve the
	// call's return type and use it as the receiver type. The recursion below walks
	// fluent builder chains (`builder().setA(..).setB(..).build(..)`) link by link.
	if (recv.type == RPAREN)
	{
		if (try lparen = self.match_paren_backward(cursor_idx - 2))
		{
			if (lparen == 0) return "";
			sz name_idx = lparen - 1;
			// Generic function call `name{Args}(...)`: step back over the `{...}`
			// block so the callee name (before `{`), not the closing brace, is used.
			if (self.entries[name_idx].type == RBRACE)
			{
				sz lbrace = self.match_lbrace_back(name_idx);
				if (lbrace >= self.size || lbrace == 0) return "";
				name_idx = lbrace - 1;
			}
			Token callee = self.entries[name_idx];
			if (!is_ident(callee.type)) return "";
			if (name_idx >= 1 && self.entries[name_idx - 1].type == DOT)
			{
				// Method call — resolve the method's own receiver type first, then its return type.
				String inner = self.resolve_receiver_type(name_idx, uri, docs, depth + 1);
				if (inner.len == 0) return "";
				return self.resolve_call_return_type_across(inner, callee.text, uri, docs);
			}
			// Free function call (possibly module-qualified, e.g. `mod::fn(..)`).
			return self.resolve_call_return_type_across("", callee.text, uri, docs);
		}
		return "";
	}

	if (!is_ident(recv.type) && recv.type != TYPE_IDENT && recv.type != CONST_IDENT) return "";

	// If receiver is a TYPE_IDENT, it IS the type (e.g. Type.CONSTANT)
	if (recv.type == TYPE_IDENT) return recv.text;

	String type_name;

	// Check if receiver is itself a chained access (e.g. stream.tokens in stream.tokens.method)
	if (cursor_idx >= 4 && self.entries[cursor_idx - 3].type == DOT)
	{
		// Recursively resolve the chain
		String parent_type = self.resolve_receiver_type(cursor_idx - 2, uri, docs, depth + 1);
		if (parent_type.len > 0)
		{
			// For struct field lookup, resolve aliases (e.g. LineOffsets → List)
			String resolved_parent = self.resolve_type_alias_across(parent_type, docs);
			if (resolved_parent.len == 0)
			{
				String file_path = uri_to_path(uri);
				if (file_path.len > 0)
				{
					resolved_parent = resolve_alias_in_project(file_path, parent_type);
				}
			}
			String lookup_type = resolved_parent.len > 0 ? resolved_parent : parent_type;
			type_name = self.resolve_field_type_across(lookup_type, recv.text, uri, docs);
		}
	}

	// If chain resolution didn't work, try as a local variable
	if (type_name.len == 0)
	{
		type_name = self.find_variable_type(recv.text);
	}

	// Handle "self" — find enclosing fn Type.method(&self) and extract Type
	if (type_name.len == 0 && recv.text == "self")
	{
		type_name = self.find_enclosing_method_type(recv.offset);
	}

	if (type_name.len == 0) return "";

	return type_name;
}

// Walk backward from token index `start` (inclusive) to the '{' that opens the
// enclosing initializer, jumping over balanced groups. Returns self.size when a
// '(' , '[' or ';' is hit first — the position is not inside a brace initializer
// (call arguments, index expression, new statement).
fn sz TokenList.enclosing_lbrace_back(&self, sz start)
{
	sz bracket_depth = 0;
	for (sz k = start + 1; k > 1; k--)
	{
		sz i = k - 1;
		TokenType t = self.entries[i].type;
		if (t == RBRACKET) { bracket_depth++; continue; }
		if (t == LBRACKET)
		{
			if (bracket_depth == 0) return self.size;
			bracket_depth--;
			continue;
		}
		if (bracket_depth > 0) continue; // inside [...] — its contents are balanced
		if (t == RBRACE)
		{
			sz open = self.match_lbrace_back(i);
			if (open >= self.size || open == 0) return self.size;
			k = open + 1; // next iteration examines the token before the '{'
			continue;
		}
		if (t == RPAREN)
		{
			if (try open = self.match_paren_backward(i))
			{
				if (open == 0) return self.size;
				k = open + 1;
				continue;
			}
			return self.size;
		}
		if (t == LBRACE) return i;
		if (t == LPAREN || t == EOS) return self.size;
	}
	return self.size;
}

// Resolve the struct type of the initializer list enclosing a designated-initializer
// field designator: `(Type){ .field`, `Type v = { .field`, `v = { .field`, the nested
// form `.outer = { .inner`, and array-element initializers `Type[4] v = { { .field`.
// cursor_idx is the token AFTER the DOT of the designator (same convention as
// resolve_receiver_type). On success, *lbrace_out (if given) receives the index of
// the initializer's opening brace. Returns "" when the dot is not a designator in a
// brace initializer (e.g. call arguments) or the type cannot be determined — including
// when the initializer's type is an array, where designators are `[index] =`, not `.field`.
fn String TokenList.resolve_initializer_type(&self, sz cursor_idx, String uri, DocumentList* docs, sz* lbrace_out = null, int depth = 0)
{
	if (cursor_idx < 2) return "";
	if (depth > 8) return ""; // bound nested-initializer recursion
	if (self.entries[cursor_idx - 1].type != DOT) return "";

	sz lb = self.enclosing_lbrace_back(cursor_idx - 2);
	if (lb >= self.size) return "";

	bool is_array;
	String type_name = self.initializer_type_at(lb, uri, docs, &is_array, depth);
	if (type_name.len == 0 || is_array) return "";
	if (lbrace_out) *lbrace_out = lb;
	return type_name;
}

// Determine the type of the initializer list whose opening '{' is at index lb, from
// what precedes the brace. *is_array is set when that type is an array (`Opt[4] v = {`),
// whose elements — not fields — the braces initialize.
fn String TokenList.initializer_type_at(&self, sz lb, String uri, DocumentList* docs, bool* is_array, int depth)
{
	*is_array = false;
	if (depth > 8 || lb < 1) return "";
	Token before = self.entries[lb - 1];

	if (before.type == RPAREN)
	{
		// Compound literal `(Type){ .field`, optionally module-qualified and/or an
		// array: `(mod::Type[4]){`. Nothing else may appear inside the parens, so a
		// function-body brace after a parameter list (`fn void f(Foo x) { .`) never matches.
		if (try lparen = self.match_paren_backward(lb - 1))
		{
			if (lparen == 0) return "";
			sz last = lb - 2; // last token inside the parens
			if (last <= lparen) return "";
			bool arr = false;
			if (self.entries[last].type == RBRACKET)
			{
				sz lbk = self.match_lbracket_back(last);
				if (lbk >= self.size || lbk <= lparen + 1) return "";
				arr = true;
				last = lbk - 1;
			}
			if (self.entries[last].type != TYPE_IDENT) return "";
			// Only `mod::` qualifier segments may precede the type name.
			if ((last - (lparen + 1)) % 2 != 0) return "";
			for (sz q = lparen + 1; q < last; q += 2)
			{
				if (self.entries[q].type != IDENT || self.entries[q + 1].type != SCOPE) return "";
			}
			*is_array = arr;
			return self.entries[last].text;
		}
		return "";
	}

	if (before.type == TYPE_IDENT)
	{
		// `Type { .field }` compound-literal form.
		return before.text;
	}

	if (before.type == RBRACKET)
	{
		// `Type[4] { ... }` — array compound-literal form.
		sz lbk = self.match_lbracket_back(lb - 1);
		if (lbk >= self.size || lbk == 0) return "";
		if (self.entries[lbk - 1].type != TYPE_IDENT) return "";
		*is_array = true;
		return self.entries[lbk - 1].text;
	}

	if (before.type == EQ && lb >= 2)
	{
		// `= { .field` — variable initializer, assignment, or nested designator.
		Token target = self.entries[lb - 2];
		if (!is_ident(target.type) && target.type != CONST_IDENT) return "";

		if (lb >= 3 && self.entries[lb - 3].type == DOT)
		{
			// Nested designator `.outer = { .inner` — resolve the enclosing
			// initializer's type, then the designated field's type within it.
			String outer = self.resolve_initializer_type(lb - 2, uri, docs, null, depth + 1);
			if (outer.len == 0) return "";
			String resolved = self.resolve_type_alias_across(outer, docs);
			if (resolved.len == 0)
			{
				String file_path = uri_to_path(uri);
				if (file_path.len > 0) resolved = resolve_alias_in_project(file_path, outer);
			}
			String lookup = resolved.len > 0 ? resolved : outer;
			return self.resolve_field_type_across(lookup, target.text, uri, docs, is_array);
		}

		// `Type var = { .field` / `var = { .field` — find the declared type.
		String type_name = self.find_variable_type(target.text, is_array);
		// Declarations find_variable_type misses (e.g. `const Foo BAR = {`).
		if (type_name.len == 0 && lb >= 3 && self.entries[lb - 3].type == TYPE_IDENT)
		{
			type_name = self.entries[lb - 3].text;
		}
		return type_name;
	}

	if (before.type == LBRACE || before.type == COMMA)
	{
		// Element of an enclosing initializer list: `Opt[4] v = { { .field` or
		// `..., { .field`. When the enclosing initializer's type is an array, this
		// brace initializes one element of it. A positional element of a struct
		// initializer is not resolvable without field-ordinal tracking — skip it
		// rather than offer the wrong struct's fields.
		sz outer = self.enclosing_lbrace_back(lb - 1);
		if (outer >= self.size) return "";
		bool outer_is_array;
		String outer_type = self.initializer_type_at(outer, uri, docs, &outer_is_array, depth + 1);
		if (outer_type.len == 0 || !outer_is_array) return "";
		return outer_type;
	}

	return "";
}

// Find the type of the enclosing method for "self" resolution.
// Scans backwards from offset to find fn Type.method(&self, ...) and returns "Type".
fn String TokenList.find_enclosing_method_type(&self, sz offset)
{
	// Find the fn/macro keyword before this offset
	for (sz i = self.size; i > 0; i--)
	{
		if (self.entries[i - 1].offset > offset) continue;
		TokenType tt = self.entries[i - 1].type;
		if (tt != FUNC && tt != MACRO) continue;

		// Found fn/macro before offset. Look for Type.name( pattern after it.
		for (sz j = i; j < self.size && j < i + 64; j++)
		{
			if (self.entries[j].type == LPAREN)
			{
				// Check for Type.name( pattern: entries[j-3]=TYPE_IDENT, [j-2]=DOT, [j-1]=IDENT
				if (j >= 3 && self.entries[j - 2].type == DOT && self.entries[j - 3].type == TYPE_IDENT)
				{
					return self.entries[j - 3].text;
				}
				break;
			}
			if (self.entries[j].type == LBRACE)
			{
				j = self.match_rbrace(j);
				if (j >= self.size) break;
				continue;
			}
			if (self.entries[j].type == EOS) break;
		}
		break;
	}
	return "";
}

// Resolve the type of a struct field across current file, open docs, and project files.
fn String TokenList.resolve_field_type_across(&self, String struct_type, String field_name, String uri, DocumentList* docs, bool* is_array = null)
{
	if (is_array) *is_array = false;

	// 1. Current file
	String result = self.find_struct_field_type(struct_type, field_name, is_array);
	if (result.len > 0) return result;

	// 2. Open documents
	for (sz d = 0; d < docs.size; d++)
	{
		TokenStream* doc_stream = docs.entries[d].get_tokens();
		result = doc_stream.tokens.find_struct_field_type(struct_type, field_name, is_array);
		if (result.len > 0) return result;
	}

	// 3. Project files on disk
	String file_path = uri_to_path(uri);
	if (file_path.len > 0)
	{
		result = resolve_field_type_in_project(file_path, struct_type, field_name);
		if (result.len > 0) return result;
		// The scan query cannot carry the array flag, so array fields need a
		// second, array-only pass.
		if (is_array)
		{
			StringScan scan = { &query_field_type_array, struct_type, field_name, "" };
			scan_project_dirs(file_path, &scan);
			if (scan.result.len > 0)
			{
				*is_array = true;
				return scan.result;
			}
		}
	}

	return "";
}

fn String query_field_type(TokenList* tokens, String struct_type, String field_name) @private
{
	return tokens.find_struct_field_type(struct_type, field_name);
}

// Matches only array-typed fields — the non-array query skips them.
fn String query_field_type_array(TokenList* tokens, String struct_type, String field_name) @private
{
	bool arr;
	String result = tokens.find_struct_field_type(struct_type, field_name, &arr);
	return arr ? result : "";
}

fn String resolve_field_type_in_project(String file_path, String struct_type, String field_name) @private
{
	StringScan scan = { &query_field_type, struct_type, field_name, "" };
	scan_project_dirs(file_path, &scan);
	return scan.result;
}

// Detect method call context (IDENT DOT IDENT) and resolve the receiver type.
// Returns the resolved type name (e.g. "List"), or empty string if not a method call.
fn String TokenList.resolve_method_type(&self, sz cursor_idx, String uri, DocumentList* docs)
{
	return self.resolve_receiver_type(cursor_idx, uri, docs);
}

// Find the matching '(' for the ')' at rparen_idx by scanning left with paren depth.
// Only parentheses affect depth; brackets/braces inside the call args are ignored.
fn sz? TokenList.match_paren_backward(&self, sz rparen_idx)
{
	if (rparen_idx >= self.size || self.entries[rparen_idx].type != RPAREN) return TOKEN_NOT_FOUND~;
	int depth = 0;
	for (sz k = rparen_idx + 1; k > 0; k--)
	{
		sz i = k - 1;
		TokenType t = self.entries[i].type;
		if (t == RPAREN)
		{
			depth++;
		}
		else if (t == LPAREN)
		{
			depth--;
			if (depth == 0) return i;
		}
	}
	return TOKEN_NOT_FOUND~;
}

// Find the return type of a free function declared as `fn <RET> name(...)`.
// Returns <RET>'s TYPE_IDENT text, or "" if not found or the return type is a builtin
// (a builtin has no chainable members downstream, so stopping there is correct).
fn String TokenList.find_function_return_type(&self, String name)
{
	for (sz i = 0; i + 2 < self.size; i++)
	{
		if (self.entries[i].type != FUNC) continue;
		if (self.entries[i + 1].type != TYPE_IDENT) continue; // <RET>
		for (sz j = i + 2; j < self.size && j < i + 64; j++)
		{
			TokenType jt = self.entries[j].type;
			if (jt == LPAREN)
			{
				// `fn <RET> name(` — name not preceded by DOT (else it is a method).
				if (is_ident(self.entries[j - 1].type) && self.entries[j - 1].text == name
					&& (j < 2 || self.entries[j - 2].type != DOT))
				{
					return self.entries[i + 1].text;
				}
				break;
			}
			// Skip a generic type block `{...}` (e.g. generic return type) — not the body.
			if (jt == LBRACE)
			{
				j = self.match_rbrace(j);
				if (j >= self.size) break;
				continue;
			}
			if (jt == EOS) break;
		}
	}
	return "";
}

// Find the return type of a method declared as `fn <RET> Type.method(...)`.
fn String TokenList.find_method_return_type(&self, String type_name, String method_name)
{
	for (sz i = 0; i + 2 < self.size; i++)
	{
		if (self.entries[i].type != FUNC) continue;
		if (self.entries[i + 1].type != TYPE_IDENT) continue; // <RET>
		for (sz j = i + 2; j < self.size && j < i + 64; j++)
		{
			TokenType jt = self.entries[j].type;
			if (jt == LPAREN)
			{
				// `fn <RET> Type.method(`
				if (j >= 4 && is_ident(self.entries[j - 1].type) && self.entries[j - 1].text == method_name
					&& self.entries[j - 2].type == DOT
					&& self.entries[j - 3].type == TYPE_IDENT && self.entries[j - 3].text == type_name)
				{
					return self.entries[i + 1].text;
				}
				break;
			}
			// Skip a generic type block `{...}` (e.g. generic return type) — not the body.
			if (jt == LBRACE)
			{
				j = self.match_rbrace(j);
				if (j >= self.size) break;
				continue;
			}
			if (jt == EOS) break;
		}
	}
	return "";
}

// Resolve a call's return type across current file, open docs, and project files on disk.
// When type_name is empty, `name` is a free function; otherwise a method on type_name.
fn String TokenList.resolve_call_return_type_across(&self, String type_name, String name, String uri, DocumentList* docs)
{
	// 1. Current file
	String result = type_name.len > 0
		? self.find_method_return_type(type_name, name)
		: self.find_function_return_type(name);
	if (result.len > 0) return result;

	// 2. Open documents (reuse their cached token streams)
	for (sz d = 0; d < docs.size; d++)
	{
		TokenStream* doc_stream = docs.entries[d].get_tokens();
		result = type_name.len > 0
			? doc_stream.tokens.find_method_return_type(type_name, name)
			: doc_stream.tokens.find_function_return_type(name);
		if (result.len > 0) return result;
	}

	// 3. Project files on disk
	String file_path = uri_to_path(uri);
	if (file_path.len > 0)
	{
		result = resolve_return_type_in_project(file_path, type_name, name);
		if (result.len > 0) return result;
	}
	return "";
}

// type_name empty = free function lookup, otherwise a method on type_name.
fn String query_return_type(TokenList* tokens, String type_name, String name) @private
{
	return type_name.len > 0
		? tokens.find_method_return_type(type_name, name)
		: tokens.find_function_return_type(name);
}

fn String resolve_return_type_in_project(String file_path, String type_name, String name) @private
{
	StringScan scan = { &query_return_type, type_name, name, "" };
	scan_project_dirs(file_path, &scan);
	return scan.result;
}

// Find the type of a struct field: struct TypeName { FieldType field_name; }
// Returns the type name (e.g. "TokenList"), or empty string if not found.
// Array-typed fields (`Opt[4] options;`) only match when the caller passes is_array
// to receive the flag — the element type alone would mislead callers that expect
// the field's own type (e.g. dot-completion on the field).
fn String TokenList.find_struct_field_type(&self, String type_name, String field_name, bool* is_array = null)
{
	for (sz i = 0; i + 1 < self.size; i++)
	{
		TokenType kw = self.entries[i].type;
		if (kw != STRUCT && kw != BITSTRUCT && kw != UNION) continue;
		if (self.entries[i + 1].type != TYPE_IDENT || self.entries[i + 1].text != type_name) continue;

		sz brace = i + 2;
		while (brace < self.size && self.entries[brace].type != LBRACE) brace++;
		if (brace >= self.size) continue;

		sz depth = 1;
		for (sz j = brace + 1; j < self.size && depth > 0; j++)
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
			if (depth == 1 && is_ident(self.entries[j].type) && self.entries[j].text == field_name)
			{
				if (j == 0) continue;
				// The type sits just before the field name; step over an optional
				// pointer `*`, an optional array suffix `[4]`, and an optional
				// generic block `{...}` (e.g. List{int} lst).
				sz prev = j - 1;
				bool arr = false;
				if (prev > 0 && self.entries[prev].type == STAR) prev--;
				if (prev > 0 && self.entries[prev].type == RBRACKET)
				{
					sz lbk = self.match_lbracket_back(prev);
					if (lbk >= self.size || lbk == 0) continue;
					arr = true;
					prev = lbk - 1;
				}
				if (prev > 0 && self.entries[prev].type == STAR) prev--;
				if (arr && is_array == null) continue; // caller cannot handle array fields
				if (prev > 0 && self.entries[prev].type == RBRACE)
				{
					sz lbrace = self.match_lbrace_back(prev);
					if (lbrace >= self.size || lbrace == 0) continue;
					prev = lbrace - 1;
				}
				if (self.entries[prev].type == TYPE_IDENT)
				{
					if (is_array) *is_array = arr;
					return self.entries[prev].text;
				}
			}
		}
	}
	return "";
}

// Find a struct field declaration: struct/bitstruct/union TypeName { ... field_name ... }
fn sz? TokenList.find_struct_field(&self, String type_name, String field_name)
{
	for (sz i = 0; i + 1 < self.size; i++)
	{
		TokenType kw = self.entries[i].type;
		if (kw != STRUCT && kw != BITSTRUCT && kw != UNION) continue;
		if (self.entries[i + 1].type != TYPE_IDENT || self.entries[i + 1].text != type_name) continue;

		// Find opening brace
		sz brace = i + 2;
		while (brace < self.size && self.entries[brace].type != LBRACE) brace++;
		if (brace >= self.size) continue;

		// Scan struct body for the field name (depth 1 only)
		sz depth = 1;
		for (sz j = brace + 1; j < self.size && depth > 0; j++)
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
			if (depth == 1 && is_ident(self.entries[j].type) && self.entries[j].text == field_name)
			{
				return j;
			}
		}
	}
	return TOKEN_NOT_FOUND~;
}

// Search for a struct field declaration across all sources.
// Uses the same 4-step search as try_find_definition.
fn bool try_find_struct_field(String type_name, String field_name, String uri, String content, DocumentList* docs, String stdlib_path, DString* out) @private
{
	// 1. Current file
	{
		TokenStream owned;
		bool owns;
		TokenStream* stream = token_stream_for_doc(uri, content, docs, &owned, &owns);
		defer { if (owns) owned.free(); }
		if (try found = stream.tokens.find_struct_field(type_name, field_name))
		{
			emit_location(uri, content, stream.tokens.entries[found], out);
			return true;
		}
	}

	// 2. Open documents (reuse their cached token streams)
	for (sz d = 0; d < docs.size; d++)
	{
		if (docs.entries[d].uri == uri) continue;
		TokenStream* other_stream = docs.entries[d].get_tokens();
		if (try found = other_stream.tokens.find_struct_field(type_name, field_name))
		{
			emit_location(docs.entries[d].uri, docs.entries[d].content, other_stream.tokens.entries[found], out);
			return true;
		}
	}

	// 3 + 4. Project files on disk, then stdlib
	String file_path = uri_to_path(uri);
	StructFieldScan scan = { type_name, field_name, out };
	return scan_project_then_stdlib(file_path, stdlib_path, &scan);
}

// On-disk struct-field definition lookup, driven through the shared scan engine.
struct StructFieldScan (FileVisitor) @private
{
	String type_name;
	String field_name;
	DString* out;
}

fn bool StructFieldScan.visit(&self, String path, String content, TokenStream* stream) @dynamic
{
	if (try found = stream.tokens.find_struct_field(self.type_name, self.field_name))
	{
		DString uri = dstring::temp();
		append_file_uri(&uri, path);
		emit_location(uri.str_view(), content, stream.tokens.entries[found], self.out);
		return true;
	}
	return false;
}

// Walk back from idx over the qualifier chain (IDENT/TYPE_IDENT and `::`) to its
// first token, e.g. from `bar` in `foo::baz::bar` back to `foo`.
fn sz TokenList.qualifier_chain_start(&self, sz idx)
{
	while (idx > 0)
	{
		TokenType prev_t = self.entries[idx - 1].type;
		if (prev_t == IDENT || prev_t == TYPE_IDENT || prev_t == SCOPE)
		{
			idx--;
		}
		else
		{
			break;
		}
	}
	return idx;
}

// Join the IDENT/TYPE_IDENT segments in [start, end_exclusive) with "::" (temp-allocated).
fn String TokenList.join_path_segments(&self, sz start, sz end_exclusive)
{
	DString path = dstring::temp();
	bool first = true;
	for (sz i = start; i < end_exclusive; i++)
	{
		TokenType t = self.entries[i].type;
		if (t == IDENT || t == TYPE_IDENT)
		{
			if (!first) path.append("::");
			path.append(self.entries[i].text);
			first = false;
		}
	}
	return path.str_view();
}

// If the token at cursor_idx is preceded by a `::`, returns the module path written
// in front of it (e.g. cursor on `bar` in `foo::baz::bar` yields "foo::baz").
// Returns "" when the identifier is not module-qualified.
fn String TokenList.resolve_module_prefix(&self, sz cursor_idx)
{
	if (cursor_idx < 2) return "";
	if (self.entries[cursor_idx - 1].type != SCOPE) return "";

	sz start_idx = self.qualifier_chain_start(cursor_idx - 1);
	return self.join_path_segments(start_idx, cursor_idx - 1);
}

// If cursor_idx sits on a segment of an `import a::b::c;` statement, returns the
// module path from the start of that import group up to and INCLUDING the cursor
// segment (e.g. cursor on `core` in `import std::core::dstring;` yields "std::core").
// Returns "" when the cursor is not inside an import path. Handles comma-separated
// imports (`import a::b, c::d;`) by walking back across earlier groups to the keyword.
fn String TokenList.import_module_path_at(&self, sz cursor_idx)
{
	if (cursor_idx >= self.size) return "";
	TokenType ct = self.entries[cursor_idx].type;
	if (ct != IDENT && ct != TYPE_IDENT) return "";

	// Walk back to the start of the qualifier chain the cursor belongs to.
	sz start_idx = self.qualifier_chain_start(cursor_idx);

	// Confirm the chain is part of an import: scanning back from the chain start we
	// must reach an IMPORT keyword, optionally across comma-separated import groups
	// (`import a::b, c::d;`). Anything else means this is an ordinary expression.
	bool in_import = false;
	for (sz j = start_idx; j > 0; j--)
	{
		TokenType t = self.entries[j - 1].type;
		if (t == IMPORT) { in_import = true; break; }
		if (t == COMMA || t == IDENT || t == TYPE_IDENT || t == SCOPE) continue;
		break;
	}
	if (!in_import) return "";

	// Build the path from chain start up to AND INCLUDING the cursor segment.
	return self.join_path_segments(start_idx, cursor_idx + 1);
}

// 4-step definition search: current file -> open docs -> project files -> stdlib.
// Returns true if a definition was found and emitted.
fn bool TokenList.try_find_definition(&self, Token cursor_tok, sz cursor_idx, String uri, String content, DocumentList* docs, String stdlib_path, DString* out, String method_type = "", String module_filter = "", ModuleCtx* ctx = null)
{
	// 1. Search current file (its declarations are always visible to itself)
	if (try decl_idx = self.find_declaration(cursor_tok, cursor_idx, method_type, module_filter))
	{
		if (decl_idx != cursor_idx)
		{
			emit_location(uri, content, self.entries[decl_idx], out);
			return true;
		}
	}

	// With a ctx, declarations in modules this file cannot see don't win outright:
	// the first such match is kept as a fallback and only used when nothing
	// visible turns up anywhere, so a missing import degrades to the old
	// first-match behavior instead of "no result".
	DString fallback = dstring::temp();
	bool have_fallback;

	// 2. Search all other open documents (reuse their cached token streams)
	for (sz d = 0; d < docs.size; d++)
	{
		if (docs.entries[d].uri == uri) continue;

		TokenStream* other_stream = docs.entries[d].get_tokens();

		if (try found = other_stream.tokens.find_declaration_in(cursor_tok, method_type, module_filter))
		{
			if (ctx == null || ctx.can_see(other_stream.tokens.module_of_decl(found)))
			{
				emit_location(docs.entries[d].uri, docs.entries[d].content, other_stream.tokens.entries[found], out);
				return true;
			}
			if (!have_fallback)
			{
				emit_location(docs.entries[d].uri, docs.entries[d].content, other_stream.tokens.entries[found], &fallback);
				have_fallback = true;
			}
		}
	}

	// 3 + 4. Scan project files on disk (src/ and lib/ relative to file), then stdlib
	String file_path = uri_to_path(uri);
	DeclScan scan = { cursor_tok, method_type, module_filter, out, ctx, &fallback, &have_fallback };
	if (scan_project_then_stdlib(file_path, stdlib_path, &scan)) return true;

	// Nothing visible anywhere — fall back to the first module-blind match.
	if (have_fallback)
	{
		out.append(fallback.str_view());
		return true;
	}
	return false;
}

// On-disk symbol-declaration lookup, driven through the shared scan engine.
struct DeclScan (FileVisitor) @private
{
	Token target;
	String method_type;
	String module_filter;
	DString* out;
	ModuleCtx* ctx;
	DString* fallback;
	bool* have_fallback;
}

fn bool DeclScan.visit(&self, String path, String content, TokenStream* stream) @dynamic
{
	if (try found = stream.tokens.find_declaration_in(self.target, self.method_type, self.module_filter))
	{
		DString uri = dstring::temp();
		append_file_uri(&uri, path);
		if (self.ctx == null || self.ctx.can_see(stream.tokens.module_of_decl(found)))
		{
			emit_location(uri.str_view(), content, stream.tokens.entries[found], self.out);
			return true;
		}
		if (!*self.have_fallback)
		{
			emit_location(uri.str_view(), content, stream.tokens.entries[found], self.fallback);
			*self.have_fallback = true;
		}
	}
	return false;
}

// Returns the index of the first name-segment token of a `module <module_path>;`
// declaration whose full path exactly equals module_path, or the empty optional.
// The match is exact so `std::io` does not resolve to a `module std::io::file;`
// declaration; exact-compare also handles files carrying several module decls.
fn sz? TokenList.find_module_decl(&self, String module_path)
{
	for (sz i = 0; i + 1 < self.size; i++)
	{
		if (self.entries[i].type != MODULE) continue;
		if (self.module_path_at(i) != module_path) continue;

		// First name segment after MODULE (skip the leading `::`, if any).
		for (sz j = i + 1; j < self.size; j++)
		{
			TokenType t = self.entries[j].type;
			if (t == IDENT || t == TYPE_IDENT || t == CONST_IDENT) return j;
			if (t == SCOPE) continue;
			break;
		}
		return i; // fallback: the MODULE keyword itself
	}
	return TOKEN_NOT_FOUND~;
}

// 4-step search for a `module <path>;` declaration, mirroring try_find_definition:
// current file -> open docs -> project files -> stdlib. Emits a Location and
// returns true on the first match.
fn bool TokenList.try_find_module_definition(&self, String module_path, String uri, String content, DocumentList* docs, String stdlib_path, DString* out)
{
	// 1. Current file
	if (try idx = self.find_module_decl(module_path))
	{
		emit_location(uri, content, self.entries[idx], out);
		return true;
	}

	// 2. Other open documents (reuse their cached token streams)
	for (sz d = 0; d < docs.size; d++)
	{
		if (docs.entries[d].uri == uri) continue;

		TokenStream* other = docs.entries[d].get_tokens();
		if (try idx = other.tokens.find_module_decl(module_path))
		{
			emit_location(docs.entries[d].uri, docs.entries[d].content, other.tokens.entries[idx], out);
			return true;
		}
	}

	// 3 + 4. Project files on disk, then stdlib
	String file_path = uri_to_path(uri);
	ModuleDeclScan scan = { module_path, out };
	return scan_project_then_stdlib(file_path, stdlib_path, &scan);
}

// On-disk `module <path>;` declaration lookup, driven through the shared scan engine.
struct ModuleDeclScan (FileVisitor) @private
{
	String module_path;
	DString* out;
}

fn bool ModuleDeclScan.visit(&self, String path, String content, TokenStream* stream) @dynamic
{
	if (try idx = stream.tokens.find_module_decl(self.module_path))
	{
		DString uri = dstring::temp();
		append_file_uri(&uri, path);
		emit_location(uri.str_view(), content, stream.tokens.entries[idx], self.out);
		return true;
	}
	return false;
}

// Encodes a go-to-definition / go-to-declaration response.
// Searches: current file -> open documents -> project files on disk -> stdlib.
fn void encode_definition(String uri, String content, sz offset, DocumentList* docs, String stdlib_path, DString* out)
{
	// Reuse the open document's cached token stream when available.
	TokenStream owned;
	bool owns;
	TokenStream* stream = token_stream_for_doc(uri, content, docs, &owned, &owns);
	defer { if (owns) owned.free(); }

	// Find the token at cursor
	Token cursor_tok;
	sz cursor_idx;
	if (!stream.tokens.find_token_at(offset, &cursor_tok, &cursor_idx)) return;

	// Only navigate for identifier-like tokens
	TokenType ct = cursor_tok.type;
	if (!is_ident(ct) && ct != TYPE_IDENT && ct != CONST_IDENT) return;

	// Module visibility of the current file — used to prefer declarations this
	// file can actually see over same-named ones in unrelated modules.
	ModuleCtx visctx;
	visctx.build(&stream.tokens);

	// Import path: `import std::core::dstring;` — jump to the module declaration
	// rather than searching for a same-named symbol (which never exists).
	String import_path = stream.tokens.import_module_path_at(cursor_idx);
	if (import_path.len > 0)
	{
		stream.tokens.try_find_module_definition(import_path, uri, content, docs, stdlib_path, out);
		return; // import segments never resolve as ordinary symbols
	}

	// For DOT-preceded tokens (field/method access), resolve the receiver type
	// to avoid jumping to unrelated declarations with the same name.
	if (cursor_idx > 0 && stream.tokens.entries[cursor_idx - 1].type == DOT)
	{
		String recv_type = stream.tokens.resolve_receiver_type(cursor_idx, uri, docs);
		if (recv_type.len > 0)
		{
			// Resolve alias for struct field lookup (e.g. LineOffsets → List)
			String resolved_type = stream.tokens.resolve_type_alias_across(recv_type, docs);
			if (resolved_type.len == 0)
			{
				String file_path = uri_to_path(uri);
				if (file_path.len > 0)
				{
					resolved_type = resolve_alias_in_project(file_path, recv_type);
				}
			}

			// Try method resolution: fn Type.name(
			// Try with original type first (methods are usually on the alias name),
			// then with resolved alias
			if (is_ident(ct))
			{
				if (stream.tokens.try_find_definition(cursor_tok, cursor_idx, uri, content, docs, stdlib_path, out, recv_type, "", &visctx))
				{
					return;
				}
				if (resolved_type.len > 0 && resolved_type != recv_type)
				{
					if (stream.tokens.try_find_definition(cursor_tok, cursor_idx, uri, content, docs, stdlib_path, out, resolved_type, "", &visctx))
					{
						return;
					}
				}
			}

			// Try struct field resolution: struct Type { ... name ... }
			// Use resolved alias for struct field lookup
			String field_type = resolved_type.len > 0 ? resolved_type : recv_type;
			if (try_find_struct_field(field_type, cursor_tok.text, uri, content, docs, stdlib_path, out))
			{
				return;
			}
			// Also try unresolved name for struct fields
			if (field_type != recv_type && try_find_struct_field(recv_type, cursor_tok.text, uri, content, docs, stdlib_path, out))
			{
				return;
			}
		}
		return;
	}

	// Method call resolution: variable.method(
	if (is_ident(ct))
	{
		String method_type = stream.tokens.resolve_method_type(cursor_idx, uri, docs);
		if (method_type.len > 0)
		{
			if (stream.tokens.try_find_definition(cursor_tok, cursor_idx, uri, content, docs, stdlib_path, out, method_type, "", &visctx))
			{
				return;
			}
		}
	}

	// Regular search (non-method). If the identifier was written module-qualified
	// (e.g. `foo::bar`), restrict the search to that module to disambiguate same-named
	// symbols. The prefix is resolved to a full import path when possible.
	String module_filter = "";
	String mod_prefix = stream.tokens.resolve_module_prefix(cursor_idx);
	if (mod_prefix.len > 0)
	{
		module_filter = resolve_module_name(content, mod_prefix);
		if (module_filter.len == 0) module_filter = mod_prefix;
	}
	// A written qualifier is authoritative — visibility ranking only applies to bare names.
	stream.tokens.try_find_definition(cursor_tok, cursor_idx, uri, content, docs, stdlib_path, out, "", module_filter, module_filter.len == 0 ? &visctx : null);
}

// Find an enum/faultdef/constdef member named `name`. Handles both the block form
// (enum E { NAME }, constdef Format : uint { FORMAT_X = 44 }) and the braceless form
// (faultdef A, NAME; / constdef NAME = 100), in which members sit in declaration
// position — right after the keyword and after each top-level comma — so value
// expressions on the right of '=' are not mistaken for declarations.
fn sz? TokenList.find_enum_or_constdef_member(&self, String name)
{
	for (sz i = 0; i + 1 < self.size; i++)
	{
		TokenType kw = self.entries[i].type;
		if (kw != ENUM && kw != FAULTDEF && kw != CONSTDEF) continue;

		// Locate the first LBRACE or EOS after the keyword to tell block from braceless.
		sz j = i + 1;
		while (j < self.size && self.entries[j].type != LBRACE && self.entries[j].type != EOS) j++;
		if (j >= self.size) continue;

		if (self.entries[j].type == LBRACE)
		{
			// Block form: scan members at brace depth 1.
			sz depth = 1;
			for (sz k = j + 1; k < self.size && depth > 0; k++)
			{
				TokenType t = self.entries[k].type;
				if (t == LBRACE) { depth++; continue; }
				if (t == RBRACE) { depth--; continue; }
				if (depth == 1 && t == CONST_IDENT && self.entries[k].text == name) return k;
			}
		}
		else
		{
			// Braceless form: members are in declaration position only.
			bool decl_pos = true;
			for (sz k = i + 1; k < j; k++)
			{
				TokenType t = self.entries[k].type;
				if (t == COMMA) { decl_pos = true; continue; }
				if (decl_pos && t == CONST_IDENT && self.entries[k].text == name) return k;
				decl_pos = false;
			}
		}
	}
	return TOKEN_NOT_FOUND~;
}

// Search for a declaration in a token stream (not tied to a cursor position).
fn sz? TokenList.find_declaration_in(&self, Token target, String method_type = "", String module_filter = "")
{
	return self.find_declaration(target, self.size, method_type, module_filter);
}

// True when the declaration at decl_idx satisfies the module-qualification filter.
// An empty filter always matches; otherwise the declaration's enclosing module
// (nearest preceding `module` keyword) must match. Used to disambiguate same-named
// symbols across modules when a call was written qualified (e.g. `foo::get`).
fn bool TokenList.decl_in_filter(&self, sz decl_idx, String module_filter)
{
	if (module_filter.len == 0) return true;
	return module_matches_filter(self.module_of_decl(decl_idx), module_filter);
}

// Searches for the declaration of a token in the token stream.
// When method_type is non-empty, searches for fn Type.name( pattern only.
// When module_filter is non-empty, only declarations in the matching module match.
fn sz? TokenList.find_declaration(&self, Token target, sz target_idx, String method_type = "", String module_filter = "")
{
	String name = target.text;

	switch (target.type)
	{
		case TYPE_IDENT:
			for (sz i = 0; i + 1 < self.size; i++)
			{
				TokenType kw = self.get(i).type;
				if (is_type_declaration_keyword(kw))
				{
					if (self.entries[i + 1].type == TYPE_IDENT && self.entries[i + 1].text == name
						&& self.decl_in_filter(i + 1, module_filter))
					{
						return i + 1;
					}
				}
			}
		case CONST_IDENT:
			// constdef NAME
			for (sz i = 0; i + 1 < self.size; i++)
			{
				if (self.get(i).type == CONSTDEF && self.entries[i + 1].type == CONST_IDENT && self.entries[i + 1].text == name
					&& self.decl_in_filter(i + 1, module_filter))
				{
					return i + 1;
				}
			}
			// const [Type] NAME = ...
			for (sz i = 0; i + 1 < self.size; i++)
			{
				if (self.get(i).type != CONST) continue;
				// const NAME = ... (no type)
				if (self.entries[i + 1].type == CONST_IDENT && self.entries[i + 1].text == name
					&& self.decl_in_filter(i + 1, module_filter))
				{
					return i + 1;
				}
				// const Type NAME = ... (with type)
				if (i + 2 < self.size && is_type_token(self.entries[i + 1].type) && self.entries[i + 2].type == CONST_IDENT && self.entries[i + 2].text == name
					&& self.decl_in_filter(i + 2, module_filter))
				{
					return i + 2;
				}
			}
			// enum / faultdef / constdef member: enum Foo { NAME }, constdef Bar : T { NAME = v }, faultdef NAME
			if (try found = self.find_enum_or_constdef_member(name)) return found;
		case IDENT:
		case AT_IDENT:
			if (method_type.len > 0)
			{
				// Search for fn ... Type.method( pattern only
				for (sz i = 0; i < self.size; i++)
				{
					if (self.get(i).type != FUNC && self.get(i).type != MACRO) continue;
					if (try j = self.fn_lparen_after(i))
					{
						if (j >= 3 && is_ident(self.entries[j - 1].type) && self.entries[j - 1].text == name && self.entries[j - 2].type == DOT && self.entries[j - 3].type == TYPE_IDENT
							&& self.entries[j - 3].text == method_type)
						{
							return j - 1;
						}
					}
				}
				return TOKEN_NOT_FOUND~;
			}
			// fn ... name( or macro ... name(
			for (sz i = 0; i < self.size; i++)
			{
				if (self.get(i).type != FUNC && self.get(i).type != MACRO) continue;
				if (try j = self.fn_lparen_after(i))
				{
					if (j > 0 && is_ident(self.entries[j - 1].type) && self.entries[j - 1].text == name
						&& self.decl_in_filter(j - 1, module_filter))
					{
						return j - 1;
					}
				}
			}
			// macro name (no parens)
			for (sz i = 0; i + 1 < self.size; i++)
			{
				if (self.get(i).type == MACRO && is_ident(self.entries[i + 1].type) && self.entries[i + 1].text == name
					&& self.decl_in_filter(i + 1, module_filter))
				{
					return i + 1;
				}
			}
			// type IDENT = ...
			for (sz i = 0; i + 1 < self.size; i++)
			{
				if (is_type_token(self.get(i).type) && is_ident(self.entries[i + 1].type) && self.entries[i + 1].text == name)
				{
					if (i + 2 < self.size)
					{
						TokenType next = self.entries[i + 2].type;
						if ((next == EQ || next == EOS || next == COMMA) && self.decl_in_filter(i + 1, module_filter))
						{
							return i + 1;
						}
					}
				}
			}
		default:
			return TOKEN_NOT_FOUND~;
	}

	return TOKEN_NOT_FOUND~;
}

// Find the parameter-list `(` of the fn/macro declaration starting at kw_idx, looking
// ahead at most 64 tokens, skipping one generic type block `{...}` before the `(`
// (not the body) and bailing at end-of-statement.
fn sz? TokenList.fn_lparen_after(&self, sz kw_idx)
{
	for (sz j = kw_idx + 1; j < self.size && j < kw_idx + 64; j++)
	{
		if (self.entries[j].type == LPAREN) return j;
		// Skip a generic type block `{...}` before the `(` — not the body.
		if (self.entries[j].type == LBRACE)
		{
			j = self.match_rbrace(j);
			if (j >= self.size) break;
			continue;
		}
		if (self.entries[j].type == EOS) break;
	}
	return TOKEN_NOT_FOUND~;
}

fn String parent_dir(String path) @private
{
	if (path.len == 0) return "";
	sz end = path.len;
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
