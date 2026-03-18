module lsp;

import std::core::mem;

const MAX_DOCUMENTS = 64;

struct Document {
	String uri;
	String content;
	int version;
}

struct DocumentStore {
	Document[MAX_DOCUMENTS] docs;
	usz count;
}

fn void DocumentStore.open(&self, String uri, String content, int version) {
	// Check if already open, update instead
	for (usz i = 0; i < self.count; i++) {
		if (self.docs[i].uri == uri) {
			self.update(uri, content, version);
			return;
		}
	}

	if (self.count >= MAX_DOCUMENTS) return;

	// Allocate copies
	char[] uri_copy = mem::new_array(char, uri.len);
	uri_copy[..] = uri[..];
	char[] content_copy = mem::new_array(char, content.len);
	content_copy[..] = content[..];

	self.docs[self.count] = {
		.uri = (String)uri_copy,
		.content = (String)content_copy,
		.version = version,
	};
	self.count++;
}

fn void DocumentStore.update(&self, String uri, String content, int version) {
	for (usz i = 0; i < self.count; i++) {
		if (self.docs[i].uri == uri) {
			// Free old content, allocate new
			if (self.docs[i].content.len > 0) {
				mem::free((char*)self.docs[i].content.ptr);
			}
			char[] content_copy = mem::new_array(char, content.len);
			content_copy[..] = content[..];
			self.docs[i].content = (String)content_copy;
			self.docs[i].version = version;
			return;
		}
	}
}

fn void DocumentStore.close(&self, String uri) {
	for (usz i = 0; i < self.count; i++) {
		if (self.docs[i].uri == uri) {
			// Free allocated memory
			if (self.docs[i].uri.len > 0) {
				mem::free((char*)self.docs[i].uri.ptr);
			}
			if (self.docs[i].content.len > 0) {
				mem::free((char*)self.docs[i].content.ptr);
			}
			// Compact: move last element here
			if (i < self.count - 1) {
				self.docs[i] = self.docs[self.count - 1];
			}
			self.count--;
			return;
		}
	}
}

fn Document* DocumentStore.get(&self, String uri) {
	for (usz i = 0; i < self.count; i++) {
		if (self.docs[i].uri == uri) {
			return &self.docs[i];
		}
	}
	return null;
}
