module lsp;

import std::core::dstring;
import std::encoding::json;
import std::collections::object;

struct LspServer {
	bool initialized;
	bool shutdown_requested;
	bool running;
	DocumentStore documents;
}

fn void LspServer.init(&self) {
	*self = { .running = true };
}

fn void handle_message(LspServer* server, String message) {
	Object* msg = json::tparse_string(message) ?? null;
	if (msg == null) return;

	// Extract id as raw JSON string for responses
	String id_json = "null";
	DString id_buf = dstring::temp();
	if (try id_obj = msg.get("id")) {
		if (id_obj.is_string()) {
			id_buf.appendf(`"%s"`, id_obj.s);
			id_json = id_buf.str_view();
		} else if (id_obj.is_float()) {
			id_buf.appendf("%d", (int)id_obj.f);
			id_json = id_buf.str_view();
		} else if (id_obj.is_int()) {
			id_buf.appendf("%d", (int)id_obj.i);
			id_json = id_buf.str_view();
		}
	}

	String method = msg.get_string("method") ?? "";

	if (method == "initialize") {
		handle_initialize(server, id_json);
	} else if (method == "initialized") {
		// No-op notification
	} else if (method == "shutdown") {
		handle_shutdown(server, id_json);
	} else if (method == "exit") {
		handle_exit(server);
	} else if (method == "textDocument/didOpen") {
		handle_did_open(server, msg);
	} else if (method == "textDocument/didChange") {
		handle_did_change(server, msg);
	} else if (method == "textDocument/didClose") {
		handle_did_close(server, msg);
	} else if (method == "textDocument/semanticTokens/full") {
		handle_semantic_tokens(server, msg, id_json);
	} else if (method == "textDocument/foldingRange") {
		handle_folding_range(server, msg, id_json);
	} else if (method == "textDocument/documentSymbol") {
		handle_document_symbol(server, msg, id_json);
	} else if (method == "textDocument/hover") {
		handle_hover(server, msg, id_json);
	} else if (method == "textDocument/completion") {
		handle_completion(server, msg, id_json);
	} else if (id_json != "null") {
		send_error(id_json, -32601, "Method not found");
	}
}
