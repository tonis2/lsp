module lsp;

import std::io;
import std::core::dstring;
import std::core::mem;

fn String read_message(InStream stream) {
	DString line = dstring::new(mem);
	defer line.free();

	// Read first line
	while (true) {
		if (try c = stream.read_byte()) {
			if (c == '\n') break;
			if (c != '\r') line.append_char(c);
		} else {
			return "";
		}
	}

	String s = line.str_view();
	if (s.len == 0) return "";

	// Content-Length framed message
	if (s.contains("Content-Length:")) {
		uint content_length = 0;
		if (try cl_pos = s.index_of("Content-Length:")) {
			String num = s[cl_pos + 15..].trim();
			content_length = num.to_uint() ?? 0;
		}
		if (content_length == 0) return "";

		// Skip remaining headers until empty line
		while (true) {
			DString hdr = dstring::new(mem);
			defer hdr.free();
			while (true) {
				if (try c = stream.read_byte()) {
					if (c == '\n') break;
					if (c != '\r') hdr.append_char(c);
				} else {
					return "";
				}
			}
			if (hdr.str_view().len == 0) break;
		}

		// Read exactly content_length bytes
		char[] body = mem::new_array(char, content_length);
		usz read_so_far = 0;
		while (read_so_far < content_length) {
			usz n = stream.read(body[read_so_far..content_length - 1]) ?? 0;
			if (n == 0) {
				mem::free(body);
				return "";
			}
			read_so_far += n;
		}

		DString result = dstring::temp((String)body[:content_length]);
		mem::free(body);
		return result.str_view();
	}

	// Bare JSON line
	DString result = dstring::temp(s);
	return result.str_view();
}

fn void send_message(String json) {
	DString header = dstring::temp();
	header.appendf("Content-Length: %d\r\n\r\n", json.len);
	io::stdout().write(header.str_view())!!;
	io::stdout().write(json)!!;
	io::stdout().flush()!!;
}

fn void send_response(String id_json, String result_json) {
	DString resp = dstring::temp();
	resp.appendf(`{"jsonrpc":"2.0","id":%s,"result":%s}`, id_json, result_json);
	send_message(resp.str_view());
}

fn void send_error(String id_json, int code, String message) {
	DString resp = dstring::temp();
	resp.appendf(`{"jsonrpc":"2.0","id":%s,"error":{"code":%d,"message":"`, id_json, code);
	json_escape_into(&resp, message);
	resp.append(`"}}`);
	send_message(resp.str_view());
}

fn void send_notification(String method, String params_json) {
	DString resp = dstring::temp();
	resp.appendf(`{"jsonrpc":"2.0","method":"%s","params":%s}`, method, params_json);
	send_message(resp.str_view());
}
