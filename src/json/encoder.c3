module lsp;

import std::core::dstring;
import std::core::mem;

// Data structures for encoding
struct Position {
	usz line;
	usz character;
}

struct Range {
	Position start;
	Position end;
}

struct Location {
	String uri;
	Range range;
}

struct DocumentHighlight {
	Range range;
	int kind; // 1 = text, 2 = read, 3 = write
}

struct DocumentSymbol {
	String name;
	int kind;
	Range range;
	Range selection_range;
	DocumentSymbol[] children;
}

struct TextEdit {
	Range range;
	String new_text;
}

struct DocumentChange {
	String uri;
	TextEdit[] edits;
}

struct CompletionItem {
	String label;
	int kind;
	String detail;
	String documentation;
	String insert_text;
}

struct ParameterInformation {
	String label;
	String documentation;
}

struct SignatureInformation {
	String label;
	ParameterInformation[] parameters;
	String documentation;
}

struct SemanticToken {
	usz line;
	usz character;
	usz length;
	int token_type;
	int token_modifiers;
}

struct FoldingRange {
	usz start_line;
	usz end_line;
	String kind;
}

// Struct encode methods

fn void Position.encode(&self, DString* out) {
	out.appendf(`{"line":%d,"character":%d}`, self.line, self.character);
}

fn void Range.encode(&self, DString* out) {
	out.append(`{"start":`);
	self.start.encode(out);
	out.append(",\"end\":");
	self.end.encode(out);
	out.append_char('}');
}

fn void Location.encode(&self, DString* out) {
	out.append(`{"uri":"`);
	json_escape_into(out, self.uri);
	out.append(`","range":`);
	self.range.encode(out);
	out.append_char('}');
}

fn void DocumentHighlight.encode(&self, DString* out) {
	out.append(`{"range":`);
	self.range.encode(out);
	out.appendf(`,"kind":%d}`, self.kind);
}

fn void DocumentSymbol.encode(&self, DString* out) {
	out.append(`{"name":"`);
	json_escape_into(out, self.name);
	out.appendf(`","kind":%d`, self.kind);
	out.append(",\"range\":");
	self.range.encode(out);
	out.append(",\"selectionRange\":");
	self.selection_range.encode(out);
	if (self.children.len > 0) {
		out.append(",\"children\":[");
		bool first = true;
		foreach (&child : self.children) {
			if (!first) out.append_char(',');
			first = false;
			child.encode(out);
		}
		out.append_char(']');
	}
	out.append_char('}');
}

fn void TextEdit.encode(&self, DString* out) {
	out.append(`{"range":`);
	self.range.encode(out);
	out.append(`,"newText":"`);
	json_escape_into(out, self.new_text);
	out.append_char('"');
	out.append_char('}');
}

fn void CompletionItem.encode(&self, DString* out) {
	out.append(`{"label":"`);
	json_escape_into(out, self.label);
	out.append_char('"');
	if (self.kind != 0) {
		out.appendf(",\"kind\":%d", self.kind);
	}
	if (self.detail.len > 0) {
		out.append(",\"detail\":\"");
		json_escape_into(out, self.detail);
		out.append_char('"');
	}
	if (self.documentation.len > 0) {
		out.append(",\"documentation\":\"");
		json_escape_into(out, self.documentation);
		out.append_char('"');
	}
	if (self.insert_text.len > 0) {
		out.append(",\"insertText\":\"");
		json_escape_into(out, self.insert_text);
		out.append_char('"');
	}
	out.append_char('}');
}

fn void FoldingRange.encode(&self, DString* out) {
	out.appendf(`{"startLine":%d,"endLine":%d`, self.start_line, self.end_line);
	if (self.kind.len > 0) {
		out.append(",\"kind\":\"");
		json_escape_into(out, self.kind);
		out.append_char('"');
	}
	out.append_char('}');
}

// Standalone encode functions for complex responses

fn void encode_hover_response(DString* out, String content, Range range) {
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
