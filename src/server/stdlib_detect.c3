module lsp;

import std::core::dstring;
import std::core::mem;
import std::io::path;
import std::os::process;

// Auto-detect the C3 standard library path by asking the compiler where it is installed.
//
// Runs `<compiler_path> --version`, which prints (among other lines):
//
//     Installed directory:       /path/to/c3
//
// and returns `<that dir>/lib/std` when it exists on disk. Returns "" on ANY failure
// (compiler missing / not executable / not c3c / unexpected output / directory absent),
// so a wrong or user-overridden `compiler-path` can never crash or hang the server —
// the caller simply keeps running with an empty stdlib path, as before.
//
// The result (when non-empty) is heap-allocated and owned by the caller.
fn String detect_stdlib_path(String compiler_path)
{
	if (compiler_path.len == 0) return "";

	String[2] cmd = { compiler_path, "--version" };

	Process proc;
	if (try p = process::spawn(cmd[..], STDERR_TO_STDOUT | INHERIT_ENV))
	{
		proc = p;
	}
	else
	{
		// Binary not found / not executable — degrade silently.
		return "";
	}
	defer (void)proc.destroy();

	if (catch proc.join()) return "";

	char[4096] buf;
	sz total = 0;
	while (total < buf.len)
	{
		sz n = proc.read_stdout(&buf[total], buf.len - total) ?? 0;
		if (n == 0) break;
		total += n;
	}

	String dir = parse_installed_dir((String)buf[:total]);
	if (dir.len == 0) return "";

	// The stdlib lives at <installed dir>/lib/std.
	DString candidate = dstring::temp();
	candidate.appendf("%s/lib/std", dir);
	String std_path = candidate.str_view();

	bool is_dir = false;
	if (try p = path::tnew(std_path))
	{
		is_dir = path::is_dir(p);
	}
	if (!is_dir) return "";

	// Copy onto the heap — `buf`/temp memory does not outlive this function.
	char[] owned = mem::new_array(char, std_path.len);
	owned[..] = std_path[..];
	return (String)owned;
}

// Extract the path printed on the `Installed directory:` line of `c3c --version`
// output. Returns "" when the line is absent (e.g. the binary was not c3c). Pure and
// side-effect free so it can be unit-tested against fixed sample output.
fn String parse_installed_dir(String version_output)
{
	String marker = "Installed directory:";
	if (try idx = version_output.index_of(marker))
	{
		sz start = idx + marker.len;
		sz end = start;
		while (end < version_output.len && version_output[end] != '\n' && version_output[end] != '\r')
		{
			end++;
		}
		if (end > start)
		{
			return version_output[start..end - 1].trim();
		}
	}
	return "";
}
