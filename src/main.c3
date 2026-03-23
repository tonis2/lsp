module lsp;

import std::io;
import args;

const String VERSION = "0.1.1";

// On Windows, stdin/stdout default to text mode which translates \n <-> \r\n.
// This corrupts LSP protocol framing, so we must set binary mode before any I/O.
extern fn int _setmode(int fd, int mode) @if(env::WIN32);

fn int main(String[] args_in) {
	$if env::WIN32:
		_setmode(0, 0x8000); // stdin -> O_BINARY
		_setmode(1, 0x8000); // stdout -> O_BINARY
	$endif

	args::Option[5] options = {
		{ .long_name = "version", .short_name = "v", .description = "Print version and exit" },
		{ .long_name = "stdlib-path", .description = "Path to C3 standard library", .is_value_required = true },
		{ .long_name = "compiler-path", .description = "Path to c3c compiler", .is_value_required = true },
		{ .long_name = "diagnostics-delay", .description = "Delay in ms between diagnostic runs", .is_value_required = true },
		{ .long_name = "sentry-dsn", .description = "Sentry DSN URL for error reporting", .is_value_required = true },
	};

	if (catch args::parse(args_in, arg_sep: "=", options: &options)) return 1;

	if (args::has_arg_long(&options, "version") ?? false)
	{
		io::printfn("%s", VERSION);
		return 0;
	}

	String stdlib_path = args::arg_value(&options, "stdlib-path") ?? "";
	String compiler_path = args::arg_value(&options, "compiler-path") ?? "c3c";
	if (compiler_path.len == 0) compiler_path = "c3c";
	String delay_str = args::arg_value(&options, "diagnostics-delay") ?? "";
	long diag_delay_ms = delay_str.len > 0 ? (long)(delay_str.to_uint() ?? 2000) : 2000;
	String sentry_dsn = args::arg_value(&options, "sentry-dsn") ?? "";

	LspServer server;
	server.init(stdlib_path, compiler_path, diag_delay_ms, sentry_dsn);

	InStream stdin_stream = io::stdin();

	while (server.running) {
		@pool() {
			String msg = read_message(stdin_stream);
			if (msg.len == 0) break;
			server.handle_message(msg);
		};
	}

	return server.shutdown_requested ? 0 : 1;
}
