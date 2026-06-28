module lsp;

import std::core::dstring;
import std::core::mem;
import std::io::file;
import std::io::path;

fn String get_test_stdlib_path() {
	// Candidate paths for standard library
	String[3] candidates = {
		"H:/scoop/apps/c3/0.8.1/lib/std",
		"C:/scoop/apps/c3/current/lib/std",
		"H:/scoop/apps/c3/current/lib/std"
	};
	foreach (c : candidates) {
		if (try pp = path::tnew(c)) {
			if (try el = path::ls(mem, pp)) {
				foreach (&e : el) e.free(mem);
				el.free();
				return c;
			}
		}
	}
	return "";
}

fn void test_stdlib_completion_import_std() @test {
	String stdlib_path = get_test_stdlib_path();
	if (stdlib_path.len == 0) {
		io::printfn("Warning: stdlib path not found, skipping test");
		return;
	}

	DString out = dstring::temp();
	DocumentList* docs = mem::new(DocumentList);
	defer mem::free(docs);

	// Test importing std and asking for completions right after std::
	String content = "import std::";
	encode_completions("file:///main.c3", content, content.len, docs, stdlib_path, &out);
	String result = out.str_view();

	io::printfn("Result for std:: completion:\n%s", result);
	// It should contain labels like "io", "collections", "core", "math", etc.
	assert(result.contains(`"label":"io"`), "expected 'io' in completions");
	assert(result.contains(`"label":"collections"`), "expected 'collections' in completions");
}

fn void test_stdlib_completion_std_io_methods() @test {
	String stdlib_path = get_test_stdlib_path();
	if (stdlib_path.len == 0) {
		io::printfn("Warning: stdlib path not found, skipping test");
		return;
	}

	DString out = dstring::temp();
	DocumentList* docs = mem::new(DocumentList);
	defer mem::free(docs);

	// Test completions for std::io::
	String content = "import std::io;\nfn void main() { std::io::";
	encode_completions("file:///main.c3", content, content.len, docs, stdlib_path, &out);
	String result = out.str_view();

	io::printfn("Result for std::io:: completion:\n%s", result);
	// It should contain functions in std::io like "print", "printf", "printfn", "sprintf", etc.
	assert(result.contains(`"label":"printfn"`), "expected 'printfn' in completions");
}
