module lsp;

import std::core::dstring;
import std::collections::object;

const TOKEN_TYPES_LEGEND = `["namespace","type","enum","struct","variable","function","macro","keyword","decorator","comment","string","number","operator"]`;

fn void handle_initialize(LspServer* server, String id_json) {
	server.initialized = true;

	DString result = dstring::temp();
	result.append(`{"capabilities":{`);
	result.append(`"textDocumentSync":1,`);
	result.append(`"semanticTokensProvider":{`);
	result.append(`"legend":{"tokenTypes":`);
	result.append(TOKEN_TYPES_LEGEND);
	result.append(`,"tokenModifiers":[]},`);
	result.append(`"full":true`);
	result.append(`}},`);
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
