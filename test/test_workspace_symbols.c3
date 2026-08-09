module lsp;

import std::core::mem;
import std::core::dstring;

// --- query matching ---

// The picker shares the completion matcher, so everything a substring query used to
// find still matches — it is now the tightest kind of match rather than the only kind.
fn void test_symbol_query_is_case_insensitive_substring() @test {
	assert(fuzzy_match_ci("load_gltf", "gltf"), "substring must match");
	assert(fuzzy_match_ci("Scene.load_gltf", "LOAD"), "match must ignore case");
	assert(fuzzy_match_ci("Camera", "camera"), "match must ignore case both ways");
	assert(!fuzzy_match_ci("Camera", "xyz"), "unrelated query must not match");
	assert(!fuzzy_match_ci("ab", "abcd"), "query longer than name cannot match");
}

// The point of the change: a query whose letters are in order but not adjacent now
// finds the symbol, which the old substring filter could not.
fn void test_symbol_query_matches_subsequence() @test {
	assert(fuzzy_match_ci("CompletionSink", "CompSink"), "subsequence must match");
	assert(fuzzy_match_ci("Scene.load_gltf", "sldgl"), "subsequence across the qualified name must match");
	assert(!fuzzy_match_ci("CompletionSink", "SinkComp"), "out-of-order letters must not match");
}


// --- response encoding ---

// Returns the position of `name` in the response, or -1 when it is absent.
fn sz symbol_position(String result, String name) @private {
	DString needle = dstring::temp();
	needle.appendf(`"name":"%s"`, name);
	if (try at = result.index_of(needle.str_view())) return (sz)at;
	return -1;
}

// Results come back best-match-first, not in the order the files were walked.
// MainCamera is declared first so scan order and rank order disagree.
fn void test_workspace_symbols_are_ranked() @test {
	DocumentList* ds = mem::new(DocumentList);
	defer mem::free(ds);
	ds.open("file:///proj/src/scene.c3", "module scene;\nstruct MainCamera {}\nstruct Camera {}\nstruct CameraController {}", 1);

	DString out = dstring::temp();
	encode_workspace_symbols("cam", ds, "", &out);
	String r = out.str_view();

	sz camera = symbol_position(r, "Camera");
	sz main_camera = symbol_position(r, "MainCamera");
	assert(camera >= 0 && main_camera >= 0, "both should match cam, got: %s", r);
	assert(camera < main_camera, "the prefix match should come first, got: %s", r);

	ds.close("file:///proj/src/scene.c3");
}

// The reason for the change: letters in order but not adjacent now find the symbol.
fn void test_workspace_symbols_match_subsequence() @test {
	DocumentList* ds = mem::new(DocumentList);
	defer mem::free(ds);
	ds.open("file:///proj/src/scene.c3", "module scene;\nstruct CameraController {}\nstruct Buffer {}", 1);

	DString out = dstring::temp();
	encode_workspace_symbols("CamCtrl", ds, "", &out);
	String r = out.str_view();
	assert(r.contains(`"name":"CameraController"`), "CamCtrl should find CameraController, got: %s", r);
	assert(!r.contains(`"name":"Buffer"`), "Buffer should not match CamCtrl, got: %s", r);

	ds.close("file:///proj/src/scene.c3");
}

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

// A file may declare several modules in sequence. Each symbol belongs to the module
// declared closest above it, not to the first one in the file — the regression here
// reported `c3w`'s Window as living in `std::core::env` because that module happened
// to be declared on line 1.
fn void test_workspace_symbols_uses_nearest_preceding_module() @test {
	DocumentList* ds = mem::new(DocumentList);
	defer mem::free(ds);
	ds.open("file:///proj/lib/main.c3",
		"module std::core::env;\n\nmodule c3w;\nimport std;\n\nstruct Wobble {}\n", 1);

	DString out = dstring::temp();
	encode_workspace_symbols("Wobble", ds, "", &out);
	String r = out.str_view();

	assert(r.contains(`"name":"Wobble"`), "struct must be found, got: %s", r);
	assert(r.contains(`"containerName":"c3w"`), "container must be the nearest module above, got: %s", r);
	assert(!r.contains(`"containerName":"std::core::env"`), "first module in file must not win, got: %s", r);

	ds.close("file:///proj/lib/main.c3");
}

// Declarations before any `module` line have no container to report.
fn void test_workspace_symbols_module_less_declaration_has_no_container() @test {
	DocumentList* ds = mem::new(DocumentList);
	defer mem::free(ds);
	ds.open("file:///proj/src/snippet.c3", "fn void loose_fn() {}\n", 1);

	DString out = dstring::temp();
	encode_workspace_symbols("loose_fn", ds, "", &out);
	String r = out.str_view();

	assert(r.contains(`"name":"loose_fn"`), "function must be found, got: %s", r);
	assert(!r.contains(`"containerName"`), "module-less decl must omit containerName, got: %s", r);

	ds.close("file:///proj/src/snippet.c3");
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
