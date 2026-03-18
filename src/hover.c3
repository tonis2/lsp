module lsp;

import std::core::dstring;
import std::core::mem;
import c3::lexer;

fn void encode_hover(String content, usz offset, DString* out) {
	LineOffsets* lo = mem::new(LineOffsets);
	defer mem::free(lo);
	build_line_offsets(content, lo);

	Lexer lex;
	lex.init(content);

	while (true) {
		if (try tok = lex.next()) {
			usz tok_end = tok.offset + tok.len;
			if (tok.offset <= offset && offset < tok_end) {
				String desc = get_token_description(tok.type, tok.text);
				if (desc.len == 0) return;

				usz line = find_line(lo, tok.offset);
				usz start_char = tok.offset - lo.offsets[line];
				usz end_line = find_line(lo, tok_end > 0 ? tok_end - 1 : 0);
				usz end_char = tok_end - lo.offsets[end_line];

				out.append(`{"contents":{"kind":"markdown","value":"`);
				json_escape_into(out, desc);
				out.appendf(`"},"range":{"start":{"line":%d,"character":%d},"end":{"line":%d,"character":%d}}}`, line, start_char, end_line, end_char);
				return;
			}
			if (tok.offset > offset) return;
		} else {
			if (lex.at_end()) break;
			lex.pos++;
			lex.col++;
		}
	}
}

fn String get_token_description(TokenType t, String text) {
	switch (t) {
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
		case ISZ: return "`isz` — Signed size type";
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
