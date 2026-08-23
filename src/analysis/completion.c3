module lsp;

import std::core::dstring;
import std::core::mem;
import std::io::file;
import std::io::path;
import c3::lexer;

const String[*] KEYWORDS = {
	"alias",
	"asm",
	"assert",
	"attrdef",
	"bitstruct",
	"break",
	"case",
	"catch",
	"const",
	"constdef",
	"continue",
	"default",
	"defer",
	"do",
	"else",
	"enum",
	"extern",
	"false",
	"faultdef",
	"fn",
	"for",
	"foreach",
	"foreach_r",
	"if",
	"import",
	"inline",
	"interface",
	"lengthof",
	"macro",
	"module",
	"nextcase",
	"null",
	"return",
	"static",
	"struct",
	"switch",
	"tlocal",
	"true",
	"try",
	"typedef",
	"union",
	"var",
	"while",
	};

const String[*] BUILTIN_TYPES = {
	"void",
	"bool",
	"char",
	"ichar",
	"short",
	"ushort",
	"int",
	"uint",
	"long",
	"ulong",
	"int128",
	"uint128",
	"float",
	"double",
	"float16",
	"bfloat16",
	"float128",
	"iptr",
	"uptr",
	"sz",
	"usz",
	"fault",
	"any",
	"typeid",
	};

const String[*] CT_KEYWORDS = {
	"$alignof",
	"$assert",
	"$assignable",
	"$case",
	"$default",
	"$defined",
	"$echo",
	"$else",
	"$endfor",
	"$endforeach",
	"$endif",
	"$endswitch",
	"$error",
	"$eval",
	"$evaltype",
	"$exec",
	"$extnameof",
	"$feature",
	"$for",
	"$foreach",
	"$if",
	"$is_const",
	"$include",
	"$kindof",
	"$nameof",
	"$offsetof",
	"$qnameof",
	"$sizeof",
	"$stringify",
	"$switch",
	"$typefrom",
	"$typeof",
	"$vaarg",
	"$vaconst",
	"$vacount",
	"$vaexpr",
	"$varef",
	"$vasplat",
	"$vatype",
	};

// How many items the response carries. Kept at the number the old streaming emit
// happened to top out at, because with nothing typed there is no ranking and a lower
// cap would drop arbitrary names rather than weak ones.
const sz MAX_COMPLETION_ITEMS = 512;

// How many distinct matching names are examined before collection stops. Deliberately
// much larger than the emission budget: collectors walk files in scan order, not in
// match order, so ranking only buys anything if it gets to choose from more candidates
// than are emitted. With the two equal, "the best N" degenerates back into "the first N".
const sz MAX_DOC_IDENTS = 2048;

// Free functions/macros declared in a single file, used to tag identifiers as callable.
const sz MAX_FILE_CALLABLES = 512;

// One candidate held back for ranking. `label` and `detail` are interned into the
// request's temp pool: collectors hand out views into file content that the scanner
// frees as soon as the visitor returns (see FileVisitor in scan.c3).
struct CompletionCandidate
{
	String label;
	String detail;
	int kind;
	FuzzyRank rank;
}

// Collects candidates, keeps the best MAX_COMPLETION_ITEMS by fuzzy rank, and writes
// them out best-first.
//
// Ranking has to happen before emission rather than during it. Collectors walk the
// current file, then open documents, then project files, then the stdlib; a better
// match in the last file scanned must still be able to displace a weak early one.
// Streaming each item straight to JSON as it was found made the response "whatever
// turned up first", which fuzzy matching made much worse by widening the candidate set.
//
// The sink also owns dedup. `seen` holds every distinct name accepted so far, both to
// suppress repeats (the same declaration is reachable through several files) and to
// bound the scan — collectors stop walking once it fills.
struct CompletionSink
{
	CompletionCandidate[MAX_COMPLETION_ITEMS] items;
	sz count;

	String[MAX_DOC_IDENTS] seen;
	uint[MAX_DOC_IDENTS] seen_hash;
	sz seen_count;

	String pattern;
	bool ranked;
}

fn void CompletionSink.init(&self, String pattern)
{
	self.count = 0;
	self.seen_count = 0;
	self.pattern = pattern;
	// Nothing typed means nothing to rank against, so keep insertion order and let the
	// client sort by label — the behaviour before ranking existed.
	self.ranked = pattern.len > 0;
}

// True once the scan budget is spent; the file visitors use this to stop walking.
fn bool CompletionSink.at_capacity(&self)
{
	return self.seen_count >= MAX_DOC_IDENTS;
}

// Record `name` as seen and return the interned copy. Returns "" when the name was
// already recorded or the scan budget is spent.
fn String CompletionSink.record(&self, String name)
{
	uint hash = completion_hash(name);
	for (sz i = 0; i < self.seen_count; i++)
	{
		if (self.seen_hash[i] == hash && self.seen[i] == name) return "";
	}
	if (self.seen_count >= MAX_DOC_IDENTS) return "";

	String interned = completion_intern(name);
	self.seen[self.seen_count] = interned;
	self.seen_hash[self.seen_count] = hash;
	self.seen_count++;
	return interned;
}

// Record `name` so it is never offered, without emitting it. Used for the initializer
// designators already assigned in the braces being completed.
fn void CompletionSink.suppress(&self, String name)
{
	self.record(name);
}

// Offer a candidate. Names that do not match the pattern, and names already seen, are
// dropped. The rest are kept in rank order; once the buffer is full a candidate has to
// beat the weakest kept item to get in.
fn void CompletionSink.add(&self, String label, int kind, String detail = "")
{
	if (label.len == 0) return;

	FuzzyRank rank = fuzzy_rank_ci(label, self.pattern);
	if (!rank.matched) return;

	String interned = self.record(label);
	if (interned.len == 0) return;

	CompletionCandidate cand = { .label = interned, .detail = detail.len > 0 ? completion_intern(detail) : "", .kind = kind, .rank = rank, };

	if (!self.ranked)
	{
		if (self.count < MAX_COMPLETION_ITEMS) self.items[self.count++] = cand;
		return;
	}

	// Full, and no better than the weakest kept item — the common case, rejected in O(1).
	if (self.count == MAX_COMPLETION_ITEMS && !fuzzy_rank_better(rank, self.items[self.count - 1].rank)) return;

	sz pos;
	if (self.count < MAX_COMPLETION_ITEMS)
	{
		pos = self.count;
		self.count++;
	}
	else
	{
		pos = self.count - 1; // the weakest item falls off the end
	}
	while (pos > 0 && fuzzy_rank_better(rank, self.items[pos - 1].rank))
	{
		self.items[pos] = self.items[pos - 1];
		pos--;
	}
	self.items[pos] = cand;
}

// Write the kept candidates as the body of the "items" array, best first.
fn void CompletionSink.flush(&self, DString* out)
{
	for (sz i = 0; i < self.count; i++)
	{
		if (i > 0) out.append_char(',');

		CompletionCandidate cand = self.items[i];
		CompletionItem item = { .label = cand.label, .kind = cand.kind, .detail = cand.detail, };

		// The list is truncated to the best MAX_COMPLETION_ITEMS, so the server's order is
		// the meaningful one. sortText carries it; without it a client that sorts by label
		// would present an arbitrary alphabetical slice of the top N as if it were the whole set.
		if (self.ranked) item.sort_text = completion_order_key(i);

		if (cand.kind == 2 || cand.kind == 3) // Method / Function (incl. macros)
		{
			// Insert "label($0)" as a snippet and trigger the parameter-hints popup so
			// accepting a callable drops the cursor inside the parens with signatures shown.
			// The label stays the plain name (filtering/display unchanged); only inserted text differs.
			item.insert_text = snippet_call_text(cand.label);
			item.insert_text_format = 2; // Snippet
			item.trigger_signature_help = true;
		}
		item.encode(out);
	}
}

// Zero-padded emission index. Fixed width because sortText is compared as text, where
// "10" would otherwise sort before "9" — so MAX_COMPLETION_ITEMS must stay under 10000.
fn String completion_order_key(sz index) @private
{
	DString key = dstring::temp();
	key.appendf("%04d", index);
	return key.str_view();
}

// Copy a string into the request's temp pool, which lives until the response is sent.
// Collectors hand out views into file content that the scanner frees as soon as the
// visitor returns (scan.c3), so nothing held past that point may alias it.
fn String completion_intern(String s) @private
{
	DString copy = dstring::temp();
	copy.append(s);
	return copy.str_view();
}

// FNV-1a, only to make the linear dedup scan cheap: a mismatching hash skips the
// string compare, which matters now that the scan budget is in the thousands.
fn uint completion_hash(String s) @private
{
	uint hash = 0x811c9dc5;
	foreach (c : s)
	{
		hash ^= (uint)c;
		hash *= 0x01000193;
	}
	return hash;
}

fn void encode_completions(String uri, String content, sz offset, DocumentList* docs, String stdlib_path, DString* out)
{
	// Find prefix by scanning backwards from offset
	sz prefix_start = offset;
	while (prefix_start > 0)
	{
		char c = content[prefix_start - 1];
		if (is_ident_char(c) || c == '$' || c == '@' || c == '#')
		{
			prefix_start--;
		}
		else
		{
			break;
		}
	}

	String prefix = "";
	if (offset > prefix_start)
	{
		prefix = content[prefix_start..offset - 1];
	}

	// Check for DOT context: "foo." or "foo.ba" (partial member)
	bool is_dot_context = prefix_start > 0 && content[prefix_start - 1] == '.';

	// Check for module scope context: "args::" or "args::h" or "std::io::"
	String module_scope = "";
	bool is_scope_context = false;
	if (!is_dot_context && prefix_start >= 2 && content[prefix_start - 1] == ':' && content[prefix_start - 2] == ':')
	{
		// Scan backwards past "::" to find the module path (may include nested :: like std::io)
		sz mod_end = prefix_start - 2;
		sz mod_start = mod_end;
		while (mod_start > 0)
		{
			char c = content[mod_start - 1];
			if (is_ident_char(c) || c == ':')
			{
				mod_start--;
			}
			else
			{
				break;
			}
		}
		if (mod_start < mod_end)
		{
			module_scope = content[mod_start..mod_end - 1];
			is_scope_context = true;
		}
	}

	// ':' is registered as a trigger character only so module-path completion can fire on
	// the second ':' of '::'. A lone ':' (case labels, ternaries, bitstruct member types)
	// must not spew a full completion list — return an empty (but valid) completion list
	// when the cursor follows a single colon that is not a module scope. Emitting the empty
	// list rather than nothing is important: the completion handler forwards this buffer
	// verbatim as the JSON-RPC `result`, so an empty buffer would produce invalid JSON.
	if (!is_dot_context && !is_scope_context && prefix.len == 0 && prefix_start > 0 && content[prefix_start - 1] == ':')
	{
		out.append(`{"isIncomplete":false,"items":[]}`);
		return;
	}

	// Emit an explicit replacement range covering the typed prefix so the client
	// overwrites it instead of inserting after it. Without this, VS Code's default
	// "current word" range excludes leading $/@/# (e.g. "$str" + "$stringify" → "$$stringify").
	// prefix_start..offset never crosses a newline (the backward scan stops at non-ident chars).
	LineOffsets lo;
	lo.init(mem);
	defer lo.free();
	lo.build(content);
	sz cur_line   = lo.find_line(offset);
	sz line_start = lo.entries[cur_line];
	Range edit_range = {
		.start = { .line = cur_line, .character = prefix_start - line_start },
		.end   = { .line = cur_line, .character = offset - line_start },
	};

	// Emit editRange as an explicit InsertReplaceEdit ({insert, replace}) rather than a
	// bare Range. Both ranges are identical (prefix_start..cursor), but the insert/replace
	// form gives VS Code unambiguous edit semantics so completions still show when a
	// closing bracket sits right after the cursor (editor.autoClosingBrackets inserts one,
	// e.g. "foo(|)"). With a bare Range VS Code suppresses the popup in that position.
	//
	// isIncomplete is true because the items are ranked against the prefix as typed at
	// this instant, and truncated to the best MAX_COMPLETION_ITEMS of them. Both go stale
	// on the next keystroke — a client re-filtering the cached list would be filtering a
	// slice chosen for the old prefix — so it must re-request. Re-requests are cheap:
	// on-disk files come from the token cache (file_cache.c3), so nothing is re-read.
	// https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#completionList
	out.append(`{"isIncomplete":true,"itemDefaults":{"editRange":{"insert":`);
	edit_range.encode(out);
	out.append(`,"replace":`);
	edit_range.encode(out);
	out.append(`}},"items":[`);

	// Too large for the stack (the candidate buffer plus the seen-name table), and it
	// lives exactly as long as the request does, so it comes from the temp pool.
	CompletionSink* sink = mem::tnew(CompletionSink);
	sink.init(prefix);

	if (is_dot_context)
	{
		collect_dot_completions(uri, content, offset, docs, stdlib_path, sink);
	}
	else if (is_scope_context)
	{
		collect_module_completions(uri, content, module_scope, prefix, docs, stdlib_path, sink);
	}
	else
	{
		// Static keywords
		if (prefix.len == 0 || (prefix[0] != '$' && prefix[0] != '@' && prefix[0] != '#'))
		{
			foreach (kw : KEYWORDS) sink.add(kw, 14);      // Keyword
			foreach (bt : BUILTIN_TYPES) sink.add(bt, 22); // Struct (for types)
		}

		// CT keywords when prefix starts with $
		if (prefix.len == 0 || prefix[0] == '$')
		{
			foreach (ct : CT_KEYWORDS) sink.add(ct, 14); // Keyword
		}

		// Document identifiers (current file + open docs + project files)
		collect_all_identifiers(uri, content, prefix, docs, stdlib_path, sink);
	}

	sink.flush(out);
	out.append("]}");
}

// Build a snippet insert text of the form "name($0)", backslash-escaping the snippet
// metacharacters $ } \ in the name (identifiers are normally safe; defensive only).
fn String snippet_call_text(String name) @private
{
	// Built in the request's temp pool (like mod_path elsewhere); the view stays valid
	// through item.encode and is released when the completion pool is freed.
	DString s = dstring::temp();
	foreach (c : name)
	{
		switch (c)
		{
			case '$':
			case '}':
			case '\\':
				s.append_char('\\');
				s.append_char(c);
			default:
				s.append_char(c);
		}
	}
	s.append("($0)");
	return s.str_view();
}

// Emit the compiler-builtin properties every array/slice/vector carries: `.len` on all
// three shapes, `.ptr` only on an unsized slice (fixed arrays and vectors have no `.ptr`).
// These are never declared in source (no `struct`/`fn` backs them), so they can't be
// found by the normal field/method scan — this is the only place they come from.
fn void emit_array_property_completions(bool is_slice, CompletionSink* sink) @private
{
	sink.add("len", 10, "usz"); // 10 = Property
	if (is_slice) sink.add("ptr", 10, "void*");
}

fn bool is_ident_char(char c) @private
{
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_';
}

// Module-scoped completion: "args::h" → only declarations from the args module starting with h
// The module_name may be a short name like "process" — resolve to full path via imports.
fn void collect_module_completions(String uri, String content, String module_name, String prefix, DocumentList* docs, String stdlib_path, CompletionSink* sink) @private
{
	// Resolve short module name to full path via imports.
	// e.g. "process" → "std::os::process" if file has "import std::os::process;"
	String full_module = resolve_module_name(content, module_name);

	// 1. Search open documents for files declaring this module
	for (sz d = 0; d < docs.size; d++)
	{
		collect_declarations_from_content(docs.entries[d].content, prefix, sink, docs.entries[d].get_tokens(), module_name, full_module);
	}

	// 2 + 3. Search project files on disk, then stdlib
	String file_path = uri_to_path(uri);
	ModuleDeclsScan scan = { module_name, full_module, prefix, sink };
	scan_project_then_stdlib(file_path, stdlib_path, &scan);
}

// Collect only top-level declarations (functions, types, constants, macros) with proper kinds.
// When short_name/full_name are given, only declarations inside a matching `module` section
// are collected — a single C3 file may declare several modules (e.g. std/io/file.c3 opens with
// `module std::io;` and later `module std::io::file;`). When both are empty, collect from all.
fn void collect_declarations_from_content(String content, String prefix, CompletionSink* sink, TokenStream* cached = null, String short_name = "", String full_name = "") @private
{
	TokenStream owned;
	TokenStream* stream;
	if (cached != null) { stream = cached; }
	else { owned = token_stream_tokenize(content); stream = &owned; }
	defer { if (cached == null) owned.free(); }

	bool filter_module = short_name.len > 0 || full_name.len > 0;
	bool in_target = !filter_module; // when not filtering, everything is in scope

	for (sz i = 0; i < stream.tokens.size; i++)
	{
		TokenType tt = stream.tokens.entries[i].type;
		String name = "";
		int kind = 0;

		switch (tt)
		{
			case MODULE:
				// Track the current module section so later declarations are gated by it.
				if (filter_module)
				{
					String declared_mod = stream.tokens.module_path_at(i);
					in_target = module_path_matches(declared_mod, short_name, full_name);

					// If the declared module is a *child* of the requested scope
					// (e.g. scope "std", declared "std::io"), suggest the next path
					// segment ("io") as a Module completion item (kind 9). This is
					// what makes `import std::` / `std::io::` offer submodules.
					String sub = next_submodule_segment(declared_mod, short_name);
					if (sub.len == 0 && full_name.len > 0) sub = next_submodule_segment(declared_mod, full_name);
					if (sub.len > 0 && sub != prefix) sink.add(sub, 9); // Module
				}
				continue;
			case FUNC:
			case MACRO:
				// fn [RetType] name( or fn [RetType] Type.name(
				// Find the LPAREN and take the IDENT before it
				for (sz j = i + 1; j < stream.tokens.size && j < i + 64; j++)
				{
					if (stream.tokens.entries[j].type == LPAREN)
					{
						if (j > 0 && is_ident(stream.tokens.entries[j - 1].type))
						{
							// Skip methods (Type.name) — those are accessed via DOT, not module scope
							if (j >= 2 && stream.tokens.entries[j - 2].type == DOT) break;
							name = stream.tokens.entries[j - 1].text;
							kind = 3; // Function
						}
						break;
					}
					// A `{...}` here is a generic type block (e.g. return type
					// `List{int}`), not the function body — skip it and keep scanning.
					if (stream.tokens.entries[j].type == LBRACE)
					{
						j = stream.tokens.match_rbrace(j);
						if (j >= stream.tokens.size) break;
						continue;
					}
					if (stream.tokens.entries[j].type == EOS) break;
				}
				// macro name (no parens)
				if (name.len == 0 && tt == MACRO && i + 1 < stream.tokens.size && is_ident(stream.tokens.entries[i + 1].type))
				{
					name = stream.tokens.entries[i + 1].text;
					kind = 3; // Function
				}
			case STRUCT:
			case BITSTRUCT:
			case UNION:
			case INTERFACE:
				if (i + 1 < stream.tokens.size && stream.tokens.entries[i + 1].type == TYPE_IDENT)
				{
					name = stream.tokens.entries[i + 1].text;
					kind = 22; // Struct
				}
				// Skip the body so members (e.g. interface method decls) are not
				// scanned as module-level declarations.
				i = stream.tokens.skip_type_body(i + 1);
			case ENUM:
			case FAULTDEF:
				if (i + 1 < stream.tokens.size && stream.tokens.entries[i + 1].type == TYPE_IDENT)
				{
					name = stream.tokens.entries[i + 1].text;
					kind = 13; // Enum
				}
				i = stream.tokens.skip_type_body(i + 1);
			case ALIAS:
				if (i + 1 < stream.tokens.size && stream.tokens.entries[i + 1].type == TYPE_IDENT)
				{
					name = stream.tokens.entries[i + 1].text;
					kind = 22; // Struct (type alias)
				}
			case CONSTDEF:
				if (i + 1 < stream.tokens.size && stream.tokens.entries[i + 1].type == CONST_IDENT)
				{
					name = stream.tokens.entries[i + 1].text;
					kind = 21; // Constant
				}
			case CONST:
				// const [Type] NAME = ...
				if (i + 1 < stream.tokens.size)
				{
					if (stream.tokens.entries[i + 1].type == CONST_IDENT)
					{
						name = stream.tokens.entries[i + 1].text;
						kind = 21; // Constant
					}
					else if (i + 2 < stream.tokens.size && stream.tokens.entries[i + 2].type == CONST_IDENT)
					{
						name = stream.tokens.entries[i + 2].text;
						kind = 21; // Constant
					}
				}
			default:
				continue;
		}

		if (!in_target) continue; // declaration belongs to a non-matching module section
		if (kind == 0) continue;
		if (name == prefix) continue;

		sink.add(name, kind);
	}
}

// If `declared` is a submodule of `target` (target is a proper segment-prefix, or a
// middle span, of declared), returns the single path segment that follows target.
// e.g. next_submodule_segment("std::io::file", "std") == "io"
//      next_submodule_segment("std::io::file", "std::io") == "file"
//      next_submodule_segment("std::io::file", "io") == "file"  (middle match)
// Returns "" when declared is not a strict child of target.
fn String next_submodule_segment(String declared, String target) @private
{
	if (target.len == 0 || declared.len <= target.len + 2) return "";

	// Case 1: declared == "target::rest"
	if (declared.starts_with(target) && declared[target.len] == ':' && declared[target.len + 1] == ':')
	{
		return first_path_segment(declared[target.len + 2..]);
	}

	// Case 2: declared == "...::target::rest"
	DString needle = dstring::temp();
	needle.appendf("::%s::", target);
	String pat = needle.str_view();
	if (try idx = declared.index_of(pat))
	{
		return first_path_segment(declared[idx + pat.len..]);
	}
	return "";
}

// Returns the first "::"-delimited segment of a module path ("io::file" → "io").
fn String first_path_segment(String s) @private
{
	if (try idx = s.index_of("::")) return s[..idx - 1];
	return s;
}

// True when `declared` satisfies an (optional) module-qualification filter: either
// no filter is set, or `declared` matches the filter by full path / short name / last
// segment. Wraps the module_path_matches predicate used across resolution searches.
fn bool module_matches_filter(String declared, String filter) @private
{
	if (filter.len == 0) return true;
	return module_path_matches(declared, last_module_segment(filter), filter);
}

// Resolve a short module name to its full path using imports.
// e.g. if content has "import std::os::process;" and module_name is "process",
// returns "std::os::process". Returns "" if no matching import found.
fn String resolve_module_name(String content, String module_name) @private
{
	String[MAX_IMPORTS] imports;
	sz import_count = parse_imports(content, &imports);

	for (sz i = 0; i < import_count; i++)
	{
		// Check if full path matches directly
		if (imports[i] == module_name) return imports[i];

		// Check if last segment matches (e.g. "process" matches "std::os::process")
		String last_seg = last_module_segment(imports[i]);
		if (last_seg == module_name) return imports[i];
	}
	return "";
}

// Extract the last segment of a module path: "std::os::process" → "process"
fn String last_module_segment(String mod_path) @private
{
	// Find last "::" and return everything after it
	sz last_colon = 0;
	bool found = false;
	for (sz i = 0; i + 1 < mod_path.len; i++)
	{
		if (mod_path[i] == ':' && mod_path[i + 1] == ':')
		{
			last_colon = i + 2;
			found = true;
		}
	}
	if (found && last_colon < mod_path.len)
	{
		return mod_path[last_colon..];
	}
	return mod_path;
}

// Does a declared module path match the requested module? Matches on the full path,
// the bare short name, or the last segment (e.g. "std::os::process" matches "process").
fn bool module_path_matches(String declared, String short_name, String full_name) @private
{
	if (declared == short_name) return true;
	if (full_name.len > 0 && declared == full_name) return true;
	if (last_module_segment(declared) == short_name) return true;
	return false;
}

// On-disk module-member completion, driven through the shared scan engine.
struct ModuleDeclsScan (FileVisitor) @private
{
	String short_name;
	String full_name;
	String prefix;
	CompletionSink* sink;
}

fn bool ModuleDeclsScan.visit(&self, String path, String content, TokenStream* stream) @dynamic
{
	if (self.sink.at_capacity()) return true; // scan budget spent — stop scanning
	// collect_declarations_from_content gates by module section internally.
	collect_declarations_from_content(content, self.prefix, self.sink, stream, self.short_name, self.full_name);
	return false;
}

const sz MAX_IMPORTS = 32;

// Parse import statements from file content, returns module paths like "std::io", "c3::lexer"
fn sz parse_imports(String content, String[MAX_IMPORTS]* imports) @private
{
	Lexer lex;
	lex.init(content);
	sz count = 0;

	while (count < MAX_IMPORTS)
	{
		if (try tok = lex.next())
		{
			if (tok.type == IMPORT)
			{
				// Collect the module path: ident (SCOPE ident)*
				DString mod_path = dstring::temp();
				bool first_part = true;
				while (true)
				{
					if (try next = lex.next())
					{
						if (is_ident(next.type) || next.type == TYPE_IDENT || next.type == CONST_IDENT)
						{
							if (!first_part) mod_path.append("::");
							mod_path.append(next.text);
							first_part = false;
						}
						else if (next.type == SCOPE) // ::
						{
							continue;
						}
						else
						{
							break;
						}
					}
					else
					{
						if (lex.at_end()) break;
						lex.pos++;
						lex.col++;
						break;
					}
				}
				if (mod_path.len() > 0)
				{
					(*imports)[count] = mod_path.str_view();
					count++;
				}
			}
			// Stop after module-level declarations end (fn, struct, etc.)
			if (tok.type == FUNC || tok.type == STRUCT || tok.type == MACRO ||
				tok.type == BITSTRUCT || tok.type == UNION || tok.type == ENUM ||
				tok.type == FAULTDEF)
			{
				break;
			}
		}
		else
		{
			if (lex.at_end()) break;
			lex.pos++;
			lex.col++;
		}
	}
	return count;
}

// Convert a module path to a directory path: "std::io" → "std/io"
fn String module_to_dir_path(String mod_path, DString* buf) @private
{
	buf.clear();
	foreach (c : mod_path)
	{
		if (c == ':') continue; // skip both colons in ::
		buf.append_char(c);
	}
	// Replace remaining double-removed colons: "stdio" → need actual slashes
	// Actually, since we skip ':', "std::io" becomes "stdio" which is wrong.
	// Let's redo: replace "::" with "/"
	buf.clear();
	sz i = 0;
	while (i < mod_path.len)
	{
		if (i + 1 < mod_path.len && mod_path[i] == ':' && mod_path[i + 1] == ':')
		{
			buf.append_char('/');
			i += 2;
		}
		else
		{
			buf.append_char(mod_path[i]);
			i++;
		}
	}
	return buf.str_view();
}

// Collect identifiers from current file, open docs, project files, and imported stdlib modules
fn void collect_all_identifiers(String uri, String content, String prefix, DocumentList* docs, String stdlib_path, CompletionSink* sink) @private
{
	// 1. Current file
	collect_idents_from_content(content, prefix, sink);

	// Only search cross-file when there's a prefix (avoid flooding with every identifier)
	if (prefix.len == 0) return;

	// 2. Open documents
	for (sz d = 0; d < docs.size; d++)
	{
		if (docs.entries[d].uri == uri) continue;
		collect_idents_from_content(docs.entries[d].content, prefix, sink, docs.entries[d].get_tokens());
	}

	// 3. Project files on disk
	String file_path = uri_to_path(uri);
	IdentsScan scan = { prefix, sink };
	if (file_path.len > 0)
	{
		scan_project_dirs(file_path, &scan);
	}

	// 4. Imported stdlib modules
	if (stdlib_path.len > 0)
	{
		String[MAX_IMPORTS] imports;
		sz import_count = parse_imports(content, &imports);

		for (sz i = 0; i < import_count; i++)
		{
			// Strip "std::" prefix since stdlib_path already points to the std/ directory
			String mod = imports[i];
			if (mod.len > 5 && mod[:5] == "std::")
			{
				mod = mod[5..];
			}

			DString dir_buf = dstring::temp();
			String mod_dir = module_to_dir_path(mod, &dir_buf);

			DString full_dir = dstring::temp();
			full_dir.appendf("%s/%s", stdlib_path, mod_dir);
			scan_dir(full_dir.str_view(), &scan);
		}
	}
}

// Collect free function / macro declaration names from a token stream. Mirrors the
// FUNC/MACRO -> LPAREN -> preceding-IDENT logic in collect_declarations_from_content,
// so identifier completions can tag those names as callable (kind 3) and emit the
// "name($0)" snippet + parameter-hints command. Methods (Type.name) are skipped — they
// surface through the dot-completion path instead.
fn void collect_callable_names(TokenStream* stream, String[MAX_FILE_CALLABLES]* names, sz* count) @private
{
	for (sz i = 0; i < stream.tokens.size; i++)
	{
		TokenType tt = stream.tokens.entries[i].type;
		// Skip type bodies so an interface's method declarations aren't treated as
		// free callable names.
		if (tt == STRUCT || tt == BITSTRUCT || tt == UNION || tt == INTERFACE || tt == ENUM || tt == FAULTDEF)
		{
			i = stream.tokens.skip_type_body(i + 1);
			continue;
		}
		if (tt != FUNC && tt != MACRO) continue;

		String name = "";
		for (sz j = i + 1; j < stream.tokens.size && j < i + 64; j++)
		{
			if (stream.tokens.entries[j].type == LPAREN)
			{
				if (j > 0 && is_ident(stream.tokens.entries[j - 1].type))
				{
					if (j >= 2 && stream.tokens.entries[j - 2].type == DOT) break; // method
					name = stream.tokens.entries[j - 1].text;
				}
				break;
			}
			// Skip a generic type block `{...}` (e.g. a generic return type) — not the body.
			if (stream.tokens.entries[j].type == LBRACE)
			{
				j = stream.tokens.match_rbrace(j);
				if (j >= stream.tokens.size) break;
				continue;
			}
			if (stream.tokens.entries[j].type == EOS) break;
		}
		// macro name (no parens)
		if (name.len == 0 && tt == MACRO && i + 1 < stream.tokens.size && is_ident(stream.tokens.entries[i + 1].type))
		{
			name = stream.tokens.entries[i + 1].text;
		}
		if (name.len == 0) continue;

		bool dup = false;
		for (sz k = 0; k < *count; k++) { if ((*names)[k] == name) { dup = true; break; } }
		if (!dup && *count < MAX_FILE_CALLABLES) { (*names)[*count] = name; (*count)++; }
	}
}

// `cached` is the caller's already-tokenized stream for this content, when it has one.
// Tokenizing is the dominant cost of a completion request — every project and stdlib
// file is walked — and the client re-requests on every keystroke, so re-tokenizing what
// the file cache already holds is the difference between a snappy popup and a laggy one.
fn void collect_idents_from_content(String content, String prefix, CompletionSink* sink, TokenStream* cached = null) @private
{
	TokenStream owned;
	TokenStream* stream;
	if (cached != null) { stream = cached; }
	else { owned = token_stream_tokenize(content); stream = &owned; }
	defer { if (cached == null) owned.free(); }

	// Pre-pass: names declared as free functions/macros, so they complete as callables.
	String[MAX_FILE_CALLABLES] callables;
	sz callable_count = 0;
	collect_callable_names(stream, &callables, &callable_count);

	for (sz i = 0; i < stream.tokens.size; i++)
	{
		String text = stream.tokens.entries[i].text;
		int kind = 0;
		switch (stream.tokens.entries[i].type)
		{
			case IDENT:
				kind = 6; // Variable
				// Promote known free functions/macros to Function so they get the call snippet.
				for (sz k = 0; k < callable_count; k++)
				{
					if (callables[k] == text) { kind = 3; break; }
				}
			case TYPE_IDENT:
				kind = 22; // Struct (type)
			case CONST_IDENT:
				kind = 21; // Constant
			default:
				continue;
		}

		// Skip if same as prefix (don't suggest what's already typed)
		if (text == prefix) continue;

		sink.add(text, kind);
	}
}

// On-disk identifier completion, driven through the shared scan engine.
struct IdentsScan (FileVisitor) @private
{
	String prefix;
	CompletionSink* sink;
}

fn bool IdentsScan.visit(&self, String path, String content, TokenStream* stream) @dynamic
{
	if (self.sink.at_capacity()) return true; // scan budget spent — stop scanning
	collect_idents_from_content(content, self.prefix, self.sink, stream);
	return false;
}

// DOT-expression completion: resolve receiver type and collect fields + methods
fn void collect_dot_completions(String uri, String content, sz offset, DocumentList* docs, String stdlib_path, CompletionSink* sink) @private
{
	TokenStream owned;
	bool owns;
	TokenStream* stream = token_stream_for_doc(uri, content, docs, &owned, &owns);
	defer { if (owns) owned.free(); }

	// Find the token at cursor offset
	Token cursor_tok;
	sz cursor_idx;
	if (!stream.tokens.find_token_at(offset, &cursor_tok, &cursor_idx)) return;

	// If we landed on the DOT itself (cursor right after "foo."),
	// resolve_receiver_type expects cursor_idx to be the token AFTER the DOT
	if (cursor_tok.type == DOT)
	{
		cursor_idx = cursor_idx + 1;
	}

	// Struct-initializer designator (`(Type){ .field`, `Type v = { .field`, `, .field`)?
	// Only struct fields are valid there, so methods and enum members are not offered.
	bool initializer_context = false;
	sz init_lbrace;
	String recv_type;
	if (cursor_idx >= 2)
	{
		TokenType before_dot = stream.tokens.entries[cursor_idx - 2].type;
		if (before_dot == LBRACE || before_dot == COMMA)
		{
			recv_type = stream.tokens.resolve_initializer_type(cursor_idx, uri, docs, &init_lbrace, 0, stdlib_path);
			initializer_context = recv_type.len > 0;
		}
	}

	// Resolve receiver type
	if (!initializer_context) recv_type = stream.tokens.resolve_receiver_type(cursor_idx, uri, docs, stdlib_path);
	if (recv_type.len == 0)
	{
		// Not a named type — but it may still be a builtin array/slice/vector, which
		// carries no struct/method declarations, only the compiler-builtin `.len` and
		// (for slices) `.ptr` properties.
		bool is_slice;
		if (!initializer_context && stream.tokens.is_receiver_array(cursor_idx, uri, docs, &is_slice, stdlib_path))
		{
			emit_array_property_completions(is_slice, sink);
		}
		return;
	}

	// Follow the alias chain (LineOffsets -> List, Vec3 -> float[<3>]), searching the
	// stdlib too since that is where most aliases live. The alias may end at a builtin
	// array or vector, whose members are declared on a wildcard receiver.
	TypeInfo canon       = stream.tokens.canonical_type(recv_type, uri, docs, stdlib_path);
	String resolved_type = canon.name == recv_type ? "" : canon.name;

	TypeInfo recv        = { .name = recv_type };
	TypeInfo struct_info = resolved_type.len > 0 ? canon : recv;
	String struct_type   = struct_info.name;

	// Is the receiver a *type name* (`Config.`) rather than an instance (`value.`)?
	// On a type receiver, instance fields and methods are not accessible — only
	// enum/faultdef members (e.g. `Color.RED`) are. The receiver token sits two
	// positions before the cursor (…receiver `.` cursor).
	bool type_receiver = cursor_idx >= 2 && stream.tokens.entries[cursor_idx - 2].type == TYPE_IDENT;

	if (initializer_context)
	{
		// Fields already assigned in this initializer are not offered again.
		stream.tokens.seed_assigned_fields(init_lbrace, cursor_idx, sink);
	}

	// Two passes: first restricted to modules visible from this file (own module
	// tree, imports, std::core), so a local `struct Rectangle` does not merge
	// members with the stdlib's same-named `union Rectangle`. If the visible pass
	// emitted nothing (e.g. the defining module was never imported), rerun
	// module-blind so results never vanish outright.
	ModuleCtx ctx;
	ctx.build(&stream.tokens);
	ModuleCtx*[2] passes = { &ctx, null };
	foreach (pass_ctx : passes)
	{
		if (initializer_context)
		{
			// Initializer designators are fields only — methods and enum members
			// are not valid there.
			collect_struct_fields(struct_info, uri, content, docs, stdlib_path, sink, pass_ctx);
			if (struct_type != recv_type)
			{
				collect_struct_fields(recv, uri, content, docs, stdlib_path, sink, pass_ctx);
			}
		}
		else
		{
			if (!type_receiver)
			{
				// Collect struct fields (use resolved alias for struct lookup)
				collect_struct_fields(struct_info, uri, content, docs, stdlib_path, sink, pass_ctx);
				// Also try unresolved name for struct fields
				if (struct_type != recv_type)
				{
					collect_struct_fields(recv, uri, content, docs, stdlib_path, sink, pass_ctx);
				}

				// Collect methods (try original alias name first, then resolved)
				collect_type_methods(recv, uri, content, docs, stdlib_path, sink, pass_ctx);
				if (resolved_type.len > 0 && resolved_type != recv_type)
				{
					collect_type_methods(canon, uri, content, docs, stdlib_path, sink, pass_ctx);
				}
			}

			// Collect enum members (Type.MEMBER) — valid for both type and instance receivers.
			collect_enum_members(struct_info, uri, content, docs, stdlib_path, sink, pass_ctx);
			if (resolved_type.len > 0 && resolved_type != recv_type)
			{
				collect_enum_members(recv, uri, content, docs, stdlib_path, sink, pass_ctx);
			}
		}

		if (sink.count > 0) break; // this pass found members — no fallback needed
	}

	// An alias of a builtin array or vector (`alias Vec3 = float[<3>]`) also carries
	// the compiler-builtin `.len`, which no declaration scan can find.
	if (!initializer_context && !type_receiver && canon.is_array)
	{
		emit_array_property_completions(canon.is_slice, sink);
	}

	// A typedef of an inline builtin slice (`typedef String = inline char[];`)
	// forwards the compiler-builtin `.len`/`.ptr` properties of its underlying
	// slice, but declares no `fn`/`struct` of its own that the scan above can find.
	if (!initializer_context && !type_receiver)
	{
		bool is_slice;
		if (resolve_inline_slice_typedef(struct_type, uri, content, docs, stdlib_path, &is_slice))
		{
			emit_array_property_completions(is_slice, sink);
		}
		else if (struct_type != recv_type && resolve_inline_slice_typedef(recv_type, uri, content, docs, stdlib_path, &is_slice))
		{
			emit_array_property_completions(is_slice, sink);
		}
	}
}

// Whether `type_name` is a typedef of an inline builtin slice (only `String` in the
// stdlib today, but this also picks up any project-defined equivalent) — searches
// current file, open docs, project files, then stdlib; stops at the first match.
fn bool resolve_inline_slice_typedef(String type_name, String uri, String content, DocumentList* docs, String stdlib_path, bool* is_slice) @private
{
	// 1. Current file
	{
		TokenStream owned;
		bool owns;
		TokenStream* stream = token_stream_for_doc(uri, content, docs, &owned, &owns);
		bool found = stream.tokens.find_inline_slice_typedef(type_name, is_slice);
		if (owns) owned.free();
		if (found) return true;
	}

	// 2. Open documents
	for (sz d = 0; d < docs.size; d++)
	{
		if (docs.entries[d].uri == uri) continue;
		TokenStream* other = docs.entries[d].get_tokens();
		if (other.tokens.find_inline_slice_typedef(type_name, is_slice)) return true;
	}

	// 3 + 4. Project files on disk, then stdlib
	InlineSliceScan scan = { type_name, false, false };
	scan_project_then_stdlib(uri_to_path(uri), stdlib_path, &scan);
	if (scan.found)
	{
		*is_slice = scan.is_slice;
		return true;
	}
	return false;
}

struct InlineSliceScan (FileVisitor) @private
{
	String type_name;
	bool found;
	bool is_slice;
}

fn bool InlineSliceScan.visit(&self, String path, String content, TokenStream* stream) @dynamic
{
	bool slice;
	if (stream.tokens.find_inline_slice_typedef(self.type_name, &slice))
	{
		self.found = true;
		self.is_slice = slice;
		return true;
	}
	return false;
}

// Record field names already assigned in the initializer opened at lbrace_idx
// (`.name =` designators at brace depth 1) so they are not offered again.
// The designator currently being typed at cursor_idx is not counted.
fn void TokenList.seed_assigned_fields(&self, sz lbrace_idx, sz cursor_idx, CompletionSink* sink)
{
	sz depth = 1;
	for (sz j = lbrace_idx + 1; j < self.size && depth > 0; j++)
	{
		TokenType tt = self.entries[j].type;
		if (tt == LBRACE) { depth++; continue; }
		if (tt == RBRACE) { depth--; continue; }
		if (depth != 1) continue;
		if (tt != DOT || j + 2 >= self.size) continue;
		if (j + 1 == cursor_idx) continue; // the designator being completed
		if (!is_ident(self.entries[j + 1].type)) continue;
		if (self.entries[j + 2].type != EQ) continue;
		sink.suppress(self.entries[j + 1].text);
	}
}

// Collect all struct fields matching prefix from a TokenList.
// A non-null ctx skips declarations in modules not visible from the requesting file.
fn void TokenList.collect_struct_fields_into(&self, TypeInfo type, CompletionSink* sink, ModuleCtx* ctx)
{
	self.@each_struct_member(type.name, ctx; sz j)
	{
		// The declared type is the completion's detail text; a field in a comma list
		// (`Real m00, m10;`) carries none of its own, which is fine to leave blank.
		TypeInfo t;
		String detail = self.read_field_decl(j, &t) ? t.name : "";
		sink.add(self.entries[j].text, 5, detail); // 5 = Field
	};
}

// Collect all methods matching prefix from a TokenList (fn Type.method_name( patterns).
// A non-null ctx skips declarations in modules not visible from the requesting file.
fn void TokenList.collect_methods_into(&self, TypeInfo type, CompletionSink* sink, ModuleCtx* ctx)
{
	for (sz i = 0; i < self.size; i++)
	{
		if (self.entries[i].type != FUNC && self.entries[i].type != MACRO) continue;

		// Look for Type.method_name( pattern
		for (sz j = i + 1; j < self.size && j < i + 64; j++)
		{
			if (self.entries[j].type == LPAREN)
			{
				// `<Type>.name(` — the receiver may be a builtin carrying an array or
				// vector suffix (`float[<*>].length`), not just a plain TYPE_IDENT.
				if (j >= 3 && is_ident(self.entries[j - 1].type)
					&& self.method_receiver_matches(j - 1, type.name, type.is_array))
				{
					if (ctx != null && !ctx.can_see(self.module_of_decl(i))) break;
					sink.add(self.entries[j - 1].text, 2); // 2 = Method
				}
				break;
			}
			// Skip a generic type block `{...}` before the method's `(` — not the body.
			if (self.entries[j].type == LBRACE)
			{
				j = self.match_rbrace(j);
				if (j >= self.size) break;
				continue;
			}
			if (self.entries[j].type == EOS) break;
		}
	}
}

// Collect enum/faultdef members matching prefix from a TokenList (enum Type { MEMBER, ... } patterns).
// A non-null ctx skips declarations in modules not visible from the requesting file.
fn void TokenList.collect_enum_members_into(&self, TypeInfo type, CompletionSink* sink, ModuleCtx* ctx)
{
	for (sz i = 0; i + 1 < self.size; i++)
	{
		TokenType kw = self.entries[i].type;
		if (kw != ENUM && kw != FAULTDEF) continue;
		if (self.entries[i + 1].type != TYPE_IDENT || self.entries[i + 1].text != type.name) continue;
		if (ctx != null && !ctx.can_see(self.module_of_decl(i))) continue;

		sz brace = i + 2;
		while (brace < self.size && self.entries[brace].type != LBRACE) brace++;
		if (brace >= self.size) continue;

		// Members are the first CONST_IDENT after the opening brace or after each
		// top-level comma; the expect_member flag skips associated-value initializers
		// like `A = SOME_CONST`.
		sz depth = 1;
		bool expect_member = true;
		for (sz j = brace + 1; j < self.size && depth > 0; j++)
		{
			TokenType tt = self.entries[j].type;
			if (tt == LBRACE) { depth++; continue; }
			if (tt == RBRACE) { depth--; continue; }
			if (depth != 1) continue;
			if (tt == COMMA) { expect_member = true; continue; }
			if (!expect_member) continue;
			expect_member = false;

			if (tt != CONST_IDENT) continue;
			sink.add(self.entries[j].text, 20); // 20 = EnumMember
		}
	}
}

// Collect struct fields across current file, open docs, project files, and stdlib
// One member-collection routine per member kind (fields / methods / enum members) —
// all three share the same 4-step search, differing only in the TokenList collector.
alias MemberCollectFn = fn void(TokenList*, TypeInfo type, CompletionSink* sink, ModuleCtx* ctx);

struct MemberScan (FileVisitor) @private
{
	MemberCollectFn collect;
	TypeInfo type;
	CompletionSink* sink;
	ModuleCtx* ctx;
}

fn bool MemberScan.visit(&self, String path, String content, TokenStream* stream) @dynamic
{
	if (self.sink.at_capacity()) return true; // scan budget spent — stop scanning
	self.collect(&stream.tokens, self.type, self.sink, self.ctx);
	return false; // members of one type can be declared across many files — visit them all
}

// Collect type members (per `collect`) across current file, open docs, project files, and stdlib.
// A non-null ctx restricts matches to modules visible from the requesting file.
fn void collect_members_all(MemberCollectFn collect, TypeInfo type, String uri, String content, DocumentList* docs, String stdlib_path, CompletionSink* sink, ModuleCtx* ctx = null) @private
{
	// 1. Current file
	{
		TokenStream owned;
		bool owns;
		TokenStream* stream = token_stream_for_doc(uri, content, docs, &owned, &owns);
		defer { if (owns) owned.free(); }
		collect(&stream.tokens, type, sink, ctx);
	}

	// 2. Open documents (reuse their cached token streams)
	for (sz d = 0; d < docs.size; d++)
	{
		if (docs.entries[d].uri == uri) continue;
		TokenStream* other_stream = docs.entries[d].get_tokens();
		collect(&other_stream.tokens, type, sink, ctx);
	}

	// 3 + 4. Project files on disk, then stdlib
	MemberScan scan = { collect, type, sink, ctx };
	scan_project_then_stdlib(uri_to_path(uri), stdlib_path, &scan);
}

fn void collect_struct_fields(TypeInfo type, String uri, String content, DocumentList* docs, String stdlib_path, CompletionSink* sink, ModuleCtx* ctx = null) @private
{
	collect_members_all(&TokenList.collect_struct_fields_into, type, uri, content, docs, stdlib_path, sink, ctx);
}

fn void collect_type_methods(TypeInfo type, String uri, String content, DocumentList* docs, String stdlib_path, CompletionSink* sink, ModuleCtx* ctx = null) @private
{
	collect_members_all(&TokenList.collect_methods_into, type, uri, content, docs, stdlib_path, sink, ctx);
}

fn void collect_enum_members(TypeInfo type, String uri, String content, DocumentList* docs, String stdlib_path, CompletionSink* sink, ModuleCtx* ctx = null) @private
{
	collect_members_all(&TokenList.collect_enum_members_into, type, uri, content, docs, stdlib_path, sink, ctx);
}
