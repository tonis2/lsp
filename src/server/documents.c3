module lsp;

import std::core::mem;
import std::collections::list;

struct Document
{
	String uri;
	String content;
	int version;
}

alias DocumentList = List{Document};

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
	for (usz i = 0; i < self.size; i++)
	{
		if (self.entries[i].uri == uri)
		{
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
	for (usz i = 0; i < self.size; i++)
	{
		if (self.entries[i].uri == uri)
		{
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

fn Document* DocumentList.find(&self, String uri)
{
	for (usz i = 0; i < self.size; i++)
	{
		if (self.entries[i].uri == uri)
		{
			return &self.entries[i];
		}
	}
	return null;
}
