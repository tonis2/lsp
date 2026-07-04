module lsp;

import std::core::dstring;
import std::core::mem;
import std::collections::list;
import std::io::file;
import std::os::process;
import std::time;

const sz COMPILER_OUTPUT_BUFFER   = 65536;
const sz MAX_COMPILER_DIAGNOSTICS = 50;

// A single parsed c3c diagnostic. `file` and `message` reference temp/buffer
// memory valid only for the duration of publish_compiler_diagnostics.
struct CompilerDiag
{
	String file;    // resolved absolute path (separators normalized to '/')
	int line;       // 0-indexed
	int col;        // 0-indexed
	int severity;   // LSP DiagnosticSeverity (1=error, 2=warning, 3=info)
	String message; // raw message text (slice into compiler output)
}

alias CompilerDiagList = List{CompilerDiag};

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
	sz cmd_len = 0;
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

	Process proc;
	if (try p = process::spawn(cmd[:cmd_len], STDERR_TO_STDOUT))
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
		return;
	}
	if (catch proc.join())
	{
		proc.destroy();
		return;
	}

	char[] buf = mem::new_array(char, COMPILER_OUTPUT_BUFFER);
	defer mem::free(buf);
	sz total_read = 0;
	while (total_read < COMPILER_OUTPUT_BUFFER)
	{
		sz n = proc.read_stdout(&buf[total_read], COMPILER_OUTPUT_BUFFER - total_read) ?? 0;
		if (n == 0) break;
		total_read += n;
	}
	proc.destroy();

	String output = (String)buf[:total_read];

	// A project build reports diagnostics across all files, so parse every
	// LSPERR line and publish per file (and clear files that no longer have
	// errors) rather than only the triggering URI. This is what keeps stale
	// errors from sticking in the editor when they are fixed.
	CompilerDiagList diags;
	diags.tinit();
	diags.parse(output, project_root);

	self.publish_grouped_diagnostics(&diags);

	// Update last diagnostics time
	self.last_diag_time = time::now();
}

// Parse all LSPERR lines from c3c output into a flat diagnostics list.
// Format per line (optionally prefixed with "> "):
//   LSPERR|severity|"file"|line|col|"message"
// File paths are resolved to file:// URIs; relative paths are joined to
// project_root. Capped at MAX_COMPILER_DIAGNOSTICS total.
fn void CompilerDiagList.parse(&self, String output, String project_root)
{
	sz pos = 0;
	while (pos < output.len && self.len() < MAX_COMPILER_DIAGNOSTICS)
	{
		// Find next line
		sz line_end = pos;
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

		String severity_str;
		String file_str;
		String line_str;
		String col_str;
		String msg_str;

		// Extract severity
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

		self.push({ .file = resolve_compiler_path(file_str, project_root), .line = diag_line, .col = diag_col, .severity = sev, .message = msg_str });
	}
}

// Publish one textDocument/publishDiagnostics per file with errors, then clear
// (publish an empty array for) any file that had diagnostics on the previous
// run but no longer does. self.diag_files tracks the current set of error files.
fn void LspServer.publish_grouped_diagnostics(&self, CompilerDiagList* diags)
{
	// Distinct URIs that have errors this run.
	List{String} current;
	current.tinit();

	foreach (d : *diags)
	{
		// Publish under the open document's own URI when the file is open, so the
		// editor matches the diagnostics to the buffer and shows inline markers
		// (the document URI may differ from the compiler path via symlinks).
		String uri = self.document_uri_for_path(d.file);
		if (current.contains(uri)) continue;
		current.push(uri);

		DString arr = dstring::temp();
		arr.append_char('[');
		int n = 0;
		foreach (d2 : *diags)
		{
			if (d2.file != d.file) continue;
			if (n > 0) arr.append_char(',');
			d2.encode(&arr);
			n++;
		}
		arr.append_char(']');
		publish_file_diagnostics(uri, arr.str_view());
	}

	// Clear files that previously had diagnostics but no longer do.
	foreach (old_uri : self.diag_files)
	{
		if (!current.contains(old_uri))
		{
			publish_file_diagnostics(old_uri, "[]");
		}
	}

	// Rebuild the persistent set with owned copies of the current error URIs.
	foreach (old_uri : self.diag_files)
	{
		if (old_uri.len > 0) mem::free((char*)old_uri.ptr);
	}
	self.diag_files.clear();
	foreach (u : current)
	{
		char[] copy = mem::new_array(char, u.len);
		copy[..] = u[..];
		self.diag_files.push((String)copy);
	}
}

// Append a single diagnostic object (LSP Diagnostic) as JSON.
fn void CompilerDiag.encode(&self, DString* out)
{
	out.append(`{"range":{"start":{"line":`);
	out.appendf("%d", self.line);
	out.append(`,"character":`);
	out.appendf("%d", self.col);
	out.append(`},"end":{"line":`);
	out.appendf("%d", self.line);
	out.append(`,"character":`);
	out.appendf("%d", self.col + 1);
	out.append(`}},"severity":`);
	out.appendf("%d", self.severity);
	out.append(`,"source":"c3c","message":"`);
	json_escape_into(out, self.message);
	out.append(`"}`);
}

// Send a publishDiagnostics notification for a single file URI.
fn void publish_file_diagnostics(String uri, String diags_array) @private
{
	DString params = dstring::temp();
	params.append(`{"uri":"`);
	json_escape_into(&params, uri);
	params.append(`","diagnostics":`);
	params.append(diags_array);
	params.append_char('}');
	send_notification("textDocument/publishDiagnostics", params.str_view());
}

// Resolve a file path from c3c output to an absolute path with separators
// normalized to '/'. Relative paths are joined to project_root.
fn String resolve_compiler_path(String file_str, String project_root) @private
{
	DString abs = dstring::temp();
	if (file_str.len > 0 && (is_path_separator(file_str[0]) || is_windows_drive_path(file_str)))
	{
		abs.append(file_str);
	}
	else if (project_root.len > 0)
	{
		abs.append(project_root);
		abs.append_char('/');
		abs.append(file_str);
	}
	else
	{
		abs.append(file_str);
	}

	DString norm = dstring::temp();
	foreach (c : abs.str_view())
	{
		norm.append_char(is_path_separator(c) ? '/' : c);
	}
	return norm.str_view();
}

// Pick the URI to publish diagnostics under for a resolved file path. If the
// file is currently open, return that document's exact URI (so the editor
// associates the diagnostics with its buffer and renders inline markers, even
// when the document URI differs from the compiler path via symlinks). Otherwise
// build a file:// URI from the path.
fn String LspServer.document_uri_for_path(&self, String file_path)
{
	foreach (doc : self.documents)
	{
		if (path_matches_uri(file_path, doc.uri)) return doc.uri;
	}
	DString u = dstring::temp();
	append_file_uri(&u, file_path);
	return u.str_view();
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
	sz fi = file_path.len;
	sz ui = uri_path.len;
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
	sz matched = file_path.len - fi;
	if (matched == 0) return false;

	// The divergence point must be at a separator boundary in both paths
	if (fi != 0 && !is_path_separator(file_path[fi])) return false;
	if (ui != 0 && !is_path_separator(uri_path[ui])) return false;

	// The matched suffix must contain at least one separator (filename + directory)
	for (sz k = fi; k < file_path.len; k++)
	{
		if (is_path_separator(file_path[k])) return true;
	}
	return false;
}

// Decode a single hex character to its numeric value (0-15), or -1 if invalid.
fn int hex_val(char c) @private
{
	if (c >= '0' && c <= '9') return c - '0';
	if (c >= 'a' && c <= 'f') return c - 'a' + 10;
	if (c >= 'A' && c <= 'F') return c - 'A' + 10;
	return -1;
}

// Decode percent-encoded sequences in a URI path (e.g. %20 -> space).
// Returns a temp-allocated string.
fn String percent_decode(String s) @private
{
	// Quick check: if no %, return as-is
	bool has_pct = false;
	foreach (c : s) { if (c == '%') { has_pct = true; break; } }
	if (!has_pct) return s;

	DString out = dstring::temp();
	sz i = 0;
	while (i < s.len)
	{
		if (s[i] == '%' && i + 2 < s.len)
		{
			int hi = hex_val(s[i + 1]);
			int lo = hex_val(s[i + 2]);
			if (hi >= 0 && lo >= 0)
			{
				out.append_char((char)(hi * 16 + lo));
				i += 3;
				continue;
			}
		}
		out.append_char(s[i]);
		i++;
	}
	return out.str_view();
}

// Percent-encode characters that are not allowed unencoded in a file URI path.
fn void percent_encode_path(DString* out, String path) @private
{
	foreach (c : path)
	{
		switch (c)
		{
			case ' ':  out.append("%20");
			case '#':  out.append("%23");
			case '?':  out.append("%3F");
			case '%':  out.append("%25");
			default:   out.append_char(c);
		}
	}
}

// Append a file:// URI for a filesystem path to a DString.
// For Windows drive-letter paths (C:/foo), uses file:///C:/foo.
// For Unix paths (/home/foo), uses file:///home/foo (file:// + /home/foo).
// Special characters in the path are percent-encoded.
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
	percent_encode_path(out, path);
}

// Convert file:// URI to filesystem path.
// On Windows, file:///C:/foo -> C:/foo (strips the leading / before drive letter).
// Also handles percent-encoded colon: file:///c%3A/foo -> c:/foo.
// On Unix, file:///home/foo -> /home/foo (unchanged).
// Percent-encoded sequences (e.g. %20) are decoded.
fn String uri_to_path(String uri)
{
	if (uri.starts_with("file:///"))
	{
		// Percent-decode first so that %3A becomes : before the drive check
		String decoded = percent_decode(uri[7..]); // "file:///path" -> "/path"
		// Strip leading / before Windows drive letter: /C:/foo -> C:/foo
		if (decoded.len >= 3 && is_windows_drive_path(decoded[1..]))
		{
			return decoded[1..];
		}
		return decoded;
	}
	if (uri.starts_with("file://"))
	{
		return percent_decode(uri[7..]);
	}
	return "";
}
