module lsp;

import std::core::dstring;
import std::encoding::json;
import std::collections::object;
import std::time;

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
	SentryConfig sentry;
}

fn void LspServer.init(&self, String stdlib_path, String compiler_path, long diag_delay_ms, String sentry_dsn)
{
	*self = { .running = true, .stdlib_path = stdlib_path, .compiler_path = compiler_path, .diag_delay_ms = diag_delay_ms, .sentry = parse_sentry_dsn(sentry_dsn), };
	self.documents.init(mem);
}

fn void LspServer.handle_message(&self, String message)
{
	Object* msg = json::tparse_string(message) ?? null;
	if (msg == null)
	{
		self.sentry.capture_error("Failed to parse JSON message", "unknown");
		return;
	}

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

	if (method == "initialize")
	{
		self.handle_initialize(msg, id_json);
	}
	else if (method == "initialized")
	{
		// No-op notification
	}
	else if (method == "shutdown")
	{
		self.handle_shutdown(id_json);
	}
	else if (method == "exit")
	{
		self.handle_exit();
	}
	else if (method == "textDocument/didOpen")
	{
		self.handle_did_open(msg);
	}
	else if (method == "textDocument/didChange")
	{
		self.handle_did_change(msg);
	}
	else if (method == "textDocument/didClose")
	{
		self.handle_did_close(msg);
	}
	else if (method == "textDocument/didSave")
	{
		self.handle_did_save(msg);
	}
	else if (method == "textDocument/semanticTokens/full")
	{
		self.handle_semantic_tokens(msg, id_json);
	}
	else if (method == "textDocument/foldingRange")
	{
		self.handle_folding_range(msg, id_json);
	}
	else if (method == "textDocument/documentSymbol")
	{
		self.handle_document_symbol(msg, id_json);
	}
	else if (method == "textDocument/hover")
	{
		self.handle_hover(msg, id_json);
	}
	else if (method == "textDocument/completion")
	{
		self.handle_completion(msg, id_json);
	}
	else if (method == "textDocument/definition")
	{
		self.handle_definition(msg, id_json);
	}
	else if (method == "textDocument/declaration")
	{
		self.handle_definition(msg, id_json);
	}
	else if (method == "textDocument/documentHighlight")
	{
		self.handle_document_highlight(msg, id_json);
	}
	else if (method == "textDocument/references")
	{
		self.handle_references(msg, id_json);
	}
	else if (method == "textDocument/signatureHelp")
	{
		self.handle_signature_help(msg, id_json);
	}
	else if (method == "textDocument/rename")
	{
		self.handle_rename(msg, id_json);
	}
	else if (id_json != "null")
	{
		send_error(id_json, -32601, "Method not found");
	}
}
