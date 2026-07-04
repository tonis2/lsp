module lsp;

fn void test_document_store_open_and_get() @test {
	DocumentList store;
	store.open("file:///a.c3", "module a;", 1);
	defer store.close("file:///a.c3");

	assert(store.len() == 1);
	Document* doc = store.find("file:///a.c3")!!;
	assert(doc.uri == "file:///a.c3");
	assert(doc.content == "module a;");
	assert(doc.version == 1);
}

fn void test_document_store_get_missing() @test {
	DocumentList store;
	assert(!@ok(store.find("file:///nope.c3")));
}

fn void test_document_store_update() @test {
	DocumentList store;
	store.open("file:///a.c3", "module a;", 1);
	defer store.close("file:///a.c3");
	store.update("file:///a.c3", "module a; // updated", 2);

	Document* doc = store.find("file:///a.c3")!!;
	assert(doc.content == "module a; // updated");
	assert(doc.version == 2);
	assert(store.len() == 1);
}

fn void test_document_store_open_duplicate_updates() @test {
	DocumentList store;
	store.open("file:///a.c3", "v1", 1);
	defer store.close("file:///a.c3");
	store.open("file:///a.c3", "v2", 2);

	assert(store.len() == 1);
	assert(store.find("file:///a.c3")!!.content == "v2");
}

fn void test_document_store_close() @test {
	DocumentList store;
	store.open("file:///a.c3", "aaa", 1);
	store.open("file:///b.c3", "bbb", 1);
	defer store.close("file:///b.c3");
	assert(store.len() == 2);

	store.close("file:///a.c3");
	assert(store.len() == 1);
	assert(!@ok(store.find("file:///a.c3")));
	assert(@ok(store.find("file:///b.c3")));
}

fn void test_document_store_close_last_compacts() @test {
	DocumentList store;
	store.open("file:///a.c3", "aaa", 1);
	store.open("file:///b.c3", "bbb", 1);
	store.open("file:///c.c3", "ccc", 1);
	defer store.close("file:///b.c3");
	defer store.close("file:///c.c3");

	// Close middle element — last element fills the gap
	store.close("file:///a.c3");
	assert(store.len() == 2);
	assert(@ok(store.find("file:///b.c3")));
	assert(@ok(store.find("file:///c.c3")));
}

fn void test_document_store_close_missing_is_noop() @test {
	DocumentList store;
	store.open("file:///a.c3", "aaa", 1);
	defer store.close("file:///a.c3");
	store.close("file:///nope.c3");
	assert(store.len() == 1);
}

fn void test_document_get_tokens_caches() @test {
	DocumentList store;
	store.open("file:///a.c3", "fn void foo() {}", 1);
	defer store.close("file:///a.c3");

	Document* doc = store.find("file:///a.c3")!!;
	TokenStream* t1 = doc.get_tokens();
	TokenStream* t2 = doc.get_tokens();
	assert(t1 == t2, "get_tokens should return the same cached stream");
	assert(t1.tokens.size > 0, "cached stream should be populated");
}

fn void test_document_update_invalidates_tokens() @test {
	DocumentList store;
	store.open("file:///a.c3", "fn void foo() {}", 1);
	defer store.close("file:///a.c3");

	Document* doc = store.find("file:///a.c3")!!;
	doc.get_tokens();
	assert(doc.tokens != null, "tokens should be cached after get_tokens");

	store.update("file:///a.c3", "fn void foo() {} fn void bar() {}", 2);
	doc = store.find("file:///a.c3")!!;
	assert(doc.tokens == null, "update must invalidate the cached tokens");

	// Rebuilding picks up the new content (no use-after-free of the freed buffer).
	TokenStream* t = doc.get_tokens();
	assert(t.content == "fn void foo() {} fn void bar() {}", "rebuilt tokens must use the new content");
}

fn void test_document_close_frees_tokens() @test {
	DocumentList store;
	store.open("file:///a.c3", "fn void foo() {}", 1);
	Document* doc = store.find("file:///a.c3")!!;
	doc.get_tokens(); // build the cache, then close must free it cleanly
	store.close("file:///a.c3");
	assert(!@ok(store.find("file:///a.c3")));
}

fn void test_document_content_is_independent_copy() @test {
	DocumentList store;
	defer store.close("file:///a.c3");

	// The store should copy content, not alias the input
	char[9] buf = "module a;".ptr[:9];
	store.open("file:///a.c3", (String)buf[..], 1);

	// Mutate the original buffer
	buf[0] = 'X';
	Document* doc = store.find("file:///a.c3")!!;
	assert(doc.content[0] == 'm', "Store content should be an independent copy");
}
