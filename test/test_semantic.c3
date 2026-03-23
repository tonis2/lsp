module lsp;

import std::core::dstring;
import std::core::mem;
import c3::lexer;

// -- map_token_type --
// The LSP only emits semantic tokens for identifiers and decorators.
// Keywords, operators, comments, strings, numbers, and builtin types
// are skipped (-1) to let the TextMate grammar handle them.

fn void test_map_keywords() @test {
	// Keywords are skipped — TextMate handles nuanced keyword scoping
	assert(map_token_type(MODULE) == SKIP);
	assert(map_token_type(FUNC) == SKIP);
	assert(map_token_type(MACRO) == SKIP);
	assert(map_token_type(IF) == SKIP);
	assert(map_token_type(RETURN) == SKIP);
	assert(map_token_type(WHILE) == SKIP);
	assert(map_token_type(STRUCT) == SKIP);
	assert(map_token_type(ENUM) == SKIP);
}

fn void test_map_types() @test {
	// User type identifiers are emitted as TYPE
	assert(map_token_type(TYPE_IDENT) == SemanticCategory.TYPE);
	assert(map_token_type(CT_TYPE_IDENT) == SemanticCategory.TYPE);
	// Builtin types are skipped — TextMate handles as storage.type.built-in
	assert(map_token_type(VOID) == SKIP);
	assert(map_token_type(INT) == SKIP);
	assert(map_token_type(BOOL) == SKIP);
	assert(map_token_type(USZ) == SKIP);
}

fn void test_map_identifiers() @test {
	assert(map_token_type(IDENT) == VARIABLE);
	assert(map_token_type(CONST_IDENT) == ENUM_MEMBER);
	assert(map_token_type(CT_IDENT) == MACRO_CAT);
}

fn void test_map_literals() @test {
	// Skipped — TextMate handles string/number coloring
	assert(map_token_type(STRING) == SKIP);
	assert(map_token_type(CHAR_LITERAL) == SKIP);
	assert(map_token_type(INTEGER) == SKIP);
	assert(map_token_type(REAL) == SKIP);
}

fn void test_map_comments() @test {
	// Skipped — TextMate handles comment coloring
	assert(map_token_type(LINE_COMMENT) == SKIP);
	assert(map_token_type(BLOCK_COMMENT) == SKIP);
	assert(map_token_type(CONTRACT) == SKIP);
}

fn void test_map_decorators() @test {
	assert(map_token_type(AT_INLINE) == DECORATOR);
	assert(map_token_type(AT_PURE) == DECORATOR);
	assert(map_token_type(AT_NOINLINE) == DECORATOR);
	assert(map_token_type(AT_IDENT) == DECORATOR);
}

fn void test_map_operators() @test {
	// Skipped — TextMate handles operator coloring
	assert(map_token_type(PLUS) == SKIP);
	assert(map_token_type(MINUS) == SKIP);
	assert(map_token_type(EQ) == SKIP);
	assert(map_token_type(LBRACE) == SKIP);
}

fn void test_map_ct_keywords() @test {
	// CT keywords are skipped — TextMate handles them
	assert(map_token_type(CT_IF) == SKIP);
	assert(map_token_type(CT_SIZEOF) == SKIP);
	assert(map_token_type(BUILTIN) == SKIP);
	// CT identifiers are emitted as macro
	assert(map_token_type(CT_IDENT) == MACRO_CAT);
}

fn void test_map_skip_tokens() @test {
	assert(map_token_type(EOF) == SKIP);
	assert(map_token_type(EOL) == SKIP);
	assert(map_token_type(INVALID) == SKIP);
}

// -- build_line_offsets / find_line --

fn void test_line_offsets_single_line() @test {
	LineOffsets lo;
	lo.init(mem);
	defer lo.free();
	lo.build("hello");

	assert(lo.size == 1);
	assert(lo.entries[0] == 0);
	assert(lo.find_line( 0) == 0);
	assert(lo.find_line( 4) == 0);
}

fn void test_line_offsets_multi_line() @test {
	LineOffsets lo;
	lo.init(mem);
	defer lo.free();
	// "ab\ncd\nef"
	//  01 2 34 5 67
	lo.build("ab\ncd\nef");

	assert(lo.size == 3);
	assert(lo.entries[0] == 0);
	assert(lo.entries[1] == 3);
	assert(lo.entries[2] == 6);

	assert(lo.find_line( 0) == 0); // 'a'
	assert(lo.find_line( 1) == 0); // 'b'
	assert(lo.find_line( 2) == 0); // '\n'
	assert(lo.find_line( 3) == 1); // 'c'
	assert(lo.find_line( 5) == 1); // '\n'
	assert(lo.find_line( 6) == 2); // 'e'
	assert(lo.find_line( 7) == 2); // 'f'
}

fn void test_line_offsets_trailing_newline() @test {
	LineOffsets lo;
	lo.init(mem);
	defer lo.free();
	lo.build("a\n");

	assert(lo.size == 2);
	assert(lo.entries[0] == 0);
	assert(lo.entries[1] == 2);
}

// -- encode_semantic_tokens --

fn void test_encode_empty() @test {
	DString out = dstring::temp();
	encode_semantic_tokens("", &out);
	assert(out.str_view() == "", "Empty input should produce no tokens");
}

fn void test_encode_single_keyword() @test {
	DString out = dstring::temp();
	// "fn" is FUNC — skipped (TextMate handles keywords)
	encode_semantic_tokens("fn", &out);
	assert(out.str_view() == "", "Keywords should be skipped, got: %s", out.str_view());
}

fn void test_encode_two_tokens_same_line() @test {
	DString out = dstring::temp();
	// "fn x" → FUNC skipped, IDENT "x" at col 3, len 1, type 4
	encode_semantic_tokens("fn x", &out);
	assert(out.str_view() == "0,3,1,4,0", "got: %s", out.str_view());
}

fn void test_encode_multiline() @test {
	DString out = dstring::temp();
	// "fn\nx" → FUNC skipped, IDENT at line 1 col 0
	encode_semantic_tokens("fn\nx", &out);
	assert(out.str_view() == "1,0,1,4,0", "got: %s", out.str_view());
}

fn void test_encode_comment() @test {
	DString out = dstring::temp();
	// Comments are skipped — TextMate handles them
	encode_semantic_tokens("// hello", &out);
	assert(out.str_view() == "", "Comments should be skipped, got: %s", out.str_view());
}

fn void test_encode_string_literal() @test {
	DString out = dstring::temp();
	// Strings are skipped — TextMate handles them
	encode_semantic_tokens(`"hello"`, &out);
	assert(out.str_view() == "", "Strings should be skipped, got: %s", out.str_view());
}

fn void test_encode_number() @test {
	DString out = dstring::temp();
	// Numbers are skipped — TextMate handles them
	encode_semantic_tokens("42", &out);
	assert(out.str_view() == "", "Numbers should be skipped, got: %s", out.str_view());
}

fn void test_encode_multiline_block_comment() @test {
	DString out = dstring::temp();
	// Block comments are skipped — TextMate handles them
	encode_semantic_tokens("/* a\nb */", &out);
	assert(out.str_view() == "", "Block comments should be skipped, got: %s", out.str_view());
}

fn void test_encode_multiline_string() @test {
	DString out = dstring::temp();
	// Multi-line strings are skipped — TextMate handles them
	encode_semantic_tokens("`a\nb`", &out);
	assert(out.str_view() == "", "Strings should be skipped, got: %s", out.str_view());
}

fn void test_encode_function_call() @test {
	DString out = dstring::temp();
	// "x()" → IDENT "x" followed by LPAREN → FUNCTION (index 5)
	encode_semantic_tokens("x()", &out);
	assert(out.str_view() == "0,0,1,5,0", "Function call should be detected, got: %s", out.str_view());
}

fn void test_encode_variable_not_function() @test {
	DString out = dstring::temp();
	// "fn x" → IDENT "x" not followed by LPAREN → VARIABLE (index 4)
	encode_semantic_tokens("fn x", &out);
	assert(out.str_view() == "0,3,1,4,0", "Variable should stay variable, got: %s", out.str_view());
}

fn void test_encode_variable_assignment() @test {
	DString out = dstring::temp();
	// "int x = 1;" → IDENT "x" followed by EQ, not LPAREN → VARIABLE (4)
	encode_semantic_tokens("int x = 1;", &out);
	assert(out.str_view() == "0,4,1,4,0", "Assignment target should be variable, got: %s", out.str_view());
}

fn void test_encode_const_ident() @test {
	DString out = dstring::temp();
	// "FOO" is CONST_IDENT → ENUM_MEMBER (index 13)
	encode_semantic_tokens("FOO", &out);
	assert(out.str_view() == "0,0,3,13,0", "CONST_IDENT should be enumMember, got: %s", out.str_view());
}

fn void test_encode_const_ident_not_function() @test {
	DString out = dstring::temp();
	// "FOO()" — CONST_IDENT is always ENUM_MEMBER, not promoted to FUNCTION
	encode_semantic_tokens("FOO()", &out);
	assert(out.str_view() == "0,0,3,13,0", "CONST_IDENT before LPAREN should stay enumMember, got: %s", out.str_view());
}

fn void test_encode_function_call_with_args() @test {
	DString out = dstring::temp();
	// "foo(x)" → "foo" FUNCTION (5), "x" VARIABLE (4)
	encode_semantic_tokens("foo(x)", &out);
	assert(out.str_view() == "0,0,3,5,0,0,4,1,4,0", "got: %s", out.str_view());
}

fn void test_encode_nested_function_calls() @test {
	DString out = dstring::temp();
	// "foo(bar())" → "foo" FUNCTION (5), "bar" FUNCTION (5)
	encode_semantic_tokens("foo(bar())", &out);
	assert(out.str_view() == "0,0,3,5,0,0,4,3,5,0", "got: %s", out.str_view());
}

fn void test_encode_method_call() @test {
	DString out = dstring::temp();
	// "x.foo()" → "x" VARIABLE (4), "foo" FUNCTION (5)
	encode_semantic_tokens("x.foo()", &out);
	assert(out.str_view() == "0,0,1,4,0,0,2,3,5,0", "got: %s", out.str_view());
}

fn void test_encode_variable_semicolon() @test {
	DString out = dstring::temp();
	// "x;" → IDENT "x" followed by EOS, not LPAREN → VARIABLE (4)
	encode_semantic_tokens("x;", &out);
	assert(out.str_view() == "0,0,1,4,0", "Ident before semicolon should be variable, got: %s", out.str_view());
}
