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
	sz pos = 0;
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
	sz pos = 0;
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
	sz pos = 0;
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
	sz pos = 0;
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
	sz pos = 0;
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

fn int count_occurrences(String haystack, String needle) @private {
	int count = 0;
	sz pos = 0;
	while (pos < haystack.len) {
		if (try found = haystack[pos..].index_of(needle)) {
			count++;
			pos = pos + found + 1;
		} else {
			break;
		}
	}
	return count;
}

fn void test_rename() @test {
	DocumentList* ds = mem::new(DocumentList);
	defer mem::free(ds);

	// Same file: decl + 2 calls = 3 edits
	{
		DString out = dstring::temp();
		encode_rename("file:///test.c3", "fn void hello() {}\nhello();\nhello();", 8, ds, "", "world", &out);
		String r = out.str_view();
		assert(r.contains(`"changes"`), "same_file: expected changes, got: %s", r);
		assert(r.contains(`"newText":"world"`), "same_file: expected newText, got: %s", r);
		assert(count_occurrences(r, `"newText"`) == 3, "same_file: expected 3 edits, got: %s", r);
	}

	// Cross file: edits in both files
	{
		DString out = dstring::temp();
		ds.open("file:///other.c3", "fn void greet() { hello(); }", 1);
		encode_rename("file:///test.c3", "fn void hello() {}\nhello();", 8, ds, "", "goodbye", &out);
		String r = out.str_view();
		assert(r.contains(`file:///test.c3`), "cross_file: got: %s", r);
		assert(r.contains(`file:///other.c3`), "cross_file: got: %s", r);
		assert(r.contains(`"newText":"goodbye"`), "cross_file: got: %s", r);
		ds.close("file:///other.c3");
	}

	// Keyword: no rename
	{
		DString out = dstring::temp();
		encode_rename("file:///test.c3", "fn void hello() {}", 0, ds, "", "xyz", &out);
		assert(out.str_view() == "", "keyword: expected empty, got: %s", out.str_view());
	}

	// Type ident: cross-file rename
	{
		DString out = dstring::temp();
		ds.open("file:///other.c3", "Foo y;", 1);
		encode_rename("file:///test.c3", "struct Foo {}\nFoo x;", 7, ds, "", "Bar", &out);
		String r = out.str_view();
		assert(r.contains(`file:///test.c3`), "type: got: %s", r);
		assert(r.contains(`file:///other.c3`), "type: got: %s", r);
		assert(r.contains(`"newText":"Bar"`), "type: got: %s", r);
		ds.close("file:///other.c3");
	}

	// Correct ranges: verify character offsets
	{
		DString out = dstring::temp();
		encode_rename("file:///test.c3", "fn void foo() { foo(); }", 8, ds, "", "baz", &out);
		String r = out.str_view();
		assert(r.contains(`"start":{"line":0,"character":8},"end":{"line":0,"character":11}`), "ranges: got: %s", r);
		assert(r.contains(`"start":{"line":0,"character":16},"end":{"line":0,"character":19}`), "ranges: got: %s", r);
	}

	// Local var scoped: only rename x in foo(), not in bar()
	{
		DString out = dstring::temp();
		String content = `fn void foo() { int x = 1; x = 2; }
fn void bar() { int x = 3; x = 4; }`;
		encode_rename("file:///test.c3", content, 20, ds, "", "y", &out);
		String r = out.str_view();
		assert(r.contains(`"newText":"y"`), "scoped: got: %s", r);
		assert(count_occurrences(r, `"newText"`) == 2, "scoped: expected 2 edits, got: %s", r);
	}

	// Local var: no cross-file leaking
	{
		DString out = dstring::temp();
		ds.open("file:///other.c3", "fn void baz() { int x = 5; }", 1);
		encode_rename("file:///test.c3", `fn void foo() { int x = 1; }`, 20, ds, "", "y", &out);
		String r = out.str_view();
		assert(r.contains(`file:///test.c3`), "no_cross: got: %s", r);
		assert(!r.contains(`file:///other.c3`), "no_cross: should not rename in other file, got: %s", r);
		ds.close("file:///other.c3");
	}

	// Function parameter (single line): rename in signature + body
	{
		DString out = dstring::temp();
		String src = `fn void update(String content, int version) { io::printfn(content); }
fn void other() { String content = "x"; }`;
		encode_rename("file:///test.c3", src, 22, ds, "", "text", &out);
		String r = out.str_view();
		assert(r.contains(`"newText":"text"`), "param: got: %s", r);
		assert(count_occurrences(r, `"newText"`) == 2, "param: expected 2 edits, got: %s", r);
	}

	// Function parameter with cursor at end-of-word (offset on comma after param name)
	// This is what VS Code sends when you press F2 on a word
	{
		DString out = dstring::temp();
		String src = `fn void update(String content, int version) { io::printfn(content); }
fn void other() { String content = "x"; }`;
		// "content" is at offset 22, length 7, so offset 29 is the comma after it
		encode_rename("file:///test.c3", src, 29, ds, "", "text", &out);
		String r = out.str_view();
		assert(r.contains(`"newText":"text"`), "param_end: got: %s", r);
		assert(count_occurrences(r, `"newText"`) == 2, "param_end: expected 2 edits, got: %s", r);
	}

	// Function parameter (multiline, brace on next line): rename param + all body usages
	{
		DString out = dstring::temp();
		String src = `fn void handle_semantic_tokens(LspServer* server, Object* msg, String id_json)
{
    Document* doc = server.documents.find(uri);
    server.running = true;
}`;
		// "server" param at offset 42
		encode_rename("file:///test.c3", src, 42, ds, "", "srv", &out);
		String r = out.str_view();
		assert(r.len > 0, "multiline_param: expected result, got empty");
		assert(r.contains(`"newText":"srv"`), "multiline_param: got: %s", r);
		assert(count_occurrences(r, `"newText"`) == 3, "multiline_param: expected 3 edits (param + 2 body), got: %s", r);
	}

	// Multiline param with cursor at end-of-word (comma after "server")
	{
		DString out = dstring::temp();
		String src = `fn void handle_semantic_tokens(LspServer* server, Object* msg, String id_json)
{
    Document* doc = server.documents.find(uri);
    server.running = true;
}`;
		// "server" at offset 42, length 6, so offset 48 is the comma
		encode_rename("file:///test.c3", src, 48, ds, "", "srv", &out);
		String r = out.str_view();
		assert(r.len > 0, "multiline_param_end: expected result, got empty");
		assert(r.contains(`"newText":"srv"`), "multiline_param_end: got: %s", r);
		assert(count_occurrences(r, `"newText"`) == 3, "multiline_param_end: expected 3 edits, got: %s", r);
	}

	// Module-level symbol: still renames globally across files
	{
		DString out = dstring::temp();
		ds.open("file:///other.c3", "fn void greet() { hello(); }", 1);
		encode_rename("file:///test.c3", "fn void hello() {}\nhello();", 8, ds, "", "goodbye", &out);
		String r = out.str_view();
		assert(r.contains(`file:///test.c3`), "global: got: %s", r);
		assert(r.contains(`file:///other.c3`), "global: got: %s", r);
		ds.close("file:///other.c3");
	}
}

// --- Module-visibility tests ---

// References to a type must not include same-named tokens in files whose module
// neither is, imports, nor is imported by the type's module.
fn void test_references_module_visibility() @test {
	DString out = dstring::temp();
	DocumentList* ds = mem::new(DocumentList);
	defer mem::free(ds);
	// Imports myapp — its Config occurrences are ours.
	ds.open("file:///user.c3", "module consumer;\nimport myapp;\nfn void t() { Config c; }", 1);
	// Unrelated module with its own Config — must be excluded.
	ds.open("file:///other.c3", "module other;\nstruct Config { int y; }\nfn void u() { Config c; }", 1);

	String content = "module myapp;\nstruct Config { int x; }";
	sz offset = content.len - 12; // on `Config`
	encode_references("file:///main.c3", content, offset, ds, "", true, &out);
	String result = out.str_view();
	assert(result.contains("file:///user.c3"), "importer's occurrences must be included, got: %s", result);
	assert(!result.contains("file:///other.c3"), "unrelated module's Config is a different symbol, got: %s", result);

	ds.close("file:///user.c3");
	ds.close("file:///other.c3");
}

// Rename must respect the same visibility rule: the unrelated module keeps its name.
fn void test_rename_module_visibility() @test {
	DString out = dstring::temp();
	DocumentList* ds = mem::new(DocumentList);
	defer mem::free(ds);
	ds.open("file:///user.c3", "module consumer;\nimport myapp;\nfn void t() { Config c; }", 1);
	ds.open("file:///other.c3", "module other;\nstruct Config { int y; }", 1);

	String content = "module myapp;\nstruct Config { int x; }";
	sz offset = content.len - 12; // on `Config`
	encode_rename("file:///main.c3", content, offset, ds, "", "Settings", &out);
	String result = out.str_view();
	assert(result.contains("file:///user.c3"), "importer must be renamed, got: %s", result);
	assert(!result.contains("file:///other.c3"), "unrelated module must not be renamed, got: %s", result);

	ds.close("file:///user.c3");
	ds.close("file:///other.c3");
}

// From the *importer's* file, the symbol must resolve to the imported module's
// declaration — not to a same-named declaration in an unrelated module that
// happens to come first in scan order.
fn void test_references_from_importer_resolves_visible_decl() @test {
	DString out = dstring::temp();
	DocumentList* ds = mem::new(DocumentList);
	defer mem::free(ds);
	// Opened first: would win under first-found module resolution.
	ds.open("file:///other.c3", "module other;\nstruct Config { int y; }\nfn void u() { Config c; }", 1);
	ds.open("file:///lib.c3", "module myapp;\nstruct Config { int x; }", 1);

	String content = "module consumer;\nimport myapp;\nfn void t() { Config c; }";
	sz offset = content.len - 10; // on `Config`
	encode_references("file:///user.c3", content, offset, ds, "", true, &out);
	String result = out.str_view();
	assert(result.contains("file:///lib.c3"), "imported module's declaration site must be included, got: %s", result);
	assert(!result.contains("file:///other.c3"), "unrelated module must be excluded even when scanned first, got: %s", result);

	ds.close("file:///other.c3");
	ds.close("file:///lib.c3");
}
