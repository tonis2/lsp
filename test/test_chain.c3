module lsp;
import std::core::dstring;
import std::core::mem;
import std::io::file;

fn void test_chain_same_file() @test {
    String content = `struct Foo { Bar bar; }
struct Bar { int baz; }
fn void test() {
    Foo foo;
    foo.bar.baz = 1;
}`;
    TokenStream stream = token_stream_tokenize(content);
    defer stream.free();

    sz baz_idx = 0;
    for (sz i = 0; i < stream.tokens.size; i++) {
        if (stream.tokens.entries[i].text == "baz" && i > 0 && stream.tokens.entries[i - 1].type == DOT) {
            baz_idx = i;
            break;
        }
    }
    DocumentList* docs = mem::new(DocumentList);
    defer mem::free(docs);
    String recv_type = stream.tokens.resolve_receiver_type(baz_idx, "file:///test.c3", docs);
    assert(recv_type == "Bar", "expected Bar, got: '%s'", recv_type);
}

fn void test_chain_cross_file() @test {
    String current = `fn void test() { Foo foo; foo.bar.baz = 1; }`;
    String other = `struct Foo { Bar bar; }
struct Bar { int baz; }`;
    TokenStream stream = token_stream_tokenize(current);
    defer stream.free();

    sz baz_idx = 0;
    for (sz i = 0; i < stream.tokens.size; i++) {
        if (stream.tokens.entries[i].text == "baz" && i > 0 && stream.tokens.entries[i - 1].type == DOT) {
            baz_idx = i;
            break;
        }
    }
    DocumentList* docs = mem::new(DocumentList);
    defer mem::free(docs);
    docs.open("file:///other.c3", other, 1);
    String recv_type = stream.tokens.resolve_receiver_type(baz_idx, "file:///test.c3", docs);
    assert(recv_type == "Bar", "expected Bar, got: '%s'", recv_type);
    docs.close("file:///other.c3");
}

fn void test_definition_struct_field() @test {
    DString out = dstring::temp();
    DocumentList* docs = mem::new(DocumentList);
    defer mem::free(docs);
    String content = "struct MyStruct { int value; }\nfn void test() {\n\tMyStruct s;\n\ts.value = 42;\n}";
    TokenStream stream = token_stream_tokenize(content);
    sz value_offset = 0;
    for (sz i = stream.tokens.size; i > 0; i--) {
        if (stream.tokens.entries[i - 1].text == "value" && i >= 2 && stream.tokens.entries[i - 2].type == DOT) {
            value_offset = stream.tokens.entries[i - 1].offset;
            break;
        }
    }
    stream.free();
    encode_definition("file:///test.c3", content, value_offset, docs, "", &out);
    String result = out.str_view();
    assert(result.len > 0, "expected definition for struct field");
    assert(result.contains(`"line":0`), "expected line 0, got: %s", result);
}

fn void test_definition_self_method() @test {
    DString out = dstring::temp();
    DocumentList* docs = mem::new(DocumentList);
    defer mem::free(docs);
    String content = "struct Foo { int x; }\nfn int Foo.get_x(&self) { return self.x; }\nfn void Foo.do_thing(&self) { self.get_x(); }";
    TokenStream stream = token_stream_tokenize(content);
    sz offset = 0;
    for (sz i = stream.tokens.size; i > 0; i--) {
        if (stream.tokens.entries[i - 1].text == "get_x" && i >= 2 && stream.tokens.entries[i - 2].type == DOT) {
            offset = stream.tokens.entries[i - 1].offset;
            break;
        }
    }
    stream.free();
    encode_definition("file:///test.c3", content, offset, docs, "", &out);
    String result = out.str_view();
    assert(result.len > 0, "expected definition for self.get_x()");
    assert(result.contains(`"line":1`), "expected line 1, got: %s", result);
}

fn void test_hover_struct_field() @test {
    DString out = dstring::temp();
    DocumentList* docs = mem::new(DocumentList);
    defer mem::free(docs);
    String content = "struct MyStruct { int value; }\nfn void test() {\n\tMyStruct s;\n\ts.value = 42;\n}";
    TokenStream stream = token_stream_tokenize(content);
    sz offset = 0;
    for (sz i = stream.tokens.size; i > 0; i--) {
        if (stream.tokens.entries[i - 1].text == "value" && i >= 2 && stream.tokens.entries[i - 2].type == DOT) {
            offset = stream.tokens.entries[i - 1].offset;
            break;
        }
    }
    stream.free();
    encode_hover("file:///test.c3", content, offset, docs, "", &out);
    String result = out.str_view();
    assert(result.len > 0, "expected hover for struct field");
    assert(!result.contains("Identifier:"), "got fallback: %s", result);
}

fn void test_hover_self_field() @test {
    DString out = dstring::temp();
    DocumentList* docs = mem::new(DocumentList);
    defer mem::free(docs);
    String content = "struct Foo { int x; }\nfn void Foo.bar(&self) { self.x = 1; }";
    TokenStream stream = token_stream_tokenize(content);
    sz offset = 0;
    for (sz i = 0; i < stream.tokens.size; i++) {
        if (stream.tokens.entries[i].text == "x" && i > 0 && stream.tokens.entries[i - 1].type == DOT) {
            offset = stream.tokens.entries[i].offset;
            break;
        }
    }
    stream.free();
    encode_hover("file:///test.c3", content, offset, docs, "", &out);
    String result = out.str_view();
    assert(result.len > 0, "expected hover for self.x");
    assert(!result.contains("Identifier:"), "got fallback for self.x: %s", result);
}

fn void test_find_variable_type_pointer() @test {
    String content = `struct Foo { int x; }
fn void test() {
    Foo* ptr;
    ptr.x = 1;
}`;
    TokenStream stream = token_stream_tokenize(content);
    defer stream.free();

    // Find "x" after DOT in "ptr.x"
    sz x_idx = 0;
    for (sz i = 0; i < stream.tokens.size; i++) {
        if (stream.tokens.entries[i].text == "x" && i > 0 && stream.tokens.entries[i - 1].type == DOT) {
            x_idx = i;
            break;
        }
    }
    assert(x_idx > 0, "couldn't find x after DOT");

    DocumentList* docs = mem::new(DocumentList);
    defer mem::free(docs);
    String recv_type = stream.tokens.resolve_receiver_type(x_idx, "file:///test.c3", docs);
    assert(recv_type == "Foo", "expected Foo, got: '%s'", recv_type);
}

fn void test_definition_pointer_field() @test {
    DString out = dstring::temp();
    DocumentList* docs = mem::new(DocumentList);
    defer mem::free(docs);
    String content = "struct Foo { int value; }\nfn void test() {\n\tFoo* ptr;\n\tptr.value = 42;\n}";
    TokenStream stream = token_stream_tokenize(content);
    sz offset = 0;
    for (sz i = stream.tokens.size; i > 0; i--) {
        if (stream.tokens.entries[i - 1].text == "value" && i >= 2 && stream.tokens.entries[i - 2].type == DOT) {
            offset = stream.tokens.entries[i - 1].offset;
            break;
        }
    }
    stream.free();
    encode_definition("file:///test.c3", content, offset, docs, "", &out);
    String result = out.str_view();
    assert(result.len > 0, "expected definition for pointer field access");
    assert(result.contains(`"line":0`), "expected line 0, got: %s", result);
}

fn void test_definition_pointer_method_call() @test {
    // Reproduces: LineOffsets* lo = ...; lo.find_line(x);
    // Method is defined in another file as fn usz LineOffsets.find_line(&self, usz offset)
    DString out = dstring::temp();
    DocumentList* docs = mem::new(DocumentList);
    defer mem::free(docs);

    String other = "fn usz MyType.find_line(&self, usz offset) { return 0; }";
    docs.open("file:///methods.c3", other, 1);

    String content = "fn void test() {\n\tMyType* lo;\n\tlo.find_line(42);\n}";
    TokenStream stream = token_stream_tokenize(content);
    sz offset = 0;
    for (sz i = 0; i < stream.tokens.size; i++) {
        if (stream.tokens.entries[i].text == "find_line" && i > 0 && stream.tokens.entries[i - 1].type == DOT) {
            offset = stream.tokens.entries[i].offset;
            break;
        }
    }
    stream.free();
    assert(offset > 0, "couldn't find find_line token");
    encode_definition("file:///test.c3", content, offset, docs, "", &out);
    String result = out.str_view();
    assert(result.len > 0, "expected definition for pointer method call, got empty");
    assert(result.contains("methods.c3"), "expected methods.c3, got: %s", result);
    docs.close("file:///methods.c3");
}

fn void test_definition_pointer_method_same_file() @test {
    // Method defined in same file, pointer variable
    DString out = dstring::temp();
    DocumentList* docs = mem::new(DocumentList);
    defer mem::free(docs);

    String content = "fn usz MyType.find_it(&self) { return 0; }\nfn void test() {\n\tMyType* lo;\n\tlo.find_it();\n}";
    TokenStream stream = token_stream_tokenize(content);
    sz offset = 0;
    // Search backwards to find the call site, not the declaration
    for (sz i = stream.tokens.size; i > 0; i--) {
        if (stream.tokens.entries[i - 1].text == "find_it" && i >= 2 && stream.tokens.entries[i - 2].type == DOT) {
            offset = stream.tokens.entries[i - 1].offset;
            break;
        }
    }
    stream.free();
    assert(offset > 0, "couldn't find find_it token");
    encode_definition("file:///test.c3", content, offset, docs, "", &out);
    String result = out.str_view();
    assert(result.len > 0, "expected definition for pointer method (same file), got empty");
    assert(result.contains(`"line":0`), "expected line 0, got: %s", result);
}

fn void test_definition_real_semantic_find_line() @test {
    // Test against actual semantic.c3: lo.find_line(tok_start) should resolve to LineOffsets.find_line
    if (try file_data = file::load(mem, "src/analysis/semantic.c3"))
    {
        defer mem::free(file_data);
        String content = (String)file_data;
        DString out = dstring::temp();
        DocumentList* docs = mem::new(DocumentList);
        defer mem::free(docs);

        TokenStream stream = token_stream_tokenize(content);
        // Find last "find_line" after DOT (call site, not declaration)
        sz offset = 0;
        for (sz i = stream.tokens.size; i > 0; i--) {
            if (stream.tokens.entries[i - 1].text == "find_line" && i >= 2 && stream.tokens.entries[i - 2].type == DOT) {
                offset = stream.tokens.entries[i - 1].offset;
                break;
            }
        }
        stream.free();
        assert(offset > 0, "couldn't find find_line call in semantic.c3");

        encode_definition("file:///src/analysis/semantic.c3", content, offset, docs, "", &out);
        String result = out.str_view();
        assert(result.len > 0, "find_line: expected definition, got empty. offset=%d", offset);
        // LineOffsets.find_line is on line 22 (0-indexed)
        assert(result.contains(`"line":22`), "expected line 22, got: %s", result);
    }
    else
    {
        assert(false, "couldn't load src/analysis/semantic.c3");
    }
}

fn void test_hover_cross_file_field() @test {
    DString out = dstring::temp();
    DocumentList* docs = mem::new(DocumentList);
    defer mem::free(docs);

    // Simulate: stream.c3 is open with TokenStream struct
    String stream_content = "struct TokenStream {\n\tTokenList tokens;\n\tString content;\n}";
    docs.open("file:///stream.c3", stream_content, 1);

    // Current file uses stream.tokens
    String content = "fn void test() {\n\tTokenStream stream;\n\tstream.tokens.size;\n}";

    // Find offset of "tokens" in "stream.tokens"
    TokenStream s = token_stream_tokenize(content);
    sz offset = 0;
    for (sz i = 0; i < s.tokens.size; i++) {
        if (s.tokens.entries[i].text == "tokens" && i > 0 && s.tokens.entries[i - 1].type == DOT) {
            offset = s.tokens.entries[i].offset;
            break;
        }
    }
    s.free();
    assert(offset > 0, "couldn't find tokens");

    encode_hover("file:///test.c3", content, offset, docs, "", &out);
    String result = out.str_view();
    assert(!result.contains("Identifier:"), "got fallback for cross-file .tokens: %s", result);
    assert(result.len > 0, "expected hover for cross-file .tokens");

    docs.close("file:///stream.c3");
}

// --- range slices and chains through the standard library ---

// `xs[a..b]` is a slice of the same thing, not one element of it, so the members
// reached through it are the collection's. Before this, `line[p..].trim()` looked
// `trim` up on `char` and found nothing.
fn void test_chain_range_slice_keeps_the_slice_type() @test {
    String content = `fn void test() {
    String line;
    line[3..].trim();
}`;
    TokenStream stream = token_stream_tokenize(content);
    defer stream.free();

    sz trim_idx = 0;
    for (sz i = 0; i < stream.tokens.size; i++) {
        if (stream.tokens.entries[i].text == "trim" && i > 0 && stream.tokens.entries[i - 1].type == DOT) {
            trim_idx = i;
            break;
        }
    }
    assert(trim_idx > 0, "couldn't find trim after DOT");

    DocumentList* docs = mem::new(DocumentList);
    defer mem::free(docs);
    String recv_type = stream.tokens.resolve_receiver_type(trim_idx, "file:///test.c3", docs);
    assert(recv_type == "String", "expected String, got: '%s'", recv_type);
}

// The counterpart: a single index still yields an element, so `xs[1].x` reaches
// `Foo.x`. A `?:` inside the brackets is a ternary, not a range.
fn void test_chain_single_index_still_yields_the_element() @test {
    String content = `struct Foo { int x; }
fn void test() {
    Foo[4] xs;
    xs[a ? b : c].x = 1;
}`;
    TokenStream stream = token_stream_tokenize(content);
    defer stream.free();

    sz x_idx = 0;
    for (sz i = stream.tokens.size; i > 0; i--) {
        if (stream.tokens.entries[i - 1].text == "x" && i >= 2 && stream.tokens.entries[i - 2].type == DOT) {
            x_idx = i - 1;
            break;
        }
    }
    assert(x_idx > 0, "couldn't find x after DOT");

    DocumentList* docs = mem::new(DocumentList);
    defer mem::free(docs);
    String recv_type = stream.tokens.resolve_receiver_type(x_idx, "file:///test.c3", docs);
    assert(recv_type == "Foo", "expected Foo, got: '%s'", recv_type);
}

// A chain only continues past a call once that call's return type is known, and a
// library call's return type is written in the stdlib — which the return-type search
// used to stop short of. `io::stdout().write(..)` is the everyday case.
fn void test_definition_through_a_stdlib_free_function_return() @test {
    mkdirs("/tmp/lsp_chain_std_fn/io");
    file::save("/tmp/lsp_chain_std_fn/io/file.c3",
        "module std::io;\nstruct File { int fd; }\nfn File* stdout() { return null; }\nfn usz? File.write(&self, char[] bytes) { return 0; }\nfn void? File.flush(&self) {}\n")!!;
    defer { if (catch file::delete("/tmp/lsp_chain_std_fn/io/file.c3")) {} }

    String content = "fn void test() {\n\tString line;\n\tio::stdout().write(line);\n\tio::stdout().flush();\n}";

    foreach (String name : {"write", "flush"}) {
        TokenStream stream = token_stream_tokenize(content);
        sz offset = 0;
        for (sz i = 0; i < stream.tokens.size; i++) {
            if (stream.tokens.entries[i].text == name && i > 0 && stream.tokens.entries[i - 1].type == DOT) {
                offset = stream.tokens.entries[i].offset;
                break;
            }
        }
        stream.free();
        assert(offset > 0, "couldn't find %s call", name);

        DocumentList* docs = mem::new(DocumentList);
        defer mem::free(docs);
        DString out = dstring::temp();
        encode_definition("file:///test.c3", content, offset, docs, "/tmp/lsp_chain_std_fn", &out);
        String result = out.str_view();
        assert(result.contains("file.c3"), "expected File.%s in the stdlib, got: %s", name, result);
    }
}

// The reported chain end to end: a range slice, a stdlib method whose return type
// carries the chain, and a second stdlib method reached through it.
fn void test_definition_through_a_stdlib_method_return() @test {
    mkdirs("/tmp/lsp_chain_std_method/core");
    file::save("/tmp/lsp_chain_std_method/core/string.c3",
        "module std::core::string;\ntypedef String = inline char[];\nfn String String.trim(self, String to_trim = \" \") { return self; }\nfn uint? String.to_uint(self, int base = 10) { return 0; }\n")!!;
    defer { if (catch file::delete("/tmp/lsp_chain_std_method/core/string.c3")) {} }

    String content = "fn void test() {\n\tString line;\n\tusz pos;\n\tusz length = (usz)(line[pos + 15..].trim().to_uint() ?? 0);\n}";

    foreach (String name : {"trim", "to_uint"}) {
        TokenStream stream = token_stream_tokenize(content);
        sz offset = 0;
        for (sz i = 0; i < stream.tokens.size; i++) {
            if (stream.tokens.entries[i].text == name && i > 0 && stream.tokens.entries[i - 1].type == DOT) {
                offset = stream.tokens.entries[i].offset;
                break;
            }
        }
        stream.free();
        assert(offset > 0, "couldn't find %s call", name);

        DocumentList* docs = mem::new(DocumentList);
        defer mem::free(docs);
        DString out = dstring::temp();
        encode_definition("file:///test.c3", content, offset, docs, "/tmp/lsp_chain_std_method", &out);
        String result = out.str_view();
        assert(result.contains("string.c3"), "expected String.%s in the stdlib, got: %s", name, result);
    }
}

// `!!` (force unwrap) and `!` (rethrow) sit between a call and the next dot, so
// without stripping them the receiver of `find()!!.baz` reads as the operator.
fn void test_chain_through_optional_operators() @test {
    String content = `struct Bar { int baz; }
fn Bar*? find() { return null; }
fn void test() {
    find()!!.baz = 1;
    find()!.baz = 2;
}`;
    TokenStream stream = token_stream_tokenize(content);
    defer stream.free();

    DocumentList* docs = mem::new(DocumentList);
    defer mem::free(docs);

    sz seen = 0;
    for (sz i = 0; i < stream.tokens.size; i++) {
        if (stream.tokens.entries[i].text != "baz") continue;
        if (i == 0 || stream.tokens.entries[i - 1].type != DOT) continue;
        String recv_type = stream.tokens.resolve_receiver_type(i, "file:///test.c3", docs);
        assert(recv_type == "Bar", "expected Bar, got: '%s'", recv_type);
        seen++;
    }
    assert(seen == 2, "expected 2 member accesses, saw %d", seen);
}

// A prefix `!` is not a postfix unwrap — `!ready.baz` must not read `ready` as the
// receiver of an unwrapped expression ending at the `!`.
fn void test_chain_prefix_bang_not_unwrap() @test {
    String content = `struct Bar { int baz; }
fn void test() {
    Bar b;
    bool ok = !b.baz;
}`;
    TokenStream stream = token_stream_tokenize(content);
    defer stream.free();

    DocumentList* docs = mem::new(DocumentList);
    defer mem::free(docs);

    sz baz_idx = 0;
    for (sz i = 0; i < stream.tokens.size; i++) {
        if (stream.tokens.entries[i].text == "baz" && i > 0 && stream.tokens.entries[i - 1].type == DOT) {
            baz_idx = i;
            break;
        }
    }
    String recv_type = stream.tokens.resolve_receiver_type(baz_idx, "file:///test.c3", docs);
    assert(recv_type == "Bar", "expected Bar, got: '%s'", recv_type);
}
