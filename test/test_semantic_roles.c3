module lsp;

import std::core::dstring;

// One decoded semantic token.
struct SemTok
{
	String text;
	int type;  // SemanticCategory index, -1 when the token isn't emitted
	int mods;
}

// The `nth` emitted semantic token of `content` whose text is `text`.
fn SemTok sem_token(String content, String text, sz nth = 0)
{
	DString out = dstring::temp();
	encode_semantic_tokens(content, &out);
	LineOffsets lo;
	lo.tinit();
	lo.build(content);
	String[] nums = out.str_view().len > 0 ? out.str_view().tsplit(",") : {};
	sz line = 0;
	sz ch = 0;
	for (sz i = 0; i + 4 < nums.len; i += 5)
	{
		sz dl = nums[i].to_uint()!!;
		sz dc = nums[i + 1].to_uint()!!;
		sz len = nums[i + 2].to_uint()!!;
		line += dl;
		ch = dl == 0 ? ch + dc : dc;
		sz start = utf16_to_byte(content, lo.entries[line], ch);
		sz end = utf16_to_byte(content, lo.entries[line], ch + len);
		if (content[start:end - start] != text) continue;
		if (nth-- > 0) continue;
		return { text, (int)nums[i + 3].to_uint()!!, (int)nums[i + 4].to_uint()!! };
	}
	return { text, -1, 0 };
}

fn void test_sem_literal_and_declaration_keywords_left_to_grammar() @test {
	String src = "struct Foo { int x; }\nfn bool f() { return true || null; }";
	assert(sem_token(src, "struct").type == -1);
	assert(sem_token(src, "fn").type == -1);
	assert(sem_token(src, "true").type == -1);
	assert(sem_token(src, "null").type == -1);
	assert(sem_token(src, "return").type == SemanticCategory.KEYWORD.index);
}

fn void test_sem_ct_variable_is_variable() @test {
	String src = "macro m() { $for (var $i = 0; $i < 3; $i++): $endfor }";
	assert(sem_token(src, "$i", 1).type == SemanticCategory.VARIABLE.index, "got %d", sem_token(src, "$i", 1).type);
}

fn void test_sem_generic_return_type_signature() @test {
	String src = "fn List{int} make(int n) { return n; }";
	SemTok name = sem_token(src, "make");
	assert(name.type == SemanticCategory.FUNCTION.index && (name.mods & MOD_DECLARATION), "got %d/%d", name.type, name.mods);
	assert(sem_token(src, "n").type == SemanticCategory.PARAMETER.index);
	assert(sem_token(src, "n", 1).type == SemanticCategory.PARAMETER.index, "a parameter's use in the body");
}

fn void test_sem_macros() @test {
	String src = "macro @m(x; @body) { @body(); }\nfn void f() @inline { @m(1; ) {}; @foo(2); }\nfn void g() @myattr(1) {}";
	SemTok decl = sem_token(src, "@m");
	assert(decl.type == SemanticCategory.MACRO_CAT.index && (decl.mods & MOD_DECLARATION), "got %d", decl.type);
	assert(sem_token(src, "x").type == SemanticCategory.PARAMETER.index, "parameter before `;`");
	assert(sem_token(src, "@body").type == SemanticCategory.PARAMETER.index, "trailing body parameter");
	assert(sem_token(src, "@inline").type == SemanticCategory.DECORATOR.index);
	assert(sem_token(src, "@m", 1).type == SemanticCategory.MACRO_CAT.index, "a macro call");
	assert(sem_token(src, "@foo").type == SemanticCategory.MACRO_CAT.index, "a macro call");
	assert(sem_token(src, "@myattr").type == SemanticCategory.DECORATOR.index, "a user attribute after a signature");
}

fn void test_sem_nested_struct_member_is_property() @test {
	String src = "struct Foo { struct inner { int x; } }";
	assert(sem_token(src, "inner").type == SemanticCategory.PROPERTY.index, "got %d", sem_token(src, "inner").type);
	assert(sem_token(src, "x").type == SemanticCategory.PROPERTY.index);
}

fn void test_sem_constants_readonly_declaration() @test {
	String src = "const int MAX = 4;\nenum Color { RED, GREEN }\nfn int f() { return MAX; }";
	SemTok max = sem_token(src, "MAX");
	assert(max.type == SemanticCategory.ENUM_MEMBER.index && max.mods == (MOD_READONLY | MOD_DECLARATION), "got %d", max.mods);
	assert(sem_token(src, "MAX", 1).mods == MOD_READONLY, "a use is not a declaration");
	assert(sem_token(src, "GREEN").mods == (MOD_READONLY | MOD_DECLARATION));
}

fn void test_sem_feat_flags() @test {
	String src = "fn void f() @feat(POSIX, !WIN32) {}\nint x = $feat(LIBC) ? 1 : 0;";
	assert(sem_token(src, "@feat").type == SemanticCategory.DECORATOR.index);
	assert(sem_token(src, "POSIX").type == SemanticCategory.MACRO_CAT.index);
	assert(sem_token(src, "WIN32").type == SemanticCategory.MACRO_CAT.index);
	assert(sem_token(src, "LIBC").type == SemanticCategory.MACRO_CAT.index);
}

// Prose with an apostrophe in a directive no longer ends the contract's coloring.
fn void test_sem_contract_with_apostrophe() @test {
	String src = "<*\n @return the caller's id\n @require x > 0\n*>";
	assert(sem_token(src, "@return").type == SemanticCategory.DECORATOR.index);
	assert(sem_token(src, "@require").type == SemanticCategory.DECORATOR.index, "the next directive still colors");
	assert(sem_token(src, "x").type == SemanticCategory.VARIABLE.index);
}

fn void test_sem_range_only_requested_lines() @test {
	DString out = dstring::temp();
	encode_semantic_tokens("return a;\nreturn b;\nreturn c;", &out, null, 1, 1);
	// Only line 1: `return` at 1:0 and `b` at 1:7; positions stay absolute.
	assert(out.str_view() == "1,0,6,7,0,0,7,1,4,0", "got: %s", out.str_view());
}

fn void test_sem_delta_edit() @test {
	DString out = dstring::temp();
	encode_semantic_edit("0,0,6,7,0,1,0,1,4,0", "0,0,6,7,0,1,0,3,4,0", &out);
	assert(out.str_view() == `{"start":7,"deleteCount":1,"data":[3]}`, "got: %s", out.str_view());
	out.clear();
	encode_semantic_edit("1,2,3", "1,2,3", &out);
	assert(out.str_view() == "", "no edit for identical arrays");
}
