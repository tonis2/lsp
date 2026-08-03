module lsp;

import std::core::dstring;
import std::core::mem;
import std::collections::list;

// Cap on results for one workspace/symbol query. Clients render these in a picker,
// so scanning the whole project is fine but serializing everything in it is not.
const sz MAX_WORKSPACE_SYMBOL_RESULTS = 512;

fn char ascii_lower(char c) @private => (c >= 'A' && c <= 'Z') ? c + 32 : c;

// Case-insensitive substring match — the conventional workspace/symbol filter.
// An empty query matches nothing: clients send one for an empty picker box, and
// answering it with every declaration in the project is slow and useless.
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
 Whether one declaration answers `query`.

 `display` is what the client is shown — "Type.method" for a method — and an
 unqualified query matches against it, so searching for a type's name still
 turns up its methods. A query that named a type matches the bare method name
 instead: the type has already been checked, and matching the display form again
 would let `Camera.` answer with `FreeCamera.orbit`.

 A query that named a module or a type but no name matches every declaration
 that survives those two, which is the listing form. A query that named nothing
 at all matches nothing.
*>
fn bool symbol_query_matches(SymbolQuery query, String display, String name, String parent_type, String module_name) @private
{
	if (query.module_path.len > 0 && !symbol_matches_query(module_name, query.module_path)) return false;

	if (query.type.len > 0)
	{
		if (!same_type_name(parent_type, query.type)
			&& !same_type_name(parent_type, query.type_target)) return false;
		return query.name.len == 0 || symbol_matches_query(name, query.name);
	}

	if (query.name.len == 0) return query.module_path.len > 0;
	return symbol_matches_query(display, query.name);
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

// Append every declaration in one file that answers `query`.
fn void collect_workspace_symbols_in(String uri, String content, TokenStream* stream,
	SymbolQuery query, DString* out, bool* first, sz* count) @private
{
	if (*count >= MAX_WORKSPACE_SYMBOL_RESULTS) return;

	List{SymbolEntry} syms;
	syms.init(mem);
	defer syms.free();
	collect_symbols(content, stream, &syms);

	for (sz i = 0; i < syms.size && *count < MAX_WORKSPACE_SYMBOL_RESULTS; i++)
	{
		SymbolEntry* entry = &syms.entries[i];

		// Module and import entries describe file structure, not symbols someone
		// searches the workspace for.
		if (entry.sym.kind == 2) continue;

		// Methods are searchable under "Type.method" as well as bare "method",
		// which a substring query over the qualified name gives for free.
		DString display = dstring::temp();
		if (entry.parent_type.len > 0)
		{
			display.append(entry.parent_type);
			display.append_char('.');
		}
		display.append(entry.sym.name);
		String name = display.str_view();

		if (!symbol_query_matches(query, name, entry.sym.name, entry.parent_type, entry.module_name)) continue;

		int kind = entry.sym.kind == 6 ? 12 : entry.sym.kind; // 6 = Method -> 12 = Function

		if (!*first) out.append_char(',');
		*first = false;
		// selection_range covers just the identifier, so clients land on the name
		// rather than the start of the declaration.
		encode_symbol_information(out, name, kind, uri, entry.sym.selection_range, entry.module_name);
		(*count)++;
	}
}

// On-disk workspace-symbol collection, driven through the shared scan engine.
struct WorkspaceSymbolScan (FileVisitor) @private
{
	SymbolQuery query;
	DString* out;
	bool* first;
	sz* count;
	DocumentList* docs;
}

fn bool WorkspaceSymbolScan.visit(&self, String path, String content, TokenStream* stream) @dynamic
{
	// Open buffers were already searched, and their unsaved content wins.
	if (already_collected(path, "", self.docs)) return false;

	DString uri = dstring::temp();
	append_file_uri(&uri, path);
	collect_workspace_symbols_in(uri.str_view(), content, stream, self.query, self.out, self.first, self.count);
	return *self.count >= MAX_WORKSPACE_SYMBOL_RESULTS;
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

	bool first = true;
	sz count = 0;

	SymbolQuery parsed = parse_symbol_query(query);
	// One alias lookup for the whole request rather than one per declaration: a
	// miss costs a full walk of both trees, and the answer is the same every time.
	if (parsed.type.len > 0)
	{
		parsed.type_target = resolve_alias_anywhere(parsed.type, docs, anchor_path, stdlib_path);
	}

	if (docs != null)
	{
		for (sz d = 0; d < docs.size && count < MAX_WORKSPACE_SYMBOL_RESULTS; d++)
		{
			collect_workspace_symbols_in(docs.entries[d].uri, docs.entries[d].content,
				docs.entries[d].get_tokens(), parsed, out, &first, &count);
		}
	}

	WorkspaceSymbolScan scan = { parsed, out, &first, &count, docs };

	if (count < MAX_WORKSPACE_SYMBOL_RESULTS && anchor_path.len > 0)
	{
		scan_project_dirs(anchor_path, &scan);
	}

	if (count < MAX_WORKSPACE_SYMBOL_RESULTS && stdlib_path.len > 0)
	{
		scan_dir(stdlib_path, &scan);
	}

	out.append("]");
}
