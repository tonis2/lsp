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

// One matched symbol held back for ranking. `name` and `uri` are built in the request's
// temp pool by the caller, but `container` is a view into file content the scanner frees
// as soon as the visitor returns (see FileVisitor in scan.c3), so it is interned.
struct WorkspaceSymbolCandidate
{
	String name;
	String container;
	String uri;
	Range range;
	int kind;
	FuzzyRank rank;
}

// Collects matches, keeps the best MAX_WORKSPACE_SYMBOL_RESULTS by fuzzy rank, and
// writes them out best-first.
//
// The picker used to take the first N found in directory order, which was defensible
// while the filter was a plain substring test — every hit contained the query, so one
// was as good as another. Subsequence matching widens the candidate set enough that
// the first N stops being a fair sample of it.
struct WorkspaceSymbolSink
{
	WorkspaceSymbolCandidate[MAX_WORKSPACE_SYMBOL_RESULTS] items;
	sz count;
	sz matched; // total matches seen, including those the cap dropped
	String query;
}

fn void WorkspaceSymbolSink.init(&self, String query)
{
	self.count = 0;
	self.matched = 0;
	self.query = query;
}

// True once the scan budget is spent; the file visitor uses this to stop walking.
fn bool WorkspaceSymbolSink.at_capacity(&self)
{
	return self.matched >= MAX_WORKSPACE_SYMBOL_MATCHES;
}

// Offer a matched symbol, keeping the buffer in rank order. Once it is full a candidate
// has to beat the weakest kept item to get in.
fn void WorkspaceSymbolSink.add(&self, WorkspaceSymbolCandidate cand)
{
	self.matched++;

	if (self.count == MAX_WORKSPACE_SYMBOL_RESULTS
		&& !fuzzy_rank_better(cand.rank, self.items[self.count - 1].rank)) return;

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
	while (pos > 0 && fuzzy_rank_better(cand.rank, self.items[pos - 1].rank))
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

// Offer every declaration in one file whose name matches the sink's query.
fn void collect_workspace_symbols_in(String uri, String content, TokenStream* stream,
	WorkspaceSymbolSink* sink) @private
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
		// query is matched against the qualified name, and a bare-name match scores
		// better than the same letters found after the "Type." prefix.
		DString display = dstring::temp();
		if (entry.parent_type.len > 0)
		{
			display.append(entry.parent_type);
			display.append_char('.');
		}
		display.append(entry.sym.name);
		String name = display.str_view();

		FuzzyRank rank = fuzzy_rank_ci(name, sink.query);
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
			.rank = rank,
		});
	}
}

// On-disk workspace-symbol collection, driven through the shared scan engine.
struct WorkspaceSymbolScan (FileVisitor) @private
{
	WorkspaceSymbolSink* sink;
	DocumentList* docs;
}

fn bool WorkspaceSymbolScan.visit(&self, String path, String content, TokenStream* stream) @dynamic
{
	// Open buffers were already searched, and their unsaved content wins.
	if (already_collected(path, "", self.docs)) return false;

	DString uri = dstring::temp();
	append_file_uri(&uri, path);
	collect_workspace_symbols_in(uri.str_view(), content, stream, self.sink);
	return self.sink.at_capacity();
}

// Encode a workspace/symbol response: every declaration in the project whose name
// fuzzy-matches `query`, best match first — the same matcher completion uses, so
// "CompSink" finds CompletionSink here just as it does in the completion list.
// Open documents are searched first so unsaved edits win, then the project
// directories on disk. The stdlib is deliberately excluded — "workspace" means this
// project, and including it buries project symbols under thousands of std:: matches.
//
// An empty query matches nothing: clients send one for an empty picker box, and
// answering it with every declaration in the project is slow and useless.
//
// `anchor_path` must be a file path inside the project: the scan engine locates
// project.json by walking up from it.
fn void encode_workspace_symbols(String query, DocumentList* docs, String anchor_path, DString* out)
{
	out.append("[");

	if (query.len == 0)
	{
		out.append("]");
		return;
	}

	// Too large for the stack, and it lives exactly as long as the request does.
	WorkspaceSymbolSink* sink = mem::tnew(WorkspaceSymbolSink);
	sink.init(query);

	if (docs != null)
	{
		for (sz d = 0; d < docs.size && !sink.at_capacity(); d++)
		{
			collect_workspace_symbols_in(docs.entries[d].uri, docs.entries[d].content,
				docs.entries[d].get_tokens(), sink);
		}
	}

	if (!sink.at_capacity() && anchor_path.len > 0)
	{
		WorkspaceSymbolScan scan = { sink, docs };
		scan_project_dirs(anchor_path, &scan);
	}

	sink.flush(out);
	out.append("]");
}
