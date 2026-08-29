module lsp;

import std::core::dstring;
import std::core::mem;
import c3::lexer;

// Static type inference over the token stream, shared by go-to-definition, hover,
// signature help and completion. Everything here answers one question — "what is the
// type of the expression ending at token N?" — and the features on top turn that
// answer into a declaration lookup.
//
// The inference is deliberately syntactic: it reads declarations, not values, so it
// never needs a type checker. What it does need is *scope*, because a file-wide
// search for `Foo x` finds whichever `x` was declared first in the file, which is
// usually in an unrelated function — see `enclosing_decl_start`.

// Bound on how deep expression/alias resolution may recurse. Chains this long are
// pathological; the limit only exists so a cyclic alias cannot hang the server.
const int MAX_INFER_DEPTH = 24;

// What is statically known about an expression's type.
//
// `name` is the ELEMENT type when `is_array` is set: a declaration `Foo[4] v` names
// `Foo` and carries the array-ness in the flag, which is the convention the older
// find_variable_type/find_struct_field_type helpers already used. `generic` is the
// LAST generic argument of a parameterised type (`List{T}` -> T, `HashMap{K,V}` -> V)
// — the one indexing and `foreach` yield. `module` is the module the declaration was
// written in, used to prefer the right same-named type when two modules declare one.
struct TypeInfo
{
	String name;
	String generic;
	String mod;
	bool is_array;
	bool is_slice;
	bool is_pointer;
	// The declaration wrote the enclosing module's generic parameter (`Type* entries`
	// inside `module std::collections::list <Type>`) rather than a type of its own.
	bool is_type_param;
}

fn bool TypeInfo.known(&self) => self.name.len > 0;

// Index of the `fn`/`macro` keyword opening the declaration that encloses `idx`, or 0
// when `idx` is not inside a function body.
//
// Variable lookup is bounded by this. Without it `find_variable_type` scans the whole
// file and returns the first `<Type> name` it meets, so a `gltf::Node* source`
// parameter loses to an `AssetNode* source` declared in some earlier function — the
// receiver then resolves to the wrong struct and every member access off it misses.
fn sz TokenList.enclosing_decl_start(&self, sz idx)
{
	if (idx > self.size) idx = self.size;

	// Walk out through the enclosing braces. Each `{` still open when the walk
	// reaches the start of the file is an enclosing scope; the last one seen is the
	// outermost, i.e. the function body.
	sz depth      = 0;
	sz body_brace = self.size;
	for (sz k = idx; k > 0; k--)
	{
		TokenType t = self.entries[k - 1].type;
		if (t == RBRACE)
		{
			depth++;
			continue;
		}
		if (t == LBRACE)
		{
			if (depth == 0)
			{
				body_brace = k - 1;
				continue;
			}
			depth--;
		}
	}
	if (body_brace >= self.size) return 0;

	// Step back over the signature to the keyword that introduced it, so parameters
	// (which sit between the two) stay inside the searched range.
	for (sz k = body_brace; k > 0; k--)
	{
		TokenType t = self.entries[k - 1].type;
		if (t == FUNC || t == MACRO) return k - 1;
		if (t == EOS || t == RBRACE || t == LBRACE) break;
	}
	return 0;
}

// The last generic argument written inside the `{...}` block opening at `lbrace`, e.g.
// `Node` for `List{Node}` and `String` for `HashMap{String, String}` — the argument a
// `foreach` or an index expression over that type yields. Nested blocks are skipped
// whole, so `List{List{int}}` reports the outer `List`. Returns "" when the block
// holds no type token.
fn String TokenList.last_generic_arg(&self, sz lbrace)
{
	sz close = self.match_rbrace(lbrace);
	if (close >= self.size) return "";

	String last  = "";
	sz depth     = 0;
	for (sz j = lbrace + 1; j < close; j++)
	{
		TokenType t = self.entries[j].type;
		if (t == LBRACE)
		{
			depth++;
			continue;
		}
		if (t == RBRACE)
		{
			if (depth > 0) depth--;
			continue;
		}
		if (depth != 0) continue;
		if (t == TYPE_IDENT || is_builtin_type_token(t)) last = self.entries[j].text;
	}
	return last;
}

// Read the type written at `i` — a TYPE_IDENT or builtin primitive, optionally
// generic (`List{T}`), optionally followed by any mix of `*`, `?`, `[N]`, `[]` and
// `[<N>]` suffixes. On success *out describes the type and *after receives the index
// of the first token past it.
fn bool TokenList.read_type_at(&self, sz i, TypeInfo* out, sz* after)
{
	if (i >= self.size) return false;
	TokenType lead = self.entries[i].type;
	if (lead != TYPE_IDENT && !is_builtin_type_token(lead)) return false;

	*out = { .name = self.entries[i].text };

	// A `mod::` qualifier in front of the name says which module the type is from.
	if (i >= 2 && self.entries[i - 1].type == SCOPE && is_ident(self.entries[i - 2].type))
	{
		out.mod = self.join_path_segments(self.qualifier_chain_start(i), i - 1);
	}

	sz j = i + 1;
	if (j < self.size && self.entries[j].type == LBRACE)
	{
		out.generic = self.last_generic_arg(j);
		j           = self.match_rbrace(j);
		if (j >= self.size) return false;
		j++;
	}

	while (j < self.size)
	{
		TokenType t = self.entries[j].type;
		if (t == STAR || t == QUESTION)
		{
			if (t == STAR && !out.is_array) out.is_pointer = true;
			j++;
			continue;
		}
		if (t == LBRACKET)
		{
			sz close = self.match_rbracket(j);
			if (close >= self.size) break;
			if (!out.is_array) out.is_slice = (j + 1 == close); // the first pair classifies
			out.is_array = true;
			j            = close + 1;
			continue;
		}
		if (t == LVEC)
		{
			// Vector suffix `[<N>]` — its own token pair, and never a slice.
			sz close = j + 1;
			while (close < self.size && self.entries[close].type != RVEC) close++;
			if (close >= self.size) break;
			out.is_array = true;
			j            = close + 1;
			continue;
		}
		break;
	}

	*after = j;
	return true;
}

// Read a variable declaration `<type> name` whose leading type token is at `i`, and
// report whether it binds `var_name`. The token after the name must be one that can
// legally follow a declarator, so `Foo bar` inside an expression is not mistaken for
// a declaration. `allow_colon` adds the `:` that closes a typed `foreach` binding
// (`foreach (Item it : xs)`), which is a terminator only there.
fn bool TokenList.read_var_decl(&self, sz i, String var_name, TypeInfo* out, bool allow_colon = false)
{
	TypeInfo t;
	sz after;
	if (!self.read_type_at(i, &t, &after)) return false;
	if (after >= self.size) return false;
	TokenType named = self.entries[after].type;
	// A typed constant (`const Conf DEFAULTS = ...`) declares a receiver as much as a
	// variable does, and its name is a CONST_IDENT rather than an IDENT.
	if (!is_ident(named) && named != CONST_IDENT) return false;
	if (self.entries[after].text != var_name) return false;
	if (after + 1 >= self.size) return false;

	TokenType next = self.entries[after + 1].type;
	bool ends_decl = next == EOS || next == EQ || next == COMMA || next == DOT || next == RPAREN
		|| (allow_colon && next == COLON);
	if (!ends_decl) return false;

	if (t.mod.len == 0) t.mod = self.module_of_decl(i);
	*out = t;
	return true;
}

// The index of the first `:` at paren depth zero between `lparen` and `rparen`, which
// in a `foreach` header separates the bindings from the collection. Returns `rparen`
// when there is none.
fn sz TokenList.foreach_colon(&self, sz lparen, sz rparen)
{
	sz depth = 0;
	for (sz j = lparen + 1; j < rparen; j++)
	{
		TokenType t = self.entries[j].type;
		if (t == LPAREN || t == LBRACKET || t == LBRACE || t == LVEC)
		{
			depth++;
			continue;
		}
		if (t == RPAREN || t == RBRACKET || t == RBRACE || t == RVEC)
		{
			depth--;
			continue;
		}
		if (depth == 0 && t == COLON) return j;
	}
	return rparen;
}

// The type a `foreach` / `foreach_r` whose keyword is at `fe_idx` binds to `var_name`.
//
// The header is `foreach ([index ,] [&] value : collection)`. A binding written with
// its type (`foreach (Foo f : xs)`) is read straight off the declaration; the common
// untyped forms (`foreach (x : xs)`, `foreach (&x : xs)`, `foreach (i, &x : xs)`) take
// the collection's element type, which is what makes members of the loop variable
// resolve at all. Returns an unknown TypeInfo when this loop does not bind `var_name`.
fn TypeInfo TokenList.foreach_binding_type(
	&self,
	sz fe_idx,
	String var_name,
	String uri,
	DocumentList* docs,
	String stdlib_path,
	int depth
)
{
	TypeInfo none;
	sz lparen = fe_idx + 1;
	if (lparen >= self.size || self.entries[lparen].type != LPAREN) return none;

	sz rparen = self.match_rparen(lparen);
	if (rparen >= self.size) return none;

	sz colon = self.foreach_colon(lparen, rparen);
	if (colon >= rparen) return none;

	// The value binding is the last comma-separated declarator before the ':'.
	sz start = lparen + 1;
	sz d     = 0;
	for (sz j = lparen + 1; j < colon; j++)
	{
		TokenType t = self.entries[j].type;
		if (t == LPAREN || t == LBRACKET || t == LBRACE || t == LVEC)
		{
			d++;
			continue;
		}
		if (t == RPAREN || t == RBRACKET || t == RBRACE || t == RVEC)
		{
			d--;
			continue;
		}
		if (d == 0 && t == COMMA) start = j + 1;
	}
	if (start < colon && self.entries[start].type == AMP) start++; // `&value` binds by reference
	if (start >= colon) return none;

	// `[&] name :` — no type written, so it comes from the collection.
	if (start + 1 == colon)
	{
		if (!is_ident(self.entries[start].type) || self.entries[start].text != var_name) return none;
		TypeInfo coll = self.expr_type(rparen - 1, uri, docs, stdlib_path, depth + 1);
		return self.element_type_of(coll, uri, docs, stdlib_path, depth);
	}

	TypeInfo decl;
	if (!self.read_var_decl(start, var_name, &decl, true)) return none;
	return decl;
}

// The type `try name = <expr>` at `try_idx` binds — the success type of the optional
// on the right, which is what `expr_type` already reports for a call to `fn Foo? f()`.
//
// Only the `=` form binds: bare `if (try x)` tests an optional declared elsewhere.
// `catch` is not read here because it binds a fault rather than a value.
fn TypeInfo TokenList.try_binding_type(
	&self,
	sz try_idx,
	String var_name,
	String uri,
	DocumentList* docs,
	String stdlib_path,
	int depth
)
{
	TypeInfo none;
	sz name_idx = try_idx + 1;
	if (name_idx + 1 >= self.size) return none;
	if (!is_ident(self.entries[name_idx].type) || self.entries[name_idx].text != var_name) return none;
	if (self.entries[name_idx + 1].type != EQ) return none;

	// The initialiser runs to the end of the condition: the `)` that closes the
	// enclosing `if (`/`while (`, or a `,` separating further bindings.
	sz d    = 0;
	sz last = name_idx + 1;
	for (sz j = name_idx + 2; j < self.size; j++)
	{
		TokenType t = self.entries[j].type;
		if (t == LPAREN || t == LBRACKET || t == LBRACE || t == LVEC)
		{
			d++;
		}
		else if (t == RPAREN || t == RBRACKET || t == RBRACE || t == RVEC)
		{
			if (d == 0) break;
			d--;
		}
		else if (d == 0 && (t == EOS || t == COMMA))
		{
			break;
		}
		last = j;
	}
	if (last <= name_idx + 1) return none;
	return self.expr_type(last, uri, docs, stdlib_path, depth + 1);
}

// The type bound to `var_name` at token `before_idx`, searched within the enclosing
// function only. The nearest preceding binding wins, so a shadowing local beats the
// parameter it shadows and a `foreach` variable beats a same-named one declared above
// the loop. Returns an unknown TypeInfo when the enclosing scope binds no such name.
fn TypeInfo TokenList.scoped_var_type(
	&self,
	String var_name,
	sz before_idx,
	String uri,
	DocumentList* docs,
	String stdlib_path,
	int depth
)
{
	TypeInfo best;
	if (before_idx > self.size) before_idx = self.size;
	sz start = self.enclosing_decl_start(before_idx);

	for (sz i = start; i + 1 < before_idx; i++)
	{
		TokenType lead = self.entries[i].type;
		if (lead == FOREACH || lead == FOREACH_R)
		{
			TypeInfo fe = self.foreach_binding_type(i, var_name, uri, docs, stdlib_path, depth);
			if (fe.known()) best = fe;
			continue;
		}
		if (lead == TRY)
		{
			TypeInfo tb = self.try_binding_type(i, var_name, uri, docs, stdlib_path, depth);
			if (tb.known()) best = tb;
			continue;
		}
		if (lead != TYPE_IDENT && !is_builtin_type_token(lead)) continue;

		TypeInfo d;
		if (self.read_var_decl(i, var_name, &d)) best = d;
	}
	return best;
}

// The type declared for `var_name` anywhere in this file, first match wins. Used for
// declarations outside any function — globals and file-scope constants — which the
// scoped search cannot reach.
fn TypeInfo TokenList.file_var_type(&self, String var_name)
{
	for (sz i = 0; i + 1 < self.size; i++)
	{
		TokenType lead = self.entries[i].type;
		if (lead != TYPE_IDENT && !is_builtin_type_token(lead)) continue;

		TypeInfo d;
		if (self.read_var_decl(i, var_name, &d)) return d;
	}
	return {};
}

// Read the right-hand side of `alias Name = <type>;`, skipping any attributes between
// the alias name and the `=` (`alias Vec3 @weak = float[<3>]`) and any `mod::`
// qualifier on the right. Returns an unknown TypeInfo when `type_name` is not aliased
// here or the right-hand side is not a plain type (e.g. a function-pointer alias).
fn TypeInfo TokenList.alias_target(&self, String type_name)
{
	TypeInfo none;
	for (sz i = 0; i + 3 < self.size; i++)
	{
		if (self.entries[i].type != ALIAS) continue;
		if (self.entries[i + 1].type != TYPE_IDENT || self.entries[i + 1].text != type_name) continue;

		// Skip attributes (`@weak`, `@private`, `@if(...)`) up to the `=`.
		sz j = i + 2;
		while (j < self.size && self.entries[j].type != EQ && self.entries[j].type != EOS)
		{
			if (self.entries[j].type == LPAREN)
			{
				j = self.match_rparen(j);
				if (j >= self.size) break;
			}
			j++;
		}
		if (j >= self.size || self.entries[j].type != EQ) continue;
		j++;

		// Skip a `mod::` qualifier in front of the aliased type.
		while (j + 1 < self.size && is_ident(self.entries[j].type) && self.entries[j + 1].type == SCOPE) j += 2;

		TypeInfo t;
		sz after;
		if (!self.read_type_at(j, &t, &after)) continue;
		if (t.mod.len == 0) t.mod = self.module_of_decl(i + 1);
		return t;
	}
	return none;
}

// Resolve `type_name` one alias step, searching the current file, the open documents,
// then the project and the stdlib on disk. Returns an unknown TypeInfo when the name
// is not an alias — callers then keep using the name they had.
fn TypeInfo TokenList.alias_target_across(
	&self,
	String type_name,
	String uri,
	DocumentList* docs,
	String stdlib_path
)
{
	TypeInfo t = self.alias_target(type_name);
	if (t.known()) return t;

	for (sz d = 0; d < docs.size; d++)
	{
		TokenStream* doc_stream = docs.entries[d].get_tokens();
		t                       = doc_stream.tokens.alias_target(type_name);
		if (t.known()) return t;
	}

	String file_path = uri_to_path(uri);
	if (file_path.len == 0) return {};
	AliasScan scan = { type_name, {} };
	scan_project_then_stdlib(file_path, stdlib_path, &scan);
	return scan.result;
}

// On-disk alias lookup, driven through the shared scan engine.
struct AliasScan (FileVisitor) @private
{
	String type_name;
	TypeInfo result;
}

fn bool AliasScan.visit(&self, String path, String content, TokenStream* stream) @dynamic
{
	TypeInfo t = stream.tokens.alias_target(self.type_name);
	if (!t.known()) return false;
	self.result = t.copy_temp();
	return true;
}

// Copy the borrowed name slices into temp storage. Scan results point into a file
// buffer the scan engine may free as soon as the visit returns.
fn TypeInfo TypeInfo.copy_temp(&self)
{
	DString buf = dstring::temp();
	buf.append(self.name);
	String name = buf.str_view();

	String generic = "";
	if (self.generic.len > 0)
	{
		DString g = dstring::temp();
		g.append(self.generic);
		generic = g.str_view();
	}
	String mod_name = "";
	if (self.mod.len > 0)
	{
		DString m = dstring::temp();
		m.append(self.mod);
		mod_name = m.str_view();
	}
	return {
		.name          = name,
		.generic       = generic,
		.mod           = mod_name,
		.is_array      = self.is_array,
		.is_slice      = self.is_slice,
		.is_pointer    = self.is_pointer,
		.is_type_param = self.is_type_param,
	};
}

// Follow `type_name` through its alias chain to the type that actually carries the
// members — `NodeList` -> `List{Node}`, `Vec3` -> `float[<3>]`. Returns the input
// unchanged when it is not an alias.
fn TypeInfo TokenList.canonical_type(&self, String type_name, String uri, DocumentList* docs, String stdlib_path)
{
	TypeInfo cur = { .name = type_name };
	for (int step = 0; step < 8; step++)
	{
		TypeInfo next = self.alias_target_across(cur.name, uri, docs, stdlib_path);
		if (!next.known() || next.name == cur.name) break;
		cur = next;
	}
	return cur;
}

// The type of one element of a collection type: the base type for an array, slice or
// vector, and the last generic argument for a parameterised container (`List{T}` -> T,
// `HashMap{K,V}` -> V, which is the value a `foreach` over a map yields). Named
// aliases are followed, so `NodeList` reaches `List{Node}`.
fn TypeInfo TokenList.element_type_of(
	&self,
	TypeInfo t,
	String uri,
	DocumentList* docs,
	String stdlib_path,
	int depth = 0
)
{
	if (t.is_array) return { .name = t.name, .mod = t.mod };
	// A parameterised container answers with its argument even through a pointer,
	// since `List{Item}* p` still indexes as a List.
	if (t.generic.len > 0) return { .name = t.generic, .mod = t.mod };
	// A bare pointer indexes as an array of what it points at (`Type* entries`).
	if (t.is_pointer) return { .name = t.name, .mod = t.mod };
	if (!t.known() || depth > MAX_INFER_DEPTH) return {};

	TypeInfo base = self.canonical_type(t.name, uri, docs, stdlib_path);
	if (base.is_array) return { .name = base.name, .mod = base.mod };
	if (base.generic.len > 0) return { .name = base.generic, .mod = base.mod };
	return {};
}

// The type of a range-slice expression `xs[a..b]`. Slicing yields another slice of
// the same element type, so a named slice type (`String`) slices to itself and the
// members reached through it are still the collection's. A pointer is the one shape
// that changes: `Foo* p` slices to `Foo[]`.
fn TypeInfo slice_of(TypeInfo t)
{
	if (!t.is_pointer) return t;
	TypeInfo out   = t;
	out.is_pointer = false;
	out.is_array   = true;
	out.is_slice   = true;
	return out;
}

// Whether the bracket pair `lbracket`..`rbracket` holds a range rather than a single
// index — `[a..b]`, `[a:n]`, `[..b]`, `[a..]`, `[..]`. Only the top level counts, so a
// nested index (`xs[ys[a..b].len]`) does not make the outer pair a range. A `:` is
// read as a range separator only when no `?` precedes it at the same level, which
// leaves a ternary index (`xs[c ? a : b]`) reading as the single index it is.
fn bool TokenList.brackets_hold_range(&self, sz lbracket, sz rbracket)
{
	bool ternary = false;
	sz depth     = 0;
	for (sz j = lbracket + 1; j < rbracket; j++)
	{
		TokenType t = self.entries[j].type;
		if (t == LPAREN || t == LBRACKET || t == LBRACE || t == LVEC)
		{
			depth++;
			continue;
		}
		if (t == RPAREN || t == RBRACKET || t == RBRACE || t == RVEC)
		{
			if (depth > 0) depth--;
			continue;
		}
		if (depth != 0) continue;
		if (t == DOTDOT) return true;
		if (t == QUESTION) ternary = true;
		if (t == COLON && !ternary) return true;
	}
	return false;
}

// The declared type of `field` on `parent`, following `parent`'s aliases when the
// name itself carries no fields. Arrays have no named members, so they yield nothing.
fn TypeInfo TokenList.field_type_of(&self, TypeInfo parent, String field, String uri, DocumentList* docs, String stdlib_path)
{
	if (parent.is_array || !parent.known()) return {};

	TypeInfo found = self.struct_field_type_across(parent.name, field, uri, docs, stdlib_path);
	if (found.known()) return substitute_type_param(found, parent);

	// The fields may live on the type the name is an alias of, and the alias is also
	// where the generic argument was written (`alias TokenList = List{Token}`).
	TypeInfo base = self.canonical_type(parent.name, uri, docs, stdlib_path);
	if (base.name == parent.name) return {};
	if (base.generic.len == 0) base.generic = parent.generic;

	found = self.struct_field_type_across(base.name, field, uri, docs, stdlib_path);
	if (!found.known()) return {};
	return substitute_type_param(found, base);
}

// Resolve a declaration typed with the declaring module's generic parameter against
// the receiver it was reached through: `List{Token}.entries` is declared `Type*` and
// is a `Token*` here. Without the argument there is nothing to substitute, and an
// unknown type is better than the placeholder name.
fn TypeInfo substitute_type_param(TypeInfo t, TypeInfo recv)
{
	if (!t.is_type_param) return t;
	if (recv.generic.len == 0) return {};

	TypeInfo out      = t;
	out.name          = recv.generic;
	out.generic       = "";
	out.is_type_param = false;
	return out;
}

// The declared type of `struct_type.field_name`, searched across the current file,
// the open documents, the project and the stdlib. Unlike the older
// find_struct_field_type wrapper this keeps the array/generic facts of the field, so
// `List{GpuMesh} meshes` can be indexed and iterated.
fn TypeInfo TokenList.struct_field_type_across(
	&self,
	String struct_type,
	String field_name,
	String uri,
	DocumentList* docs,
	String stdlib_path
)
{
	TypeInfo t = self.field_decl_type(struct_type, field_name);
	if (t.known()) return t;

	for (sz d = 0; d < docs.size; d++)
	{
		TokenStream* doc_stream = docs.entries[d].get_tokens();
		t                       = doc_stream.tokens.field_decl_type(struct_type, field_name);
		if (t.known()) return t;
	}

	String file_path = uri_to_path(uri);
	if (file_path.len == 0) return {};
	FieldTypeScan scan = { struct_type, field_name, {} };
	scan_project_then_stdlib(file_path, stdlib_path, &scan);
	return scan.result;
}

struct FieldTypeScan (FileVisitor) @private
{
	String struct_type;
	String field_name;
	TypeInfo result;
}

fn bool FieldTypeScan.visit(&self, String path, String content, TokenStream* stream) @dynamic
{
	TypeInfo t = stream.tokens.field_decl_type(self.struct_type, self.field_name);
	if (!t.known()) return false;
	self.result = t.copy_temp();
	return true;
}

// The declared type of `field_name` inside `struct/union/bitstruct type_name`, as
// written in this file. Field declarations read the same way variable declarations do,
// only backwards — the name comes last — so the type is found by stepping back over
// the declarator suffixes from the field name.
fn TypeInfo TokenList.field_decl_type(&self, String type_name, String field_name)
{
	self.@each_struct_member(type_name, null; sz j)
	{
		TypeInfo found;
		if (self.entries[j].text == field_name && self.read_field_decl(j, &found)) return found;
	};
	return {};
}

// Read the type of the field whose name token is at `name_idx`. A field declaration
// is a type followed by the name, so the type is found by stepping back over the
// declarator suffixes; it must end exactly at the name, which rules out the trailing
// names of a comma list (`Real m00, m10;` — only `m00` carries the type).
fn bool TokenList.read_field_decl(&self, sz name_idx, TypeInfo* out)
{
	sz lead = self.decl_type_start(name_idx);
	if (lead >= self.size) return false;

	TypeInfo t;
	sz after;
	if (!self.read_type_at(lead, &t, &after)) return false;
	if (after != name_idx) return false;
	if (t.mod.len == 0) t.mod = self.module_of_decl(name_idx);
	t.is_type_param = self.is_module_generic_param(name_idx, t.name);
	*out            = t;
	return true;
}

// Walk back from a declarator name at `name_idx` over the suffixes that may sit
// between a type and the name it declares (`*`, `[N]`, `[]`, `[<N>]`, `{T}`) to the
// index of the leading type token. Returns self.size when there is none.
fn sz TokenList.decl_type_start(&self, sz name_idx)
{
	if (name_idx == 0) return self.size;
	sz p = name_idx - 1;
	while (p > 0)
	{
		TokenType t = self.entries[p].type;
		if (t == STAR || t == QUESTION)
		{
			p--;
			continue;
		}
		if (t == RBRACKET)
		{
			sz open = self.match_lbracket_back(p);
			if (open >= self.size || open == 0) return self.size;
			p = open - 1;
			continue;
		}
		if (t == RVEC)
		{
			sz open = p;
			while (open > 0 && self.entries[open].type != LVEC) open--;
			if (self.entries[open].type != LVEC || open == 0) return self.size;
			p = open - 1;
			continue;
		}
		if (t == RBRACE)
		{
			sz open = self.match_lbrace_back(p);
			if (open >= self.size || open == 0) return self.size;
			p = open - 1;
			continue;
		}
		break;
	}
	if (self.entries[p].type == TYPE_IDENT || is_builtin_type_token(self.entries[p].type)) return p;
	return self.size;
}

// The type of the expression whose last token is `last`.
//
// This is the shared core of receiver resolution. It handles plain variables, `self`,
// field chains (`a.b.c`), call results (`f(..)`, `x.m(..)`), index and slice
// expressions (`xs[i]`), parenthesised expressions and type names used as namespaces
// (`Color.RED`). Anything it cannot read yields an unknown TypeInfo rather than a
// guess, because a wrong receiver type sends go-to-definition to the wrong file.
fn TypeInfo TokenList.expr_type(&self, sz last, String uri, DocumentList* docs, String stdlib_path, int depth = 0)
{
	if (depth > MAX_INFER_DEPTH || last >= self.size) return {};

	Token t = self.entries[last];
	switch (t.type)
	{
		case RPAREN:
			return self.paren_expr_type(last, uri, docs, stdlib_path, depth);
		case RBRACKET:
			// `xs[i]` yields an element, but `xs[a..b]` / `xs[a:n]` yields another
			// slice of the same thing — `line[p..].trim()` calls String.trim, not
			// char.trim, so the two cases cannot share an answer.
			sz open = self.match_lbracket_back(last);
			if (open >= self.size || open == 0) return {};
			TypeInfo indexed = self.expr_type(open - 1, uri, docs, stdlib_path, depth + 1);
			if (self.brackets_hold_range(open, last)) return slice_of(indexed);
			return self.element_type_of(indexed, uri, docs, stdlib_path, depth);
		case TYPE_IDENT:
			// A type name used as a namespace: `Color.RED`, `Foo.static_method()`.
			TypeInfo named = { .name = t.text };
			if (last >= 2 && self.entries[last - 1].type == SCOPE && is_ident(self.entries[last - 2].type))
			{
				named.mod = self.join_path_segments(self.qualifier_chain_start(last), last - 1);
			}
			return named;
		case IDENT:
		case AT_IDENT:
		case CONST_IDENT:
			break;
		default:
			return {};
	}

	// `parent.name` — a field of whatever precedes the dot.
	if (last >= 2 && self.entries[last - 1].type == DOT)
	{
		TypeInfo parent = self.expr_type(last - 2, uri, docs, stdlib_path, depth + 1);
		if (!parent.known()) return {};
		return self.field_type_of(parent, t.text, uri, docs, stdlib_path);
	}

	// A cast names the type outright: `(Foo*)raw` is a Foo however `raw` was declared.
	// Only a parenthesised group holding exactly a type counts, so a `foreach`,
	// `if` or `while` header before the identifier is not mistaken for one.
	if (last >= 1 && self.entries[last - 1].type == RPAREN)
	{
		sz? open = self.match_paren_backward(last - 1);
		if (try open)
		{
			TypeInfo cast;
			sz after;
			if (self.read_type_at(open + 1, &cast, &after) && after == last - 1) return cast;
		}
	}

	// A module-qualified name (`mod::thing`) names a global, never a local, so the
	// scoped pass would only find an unrelated same-named variable.
	bool qualified = last >= 1 && self.entries[last - 1].type == SCOPE;

	if (!qualified)
	{
		TypeInfo local = self.scoped_var_type(t.text, last, uri, docs, stdlib_path, depth);
		if (local.known()) return local;

		if (t.text == "self")
		{
			String enclosing = self.find_enclosing_method_type(t.offset);
			if (enclosing.len > 0) return { .name = enclosing, .mod = self.module_of_decl(last) };
		}
	}

	// Fall back to the file-wide search for declarations outside any function
	// (globals, and file-scope constants) that the scoped pass cannot see.
	return self.file_var_type(t.text);
}

// The type of an expression ending in `)` — either a call, or a parenthesised
// expression whose type is the type of what it wraps.
fn TypeInfo TokenList.paren_expr_type(
	&self,
	sz rparen,
	String uri,
	DocumentList* docs,
	String stdlib_path,
	int depth
)
{
	sz? matched = self.match_paren_backward(rparen);
	if (catch matched) return {};
	sz lparen = matched;
	if (lparen == 0) return {};

	sz name_idx = lparen - 1;

	// Generic call `name{Args}(...)` — step over the argument block to the callee.
	if (self.entries[name_idx].type == RBRACE)
	{
		sz lbrace = self.match_lbrace_back(name_idx);
		if (lbrace >= self.size || lbrace == 0) return {};
		name_idx = lbrace - 1;
	}

	Token callee = self.entries[name_idx];

	// A cast `(Type)expr` reads as `)`-terminated too, but its `(` is preceded by
	// something that is not a callee name — treat only identifiers as calls.
	if (!is_ident(callee.type))
	{
		// `(expr)` — the parentheses are grouping, so the type is the inner
		// expression's. Guard against an empty pair.
		if (rparen > lparen + 1) return self.expr_type(rparen - 1, uri, docs, stdlib_path, depth + 1);
		return {};
	}

	if (name_idx >= 1 && self.entries[name_idx - 1].type == DOT)
	{
		// Method call — resolve its own receiver first, then the method's return type.
		TypeInfo recv = self.expr_type(name_idx - 2, uri, docs, stdlib_path, depth + 1);
		if (!recv.known()) return {};
		return self.call_return_type(recv, callee.text, uri, docs, stdlib_path);
	}

	// Free function, possibly module-qualified (`mod::make(...)`).
	return self.call_return_type({}, callee.text, uri, docs, stdlib_path);
}

// The return type of `name` called on `recv` (or as a free function when `recv` is
// unknown). Aliases on the receiver are followed, since methods are declared on the
// underlying type as often as on the alias.
fn TypeInfo TokenList.call_return_type(&self, TypeInfo recv, String name, String uri, DocumentList* docs, String stdlib_path)
{
	String ret = self.resolve_call_return_type_across(recv.name, name, uri, docs, stdlib_path);
	if (ret.len == 0 && recv.known())
	{
		TypeInfo base = self.canonical_type(recv.name, uri, docs, stdlib_path);
		if (base.name != recv.name) ret = self.resolve_call_return_type_across(base.name, name, uri, docs, stdlib_path);
	}
	if (ret.len == 0) return {};
	return { .name = ret };
}

// True when the `{` at `lbrace` opens an anonymous `struct`/`union`/`bitstruct` block
// inside a struct body. C3 inlines such a block into its parent, so `Matrix4x4`'s
// `m` — declared inside `union { struct { ... } Real[<16>] m; }` — is reached as
// `mat.m`, not `mat.<something>.m`. A named nested type (`struct inner { ... }`)
// declares a member instead and is not inlined.
fn bool TokenList.opens_inlined_member_block(&self, sz lbrace)
{
	if (lbrace == 0) return false;
	// Step back over what may sit between the keyword and the brace: attributes
	// (`@packed`), and a bitstruct's backing type (`bitstruct : uint {`).
	for (sz k = lbrace; k > 0 && k + 8 > lbrace; k--)
	{
		TokenType t = self.entries[k - 1].type;
		if (t == STRUCT || t == UNION || t == BITSTRUCT) return true;
		if (t == TYPE_IDENT || is_ident(t) || t == EOS || t == LBRACE || t == RBRACE) return false;
	}
	return false;
}

<*
 Visit the name token of every member of `struct`/`union`/`bitstruct type_name` as
 declared in this token list, passing its index to the body.

 Members of an anonymous `struct`/`union` nested in the body are visited too, because
 C3 inlines those into the parent — without this, `Matrix4f.m` and every other field
 declared inside a union resolves to nothing. Members of a *named* nested type are
 not, since they belong to that type.

 When `ctx` is non-null only declarations that module can see are visited, which is
 how completion keeps another module's same-named struct out of the list.
*>
macro TokenList.@each_struct_member(&self, String type_name, ModuleCtx* ctx; @body(sz name_idx))
{
	for (sz i = 0; i + 1 < self.size; i++)
	{
		TokenType kw = self.entries[i].type;
		if (kw != STRUCT && kw != BITSTRUCT && kw != UNION) continue;
		if (self.entries[i + 1].type != TYPE_IDENT || self.entries[i + 1].text != type_name) continue;
		if (ctx != null && !ctx.can_see(self.module_of_decl(i))) continue;

		sz brace = i + 2;
		while (brace < self.size && self.entries[brace].type != LBRACE) brace++;
		if (brace >= self.size) continue;

		// `depth` counts open braces inside the body; `opaque` counts only those that
		// do NOT inline, so members are the idents seen while `opaque` is zero.
		// `inlined` remembers, per depth, which kind a brace was.
		sz depth     = 0;
		sz opaque    = 0;
		ulong inlined = 0;
		for (sz j = brace + 1; j < self.size; j++)
		{
			TokenType t = self.entries[j].type;
			if (t == LBRACE)
			{
				bool anon = depth < 63 && self.opens_inlined_member_block(j);
				depth++;
				if (anon)
				{
					inlined |= 1UL << (depth - 1);
				}
				else
				{
					opaque++;
				}
				continue;
			}
			if (t == RBRACE)
			{
				if (depth == 0) break; // closes the struct body
				if ((inlined & (1UL << (depth - 1))) == 0)
				{
					opaque--;
				}
				else
				{
					inlined &= ~(1UL << (depth - 1));
				}
				depth--;
				continue;
			}
			if (opaque != 0 || t != IDENT) continue;
			@body(j);
		}
	}
}

// Whether the method/macro whose name token is at `name_idx` is declared on
// `recv_type`.
//
// The receiver sits just before the `.`, and is not always a plain TYPE_IDENT: the
// stdlib declares the members every float vector has as `macro float
// float[<*>].length(...)`, so the receiver can be a builtin primitive carrying an
// array, slice or vector suffix. `recv_is_array` says whether the type being looked up
// is itself array-shaped, which keeps `Vec3` (an alias of `float[<3>]`) matching
// `float[<*>].length` while a plain `float` does not.
fn bool TokenList.method_receiver_matches(&self, sz name_idx, String recv_type, bool recv_is_array)
{
	if (name_idx < 2 || self.entries[name_idx - 1].type != DOT) return false;

	sz p         = name_idx - 2;
	bool suffixed = false;
	while (p > 0)
	{
		TokenType t = self.entries[p].type;
		if (t == STAR)
		{
			p--;
			continue;
		}
		if (t == RBRACKET)
		{
			sz open = self.match_lbracket_back(p);
			if (open >= self.size || open == 0) return false;
			suffixed = true;
			p        = open - 1;
			continue;
		}
		if (t == RVEC)
		{
			sz open = p;
			while (open > 0 && self.entries[open].type != LVEC) open--;
			if (self.entries[open].type != LVEC || open == 0) return false;
			suffixed = true;
			p        = open - 1;
			continue;
		}
		if (t == RBRACE)
		{
			// Generic receiver `Foo{Type}.method` — the arguments are not part of
			// the name being matched.
			sz open = self.match_lbrace_back(p);
			if (open >= self.size || open == 0) return false;
			p = open - 1;
			continue;
		}
		break;
	}

	TokenType lead = self.entries[p].type;
	if (lead != TYPE_IDENT && !is_builtin_type_token(lead)) return false;
	if (self.entries[p].text != recv_type) return false;
	return suffixed == recv_is_array;
}

// The `(` of the call whose argument list directly encloses `idx`, with *arg_index
// receiving the position `idx` sits at. Balanced groups on the way back are skipped
// whole, so a nested call's commas do not shift the count. Returns self.size when
// `idx` is not inside a call's argument list.
fn sz TokenList.enclosing_call_lparen(&self, sz idx, sz* arg_index)
{
	sz argn = 0;
	for (sz k = idx + 1; k > 1; k--)
	{
		sz i        = k - 1;
		TokenType t = self.entries[i].type;
		if (t == RPAREN)
		{
			sz? open = self.match_paren_backward(i);
			if (catch open) return self.size;
			if (open == 0) return self.size;
			k = open + 1;
			continue;
		}
		if (t == RBRACE)
		{
			sz open = self.match_lbrace_back(i);
			if (open >= self.size || open == 0) return self.size;
			k = open + 1;
			continue;
		}
		if (t == RBRACKET)
		{
			sz open = self.match_lbracket_back(i);
			if (open >= self.size || open == 0) return self.size;
			k = open + 1;
			continue;
		}
		if (t == COMMA)
		{
			argn++;
			continue;
		}
		if (t == LPAREN)
		{
			// Only a call has argument positions; `if (`, `(cast)` and grouping
			// parens do not.
			if (i == 0 || !is_ident(self.entries[i - 1].type)) return self.size;
			*arg_index = argn;
			return i;
		}
		if (t == EOS || t == LBRACE || t == LBRACKET) return self.size;
	}
	return self.size;
}

// True when `name` is one of the generic parameters of the module enclosing
// `decl_idx` — the names in `module std::collections::list {Type};`. Such a parameter
// is not a real type; it stands for whatever the instantiation supplied, so the caller
// substitutes the receiver's own generic argument for it.
fn bool TokenList.is_module_generic_param(&self, sz decl_idx, String name)
{
	if (name.len == 0) return false;
	for (sz k = decl_idx; k > 0; k--)
	{
		if (self.entries[k - 1].type != MODULE) continue;
		// The parameter list is written `<Type>` on the module declaration, even
		// though instantiations spell it `List{Type}`. Both are accepted here.
		for (sz j = k; j < self.size && self.entries[j].type != EOS; j++)
		{
			TokenType open = self.entries[j].type;
			if (open != LBRACE && open != LESS) continue;
			TokenType close_type = open == LBRACE ? RBRACE : GREATER;
			for (sz q = j + 1; q < self.size && self.entries[q].type != close_type; q++)
			{
				if (self.entries[q].type == TYPE_IDENT && self.entries[q].text == name) return true;
			}
			return false;
		}
		return false;
	}
	return false;
}

// The declared type of parameter `arg_index` of the `fn`/`macro` named `name` — a
// method on `type_name` when that is non-empty, otherwise a free function.
//
// A method's implicit `self` parameter is skipped, so `arg_index` counts arguments the
// way they are written at the call site. The result is marked `is_type_param` when the
// parameter's type is one of the declaring module's generic parameters.
fn TypeInfo TokenList.param_decl_type(&self, String type_name, String name, sz arg_index)
{
	for (sz i = 0; i < self.size; i++)
	{
		TokenType kw = self.entries[i].type;
		if (kw != FUNC && kw != MACRO) continue;

		sz? found = self.fn_lparen_after(i);
		if (catch found) continue;
		sz lparen = found;
		if (lparen == 0) continue;

		sz name_idx = lparen - 1;
		if (!is_ident(self.entries[name_idx].type) || self.entries[name_idx].text != name) continue;

		bool is_method = name_idx >= 1 && self.entries[name_idx - 1].type == DOT;
		if (type_name.len > 0)
		{
			if (!self.method_receiver_matches(name_idx, type_name, false)) continue;
		}
		else if (is_method)
		{
			continue; // a method, where a free function was asked for
		}

		sz rparen = self.match_rparen(lparen);
		if (rparen >= self.size) continue;

		sz want  = is_method ? arg_index + 1 : arg_index; // the receiver takes slot 0
		sz group = lparen + 1;
		sz argn  = 0;
		sz depth = 0;
		for (sz j = lparen + 1; j <= rparen; j++)
		{
			TokenType t = self.entries[j].type;
			if (t == LPAREN || t == LBRACE || t == LBRACKET || t == LVEC)
			{
				depth++;
				continue;
			}
			if (t == RBRACE || t == RBRACKET || t == RVEC)
			{
				depth--;
				continue;
			}
			if (t == RPAREN && j != rparen)
			{
				depth--;
				continue;
			}
			if (depth != 0) continue;
			if (t != COMMA && j != rparen) continue;

			if (argn == want)
			{
				sz start = group;
				if (start < j && self.entries[start].type == AMP) start++;
				TypeInfo pt;
				sz after;
				if (!self.read_type_at(start, &pt, &after)) return {};
				pt.is_type_param = self.is_module_generic_param(i, pt.name);
				return pt;
			}
			argn++;
			group = j + 1;
		}
		return {};
	}
	return {};
}

// The declared type of argument `arg_index` of `name` called on `recv`, searched
// across the current file, the open documents, the project and the stdlib.
//
// A parameter typed with the declaring module's generic parameter (`Type value` in
// `macro List.push(&self, Type value)`) is not a type of its own: the receiver's own
// generic argument is substituted, so `List{PlacedNode}.push({ .field` knows it is
// initializing a PlacedNode.
fn TypeInfo TokenList.param_type_across(
	&self,
	TypeInfo recv,
	String name,
	sz arg_index,
	String uri,
	DocumentList* docs,
	String stdlib_path
)
{
	TypeInfo pt = self.param_decl_type(recv.name, name, arg_index);

	for (sz d = 0; d < docs.size && !pt.known(); d++)
	{
		TokenStream* doc_stream = docs.entries[d].get_tokens();
		pt                      = doc_stream.tokens.param_decl_type(recv.name, name, arg_index);
	}
	if (!pt.known())
	{
		String file_path = uri_to_path(uri);
		if (file_path.len == 0) return {};
		ParamTypeScan scan = { recv.name, name, arg_index, {} };
		scan_project_then_stdlib(file_path, stdlib_path, &scan);
		pt = scan.result;
	}
	if (!pt.known()) return {};
	return substitute_type_param(pt, recv);
}

struct ParamTypeScan (FileVisitor) @private
{
	String type_name;
	String name;
	sz arg_index;
	TypeInfo result;
}

fn bool ParamTypeScan.visit(&self, String path, String content, TokenStream* stream) @dynamic
{
	TypeInfo t = stream.tokens.param_decl_type(self.type_name, self.name, self.arg_index);
	if (!t.known()) return false;
	self.result = t.copy_temp();
	return true;
}

// The type an initializer list passed straight as a call argument initializes:
// `out.push({ .name = ... })` initializes whatever `push` takes. `lb` is the index of
// the initializer's `{`. Returns an unknown TypeInfo when `lb` is not a call argument
// or the callee cannot be resolved.
fn TypeInfo TokenList.call_argument_init_type(
	&self,
	sz lb,
	String uri,
	DocumentList* docs,
	String stdlib_path,
	int depth
)
{
	if (lb == 0 || depth > MAX_INFER_DEPTH) return {};

	sz arg_index;
	sz lparen = self.enclosing_call_lparen(lb - 1, &arg_index);
	if (lparen >= self.size || lparen == 0) return {};

	sz name_idx = lparen - 1;
	if (self.entries[name_idx].type == RBRACE)
	{
		// Generic call `name{Args}(...)` — step over the argument block.
		sz open = self.match_lbrace_back(name_idx);
		if (open >= self.size || open == 0) return {};
		name_idx = open - 1;
	}
	if (!is_ident(self.entries[name_idx].type)) return {};

	TypeInfo recv;
	if (name_idx >= 2 && self.entries[name_idx - 1].type == DOT)
	{
		recv = self.expr_type(name_idx - 2, uri, docs, stdlib_path, depth + 1);
		if (!recv.known()) return {};
		// Methods are declared on the underlying type as often as on the alias.
		TypeInfo base = self.canonical_type(recv.name, uri, docs, stdlib_path);
		if (base.name != recv.name && base.generic.len > 0 && recv.generic.len == 0) recv.generic = base.generic;
	}

	TypeInfo pt = self.param_type_across(recv, self.entries[name_idx].text, arg_index, uri, docs, stdlib_path);
	if (!pt.known() && recv.known())
	{
		TypeInfo base = self.canonical_type(recv.name, uri, docs, stdlib_path);
		if (base.name != recv.name)
		{
			base.generic = recv.generic.len > 0 ? recv.generic : base.generic;
			pt           = self.param_type_across(base, self.entries[name_idx].text, arg_index, uri, docs, stdlib_path);
		}
	}
	return pt;
}
