module lsp;

import std::io;

const String VERSION = "0.1.0";

// Extracts the value from a CLI argument.
// For --flag=value, returns the part after '='.
// For --flag value, returns args[i+1] if available.
fn String get_arg_value(String[] args, usz i) @private {
	String arg = args[i];
	for (usz j = 0; j < arg.len; j++) {
		if (arg[j] == '=') {
			return arg[j + 1..];
		}
	}
	if (i + 1 < args.len) {
		return args[i + 1];
	}
	return "";
}

fn int main(String[] args) {
	String stdlib_path = "";
	String compiler_path = "c3c";
	long diag_delay_ms = 2000; // Default 2 second delay

	// Parse CLI arguments (supports both --flag=value and --flag value)
	for (usz i = 1; i < args.len; i++) {
		if (args[i] == "--version") {
			io::printfn("%s", VERSION);
			return 0;
		}
		String val = get_arg_value(args, i);
		if (args[i].starts_with("--stdlib-path")) {
			if (val.len > 0) { stdlib_path = val; }
			if (args[i] == "--stdlib-path") { i++; }
		} else if (args[i].starts_with("--compiler-path")) {
			if (val.len > 0) { compiler_path = val; }
			if (args[i] == "--compiler-path") { i++; }
		} else if (args[i].starts_with("--diagnostics-delay")) {
			if (val.len > 0) { diag_delay_ms = (long)(val.to_uint() ?? 2000); }
			if (args[i] == "--diagnostics-delay") { i++; }
		}
	}

	LspServer server;
	server.init(stdlib_path, compiler_path, diag_delay_ms);

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
