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

// Append every declaration in one file whose name matches `query`.
fn void collect_workspace_symbols_in(String uri, String content, TokenStream* stream,
	String query, DString* out, bool* first, sz* count) @private
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

		if (!symbol_matches_query(name, query)) continue;

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
	String query;
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

// Encode a workspace/symbol response: every declaration in the project whose name
// contains `query`, case-insensitively. Open documents are searched first so
// unsaved edits win, then the project directories on disk. The stdlib is
// deliberately excluded — "workspace" means this project, and including it buries
// project symbols under thousands of std:: matches.
//
// `anchor_path` must be a file path inside the project: the scan engine locates
// project.json by walking up from it.
fn void encode_workspace_symbols(String query, DocumentList* docs, String anchor_path, DString* out)
{
	out.append("[");

	bool first = true;
	sz count = 0;

	if (docs != null)
	{
		for (sz d = 0; d < docs.size && count < MAX_WORKSPACE_SYMBOL_RESULTS; d++)
		{
			collect_workspace_symbols_in(docs.entries[d].uri, docs.entries[d].content,
				docs.entries[d].get_tokens(), query, out, &first, &count);
		}
	}

	if (count < MAX_WORKSPACE_SYMBOL_RESULTS && anchor_path.len > 0)
	{
		WorkspaceSymbolScan scan = { query, out, &first, &count, docs };
		scan_project_dirs(anchor_path, &scan);
	}

	out.append("]");
}
