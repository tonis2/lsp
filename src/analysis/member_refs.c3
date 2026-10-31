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

// The receiver type of the method declaration `fn T Type.name(` whose name is at
// `idx`, or "" when `idx` is a use rather than a declaration. A method on a generic
// instance, `fn void HashMap{String, String}.release(`, belongs to `HashMap`.
fn String TokenList.method_decl_owner(&self, sz idx)
{
	if (idx < 3 || self.entries[idx - 1].type != DOT) return "";
	if (idx + 1 >= self.size || self.entries[idx + 1].type != LPAREN) return "";
	sz recv = idx - 2;
	if (self.entries[recv].type == RBRACE)
	{
		sz open = self.match_lbrace_back(recv);
		if (open >= self.size || open == 0) return "";
		recv = open - 1;
	}
	if (recv == 0 || self.entries[recv].type != TYPE_IDENT) return "";
	for (sz k = recv; k > 0; k--)
	{
		TokenType t = self.entries[k - 1].type;
		if (t == FUNC || t == MACRO) return self.entries[recv].text;
		if (t == EOS || t == LBRACE || t == RBRACE || t == EQ || t == LPAREN) return "";
	}
	return "";
}

// Whether the DOT-preceded name at `idx` is a method declaration `fn T Type.name(`
// rather than a use.
fn bool TokenList.is_method_decl_name(&self, sz idx) => self.method_decl_owner(idx).len > 0;

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

// Whether the CONST_IDENT at `idx` is an enum member whose enum is left to inference:
// written bare (`case RED:`) or with a dot that follows nothing (`c = .RED`).
fn bool TokenList.is_inferred_member(&self, sz idx)
{
	if (self.entries[idx].type != CONST_IDENT) return false;
	if (idx == 0 || self.entries[idx - 1].type != DOT) return true;
	return idx < 2 || !can_end_expression(self.entries[idx - 2].type);
}

// The member at `idx`, when it is one: an access, a designator, a method declaration,
// a field declaration, an enum member or an interface method. An access whose
// receiver cannot be typed still resolves when only one type declares a member of
// that name (`name_fallback`).
fn MemberTarget? TokenList.member_target(&self, sz idx, String uri, DocumentList* docs, String stdlib_path, bool name_fallback = true)
{
	Token tok = self.entries[idx];
	if (!is_ident(tok.type) && tok.type != CONST_IDENT) return TOKEN_NOT_FOUND~;

	bool dotted = idx > 0 && self.entries[idx - 1].type == DOT;
	String raw;
	if (dotted && !self.is_inferred_member(idx))
	{
		raw = self.member_access_type(idx, uri, docs, stdlib_path);
		if (raw.len == 0 && name_fallback) raw = unique_member_owner(self, tok.text, uri, docs, stdlib_path);
	}
	else
	{
		raw = self.struct_member_owner(idx);
		if (raw.len == 0) raw = self.body_member_owner(idx);
		if (raw.len == 0 && self.is_inferred_member(idx))
		{
			// An enum member use. Unlike a field, a bare name may just as well be a
			// plain constant, so it only counts when its enum declares it.
			TypeInfo expected = self.expected_type_at(dotted ? idx - 1 : idx, uri, docs, stdlib_path);
			TypeInfo owner = self.member_declarer(expected, tok.text, uri, docs, stdlib_path);
			if (owner.known()) return { .owner = owner.name.tcopy(), .name = tok.text, .type = tok.type };
			// `.RED` is never a plain constant, so the name alone may still decide it.
			if (dotted && name_fallback) raw = unique_member_owner(self, tok.text, uri, docs, stdlib_path);
		}
	}
	if (raw.len == 0) return TOKEN_NOT_FOUND~;

	TypeInfo owner = self.member_declarer({ .name = raw }, tok.text, uri, docs, stdlib_path);
	return { .owner = owner.known() ? owner.name.tcopy() : raw.tcopy(), .name = tok.text, .type = tok.type };
}

// Members the compiler gives types and arrays, which no source declares: a receiver
// that cannot be typed says nothing about which type these belong to.
const String[*] BUILTIN_PROPERTIES = {
	"len", "ptr", "sizeof", "alignof", "nameof", "qnameof", "typeid", "kindof", "values",
	"names", "min", "max", "inner", "ordinal", "membersof", "methodsof",
};

fn bool is_builtin_property(String name) @private
{
	foreach (p : BUILTIN_PROPERTIES)
	{
		if (p == name) return true;
	}
	return false;
}

fn void add_owner(List{String}* owners, String owner) @private
{
	foreach (o : *owners)
	{
		if (o == owner) return;
	}
	owners.push(owner.tcopy());
}

// Visit each declaration of a member named `member` in this list with the type that
// owns it: a method, a struct/union/bitstruct field, an enum/constset/constdef member
// or an interface method. One walk over the type declarations, where asking
// struct_member_owner/body_member_owner of every same-named token costs a pass each.
macro TokenList.@each_member_decl(&self, String member; @body(sz idx, String owner))
{
	for (sz i = 0; i + 1 < self.size; i++)
	{
		Token tok = self.entries[i];
		if (tok.text == member)
		{
			String recv = self.method_decl_owner(i);
			if (recv.len > 0) @body(i, recv);
			continue;
		}
		if (self.entries[i + 1].type != TYPE_IDENT) continue;
		String name = self.entries[i + 1].text;
		switch (tok.type)
		{
			case STRUCT:
			case UNION:
			case BITSTRUCT:
				self.@each_struct_member(name, null; sz j)
				{
					if (self.entries[j].text == member) @body(j, name);
				};
			case ENUM:
			case CONSTSET:
			case CONSTDEF:
				if (try at = self.find_enum_or_constdef_member(member, name)) @body(at, name);
			case INTERFACE:
				self.@each_interface_method(name; sz j)
				{
					if (self.entries[j].text == member) @body(j, name);
				};
			default:
				break;
		}
	}
}

// Add to `owners` each type this list declares a member named `member` on. Stops once
// two distinct owners are known — more cannot make it unique again.
fn void TokenList.add_member_owners(&self, String member, List{String}* owners)
{
	bool mentioned;
	foreach (tok : self)
	{
		if (tok.text == member)
		{
			mentioned = true;
			break;
		}
	}
	if (!mentioned) return;

	self.@each_member_decl(member; sz idx, String owner)
	{
		add_owner(owners, owner);
		if (owners.len() >= 2) return;
	};
}

// The one type that declares a member named `member` in the current file, the open
// documents, the project or the stdlib — "" when none or several do.
fn String unique_member_owner(TokenList* toks, String member, String uri, DocumentList* docs, String stdlib_path)
{
	if (is_builtin_property(member)) return "";
	List{String} owners;
	owners.tinit();
	toks.add_member_owners(member, &owners);
	for (sz d = 0; d < docs.size && owners.len() < 2; d++)
	{
		if (docs.entries[d].uri == uri) continue;
		docs.entries[d].get_tokens().tokens.add_member_owners(member, &owners);
	}
	String file_path = uri_to_path(uri);
	if (owners.len() < 2 && file_path.len > 0)
	{
		MemberOwnersScan scan = { member, &owners, uri, docs };
		scan_project_then_stdlib(file_path, stdlib_path, &scan);
	}
	return owners.len() == 1 ? owners[0] : "";
}

struct MemberOwnersScan (FileVisitor) @private
{
	String member;
	List{String}* owners;
	String origin_uri;
	DocumentList* docs;
}

fn bool MemberOwnersScan.visit(&self, String path, String content, TokenStream* stream) @dynamic
{
	if (already_collected(path, self.origin_uri, self.docs)) return false;
	stream.tokens.add_member_owners(self.member, self.owners);
	return self.owners.len() >= 2;
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
	HashMap{String, bool} memo; // access type -> reaches the target
	HashMap{String, String} receivers; // receiver chain (per binding) -> access type, one file at a time
	TokenList* receivers_of;
	TokenList* origin_toks;
	bool no_name_fallback; // highlights: never scan the project to decide an untyped access
	bool unique_checked;
	bool unique;           // only the target's owner declares a member of its name
	// Output: Location array for references, or URI-keyed TextEdit arrays for rename.
	DString* out;
	bool* first;
	String new_name;       // non-empty for rename
}

fn void MemberQuery.init(&self, TokenList* toks, MemberTarget target, String uri, DocumentList* docs, String stdlib_path, DString* out, bool* first)
{
	*self = { .target = target, .origin_uri = uri, .docs = docs, .stdlib_path = stdlib_path, .out = out, .first = first, .origin_toks = toks };
	self.memo.tinit();
	self.receivers.tinit();
	// A file that cannot see the owner's module cannot use its members — which skips
	// most library code without resolving a single receiver in it.
	Token owner_tok = { .type = TYPE_IDENT, .text = target.owner };
	self.owner_module = find_symbol_module(toks, owner_tok, uri, docs, stdlib_path).tcopy();
}

// Whether the member reached through `access_type` is the target, memoized for the
// request (the same receiver type recurs on every line of a file). The declarer is
// always one of the types `access_type` takes members from, and finding those stops at
// each one's declaration — so a list without the target's owner settles it without
// the member search, which visits every file when the member is not declared at all.
fn bool MemberQuery.reaches_target(&self, TokenList* toks, String access_type, String uri)
{
	if (access_type == self.target.owner) return true;
	if (try hit = self.memo.get(access_type)) return hit;
	MemberSource[MAX_MEMBER_SOURCES] srcs;
	sz n = toks.member_sources({ .name = access_type }, uri, self.docs, self.stdlib_path, &srcs);
	bool result;
	for (sz k = 0; k < n && !result; k++) result = srcs[k].type.name == self.target.owner;
	if (result)
	{
		result = toks.member_declarer({ .name = access_type }, self.target.name, uri, self.docs, self.stdlib_path).name == self.target.owner;
	}
	self.memo.set(access_type.tcopy(), result);
	return result;
}

// member_access_type, memoized per receiver: a function touches `accessor.count` or
// `self.entries[i].type` many times over, and typing the receiver dominates the
// request. A receiver made of names, dots and indexing is keyed by its text — the index
// expressions left out, as they do not change the type — and by the declaration its
// first name resolves to, so a same-named local in a sibling block is typed separately.
fn String MemberQuery.access_type_of(&self, TokenList* toks, sz idx, String uri)
{
	if (self.receivers_of != toks)
	{
		self.receivers.clear();
		self.receivers_of = toks;
	}
	sz head;
	if (!toks.receiver_chain_start(idx - 2, &head)) return toks.member_access_type(idx, uri, self.docs, self.stdlib_path);

	DString key = dstring::temp();
	LocalScope scope;
	if (try decl = toks.local_target(head, &scope))
	{
		key.appendf("%d:", decl);
	}
	else
	{
		key.append("-:");
	}
	for (sz k = head; k + 1 < idx; k++)
	{
		if (toks.entries[k].type != LBRACKET)
		{
			key.append(toks.entries[k].text);
			continue;
		}
		// `xs[i]` and `xs[i..j]` differ in type; `xs[i]` and `xs[k]` do not.
		sz close = toks.match_rbracket(k);
		bool range = toks.brackets_hold_range(k, close);
		key.append(range ? "[..]" : "[]");
		k = close;
	}
	if (try hit = self.receivers.get(key.str_view())) return hit;
	String access = toks.member_access_type(idx, uri, self.docs, self.stdlib_path).tcopy();
	self.receivers.set(key.str_view(), access);
	return access;
}

// Walk back from `last`, the receiver's final token, over `name`, `.name` and `[...]`
// to the receiver's first name. False for any other shape (a call, a cast, a
// `mod::` path), which is typed afresh every time.
fn bool TokenList.receiver_chain_start(&self, sz last, sz* head)
{
	sz k = last;
	while (true)
	{
		TokenType t = self.entries[k].type;
		if (t == RBRACKET)
		{
			sz open = self.match_lbracket_back(k);
			if (open >= self.size || open == 0) return false;
			k = open - 1;
			continue;
		}
		if (!is_ident(t)) return false;
		if (k >= 2 && self.entries[k - 1].type == DOT)
		{
			k -= 2;
			continue;
		}
		if (k > 0 && (self.entries[k - 1].type == SCOPE || self.entries[k - 1].type == DOT)) return false;
		*head = k;
		return true;
	}
}

// Whether the target is the only member of its name anywhere, so a use whose type
// cannot be worked out is still known to be it. Decided once per request, on the first
// such use.
fn bool MemberQuery.name_is_unique(&self)
{
	if (self.no_name_fallback) return false;
	if (!self.unique_checked)
	{
		self.unique_checked = true;
		String only = unique_member_owner(self.origin_toks, self.target.name, self.origin_uri, self.docs, self.stdlib_path);
		self.unique = only == self.target.owner;
	}
	return self.unique;
}

// Whether the enum member use at `idx` — bare `RED` or inferred `.RED` — belongs to
// the target's enum, judged by the type its position expects. Where nothing says, a
// bare use keeps matching by name; `.RED` was never matched before, so it only does
// when the name is unique.
fn bool MemberQuery.enum_use_matches(&self, TokenList* toks, sz idx, String uri)
{
	bool dotted = idx > 0 && toks.entries[idx - 1].type == DOT;
	TypeInfo expected = toks.expected_type_at(dotted ? idx - 1 : idx, uri, self.docs, self.stdlib_path);
	if (expected.known()) return self.reaches_target(toks, expected.name, uri);
	return !dotted || self.name_is_unique();
}

// Collect this file's occurrences of the target member into `hits`. A declaration is
// recognized by its shape — `fn T Owner.name(`, a field of `struct Owner`, a member of
// `enum Owner` or a method of `interface Owner` — and needs no receiver resolution.
fn void MemberQuery.collect_in(&self, TokenList* toks, String uri, List{Token}* hits)
{
	MemberTarget t = self.target;
	HashMap{sz, String} decls;
	decls.tinit();
	toks.@each_member_decl(t.name; sz idx, String owner)
	{
		decls.set(idx, owner);
	};
	for (sz i = 0; i < toks.size; i++)
	{
		Token tok = toks.entries[i];
		if (tok.type != t.type || tok.text != t.name) continue;

		bool dotted = i > 0 && toks.entries[i - 1].type == DOT;
		bool is_decl;
		bool hit;
		String decl_owner = dotted ? toks.method_decl_owner(i) : "";
		if (decl_owner.len > 0)
		{
			is_decl = true;
			hit = decl_owner == t.owner;
		}
		else if (dotted && !toks.is_inferred_member(i))
		{
			if (self.decls_only) continue;
			String access = self.access_type_of(toks, i, uri);
			// A receiver that cannot be typed only counts when the name decides it.
			hit = access.len == 0
				? !is_builtin_property(t.name) && self.name_is_unique()
				: self.reaches_target(toks, access, uri);
		}
		else
		{
			String owner = dotted ? "" : decls.get(i) ?? "";
			if (owner.len > 0)
			{
				is_decl = true;
				hit = owner == t.owner;
			}
			else if (!self.decls_only && t.type == CONST_IDENT)
			{
				// An enum member whose enum is inferred (`case RED:`, `c = .RED`).
				hit = self.enum_use_matches(toks, i, uri);
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
