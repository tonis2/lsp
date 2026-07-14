module lsp;

import std::core::mem;
import std::core::dstring;
import std::io::file;
import std::io::path;
import libc;

fn void test_file_cache_hit_and_invalidate() @test {
	FileCache fc;
	fc.init(mem);
	defer fc.free_all();

	String path = "/tmp/lsp_fc_test_one.c3";
	file::save(path, "fn void foo() {}")!!;
	file::set_modified_time(path, (libc::Time_t)1000)!!;
	defer { if (catch file::delete(path)) {} }

	// First lookup: loads + tokenizes.
	String c1;
	TokenStream* s1 = fc.stream_for(path, &c1)!!;
	assert(s1.tokens.size > 0, "stream should be populated");
	sz n1 = s1.tokens.size;

	// Second lookup, unchanged mtime: cache hit returns the same stream object.
	String c2;
	TokenStream* s2 = fc.stream_for(path, &c2)!!;
	assert(s1 == s2, "unchanged file must hit the cache (same stream pointer)");

	// Change content and bump mtime: the stale entry is rebuilt against new content.
	file::save(path, "fn void foo() {} fn void bar() {}")!!;
	file::set_modified_time(path, (libc::Time_t)2000)!!;
	String c3;
	TokenStream* s3 = fc.stream_for(path, &c3)!!;
	assert(c3 == "fn void foo() {} fn void bar() {}", "stale entry must reload new content");
	assert(s3.tokens.size > n1, "rebuilt stream should reflect the larger file");
}

// Exercise the integrated path: a scan_dir_* with the global cache active should
// produce correct results and populate the cache.
fn void test_file_cache_used_by_scan() @test {
	String dir = "/tmp/lsp_fc_scan_dir";
	if (try p = path::tnew(dir)) { if (catch path::mkdir(p, true)) {} }
	String f = "/tmp/lsp_fc_scan_dir/colors.c3";
	file::save(f, "enum Color { RED, GREEN }")!!;
	defer { if (catch file::delete(f)) {} }

	FileCache fc;
	fc.init(mem);
	g_file_cache = &fc;
	defer { g_file_cache = null; fc.free_all(); }

	DString out = dstring::temp();
	bool first = true;
	String[MAX_DOC_IDENTS] seen;
	sz seen_count = 0;
	MemberScan scan = { &TokenList.collect_enum_members_into, "Color", "", &out, &first, &seen, &seen_count, null };
	scan_dir(dir, &scan);

	String r = out.str_view();
	assert(r.contains(`"label":"RED"`), "expected RED from cached scan, got: %s", r);
	assert(fc.size > 0, "scan should have populated the file cache");
}

fn void test_file_cache_missing_file() @test {
	FileCache fc;
	fc.init(mem);
	defer fc.free_all();

	String c;
	assert(!@ok(fc.stream_for("/tmp/lsp_fc_does_not_exist_zzz.c3", &c)), "missing file must return FILE_UNREADABLE");
}
