module lsp;

import std::core::dstring;

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

fn void test_signature_macro() @test {
	DString out = dstring::temp();
	String content = "macro swap(a, b) { }\nswap(";
	encode_signature_help(content, content.len, &out);
	String result = out.str_view();
	assert(result.contains("swap"), "got: %s", result);
	assert(result.contains(`"parameters"`), "got: %s", result);
}
