module lsp;

import std::core::dstring;
import std::core::mem;
import std::io::file;
import std::os::process;
import std::time;

const usz COMPILER_OUTPUT_BUFFER   = 65536;
const usz MAX_COMPILER_DIAGNOSTICS = 50;

// Run c3c build -C --lsp from the project root and publish diagnostics.
// Falls back to compile-only for standalone files with no project.json.
fn void LspServer.publish_compiler_diagnostics(&self, String uri)
{
	String path = uri_to_path(uri);
	if (path.len == 0) return;

	// Find project root by walking up from file looking for project.json
	ProjectDirs pdirs;
	pdirs.get_search_dirs(path);
	String project_root = pdirs.project_root;

	// Build command line
	String[10] cmd;
	usz cmd_len = 0;
	cmd[cmd_len++] = self.compiler_path;

	if (project_root.len > 0)
	{
		// Project-level build: checks all files together
		cmd[cmd_len++] = "build";
		cmd[cmd_len++] = "-C";
		cmd[cmd_len++] = "--lsp";
		cmd[cmd_len++] = "--path";
		cmd[cmd_len++] = project_root;
	}
	else
	{
		// Standalone file: compile-only
		cmd[cmd_len++] = "compile-only";
		cmd[cmd_len++] = "-C";
		cmd[cmd_len++] = "--lsp";
		cmd[cmd_len++] = path;
	}

	if (self.stdlib_path.len > 0)
	{
		cmd[cmd_len++] = "--stdlib";
		cmd[cmd_len++] = self.stdlib_path;
	}

	SubProcess proc;
	if (try p = process::create(cmd[:cmd_len], { .search_user_path = true, .combined_stdout_stderr = true }))
	{
		proc = p;
	}
	else
	{
		DString errmsg = dstring::temp();
		errmsg.append(`{"type":1,"message":"c3-lsp: failed to run '`);
		json_escape_into(&errmsg, self.compiler_path);
		errmsg.append(`'. Make sure c3c is in your PATH or set compiler-path."}`);
		send_notification("window/showMessage", errmsg.str_view());
		self.sentry.capture_error("Failed to spawn compiler process", "textDocument/publishDiagnostics");
		return;
	}
	if (catch proc.join())
	{
		self.sentry.capture_error("Compiler process join failed", "textDocument/publishDiagnostics");
		proc.destroy();
		return;
	}

	char[] buf = mem::new_array(char, COMPILER_OUTPUT_BUFFER);
	defer mem::free(buf);
	usz total_read = 0;
	while (total_read < COMPILER_OUTPUT_BUFFER)
	{
		usz n = proc.read_stdout(&buf[total_read], COMPILER_OUTPUT_BUFFER - total_read) ?? 0;
		if (n == 0) break;
		total_read += n;
	}
	proc.destroy();

	String output = (String)buf[:total_read];

	// Collect diagnostics per file, but only publish for the triggering URI.
	// Also clear diagnostics when there are no errors for this file.
	DString diags = dstring::temp();
	diags.append_char('[');
	int diag_count = 0;

	// Parse LSPERR lines: LSPERR|severity|"file"|line|col|"message"
	usz pos = 0;
	while (pos < output.len && diag_count < MAX_COMPILER_DIAGNOSTICS)
	{
		// Find next line
		usz line_end = pos;
		while (line_end < output.len && output[line_end] != '\n')
		{
			line_end++;
		}
		String line = output[pos:line_end - pos];
		pos = line_end + 1;

		// Strip leading "> " if present
		if (line.len >= 2 && line[0] == '>' && line[1] == ' ')
		{
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

		if (try sep1 = rest.index_of_char('|'))
		{
			severity_str = rest[:sep1];
			rest = rest[sep1 + 1..];
		}
		else
		{
			continue;
		}

		// Extract file (quoted)
		if (rest.len > 0 && rest[0] == '"')
		{
			if (try end_quote = rest[1..].index_of_char('"'))
			{
				file_str = rest[1:end_quote];
				rest = rest[end_quote + 2..]; // skip closing quote
				if (rest.len > 0 && rest[0] == '|')
				{
					rest = rest[1..];
				}
			}
			else
			{
				continue;
			}
		}
		else
		{
			continue;
		}

		// Only collect diagnostics for the file that triggered the build
		if (!path_matches_uri(file_str, uri)) continue;

		// Extract line number
		if (try sep = rest.index_of_char('|'))
		{
			line_str = rest[:sep];
			rest = rest[sep + 1..];
		}
		else
		{
			continue;
		}

		// Extract column
		if (try sep = rest.index_of_char('|'))
		{
			col_str = rest[:sep];
			rest = rest[sep + 1..];
		}
		else
		{
			continue;
		}

		// Extract message (quoted)
		if (rest.len >= 2 && rest[0] == '"' && rest[rest.len - 1] == '"')
		{
			msg_str = rest[1:rest.len - 2];
		}
		else
		{
			msg_str = rest;
		}

		// Convert line/col to 0-indexed
		int diag_line = (int)(line_str.to_uint() ?? 1) - 1;
		int diag_col = (int)(col_str.to_uint() ?? 1) - 1;
		if (diag_line < 0) diag_line = 0;
		if (diag_col < 0) diag_col = 0;

		// Map severity
		int sev = 1; // error
		if (severity_str == "warning")
		{
			sev = 2;
		}
		else if (severity_str == "note" || severity_str == "info")
		{
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
	self.last_diag_time = time::now();
}

// Check if a filesystem path matches a file:// URI.
// Compares from the end to handle symlink prefix differences
// (e.g. /home/user vs /var/home/user).
// Treats / and \ as equivalent (file_path may use \ on Windows).
fn bool path_matches_uri(String file_path, String uri) @private
{
	String uri_path = uri_to_path(uri);
	if (file_path == uri_path) return true;
	if (file_path.len == 0 || uri_path.len == 0) return false;

	// Count matching characters from the end, treating / and \ as equal
	usz fi = file_path.len;
	usz ui = uri_path.len;
	while (fi > 0 && ui > 0)
	{
		char fc = file_path[fi - 1];
		char uc = uri_path[ui - 1];
		if (fc == uc || (is_path_separator(fc) && is_path_separator(uc)))
		{
			fi--;
			ui--;
		}
		else
		{
			break;
		}
	}
	usz matched = file_path.len - fi;
	if (matched == 0) return false;

	// The divergence point must be at a separator boundary in both paths
	if (fi != 0 && !is_path_separator(file_path[fi])) return false;
	if (ui != 0 && !is_path_separator(uri_path[ui])) return false;

	// The matched suffix must contain at least one separator (filename + directory)
	for (usz k = fi; k < file_path.len; k++)
	{
		if (is_path_separator(file_path[k])) return true;
	}
	return false;
}

// Append a file:// URI for a filesystem path to a DString.
// For Windows drive-letter paths (C:/foo), uses file:///C:/foo.
// For Unix paths (/home/foo), uses file:///home/foo (file:// + /home/foo).
fn void append_file_uri(DString* out, String path)
{
	if (is_windows_drive_path(path))
	{
		out.append("file:///");
	}
	else
	{
		out.append("file://");
	}
	out.append(path);
}

// Convert file:// URI to filesystem path.
// On Windows, file:///C:/foo -> C:/foo (strips the leading / before drive letter).
// On Unix, file:///home/foo -> /home/foo (unchanged).
fn String uri_to_path(String uri)
{
	if (uri.starts_with("file:///"))
	{
		String result = uri[7..]; // "file:///path" -> "/path"
		// Strip leading / before Windows drive letter: /C:/foo -> C:/foo
		if (result.len >= 3 && is_windows_drive_path(result[1..]))
		{
			return result[1..];
		}
		return result;
	}
	if (uri.starts_with("file://"))
	{
		return uri[7..];
	}
	return "";
}
