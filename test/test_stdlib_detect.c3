module lsp;

import std::core::dstring;

// parse_installed_dir extracts the path from a realistic `c3c --version` block,
// trimming the run of spaces after the colon.
fn void test_parse_installed_dir_ok() @test {
	String sample = "C3 Compiler Version:       0.8.0_3\nInstalled directory:       /opt/c3\nBackends:                  LLVM\n";
	assert(parse_installed_dir(sample) == "/opt/c3", "got: '%s'", parse_installed_dir(sample));
}

// A trailing line with no newline is still parsed (end-of-string terminates it).
fn void test_parse_installed_dir_last_line() @test {
	String sample = "Installed directory:  /usr/local/c3c";
	assert(parse_installed_dir(sample) == "/usr/local/c3c", "got: '%s'", parse_installed_dir(sample));
}

// Output from a non-c3c binary (no marker line) yields "" without faulting.
fn void test_parse_installed_dir_missing() @test {
	assert(parse_installed_dir("this is not c3c output\n") == "", "expected empty");
	assert(parse_installed_dir("") == "", "expected empty");
}

// Crash-safety: a bogus compiler path must never fault — it just returns "".
fn void test_detect_stdlib_path_bad_compiler() @test {
	assert(detect_stdlib_path("/no/such/c3c-binary-xyz") == "", "bad compiler path should yield empty");
	assert(detect_stdlib_path("") == "", "empty compiler path should yield empty");
}
