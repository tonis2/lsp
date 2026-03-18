module lsp;

import std::core::dstring;

fn void test_json_escape_plain() @test {
	DString out = dstring::temp();
	json_escape_into(&out, "hello");
	assert(out.str_view() == "hello");
}

fn void test_json_escape_quotes() @test {
	DString out = dstring::temp();
	json_escape_into(&out, `say "hi"`);
	assert(out.str_view() == `say \"hi\"`);
}

fn void test_json_escape_backslash() @test {
	DString out = dstring::temp();
	json_escape_into(&out, "a\\b");
	assert(out.str_view() == "a\\\\b");
}

fn void test_json_escape_newline() @test {
	DString out = dstring::temp();
	json_escape_into(&out, "a\nb");
	assert(out.str_view() == "a\\nb");
}

fn void test_json_escape_tab() @test {
	DString out = dstring::temp();
	json_escape_into(&out, "a\tb");
	assert(out.str_view() == "a\\tb");
}

fn void test_json_escape_empty() @test {
	DString out = dstring::temp();
	json_escape_into(&out, "");
	assert(out.str_view() == "");
}
