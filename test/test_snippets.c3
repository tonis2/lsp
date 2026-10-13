module lsp;

import std::core::dstring;
import std::core::mem;
import std::encoding::json;
import std::collections::object;

// Keyword templates offered as snippet completions (kind 15) next to the keywords.

fn String complete_end(String content, bool snippets = true) @private
{
	DocumentList* docs = mem::tnew(DocumentList);
	DString out = dstring::temp();
	encode_completions("", content, content.len, docs, "", &out, snippets);
	return out.str_view();
}

fn bool has_snippet(String result, String label) @private
{
	return result.contains(string::tformat(`"label":"%s","kind":15`, label));
}

fn void test_snippet_for_loop_in_body() @test
{
	String r = complete_end("fn void t()\n{\n\tfo");
	assert(has_snippet(r, "for"), "got: %s", r);
	assert(r.contains(`"textEditText":"for (${1:int i = 0}; ${2:i < len}; ${3:i++})\n{\n\t$0\n}"`), "got: %s", r);
	assert(r.contains(`"insertTextFormat":2,"insertTextMode":2`), "got: %s", r);
	assert(r.contains(`"label":"for","kind":14`), "the plain keyword stays, got: %s", r);
	assert(has_snippet(r, "foreach"), "got: %s", r);
}

fn void test_snippet_statement_positions() @test
{
	assert(has_snippet(complete_end("fn void t()\n{\n\tint x = 1;\n\twh"), "while"), "after a statement");
	assert(has_snippet(complete_end("fn void t(int x)\n{\n\tswitch (x)\n\t{\n\t\tcase 1:\n\t\t\twh"), "while"), "after a case label");
	assert(has_snippet(complete_end("fn void t()\n{\n\tif (true)\n\t{\n\t}\n\tel"), "else"), "after a block");
}

fn void test_snippet_not_in_expressions() @test
{
	assert(!has_snippet(complete_end("fn void t()\n{\n\tint x = fo"), "for"), "after =");
	assert(!has_snippet(complete_end("fn void t()\n{\n\tfor (int i = 0; wh"), "while"), "inside a for header");
	assert(!has_snippet(complete_end("struct Foo { int a; }\nfn void t()\n{\n\tFoo f = { fo"), "for"), "inside an initializer");
	assert(!has_snippet(complete_end("fn void t(int x)\n{\n\tint y = x ? 1 : wh"), "while"), "after a ternary colon");
}

fn void test_snippet_not_in_comments_or_strings() @test
{
	assert(!has_snippet(complete_end("fn void t()\n{\n\t// fo"), "for"), "line comment");
	assert(!has_snippet(complete_end("fn void t()\n{\n\t/* fo"), "for"), "unterminated block comment");
	String src = "fn void t()\n{\n\tfoo(\"fo \");\n}";
	DocumentList* docs = mem::tnew(DocumentList);
	DString out = dstring::temp();
	encode_completions("", src, nth_offset(src, "fo ") + 2, docs, "", &out);
	assert(!has_snippet(out.str_view(), "for"), "string, got: %s", out.str_view());
}

fn void test_snippet_declarations_only_at_top_level() @test
{
	assert(has_snippet(complete_end("module m;\nst"), "struct"), "after module");
	assert(has_snippet(complete_end("fn"), "fn"), "start of file");
	assert(has_snippet(complete_end("<*\n Doc\n*>\nfn"), "fn"), "after a contract");
	assert(!has_snippet(complete_end("fn void t()\n{\n\tst"), "struct"), "not in a body");
	assert(!has_snippet(complete_end("module m;\nfo"), "for"), "no statements at top level");
	assert(!has_snippet(complete_end("struct Foo\n{\n\tint a;\n\tst"), "struct"), "not in a struct body");
}

fn void test_snippet_compile_time_needs_dollar() @test
{
	String r = complete_end("fn void t()\n{\n\t$i");
	assert(has_snippet(r, "$if"), "got: %s", r);
	assert(r.contains(`"textEditText":"\\$if ${1:cond}:\n\t$0\n\\$endif"`), "$ is escaped, got: %s", r);
	assert(!has_snippet(complete_end("fn void t()\n{\n\ti"), "$if"), "plain prefix");
	assert(!has_snippet(r, "if"), "no plain templates after $");
}

fn void test_snippet_support_can_be_off() @test
{
	String src = "fn void helper() {}\nfn void t()\n{\n\thel";
	assert(complete_end(src).contains(`helper($0)`), "call snippets on by default");
	String r = complete_end(src, false);
	assert(!r.contains(`$0`) && !r.contains(`"kind":15`), "got: %s", r);
	assert(r.contains(`"label":"helper"`), "the plain item stays, got: %s", r);
}

// initialize must survive a client that sends no completion capabilities at all.
fn void test_snippet_capability_lookup() @test
{
	Object* msg = json::tparse(`{"params":{"capabilities":{}}}`)!!;
	assert(!@ok(completion_item_capabilities(msg)), "absent capabilities are a miss, not a crash");
	msg = json::tparse(`{"params":{}}`)!!;
	assert(!@ok(completion_item_capabilities(msg)));
	msg = json::tparse(`{"params":{"capabilities":{"textDocument":{"completion":{"completionItem":{"snippetSupport":true}}}}}}`)!!;
	Object* item = completion_item_capabilities(msg)!!;
	assert(item.get_bool("snippetSupport")!!);
}
