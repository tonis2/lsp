module lsp;

import std::core::dstring;
import std::core::mem;
import std::os::process;
import std::time;

const usz COMPILER_OUTPUT_BUFFER = 65536;
const usz MAX_COMPILER_DIAGNOSTICS = 50;

// Run c3c compile-only with --lsp flag on the file and publish diagnostics.
// The file URI is converted to a path and the on-disk file is compiled.
fn void publish_compiler_diagnostics(LspServer* server, String uri) {
	String path = uri_to_path(uri);
	if (path.len == 0) return;

	// Build command line
	String[8] cmd;
	usz cmd_len = 0;
	cmd[cmd_len++] = "c3c";
	cmd[cmd_len++] = "compile-only";
	cmd[cmd_len++] = "-C";
	cmd[cmd_len++] = "--lsp";
	if (server.stdlib_path.len > 0) {
		cmd[cmd_len++] = "--stdlib";
		cmd[cmd_len++] = server.stdlib_path;
	}
	cmd[cmd_len++] = path;

	SubProcess proc;
	if (try p = process::create(cmd[:cmd_len], { .search_user_path = true, .combined_stdout_stderr = true })) {
		proc = p;
	} else {
		return;
	}
	if (catch proc.join()) {
		proc.destroy();
		return;
	}

	char[] buf = mem::new_array(char, COMPILER_OUTPUT_BUFFER);
	defer mem::free(buf);
	usz total_read = 0;
	while (total_read < COMPILER_OUTPUT_BUFFER) {
		usz n = proc.read_stdout(&buf[total_read], COMPILER_OUTPUT_BUFFER - total_read) ?? 0;
		if (n == 0) break;
		total_read += n;
	}
	proc.destroy();

	String output = (String)buf[:total_read];

	DString diags = dstring::temp();
	diags.append_char('[');
	int diag_count = 0;

	// Parse LSPERR lines: LSPERR|severity|"file"|line|col|"message"
	usz pos = 0;
	while (pos < output.len && diag_count < MAX_COMPILER_DIAGNOSTICS) {
		// Find next line
		usz line_end = pos;
		while (line_end < output.len && output[line_end] != '\n') {
			line_end++;
		}
		String line = output[pos..line_end > pos ? line_end - 1 : pos];
		pos = line_end + 1;

		// Strip leading "> " if present
		if (line.len >= 2 && line[0] == '>' && line[1] == ' ') {
			line = line[2..];
		}

		if (!line.starts_with("LSPERR|")) continue;

		// Parse: LSPERR|severity|"file"|line|col|"message"
		String rest = line[7..]; // after "LSPERR|"

		// Extract severity
		String severity_str;
		String file_str;
		String line_str;
		String col_str;
		String msg_str;

		if (try sep1 = rest.index_of_char('|')) {
			severity_str = rest[:sep1];
			rest = rest[sep1 + 1..];
		} else {
			continue;
		}

		// Extract file (quoted)
		if (rest.len > 0 && rest[0] == '"') {
			if (try end_quote = rest[1..].index_of_char('"')) {
				file_str = rest[1..end_quote];
				rest = rest[end_quote + 2..]; // skip closing quote
				if (rest.len > 0 && rest[0] == '|') {
					rest = rest[1..];
				}
			} else {
				continue;
			}
		} else {
			continue;
		}

		// Extract line number
		if (try sep = rest.index_of_char('|')) {
			line_str = rest[:sep];
			rest = rest[sep + 1..];
		} else {
			continue;
		}

		// Extract column
		if (try sep = rest.index_of_char('|')) {
			col_str = rest[:sep];
			rest = rest[sep + 1..];
		} else {
			continue;
		}

		// Extract message (quoted)
		if (rest.len >= 2 && rest[0] == '"' && rest[rest.len - 1] == '"') {
			msg_str = rest[1..rest.len - 2];
		} else {
			msg_str = rest;
		}

		// Convert line/col to 0-indexed
		int diag_line = (int)(line_str.to_uint() ?? 1) - 1;
		int diag_col = (int)(col_str.to_uint() ?? 1) - 1;
		if (diag_line < 0) diag_line = 0;
		if (diag_col < 0) diag_col = 0;

		// Map severity
		int sev = 1; // error
		if (severity_str == "warning") {
			sev = 2;
		} else if (severity_str == "note" || severity_str == "info") {
			sev = 3;
		}

		if (diag_count > 0) diags.append_char(',');
		diags.append(`{"range":{"start":{"line":`);
		diags.appendf("%d", diag_line);
		diags.append(`,"character":`);
		diags.appendf("%d", diag_col);
		diags.append(`},"end":{"line":`);
		diags.appendf("%d", diag_line);
		diags.append(`,"character":`);
		diags.appendf("%d", diag_col + 1);
		diags.append(`}},"severity":`);
		diags.appendf("%d", sev);
		diags.append(`,"source":"c3c","message":"`);
		json_escape_into(&diags, msg_str);
		diags.append(`"}`);
		diag_count++;
	}

	diags.append_char(']');

	DString params = dstring::temp();
	params.append(`{"uri":"`);
	json_escape_into(&params, uri);
	params.append(`","diagnostics":`);
	params.append(diags.str_view());
	params.append_char('}');

	send_notification("textDocument/publishDiagnostics", params.str_view());

	// Update last diagnostics time
	server.last_diag_time = time::now();
}

// Convert file:// URI to filesystem path.
fn String uri_to_path(String uri) {
	if (uri.starts_with("file:///")) {
		return uri[7..]; // "file:///path" -> "/path"
	}
	if (uri.starts_with("file://")) {
		return uri[7..];
	}
	return "";
}
