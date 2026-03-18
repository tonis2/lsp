module lsp;

import std::io;

fn int main(String[] args) {
	String stdlib_path = "";
	long diag_delay_ms = 2000; // Default 2 second delay

	// Parse CLI arguments
	for (usz i = 1; i < args.len; i++) {
		if (args[i] == "--stdlib" && i + 1 < args.len) {
			stdlib_path = args[++i];
		} else if (args[i] == "--diagnostics-delay" && i + 1 < args.len) {
			diag_delay_ms = (long)(args[++i].to_uint() ?? 2000);
		}
	}

	LspServer server;
	server.init(stdlib_path, diag_delay_ms);

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
