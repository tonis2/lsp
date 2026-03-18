module lsp;

import std::core::dstring;
import std::core::mem;
import c3::lexer;

const usz MAX_LINE_OFFSETS = 100000;

fn int map_token_type(TokenType t) {
	switch (t) {
		case MODULE: return 0;       // namespace
		case TYPE_IDENT:
		case AT_TYPE_IDENT:
		case HASH_TYPE_IDENT:
		case CT_TYPE_IDENT:
		case VOID: case BOOL: case CHAR: case ICHAR:
		case SHORT: case USHORT: case INT: case UINT:
		case LONG: case ULONG: case INT128: case UINT128:
		case FLOAT: case DOUBLE: case FLOAT16: case BFLOAT16: case FLOAT128:
		case IPTR: case UPTR: case ISZ: case USZ:
		case FAULT: case ANY: case TYPEID:
			return 1;                // type
		case ENUM: case FAULTDEF: case BITSTRUCT:
			return 2;                // enum
		case STRUCT: case UNION:
			return 3;                // struct
		case IDENT: case CONST_IDENT:
			return 4;                // variable
		case FUNC:
			return 5;                // function
		case MACRO:
		case BUILTIN:
		case CT_ALIGNOF: case CT_ASSERT: case CT_ASSIGNABLE:
		case CT_CASE: case CT_DEFAULT: case CT_DEFINED:
		case CT_ECHO: case CT_ELSE: case CT_ENDFOR:
		case CT_ENDFOREACH: case CT_ENDIF: case CT_ENDSWITCH:
		case CT_ERROR: case CT_EVAL: case CT_EVALTYPE:
		case CT_EXEC: case CT_EXTNAMEOF: case CT_FEATURE:
		case CT_FOR: case CT_FOREACH: case CT_IF:
		case CT_IS_CONST: case CT_INCLUDE: case CT_KINDOF:
		case CT_NAMEOF: case CT_OFFSETOF: case CT_QNAMEOF:
		case CT_SIZEOF: case CT_STRINGIFY: case CT_SWITCH:
		case CT_TYPEFROM: case CT_TYPEOF:
		case CT_VAARG: case CT_VACONST: case CT_VACOUNT:
		case CT_VAEXPR: case CT_VAREF: case CT_VATYPE: case CT_VASPLAT:
		case CT_IDENT: case CT_CONST_IDENT:
			return 6;                // macro
		case ALIAS: case ASM: case ASSERT: case ATTRDEF:
		case CONST: case CONSTDEF:
		case IMPORT: case INTERFACE: case TYPEDEF:
		case BREAK: case CASE: case CATCH: case CONTINUE:
		case DEFAULT: case DEFER: case DO: case ELSE:
		case EXTERN: case FALSE: case FOR: case FOREACH: case FOREACH_R:
		case IF: case INLINE: case LENGTHOF: case NEXTCASE:
		case NULL: case RETURN: case STATIC: case SWITCH:
		case TLOCAL: case TRUE: case TRY: case VAR: case WHILE:
			return 7;                // keyword
		case AT_INLINE: case AT_PURE: case AT_NOINLINE:
		case AT_IDENT: case AT_CONST_IDENT:
		case HASH_IDENT: case HASH_CONST_IDENT:
			return 8;                // decorator (modifier)
		case LINE_COMMENT: case BLOCK_COMMENT: case CONTRACT:
			return 9;                // comment
		case STRING: case CHAR_LITERAL: case BYTES:
			return 10;               // string
		case INTEGER: case REAL:
			return 11;               // number
		// Operators and punctuation
		case AMP: case BIT_OR: case BIT_XOR: case BIT_NOT: case BANG:
		case PLUS: case MINUS: case STAR: case DIV: case MOD:
		case QUESTION: case QUESTQUEST: case ELVIS: case BANGBANG:
		case SHR_OP: case SHL_OP: case PLUSPLUS: case MINUSMINUS:
		case CT_CONCAT_OP: case CT_TERNARY:
		case EQ: case SHR_ASSIGN: case SHL_ASSIGN: case PLUS_ASSIGN:
		case MINUS_ASSIGN: case MULT_ASSIGN: case DIV_ASSIGN:
		case MOD_ASSIGN: case BIT_AND_ASSIGN: case BIT_XOR_ASSIGN:
		case BIT_OR_ASSIGN: case CT_CONCAT_ASSIGN:
		case LESS: case GREATER: case AND: case OR:
		case LESS_EQ: case GREATER_EQ: case EQEQ: case NOT_EQUAL:
		case CT_AND_OP: case CT_OR_OP:
		case EOS: case COLON: case SCOPE: case COMMA: case DOT:
		case DOTDOT: case ELLIPSIS:
		case LBRACE: case RBRACE: case LBRACKET: case RBRACKET:
		case LPAREN: case RPAREN: case ARROW: case IMPLIES:
		case LVEC: case RVEC:
			return 12;               // operator
		default:
			return -1;               // skip (EOF, EOL, INVALID)
	}
}

struct LineOffsets {
	usz[MAX_LINE_OFFSETS] offsets;
	usz count;
}

fn void build_line_offsets(String content, LineOffsets* lo) {
	lo.count = 1;
	lo.offsets[0] = 0; // Line 0 starts at byte 0

	for (usz i = 0; i < content.len && lo.count < MAX_LINE_OFFSETS; i++) {
		if (content[i] == '\n') {
			lo.offsets[lo.count] = i + 1;
			lo.count++;
		}
	}
}

fn usz find_line(LineOffsets* lo, usz offset) {
	usz low = 0;
	usz high = lo.count;
	while (low < high) {
		usz mid = (low + high) / 2;
		if (lo.offsets[mid] <= offset) {
			low = mid + 1;
		} else {
			high = mid;
		}
	}
	return low > 0 ? low - 1 : 0;
}

fn void encode_semantic_tokens(String content, DString* out) {
	LineOffsets* lo = mem::new(LineOffsets);
	defer mem::free(lo);
	build_line_offsets(content, lo);

	Lexer lex;
	lex.init(content);

	usz prev_line = 0;
	usz prev_start_char = 0;
	bool first = true;

	while (true) {
		if (try tok = lex.next()) {
			int token_type = map_token_type(tok.type);
			if (token_type < 0) continue;

			usz line = find_line(lo, tok.offset);
			usz start_char = tok.offset - lo.offsets[line];

			usz delta_line = line - prev_line;
			usz delta_start_char = delta_line == 0 ? start_char - prev_start_char : start_char;

			if (!first) out.append_char(',');
			out.appendf("%d,%d,%d,%d,0", delta_line, delta_start_char, tok.len, token_type);
			first = false;

			prev_line = line;
			prev_start_char = start_char;
		} else {
			if (lex.at_end()) break;
			lex.pos++;
			lex.col++;
		}
	}
}
