module lsp;

import std::core::dstring;
import std::collections::list;
import c3::lexer;

alias TokenList = List{Token};

// Semantic token categories for LSP semantic highlighting.
// The index value corresponds to the position in TOKEN_TYPES_LEGEND.
enum SemanticCategory : char (int index)
{
	NAMESPACE   { 0 },
	TYPE        { 1 },
	ENUM_CAT    { 2 },
	STRUCT_CAT  { 3 },
	VARIABLE    { 4 },
	FUNCTION    { 5 },
	MACRO_CAT   { 6 },
	KEYWORD     { 7 },
	DECORATOR   { 8 },
	COMMENT     { 9 },
	STRING_CAT  { 10 },
	NUMBER      { 11 },
	OPERATOR    { 12 },
	ENUM_MEMBER { 13 },
	CLASS       { 14 },
	PARAMETER   { 15 },
	PROPERTY    { 16 },
	SKIP        { -1 },
}

// Semantic token modifiers, as bits in the order of TOKEN_MODIFIERS_LEGEND.
const int MOD_DECLARATION     = 1 << 0; // the name being declared
const int MOD_READONLY        = 1 << 1; // constants and enum members
const int MOD_DEFAULT_LIBRARY = 1 << 2; // builtin types

// Maps a TokenType to its semantic token category index.
// Names, types, literals, comments and control-flow keywords get a semantic token,
// colored from the lexer rather than the TextMate grammar's regex approximation.
// Operators and punctuation are left uncolored (SKIP), and so are the literal and
// declaration keywords (`true`, `null`, `struct`, `fn`, `static`, ...): the standard
// legend has no category for them, and "keyword" would paint them all in the
// control-flow color, so the grammar's constant/storage colors are kept instead.
fn SemanticCategory map_token_type(TokenType t)
{
	switch (t)
	{
		// Identifiers — kind is confirmed by the lexer.
		// IDENT may be refined to FUNCTION / NAMESPACE in the encoder
		// based on the following token ( "(" or "::" ).
		case TYPE_IDENT:
		case HASH_TYPE_IDENT:
		case CT_TYPE_IDENT:
			return TYPE;
		case CONST_IDENT:
		case AT_CONST_IDENT:
		case HASH_CONST_IDENT:
		case CT_CONST_IDENT:
			return ENUM_MEMBER;
		case IDENT:
		case CT_IDENT:
			return VARIABLE;
		case HASH_IDENT:
			return PARAMETER; // only macro parameters are named #name

		// Decorators — @attributes
		case AT_INLINE:
		case AT_PURE:
		case AT_NOINLINE:
		case AT_IDENT:
		case AT_TYPE_IDENT: // user-defined attributes: attrdef/attrmacro @Name
			return DECORATOR;

		// Builtin types — colored like user types.
		case VOID:
		case BOOL:
		case CHAR:
		case ICHAR:
		case SHORT:
		case USHORT:
		case INT:
		case UINT:
		case LONG:
		case ULONG:
		case INT128:
		case UINT128:
		case FLOAT:
		case DOUBLE:
		case FLOAT16:
		case BFLOAT:
		case UNTYPEDLIST:
		case FLOAT128:
		case IPTR:
		case UPTR:
		case ISZ:
		case USZ:
		case FAULT:
		case ANY:
		case TYPEID:
			return TYPE;

		// Comments and contracts
		case LINE_COMMENT:
		case BLOCK_COMMENT:
		case CONTRACT:
			return COMMENT;

		// String / char / bytes literals
		case STRING:
		case CHAR_LITERAL:
		case BYTES:
			return STRING_CAT;

		// Numeric literals
		case INTEGER:
		case REAL:
			return NUMBER;

		// Control-flow and statement keywords.
		case ASM:
		case ASSERT:
		case BREAK:
		case CASE:
		case CATCH:
		case CONTINUE:
		case DEFAULT:
		case DEFER:
		case DO:
		case ELSE:
		case FOR:
		case FOREACH:
		case FOREACH_R:
		case IF:
		case LENGTHOF:
		case NEXTCASE:
		case RETURN:
		case SWITCH:
		case TRY:
		case WHILE:
			return KEYWORD;

		// Compile-time ($) keywords and the $$ builtin intrinsic.
		case CT_ASSERT:
		case CT_CASE:
		case CT_DEFAULT:
		case CT_DEFINED:
		case CT_ECHO:
		case CT_ELSE:
		case CT_EMBED:
		case CT_ENDFOR:
		case CT_ENDFOREACH:
		case CT_ENDIF:
		case CT_ENDSWITCH:
		case CT_ERROR:
		case CT_EVAL:
		case CT_EXEC:
		case CT_EXPAND:
		case CT_FEAT:
		case CT_FEATURE:
		case CT_FOR:
		case CT_FOREACH:
		case CT_IF:
		case CT_INCLUDE:
		case CT_REFLECT:
		case CT_STRINGIFY:
		case CT_SWITCH:
		case CT_TYPEFROM:
		case CT_TYPEOF:
		case CT_VAARG:
		case BUILTIN:
			return KEYWORD;

		// Operators, assignment, comparison, punctuation and structure
		// tokens stay uncolored.
		default:
			return SKIP;
	}
}

// Check if a character is a path separator (/ or \).
fn bool is_path_separator(char c)
{
	return c == '/' || c == '\\';
}

// Check if a string starts with a Windows drive letter pattern (e.g. "C:/" or "C:\").
fn bool is_windows_drive_path(String s)
{
	if (s.len < 3) return false;
	char c = s[0];
	if (!((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z'))) return false;
	return s[1] == ':' && is_path_separator(s[2]);
}

// Checks if a token is a base type or type identifier (used for variable declarations).
fn bool is_type_token(TokenType t)
{
	switch (t)
	{
		case VOID:
		case BOOL:
		case CHAR:
		case ICHAR:
		case SHORT:
		case USHORT:
		case INT:
		case UINT:
		case LONG:
		case ULONG:
		case INT128:
		case UINT128:
		case FLOAT:
		case DOUBLE:
		case FLOAT16:
		case BFLOAT:
		case UNTYPEDLIST:
		case FLOAT128:
		case IPTR:
		case UPTR:
		case ISZ:
		case USZ:
		case FAULT:
		case ANY:
		case TYPEID:
		case TYPE_IDENT:
		case VAR:
			return true;
		default:
			return false;
	}
}

// Checks if a token is a builtin primitive type (void, int, bool, ...), as
// opposed to a user-defined type name (TYPE_IDENT). Used to decide whether a
// function's return type gets the primitive declaration-accent color or is
// left as a regular (green) type reference.
fn bool is_builtin_type_token(TokenType t)
{
	switch (t)
	{
		case VOID:
		case BOOL:
		case CHAR:
		case ICHAR:
		case SHORT:
		case USHORT:
		case INT:
		case UINT:
		case LONG:
		case ULONG:
		case INT128:
		case UINT128:
		case FLOAT:
		case DOUBLE:
		case FLOAT16:
		case BFLOAT:
		case UNTYPEDLIST:
		case FLOAT128:
		case IPTR:
		case UPTR:
		case ISZ:
		case USZ:
		case FAULT:
		case ANY:
		case TYPEID:
			return true;
		default:
			return false;
	}
}

// Checks if a token introduces a type or constant declaration.
fn bool is_type_declaration_keyword(TokenType t)
{
	switch (t)
	{
		case STRUCT:
		case UNION:
		case BITSTRUCT:
		case ENUM:
		case CONSTSET:
		case FAULTDEF:
		case INTERFACE:
		case TYPEDEF:
		case CONSTDEF:
		case ALIAS:
			return true;
		default:
			return false;
	}
}

// Checks if a token is an identifier (IDENT or AT_IDENT for macro names like @foo).
fn bool is_ident(TokenType t)
{
	return t == IDENT || t == AT_IDENT;
}

// --- Balanced-brace / module-path helpers -----------------------------------
// C3 generics use braces at call/declaration sites (`Foo{int}`, `foo{Bar}(...)`,
// `fn List{int} get_list()`), so a `{` is not necessarily a function body. The
// scanners below let forward/backward walks skip a balanced `{...}` block instead
// of stopping at the first brace. Reused across completion/definition/signature/
// symbols to avoid the same depth-counting loop being copy-pasted everywhere.

// Given the index of an LBRACE token, returns the index of its matching RBRACE.
// Returns self.size if the braces are unbalanced (caller treats it as end-of-scan).
fn sz TokenList.match_rbrace(&self, sz lbrace_idx)
{
	sz depth = 0;
	for (sz j = lbrace_idx; j < self.size; j++)
	{
		TokenType t = self.entries[j].type;
		if (t == LBRACE)
		{
			depth++;
		}
		else if (t == RBRACE)
		{
			depth--;
			if (depth == 0) return j;
		}
	}
	return self.size;
}

// Given the index of an RBRACE token, returns the index of its matching LBRACE by
// scanning backward. Returns self.size if the braces are unbalanced.
fn sz TokenList.match_lbrace_back(&self, sz rbrace_idx)
{
	sz depth = 0;
	for (sz j = rbrace_idx; ; j--)
	{
		TokenType t = self.entries[j].type;
		if (t == RBRACE)
		{
			depth++;
		}
		else if (t == LBRACE)
		{
			depth--;
			if (depth == 0) return j;
		}
		if (j == 0) break;
	}
	return self.size;
}

// Given the index of an LBRACKET token, returns the index of its matching RBRACKET.
// Returns self.size if the brackets are unbalanced.
fn sz TokenList.match_rbracket(&self, sz lbracket_idx)
{
	sz depth = 0;
	for (sz j = lbracket_idx; j < self.size; j++)
	{
		TokenType t = self.entries[j].type;
		if (t == LBRACKET)
		{
			depth++;
		}
		else if (t == RBRACKET)
		{
			depth--;
			if (depth == 0) return j;
		}
	}
	return self.size;
}

// Given the index of an LPAREN token, returns the index of its matching RPAREN.
// Returns self.size if the parens are unbalanced.
fn sz TokenList.match_rparen(&self, sz lparen_idx)
{
	sz depth = 0;
	for (sz j = lparen_idx; j < self.size; j++)
	{
		TokenType t = self.entries[j].type;
		if (t == LPAREN)
		{
			depth++;
		}
		else if (t == RPAREN)
		{
			depth--;
			if (depth == 0) return j;
		}
	}
	return self.size;
}

// Given the index of an RBRACKET token, returns the index of its matching LBRACKET
// by scanning backward. Returns self.size if the brackets are unbalanced.
fn sz TokenList.match_lbracket_back(&self, sz rbracket_idx)
{
	sz depth = 0;
	for (sz j = rbracket_idx; ; j--)
	{
		TokenType t = self.entries[j].type;
		if (t == RBRACKET)
		{
			depth++;
		}
		else if (t == LBRACKET)
		{
			depth--;
			if (depth == 0) return j;
		}
		if (j == 0) break;
	}
	return self.size;
}

// Builds the "a::b::c" module path from the tokens following a MODULE keyword at
// mod_idx: accumulates ident/type/const segments, skips SCOPE (::), and stops at
// the first other token (e.g. EOS, or `<` of a generic module declaration).
fn String TokenList.module_path_at(&self, sz mod_idx)
{
	DString path = dstring::temp();
	bool first = true;
	for (sz j = mod_idx + 1; j < self.size; j++)
	{
		TokenType t = self.entries[j].type;
		// Plain IDENT only (not AT_IDENT): a module attribute such as
		// `module foo @private;` must terminate the path, not extend it.
		if (t == IDENT || t == TYPE_IDENT || t == CONST_IDENT)
		{
			if (!first) path.append("::");
			path.append(self.entries[j].text);
			first = false;
		}
		else if (t == SCOPE)
		{
			continue;
		}
		else
		{
			break;
		}
	}
	return path.str_view();
}

// Returns the module path of the declaration at decl_idx by scanning backward to
// the nearest preceding MODULE keyword (or "" if the declaration is module-less).
fn String TokenList.module_of_decl(&self, sz decl_idx)
{
	for (sz j = decl_idx; ; j--)
	{
		if (self.entries[j].type == MODULE) return self.module_path_at(j);
		if (j == 0) break;
	}
	return "";
}

// The `@feat(...)` conditions a declaration is compiled under, as written: those on the
// declaration itself (`fn void foo() @feat(POSIX)`, `alias WChar @feat(WIN32) = ...`)
// and those on the module section it sits in (`module libc @feat(LIBC);`), joined by
// a space. "" for a declaration that is always compiled. `name_idx` is the declared
// name. Nothing is evaluated: this is for telling platform variants apart.
fn String TokenList.decl_feat(&self, sz name_idx)
{
	String own = self.decl_own_feat(name_idx);
	for (sz m = name_idx; m > 0; m--)
	{
		if (self.entries[m - 1].type != MODULE) continue;
		return join_feat(own, self.module_feat(m - 1));
	}
	return own;
}

// The `@feat(...)` attributes on the declaration named at `name_idx` itself: from the
// name to its body, `=` or `;`, stepping over a parameter list whole.
fn String TokenList.decl_own_feat(&self, sz name_idx)
{
	DString feat = dstring::temp();
	for (sz j = name_idx + 1; j < self.size && j < name_idx + 256; j++)
	{
		TokenType t = self.entries[j].type;
		if (t == LBRACE || t == EOS || t == EQ || t == IMPLIES) break;
		if (t == LPAREN)
		{
			j = self.match_rparen(j);
			continue;
		}
		if (t == AT_IDENT && self.entries[j].text == "@feat") j = self.append_attr(j, &feat);
	}
	return feat.str_view();
}

// The `@feat(...)` attributes of the `module` line at `module_idx`.
fn String TokenList.module_feat(&self, sz module_idx)
{
	DString feat = dstring::temp();
	for (sz j = module_idx; j < self.size && self.entries[j].type != EOS; j++)
	{
		if (self.entries[j].type == AT_IDENT && self.entries[j].text == "@feat") j = self.append_attr(j, &feat);
	}
	return feat.str_view();
}

fn String join_feat(String a, String b)
{
	if (a.len == 0) return b;
	if (b.len == 0) return a;
	return string::tformat("%s %s", a, b);
}

// Append the attribute starting at `at_idx` (`@feat(POSIX, WIN32)`) to `out` as it is
// written, space-separated from what is already there. Returns the index of its last
// token.
fn sz TokenList.append_attr(&self, sz at_idx, DString* out)
{
	sz last = at_idx;
	if (at_idx + 1 < self.size && self.entries[at_idx + 1].type == LPAREN)
	{
		last = self.match_rparen(at_idx + 1);
		if (last >= self.size) last = self.size - 1;
	}
	Token first = self.entries[at_idx];
	Token end = self.entries[last];
	if (out.len() > 0) out.append_char(' ');
	// Both tokens slice the same text, so the span between them is the source as written.
	out.append(((String)first.text.ptr[:end.offset + end.len - first.offset]));
	return last;
}

// From decl_idx, find the first `{` and return the index of its matching `}`, so a
// loop iterating top-level declarations can skip a type body `{...}` (e.g. an
// interface's method declarations, which must not be scanned as module functions).
// Returns decl_idx unchanged when there is no body before the end of the declaration.
fn sz TokenList.skip_type_body(&self, sz decl_idx)
{
	for (sz j = decl_idx; j < self.size; j++)
	{
		if (self.entries[j].type == LBRACE) return self.match_rbrace(j);
		if (self.entries[j].type == EOS) return decl_idx;
	}
	return decl_idx;
}

// Returns a human-readable description for a token (used in hover).
fn String get_token_description(TokenType t, String text)
{
	switch (t)
	{
		// Keywords
		case ALIAS: return "`alias` — Defines a type alias";
		case ASM: return "`asm` — Inline assembly block";
		case ASSERT: return "`assert` — Runtime assertion";
		case ATTRDEF: return "`attrdef` — Defines a custom attribute";
		case BITSTRUCT: return "`bitstruct` — Bit-level struct definition";
		case BREAK: return "`break` — Exits the current loop or switch";
		case CASE: return "`case` — Branch in a switch statement";
		case CATCH: return "`catch` — Catches an optional fault value";
		case CONST: return "`const` — Compile-time constant declaration";
		case CONSTDEF: return "`constdef` — Defines a named constant";
		case CONSTSET: return "`constset` — Non-sequential enumeration type definition";
		case CONTINUE: return "`continue` — Skips to next loop iteration";
		case DEFAULT: return "`default` — Default branch in switch";
		case DEFER: return "`defer` — Defers statement execution to scope exit";
		case DO: return "`do` — Do-while loop";
		case ELSE: return "`else` — Alternative branch";
		case ENUM: return "`enum` — Enumeration type definition";
		case EXTERN: return "`extern` — External linkage declaration";
		case FALSE: return "`false` — Boolean false literal";
		case FAULTDEF: return "`faultdef` — Defines a fault type";
		case FOR: return "`for` — For loop";
		case FOREACH: return "`foreach` — Iterates over elements";
		case FOREACH_R: return "`foreach_r` — Reverse iteration";
		case FUNC: return "`fn` — Function declaration";
		case IF: return "`if` — Conditional branch";
		case IMPORT: return "`import` — Imports a module";
		case INLINE: return "`inline` — Hint to inline a function";
		case INTERFACE: return "`interface` — Interface definition";
		case LENGTHOF: return "`lengthof` — Returns the length of an array or container";
		case MACRO: return "`macro` — Macro definition";
		case MODULE: return "`module` — Module declaration";
		case NEXTCASE: return "`nextcase` — Falls through to next case";
		case NULL: return "`null` — Null pointer literal";
		case RETURN: return "`return` — Returns from function";
		case STATIC: return "`static` — Static storage or scope";
		case STRUCT: return "`struct` — Struct type definition";
		case SWITCH: return "`switch` — Multi-way branch";
		case TLOCAL: return "`tlocal` — Thread-local storage";
		case TRUE: return "`true` — Boolean true literal";
		case TRY: return "`try` — Unwraps an optional, returning on fault";
		case TYPEDEF: return "`typedef` — Defines a distinct type";
		case UNION: return "`union` — Union type definition";
		case VAR: return "`var` — Variable with inferred type";
		case WHILE: return "`while` — While loop";

		// Builtin types
		case VOID: return "`void` — No value type";
		case BOOL: return "`bool` — Boolean type (true/false)";
		case CHAR: return "`char` — 8-bit unsigned character";
		case ICHAR: return "`ichar` — 8-bit signed character";
		case SHORT: return "`short` — 16-bit signed integer";
		case USHORT: return "`ushort` — 16-bit unsigned integer";
		case INT: return "`int` — 32-bit signed integer";
		case UINT: return "`uint` — 32-bit unsigned integer";
		case LONG: return "`long` — 64-bit signed integer";
		case ULONG: return "`ulong` — 64-bit unsigned integer";
		case INT128: return "`int128` — 128-bit signed integer";
		case UINT128: return "`uint128` — 128-bit unsigned integer";
		case FLOAT: return "`float` — 32-bit floating point";
		case DOUBLE: return "`double` — 64-bit floating point";
		case FLOAT16: return "`float16` — 16-bit floating point";
		case BFLOAT: return "`bfloat` — 16-bit brain floating point";
		case UNTYPEDLIST: return "`untypedlist` — Type of an untyped initializer list";
		case FLOAT128: return "`float128` — 128-bit floating point";
		case IPTR: return "`iptr` — Signed pointer-sized integer";
		case UPTR: return "`uptr` — Unsigned pointer-sized integer";
		case ISZ: return "`sz` — Signed size type";
		case USZ: return "`usz` — Unsigned size type";
		case FAULT: return "`fault` — Fault type for error handling";
		case ANY: return "`any` — Type-erased interface type";
		case TYPEID: return "`typeid` — Runtime type identifier";

		// Compile-time intrinsics
		case CT_ASSERT: return "`$assert` — Compile-time assertion";
		case CT_CASE: return "`$case` — Compile-time case";
		case CT_DEFAULT: return "`$default` — Compile-time default case";
		case CT_DEFINED: return "`$defined` — Checks if an expression is defined";
		case CT_ECHO: return "`$echo` — Compile-time message output";
		case CT_ELSE: return "`$else` — Compile-time else branch";
		case CT_EMBED: return "`$embed` — Embeds a file's contents as a constant";
		case CT_ENDFOR: return "`$endfor` — Ends compile-time for";
		case CT_ENDFOREACH: return "`$endforeach` — Ends compile-time foreach";
		case CT_ENDIF: return "`$endif` — Ends compile-time if";
		case CT_ENDSWITCH: return "`$endswitch` — Ends compile-time switch";
		case CT_ERROR: return "`$error` — Emits a compile-time error";
		case CT_EVAL: return "`$eval` — Compile-time expression evaluation";
		case CT_EXEC: return "`$exec` — Executes a compile-time command";
		case CT_EXPAND: return "`$expand` — Expands a string into code";
		case CT_FEAT: return "`$feat` — Checks a feature-flag expression";
		case CT_FEATURE: return "`$feature` — Checks for a feature flag (deprecated: use `$feat`)";
		case CT_FOR: return "`$for` — Compile-time for loop";
		case CT_FOREACH: return "`$foreach` — Compile-time foreach loop";
		case CT_IF: return "`$if` — Compile-time conditional";
		case CT_INCLUDE: return "`$include` — Includes a file at compile time";
		case CT_REFLECT: return "`$reflect` — Compile-time reflection on a type or symbol";
		case CT_STRINGIFY: return "`$stringify` — Converts expression to string";
		case CT_SWITCH: return "`$switch` — Compile-time switch";
		case CT_TYPEFROM: return "`$Typefrom` — Creates a type from a typeid";
		case CT_TYPEOF: return "`$Typeof` — The type of an expression";
		case CT_VAARG: return "`$vaarg` — Accesses variadic arguments";
		case BUILTIN: return "`$$` — Builtin intrinsic access";

		// Identifier types
		case AT_TYPE_IDENT:
			DString d = dstring::temp();
			d.append("Attribute: `");
			d.append(text);
			d.append_char('`');
			return d.str_view();
		case TYPE_IDENT:
		case HASH_TYPE_IDENT:
		case CT_TYPE_IDENT:
			DString d = dstring::temp();
			d.append("Type: `");
			d.append(text);
			d.append_char('`');
			return d.str_view();
		case CONST_IDENT:
		case AT_CONST_IDENT:
		case HASH_CONST_IDENT:
		case CT_CONST_IDENT:
			DString d = dstring::temp();
			d.append("Constant: `");
			d.append(text);
			d.append_char('`');
			return d.str_view();
		case IDENT:
		case AT_IDENT:
		case HASH_IDENT:
		case CT_IDENT:
			DString d = dstring::temp();
			d.append("Identifier: `");
			d.append(text);
			d.append_char('`');
			return d.str_view();

		default:
			return "";
	}
}
