module lsp;

import std::core::mem;
import std::collections::list;
import std::io::file;
import std::time;

// Persistent cache of tokenized on-disk files, keyed by absolute path and invalidated
// by file modification time. This removes the dominant cost of cross-file features
// (completion, goto-definition, hover, references, rename), which previously re-read
// AND re-tokenized every project + stdlib file from disk on every single request.
// 
// Lifetime: a CachedFile owns its `path`, its `content` buffer, and the TokenStream
// whose tokens slice into that `content`. They are freed together (CachedFile.free),
// so the token slices are always valid while the entry lives. All allocations come
// from the global `mem` allocator and survive across messages (never the per-message
// @pool). The cache lives for the whole session on the LspServer and is freed at
// shutdown via FileCache.free_all.
struct CachedFile
{
	String path;
	String content;
	TokenStream* stream;
	long mtime;
}

alias FileCache = List{CachedFile};

// Global handle to the server's file cache. Set by LspServer.init; stays null in unit
// tests and headless contexts, in which case the scan_dir_* helpers fall back to the
// original load-and-tokenize-every-time behavior (so tests see no change).
FileCache* g_file_cache = null;

// Return the cached token stream for the .c3/.c3i file at `abs_path`, loading and
// tokenizing it on first use and refreshing it when its mtime changes. Sets
// *out_content to the (cache-owned) file content the tokens slice into. Returns null
// if the file cannot be read.
fn TokenStream* FileCache.stream_for(&self, String abs_path, String* out_content)
{
	long mt = (long)(file::last_modified(abs_path) ?? (Time)0);

	for (sz i = 0; i < self.size; i++)
	{
		if (self.entries[i].path == abs_path)
		{
			if (self.entries[i].mtime == mt)
			{
				*out_content = self.entries[i].content;
				return self.entries[i].stream;
			}
			// Stale: drop the old entry (frees its stream + content) and reload below.
			self.entries[i].free();
			self.remove_at(i);
			break;
		}
	}

	if (try fc = file::load(mem, abs_path))
	{
		String content   = (String)fc;
		char[] path_copy = mem::new_array(char, abs_path.len);
		path_copy[..] = abs_path[..];

		TokenStream* st = mem::new(TokenStream);
		*st = token_stream_tokenize(content);

		self.push({ .path = (String)path_copy, .content = content, .stream = st, .mtime = mt });
		*out_content = content;
		return st;
	}

	*out_content = "";
	return null;
}

fn void CachedFile.free(&self)
{
	if (self.stream != null)
	{
		self.stream.free();
		mem::free(self.stream);
	}
	if (self.content.len > 0) mem::free((char*)self.content.ptr);
	if (self.path.len > 0) mem::free((char*)self.path.ptr);
}

// Free every cached entry and the backing list. Called at server shutdown.
// Named free_all (not free) to avoid shadowing List.free, which only frees the backing.
fn void FileCache.free_all(&self)
{
	for (sz i = 0; i < self.size; i++)
	{
		self.entries[i].free();
	}
	self.free();
}

// Return a token stream for the .c3/.c3i file at `abs_path`, preferring the global
// file cache. When the cache is active the returned stream and its content are
// cache-owned and *owns is false. Otherwise the file is loaded and tokenized into
// *fallback, *owns is true, and the caller MUST free both the stream (*fallback) and
// the content buffer (mem::free of *content's pointer). Returns null if unreadable.
fn TokenStream* file_token_stream(String abs_path, TokenStream* fallback, String* content, bool* owns)
{
	if (g_file_cache != null)
	{
		*owns = false;
		return g_file_cache.stream_for(abs_path, content);
	}
	if (try fc = file::load(mem, abs_path))
	{
		*content = (String)fc;
		*fallback = token_stream_tokenize(*content);
		*owns = true;
		return fallback;
	}
	*owns = false;
	*content = "";
	return null;
}
