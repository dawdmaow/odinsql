package main

import "core:fmt"
import "core:log"
import "core:strings"

Token_Kind :: enum u8 {
	__INVALID__,
	Ident,
	Open_Paren,
	Close_Paren,
	Asterisk,
	Plus,
	Minus,
	Slash,
	Semicolon,
	Comma,
	__Literal_Begin__,
	Number,
	String,
	__Literal_End__,
	__Keyword_Begin__,
	Equals,
	Not_Equals,
	Greater_Than,
	Less_Than,
	Gt_Eq,
	Lt_Eq,
	In,
	Not_In,
	Between,
	Not_Between,
	Like,
	Not_Like,
	And,
	Or,
	Not,
	Select,
	From,
	Where,
	Order_By,
	Limit,
	Offset,
	Insert,
	Into,
	Values,
	Update,
	Set,
	Delete,
	Create,
	Table,
	Join,
	Inner,
	Left,
	Right,
	On,
	Primary,
	Key,
	Null,
	True,
	False,
	__Keyword_End__,
}

Token :: struct {
	line:   u16,
	column: u16,
	kind:   Token_Kind,
	text:   string, // a slice from the original source code. don't deallocate the source code before tokens are processed.
}

Tokenizer_Error :: struct {
	message: string,
}

is_digit :: proc(ch: u8) -> bool {
	return ch >= '0' && ch <= '9'
}

is_letter :: proc(ch: u8) -> bool {
	return (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z')
}

is_ident_char :: proc(ch: u8) -> bool {
	return is_letter(ch) || is_digit(ch) || ch == '_'
}

is_whitespace :: proc(ch: u8) -> bool {
	return ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r' || ch == '\f' || ch == '\v'
}

is_newline :: proc(ch: u8) -> bool {
	return ch == '\n' || ch == '\r'
}

keyword_from_string :: proc(s: string) -> (Token_Kind, bool) {
	switch strings.to_upper(s, context.temp_allocator) {
	case "SELECT":
		return .Select, true
	case "FROM":
		return .From, true
	case "WHERE":
		return .Where, true
	case "ORDER BY":
		return .Order_By, true
	case "LIMIT":
		return .Limit, true
	case "OFFSET":
		return .Offset, true
	case "INSERT":
		return .Insert, true
	case "INTO":
		return .Into, true
	case "VALUES":
		return .Values, true
	case "UPDATE":
		return .Update, true
	case "SET":
		return .Set, true
	case "DELETE":
		return .Delete, true
	case "CREATE":
		return .Create, true
	case "TABLE":
		return .Table, true
	case "JOIN":
		return .Join, true
	case "INNER":
		return .Inner, true
	case "LEFT":
		return .Left, true
	case "RIGHT":
		return .Right, true
	case "ON":
		return .On, true
	case "PRIMARY":
		return .Primary, true
	case "KEY":
		return .Key, true
	case "IN":
		return .In, true
	case "NOT IN":
		return .Not_In, true
	case "BETWEEN":
		return .Between, true
	case "NOT BETWEEN":
		return .Not_Between, true
	case "LIKE":
		return .Like, true
	case "NOT LIKE":
		return .Not_Like, true
	case "AND":
		return .And, true
	case "OR":
		return .Or, true
	case "NOT":
		return .Not, true
	case "NULL":
		return .Null, true
	case "TRUE":
		return .True, true
	case "FALSE":
		return .False, true
	}
	return .__INVALID__, false
}

// TODO: `column` counter is completely wrong for non-ASCII UTF-8 runes. maybe it would be worth it to handle runes instead of bytes.
tokenize :: proc(s: string, allocator := context.allocator) -> (tokens: [dynamic]Token, ok: bool) {
	context.allocator = allocator

	result := make([dynamic]Token)
	i := 0
	line := 1
	column := 1

	for i < len(s) {
		ch := s[i]

		// handle newline
		if is_newline(ch) {
			i += 1
			line += 1
			column = 1
			continue
		}

		// skip whitespace
		if is_whitespace(ch) {
			start := i
			for i < len(s) && is_whitespace(s[i]) && !is_newline(s[i]) {
				i += 1
			}
			column += i - start
			continue
		}

		// get a number token
		if is_digit(ch) {
			start_pos := i
			start_col := column

			for i < len(s) && is_digit(s[i]) {
				i += 1
			}

			if i < len(s) && s[i] == '.' && i + 1 < len(s) && is_digit(s[i + 1]) {
				i += 1
				for i < len(s) && is_digit(s[i]) {
					i += 1
				}
			}

			text := s[start_pos:i]
			column += len(text)
			append(
				&result,
				Token{line = u16(line), column = u16(start_col), kind = .Number, text = text},
			)
			continue
		}

		// handle special characters
		if ch == '(' ||
		   ch == ')' ||
		   ch == '*' ||
		   ch == ';' ||
		   ch == ',' ||
		   ch == '+' ||
		   ch == '-' ||
		   ch == '/' {
			kind: Token_Kind
			switch ch {
			case '(':
				kind = .Open_Paren
			case ')':
				kind = .Close_Paren
			case '*':
				kind = .Asterisk
			case ';':
				kind = .Semicolon
			case ',':
				kind = .Comma
			case '+':
				kind = .Plus
			case '-':
				kind = .Minus
			case '/':
				kind = .Slash
			case:
				unreachable()
			}
			append(
				&result,
				Token{line = u16(line), column = u16(column), kind = kind, text = s[i:i + 1]},
			)
			i += 1
			column += 1
			continue
		}

		// handle == and !=
		if i + 1 < len(s) && (s[i:i + 2] == "==" || s[i:i + 2] == "!=") {
			kind := s[i:i + 2] == "==" ? Token_Kind.Equals : Token_Kind.Not_Equals
			append(
				&result,
				Token{line = u16(line), column = u16(column), kind = kind, text = s[i:i + 2]},
			)
			i += 2
			column += 2
			continue
		}

		// handle <>
		if i + 1 < len(s) && s[i:i + 2] == "<>" {
			append(
				&result,
				Token {
					line = u16(line),
					column = u16(column),
					kind = .Not_Equals,
					text = s[i:i + 2],
				},
			)
			i += 2
			column += 2
			continue
		}

		// handle =
		if ch == '=' {
			append(
				&result,
				Token{line = u16(line), column = u16(column), kind = .Equals, text = s[i:i + 1]},
			)
			i += 1
			column += 1
			continue
		}

		// handle <=, >=, <, >
		if ch == '<' || ch == '>' {
			start_col := column
			start_pos := i
			i += 1
			column += 1

			if i < len(s) && s[i] == '=' {
				kind := ch == '<' ? Token_Kind.Lt_Eq : Token_Kind.Gt_Eq
				append(
					&result,
					Token {
						line = u16(line),
						column = u16(start_col),
						kind = kind,
						text = s[start_pos:i + 1],
					},
				)
				i += 1
				column += 1
			} else {
				kind := ch == '<' ? Token_Kind.Less_Than : Token_Kind.Greater_Than
				append(
					&result,
					Token {
						line = u16(line),
						column = u16(start_col),
						kind = kind,
						text = s[start_pos:i],
					},
				)
			}
			continue
		}

		// handle string literals
		if ch == '\'' || ch == '"' {
			str_char := ch
			start_col := column
			start_pos := i
			i += 1
			column += 1
			content_start := i

			for i < len(s) && s[i] != str_char {
				i += 1
				column += 1
			}

			content_end := i

			if i < len(s) {
				i += 1
				column += 1
			}

			append(
				&result,
				Token {
					line = u16(line),
					column = u16(start_col),
					kind = .String,
					text = s[content_start:content_end],
				},
			)
			continue
		}

		// miscellaneous
		if is_letter(ch) {
			start_pos := i
			kw_or_ident_col := column

			for i < len(s) && is_ident_char(s[i]) {
				i += 1
			}

			text := s[start_pos:i]
			text_upper := strings.to_upper(text, context.temp_allocator)

			// handle ORDER BY
			if text_upper == "ORDER" && i < len(s) && s[i] == ' ' {
				for i < len(s) && is_whitespace(s[i]) {
					i += 1
					column += 1
				}

				if i < len(s) && is_letter(s[i]) {
					by_start := i
					for i < len(s) && is_ident_char(s[i]) {
						i += 1
					}
					by_text := s[by_start:i]
					by_upper := strings.to_upper(by_text, context.temp_allocator)

					if by_upper == "BY" {
						full_text := s[start_pos:i]
						column += len(text) + len(by_text)
						append(
							&result,
							Token {
								line = u16(line),
								column = u16(kw_or_ident_col),
								kind = .Order_By,
								text = full_text,
							},
						)
						continue
					}
				}
			}

			// handle 'NOT IN', 'NOT LIKE', 'NOT BETWEEN' (but not 'NOT' itself)
			if text_upper == "NOT" && i < len(s) && s[i] == ' ' {
				prev_i := i
				prev_col := column
				prev_line := line

				for i < len(s) && is_whitespace(s[i]) {
					i += 1
					column += 1
				}

				if i < len(s) && is_letter(s[i]) {
					next_start := i
					for i < len(s) && is_ident_char(s[i]) {
						i += 1
					}
					next_text := s[next_start:i]
					next_upper := strings.to_upper(next_text, context.temp_allocator)

					kind: Token_Kind
					found := false

					if next_upper == "IN" {
						kind = .Not_In
						found = true
					} else if next_upper == "LIKE" {
						kind = .Not_Like
						found = true
					} else if next_upper == "BETWEEN" {
						kind = .Not_Between
						found = true
					}

					if found {
						full_text := s[start_pos:i]
						column += len(text) + len(next_text)
						append(
							&result,
							Token {
								line = u16(line),
								column = u16(kw_or_ident_col),
								kind = kind,
								text = full_text,
							},
						)
						continue
					}
				}

				// whoops, need to reset the positions to the 'NOT' so that the keyword matching legic below catches it instead
				i = prev_i
				column = prev_col
				line = prev_line
			}

			// handle qualified identifiers (ex. 'users.name')
			if i < len(s) && s[i] == '.' {
				i += 1
				dot_start := i
				for i < len(s) && is_ident_char(s[i]) {
					i += 1
				}

				full_text := s[start_pos:i]
				column += len(full_text)
				append(
					&result,
					Token {
						line = u16(line),
						column = u16(kw_or_ident_col),
						kind = .Ident,
						text = full_text,
					},
				)
				continue
			}

			// handle keywords (ex. 'SELECT')
			if kw, ok := keyword_from_string(text); ok {
				column += len(text)
				append(
					&result,
					Token{line = u16(line), column = u16(kw_or_ident_col), kind = kw, text = text},
				)
				continue
			}

			// handle identifiers (unqualified)
			column += len(text)
			append(
				&result,
				Token{line = u16(line), column = u16(kw_or_ident_col), kind = .Ident, text = text},
			)
			continue
		}

		log.errorf("Unexpected character at %v:%v: %v", line, column, ch)
		return result, false
	}

	return result, true
}
