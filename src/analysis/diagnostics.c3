module lsp;

import std::core::dstring;
import std::core::mem;
import std::collections::list;
import c3::lexer;

const MAX_DIAGNOSTICS = 20;

// Documents larger than this (bytes) get debounced lexer diagnostics instead of a full
// O(n) scan on every keystroke, keeping editing responsive on very large sources
// (e.g. generated Vulkan bindings). Smaller files keep scanning on every change.
const sz LARGE_FILE_BYTES = 256 * 1024;

// The two producers of diagnostics, which run on completely different schedules: the
// lexer on every keystroke, the c3c build on open and save.
enum DiagSource : char
{
	LEXER,
	COMPILER,
}

// One file's currently-published diagnostics, kept split by producer. A
// publishDiagnostics notification replaces the *entire* set for a URI, so the two
// producers have to be merged here — otherwise each publish silently erases the other's
// markers, and a marker that is never republished can never be taken back either.
// Each half holds comma-separated JSON diagnostic objects without the enclosing
// brackets, so publishing is a concatenation. `uri` and both halves are mem-allocated
// and owned by the entry.
//
// The compiler only sees the file as last saved, so between saves its markers are kept
// in place by hand: `cdiags` is the structured form of the compiler half (owned
// copies), which shift_compiler_diagnostics moves along with each edit. It is empty
// when the compiler half was set from raw JSON.
struct DiagEntry
{
	String uri;
	String lex;
	String compiler;
	CompilerDiag[] cdiags;
}

alias DiagState = List{DiagEntry};

// Index of `uri` in the published state, or diag_state.size when it isn't tracked.
fn sz LspServer.diag_index(&self, String uri)
{
	for (sz i = 0; i < self.diag_state.size; i++)
	{
		if (self.diag_state.entries[i].uri == uri) return i;
	}
	return self.diag_state.size;
}

// Replace one producer's half of `uri`'s diagnostics and send the merged set. `elements`
// is comma-separated JSON diagnostic objects, or "" to clear that half.
//
// Clearing still notifies: an empty array is the only thing that removes a marker from
// the editor, so a fixed error that is simply not reported again would otherwise stay on
// screen forever. Files with nothing published are the one case that stays silent —
// there the client already shows no markers.
fn void LspServer.set_diagnostics(&self, String uri, String elements, DiagSource source)
{
	sz idx = self.diag_index(uri);
	if (idx == self.diag_state.size)
	{
		if (elements.len == 0) return;
		self.diag_state.push({ .uri = str_own(uri) });
	}

	DiagEntry* e = &self.diag_state.entries[idx];
	String* half = source == LEXER ? &e.lex : &e.compiler;
	// Unchanged: the client's view of this file is already correct.
	if (*half == elements) return;

	// Copy before freeing: `elements` may be a slice of the half being replaced.
	String owned = str_own(elements);
	if (half.len > 0) mem::free((char*)half.ptr);
	*half = owned;
	// The structured copy describes the compiler half, so it goes when that is cleared.
	if (source == COMPILER && elements.len == 0)
	{
		free_compiler_diags(e.cdiags);
		e.cdiags = {};
	}

	publish_file_diagnostics(uri, merge_diag_elements(e.lex, e.compiler));

	// Nothing left for this file — stop tracking it so the list stays bounded by the
	// number of files that actually have errors.
	if (e.lex.len == 0 && e.compiler.len == 0)
	{
		if (e.uri.len > 0) mem::free((char*)e.uri.ptr);
		self.diag_state.remove_at(idx);
	}
}

// Join both producers' element lists into the JSON array the client receives. Two empty
// halves give "[]", which is what actually removes a file's markers from the editor.
fn String merge_diag_elements(String lex, String compiler)
{
	DString merged = dstring::temp();
	merged.append_char('[');
	merged.append(lex);
	if (lex.len > 0 && compiler.len > 0) merged.append_char(',');
	merged.append(compiler);
	merged.append_char(']');
	return merged.str_view();
}

// Release every tracked file's diagnostics state. Called on exit.
fn void LspServer.free_diag_state(&self)
{
	foreach (e : self.diag_state)
	{
		if (e.uri.len > 0) mem::free((char*)e.uri.ptr);
		if (e.lex.len > 0) mem::free((char*)e.lex.ptr);
		if (e.compiler.len > 0) mem::free((char*)e.compiler.ptr);
		free_compiler_diags(e.cdiags);
	}
	self.diag_state.free();
}

// An owned (mem-allocated) copy of `diags`, including their strings.
fn CompilerDiag[] own_compiler_diags(CompilerDiag[] diags)
{
	if (diags.len == 0) return {};
	CompilerDiag[] copy = mem::new_array(CompilerDiag, diags.len);
	foreach (i, d : diags)
	{
		copy[i] = d;
		copy[i].file = str_own(d.file);
		copy[i].message = str_own(d.message);
		copy[i].note_file = str_own(d.note_file);
		copy[i].note_message = str_own(d.note_message);
	}
	return copy;
}

// Release a list made by own_compiler_diags.
fn void free_compiler_diags(CompilerDiag[] diags)
{
	if (diags.len == 0) return;
	foreach (d : diags)
	{
		if (d.file.len > 0) mem::free((char*)d.file.ptr);
		if (d.message.len > 0) mem::free((char*)d.message.ptr);
		if (d.note_file.len > 0) mem::free((char*)d.note_file.ptr);
		if (d.note_message.len > 0) mem::free((char*)d.note_message.ptr);
	}
	mem::free(diags.ptr);
}

// The lines one edit touched, found by diffing the document before and after it. Only
// lines before the edit keep their numbers; lines after it move by `line_delta`.
struct EditSpan
{
	int first_line;  // first old line the edit touches
	int end_line;    // old lines in [first_line, end_line) were edited
	int line_delta;  // how far the lines from end_line on moved
}

// Diff `old` against `new` by their common prefix and suffix. Returns false when they
// are identical.
fn bool edit_span(String old, String new, EditSpan* span)
{
	sz shorter = old.len < new.len ? old.len : new.len;
	sz prefix = 0;
	while (prefix < shorter && old[prefix] == new[prefix]) prefix++;
	if (prefix == old.len && prefix == new.len) return false;
	sz suffix = 0;
	while (suffix < shorter - prefix && old[old.len - 1 - suffix] == new[new.len - 1 - suffix]) suffix++;

	String old_mid = old[prefix:old.len - suffix - prefix];
	String new_mid = new[prefix:new.len - suffix - prefix];
	int old_lines = (int)count_newlines(old_mid);

	// Whole lines inserted or removed (Enter at a line end, deleting a line) leave every
	// other line's text intact, including the one the edit stops at. Anything else
	// changes the text of the last line it touches too.
	bool whole_lines = (prefix == 0 || old[prefix - 1] == '\n')
		&& (old_mid.len == 0 || old_mid[^1] == '\n')
		&& (new_mid.len == 0 || new_mid[^1] == '\n');

	span.first_line = (int)count_newlines(old[:prefix]);
	span.end_line = span.first_line + old_lines + (whole_lines ? 0 : 1);
	span.line_delta = (int)count_newlines(new_mid) - old_lines;
	return true;
}

fn sz count_newlines(String s) @private
{
	sz n = 0;
	foreach (c : s) if (c == '\n') n++;
	return n;
}

// Keep the compiler's markers on the text they belong to while the buffer is edited
// between builds: markers below the edit move with it, and markers on a line that was
// edited are dropped. Editing the line is usually fixing the error; the next save
// checks it again.
fn void LspServer.shift_compiler_diagnostics(&self, String uri, String old_content, String new_content)
{
	sz idx = self.diag_index(uri);
	if (idx == self.diag_state.size) return;
	CompilerDiag[] diags = self.diag_state.entries[idx].cdiags;
	if (diags.len == 0) return;

	EditSpan span;
	if (!edit_span(old_content, new_content, &span)) return;

	CompilerDiagList kept;
	kept.tinit();
	bool changed = false;
	foreach (d : diags)
	{
		if (d.line >= span.first_line && d.line < span.end_line)
		{
			changed = true;
			continue;
		}
		if (d.line >= span.end_line && span.line_delta != 0)
		{
			d.line += span.line_delta;
			changed = true;
		}
		// A note pointing elsewhere in this file moves the same way.
		if (d.note_file == d.file && d.note_line >= span.first_line)
		{
			if (d.note_line < span.end_line)
			{
				d.note_file = "";
			}
			else
			{
				d.note_line += span.line_delta;
			}
		}
		kept.push(d);
	}
	if (!changed) return;
	self.set_compiler_diagnostics(uri, new_content, kept.array_view());
}

// Return a mem-allocated copy of `s`; "" allocates nothing.
fn String str_own(String s)
{
	if (s.len == 0) return "";
	char[] copy = mem::new_array(char, s.len);
	copy[..] = s[..];
	return (String)copy;
}

// Lex `content` and publish the result, merged with whatever the compiler last reported
// for this file. A clean lex clears the previous lexer markers.
fn void LspServer.publish_lex_diagnostics(&self, String uri, String content)
{
	self.set_diagnostics(uri, lex_diagnostic_elements(content), LEXER);
}

// Encode what the lexer can tell is wrong with `content` as comma-separated JSON
// diagnostic objects (no enclosing brackets), or "" when the file lexes cleanly:
// characters that can't start a token, and strings, comments and contracts that are
// never closed. Temp-allocated.
fn String lex_diagnostic_elements(String content)
{
	DString diags = dstring::temp();
	int diag_count = 0;

	LineOffsets lo;
	lo.tinit();
	lo.build(content);

	Lexer lex;
	lex.init(content);

	while (diag_count < MAX_DIAGNOSTICS)
	{
		Token? tok = lex.next();
		if (catch tok) break;

		if (tok.type == INVALID)
		{
			DString msg = dstring::temp();
			char c = tok.text[0];
			if (tok.len == 1 && (c < 0x20 || c == 0x7F))
			{
				msg.appendf("Invalid character '\\x%02x'", c);
			}
			else
			{
				msg.appendf("Invalid character '%s'", tok.text);
			}
			add_lex_diag(&diags, &diag_count, content, &lo, tok.offset, tok.len, msg.str_view());
			continue;
		}
		if (!tok.unterminated) continue;

		// An unclosed literal is marked from its start to the end of that line; a
		// comment or contract only at its opening, since it runs to the end of the file.
		switch (tok.type)
		{
			case BLOCK_COMMENT:
				// The compiler accepts this (the comment just runs to the end), but it
				// is rarely meant: everything below has silently become a comment.
				add_lex_diag(&diags, &diag_count, content, &lo, tok.offset, 2, "Unterminated block comment: the rest of the file is commented out", 2);
			case CONTRACT:
				add_lex_diag(&diags, &diag_count, content, &lo, tok.offset, 2, "Unterminated contract block");
			default:
				sz len = tok.text.index_of_char('\n') ?? tok.len;
				add_lex_diag(&diags, &diag_count, content, &lo, tok.offset, len, "Unterminated string literal");
		}
	}

	return diag_count > 0 ? diags.str_view() : "";
}

// Append one lexer diagnostic covering `len` bytes at byte `offset` of `content`.
fn void add_lex_diag(DString* out, int* count, String content, LineOffsets* lo, sz offset, sz len, String message, int severity = 1) @private
{
	sz line = lo.find_line(offset);
	sz line_start = lo.entries[line];
	sz start = utf16_len(content, line_start, offset);
	sz width = utf16_len(content, offset, offset + len);
	Range range = { { line, start }, { line, start + (width > 0 ? width : 1) } };

	if (*count > 0) out.append_char(',');
	out.append(`{"range":`);
	range.encode(out);
	out.appendf(`,"severity":%d,"source":"c3-lsp","message":"`, severity);
	json_escape_into(out, message);
	out.append(`"}`);
	(*count)++;
}
