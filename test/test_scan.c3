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

// --- search-dir normalization / overlap tests ---

fn void test_normalize_search_dir_root_spellings() @test {
	// "./" and "." and "/" all name the project root.
	assert(normalize_search_dir("./") == ".", "got: %s", normalize_search_dir("./"));
	assert(normalize_search_dir(".") == ".", "got: %s", normalize_search_dir("."));
	assert(normalize_search_dir("/") == ".", "got: %s", normalize_search_dir("/"));
}

fn void test_normalize_search_dir_strips_prefix_and_suffix() @test {
	assert(normalize_search_dir("./src") == "src", "got: %s", normalize_search_dir("./src"));
	assert(normalize_search_dir("src/") == "src", "got: %s", normalize_search_dir("src/"));
	assert(normalize_search_dir("./test/") == "test", "got: %s", normalize_search_dir("./test/"));
	assert(normalize_search_dir("lib") == "lib", "got: %s", normalize_search_dir("lib"));
}

fn void test_dir_covers_root_covers_all() @test {
	assert(dir_covers(".", "src"), "root must cover src");
	assert(dir_covers(".", "a/b/c"), "root must cover nested dirs");
}

fn void test_dir_covers_is_segment_aligned() @test {
	assert(dir_covers("src", "src/vendor"), "parent must cover child");
	assert(dir_covers("src", "src"), "dir must cover itself");
	assert(!dir_covers("src", "srclib"), "prefix match must be segment-aligned");
	assert(!dir_covers("src/vendor", "src"), "child must not cover parent");
}

fn void test_add_search_dir_drops_overlapping_entries() @test {
	ProjectDirs p;
	p.count = 0;
	p.add_search_dir("linux");
	p.add_search_dir("./test");
	// The root arrives last and subsumes both of the above.
	p.add_search_dir("./");
	assert(p.count == 1, "root must collapse the list, got count=%d", p.count);
	assert(p.dirs[0] == ".", "got: %s", p.dirs[0]);

	// A narrower dir added afterwards is already reached, so it is not re-added.
	p.add_search_dir("darwin");
	assert(p.count == 1, "covered dir must not be added, got count=%d", p.count);
}

fn void test_add_search_dir_keeps_siblings() @test {
	ProjectDirs p;
	p.count = 0;
	p.add_search_dir("src");
	p.add_search_dir("lib");
	p.add_search_dir("test");
	p.add_search_dir("./src");  // same dir, different spelling
	assert(p.count == 3, "siblings must all be kept and spellings deduped, got count=%d", p.count);
}

// Count non-overlapping occurrences of `needle` in `haystack`.
fn int count_of(String haystack, String needle) @private
{
	int n = 0;
	sz i = 0;
	while (i + needle.len <= haystack.len)
	{
		if (haystack[i:needle.len] == needle)
		{
			n++;
			i += needle.len;
		}
		else
		{
			i++;
		}
	}
	return n;
}

// The regression this guards: a project.json that names the root two different ways
// (`dependency-search-paths: ["./"]` plus a root-level `sources` entry) used to be
// walked once per spelling, and again per nested source dir, so find-references
// reported every hit in those dirs three times.
fn void test_scan_project_dirs_visits_each_file_once() @test {
	mkdirs("/tmp/lsp_dupe_scan/linux");
	mkdirs("/tmp/lsp_dupe_scan/darwin");
	mkdirs("/tmp/lsp_dupe_scan/test");

	file::save("/tmp/lsp_dupe_scan/project.json",
		`{"dependency-search-paths":["./"],"sources":["darwin/**","linux/**","main.c3"],`
		+++ `"targets":{"test":{"sources":["./test/main.c3"]}}}`)!!;
	file::save("/tmp/lsp_dupe_scan/main.c3", "module dupe; fn void root_fn() {}")!!;
	file::save("/tmp/lsp_dupe_scan/linux/unified.c3", "module dupe; fn void linux_fn() {}")!!;
	file::save("/tmp/lsp_dupe_scan/darwin/objc.c3", "module dupe; fn void darwin_fn() {}")!!;
	file::save("/tmp/lsp_dupe_scan/test/main.c3", "module dupe; fn void test_fn() {}")!!;
	defer {
		if (catch file::delete("/tmp/lsp_dupe_scan/project.json")) {}
		if (catch file::delete("/tmp/lsp_dupe_scan/main.c3")) {}
		if (catch file::delete("/tmp/lsp_dupe_scan/linux/unified.c3")) {}
		if (catch file::delete("/tmp/lsp_dupe_scan/darwin/objc.c3")) {}
		if (catch file::delete("/tmp/lsp_dupe_scan/test/main.c3")) {}
	}

	DString out = dstring::temp();
	ScanPathCollector collector = { &out };
	scan_project_dirs("/tmp/lsp_dupe_scan/main.c3", &collector);

	String r = out.str_view();
	assert(count_of(r, "linux/unified.c3") == 1, "visited %d times: %s", count_of(r, "linux/unified.c3"), r);
	assert(count_of(r, "darwin/objc.c3") == 1, "visited %d times: %s", count_of(r, "darwin/objc.c3"), r);
	assert(count_of(r, "/tmp/lsp_dupe_scan/main.c3") == 1, "visited %d times: %s", count_of(r, "/tmp/lsp_dupe_scan/main.c3"), r);
	assert(count_of(r, "test/main.c3") == 1, "visited %d times: %s", count_of(r, "test/main.c3"), r);
}

// A vendored library and the copy c3c unpacks under build/unpacked_c3l are the same
// archive, so only one of them may be scanned.
fn void test_scan_project_dirs_skips_unpacked_copy_of_vendored_lib() @test {
	mkdirs("/tmp/lsp_unpacked/lib/demo.c3l/src");
	mkdirs("/tmp/lsp_unpacked/build/unpacked_c3l/demo.c3l/src");
	mkdirs("/tmp/lsp_unpacked/build/unpacked_c3l/fetched.c3l/src");
	mkdirs("/tmp/lsp_unpacked/src");

	file::save("/tmp/lsp_unpacked/project.json",
		`{"dependency-search-paths":["lib"],"sources":["src/**"]}`)!!;
	file::save("/tmp/lsp_unpacked/src/app.c3", "module app; fn void app_fn() {}")!!;
	file::save("/tmp/lsp_unpacked/lib/demo.c3l/manifest.json", `{"sources":["src/**"]}`)!!;
	file::save("/tmp/lsp_unpacked/lib/demo.c3l/src/demo.c3", "module demo; fn void demo_fn() {}")!!;
	file::save("/tmp/lsp_unpacked/build/unpacked_c3l/demo.c3l/manifest.json", `{"sources":["src/**"]}`)!!;
	file::save("/tmp/lsp_unpacked/build/unpacked_c3l/demo.c3l/src/demo.c3", "module demo; fn void demo_fn() {}")!!;
	file::save("/tmp/lsp_unpacked/build/unpacked_c3l/fetched.c3l/manifest.json", `{"sources":["src/**"]}`)!!;
	file::save("/tmp/lsp_unpacked/build/unpacked_c3l/fetched.c3l/src/fetched.c3", "module fetched; fn void fetched_fn() {}")!!;
	defer {
		if (catch file::delete("/tmp/lsp_unpacked/project.json")) {}
		if (catch file::delete("/tmp/lsp_unpacked/src/app.c3")) {}
		if (catch file::delete("/tmp/lsp_unpacked/lib/demo.c3l/manifest.json")) {}
		if (catch file::delete("/tmp/lsp_unpacked/lib/demo.c3l/src/demo.c3")) {}
		if (catch file::delete("/tmp/lsp_unpacked/build/unpacked_c3l/demo.c3l/manifest.json")) {}
		if (catch file::delete("/tmp/lsp_unpacked/build/unpacked_c3l/demo.c3l/src/demo.c3")) {}
		if (catch file::delete("/tmp/lsp_unpacked/build/unpacked_c3l/fetched.c3l/manifest.json")) {}
		if (catch file::delete("/tmp/lsp_unpacked/build/unpacked_c3l/fetched.c3l/src/fetched.c3")) {}
	}

	DString out = dstring::temp();
	ScanPathCollector collector = { &out };
	scan_project_dirs("/tmp/lsp_unpacked/src/app.c3", &collector);

	String r = out.str_view();
	assert(count_of(r, "demo.c3l/src/demo.c3") == 1, "vendored lib scanned %d times: %s", count_of(r, "demo.c3l/src/demo.c3"), r);
	assert(!r.contains("unpacked_c3l/demo.c3l"), "unpacked copy of a vendored lib must be skipped, got: %s", r);
	assert(r.contains("unpacked_c3l/fetched.c3l/src/fetched.c3"), "a lib only present unpacked must still be scanned, got: %s", r);
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

// Many libraries declare no top-level "sources", only one list per platform target.
// All of them are read — the platform being edited is not necessarily the host — and
// directories outside them (test/) stay excluded instead of falling back to a full walk.
fn void test_scan_c3l_reads_per_target_manifest_sources() @test {
	String lib = "/tmp/lsp_scan_targets/plat.c3l";
	mkdirs("/tmp/lsp_scan_targets/plat.c3l/linux");
	mkdirs("/tmp/lsp_scan_targets/plat.c3l/win32");
	mkdirs("/tmp/lsp_scan_targets/plat.c3l/test");

	file::save("/tmp/lsp_scan_targets/plat.c3l/manifest.json",
		`{"provides":"plat","targets":{`
		+++ `"linux-x64":{"sources":["linux/unified.c3"]},`
		+++ `"windows-x64":{"sources":["win32/main.c3"]}}}`)!!;
	file::save("/tmp/lsp_scan_targets/plat.c3l/main.c3", "module plat; fn void plat_root() {}")!!;
	file::save("/tmp/lsp_scan_targets/plat.c3l/linux/unified.c3", "module plat; fn void plat_linux() {}")!!;
	file::save("/tmp/lsp_scan_targets/plat.c3l/win32/main.c3", "module plat; fn void plat_win() {}")!!;
	file::save("/tmp/lsp_scan_targets/plat.c3l/test/harness.c3", "module plat; fn void plat_test() {}")!!;
	defer {
		if (catch file::delete("/tmp/lsp_scan_targets/plat.c3l/manifest.json")) {}
		if (catch file::delete("/tmp/lsp_scan_targets/plat.c3l/main.c3")) {}
		if (catch file::delete("/tmp/lsp_scan_targets/plat.c3l/linux/unified.c3")) {}
		if (catch file::delete("/tmp/lsp_scan_targets/plat.c3l/win32/main.c3")) {}
		if (catch file::delete("/tmp/lsp_scan_targets/plat.c3l/test/harness.c3")) {}
	}

	DString out = dstring::temp();
	ScanPathCollector collector = { &out };
	scan_dir(lib, &collector);

	String r = out.str_view();
	assert(count_of(r, "linux/unified.c3") == 1, "linux target source visited %d times: %s", count_of(r, "linux/unified.c3"), r);
	assert(count_of(r, "win32/main.c3") == 1, "windows target source visited %d times: %s", count_of(r, "win32/main.c3"), r);
	assert(!r.contains("test/harness.c3"), "test dir is not a declared source, got: %s", r);
	assert(!r.contains("plat.c3l/main.c3"), "root file is not a declared source here, got: %s", r);
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
