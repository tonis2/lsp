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

fn void test_definition_const_no_type() @test {
	DString out = dstring::temp();
	DocumentList* ds = mem::new(DocumentList);
	defer mem::free(ds);
	String content = "const FOO = 42;\nint x = FOO;";
	// Cursor on "FOO" in usage at offset 24
	encode_definition("file:///test.c3", content, 24, ds, "", &out);
	String result = out.str_view();
	assert(result.contains(`"line":0`), "got: %s", result);
	assert(result.contains(`"character":6`), "got: %s", result);
}

fn void test_definition_const_with_type() @test {
	DString out = dstring::temp();
	DocumentList* ds = mem::new(DocumentList);
	defer mem::free(ds);
	String content = "const usz BUFFER_SIZE = 1024;\nusz x = BUFFER_SIZE;";
	// Cursor on "BUFFER_SIZE" in usage at offset 38
	encode_definition("file:///test.c3", content, 38, ds, "", &out);
	String result = out.str_view();
	assert(result.contains(`"line":0`), "got: %s", result);
	assert(result.contains(`"character":10`), "got: %s", result);
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

fn void test_definition_constdef_block_member() @test {
	DString out = dstring::temp();
	DocumentList* ds = mem::new(DocumentList);
	defer mem::free(ds);
	// Block-form constdef (as used by the Vulkan bindings): the members are
	// module-scoped constants used unqualified.
	String content = "constdef Format : uint { FORMAT_X = 44 }\nFormat f = FORMAT_X;";
	// Cursor on "FORMAT_X" in usage (offset 53, inside the second occurrence)
	encode_definition("file:///test.c3", content, 53, ds, "", &out);
	String result = out.str_view();
	assert(result.contains(`"line":0`), "got: %s", result);
	assert(result.contains(`"character":25`), "got: %s", result);
}

fn void test_definition_constdef_block_member_cross_file() @test {
	DString out = dstring::temp();
	DocumentList* ds = mem::new(DocumentList);
	defer mem::free(ds);
	ds.open("file:///vk.c3", "constdef Format : uint { FORMAT_X = 44 }", 1);

	String content = "Format f = FORMAT_X;";
	// Cursor on "FORMAT_X" at offset 12
	encode_definition("file:///test.c3", content, 12, ds, "", &out);
	String result = out.str_view();
	assert(result.contains(`file:///vk.c3`), "got: %s", result);
	assert(result.contains(`"character":25`), "got: %s", result);

	ds.close("file:///vk.c3");
}

fn void test_definition_fluent_chain_cross_file() @test {
	DString out = dstring::temp();
	DocumentList* ds = mem::new(DocumentList);
	defer mem::free(ds);
	// Fluent builder pattern (as in the Vulkan bindings): a free fn returns the
	// builder, each method returns the same builder type, enabling chaining.
	ds.open("file:///b.c3",
		"struct Builder { int x; }\n"
		"fn Builder builder() { Builder b; return b; }\n"
		"fn Builder Builder.setX(&self, int v) { return *self; }\n"
		"fn int Builder.fin(&self) { return 0; }", 1);

	// Cursor on ".fin" — a NON-first link reached through builder().setX(1).
	String content = "int r = builder().setX(1).fin();";
	encode_definition("file:///test.c3", content, 27, ds, "", &out);
	String result = out.str_view();
	assert(result.contains(`file:///b.c3`), "expected jump into builder file, got: %s", result);
	assert(result.contains(`"line":3`), "got: %s", result);
	assert(result.contains(`"character":15`), "got: %s", result);

	ds.close("file:///b.c3");
}

fn void test_definition_fluent_chain_first_link() @test {
	DString out = dstring::temp();
	DocumentList* ds = mem::new(DocumentList);
	defer mem::free(ds);
	// Same file: a method invoked directly on a free-function call result
	// (receiver is a call expression — previously unresolved).
	String content =
		"struct Builder { int x; }\n"
		"fn Builder builder() { Builder b; return b; }\n"
		"fn Builder Builder.setX(&self, int v) { return *self; }\n"
		"fn void test() { builder().setX(1); }";
	// Cursor on "setX" in the usage (last line)
	sz off = content.len - 8; // inside "setX(1); }" → on setX
	encode_definition("file:///test.c3", content, off, ds, "", &out);
	String result = out.str_view();
	assert(result.contains(`"line":2`), "expected setX declaration on line 2, got: %s", result);
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

fn void test_strip_json_comments_line() @test {
	String input = `{"key": "value" // this is a comment
}`;
	String result = strip_json_comments(input);
	assert(result.contains(`"key": "value"`), "got: %s", result);
	assert(!result.contains("//"), "got: %s", result);
	assert(!result.contains("this is a comment"), "got: %s", result);
}

fn void test_strip_json_comments_block() @test {
	String input = `{"key": /* block comment */ "value"}`;
	String result = strip_json_comments(input);
	assert(result == `{"key":  "value"}`, "got: %s", result);
}

fn void test_strip_json_comments_preserves_strings() @test {
	String input = `{"url": "http://example.com"}`;
	String result = strip_json_comments(input);
	assert(result == input, "got: %s", result);
}

fn void test_strip_json_comments_no_comments() @test {
	String input = `{"sources": ["src", "lib"]}`;
	String result = strip_json_comments(input);
	assert(result == input, "got: %s", result);
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
