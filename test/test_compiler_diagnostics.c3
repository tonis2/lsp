module lsp;

import std::core::dstring;

fn void test_uri_to_path_file_uri() @test {
	assert(uri_to_path("file:///home/user/test.c3") == "/home/user/test.c3");
}

fn void test_uri_to_path_triple_slash() @test {
	assert(uri_to_path("file:///tmp/foo.c3") == "/tmp/foo.c3");
}

fn void test_uri_to_path_not_file_uri() @test {
	assert(uri_to_path("http://example.com") == "");
}

fn void test_uri_to_path_empty() @test {
	assert(uri_to_path("") == "");
}

fn void test_uri_to_path_windows_drive() @test {
	assert(uri_to_path("file:///C:/Users/test/foo.c3") == "C:/Users/test/foo.c3");
}

fn void test_uri_to_path_windows_lowercase_drive() @test {
	assert(uri_to_path("file:///d:/projects/bar.c3") == "d:/projects/bar.c3");
}

fn void test_uri_to_path_unix_unchanged() @test {
	// Ensure Unix paths are not affected by the drive-letter check
	assert(uri_to_path("file:///home/user/test.c3") == "/home/user/test.c3");
}

fn void test_path_matches_uri_backslash() @test {
	// Windows compiler output uses backslashes, URI uses forward slashes
	assert(path_matches_uri(`C:\Users\test\foo.c3`, "file:///C:/Users/test/foo.c3"));
}

fn void test_path_matches_uri_unix_unchanged() @test {
	assert(path_matches_uri("/home/user/test.c3", "file:///home/user/test.c3"));
}

fn void test_append_file_uri_windows() @test {
	DString d = dstring::temp();
	append_file_uri(&d, "C:/Users/test/foo.c3");
	assert(d.str_view() == "file:///C:/Users/test/foo.c3");
}

fn void test_append_file_uri_unix() @test {
	DString d = dstring::temp();
	append_file_uri(&d, "/home/user/foo.c3");
	assert(d.str_view() == "file:///home/user/foo.c3");
}

fn void test_uri_to_path_percent_decode_space() @test {
	assert(uri_to_path("file:///C:/My%20Documents/foo.c3") == "C:/My Documents/foo.c3");
}

fn void test_uri_to_path_percent_decode_hash() @test {
	assert(uri_to_path("file:///home/user/project%23v2/foo.c3") == "/home/user/project#v2/foo.c3");
}

fn void test_uri_to_path_percent_encoded_colon() @test {
	// VS Code on Windows encodes the drive colon as %3A
	assert(uri_to_path("file:///c%3A/Users/tonis/foo.c3") == "c:/Users/tonis/foo.c3");
}

fn void test_uri_to_path_no_percent_passthrough() @test {
	// No percent sequences — should return as-is
	assert(uri_to_path("file:///C:/Users/test/foo.c3") == "C:/Users/test/foo.c3");
}

fn void test_append_file_uri_percent_encode_space() @test {
	DString d = dstring::temp();
	append_file_uri(&d, "C:/My Documents/foo.c3");
	assert(d.str_view() == "file:///C:/My%20Documents/foo.c3");
}

fn void test_parent_dir_windows_drive_root() @test {
	assert(parent_dir("C:/Users") == "C:/");
}

fn void test_parent_dir_windows_nested() @test {
	assert(parent_dir("C:/Users/test/project") == "C:/Users/test");
}

fn void test_parent_dir_unix_unchanged() @test {
	assert(parent_dir("/home/user/project") == "/home/user");
}

// --- resolve_compiler_path ---

fn void test_compiler_path_absolute_unix() @test {
	assert(resolve_compiler_path("/home/user/project/src/foo.c3", "/home/user/project") == "/home/user/project/src/foo.c3");
}

fn void test_compiler_path_relative_joined() @test {
	assert(resolve_compiler_path("src/foo.c3", "/home/user/project") == "/home/user/project/src/foo.c3");
}

fn void test_compiler_path_windows_backslash() @test {
	assert(resolve_compiler_path(`C:\Users\test\foo.c3`, `C:\Users\test`) == "C:/Users/test/foo.c3");
}

fn void test_compiler_path_relative_no_root() @test {
	// No project root: use the path as-is (standalone file fallback).
	assert(resolve_compiler_path("/tmp/foo.c3", "") == "/tmp/foo.c3");
}

// --- CompilerDiagList.parse ---

fn void test_parse_single_diagnostic() @test {
	CompilerDiagList diags;
	diags.tinit();
	String out = "> LSPERR|error|\"/proj/src/a.c3\"|3|5|\"undefined symbol\"\n";
	diags.parse(out, "/proj");
	assert(diags.len() == 1);
	assert(diags[0].file == "/proj/src/a.c3");
	assert(diags[0].line == 2); // 0-indexed
	assert(diags[0].col == 4);
	assert(diags[0].severity == 1);
	assert(diags[0].message == "undefined symbol");
}

fn void test_parse_groups_two_files() @test {
	// Two errors in two different files should yield two distinct URIs.
	CompilerDiagList diags;
	diags.tinit();
	String out = "LSPERR|error|\"/proj/a.c3\"|1|1|\"err a\"\nLSPERR|warning|\"/proj/b.c3\"|2|2|\"warn b\"\n";
	diags.parse(out, "/proj");
	assert(diags.len() == 2);
	assert(diags[0].file == "/proj/a.c3");
	assert(diags[1].file == "/proj/b.c3");
	assert(diags[1].severity == 2); // warning
}

fn void test_parse_relative_path() @test {
	CompilerDiagList diags;
	diags.tinit();
	String out = "LSPERR|error|\"src/x.c3\"|10|1|\"oops\"\n";
	diags.parse(out, "/home/u/proj");
	assert(diags.len() == 1);
	assert(diags[0].file == "/home/u/proj/src/x.c3");
}

fn void test_parse_ignores_non_lsperr() @test {
	CompilerDiagList diags;
	diags.tinit();
	String out = "Compiling...\nsome other output\n";
	diags.parse(out, "/proj");
	assert(diags.len() == 0);
}
