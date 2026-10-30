module lsp;

import std::core::dstring;
import std::core::mem;

// `日本` is 6 bytes but 2 UTF-16 units; `😀` is 4 bytes and a surrogate pair (2 units).
fn void test_utf16_to_byte() @test {
	String s = "a日本b😀c\nnext";
	assert(utf16_to_byte(s, 0, 0) == 0);
	assert(utf16_to_byte(s, 0, 1) == 1);  // after a
	assert(utf16_to_byte(s, 0, 3) == 7);  // after 日本
	assert(utf16_to_byte(s, 0, 4) == 8);  // after b
	assert(utf16_to_byte(s, 0, 6) == 12); // after 😀
	assert(utf16_to_byte(s, 0, 99) == 13, "clamped to the end of the line, not the next one");
}

fn void test_position_to_offset_converts_and_clamps() @test {
	String s = "x = \"日本\"; foo();\nbar";
	// `foo` is at UTF-16 column 10 (byte 14).
	assert(position_to_offset(s, 0, 10) == 14, "got %d", position_to_offset(s, 0, 10));
	assert(position_to_offset(s, 0, 500) == 20, "a column past the line stays on it");
	assert(position_to_offset(s, 1, 1) == 22);
	assert(position_to_offset(s, 9, 0) == 0);
}

fn void test_span_to_range_utf16() @test {
	String s = "x = \"日本\"; foo();\n";
	LineOffsets lo;
	lo.tinit();
	lo.build(s);
	Range r = span_to_range(s, &lo, 14, 17);
	assert(r.start.line == 0 && r.start.character == 10 && r.end.character == 13, "got %d-%d", r.start.character, r.end.character);
}

fn void test_token_range_multiline_token() @test {
	String s = "a /* é\nxy */ b";
	TokenList toks;
	toks.tinit();
	toks.tokenize(s);
	LineOffsets lo;
	lo.tinit();
	lo.build(s);
	Range r = token_range(toks.entries[1], &lo);
	assert(r.start.line == 0 && r.start.character == 2);
	assert(r.end.line == 1 && r.end.character == 5, "got %d:%d", r.end.line, r.end.character);
	Range b = token_range(toks.entries[2], &lo);
	assert(b.start.line == 1 && b.start.character == 6, "got %d:%d", b.start.line, b.start.character);
}

// End to end: a cursor after non-ASCII text on the same line finds the right token,
// and the answer's columns are UTF-16 too.
fn void test_definition_after_non_ascii() @test {
	DString out = dstring::temp();
	DocumentList* ds = mem::new(DocumentList);
	defer mem::free(ds);
	String content = "fn void foo() {}\nfn void main() { String s = \"日本\"; foo(); }";
	sz offset = position_to_offset(content, 1, 34); // on `foo` in the call
	assert(content[offset] == 'f', "got %c", content[offset]);
	encode_definition("file:///test.c3", content, offset, ds, "", &out);
	String result = out.str_view();
	assert(result.contains(`"start":{"line":0,"character":8}`), "got: %s", result);
}

fn void test_highlight_columns_are_utf16() @test {
	DString out = dstring::temp();
	String content = "fn void f() { String s = \"é\"; s.len; }";
	TokenStream stream = token_stream_tokenize(content);
	defer stream.free();
	// cursor on the declaration of `s` (byte 21)
	encode_document_highlights(content, 21, &out, &stream);
	String result = out.str_view();
	// `s` in `s.len` is at byte 31, UTF-16 column 30.
	assert(result.contains(`"start":{"line":0,"character":30}`), "got: %s", result);
}
