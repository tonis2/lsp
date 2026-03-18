module lsp;

import std::core::dstring;
import std::core::mem;
import c3::lexer;

// -- map_token_type --

fn void test_map_keywords() @test {
	assert(map_token_type(MODULE) == 0);   // namespace
	assert(map_token_type(FUNC) == 5);     // function
	assert(map_token_type(MACRO) == 6);    // macro
	assert(map_token_type(IF) == 7);       // keyword
	assert(map_token_type(RETURN) == 7);
	assert(map_token_type(WHILE) == 7);
}

fn void test_map_types() @test {
	assert(map_token_type(TYPE_IDENT) == 1);
	assert(map_token_type(VOID) == 1);
	assert(map_token_type(INT) == 1);
	assert(map_token_type(BOOL) == 1);
	assert(map_token_type(DOUBLE) == 1);
	assert(map_token_type(USZ) == 1);
	assert(map_token_type(TYPEID) == 1);
}

fn void test_map_definitions() @test {
	assert(map_token_type(ENUM) == 2);      // enum
	assert(map_token_type(FAULTDEF) == 2);
	assert(map_token_type(BITSTRUCT) == 2);
	assert(map_token_type(STRUCT) == 3);    // struct
	assert(map_token_type(UNION) == 3);
}

fn void test_map_identifiers() @test {
	assert(map_token_type(IDENT) == 4);       // variable
	assert(map_token_type(CONST_IDENT) == 4);
}

fn void test_map_literals() @test {
	assert(map_token_type(STRING) == 10);
	assert(map_token_type(CHAR_LITERAL) == 10);
	assert(map_token_type(BYTES) == 10);
	assert(map_token_type(INTEGER) == 11);
	assert(map_token_type(REAL) == 11);
}

fn void test_map_comments() @test {
	assert(map_token_type(LINE_COMMENT) == 9);
	assert(map_token_type(BLOCK_COMMENT) == 9);
	assert(map_token_type(CONTRACT) == 9);
}

fn void test_map_decorators() @test {
	assert(map_token_type(AT_INLINE) == 8);
	assert(map_token_type(AT_PURE) == 8);
	assert(map_token_type(AT_NOINLINE) == 8);
	assert(map_token_type(AT_IDENT) == 8);
}

fn void test_map_operators() @test {
	assert(map_token_type(PLUS) == 12);
	assert(map_token_type(MINUS) == 12);
	assert(map_token_type(EQ) == 12);
	assert(map_token_type(LBRACE) == 12);
	assert(map_token_type(RPAREN) == 12);
	assert(map_token_type(EOS) == 12);
}

fn void test_map_ct_keywords() @test {
	assert(map_token_type(CT_IF) == 6);       // macro
	assert(map_token_type(CT_ENDIF) == 6);
	assert(map_token_type(CT_SIZEOF) == 6);
	assert(map_token_type(BUILTIN) == 6);
	assert(map_token_type(CT_IDENT) == 6);
}

fn void test_map_skip_tokens() @test {
	assert(map_token_type(EOF) == -1);
	assert(map_token_type(EOL) == -1);
	assert(map_token_type(INVALID) == -1);
}

// -- build_line_offsets / find_line --

fn void test_line_offsets_single_line() @test {
	LineOffsets* lo = mem::new(LineOffsets);
	defer mem::free(lo);
	build_line_offsets("hello", lo);

	assert(lo.count == 1);
	assert(lo.offsets[0] == 0);
	assert(find_line(lo, 0) == 0);
	assert(find_line(lo, 4) == 0);
}

fn void test_line_offsets_multi_line() @test {
	LineOffsets* lo = mem::new(LineOffsets);
	defer mem::free(lo);
	// "ab\ncd\nef"
	//  01 2 34 5 67
	build_line_offsets("ab\ncd\nef", lo);

	assert(lo.count == 3);
	assert(lo.offsets[0] == 0);
	assert(lo.offsets[1] == 3);
	assert(lo.offsets[2] == 6);

	assert(find_line(lo, 0) == 0); // 'a'
	assert(find_line(lo, 1) == 0); // 'b'
	assert(find_line(lo, 2) == 0); // '\n'
	assert(find_line(lo, 3) == 1); // 'c'
	assert(find_line(lo, 5) == 1); // '\n'
	assert(find_line(lo, 6) == 2); // 'e'
	assert(find_line(lo, 7) == 2); // 'f'
}

fn void test_line_offsets_trailing_newline() @test {
	LineOffsets* lo = mem::new(LineOffsets);
	defer mem::free(lo);
	build_line_offsets("a\n", lo);

	assert(lo.count == 2);
	assert(lo.offsets[0] == 0);
	assert(lo.offsets[1] == 2);
}

// -- encode_semantic_tokens --

fn void test_encode_empty() @test {
	DString out = dstring::temp();
	encode_semantic_tokens("", &out);
	assert(out.str_view() == "", "Empty input should produce no tokens");
}

fn void test_encode_single_keyword() @test {
	DString out = dstring::temp();
	// "fn" is FUNC → type 5, at line 0, col 0, len 2
	encode_semantic_tokens("fn", &out);
	assert(out.str_view() == "0,0,2,5,0");
}

fn void test_encode_two_tokens_same_line() @test {
	DString out = dstring::temp();
	// "fn x" → FUNC(0,0,2,5,0) IDENT(0,3,1,4,0)
	encode_semantic_tokens("fn x", &out);
	assert(out.str_view() == "0,0,2,5,0,0,3,1,4,0");
}

fn void test_encode_multiline() @test {
	DString out = dstring::temp();
	// "fn\nx" → FUNC at (0,0) then IDENT at (1,0)
	// FUNC: deltaLine=0, deltaStart=0, len=2, type=5
	// IDENT: deltaLine=1, deltaStart=0, len=1, type=4
	encode_semantic_tokens("fn\nx", &out);
	assert(out.str_view() == "0,0,2,5,0,1,0,1,4,0");
}

fn void test_encode_comment() @test {
	DString out = dstring::temp();
	encode_semantic_tokens("// hello", &out);
	// LINE_COMMENT → type 9, at (0,0), len 8
	assert(out.str_view() == "0,0,8,9,0");
}

fn void test_encode_string_literal() @test {
	DString out = dstring::temp();
	encode_semantic_tokens(`"hello"`, &out);
	// STRING → type 10, at (0,0), len 7
	assert(out.str_view() == "0,0,7,10,0");
}

fn void test_encode_number() @test {
	DString out = dstring::temp();
	encode_semantic_tokens("42", &out);
	// INTEGER → type 11, at (0,0), len 2
	assert(out.str_view() == "0,0,2,11,0");
}
