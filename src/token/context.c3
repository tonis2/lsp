module lsp;

import std::core::dstring;
import std::core::mem;
import std::io::file;
import std::io::path;
import c3::lexer;

// AnalysisContext provides cross-document search with automatic hierarchy:
// 1. Current file
// 2. Open documents
// 3. Project files on disk
// 4. Stdlib

struct AnalysisContext {
	TokenStream* current;
	DocumentList* open_docs;
	String project_root;
	String[MAX_SEARCH_DIRS] search_dirs;
	usz search_dir_count;
	String stdlib_path;
}

// Initialize context with current document and search configuration
fn AnalysisContext analysis_context_init(
	TokenStream* current,
	DocumentList* open_docs,
	String file_path,
	String stdlib_path
) {
	AnalysisContext ctx;
	ctx.current = current;
	ctx.open_docs = open_docs;
	ctx.stdlib_path = stdlib_path;

	// Discover project directories
	ProjectDirs pdirs;
	pdirs.get_search_dirs(file_path);
	ctx.project_root = pdirs.project_root;
	ctx.search_dir_count = pdirs.count;
	for (usz i = 0; i < pdirs.count && i < MAX_SEARCH_DIRS; i++) {
		ctx.search_dirs[i] = pdirs.dirs[i];
	}

	return ctx;
}

// Find definition across all sources (current -> open docs -> project -> stdlib)
fn Location? AnalysisContext.find_definition(&self, Token target) {
	// 1. Search current file
	Token? decl = self.current.find_declaration_of(target, self.current.tokens.size);
	if (try d = decl) {
		return (Location) {.uri = "", .range = self.current.token_to_range(d)};
	}

	// 2. Search open documents
	for (usz i = 0; i < self.open_docs.size; i++) {
		Document doc = self.open_docs.entries[i];
		TokenStream stream = token_stream_tokenize(doc.content);
		defer stream.free();
		Token? found = stream.find_declaration_of(target, stream.tokens.size);
		if (try f = found) {
			return (Location) {.uri = doc.uri, .range = stream.token_to_range(f)};
		}
	}

	// 3. Scan project files
	if (self.project_root.len > 0) {
		Location? project_result = self.scan_project_for_definition(target);
		if (try loc = project_result) {
			return loc;
		}
	}

	// 4. Scan stdlib
	if (self.stdlib_path.len > 0) {
		Location? stdlib_result = self.scan_stdlib_for_definition(target);
		if (try loc = stdlib_result) {
			return loc;
		}
	}

	return TOKEN_NOT_FOUND~;
}

// Scan project directories for definition
fn Location? AnalysisContext.scan_project_for_definition(&self, Token target) {
	for (usz i = 0; i < self.search_dir_count; i++) {
		DString p = dstring::temp();
		p.appendf("%s/%s", self.project_root, self.search_dirs[i]);

		Location? result = self.scan_dir_for_definition(
			p.str_view(),
			target,
			0
		);
		if (try loc = result) {
			return loc;
		}
	}
	return TOKEN_NOT_FOUND~;
}

// Scan stdlib for definition
fn Location? AnalysisContext.scan_stdlib_for_definition(&self, Token target) {
	return self.scan_dir_for_definition(self.stdlib_path, target, 0);
}

// Recursively scan directory for definition
fn Location? AnalysisContext.scan_dir_for_definition(
	&self,
	String dir_path,
	Token target,
	int depth
) {
	if (depth > MAX_SCAN_DEPTH) return TOKEN_NOT_FOUND~;

	Path p;
	if (try pp = path::temp(dir_path)) {
		p = pp;
	} else {
		return TOKEN_NOT_FOUND~;
	}

	PathList entries;
	if (try el = path::ls(mem, p)) {
		entries = el;
	} else {
		return TOKEN_NOT_FOUND~;
	}
	defer {
		foreach (&e : entries) e.free();
		entries.free();
	}

	foreach (entry : entries) {
		String entry_name = entry.str_view();

		// Build full path
		char[] path_buf = mem::new_array(char, dir_path.len + 1 + entry_name.len);
		defer mem::free(path_buf);
		path_buf[:dir_path.len] = dir_path[:dir_path.len];
		path_buf[dir_path.len] = '/';
		path_buf[dir_path.len + 1..] = entry_name[:entry_name.len];
		String full_path = (String)path_buf;

		if (entry_name.ends_with(".c3") || entry_name.ends_with(".c3i")) {
			if (try file_content = file::load(mem, full_path)) {
				defer mem::free(file_content);

				TokenStream stream = token_stream_tokenize((String)file_content);
				defer stream.free();

				Token? found = stream.find_declaration_of(target, stream.tokens.size);
				if (try f = found) {
					DString uri = dstring::temp();
					append_file_uri(&uri, full_path);
					return (Location) {.uri = uri.str_view(), .range = stream.token_to_range(f)};
				}
			}
		} else {
			// Recurse into subdirectory
			Location? sub_result = self.scan_dir_for_definition(full_path, target, depth + 1);
			if (try loc = sub_result) {
				return loc;
			}
		}
	}

	return TOKEN_NOT_FOUND~;
}
