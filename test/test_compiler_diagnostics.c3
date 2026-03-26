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
