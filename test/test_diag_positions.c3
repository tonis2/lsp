module lsp;

import std::core::dstring;

// --- diag_range: byte positions from c3c to UTF-16 ranges ---

// c3c counts bytes; LSP counts UTF-16 units. `ééé` is six bytes but three units, so
// without conversion the marker lands three characters to the right of the name.
fn void test_diag_range_converts_bytes_to_utf16() @test {
	String src = "module a;\n\tString s = \"ééé\"; int y = z;\n";
	LineOffsets lo;
	lo.tinit();
	lo.build(src);
	Range r = diag_range(src, &lo, 1, 30); // c3c's column for `z`
	assert(r.start.line == 1);
	assert(r.start.character == 27, "got %d", r.start.character);
	assert(r.end.character == 28, "got %d", r.end.character);
}

// The range covers the whole name at the reported column.
fn void test_diag_range_spans_name() @test {
	String src = "module a;\n    io::printn(\"x\");\n";
	LineOffsets lo;
	lo.tinit();
	lo.build(src);
	Range r = diag_range(src, &lo, 1, 4);
	assert(r.start.character == 4 && r.end.character == 14, "got %d-%d", r.start.character, r.end.character);
}

// c3c sometimes reports a column like 65532; it is clamped to the end of the line.
fn void test_diag_range_clamps_column_to_line() @test {
	String src = "module a;\nint x = \"abc\nfoo\n";
	LineOffsets lo;
	lo.tinit();
	lo.build(src);
	Range r = diag_range(src, &lo, 1, 65531);
	assert(r.start.line == 1);
	assert(r.start.character == 12, "got %d", r.start.character);
}

// A line past the end of the file lands on the last line rather than off-screen.
fn void test_diag_range_clamps_line() @test {
	String src = "module a;\nfn void f() {";
	LineOffsets lo;
	lo.tinit();
	lo.build(src);
	Range r = diag_range(src, &lo, 7, 0);
	assert(r.start.line == 1, "got %d", r.start.line);
}

// Unknown file text: keep the position c3c reported.
fn void test_diag_range_without_content() @test {
	LineOffsets lo;
	lo.tinit();
	lo.build("");
	Range r = diag_range("", &lo, 3, 5);
	assert(r.start.line == 3 && r.start.character == 5 && r.end.character == 6);
}

// The follow-up error c3c reports far past the end of the same line is dropped.
fn void test_encode_drops_cascade_past_line_end() @test {
	LspServer s;
	s.init("", "c3c", 0);
	defer s.handle_exit();

	String src = "module a;\nint x = \"abc\nfoo\n";
	CompilerDiag[2] diags = {
		{ .file = "/a.c3", .line = 1, .col = 8, .severity = 1, .message = "unterminated" },
		{ .file = "/a.c3", .line = 1, .col = 65531, .severity = 1, .message = "cascade" },
	};
	DString out = dstring::temp();
	s.encode_compiler_elements(src, &diags, &out);
	assert(out.str_view().contains("unterminated"));
	assert(!out.str_view().contains("cascade"), "got: %s", out.str_view());
}

// --- notes ---

// A note line belongs to the error before it and is not a diagnostic of its own.
fn void test_parse_attaches_note_to_previous_error() @test {
	CompilerDiagList diags;
	diags.tinit();
	String out = "> LSPERR|error|\"/p/a.c3\"|8|8|\"'Foo' would shadow a previous declaration.\"\n"
		"> LSPERR|note|\"/p/a.c3\"|7|8|\"The previous use of 'Foo' was here.\"\n";
	diags.parse(out, "/p");
	assert(diags.len() == 1, "got %d", diags.len());
	assert(diags[0].note_file == "/p/a.c3");
	assert(diags[0].note_line == 6 && diags[0].note_col == 7);
	assert(diags[0].note_message == "The previous use of 'Foo' was here.");
}

// With nothing before it to attach to, a note stays an informational diagnostic.
fn void test_parse_lone_note_stays_info() @test {
	CompilerDiagList diags;
	diags.tinit();
	diags.parse("LSPERR|note|\"/p/a.c3\"|1|1|\"n\"\n", "/p");
	assert(diags.len() == 1);
	assert(diags[0].severity == 3);
	assert(diags[0].note_file.len == 0);
}

fn void test_encode_note_as_related_information() @test {
	LspServer s;
	s.init("", "c3c", 0);
	defer s.handle_exit();

	String src = "module a;\nstruct Foo { int a; }\nstruct Foo { int b; }\n";
	CompilerDiag[1] diags = {
		{ .file = "/p/a.c3", .line = 2, .col = 7, .severity = 1, .message = "shadow",
		  .note_file = "/p/a.c3", .note_line = 1, .note_col = 7, .note_message = "previous" },
	};
	DString out = dstring::temp();
	s.encode_compiler_elements(src, &diags, &out);
	String json = out.str_view();
	assert(json.contains(`"relatedInformation":[{"location":{"uri":"file:///p/a.c3","range":{"start":{"line":1,"character":7},"end":{"line":1,"character":10}}},"message":"previous"}]`), "got: %s", json);
}

// --- shifting compiler markers with edits ---

fn void test_edit_span_insert_line_above() @test {
	EditSpan span;
	assert(edit_span("a\nERR\n", "a\nX\nERR\n", &span));
	assert(span.end_line == 1, "a whole inserted line edits nothing, got %d", span.end_line);
	assert(span.line_delta == 1);
}

fn void test_edit_span_typing_on_line() @test {
	EditSpan span;
	assert(edit_span("a\nERR\nb\n", "a\nERxR\nb\n", &span));
	assert(span.first_line == 1 && span.end_line == 2);
	assert(span.line_delta == 0);
}

fn void test_edit_span_enter_mid_line() @test {
	EditSpan span;
	assert(edit_span("ab\nERR\n", "a\nb\nERR\n", &span));
	assert(span.first_line == 0 && span.end_line == 1);
	assert(span.line_delta == 1);
}

fn void test_edit_span_identical() @test {
	EditSpan span;
	assert(!edit_span("abc", "abc", &span));
}

// Publish one compiler error on `line` of `src` for file:///p/a.c3.
fn void publish_one(LspServer* s, String src, int line, int col)
{
	CompilerDiag[1] diags = { { .file = "/p/a.c3", .line = line, .col = col, .severity = 1, .message = "boom" } };
	s.set_compiler_diagnostics("file:///p/a.c3", src, &diags);
}

fn CompilerDiag[] tracked(LspServer* s)
{
	sz i = s.diag_index("file:///p/a.c3");
	if (i == s.diag_state.size) return {};
	return s.diag_state.entries[i].cdiags;
}

fn void test_shift_moves_marker_down_with_inserted_lines() @test {
	LspServer s;
	s.init("", "c3c", 0);
	defer s.handle_exit();

	String old = "module a;\nfn void f()\n{\n\tint y = z;\n}\n";
	publish_one(&s, old, 3, 9);
	s.shift_compiler_diagnostics("file:///p/a.c3", old, "module a;\n\n\nfn void f()\n{\n\tint y = z;\n}\n");
	assert(tracked(&s).len == 1);
	assert(tracked(&s)[0].line == 5, "got %d", tracked(&s)[0].line);
	sz i = s.diag_index("file:///p/a.c3");
	assert(s.diag_state.entries[i].compiler.contains(`"start":{"line":5,"character":9}`), "got: %s", s.diag_state.entries[i].compiler);
}

fn void test_shift_moves_marker_up_with_deleted_lines() @test {
	LspServer s;
	s.init("", "c3c", 0);
	defer s.handle_exit();

	String old = "module a;\n// one\n// two\nfn void f() { int y = z; }\n";
	publish_one(&s, old, 3, 22);
	s.shift_compiler_diagnostics("file:///p/a.c3", old, "module a;\nfn void f() { int y = z; }\n");
	assert(tracked(&s).len == 1);
	assert(tracked(&s)[0].line == 1, "got %d", tracked(&s)[0].line);
}

// Editing the line an error is on (usually fixing it) removes the marker.
fn void test_shift_drops_marker_on_edited_line() @test {
	LspServer s;
	s.init("", "c3c", 0);
	defer s.handle_exit();

	String old = "module a;\nfn void f() { int y = z; }\n";
	publish_one(&s, old, 1, 22);
	s.shift_compiler_diagnostics("file:///p/a.c3", old, "module a;\nfn void f() { int y = 1; }\n");
	assert(s.diag_index("file:///p/a.c3") == s.diag_state.size, "the fixed error must be cleared");
}

// An edit below the error leaves it alone.
fn void test_shift_ignores_edits_below() @test {
	LspServer s;
	s.init("", "c3c", 0);
	defer s.handle_exit();

	String old = "module a;\nfn void f() { int y = z; }\n\n";
	publish_one(&s, old, 1, 22);
	sz i = s.diag_index("file:///p/a.c3");
	String before = s.diag_state.entries[i].compiler;
	s.shift_compiler_diagnostics("file:///p/a.c3", old, "module a;\nfn void f() { int y = z; }\n\nfn void g() {}\n");
	assert(tracked(&s).len == 1 && tracked(&s)[0].line == 1);
	assert(s.diag_state.entries[i].compiler == before);
}

// Raw-JSON compiler halves (no structured copy) are left as they are.
fn void test_shift_without_structured_diags_is_noop() @test {
	LspServer s;
	s.init("", "c3c", 0);
	defer s.handle_exit();

	s.set_diagnostics("file:///p/a.c3", `{"compiler":1}`, COMPILER);
	s.shift_compiler_diagnostics("file:///p/a.c3", "a\n", "x\na\n");
	assert(s.diag_state.entries[0].compiler == `{"compiler":1}`);
}

// --- lexer diagnostics ---

fn int count_diags(String els)
{
	if (els.len == 0) return 0;
	int n = 0;
	sz pos = 0;
	while (try i = els[pos..].index_of(`"range"`))
	{
		n++;
		pos += i + 1;
	}
	return n;
}

// A "..." string missing its closing quote is reported at its start, and lexing
// carries on from the next line so later problems are still found.
fn void test_lex_unterminated_string_mid_file() @test {
	String els = lex_diagnostic_elements("fn void f()\n{\n\tString s = \"abc;\n\tint x = 1; \x01\n\tString t = \"ok\";\n}\n");
	assert(els.contains(`"start":{"line":2,"character":12}`) && els.contains("Unterminated string literal"), "got: %s", els);
	assert(els.contains(`"start":{"line":3,"character":12}`), "the invalid byte on the next line must still be found, got: %s", els);
	assert(count_diags(els) == 2, "got: %s", els);
}

fn void test_lex_unterminated_string_at_eof() @test {
	String els = lex_diagnostic_elements("fn void f() {\n\tString s = \"abc");
	assert(els.contains("Unterminated string literal") && els.contains(`"start":{"line":1,"character":12}`), "got: %s", els);
}

// Raw strings may span lines.
fn void test_lex_raw_string_across_lines_ok() @test {
	assert(lex_diagnostic_elements("String s = `a\nb`;\n").len == 0);
}

fn void test_lex_unterminated_block_comment() @test {
	String els = lex_diagnostic_elements("fn void f() {}\n/* never closed\nfn void g() {}\n");
	assert(count_diags(els) == 1 && els.contains("Unterminated block comment") && els.contains(`"severity":2`), "got: %s", els);
	assert(els.contains(`"start":{"line":1,"character":0}`), "got: %s", els);
}

fn void test_lex_unterminated_contract() @test {
	String els = lex_diagnostic_elements("<* doc\nfn void f() {}\n");
	assert(count_diags(els) == 1 && els.contains("Unterminated contract block"), "got: %s", els);
}

// A pasted smart quote is three bytes but one character: one marker, one unit wide.
fn void test_lex_multibyte_invalid_char_once() @test {
	String els = lex_diagnostic_elements("int é = 1; x = “a”;\n");
	assert(els.contains("Invalid character '“'"), "got: %s", els);
	// `é` itself is also rejected; ranges are in UTF-16 units.
	assert(els.contains(`"start":{"line":0,"character":4},"end":{"line":0,"character":5}`), "got: %s", els);
	assert(els.contains(`"start":{"line":0,"character":15},"end":{"line":0,"character":16}`), "got: %s", els);
	assert(count_diags(els) == 3, "got: %s", els);
}
