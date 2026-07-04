module lsp;

import std::core::dstring;
import std::core::mem;
import std::collections::object;
import std::time;

const TOKEN_TYPES_LEGEND = `["namespace","type","enum","struct","variable","function","macro","keyword","decorator","comment","string","number","operator","enumMember","class","parameter","property","typeParameter"]`;

fn sz position_to_offset(String content, int line, int character)
{
	LineOffsets lo;
	lo.init(mem);
	defer lo.free();
	lo.build(content);
	if ((sz)line < lo.size) return lo.entries[(sz)line] + (sz)character;
	return 0;
}

// --- Typed request decode ---------------------------------------------------
// All request-param JSON access lives in these helpers so handlers stay thin.
// Malformed params panic (!!), matching the historical behavior.

struct DocPosition
{
	int line;
	int character;
}

fn String request_uri(Object* msg) @private
{
	return msg.get("params")!!.get("textDocument")!!.get_string("uri") ?? "";
}

fn DocPosition request_position(Object* msg) @private
{
	Object* pos = msg.get("params")!!.get("position")!!;
	return { .line = pos.get_int("line") ?? 0, .character = pos.get_int("character") ?? 0 };
}

// Look up an open document; when missing, answer `fallback` and return DOC_NOT_FOUND,
// so handlers read as `if (try doc = self.doc_or_respond(...)) { ... }`.
fn Document*? LspServer.doc_or_respond(&self, String uri, String id_json, String fallback)
{
	Document*? doc = self.documents.find(uri);
	if (catch doc)
	{
		send_response(id_json, fallback);
		return DOC_NOT_FOUND~;
	}
	return doc;
}

// Send `data`, falling back when the encoder produced nothing — forwarding an empty
// buffer would yield `"result":` (invalid JSON) and drop the connection.
fn void respond_nonempty(String id_json, DString* data, String fallback) @private
{
	send_response(id_json, data.str_view().len == 0 ? fallback : data.str_view());
}

fn void LspServer.handle_initialize(&self, Object* msg, String id_json)
{
	self.initialized = true;

	// Extract initializationOptions if provided by the client
	if (try opts = msg.get("params")!!.get("initializationOptions"))
	{
		String stdlib = opts.get_string("stdlib-path") ?? "";
		if (stdlib.len > 0 && self.stdlib_path.len == 0)
		{
			char[] copy = mem::new_array(char, stdlib.len);
			copy[..] = stdlib[..];
			self.stdlib_path = (String)copy;
		}
		String compiler = opts.get_string("compiler-path") ?? "";
		if (compiler.len > 0 && self.compiler_path == "c3c")
		{
			char[] copy = mem::new_array(char, compiler.len);
			copy[..] = compiler[..];
			self.compiler_path = (String)copy;
		}
		// Client config overrides the CLI/default. 0 means "no throttle".
		if (try delay = opts.get_int("diagnosticsDelay"))
		{
			self.diag_delay_ms = (long)delay;
		}
	}

	// If no stdlib path was supplied (via CLI or client settings), ask the resolved
	// compiler where it is installed and derive <install dir>/lib/std. Runs after the
	// overrides above so a client-configured compiler-path is honored. detect_stdlib_path
	// never throws, so a bad compiler-path just leaves stdlib_path empty.
	if (self.stdlib_path.len == 0)
	{
		String detected = detect_stdlib_path(self.compiler_path);
		if (detected.len > 0) self.stdlib_path = detected;
	}

	DString result = dstring::temp();
	encode_server_capabilities(&result, VERSION);
	send_response(id_json, result.str_view());
}

fn void LspServer.handle_shutdown(&self, Object* msg, String id_json)
{
	self.shutdown_requested = true;
	send_response(id_json, "null");
}

fn void LspServer.handle_exit(&self, Object* msg = null, String id_json = "")
{
	self.running = false;

	// Release the on-disk token cache (and detach the global handle).
	g_file_cache = null;
	self.fcache.free_all();

	// Close every open document (frees content, uri, and cached tokens), then the lists.
	while (self.documents.size > 0)
	{
		self.documents.close(self.documents.entries[0].uri);
	}
	self.documents.free();
	self.diag_files.free();

	if (self.diag_pending_uri.len > 0) mem::free((char*)self.diag_pending_uri.ptr);
	if (self.lex_diag_pending_uri.len > 0) mem::free((char*)self.lex_diag_pending_uri.ptr);
}

fn void LspServer.handle_did_open(&self, Object* msg, String id_json = "")
{
	Object* td  = msg.get("params")!!.get("textDocument")!!;
	String uri  = td.get_string("uri") ?? "";
	String text = td.get_string("text") ?? "";
	int version = td.get_int("version") ?? 0;
	self.documents.open(uri, text, version);
	publish_diagnostics(uri, text);
	self.maybe_run_compiler_diagnostics(uri);
}

fn void LspServer.handle_did_change(&self, Object* msg, String id_json = "")
{
	Object* params = msg.get("params")!!;
	Object* td     = params.get("textDocument")!!;
	String uri     = td.get_string("uri") ?? "";
	int version    = td.get_int("version") ?? 0;

	Object* changes = params.get("contentChanges")!!;
	Object* first   = changes.get_at(0);
	String text     = first.get_string("text") ?? "";

	self.documents.update(uri, text, version);
	self.maybe_publish_lex_diagnostics(uri, text);
}

fn void LspServer.handle_did_close(&self, Object* msg, String id_json = "")
{
	self.documents.close(request_uri(msg));
}

fn void LspServer.handle_did_save(&self, Object* msg, String id_json = "")
{
	self.maybe_run_compiler_diagnostics(request_uri(msg));
}

fn void LspServer.maybe_run_compiler_diagnostics(&self, String uri)
{
	// No throttle configured: run immediately.
	if (self.diag_delay_ms <= 0)
	{
		self.diag_pending = false;
		self.publish_compiler_diagnostics(uri);
		return;
	}

	Time now         = time::now();
	Duration elapsed = now - self.last_diag_time;
	Duration delay   = time::ms(self.diag_delay_ms);
	if ((long)elapsed >= (long)delay || (long)self.last_diag_time == 0)
	{
		// Enough time has passed (or first run) — run now.
		self.diag_pending = false;
		self.publish_compiler_diagnostics(uri);
		return;
	}

	// Inside the throttle window — defer with a trailing-edge debounce. Store an
	// owned copy of the URI so flush_pending_diagnostics can re-run it once the
	// window elapses (on the next incoming message). This prevents a fix-save
	// from being silently dropped and leaving stale diagnostics behind.
	self.set_pending_diag_uri(uri);
	self.diag_pending = true;
}

// Publish the cheap lexer diagnostics, debouncing for large files so a full O(n) scan
// doesn't run on every keystroke. Small files scan immediately (unchanged behavior).
fn void LspServer.maybe_publish_lex_diagnostics(&self, String uri, String content)
{
	if (content.len <= LARGE_FILE_BYTES)
	{
		publish_diagnostics(uri, content);
		return;
	}

	// Large file: leading-edge run, then defer until the window elapses. The trailing
	// run is flushed by flush_pending_diagnostics on a later incoming message, so the
	// final state is never dropped.
	Time now         = time::now();
	Duration elapsed = now - self.last_lex_diag_time;
	Duration delay   = time::ms(self.diag_delay_ms > 0 ? self.diag_delay_ms : 500);
	if ((long)self.last_lex_diag_time == 0 || (long)elapsed >= (long)delay)
	{
		self.last_lex_diag_time = now;
		self.lex_diag_pending = false;
		publish_diagnostics(uri, content);
		return;
	}

	self.set_pending_lex_diag_uri(uri);
	self.lex_diag_pending = true;
}

// Store an owned copy of the URI whose lexer diagnostics are pending a deferred run.
fn void LspServer.set_pending_lex_diag_uri(&self, String uri)
{
	if (self.lex_diag_pending_uri.len > 0)
	{
		mem::free((char*)self.lex_diag_pending_uri.ptr);
	}
	char[] copy = mem::new_array(char, uri.len);
	copy[..] = uri[..];
	self.lex_diag_pending_uri = (String)copy;
}

// Store an owned copy of the URI whose diagnostics are pending a deferred run.
fn void LspServer.set_pending_diag_uri(&self, String uri)
{
	if (self.diag_pending_uri.len > 0)
	{
		mem::free((char*)self.diag_pending_uri.ptr);
	}
	char[] copy = mem::new_array(char, uri.len);
	copy[..] = uri[..];
	self.diag_pending_uri = (String)copy;
}

fn void LspServer.handle_semantic_tokens(&self, Object* msg, String id_json)
{
	if (try doc = self.doc_or_respond(request_uri(msg), id_json, `{"data":[]}`))
	{
		DString data = dstring::temp();
		encode_semantic_tokens(doc.content, &data, doc.get_tokens());

		DString result = dstring::temp();
		result.appendf(`{"data":[%s]}`, data.str_view());
		send_response(id_json, result.str_view());
	}
}

fn void LspServer.handle_folding_range(&self, Object* msg, String id_json)
{
	if (try doc = self.doc_or_respond(request_uri(msg), id_json, "[]"))
	{
		DString data = dstring::temp();
		encode_folding_ranges(doc.content, &data);

		DString result = dstring::temp();
		result.appendf("[%s]", data.str_view());
		send_response(id_json, result.str_view());
	}
}

fn void LspServer.handle_document_symbol(&self, Object* msg, String id_json)
{
	if (try doc = self.doc_or_respond(request_uri(msg), id_json, "[]"))
	{
		DString data = dstring::temp();
		encode_document_symbols(doc.content, &data, doc.get_tokens());

		DString result = dstring::temp();
		result.appendf("[%s]", data.str_view());
		send_response(id_json, result.str_view());
	}
}

fn void LspServer.handle_hover(&self, Object* msg, String id_json)
{
	String uri = request_uri(msg);
	if (try doc = self.doc_or_respond(uri, id_json, "null"))
	{
		DocPosition p = request_position(msg);
		sz offset = position_to_offset(doc.content, p.line, p.character);

		DString data = dstring::temp();
		encode_hover(uri, doc.content, offset, &self.documents, self.stdlib_path, &data);
		respond_nonempty(id_json, &data, "null");
	}
}

fn void LspServer.handle_completion(&self, Object* msg, String id_json)
{
	String uri = request_uri(msg);
	if (try doc = self.doc_or_respond(uri, id_json, `{"isIncomplete":false,"items":[]}`))
	{
		DocPosition p = request_position(msg);
		sz offset = position_to_offset(doc.content, p.line, p.character);
		if (offset > doc.content.len)
		{
			offset = doc.content.len;
		}

		DString data = dstring::temp();
		encode_completions(uri, doc.content, offset, &self.documents, self.stdlib_path, &data);
		respond_nonempty(id_json, &data, `{"isIncomplete":false,"items":[]}`);
	}
}

fn void LspServer.handle_definition(&self, Object* msg, String id_json)
{
	String uri = request_uri(msg);
	if (try doc = self.doc_or_respond(uri, id_json, "null"))
	{
		DocPosition p = request_position(msg);
		sz offset = position_to_offset(doc.content, p.line, p.character);

		DString data = dstring::temp();
		encode_definition(uri, doc.content, offset, &self.documents, self.stdlib_path, &data);
		respond_nonempty(id_json, &data, "null");
	}
}

fn void LspServer.handle_signature_help(&self, Object* msg, String id_json)
{
	String uri = request_uri(msg);
	if (try doc = self.doc_or_respond(uri, id_json, "null"))
	{
		DocPosition p = request_position(msg);
		sz offset = position_to_offset(doc.content, p.line, p.character);

		DString data = dstring::temp();
		encode_signature_help(doc.content, offset, &data, doc.get_tokens(), uri, &self.documents, self.stdlib_path);
		respond_nonempty(id_json, &data, "null");
	}
}

fn void LspServer.handle_document_highlight(&self, Object* msg, String id_json)
{
	if (try doc = self.doc_or_respond(request_uri(msg), id_json, "null"))
	{
		DocPosition p = request_position(msg);
		sz offset = position_to_offset(doc.content, p.line, p.character);

		DString data = dstring::temp();
		encode_document_highlights(doc.content, offset, &data, doc.get_tokens());
		respond_nonempty(id_json, &data, "null");
	}
}

fn void LspServer.handle_references(&self, Object* msg, String id_json)
{
	String uri = request_uri(msg);
	if (try doc = self.doc_or_respond(uri, id_json, "null"))
	{
		DocPosition p = request_position(msg);
		sz offset = position_to_offset(doc.content, p.line, p.character);

		bool include_decl = true;
		if (try ctx = msg.get("params")!!.get("context"))
		{
			include_decl = (ctx.get_int("includeDeclaration") ?? 1) != 0;
		}

		DString data = dstring::temp();
		encode_references(uri, doc.content, offset, &self.documents, self.stdlib_path, include_decl, &data);
		respond_nonempty(id_json, &data, "null");
	}
}

fn void LspServer.handle_rename(&self, Object* msg, String id_json)
{
	String uri = request_uri(msg);
	if (try doc = self.doc_or_respond(uri, id_json, "null"))
	{
		DocPosition p = request_position(msg);

		String new_name = msg.get("params")!!.get_string("newName") ?? "";
		if (new_name.len == 0)
		{
			send_error(id_json, -32602, "newName is required");
			return;
		}

		sz offset = position_to_offset(doc.content, p.line, p.character);

		DString data = dstring::temp();
		encode_rename(uri, doc.content, offset, &self.documents, self.stdlib_path, new_name, &data);
		respond_nonempty(id_json, &data, "null");
	}
}
