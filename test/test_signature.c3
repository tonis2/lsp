module lsp;

import std::core::dstring;
import std::core::mem;

fn void test_signature_basic() @test {
	DString out = dstring::temp();
	// Declaration + call site. Cursor inside parens of call.
	String content = "fn void greet(String name) {}\ngreet(";
	encode_signature_help(content, content.len, &out);
	String result = out.str_view();
	assert(result.contains(`"signatures"`), "got: %s", result);
	assert(result.contains("greet"), "got: %s", result);
	assert(result.contains("String name"), "got: %s", result);
	assert(result.contains(`"activeParameter":0`), "got: %s", result);
}

fn void test_signature_second_param() @test {
	DString out = dstring::temp();
	String content = "fn int add(int a, int b) { return a + b; }\nadd(1, ";
	encode_signature_help(content, content.len, &out);
	String result = out.str_view();
	assert(result.contains(`"activeParameter":1`), "got: %s", result);
	assert(result.contains("int a"), "got: %s", result);
	assert(result.contains("int b"), "got: %s", result);
}

fn void test_signature_no_context() @test {
	DString out = dstring::temp();
	// Cursor not inside any function call
	encode_signature_help("int x = 5;", 5, &out);
	assert(out.str_view() == "", "got: %s", out.str_view());
}

fn void test_signature_unknown_function() @test {
	DString out = dstring::temp();
	// Function called but not declared in file
	encode_signature_help("unknown(", 8, &out);
	assert(out.str_view() == "", "got: %s", out.str_view());
}

fn void test_signature_no_params() @test {
	DString out = dstring::temp();
	String content = "fn void nop() {}\nnop(";
	encode_signature_help(content, content.len, &out);
	String result = out.str_view();
	assert(result.contains("nop"), "got: %s", result);
	assert(result.contains(`"activeParameter":0`), "got: %s", result);
}

// Regression: closing paren already present (as produced by the function-completion
// snippet "name($0)"), cursor between '(' and ')'. The ')' starts at the cursor offset
// and must not hide the call's opening paren.
fn void test_signature_closed_parens_empty() @test {
	DString out = dstring::temp();
	String content = "fn void greet(String name) {}\ngreet()";
	// Cursor between the call's '(' and ')': offset of the ')' (last char).
	encode_signature_help(content, content.len - 1, &out);
	String result = out.str_view();
	assert(result.contains(`"signatures"`), "expected signature, got: %s", result);
	assert(result.contains("String name"), "expected param, got: %s", result);
	assert(result.contains(`"activeParameter":0`), "got: %s", result);
}

fn void test_signature_closed_parens_with_args() @test {
	DString out = dstring::temp();
	String content = "fn int add(int a, int b) {}\nadd(1, )";
	// Cursor between ',' and ')': offset of the ')' (last char).
	encode_signature_help(content, content.len - 1, &out);
	String result = out.str_view();
	assert(result.contains("int b"), "expected param b, got: %s", result);
	assert(result.contains(`"activeParameter":1`), "got: %s", result);
}

// A method call `recv.method(` must drop the implicit `self` receiver so the first
// hint and activeParameter line up with the caller's first real argument.
fn void test_signature_method_skips_self() @test {
	DString out = dstring::temp();
	String content = "struct Foo { int x; }\nfn int Foo.scale(self, int factor) {}\nFoo f;\nf.scale(";
	encode_signature_help(content, content.len, &out);
	String result = out.str_view();
	assert(result.contains("Foo.scale"), "got: %s", result);
	assert(result.contains("int factor"), "got: %s", result);
	// `self` is the receiver and must not appear as a parameter hint.
	assert(!result.contains(`{"label":"self"}`), "self should be dropped, got: %s", result);
	assert(result.contains(`"activeParameter":0`), "got: %s", result);
}

fn void test_signature_method_second_param() @test {
	DString out = dstring::temp();
	String content = "struct Foo { int x; }\nfn int Foo.add(self, int a, int b) {}\nFoo f;\nf.add(1, ";
	encode_signature_help(content, content.len, &out);
	String result = out.str_view();
	// Receiver dropped; the cursor sits on the second real arg -> activeParameter 1.
	assert(result.contains("int a"), "got: %s", result);
	assert(result.contains("int b"), "got: %s", result);
	assert(result.contains(`"activeParameter":1`), "got: %s", result);
}

fn void test_signature_macro() @test {
	DString out = dstring::temp();
	String content = "macro swap(a, b) { }\nswap(";
	encode_signature_help(content, content.len, &out);
	String result = out.str_view();
	assert(result.contains("swap"), "got: %s", result);
	assert(result.contains(`"parameters"`), "got: %s", result);
}

// Cursor in the VALUE-arg list of a generic call `foo{Bar}(...)` → show value params.
fn void test_signature_generic_function_param() @test {
	DString out = dstring::temp();
	String content = "fn void foo(int a, double b)<T> {}\nfoo{Bar}(1, ";
	encode_signature_help(content, content.len, &out);
	String result = out.str_view();
	assert(result.contains("foo"), "got: %s", result);
	assert(result.contains("double b"), "got: %s", result);
	assert(result.contains(`"activeParameter":1`), "got: %s", result);
}

// Cursor in the GENERIC type-arg list `foo{...}` → show type params, not value params.
fn void test_signature_generic_function_generic() @test {
	DString out = dstring::temp();
	String content = "fn void foo(int a, double b)<T, U> {}\nfoo{Bar, ";
	encode_signature_help(content, content.len, &out);
	String result = out.str_view();
	assert(result.contains("foo"), "got: %s", result);
	assert(result.contains(`"label":"U"`), "got: %s", result);
	assert(result.contains(`"activeParameter":1`), "got: %s", result);
}

// A module-qualified generic call resolves to the right module's overload.
fn void test_signature_module_qualification() @test {
	DString out = dstring::temp();
	DocumentList* ds = mem::new(DocumentList);
	defer mem::free(ds);

	ds.open("file:///bar.c3", "module bar;\nfn void get(double x) {}", 1);
	String content = "import foo;\nimport bar;\nfn void test() {\n\tfoo::get{int}(\n}";
	ds.open("file:///test.c3", content, 1);
	ds.open("file:///foo.c3", "module foo;\nfn void get(int x) {}", 1);

	encode_signature_help(content, 56, &out, uri: "file:///test.c3", docs: ds);
	String result = out.str_view();
	assert(result.contains("int x"), "got: %s", result);
	assert(!result.contains("double x"), "got: %s", result);

	ds.close("file:///bar.c3");
	ds.close("file:///foo.c3");
	ds.close("file:///test.c3");
}
