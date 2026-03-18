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
