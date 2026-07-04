module lsp;

import std::core::dstring;
import std::core::mem;
import std::collections::list;
import std::encoding::json;
import std::collections::object;
import std::time;

// Set of file:// URIs that currently have published c3c compiler diagnostics.
// Used to clear (publish an empty array for) files that no longer have errors.
alias PublishedFiles = List{String};

struct LspServer
{
	bool initialized;
	bool shutdown_requested;
	bool running;
	DocumentList documents;
	String stdlib_path;
	String compiler_path;
	long diag_delay_ms;
	Time last_diag_time;
	PublishedFiles diag_files;
	bool diag_pending;
	String diag_pending_uri;
	// Trailing-edge debounce state for the cheap lexer diagnostics on large files.
	bool lex_diag_pending;
	String lex_diag_pending_uri;
	Time last_lex_diag_time;
	// Persistent cache of tokenized on-disk files (project + stdlib), keyed by path+mtime.
	FileCache fcache;
}

fn void LspServer.init(&self, String stdlib_path, String compiler_path, long diag_delay_ms)
{
	*self = { .running = true, .stdlib_path = stdlib_path, .compiler_path = compiler_path, .diag_delay_ms = diag_delay_ms, };
	self.documents.init(mem);
	self.diag_files.init(mem);
	self.fcache.init(mem);
	// Publish the cache so the cross-file scan_dir_* helpers can consult it. The server
	// is a stable stack value for the whole program, so &self.fcache is valid for life.
	g_file_cache = &self.fcache;
}

alias HandlerFn = fn void(LspServer*, Object* msg, String id_json);

struct MethodHandler
{
	String method;
	HandlerFn handler;
}

// Method dispatch table. A null handler marks a deliberately ignored notification
// ("initialized"); unknown methods with an id get a -32601 error response.
const MethodHandler[] HANDLERS = {
	{ "initialize",                       &LspServer.handle_initialize },
	{ "initialized",                      null },
	{ "shutdown",                         &LspServer.handle_shutdown },
	{ "exit",                             &LspServer.handle_exit },
	{ "textDocument/didOpen",             &LspServer.handle_did_open },
	{ "textDocument/didChange",           &LspServer.handle_did_change },
	{ "textDocument/didClose",            &LspServer.handle_did_close },
	{ "textDocument/didSave",             &LspServer.handle_did_save },
	{ "textDocument/semanticTokens/full", &LspServer.handle_semantic_tokens },
	{ "textDocument/foldingRange",        &LspServer.handle_folding_range },
	{ "textDocument/documentSymbol",      &LspServer.handle_document_symbol },
	{ "textDocument/hover",               &LspServer.handle_hover },
	{ "textDocument/completion",          &LspServer.handle_completion },
	{ "textDocument/definition",          &LspServer.handle_definition },
	{ "textDocument/declaration",         &LspServer.handle_definition },
	{ "textDocument/documentHighlight",   &LspServer.handle_document_highlight },
	{ "textDocument/references",          &LspServer.handle_references },
	{ "textDocument/signatureHelp",       &LspServer.handle_signature_help },
	{ "textDocument/rename",              &LspServer.handle_rename },
};

fn void LspServer.handle_message(&self, String message)
{
	Object*? msg = json::tparse(message);
	if (catch msg) return;

	// Extract id as raw JSON string for responses
	String id_json = "null";
	DString id_buf = dstring::temp();
	if (try id_obj = msg.get("id"))
	{
		if (id_obj.is_string())
		{
			id_buf.appendf(`"%s"`, id_obj.s);
			id_json = id_buf.str_view();
		}
		else if (id_obj.is_float())
		{
			id_buf.appendf("%d", (int)id_obj.f);
			id_json = id_buf.str_view();
		}
		else if (id_obj.is_int())
		{
			id_buf.appendf("%d", (int)id_obj.i);
			id_json = id_buf.str_view();
		}
	}

	String method = msg.get_string("method") ?? "";

	bool dispatched = false;
	foreach (h : HANDLERS)
	{
		if (h.method == method)
		{
			if (h.handler != null) h.handler(self, msg, id_json);
			dispatched = true;
			break;
		}
	}
	if (!dispatched && id_json != "null")
	{
		send_error(id_json, -32601, "Method not found");
	}

	// Flush any compiler diagnostics that were throttled. The server blocks on
	// stdin, so we piggyback on incoming messages (e.g. didChange keystrokes) to
	// run a pending build once the throttle window has elapsed.
	self.flush_pending_diagnostics();
}

// Run throttled-and-deferred diagnostics whose delay windows have now elapsed. Called
// after every dispatched message; the server blocks on stdin, so we piggyback on
// incoming messages (e.g. didChange keystrokes) to run deferred work.
fn void LspServer.flush_pending_diagnostics(&self)
{
	Time now = time::now();
	Duration delay = time::ms(self.diag_delay_ms);

	// Deferred compiler diagnostics (project build).
	if (self.diag_pending)
	{
		Duration elapsed = now - self.last_diag_time;
		if ((long)elapsed >= (long)delay || (long)self.last_diag_time == 0)
		{
			self.diag_pending = false;
			self.publish_compiler_diagnostics(self.diag_pending_uri);
		}
	}

	// Deferred lexer diagnostics for large files (re-read the current content).
	if (self.lex_diag_pending)
	{
		Duration elapsed = now - self.last_lex_diag_time;
		if ((long)elapsed >= (long)delay || (long)self.last_lex_diag_time == 0)
		{
			self.lex_diag_pending = false;
			self.last_lex_diag_time = now;
			if (try d = self.documents.find(self.lex_diag_pending_uri))
			{
				publish_diagnostics(self.lex_diag_pending_uri, d.content);
			}
		}
	}
}
