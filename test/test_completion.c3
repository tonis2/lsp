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
		if (try idx = file_content.index_of("Document* doc = self.documents.find(uri);"))
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
