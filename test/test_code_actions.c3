module lsp;

import std::core::dstring;
import std::encoding::json;
import std::collections::object;

// Messages below are verbatim c3c 0.8.4 `--lsp` output; positions are 0-indexed
// (c3c's 1-indexed line/col minus one).

const String MISSING_IO = "Did you mean the macro 'printn' in module std::io? If so please add 'import std::io'.";
const String MISSING_LIST = "Did you mean the struct 'List' in module std::collections::list? If so please add 'import std::collections::list'.";

fn String code_actions_for(String content, int line, int col, String message) @private
{
	ActionDiag[1] diags = { { .range = { { (sz)line, (sz)col }, { (sz)line, (sz)col + 1 } }, .message = message, .source = "c3c", .severity = 1 } };
	DString out = dstring::temp();
	encode_code_actions("file:///proj/a.c3", content, null, diags[..], &out);
	return out.str_view();
}

fn String insert_at(int line, int col, String text) @private
{
	return string::tformat(`{"range":{"start":{"line":%d,"character":%d},"end":{"line":%d,"character":%d}},"newText":"%s"}`, line, col, line, col, text);
}

// --- missing import ---

fn void test_code_action_import_and_prefix_for_function() @test {
	String r = code_actions_for("module a;\n\nfn void main()\n{\n    printn(\"x\");\n}\n", 4, 4, MISSING_IO);
	assert(r.contains(`"title":"Add 'import std::io;' and use 'io::printn'","kind":"quickfix","isPreferred":true`),
		"a function also needs its prefix once imported, so that fix is preferred, got: %s", r);
	assert(r.contains(insert_at(1, 0, `import std::io;\n`)), "import goes after the module line, got: %s", r);
	assert(r.contains(insert_at(4, 4, "io::")), "prefix goes before the name, got: %s", r);
	assert(r.contains(`"title":"Add 'import std::io;'","kind":"quickfix","diagnostics"`),
		"the import-only fix is still offered, not preferred, got: %s", r);
}

fn void test_code_action_import_only_for_type() @test {
	String r = code_actions_for("module a;\n\nfn void main()\n{\n    List{int} l;\n}\n", 4, 4, MISSING_LIST);
	assert(r.contains(`"title":"Add 'import std::collections::list;'","kind":"quickfix","isPreferred":true`), "got: %s", r);
	assert(!r.contains("and use"), "types are used unprefixed, got: %s", r);
}

fn void test_code_action_import_only_when_already_qualified() @test {
	String r = code_actions_for("module a;\n\nfn void main()\n{\n    io::printn(\"x\");\n}\n", 4, 4,
		"Did you mean the macro 'std::io::printn' in module std::io? If so please add 'import std::io'.");
	assert(r.contains(`"title":"Add 'import std::io;'","kind":"quickfix","isPreferred":true`), "got: %s", r);
	assert(!r.contains("and use"), "the call is already prefixed, got: %s", r);
}

fn void test_code_action_import_goes_after_last_import() @test {
	String r = code_actions_for("module a;\nimport std::io;\nimport std::math;\n\nfn void main()\n{\n    List{int} l;\n}\n", 6, 4, MISSING_LIST);
	assert(r.contains(insert_at(3, 0, `import std::collections::list;\n`)), "got: %s", r);
}

fn void test_code_action_import_at_top_without_module() @test {
	String r = code_actions_for("fn void main()\n{\n    List{int} l;\n}\n", 2, 4, MISSING_LIST);
	assert(r.contains(insert_at(0, 0, `import std::collections::list;\n`)), "got: %s", r);
}

fn void test_code_action_import_targets_enclosing_module_section() @test {
	// Imports are per module section: section `a` importing std::io does not help `b`.
	String src = "module a;\nimport std::io;\nfn void f() {}\n\nmodule b;\n\nfn void main()\n{\n    printn(\"x\");\n}\n";
	String r = code_actions_for(src, 8, 4, MISSING_IO);
	assert(r.contains(insert_at(5, 0, `import std::io;\n`)), "import goes after `module b;`, got: %s", r);
}

fn void test_code_action_import_skipped_when_present() @test {
	// A stale diagnostic: the import was added since the last save.
	String r = code_actions_for("module a;\nimport std::collections::list;\nfn void main()\n{\n    List{int} l;\n}\n", 4, 4, MISSING_LIST);
	assert(r == "[]", "got: %s", r);
}

fn void test_code_action_import_after_last_line_without_newline() @test {
	String r = code_actions_for("module a;", 3, 0, MISSING_LIST);
	assert(r.contains(insert_at(0, 9, `\nimport std::collections::list;`)), "got: %s", r);
}

fn void test_code_action_try_importing_message() @test {
	String r = code_actions_for("module a;\n\nfn void main()\n{\n    foo();\n}\n", 4, 4, "'foo' could not be found, try importing the 'b' module.");
	assert(r.contains(`"title":"Add 'import b;'"`), "got: %s", r);
}

// --- missing module prefix ---

fn void test_code_action_prefix_for_macro() @test {
	String r = code_actions_for("module a;\nimport std::io;\n\nfn void main()\n{\n    printn(\"x\");\n}\n", 5, 4,
		"Macros from other modules must be prefixed with the module name, please use io::printn instead.");
	assert(r.contains(`"title":"Use 'io::printn'","kind":"quickfix","isPreferred":true`), "got: %s", r);
	assert(r.contains(insert_at(5, 4, "io::")), "got: %s", r);
}

fn void test_code_action_prefix_strips_call_suffix() @test {
	String r = code_actions_for("module a;\nimport std::io;\nfn void main() { printn(\"x\"); }\n", 2, 17,
		"Functions from other modules must be prefixed with the module name, please use io::printn(...) instead.");
	assert(r.contains(`"title":"Use 'io::printn'"`), "got: %s", r);
	assert(r.contains(insert_at(2, 17, "io::")), "got: %s", r);
}

fn void test_code_action_prefix_for_constant() @test {
	String r = code_actions_for("module a;\nimport b;\nfn void main()\n{\n    int y = MAX_THING;\n}\n", 4, 12,
		"Globals from other modules must be prefixed with the module name, please use b::MAX_THING instead.");
	assert(r.contains(insert_at(4, 12, "b::")), "got: %s", r);
}

fn void test_code_action_prefix_finds_moved_name() @test {
	// The buffer changed since the save and the name moved along the line.
	String r = code_actions_for("module a;\nimport std::io;\nfn void main()\n{\n        printn(\"x\");\n}\n", 4, 4,
		"Macros from other modules must be prefixed with the module name, please use io::printn instead.");
	assert(r.contains(insert_at(4, 8, "io::")), "got: %s", r);
}

fn void test_code_action_prefix_skipped_when_name_gone() @test {
	String r = code_actions_for("module a;\nimport std::io;\nfn void main()\n{\n    printnx(\"x\");\n}\n", 4, 4,
		"Macros from other modules must be prefixed with the module name, please use io::printn instead.");
	assert(r == "[]", "a partial match must not be prefixed, got: %s", r);
}

// --- typos ---

fn void test_code_action_typo_single_candidate() @test {
	String r = code_actions_for("module a;\n\nfn void foo_bar() {}\nfn void main()\n{\n    foo_baz();\n}\n", 5, 4,
		"'foo_baz' could not be found, did you perhaps want 'foo_bar'?");
	assert(r.contains(`"title":"Change to 'foo_bar'","kind":"quickfix","isPreferred":true`), "got: %s", r);
	assert(r.contains(`{"range":{"start":{"line":5,"character":4},"end":{"line":5,"character":11}},"newText":"foo_bar"}`), "got: %s", r);
}

fn void test_code_action_typo_qualified_two_candidates() @test {
	String r = code_actions_for("module a;\nimport std::io;\n\nfn void main()\n{\n    io::prinn(\"x\");\n}\n", 5, 4,
		"'io::prinn' could not be found, did you perhaps want 'io::print' or 'io::printn'?");
	assert(r.contains(`"title":"Change to 'io::print'","kind":"quickfix","diagnostics"`), "ambiguous: not preferred, got: %s", r);
	assert(r.contains(`"title":"Change to 'io::printn'"`), "got: %s", r);
	assert(r.contains(`{"range":{"start":{"line":5,"character":4},"end":{"line":5,"character":13}},"newText":"io::printn"}`), "got: %s", r);
}

fn void test_code_action_typo_three_candidates() @test {
	String r = code_actions_for("fn void main() { fooo(); }", 0, 17, "'fooo' could not be found, did you perhaps want 'foo', 'food' or 'fool'?");
	assert(r.contains(`"title":"Change to 'foo'"`) && r.contains(`"title":"Change to 'food'"`) && r.contains(`"title":"Change to 'fool'"`), "got: %s", r);
}

fn void test_code_action_no_suggestion_is_empty() @test {
	String r = code_actions_for("module a;\nfn void main() { counx = 2; }\n", 1, 17, "'counx' could not be found, did you spell it right?");
	assert(r == "[]", "got: %s", r);
	r = code_actions_for("module a;\n", 0, 0, "Implicitly casting 'fault' to 'usz' (ulong) is not permitted.");
	assert(r == "[]", "got: %s", r);
}

// --- shape ---

fn void test_code_action_echoes_diagnostic() @test {
	String r = code_actions_for("fn void main() { foo_baz(); }", 0, 17, "'foo_baz' could not be found, did you perhaps want 'foo_bar'?");
	assert(r.contains(`"diagnostics":[{"range":{"start":{"line":0,"character":17},"end":{"line":0,"character":18}},"severity":1,"source":"c3c","message":"'foo_baz' could not be found`), "got: %s", r);
	assert(r.contains(`"edit":{"changes":{"file:///proj/a.c3":[`), "got: %s", r);
}

fn void test_code_action_dedupes_same_fix() @test {
	String src = "module a;\nfn void main()\n{\n    List{int} a;\n    List{int} b;\n}\n";
	ActionDiag[2] diags = {
		{ .range = { { 3, 4 }, { 3, 5 } }, .message = MISSING_LIST },
		{ .range = { { 4, 4 }, { 4, 5 } }, .message = MISSING_LIST },
	};
	DString out = dstring::temp();
	encode_code_actions("file:///proj/a.c3", src, null, diags[..], &out);
	String r = out.str_view();
	sz first = r.index_of("Add 'import")!!;
	assert(!r[first + 1..].contains("Add 'import"), "one import fix for both uses, got: %s", r);
}

fn void test_code_action_respects_only_filter() @test {
	Object* ctx = json::tparse(`{"diagnostics":[],"only":["source.organizeImports"]}`)!!;
	assert(!wants_quickfix(ctx), "source-only requests get no quick fixes");
	ctx = json::tparse(`{"diagnostics":[],"only":["quickfix"]}`)!!;
	assert(wants_quickfix(ctx));
	ctx = json::tparse(`{"diagnostics":[]}`)!!;
	assert(wants_quickfix(ctx), "no filter means every kind");
}

fn void test_code_action_capability_is_advertised() @test {
	DString out = dstring::temp();
	encode_server_capabilities(&out, "0.0.0");
	assert(out.str_view().contains(`"codeActionProvider":{"codeActionKinds":["quickfix"]}`), "got: %s", out.str_view());
}
