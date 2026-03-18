module lsp;

import std::core::dstring;
import std::core::mem;

fn void test_hover_keyword() @test {
	DString out = dstring::temp();
	DocumentStore* ds = mem::new(DocumentStore);
	defer mem::free(ds);
	encode_hover("file:///test.c3", "defer x();", 0, ds, "", &out);
	String result = out.str_view();
	assert(result.contains("Defers statement execution to scope exit"), "got: %s", result);
	assert(result.contains(`"kind":"markdown"`), "got: %s", result);
}

fn void test_hover_builtin_type() @test {
	DString out = dstring::temp();
	DocumentStore* ds = mem::new(DocumentStore);
	defer mem::free(ds);
	encode_hover("file:///test.c3", "int x = 0;", 0, ds, "", &out);
	String result = out.str_view();
	assert(result.contains("32-bit signed integer"), "got: %s", result);
}

fn void test_hover_identifier() @test {
	DString out = dstring::temp();
	DocumentStore* ds = mem::new(DocumentStore);
	defer mem::free(ds);
	// "fn foo" — hover on "foo" at offset 3
	encode_hover("file:///test.c3", "fn foo", 3, ds, "", &out);
	String result = out.str_view();
	// Now shows signature in code block
	assert(result.contains("foo"), "got: %s", result);
}

fn void test_hover_type_ident() @test {
	DString out = dstring::temp();
	DocumentStore* ds = mem::new(DocumentStore);
	defer mem::free(ds);
	// "struct MyType {}" — hover on MyType at offset 7
	encode_hover("file:///test.c3", "struct MyType {}", 7, ds, "", &out);
	String result = out.str_view();
	// Now shows signature in code block
	assert(result.contains("MyType"), "got: %s", result);
}

fn void test_hover_ct_keyword() @test {
	DString out = dstring::temp();
	DocumentStore* ds = mem::new(DocumentStore);
	defer mem::free(ds);
	encode_hover("file:///test.c3", "$sizeof(int)", 0, ds, "", &out);
	String result = out.str_view();
	assert(result.contains("Returns size of a type in bytes"), "got: %s", result);
}

fn void test_hover_no_hover_on_whitespace() @test {
	DString out = dstring::temp();
	DocumentStore* ds = mem::new(DocumentStore);
	defer mem::free(ds);
	encode_hover("file:///test.c3", "fn x", 2, ds, "", &out);
	assert(out.str_view() == "", "got: %s", out.str_view());
}

fn void test_hover_empty() @test {
	DString out = dstring::temp();
	DocumentStore* ds = mem::new(DocumentStore);
	defer mem::free(ds);
	encode_hover("file:///test.c3", "", 0, ds, "", &out);
	assert(out.str_view() == "");
}

fn void test_hover_const_ident() @test {
	DString out = dstring::temp();
	DocumentStore* ds = mem::new(DocumentStore);
	defer mem::free(ds);
	encode_hover("file:///test.c3", "constdef MAX = 1;", 9, ds, "", &out);
	String result = out.str_view();
	// Now shows signature in code block
	assert(result.contains("MAX"), "got: %s", result);
}

fn void test_hover_function_with_doc_comment() @test {
	DString out = dstring::temp();
	DocumentStore* ds = mem::new(DocumentStore);
	defer mem::free(ds);
	String content = "// Greets the user with a message.\nfn void greet() {}\ngreet();";
	// Cursor on "greet" in the call at offset 54 (after \n before greet())
	encode_hover("file:///test.c3", content, 54, ds, "", &out);
	String result = out.str_view();
	assert(result.contains("Greets the user with a message"), "expected doc comment, got: %s", result);
	assert(result.contains("fn void greet()"), "expected signature, got: %s", result);
}

fn void test_hover_function_with_block_comment() @test {
	DString out = dstring::temp();
	DocumentStore* ds = mem::new(DocumentStore);
	defer mem::free(ds);
	String content = "/* Processes input data. */\nfn void process() {}\nprocess();";
	// Cursor on "process" in the call
	encode_hover("file:///test.c3", content, 49, ds, "", &out);
	String result = out.str_view();
	assert(result.contains("Processes input data"), "expected doc comment, got: %s", result);
}

fn void test_hover_function_no_comment() @test {
	DString out = dstring::temp();
	DocumentStore* ds = mem::new(DocumentStore);
	defer mem::free(ds);
	String content = "fn void bare() {}\nbare();";
	// Cursor on "bare" in the call
	encode_hover("file:///test.c3", content, 19, ds, "", &out);
	String result = out.str_view();
	assert(result.contains("fn void bare()"), "expected signature, got: %s", result);
	// Should not contain the separator since there's no comment
	assert(!result.contains("---"), "should have no separator, got: %s", result);
}

fn void test_hover_cross_file_doc_comment() @test {
	DString out = dstring::temp();
	DocumentStore* ds = mem::new(DocumentStore);
	defer mem::free(ds);
	ds.open("file:///lib.c3", "// Computes the sum of two numbers.\nfn int add(int a, int b) { return a + b; }", 1);

	String content = "int x = add(1, 2);";
	// Cursor on "add" at offset 8
	encode_hover("file:///test.c3", content, 8, ds, "", &out);
	String result = out.str_view();
	assert(result.contains("Computes the sum of two numbers"), "expected cross-file doc, got: %s", result);
	assert(result.contains("fn int add(int a, int b)"), "expected signature, got: %s", result);

	ds.close("file:///lib.c3");
}
