module lsp;

import std::io;

fn int main(String[] args) {
	LspServer server;
	server.init();

	InStream stdin_stream = io::stdin();

	while (server.running) {
		@pool() {
			String msg = read_message(stdin_stream);
			if (msg.len == 0) break;
			handle_message(&server, msg);
		};
	}

	return server.shutdown_requested ? 0 : 1;
}
