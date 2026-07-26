module lsp;

import std::core::mem;
import std::core::dstring;

// --- helpers ---

fn void test_call_hierarchy_bare_name_strips_receiver_type() @test {
	assert(call_hierarchy_bare_name("Window.getEvent") == "getEvent",
		"got: %s", call_hierarchy_bare_name("Window.getEvent"));
	assert(call_hierarchy_bare_name("plain_fn") == "plain_fn",
		"got: %s", call_hierarchy_bare_name("plain_fn"));
}

// --- prepareCallHierarchy ---

fn void test_prepare_call_hierarchy_on_declaration_name() @test {
	String src = "module app;\n"
		+++ "fn void helper() {}\n"
		+++ "fn void caller() { helper(); }\n";

	DocumentList* ds = mem::new(DocumentList);
	defer mem::free(ds);
	ds.open("file:///proj/src/a.c3", src, 1);

	DString out = dstring::temp();
	encode_prepare_call_hierarchy("file:///proj/src/a.c3", src, offset_of(src, "helper"), ds, "", &out);
	String r = out.str_view();

	assert(r.contains(`"name":"helper"`), "item must name the callable, got: %s", r);
	assert(r.contains(`"kind":12`), "callables are reported as functions, got: %s", r);
	assert(r.contains(`"detail":"app"`), "detail must carry the module, got: %s", r);
	assert(r.contains(`"selectionRange"`), "item needs a selectionRange, got: %s", r);

	ds.close("file:///proj/src/a.c3");
}

// Invoked on a call site, the hierarchy should open on the callee, not on the function
// the cursor happens to sit in.
fn void test_prepare_call_hierarchy_on_call_site_resolves_callee() @test {
	String src = "module app;\n"
		+++ "fn void helper() {}\n"
		+++ "fn void caller() { helper(); }\n";

	DocumentList* ds = mem::new(DocumentList);
	defer mem::free(ds);
	ds.open("file:///proj/src/b.c3", src, 1);

	DString out = dstring::temp();
	// Second occurrence of "helper" is the call inside caller().
	encode_prepare_call_hierarchy("file:///proj/src/b.c3", src, offset_of(src, "helper", 2), ds, "", &out);
	String r = out.str_view();

	assert(r.contains(`"name":"helper"`), "call site must resolve to the callee, got: %s", r);
	assert(!r.contains(`"name":"caller"`), "must not report the enclosing function, got: %s", r);

	ds.close("file:///proj/src/b.c3");
}

// With the cursor on nothing callable, fall back to the function it sits inside.
fn void test_prepare_call_hierarchy_falls_back_to_enclosing_function() @test {
	String src = "module app;\n"
		+++ "fn void caller() {\n"
		+++ "    int local_value = 1;\n"
		+++ "}\n";

	DocumentList* ds = mem::new(DocumentList);
	defer mem::free(ds);
	ds.open("file:///proj/src/c.c3", src, 1);

	DString out = dstring::temp();
	encode_prepare_call_hierarchy("file:///proj/src/c.c3", src, offset_of(src, "local_value"), ds, "", &out);
	String r = out.str_view();

	assert(r.contains(`"name":"caller"`), "must fall back to the enclosing function, got: %s", r);

	ds.close("file:///proj/src/c.c3");
}

fn void test_prepare_call_hierarchy_outside_any_function_yields_nothing() @test {
	String src = "module app;\nconst int TOP = 1;\n";

	DocumentList* ds = mem::new(DocumentList);
	defer mem::free(ds);
	ds.open("file:///proj/src/d.c3", src, 1);

	DString out = dstring::temp();
	encode_prepare_call_hierarchy("file:///proj/src/d.c3", src, offset_of(src, "TOP"), ds, "", &out);
	assert(out.str_view().len == 0, "nothing callable at cursor must report nothing, got: %s", out.str_view());

	ds.close("file:///proj/src/d.c3");
}

// --- incomingCalls ---

fn void test_incoming_calls_groups_ranges_by_calling_function() @test {
	String src = "module app;\n"
		+++ "fn void target() {}\n"
		+++ "fn void one() { target(); }\n"
		+++ "fn void two() { target(); target(); }\n"
		+++ "fn void none() { int x = 1; }\n";

	DocumentList* ds = mem::new(DocumentList);
	defer mem::free(ds);
	ds.open("file:///proj/src/e.c3", src, 1);

	DString out = dstring::temp();
	encode_incoming_calls("file:///proj/src/e.c3", "target", 1, 8, ds, "", &out);
	String r = out.str_view();

	assert(r.contains(`"name":"one"`), "single caller must be reported, got: %s", r);
	assert(r.contains(`"name":"two"`), "second caller must be reported, got: %s", r);
	assert(!r.contains(`"name":"none"`), "a non-caller must not appear, got: %s", r);
	// One entry per calling function, however many call sites it holds.
	assert(count_of(r, `"fromRanges"`) == 2, "one entry per calling function, got: %s", r);
	// two() calls target twice, so its single entry carries both call ranges.
	assert(r.contains(`"fromRanges":[{"start":{"line":3,"character":16},"end":{"line":3,"character":22}},`
		+++ `{"start":{"line":3,"character":26},"end":{"line":3,"character":32}}]`),
		"repeated calls must group into one entry's fromRanges, got: %s", r);

	ds.close("file:///proj/src/e.c3");
}

// The declaration's own name is followed by `(` just like a call, but it is not one.
fn void test_incoming_calls_excludes_the_declaration_itself() @test {
	String src = "module app;\nfn void target() {}\n";

	DocumentList* ds = mem::new(DocumentList);
	defer mem::free(ds);
	ds.open("file:///proj/src/f.c3", src, 1);

	DString out = dstring::temp();
	encode_incoming_calls("file:///proj/src/f.c3", "target", 1, 8, ds, "", &out);
	assert(out.str_view().len == 0, "a declaration is not a call to itself, got: %s", out.str_view());

	ds.close("file:///proj/src/f.c3");
}

fn void test_incoming_calls_accepts_qualified_item_name() @test {
	String src = "module app;\n"
		+++ "struct Box {}\n"
		+++ "fn void Box.open(&self) {}\n"
		+++ "fn void use(Box b) { b.open(); }\n";

	DocumentList* ds = mem::new(DocumentList);
	defer mem::free(ds);
	ds.open("file:///proj/src/g.c3", src, 1);

	DString out = dstring::temp();
	// The item name a client sends back is the qualified one.
	encode_incoming_calls("file:///proj/src/g.c3", "Box.open", 2, 8, ds, "", &out);
	String r = out.str_view();
	assert(r.contains(`"name":"use"`), "method caller must be found via the bare name, got: %s", r);

	ds.close("file:///proj/src/g.c3");
}

// --- outgoingCalls ---

fn void test_outgoing_calls_lists_callees_with_their_ranges() @test {
	String src = "module app;\n"
		+++ "fn void alpha() {}\n"
		+++ "fn void beta() {}\n"
		+++ "fn void caller() {\n"
		+++ "    alpha();\n"
		+++ "    beta();\n"
		+++ "    alpha();\n"
		+++ "}\n";

	DocumentList* ds = mem::new(DocumentList);
	defer mem::free(ds);
	ds.open("file:///proj/src/h.c3", src, 1);

	DString out = dstring::temp();
	// caller()'s name sits on line 3 (0-based), at the character after "fn void ".
	encode_outgoing_calls("file:///proj/src/h.c3", 3, 8, ds, "", &out);
	String r = out.str_view();

	assert(r.contains(`"name":"alpha"`), "callee alpha must be reported, got: %s", r);
	assert(r.contains(`"name":"beta"`), "callee beta must be reported, got: %s", r);
	// Two distinct callees, so two entries — alpha's repeated call adds a range, not an entry.
	assert(count_of(r, `"to":`) == 2, "callees must be deduplicated, got: %s", r);

	ds.close("file:///proj/src/h.c3");
}

fn void test_outgoing_calls_ignores_calls_outside_the_function() @test {
	String src = "module app;\n"
		+++ "fn void alpha() {}\n"
		+++ "fn void beta() {}\n"
		+++ "fn void first() { alpha(); }\n"
		+++ "fn void second() { beta(); }\n";

	DocumentList* ds = mem::new(DocumentList);
	defer mem::free(ds);
	ds.open("file:///proj/src/i.c3", src, 1);

	DString out = dstring::temp();
	// first() is declared on line 3 (0-based).
	encode_outgoing_calls("file:///proj/src/i.c3", 3, 8, ds, "", &out);
	String r = out.str_view();

	assert(r.contains(`"name":"alpha"`), "own callee must be reported, got: %s", r);
	assert(!r.contains(`"name":"beta"`), "a sibling function's callee must not leak in, got: %s", r);

	ds.close("file:///proj/src/i.c3");
}

fn void test_outgoing_calls_of_leaf_function_yields_nothing() @test {
	String src = "module app;\nfn void leaf() { int x = 1; }\n";

	DocumentList* ds = mem::new(DocumentList);
	defer mem::free(ds);
	ds.open("file:///proj/src/j.c3", src, 1);

	DString out = dstring::temp();
	encode_outgoing_calls("file:///proj/src/j.c3", 1, 8, ds, "", &out);
	assert(out.str_view().len == 0, "a function calling nothing must report nothing, got: %s", out.str_view());

	ds.close("file:///proj/src/j.c3");
}

// A same-named declaration in a module the caller cannot see must lose to the visible
// one — otherwise `out.clear()` lands on whatever `clear` the scan happened to reach.
fn void test_outgoing_calls_prefers_visible_module() @test {
	DocumentList* ds = mem::new(DocumentList);
	defer mem::free(ds);

	// Scanned first, but unreachable from the caller's file.
	ds.open("file:///proj/src/unreachable.c3", "module hidden::stuff;\nfn void clear() {}\n", 1);
	// The module the caller actually imports.
	ds.open("file:///proj/src/visible.c3", "module helpers;\nfn void clear() {}\n", 1);

	String src = "module app;\nimport helpers;\nfn void caller() { clear(); }\n";
	ds.open("file:///proj/src/k.c3", src, 1);

	DString out = dstring::temp();
	encode_outgoing_calls("file:///proj/src/k.c3", 2, 8, ds, "", &out);
	String r = out.str_view();

	assert(r.contains("visible.c3"), "callee must resolve in the imported module, got: %s", r);
	assert(!r.contains("unreachable.c3"), "an unreachable module must not win, got: %s", r);

	ds.close("file:///proj/src/k.c3");
	ds.close("file:///proj/src/visible.c3");
	ds.close("file:///proj/src/unreachable.c3");
}

fn void test_call_hierarchy_capability_is_advertised() @test {
	DString out = dstring::temp();
	encode_server_capabilities(&out, "0.0.0");
	assert(out.str_view().contains(`"callHierarchyProvider":true`),
		"capability must be advertised or clients never send the request, got: %s", out.str_view());
}
