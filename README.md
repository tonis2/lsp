# C3 LSP

A Language Server Protocol implementation for the [C3 programming language](https://c3-lang.org), written in C3.

## Features

- **Go to Definition / Declaration** — navigate to functions, types, constants, enum members; supports method calls and cross-file lookup including stdlib
- **Find References** — find all occurrences of a symbol across open files and project sources
- **Rename Symbol** — rename identifiers, types, and constants across files
- **Hover** — view type signatures and doc comments on hover
- **Completion** — autocomplete for keywords, types, identifiers, compile-time builtins, and attribute names
- **Signature Help** — parameter hints when calling functions and macros
- **Document Symbols** — outline of modules, functions, structs, enums, macros, and constants
- **Document Highlights** — highlight all occurrences of a symbol in the current file
- **Semantic Tokens** — enhanced syntax highlighting for identifiers, types, functions, macros, and attributes
- **Folding Ranges** — code folding for braces, imports, and block comments
- **Diagnostics** — reports errors and warnings from the C3 compiler on save

NB! Uses C3 `project.json` sources: [], for reference/auto-complete targets, so make sure your project has project.json, for good experience. 

## Building

Requires the [C3 compiler](https://github.com/c3lang/c3c) (v0.7.x or later).

```sh
# Build
c3c build lsp

# Run tests
c3c test lsp
```

The binary is output to `build/lsp`.

## Usage

```sh
./build/lsp [options]
```

The server communicates over stdin/stdout using the LSP JSON-RPC protocol.

### Options

| Flag | Description | Default |
|------|-------------|---------|
| `--stdlib-path <path>` | Path to the C3 standard library | *(none)* |
| `--compiler-path <path>` | Path to the C3 compiler binary | `c3c` |
| `--diagnostics-delay <ms>` | Throttle delay for diagnostics (ms) | `2000` |

### Editor Setup

Configure your editor's C3 language extension to use this LSP binary. For VS Code, set the server path in the [C3 extension](https://marketplace.visualstudio.com/items?itemName=c3-lang.c3-lsp) settings.
