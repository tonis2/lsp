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

    usz baz_idx = 0;
    for (usz i = 0; i < stream.tokens.size; i++) {
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

    usz baz_idx = 0;
    for (usz i = 0; i < stream.tokens.size; i++) {
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
    usz value_offset = 0;
    for (usz i = stream.tokens.size; i > 0; i--) {
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
    usz offset = 0;
    for (usz i = stream.tokens.size; i > 0; i--) {
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
    usz offset = 0;
    for (usz i = stream.tokens.size; i > 0; i--) {
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
    usz offset = 0;
    for (usz i = 0; i < stream.tokens.size; i++) {
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
    usz x_idx = 0;
    for (usz i = 0; i < stream.tokens.size; i++) {
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
    usz offset = 0;
    for (usz i = stream.tokens.size; i > 0; i--) {
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
    usz offset = 0;
    for (usz i = 0; i < stream.tokens.size; i++) {
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
    usz offset = 0;
    // Search backwards to find the call site, not the declaration
    for (usz i = stream.tokens.size; i > 0; i--) {
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
        usz offset = 0;
        for (usz i = stream.tokens.size; i > 0; i--) {
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
    usz offset = 0;
    for (usz i = 0; i < s.tokens.size; i++) {
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
