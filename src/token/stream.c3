module lsp;

import std::core::dstring;
import std::core::mem;
import std::collections::list;
import c3::lexer;

// Fault types for token operations
faultdef TOKEN_NOT_FOUND;
faultdef OUT_OF_BOUNDS;

// TokenStream wraps token list with lazy LineOffsets caching
struct TokenStream
{
	TokenList tokens;
	String content;
	LineOffsets* line_cache;
	sz index; // Current position for navigation
}

// Initialize from content by tokenizing
fn TokenStream token_stream_tokenize(String content)
{
	TokenStream self;
	self.content = content;
	self.line_cache = null;
	self.index = 0;
	self.tokens.init(mem);

	Lexer lex;
	lex.init(content);
	// Invalid input comes back as INVALID tokens, so the only failure is the end.
	while (try tok = lex.next()) self.tokens.push(tok);
	return self;
}

// Initialize from existing tokens (used when loading from documents)
fn TokenStream token_stream_from_tokens(TokenList tokens, String content)
{
	TokenStream self;
	self.tokens = tokens;
	self.content = content;
	self.line_cache = null;
	self.index = 0;
	return self;
}

// Free the stream and its cache
fn void TokenStream.free(&self)
{
	self.tokens.free();
	if (self.line_cache != null)
	{
		self.line_cache.free();
		mem::free(self.line_cache);
	}
}

// Get lazy-initialized line offsets
fn LineOffsets* TokenStream.get_line_offsets(&self)
{
	if (self.line_cache == null)
	{
		self.line_cache = mem::new(LineOffsets);
		self.line_cache.init(mem);
		self.line_cache.build(self.content);
	}
	return self.line_cache;
}

// Convert a token to a Range using this stream's line offsets
fn Range TokenStream.token_to_range(&self, Token tok)
{
	return span_to_range(self.content, self.get_line_offsets(), tok.offset, tok.offset + tok.len);
}

// Core accessors with C3 error handling using ?
fn Token? TokenStream.at(&self, sz idx)
{
	if (idx >= self.tokens.size) return OUT_OF_BOUNDS~;
	return self.tokens.get(idx);
}

fn Token? TokenStream.find_at(&self, sz offset)
{
	for (sz i = 0; i < self.tokens.size; i++)
	{
		Token tok = self.tokens.get(i);
		sz tok_end = tok.offset + tok.len;
		if (tok.offset <= offset && offset < tok_end)
		{
			return tok;
		}
	}
	// Try offset-1 for cursor at end of word
	if (offset > 0)
	{
		sz adj = offset - 1;
		for (sz i = 0; i < self.tokens.size; i++)
		{
			Token tok = self.tokens.get(i);
			sz tok_end = tok.offset + tok.len;
			if (tok.offset <= adj && adj < tok_end)
			{
				return tok;
			}
		}
	}
	return TOKEN_NOT_FOUND~;
}

fn Token? TokenStream.find_ident_at(&self, sz offset)
{
	Token? tok_result = self.find_at(offset);
	if (try tok = tok_result)
	{
		if (is_ident(tok.type) || tok.type == TYPE_IDENT || tok.type == CONST_IDENT)
		{
			return tok;
		}
	}
	// Try offset-1 for preceding identifier
	if (offset > 0)
	{
		Token? prev_result = self.find_at(offset - 1);
		if (try prev = prev_result)
		{
			if (is_ident(prev.type) || prev.type == TYPE_IDENT || prev.type == CONST_IDENT)
			{
				return prev;
			}
		}
	}
	// Try offset+1 for following identifier
	Token? next_result = self.find_at(offset + 1);
	if (try next = next_result)
	{
		if (is_ident(next.type) || next.type == TYPE_IDENT || next.type == CONST_IDENT)
		{
			return next;
		}
	}
	return TOKEN_NOT_FOUND~;
}

// Get token index at offset
fn sz? TokenStream.index_at(&self, sz offset)
{
	for (sz i = 0; i < self.tokens.size; i++)
	{
		Token tok = self.tokens.get(i);
		sz tok_end = tok.offset + tok.len;
		if (tok.offset <= offset && offset < tok_end)
		{
			return i;
		}
	}
	if (offset > 0)
	{
		sz adj = offset - 1;
		for (sz i = 0; i < self.tokens.size; i++)
		{
			Token tok = self.tokens.get(i);
			sz tok_end = tok.offset + tok.len;
			if (tok.offset <= adj && adj < tok_end)
			{
				return i;
			}
		}
	}
	return TOKEN_NOT_FOUND~;
}

// Line/Column with caching
fn sz? TokenStream.line_of(&self, sz offset)
{
	if (offset > self.content.len) return OUT_OF_BOUNDS~;
	LineOffsets* lo = self.get_line_offsets();
	return lo.find_line(offset);
}

fn sz? TokenStream.col_of(&self, sz offset)
{
	if (offset > self.content.len) return OUT_OF_BOUNDS~;
	LineOffsets* lo = self.get_line_offsets();
	sz line = lo.find_line(offset);
	return offset - lo.entries[line];
}

// Navigation helpers
fn Token? TokenStream.next_of_type(&self, TokenType type, sz from_idx)
{
	for (sz i = from_idx + 1; i < self.tokens.size; i++)
	{
		Token tok = self.tokens.get(i);
		if (tok.type == type) return tok;
	}
	return TOKEN_NOT_FOUND~;
}

fn Token? TokenStream.prev_of_type(&self, TokenType type, sz from_idx)
{
	if (from_idx == 0) return OUT_OF_BOUNDS~;
	for (sz i = from_idx - 1; i < self.tokens.size; i--)
	{
		Token tok = self.tokens.get(i);
		if (tok.type == type) return tok;
	}
	return TOKEN_NOT_FOUND~;
}

// Skip to matching brace/paren/bracket
fn Token? TokenStream.skip_to_matching(&self, sz from_idx)
{
	if (from_idx >= self.tokens.size) return OUT_OF_BOUNDS~;

	Token open = self.tokens.get(from_idx);
	TokenType close_type;
	int direction = 1;

	switch (open.type)
	{
		case LBRACE: close_type = RBRACE;
		case LPAREN: close_type = RPAREN;
		case LBRACKET: close_type = RBRACKET;
		case RBRACE:
			close_type = LBRACE;
			direction = -1;
		case RPAREN:
			close_type = LPAREN;
			direction = -1;
		case RBRACKET:
			close_type = LBRACKET;
			direction = -1;
		default: return TOKEN_NOT_FOUND~;
	}

	// Guard against underflow when going backwards from index 0
	if (direction < 0 && from_idx == 0) return TOKEN_NOT_FOUND~;

	sz depth = 1;
	sz i = (sz)((long)from_idx + direction);

	while (i < self.tokens.size)
	{
		Token tok = self.tokens.get(i);
		if (tok.type == open.type)
		{
			depth++;
		}
		else if (tok.type == close_type)
		{
			depth--;
			if (depth == 0) return tok;
		}
		if (direction < 0 && i == 0) break;
		i = (sz)((long)i + direction);
	}

	return TOKEN_NOT_FOUND~;
}

// Find end of statement (semicolon or end of stream)
fn Token? TokenStream.find_eos(&self, sz from_idx)
{
	for (sz i = from_idx; i < self.tokens.size; i++)
	{
		Token tok = self.tokens.get(i);
		if (tok.type == EOS) return tok;
	}
	return TOKEN_NOT_FOUND~;
}

// Navigation methods

// Get current position
fn sz TokenStream.position(&self) => self.index;

// Set position
fn void TokenStream.set_position(&self, sz pos)
{
	self.index = pos;
}

// Reset to beginning
fn void TokenStream.reset(&self)
{
	self.index = 0;
}

// Get current token at position
fn Token? TokenStream.current(&self)
{
	if (self.index >= self.tokens.size) return OUT_OF_BOUNDS~;
	return self.tokens.get(self.index);
}

// Advance to next token
fn Token? TokenStream.advance(&self)
{
	self.index++;
	return self.current();
}

// Rewind to previous token
fn Token? TokenStream.rewind(&self)
{
	if (self.index == 0) return OUT_OF_BOUNDS~;
	self.index--;
	return self.current();
}

// Check if at end
fn bool TokenStream.at_end(&self) => self.index >= self.tokens.size;

// Peek ahead without moving
fn Token? TokenStream.peek(&self, sz ahead)
{
	sz target = self.index + ahead;
	if (target >= self.tokens.size) return OUT_OF_BOUNDS~;
	return self.tokens.get(target);
}

// Look behind without rewinding
fn Token? TokenStream.look_back(&self, sz behind)
{
	if (behind > self.index) return OUT_OF_BOUNDS~;
	return self.tokens.get(self.index - behind);
}

// Skip to next token of specific type
fn Token? TokenStream.skip_to(&self, TokenType type)
{
	while (self.index < self.tokens.size)
	{
		Token tok = self.tokens.get(self.index);
		if (tok.type == type) return tok;
		self.index++;
	}
	return TOKEN_NOT_FOUND~;
}

// Match current token type
fn bool TokenStream.match(&self, TokenType expected)
{
	if (self.index >= self.tokens.size) return false;
	return self.tokens.get(self.index).type == expected;
}

// Match and advance if matches
fn bool TokenStream.match_advance(&self, TokenType expected)
{
	if (self.match(expected))
	{
		self.index++;
		return true;
	}
	return false;
}

// Match sequence of tokens (does not advance)
fn bool TokenStream.match_sequence(&self, TokenType[] pattern)
{
	if (self.index + pattern.len > self.tokens.size) return false;
	for (sz i = 0; i < pattern.len; i++)
	{
		if (self.tokens.get(self.index + i).type != pattern[i])
		{
			return false;
		}
	}
	return true;
}

// Match and consume sequence (advances past pattern)
fn bool TokenStream.consume_sequence(&self, TokenType[] pattern)
{
	if (!self.match_sequence(pattern)) return false;
	self.index += pattern.len;
	return true;
}

// Skip past the matching close brace/paren/bracket
fn Token? TokenStream.skip_past_matching(&self)
{
	Token? match_result = self.skip_to_matching(self.index);
	if (try matched = match_result)
	{
		// Find the index of the matched token and move past it
		for (sz i = self.index + 1; i < self.tokens.size; i++)
		{
			Token tok = self.tokens.get(i);
			if (tok.offset == matched.offset && tok.len == matched.len)
			{
				self.index = i + 1;
				if (self.index < self.tokens.size)
				{
					return self.tokens.get(self.index);
				}
				return OUT_OF_BOUNDS~;
			}
		}
	}
	return TOKEN_NOT_FOUND~;
}

// Check if current position is inside a function body
fn bool TokenStream.is_in_function_body(&self)
{
	sz depth = 0;
	for (sz i = 0; i < self.index && i < self.tokens.size; i++)
	{
		Token tok = self.tokens.get(i);
		if (tok.type == FUNC || tok.type == MACRO)
		{
			// Check if we're after the function signature's opening brace
			for (sz j = i + 1; j < self.tokens.size && j < self.index; j++)
			{
				Token inner = self.tokens.get(j);
				if (inner.type == LBRACE)
				{
					depth++;
				}
				else if (inner.type == RBRACE)
				{
					depth--;
				}
			}
			return depth > 0;
		}
	}
	return false;
}

// Find end of statement (semicolon) starting from given index
fn Token? TokenStream.find_eos_end(&self, sz start_idx)
{
	for (sz j = start_idx; j < self.tokens.size; j++)
	{
		if (self.tokens.get(j).type == EOS)
		{
			return self.tokens.get(j);
		}
	}
	return TOKEN_NOT_FOUND~;
}

// Find matching closing brace starting from given index
fn Token? TokenStream.find_brace_end(&self, sz start_idx)
{
	sz depth = 0;
	bool found_brace = false;
	for (sz j = start_idx; j < self.tokens.size; j++)
	{
		Token tok = self.tokens.get(j);
		if (tok.type == LBRACE)
		{
			depth++;
			found_brace = true;
		}
		else if (tok.type == RBRACE)
		{
			if (depth > 0) depth--;
			if (depth == 0 && found_brace)
			{
				return tok;
			}
		}
	}
	return TOKEN_NOT_FOUND~;
}

// Iterate over tokens
fn TokenIter TokenStream.iter(&self)
{
	return { .stream = self, .index = 0 };
}

fn TokenIter TokenStream.iter_from(&self, sz start)
{
	return { .stream = self, .index = start };
}

fn TokenIter TokenStream.iter_in_range(&self, sz start, sz end)
{
	return { .stream = self, .index = start, .end = end };
}

struct TokenIter
{
	TokenStream* stream;
	sz index;
	sz end; // 0 means no limit
}

fn Token? TokenIter.next(&self)
{
	if (self.index >= self.stream.tokens.size) return OUT_OF_BOUNDS~;
	if (self.end > 0 && self.index >= self.end) return OUT_OF_BOUNDS~;
	Token tok = self.stream.tokens.get(self.index);
	self.index++;
	return tok;
}

fn bool TokenIter.has_next(&self)
{
	if (self.index >= self.stream.tokens.size) return false;
	if (self.end > 0 && self.index >= self.end) return false;
	return true;
}

fn void TokenIter.reset(&self)
{
	self.index = 0;
}
