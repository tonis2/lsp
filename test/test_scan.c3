module lsp;

import std::core::mem;
import std::core::dstring;
import std::io::file;
import std::io::path;

// --- source_entry_dir tests ---

fn void test_source_entry_dir_glob() @test {
	assert(source_entry_dir("src/**") == "src", "got: %s", source_entry_dir("src/**"));
	assert(source_entry_dir("./src/*") == "./src", "got: %s", source_entry_dir("./src/*"));
	assert(source_entry_dir("vk/**") == "vk", "got: %s", source_entry_dir("vk/**"));
}

fn void test_source_entry_dir_plain_dir() @test {
	assert(source_entry_dir("src") == "src", "got: %s", source_entry_dir("src"));
}

fn void test_source_entry_dir_single_file() @test {
	assert(source_entry_dir("./helpers/context.c3") == "./helpers", "got: %s", source_entry_dir("./helpers/context.c3"));
}

fn void test_source_entry_dir_root_file() @test {
	// A file with no directory component lives in the project root.
	assert(source_entry_dir("main.c3") == ".", "got: %s", source_entry_dir("main.c3"));
}

fn void test_source_entry_dir_empty() @test {
	assert(source_entry_dir("") == "", "got: %s", source_entry_dir(""));
}

// --- .c3l manifest scanning tests ---

// Records every file the scan engine visits, so a test can assert on coverage.
struct ScanPathCollector (FileVisitor) @private
{
	DString* out;
}

fn bool ScanPathCollector.visit(&self, String path, String content, TokenStream* stream) @dynamic
{
	self.out.append(path);
	self.out.append_char(';');
	return false; // collect-all: never stop early
}

fn void mkdirs(String dir) @private
{
	if (try p = path::tnew(dir)) { if (catch path::mkdir(p, true)) {} }
}

// A .c3l library declares its compilation unit in manifest.json. Directories
// outside that list (examples/, test/, build/, vendored libs/) are shipped in the
// archive but never compiled, so symbols there must not surface as project symbols.
fn void test_scan_c3l_respects_manifest_sources() @test {
	String lib = "/tmp/lsp_scan_manifest/demo.c3l";
	mkdirs("/tmp/lsp_scan_manifest/demo.c3l/src");
	mkdirs("/tmp/lsp_scan_manifest/demo.c3l/examples");

	file::save("/tmp/lsp_scan_manifest/demo.c3l/manifest.json", `{"provides":"demo","sources":["src/**"]}`)!!;
	file::save("/tmp/lsp_scan_manifest/demo.c3l/src/real.c3", "fn void demo_thing() {}")!!;
	file::save("/tmp/lsp_scan_manifest/demo.c3l/examples/sample.c3", "fn void demo_thing() {}")!!;
	defer {
		if (catch file::delete("/tmp/lsp_scan_manifest/demo.c3l/manifest.json")) {}
		if (catch file::delete("/tmp/lsp_scan_manifest/demo.c3l/src/real.c3")) {}
		if (catch file::delete("/tmp/lsp_scan_manifest/demo.c3l/examples/sample.c3")) {}
	}

	DString out = dstring::temp();
	ScanPathCollector collector = { &out };
	scan_dir(lib, &collector);

	String r = out.str_view();
	assert(r.contains("src/real.c3"), "manifest source dir must be scanned, got: %s", r);
	assert(!r.contains("examples/sample.c3"), "dir outside manifest sources must be skipped, got: %s", r);
}

// Without a readable manifest there is nothing to narrow the scan to, so the
// whole directory is walked as before.
fn void test_scan_c3l_without_manifest_walks_everything() @test {
	String lib = "/tmp/lsp_scan_nomanifest/plain.c3l";
	mkdirs("/tmp/lsp_scan_nomanifest/plain.c3l/examples");

	file::save("/tmp/lsp_scan_nomanifest/plain.c3l/examples/sample.c3", "fn void plain_thing() {}")!!;
	defer { if (catch file::delete("/tmp/lsp_scan_nomanifest/plain.c3l/examples/sample.c3")) {} }

	DString out = dstring::temp();
	ScanPathCollector collector = { &out };
	scan_dir(lib, &collector);

	assert(out.str_view().contains("examples/sample.c3"), "no manifest must fall back to a full walk, got: %s", out.str_view());
}

// A manifest naming several source dirs must have all of them scanned.
fn void test_scan_c3l_multiple_source_dirs() @test {
	String lib = "/tmp/lsp_scan_multi/multi.c3l";
	mkdirs("/tmp/lsp_scan_multi/multi.c3l/src");
	mkdirs("/tmp/lsp_scan_multi/multi.c3l/extra");
	mkdirs("/tmp/lsp_scan_multi/multi.c3l/test");

	file::save("/tmp/lsp_scan_multi/multi.c3l/manifest.json", `{"sources":["src/**","extra/**"]}`)!!;
	file::save("/tmp/lsp_scan_multi/multi.c3l/src/a.c3", "fn void multi_a() {}")!!;
	file::save("/tmp/lsp_scan_multi/multi.c3l/extra/b.c3", "fn void multi_b() {}")!!;
	file::save("/tmp/lsp_scan_multi/multi.c3l/test/c.c3", "fn void multi_c() {}")!!;
	defer {
		if (catch file::delete("/tmp/lsp_scan_multi/multi.c3l/manifest.json")) {}
		if (catch file::delete("/tmp/lsp_scan_multi/multi.c3l/src/a.c3")) {}
		if (catch file::delete("/tmp/lsp_scan_multi/multi.c3l/extra/b.c3")) {}
		if (catch file::delete("/tmp/lsp_scan_multi/multi.c3l/test/c.c3")) {}
	}

	DString out = dstring::temp();
	ScanPathCollector collector = { &out };
	scan_dir(lib, &collector);

	String r = out.str_view();
	assert(r.contains("src/a.c3"), "first source dir must be scanned, got: %s", r);
	assert(r.contains("extra/b.c3"), "second source dir must be scanned, got: %s", r);
	assert(!r.contains("test/c.c3"), "test dir is not a declared source, got: %s", r);
}
