package main

import "core:log"
import "core:testing"

@(test)
parser_test_select_1 :: proc(t: ^testing.T) {
	tokens := []Token {
		Token{kind = .Select, text = "SELECT"},
		Token{kind = .Asterisk, text = "*"},
		Token{kind = .From, text = "FROM"},
		Token{kind = .Ident, text = "users"},
	}
	parser := parser_init(tokens, context.temp_allocator)
	select, ok := parse_select(&parser)
	testing.expect(t, ok)
}

@(test)
parser_test_select_subquery :: proc(t: ^testing.T) {
	tokens := []Token {
		Token{kind = .Select, text = "SELECT"},
		Token{kind = .Asterisk, text = "*"},
		Token{kind = .From, text = "FROM"},
		Token{kind = .Open_Paren, text = "("},
		Token{kind = .Select, text = "SELECT"},
		Token{kind = .Ident, text = "name"},
		Token{kind = .From, text = "FROM"},
		Token{kind = .Ident, text = "users"},
		Token{kind = .Close_Paren, text = ")"},
		Token{kind = .Where, text = "WHERE"},
		Token{kind = .Ident, text = "age"},
		Token{kind = .Greater_Than, text = ">"},
		Token{kind = .Number, text = "18"},
	}
	parser := parser_init(tokens, context.temp_allocator)
	select, ok := parse_select(&parser)
	testing.expect(t, ok)

	select_subquery, subquery_ok := select.table_or_subquery.value.(^Select)
	testing.expect(t, subquery_ok, "Expected table to be a Select subquery")

	if subquery_ok {
		subquery_table, table_ok := select_subquery.table_or_subquery.value.(^AST_Ident)
		testing.expect(t, table_ok, "Expected subquery table to be an Ident")
		testing.expect(
			t,
			subquery_table.name == "users",
			"Expected subquery table name to be 'users'",
		)
	}
}
