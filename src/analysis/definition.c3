module lsp;

import std::core::dstring;
import std::core::mem;
import std::io::file;
import std::io::path;
import std::encoding::json;
import std::collections::object;
import c3::lexer;

const int MAX_SEARCH_DIRS = 32;

// Where c3c unpacks fetched .c3l archives, relative to the project root.
const String UNPACKED_C3L_DIR = "build/unpacked_c3l";

struct ProjectDirs
{
	String project_root;
	String[MAX_SEARCH_DIRS] dirs;
	sz count;
}

// Strip // and /* */ comments from JSON, respecting quoted strings.
fn String strip_json_comments(String input) @private
{
	DString out    = dstring::temp();
	sz i           = 0;
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

// Reduce one "sources" entry to the directory it starts from. Handles globs
// ("src/**" -> "src"), individual files ("./helpers/context.c3" -> "./helpers",
// "main.c3" -> "."), and plain dirs ("src" -> "src"). Returns "" when the entry
// yields no directory. Shared by project.json parsing and .c3l manifests.
fn String source_entry_dir(String src)
{
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
			sz last_slash    = 0;
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
				return ".";
			}
		}
	}

	if (dir_end == 0) return "";
	return src[:dir_end];
}

// Reduce a search-dir entry to a canonical relative form so entries that name the
// same directory compare equal: drops a leading "./", drops trailing separators,
// and maps the project root ("./", "/") to ".". Input is never empty — callers
// drop empty entries before normalizing.
fn String normalize_search_dir(String dir)
{
	String s = dir;
	while (s.len >= 2 && s[0] == '.' && is_path_separator(s[1])) s = s[2..];
	while (s.len > 0 && is_path_separator(s[s.len - 1])) s = s[:s.len - 1];
	return s.len == 0 ? "." : s;
}

// True when scanning `parent` already reaches everything under `child` — `child` is
// `parent` itself or nested inside it. Comparison is segment-aligned, so "src" does
// not cover "srclib". "." is the project root and covers every relative entry.
fn bool dir_covers(String parent, String child)
{
	if (parent == ".") return true;
	if (parent.len > child.len) return false;
	if (child[:parent.len] != parent) return false;
	if (child.len == parent.len) return true;
	return is_path_separator(child[parent.len]);
}

// Add one search dir, keeping the list free of directories that overlap. Scanning
// two dirs where one contains the other visits every file below the inner one
// twice, which is what made find-references and workspace/symbol report the same
// location several times (a project.json with both `dependency-search-paths: ["./"]`
// and a `sources` entry like "main.c3" yields two spellings of the project root).
fn void ProjectDirs.add_search_dir(&self, String raw)
{
	if (raw.len == 0) return;
	String dir = normalize_search_dir(raw);

	// Already reached by a broader entry — adding it would duplicate every hit.
	for (sz k = 0; k < self.count; k++)
	{
		if (dir_covers(self.dirs[k], dir)) return;
	}

	// This entry is broader than ones already collected: drop those, keep this.
	sz keep = 0;
	for (sz k = 0; k < self.count; k++)
	{
		if (dir_covers(dir, self.dirs[k])) continue;
		self.dirs[keep++] = self.dirs[k];
	}
	self.count = keep;

	if (self.count >= MAX_SEARCH_DIRS) return;
	self.dirs[self.count++] = dir;
}

// Extract a directory from a source path and add it to search dirs.
fn void ProjectDirs.add_source_dir(&self, String src)
{
	String src_dir = source_entry_dir(src);
	if (src_dir.len == 0) return;
	self.add_search_dir(src_dir);
}

// Add the unpacked-dependency dirs under build/unpacked_c3l, skipping libraries that
// are also vendored in one of the search dirs collected so far. c3c unpacks a copy of
// each fetched archive there, so a project that keeps `lib/foo.c3l` checked in has the
// same library on disk twice — scanning both reports every symbol in it twice.
fn void ProjectDirs.add_unpacked_c3l_dirs(&self)
{
	DString unpacked = dstring::temp();
	unpacked.appendf("%s/%s", self.project_root, UNPACKED_C3L_DIR);

	Path base;
	if (try p = path::tnew(unpacked.str_view()))
	{
		base = p;
	}
	else
	{
		return;
	}
	// See scan_dir_entries: path::ls leaks its result list when the read fails, and
	// build/unpacked_c3l is absent in any project that has not been built yet.
	if (!path::is_dir(base)) return;
	PathList entries;
	if (try el = path::ls(mem, base))
	{
		entries = el;
	}
	else
	{
		return;
	}
	defer
	{
		foreach (&e : entries) e.free(mem);
		entries.free();
	}

	// Snapshot the count: dirs added below must not be treated as vendoring roots.
	sz vendor_count = self.count;

	foreach (entry : entries)
	{
		String name = (String)entry;
		if (!name.ends_with(".c3l")) continue;
		if (self.is_vendored_lib(name, vendor_count)) continue;

		DString rel = dstring::temp();
		rel.appendf("%s/%s", UNPACKED_C3L_DIR, name);
		self.add_search_dir(rel.str_view());
	}
}

// True when `lib_name` (e.g. "window.c3l") exists as a directory under one of the
// first `limit` search dirs, meaning the project already scans a vendored copy.
fn bool ProjectDirs.is_vendored_lib(&self, String lib_name, sz limit)
{
	for (sz k = 0; k < limit; k++)
	{
		DString candidate = dstring::temp();
		candidate.appendf("%s/%s", join_search_path(self.project_root, self.dirs[k]), lib_name);
		if (try p = path::tnew(candidate.str_view()))
		{
			if (path::is_dir(p)) return true;
		}
	}
	return false;
}

// Find project root and collect all search directories from project.json.
// Includes dependency-search-paths, sources dirs, and build/unpacked_c3l.
// Add the directory `file_path` lives in, expressed relative to the project root.
// Does nothing when the file is outside the project root (it is then reached through
// a search dir already, or not at all).
fn void ProjectDirs.add_own_dir(&self, String file_path)
{
	String own = parent_dir(file_path);
	if (own.len <= self.project_root.len || !own.starts_with(self.project_root)) return;

	String rel = own[self.project_root.len..];
	while (rel.len > 0 && is_path_separator(rel[0])) rel = rel[1..];
	if (rel.len > 0) self.add_search_dir(rel);
}

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
					if (item.is_string()) self.add_search_dir(item.s);
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
		self.add_search_dir("src");
		self.add_search_dir("lib");
	}

	// The directory holding the file being edited. A manifest names the directories
	// the *build* compiles, which is not the same set as the directories a developer
	// edits: tests, examples and scratch programs live outside `sources` and would
	// otherwise resolve nothing declared beside them. add_search_dir drops it again
	// when an existing entry already covers it, so this costs nothing for a file that
	// is part of the build.
	self.add_own_dir(file_path);

	// Always include unpacked c3l libraries, minus the ones already vendored above.
	self.add_unpacked_c3l_dirs();
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

	sz line    = lo.find_line(tok.offset);
	sz col     = tok.offset - lo.entries[line];
	sz end_col = col + tok.len;

	Location loc = {
		.uri = uri,
		.range = { .start = { .line = line, .character = col }, .end = { .line = line, .character = end_col }, },
	};
	loc.encode(out);
}

// Find the type name of a variable by scanning for `TYPE_IDENT var`, `TYPE_IDENT* var`,
// the generic forms `TYPE_IDENT{...} var` / `TYPE_IDENT{...}* var`, or a builtin
// primitive leading type (`int var`, `char[] var`, ...).
// Array declarations (`TYPE_IDENT[4] var`, `TYPE_IDENT[] var`, vectors `TYPE_IDENT[<4>] var`)
// only match when the caller passes is_array to receive the flag — the element type is
// not the variable's type, so callers that cannot handle arrays must not see it. When
// is_slice is also passed, it is set true for an unsized slice (`[]`) as opposed to a
// fixed-size array or vector — the distinction that decides whether `.ptr` is valid.
fn String TokenList.find_variable_type(&self, String var_name, bool* is_array = null, bool* is_slice = null)
{
	TypeInfo t = self.file_var_type(var_name);
	if (!t.known()) return "";
	if (t.is_array && is_array == null) return ""; // caller cannot handle arrays
	if (is_array) *is_array = t.is_array;
	if (is_slice) *is_slice = t.is_slice;
	return t.name;
}

// Resolve a type alias to its base type name.
// e.g. alias TokenList = List{Token} → "List"
fn String TokenList.resolve_type_alias(&self, String type_name)
{
	for (sz i = 0; i + 3 < self.size; i++)
	{
		if (self.get(i)
			.type == ALIAS && self.entries[i + 1].type
				== TYPE_IDENT && self.entries[i + 1].text
					== type_name && self.entries[i + 2].type == EQ && self.entries[i + 3].type == TYPE_IDENT)
		{
			return self.entries[i + 3].text;
		}
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

<*
 Resolve `alias Type = Target` for a name declared anywhere the server can see:
 open buffers first, so an alias edited but not saved wins, then the project's
 sources, then the stdlib.

 Returns "" when the name is not an alias — the common case, and the one that
 costs a walk of both trees, since a miss can only be established by looking
 everywhere. Call it once per request, not once per declaration.

 The result is temp-allocated when it came from disk and points into a cached
 file's content when it came from a buffer; either way it lasts until the end of
 the message being handled, and no longer.
*>
fn String resolve_alias_anywhere(String type_name, DocumentList* docs, String anchor_path, String stdlib_path)
{
	if (type_name.len == 0) return "";

	if (docs != null)
	{
		for (sz d = 0; d < docs.size; d++)
		{
			String resolved = docs.entries[d].get_tokens().tokens.resolve_type_alias(type_name);
			if (resolved.len > 0) return resolved;
		}
	}

	StringScan scan = { &query_type_alias, type_name, "", "" };
	scan_project_then_stdlib(anchor_path, stdlib_path, &scan);
	return scan.result;
}

// Resolve the type of a receiver in a DOT expression at cursor_idx.
// cursor_idx is the token AFTER the DOT. The token at cursor_idx-2 must be an IDENT.
// Handles chained access: for stream.tokens.method(), resolves stream→TokenStream,
// then TokenStream.tokens→TokenList, returning "TokenList".
// Returns the type name (e.g. "TokenStream"), or empty string if not resolvable.
fn String TokenList.resolve_receiver_type(
	&self,
	sz cursor_idx,
	String uri,
	DocumentList* docs,
	String stdlib_path = "",
	int depth = 0
)
{
	if (cursor_idx < 2) return "";
	if (self.entries[cursor_idx - 1].type != DOT) return "";

	TypeInfo t = self.expr_type(cursor_idx - 2, uri, docs, stdlib_path, depth);
	// An array receiver carries no named declarations of its own — only the
	// compiler-builtin `.len`/`.ptr` — so callers must not be handed its element
	// type as though members could be looked up on it.
	if (t.is_array) return "";
	return t.name;
}

// The full inferred type of the dot-completion receiver at cursor_idx, including the
// array/generic facts `resolve_receiver_type` drops. Callers that need to know the
// receiver is a collection (or which module its type came from) use this instead.
fn TypeInfo TokenList.receiver_type_info(&self, sz cursor_idx, String uri, DocumentList* docs, String stdlib_path = "")
{
	if (cursor_idx < 2) return {};
	if (self.entries[cursor_idx - 1].type != DOT) return {};
	return self.expr_type(cursor_idx - 2, uri, docs, stdlib_path);
}

// Whether the dot-completion receiver at cursor_idx (the token AFTER the DOT) is
// statically known to be array/slice/vector-shaped — a local variable, parameter, or
// same-file struct field declared with an array suffix (`T[]`, `T[4]`, `T[<4>]`),
// for ANY element type T (builtin or class). Arrays carry no named struct/method
// declarations of their own; they only expose the compiler-builtin `.len` (all three
// shapes) and `.ptr` (unsized slice only) properties, which resolve_receiver_type
// cannot describe (it already returns "" for an array receiver, by design — see
// find_variable_type/find_struct_field_type's `is_array == null` guards). Only the
// current file's tokens are consulted — a struct defined in another file with an
// array field is not detected, so completions may be missing (never wrong) there.
fn bool TokenList.is_receiver_array(
	&self,
	sz cursor_idx,
	String uri,
	DocumentList* docs,
	bool* is_slice,
	String stdlib_path = ""
)
{
	TypeInfo t = self.receiver_type_info(cursor_idx, uri, docs, stdlib_path);
	if (!t.is_array) return false;
	if (is_slice) *is_slice = t.is_slice;
	return true;
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
		sz i        = k - 1;
		TokenType t = self.entries[i].type;
		if (t == RBRACKET)
		{
			bracket_depth++;
			continue;
		}
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
fn String TokenList.resolve_initializer_type(
	&self,
	sz cursor_idx,
	String uri,
	DocumentList* docs,
	sz* lbrace_out = null,
	int depth = 0,
	String stdlib_path = ""
)
{
	if (cursor_idx < 2) return "";
	if (depth > 8) return ""; // bound nested-initializer recursion
	if (self.entries[cursor_idx - 1].type != DOT) return "";

	sz lb = self.enclosing_lbrace_back(cursor_idx - 2);
	if (lb >= self.size) return "";

	TypeInfo t = self.initializer_type_at(lb, uri, docs, stdlib_path, depth);
	if (!t.known() || t.is_array) return "";
	if (lbrace_out) *lbrace_out = lb;
	return t.name;
}

// Determine the type of the initializer list whose opening '{' is at index lb, from
// what precedes the brace. The result is flagged as an array (`Opt[4] v = {`) when the
// braces initialize elements rather than fields — designators are `[index] =` there,
// not `.field`, so callers treat that as "not a struct initializer".
fn TypeInfo TokenList.initializer_type_at(&self, sz lb, String uri, DocumentList* docs, String stdlib_path, int depth)
{
	if (depth > 8 || lb < 1) return {};
	Token before = self.entries[lb - 1];

	if (before.type == RPAREN)
	{
		// Compound literal `(Type){ .field`, optionally module-qualified and/or an
		// array: `(mod::Type[4]){`. Nothing else may appear inside the parens, so a
		// function-body brace after a parameter list (`fn void f(Foo x) { .`) never matches.
		sz? matched = self.match_paren_backward(lb - 1);
		if (catch matched) return {};
		sz lparen = matched;
		if (lparen == 0) return {};
		sz last = lb - 2; // last token inside the parens
		if (last <= lparen) return {};
		bool arr = false;
		if (self.entries[last].type == RBRACKET)
		{
			sz lbk = self.match_lbracket_back(last);
			if (lbk >= self.size || lbk <= lparen + 1) return {};
			arr  = true;
			last = lbk - 1;
		}
		if (self.entries[last].type != TYPE_IDENT) return {};
		// Only `mod::` qualifier segments may precede the type name.
		if ((last - (lparen + 1)) % 2 != 0) return {};
		for (sz q = lparen + 1; q < last; q += 2)
		{
			if (self.entries[q].type != IDENT || self.entries[q + 1].type != SCOPE) return {};
		}
		return { .name = self.entries[last].text, .is_array = arr };
	}

	if (before.type == TYPE_IDENT)
	{
		// `Type { .field }` compound-literal form.
		return { .name = before.text };
	}

	if (before.type == RBRACKET)
	{
		// `Type[4] { ... }` — array compound-literal form.
		sz lbk = self.match_lbracket_back(lb - 1);
		if (lbk >= self.size || lbk == 0) return {};
		if (self.entries[lbk - 1].type != TYPE_IDENT) return {};
		return { .name = self.entries[lbk - 1].text, .is_array = true };
	}

	if (before.type == EQ && lb >= 2)
	{
		// `= { .field` — variable initializer, assignment, or nested designator.
		Token target = self.entries[lb - 2];
		if (!is_ident(target.type) && target.type != CONST_IDENT) return {};

		if (lb >= 3 && self.entries[lb - 3].type == DOT)
		{
			// Nested designator `.outer = { .inner` — resolve the enclosing
			// initializer's type, then the designated field's type within it.
			String outer = self.resolve_initializer_type(lb - 2, uri, docs, null, depth + 1, stdlib_path);
			if (outer.len == 0) return {};
			return self.field_type_of({ .name = outer }, target.text, uri, docs, stdlib_path);
		}

		// `Type var = { .field` / `var = { .field` — find the declared type. The
		// assigned-to variable may also be an element or field expression
		// (`xs[i] = { .field`, `self.thing = { .field`).
		TypeInfo declared = self.expr_type(lb - 2, uri, docs, stdlib_path, depth + 1);
		if (declared.known()) return declared;

		// Declarations expr_type misses (e.g. `const Foo BAR = {`).
		if (lb >= 3 && self.entries[lb - 3].type == TYPE_IDENT) return { .name = self.entries[lb - 3].text };
		return {};
	}

	if (before.type == LBRACE || before.type == COMMA)
	{
		// Element of an enclosing initializer list: `Opt[4] v = { { .field` or
		// `..., { .field`. When the enclosing initializer's type is an array, this
		// brace initializes one element of it. A positional element of a struct
		// initializer is not resolvable without field-ordinal tracking — skip it
		// rather than offer the wrong struct's fields.
		sz outer = self.enclosing_lbrace_back(lb - 1);
		if (outer < self.size)
		{
			TypeInfo outer_type = self.initializer_type_at(outer, uri, docs, stdlib_path, depth + 1);
			if (outer_type.known() && outer_type.is_array) return { .name = outer_type.name };
			return {};
		}
		// No enclosing initializer — a `{` after a comma is then a later argument of
		// a call, e.g. `f(a, { .field = 1 })`.
	}

	// An initializer written straight as a call argument (`out.push({ .name = ... })`)
	// takes its type from the parameter it is passed to, which is where most struct
	// literals in real code appear.
	if (before.type == LPAREN || before.type == COMMA)
	{
		return self.call_argument_init_type(lb, uri, docs, stdlib_path, depth + 1);
	}

	return {};
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

// Detect method call context (IDENT DOT IDENT) and resolve the receiver type.
// Returns the resolved type name (e.g. "List"), or empty string if not a method call.
fn String TokenList.resolve_method_type(&self, sz cursor_idx, String uri, DocumentList* docs, String stdlib_path = "")
{
	return self.resolve_receiver_type(cursor_idx, uri, docs, stdlib_path);
}

// Find the matching '(' for the ')' at rparen_idx by scanning left with paren depth.
// Only parentheses affect depth; brackets/braces inside the call args are ignored.
fn sz? TokenList.match_paren_backward(&self, sz rparen_idx)
{
	if (rparen_idx >= self.size || self.entries[rparen_idx].type != RPAREN) return TOKEN_NOT_FOUND~;
	int depth = 0;
	for (sz k = rparen_idx + 1; k > 0; k--)
	{
		sz i        = k - 1;
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
				if (is_ident(
					self.entries[j - 1].type
				) && self.entries[j - 1].text == name && (j < 2 || self.entries[j - 2].type != DOT))
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
				if (j >= 4 && is_ident(
					self.entries[j - 1].type
				) && self.entries[j - 1].text
					== method_name && self.entries[j - 2].type
						== DOT && self.entries[j - 3].type == TYPE_IDENT && self.entries[j - 3].text == type_name)
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
fn String TokenList.resolve_call_return_type_across(
	&self,
	String type_name,
	String name,
	String uri,
	DocumentList* docs
)
{
	// 1. Current file
	String result = type_name.len > 0 ? self.find_method_return_type(type_name, name)
		: self.find_function_return_type(name);
	if (result.len > 0) return result;

	// 2. Open documents (reuse their cached token streams)
	for (sz d = 0; d < docs.size; d++)
	{
		TokenStream* doc_stream = docs.entries[d].get_tokens();
		result = type_name.len > 0 ? doc_stream.tokens.find_method_return_type(type_name, name)
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
	return type_name.len > 0 ? tokens.find_method_return_type(type_name, name) : tokens.find_function_return_type(name);
}

fn String resolve_return_type_in_project(String file_path, String type_name, String name) @private
{
	StringScan scan = { &query_return_type, type_name, name, "" };
	scan_project_dirs(file_path, &scan);
	return scan.result;
}

// Find the type of a struct field: struct TypeName { FieldType field_name; }
// Returns the type name (e.g. "TokenList"), or empty string if not found. The field's
// leading type may be a TYPE_IDENT or a builtin primitive (`int`, `char[]`, ...).
// Array-typed fields (`Opt[4] options;`) only match when the caller passes is_array
// to receive the flag — the element type alone would mislead callers that expect
// the field's own type (e.g. dot-completion on the field). When is_slice is also
// passed, it is set true for an unsized slice (`[]`) as opposed to a fixed-size array
// or vector — the distinction that decides whether `.ptr` is valid.
fn String TokenList.find_struct_field_type(&self, String type_name, String field_name, bool* is_array = null, bool* is_slice = null)
{
	TypeInfo t = self.field_decl_type(type_name, field_name);
	if (!t.known()) return "";
	if (t.is_array && is_array == null) return ""; // caller cannot handle array fields
	if (is_array) *is_array = t.is_array;
	if (is_slice) *is_slice = t.is_slice;
	return t.name;
}

// Whether `type_name` is declared as a typedef of an inline builtin slice
// (`typedef String = inline char[];`) — forwards the compiler-builtin `.len`/`.ptr`
// properties of the underlying slice without declaring any `fn`/`struct` of its own.
// Only a plain slice (`inline char[]`) counts; `inline char*` (e.g. ZString) and a
// scalar inline typedef (e.g. `inline char`) are not array-shaped and return false.
// Skips leading attributes (`@constinit`, `@if(...)`, ...) between the name and `=`.
fn bool TokenList.find_inline_slice_typedef(&self, String type_name, bool* is_slice)
{
	for (sz i = 0; i + 1 < self.size; i++)
	{
		if (self.entries[i].type != TYPEDEF) continue;
		if (self.entries[i + 1].type != TYPE_IDENT || self.entries[i + 1].text != type_name) continue;

		sz j = i + 2;
		sz paren_depth = 0;
		while (j < self.size)
		{
			TokenType t = self.entries[j].type;
			if (t == LPAREN) { paren_depth++; j++; continue; }
			if (t == RPAREN) { paren_depth--; j++; continue; }
			if (paren_depth == 0 && (t == EQ || t == EOS)) break;
			j++;
		}
		if (j >= self.size || self.entries[j].type != EQ) continue;
		j++;
		if (j >= self.size || self.entries[j].type != INLINE) continue;
		j++;
		if (j >= self.size) continue;
		TokenType lead = self.entries[j].type;
		if (lead != TYPE_IDENT && !is_builtin_type_token(lead)) continue;
		j++;

		if (j < self.size && self.entries[j].type == LBRACKET)
		{
			sz close = self.match_rbracket(j);
			if (close < self.size)
			{
				*is_slice = (j + 1 == close);
				return true;
			}
		}
		return false; // scalar or pointer inline base — not array-shaped
	}
	return false;
}

// Find a struct field declaration: struct/bitstruct/union TypeName { ... field_name ... }
fn sz? TokenList.find_struct_field(&self, String type_name, String field_name)
{
	self.@each_struct_member(type_name, null; sz j)
	{
		if (self.entries[j].text == field_name) return j;
	};
	return TOKEN_NOT_FOUND~;
}

// Search for a struct field declaration across all sources.
// Uses the same 4-step search as try_find_definition.
fn bool try_find_struct_field(
	String type_name,
	String field_name,
	String uri,
	String content,
	DocumentList* docs,
	String stdlib_path,
	DString* out
) @private
{
	// 1. Current file

	{
		TokenStream owned;
		bool owns;
		TokenStream* stream = token_stream_for_doc(uri, content, docs, &owned, &owns);
		defer
		{
			if (owns) owned.free();
		}
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
	String file_path     = uri_to_path(uri);
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
	bool first   = true;
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
		if (t == IMPORT)
		{
			in_import = true;
			break;
		}
		if (t == COMMA || t == IDENT || t == TYPE_IDENT || t == SCOPE) continue;
		break;
	}
	if (!in_import) return "";

	// Build the path from chain start up to AND INCLUDING the cursor segment.
	return self.join_path_segments(start_idx, cursor_idx + 1);
}

// 4-step definition search: current file -> open docs -> project files -> stdlib.
// Returns true if a definition was found and emitted.
fn bool TokenList.try_find_definition(
	&self,
	Token cursor_tok,
	sz cursor_idx,
	String uri,
	String content,
	DocumentList* docs,
	String stdlib_path,
	DString* out,
	String method_type = "",
	String module_filter = "",
	ModuleCtx* ctx = null,
	bool method_recv_array = false
)
{
	// 1. Search current file (its declarations are always visible to itself)
	if (try decl_idx = self.find_declaration(cursor_tok, cursor_idx, method_type, module_filter, method_recv_array))
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

		if (try found = other_stream.tokens.find_declaration_in(
			cursor_tok,
			method_type,
			module_filter,
			method_recv_array
		))
		{
			if (ctx == null || ctx.can_see(other_stream.tokens.module_of_decl(found)))
			{
				emit_location(docs.entries[d].uri, docs.entries[d].content, other_stream.tokens.entries[found], out);
				return true;
			}
			if (!have_fallback)
			{
				emit_location(
					docs.entries[d].uri,
					docs.entries[d].content,
					other_stream.tokens.entries[found],
					&fallback
				);
				have_fallback = true;
			}
		}
	}

	// 3 + 4. Scan project files on disk (src/ and lib/ relative to file), then stdlib
	String file_path = uri_to_path(uri);
	DeclScan scan    = { cursor_tok, method_type, module_filter, out, ctx, &fallback, &have_fallback, method_recv_array };
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
	bool method_recv_array;
}

fn bool DeclScan.visit(&self, String path, String content, TokenStream* stream) @dynamic
{
	if (try found = stream.tokens.find_declaration_in(
		self.target,
		self.method_type,
		self.module_filter,
		self.method_recv_array
	))
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
fn bool TokenList.try_find_module_definition(
	&self,
	String module_path,
	String uri,
	String content,
	DocumentList* docs,
	String stdlib_path,
	DString* out
)
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
	String file_path    = uri_to_path(uri);
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
	defer
	{
		if (owns) owned.free();
	}

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
		// A designator in a struct initializer (`Foo v = { .field = 1 }`, `, .field =`)
		// names a field of the type being initialized, not a member of whatever token
		// happens to sit before the dot — there is no receiver expression there at all.
		if (cursor_idx >= 2)
		{
			TokenType before_dot = stream.tokens.entries[cursor_idx - 2].type;
			if (before_dot == LBRACE || before_dot == COMMA || before_dot == LPAREN)
			{
				String init_type = stream.tokens.resolve_initializer_type(cursor_idx, uri, docs, null, 0, stdlib_path);
				if (init_type.len > 0)
				{
					if (try_find_struct_field(init_type, cursor_tok.text, uri, content, docs, stdlib_path, out))
					{
						return;
					}
					TypeInfo init_base = stream.tokens.canonical_type(init_type, uri, docs, stdlib_path);
					if (init_base.name != init_type && try_find_struct_field(
						init_base.name,
						cursor_tok.text,
						uri,
						content,
						docs,
						stdlib_path,
						out
					))
					{
						return;
					}
				}
				return; // a designator is never a member of the preceding token
			}
		}

		String recv_type = stream.tokens.resolve_receiver_type(cursor_idx, uri, docs, stdlib_path);
		if (recv_type.len > 0)
		{
			// Follow the alias chain for the struct-field lookup (LineOffsets -> List,
			// Matrix4f -> Matrix4x4). The stdlib is searched too, so an alias declared
			// there — which is where most of them are — resolves like a project one.
			TypeInfo base        = stream.tokens.canonical_type(recv_type, uri, docs, stdlib_path);
			String resolved_type = base.name == recv_type ? "" : base.name;

			// Try method resolution: fn Type.name(
			// Try with original type first (methods are usually on the alias name),
			// then with resolved alias
			if (is_ident(ct))
			{
				if (stream.tokens.try_find_definition(
					cursor_tok,
					cursor_idx,
					uri,
					content,
					docs,
					stdlib_path,
					out,
					recv_type,
					"",
					&visctx
				))
				{
					return;
				}
				// The alias may end at a builtin array or vector rather than a named
				// type — `Vec3` is `float[<3>]`, whose members the stdlib declares on
				// the wildcard receiver `float[<*>]`.
				if (resolved_type.len > 0 && resolved_type != recv_type)
				{
					if (stream.tokens.try_find_definition(
						cursor_tok,
						cursor_idx,
						uri,
						content,
						docs,
						stdlib_path,
						out,
						resolved_type,
						"",
						&visctx,
						base.is_array
					))
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
			if (field_type != recv_type && try_find_struct_field(
				recv_type,
				cursor_tok.text,
				uri,
				content,
				docs,
				stdlib_path,
				out
			))
			{
				return;
			}
		}
		return;
	}

	// Method call resolution: variable.method(
	if (is_ident(ct))
	{
		String method_type = stream.tokens.resolve_method_type(cursor_idx, uri, docs, stdlib_path);
		if (method_type.len > 0)
		{
			if (stream.tokens.try_find_definition(
				cursor_tok,
				cursor_idx,
				uri,
				content,
				docs,
				stdlib_path,
				out,
				method_type,
				"",
				&visctx
			))
			{
				return;
			}
		}
	}

	// Regular search (non-method). If the identifier was written module-qualified
	// (e.g. `foo::bar`), restrict the search to that module to disambiguate same-named
	// symbols. The prefix is resolved to a full import path when possible.
	String module_filter = "";
	String mod_prefix    = stream.tokens.resolve_module_prefix(cursor_idx);
	if (mod_prefix.len > 0)
	{
		module_filter = resolve_module_name(content, mod_prefix);
		if (module_filter.len == 0) module_filter = mod_prefix;
	}
	// A written qualifier is authoritative — visibility ranking only applies to bare names.
	stream.tokens.try_find_definition(
		cursor_tok,
		cursor_idx,
		uri,
		content,
		docs,
		stdlib_path,
		out,
		"",
		module_filter,
		module_filter.len == 0 ? &visctx : null
	);
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
				if (t == LBRACE)
				{
					depth++;
					continue;
				}
				if (t == RBRACE)
				{
					depth--;
					continue;
				}
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
				if (t == COMMA)
				{
					decl_pos = true;
					continue;
				}
				if (decl_pos && t == CONST_IDENT && self.entries[k].text == name) return k;
				decl_pos = false;
			}
		}
	}
	return TOKEN_NOT_FOUND~;
}

// Search for a declaration in a token stream (not tied to a cursor position).
fn sz? TokenList.find_declaration_in(
	&self,
	Token target,
	String method_type = "",
	String module_filter = "",
	bool method_recv_array = false
)
{
	return self.find_declaration(target, self.size, method_type, module_filter, method_recv_array);
}

// Scope-aware local-variable lookup: the nearest declaration of `name` before
// target_idx, inside the fn/macro enclosing it. The range spans the whole
// declaration, so parameters count and a use nested in an `if`/`for`/`while`/
// `switch` block still sees the locals around it. C3 forbids shadowing, so a
// name is declared at most once per function — the nearest preceding
// declaration is the one the use refers to. Returns empty when target_idx
// carries no cursor (find_declaration_in passes self.size) or the cursor sits
// outside any fn/macro body.
fn sz? TokenList.find_local_declaration(&self, String name, sz target_idx)
{
	if (target_idx == 0 || target_idx >= self.size) return TOKEN_NOT_FOUND~;

	// `enclosing_decl_start` reports the `fn`/`macro` keyword opening the
	// declaration around target_idx, so the range below covers the parameter
	// list as well as the body. It returns 0 both for "not inside a function"
	// and for a keyword that IS token 0, so the latter is checked separately.
	sz kw = self.enclosing_decl_start(target_idx);
	if (kw == 0 && self.entries[0].type != FUNC && self.entries[0].type != MACRO) return TOKEN_NOT_FOUND~;
	sz start = kw + 1;

	for (sz k = target_idx; k > start + 1; k--)
	{
		sz i = k - 1;
		if (self.entries[i].type != IDENT || self.entries[i].text != name) continue;

		// RPAREN: the LAST parameter of the list ends in `)` rather than `,`.
		// A use in that position (e.g. `foo(len)`) never passes the type check
		// on the left side below, so accepting it here is safe.
		TokenType next = self.entries[i + 1].type;
		if (next != EOS && next != EQ && next != COMMA && next != RPAREN) continue;

		// The left side must be a type, across `?`/`*` suffixes and a generic
		// `{...}` block — exactly the declaration shapes the file-global loops
		// cannot see (io.c3: `sz? len`).
		sz p = i;
		while (p > start + 1 && (self.entries[p - 1].type == QUESTION || self.entries[p - 1].type == STAR)) p--;
		if (p > start + 1 && self.entries[p - 1].type == RBRACE)
		{
			sz lbrace = self.match_lbrace_back(p - 1);
			if (lbrace == 0 || lbrace >= self.size) continue;
			p = lbrace;
		}
		if (!is_type_token(self.entries[p - 1].type)) continue;
		return i;
	}
	return TOKEN_NOT_FOUND~;
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
fn sz? TokenList.find_declaration(
	&self,
	Token target,
	sz target_idx,
	String method_type = "",
	String module_filter = "",
	bool method_recv_array = false
)
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
						&& self.decl_in_filter(
						i + 1,
						module_filter
					))
					{
						return i + 1;
					}
				}
			}
		case CONST_IDENT:
			// constdef NAME
			for (sz i = 0; i + 1 < self.size; i++)
			{
				if (self.get(i)
					.type == CONSTDEF && self.entries[i + 1].type
						== CONST_IDENT && self.entries[i + 1].text == name && self.decl_in_filter(
						i + 1,
						module_filter
					))
				{
					return i + 1;
				}
			}
			// const [Type] NAME = ...
			for (sz i = 0; i + 1 < self.size; i++)
			{
				if (self.get(i).type != CONST) continue;
				// const NAME = ... (no type)
				if (self.entries[i + 1].type == CONST_IDENT && self.entries[i + 1].text == name && self.decl_in_filter(
					i + 1,
					module_filter
				))
				{
					return i + 1;
				}
				// const Type NAME = ... (with type)
				if (i + 2 < self.size && is_type_token(
					self.entries[i + 1].type
				) && self.entries[i + 2].type == CONST_IDENT && self.entries[i + 2].text == name && self.decl_in_filter(
					i + 2,
					module_filter
				))
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
						if (j >= 3 && is_ident(
							self.entries[j - 1].type
						) && self.entries[j - 1].text == name && self.method_receiver_matches(
							j - 1,
							method_type,
							method_recv_array
						))
						{
							return j - 1;
						}
					}
				}
				return TOKEN_NOT_FOUND~;
			}
			// Local variables and parameters resolve scope-aware: the nearest
			// declaration in the enclosing function wins over same-named
			// declarations anywhere else in the file (io.c3: `len` in printfn
			// used to jump to the first `sz len;` in an unrelated function).
			// Cursor-less callers pass target_idx == self.size and skip this.
			if (target.type == IDENT)
			{
				if (try local_idx = self.find_local_declaration(name, target_idx))
				{
					return local_idx;
				}
			}
			// fn ... name( or macro ... name(
			for (sz i = 0; i < self.size; i++)
			{
				if (self.get(i).type != FUNC && self.get(i).type != MACRO) continue;
				if (try j = self.fn_lparen_after(i))
				{
					if (j > 0 && is_ident(
						self.entries[j - 1].type
					) && self.entries[j - 1].text == name && self.decl_in_filter(j - 1, module_filter))
					{
						return j - 1;
					}
				}
			}
			// macro name (no parens)
			for (sz i = 0; i + 1 < self.size; i++)
			{
				if (self.get(i)
					.type == MACRO && is_ident(
						self.entries[i + 1].type
					) && self.entries[i + 1].text == name && self.decl_in_filter(i + 1, module_filter))
				{
					return i + 1;
				}
			}
			// type IDENT = ...
			for (sz i = 0; i + 1 < self.size; i++)
			{
				if (is_type_token(self.get(i)
					.type) && is_ident(self.entries[i + 1].type) && self.entries[i + 1].text == name)
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
