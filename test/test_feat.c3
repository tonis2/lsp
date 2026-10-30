module lsp;

import std::core::dstring;
import std::core::mem;

// --- decl_feat ---

fn String feat_of(String src, String name)
{
	TokenList toks;
	toks.tinit();
	toks.tokenize(src);
	foreach (i, t : toks)
	{
		if (t.text == name) return toks.decl_feat(i);
	}
	return "<missing>";
}

fn void test_decl_feat_function() @test {
	assert(feat_of("fn CInt? Process.join(&self) @feat(POSIX) { }", "join") == "@feat(POSIX)");
	assert(feat_of("fn void f(int a = $feat(X)) @inline { }", "f") == "", "params and other attributes don't count");
}

fn void test_decl_feat_type_and_alias() @test {
	assert(feat_of("struct Fpos_t @feat(!WIN32) { int x; }", "Fpos_t") == "@feat(!WIN32)");
	assert(feat_of("alias WChar @feat(WIN32) = Char16;", "WChar") == "@feat(WIN32)");
	assert(feat_of("const int MAX @feat(LINUX, ANDROID) = 4;", "MAX") == "@feat(LINUX, ANDROID)");
	assert(feat_of("alias Plain = int;", "Plain") == "");
}

fn void test_decl_feat_module_section() @test {
	String src = "module libc @feat(LIBC);\nfn void close() @feat(!WIN32) {}\nmodule other;\nfn void open() {}";
	assert(feat_of(src, "close") == "@feat(!WIN32) @feat(LIBC)", "got %s", feat_of(src, "close"));
	assert(feat_of(src, "open") == "", "a later module section without @feat resets it");
}

// --- go-to-definition returns every variant ---

fn void test_definition_returns_all_feat_variants() @test {
	DString out = dstring::temp();
	DocumentList* ds = mem::new(DocumentList);
	defer mem::free(ds);
	String content = "fn int errno() @feat(LINUX) { return 1; }\n"
		"fn int errno() @feat(DARWIN) { return 2; }\n"
		"fn void main() { errno(); }";
	sz offset = content.index_of("errno();")!!;
	encode_definition("file:///p/os.c3", content, offset, ds, "", &out);
	String result = out.str_view();
	assert(result.starts_with("["), "several variants are an array, got: %s", result);
	assert(result.contains(`"start":{"line":0,"character":7}`) && result.contains(`"start":{"line":1,"character":7}`), "got: %s", result);
}

// Standing on one variant offers the others too, so you can hop between platforms.
fn void test_definition_on_variant_lists_all() @test {
	DString out = dstring::temp();
	DocumentList* ds = mem::new(DocumentList);
	defer mem::free(ds);
	String content = "alias WChar @feat(WIN32) = Char16;\nalias WChar @feat(!WIN32) = Char32;\n";
	encode_definition("file:///p/libc.c3", content, 6, ds, "", &out);
	String result = out.str_view();
	assert(result.starts_with("[") && result.contains(`"line":1`), "got: %s", result);
}

// Variants spread over files (os/linux.c3, os/darwin.c3) are all found.
fn void test_definition_feat_variants_across_open_docs() @test {
	DString out = dstring::temp();
	DocumentList docs;
	docs.init(mem);
	defer { while (docs.size > 0) docs.close(docs.entries[0].uri); docs.free(); }
	docs.open("file:///p/linux.c3", "module os;\nfn int stat() @feat(LINUX) { return 0; }\n", 1);
	docs.open("file:///p/darwin.c3", "module os;\nfn int stat() @feat(DARWIN) { return 0; }\n", 1);
	String content = "module os;\nfn void main() { stat(); }";
	docs.open("file:///p/main.c3", content, 1);
	encode_definition("file:///p/main.c3", content, content.index_of("stat")!!, &docs, "", &out);
	String result = out.str_view();
	assert(result.starts_with("["), "got: %s", result);
	assert(result.index_of("file:///p/darwin.c3")!! < result.index_of("file:///p/linux.c3")!!, "sorted by file, got: %s", result);
}

// An ungated declaration is a single answer, exactly as before.
fn void test_definition_ungated_stays_single() @test {
	DString out = dstring::temp();
	DocumentList* ds = mem::new(DocumentList);
	defer mem::free(ds);
	String content = "fn void hello() {}\nhello();";
	encode_definition("file:///test.c3", content, 19, ds, "", &out);
	assert(out.str_view().starts_with("{"), "got: %s", out.str_view());
}

// Hover on a gated declaration lists every variant with its conditions.
fn void test_hover_lists_feat_variants() @test {
	DString out = dstring::temp();
	DocumentList* ds = mem::new(DocumentList);
	defer mem::free(ds);
	String content = "fn int errno() @feat(LINUX) { return 1; }\n"
		"fn int errno() @feat(DARWIN) { return 2; }\n"
		"fn void main() { errno(); }";
	encode_hover("file:///p/os.c3", content, content.index_of("errno();")!!, ds, "", &out);
	String result = out.str_view();
	assert(result.contains("**Variants**"), "got: %s", result);
	assert(result.contains("`@feat(LINUX)` — [os.c3:1](file:///p/os.c3#L1)"), "got: %s", result);
	assert(result.contains("`@feat(DARWIN)` — [os.c3:2](file:///p/os.c3#L2)"), "got: %s", result);
}

// An ordinary declaration gets no variants section.
fn void test_hover_ungated_has_no_variants() @test {
	DString out = dstring::temp();
	DocumentList* ds = mem::new(DocumentList);
	defer mem::free(ds);
	String content = "fn int hello() { return 1; }\nfn void main() { hello(); }";
	encode_hover("file:///p/a.c3", content, content.index_of("hello();")!!, ds, "", &out);
	assert(!out.str_view().contains("Variants"), "got: %s", out.str_view());
}

// A cast before a receiver applies to the whole member chain, not the receiver.
fn void test_definition_receiver_after_cast() @test {
	DString out = dstring::temp();
	DocumentList* ds = mem::new(DocumentList);
	defer mem::free(ds);
	String content = "struct Proc { int x; }\nfn int Proc.other(&self) { return 1; }\nfn void main() { Proc p; (void)p.other(); }";
	encode_definition("file:///p/a.c3", content, content.index_of("other();")!!, ds, "", &out);
	assert(out.str_view().contains(`"start":{"line":1,"character":12}`), "got: %s", out.str_view());
}

// Document symbols carry the conditions as their detail, so the outline tells the
// variants apart.
fn void test_document_symbols_feat_detail() @test {
	DString out = dstring::temp();
	String content = "module libc @feat(LIBC);\nfn void close() @feat(!WIN32) {}\nstruct Stat @feat(DARWIN) { int x; }\nfn void open() {}";
	TokenStream stream = token_stream_tokenize(content);
	defer stream.free();
	encode_document_symbols(content, &out, &stream);
	String result = out.str_view();
	assert(result.contains(`"name":"close","detail":"@feat(!WIN32) @feat(LIBC)"`), "got: %s", result);
	assert(result.contains(`"name":"Stat","detail":"@feat(DARWIN) @feat(LIBC)"`), "got: %s", result);
	assert(result.contains(`"name":"open","detail":"@feat(LIBC)"`), "the module section's condition applies, got: %s", result);
}
