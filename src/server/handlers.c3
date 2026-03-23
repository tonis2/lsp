module lsp;

import std::core::dstring;
import std::core::mem;
import std::collections::object;
import std::time;

const TOKEN_TYPES_LEGEND = `["namespace","type","enum","struct","variable","function","macro","keyword","decorator","comment","string","number","operator","enumMember"]`;

fn usz position_to_offset(String content, int line, int character)
{
	LineOffsets lo;
	lo.init(mem);
	defer lo.free();
	lo.build(content);
	if ((usz)line < lo.size) return lo.entries[(usz)line] + (usz)character;
	return 0;
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
		int delay = opts.get_int("diagnosticsDelay") ?? 0;
		if (delay > 0 && self.diag_delay_ms == 0)
		{
			self.diag_delay_ms = delay;
		}
		String sentry = opts.get_string("sentryDsn") ?? "";
		if (sentry.len > 0 && !self.sentry.enabled)
		{
			char[] copy = mem::new_array(char, sentry.len);
			copy[..] = sentry[..];
			self.sentry = parse_sentry_dsn((String)copy);
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
	result.append(`"documentHighlightProvider":true,`);
	result.append(`"referencesProvider":true,`);
	result.append(`"renameProvider":true,`);
	result.append(`"signatureHelpProvider":{"triggerCharacters":["(",","]}`);
	result.append(`},`);
	result.appendf(`"serverInfo":{"name":"c3-lsp","version":"%s"}}`, VERSION);

	send_response(id_json, result.str_view());
}

fn void LspServer.handle_shutdown(&self, String id_json)
{
	self.shutdown_requested = true;
	send_response(id_json, "null");
}

fn void LspServer.handle_exit(&self)
{
	self.running = false;
}

fn void LspServer.handle_did_open(&self, Object* msg)
{
	Object* td = msg.get("params")!!.get("textDocument")!!;
	String uri = td.get_string("uri") ?? "";
	String text = td.get_string("text") ?? "";
	int version = td.get_int("version") ?? 0;

	self.documents.open(uri, text, version);
	publish_diagnostics(uri, text);
	self.maybe_run_compiler_diagnostics(uri);
}

fn void LspServer.handle_did_change(&self, Object* msg)
{
	Object* params = msg.get("params")!!;
	Object* td = params.get("textDocument")!!;
	String uri = td.get_string("uri") ?? "";
	int version = td.get_int("version") ?? 0;

	Object* changes = params.get("contentChanges")!!;
	Object* first = changes.get_at(0);
	String text = first.get_string("text") ?? "";

	self.documents.update(uri, text, version);
	publish_diagnostics(uri, text);
}

fn void LspServer.handle_did_close(&self, Object* msg)
{
	Object* td = msg.get("params")!!.get("textDocument")!!;
	String uri = td.get_string("uri") ?? "";
	self.documents.close(uri);
}

fn void LspServer.handle_did_save(&self, Object* msg)
{
	Object* td = msg.get("params")!!.get("textDocument")!!;
	String uri = td.get_string("uri") ?? "";
	self.maybe_run_compiler_diagnostics(uri);
}

fn void LspServer.maybe_run_compiler_diagnostics(&self, String uri)
{
	// Throttle: only run if enough time has passed since last run
	if (self.diag_delay_ms > 0)
	{
		Time now = time::now();
		Duration elapsed = now - self.last_diag_time;
		Duration delay = time::ms(self.diag_delay_ms);
		if ((long)elapsed < (long)delay && (long)self.last_diag_time > 0)
		{
			return;
		}
	}
	self.publish_compiler_diagnostics(uri);
}

fn void LspServer.handle_semantic_tokens(&self, Object* msg, String id_json)
{
	Object* td = msg.get("params")!!.get("textDocument")!!;
	String uri = td.get_string("uri") ?? "";

	Document* doc = self.documents.find(uri);
	if (doc == null)
	{
		send_response(id_json, `{"data":[]}`);
		return;
	}

	DString data = dstring::temp();
	encode_semantic_tokens(doc.content, &data);

	DString result = dstring::temp();
	result.appendf(`{"data":[%s]}`, data.str_view());
	send_response(id_json, result.str_view());
}

fn void LspServer.handle_folding_range(&self, Object* msg, String id_json)
{
	Object* td = msg.get("params")!!.get("textDocument")!!;
	String uri = td.get_string("uri") ?? "";

	Document* doc = self.documents.find(uri);
	if (doc == null)
	{
		send_response(id_json, "[]");
		return;
	}

	DString data = dstring::temp();
	encode_folding_ranges(doc.content, &data);

	DString result = dstring::temp();
	result.appendf("[%s]", data.str_view());
	send_response(id_json, result.str_view());
}

fn void LspServer.handle_document_symbol(&self, Object* msg, String id_json)
{
	Object* td = msg.get("params")!!.get("textDocument")!!;
	String uri = td.get_string("uri") ?? "";

	Document* doc = self.documents.find(uri);
	if (doc == null)
	{
		send_response(id_json, "[]");
		return;
	}

	DString data = dstring::temp();
	encode_document_symbols(doc.content, &data);

	DString result = dstring::temp();
	result.appendf("[%s]", data.str_view());
	send_response(id_json, result.str_view());
}

fn void LspServer.handle_hover(&self, Object* msg, String id_json)
{
	Object* td = msg.get("params")!!.get("textDocument")!!;
	String uri = td.get_string("uri") ?? "";

	Document* doc = self.documents.find(uri);
	if (doc == null)
	{
		send_response(id_json, "null");
		return;
	}

	Object* pos = msg.get("params")!!.get("position")!!;
	int line = pos.get_int("line") ?? 0;
	int character = pos.get_int("character") ?? 0;

	usz offset = position_to_offset(doc.content, line, character);

	DString data = dstring::temp();
	encode_hover(uri, doc.content, offset, &self.documents, self.stdlib_path, &data);

	if (data.str_view().len == 0)
	{
		send_response(id_json, "null");
	}
	else
	{
		send_response(id_json, data.str_view());
	}
}

fn void LspServer.handle_completion(&self, Object* msg, String id_json)
{
	Object* td = msg.get("params")!!.get("textDocument")!!;
	String uri = td.get_string("uri") ?? "";

	Document* doc = self.documents.find(uri);
	if (doc == null)
	{
		send_response(id_json, `{"isIncomplete":false,"items":[]}`);
		return;
	}

	Object* pos = msg.get("params")!!.get("position")!!;
	int line = pos.get_int("line") ?? 0;
	int character = pos.get_int("character") ?? 0;

	usz offset = position_to_offset(doc.content, line, character);
	if (offset > doc.content.len)
	{
		offset = doc.content.len;
	}

	DString data = dstring::temp();
	encode_completions(doc.content, offset, &data);
	send_response(id_json, data.str_view());
}

fn void LspServer.handle_definition(&self, Object* msg, String id_json)
{
	Object* td = msg.get("params")!!.get("textDocument")!!;
	String uri = td.get_string("uri") ?? "";

	Document* doc = self.documents.find(uri);
	if (doc == null)
	{
		send_response(id_json, "null");
		return;
	}

	Object* pos = msg.get("params")!!.get("position")!!;
	int line = pos.get_int("line") ?? 0;
	int character = pos.get_int("character") ?? 0;

	usz offset = position_to_offset(doc.content, line, character);

	DString data = dstring::temp();
	encode_definition(uri, doc.content, offset, &self.documents, self.stdlib_path, &data);

	if (data.str_view().len == 0)
	{
		send_response(id_json, "null");
	}
	else
	{
		send_response(id_json, data.str_view());
	}
}

fn void LspServer.handle_signature_help(&self, Object* msg, String id_json)
{
	Object* td = msg.get("params")!!.get("textDocument")!!;
	String uri = td.get_string("uri") ?? "";

	Document* doc = self.documents.find(uri);
	if (doc == null)
	{
		send_response(id_json, "null");
		return;
	}

	Object* pos = msg.get("params")!!.get("position")!!;
	int line = pos.get_int("line") ?? 0;
	int character = pos.get_int("character") ?? 0;

	usz offset = position_to_offset(doc.content, line, character);

	DString data = dstring::temp();
	encode_signature_help(doc.content, offset, &data);

	if (data.str_view().len == 0)
	{
		send_response(id_json, "null");
	}
	else
	{
		send_response(id_json, data.str_view());
	}
}

fn void LspServer.handle_document_highlight(&self, Object* msg, String id_json)
{
	Object* td = msg.get("params")!!.get("textDocument")!!;
	String uri = td.get_string("uri") ?? "";

	Document* doc = self.documents.find(uri);
	if (doc == null)
	{
		send_response(id_json, "null");
		return;
	}

	Object* pos = msg.get("params")!!.get("position")!!;
	int line = pos.get_int("line") ?? 0;
	int character = pos.get_int("character") ?? 0;

	usz offset = position_to_offset(doc.content, line, character);

	DString data = dstring::temp();
	encode_document_highlights(doc.content, offset, &data);

	if (data.str_view().len == 0)
	{
		send_response(id_json, "null");
	}
	else
	{
		send_response(id_json, data.str_view());
	}
}

fn void LspServer.handle_references(&self, Object* msg, String id_json)
{
	Object* td = msg.get("params")!!.get("textDocument")!!;
	String uri = td.get_string("uri") ?? "";

	Document* doc = self.documents.find(uri);
	if (doc == null)
	{
		send_response(id_json, "null");
		return;
	}

	Object* pos = msg.get("params")!!.get("position")!!;
	int line = pos.get_int("line") ?? 0;
	int character = pos.get_int("character") ?? 0;

	usz offset = position_to_offset(doc.content, line, character);

	bool include_decl = true;
	if (try ctx = msg.get("params")!!.get("context"))
	{
		include_decl = (ctx.get_int("includeDeclaration") ?? 1) != 0;
	}

	DString data = dstring::temp();
	encode_references(uri, doc.content, offset, &self.documents, self.stdlib_path, include_decl, &data);

	if (data.str_view().len == 0)
	{
		send_response(id_json, "null");
	}
	else
	{
		send_response(id_json, data.str_view());
	}
}

fn void LspServer.handle_rename(&self, Object* msg, String id_json)
{
	Object* td = msg.get("params")!!.get("textDocument")!!;
	String uri = td.get_string("uri") ?? "";

	Document* doc = self.documents.find(uri);
	if (doc == null)
	{
		send_response(id_json, "null");
		return;
	}

	Object* pos = msg.get("params")!!.get("position")!!;
	int line = pos.get_int("line") ?? 0;
	int character = pos.get_int("character") ?? 0;

	String new_name = msg.get("params")!!.get_string("newName") ?? "";
	if (new_name.len == 0)
	{
		send_error(id_json, -32602, "newName is required");
		return;
	}

	usz offset = position_to_offset(doc.content, line, character);

	DString data = dstring::temp();
	encode_rename(uri, doc.content, offset, &self.documents, self.stdlib_path, new_name, &data);

	if (data.str_view().len == 0)
	{
		send_response(id_json, "null");
	}
	else
	{
		send_response(id_json, data.str_view());
	}
}
