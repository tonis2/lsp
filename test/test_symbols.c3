module lsp;

import std::core::dstring;

fn void test_symbols_empty() @test {
	DString out = dstring::temp();
	encode_document_symbols("", &out);
	assert(out.str_view() == "");
}

fn void test_symbols_module() @test {
	DString out = dstring::temp();
	encode_document_symbols("module foo;", &out);
	String result = out.str_view();
	assert(result.contains(`"name":"foo"`), "got: %s", result);
	assert(result.contains(`"kind":2`), "got: %s", result); // Module
}

fn void test_symbols_function() @test {
	DString out = dstring::temp();
	encode_document_symbols("fn void hello() {}", &out);
	String result = out.str_view();
	assert(result.contains(`"name":"hello"`), "got: %s", result);
	assert(result.contains(`"kind":12`), "got: %s", result); // Function
}

fn void test_symbols_struct() @test {
	DString out = dstring::temp();
	encode_document_symbols("struct MyStruct { int x; }", &out);
	String result = out.str_view();
	assert(result.contains(`"name":"MyStruct"`), "got: %s", result);
	assert(result.contains(`"kind":23`), "got: %s", result); // Struct
}

fn void test_symbols_enum() @test {
	DString out = dstring::temp();
	encode_document_symbols("enum Color { RED, GREEN, BLUE }", &out);
	String result = out.str_view();
	assert(result.contains(`"name":"Color"`), "got: %s", result);
	assert(result.contains(`"kind":10`), "got: %s", result); // Enum
}

fn void test_symbols_method() @test {
	DString out = dstring::temp();
	encode_document_symbols("fn void MyType.do_thing() {}", &out);
	String result = out.str_view();
	assert(result.contains(`"name":"MyType.do_thing"`), "got: %s", result);
	assert(result.contains(`"kind":12`), "got: %s", result); // Function
}

fn void test_symbols_import() @test {
	DString out = dstring::temp();
	encode_document_symbols("import std;", &out);
	String result = out.str_view();
	assert(result.contains(`"name":"std"`), "got: %s", result);
	assert(result.contains(`"kind":2`), "got: %s", result); // Module
}

fn void test_symbols_import_scoped() @test {
	DString out = dstring::temp();
	encode_document_symbols("import std::io;", &out);
	String result = out.str_view();
	assert(result.contains(`"name":"std::io"`), "got: %s", result);
	assert(result.contains(`"kind":2`), "got: %s", result); // Module
}

fn void test_symbols_import_deep_scoped() @test {
	DString out = dstring::temp();
	encode_document_symbols("import std::collections::list;", &out);
	String result = out.str_view();
	assert(result.contains(`"name":"std::collections::list"`), "got: %s", result);
}

fn void test_symbols_import_comma_list() @test {
	DString out = dstring::temp();
	encode_document_symbols("import std::io, std::core::ascii;", &out);
	String result = out.str_view();
	// Both modules should appear as separate symbols.
	assert(result.contains(`"name":"std::io"`), "got: %s", result);
	assert(result.contains(`"name":"std::core::ascii"`), "got: %s", result);
}

fn void test_symbols_module_scoped() @test {
	DString out = dstring::temp();
	encode_document_symbols("module foo::bar;", &out);
	String result = out.str_view();
	assert(result.contains(`"name":"foo::bar"`), "got: %s", result);
	assert(result.contains(`"kind":2`), "got: %s", result); // Module
}

fn void test_symbols_constdef() @test {
	DString out = dstring::temp();
	encode_document_symbols("constdef MAX_SIZE = 100;", &out);
	String result = out.str_view();
	assert(result.contains(`"name":"MAX_SIZE"`), "got: %s", result);
	assert(result.contains(`"kind":14`), "got: %s", result); // Constant
}

fn void test_symbols_interface() @test {
	DString out = dstring::temp();
	encode_document_symbols("interface Printable { }", &out);
	String result = out.str_view();
	assert(result.contains(`"name":"Printable"`), "got: %s", result);
	assert(result.contains(`"kind":11`), "got: %s", result); // Interface
}

fn void test_symbols_multiple() @test {
	DString out = dstring::temp();
	encode_document_symbols("module test;\nstruct Foo {}\nenum Bar { A }", &out);
	String result = out.str_view();
	assert(result.contains(`"name":"test"`), "got: %s", result);
	assert(result.contains(`"name":"Foo"`), "got: %s", result);
	assert(result.contains(`"name":"Bar"`), "got: %s", result);
}

fn void test_symbols_method_nested() @test {
	DString out = dstring::temp();
	encode_document_symbols("struct World { int x; }\nfn void World.find_chunk() {}\nfn void World.block_type_at() {}", &out);
	String result = out.str_view();
	// Methods should be nested as children of their parent struct
	assert(result.contains(`"children":`), "expected children array, got: %s", result);
	assert(result.contains(`"name":"find_chunk"`), "got: %s", result);
	assert(result.contains(`"name":"block_type_at"`), "got: %s", result);
	// The methods should NOT appear as top-level "World.find_chunk"
	assert(!result.contains(`"name":"World.find_chunk"`), "method should be nested, got: %s", result);
	assert(!result.contains(`"name":"World.block_type_at"`), "method should be nested, got: %s", result);
}

fn void test_symbols_method_orphan() @test {
	DString out = dstring::temp();
	// Method without matching struct in same file — should show as Type.method at top level
	encode_document_symbols("fn void MyType.do_thing() {}", &out);
	String result = out.str_view();
	assert(result.contains(`"name":"MyType.do_thing"`), "got: %s", result);
	assert(result.contains(`"kind":12`), "got: %s", result); // Function
}

fn void test_symbols_no_truncation() @test {
	// More declarations than the old fixed cap (512). All must be emitted — no silent
	// truncation now that the symbol store is a heap-backed list.
	// Names need a lowercase letter to lex as TYPE_IDENT (all-caps+digits would be CONST_IDENT).
	const int N = 600;
	DString src = dstring::temp();
	for (int i = 0; i < N; i++) {
		src.appendf("struct Foo%d {}\n", i);
	}
	DString out = dstring::temp();
	encode_document_symbols(src.str_view(), &out);
	String result = out.str_view();

	// Count struct symbols (kind 23) — one per declaration.
	int count = 0;
	String needle = `"kind":23`;
	for (usz i = 0; i + needle.len <= result.len; i++) {
		if (result[i:needle.len] == needle) count++;
	}
	assert(count == N, "expected %d structs, got %d", N, count);
}
