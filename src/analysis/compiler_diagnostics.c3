module lsp;

import std::core::dstring;
import std::core::mem;
import std::collections::list;
import std::io::file;
import std::os::process;
import std::time;

const sz COMPILER_OUTPUT_BUFFER   = 65536;
const sz MAX_COMPILER_DIAGNOSTICS = 50;

// A single parsed c3c diagnostic. Line and columns are in bytes, as c3c reports them;
// they are converted to the UTF-16 positions LSP wants only when encoded, against the
// text the diagnostic is shown in. The strings reference temp/buffer memory while a
// build is being published; DiagEntry keeps owned copies (see CompilerDiag.own).
struct CompilerDiag
{
	String file;    // resolved absolute path (separators normalized to '/')
	int line;       // 0-indexed
	int col;        // 0-indexed byte column
	int severity;   // LSP DiagnosticSeverity (1=error, 2=warning, 3=info)
	String message; // raw message text (slice into compiler output)
	// The `note` c3c prints right after an error ("The previous use of 'Foo' was
	// here."), published as the error's relatedInformation. note_file "" = no note.
	String note_file;
	int note_line;
	int note_col;
	String note_message;
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
	// Drain the output before joining: it arrives through a pipe, and a compiler that
	// fills the pipe blocks until someone reads it, so joining first can hang forever.
	// Output past the buffer is read and dropped.
	char[] buf = mem::new_array(char, COMPILER_OUTPUT_BUFFER);
	defer mem::free(buf);
	char[1024] discard;
	sz total_read = 0;
	while (true)
	{
		sz n;
		if (total_read < COMPILER_OUTPUT_BUFFER)
		{
			n = proc.read_stdout(&buf[total_read], COMPILER_OUTPUT_BUFFER - total_read) ?? 0;
			total_read += n;
		}
		else
		{
			n = proc.read_stdout(&discard, discard.len) ?? 0;
		}
		if (n == 0) break;
	}
	if (catch proc.join())
	{
		proc.destroy();
		return;
	}
	proc.destroy();

	String output = (String)buf[:total_read];

	// Without the BEGINLSP marker c3c never got as far as compiling: a broken
	// project.json, a missing dependency, a bad flag. Reading that as "no errors" would
	// clear every marker while nothing builds, so keep what is shown and say why.
	if (!output.contains("BEGINLSP"))
	{
		self.report_build_failure(output);
		self.last_diag_time = time::now();
		return;
	}
	self.clear_build_failure();

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

		String file = resolve_compiler_path(file_str, project_root);

		// A note explains the diagnostic just before it; attach it there rather than
		// publishing a second, unrelated-looking marker.
		if (severity_str == "note" && self.len() > 0)
		{
			CompilerDiag* prev = self.get_ref(self.len() - 1);
			if (prev.note_file.len == 0)
			{
				prev.note_file = file;
				prev.note_line = diag_line;
				prev.note_col = diag_col;
				prev.note_message = msg_str;
				continue;
			}
		}

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

		self.push({ .file = file, .line = diag_line, .col = diag_col, .severity = sev, .message = msg_str });
	}
}

// Hand this build's diagnostics to the merged per-file state: one update per file with
// errors, then a clear for every file that had compiler errors on the previous run but
// no longer does. The clears are what keep fixed errors from sticking in the editor.
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

		CompilerDiagList file_diags;
		file_diags.tinit();
		foreach (d2 : *diags)
		{
			if (d2.file == d.file) file_diags.push(d2);
		}
		self.set_compiler_diagnostics(uri, self.content_for_path(d.file), file_diags.array_view());
	}

	// Clear the compiler half of files that dropped out of this run, leaving any lexer
	// markers they still have in place. Walk backwards: set_diagnostics drops an entry
	// once both of its halves are empty, which shifts everything after it down.
	for (sz i = self.diag_state.size; i > 0; i--)
	{
		DiagEntry* e = &self.diag_state.entries[i - 1];
		if (e.compiler.len == 0 || current.contains(e.uri)) continue;
		self.set_diagnostics(e.uri, "", COMPILER);
	}
}

// Encode `diags` (all in one file) and make them that file's compiler half, keeping an
// owned copy so they can be moved along with later edits (shift_compiler_diagnostics).
// `content` is the text the markers are shown on, which their positions are converted
// against.
fn void LspServer.set_compiler_diagnostics(&self, String uri, String content, CompilerDiag[] diags)
{
	DString arr = dstring::temp();
	self.encode_compiler_elements(content, diags, &arr);
	// Copy first: `diags` may point into the entry's current copy.
	CompilerDiag[] owned = own_compiler_diags(diags);
	self.set_diagnostics(uri, arr.str_view(), COMPILER);

	sz idx = self.diag_index(uri);
	if (idx == self.diag_state.size)
	{
		free_compiler_diags(owned);
		return;
	}
	DiagEntry* e = &self.diag_state.entries[idx];
	free_compiler_diags(e.cdiags);
	e.cdiags = owned;
}

// The text of a file as the user sees it: the open buffer when there is one, otherwise
// what is on disk. "" when neither is available.
fn String LspServer.content_for_path(&self, String file_path)
{
	if (try doc = self.documents.find(self.document_uri_for_path(file_path))) return doc.content;
	return (String)file::load_temp(file_path) ?? "";
}

// Encode one file's diagnostics as comma-separated LSP Diagnostic objects. Positions are
// clamped to the line they are on and converted from bytes to UTF-16 units, and each
// range is widened over the name at the reported column.
fn void LspServer.encode_compiler_elements(&self, String content, CompilerDiag[] diags, DString* out)
{
	LineOffsets lo;
	lo.tinit();
	lo.build(content);

	int n = 0;
	foreach (i, d : diags)
	{
		// After some errors (an unterminated string) c3c follows up with a second one
		// on the same line at a column far past its end. It is noise caused by the
		// first, not something to fix separately.
		if (n > 0 && col_past_line_end(content, &lo, d.line, d.col) && diags[i - 1].line == d.line) continue;

		Range range = diag_range(content, &lo, d.line, d.col);
		Location note;
		bool has_note = d.note_file.len > 0;
		if (has_note)
		{
			String note_content = d.note_file == d.file ? content : self.content_for_path(d.note_file);
			LineOffsets note_lo;
			note_lo.tinit();
			note_lo.build(note_content);
			note = { self.document_uri_for_path(d.note_file), diag_range(note_content, &note_lo, d.note_line, d.note_col) };
		}

		if (n > 0) out.append_char(',');
		d.encode(out, range, has_note ? &note : null);
		n++;
	}
}

// Append a single diagnostic object (LSP Diagnostic) as JSON, at `range` (already in
// UTF-16 units), with the note it carries, if any, as relatedInformation.
fn void CompilerDiag.encode(&self, DString* out, Range range, Location* note = null)
{
	out.append(`{"range":`);
	range.encode(out);
	out.append(`,"severity":`);
	out.appendf("%d", self.severity);
	out.append(`,"source":"c3c","message":"`);
	json_escape_into(out, self.message);
	out.append_char('"');
	if (note)
	{
		out.append(`,"relatedInformation":[{"location":{"uri":"`);
		json_escape_into(out, note.uri);
		out.append(`","range":`);
		note.range.encode(out);
		out.append(`},"message":"`);
		json_escape_into(out, self.note_message);
		out.append(`"}]`);
	}
	out.append_char('}');
}

// The LSP range for a c3c position (0-indexed line, byte column) in `content`: the name
// starting there, or one character when there is none. Lines past the end are clamped
// to the last line and columns to the end of their line, so a marker always lands on
// real text; positions are converted to UTF-16 units. Unknown content ("") leaves the
// position as reported.
fn Range diag_range(String content, LineOffsets* lo, int line, int col)
{
	if (content.len == 0) return { { (sz)line, (sz)col }, { (sz)line, (sz)col + 1 } };

	int ln = (sz)line < lo.size ? line : (int)lo.size - 1;
	sz line_start = lo.entries[(sz)ln];
	sz line_len = line_byte_len(content, lo, ln);
	int c = (sz)col > line_len ? (int)line_len : col;

	sz start = utf16_len(content, line_start, line_start + (sz)c);
	int end_col = name_end_col(content, lo, ln, c);
	sz end = end_col > c ? utf16_len(content, line_start, line_start + (sz)end_col) : start + 1;
	return { { (sz)ln, start }, { (sz)ln, end } };
}

// Whether a byte column lies beyond the end of its line (or the line beyond the file).
fn bool col_past_line_end(String content, LineOffsets* lo, int line, int col) @private
{
	if (content.len == 0) return false;
	if ((sz)line >= lo.size) return true;
	return (sz)col > line_byte_len(content, lo, line);
}

// Length in bytes of a line, without its line terminator.
fn sz line_byte_len(String content, LineOffsets* lo, int line) @private
{
	sz start = lo.entries[(sz)line];
	sz end = (sz)line + 1 < lo.size ? lo.entries[(sz)line + 1] - 1 : content.len;
	if (end > start && content[end - 1] == '\r') end--;
	return end - start;
}

// End column of the (possibly `::`-qualified) name starting at line/col of `content`,
// e.g. all of `io::printn` or `@foo`; 0 when no name starts there.
fn int name_end_col(String content, LineOffsets* lo, int line, int col) @private
{
	if ((sz)line >= lo.size) return 0;
	sz start = lo.entries[(sz)line] + (sz)col;
	sz i = start;
	if (i < content.len && (content[i] == '@' || content[i] == '$' || content[i] == '#')) i++;
	sz name_start = i;
	while (i < content.len && is_ident_char(content[i]))
	{
		i++;
		if (i + 2 < content.len && content[i] == ':' && content[i + 1] == ':' && is_ident_char(content[i + 2])) i += 2;
	}
	if (i == name_start) return 0;
	return col + (int)(i - start);
}

// c3c failed before compiling anything, so its output is plain text rather than LSPERR
// lines. Tell the user what it said; the same failure on every save is shown once.
fn void LspServer.report_build_failure(&self, String output)
{
	String first = first_nonempty_line(output);
	if (first.len == 0) first = "the compiler produced no diagnostics output";
	if (first == self.last_build_error) return;
	if (self.last_build_error.len > 0) mem::free((char*)self.last_build_error.ptr);
	self.last_build_error = str_own(first);

	DString msg = dstring::temp();
	msg.append(`{"type":1,"message":"c3c: `);
	json_escape_into(&msg, first);
	msg.append(`"}`);
	send_notification("window/showMessage", msg.str_view());
}

// A build got far enough to report diagnostics, so the next failure is news again.
fn void LspServer.clear_build_failure(&self)
{
	if (self.last_build_error.len > 0) mem::free((char*)self.last_build_error.ptr);
	self.last_build_error = "";
}

// The first line of `s` with any text on it, trimmed.
fn String first_nonempty_line(String s) @private
{
	foreach (line : s.tsplit("\n"))
	{
		String t = line.trim();
		if (t.len > 0) return t;
	}
	return "";
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
