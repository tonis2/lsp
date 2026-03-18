module lsp;

import std::core::dstring;

fn void test_folding_empty() @test {
	DString out = dstring::temp();
	encode_folding_ranges("", &out);
	assert(out.str_view() == "");
}

fn void test_folding_single_brace_pair() @test {
	DString out = dstring::temp();
	// fn main() {\n}\n
	encode_folding_ranges("fn main() {\n}", &out);
	assert(out.str_view() == `{"startLine":0,"endLine":1}`, "got: %s", out.str_view());
}

fn void test_folding_same_line_braces() @test {
	DString out = dstring::temp();
	// Braces on same line should not produce a fold
	encode_folding_ranges("struct Foo {}", &out);
	assert(out.str_view() == "");
}

fn void test_folding_nested_braces() @test {
	DString out = dstring::temp();
	// "fn x() {\nif (true) {\n}\n}"
	encode_folding_ranges("fn x() {\nif (true) {\n}\n}", &out);
	// Inner fold: lines 1-2, outer fold: lines 0-3
	String result = out.str_view();
	assert(result.contains(`"startLine":1`));
	assert(result.contains(`"startLine":0`));
}

fn void test_folding_block_comment() @test {
	DString out = dstring::temp();
	encode_folding_ranges("/* line1\nline2\nline3 */", &out);
	assert(out.str_view() == `{"startLine":0,"endLine":2,"kind":"comment"}`, "got: %s", out.str_view());
}

fn void test_folding_consecutive_imports() @test {
	DString out = dstring::temp();
	encode_folding_ranges("import foo;\nimport bar;\nimport baz;", &out);
	String result = out.str_view();
	assert(result.contains(`"kind":"imports"`), "got: %s", result);
	assert(result.contains(`"startLine":0`));
	assert(result.contains(`"endLine":2`));
}

fn void test_folding_single_import_no_fold() @test {
	DString out = dstring::temp();
	encode_folding_ranges("import foo;\nfn x() {}", &out);
	// Single import should not produce an imports fold
	String result = out.str_view();
	assert(!result.contains(`"kind":"imports"`), "got: %s", result);
}
