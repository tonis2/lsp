module lsp;

import std::core::dstring;
import std::core::mem;

// Local-variable scoping for rename, highlight, references and definition
// (issue #6: renaming one block's `abc` also renamed a sibling block's `abc`).

const String SIBLING_BLOCKS = `fn void example()
{
    {
        long abc = 123;
        abc += 1;
    }
    {
        long abc = 123;
        abc += 2;
    }
}`;

// Offset of the nth (1-based) occurrence of `needle` in `s`.
fn sz nth_offset(String s, String needle, int nth = 1) @private
{
	sz from = 0;
	for (int i = 1; ; i++)
	{
		sz at = from + s[from..].index_of(needle)!!;
		if (i == nth) return at;
		from = at + 1;
	}
}

fn int edit_count(String json) @private
{
	int count = 0;
	sz pos = 0;
	while (try found = json[pos..].index_of(`"range"`))
	{
		count++;
		pos += found + 1;
	}
	return count;
}

fn String start_at(int line, int col) @private
{
	return string::tformat(`"start":{"line":%d,"character":%d}`, line, col);
}

fn String rename_at(String content, sz offset, DocumentList* ds = null) @private
{
	DocumentList* docs = ds;
	if (docs == null) docs = mem::tnew(DocumentList);
	DString out = dstring::temp();
	encode_rename("file:///test.c3", content, offset, docs, "", "renamed", &out);
	return out.str_view();
}

fn void test_rename_local_ignores_sibling_block() @test
{
	String r = rename_at(SIBLING_BLOCKS, nth_offset(SIBLING_BLOCKS, "abc", 1));
	assert(edit_count(r) == 2, "only the first block, got: %s", r);
	assert(r.contains(start_at(3, 13)) && r.contains(start_at(4, 8)), "got: %s", r);

	r = rename_at(SIBLING_BLOCKS, nth_offset(SIBLING_BLOCKS, "abc", 4));
	assert(edit_count(r) == 2, "only the second block, got: %s", r);
	assert(r.contains(start_at(7, 13)) && r.contains(start_at(8, 8)), "got: %s", r);
}

fn void test_rename_local_after_closed_block() @test
{
	// The block's `x` is out of scope once the block closes.
	String src = "fn void f()\n{\n    { int x = 1; x++; }\n    int x = 2;\n    x = 3;\n}";
	String r = rename_at(src, nth_offset(src, "x", 4));
	assert(edit_count(r) == 2, "got: %s", r);
	assert(r.contains(start_at(3, 8)) && r.contains(start_at(4, 4)), "got: %s", r);
}

fn void test_rename_foreach_variables_per_loop() @test
{
	String src = "fn void f(int[] a)\n{\n    foreach (x : a) { x += 1; }\n    foreach (i, x : a) { x += (int)i; }\n}";
	String r = rename_at(src, nth_offset(src, "x", 1));
	assert(edit_count(r) == 2, "got: %s", r);
	assert(r.contains(start_at(2, 13)) && r.contains(start_at(2, 22)), "got: %s", r);
}

fn void test_rename_local_skips_members_and_designators() @test
{
	String src = "struct P { int x; }\nfn void f(P p)\n{\n    int x = p.x;\n    P q = { .x = x };\n}";
	String r = rename_at(src, nth_offset(src, "x", 2));
	assert(edit_count(r) == 2, "the local and its one use, got: %s", r);
	assert(r.contains(start_at(3, 8)) && r.contains(start_at(4, 17)), "got: %s", r);
}

fn void test_rename_untyped_macro_parameter() @test
{
	String src = "macro twice(v) { return v * 2; }\nfn void f() { int v = 1; }";
	String r = rename_at(src, nth_offset(src, "v", 2));
	assert(edit_count(r) == 2, "got: %s", r);
	assert(r.contains(start_at(0, 12)) && r.contains(start_at(0, 24)), "got: %s", r);
}

fn void test_rename_lambda_parameter_separately() @test
{
	// C3 lambdas do not capture, so the lambda's `num` and f's `num` are unrelated.
	String src = "alias IntFn = fn int(int);\nfn int f(int num)\n{\n    IntFn g = fn int(int num) => num * 3;\n    return g(num);\n}";
	String r = rename_at(src, nth_offset(src, "num", 3));
	assert(edit_count(r) == 2, "only the lambda's num, got: %s", r);
	assert(r.contains(start_at(3, 25)) && r.contains(start_at(3, 33)), "got: %s", r);
	r = rename_at(src, nth_offset(src, "num", 4));
	assert(edit_count(r) == 2, "only f's num, got: %s", r);
	assert(r.contains(start_at(1, 13)) && r.contains(start_at(4, 13)), "got: %s", r);
}

fn void test_rename_function_from_call_inside_body() @test
{
	String src = "fn void helper() {}\nfn void a() { helper(); }\nfn void b() { helper(); }";
	String r = rename_at(src, nth_offset(src, "helper", 2));
	assert(edit_count(r) == 3, "the declaration and both calls, got: %s", r);
}

fn void test_rename_global_variable_from_inside_body() @test
{
	String src = "int counter = 0;\nfn void a() { counter++; }\nfn void b() { counter++; }";
	String r = rename_at(src, nth_offset(src, "counter", 2));
	assert(edit_count(r) == 3, "got: %s", r);
}

fn void test_rename_function_declared_in_other_open_file() @test
{
	DocumentList* ds = mem::new(DocumentList);
	defer mem::free(ds);
	ds.open("file:///other.c3", "fn void helper() {}", 1);
	String r = rename_at("fn void a() { helper(); }", 15, ds);
	assert(r.contains("file:///other.c3") && r.contains("file:///test.c3"), "got: %s", r);
	ds.close("file:///other.c3");
}

fn void test_rename_type_from_inside_body() @test
{
	String src = "struct Foo { int a; }\nfn void f() { Foo x; }\nfn void g() { Foo y; }";
	String r = rename_at(src, nth_offset(src, "Foo", 2));
	assert(edit_count(r) == 3, "got: %s", r);
}

fn void test_rename_refuses_names_declared_outside_project() @test
{
	// `printn` and `String` live in the stdlib: renaming the uses alone would
	// break the code.
	String src = "import std::io;\nfn void f() { io::printn(\"x\"); String s; }";
	assert(rename_at(src, nth_offset(src, "printn")) == "", "qualified stdlib call");
	assert(rename_at(src, nth_offset(src, "String")) == "", "stdlib type");
}

fn void test_highlight_local_ignores_other_scopes() @test
{
	String src = "fn void a() { int abc = 1; abc++; }\nfn void b() { int abc = 2; }";
	DString out = dstring::temp();
	encode_document_highlights(src, nth_offset(src, "abc", 2), &out);
	assert(edit_count(out.str_view()) == 2, "got: %s", out.str_view());
}

fn void test_references_local_stay_in_scope() @test
{
	DocumentList* ds = mem::new(DocumentList);
	defer mem::free(ds);
	ds.open("file:///other.c3", "fn void c() { long abc = 5; }", 1);
	DString out = dstring::temp();
	encode_references("file:///test.c3", SIBLING_BLOCKS, nth_offset(SIBLING_BLOCKS, "abc", 2), ds, "", true, &out);
	String r = out.str_view();
	assert(edit_count(r) == 2, "got: %s", r);
	assert(!r.contains("other.c3"), "a local never leaves its function, got: %s", r);

	out.clear();
	encode_references("file:///test.c3", SIBLING_BLOCKS, nth_offset(SIBLING_BLOCKS, "abc", 2), ds, "", false, &out);
	assert(edit_count(out.str_view()) == 1, "without the declaration, got: %s", out.str_view());
	ds.close("file:///other.c3");
}

fn void test_definition_local_in_second_block() @test
{
	DocumentList* ds = mem::new(DocumentList);
	defer mem::free(ds);
	DString out = dstring::temp();
	encode_definition("file:///test.c3", SIBLING_BLOCKS, nth_offset(SIBLING_BLOCKS, "abc", 4), ds, "", &out);
	assert(out.str_view().contains(start_at(7, 13)), "the use goes to its own block, got: %s", out.str_view());

	out.clear();
	encode_definition("file:///test.c3", SIBLING_BLOCKS, nth_offset(SIBLING_BLOCKS, "abc", 3), ds, "", &out);
	assert(out.str_view().contains(start_at(7, 13)), "a local declaration is its own definition, got: %s", out.str_view());
}

fn void test_definition_array_and_foreach_locals() @test
{
	DocumentList* ds = mem::new(DocumentList);
	defer mem::free(ds);
	String src = "fn void f()\n{\n    int[3] arr;\n    int[<4>] vec;\n    foreach (x : arr) { x += vec[0]; }\n}";
	DString out = dstring::temp();
	encode_definition("file:///test.c3", src, nth_offset(src, "arr", 2), ds, "", &out);
	assert(out.str_view().contains(start_at(2, 11)), "got: %s", out.str_view());

	out.clear();
	encode_definition("file:///test.c3", src, nth_offset(src, "vec", 2), ds, "", &out);
	assert(out.str_view().contains(start_at(3, 13)), "got: %s", out.str_view());

	out.clear();
	encode_definition("file:///test.c3", src, nth_offset(src, "x", 2), ds, "", &out);
	assert(out.str_view().contains(start_at(4, 13)), "got: %s", out.str_view());
}
