module lsp;

import std::core::dstring;
import std::core::mem;

// Data structures for encoding
struct Position
{
	sz line;
	sz character;
}

struct Range
{
	Position start;
	Position end;
}

struct Location
{
	String uri;
	Range range;
}

struct DocumentHighlight
{
	Range range;
	int kind; // 1 = text, 2 = read, 3 = write
}

struct DocumentSymbol
{
	String name;
	int kind;
	Range range;
	Range selection_range;
	DocumentSymbol[] children;
}

struct TextEdit
{
	Range range;
	String new_text;
}

struct DocumentChange
{
	String uri;
	TextEdit[] edits;
}

struct CompletionItem
{
	String label;
	int kind;
	String detail;
	String documentation;
	String insert_text;
	int insert_text_format;      // 0 = unset, 1 = PlainText, 2 = Snippet
	bool trigger_signature_help; // emit editor.action.triggerParameterHints command
}

struct ParameterInformation
{
	String label;
	String documentation;
}

struct SignatureInformation
{
	String label;
	ParameterInformation[] parameters;
	String documentation;
}

struct SemanticToken
{
	sz line;
	sz character;
	sz length;
	int token_type;
	int token_modifiers;
}

struct FoldingRange
{
	sz start_line;
	sz end_line;
	String kind;
}

// Struct encode methods

fn void Position.encode(&self, DString* out)
{
	out.appendf(`{"line":%d,"character":%d}`, self.line, self.character);
}

fn void Range.encode(&self, DString* out)
{
	out.append(`{"start":`);
	self.start.encode(out);
	out.append(",\"end\":");
	self.end.encode(out);
	out.append_char('}');
}

fn void Location.encode(&self, DString* out)
{
	out.append(`{"uri":"`);
	json_escape_into(out, self.uri);
	out.append(`","range":`);
	self.range.encode(out);
	out.append_char('}');
}

fn void DocumentHighlight.encode(&self, DString* out)
{
	out.append(`{"range":`);
	self.range.encode(out);
	out.appendf(`,"kind":%d}`, self.kind);
}

fn void DocumentSymbol.encode(&self, DString* out)
{
	out.append(`{"name":"`);
	json_escape_into(out, self.name);
	out.appendf(`","kind":%d`, self.kind);
	out.append(",\"range\":");
	self.range.encode(out);
	out.append(",\"selectionRange\":");
	self.selection_range.encode(out);
	if (self.children.len > 0)
	{
		out.append(",\"children\":[");
		bool first = true;
		foreach (&child : self.children)
		{
			if (!first) out.append_char(',');
			first = false;
			child.encode(out);
		}
		out.append_char(']');
	}
	out.append_char('}');
}

fn void TextEdit.encode(&self, DString* out)
{
	out.append(`{"range":`);
	self.range.encode(out);
	out.append(`,"newText":"`);
	json_escape_into(out, self.new_text);
	out.append_char('"');
	out.append_char('}');
}

fn void CompletionItem.encode(&self, DString* out)
{
	out.append(`{"label":"`);
	json_escape_into(out, self.label);
	out.append_char('"');
	if (self.kind != 0)
	{
		out.appendf(",\"kind\":%d", self.kind);
	}
	if (self.detail.len > 0)
	{
		out.append(",\"detail\":\"");
		json_escape_into(out, self.detail);
		out.append_char('"');
	}
	if (self.documentation.len > 0)
	{
		out.append(",\"documentation\":\"");
		json_escape_into(out, self.documentation);
		out.append_char('"');
	}
	if (self.insert_text.len > 0)
	{
		out.append(",\"insertText\":\"");
		json_escape_into(out, self.insert_text);
		out.append_char('"');
		// When the CompletionList provides itemDefaults.editRange (this server always does),
		// the client takes the inserted text from textEditText (falling back to label) and
		// IGNORES insertText. Emit both so the snippet applies with or without the default.
		out.append(",\"textEditText\":\"");
		json_escape_into(out, self.insert_text);
		out.append_char('"');
	}
	if (self.insert_text_format != 0)
	{
		out.appendf(",\"insertTextFormat\":%d", self.insert_text_format);
	}
	if (self.trigger_signature_help)
	{
		out.append(`,"command":{"title":"Trigger Parameter Hints","command":"editor.action.triggerParameterHints"}`);
	}
	out.append_char('}');
}

fn void FoldingRange.encode(&self, DString* out)
{
	out.appendf(`{"startLine":%d,"endLine":%d`, self.start_line, self.end_line);
	if (self.kind.len > 0)
	{
		out.append(",\"kind\":\"");
		json_escape_into(out, self.kind);
		out.append_char('"');
	}
	out.append_char('}');
}

// Standalone encode functions for complex responses

// The initialize-response capabilities advertised to the client.
fn void encode_server_capabilities(DString* out, String version)
{
	out.append(`{"capabilities":{`);
	out.append(`"textDocumentSync":{"openClose":true,"change":1,"save":true},`);
	out.append(`"semanticTokensProvider":{`);
	out.append(`"legend":{"tokenTypes":`);
	out.append(TOKEN_TYPES_LEGEND);
	out.append(`,"tokenModifiers":[]},`);
	out.append(`"full":true`);
	out.append(`},`);
	out.append(`"foldingRangeProvider":true,`);
	out.append(`"documentSymbolProvider":true,`);
	out.append(`"hoverProvider":true,`);
	// ':' is registered so module-path completion can trigger, but only the second ':'
	// of '::' actually produces items (a lone ':' is neutralized in encode_completions).
	out.append(`"completionProvider":{"triggerCharacters":[".",":","$","@","#"]},`);
	out.append(`"definitionProvider":true,`);
	out.append(`"declarationProvider":true,`);
	out.append(`"documentHighlightProvider":true,`);
	out.append(`"referencesProvider":true,`);
	out.append(`"renameProvider":true,`);
	out.append(`"signatureHelpProvider":{"triggerCharacters":["(",",","{","}"]}`);
	out.append(`},`);
	out.appendf(`"serverInfo":{"name":"c3-lsp","version":"%s"}}`, version);
}

fn void encode_hover_response(DString* out, String content, Range range)
{
	out.append(`{"contents":{"kind":"markdown","value":"`);
	json_escape_into(out, content);
	out.append(`"},"range":`);
	range.encode(out);
	out.append_char('}');
}

fn void json_escape_into(DString* out, String s)
{
	foreach (c : s)
	{
		switch (c)
		{
			case '"': out.append("\\\"");
			case '\\': out.append("\\\\");
			case '\n': out.append("\\n");
			case '\r': out.append("\\r");
			case '\t': out.append("\\t");
			default: out.append_char(c);
		}
	}
}
