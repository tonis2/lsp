module lsp;

import std::core::dstring;
import std::core::mem;

fn void test_definition_function() @test {
	DString out = dstring::temp();
	DocumentList* ds = mem::new(DocumentList);
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
	DocumentList* ds = mem::new(DocumentList);
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
	DocumentList* ds = mem::new(DocumentList);
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
	DocumentList* ds = mem::new(DocumentList);
	defer mem::free(ds);
	String content = "fn void hello() {}";
	// Cursor on "hello" at the declaration itself — offset 8
	encode_definition("file:///test.c3", content, 8, ds, "", &out);
	// Should return empty (already at declaration)
	assert(out.str_view() == "", "got: %s", out.str_view());
}

fn void test_definition_keyword_no_result() @test {
	DString out = dstring::temp();
	DocumentList* ds = mem::new(DocumentList);
	defer mem::free(ds);
	encode_definition("file:///test.c3", "fn void hello() {}", 0, ds, "", &out);
	// "fn" is a keyword, not navigable
	assert(out.str_view() == "");
}

fn void test_definition_constdef() @test {
	DString out = dstring::temp();
	DocumentList* ds = mem::new(DocumentList);
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
	DocumentList* ds = mem::new(DocumentList);
	defer mem::free(ds);
	String content = "fn void main() { unknown(); }";
	// Cursor on "unknown" at offset 17
	encode_definition("file:///test.c3", content, 17, ds, "", &out);
	// No declaration found — empty store, no project files
	assert(out.str_view() == "", "got: %s", out.str_view());
}

fn void test_definition_uri_in_result() @test {
	DString out = dstring::temp();
	DocumentList* ds = mem::new(DocumentList);
	defer mem::free(ds);
	String content = "struct Bar {}\nBar b;";
	encode_definition("file:///my/file.c3", content, 14, ds, "", &out);
	String result = out.str_view();
	assert(result.contains(`file:///my/file.c3`), "got: %s", result);
}

fn void test_definition_enum_member() @test {
	DString out = dstring::temp();
	DocumentList* ds = mem::new(DocumentList);
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
	DocumentList* ds = mem::new(DocumentList);
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
	DocumentList* ds = mem::new(DocumentList);
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

fn void test_definition_method_call_same_file() @test {
	DString out = dstring::temp();
	DocumentList* ds = mem::new(DocumentList);
	defer mem::free(ds);
	// File has a struct, a method on it, and a call site
	String content = "struct Foo {}\nfn void Foo.init(&self) {}\nFoo f;\nf.init();";
	// "f.init()" — cursor on "init" at offset 50
	encode_definition("file:///test.c3", content, 50, ds, "", &out);
	String result = out.str_view();
	// Should navigate to "init" in "fn void Foo.init" (line 1, character 12)
	assert(result.contains(`"line":1`), "got: %s", result);
	assert(result.contains(`"character":12`), "got: %s", result);
}

fn void test_definition_method_call_cross_file() @test {
	DString out = dstring::temp();
	DocumentList* ds = mem::new(DocumentList);
	defer mem::free(ds);
	// Method declaration in another file
	ds.open("file:///foo.c3", "struct Foo {}\nfn void Foo.start(&self) {}", 1);

	// Current file uses the method
	String content = "Foo f;\nf.start();";
	// "f.start()" — cursor on "start" at offset 9
	encode_definition("file:///test.c3", content, 9, ds, "", &out);
	String result = out.str_view();
	assert(result.contains(`file:///foo.c3`), "got: %s", result);
	assert(result.contains(`"line":1`), "got: %s", result);
	assert(result.contains(`"character":12`), "got: %s", result);

	ds.close("file:///foo.c3");
}

fn void test_definition_method_call_alias_resolved() @test {
	DString out = dstring::temp();
	DocumentList* ds = mem::new(DocumentList);
	defer mem::free(ds);
	// Alias definition in one file, method on the base type in another
	ds.open("file:///types.c3", "alias MyList = BaseList;", 1);
	ds.open("file:///base.c3", "struct BaseList {}\nfn void BaseList.push(&self) {}", 1);

	// Current file uses the alias type and calls the method
	String content = "MyList items;\nitems.push();";
	// "items.push()" — cursor on "push" at offset 20
	encode_definition("file:///test.c3", content, 20, ds, "", &out);
	String result = out.str_view();
	// Should resolve MyList -> BaseList, then find fn BaseList.push
	assert(result.contains(`file:///base.c3`), "got: %s", result);
	assert(result.contains(`"character":17`), "got: %s", result);

	ds.close("file:///types.c3");
	ds.close("file:///base.c3");
}

fn void test_definition_at_ident_macro() @test {
	DString out = dstring::temp();
	DocumentList* ds = mem::new(DocumentList);
	defer mem::free(ds);
	String content = "macro @upload(mgr, comp, val) {}\n@upload(m, c, v);";
	// Cursor on "@upload" in the call at offset 33
	encode_definition("file:///test.c3", content, 33, ds, "", &out);
	String result = out.str_view();
	assert(result.contains(`"line":0`), "got: %s", result);
	assert(result.contains(`"character":6`), "got: %s", result);
}
