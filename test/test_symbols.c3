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
