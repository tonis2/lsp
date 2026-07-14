module lsp;

import std::core::dstring;
import c3::lexer;

// Module-visibility context of a file: the module paths it declares plus the module
// paths it imports. Symbol searches use it to prefer declarations the file can
// actually see (C3 visibility rules) over same-named declarations in unrelated
// modules — e.g. a user's `struct Rectangle` vs the stdlib's `union Rectangle`
// in std::math. Filtering is best-effort: callers fall back to the module-blind
// search when nothing visible matches, so a missing import degrades to the old
// behavior instead of hiding results.

const sz MAX_OWN_MODULES = 16;
const sz MAX_IMPORT_MODULES = 48;

struct ModuleCtx
{
	String[MAX_OWN_MODULES] own;
	sz own_count;
	String[MAX_IMPORT_MODULES] imports;
	sz import_count;
	bool overflow; // ran out of slots — report every module as visible
}

// True when `path` is `prefix` itself or a submodule of it. The prefix must be
// segment-aligned: module_covers("std::io", "std::io::path") but not "std::iox".
fn bool module_covers(String prefix, String path)
{
	if (prefix.len == 0 || path.len < prefix.len) return false;
	if (path[0..prefix.len - 1] != prefix) return false;
	if (path.len == prefix.len) return true;
	return path.len > prefix.len + 1 && path[prefix.len] == ':' && path[prefix.len + 1] == ':';
}

// Collect the module declarations and import paths of a token stream.
fn void ModuleCtx.build(&self, TokenList* tokens)
{
	for (sz i = 0; i < tokens.size; i++)
	{
		TokenType t = tokens.entries[i].type;
		if (t == MODULE)
		{
			String path = tokens.module_path_at(i);
			if (path.len == 0) continue;
			if (self.own_count >= MAX_OWN_MODULES)
			{
				self.overflow = true;
				continue;
			}
			self.own[self.own_count] = path;
			self.own_count++;
		}
		else if (t == IMPORT)
		{
			// One import statement may list several comma-separated paths:
			// `import std::io, std::math;`. Attributes (`@public`) end the path.
			sz j = i + 1;
			while (j < tokens.size)
			{
				TokenType jt = tokens.entries[j].type;
				if (jt == COMMA || jt == SCOPE)
				{
					j++;
					continue;
				}
				if (jt != IDENT && jt != TYPE_IDENT && jt != CONST_IDENT) break;

				DString path = dstring::temp();
				while (j < tokens.size)
				{
					TokenType st = tokens.entries[j].type;
					if (st == IDENT || st == TYPE_IDENT || st == CONST_IDENT)
					{
						if (path.len() > 0) path.append("::");
						path.append(tokens.entries[j].text);
						j++;
					}
					else if (st == SCOPE)
					{
						j++;
					}
					else
					{
						break;
					}
				}
				if (path.len() > 0)
				{
					if (self.import_count >= MAX_IMPORT_MODULES)
					{
						self.overflow = true;
						break;
					}
					self.imports[self.import_count] = path.str_view();
					self.import_count++;
				}
			}
			if (j > i) i = j - 1;
		}
	}
}

// True when a declaration in module `decl_mod` is visible from this context:
// module-less declarations always are; otherwise any segment-prefix relation with
// an own module (same module, parent, or submodule — C3 shares visibility along
// the module tree), a covering import (imports are recursive: `import std::io`
// also imports `std::io::path`), or the implicitly imported std::core subtree.
// A context with no module information at all stays permissive so plain snippet
// files keep the module-blind behavior.
fn bool ModuleCtx.can_see(&self, String decl_mod)
{
	if (decl_mod.len == 0) return true;
	if (self.overflow) return true;
	if (self.own_count == 0 && self.import_count == 0) return true;

	for (sz i = 0; i < self.own_count; i++)
	{
		if (module_covers(self.own[i], decl_mod) || module_covers(decl_mod, self.own[i])) return true;
	}
	for (sz i = 0; i < self.import_count; i++)
	{
		if (module_covers(self.imports[i], decl_mod)) return true;
	}
	return module_covers("std::core", decl_mod);
}

// Build a ModuleCtx for `tokens` and test whether it can see decl_module.
// Reference/rename filtering uses this, where the seeing file changes per visit.
fn bool file_can_see(TokenList* tokens, String decl_module)
{
	if (decl_module.len == 0) return true;
	ModuleCtx ctx;
	ctx.build(tokens);
	return ctx.can_see(decl_module);
}

// Resolve the module that declares the symbol `target`, searching the usual
// 4 steps (current file -> open docs -> project files -> stdlib). Among several
// same-named declarations, one in a module visible from the requesting file wins
// (from an importer's file, its import resolves the symbol — not an unrelated
// module's same-named declaration found earlier in scan order). Returns "" when
// no declaration is found or the declaration is module-less — callers treat ""
// as "no visibility filtering possible".
fn String find_symbol_module(TokenList* tokens, Token target, String uri, DocumentList* docs, String stdlib_path)
{
	if (try decl_idx = tokens.find_declaration(target, tokens.size))
	{
		return tokens.module_of_decl(decl_idx);
	}

	ModuleCtx ctx;
	ctx.build(tokens);
	String fallback = "";
	bool have_fallback;

	for (sz d = 0; d < docs.size; d++)
	{
		if (docs.entries[d].uri == uri) continue;
		TokenStream* other = docs.entries[d].get_tokens();
		if (try found = other.tokens.find_declaration_in(target))
		{
			String mod = other.tokens.module_of_decl(found);
			if (ctx.can_see(mod)) return mod;
			if (!have_fallback)
			{
				fallback = mod;
				have_fallback = true;
			}
		}
	}

	DeclModuleScan scan = { target, &ctx, "", fallback, have_fallback };
	scan_project_then_stdlib(uri_to_path(uri), stdlib_path, &scan);
	if (scan.result.len > 0) return scan.result;
	return scan.fallback;
}

// On-disk declaring-module lookup, driven through the shared scan engine.
// Stops at the first declaration visible from ctx; module-blind first hit is
// kept as a fallback.
struct DeclModuleScan (FileVisitor) @private
{
	Token target;
	ModuleCtx* ctx;
	String result;
	String fallback;
	bool have_fallback;
}

fn bool DeclModuleScan.visit(&self, String path, String content, TokenStream* stream) @dynamic
{
	if (try found = stream.tokens.find_declaration_in(self.target))
	{
		// module_of_decl builds into the temp allocator, not the visited file's
		// content buffer, so keeping it past the visit is safe.
		String mod = stream.tokens.module_of_decl(found);
		if (self.ctx.can_see(mod))
		{
			self.result = mod;
			return true;
		}
		if (!self.have_fallback)
		{
			self.fallback = mod;
			self.have_fallback = true;
		}
	}
	return false;
}
