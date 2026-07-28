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
struct DiagEntry
{
	String uri;
	String lex;
	String compiler;
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
	}
	self.diag_state.free();
}

// Return a mem-allocated copy of `s`; "" allocates nothing.
fn String str_own(String s) @private
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

// Encode every byte the lexer rejects in `content` as comma-separated JSON diagnostic
// objects (no enclosing brackets), or "" when the file lexes cleanly. Temp-allocated.
fn String lex_diagnostic_elements(String content)
{
	DString diags = dstring::temp();
	int diag_count = 0;

	Lexer lex;
	lex.init(content);

	while (true)
	{
		if (try tok = lex.next())
		{
			continue;
		}
		else
		{
			// EOF — done lexing
			if (lex.at_end()) break;

			if (diag_count >= MAX_DIAGNOSTICS)
			{
				lex.pos++;
				lex.col++;
				continue;
			}

			// Lexer ln/col are 1-indexed, LSP wants 0-indexed
			sz line = lex.ln > 0 ? lex.ln - 1 : 0;
			sz col = lex.col > 0 ? lex.col - 1 : 0;

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

	return diag_count > 0 ? diags.str_view() : "";
}
