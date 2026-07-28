module lsp;

// A file the lexer accepts produces no diagnostic elements at all.
fn void test_lex_elements_clean_file() @test {
	assert(lex_diagnostic_elements("fn void foo() {}").len == 0);
}

// A byte the lexer rejects produces one diagnostic element.
fn void test_lex_elements_invalid_char() @test {
	String els = lex_diagnostic_elements("fn void foo() { \x01 }");
	assert(els.len > 0, "an invalid byte must produce a diagnostic");
	assert(els.contains("Invalid character"));
}

// The merged array is what goes on the wire, so it has to stay valid JSON for every
// combination of present and absent halves.
fn void test_merge_elements_both_halves() @test {
	assert(merge_diag_elements(`{"lex":1}`, `{"c":1}`) == `[{"lex":1},{"c":1}]`);
}

fn void test_merge_elements_lex_only() @test {
	assert(merge_diag_elements(`{"lex":1}`, "") == `[{"lex":1}]`);
}

fn void test_merge_elements_compiler_only() @test {
	assert(merge_diag_elements("", `{"c":1}`) == `[{"c":1}]`);
}

// An empty array is the notification that clears a file's markers.
fn void test_merge_elements_empty() @test {
	assert(merge_diag_elements("", "") == "[]");
}

// The lexer and the compiler publish to the same per-URI channel, and every publish
// replaces the whole set, so the two have to be merged rather than overwrite each other.
fn void test_merge_keeps_both_producers() @test {
	LspServer s;
	s.init("", "c3c", 0);
	defer s.handle_exit();

	String uri = "file:///a.c3";
	s.set_diagnostics(uri, `{"compiler":1}`, COMPILER);
	s.set_diagnostics(uri, `{"lex":1}`, LEXER);

	sz i = s.diag_index(uri);
	assert(i < s.diag_state.size, "the file must be tracked");
	assert(s.diag_state.entries[i].compiler == `{"compiler":1}`, "a lexer publish must not erase compiler errors");
	assert(s.diag_state.entries[i].lex == `{"lex":1}`);
}

// Clearing one producer's half leaves the other's markers in place.
fn void test_clearing_lex_half_keeps_compiler_half() @test {
	LspServer s;
	s.init("", "c3c", 0);
	defer s.handle_exit();

	String uri = "file:///a.c3";
	s.set_diagnostics(uri, `{"compiler":1}`, COMPILER);
	s.set_diagnostics(uri, `{"lex":1}`, LEXER);
	s.set_diagnostics(uri, "", LEXER);

	sz i = s.diag_index(uri);
	assert(i < s.diag_state.size, "compiler errors must still be tracked");
	assert(s.diag_state.entries[i].lex.len == 0);
	assert(s.diag_state.entries[i].compiler == `{"compiler":1}`);
}

// The regression: a lexer diagnostic that goes away has to be published as an empty
// array, since that is the only thing that removes the marker from the editor. The file
// dropping out of the tracked state is that publish having happened.
fn void test_lex_diagnostic_cleared_when_fixed() @test {
	LspServer s;
	s.init("", "c3c", 0);
	defer s.handle_exit();

	String uri = "file:///a.c3";
	s.publish_lex_diagnostics(uri, "fn void foo() { \x01 }");
	assert(s.diag_index(uri) < s.diag_state.size, "the invalid byte must be published");

	s.publish_lex_diagnostics(uri, "fn void foo() {}");
	assert(s.diag_index(uri) == s.diag_state.size, "fixing the invalid byte must clear the marker");
}

// A file that never had anything published stays silent — the client already shows no
// markers for it, so an empty publish would be pure noise.
fn void test_clean_file_never_published() @test {
	LspServer s;
	s.init("", "c3c", 0);
	defer s.handle_exit();

	s.publish_lex_diagnostics("file:///clean.c3", "fn void foo() {}");
	assert(s.diag_state.size == 0, "a clean file must not be tracked");
}

// A build that no longer reports a file clears that file's compiler half, but must not
// take the lexer's markers with it.
fn void test_clean_build_clears_only_compiler_half() @test {
	LspServer s;
	s.init("", "c3c", 0);
	defer s.handle_exit();

	String uri = "file:///a.c3";
	s.set_diagnostics(uri, `{"lex":1}`, LEXER);
	s.set_diagnostics(uri, `{"compiler":1}`, COMPILER);

	// A build that reported nothing.
	CompilerDiagList diags;
	diags.tinit();
	s.publish_grouped_diagnostics(&diags);

	sz i = s.diag_index(uri);
	assert(i < s.diag_state.size, "the lexer marker must survive a clean build");
	assert(s.diag_state.entries[i].compiler.len == 0, "the compiler half must be cleared");
	assert(s.diag_state.entries[i].lex == `{"lex":1}`);
}

// With no lexer markers to keep, a file that a build stops reporting is dropped entirely.
fn void test_clean_build_drops_file_with_no_lex_markers() @test {
	LspServer s;
	s.init("", "c3c", 0);
	defer s.handle_exit();

	String uri = "file:///a.c3";
	s.set_diagnostics(uri, `{"compiler":1}`, COMPILER);

	CompilerDiagList diags;
	diags.tinit();
	s.publish_grouped_diagnostics(&diags);

	assert(s.diag_state.size == 0, "a file with nothing left must stop being tracked");
}
