module lsp;

import std::core::dstring;
import std::core::mem;
import std::encoding::json;
import std::collections::object;

// Cursor-based rewrites in the code-action menu: fill switch, fill struct fields,
// generate a contract, toggle a `=>` body.

const String REFACTOR_URI = "file:///test.c3";

// The code actions for the cursor at the nth `needle` in `src`.
fn String actions_at(String src, String needle, int nth = 1, DocumentList* ds = null) @private
{
	DocumentList* docs = ds;
	if (docs == null) docs = mem::tnew(DocumentList);
	ActionDiag[] none = {};
	DString out = dstring::temp();
	encode_code_actions(REFACTOR_URI, src, docs, none, &out, "", true, nth_offset(src, needle, nth));
	return out.str_view();
}

// `src` after applying the action titled `title` from the `actions` JSON, or "" when
// there is no such action.
fn String apply_action(String src, String actions, String title) @private
{
	Object* arr = json::tparse(actions)!!;
	for (sz i = 0; i < arr.get_len(); i++)
	{
		Object* action = arr.get_at(i);
		if ((action.get_string("title") ?? "") != title) continue;
		Object* edits = action.get("edit")!!.get("changes")!!.get(REFACTOR_URI)!!;

		LineOffsets lo;
		lo.init(mem);
		defer lo.free();
		lo.build(src);
		// Non-overlapping edits, in order; inserts at one spot keep their order.
		DString res = dstring::temp();
		sz done = 0;
		for (sz e = 0; e < edits.get_len(); e++)
		{
			Object* edit = edits.get_at(e);
			Range r = decode_range(edit.get("range")!!);
			sz start = lo.entries[r.start.line] + r.start.character;
			sz end = lo.entries[r.end.line] + r.end.character;
			assert(start >= done, "edits must be in document order");
			res.append(src[done:start - done]);
			res.append(edit.get_string("newText")!!);
			done = end;
		}
		res.append(src[done..]);
		return res.str_view();
	}
	return "";
}

const String COLOR = "enum Color\n{\n\tRED,\n\tGREEN,\n\tBLUE,\n}\n";

fn void test_fill_switch_adds_missing_cases() @test
{
	String src = COLOR +++ "fn void f(Color c)\n{\n\tswitch (c)\n\t{\n\t\tcase RED:\n\t\t\tbreak;\n\t}\n}\n";
	String r = actions_at(src, "switch");
	assert(r.contains(`"title":"Add 2 missing cases","kind":"refactor.rewrite"`), "got: %s", r);
	String want = COLOR +++ "fn void f(Color c)\n{\n\tswitch (c)\n\t{\n\t\tcase RED:\n\t\t\tbreak;\n\t\tcase GREEN:\n\t\t\tbreak;\n\t\tcase BLUE:\n\t\t\tbreak;\n\t}\n}\n";
	String got = apply_action(src, r, "Add 2 missing cases");
	assert(got == want, "got:\n%s", got);
	assert(apply_action(src, actions_at(src, "break"), "Add 2 missing cases") == want, "from inside the body");
}

fn void test_fill_switch_goes_before_default() @test
{
	String src = COLOR +++ "fn void f(Color c)\n{\n\tswitch (c)\n\t{\n\t\tcase GREEN:\n\t\t\tbreak;\n\t\tdefault:\n\t\t\tbreak;\n\t}\n}\n";
	String want = COLOR +++ "fn void f(Color c)\n{\n\tswitch (c)\n\t{\n\t\tcase GREEN:\n\t\t\tbreak;\n\t\tcase RED:\n\t\t\tbreak;\n\t\tcase BLUE:\n\t\t\tbreak;\n\t\tdefault:\n\t\t\tbreak;\n\t}\n}\n";
	String got = apply_action(src, actions_at(src, "switch"), "Add 2 missing cases");
	assert(got == want, "got:\n%s", got);
}

fn void test_fill_switch_reads_qualified_and_range_labels() @test
{
	String src = COLOR +++ "fn void f(Color c)\n{\n\tswitch (c)\n\t{\n\t\tcase Color.RED..GREEN:\n\t\t\tbreak;\n\t}\n}\n";
	String r = actions_at(src, "switch");
	assert(r.contains(`"title":"Add missing case 'BLUE'"`), "got: %s", r);

	src = COLOR +++ "fn void f(Color c)\n{\n\tswitch (c)\n\t{\n\t\tcase RED:\n\t\tcase GREEN:\n\t\tcase BLUE:\n\t\t\tbreak;\n\t}\n}\n";
	r = actions_at(src, "switch");
	assert(!r.contains("missing case"), "nothing missing, got: %s", r);
}

fn void test_fill_switch_enum_from_other_file() @test
{
	DocumentList* ds = mem::new(DocumentList);
	defer mem::free(ds);
	ds.open("file:///other.c3", "enum Color { RED, GREEN }", 1);
	String src = "fn void f(Color c)\n{\n\tswitch (c)\n\t{\n\t}\n}\n";
	String want = "fn void f(Color c)\n{\n\tswitch (c)\n\t{\n\t\tcase RED:\n\t\t\tbreak;\n\t\tcase GREEN:\n\t\t\tbreak;\n\t}\n}\n";
	String got = apply_action(src, actions_at(src, "switch", 1, ds), "Add 2 missing cases");
	assert(got == want, "got:\n%s", got);
	ds.close("file:///other.c3");
}

fn void test_fill_switch_one_line() @test
{
	String src = COLOR +++ "fn void f(Color c)\n{\n\tswitch (c) { case RED: break; }\n}\n";
	String want = COLOR +++ "fn void f(Color c)\n{\n\tswitch (c) { case RED: break; \n\t\tcase GREEN:\n\t\t\tbreak;\n\t\tcase BLUE:\n\t\t\tbreak;\n\t}\n}\n";
	String got = apply_action(src, actions_at(src, "switch"), "Add 2 missing cases");
	assert(got == want, "got:\n%s", got);
}

fn void test_fill_switch_ignores_non_enum() @test
{
	String src = "fn void f(int c)\n{\n\tswitch (c)\n\t{\n\t\tcase 1:\n\t\t\tbreak;\n\t}\n}\n";
	assert(!actions_at(src, "switch").contains("missing case"));
}

const String FOO = "struct Foo\n{\n\tint a;\n\tString name;\n\tFoo* next;\n\tbool ok;\n\tfloat[4] v;\n}\n";

fn void test_fill_fields_empty_initializer() @test
{
	String src = FOO +++ "fn void f()\n{\n\tFoo x = {};\n}\n";
	String r = actions_at(src, "{}");
	assert(r.contains(`"title":"Fill 5 missing fields of 'Foo'","kind":"refactor.rewrite"`), "got: %s", r);
	String want = FOO +++ "fn void f()\n{\n\tFoo x = {\n\t\t.a = 0,\n\t\t.name = \"\",\n\t\t.next = null,\n\t\t.ok = false,\n\t\t.v = {},\n\t};\n}\n";
	String got = apply_action(src, r, "Fill 5 missing fields of 'Foo'");
	assert(got == want, "got:\n%s", got);
}

fn void test_fill_fields_single_line() @test
{
	String src = FOO +++ "fn void f()\n{\n\tFoo x = { .a = 1, .ok = true };\n}\n";
	String want = FOO +++ "fn void f()\n{\n\tFoo x = { .a = 1, .ok = true, .name = \"\", .next = null, .v = {} };\n}\n";
	String got = apply_action(src, actions_at(src, ".ok"), "Fill 3 missing fields of 'Foo'");
	assert(got == want, "got:\n%s", got);
}

fn void test_fill_fields_multi_line_adds_comma() @test
{
	String src = FOO +++ "fn void f()\n{\n\tFoo x = {\n\t\t.a = 1,\n\t\t.ok = true // set\n\t};\n}\n";
	String want = FOO +++ "fn void f()\n{\n\tFoo x = {\n\t\t.a = 1,\n\t\t.ok = true, // set\n\t\t.name = \"\",\n\t\t.next = null,\n\t\t.v = {},\n\t};\n}\n";
	String got = apply_action(src, actions_at(src, ".a"), "Fill 3 missing fields of 'Foo'");
	assert(got == want, "got:\n%s", got);
}

const String NESTED = "struct Inner { int q; int w; }\nstruct Outer { Inner inner; int z; }\n";

fn void test_fill_fields_nested_and_return() @test
{
	String src = NESTED +++ "fn void f()\n{\n\tOuter o = { .inner = { .q = 1 } };\n}\n";
	String got = apply_action(src, actions_at(src, ".q"), "Fill missing field 'w' of 'Inner'");
	assert(got == NESTED +++ "fn void f()\n{\n\tOuter o = { .inner = { .q = 1, .w = 0 } };\n}\n", "got:\n%s", got);

	src = NESTED +++ "fn Inner make()\n{\n\treturn { .w = 2 };\n}\n";
	got = apply_action(src, actions_at(src, ".w"), "Fill missing field 'q' of 'Inner'");
	assert(got == NESTED +++ "fn Inner make()\n{\n\treturn { .w = 2, .q = 0 };\n}\n", "got:\n%s", got);
}

fn void test_fill_fields_skips_union_members() @test
{
	String src = "struct Tagged\n{\n\tint kind;\n\tunion\n\t{\n\t\tint i;\n\t\tfloat f;\n\t}\n}\nfn void f()\n{\n\tTagged t = {};\n}\n";
	String r = actions_at(src, "{}");
	assert(r.contains(`"title":"Fill missing field 'kind' of 'Tagged'"`), "got: %s", r);
}

fn void test_fill_fields_not_offered() @test
{
	String src = FOO +++ "fn void f(bool b)\n{\n\tFoo x = { 1, \"n\" };\n\tif (b)\n\t{\n\t\tx.a = 2;\n\t}\n}\n";
	assert(!actions_at(src, "1, ").contains("Fill"), "positional initializer");
	assert(!actions_at(src, "x.a").contains("Fill"), "block brace");
	assert(!actions_at(src, "Foo x").contains("Fill"), "outside the braces");
}

fn void test_contract_generated_from_signature() @test
{
	String src = "module m;\n\nfn int add(int a, int b = 2) => a + b;\n";
	String r = actions_at(src, "add");
	assert(r.contains(`"title":"Generate doc contract","kind":"refactor.rewrite"`), "got: %s", r);
	String got = apply_action(src, r, "Generate doc contract");
	assert(got == "module m;\n\n<*\n @param a\n @param b\n @return\n*>\nfn int add(int a, int b = 2) => a + b;\n", "got:\n%s", got);

	src = "macro @twice(#expr, $Type, x; @body(i))\n{\n}\n";
	got = apply_action(src, actions_at(src, "twice"), "Generate doc contract");
	assert(got == "<*\n @param #expr\n @param $Type\n @param x\n*>\nmacro @twice(#expr, $Type, x; @body(i))\n{\n}\n", "got:\n%s", got);

	src = "struct Foo { int v; }\nfn void Foo.set(&self, int v)\n{\n\tself.v = v;\n}\n";
	got = apply_action(src, actions_at(src, "set"), "Generate doc contract");
	assert(got == "struct Foo { int v; }\n<*\n @param v\n*>\nfn void Foo.set(&self, int v)\n{\n\tself.v = v;\n}\n", "got:\n%s", got);
}

fn void test_contract_not_offered() @test
{
	assert(!actions_at("fn void f()\n{\n}\n", "f").contains("contract"), "nothing to document");
	assert(!actions_at("<*\n @param a\n*>\nfn int g(int a) => a;\n", "g").contains("contract"), "already has one");
	assert(!actions_at("alias Cb = fn void(int x);\n", "x").contains("contract"), "function type");
	String src = "fn void f(int a)\n{\n\ta++;\n}\n";
	assert(!actions_at(src, "a++").contains("contract"), "only on the header");
}

fn void test_toggle_expression_body() @test
{
	String src = "fn int twice(int x) => x * 2;\n";
	String r = actions_at(src, "twice");
	assert(r.contains(`"title":"Convert to block body","kind":"refactor.rewrite"`), "got: %s", r);
	String block = "fn int twice(int x)\n{\n\treturn x * 2;\n}\n";
	assert(apply_action(src, r, "Convert to block body") == block, "got:\n%s", apply_action(src, r, "Convert to block body"));
	String back = apply_action(block, actions_at(block, "return"), "Convert to expression body (=>)");
	assert(back == src, "got:\n%s", back);
}

fn void test_toggle_void_body() @test
{
	String src = "fn void hi() => io::printn(\"hi\");\n";
	String block = "fn void hi()\n{\n\tio::printn(\"hi\");\n}\n";
	assert(apply_action(src, actions_at(src, "hi"), "Convert to block body") == block);
	assert(apply_action(block, actions_at(block, "hi"), "Convert to expression body (=>)") == src);
}

fn void test_toggle_uses_file_indentation() @test
{
	String src = "fn int one()\n{\n    return 1;\n}\nfn int two() => 2;\n";
	String got = apply_action(src, actions_at(src, "two"), "Convert to block body");
	assert(got == "fn int one()\n{\n    return 1;\n}\nfn int two()\n{\n    return 2;\n}\n", "got:\n%s", got);
}

fn void test_toggle_not_offered() @test
{
	String src = "fn int f(int x)\n{\n\tx++;\n\treturn x;\n}\n";
	assert(!actions_at(src, "f").contains("Convert"), "two statements");
	src = "alias IntFn = fn int(int);\nfn void f()\n{\n\tIntFn g = fn int(int n) => n;\n}\n";
	assert(!actions_at(src, "n) =>").contains("Convert"), "lambda");
	src = "fn int f(int x)\n{\n\t// keep\n\treturn x;\n}\n";
	assert(!actions_at(src, "f").contains("Convert"), "comment would be lost");
}
