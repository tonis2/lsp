module lsp;

import std::core::dstring;
import std::core::mem;

// --- Document Highlight tests ---

fn void test_highlight_function_calls() @test {
	DString out = dstring::temp();
	String content = "fn void hello() {}\nhello();\nhello();";
	// Cursor on "hello" in first call at offset 19
	encode_document_highlights(content, 19, &out);
	String result = out.str_view();
	// Should have 3 highlights: declaration + 2 calls
	assert(result.contains(`"kind":1`), "got: %s", result);
	// Count occurrences of "range" — should be 3
	int count = 0;
	usz pos = 0;
	while (pos < result.len) {
		if (try found = result[pos..].index_of(`"range"`)) {
			count++;
			pos = pos + found + 1;
		} else {
			break;
		}
	}
	assert(count == 3, "expected 3 highlights, got %d: %s", count, result);
}

fn void test_highlight_no_match_on_keyword() @test {
	DString out = dstring::temp();
	// Cursor on "fn" keyword at offset 0
	encode_document_highlights("fn void hello() {}", 0, &out);
	assert(out.str_view() == "", "expected empty for keyword, got: %s", out.str_view());
}

fn void test_highlight_single_occurrence() @test {
	DString out = dstring::temp();
	String content = "fn void unique_name() {}";
	// Cursor on "unique_name" at offset 8
	encode_document_highlights(content, 8, &out);
	String result = out.str_view();
	assert(result.contains(`"range"`), "got: %s", result);
	// Should be exactly 1 highlight
	int count = 0;
	usz pos = 0;
	while (pos < result.len) {
		if (try found = result[pos..].index_of(`"range"`)) {
			count++;
			pos = pos + found + 1;
		} else {
			break;
		}
	}
	assert(count == 1, "expected 1 highlight, got %d: %s", count, result);
}

fn void test_highlight_type_ident() @test {
	DString out = dstring::temp();
	String content = "struct Foo {}\nFoo x;";
	// Cursor on "Foo" at offset 7 (declaration)
	encode_document_highlights(content, 7, &out);
	String result = out.str_view();
	int count = 0;
	usz pos = 0;
	while (pos < result.len) {
		if (try found = result[pos..].index_of(`"range"`)) {
			count++;
			pos = pos + found + 1;
		} else {
			break;
		}
	}
	assert(count == 2, "expected 2 highlights for type, got %d: %s", count, result);
}

fn void test_highlight_const_ident() @test {
	DString out = dstring::temp();
	String content = "constdef MAX = 100;\nint x = MAX;";
	// Cursor on "MAX" at offset 9
	encode_document_highlights(content, 9, &out);
	String result = out.str_view();
	int count = 0;
	usz pos = 0;
	while (pos < result.len) {
		if (try found = result[pos..].index_of(`"range"`)) {
			count++;
			pos = pos + found + 1;
		} else {
			break;
		}
	}
	assert(count == 2, "expected 2 highlights for const, got %d: %s", count, result);
}

// --- Find References tests ---

fn void test_references_same_file() @test {
	DString out = dstring::temp();
	DocumentList* ds = mem::new(DocumentList);
	defer mem::free(ds);
	String content = "fn void hello() {}\nhello();\nhello();";
	// Cursor on "hello" at offset 19
	encode_references("file:///test.c3", content, 19, ds, "", true, &out);
	String result = out.str_view();
	// Should find 3 references: decl + 2 calls
	int count = 0;
	usz pos = 0;
	while (pos < result.len) {
		if (try found = result[pos..].index_of(`"uri"`)) {
			count++;
			pos = pos + found + 1;
		} else {
			break;
		}
	}
	assert(count == 3, "expected 3 references, got %d: %s", count, result);
}

fn void test_references_cross_file() @test {
	DString out = dstring::temp();
	DocumentList* ds = mem::new(DocumentList);
	defer mem::free(ds);
	ds.open("file:///other.c3", "fn void greet() { hello(); }", 1);

	String content = "fn void hello() {}\nhello();";
	// Cursor on "hello" at offset 19
	encode_references("file:///test.c3", content, 19, ds, "", true, &out);
	String result = out.str_view();
	// Should find references in both files
	assert(result.contains(`file:///test.c3`), "got: %s", result);
	assert(result.contains(`file:///other.c3`), "got: %s", result);

	ds.close("file:///other.c3");
}

fn void test_references_keyword_empty() @test {
	DString out = dstring::temp();
	DocumentList* ds = mem::new(DocumentList);
	defer mem::free(ds);
	encode_references("file:///test.c3", "fn void hello() {}", 0, ds, "", true, &out);
	assert(out.str_view() == "", "expected empty for keyword, got: %s", out.str_view());
}

fn void test_references_type_ident() @test {
	DString out = dstring::temp();
	DocumentList* ds = mem::new(DocumentList);
	defer mem::free(ds);
	ds.open("file:///other.c3", "Foo y;", 1);

	String content = "struct Foo {}\nFoo x;";
	// Cursor on "Foo" at offset 14
	encode_references("file:///test.c3", content, 14, ds, "", true, &out);
	String result = out.str_view();
	assert(result.contains(`file:///test.c3`), "got: %s", result);
	assert(result.contains(`file:///other.c3`), "got: %s", result);

	ds.close("file:///other.c3");
}
