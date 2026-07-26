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

// Read the "sources" list from a .c3l library's manifest.json, reduced to the
// directories it names. Returns false when there is no usable manifest, so the
// caller falls back to walking the whole library directory.
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
				sz srcs_len = srcs.get_len();
				for (sz i = 0; i < srcs_len && *count < MAX_C3L_SOURCES; i++)
				{
					Object* item = srcs.get_at(i);
					if (item == null) break;
					if (!item.is_string()) continue;
					String src_dir = source_entry_dir(item.s);
					if (src_dir.len == 0) continue;
					(*out)[(*count)++] = src_dir;
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
				DString sub = dstring::temp();
				sub.appendf("%s/%s", dir_path, src_dirs[i]);
				if (scan_dir(sub.str_view(), visitor, depth + 1)) return true;
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
		DString search_path = dstring::temp();
		search_path.appendf("%s/%s", pdirs.project_root, pdirs.dirs[i]);
		if (scan_dir(search_path.str_view(), visitor))
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
