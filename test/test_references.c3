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

// --- Rename tests ---

fn void test_rename_same_file() @test {
	DString out = dstring::temp();
	DocumentList* ds = mem::new(DocumentList);
	defer mem::free(ds);
	String content = "fn void hello() {}\nhello();\nhello();";
	// Cursor on "hello" at offset 8
	encode_rename("file:///test.c3", content, 8, ds, "", "world", &out);
	String result = out.str_view();
	assert(result.contains(`"changes"`), "expected changes, got: %s", result);
	assert(result.contains(`"newText":"world"`), "expected newText, got: %s", result);
	// Should have 3 edits (decl + 2 calls)
	int count = 0;
	usz pos = 0;
	while (pos < result.len) {
		if (try found = result[pos..].index_of(`"newText"`)) {
			count++;
			pos = pos + found + 1;
		} else {
			break;
		}
	}
	assert(count == 3, "expected 3 edits, got %d: %s", count, result);
}

fn void test_rename_cross_file() @test {
	DString out = dstring::temp();
	DocumentList* ds = mem::new(DocumentList);
	defer mem::free(ds);
	ds.open("file:///other.c3", "fn void greet() { hello(); }", 1);

	String content = "fn void hello() {}\nhello();";
	// Cursor on "hello" at offset 8
	encode_rename("file:///test.c3", content, 8, ds, "", "goodbye", &out);
	String result = out.str_view();
	assert(result.contains(`file:///test.c3`), "got: %s", result);
	assert(result.contains(`file:///other.c3`), "got: %s", result);
	assert(result.contains(`"newText":"goodbye"`), "got: %s", result);

	ds.close("file:///other.c3");
}

fn void test_rename_keyword_empty() @test {
	DString out = dstring::temp();
	DocumentList* ds = mem::new(DocumentList);
	defer mem::free(ds);
	// Cursor on "fn" keyword at offset 0
	encode_rename("file:///test.c3", "fn void hello() {}", 0, ds, "", "xyz", &out);
	assert(out.str_view() == "", "expected empty for keyword, got: %s", out.str_view());
}

fn void test_rename_type_ident() @test {
	DString out = dstring::temp();
	DocumentList* ds = mem::new(DocumentList);
	defer mem::free(ds);
	ds.open("file:///other.c3", "Foo y;", 1);

	String content = "struct Foo {}\nFoo x;";
	// Cursor on "Foo" at offset 7
	encode_rename("file:///test.c3", content, 7, ds, "", "Bar", &out);
	String result = out.str_view();
	assert(result.contains(`file:///test.c3`), "got: %s", result);
	assert(result.contains(`file:///other.c3`), "got: %s", result);
	assert(result.contains(`"newText":"Bar"`), "got: %s", result);

	ds.close("file:///other.c3");
}

fn void test_rename_correct_ranges() @test {
	DString out = dstring::temp();
	DocumentList* ds = mem::new(DocumentList);
	defer mem::free(ds);
	// "foo" starts at char 8, length 3
	String content = "fn void foo() { foo(); }";
	encode_rename("file:///test.c3", content, 8, ds, "", "baz", &out);
	String result = out.str_view();
	// First foo: char 8-11
	assert(result.contains(`"start":{"line":0,"character":8},"end":{"line":0,"character":11}`), "got: %s", result);
	// Second foo: char 16-19
	assert(result.contains(`"start":{"line":0,"character":16},"end":{"line":0,"character":19}`), "got: %s", result);
}

// --- Scoped Rename tests ---

fn void test_rename_local_var_scoped() @test {
	DString out = dstring::temp();
	DocumentList* ds = mem::new(DocumentList);
	defer mem::free(ds);
	// Two functions each with a local variable "x"
	String content = `fn void foo() { int x = 1; x = 2; }
fn void bar() { int x = 3; x = 4; }`;
	// Cursor on "x" inside foo() — offset of first "x" after "int "
	// "fn void foo() { int " = 20 chars, so x is at offset 20
	encode_rename("file:///test.c3", content, 20, ds, "", "y", &out);
	String result = out.str_view();
	assert(result.contains(`"newText":"y"`), "expected rename edits, got: %s", result);
	// Should have exactly 2 edits (the two x's in foo), not 4
	int count = 0;
	usz pos = 0;
	while (pos < result.len) {
		if (try found = result[pos..].index_of(`"newText"`)) {
			count++;
			pos = pos + found + 1;
		} else {
			break;
		}
	}
	assert(count == 2, "expected 2 edits (only in foo), got %d: %s", count, result);
}

fn void test_rename_local_var_no_cross_file() @test {
	DString out = dstring::temp();
	DocumentList* ds = mem::new(DocumentList);
	defer mem::free(ds);
	// Other file also has "x"
	ds.open("file:///other.c3", "fn void baz() { int x = 5; }", 1);

	String content = `fn void foo() { int x = 1; }`;
	// Cursor on "x" inside foo() at offset 20
	encode_rename("file:///test.c3", content, 20, ds, "", "y", &out);
	String result = out.str_view();
	assert(result.contains(`file:///test.c3`), "got: %s", result);
	// Should NOT contain edits for the other file
	assert(!result.contains(`file:///other.c3`), "should not rename in other file, got: %s", result);

	ds.close("file:///other.c3");
}

fn void test_rename_module_level_still_global() @test {
	DString out = dstring::temp();
	DocumentList* ds = mem::new(DocumentList);
	defer mem::free(ds);
	ds.open("file:///other.c3", "fn void greet() { hello(); }", 1);

	// "hello" at offset 8 is the function name — module level
	String content = "fn void hello() {}\nhello();";
	encode_rename("file:///test.c3", content, 8, ds, "", "goodbye", &out);
	String result = out.str_view();
	// Should still rename across files for module-level symbols
	assert(result.contains(`file:///test.c3`), "got: %s", result);
	assert(result.contains(`file:///other.c3`), "got: %s", result);

	ds.close("file:///other.c3");
}
