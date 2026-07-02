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
	// Reuses the standard "typeParameter" legend slot as a "declaration
	// accent" color: the fn/macro keyword plus a *primitive* return type
	// (void, int, bool, ...), so `fn void foo(...)` reads as one visual
	// unit distinct from other keywords. A class return type is left as
	// TYPE instead — it renders as a regular (green) type reference.
	DECL_ACCENT { 17 },
	SKIP        { -1 },
}

// Maps a TokenType to its semantic token category index.
// The LSP owns all syntax coloring: it emits a semantic token for every
// meaningful token so VS Code colors from the lexer (accurate) rather than
// relying on the TextMate grammar's regex approximation. Only operators,
// punctuation and structural tokens are left uncolored (SKIP).
fn SemanticCategory map_token_type(TokenType t)
{
	switch (t)
	{
		// Identifiers — kind is confirmed by the lexer.
		// IDENT may be refined to FUNCTION / NAMESPACE in the encoder
		// based on the following token ( "(" or "::" ).
		case TYPE_IDENT:
		case AT_TYPE_IDENT:
		case HASH_TYPE_IDENT:
		case CT_TYPE_IDENT:
			return TYPE;
		case CONST_IDENT:
		case AT_CONST_IDENT:
		case HASH_CONST_IDENT:
		case CT_CONST_IDENT:
			return ENUM_MEMBER;
		case IDENT:
		case HASH_IDENT:
			return VARIABLE;
		case CT_IDENT:
			return MACRO_CAT;

		// Decorators — @attributes
		case AT_INLINE:
		case AT_PURE:
		case AT_NOINLINE:
		case AT_IDENT:
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
		case BFLOAT16:
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

		// Keywords — declarations, control flow, storage, literals.
		case ALIAS:
		case ASM:
		case ASSERT:
		case ATTRDEF:
		case BITSTRUCT:
		case CONST:
		case CONSTDEF:
		case ENUM:
		case FAULTDEF:
		case FUNC:
		case IMPORT:
		case INTERFACE:
		case MACRO:
		case MODULE:
		case STRUCT:
		case UNION:
		case TYPEDEF:
		case BREAK:
		case CASE:
		case CATCH:
		case CONTINUE:
		case DEFAULT:
		case DEFER:
		case DO:
		case ELSE:
		case EXTERN:
		case FALSE:
		case FOR:
		case FOREACH:
		case FOREACH_R:
		case IF:
		case INLINE:
		case LENGTHOF:
		case NEXTCASE:
		case NULL:
		case RETURN:
		case STATIC:
		case SWITCH:
		case TLOCAL:
		case TRUE:
		case TRY:
		case VAR:
		case WHILE:
			return KEYWORD;

		// Compile-time ($) keywords and the $$ builtin intrinsic.
		case CT_ALIGNOF:
		case CT_ASSERT:
		case CT_ASSIGNABLE:
		case CT_CASE:
		case CT_DEFAULT:
		case CT_DEFINED:
		case CT_ECHO:
		case CT_ELSE:
		case CT_ENDFOR:
		case CT_ENDFOREACH:
		case CT_ENDIF:
		case CT_ENDSWITCH:
		case CT_ERROR:
		case CT_EVAL:
		case CT_EVALTYPE:
		case CT_EXEC:
		case CT_EXTNAMEOF:
		case CT_FEATURE:
		case CT_FOR:
		case CT_FOREACH:
		case CT_IF:
		case CT_IS_CONST:
		case CT_INCLUDE:
		case CT_KINDOF:
		case CT_NAMEOF:
		case CT_OFFSETOF:
		case CT_QNAMEOF:
		case CT_SIZEOF:
		case CT_STRINGIFY:
		case CT_SWITCH:
		case CT_TYPEFROM:
		case CT_TYPEOF:
		case CT_VAARG:
		case CT_VACONST:
		case CT_VACOUNT:
		case CT_VAEXPR:
		case CT_VAREF:
		case CT_VATYPE:
		case CT_VASPLAT:
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
		case BFLOAT16:
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
		case BFLOAT16:
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
		case BFLOAT16: return "`bfloat16` — 16-bit brain floating point";
		case FLOAT128: return "`float128` — 128-bit floating point";
		case IPTR: return "`iptr` — Signed pointer-sized integer";
		case UPTR: return "`uptr` — Unsigned pointer-sized integer";
		case ISZ: return "`sz` — Signed size type";
		case USZ: return "`usz` — Unsigned size type";
		case FAULT: return "`fault` — Fault type for error handling";
		case ANY: return "`any` — Type-erased interface type";
		case TYPEID: return "`typeid` — Runtime type identifier";

		// Compile-time intrinsics
		case CT_ALIGNOF: return "`$alignof` — Returns alignment of a type";
		case CT_ASSERT: return "`$assert` — Compile-time assertion";
		case CT_ASSIGNABLE: return "`$assignable` — Checks if a value is assignable";
		case CT_CASE: return "`$case` — Compile-time case";
		case CT_DEFAULT: return "`$default` — Compile-time default case";
		case CT_DEFINED: return "`$defined` — Checks if an identifier is defined";
		case CT_ECHO: return "`$echo` — Compile-time message output";
		case CT_ELSE: return "`$else` — Compile-time else branch";
		case CT_ENDFOR: return "`$endfor` — Ends compile-time for";
		case CT_ENDFOREACH: return "`$endforeach` — Ends compile-time foreach";
		case CT_ENDIF: return "`$endif` — Ends compile-time if";
		case CT_ENDSWITCH: return "`$endswitch` — Ends compile-time switch";
		case CT_ERROR: return "`$error` — Emits a compile-time error";
		case CT_EVAL: return "`$eval` — Compile-time expression evaluation";
		case CT_EVALTYPE: return "`$evaltype` — Evaluates to a type at compile time";
		case CT_EXEC: return "`$exec` — Executes a compile-time command";
		case CT_EXTNAMEOF: return "`$extnameof` — External name of a symbol";
		case CT_FEATURE: return "`$feature` — Checks for a compile-time feature";
		case CT_FOR: return "`$for` — Compile-time for loop";
		case CT_FOREACH: return "`$foreach` — Compile-time foreach loop";
		case CT_IF: return "`$if` — Compile-time conditional";
		case CT_IS_CONST: return "`$is_const` — Checks if expression is constant";
		case CT_INCLUDE: return "`$include` — Includes a file at compile time";
		case CT_KINDOF: return "`$kindof` — Returns the kind of a type";
		case CT_NAMEOF: return "`$nameof` — Returns the name of a symbol";
		case CT_OFFSETOF: return "`$offsetof` — Returns field offset in bytes";
		case CT_QNAMEOF: return "`$qnameof` — Returns qualified name of a symbol";
		case CT_SIZEOF: return "`$sizeof` — Returns size of a type in bytes";
		case CT_STRINGIFY: return "`$stringify` — Converts expression to string";
		case CT_SWITCH: return "`$switch` — Compile-time switch";
		case CT_TYPEFROM: return "`$typefrom` — Creates type from typeid";
		case CT_TYPEOF: return "`$typeof` — Returns the type of an expression";
		case CT_VAARG: return "`$vaarg` — Accesses variadic argument";
		case CT_VACONST: return "`$vaconst` — Variadic constant access";
		case CT_VACOUNT: return "`$vacount` — Returns number of variadic arguments";
		case CT_VAEXPR: return "`$vaexpr` — Variadic expression access";
		case CT_VAREF: return "`$varef` — Variadic reference access";
		case CT_VATYPE: return "`$vatype` — Variadic type access";
		case CT_VASPLAT: return "`$vasplat` — Splats variadic arguments";
		case BUILTIN: return "`$$` — Builtin intrinsic access";

		// Identifier types
		case TYPE_IDENT:
		case AT_TYPE_IDENT:
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
