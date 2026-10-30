module lsp;

import std::core::dstring;
import std::core::mem;

// Go to the definition of the first `needle` occurrence (+ `skip` bytes into it) in a
// single-file program and return the JSON answer.
fn String def_at(String content, String needle, sz skip = 0, sz nth = 0)
{
	DString out = dstring::temp();
	DocumentList* ds = mem::new(DocumentList);
	defer mem::free(ds);
	sz from = 0;
	sz at;
	for (sz n = 0; n <= nth; n++)
	{
		at = from + content[from..].index_of(needle)!!;
		from = at + 1;
	}
	encode_definition("file:///p/a.c3", content, at + skip, ds, "", &out);
	return out.str_view();
}

fn bool starts_at(String json, int line, int character)
{
	return json.contains(string::tformat(`"start":{"line":%d,"character":%d}`, line, character));
}

// 1. A cursor right after a name (before `(` or `.`) still means that name.
fn void test_def_cursor_after_name() @test {
	String src = "fn void foo() {}\nfn void main() { foo(); }";
	String r = def_at(src, "foo();", 3); // on the `(`, i.e. just after `foo`
	assert(starts_at(r, 0, 8), "got: %s", r);
}

// 1b. Compile-time and hash parameters resolve to their declaration.
fn void test_def_ct_and_hash_params() @test {
	String src = "macro @m($Type, #expr, $n)\n{\n\t$Type x = #expr;\n\treturn $n;\n}";
	assert(starts_at(def_at(src, "$Type x"), 0, 9), "got: %s", def_at(src, "$Type x"));
	assert(starts_at(def_at(src, "#expr;"), 0, 16), "got: %s", def_at(src, "#expr;"));
	assert(starts_at(def_at(src, "$n;"), 0, 23), "got: %s", def_at(src, "$n;"));
}

// 2. Enum members through their type, and inferred `.MEMBER`.
fn void test_def_enum_member_access() @test {
	String src = "enum Color { RED, GREEN }\nfn void main() { Color c = Color.GREEN; c = .RED; switch (c) { case .GREEN: break; default: break; } }";
	assert(starts_at(def_at(src, "GREEN;"), 0, 18), "Color.GREEN, got: %s", def_at(src, "GREEN;"));
	assert(starts_at(def_at(src, "RED;"), 0, 13), ".RED, got: %s", def_at(src, "RED;"));
	assert(starts_at(def_at(src, "GREEN:"), 0, 18), "case .GREEN, got: %s", def_at(src, "GREEN:"));
}

fn void test_def_constdef_member_access() @test {
	String src = "constdef Flags : int { A = 1, B = 2 }\nfn void main() { int x = Flags.B; }";
	assert(starts_at(def_at(src, "B;"), 0, 30), "got: %s", def_at(src, "B;"));
}

// 3. A method returning the generic parameter keeps the chain going.
fn void test_def_generic_return_chain() @test {
	String src = "module m <Type>;\nstruct Box { Type value; }\nfn Type Box.get(&self) { return self.value; }\n"
		"module app;\nimport m;\nstruct Foo { int bar; }\nfn void main() { Box{Foo} b; int x = b.get().bar; }";
	assert(starts_at(def_at(src, "bar;", 0, 1), 5, 17), "got: %s", def_at(src, "bar;", 0, 1));
}

// 4. A plain call never resolves to a same-named method.
fn void test_def_free_call_not_method() @test {
	String src = "struct Foo { int x; }\nfn void Foo.init(&self) {}\nfn void init() {}\nfn void main() { init(); }";
	assert(starts_at(def_at(src, "init();"), 2, 8), "got: %s", def_at(src, "init();"));
}

// 5. Globals of any type, with attributes, and function aliases.
fn void test_def_globals_and_aliases() @test {
	String src = "struct Cache { int x; }\nCache* g_cache @private = null;\nint[4] g_arr;\nfn void real() {}\nalias fake = real;\n"
		"fn void f() { int count = 1; }\nint count = 2;\nfn void main() { g_cache = null; g_arr[0] = 1; fake(); count = 3; }";
	assert(starts_at(def_at(src, "g_cache = null"), 1, 7), "pointer global, got: %s", def_at(src, "g_cache = null"));
	assert(starts_at(def_at(src, "g_arr[0]"), 2, 7), "array global, got: %s", def_at(src, "g_arr[0]"));
	assert(starts_at(def_at(src, "fake();"), 4, 6), "function alias, got: %s", def_at(src, "fake();"));
	assert(starts_at(def_at(src, "count = 3"), 6, 4), "the global, not another function's local, got: %s", def_at(src, "count = 3"));
}

// 6a. Methods through an interface-typed receiver.
fn void test_def_interface_receiver() @test {
	String src = "interface Printable\n{\n\tfn String to_text();\n}\nfn void show(Printable p) { p.to_text(); }";
	assert(starts_at(def_at(src, "to_text();", 0, 1), 2, 11), "got: %s", def_at(src, "to_text();", 0, 1));
}

// 6b. Members reached through an `inline` embedded struct.
fn void test_def_inline_member() @test {
	String src = "struct Base { int id; }\nstruct Derived { inline Base base; int extra; }\nfn void main() { Derived d; d.id = 1; }";
	assert(starts_at(def_at(src, "id = 1"), 0, 18), "got: %s", def_at(src, "id = 1"));
}

// 6c. `var` locals take the initializer's type.
fn void test_def_var_local() @test {
	String src = "struct Foo { int bar; }\nfn Foo make() { return {}; }\nfn void main() { var f = make(); f.bar = 1; }";
	assert(starts_at(def_at(src, "bar = 1"), 0, 17), "got: %s", def_at(src, "bar = 1"));
}

// 6d. An unknown receiver still finds a method by name when only one type has it.
fn void test_def_unknown_receiver_unique_method() @test {
	String src = "struct Foo { int x; }\nfn void Foo.frobnicate(&self) {}\nfn void main() { unknown_thing().frobnicate(); }";
	assert(starts_at(def_at(src, "frobnicate();"), 1, 12), "got: %s", def_at(src, "frobnicate();"));
}

// 7. A module-qualified receiver type picks that module's struct.
fn void test_def_module_qualified_receiver() @test {
	String src = "module a;\nstruct Node { int kids; }\nmodule b;\nstruct Node { int children; int kids; }\nmodule app;\nimport a, b;\nfn void main() { b::Node* n; n.kids = 1; }";
	assert(starts_at(def_at(src, "kids = 1"), 3, 32), "got: %s", def_at(src, "kids = 1"));
}

// 8. Labels.
fn void test_def_labels() @test {
	String src = "const OUTER = 1;\nfn void main()\n{\n\tOUTER: while (true)\n\t{\n\t\tbreak OUTER;\n\t}\n}";
	assert(starts_at(def_at(src, "OUTER;"), 3, 1), "got: %s", def_at(src, "OUTER;"));
}

// 9. A generic module parameter.
fn void test_def_generic_module_param() @test {
	String src = "struct Event { int x; }\nmodule queue <Event>;\nstruct Queue { Event[8] items; }";
	assert(starts_at(def_at(src, "Event[8]"), 1, 14), "got: %s", def_at(src, "Event[8]"));
}

// A receiver whose type lives in another module, used unqualified, still finds its
// methods and fields (the receiver's module is a preference, not a filter).
fn void test_def_member_of_type_from_other_module() @test {
	DString out = dstring::temp();
	DocumentList docs;
	docs.init(mem);
	defer { while (docs.size > 0) docs.close(docs.entries[0].uri); docs.free(); }
	docs.open("file:///p/lib.c3", "module lib;\nstruct Thing { int size; }\nfn void Thing.go(&self) {}\n", 1);
	String content = "module app;\nimport lib;\nfn void main() { Thing t; t.go(); t.size = 1; }";
	docs.open("file:///p/app.c3", content, 1);
	encode_definition("file:///p/app.c3", content, content.index_of("go();")!!, &docs, "", &out);
	assert(out.str_view().contains(`"uri":"file:///p/lib.c3"`) && starts_at(out.str_view(), 2, 14), "method, got: %s", out.str_view());
	out.clear();
	encode_definition("file:///p/app.c3", content, content.index_of("size = 1")!!, &docs, "", &out);
	assert(starts_at(out.str_view(), 1, 19), "field, got: %s", out.str_view());
}
