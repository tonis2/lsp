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

fn void test_implementation_capability_is_advertised() @test {
	DString out = dstring::temp();
	encode_server_capabilities(&out, "0.0.0");
	assert(out.str_view().contains(`"implementationProvider":true`),
		"capability must be advertised or clients never send the request, got: %s", out.str_view());
}
