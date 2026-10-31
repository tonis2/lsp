module lsp;

import std::core::dstring;
import std::core::mem;

// Parameter-name inlay hints before call arguments.
const String IH_LIB = "module game::util;\n"
	+++ "fn void shout(String msg, int times = 1) {}\n";

const String IH_SRC = "module game;\n"
	+++ "import game::util;\n"
	+++ "struct Vec { int x; }\n"
	+++ "fn void Vec.add(&self, int dx, int dy) {}\n"
	+++ "struct GameObject { int id; }\n"
	+++ "fn void GameObject.rename(&self, String name) {}\n"
	+++ "struct Comp { inline GameObject obj; }\n"
	+++ "fn void move(int x, int y) {}\n"
	+++ "fn int twice(int n) => n * 2;\n"
	+++ "fn void log(String fmt, args...) {}\n"
	+++ "macro @each(list; @body(it)) {}\n"
	+++ "fn void f(Vec v, Comp c, int x)\n"
	+++ "{\n"
	+++ "\tmove(1, 2);\n"
	+++ "\tv.add(3, 4);\n"
	+++ "\tVec.add(v, 5, 6);\n"
	+++ "\tmove(x, 7);\n"
	+++ "\tmove(x: 1, y: 2);\n"
	+++ "\tlog(\"a\", 1, 2);\n"
	+++ "\tmove(twice(8), 9);\n"
	+++ "\tutil::shout(\"hi\");\n"
	+++ "\tc.rename(\"n\");\n"
	+++ "\tmystery(1);\n"
	+++ "\t@each(v) {};\n"
	+++ "}\n";

const String IH_LIB_URI = "file:///p/util.c3";

// The hints for the lines `from_line`..`to_line` (inclusive) of IH_SRC.
fn String ih_hints(int from_line, int to_line) @private
{
	DocumentList* ds = mem::new(DocumentList);
	defer mem::free(ds);
	ds.open(IH_LIB_URI, IH_LIB, 1);
	defer ds.close(IH_LIB_URI);
	DString out = dstring::temp();
	encode_inlay_hints("file:///p/a.c3", IH_SRC, position_to_offset(IH_SRC, from_line, 0),
		position_to_offset(IH_SRC, to_line, 999), &out, null, ds, "");
	return out.str_view();
}

// `"line":<line>,"character":<col>},"label":"<label>"` appears in the answer.
fn bool ih_has(String json, int line, int col, String label) @private
{
	return json.contains(string::tformat(`{"line":%d,"character":%d},"label":"%s"`, line, col, label));
}

fn int ih_count(String json) @private
{
	int count = 0;
	String rest = json;
	while (try at = rest.index_of(`"label"`))
	{
		count++;
		rest = rest[at + 1..];
	}
	return count;
}

fn void test_inlay_free_function() @test {
	String r = ih_hints(13, 13);
	assert(ih_count(r) == 2 && ih_has(r, 13, 6, "x:") && ih_has(r, 13, 9, "y:"), "got: %s", r);
}

fn void test_inlay_method_receiver() @test {
	// `v.add(3, 4)` passes the receiver implicitly; `Vec.add(v, 5, 6)` spells it out.
	String r = ih_hints(14, 14);
	assert(ih_count(r) == 2 && ih_has(r, 14, 7, "dx:") && ih_has(r, 14, 10, "dy:"), "got: %s", r);
	r = ih_hints(15, 15);
	assert(ih_count(r) == 3 && ih_has(r, 15, 9, "self:") && ih_has(r, 15, 12, "dx:") && ih_has(r, 15, 15, "dy:"), "got: %s", r);
}

fn void test_inlay_no_hints_on_declarations() @test {
	String r = ih_hints(0, 11);
	assert(r == "[]", "got: %s", r);
}

fn void test_inlay_skips_self_describing_arguments() @test {
	// `move(x, 7)`: the argument is spelled like the parameter.
	String r = ih_hints(16, 16);
	assert(ih_count(r) == 1 && ih_has(r, 16, 9, "y:"), "got: %s", r);
	// Named arguments.
	r = ih_hints(17, 17);
	assert(r == "[]", "got: %s", r);
}

fn void test_inlay_variadic() @test {
	String r = ih_hints(18, 18);
	assert(ih_count(r) == 1 && ih_has(r, 18, 5, "fmt:"), "got: %s", r);
}

fn void test_inlay_nested_calls() @test {
	String r = ih_hints(19, 19);
	assert(ih_count(r) == 3, "got: %s", r);
	assert(ih_has(r, 19, 6, "x:") && ih_has(r, 19, 12, "n:") && ih_has(r, 19, 16, "y:"), "got: %s", r);
}

fn void test_inlay_module_call_in_other_document() @test {
	String r = ih_hints(20, 20);
	assert(ih_count(r) == 1 && ih_has(r, 20, 13, "msg:"), "got: %s", r);
}

fn void test_inlay_method_through_inline() @test {
	String r = ih_hints(21, 21);
	assert(ih_count(r) == 1 && ih_has(r, 21, 10, "name:"), "got: %s", r);
}

fn void test_inlay_unknown_callee_and_macro() @test {
	// `mystery` is declared nowhere; `@each(v)` stops at the macro's body parameters.
	String r = ih_hints(22, 23);
	assert(ih_count(r) == 1 && ih_has(r, 23, 7, "list:"), "got: %s", r);
}

fn void test_inlay_only_in_range() @test {
	String r = ih_hints(14, 15);
	assert(ih_count(r) == 5, "got: %s", r);
	assert(!r.contains(`"line":13,`) && !r.contains(`"line":16,`), "got: %s", r);
}
