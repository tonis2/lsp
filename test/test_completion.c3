module lsp;

import std::core::dstring;

fn void test_completion_empty_prefix() @test {
	DString out = dstring::temp();
	encode_completions("fn x() {}", 0, &out);
	String result = out.str_view();
	assert(result.contains(`"isIncomplete":false`), "got: %s", result);
	assert(result.contains(`"items":[`));
}

fn void test_completion_keyword_prefix() @test {
	DString out = dstring::temp();
	// "whi" at offset 3 — should match "while"
	encode_completions("whi", 3, &out);
	String result = out.str_view();
	assert(result.contains(`"label":"while"`), "got: %s", result);
}

fn void test_completion_type_prefix() @test {
	DString out = dstring::temp();
	// "in" at offset 2 — should match "int", "int128", "inline", "interface", "import"
	encode_completions("in", 2, &out);
	String result = out.str_view();
	assert(result.contains(`"label":"int"`), "got: %s", result);
}

fn void test_completion_ct_prefix() @test {
	DString out = dstring::temp();
	// "$si" at offset 3 — should match "$sizeof"
	encode_completions("$si", 3, &out);
	String result = out.str_view();
	assert(result.contains(`"label":"$sizeof"`), "got: %s", result);
	// Should not include regular keywords when prefix starts with $
	assert(!result.contains(`"label":"if"`), "got: %s", result);
}

fn void test_completion_doc_identifiers() @test {
	DString out = dstring::temp();
	// "fn hello() {}\nfn world() {}\nhel" — at offset after "hel"
	String content = "fn hello() {}\nfn world() {}\nhel";
	encode_completions(content, content.len, &out);
	String result = out.str_view();
	assert(result.contains(`"label":"hello"`), "got: %s", result);
}

fn void test_completion_no_duplicate_doc_idents() @test {
	DString out = dstring::temp();
	// Same identifier appears twice; should only appear once in completions
	String content = "fn x() { foo(); foo(); }\nfo";
	encode_completions(content, content.len, &out);
	String result = out.str_view();
	// Count occurrences of "foo" — should be exactly one
	usz count = 0;
	usz pos = 0;
	while (pos < result.len) {
		if (try idx = result[pos..].index_of(`"label":"foo"`)) {
			count++;
			pos = pos + idx + 1;
		} else {
			break;
		}
	}
	assert(count == 1, "Expected 1 occurrence of foo, got %d", count);
}

fn void test_completion_struct_json() @test {
	DString out = dstring::temp();
	encode_completions("str", 3, &out);
	String result = out.str_view();
	// Should have "struct" as keyword and be valid JSON structure
	assert(result.contains(`"label":"struct"`), "got: %s", result);
	assert(result.contains(`"kind":14`), "got: %s", result); // Keyword kind
}
