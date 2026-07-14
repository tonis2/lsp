# C3 LSP

A Language Server Protocol implementation for the [C3 programming language](https://c3-lang.org), written in C3.

## Features

- **Go to Definition / Declaration** — navigate to functions, macros, types, constants, enum members, and struct fields; resolves method calls, module-qualified paths (`std::io::printfn`), and individual segments of `import` statements; searches the current file, project sources, and the C3 standard library, preferring declarations in modules visible from the current file (its module tree and imports)
- **Find References** — find all occurrences of a symbol across the project and stdlib, skipping files that cannot see the symbol's module
- **Rename Symbol** — rename identifiers, types, and constants across files.
- **Hover** — type signatures and doc comments (`<* ... *>`) for functions, macros, types, and struct fields
- **Completion** — keywords, types, identifiers, compile-time builtins (`$if`, `@sizeof`, …), and attribute names; member completion after `.` for struct fields, methods, and enum values.
- **Signature Help** — parameter hints when calling functions and macros, with the active parameter highlighted
- **Document Symbols** — outline of modules, functions, structs, enums, macros, and constants
- **Document Highlights** — highlight all occurrences of a symbol in the current file
- **Semantic Tokens** — enhanced syntax highlighting for identifiers, types, functions, macros, and attributes
- **Folding Ranges** — code folding for braces, imports, and block comments
- **Diagnostics** — instant lexer errors while typing, plus errors and warnings from the C3 compiler on save (throttled, configurable)

> **NB!** Project-wide features (references, completion, navigation) read the `sources` list from your project's `project.json`, so make sure your project has one for the best experience.

## Building

Requires the [C3 compiler](https://github.com/c3lang/c3c) (v0.8.x or later).

```sh
# Fetch the lexer/argparse dependencies (first build only)
git submodule update --init

# Build — binary is output to build/lsp
c3c build lsp

# Run tests
c3c test lsp
```

## Usage

```sh
./build/lsp [options]
```

The server communicates over stdin/stdout using the LSP JSON-RPC protocol.

### Options

Options take their value after `=` (e.g. `--stdlib-path=/opt/c3/lib/std`).

| Flag | Description | Default |
|------|-------------|---------|
| `--stdlib-path=<path>` | Path to the C3 standard library | *(auto-detected, see below)* |
| `--compiler-path=<path>` | Path to the C3 compiler binary | `c3c` |
| `--diagnostics-delay=<ms>` | Throttle delay for compiler diagnostics (ms), `0` disables throttling | `2000` |
| `--version`, `-v` | Print version and exit | |

If no stdlib path is given, the server asks the configured compiler where it is
installed (`c3c --version`) and uses `<install dir>/lib/std` when it exists. A missing
or broken compiler never crashes the server — stdlib features simply stay off.

### Client configuration

The same settings can be sent by the editor in the `initialize` request instead of on
the command line, via `initializationOptions`:

```json
{
	"stdlib-path": "/opt/c3/lib/std",
	"compiler-path": "/usr/local/bin/c3c",
	"diagnosticsDelay": 500
}
```

Command-line flags take precedence over client options; auto-detection runs last.


## Architecture

The code is layered so that JSON never leaks into the language analysis:

- `src/server/` — transport (`Content-Length` framing over stdio), a table-driven
  method dispatcher, and thin request handlers that decode params and encode responses
- `src/token/` — the tokenizer, `TokenStream`/`TokenList` queries, and an mtime-based
  file cache so unchanged files are never re-tokenized
- `src/analysis/` — one file per LSP feature (definition, hover, completion, …), all
  operating on token streams only
- `src/analysis/scan.c3` — the single project/stdlib directory walker; features
  implement the `FileVisitor` interface and receive each tokenized file via `@dynamic`
  dispatch
- `src/json/` — typed LSP structures (`Position`, `Range`, `Location`, …) with
  `encode` methods

Contributions should keep `c3c test lsp` green — the test suite pins the exact JSON
responses for every feature.
