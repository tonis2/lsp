module lsp;

import std::core::dstring;
import std::time;

// Small files publish lexer diagnostics immediately — never deferred.
fn void test_lex_diag_small_file_immediate() @test {
	LspServer s;
	s.init("", "c3c", 2000);
	defer s.handle_exit();

	s.maybe_publish_lex_diagnostics("file:///small.c3", "fn void foo() {}");
	assert(!s.lex_diag_pending, "small files must not defer diagnostics");
}

// Large files debounce: the first change runs on the leading edge, a rapid second
// change within the window is deferred (to be flushed later).
fn void test_lex_diag_large_file_debounced() @test {
	LspServer s;
	s.init("", "c3c", 2000);
	defer s.handle_exit();

	// Build > LARGE_FILE_BYTES of valid C3 (no invalid chars → no notification sent).
	DString big = dstring::temp();
	while (big.str_view().len <= LARGE_FILE_BYTES) {
		big.append("fn void foo() {}\n");
	}
	String content = big.str_view();
	String uri = "file:///big.c3";

	// Leading edge (last_lex_diag_time == 0): runs now, nothing pending.
	s.maybe_publish_lex_diagnostics(uri, content);
	assert(!s.lex_diag_pending, "leading-edge run should not leave work pending");

	// Immediate second change within the window: deferred to the trailing edge.
	s.maybe_publish_lex_diagnostics(uri, content);
	assert(s.lex_diag_pending, "rapid second change on a large file must defer");
	assert(s.lex_diag_pending_uri == uri, "deferred uri must be recorded");
}

// A didOpen inside the throttle window defers, but the following save must build right
// away and drop the deferred run — otherwise the fix only lands when the next message
// happens to arrive, leaving errors the user already fixed on screen.
fn void test_save_bypasses_throttle() @test {
	LspServer s;
	s.init("", "c3c", 60_000);
	defer s.handle_exit();

	// Pretend a build just finished, so the next request lands inside the window.
	s.last_diag_time = time::now();
	s.maybe_run_compiler_diagnostics("file:///a.c3");
	assert(s.diag_pending, "an open inside the throttle window must defer");

	// The empty URI resolves to no path, so the build returns before spawning c3c —
	// what matters here is that the throttle no longer gates the run.
	s.run_compiler_diagnostics_now("");
	assert(!s.diag_pending, "a save must build now and supersede the deferred run");
}
