module lsp;

import std::core::dstring;
import std::core::mem;
import c3::lexer;

// -- map_token_type --
// The LSP owns all syntax coloring: it emits semantic tokens for keywords,
// builtin types, literals, comments and identifiers. Only operators,
// punctuation and structural tokens are skipped (-1).

fn void test_map_keywords() @test {
	assert(map_token_type(MODULE) == KEYWORD);
	assert(map_token_type(FUNC) == KEYWORD);
	assert(map_token_type(MACRO) == KEYWORD);
	assert(map_token_type(IF) == KEYWORD);
	assert(map_token_type(RETURN) == KEYWORD);
	assert(map_token_type(WHILE) == KEYWORD);
	assert(map_token_type(STRUCT) == KEYWORD);
	assert(map_token_type(ENUM) == KEYWORD);
}

fn void test_map_types() @test {
	// User type identifiers are emitted as TYPE
	assert(map_token_type(TYPE_IDENT) == SemanticCategory.TYPE);
	assert(map_token_type(CT_TYPE_IDENT) == SemanticCategory.TYPE);
	// Builtin types are also emitted as TYPE — colored like user types
	assert(map_token_type(VOID) == SemanticCategory.TYPE);
	assert(map_token_type(INT) == SemanticCategory.TYPE);
	assert(map_token_type(BOOL) == SemanticCategory.TYPE);
	assert(map_token_type(USZ) == SemanticCategory.TYPE);
}

fn void test_map_identifiers() @test {
	assert(map_token_type(IDENT) == VARIABLE);
	assert(map_token_type(CONST_IDENT) == ENUM_MEMBER);
	assert(map_token_type(CT_IDENT) == MACRO_CAT);
}

fn void test_map_literals() @test {
	assert(map_token_type(STRING) == STRING_CAT);
	assert(map_token_type(CHAR_LITERAL) == STRING_CAT);
	assert(map_token_type(INTEGER) == NUMBER);
	assert(map_token_type(REAL) == NUMBER);
}

fn void test_map_comments() @test {
	assert(map_token_type(LINE_COMMENT) == COMMENT);
	assert(map_token_type(BLOCK_COMMENT) == COMMENT);
	assert(map_token_type(CONTRACT) == COMMENT);
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
	// CT keywords and the $$ builtin are emitted as KEYWORD
	assert(map_token_type(CT_IF) == KEYWORD);
	assert(map_token_type(CT_SIZEOF) == KEYWORD);
	assert(map_token_type(BUILTIN) == KEYWORD);
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
	// "fn" is FUNC → KEYWORD (index 7), len 2
	encode_semantic_tokens("fn", &out);
	assert(out.str_view() == "0,0,2,7,0", "got: %s", out.str_view());
}

fn void test_encode_two_tokens_same_line() @test {
	DString out = dstring::temp();
	// "fn x" → "fn" KEYWORD (7), IDENT "x" at col 3 → VARIABLE (4)
	encode_semantic_tokens("fn x", &out);
	assert(out.str_view() == "0,0,2,7,0,0,3,1,4,0", "got: %s", out.str_view());
}

fn void test_encode_multiline() @test {
	DString out = dstring::temp();
	// "fn\nx" → "fn" KEYWORD (7), IDENT "x" at line 1 col 0 → VARIABLE (4)
	encode_semantic_tokens("fn\nx", &out);
	assert(out.str_view() == "0,0,2,7,0,1,0,1,4,0", "got: %s", out.str_view());
}

fn void test_encode_comment() @test {
	DString out = dstring::temp();
	// "// hello" → LINE_COMMENT → COMMENT (9), len 8
	encode_semantic_tokens("// hello", &out);
	assert(out.str_view() == "0,0,8,9,0", "got: %s", out.str_view());
}

fn void test_encode_string_literal() @test {
	DString out = dstring::temp();
	// `"hello"` → STRING → STRING_CAT (10), len 7
	encode_semantic_tokens(`"hello"`, &out);
	assert(out.str_view() == "0,0,7,10,0", "got: %s", out.str_view());
}

fn void test_encode_number() @test {
	DString out = dstring::temp();
	// "42" → INTEGER → NUMBER (11), len 2
	encode_semantic_tokens("42", &out);
	assert(out.str_view() == "0,0,2,11,0", "got: %s", out.str_view());
}

fn void test_encode_multiline_block_comment() @test {
	DString out = dstring::temp();
	// "/* a\nb */" → BLOCK_COMMENT → COMMENT (9), split per line
	encode_semantic_tokens("/* a\nb */", &out);
	assert(out.str_view() == "0,0,4,9,0,1,0,4,9,0", "got: %s", out.str_view());
}

fn void test_encode_multiline_string() @test {
	DString out = dstring::temp();
	// "`a\nb`" → STRING → STRING_CAT (10), split per line
	encode_semantic_tokens("`a\nb`", &out);
	assert(out.str_view() == "0,0,2,10,0,1,0,2,10,0", "got: %s", out.str_view());
}

fn void test_encode_function_call() @test {
	DString out = dstring::temp();
	// "x()" → IDENT "x" followed by LPAREN → FUNCTION (index 5)
	encode_semantic_tokens("x()", &out);
	assert(out.str_view() == "0,0,1,5,0", "Function call should be detected, got: %s", out.str_view());
}

fn void test_encode_variable_not_function() @test {
	DString out = dstring::temp();
	// "fn x" → "fn" KEYWORD (7), "x" not followed by LPAREN → VARIABLE (4)
	encode_semantic_tokens("fn x", &out);
	assert(out.str_view() == "0,0,2,7,0,0,3,1,4,0", "Variable should stay variable, got: %s", out.str_view());
}

fn void test_encode_variable_assignment() @test {
	DString out = dstring::temp();
	// "int x = 1;" → "int" TYPE (1), "x" → VARIABLE (4), "1" → NUMBER (11)
	encode_semantic_tokens("int x = 1;", &out);
	assert(out.str_view() == "0,0,3,1,0,0,4,1,4,0,0,4,1,11,0", "got: %s", out.str_view());
}

fn void test_encode_namespace() @test {
	DString out = dstring::temp();
	// "io::print()" → "io" before "::" → NAMESPACE (0), "print" before "(" → FUNCTION (5)
	encode_semantic_tokens("io::print()", &out);
	assert(out.str_view() == "0,0,2,0,0,0,4,5,5,0", "got: %s", out.str_view());
}

// -- role-aware classification --

fn void test_encode_method_signature() @test {
	DString out = dstring::temp();
	// "fn void Foo.bar(int x)":
	//   fn    → DECL_ACCENT (17) [signature keyword]
	//   void  → DECL_ACCENT (17) [return type, same accent as "fn"]
	//   Foo   → CLASS (14)       [receiver type, before ".name("]
	//   bar   → FUNCTION (5)     [method name, before "("]
	//   int   → TYPE (1)         [parameter type — NOT the return type, stays plain]
	//   x     → PARAMETER (15)   [parameter name, before ")"]
	encode_semantic_tokens("fn void Foo.bar(int x)", &out);
	assert(out.str_view() == "0,0,2,17,0,0,3,4,17,0,0,5,3,14,0,0,4,3,5,0,0,4,3,1,0,0,4,1,15,0",
		"got: %s", out.str_view());
}

fn void test_encode_plain_function_signature() @test {
	DString out = dstring::temp();
	// "fn int add(int a)": no receiver — "add" is the name, "a" a parameter
	//   fn(17, accent) int(17, accent — return type) add(5) int(1, param type) a(15)
	encode_semantic_tokens("fn int add(int a)", &out);
	assert(out.str_view() == "0,0,2,17,0,0,3,3,17,0,0,4,3,5,0,0,4,3,1,0,0,4,1,15,0",
		"got: %s", out.str_view());
}

fn void test_encode_class_return_type() @test {
	DString out = dstring::temp();
	// "fn Foo bar()": fn → DECL_ACCENT(17), Foo → TYPE(1) [class return type,
	// NOT accented — regular type green], bar → FUNCTION(5)
	encode_semantic_tokens("fn Foo bar()", &out);
	assert(out.str_view() == "0,0,2,17,0,0,3,3,1,0,0,4,3,5,0",
		"got: %s", out.str_view());
}

fn void test_encode_type_declaration() @test {
	DString out = dstring::temp();
	// "struct Point" → struct KEYWORD (7), Point CLASS (14)
	encode_semantic_tokens("struct Point", &out);
	assert(out.str_view() == "0,0,6,7,0,0,7,5,14,0", "got: %s", out.str_view());
}

fn void test_encode_property_access() @test {
	DString out = dstring::temp();
	// "x.y" → "x" VARIABLE (4), "y" after "." not a call → PROPERTY (16)
	encode_semantic_tokens("x.y", &out);
	assert(out.str_view() == "0,0,1,4,0,0,2,1,16,0", "got: %s", out.str_view());
}

fn void test_encode_param_not_leaked_to_call() @test {
	DString out = dstring::temp();
	// "foo(x)" is a call, NOT a declaration → "x" stays VARIABLE (4), not PARAMETER
	encode_semantic_tokens("foo(x)", &out);
	assert(out.str_view() == "0,0,3,5,0,0,4,1,4,0", "got: %s", out.str_view());
}

// -- UTF-16 length encoding (LSP positions are UTF-16 code units, not bytes) --

fn void test_encode_utf16_string() @test {
	DString out = dstring::temp();
	// `"café"` → STRING (10). Bytes = 7 (é is 2 bytes), but UTF-16 length = 6.
	encode_semantic_tokens(`"café"`, &out);
	assert(out.str_view() == "0,0,6,10,0", "got: %s", out.str_view());
}

fn void test_encode_utf16_comment() @test {
	DString out = dstring::temp();
	// "// á" → COMMENT (9). Bytes = 5 (á is 2 bytes), but UTF-16 length = 4.
	encode_semantic_tokens("// á", &out);
	assert(out.str_view() == "0,0,4,9,0", "got: %s", out.str_view());
}

fn void test_encode_utf16_char_offset() @test {
	DString out = dstring::temp();
	// `x "é" y` — the trailing "y" must be offset by UTF-16 columns, not bytes.
	//   x(0) VARIABLE(4); "é"(2) STRING(10), 4 UTF-16 cols wide as bytes but
	//   token at UTF-16 col 2 len 3; y at UTF-16 col 6.
	//   x: 0,0,1,4,0   "é": col2 len3 → 0,2,3,10,0   y: col6 → 0,4,1,4,0
	encode_semantic_tokens(`x "é" y`, &out);
	assert(out.str_view() == "0,0,1,4,0,0,2,3,10,0,0,4,1,4,0", "got: %s", out.str_view());
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
