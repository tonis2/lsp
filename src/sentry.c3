module lsp;

import std::core::dstring;
import std::core::mem;
import std::os::process;
import std::time;

struct SentryConfig
{
	String key;
	String host;
	String project_id;
	bool enabled;
}

long event_counter @private;
SubProcess last_sentry_proc @private;
bool has_sentry_proc @private;

fn SentryConfig parse_sentry_dsn(String dsn)
{
	// Format: https://<key>@<host>/<project_id>
	if (!dsn.starts_with("https://")) return {};

	String rest = dsn[8..]; // after "https://"

	// Find @ separator
	usz at_idx;
	if (try idx = rest.index_of_char('@')) { at_idx = idx; } else { return {}; }

	String key = rest[:at_idx];
	if (key.len == 0) return {};

	rest = rest[at_idx + 1..]; // after @

	// Find / separator between host and project_id
	usz slash_idx;
	if (try idx = rest.index_of_char('/')) { slash_idx = idx; } else { return {}; }

	String host = rest[:slash_idx];
	String project_id = rest[slash_idx + 1..];

	if (host.len == 0 || project_id.len == 0) return {};

	return { .key = key, .host = host, .project_id = project_id, .enabled = true };
}

fn String generate_event_id() @private
{
	long ts = (long)time::now();
	long val = ts * 1000000 + event_counter;
	event_counter++;

	// Generate 32 hex chars
	DString id = dstring::temp();
	// Use the value twice with different shifts to fill 32 chars
	id.appendf("%016lx", val);
	id.appendf("%016lx", val ^ 0x5a5a5a5a5a5a5a5a);
	return id.str_view();
}

fn void SentryConfig.capture_error(&self, String message, String lsp_method)
{
	if (!self.enabled) return;

	// Clean up previous fire-and-forget process
	if (has_sentry_proc)
	{
		last_sentry_proc.destroy();
		has_sentry_proc = false;
	}

	String event_id = generate_event_id();
	long timestamp = (long)time::now();

	// Build JSON payload
	DString payload = dstring::temp();
	payload.append(`{"event_id":"`);
	payload.append(event_id);
	payload.append(`","timestamp":`);
	payload.appendf("%ld", timestamp);
	payload.append(`,"platform":"other","level":"error","logger":"c3-lsp"`);
	payload.append(`,"message":{"formatted":"`);
	json_escape_into(&payload, message);
	payload.append(`"},"sdk":{"name":"c3-lsp","version":"`);
	payload.append(VERSION);
	payload.append(`"},"tags":{"lsp_method":"`);
	json_escape_into(&payload, lsp_method);
	payload.append(`"}}`);

	// Build auth header
	DString auth = dstring::temp();
	auth.append("X-Sentry-Auth: Sentry sentry_version=7, sentry_key=");
	auth.append(self.key);

	// Build URL
	DString url = dstring::temp();
	url.append("https://");
	url.append(self.host);
	url.append("/api/");
	url.append(self.project_id);
	url.append("/store/");

	$if env::WIN32:
		String devnull = "NUL";
	$else
		String devnull = "/dev/null";
	$endif

	String[13] cmd;
	cmd[0] = "curl";
	cmd[1] = "-s";
	cmd[2] = "-o";
	cmd[3] = devnull;
	cmd[4] = "-X";
	cmd[5] = "POST";
	cmd[6] = "-H";
	cmd[7] = auth.str_view();
	cmd[8] = "-H";
	cmd[9] = "Content-Type: application/json";
	cmd[10] = "-d";
	cmd[11] = payload.str_view();
	cmd[12] = url.str_view();

	if (try p = process::create(cmd[:13], { .search_user_path = true }))
	{
		last_sentry_proc = p;
		has_sentry_proc = true;
	}
}
