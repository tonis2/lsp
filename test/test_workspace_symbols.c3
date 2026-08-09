module lsp;

import std::core::mem;
import std::core::dstring;
import std::io::file;

// --- query matching ---

// The module-path qualifier keeps the substring test: that part of a query names a
// place rather than searching for one.
fn void test_symbol_module_path_is_case_insensitive_substring() @test {
	assert(symbol_matches_query("std::math::quaternion", "math"), "substring must match");
	assert(symbol_matches_query("std::io", "IO"), "match must ignore case");
	assert(!symbol_matches_query("std::io", "xyz"), "unrelated query must not match");
	assert(!symbol_matches_query("io", "stdio"), "query longer than name cannot match");
}

// The name term uses the completion matcher, so everything a substring query used to
// find still matches — it is now the tightest kind of match rather than the only kind.
fn void test_symbol_name_query_still_matches_substrings() @test {
	assert(fuzzy_match_ci("load_gltf", "gltf"), "substring must match");
	assert(fuzzy_match_ci("Scene.load_gltf", "LOAD"), "match must ignore case");
	assert(fuzzy_match_ci("Camera", "camera"), "match must ignore case both ways");
	assert(!fuzzy_match_ci("Camera", "xyz"), "unrelated query must not match");
	assert(!fuzzy_match_ci("ab", "abcd"), "query longer than name cannot match");
}

// The point of the change: letters in order but not adjacent now find the symbol.
fn void test_symbol_name_query_matches_subsequence() @test {
	assert(fuzzy_match_ci("CompletionSink", "CompSink"), "subsequence must match");
	assert(fuzzy_match_ci("Scene.load_gltf", "sldgl"), "subsequence across the qualified name must match");
	assert(!fuzzy_match_ci("CompletionSink", "SinkComp"), "out-of-order letters must not match");
}

fn void test_symbol_query_splits_module_and_type() @test {
	SymbolQuery plain = parse_symbol_query("acos");
	assert(plain.module_path == "" && plain.type == "" && plain.name == "acos",
		"an unqualified query is all name, got module=%s type=%s name=%s", plain.module_path, plain.type, plain.name);

	SymbolQuery scoped = parse_symbol_query("math::acos");
	assert(scoped.module_path == "math" && scoped.name == "acos",
		"`::` must split module from name, got module=%s name=%s", scoped.module_path, scoped.name);

	SymbolQuery member = parse_symbol_query("Camera.rotate");
	assert(member.type == "Camera" && member.name == "rotate",
		"`.` must split type from name, got type=%s name=%s", member.type, member.name);

	// Split from the right, so the module path survives whole.
	SymbolQuery full = parse_symbol_query("std::math::quaternion::QuaternionNumber.to_axis_angle");
	assert(full.module_path == "std::math::quaternion" && full.type == "QuaternionNumber"
		&& full.name == "to_axis_angle",
		"a fully qualified query must come apart as written, got module=%s type=%s name=%s",
		full.module_path, full.type, full.name);
}

// The listing forms: text before a separator with nothing after it. These are what
// make "show me this library" and "show me this type's methods" expressible at all,
// so an empty tail must not collapse back to the empty query that matches nothing.
fn void test_symbol_query_keeps_an_empty_tail() @test {
	SymbolQuery library = parse_symbol_query("std::");
	assert(library.module_path == "std" && library.name == "", "`std::` must list a module, got module=%s name=%s",
		library.module_path, library.name);

	SymbolQuery members = parse_symbol_query("Camera.");
	assert(members.type == "Camera" && members.name == "", "`Camera.` must list a type, got type=%s name=%s",
		members.type, members.name);

	// A leading dot names no type — there is nothing before it to be one.
	SymbolQuery lone = parse_symbol_query(".");
	assert(lone.type == "" && lone.name == ".", "a lone dot is not a type query, got type=%s name=%s",
		lone.type, lone.name);
}

fn void test_symbol_query_matches_by_module_and_type() @test {
	SymbolQuery scoped = parse_symbol_query("math::angle");
	assert(symbol_query_rank(scoped, "to_angle", "to_angle", "", "std::math::quaternion").matched,
		"a module fragment must match anywhere in the path");
	assert(!symbol_query_rank(scoped, "to_angle", "to_angle", "", "std::io").matched,
		"a symbol outside the named module must not match");

	// The type is matched whole, not as a substring: a substring test over the
	// "Type.method" display form lets `Camera.` answer with `FreeCamera.orbit`.
	SymbolQuery member = parse_symbol_query("Camera.");
	assert(symbol_query_rank(member, "Camera.rotate", "rotate", "Camera", "app").matched,
		"a listing query must match every method on the type");
	assert(!symbol_query_rank(member, "FreeCamera.orbit", "orbit", "FreeCamera", "app").matched,
		"a type whose name merely ends with the query must not match");
	assert(!symbol_query_rank(member, "Camera", "Camera", "", "app").matched,
		"the type itself is not one of its own members");
}

// An empty query matches nothing — clients send one for an empty picker box, and the
// fuzzy matcher on its own treats an empty pattern as matching everything.
fn void test_symbol_query_empty_matches_nothing() @test {
	SymbolQuery empty = parse_symbol_query("");
	assert(!symbol_query_rank(empty, "Camera", "Camera", "", "app").matched, "empty query must match nothing");
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
	encode_workspace_symbols("cam", ds, "", "", &out);
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
	encode_workspace_symbols("CamCtrl", ds, "", "", &out);
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
	encode_workspace_symbols("Camera", ds, "", "", &out);
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
	encode_workspace_symbols("Wobble", ds, "", "", &out);
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
	encode_workspace_symbols("loose_fn", ds, "", "", &out);
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
	encode_workspace_symbols("wanted", ds, "", "", &out);
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
	encode_workspace_symbols("mymod", ds, "", "", &out);
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
	encode_workspace_symbols("", ds, "", "", &out);
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
	encode_workspace_symbols("zzz_no_such_symbol", ds, "", "", &out);
	assert(out.str_view() == "[]", "expected empty array, got: %s", out.str_view());

	ds.close("file:///proj/src/d.c3");
}

// --- the standard library ---

// A name nobody has written down yet is exactly the one worth searching for, and
// the project cannot answer it. Without this the response is an empty array, which
// reads as "no such symbol" when it means "not looked for".
fn void test_workspace_symbols_reach_the_stdlib() @test {
	mkdirs("/tmp/lsp_ws_std_reach/math");
	file::save("/tmp/lsp_ws_std_reach/math/quaternion.c3",
		"module std::math::quaternion;\nstruct QuaternionNumber {}\nfn float QuaternionNumber.to_axis_angle(self) {}\n")!!;
	defer { if (catch file::delete("/tmp/lsp_ws_std_reach/math/quaternion.c3")) {} }

	DocumentList* ds = mem::new(DocumentList);
	defer mem::free(ds);

	DString out = dstring::temp();
	encode_workspace_symbols("to_axis_angle", ds, "", "/tmp/lsp_ws_std_reach", &out);
	String r = out.str_view();

	assert(r.contains(`"name":"QuaternionNumber.to_axis_angle"`), "stdlib method must be found, got: %s", r);
	assert(r.contains(`"containerName":"std::math::quaternion"`),
		"the declaring module is what tells a stdlib hit from a project one, got: %s", r);
}

// The stdlib is searched last and only with what is left of the result cap, so a
// query the project can answer is never buried under std:: matches.
fn void test_workspace_symbols_put_the_project_before_the_stdlib() @test {
	mkdirs("/tmp/lsp_ws_order/src");
	mkdirs("/tmp/lsp_ws_std_order");
	file::save("/tmp/lsp_ws_order/project.json", `{"sources": ["src/**"]}`)!!;
	file::save("/tmp/lsp_ws_order/src/app.c3", "module app;\nfn void shared_name() {}\n")!!;
	file::save("/tmp/lsp_ws_std_order/core.c3", "module std::core;\nfn void shared_name() {}\n")!!;
	defer
	{
		if (catch file::delete("/tmp/lsp_ws_order/project.json")) {}
		if (catch file::delete("/tmp/lsp_ws_order/src/app.c3")) {}
		if (catch file::delete("/tmp/lsp_ws_std_order/core.c3")) {}
	}

	DocumentList* ds = mem::new(DocumentList);
	defer mem::free(ds);

	DString out = dstring::temp();
	encode_workspace_symbols("shared_name", ds, "/tmp/lsp_ws_order/src/app.c3", "/tmp/lsp_ws_std_order", &out);
	String r = out.str_view();

	sz project_at = r.index_of(`"containerName":"app"`)!!;
	sz stdlib_at = r.index_of(`"containerName":"std::core"`)!!;
	assert(project_at < stdlib_at, "the project's own symbol must be listed first, got: %s", r);
}

// Methods are declared on the type an alias points at, so a query written with the
// alias — which is the name the caller has in front of them — has to resolve first.
fn void test_workspace_symbols_list_members_through_an_alias() @test {
	mkdirs("/tmp/lsp_ws_std_alias");
	file::save("/tmp/lsp_ws_std_alias/quaternion.c3",
		"module std::math::quaternion;\nalias Quaternionf = QuaternionNumber {float};\n"
		"struct QuaternionNumber {}\nfn float QuaternionNumber.to_angle(self) {}\n"
		"fn float QuaternionNumber.length(self) {}\nfn void unrelated() {}\n")!!;
	defer { if (catch file::delete("/tmp/lsp_ws_std_alias/quaternion.c3")) {} }

	DocumentList* ds = mem::new(DocumentList);
	defer mem::free(ds);

	DString out = dstring::temp();
	encode_workspace_symbols("Quaternionf.", ds, "", "/tmp/lsp_ws_std_alias", &out);
	String r = out.str_view();

	assert(r.contains(`"name":"QuaternionNumber.to_angle"`), "alias must resolve to its target's methods, got: %s", r);
	assert(r.contains(`"name":"QuaternionNumber.length"`), "every method must be listed, got: %s", r);
	assert(!r.contains(`"name":"unrelated"`), "a free function is not a member, got: %s", r);
}

fn void test_workspace_symbols_capability_is_advertised() @test {
	DString out = dstring::temp();
	encode_server_capabilities(&out, "0.0.0");
	assert(out.str_view().contains(`"workspaceSymbolProvider":true`),
		"capability must be advertised or clients never send the request, got: %s", out.str_view());
}
