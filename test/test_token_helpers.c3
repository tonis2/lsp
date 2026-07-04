module lsp;

import std::core::dstring;
import c3::lexer;

// Find the index of the first token of a given type at/after `from`.
fn sz first_of(TokenStream* s, TokenType t, sz from = 0)
{
	for (sz i = from; i < s.tokens.size; i++)
	{
		if (s.tokens.entries[i].type == t) return i;
	}
	return s.tokens.size;
}

fn void test_match_rbrace_nested() @test {
	// a{b{c}d}e — the first '{' matches the LAST '}'.
	TokenStream s = token_stream_tokenize("a{b{c}d}e");
	defer s.free();

	sz first_lbrace = first_of(&s, LBRACE);
	sz close = s.tokens.match_rbrace(first_lbrace);

	// The matched '}' must be the last '}', immediately before 'e'.
	assert(close < s.tokens.size, "expected a match, got size");
	assert(s.tokens.entries[close].type == RBRACE, "expected RBRACE");
	assert(close + 1 < s.tokens.size && s.tokens.entries[close + 1].text == "e",
		"matched brace should be the outer one preceding 'e'");
}

fn void test_match_rbrace_unbalanced() @test {
	// Missing closing brace → returns size (end-of-scan sentinel).
	TokenStream s = token_stream_tokenize("a{b{c}");
	defer s.free();

	sz first_lbrace = first_of(&s, LBRACE);
	assert(s.tokens.match_rbrace(first_lbrace) == s.tokens.size, "unbalanced braces should return size");
}

fn void test_match_lbrace_back_nested() @test {
	// a{b{c}d}e — the last '}' matches the FIRST '{', immediately after 'a'.
	TokenStream s = token_stream_tokenize("a{b{c}d}e");
	defer s.free();

	// Find the last '}'.
	sz last_rbrace = s.tokens.size;
	for (sz i = 0; i < s.tokens.size; i++)
	{
		if (s.tokens.entries[i].type == RBRACE) last_rbrace = i;
	}
	sz open = s.tokens.match_lbrace_back(last_rbrace);
	assert(open < s.tokens.size && s.tokens.entries[open].type == LBRACE, "expected an LBRACE match");
	assert(open > 0 && s.tokens.entries[open - 1].text == "a", "matched brace should be the outer one after 'a'");
}

fn void test_module_path_at() @test {
	TokenStream s = token_stream_tokenize("module std::io::file;\nfn void x() {}");
	defer s.free();
	sz mod_idx = first_of(&s, MODULE);
	assert(s.tokens.module_path_at(mod_idx) == "std::io::file", "got: %s", s.tokens.module_path_at(mod_idx));
}
