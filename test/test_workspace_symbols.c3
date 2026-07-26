module lsp;

import std::core::mem;
import std::core::dstring;

// --- query matching ---

fn void test_symbol_query_is_case_insensitive_substring() @test {
	assert(symbol_matches_query("load_gltf", "gltf"), "substring must match");
	assert(symbol_matches_query("Scene.load_gltf", "LOAD"), "match must ignore case");
	assert(symbol_matches_query("Camera", "camera"), "match must ignore case both ways");
	assert(!symbol_matches_query("Camera", "xyz"), "unrelated query must not match");
	assert(!symbol_matches_query("ab", "abcd"), "query longer than name cannot match");
}

fn void test_symbol_query_empty_matches_nothing() @test {
	// Clients send an empty query for an empty picker box; answering with every
	// declaration in the project would be slow and useless.
	assert(!symbol_matches_query("Camera", ""), "empty query must match nothing");
}

// --- response encoding ---

fn void test_workspace_symbols_finds_open_document_symbol() @test {
	DocumentList* ds = mem::new(DocumentList);
	defer mem::free(ds);
	ds.open("file:///proj/src/camera.c3", "module camera;\nstruct Camera {}\nfn void Camera.rotate(&self) {}", 1);

	DString out = dstring::temp();
	encode_workspace_symbols("Camera", ds, "", &out);
	String r = out.str_view();

	assert(r.contains(`"name":"Camera"`), "struct must be found, got: %s", r);
	assert(r.contains(`"name":"Camera.rotate"`), "method must be qualified with its type, got: %s", r);
	assert(r.contains(`file:///proj/src/camera.c3`), "result must carry its location, got: %s", r);
	assert(r.contains(`"containerName":"camera"`), "declaring module must be the container, got: %s", r);

	ds.close("file:///proj/src/camera.c3");
}

fn void test_workspace_symbols_filters_by_query() @test {
	DocumentList* ds = mem::new(DocumentList);
	defer mem::free(ds);
	ds.open("file:///proj/src/a.c3", "module a;\nfn void wanted() {}\nfn void other() {}", 1);

	DString out = dstring::temp();
	encode_workspace_symbols("wanted", ds, "", &out);
	String r = out.str_view();

	assert(r.contains(`"name":"wanted"`), "matching symbol must be present, got: %s", r);
	assert(!r.contains(`"name":"other"`), "non-matching symbol must be filtered out, got: %s", r);

	ds.close("file:///proj/src/a.c3");
}

fn void test_workspace_symbols_excludes_module_and_import_entries() @test {
	DocumentList* ds = mem::new(DocumentList);
	defer mem::free(ds);
	ds.open("file:///proj/src/b.c3", "module mymod;\nimport mymod_helper;\nfn void mymod_fn() {}", 1);

	DString out = dstring::temp();
	encode_workspace_symbols("mymod", ds, "", &out);
	String r = out.str_view();

	// The function matches the query; the module and import declarations describe
	// file structure and are not workspace symbols.
	assert(r.contains(`"name":"mymod_fn"`), "function must be found, got: %s", r);
	assert(!r.contains(`"name":"mymod"`), "module decl must not be a workspace symbol, got: %s", r);
	assert(!r.contains(`"name":"mymod_helper"`), "import must not be a workspace symbol, got: %s", r);

	ds.close("file:///proj/src/b.c3");
}

fn void test_workspace_symbols_empty_query_yields_empty_array() @test {
	DocumentList* ds = mem::new(DocumentList);
	defer mem::free(ds);
	ds.open("file:///proj/src/c.c3", "module c;\nfn void thing() {}", 1);

	DString out = dstring::temp();
	encode_workspace_symbols("", ds, "", &out);
	// Must still be valid JSON — an empty buffer would produce `"result":` and
	// drop the connection.
	assert(out.str_view() == "[]", "expected empty array, got: %s", out.str_view());

	ds.close("file:///proj/src/c.c3");
}

fn void test_workspace_symbols_no_match_yields_empty_array() @test {
	DocumentList* ds = mem::new(DocumentList);
	defer mem::free(ds);
	ds.open("file:///proj/src/d.c3", "module d;\nfn void thing() {}", 1);

	DString out = dstring::temp();
	encode_workspace_symbols("zzz_no_such_symbol", ds, "", &out);
	assert(out.str_view() == "[]", "expected empty array, got: %s", out.str_view());

	ds.close("file:///proj/src/d.c3");
}

fn void test_workspace_symbols_capability_is_advertised() @test {
	DString out = dstring::temp();
	encode_server_capabilities(&out, "0.0.0");
	assert(out.str_view().contains(`"workspaceSymbolProvider":true`),
		"capability must be advertised or clients never send the request, got: %s", out.str_view());
}
