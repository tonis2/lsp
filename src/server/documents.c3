module lsp;

import std::core::mem;
import std::collections::list;

struct Document
{
	String uri;
	String content;
	int version;
	// Lazily-built token cache for `content`. null = not built yet. Owned by this
	// Document (mem-allocated, survives across messages). Its tokens slice into
	// `content`, so it MUST be invalidated whenever `content` is freed/replaced.
	TokenStream* tokens;
}

alias DocumentList = List{Document};

faultdef DOC_NOT_FOUND;

// Return the cached token stream for this document, tokenizing on first use.
fn TokenStream* Document.get_tokens(&self)
{
	if (self.tokens == null)
	{
		self.tokens = mem::new(TokenStream);
		*self.tokens = token_stream_tokenize(self.content);
	}
	return self.tokens;
}

// Free and clear the cached token stream. Must be called before `content` is freed,
// since the cached tokens hold String slices into `content`.
fn void Document.invalidate_tokens(&self)
{
	if (self.tokens != null)
	{
		self.tokens.free();
		mem::free(self.tokens);
		self.tokens = null;
	}
}

fn void DocumentList.open(&self, String uri, String content, int version)
{
	// Check if already open, update instead

	foreach (entry : self)
	{
		if (entry.uri == uri)
		{
			self.update(uri, content, version);
			return;
		}
	}

	// Allocate copies
	char[] uri_copy = mem::new_array(char, uri.len);
	uri_copy[..] = uri[..];
	char[] content_copy = mem::new_array(char, content.len);
	content_copy[..] = content[..];

	self.push({ .uri = (String)uri_copy, .content = (String)content_copy, .version = version });
}

fn void DocumentList.update(&self, String uri, String content, int version)
{
	for (sz i = 0; i < self.size; i++)
	{
		if (self.entries[i].uri == uri)
		{
			// Cached tokens slice into the old content — drop them before freeing it.
			self.entries[i].invalidate_tokens();
			// Free old content, allocate new
			if (self.entries[i].content.len > 0)
			{
				mem::free((char*)self.entries[i].content.ptr);
			}
			char[] content_copy = mem::new_array(char, content.len);
			content_copy[..] = content[..];
			self.entries[i].content = (String)content_copy;
			self.entries[i].version = version;
			return;
		}
	}
}

fn void DocumentList.close(&self, String uri)
{
	for (sz i = 0; i < self.size; i++)
	{
		if (self.entries[i].uri == uri)
		{
			// Cached tokens slice into content — drop them before freeing it.
			self.entries[i].invalidate_tokens();
			// Free allocated memory
			if (self.entries[i].uri.len > 0)
			{
				mem::free((char*)self.entries[i].uri.ptr);
			}
			if (self.entries[i].content.len > 0)
			{
				mem::free((char*)self.entries[i].content.ptr);
			}
			self.remove_at(i);
			return;
		}
	}
}

// Return a token stream for `content`, preferring the cached stream of the open
// document `uri` when `content` is exactly that document's buffer (pointer-identical).
// The pointer check guarantees we never serve stale tokens for a different string, and
// makes callers that pass a literal (e.g. tests) fall back to a fresh tokenization.
//
// When the returned stream was freshly tokenized, *owns is set true and the caller MUST
// free it; when it comes from the document cache, *owns is false and the cache owns it.
fn TokenStream* token_stream_for_doc(String uri, String content, DocumentList* docs, TokenStream* fallback, bool* owns)
{
	if (docs != null)
	{
		if (try d = docs.find(uri))
		{
			if (d.content.ptr == content.ptr)
			{
				*owns = false;
				return d.get_tokens();
			}
		}
	}
	*fallback = token_stream_tokenize(content);
	*owns = true;
	return fallback;
}

fn Document*? DocumentList.find(&self, String uri)
{
	for (sz i = 0; i < self.size; i++)
	{
		if (self.entries[i].uri == uri)
		{
			return &self.entries[i];
		}
	}
	return DOC_NOT_FOUND~;
}
