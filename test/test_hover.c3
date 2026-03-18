module lsp;

import std::core::dstring;

fn void test_hover_keyword() @test {
	DString out = dstring::temp();
	// "defer" at offset 0
	encode_hover("defer x();", 0, &out);
	String result = out.str_view();
	assert(result.contains("Defers statement execution to scope exit"), "got: %s", result);
	assert(result.contains(`"kind":"markdown"`), "got: %s", result);
}

fn void test_hover_builtin_type() @test {
	DString out = dstring::temp();
	encode_hover("int x = 0;", 0, &out);
	String result = out.str_view();
	assert(result.contains("32-bit signed integer"), "got: %s", result);
}

fn void test_hover_identifier() @test {
	DString out = dstring::temp();
	// "fn foo" — hover on "foo" at offset 3
	encode_hover("fn foo", 3, &out);
	String result = out.str_view();
	assert(result.contains("Identifier: `foo`"), "got: %s", result);
}

fn void test_hover_type_ident() @test {
	DString out = dstring::temp();
	// "struct MyType {}" — hover on MyType at offset 7
	encode_hover("struct MyType {}", 7, &out);
	String result = out.str_view();
	assert(result.contains("Type: `MyType`"), "got: %s", result);
}

fn void test_hover_ct_keyword() @test {
	DString out = dstring::temp();
	encode_hover("$sizeof(int)", 0, &out);
	String result = out.str_view();
	assert(result.contains("Returns size of a type in bytes"), "got: %s", result);
}

fn void test_hover_no_hover_on_whitespace() @test {
	DString out = dstring::temp();
	// offset 2 is a space between "fn" and "x"
	encode_hover("fn x", 2, &out);
	assert(out.str_view() == "", "got: %s", out.str_view());
}

fn void test_hover_empty() @test {
	DString out = dstring::temp();
	encode_hover("", 0, &out);
	assert(out.str_view() == "");
}

fn void test_hover_const_ident() @test {
	DString out = dstring::temp();
	encode_hover("constdef MAX = 1;", 9, &out);
	String result = out.str_view();
	assert(result.contains("Constant: `MAX`"), "got: %s", result);
}
