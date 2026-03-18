module lsp;

fn void test_document_store_open_and_get() @test {
	DocumentStore store;
	store.open("file:///a.c3", "module a;", 1);
	defer store.close("file:///a.c3");

	assert(store.count == 1);
	Document* doc = store.get("file:///a.c3");
	assert(doc != null);
	assert(doc.uri == "file:///a.c3");
	assert(doc.content == "module a;");
	assert(doc.version == 1);
}

fn void test_document_store_get_missing() @test {
	DocumentStore store;
	assert(store.get("file:///nope.c3") == null);
}

fn void test_document_store_update() @test {
	DocumentStore store;
	store.open("file:///a.c3", "module a;", 1);
	defer store.close("file:///a.c3");
	store.update("file:///a.c3", "module a; // updated", 2);

	Document* doc = store.get("file:///a.c3");
	assert(doc != null);
	assert(doc.content == "module a; // updated");
	assert(doc.version == 2);
	assert(store.count == 1);
}

fn void test_document_store_open_duplicate_updates() @test {
	DocumentStore store;
	store.open("file:///a.c3", "v1", 1);
	defer store.close("file:///a.c3");
	store.open("file:///a.c3", "v2", 2);

	assert(store.count == 1);
	assert(store.get("file:///a.c3").content == "v2");
}

fn void test_document_store_close() @test {
	DocumentStore store;
	store.open("file:///a.c3", "aaa", 1);
	store.open("file:///b.c3", "bbb", 1);
	defer store.close("file:///b.c3");
	assert(store.count == 2);

	store.close("file:///a.c3");
	assert(store.count == 1);
	assert(store.get("file:///a.c3") == null);
	assert(store.get("file:///b.c3") != null);
}

fn void test_document_store_close_last_compacts() @test {
	DocumentStore store;
	store.open("file:///a.c3", "aaa", 1);
	store.open("file:///b.c3", "bbb", 1);
	store.open("file:///c.c3", "ccc", 1);
	defer store.close("file:///b.c3");
	defer store.close("file:///c.c3");

	// Close middle element — last element fills the gap
	store.close("file:///a.c3");
	assert(store.count == 2);
	assert(store.get("file:///b.c3") != null);
	assert(store.get("file:///c.c3") != null);
}

fn void test_document_store_close_missing_is_noop() @test {
	DocumentStore store;
	store.open("file:///a.c3", "aaa", 1);
	defer store.close("file:///a.c3");
	store.close("file:///nope.c3");
	assert(store.count == 1);
}

fn void test_document_content_is_independent_copy() @test {
	DocumentStore store;
	defer store.close("file:///a.c3");

	// The store should copy content, not alias the input
	char[9] buf = "module a;".ptr[:9];
	store.open("file:///a.c3", (String)buf[..], 1);

	// Mutate the original buffer
	buf[0] = 'X';
	Document* doc = store.get("file:///a.c3");
	assert(doc.content[0] == 'm', "Store content should be an independent copy");
}
