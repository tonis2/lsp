module lsp;

import std::core::dstring;
import std::core::mem;
import c3::lexer;

// High-level queries for finding declarations, references, etc.
// These work on a single token stream

// Find the declaration of a token in the stream
// Returns the token at the declaration site
fn Token? TokenStream.find_declaration_of(&self, Token target, sz target_idx)
{
	String name = target.text;

	switch (target.type)
	{
		case TYPE_IDENT:
			// Search for: struct/union/bitstruct/enum/faultdef/interface/typedef/constdef/alias TYPE_IDENT
			for (sz i = 0; i + 1 < self.tokens.size; i++)
			{
				TokenType kw = self.tokens.get(i).type;
				if (is_type_declaration_keyword(kw))
				{
					Token next = self.tokens.get(i + 1);
					if (next.type == TYPE_IDENT && next.text == name)
					{
						return next;
					}
				}
			}

		case CONST_IDENT:
			// constdef NAME
			for (sz i = 0; i + 1 < self.tokens.size; i++)
			{
				if (self.tokens.get(i).type == CONSTDEF)
				{
					Token next = self.tokens.get(i + 1);
					if (next.type == CONST_IDENT && next.text == name)
					{
						return next;
					}
				}
			}

			// const [Type] NAME = ...
			for (sz i = 0; i + 1 < self.tokens.size; i++)
			{
				if (self.tokens.get(i).type != CONST) continue;
				// const NAME = ... (no type)
				Token next = self.tokens.get(i + 1);
				if (next.type == CONST_IDENT && next.text == name)
				{
					return next;
				}
				// const Type NAME = ... (with type)
				if (i + 2 < self.tokens.size)
				{
					Token after_type = self.tokens.get(i + 2);
					if (is_type_token(next.type) && after_type.type == CONST_IDENT && after_type.text == name)
					{
						return after_type;
					}
				}
			}

			// enum / faultdef / constdef member: enum Foo { NAME }, constdef Bar : T { NAME = v }, faultdef NAME
			if (try found = self.tokens.find_enum_or_constdef_member(name))
			{
				return self.tokens.entries[found];
			}

		case IDENT:
		case AT_IDENT:
			// fn ... name( or macro ... name(
			for (sz i = 0; i < self.tokens.size; i++)
			{
				TokenType kw = self.tokens.get(i).type;
				if (kw != FUNC && kw != MACRO) continue;
				for (sz j = i + 1; j < self.tokens.size && j < i + 64; j++)
				{
					Token t = self.tokens.get(j);
					if (t.type == LPAREN)
					{
						if (j > 0)
						{
							Token prev = self.tokens.get(j - 1);
							if (is_ident(prev.type) && prev.text == name)
							{
								return prev;
							}
						}
						break;
					}
					if (t.type == LBRACE || t.type == EOS) break;
				}
			}

			// macro name (no parens)
			for (sz i = 0; i + 1 < self.tokens.size; i++)
			{
				if (self.tokens.get(i).type == MACRO)
				{
					Token next = self.tokens.get(i + 1);
					if (is_ident(next.type) && next.text == name)
					{
						return next;
					}
				}
			}

			// type IDENT = ... (variable declaration)
			for (sz i = 0; i + 1 < self.tokens.size; i++)
			{
				Token t = self.tokens.get(i);
				if (is_type_token(t.type))
				{
					Token next = self.tokens.get(i + 1);
					if (is_ident(next.type) && next.text == name)
					{
						if (i + 2 < self.tokens.size)
						{
							TokenType after = self.tokens.get(i + 2).type;
							if (after == EQ || after == EOS || after == COMMA || after == DOT)
							{
								return next;
							}
						}
					}
				}
			}

		default:
			return TOKEN_NOT_FOUND~;
	}

	return TOKEN_NOT_FOUND~;
}

// Count references to a token in the stream
fn sz TokenStream.count_refs(&self, Token target)
{
	sz count = 0;
	foreach (tok : self.tokens)
	{
		if (tok.type == target.type && tok.text == target.text)
		{
			count++;
		}
	}
	return count;
}

// Check if a reference exists in a specific offset range
fn bool TokenStream.has_ref_in_range(&self, Token target, sz start_offset, sz end_offset)
{
	foreach (tok : self.tokens)
	{
		if (tok.offset >= start_offset && tok.offset < end_offset)
		{
			if (tok.type == target.type && tok.text == target.text)
			{
				return true;
			}
		}
	}
	return false;
}

// Find the type name of a variable by scanning for TYPE_IDENT var_name or TYPE_IDENT* var_name patterns.
fn String TokenStream.find_variable_type(&self, String var_name)
{
	for (sz i = 0; i + 1 < self.tokens.size; i++)
	{
		Token type_tok = self.tokens.get(i);
		if (type_tok.type != TYPE_IDENT) continue;

		// Direct: TYPE_IDENT var_name
		Token var_tok = self.tokens.get(i + 1);
		if (is_ident(var_tok.type) && var_tok.text == var_name)
		{
			if (i + 2 < self.tokens.size)
			{
				TokenType next = self.tokens.get(i + 2).type;
				if (next == EOS || next == EQ || next == COMMA || next == DOT)
				{
					return type_tok.text;
				}
			}
		}
		// Pointer: TYPE_IDENT* var_name
		if (i + 2 < self.tokens.size && var_tok.type == STAR)
		{
			Token ptr_var = self.tokens.get(i + 2);
			if (is_ident(ptr_var.type) && ptr_var.text == var_name)
			{
				if (i + 3 < self.tokens.size)
				{
					TokenType next = self.tokens.get(i + 3).type;
					if (next == EOS || next == EQ || next == COMMA || next == DOT)
					{
						return type_tok.text;
					}
				}
			}
		}
	}
	return "";
}

// Resolve a type alias to its base type name
// e.g. alias TokenList = List{Token} -> "List"
fn String TokenStream.resolve_type_alias(&self, String type_name)
{
	for (sz i = 0; i + 3 < self.tokens.size; i++)
	{
		Token kw   = self.tokens.get(i);
		Token name = self.tokens.get(i + 1);
		Token eq   = self.tokens.get(i + 2);
		Token base = self.tokens.get(i + 3);

		if (kw.type == ALIAS && name.type == TYPE_IDENT && name.text == type_name && eq.type == EQ
			&& base.type == TYPE_IDENT)
		{
			return base.text;
		}
	}
	return "";
}

// Detect method call context (IDENT DOT IDENT) and resolve receiver type
fn String TokenStream.resolve_method_type(&self, sz cursor_idx)
{
	if (cursor_idx < 2) return "";

	Token dot      = self.tokens.get(cursor_idx - 1);
	Token receiver = self.tokens.get(cursor_idx - 2);

	if (dot.type != DOT || !is_ident(receiver.type)) return "";

	String type_name = self.find_variable_type(receiver.text);
	if (type_name.len == 0) return "";

	// Try local resolution
	String local_resolved = self.resolve_type_alias(type_name);
	if (local_resolved.len > 0 && local_resolved != type_name) return local_resolved;

	return type_name;
}

// Find function scope boundaries containing a given offset
fn sz[2]? TokenStream.find_function_scope(&self, sz offset)
{
	for (sz i = 0; i < self.tokens.size; i++)
	{
		TokenType tt = self.tokens.get(i).type;
		if (tt != FUNC && tt != MACRO) continue;

		// Find the opening brace of this function
		sz brace_idx   = 0;
		sz paren_start = 0;
		for (sz j = i + 1; j < self.tokens.size; j++)
		{
			TokenType jt = self.tokens.get(j).type;
			if (paren_start == 0 && jt == LPAREN)
			{
				paren_start = self.tokens.get(j).offset;
			}
			if (jt == LBRACE)
			{
				brace_idx = j;
				break;
			}
			if (jt == EOS) break;
		}
		if (brace_idx == 0) continue;

		// Find matching close brace without modifying cursor
		Token? close = self.skip_to_matching(brace_idx);
		if (try c = close)
		{
			sz brace_start = self.tokens.get(brace_idx).offset;
			sz brace_end   = c.offset + c.len;

			// Check if offset is in function body
			if (offset >= brace_start && offset < brace_end)
			{
				return { brace_start, brace_end };
			}

			// Check if offset is in parameter list
			if (paren_start != 0 && offset >= paren_start && offset < brace_start)
			{
				return { paren_start, brace_end };
			}
		}
	}
	return TOKEN_NOT_FOUND~;
}

// Find the index of a token by its offset
fn sz? TokenStream.index_of(&self, Token target)
{
	for (sz i = 0; i < self.tokens.size; i++)
	{
		Token tok = self.tokens.get(i);
		if (tok.offset == target.offset && tok.len == target.len)
		{
			return i;
		}
	}
	return TOKEN_NOT_FOUND~;
}

// Check if a token is at a specific declaration site
fn bool TokenStream.is_at_declaration(&self, Token target)
{
	Token? decl = self.find_declaration_of(target, self.tokens.size);
	if (try d = decl)
	{
		return d.offset == target.offset;
	}
	return false;
}

// Get the signature range of a declaration (from keyword to before body)
fn sz[2]? TokenStream.declaration_signature_range(&self, sz decl_idx)
{
	if (decl_idx >= self.tokens.size) return OUT_OF_BOUNDS~;

	// Walk back to find declaration keyword
	sz keyword_idx = decl_idx;
	for (sz i = decl_idx; i > 0; i--)
	{
		TokenType t = self.tokens.get(i - 1).type;
		if (t == FUNC || t == MACRO || t == STRUCT || t == UNION || t == ENUM || t == BITSTRUCT || t == INTERFACE
			|| t == FAULTDEF
			|| t == CONSTDEF
			|| t == TYPEDEF
			|| t == ALIAS
			|| t == ATTRDEF)
		{
			keyword_idx = i - 1;
			break;
		}
		if (t == RBRACE || t == EOS || t == LBRACE) break;
	}

	sz start = self.tokens.get(keyword_idx).offset;
	sz end   = start;

	// Find end: up to '{' or ';' or end of stream
	for (sz i = keyword_idx; i < self.tokens.size; i++)
	{
		Token t = self.tokens.get(i);
		if (t.type == LBRACE || t.type == EOS)
		{
			end = t.offset;
			break;
		}
		end = t.offset + t.len;
	}

	return { start, end };
}
