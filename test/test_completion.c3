module lsp;

import std::core::dstring;
import std::core::mem;
import std::io::file;
import std::io::path;

fn void test_completion_empty_prefix() @test {
	DString out = dstring::temp();
	DocumentList* docs = mem::new(DocumentList);
	defer mem::free(docs);
	encode_completions("", "fn x() {}", 0, docs, "", &out);
	String result = out.str_view();
	assert(result.contains(`"isIncomplete":false`), "got: %s", result);
	assert(result.contains(`"items":[`));
}

fn void test_completion_keyword_prefix() @test {
	DString out = dstring::temp();
	DocumentList* docs = mem::new(DocumentList);
	defer mem::free(docs);
	// "whi" at offset 3 — should match "while"
	encode_completions("", "whi", 3, docs, "", &out);
	String result = out.str_view();
	assert(result.contains(`"label":"while"`), "got: %s", result);
}

fn void test_completion_type_prefix() @test {
	DString out = dstring::temp();
	DocumentList* docs = mem::new(DocumentList);
	defer mem::free(docs);
	// "in" at offset 2 — should match "int", "int128", "inline", "interface", "import"
	encode_completions("", "in", 2, docs, "", &out);
	String result = out.str_view();
	assert(result.contains(`"label":"int"`), "got: %s", result);
}

fn void test_completion_ct_prefix() @test {
	DString out = dstring::temp();
	DocumentList* docs = mem::new(DocumentList);
	defer mem::free(docs);
	// "$si" at offset 3 — should match "$sizeof"
	encode_completions("", "$si", 3, docs, "", &out);
	String result = out.str_view();
	assert(result.contains(`"label":"$sizeof"`), "got: %s", result);
	// Should not include regular keywords when prefix starts with $
	assert(!result.contains(`"label":"if"`), "got: %s", result);
}

fn void test_completion_doc_identifiers() @test {
	DString out = dstring::temp();
	DocumentList* docs = mem::new(DocumentList);
	defer mem::free(docs);
	// "fn hello() {}\nfn world() {}\nhel" — at offset after "hel"
	String content = "fn hello() {}\nfn world() {}\nhel";
	encode_completions("", content, content.len, docs, "", &out);
	String result = out.str_view();
	assert(result.contains(`"label":"hello"`), "got: %s", result);
}

fn void test_completion_no_duplicate_doc_idents() @test {
	DString out = dstring::temp();
	DocumentList* docs = mem::new(DocumentList);
	defer mem::free(docs);
	// Same identifier appears twice; should only appear once in completions
	String content = "fn x() { foo(); foo(); }\nfo";
	encode_completions("", content, content.len, docs, "", &out);
	String result = out.str_view();
	// Count occurrences of "foo" — should be exactly one
	usz count = 0;
	sz pos = 0;
	while (pos < result.len) {
		if (try idx = result[pos..].index_of(`"label":"foo"`)) {
			count++;
			pos = pos + idx + 1;
		} else {
			break;
		}
	}
	assert(count == 1, "Expected 1 occurrence of foo, got %d", count);
}

fn void test_completion_struct_json() @test {
	DString out = dstring::temp();
	DocumentList* docs = mem::new(DocumentList);
	defer mem::free(docs);
	encode_completions("", "str", 3, docs, "", &out);
	String result = out.str_view();
	// Should have "struct" as keyword and be valid JSON structure
	assert(result.contains(`"label":"struct"`), "got: %s", result);
	assert(result.contains(`"kind":14`), "got: %s", result); // Keyword kind
}

// --- DOT completion tests ---

fn void test_completion_dot_struct_fields() @test {
	DString out = dstring::temp();
	DocumentList* docs = mem::new(DocumentList);
	defer mem::free(docs);
	String content = "struct Foo { int x; String name; }\nfn void test() { Foo f; f.";
	encode_completions("", content, content.len, docs, "", &out);
	String result = out.str_view();
	assert(result.contains(`"label":"x"`), "expected field x, got: %s", result);
	assert(result.contains(`"label":"name"`), "expected field name, got: %s", result);
	assert(result.contains(`"kind":5`), "expected Field kind=5, got: %s", result);
	// Should NOT contain keywords
	assert(!result.contains(`"label":"while"`), "should not have keywords in dot context, got: %s", result);
}

fn void test_completion_dot_methods() @test {
	DString out = dstring::temp();
	DocumentList* docs = mem::new(DocumentList);
	defer mem::free(docs);
	String content = "struct Foo { int x; }\nfn int Foo.get_x(&self) { return self.x; }\nfn void test() { Foo f; f.";
	encode_completions("", content, content.len, docs, "", &out);
	String result = out.str_view();
	assert(result.contains(`"label":"get_x"`), "expected method get_x, got: %s", result);
	assert(result.contains(`"kind":2`), "expected Method kind=2, got: %s", result);
}

fn void test_completion_dot_partial_prefix() @test {
	DString out = dstring::temp();
	DocumentList* docs = mem::new(DocumentList);
	defer mem::free(docs);
	String content = "struct Foo { int x; String name; }\nfn int Foo.get_x(&self) { return self.x; }\nfn void test() { Foo f; f.ge";
	encode_completions("", content, content.len, docs, "", &out);
	String result = out.str_view();
	assert(result.contains(`"label":"get_x"`), "expected method get_x with partial prefix, got: %s", result);
	// "x" and "name" should NOT appear (don't start with "ge")
	assert(!result.contains(`"label":"x"`), "field x should be filtered out by prefix, got: %s", result);
	assert(!result.contains(`"label":"name"`), "field name should be filtered out by prefix, got: %s", result);
}

fn void test_completion_dot_pointer_type() @test {
	DString out = dstring::temp();
	DocumentList* docs = mem::new(DocumentList);
	defer mem::free(docs);
	String content = "struct Foo { int value; }\nfn void test() { Foo* ptr; ptr.";
	encode_completions("", content, content.len, docs, "", &out);
	String result = out.str_view();
	assert(result.contains(`"label":"value"`), "expected field value for pointer type, got: %s", result);
}

fn void test_completion_dot_no_keywords() @test {
	DString out = dstring::temp();
	DocumentList* docs = mem::new(DocumentList);
	defer mem::free(docs);
	String content = "struct Foo { int x; }\nfn void test() { Foo f; f.";
	encode_completions("", content, content.len, docs, "", &out);
	String result = out.str_view();
	// DOT context should never contain keywords or builtin types
	assert(!result.contains(`"label":"while"`), "no keywords in dot completion");
	assert(!result.contains(`"label":"int"`), "no builtin types in dot completion");
	assert(!result.contains(`"label":"$sizeof"`), "no CT keywords in dot completion");
}

fn void test_completion_dot_after_fluent_chain() @test {
	DString out = dstring::temp();
	DocumentList* docs = mem::new(DocumentList);
	defer mem::free(docs);
	// Completion after a `.` that follows a chained method call: the receiver
	// `builder().setX(1)` must resolve to Builder so its methods are offered.
	String content =
		"struct Builder { int x; }\n"
		"fn Builder builder() { Builder b; return b; }\n"
		"fn Builder Builder.setX(&self, int v) { return *self; }\n"
		"fn int Builder.fin(&self) { return 0; }\n"
		"fn void test() { builder().setX(1).";
	encode_completions("", content, content.len, docs, "", &out);
	String result = out.str_view();
	assert(result.contains(`"label":"setX"`), "expected method setX after chain, got: %s", result);
	assert(result.contains(`"label":"fin"`), "expected method fin after chain, got: %s", result);
}

fn void test_completion_dot_cross_file() @test {
	DString out = dstring::temp();
	DocumentList* docs = mem::new(DocumentList);
	defer mem::free(docs);

	// Struct defined in another open document
	String other_content = "struct Bar { int count; String label; }\nfn void Bar.reset(&self) {}";
	docs.open("file:///other.c3", other_content, 1);

	String content = "fn void test() { Bar b; b.";
	encode_completions("file:///main.c3", content, content.len, docs, "", &out);
	String result = out.str_view();
	docs.close("file:///other.c3");
	assert(result.contains(`"label":"count"`), "expected cross-file field count, got: %s", result);
	assert(result.contains(`"label":"label"`), "expected cross-file field label, got: %s", result);
	assert(result.contains(`"label":"reset"`), "expected cross-file method reset, got: %s", result);
}

fn void test_completion_dot_field_detail() @test {
	DString out = dstring::temp();
	DocumentList* docs = mem::new(DocumentList);
	defer mem::free(docs);
	String content = "struct Foo { String name; }\nfn void test() { Foo f; f.";
	encode_completions("", content, content.len, docs, "", &out);
	String result = out.str_view();
	// Field should have its type as detail
	assert(result.contains(`"detail":"String"`), "expected detail with type String, got: %s", result);
}

fn void test_completion_parse_imports() @test {
	String[MAX_IMPORTS] imports;
	String content = "module lsp;\n\nimport std::io;\nimport c3::lexer;\nimport args;\n\nfn void main() {}";
	sz count = parse_imports(content, &imports);
	assert(count == 3, "expected 3 imports, got %d", count);

	bool found_io = false;
	bool found_lexer = false;
	bool found_args = false;
	for (sz i = 0; i < count; i++)
	{
		if (imports[i] == "std::io") found_io = true;
		if (imports[i] == "c3::lexer") found_lexer = true;
		if (imports[i] == "args") found_args = true;
	}
	assert(found_io, "expected std::io import");
	assert(found_lexer, "expected c3::lexer import");
	assert(found_args, "expected args import");
}

fn void test_completion_module_to_dir() @test {
	DString buf = dstring::temp();
	String result = module_to_dir_path("std::io", &buf);
	assert(result == "std/io", "expected std/io, got: %s", result);

	buf = dstring::temp();
	result = module_to_dir_path("std::collections::list", &buf);
	assert(result == "std/collections/list", "expected std/collections/list, got: %s", result);

	buf = dstring::temp();
	result = module_to_dir_path("args", &buf);
	assert(result == "args", "expected args, got: %s", result);
}

fn void test_completion_cross_file_type() @test {
	DString out = dstring::temp();
	DocumentList* docs = mem::new(DocumentList);
	defer mem::free(docs);

	// Simulate another open file with a type
	String other = "struct TokenStream { TokenList tokens; }";
	docs.open("file:///stream.c3", other, 1);

	// Current file typing "Token" should find TokenStream from open doc
	String content = "module lsp;\nfn void main() { Token";
	encode_completions("file:///main.c3", content, content.len, docs, "", &out);
	String result = out.str_view();
	docs.close("file:///stream.c3");
	assert(result.contains(`"label":"TokenStream"`), "expected TokenStream from open doc, got: %s", result);
}

fn void test_completion_module_scope() @test {
	DString out = dstring::temp();
	DocumentList* docs = mem::new(DocumentList);
	defer mem::free(docs);

	// Simulate an open file from the "args" module
	String args_content = "module args;\nfn void help() {}\nfn void handle_input() {}\nstruct Config { int verbose; }";
	docs.open("file:///args.c3", args_content, 1);

	// Also have an open file from another module with similar names
	String other_content = "module parser;\nfn void highlight() {}\nfn void handle_token() {}";
	docs.open("file:///parser.c3", other_content, 1);

	// Type "args::h" — should only see args module identifiers starting with h
	String content = "module lsp;\nimport args;\nfn void main() { args::h";
	encode_completions("file:///main.c3", content, content.len, docs, "", &out);
	String result = out.str_view();
	docs.close("file:///args.c3");
	docs.close("file:///parser.c3");

	assert(result.contains(`"label":"help"`), "expected help from args module, got: %s", result);
	assert(result.contains(`"label":"handle_input"`), "expected handle_input from args module, got: %s", result);
	// Should NOT contain identifiers from parser module
	assert(!result.contains(`"label":"highlight"`), "should not have parser::highlight, got: %s", result);
	assert(!result.contains(`"label":"handle_token"`), "should not have parser::handle_token, got: %s", result);
	// Should NOT contain keywords
	assert(!result.contains(`"label":"while"`), "should not have keywords in scope context, got: %s", result);
}

fn void test_completion_module_scope_no_prefix() @test {
	DString out = dstring::temp();
	DocumentList* docs = mem::new(DocumentList);
	defer mem::free(docs);

	String args_content = "module args;\nfn void help() {}\nstruct Config { int verbose; }";
	docs.open("file:///args.c3", args_content, 1);

	// Type "args::" with no prefix — should see all args identifiers
	String content = "module lsp;\nimport args;\nfn void main() { args::";
	encode_completions("file:///main.c3", content, content.len, docs, "", &out);
	String result = out.str_view();
	docs.close("file:///args.c3");

	assert(result.contains(`"label":"help"`), "expected help, got: %s", result);
	assert(result.contains(`"label":"Config"`), "expected Config, got: %s", result);
}

fn void test_completion_module_scope_short_name() @test {
	DString out = dstring::temp();
	DocumentList* docs = mem::new(DocumentList);
	defer mem::free(docs);

	// File declares "module std::os::process;" but user types "process::c"
	String process_content = "module std::os::process;\nfn SubProcess create(String[] cmd) {}\nfn void cleanup() {}";
	docs.open("file:///process.c3", process_content, 1);

	// import std::os::process; then type process::c
	String content = "module lsp;\nimport std::os::process;\nfn void main() { process::c";
	encode_completions("file:///main.c3", content, content.len, docs, "", &out);
	String result = out.str_view();
	docs.close("file:///process.c3");

	assert(result.contains(`"label":"create"`), "expected create from process module via short name, got: %s", result);
	assert(result.contains(`"label":"cleanup"`), "expected cleanup from process module via short name, got: %s", result);
	// Functions should have kind=3 (Function), not kind=6 (Variable)
	assert(result.contains(`"kind":3`), "expected Function kind=3, got: %s", result);
}

fn void test_completion_module_scope_declaration_kinds() @test {
	DString out = dstring::temp();
	DocumentList* docs = mem::new(DocumentList);
	defer mem::free(docs);

	String mod_content = "module mymod;\nfn void do_thing() {}\nstruct Config { int x; }\nenum Color { RED, GREEN }\nconst int MAX_SIZE = 100;\nmacro @helper() {}";
	docs.open("file:///mymod.c3", mod_content, 1);

	String content = "module lsp;\nimport mymod;\nfn void main() { mymod::";
	encode_completions("file:///main.c3", content, content.len, docs, "", &out);
	String result = out.str_view();
	docs.close("file:///mymod.c3");

	// Should see declarations with correct kinds
	assert(result.contains(`"label":"do_thing"`), "expected do_thing function, got: %s", result);
	assert(result.contains(`"label":"Config"`), "expected Config struct, got: %s", result);
	assert(result.contains(`"label":"Color"`), "expected Color enum, got: %s", result);
	assert(result.contains(`"label":"MAX_SIZE"`), "expected MAX_SIZE constant, got: %s", result);

	// Should NOT contain local identifiers like "x" (struct field) or "RED" (enum member)
	assert(!result.contains(`"label":"x"`), "should not have struct field x, got: %s", result);

	// Check kinds: 3=Function, 22=Struct, 13=Enum, 21=Constant
	assert(result.contains(`"kind":3`), "expected Function kind, got: %s", result);
	assert(result.contains(`"kind":22`), "expected Struct kind, got: %s", result);
	assert(result.contains(`"kind":13`), "expected Enum kind, got: %s", result);
	assert(result.contains(`"kind":21`), "expected Constant kind, got: %s", result);
}

// Function/method completions insert a "name($0)" snippet and trigger the parameter-hints
// popup; non-callable items (structs, constants) keep plain-text insertion.
fn void test_completion_function_snippet_and_signature_help() @test {
	DString out = dstring::temp();
	DocumentList* docs = mem::new(DocumentList);
	defer mem::free(docs);

	String mod_content = "module mymod;\nfn void do_thing() {}\nstruct Config { int x; }";
	docs.open("file:///mymod.c3", mod_content, 1);

	String content = "module lsp;\nimport mymod;\nfn void main() { mymod::";
	encode_completions("file:///main.c3", content, content.len, docs, "", &out);
	String result = out.str_view();
	docs.close("file:///mymod.c3");

	// The function item carries a snippet insert + signature-help command.
	assert(result.contains(`"insertText":"do_thing($0)"`), "expected do_thing snippet insert, got: %s", result);
	assert(result.contains(`"textEditText":"do_thing($0)"`), "expected do_thing textEditText (honored under itemDefaults.editRange), got: %s", result);
	assert(result.contains(`"insertTextFormat":2`), "expected Snippet insertTextFormat=2, got: %s", result);
	assert(result.contains(`"command":{"title":"Trigger Parameter Hints","command":"editor.action.triggerParameterHints"}`),
		"expected triggerParameterHints command, got: %s", result);

	// The struct item must NOT get a snippet/insertText/command.
	assert(!result.contains(`"insertText":"Config($0)"`), "struct should not get call snippet, got: %s", result);
}

// A function declared in the SAME file (default identifier context, not module-scope or
// dot) must also complete as a callable with the snippet + parameter-hints command.
fn void test_completion_local_function_snippet() @test {
	DString out = dstring::temp();
	DocumentList* docs = mem::new(DocumentList);
	defer mem::free(docs);

	String content = "module app;\nfn void test_named_default(int times = 1) {}\nint counter = 0;\nfn void main() { test_na";
	encode_completions("file:///app.c3", content, content.len, docs, "", &out);
	String result = out.str_view();

	assert(result.contains(`"insertText":"test_named_default($0)"`), "expected local function snippet, got: %s", result);
	assert(result.contains(`"textEditText":"test_named_default($0)"`), "expected local function textEditText, got: %s", result);
	assert(result.contains(`"insertTextFormat":2`), "expected Snippet insertTextFormat=2, got: %s", result);
	assert(result.contains(`"command":{"title":"Trigger Parameter Hints","command":"editor.action.triggerParameterHints"}`),
		"expected triggerParameterHints command, got: %s", result);
}

// Regression: a single file declaring multiple modules, where the requested module is
// NOT the file's first module (mirrors std/io/file.c3: `module std::io;` then
// `module std::io::file;`). Completion must scan past the first module and only emit
// declarations from the matching section.
fn void test_completion_module_scope_multi_module_file() @test {
	DString out = dstring::temp();
	DocumentList* docs = mem::new(DocumentList);
	defer mem::free(docs);

	String file_content = "module std::io;\nstruct File { int handle; }\nfn void io_only() {}\nmodule std::io::file;\nfn void load() {}\nfn void load_buffer() {}";
	docs.open("file:///file.c3", file_content, 1);

	// import std::io::file; then type file::l
	String content = "module lsp;\nimport std::io::file;\nfn void main() { file::l";
	encode_completions("file:///main.c3", content, content.len, docs, "", &out);
	String result = out.str_view();
	docs.close("file:///file.c3");

	assert(result.contains(`"label":"load"`), "expected load from std::io::file, got: %s", result);
	assert(result.contains(`"label":"load_buffer"`), "expected load_buffer from std::io::file, got: %s", result);
	// Must NOT leak declarations from the file's first module (std::io)
	assert(!result.contains(`"label":"File"`), "should not surface std::io::File under file::, got: %s", result);
	assert(!result.contains(`"label":"io_only"`), "should not surface std::io::io_only under file::, got: %s", result);
}

// Companion to the above: the first module in the same multi-module file resolves too,
// and does not leak the second module's declarations.
fn void test_completion_module_scope_multi_module_first() @test {
	DString out = dstring::temp();
	DocumentList* docs = mem::new(DocumentList);
	defer mem::free(docs);

	String file_content = "module std::io;\nstruct File { int handle; }\nfn void io_only() {}\nmodule std::io::file;\nfn void load() {}";
	docs.open("file:///file.c3", file_content, 1);

	// import std::io; then type io::
	String content = "module lsp;\nimport std::io;\nfn void main() { io::";
	encode_completions("file:///main.c3", content, content.len, docs, "", &out);
	String result = out.str_view();
	docs.close("file:///file.c3");

	assert(result.contains(`"label":"File"`), "expected File from std::io, got: %s", result);
	assert(result.contains(`"label":"io_only"`), "expected io_only from std::io, got: %s", result);
	// Must NOT surface the sub-module's declarations under io::
	assert(!result.contains(`"label":"load"`), "should not surface std::io::file::load under io::, got: %s", result);
}

fn void test_completion_dot_real_handler_code() @test {
	DString out = dstring::temp();
	DocumentList* docs = mem::new(DocumentList);
	defer mem::free(docs);

	// Document struct in another file
	String docs_content = "struct Document { String uri; String content; int version; }";
	docs.open("file:///documents.c3", docs_content, 1);

	// Realistic handler code — exact pattern from handlers.c3
	String content = `fn void LspServer.handle_definition(&self, Object* msg, String id_json)
{
	Object* td = msg.get("params")!!.get("textDocument")!!;
	String uri = td.get_string("uri") ?? "";

	Document* doc = self.documents.find(uri);

	if (doc == null)
	{
		send_response(id_json, "null");
		return;
	}

	doc.`;
	encode_completions("file:///handler.c3", content, content.len, docs, "", &out);
	String result = out.str_view();
	docs.close("file:///documents.c3");

	assert(result.contains(`"label":"uri"`), "expected uri field from Document in handler, got: %s", result);
	assert(result.contains(`"label":"content"`), "expected content field from Document in handler, got: %s", result);
}

fn void test_completion_dot_real_handlers_file() @test {
	// Load the actual handlers.c3 and simulate typing doc. after find(uri)
	if (try file_data = file::load(mem, "src/server/handlers.c3"))
	{
		defer mem::free(file_data);
		String file_content = (String)file_data;

		// Find "Document* doc = self.documents.find(uri);" and insert "doc." after the block
		sz insert_pos = 0;
		if (try idx = file_content.index_of("Document*? doc = self.documents.find(uri);"))
		{
			// Find the next newline after the declaration
			for (sz i = idx; i < file_content.len; i++)
			{
				if (file_content[i] == '\n')
				{
					insert_pos = i + 1;
					break;
				}
			}
		}
		assert(insert_pos > 0, "couldn't find doc declaration in handlers.c3");

		// Build content with "doc." inserted
		DString modified = dstring::temp();
		modified.append(file_content[:insert_pos]);
		modified.append("\tdoc.");
		sz cursor_offset = modified.len();
		modified.append(file_content[insert_pos..]);

		// Open documents.c3 so Document struct is found
		DocumentList* docs = mem::new(DocumentList);
		defer mem::free(docs);
		if (try docs_data = file::load(mem, "src/server/documents.c3"))
		{
			defer mem::free(docs_data);
			docs.open("file:///src/server/documents.c3", (String)docs_data, 1);
		}

		DString out = dstring::temp();
		encode_completions("file:///src/server/handlers.c3", modified.str_view(), cursor_offset, docs, "", &out);
		String result = out.str_view();
		docs.close("file:///src/server/documents.c3");

		assert(result.contains(`"label":"uri"`), "expected uri field, got: %s", result);
		assert(result.contains(`"label":"content"`), "expected content field, got: %s", result);
		assert(result.contains(`"label":"version"`), "expected version field, got: %s", result);
	}
	else
	{
		assert(false, "couldn't load src/server/handlers.c3");
	}
}

fn void test_completion_dot_pointer_from_other_file() @test {
	DString out = dstring::temp();
	DocumentList* docs = mem::new(DocumentList);
	defer mem::free(docs);

	// Document struct defined in another file
	String docs_content = "struct Document { String uri; String content; int version; }\nfn Document* DocumentList.find(&self, String uri) { return null; }";
	docs.open("file:///documents.c3", docs_content, 1);

	// Handler code with Document* doc = ...; doc.
	String content = "fn void test() { Document* doc = something(); doc.";
	encode_completions("file:///handler.c3", content, content.len, docs, "", &out);
	String result = out.str_view();
	docs.close("file:///documents.c3");

	assert(result.contains(`"label":"uri"`), "expected uri field from Document, got: %s", result);
	assert(result.contains(`"label":"content"`), "expected content field from Document, got: %s", result);
	assert(result.contains(`"label":"version"`), "expected version field from Document, got: %s", result);
}

fn void test_completion_dot_self_field_method() @test {
	DString out = dstring::temp();
	DocumentList* docs = mem::new(DocumentList);
	defer mem::free(docs);

	// DocumentList with methods in another file
	String docs_content = "alias DocumentList = List{Document};\nfn void DocumentList.open(&self, String uri, String content, int version) {}\nfn void DocumentList.close(&self, String uri) {}";
	docs.open("file:///documents.c3", docs_content, 1);

	// Server struct with documents field
	String server_content = "struct LspServer { DocumentList documents; String stdlib_path; }";
	docs.open("file:///server.c3", server_content, 1);

	// self.documents. should show DocumentList methods
	String content = "fn void LspServer.test(&self) { self.documents.";
	encode_completions("file:///handler.c3", content, content.len, docs, "", &out);
	String result = out.str_view();
	docs.close("file:///documents.c3");
	docs.close("file:///server.c3");

	assert(result.contains(`"label":"open"`), "expected open method from DocumentList, got: %s", result);
	assert(result.contains(`"label":"close"`), "expected close method from DocumentList, got: %s", result);
}

// --- editRange (itemDefaults) tests ---

fn void test_completion_edit_range_ct_prefix() @test {
	DString out = dstring::temp();
	DocumentList* docs = mem::new(DocumentList);
	defer mem::free(docs);
	// "$str" at offset 4 — editRange must cover the whole "$str" (incl. the $),
	// otherwise accepting "$stringify" yields "$$stringify".
	encode_completions("", "$str", 4, docs, "", &out);
	String result = out.str_view();
	assert(result.contains(`"label":"$stringify"`), "got: %s", result);
	assert(result.contains(`"itemDefaults":{"editRange":{"insert":{"start":{"line":0,"character":0},"end":{"line":0,"character":4}},"replace":{"start":{"line":0,"character":0},"end":{"line":0,"character":4}}}}`), "got: %s", result);
}

fn void test_completion_edit_range_later_line() @test {
	DString out = dstring::temp();
	DocumentList* docs = mem::new(DocumentList);
	defer mem::free(docs);
	String content = "fn x() {}\n$str";
	encode_completions("", content, content.len, docs, "", &out);
	String result = out.str_view();
	assert(result.contains(`"itemDefaults":{"editRange":{"insert":{"start":{"line":1,"character":0},"end":{"line":1,"character":4}},"replace":{"start":{"line":1,"character":0},"end":{"line":1,"character":4}}}}`), "got: %s", result);
}

fn void test_completion_edit_range_dot_partial() @test {
	DString out = dstring::temp();
	DocumentList* docs = mem::new(DocumentList);
	defer mem::free(docs);
	// "f.ge" — editRange covers only the partial "ge" (chars 27..29), not the receiver.
	String content = "struct Foo { int x; }\nFoo f; f.ge";
	encode_completions("", content, content.len, docs, "", &out);
	String result = out.str_view();
	assert(result.contains(`"itemDefaults":{"editRange":{"insert":{"start":{"line":1,"character":9},"end":{"line":1,"character":11}},"replace":{"start":{"line":1,"character":9},"end":{"line":1,"character":11}}}}`), "got: %s", result);
}

// --- enum-member completion tests ---

fn void test_completion_enum_members() @test {
	DString out = dstring::temp();
	DocumentList* docs = mem::new(DocumentList);
	defer mem::free(docs);
	String content = "enum Color { RED, GREEN, BLUE }\nfn void t() { Color.";
	encode_completions("", content, content.len, docs, "", &out);
	String result = out.str_view();
	assert(result.contains(`"label":"RED"`), "expected RED, got: %s", result);
	assert(result.contains(`"label":"GREEN"`), "expected GREEN, got: %s", result);
	assert(result.contains(`"label":"BLUE"`), "expected BLUE, got: %s", result);
	assert(result.contains(`"kind":20`), "expected EnumMember kind=20, got: %s", result);
}

fn void test_completion_enum_members_prefix() @test {
	DString out = dstring::temp();
	DocumentList* docs = mem::new(DocumentList);
	defer mem::free(docs);
	String content = "enum Color { RED, GREEN, BLUE }\nfn void t() { Color.RE";
	encode_completions("", content, content.len, docs, "", &out);
	String result = out.str_view();
	assert(result.contains(`"label":"RED"`), "expected RED, got: %s", result);
	assert(!result.contains(`"label":"GREEN"`), "GREEN should be filtered by prefix, got: %s", result);
	assert(!result.contains(`"label":"BLUE"`), "BLUE should be filtered by prefix, got: %s", result);
}

fn void test_completion_enum_members_assoc_values() @test {
	DString out = dstring::temp();
	DocumentList* docs = mem::new(DocumentList);
	defer mem::free(docs);
	// Associated-value initializers (= MAX) must not be suggested as members.
	String content = "const int MAX = 9;\nenum Level : int { LOW = 1, HIGH = MAX }\nfn void t() { Level.";
	encode_completions("", content, content.len, docs, "", &out);
	String result = out.str_view();
	assert(result.contains(`"label":"LOW"`), "expected LOW, got: %s", result);
	assert(result.contains(`"label":"HIGH"`), "expected HIGH, got: %s", result);
	assert(!result.contains(`"label":"MAX"`), "associated-value const MAX should not be a member, got: %s", result);
}

fn void test_completion_enum_members_no_leak() @test {
	DString out = dstring::temp();
	DocumentList* docs = mem::new(DocumentList);
	defer mem::free(docs);
	// Non-dot context with an enum in the file: members must NOT appear at top level.
	String content = "enum Color { RED, GREEN, BLUE }\nfn void t() { RE";
	encode_completions("", content, content.len, docs, "", &out);
	String result = out.str_view();
	// RED may still appear as a plain document identifier (kind 21), but never as an
	// EnumMember (kind 20) — enum members are only emitted in dot context.
	assert(!result.contains(`"kind":20`), "enum members should not leak into non-dot completion, got: %s", result);
}

// A lone ':' (not '::') must still produce a VALID (empty) completion list, never an
// empty buffer — an empty buffer becomes `"result":` (invalid JSON) and kills the client.
fn void test_completion_lone_colon_valid_json() @test {
	DString out = dstring::temp();
	DocumentList* docs = mem::new(DocumentList);
	defer mem::free(docs);
	// Cursor right after a single ':' in a case label.
	String content = "fn void t() { switch (x) { case 1:";
	encode_completions("", content, content.len, docs, "", &out);
	String result = out.str_view();
	assert(result.len > 0, "must emit a valid JSON body, not empty");
	assert(result.contains(`"items":[]`), "expected empty items list, got: %s", result);
}

// Single-character prefix on dot completion still filters fields correctly.
fn void test_completion_dot_single_char_prefix() @test {
	DString out = dstring::temp();
	DocumentList* docs = mem::new(DocumentList);
	defer mem::free(docs);
	String content = "struct Foo { int x; String name; }\nfn void test() { Foo f; f.x";
	encode_completions("", content, content.len, docs, "", &out);
	String result = out.str_view();
	assert(result.contains(`"label":"x"`), "expected field x, got: %s", result);
	assert(!result.contains(`"label":"name"`), "field name should be filtered by prefix 'x', got: %s", result);
}

// Module-scope completion offers types but not methods or interface methods.
fn void test_completion_module_scope_skips_methods() @test {
	DString out = dstring::temp();
	DocumentList* docs = mem::new(DocumentList);
	defer mem::free(docs);

	String mod_content = "module mymod;\nstruct Config {}\nfn void Config.my_method(&self) {}\ninterface InStream { fn void my_interface_method(); }";
	docs.open("file:///mymod.c3", mod_content, 1);

	String content = "module lsp;\nimport mymod;\nfn void main() { mymod::";
	encode_completions("file:///main.c3", content, content.len, docs, "", &out);
	String result = out.str_view();
	docs.close("file:///mymod.c3");

	assert(result.contains(`"label":"Config"`), "expected Config struct, got: %s", result);
	assert(!result.contains(`"label":"my_method"`), "method should not appear, got: %s", result);
	assert(!result.contains(`"label":"my_interface_method"`), "interface method should not appear, got: %s", result);
}

// Module-scope completion offers submodule names as Module items (kind 9).
fn void test_completion_submodule_scope() @test {
	DString out = dstring::temp();
	DocumentList* docs = mem::new(DocumentList);
	defer mem::free(docs);

	docs.open("file:///io.c3", "module myproj::io;\nfn void write() {}", 1);
	docs.open("file:///net.c3", "module myproj::net;\nfn void connect() {}", 1);

	String content = "import myproj;\nfn void main() { myproj::";
	encode_completions("file:///main.c3", content, content.len, docs, "", &out);
	String result = out.str_view();
	docs.close("file:///io.c3");
	docs.close("file:///net.c3");

	assert(result.contains(`"label":"io"`), "expected submodule io, got: %s", result);
	assert(result.contains(`"label":"net"`), "expected submodule net, got: %s", result);
	assert(result.contains(`"kind":9`), "expected Module kind 9, got: %s", result);
}

// A dot on a TYPE name suppresses instance fields/methods, but an enum type still
// offers its members.
fn void test_completion_dot_on_type_name() @test {
	DString out = dstring::temp();
	DocumentList* docs = mem::new(DocumentList);
	defer mem::free(docs);

	String mod_content = "module mymod;\nstruct Config { int val; }\nfn void Config.my_method(&self) {}\nenum Color { RED, GREEN }";
	docs.open("file:///mymod.c3", mod_content, 1);

	// Config. (a type name) — no instance field/method.
	String content1 = "module lsp;\nimport mymod;\nfn void main() { Config.";
	encode_completions("file:///main.c3", content1, content1.len, docs, "", &out);
	String result1 = out.str_view();
	assert(!result1.contains(`"label":"val"`), "field should not show on type receiver, got: %s", result1);
	assert(!result1.contains(`"label":"my_method"`), "method should not show on type receiver, got: %s", result1);

	// Color. (an enum type) — members are valid.
	out.clear();
	String content2 = "module lsp;\nimport mymod;\nfn void main() { Color.";
	encode_completions("file:///main.c3", content2, content2.len, docs, "", &out);
	String result2 = out.str_view();
	assert(result2.contains(`"label":"RED"`), "expected enum member RED on type receiver, got: %s", result2);

	docs.close("file:///mymod.c3");
}

// --- Struct-initializer field completion tests ---

// The compound-literal form from the bug report: LspServer server2 = (LspServer){ .init
fn void test_completion_initializer_compound_literal() @test {
	DString out = dstring::temp();
	DocumentList* docs = mem::new(DocumentList);
	defer mem::free(docs);
	String content = "struct LspServer { int initialize; int shutdown; }\nfn void t() { LspServer server2 = (LspServer){ .init";
	encode_completions("", content, content.len, docs, "", &out);
	String result = out.str_view();
	assert(result.contains(`"label":"initialize"`), "expected field initialize, got: %s", result);
	assert(result.contains(`"kind":5`), "expected Field kind=5, got: %s", result);
	assert(!result.contains(`"label":"shutdown"`), "shutdown filtered out by prefix, got: %s", result);
	assert(!result.contains(`"label":"while"`), "no keywords in initializer context, got: %s", result);
}

// Plain `Type var = { .` initializer — fields only, no methods.
fn void test_completion_initializer_decl_fields_only() @test {
	DString out = dstring::temp();
	DocumentList* docs = mem::new(DocumentList);
	defer mem::free(docs);
	String content = "struct Rectangle { int width; int height; }\nfn void Rectangle.draw(&self) {}\nfn void t() { Rectangle r = { .";
	encode_completions("", content, content.len, docs, "", &out);
	String result = out.str_view();
	assert(result.contains(`"label":"width"`), "expected field width, got: %s", result);
	assert(result.contains(`"label":"height"`), "expected field height, got: %s", result);
	assert(!result.contains(`"label":"draw"`), "methods are not valid in initializers, got: %s", result);
}

// After a comma, the next designator completes — and already-assigned fields are not re-offered.
fn void test_completion_initializer_after_comma() @test {
	DString out = dstring::temp();
	DocumentList* docs = mem::new(DocumentList);
	defer mem::free(docs);
	String content = "struct Rectangle { int width; int height; }\nfn void t() { Rectangle r = (Rectangle){ .width = 1, .";
	encode_completions("", content, content.len, docs, "", &out);
	String result = out.str_view();
	assert(result.contains(`"label":"height"`), "expected field height, got: %s", result);
	assert(!result.contains(`"label":"width"`), "width already assigned, got: %s", result);
}

// Nested designated initializer: the inner braces complete the field's own struct type.
fn void test_completion_initializer_nested() @test {
	DString out = dstring::temp();
	DocumentList* docs = mem::new(DocumentList);
	defer mem::free(docs);
	String content = "struct Inner { int deep_val; }\nstruct Outer { Inner inner; int flag; }\nfn void t() { Outer o = { .inner = { .de";
	encode_completions("", content, content.len, docs, "", &out);
	String result = out.str_view();
	assert(result.contains(`"label":"deep_val"`), "expected nested field deep_val, got: %s", result);
	assert(!result.contains(`"label":"flag"`), "outer field must not leak into nested initializer, got: %s", result);
}

// Struct defined in another open document is still found.
fn void test_completion_initializer_cross_file() @test {
	DString out = dstring::temp();
	DocumentList* docs = mem::new(DocumentList);
	defer mem::free(docs);
	docs.open("file:///other.c3", "module other;\nstruct Point { int px; int py; }", 1);
	String content = "module lsp;\nimport other;\nfn void t() { Point p = (Point){ .p";
	encode_completions("file:///main.c3", content, content.len, docs, "", &out);
	String result = out.str_view();
	assert(result.contains(`"label":"px"`), "expected cross-file field px, got: %s", result);
	assert(result.contains(`"label":"py"`), "expected cross-file field py, got: %s", result);
	docs.close("file:///other.c3");
}

// A dot after a comma in call arguments is not an initializer designator.
fn void test_completion_initializer_not_in_call_args() @test {
	DString out = dstring::temp();
	DocumentList* docs = mem::new(DocumentList);
	defer mem::free(docs);
	String content = "struct Foo { int x; }\nfn void call_me(int a, int b) {}\nfn void t() { call_me(1, .";
	encode_completions("", content, content.len, docs, "", &out);
	String result = out.str_view();
	assert(!result.contains(`"label":"x"`), "call args are not an initializer, got: %s", result);
}

// A dot at the start of a function body is not an initializer designator, even when
// the parameter list ends in a struct-typed parameter (`(Rectangle r) {` vs `(Rectangle){`).
fn void test_completion_initializer_not_function_body() @test {
	DString out = dstring::temp();
	DocumentList* docs = mem::new(DocumentList);
	defer mem::free(docs);
	String content = "struct Rectangle { int width; int height; }\nfn void handle(Rectangle r) { .";
	encode_completions("", content, content.len, docs, "", &out);
	String result = out.str_view();
	assert(!result.contains(`"label":"width"`), "function body brace is not an initializer, got: %s", result);
}

// --- Module-visibility tests for member completion ---

// A same-named type in a module this file does not import must not merge its
// members into the completion list (e.g. user Rectangle vs std::math Rectangle).
fn void test_completion_dot_invisible_module_not_merged() @test {
	DString out = dstring::temp();
	DocumentList* docs = mem::new(DocumentList);
	defer mem::free(docs);
	docs.open("file:///geom.c3", "module other::geom;\nunion Rectangle { int v; }", 1);
	String content = "module myapp;\nstruct Rectangle { int width; int height; }\nfn void t() { Rectangle r; r.";
	encode_completions("file:///main.c3", content, content.len, docs, "", &out);
	String result = out.str_view();
	assert(result.contains(`"label":"width"`), "expected own field width, got: %s", result);
	assert(result.contains(`"label":"height"`), "expected own field height, got: %s", result);
	assert(!result.contains(`"label":"v"`), "field from unimported module must not merge, got: %s", result);
	docs.close("file:///geom.c3");
}

// The same collision inside a struct initializer.
fn void test_completion_initializer_invisible_module_not_merged() @test {
	DString out = dstring::temp();
	DocumentList* docs = mem::new(DocumentList);
	defer mem::free(docs);
	docs.open("file:///geom.c3", "module other::geom;\nunion Rectangle { int v; }", 1);
	String content = "module myapp;\nstruct Rectangle { int width; int height; }\nfn void t() { Rectangle r = (Rectangle){ .";
	encode_completions("file:///main.c3", content, content.len, docs, "", &out);
	String result = out.str_view();
	assert(result.contains(`"label":"width"`), "expected own field width, got: %s", result);
	assert(!result.contains(`"label":"v"`), "initializer must not offer unimported module's field, got: %s", result);
	docs.close("file:///geom.c3");
}

// An imported module's type completes normally.
fn void test_completion_dot_imported_module_visible() @test {
	DString out = dstring::temp();
	DocumentList* docs = mem::new(DocumentList);
	defer mem::free(docs);
	docs.open("file:///geom.c3", "module other::geom;\nstruct Circle { int radius; }", 1);
	String content = "module myapp;\nimport other::geom;\nfn void t() { Circle c; c.";
	encode_completions("file:///main.c3", content, content.len, docs, "", &out);
	String result = out.str_view();
	assert(result.contains(`"label":"radius"`), "imported module's fields must complete, got: %s", result);
	docs.close("file:///geom.c3");
}

// Without the import, the members still complete via the module-blind fallback
// pass — a missing import must degrade to the old behavior, not to nothing.
fn void test_completion_dot_fallback_when_not_imported() @test {
	DString out = dstring::temp();
	DocumentList* docs = mem::new(DocumentList);
	defer mem::free(docs);
	docs.open("file:///geom.c3", "module other::geom;\nstruct Circle { int radius; }", 1);
	String content = "module myapp;\nfn void t() { Circle c; c.";
	encode_completions("file:///main.c3", content, content.len, docs, "", &out);
	String result = out.str_view();
	assert(result.contains(`"label":"radius"`), "fallback pass must still find the only candidate, got: %s", result);
	docs.close("file:///geom.c3");
}
