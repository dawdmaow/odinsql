#+vet explicit-allocators

package main

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
	Group_By,
	Having,
	Order_By,
	Asc,
	Desc,
	As,
	Limit,
	Offset,
	Insert,
	Into,
	Values,
	Update,
	Set,
	Delete,
	Create,
	Alter,
	Drop,
	Begin,
	Commit,
	Rollback,
	Table,
	If,
	Exists,
	Add,
	Rename,
	Column,
	To,
	Index,
	Join,
	Inner,
	Left,
	Right,
	Cross,
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
	start:  int, // byte offset into original query, inclusive
	end:    int, // byte offset into original query, exclusive
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
	// TODO: could do char-by-char case-insenstive comparison instead...
	switch strings.to_upper(s, database_query_allocator) {
	case "SELECT":
		return .Select, true
	case "FROM":
		return .From, true
	case "WHERE":
		return .Where, true
	case "GROUP BY":
		return .Group_By, true
	case "HAVING":
		return .Having, true
	case "ORDER BY":
		return .Order_By, true
	case "ASC":
		return .Asc, true
	case "DESC":
		return .Desc, true
	case "AS":
		return .As, true
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
	case "ALTER":
		return .Alter, true
	case "DROP":
		return .Drop, true
	case "BEGIN":
		return .Begin, true
	case "COMMIT":
		return .Commit, true
	case "ROLLBACK":
		return .Rollback, true
	case "TABLE":
		return .Table, true
	case "IF":
		return .If, true
	case "EXISTS":
		return .Exists, true
	case "ADD":
		return .Add, true
	case "RENAME":
		return .Rename, true
	case "COLUMN":
		return .Column, true
	case "TO":
		return .To, true
	case "INDEX":
		return .Index, true
	case "JOIN":
		return .Join, true
	case "INNER":
		return .Inner, true
	case "LEFT":
		return .Left, true
	case "RIGHT":
		return .Right, true
	case "CROSS":
		return .Cross, true
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
tokenize :: proc(s: string) -> (result: [dynamic]Token, ok: bool) {
	result = make([dynamic]Token, database_query_allocator)
	i := 0
	line := 1
	column := 1

	for i < len(s) {
		ch := s[i]

		switch {

		// skip newlines (CRLF counts as one line break, not two)
		case is_newline(ch):
			i += 1
			if ch == '\r' && i < len(s) && s[i] == '\n' {
				i += 1
			}
			line += 1
			column = 1

		// skip whitespace
		case is_whitespace(ch):
			start := i
			for i < len(s) && is_whitespace(s[i]) && !is_newline(s[i]) do i += 1
			column += i - start

		// SQL `--` line comments: skip through end of line; leave the newline for the branch above
		case i + 1 < len(s) && ch == '-' && s[i + 1] == '-':
			i += 2
			column += 2
			for i < len(s) && !is_newline(s[i]) {
				i += 1
				column += 1
			}

		// get a number token
		case is_digit(ch):
			start_pos := i
			start_col := column

			for i < len(s) && is_digit(s[i]) do i += 1

			if i < len(s) && s[i] == '.' && i + 1 < len(s) && is_digit(s[i + 1]) {
				i += 1
				for i < len(s) && is_digit(s[i]) do i += 1
			}

			text := s[start_pos:i]
			column += len(text)
			append(
				&result,
				Token {
					line = u16(line),
					column = u16(start_col),
					start = start_pos,
					end = i,
					kind = .Number,
					text = text,
				},
			)

		// handle some one-character special characters
		case ch == '(' ||
		     ch == ')' ||
		     ch == '*' ||
		     ch == ';' ||
		     ch == ',' ||
		     ch == '+' ||
		     ch == '-' ||
		     ch == '/':
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
				Token {
					line = u16(line),
					column = u16(column),
					start = i,
					end = i + 1,
					kind = kind,
					text = s[i:i + 1],
				},
			)
			i += 1
			column += 1

		// handle == and !=
		case i + 1 < len(s) && (s[i:i + 2] == "==" || s[i:i + 2] == "!="):
			kind := s[i:i + 2] == "==" ? Token_Kind.Equals : Token_Kind.Not_Equals
			append(
				&result,
				Token {
					line = u16(line),
					column = u16(column),
					start = i,
					end = i + 2,
					kind = kind,
					text = s[i:i + 2],
				},
			)
			i += 2
			column += 2

		// handle <>
		case i + 1 < len(s) && s[i:i + 2] == "<>":
			append(
				&result,
				Token {
					line = u16(line),
					column = u16(column),
					start = i,
					end = i + 2,
					kind = .Not_Equals,
					text = s[i:i + 2],
				},
			)
			i += 2
			column += 2

		// handle =
		case ch == '=':
			append(
				&result,
				Token {
					line = u16(line),
					column = u16(column),
					start = i,
					end = i + 1,
					kind = .Equals,
					text = s[i:i + 1],
				},
			)
			i += 1
			column += 1

		// handle <=, >=, <, >
		case ch == '<' || ch == '>':
			start_col := column
			start_pos := i
			i += 1
			column += 1

			switch {
			case i < len(s) && s[i] == '=':
				kind := ch == '<' ? Token_Kind.Lt_Eq : Token_Kind.Gt_Eq
				append(
					&result,
					Token {
						line = u16(line),
						column = u16(start_col),
						start = start_pos,
						end = i + 1,
						kind = kind,
						text = s[start_pos:i + 1],
					},
				)
				i += 1
				column += 1
			case:
				kind := ch == '<' ? Token_Kind.Less_Than : Token_Kind.Greater_Than
				append(
					&result,
					Token {
						line = u16(line),
						column = u16(start_col),
						start = start_pos,
						end = i,
						kind = kind,
						text = s[start_pos:i],
					},
				)
			}

		// handle string literals
		case ch == '\'' || ch == '"':
			str_char := ch
			start_col := column
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
					start = content_start,
					end = content_end,
					kind = .String,
					text = s[content_start:content_end],
				},
			)

		// handle custom metadata/tags
		case ch == '@':
			start_pos := i
			start_col := column
			i += 1
			for i < len(s) && is_ident_char(s[i]) do i += 1

			if i == start_pos + 1 {
				msgf(
					.Error,
					.Tokenizer,
					"Unexpected character at %v:%v-%v:%v %c",
					line,
					column,
					line,
					column + 1,
					ch,
				)
				return
			}

			text := s[start_pos:i]

			append(
				&result,
				Token {
					line = u16(line),
					column = u16(start_col),
					start = start_pos,
					end = i,
					kind = .Ident,
					text = text,
				},
			)

			column += len(text)

		case is_letter(ch):
			// handle keywords or identifiers
			start_pos := i
			kw_or_ident_col := column

			for i < len(s) && is_ident_char(s[i]) do i += 1

			text := s[start_pos:i]

			// TODO: could do char-by-char case-insenstive comparison instead...
			text_upper := strings.to_upper(text, database_query_allocator)

			// handle ORDER BY / GROUP BY
			if (text_upper == "ORDER" || text_upper == "GROUP") && i < len(s) && s[i] == ' ' {
				for i < len(s) && is_whitespace(s[i]) {
					i += 1
					column += 1
				}

				if i < len(s) && is_letter(s[i]) {
					by_start := i
					for i < len(s) && is_ident_char(s[i]) do i += 1
					by_text := s[by_start:i]
					by_upper := strings.to_upper(by_text, database_query_allocator)

					if by_upper == "BY" {
						full_text := s[start_pos:i]
						column += len(text) + len(by_text)

						by_kind: Token_Kind
						switch text_upper {
						case "GROUP":
							by_kind = .Group_By
						case "ORDER":
							by_kind = .Order_By
						case:
							unreachable()
						}

						append(
							&result,
							Token {
								line = u16(line),
								column = u16(kw_or_ident_col),
								start = start_pos,
								end = i,
								kind = by_kind,
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
					for i < len(s) && is_ident_char(s[i]) do i += 1
					next_text := s[next_start:i]
					next_upper := strings.to_upper(next_text, database_query_allocator)

					kind: Token_Kind
					found := false

					switch next_upper {
					case "IN":
						kind = .Not_In
						found = true
					case "LIKE":
						kind = .Not_Like
						found = true
					case "BETWEEN":
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
								start = start_pos,
								end = i,
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
				for i < len(s) && is_ident_char(s[i]) do i += 1

				full_text := s[start_pos:i]
				column += len(full_text)
				append(
					&result,
					Token {
						line = u16(line),
						column = u16(kw_or_ident_col),
						start = start_pos,
						end = i,
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
					Token {
						line = u16(line),
						column = u16(kw_or_ident_col),
						start = start_pos,
						end = i,
						kind = kw,
						text = text,
					},
				)
				continue
			}

			// handle identifiers (unqualified)
			column += len(text)
			append(
				&result,
				Token {
					line = u16(line),
					column = u16(kw_or_ident_col),
					start = start_pos,
					end = i,
					kind = .Ident,
					text = text,
				},
			)
		case:
			msgf(
				.Error,
				.Tokenizer,
				"Unexpected character at %v:%v-%v:%v %c",
				line,
				column,
				line,
				column + 1,
				ch,
			)
			return
		}
	}

	ok = true
	return
}
