module lsp;

import std::core::dstring;
import std::collections::list;
import c3::lexer;

// Quick fixes built from c3c's own diagnostic text. c3c already spells out the fix
// ("please add 'import std::io'", "please use io::printn instead", "did you perhaps
// want 'foo_bar'?"), so each action is that suggestion turned into an edit. The
// client sends the diagnostics under the cursor with every codeAction request, so
// nothing about compiler diagnostics has to be kept on the server.

// A diagnostic as the client echoes it back in codeAction's context.diagnostics.
struct ActionDiag
{
	Range range;
	String message;
	String source;  // "" = not sent
	int severity;   // 0 = not sent
}

struct QuickFix
{
	String title;
	bool preferred;
	ActionDiag diag;
	TextEdit[2] edits;
	sz edit_count;
}

alias QuickFixList = List{QuickFix};

const String IMPORT_HINT  = "please add 'import ";
const String IMPORT_HINT2 = "try importing the '";
const String PREFIX_HINT  = "must be prefixed with the module name, please use ";
const String TYPO_HINT    = "' could not be found, did you perhaps want ";

// Encode the quick fixes for `diags` in document `uri` as a JSON CodeAction[] array.
fn void encode_code_actions(String uri, String content, DocumentList* docs, ActionDiag[] diags, DString* out)
{
	TokenStream owned;
	bool owns;
	TokenStream* stream = token_stream_for_doc(uri, content, docs, &owned, &owns);
	defer { if (owns) owned.free(); }

	QuickFixList fixes;
	fixes.tinit();
	foreach (d : diags)
	{
		stream.add_import_fixes(d, &fixes);
		stream.add_prefix_fix(d, &fixes);
		stream.add_typo_fixes(d, &fixes);
	}

	out.append_char('[');
	foreach (i, f : fixes)
	{
		if (i > 0) out.append_char(',');
		f.encode(uri, out);
	}
	out.append_char(']');
}

// Keep the first fix per title: one missing import is reported at every use.
fn void QuickFixList.add_unique(&self, QuickFix fix)
{
	foreach (f : *self)
	{
		if (f.title == fix.title) return;
	}
	self.push(fix);
}

// "Did you mean the macro 'printn' in module std::io? If so please add 'import std::io'."
// → add the import; for a function/macro/global/constant also add the `io::` prefix the
// name will need once imported (types are used unprefixed).
fn void TokenStream.add_import_fixes(&self, ActionDiag d, QuickFixList* fixes)
{
	String path = quoted_after(d.message, IMPORT_HINT) ?? quoted_after(d.message, IMPORT_HINT2) ?? "";
	if (path.len == 0) return;

	sz line = d.range.start.line;
	TextEdit? import_edit = self.import_edit(path, line);
	if (catch import_edit) return;

	QuickFix plain = { .title = string::tformat("Add 'import %s;'", path), .preferred = true, .diag = d, .edit_count = 1 };
	plain.edits[0] = import_edit;

	String name = first_quoted(d.message) ?? "";
	if (name.len > 0 && !name.contains("::") && !is_type_name(name))
	{
		String prefix = last_module_segment(path);
		String text = self.line_text(line);
		if (try col = find_word_near(text, name, d.range.start.character))
		{
			if (!is_scoped_at(text, col))
			{
				QuickFix both = { .title = string::tformat("Add 'import %s;' and use '%s::%s'", path, prefix, name), .preferred = true, .diag = d, .edit_count = 2 };
				both.edits[0] = import_edit;
				both.edits[1] = { .range = { { line, col }, { line, col } }, .new_text = string::tformat("%s::", prefix) };
				fixes.add_unique(both);
				plain.preferred = false;
			}
		}
	}
	fixes.add_unique(plain);
}

// "Macros from other modules must be prefixed with the module name, please use io::printn instead."
fn void TokenStream.add_prefix_fix(&self, ActionDiag d, QuickFixList* fixes)
{
	sz? at = d.message.index_of(PREFIX_HINT);
	if (catch at) return;
	String rest = d.message[at + PREFIX_HINT.len..];
	sz? end = rest.index_of(" instead");
	if (catch end) return;
	String qualified = rest[:end];
	if (qualified.ends_with("(...)")) qualified = qualified[:qualified.len - 5];
	sz? sep = qualified.rindex_of("::");
	if (catch sep) return;
	String prefix = qualified[:sep];
	String name = qualified[sep + 2..];
	if (prefix.len == 0 || name.len == 0) return;

	sz line = d.range.start.line;
	String text = self.line_text(line);
	sz? col = find_word_near(text, name, d.range.start.character);
	if (catch col) return;
	if (is_scoped_at(text, col)) return;

	QuickFix fix = { .title = string::tformat("Use '%s'", qualified), .preferred = true, .diag = d, .edit_count = 1 };
	fix.edits[0] = { .range = { { line, col }, { line, col } }, .new_text = string::tformat("%s::", prefix) };
	fixes.add_unique(fix);
}

// "'foo_baz' could not be found, did you perhaps want 'foo_bar'?" (up to three
// candidates, possibly qualified: 'io::prinn' → 'io::print' or 'io::printn').
fn void TokenStream.add_typo_fixes(&self, ActionDiag d, QuickFixList* fixes)
{
	String msg = d.message;
	if (!msg.starts_with("'")) return;
	sz? at = msg.index_of(TYPO_HINT);
	if (catch at) return;
	if (at < 2) return;
	String wrong = msg[1:at - 1];

	String[8] candidates;
	sz count = 0;
	String rest = msg[at + TYPO_HINT.len..];
	while (count < candidates.len)
	{
		String? cand = first_quoted(rest);
		if (catch cand) break;
		candidates[count++] = cand;
		// Continue after this candidate's closing quote.
		rest = rest[(sz)(cand.ptr - rest.ptr) + cand.len + 1..];
	}
	if (count == 0) return;

	sz line = d.range.start.line;
	sz? col = find_word_near(self.line_text(line), wrong, d.range.start.character);
	if (catch col) return;

	foreach (cand : candidates[:count])
	{
		QuickFix fix = { .title = string::tformat("Change to '%s'", cand), .preferred = count == 1, .diag = d, .edit_count = 1 };
		fix.edits[0] = { .range = { { line, col }, { line, col + wrong.len } }, .new_text = cand };
		fixes.add_unique(fix);
	}
}

// Edit inserting `import <path>;` for code on `line`: after the last import of the
// enclosing module section, else after its `module` statement, else at the top of
// the file. Fails when that section already imports `path`.
fn TextEdit? TokenStream.import_edit(&self, String path, sz line)
{
	LineOffsets* lo = self.get_line_offsets();
	sz line_start = line < lo.size ? lo.entries[line] : self.content.len;
	TokenList* toks = &self.tokens;

	// The module section holding `line`, and where the next one starts.
	sz section = toks.size;
	sz i = 0;
	for (; i < toks.size && toks.entries[i].offset < line_start; i++)
	{
		if (toks.entries[i].type == MODULE) section = i;
	}
	sz section_end = i;
	while (section_end < toks.size && toks.entries[section_end].type != MODULE) section_end++;

	ModuleCtx ctx;
	ctx.build_range(toks, section == toks.size ? 0 : section, section_end);
	foreach (imp : ctx.imports[:ctx.import_count])
	{
		if (imp == path) return TOKEN_NOT_FOUND~;
	}

	String stmt = string::tformat("import %s;", path);
	if (section == toks.size)
	{
		return { .range = { { 0, 0 }, { 0, 0 } }, .new_text = string::tformat("%s\n", stmt) };
	}

	// Anchor on the last import before `line`, else on the module statement.
	sz anchor = section;
	for (sz j = section + 1; j < i; j++)
	{
		if (toks.entries[j].type == IMPORT) anchor = j;
	}
	Token anchor_tok = toks.entries[anchor];
	Token eos = self.find_eos(anchor) ?? anchor_tok;
	sz anchor_line = lo.find_line(eos.offset);
	if (anchor_line + 1 < lo.size)
	{
		return { .range = { { anchor_line + 1, 0 }, { anchor_line + 1, 0 } }, .new_text = string::tformat("%s\n", stmt) };
	}
	// The anchor is on the last line, which has no newline to insert after.
	sz end_col = self.line_text(anchor_line).len;
	return { .range = { { anchor_line, end_col }, { anchor_line, end_col } }, .new_text = string::tformat("\n%s", stmt) };
}

// Text of `line` without its line terminator ("" past the end of the document).
fn String TokenStream.line_text(&self, sz line)
{
	LineOffsets* lo = self.get_line_offsets();
	if (line >= lo.size) return "";
	sz start = lo.entries[line];
	sz end = line + 1 < lo.size ? lo.entries[line + 1] : self.content.len;
	while (end > start && (self.content[end - 1] == '\n' || self.content[end - 1] == '\r')) end--;
	return self.content[start:end - start];
}

fn void QuickFix.encode(&self, String uri, DString* out)
{
	out.append(`{"title":"`);
	json_escape_into(out, self.title);
	out.append(`","kind":"quickfix"`);
	if (self.preferred) out.append(`,"isPreferred":true`);
	out.append(`,"diagnostics":[`);
	self.diag.encode(out);
	out.append(`],"edit":{"changes":{"`);
	json_escape_into(out, uri);
	out.append(`":[`);
	foreach (i, e : self.edits[:self.edit_count])
	{
		if (i > 0) out.append_char(',');
		e.encode(out);
	}
	out.append(`]}}}`);
}

fn void ActionDiag.encode(&self, DString* out)
{
	out.append(`{"range":`);
	self.range.encode(out);
	if (self.severity > 0) out.appendf(`,"severity":%d`, self.severity);
	if (self.source.len > 0)
	{
		out.append(`,"source":"`);
		json_escape_into(out, self.source);
		out.append_char('"');
	}
	out.append(`,"message":"`);
	json_escape_into(out, self.message);
	out.append(`"}`);
}

// Text between the first pair of single quotes in `s`.
fn String? first_quoted(String s) @private
{
	sz open = s.index_of_char('\'')!;
	String rest = s[open + 1..];
	sz close = rest.index_of_char('\'')!;
	if (close == 0) return TOKEN_NOT_FOUND~;
	return rest[:close];
}

// Text after `marker` up to the next single quote.
fn String? quoted_after(String s, String marker) @private
{
	sz at = s.index_of(marker)!;
	String rest = s[at + marker.len..];
	sz close = rest.index_of_char('\'')!;
	if (close == 0) return TOKEN_NOT_FOUND~;
	return rest[:close];
}

// Column of the whole-word occurrence of `needle` in `text` closest to `col`.
fn sz? find_word_near(String text, String needle, sz col) @private
{
	if (needle.len == 0 || needle.len > text.len) return TOKEN_NOT_FOUND~;
	bool found = false;
	sz best = 0;
	sz best_dist = 0;
	for (sz i = 0; i + needle.len <= text.len; i++)
	{
		if (text[i:needle.len] != needle) continue;
		if (i > 0 && is_ident_char(text[i - 1])) continue;
		sz end = i + needle.len;
		if (end < text.len && is_ident_char(text[end])) continue;
		sz dist = i > col ? i - col : col - i;
		if (!found || dist < best_dist)
		{
			best = i;
			best_dist = dist;
			found = true;
		}
	}
	if (!found) return TOKEN_NOT_FOUND~;
	return best;
}

// True when the name at `col` is already qualified (`mod::name`).
fn bool is_scoped_at(String text, sz col) @private
{
	return col >= 2 && text[col - 2] == ':' && text[col - 1] == ':';
}

// C3 type names start uppercase and contain a lowercase letter (`List`, `Path`);
// all-caps names are constants. Types are used without a module prefix.
fn bool is_type_name(String name) @private
{
	sz i = 0;
	while (i < name.len && (name[i] == '@' || name[i] == '$' || name[i] == '#')) i++;
	if (i >= name.len || name[i] < 'A' || name[i] > 'Z') return false;
	foreach (c : name[i..])
	{
		if (c >= 'a' && c <= 'z') return true;
	}
	return false;
}
