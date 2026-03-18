module lsp;

import std::io;

fn void test_read_message_content_length() @test {
	String input = "Content-Length: 14\r\n\r\n{\"id\":1,\"m\":0}";
	ByteReader reader;
	reader.init(input);
	@pool() {
		String msg = read_message(&reader);
		assert(msg == `{"id":1,"m":0}`, "Got: '%s'", msg);
	};
}

fn void test_read_message_empty_on_eof() @test {
	String input = "";
	ByteReader reader;
	reader.init(input);
	@pool() {
		String msg = read_message(&reader);
		assert(msg.len == 0);
	};
}

fn void test_read_message_extra_headers() @test {
	String input = "Content-Length: 2\r\nContent-Type: utf-8\r\n\r\n{}";
	ByteReader reader;
	reader.init(input);
	@pool() {
		String msg = read_message(&reader);
		assert(msg == "{}", "Got: '%s'", msg);
	};
}

fn void test_read_message_bare_json() @test {
	String input = "{\"jsonrpc\":\"2.0\"}\n";
	ByteReader reader;
	reader.init(input);
	@pool() {
		String msg = read_message(&reader);
		assert(msg == `{"jsonrpc":"2.0"}`, "Got: '%s'", msg);
	};
}

fn void test_read_message_zero_length() @test {
	String input = "Content-Length: 0\r\n\r\n";
	ByteReader reader;
	reader.init(input);
	@pool() {
		String msg = read_message(&reader);
		assert(msg.len == 0);
	};
}

fn void test_read_two_messages() @test {
	String input = "Content-Length: 2\r\n\r\n{}Content-Length: 4\r\n\r\n\"ab\"";
	ByteReader reader;
	reader.init(input);
	@pool() {
		String msg1 = read_message(&reader);
		assert(msg1 == "{}", "msg1: '%s'", msg1);
	};
	@pool() {
		String msg2 = read_message(&reader);
		assert(msg2 == `"ab"`, "msg2: '%s'", msg2);
	};
}
