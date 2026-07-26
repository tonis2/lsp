module lsp;

import std::core::mem;
import std::core::dstring;

// Offset of the nth (1-based) occurrence of `needle` in `s`, for placing a cursor.
fn sz offset_of(String s, String needle, int nth = 1) @private
{
	int seen = 0;
	for (sz i = 0; i + needle.len <= s.len; i++)
	{
		if (s[i:needle.len] != needle) continue;
		seen++;
		if (seen == nth) return i;
	}
	return 0;
}

// --- interface name -> implementing types ---

fn void test_implementation_finds_types_with_conformance_clause() @test {
	String src = "module app;\n"
		+++ "interface Greeter { fn void greet(); }\n"
		+++ "struct Loud (Greeter) {}\n"
		+++ "struct Quiet (Greeter) @private {}\n"
		+++ "struct Unrelated {}\n"
		+++ "fn void Loud.greet(&self) @dynamic {}\n";

	DocumentList* ds = mem::new(DocumentList);
	defer mem::free(ds);
	ds.open("file:///proj/src/a.c3", src, 1);

	DString out = dstring::temp();
	// Cursor on the interface's own name.
	encode_implementation("file:///proj/src/a.c3", src, offset_of(src, "Greeter"), ds, "", &out);
	String r = out.str_view();

	assert(r.contains(`"line":2`), "Loud must be reported, got: %s", r);
	assert(r.contains(`"line":3`), "Quiet must be reported, got: %s", r);
	assert(!r.contains(`"line":4`), "a type with no conformance clause must not be reported, got: %s", r);

	ds.close("file:///proj/src/a.c3");
}

fn void test_implementation_handles_multiple_interfaces_in_one_clause() @test {
	String src = "module app;\n"
		+++ "interface Alpha { fn void a(); }\n"
		+++ "interface Beta { fn void b(); }\n"
		+++ "struct Both (Alpha, Beta) {}\n";

	DocumentList* ds = mem::new(DocumentList);
	defer mem::free(ds);
	ds.open("file:///proj/src/b.c3", src, 1);

	DString out = dstring::temp();
	encode_implementation("file:///proj/src/b.c3", src, offset_of(src, "Beta"), ds, "", &out);
	String r = out.str_view();
	assert(r.contains(`"line":3`), "second entry of the clause must match, got: %s", r);

	ds.close("file:///proj/src/b.c3");
}

// An enum's associated-value list uses the same parentheses as a conformance clause.
// `String` there is a parameter type, not an implemented interface.
fn void test_implementation_ignores_enum_associated_values() @test {
	String src = "module app;\n"
		+++ "enum State : int (String desc) { RUNNING, DONE }\n";

	DocumentList* ds = mem::new(DocumentList);
	defer mem::free(ds);
	ds.open("file:///proj/src/c.c3", src, 1);

	DString out = dstring::temp();
	encode_implementation("file:///proj/src/c.c3", src, offset_of(src, "String"), ds, "", &out);
	assert(out.str_view().len == 0, "associated-value type must not read as conformance, got: %s", out.str_view());

	ds.close("file:///proj/src/c.c3");
}

fn void test_implementation_of_plain_type_yields_nothing() @test {
	String src = "module app;\nstruct Plain {}\nfn void use(Plain p) {}\n";

	DocumentList* ds = mem::new(DocumentList);
	defer mem::free(ds);
	ds.open("file:///proj/src/d.c3", src, 1);

	DString out = dstring::temp();
	encode_implementation("file:///proj/src/d.c3", src, offset_of(src, "Plain"), ds, "", &out);
	// Empty buffer, so the handler answers `null` rather than an empty array.
	assert(out.str_view().len == 0, "a type nobody implements must report nothing, got: %s", out.str_view());

	ds.close("file:///proj/src/d.c3");
}

// --- interface method -> @dynamic bodies ---

fn void test_implementation_finds_dynamic_method_bodies() @test {
	String src = "module app;\n"
		+++ "interface Greeter { fn void greet(); }\n"
		+++ "struct Loud (Greeter) {}\n"
		+++ "fn void Loud.greet(&self) @dynamic {}\n"
		+++ "struct Other {}\n"
		+++ "fn void Other.greet(&self) {}\n";

	DocumentList* ds = mem::new(DocumentList);
	defer mem::free(ds);
	ds.open("file:///proj/src/e.c3", src, 1);

	DString out = dstring::temp();
	// Cursor on the method name declared inside the interface body.
	encode_implementation("file:///proj/src/e.c3", src, offset_of(src, "greet"), ds, "", &out);
	String r = out.str_view();

	assert(r.contains(`"line":3`), "the @dynamic body must be reported, got: %s", r);
	assert(!r.contains(`"line":5`), "a same-named method without @dynamic is not an implementation, got: %s", r);

	ds.close("file:///proj/src/e.c3");
}

// The attribute sits after the parameter list; a `@dynamic` belonging to some later
// declaration must not be attributed to this one.
fn void test_implementation_dynamic_attribute_does_not_leak_across_declarations() @test {
	String src = "module app;\n"
		+++ "interface Greeter { fn void greet(); }\n"
		+++ "fn void Plain.greet(&self) {}\n"
		+++ "fn void Loud.greet(&self) @dynamic {}\n";

	DocumentList* ds = mem::new(DocumentList);
	defer mem::free(ds);
	ds.open("file:///proj/src/f.c3", src, 1);

	DString out = dstring::temp();
	encode_implementation("file:///proj/src/f.c3", src, offset_of(src, "greet"), ds, "", &out);
	String r = out.str_view();

	assert(!r.contains(`"line":2`), "body-less-of-@dynamic must not attach to the previous fn, got: %s", r);
	assert(r.contains(`"line":3`), "the @dynamic body must be reported, got: %s", r);

	ds.close("file:///proj/src/f.c3");
}

// --- same-named interfaces in unrelated modules ---

// Two modules may each declare a `Greeter`. Matching is by name, so without a
// visibility filter the other module's implementors get pooled in with ours -- the
// real-world case being `vk::Allocator` collecting every std::core::mem allocator.
fn void test_implementation_excludes_same_named_interface_in_unrelated_module() @test {
	DocumentList* ds = mem::new(DocumentList);
	defer mem::free(ds);

	// Unrelated module, its own Greeter, its own implementor.
	ds.open("file:///proj/src/other.c3",
		"module other;\ninterface Greeter { fn void greet(); }\nstruct Stranger (Greeter) {}\n", 1);

	String src = "module app;\n"
		+++ "interface Greeter { fn void greet(); }\n"
		+++ "struct Loud (Greeter) {}\n";
	ds.open("file:///proj/src/a2.c3", src, 1);

	DString out = dstring::temp();
	encode_implementation("file:///proj/src/a2.c3", src, offset_of(src, "Greeter"), ds, "", &out);
	String r = out.str_view();

	assert(r.contains("a2.c3"), "our own implementor must be reported, got: %s", r);
	assert(!r.contains("other.c3"), "another module's Greeter must not contribute, got: %s", r);

	ds.close("file:///proj/src/a2.c3");
	ds.close("file:///proj/src/other.c3");
}

// A type that imports the interface's module is visible to it, so it stays in.
fn void test_implementation_keeps_implementor_that_imports_the_module() @test {
	DocumentList* ds = mem::new(DocumentList);
	defer mem::free(ds);

	ds.open("file:///proj/src/client.c3",
		"module client;\nimport app;\nstruct Polite (Greeter) {}\n", 1);

	String src = "module app;\ninterface Greeter { fn void greet(); }\n";
	ds.open("file:///proj/src/a3.c3", src, 1);

	DString out = dstring::temp();
	encode_implementation("file:///proj/src/a3.c3", src, offset_of(src, "Greeter"), ds, "", &out);
	assert(out.str_view().contains("client.c3"),
		"an importing module implements the same interface, got: %s", out.str_view());

	ds.close("file:///proj/src/a3.c3");
	ds.close("file:///proj/src/client.c3");
}

// The filter must never be able to empty a non-empty answer: when nothing can be
// proven visible, every hit is reported instead of none.
fn void test_implementation_falls_back_when_no_hit_is_provably_visible() @test {
	DocumentList* ds = mem::new(DocumentList);
	defer mem::free(ds);

	// Neither declares Greeter nor imports app, so visibility cannot be established.
	ds.open("file:///proj/src/far.c3", "module far;\nstruct Stranger (Greeter) {}\n", 1);

	String src = "module app;\ninterface Greeter { fn void greet(); }\n";
	ds.open("file:///proj/src/a4.c3", src, 1);

	DString out = dstring::temp();
	encode_implementation("file:///proj/src/a4.c3", src, offset_of(src, "Greeter"), ds, "", &out);
	assert(out.str_view().contains("far.c3"),
		"an unprovable hit beats reporting nothing, got: %s", out.str_view());

	ds.close("file:///proj/src/a4.c3");
	ds.close("file:///proj/src/far.c3");
}

// std::core is visible from every file, so plain visibility cannot tell a std
// interface's own implementors from a user type that reuses the name. The stronger tie
// has to win, or `Allocator` in std pulls in `struct MyBuf (Allocator)` from any project.
fn void test_implementation_prefers_direct_visibility_over_implicit_std_core() @test {
	DocumentList* ds = mem::new(DocumentList);
	defer mem::free(ds);

	// Sees std::core implicitly, but has nothing to do with std's Allocator.
	ds.open("file:///proj/src/user.c3", "module app;\nstruct MyBuf (Allocator) {}\n", 1);

	String src = "module std::core::mem::allocator;\n"
		+++ "interface Allocator { fn void* acquire(); }\n"
		+++ "struct Arena (Allocator) {}\n";
	ds.open("file:///proj/src/std_alloc.c3", src, 1);

	DString out = dstring::temp();
	encode_implementation("file:///proj/src/std_alloc.c3", src, offset_of(src, "Allocator"), ds, "", &out);
	String r = out.str_view();

	assert(r.contains("std_alloc.c3"), "std's own implementor must be reported, got: %s", r);
	assert(!r.contains("user.c3"), "implicit std::core visibility must lose to a direct tie, got: %s", r);

	ds.close("file:///proj/src/std_alloc.c3");
	ds.close("file:///proj/src/user.c3");
}

fn void test_implementation_capability_is_advertised() @test {
	DString out = dstring::temp();
	encode_server_capabilities(&out, "0.0.0");
	assert(out.str_view().contains(`"implementationProvider":true`),
		"capability must be advertised or clients never send the request, got: %s", out.str_view());
}
