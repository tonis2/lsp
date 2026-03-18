module lsp;

import std::core::dstring;
import c3::lexer;

const MAX_DIAGNOSTICS = 20;

fn void publish_diagnostics(String uri, String content) {
	DString diags = dstring::temp();
	diags.append_char('[');
	int diag_count = 0;

	Lexer lex;
	lex.init(content);

	while (true) {
		if (try tok = lex.next()) {
			continue;
		} else {
			// EOF — done lexing
			if (lex.at_end()) break;

			if (diag_count >= MAX_DIAGNOSTICS) {
				lex.pos++;
				lex.col++;
				continue;
			}

			// Lexer ln/col are 1-indexed, LSP wants 0-indexed
			usz line = lex.ln > 0 ? lex.ln - 1 : 0;
			usz col = lex.col > 0 ? lex.col - 1 : 0;

			if (diag_count > 0) diags.append_char(',');

			diags.append(`{"range":{"start":{"line":`);
			diags.appendf("%d", line);
			diags.append(`,"character":`);
			diags.appendf("%d", col);
			diags.append(`},"end":{"line":`);
			diags.appendf("%d", line);
			diags.append(`,"character":`);
			diags.appendf("%d", col + 1);
			diags.append(`}},"severity":1,"source":"c3-lsp","message":"Invalid character"}`);

			diag_count++;

			// Skip the bad byte so lexer can continue
			lex.pos++;
			lex.col++;
		}
	}

	diags.append_char(']');

	DString params = dstring::temp();
	params.append(`{"uri":"`);
	json_escape_into(&params, uri);
	params.append(`","diagnostics":`);
	params.append(diags.str_view());
	params.append_char('}');

	send_notification("textDocument/publishDiagnostics", params.str_view());
}
