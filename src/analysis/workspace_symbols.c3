module lsp;

import std::core::dstring;
import std::core::mem;
import std::collections::list;

// Cap on results for one workspace/symbol query. Clients render these in a picker,
// so scanning the whole project is fine but serializing everything in it is not.
const sz MAX_WORKSPACE_SYMBOL_RESULTS = 512;

// Matching symbols examined before the scan gives up. Larger than the result cap so
// ranking has more candidates to choose from than it emits — files are visited in
// directory order, not in match order.
const sz MAX_WORKSPACE_SYMBOL_MATCHES = 4096;

// One matched declaration held back for ranking. `name` and `uri` are built in the
// request's temp pool by the caller, but `container` is a view into file content the
// scanner frees as soon as the visitor returns (see FileVisitor in scan.c3).
struct WorkspaceSymbolCandidate
{
	String name;
	String container;
	String uri;
	Range range;
	int kind;
	bool from_stdlib;
	FuzzyRank rank;
}

fn bool workspace_candidate_better(WorkspaceSymbolCandidate a, WorkspaceSymbolCandidate b) @private
{
	// The project's own declarations come before the standard library's however well a
	// std:: name scores. Ranking within one pool is a better answer to "which of these
	// did you mean"; ranking across both would undo the ordering encode_workspace_symbols
	// exists to enforce.
	if (a.from_stdlib != b.from_stdlib) return !a.from_stdlib;
	return fuzzy_rank_better(a.rank, b.rank);
}

// Collects matches, keeps the best MAX_WORKSPACE_SYMBOL_RESULTS, and writes them out
// best-first.
//
// Taking the first N found in directory order was defensible while the filter was a
// plain substring test — every hit contained the query, so one was as good as another.
// Subsequence matching widens the candidate set enough that the first N stops being a
// fair sample of it.
struct WorkspaceSymbolSink
{
	WorkspaceSymbolCandidate[MAX_WORKSPACE_SYMBOL_RESULTS] items;
	sz count;
	sz matched; // total matches seen, including those the cap dropped
}

// True once the scan budget is spent; the file visitor uses this to stop walking.
fn bool WorkspaceSymbolSink.at_capacity(&self)
{
	return self.matched >= MAX_WORKSPACE_SYMBOL_MATCHES;
}

// Offer a match, keeping the buffer in rank order. Once it is full a candidate has to
// beat the weakest kept item to get in.
fn void WorkspaceSymbolSink.add(&self, WorkspaceSymbolCandidate cand)
{
	self.matched++;

	if (self.count == MAX_WORKSPACE_SYMBOL_RESULTS
		&& !workspace_candidate_better(cand, self.items[self.count - 1])) return;

	sz pos;
	if (self.count < MAX_WORKSPACE_SYMBOL_RESULTS)
	{
		pos = self.count;
		self.count++;
	}
	else
	{
		pos = self.count - 1; // the weakest item falls off the end
	}
	while (pos > 0 && workspace_candidate_better(cand, self.items[pos - 1]))
	{
		self.items[pos] = self.items[pos - 1];
		pos--;
	}
	self.items[pos] = cand;
}

fn void WorkspaceSymbolSink.flush(&self, DString* out)
{
	for (sz i = 0; i < self.count; i++)
	{
		if (i > 0) out.append_char(',');
		WorkspaceSymbolCandidate cand = self.items[i];
		encode_symbol_information(out, cand.name, cand.kind, cand.uri, cand.range, cand.container);
	}
}

fn char ascii_lower(char c) @private => (c >= 'A' && c <= 'Z') ? c + 32 : c;

// Case-insensitive substring match. Still the right test for the module-path
// qualifier: that part of a query names a place rather than searching for one, and
// matching it as a subsequence would let `std::` answer with any module whose letters
// happen to line up.
fn bool symbol_matches_query(String name, String query) @private
{
	if (query.len == 0 || query.len > name.len) return false;

	for (sz i = 0; i + query.len <= name.len; i++)
	{
		bool hit = true;
		for (sz j = 0; j < query.len; j++)
		{
			if (ascii_lower(name[i + j]) != ascii_lower(query[j]))
			{
				hit = false;
				break;
			}
		}
		if (hit) return true;
	}
	return false;
}

<*
 A workspace/symbol query, split into the parts of a declaration it constrains.

 A client sends one free-text string and no options, so the two qualified forms
 are spelled into it: `math::acos` narrows by the module a declaration belongs
 to, `Quaternionf.to_axis` by the type a method hangs off. Either may stand
 alone — `std::` lists a library and `Camera.` lists one type's methods — and a
 query with neither is the plain substring search a picker box sends.

 `type_target` is what `type` resolves to when it is an alias, filled in by
 `encode_workspace_symbols`; methods can be declared on either name, so both are
 matched.
*>
struct SymbolQuery
{
	String module_path;
	String type;
	String type_target;
	String name;
}

fn String query_tail(String text, sz start) @private => start >= text.len ? "" : text[start..];

<*
 Split a query at its last `::` and its last `.`.

 Both separators are taken from the right, so a fully qualified name comes apart
 the way it was written: `std::math::quaternion::QuaternionNumber.to_axis_angle`
 leaves the module path whole and the type beside its method. The text before a
 separator is kept even when nothing follows it, which is what lets `std::` and
 `Camera.` list rather than match nothing.

 A `.` is only read as a type when something precedes it, so a query that is
 nothing but `.` stays a plain — and empty — name search.
*>
fn SymbolQuery parse_symbol_query(String query)
{
	SymbolQuery parsed = { .name = query };

	if (try idx = query.rindex_of("::"))
	{
		parsed.module_path = query[:idx];
		parsed.name = query_tail(query, idx + 2);
	}

	if (try idx = parsed.name.rindex_of("."))
	{
		if (idx > 0)
		{
			parsed.type = parsed.name[:idx];
			parsed.name = query_tail(parsed.name, idx + 1);
		}
	}

	return parsed;
}

fn bool same_type_name(String a, String b) @private => a.len > 0 && a.compare_to_ignore_case(b) == 0;

<*
 How well one declaration answers `query`, or an unmatched rank when it does not.

 `display` is what the client is shown — "Type.method" for a method — and an
 unqualified query matches against it, so searching for a type's name still
 turns up its methods. A query that named a type matches the bare method name
 instead: the type has already been checked, and matching the display form again
 would let `Camera.` answer with `FreeCamera.orbit`.

 The name is matched with the same fuzzy matcher completion uses, so "CompSink"
 finds CompletionSink here too, and the rank it returns is what orders the
 results. The module and type qualifiers are not fuzzy — see symbol_matches_query
 and same_type_name for why each is matched the way it is.

 A query that named a module or a type but no name matches every declaration
 that survives those two, which is the listing form; those all rank equally and
 fall back to the shortest name first. A query that named nothing at all matches
 nothing — clients send one for an empty picker box, and answering it with every
 declaration in the project is slow and useless.
*>
fn FuzzyRank symbol_query_rank(SymbolQuery query, String display, String name, String parent_type, String module_name) @private
{
	FuzzyRank no_match = { .matched = false };

	if (query.module_path.len > 0 && !symbol_matches_query(module_name, query.module_path)) return no_match;

	if (query.type.len > 0)
	{
		if (!same_type_name(parent_type, query.type)
			&& !same_type_name(parent_type, query.type_target)) return no_match;
		return fuzzy_rank_ci(name, query.name);
	}

	if (query.name.len == 0)
	{
		return query.module_path.len > 0 ? fuzzy_rank_ci(display, "") : no_match;
	}
	return fuzzy_rank_ci(display, query.name);
}

// Emit one SymbolInformation object.
fn void encode_symbol_information(DString* out, String name, int kind, String uri, Range range, String container) @private
{
	out.append(`{"name":"`);
	json_escape_into(out, name);
	out.appendf(`","kind":%d,"location":`, kind);
	Location loc = { .uri = uri, .range = range };
	loc.encode(out);
	if (container.len > 0)
	{
		out.append(`,"containerName":"`);
		json_escape_into(out, container);
		out.append_char('"');
	}
	out.append_char('}');
}

// Offer every declaration in one file that answers `query`.
fn void collect_workspace_symbols_in(String uri, String content, TokenStream* stream,
	SymbolQuery query, WorkspaceSymbolSink* sink, bool from_stdlib) @private
{
	if (sink.at_capacity()) return;

	List{SymbolEntry} syms;
	syms.init(mem);
	defer syms.free();
	collect_symbols(content, stream, &syms);

	for (sz i = 0; i < syms.size && !sink.at_capacity(); i++)
	{
		SymbolEntry* entry = &syms.entries[i];

		// Module and import entries describe file structure, not symbols someone
		// searches the workspace for.
		if (entry.sym.kind == 2) continue;

		// Methods are searchable under "Type.method" as well as bare "method": the
		// query is matched against the qualified name, and a bare-name match ranks
		// better than the same letters found after the "Type." prefix.
		DString display = dstring::temp();
		if (entry.parent_type.len > 0)
		{
			display.append(entry.parent_type);
			display.append_char('.');
		}
		display.append(entry.sym.name);
		String name = display.str_view();

		FuzzyRank rank = symbol_query_rank(query, name, entry.sym.name, entry.parent_type, entry.module_name);
		if (!rank.matched) continue;

		int kind = entry.sym.kind == 6 ? 12 : entry.sym.kind; // 6 = Method -> 12 = Function

		// selection_range covers just the identifier, so clients land on the name
		// rather than the start of the declaration.
		sink.add({
			.name = name,
			.container = completion_intern(entry.module_name),
			.uri = uri,
			.range = entry.sym.selection_range,
			.kind = kind,
			.from_stdlib = from_stdlib,
			.rank = rank,
		});
	}
}

// On-disk workspace-symbol collection, driven through the shared scan engine.
struct WorkspaceSymbolScan (FileVisitor) @private
{
	SymbolQuery query;
	WorkspaceSymbolSink* sink;
	DocumentList* docs;
	bool from_stdlib;
}

fn bool WorkspaceSymbolScan.visit(&self, String path, String content, TokenStream* stream) @dynamic
{
	// Open buffers were already searched, and their unsaved content wins.
	if (already_collected(path, "", self.docs)) return false;

	DString uri = dstring::temp();
	append_file_uri(&uri, path);
	collect_workspace_symbols_in(uri.str_view(), content, stream, self.query, self.sink, self.from_stdlib);
	return self.sink.at_capacity();
}

<*
 Encode a workspace/symbol response: every declaration that answers `query`, in
 the order the answers are worth having.

 Open documents first, so unsaved edits win, then the project's own sources on
 disk, then the standard library with whatever of the result cap is left. That
 order is what keeps the stdlib from burying the project: a query with plenty of
 local matches spends the budget before the scan reaches `std`, and one with
 none — a stdlib function nobody has written down yet — falls through to where
 the answer actually is. Searching the project alone leaves that second query
 with nothing to show and no way to tell "not there" from "not indexed".

 See `parse_symbol_query` for what a query may say beyond a name.

 @param anchor_path : `A file path inside the project; the scan engine finds project.json by walking up from it. Nothing on disk is searched when it is empty.`
 @param stdlib_path : `The standard library's root, or "" to leave it out.`
*>
fn void encode_workspace_symbols(String query, DocumentList* docs, String anchor_path, String stdlib_path, DString* out)
{
	out.append("[");

	SymbolQuery parsed = parse_symbol_query(query);
	// One alias lookup for the whole request rather than one per declaration: a
	// miss costs a full walk of both trees, and the answer is the same every time.
	if (parsed.type.len > 0)
	{
		parsed.type_target = resolve_alias_anywhere(parsed.type, docs, anchor_path, stdlib_path);
	}

	// Too large for the stack, and it lives exactly as long as the request does.
	WorkspaceSymbolSink* sink = mem::tnew(WorkspaceSymbolSink);

	if (docs != null)
	{
		for (sz d = 0; d < docs.size && !sink.at_capacity(); d++)
		{
			collect_workspace_symbols_in(docs.entries[d].uri, docs.entries[d].content,
				docs.entries[d].get_tokens(), parsed, sink, false);
		}
	}

	WorkspaceSymbolScan scan = { parsed, sink, docs, false };

	if (!sink.at_capacity() && anchor_path.len > 0)
	{
		scan_project_dirs(anchor_path, &scan);
	}

	// Whatever of the result cap the project left over. Ranking never lets a stdlib
	// match displace a project one, so this only ever fills space rather than taking it.
	if (sink.count < MAX_WORKSPACE_SYMBOL_RESULTS && !sink.at_capacity() && stdlib_path.len > 0)
	{
		scan.from_stdlib = true;
		scan_dir(stdlib_path, &scan);
	}

	sink.flush(out);
	out.append("]");
}
