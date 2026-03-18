module lsp;

import std::core::dstring;
import std::core::mem;

fn void test_definition_function() @test {
	DString out = dstring::temp();
	DocumentStore* ds = mem::new(DocumentStore);
	defer mem::free(ds);
	String content = "fn void hello() {}\nhello();";
	// Cursor on "hello" in the call at offset 19
	encode_definition("file:///test.c3", content, 19, ds, "", &out);
	String result = out.str_view();
	assert(result.contains(`"line":0`), "got: %s", result);
	assert(result.contains(`"character":8`), "got: %s", result);
}

fn void test_definition_struct() @test {
	DString out = dstring::temp();
	DocumentStore* ds = mem::new(DocumentStore);
	defer mem::free(ds);
	String content = "struct Foo {}\nFoo x;";
	// Cursor on "Foo" in usage at offset 14
	encode_definition("file:///test.c3", content, 14, ds, "", &out);
	String result = out.str_view();
	assert(result.contains(`"line":0`), "got: %s", result);
	assert(result.contains(`"character":7`), "got: %s", result);
}

fn void test_definition_enum() @test {
	DString out = dstring::temp();
	DocumentStore* ds = mem::new(DocumentStore);
	defer mem::free(ds);
	String content = "enum Color { RED }\nColor c;";
	// Cursor on "Color" in usage at offset 19
	encode_definition("file:///test.c3", content, 19, ds, "", &out);
	String result = out.str_view();
	assert(result.contains(`"line":0`), "got: %s", result);
	assert(result.contains(`"character":5`), "got: %s", result);
}

fn void test_definition_at_declaration_no_result() @test {
	DString out = dstring::temp();
	DocumentStore* ds = mem::new(DocumentStore);
	defer mem::free(ds);
	String content = "fn void hello() {}";
	// Cursor on "hello" at the declaration itself — offset 8
	encode_definition("file:///test.c3", content, 8, ds, "", &out);
	// Should return empty (already at declaration)
	assert(out.str_view() == "", "got: %s", out.str_view());
}

fn void test_definition_keyword_no_result() @test {
	DString out = dstring::temp();
	DocumentStore* ds = mem::new(DocumentStore);
	defer mem::free(ds);
	encode_definition("file:///test.c3", "fn void hello() {}", 0, ds, "", &out);
	// "fn" is a keyword, not navigable
	assert(out.str_view() == "");
}

fn void test_definition_constdef() @test {
	DString out = dstring::temp();
	DocumentStore* ds = mem::new(DocumentStore);
	defer mem::free(ds);
	String content = "constdef MAX = 100;\nint x = MAX;";
	// Cursor on "MAX" in usage at offset 28
	encode_definition("file:///test.c3", content, 28, ds, "", &out);
	String result = out.str_view();
	assert(result.contains(`"line":0`), "got: %s", result);
	assert(result.contains(`"character":9`), "got: %s", result);
}

fn void test_definition_not_found() @test {
	DString out = dstring::temp();
	DocumentStore* ds = mem::new(DocumentStore);
	defer mem::free(ds);
	String content = "fn void main() { unknown(); }";
	// Cursor on "unknown" at offset 17
	encode_definition("file:///test.c3", content, 17, ds, "", &out);
	// No declaration found — empty store, no project files
	assert(out.str_view() == "", "got: %s", out.str_view());
}

fn void test_definition_uri_in_result() @test {
	DString out = dstring::temp();
	DocumentStore* ds = mem::new(DocumentStore);
	defer mem::free(ds);
	String content = "struct Bar {}\nBar b;";
	encode_definition("file:///my/file.c3", content, 14, ds, "", &out);
	String result = out.str_view();
	assert(result.contains(`file:///my/file.c3`), "got: %s", result);
}

fn void test_definition_enum_member() @test {
	DString out = dstring::temp();
	DocumentStore* ds = mem::new(DocumentStore);
	defer mem::free(ds);
	String content = "enum TokenType { LBRACE, RBRACE }\nTokenType t = LBRACE;";
	// Cursor on "LBRACE" in usage at offset 48
	encode_definition("file:///test.c3", content, 48, ds, "", &out);
	String result = out.str_view();
	assert(result.contains(`"line":0`), "got: %s", result);
	assert(result.contains(`"character":17`), "got: %s", result);
}

fn void test_definition_enum_member_cross_file() @test {
	DString out = dstring::temp();
	DocumentStore* ds = mem::new(DocumentStore);
	defer mem::free(ds);
	ds.open("file:///types.c3", "enum Color { RED, GREEN, BLUE }", 1);

	String content = "Color c = RED;";
	// Cursor on "RED" at offset 10
	encode_definition("file:///test.c3", content, 10, ds, "", &out);
	String result = out.str_view();
	assert(result.contains(`file:///types.c3`), "got: %s", result);
	assert(result.contains(`"character":13`), "got: %s", result);

	ds.close("file:///types.c3");
}

fn void test_definition_cross_file() @test {
	DString out = dstring::temp();
	DocumentStore* ds = mem::new(DocumentStore);
	defer mem::free(ds);
	// Open a second document with the struct definition
	ds.open("file:///other.c3", "struct MyWidget { int x; }", 1);

	// Current file uses MyWidget but doesn't define it
	String content = "MyWidget w;";
	encode_definition("file:///test.c3", content, 0, ds, "", &out);
	String result = out.str_view();
	assert(result.contains(`file:///other.c3`), "got: %s", result);
	assert(result.contains(`"character":7`), "got: %s", result);

	ds.close("file:///other.c3");
}
