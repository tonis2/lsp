module lsp;

import std::core::dstring;
import std::collections::list;
import std::collections::map;
import c3::lexer;

// References and rename for members — fields, methods, enum members and interface
// methods. A member is the pair (declaring type, name): `c.getName()` on a `Comp` that
// embeds `inline GameObject obj;` and `fn String GameObject.getName` are the same
// member, while `Other.getName` is not. Every candidate occurrence is resolved to its
// declaring type with member_declarer and kept when that matches the target's.
//
// Uses are searched in the current file, the open documents and the project. The
// stdlib is only searched for the declaration of a member it owns: nothing there can
// use a project type, and resolving every `.len` in it would be far too slow.

// The member under the cursor: the type declaring it and its name.
struct MemberTarget
{
	String owner;
	String name;
	TokenType type;
}

// The struct, union or bitstruct whose body declares the field named at `idx`, or ""
// when `idx` is not a field declaration. Anonymous nested structs inline their fields
// into the parent, which @each_struct_member already accounts for.
fn String TokenList.struct_member_owner(&self, sz idx)
{
	if (self.entries[idx].type != IDENT) return "";
	for (sz i = 0; i + 1 < self.size && i < idx; i++)
	{
		TokenType kw = self.entries[i].type;
		if (kw != STRUCT && kw != BITSTRUCT && kw != UNION) continue;
		if (self.entries[i + 1].type != TYPE_IDENT) continue;
		String name = self.entries[i + 1].text;
		self.@each_struct_member(name, null; sz j)
		{
			if (j == idx) return name;
		};
	}
	return "";
}

// The enum/constdef/constset whose body declares the member at `idx`, or the interface
// whose body declares the method at `idx`; "" otherwise.
fn String TokenList.body_member_owner(&self, sz idx)
{
	Token tok = self.entries[idx];
	for (sz i = 0; i + 1 < self.size && i < idx; i++)
	{
		TokenType kw = self.entries[i].type;
		if (self.entries[i + 1].type != TYPE_IDENT) continue;
		String name = self.entries[i + 1].text;
		if (kw == INTERFACE && tok.type == IDENT)
		{
			self.@each_interface_method(name; sz j)
			{
				if (j == idx) return name;
			};
		}
		else if ((kw == ENUM || kw == CONSTSET || kw == CONSTDEF) && tok.type == CONST_IDENT)
		{
			if (try at = self.find_enum_or_constdef_member(tok.text, name))
			{
				if (at == idx) return name;
			}
		}
	}
	return "";
}

// Whether the DOT-preceded name at `idx` is a method declaration `fn T Type.name(`
// rather than a use.
fn bool TokenList.is_method_decl_name(&self, sz idx)
{
	if (idx < 3 || self.entries[idx - 2].type != TYPE_IDENT) return false;
	if (idx + 1 >= self.size || self.entries[idx + 1].type != LPAREN) return false;
	for (sz k = idx - 2; k > 0; k--)
	{
		TokenType t = self.entries[k - 1].type;
		if (t == FUNC || t == MACRO) return true;
		if (t == EOS || t == LBRACE || t == RBRACE || t == EQ || t == LPAREN) return false;
	}
	return false;
}

// The type a member access at `idx` is reached through, before normalizing it to the
// declaring type: the receiver of `x.name` / `Type.name`, or the initializer's type for
// a designator `{ .name = ... }`.
fn String TokenList.member_access_type(&self, sz idx, String uri, DocumentList* docs, String stdlib_path)
{
	if (idx < 2 || self.entries[idx - 1].type != DOT) return "";
	TokenType before = self.entries[idx - 2].type;
	if (before == LBRACE || before == COMMA)
	{
		String init = self.resolve_initializer_type(idx, uri, docs, null, 0, stdlib_path);
		if (init.len > 0) return init;
	}
	return self.member_owner_type(idx, uri, docs, stdlib_path);
}

// The member at `idx`, when it is one: an access, a designator, a method declaration,
// a field declaration, an enum member or an interface method.
fn MemberTarget? TokenList.member_target(&self, sz idx, String uri, DocumentList* docs, String stdlib_path)
{
	Token tok = self.entries[idx];
	if (!is_ident(tok.type) && tok.type != CONST_IDENT) return TOKEN_NOT_FOUND~;

	String raw;
	if (idx > 0 && self.entries[idx - 1].type == DOT)
	{
		raw = self.member_access_type(idx, uri, docs, stdlib_path);
	}
	else
	{
		raw = self.struct_member_owner(idx);
		if (raw.len == 0) raw = self.body_member_owner(idx);
	}
	if (raw.len == 0) return TOKEN_NOT_FOUND~;

	TypeInfo owner = self.member_declarer({ .name = raw }, tok.text, uri, docs, stdlib_path);
	return { .owner = owner.known() ? owner.name.tcopy() : raw.tcopy(), .name = tok.text, .type = tok.type };
}

// What to collect and where it goes.
struct MemberQuery
{
	MemberTarget target;
	String owner_module;   // the module declaring the owner type ("" = unknown)
	String origin_uri;
	DocumentList* docs;
	String stdlib_path;
	bool include_decl;
	bool decls_only;       // the stdlib pass: only the declaration is looked for
	bool decl_found;
	HashMap{String, String} memo; // access type -> declaring type
	// Output: Location array for references, or URI-keyed TextEdit arrays for rename.
	DString* out;
	bool* first;
	String new_name;       // non-empty for rename
}

fn void MemberQuery.init(&self, TokenList* toks, MemberTarget target, String uri, DocumentList* docs, String stdlib_path, DString* out, bool* first)
{
	*self = { .target = target, .origin_uri = uri, .docs = docs, .stdlib_path = stdlib_path, .out = out, .first = first };
	self.memo.tinit();
	// A file that cannot see the owner's module cannot use its members — which skips
	// most library code without resolving a single receiver in it.
	Token owner_tok = { .type = TYPE_IDENT, .text = target.owner };
	self.owner_module = find_symbol_module(toks, owner_tok, uri, docs, stdlib_path).tcopy();
}

// The declaring type of a member reached through `access_type`, memoized for the
// request (the same receiver type recurs on every line of a file).
fn String MemberQuery.declarer_of(&self, TokenList* toks, String access_type, String uri)
{
	if (try hit = self.memo.get(access_type)) return hit;
	TypeInfo owner = toks.member_declarer({ .name = access_type }, self.target.name, uri, self.docs, self.stdlib_path);
	String result = owner.known() ? owner.name.tcopy() : "";
	self.memo.set(access_type.tcopy(), result);
	return result;
}

// Collect this file's occurrences of the target member into `hits`. A declaration is
// recognized by its shape — `fn T Owner.name(`, a field of `struct Owner`, a member of
// `enum Owner` or a method of `interface Owner` — and needs no receiver resolution.
fn void MemberQuery.collect_in(&self, TokenList* toks, String uri, List{Token}* hits)
{
	MemberTarget t = self.target;
	for (sz i = 0; i < toks.size; i++)
	{
		Token tok = toks.entries[i];
		if (tok.type != t.type || tok.text != t.name) continue;

		bool dotted = i > 0 && toks.entries[i - 1].type == DOT;
		bool is_decl;
		bool hit;
		if (dotted && toks.is_method_decl_name(i))
		{
			is_decl = true;
			hit = toks.entries[i - 2].text == t.owner;
		}
		else if (dotted)
		{
			if (self.decls_only) continue;
			String access = toks.member_access_type(i, uri, self.docs, self.stdlib_path);
			if (access.len == 0) continue; // unresolvable receiver: leave it out
			hit = access == t.owner || self.declarer_of(toks, access, uri) == t.owner;
		}
		else
		{
			String owner = toks.struct_member_owner(i);
			if (owner.len == 0) owner = toks.body_member_owner(i);
			if (owner.len > 0)
			{
				is_decl = true;
				hit = owner == t.owner;
			}
			else if (!self.decls_only && t.type == CONST_IDENT)
			{
				// An enum member written bare (`case RED:`, `Color c = RED;`).
				hit = true;
			}
		}
		if (!hit) continue;
		if (is_decl) self.decl_found = true;
		if (is_decl && !self.include_decl) continue;
		hits.push(tok);
	}
}

// Collect `toks`' occurrences and write them out in the requested form.
fn void MemberQuery.emit_file(&self, TokenList* toks, String uri, String content)
{
	if (!content.contains(self.target.name)) return;
	if (!file_can_see(toks, self.owner_module)) return;
	List{Token} hits;
	hits.tinit();
	self.collect_in(toks, uri, &hits);
	if (hits.len() == 0) return;

	LineOffsets lo;
	lo.init(mem);
	defer lo.free();
	lo.build(content);
	if (self.new_name.len > 0)
	{
		emit_rename_edits(uri, &lo, hits.array_view(), self.new_name, self.out, self.first);
		return;
	}
	foreach (tok : hits) append_ref_location(uri, tok, &lo, self.out, self.first);
}

// Every occurrence of the target: the current file, the open documents, the project,
// and — for a member the project does not declare — its declaration in the stdlib.
fn void MemberQuery.run(&self, TokenList* toks, String content)
{
	self.emit_file(toks, self.origin_uri, content);
	for (sz d = 0; d < self.docs.size; d++)
	{
		if (self.docs.entries[d].uri == self.origin_uri) continue;
		self.emit_file(&self.docs.entries[d].get_tokens().tokens, self.docs.entries[d].uri, self.docs.entries[d].content);
	}

	String file_path = uri_to_path(self.origin_uri);
	if (file_path.len == 0) return;
	MemberRefsScan scan = { self };
	scan_project_dirs(file_path, &scan);

	if (self.decl_found || !self.include_decl || self.new_name.len > 0 || self.stdlib_path.len == 0) return;
	self.decls_only = true;
	scan_dir(self.stdlib_path, &scan);
}

struct MemberRefsScan (FileVisitor) @private
{
	MemberQuery* query;
}

fn bool MemberRefsScan.visit(&self, String path, String content, TokenStream* stream) @dynamic
{
	MemberQuery* q = self.query;
	if (already_collected(path, q.origin_uri, q.docs)) return false;
	DString uri = dstring::temp();
	append_file_uri(&uri, path);
	q.emit_file(&stream.tokens, uri.str_view(), content);
	// The stdlib pass stops at the declaration; the project pass visits every file.
	return q.decls_only && q.decl_found;
}

// Whether the project (this file, the open documents or the project files) declares
// `member` on `owner`. A member declared only in the stdlib must not be renamed.
fn bool member_declared_in_project(TokenList* toks, String owner, String member, String uri, DocumentList* docs) @private
{
	if (toks.declares_member(owner, member, false)) return true;
	for (sz d = 0; d < docs.size; d++)
	{
		if (docs.entries[d].get_tokens().tokens.declares_member(owner, member, false)) return true;
	}
	String file_path = uri_to_path(uri);
	if (file_path.len == 0) return false;
	DeclaresMemberScan scan = { owner, member, false };
	return scan_project_dirs(file_path, &scan);
}
