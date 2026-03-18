module lsp;

import std::core::dstring;

fn void json_escape_into(DString* out, String s) {
	foreach (c : s) {
		switch (c) {
			case '"': out.append("\\\"");
			case '\\': out.append("\\\\");
			case '\n': out.append("\\n");
			case '\r': out.append("\\r");
			case '\t': out.append("\\t");
			default: out.append_char(c);
		}
	}
}
