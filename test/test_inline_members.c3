module lsp;

import std::core::dstring;
import std::core::mem;

// Members reached through `inline` (a struct's `inline GameObject obj;` or `typedef Comp =
// inline GameObject;`) and the methods an interface declares read as the receiver's own:
// `self.context.` on such a field offers them, and they resolve and hover.
const String INLINE_BASE = "module game;\n"
	+++ "struct Pos { int x; }\n"
	+++ "struct GameObject { void* handle; Pos pos; }\n"
	+++ "<* Its name. *>\n"
	+++ "fn String GameObject.getName(&self) { return \"\"; }\n";

const String INLINE_USER = "struct Car\n"
	+++ "{\n"
	+++ "\tComp context;\n"
	+++ "}\n"
	+++ "fn void Car.init(&self)\n"
	+++ "{\n"
	+++ "\tself.context.getName();\n"
	+++ "\tself.context.pos.x = 1;\n"
	+++ "\tself.context.";

const String INLINE_MEMBER_SRC = INLINE_BASE +++ "struct Comp { inline GameObject obj; int extra; }\n" +++ INLINE_USER;
const String INLINE_TYPEDEF_SRC = INLINE_BASE +++ "typedef Comp = inline GameObject;\n" +++ INLINE_USER;

fn String inline_complete(String src) @private
{
	DocumentList* ds = mem::new(DocumentList);
	defer mem::free(ds);
	DString out = dstring::temp();
	encode_completions("file:///p/a.c3", src, src.len, ds, "", &out);
	return out.str_view();
}

fn void test_inline_member_completion() @test {
	String r = inline_complete(INLINE_MEMBER_SRC);
	foreach (String label : { "obj", "extra", "handle", "pos", "getName" })
	{
		assert(r.contains(string::tformat(`"label":"%s"`, label)), "%s missing, got: %s", label, r);
	}
}

fn void test_inline_typedef_completion() @test {
	String r = inline_complete(INLINE_TYPEDEF_SRC);
	foreach (String label : { "handle", "pos", "getName" })
	{
		assert(r.contains(string::tformat(`"label":"%s"`, label)), "%s missing, got: %s", label, r);
	}
}

fn void test_inline_field_chain() @test {
	// `pos` lives on the embedded GameObject; its own members still complete.
	String r = inline_complete(INLINE_MEMBER_SRC +++ "pos.");
	assert(r.contains(`"label":"x"`), "got: %s", r);
	assert(starts_at(def_at(INLINE_TYPEDEF_SRC, "x = 1"), 1, 17), "got: %s", def_at(INLINE_TYPEDEF_SRC, "x = 1"));
}

fn void test_inline_method_definition_and_hover() @test {
	foreach (String src : { INLINE_MEMBER_SRC, INLINE_TYPEDEF_SRC })
	{
		String r = def_at(src, "getName();");
		assert(starts_at(r, 4, 21), "got: %s", r);

		DocumentList* ds = mem::new(DocumentList);
		defer mem::free(ds);
		DString out = dstring::temp();
		encode_hover("file:///p/a.c3", src, src.index_of("getName();")!! + 1, ds, "", &out);
		assert(out.str_view().contains("Its name."), "got: %s", out.str_view());
	}
}

fn void test_interface_method_completion() @test {
	String src = "module game;\n"
		+++ "interface Named { fn String getName(); }\n"
		+++ "interface Comp : Named { fn void setName(String n) @optional; }\n"
		+++ INLINE_USER;
	String r = inline_complete(src);
	assert(r.contains(`"label":"getName"`) && r.contains(`"label":"setName"`), "got: %s", r);
}

fn void test_inline_cycle_terminates() @test {
	String src = "module game;\n"
		+++ "struct Comp { inline Other o; }\n"
		+++ "struct Other { inline Comp c; int q; }\n"
		+++ INLINE_USER;
	String r = inline_complete(src);
	assert(r.contains(`"label":"o"`) && r.contains(`"label":"q"`) && r.contains(`"label":"c"`), "got: %s", r);
}

fn void test_inline_slice_typedef_unchanged() @test {
	// `typedef String = inline char[]` has no declared members to inherit; only the
	// builtin slice properties come through, as before.
	String src = "module game;\ntypedef Str = inline char[];\nfn void f(Str s) { s.";
	String r = inline_complete(src);
	assert(r.contains(`"label":"len"`) && r.contains(`"label":"ptr"`), "got: %s", r);
}
