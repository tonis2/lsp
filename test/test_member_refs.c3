module lsp;

import std::core::dstring;
import std::core::mem;

// Members — fields, methods, enum members — are found by the type that declares them,
// across files: the declaration plus every use whose receiver resolves to that type.
const String MR_LIB = "module game::core;\n"
	+++ "struct Thing { int count; }\n"
	+++ "struct Other { int count; }\n"
	+++ "fn void Thing.ping(&self) {}\n"
	+++ "fn void local_use() { Thing t; t.ping(); int count = 3; count++; }\n"
	+++ "struct GameObject { void* handle; }\n"
	+++ "fn String GameObject.getName(&self) { return \"\"; }\n"
	+++ "struct Comp { inline GameObject obj; }\n"
	+++ "enum Color { RED, GREEN }\n";

const String MR_APP = "module game::app;\n"
	+++ "import game::core;\n"
	+++ "struct Car { Comp context; }\n"
	+++ "fn void Car.go(&self, Thing* t, Other* o, Comp c)\n"
	+++ "{\n"
	+++ "\tt.ping();\n"
	+++ "\tt.count = 2;\n"
	+++ "\to.count = 5;\n"
	+++ "\tThing t2 = { .count = 1 };\n"
	+++ "\tc.getName();\n"
	+++ "\tself.context.getName();\n"
	+++ "\tColor k = Color.RED;\n"
	+++ "\tif (k == RED) return;\n"
	+++ "}\n";

const String MR_LIB_URI = "file:///p/core.c3";
const String MR_APP_URI = "file:///p/app.c3";

fn sz mr_offset(String s, String needle, int nth = 0) @private
{
	sz from = 0;
	for (int i = 0; ; i++)
	{
		sz at = from + s[from..].index_of(needle)!!;
		if (i == nth) return at;
		from = at + 1;
	}
}

fn int mr_count(String haystack, String needle) @private
{
	int count = 0;
	sz pos = 0;
	while (pos < haystack.len)
	{
		sz? found = haystack[pos..].index_of(needle);
		if (catch found) break;
		count++;
		pos += found + 1;
	}
	return count;
}

// `"uri":"<uri>","range":{"start":{"line":<line>` appears in the answer.
fn bool mr_has(String json, String uri, int line) @private
{
	return json.contains(string::tformat(`"uri":"%s","range":{"start":{"line":%d,`, uri, line));
}

// References asked in `uri`/`content` at `needle` (+ `skip`), with the other file open.
fn String mr_refs(String uri, String content, String needle, sz skip, bool include_decl = true) @private
{
	DocumentList* ds = mem::new(DocumentList);
	defer mem::free(ds);
	ds.open(MR_LIB_URI, MR_LIB, 1);
	ds.open(MR_APP_URI, MR_APP, 1);
	defer { ds.close(MR_LIB_URI); ds.close(MR_APP_URI); }
	DString out = dstring::temp();
	encode_references(uri, content, mr_offset(content, needle) + skip, ds, "", include_decl, &out);
	return out.str_view();
}

fn String mr_rename(String uri, String content, String needle, sz skip) @private
{
	DocumentList* ds = mem::new(DocumentList);
	defer mem::free(ds);
	ds.open(MR_LIB_URI, MR_LIB, 1);
	ds.open(MR_APP_URI, MR_APP, 1);
	defer { ds.close(MR_LIB_URI); ds.close(MR_APP_URI); }
	DString out = dstring::temp();
	encode_rename(uri, content, mr_offset(content, needle) + skip, ds, "", "renamed", &out);
	return out.str_view();
}

fn void test_member_refs_method_across_files() @test {
	// From the declaration and from a call in the other file: the same three.
	foreach (String r : { mr_refs(MR_LIB_URI, MR_LIB, "Thing.ping", 6), mr_refs(MR_APP_URI, MR_APP, "t.ping", 2) })
	{
		assert(mr_count(r, `"uri"`) == 3, "got: %s", r);
		assert(mr_has(r, MR_LIB_URI, 3) && mr_has(r, MR_LIB_URI, 4) && mr_has(r, MR_APP_URI, 5), "got: %s", r);
	}
}

fn void test_member_refs_field_by_type() @test {
	// From the field declaration, a use and a designator: Thing.count's declaration and
	// its two typed uses — not Other.count, not the local `count`.
	foreach (String r : {
		mr_refs(MR_LIB_URI, MR_LIB, "int count", 4),
		mr_refs(MR_APP_URI, MR_APP, "t.count", 2),
		mr_refs(MR_APP_URI, MR_APP, ".count = 1", 1) })
	{
		assert(mr_count(r, `"uri"`) == 3, "got: %s", r);
		assert(mr_has(r, MR_LIB_URI, 1) && mr_has(r, MR_APP_URI, 6) && mr_has(r, MR_APP_URI, 8), "got: %s", r);
	}
	String other = mr_refs(MR_APP_URI, MR_APP, "o.count", 2);
	assert(mr_count(other, `"uri"`) == 2 && mr_has(other, MR_LIB_URI, 2), "got: %s", other);
}

fn void test_member_refs_without_declaration() @test {
	String r = mr_refs(MR_APP_URI, MR_APP, "t.count", 2, false);
	assert(mr_count(r, `"uri"`) == 2 && !mr_has(r, MR_LIB_URI, 1), "got: %s", r);
}

fn void test_member_refs_through_inline() @test {
	// `c.getName()` on a Comp and `self.context.getName()` reach GameObject.getName.
	String r = mr_refs(MR_LIB_URI, MR_LIB, "GameObject.getName", 11);
	assert(mr_count(r, `"uri"`) == 3, "got: %s", r);
	assert(mr_has(r, MR_LIB_URI, 6) && mr_has(r, MR_APP_URI, 9) && mr_has(r, MR_APP_URI, 10), "got: %s", r);
}

fn void test_member_refs_enum_member() @test {
	// `Color.RED`, the bare `RED` and the declaration.
	String r = mr_refs(MR_APP_URI, MR_APP, "Color.RED", 6);
	assert(mr_count(r, `"uri"`) == 3, "got: %s", r);
	assert(mr_has(r, MR_LIB_URI, 8) && mr_has(r, MR_APP_URI, 11) && mr_has(r, MR_APP_URI, 12), "got: %s", r);
}

fn void test_member_rename_field() @test {
	foreach (String r : { mr_rename(MR_APP_URI, MR_APP, "t.count", 2), mr_rename(MR_LIB_URI, MR_LIB, "int count", 4) })
	{
		assert(mr_count(r, `"newText":"renamed"`) == 3, "got: %s", r);
		// Not Other.count (line 2 / `o.count`), not the local `count` (line 4).
		assert(!r.contains(`"start":{"line":2,"character":21}`), "got: %s", r);
		assert(!r.contains(`"start":{"line":7,`), "got: %s", r);
		assert(!r.contains(`"start":{"line":4,"character":43}`), "got: %s", r);
	}
}

fn void test_member_rename_refused_for_undeclared_member() @test {
	// A member the project does not declare (a library's) is left alone.
	String src = "module game::x;\nimport std::collections::list;\nfn void f(List{int} li) { li.push(1); }\n";
	DocumentList* ds = mem::new(DocumentList);
	defer mem::free(ds);
	DString out = dstring::temp();
	encode_rename("file:///p/x.c3", src, mr_offset(src, "push"), ds, "", "renamed", &out);
	assert(out.str_view() == "", "got: %s", out.str_view());
}

// --- definition, hover and completion through the types a type takes members from ---

const String MR_SRC = "module game;\n"
	+++ "struct Pos { int x; }\n"
	+++ "struct GameObject { void* handle; Pos pos; }\n"
	+++ "fn Pos GameObject.getPos(&self) { return self.pos; }\n"
	+++ "struct Comp { inline GameObject obj; }\n"
	+++ "typedef PlainT = GameObject;\n"
	+++ "struct Bag <Type> { Type item; }\n"
	+++ "fn void Bag.shake(&self) {}\n"
	+++ "struct Holder { inline Bag{int} bag; }\n"
	+++ "interface Named { fn String getName(); }\n"
	+++ "alias NamedAlias = Living;\n"
	+++ "fn void f(Comp c, Holder h, Living l, NamedAlias na, PlainT pt)\n"
	+++ "{\n"
	+++ "\tc.getPos().x = 1;\n"
	+++ "\th.shake();\n"
	+++ "\tl.getName();\n"
	+++ "\tna.getName();\n"
	+++ "\t";

// The parent interface lives in another file.
const String MR_IFACE = "module game;\ninterface Living : Named { fn void live(); }\n";

fn String mr_def(String needle, sz skip) @private
{
	DocumentList* ds = mem::new(DocumentList);
	defer mem::free(ds);
	ds.open("file:///p/iface.c3", MR_IFACE, 1);
	defer ds.close("file:///p/iface.c3");
	DString out = dstring::temp();
	encode_definition("file:///p/a.c3", MR_SRC, mr_offset(MR_SRC, needle) + skip, ds, "", &out);
	return out.str_view();
}

fn String mr_complete(String tail) @private
{
	DocumentList* ds = mem::new(DocumentList);
	defer mem::free(ds);
	ds.open("file:///p/iface.c3", MR_IFACE, 1);
	defer ds.close("file:///p/iface.c3");
	String src = string::tformat("%s%s", MR_SRC, tail);
	DString out = dstring::temp();
	encode_completions("file:///p/a.c3", src, src.len, ds, "", &out);
	return out.str_view();
}

fn void test_member_return_type_through_inline() @test {
	String r = mr_def("x = 1", 0);
	assert(starts_at(r, 1, 17), "got: %s", r);
	r = mr_complete("c.getPos().");
	assert(r.contains(`"label":"x"`), "got: %s", r);
}

fn void test_member_generic_inline() @test {
	String r = mr_def("shake();", 0);
	assert(starts_at(r, 7, 12), "got: %s", r);
	r = mr_complete("h.");
	assert(r.contains(`"label":"shake"`) && r.contains(`"label":"item"`), "got: %s", r);
}

fn void test_member_interface_parent_in_other_file() @test {
	String r = mr_def("l.getName", 2);
	assert(starts_at(r, 9, 28), "got: %s", r);
	r = mr_def("na.getName", 3);
	assert(starts_at(r, 9, 28), "alias to interface, got: %s", r);
	r = mr_complete("l.");
	assert(r.contains(`"label":"getName"`) && r.contains(`"label":"live"`), "got: %s", r);
}

fn void test_member_plain_typedef_fields_only() @test {
	// `typedef PlainT = GameObject;` keeps the fields but not the methods.
	String r = mr_complete("pt.");
	assert(r.contains(`"label":"handle"`) && r.contains(`"label":"pos"`), "got: %s", r);
	assert(!r.contains(`"label":"getPos"`), "got: %s", r);
}

// --- generic receivers, inferred enum members, untyped receivers, highlights ---

const String ME_SRC = "module game::e;\n"
	+++ "enum Color { RED, GREEN }\n"
	+++ "enum Light { RED, OFF }\n"
	+++ "struct Box <Type> { Type n; }\n"
	+++ "fn void Box{int}.clear(&self) {}\n"
	+++ "struct Ping { int id; }\n"
	+++ "fn void Ping.unique_ping(&self) {}\n"
	+++ "struct Tag { int id; }\n"
	+++ "fn void paint(Color c) {}\n"
	+++ "fn Color pick() { return RED; }\n"
	+++ "macro go(x) { x.unique_ping(); }\n"
	+++ "macro go2(y) { y.id = 1; }\n"
	+++ "fn void h1(Ping x) { x.id = 1; }\n"
	+++ "fn void h2(Tag x) { x.id = 2; }\n"
	+++ "fn void f(Color k, Box{int} b)\n"
	+++ "{\n"
	+++ "\tswitch (k)\n"
	+++ "\t{\n"
	+++ "\t\tcase RED: break;\n"
	+++ "\t\tdefault: break;\n"
	+++ "\t}\n"
	+++ "\tLight l = RED;\n"
	+++ "\tpaint(.RED);\n"
	+++ "\tb.clear();\n"
	+++ "\tif (k == RED) return;\n"
	+++ "}\n";

const String ME_URI = "file:///p/e.c3";

enum MeRequest @private
{
	REFS,
	RENAME,
	HIGHLIGHT,
}

fn String me_ask(MeRequest req, String needle, sz skip = 0, int nth = 0) @private
{
	DocumentList* ds = mem::new(DocumentList);
	defer mem::free(ds);
	ds.open(ME_URI, ME_SRC, 1);
	defer ds.close(ME_URI);
	DString out = dstring::temp();
	sz offset = mr_offset(ME_SRC, needle, nth) + skip;
	switch (req)
	{
		case REFS: encode_references(ME_URI, ME_SRC, offset, ds, "", true, &out);
		case RENAME: encode_rename(ME_URI, ME_SRC, offset, ds, "", "renamed", &out);
		case HIGHLIGHT: encode_document_highlights(ME_SRC, offset, &out, null, ME_URI, ds, "");
	}
	return out.str_view();
}

fn bool me_on_line(String json, int line) @private
{
	return json.contains(string::tformat(`"start":{"line":%d,`, line));
}

fn void test_member_refs_generic_receiver_declaration() @test {
	// `fn void Box{int}.clear` is the declaration `b.clear()` on a `Box{int}` calls.
	foreach (String r : { me_ask(REFS, "b.clear", 2), me_ask(REFS, "}.clear", 2) })
	{
		assert(mr_count(r, `"uri"`) == 2 && me_on_line(r, 4) && me_on_line(r, 23), "got: %s", r);
	}
	String r = me_ask(RENAME, "b.clear", 2);
	assert(mr_count(r, `"newText":"renamed"`) == 2 && me_on_line(r, 4) && me_on_line(r, 23), "got: %s", r);
}

fn void test_member_refs_inferred_enum_member() @test {
	// Color.RED: the declaration, `return RED`, `case RED`, `paint(.RED)` and `k == RED`
	// — not Light.RED or `Light l = RED`.
	foreach (String r : { me_ask(REFS, "RED"), me_ask(REFS, "case RED", 5), me_ask(REFS, ".RED", 1) })
	{
		assert(mr_count(r, `"uri"`) == 5, "got: %s", r);
		assert(me_on_line(r, 1) && me_on_line(r, 9) && me_on_line(r, 18) && me_on_line(r, 22) && me_on_line(r, 24), "got: %s", r);
	}
	foreach (String r : { me_ask(REFS, "RED", 0, 1), me_ask(REFS, "l = RED", 4) })
	{
		assert(mr_count(r, `"uri"`) == 2 && me_on_line(r, 2) && me_on_line(r, 21), "got: %s", r);
	}
}

fn void test_member_rename_enum_member_leaves_other_enum() @test {
	String r = me_ask(RENAME, "case RED", 5);
	assert(mr_count(r, `"newText":"renamed"`) == 5, "got: %s", r);
	assert(!me_on_line(r, 2) && !me_on_line(r, 21), "got: %s", r);
}

fn void test_member_refs_untyped_receiver_unique_name() @test {
	// `x` in `macro go(x)` has no type, but only Ping declares `unique_ping`.
	foreach (String r : { me_ask(REFS, "x.unique_ping", 2), me_ask(REFS, "Ping.unique_ping", 5) })
	{
		assert(mr_count(r, `"uri"`) == 2 && me_on_line(r, 6) && me_on_line(r, 10), "got: %s", r);
	}
	// Both Ping and Tag declare `id`: the untyped `y.id` only matches itself.
	String r = me_ask(REFS, "y.id", 2);
	assert(mr_count(r, `"uri"`) == 1 && me_on_line(r, 11), "got: %s", r);
}

fn void test_member_highlights_by_type() @test {
	// `x.id` on a Ping marks Ping.id, not the same-spelled `x.id` on a Tag.
	String r = me_ask(HIGHLIGHT, "x.id", 2);
	assert(mr_count(r, `"range"`) == 2 && me_on_line(r, 5) && me_on_line(r, 12), "got: %s", r);
	// An untyped receiver keeps matching by receiver text.
	r = me_ask(HIGHLIGHT, "y.id", 2);
	assert(mr_count(r, `"range"`) == 1 && me_on_line(r, 11), "got: %s", r);
}
