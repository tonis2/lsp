module lsp;

import std::core::dstring;
import std::core::mem;
import std::io::file;
import std::io::path;
import std::encoding::json;
import std::collections::object;

// Shared on-disk file walker for all cross-file searches (definitions, hover docs,
// references, rename, signatures, completions). Callers implement FileVisitor on a
// small per-feature struct carrying the search state, and pass `&that_struct`.

interface FileVisitor
{
	// Inspect one tokenized file. Return true to stop the scan (hit found / capacity
	// reached), false to continue. `path` is the on-disk path (not a URI); `content`
	// and `stream` are only valid during the call — copy anything you keep.
	fn bool visit(String path, String content, TokenStream* stream);
}

const int MAX_SCAN_DEPTH = 5;
const int MAX_C3L_SOURCES = 16;

// Join a search dir onto a base path. A normalized "." names the base itself, so it
// contributes no segment — appending it would produce "<base>/./file.c3", which then
// travels into the file:// URIs handed to the client and into the path-vs-URI
// comparisons that stop on-disk hits from duplicating open-document ones.
fn String join_search_path(String base, String rel) @private
{
	if (rel.len == 0 || rel == ".") return base;
	DString joined = dstring::temp();
	joined.appendf("%s/%s", base, rel);
	return joined.str_view();
}

// Add one manifest "sources" entry, reduced to its directory, keeping the set free
// of overlapping dirs. Same rule as the project search dirs: a manifest listing both
// "main.c3" (-> ".") and "linux/**" must not walk linux/ twice.
fn void add_c3l_source_dir(String[MAX_C3L_SOURCES]* out, sz* count, String raw) @private
{
	String src_dir = source_entry_dir(raw);
	if (src_dir.len == 0) return;
	src_dir = normalize_search_dir(src_dir);

	for (sz k = 0; k < *count; k++)
	{
		if (dir_covers((*out)[k], src_dir)) return;
	}
	sz keep = 0;
	for (sz k = 0; k < *count; k++)
	{
		if (dir_covers(src_dir, (*out)[k])) continue;
		(*out)[keep++] = (*out)[k];
	}
	*count = keep;

	if (*count >= MAX_C3L_SOURCES) return;
	(*out)[(*count)++] = src_dir;
}

// Collect the directories one "sources" array names.
fn void add_c3l_sources_array(String[MAX_C3L_SOURCES]* out, sz* count, Object* srcs) @private
{
	sz srcs_len = srcs.get_len();
	for (sz i = 0; i < srcs_len && *count < MAX_C3L_SOURCES; i++)
	{
		Object* item = srcs.get_at(i);
		if (item == null) break;
		if (!item.is_string()) continue;
		add_c3l_source_dir(out, count, item.s);
	}
}

// Read the source directories a .c3l library's manifest.json declares. Returns false
// when there is no usable manifest, so the caller falls back to walking the whole
// library directory.
//
// A manifest may declare sources at the top level, per build target, or both. Many
// libraries only do the latter — one source list per platform triple — so both are
// read: every target's sources count, because the platform being edited is not
// necessarily the host. Without this such a library falls back to a full-archive walk
// that pulls in test/ and examples/, which are not part of the compilation unit.
fn bool c3l_source_dirs(String lib_path, String[MAX_C3L_SOURCES]* out, sz* count) @private
{
	*count = 0;

	DString manifest_path = dstring::temp();
	manifest_path.appendf("%s/manifest.json", lib_path);

	if (try raw = file::load(mem, manifest_path.str_view()))
	{
		defer mem::free(raw);
		String clean_json = strip_json_comments((String)raw);
		if (try manifest = json::tparse(clean_json))
		{
			if (try srcs = manifest.get("sources"))
			{
				add_c3l_sources_array(out, count, srcs);
			}
			if (try targets = manifest.get("targets"))
			{
				if (targets.is_map())
				{
					targets.map.@each(; String key, Object* tgt)
					{
						if (try tgt_srcs = tgt.get("sources"))
						{
							add_c3l_sources_array(out, count, tgt_srcs);
						}
					};
				}
			}
		}
	}
	return *count > 0;
}

// Walk dir_path, visiting every .c3/.c3i file.
//
// A `.c3l` library directory is restricted to the directories its manifest.json
// declares as sources. The rest of such an archive — examples/, test/, build/,
// vendored libs/ — is not part of this project's compilation unit, so symbols
// found there are not symbols of this project.
fn bool scan_dir(String dir_path, FileVisitor visitor, int depth = 0)
{
	if (depth > MAX_SCAN_DEPTH) return false;

	if (dir_path.ends_with(".c3l"))
	{
		String[MAX_C3L_SOURCES] src_dirs;
		sz src_count;
		if (c3l_source_dirs(dir_path, &src_dirs, &src_count))
		{
			for (sz i = 0; i < src_count; i++)
			{
				// "." names the library root itself (a manifest entry like "main.c3").
				// Walk its entries directly: re-entering scan_dir would re-read the
				// manifest and recurse on the same path until the depth cap, visiting
				// nothing at all.
				if (src_dirs[i] == ".")
				{
					if (scan_dir_entries(dir_path, visitor, depth)) return true;
					continue;
				}
				if (scan_dir(join_search_path(dir_path, src_dirs[i]), visitor, depth + 1)) return true;
			}
			return false;
		}
	}

	return scan_dir_entries(dir_path, visitor, depth);
}

// Recursively walk dir_path, visiting every .c3/.c3i file. Non-source entries are
// recursed into as directories; unreadable paths are silently skipped. Tokenized
// streams come from the mtime-keyed file cache; owned streams/content are freed
// after the visitor returns.
fn bool scan_dir_entries(String dir_path, FileVisitor visitor, int depth) @private
{
	Path p;
	if (try pp = path::tnew(dir_path))
	{
		p = pp;
	}
	else
	{
		return false;
	}
	// Only directories from here on. path::ls allocates its result list before reading
	// the directory and rethrows without freeing it when the read fails, so calling it
	// on a plain file (every non-source entry the walk recurses into — project.json,
	// README.md, ...) leaks the list. Checking first also skips a doomed syscall.
	if (!path::is_dir(p)) return false;
	PathList entries;
	if (try el = path::ls(mem, p))
	{
		entries = el;
	}
	else
	{
		// Not a directory or can't read — silently skip
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
		// Build full path: dir_path/entry_name
		char[] path_buf = mem::new_array(char, dir_path.len + 1 + entry_name.len);
		defer mem::free(path_buf);
		path_buf[:dir_path.len] = dir_path[:dir_path.len];
		path_buf[dir_path.len] = '/';
		path_buf[dir_path.len + 1..] = entry_name[:entry_name.len];
		String full_path = (String)path_buf;

		if (entry_name.ends_with(".c3") || entry_name.ends_with(".c3i"))
		{
			// Read and tokenize this file (cached on disk by path+mtime)
			TokenStream owned;
			String content;
			bool owns;
			if (try stream = file_token_stream(full_path, &owned, &content, &owns))
			{
				bool stop = visitor.visit(full_path, content, stream);
				if (owns) { owned.free(); mem::free((char*)content.ptr); }
				if (stop) return true;
			}
		}
		else
		{
			// Try to recurse into subdirectories
			if (scan_dir(full_path, visitor, depth + 1))
			{
				return true;
			}
		}
	}
	return false;
}

// Walk every project search dir (from project.json discovered via file_path).
// Returns false immediately when no project root is found.
fn bool scan_project_dirs(String file_path, FileVisitor visitor)
{
	ProjectDirs pdirs;
	pdirs.get_search_dirs(file_path);
	if (pdirs.project_root.len == 0) return false;

	for (sz i = 0; i < pdirs.count; i++)
	{
		if (scan_dir(join_search_path(pdirs.project_root, pdirs.dirs[i]), visitor))
		{
			return true;
		}
	}
	return false;
}

// The ubiquitous "project files, then stdlib" tail of the 4-step search.
fn bool scan_project_then_stdlib(String file_path, String stdlib_path, FileVisitor visitor)
{
	if (file_path.len > 0 && scan_project_dirs(file_path, visitor)) return true;
	if (stdlib_path.len > 0 && scan_dir(stdlib_path, visitor)) return true;
	return false;
}
