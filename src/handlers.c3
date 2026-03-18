module lsp;

import std::core::dstring;
import std::core::mem;
import std::collections::object;
import std::time;

const TOKEN_TYPES_LEGEND = `["namespace","type","enum","struct","variable","function","macro","keyword","decorator","comment","string","number","operator"]`;

fn void handle_initialize(LspServer* server, Object* msg, String id_json) {
	server.initialized = true;

	// Extract initializationOptions if provided by the client
	if (try opts = msg.get("params")!!.get("initializationOptions")) {
		String stdlib = opts.get_string("stdlib") ?? "";
		if (stdlib.len > 0 && server.stdlib_path.len == 0) {
			// Client-provided stdlib overrides only if not set via CLI
			char[] copy = mem::new_array(char, stdlib.len);
			copy[..] = stdlib[..];
			server.stdlib_path = (String)copy;
		}
		int delay = opts.get_int("diagnosticsDelay") ?? 0;
		if (delay > 0 && server.diag_delay_ms == 0) {
			server.diag_delay_ms = delay;
		}
	}

	DString result = dstring::temp();
	result.append(`{"capabilities":{`);
	result.append(`"textDocumentSync":{"openClose":true,"change":1,"save":true},`);
	result.append(`"semanticTokensProvider":{`);
	result.append(`"legend":{"tokenTypes":`);
	result.append(TOKEN_TYPES_LEGEND);
	result.append(`,"tokenModifiers":[]},`);
	result.append(`"full":true`);
	result.append(`},`);
	result.append(`"foldingRangeProvider":true,`);
	result.append(`"documentSymbolProvider":true,`);
	result.append(`"hoverProvider":true,`);
	result.append(`"completionProvider":{"triggerCharacters":[".","$","@","#"]},`);
	result.append(`"definitionProvider":true,`);
	result.append(`"declarationProvider":true,`);
	result.append(`"signatureHelpProvider":{"triggerCharacters":["(",","]}`);
	result.append(`},`);
	result.append(`"serverInfo":{"name":"c3-lsp","version":"0.1.0"}}`);

	send_response(id_json, result.str_view());
}

fn void handle_shutdown(LspServer* server, String id_json) {
	server.shutdown_requested = true;
	send_response(id_json, "null");
}

fn void handle_exit(LspServer* server) {
	server.running = false;
}

fn void handle_did_open(LspServer* server, Object* msg) {
	Object* td = msg.get("params")!!.get("textDocument")!!;
	String uri = td.get_string("uri") ?? "";
	String text = td.get_string("text") ?? "";
	int version = td.get_int("version") ?? 0;

	server.documents.open(uri, text, version);
	publish_diagnostics(uri, text);
	maybe_run_compiler_diagnostics(server, uri);
}

fn void handle_did_change(LspServer* server, Object* msg) {
	Object* params = msg.get("params")!!;
	Object* td = params.get("textDocument")!!;
	String uri = td.get_string("uri") ?? "";
	int version = td.get_int("version") ?? 0;

	Object* changes = params.get("contentChanges")!!;
	Object* first = changes.get_at(0);
	String text = first.get_string("text") ?? "";

	server.documents.update(uri, text, version);
	publish_diagnostics(uri, text);
}

fn void handle_did_close(LspServer* server, Object* msg) {
	Object* td = msg.get("params")!!.get("textDocument")!!;
	String uri = td.get_string("uri") ?? "";
	server.documents.close(uri);
}

fn void handle_did_save(LspServer* server, Object* msg) {
	Object* td = msg.get("params")!!.get("textDocument")!!;
	String uri = td.get_string("uri") ?? "";
	maybe_run_compiler_diagnostics(server, uri);
}

fn void maybe_run_compiler_diagnostics(LspServer* server, String uri) {
	// Throttle: only run if enough time has passed since last run
	if (server.diag_delay_ms > 0) {
		Time now = time::now();
		Duration elapsed = now - server.last_diag_time;
		Duration delay = time::ms(server.diag_delay_ms);
		if ((long)elapsed < (long)delay && (long)server.last_diag_time > 0) {
			return;
		}
	}
	publish_compiler_diagnostics(server, uri);
}

fn void handle_semantic_tokens(LspServer* server, Object* msg, String id_json) {
	Object* td = msg.get("params")!!.get("textDocument")!!;
	String uri = td.get_string("uri") ?? "";

	Document* doc = server.documents.get(uri);
	if (doc == null) {
		send_response(id_json, `{"data":[]}`);
		return;
	}

	DString data = dstring::temp();
	encode_semantic_tokens(doc.content, &data);

	DString result = dstring::temp();
	result.appendf(`{"data":[%s]}`, data.str_view());
	send_response(id_json, result.str_view());
}

fn void handle_folding_range(LspServer* server, Object* msg, String id_json) {
	Object* td = msg.get("params")!!.get("textDocument")!!;
	String uri = td.get_string("uri") ?? "";

	Document* doc = server.documents.get(uri);
	if (doc == null) {
		send_response(id_json, "[]");
		return;
	}

	DString data = dstring::temp();
	encode_folding_ranges(doc.content, &data);

	DString result = dstring::temp();
	result.appendf("[%s]", data.str_view());
	send_response(id_json, result.str_view());
}

fn void handle_document_symbol(LspServer* server, Object* msg, String id_json) {
	Object* td = msg.get("params")!!.get("textDocument")!!;
	String uri = td.get_string("uri") ?? "";

	Document* doc = server.documents.get(uri);
	if (doc == null) {
		send_response(id_json, "[]");
		return;
	}

	DString data = dstring::temp();
	encode_document_symbols(doc.content, &data);

	DString result = dstring::temp();
	result.appendf("[%s]", data.str_view());
	send_response(id_json, result.str_view());
}

fn void handle_hover(LspServer* server, Object* msg, String id_json) {
	Object* td = msg.get("params")!!.get("textDocument")!!;
	String uri = td.get_string("uri") ?? "";

	Document* doc = server.documents.get(uri);
	if (doc == null) {
		send_response(id_json, "null");
		return;
	}

	Object* pos = msg.get("params")!!.get("position")!!;
	int line = pos.get_int("line") ?? 0;
	int character = pos.get_int("character") ?? 0;

	LineOffsets* lo = mem::new(LineOffsets);
	defer mem::free(lo);
	build_line_offsets(doc.content, lo);

	usz offset = 0;
	if ((usz)line < lo.count) {
		offset = lo.offsets[(usz)line] + (usz)character;
	}

	DString data = dstring::temp();
	encode_hover(doc.content, offset, &data);

	if (data.str_view().len == 0) {
		send_response(id_json, "null");
	} else {
		send_response(id_json, data.str_view());
	}
}

fn void handle_completion(LspServer* server, Object* msg, String id_json) {
	Object* td = msg.get("params")!!.get("textDocument")!!;
	String uri = td.get_string("uri") ?? "";

	Document* doc = server.documents.get(uri);
	if (doc == null) {
		send_response(id_json, `{"isIncomplete":false,"items":[]}`);
		return;
	}

	Object* pos = msg.get("params")!!.get("position")!!;
	int line = pos.get_int("line") ?? 0;
	int character = pos.get_int("character") ?? 0;

	LineOffsets* lo = mem::new(LineOffsets);
	defer mem::free(lo);
	build_line_offsets(doc.content, lo);

	usz offset = 0;
	if ((usz)line < lo.count) {
		offset = lo.offsets[(usz)line] + (usz)character;
	}
	if (offset > doc.content.len) {
		offset = doc.content.len;
	}

	DString data = dstring::temp();
	encode_completions(doc.content, offset, &data);
	send_response(id_json, data.str_view());
}

fn void handle_definition(LspServer* server, Object* msg, String id_json) {
	Object* td = msg.get("params")!!.get("textDocument")!!;
	String uri = td.get_string("uri") ?? "";

	Document* doc = server.documents.get(uri);
	if (doc == null) {
		send_response(id_json, "null");
		return;
	}

	Object* pos = msg.get("params")!!.get("position")!!;
	int line = pos.get_int("line") ?? 0;
	int character = pos.get_int("character") ?? 0;

	LineOffsets* lo = mem::new(LineOffsets);
	defer mem::free(lo);
	build_line_offsets(doc.content, lo);

	usz offset = 0;
	if ((usz)line < lo.count) {
		offset = lo.offsets[(usz)line] + (usz)character;
	}

	DString data = dstring::temp();
	encode_definition(uri, doc.content, offset, &data);

	if (data.str_view().len == 0) {
		send_response(id_json, "null");
	} else {
		send_response(id_json, data.str_view());
	}
}

fn void handle_signature_help(LspServer* server, Object* msg, String id_json) {
	Object* td = msg.get("params")!!.get("textDocument")!!;
	String uri = td.get_string("uri") ?? "";

	Document* doc = server.documents.get(uri);
	if (doc == null) {
		send_response(id_json, "null");
		return;
	}

	Object* pos = msg.get("params")!!.get("position")!!;
	int line = pos.get_int("line") ?? 0;
	int character = pos.get_int("character") ?? 0;

	LineOffsets* lo = mem::new(LineOffsets);
	defer mem::free(lo);
	build_line_offsets(doc.content, lo);

	usz offset = 0;
	if ((usz)line < lo.count) {
		offset = lo.offsets[(usz)line] + (usz)character;
	}

	DString data = dstring::temp();
	encode_signature_help(doc.content, offset, &data);

	if (data.str_view().len == 0) {
		send_response(id_json, "null");
	} else {
		send_response(id_json, data.str_view());
	}
}
