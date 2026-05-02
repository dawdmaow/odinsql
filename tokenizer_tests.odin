#+build !js

package main

import "core:testing"

@(private)
_tokenizer_test :: proc(t: ^testing.T, query: string, expected: []Token) {
	defer main_finish()
	main_init()
	tokens, ok := tokenize(query)
	testing.expect(t, ok)
	testing.expect_value(t, len(tokens), len(expected))
	if len(tokens) != len(expected) {
		testing.expectf(t, false, "%#v", tokens)
		return
	}

	for token, i in tokens {
		expected_token := expected[i]
		testing.expect_value(t, token.line, expected_token.line)
		testing.expect_value(t, token.column, expected_token.column)
		testing.expect_value(t, token.kind, expected_token.kind)
		testing.expect_value(t, token.text, expected_token.text)

		// Keep span metadata honest by checking that each token points at its exact source slice.
		testing.expect(t, token.start >= 0)
		testing.expect(t, token.end >= token.start)
		testing.expect(t, token.end <= len(query))
		if token.start >= 0 && token.end >= token.start && token.end <= len(query) {
			testing.expect_value(t, query[token.start:token.end], token.text)
		}
	}
}

@(test)
tokenizer_test_1 :: proc(t: ^testing.T) {
	_tokenizer_test(
		t,
		"SELECT * FROM users",
		{
			Token{line = 1, column = 1, kind = .Select, text = "SELECT"},
			Token{line = 1, column = 8, kind = .Asterisk, text = "*"},
			Token{line = 1, column = 10, kind = .From, text = "FROM"},
			Token{line = 1, column = 15, kind = .Ident, text = "users"},
		},
	)
}

@(test)
tokenizer_test_2 :: proc(t: ^testing.T) {
	_tokenizer_test(
		t,
		"SELECT * FROM users WHERE age > 18",
		{
			Token{line = 1, column = 1, kind = .Select, text = "SELECT"},
			Token{line = 1, column = 8, kind = .Asterisk, text = "*"},
			Token{line = 1, column = 10, kind = .From, text = "FROM"},
			Token{line = 1, column = 15, kind = .Ident, text = "users"},
			Token{line = 1, column = 21, kind = .Where, text = "WHERE"},
			Token{line = 1, column = 27, kind = .Ident, text = "age"},
			Token{line = 1, column = 31, kind = .Greater_Than, text = ">"},
			Token{line = 1, column = 33, kind = .Number, text = "18"},
		},
	)
}

@(test)
tokenizer_test_sql_line_comments :: proc(t: ^testing.T) {
	// `--` removes the rest of the line; lone `-` stays minus; line/column continue correctly across CRLF.
	_tokenizer_test(
		t,
		"SELECT 1 -- ignored\nFROM t\r\nWHERE id--no space needed\r\n= 2",
		{
			Token{line = 1, column = 1, kind = .Select, text = "SELECT"},
			Token{line = 1, column = 8, kind = .Number, text = "1"},
			Token{line = 2, column = 1, kind = .From, text = "FROM"},
			Token{line = 2, column = 6, kind = .Ident, text = "t"},
			Token{line = 3, column = 1, kind = .Where, text = "WHERE"},
			Token{line = 3, column = 7, kind = .Ident, text = "id"},
			Token{line = 4, column = 1, kind = .Equals, text = "="},
			Token{line = 4, column = 3, kind = .Number, text = "2"},
		},
	)
}

@(test)
tokenizer_test_numbers :: proc(t: ^testing.T) {
	_tokenizer_test(
		t,
		"42 3.14 0 100.5",
		{
			Token{line = 1, column = 1, kind = .Number, text = "42"},
			Token{line = 1, column = 4, kind = .Number, text = "3.14"},
			Token{line = 1, column = 9, kind = .Number, text = "0"},
			Token{line = 1, column = 11, kind = .Number, text = "100.5"},
		},
	)
}

@(test)
tokenizer_test_strings :: proc(t: ^testing.T) {
	_tokenizer_test(
		t,
		"'hello' \"world\" 'John Doe'",
		{
			Token{line = 1, column = 1, kind = .String, text = "hello"},
			Token{line = 1, column = 9, kind = .String, text = "world"},
			Token{line = 1, column = 17, kind = .String, text = "John Doe"},
		},
	)
}

@(test)
tokenizer_test_operators :: proc(t: ^testing.T) {
	_tokenizer_test(
		t,
		"= != < > <= >=",
		{
			Token{line = 1, column = 1, kind = .Equals, text = "="},
			Token{line = 1, column = 3, kind = .Not_Equals, text = "!="},
			Token{line = 1, column = 6, kind = .Less_Than, text = "<"},
			Token{line = 1, column = 8, kind = .Greater_Than, text = ">"},
			Token{line = 1, column = 10, kind = .Lt_Eq, text = "<="},
			Token{line = 1, column = 13, kind = .Gt_Eq, text = ">="},
		},
	)
}

@(test)
tokenizer_test_special_chars :: proc(t: ^testing.T) {
	_tokenizer_test(
		t,
		"( ) * ; ,",
		{
			Token{line = 1, column = 1, kind = .Open_Paren, text = "("},
			Token{line = 1, column = 3, kind = .Close_Paren, text = ")"},
			Token{line = 1, column = 5, kind = .Asterisk, text = "*"},
			Token{line = 1, column = 7, kind = .Semicolon, text = ";"},
			Token{line = 1, column = 9, kind = .Comma, text = ","},
		},
	)
}

@(test)
tokenizer_test_qualified_ident :: proc(t: ^testing.T) {
	_tokenizer_test(
		t,
		"users.id products.name",
		{
			Token{line = 1, column = 1, kind = .Ident, text = "users.id"},
			Token{line = 1, column = 10, kind = .Ident, text = "products.name"},
		},
	)
}

@(test)
tokenizer_test_order_by :: proc(t: ^testing.T) {
	_tokenizer_test(
		t,
		"SELECT * FROM users ORDER BY name",
		{
			Token{line = 1, column = 1, kind = .Select, text = "SELECT"},
			Token{line = 1, column = 8, kind = .Asterisk, text = "*"},
			Token{line = 1, column = 10, kind = .From, text = "FROM"},
			Token{line = 1, column = 15, kind = .Ident, text = "users"},
			Token{line = 1, column = 21, kind = .Order_By, text = "ORDER BY"},
			Token{line = 1, column = 30, kind = .Ident, text = "name"},
		},
	)
}

@(test)
tokenizer_test_as_keyword :: proc(t: ^testing.T) {
	_tokenizer_test(
		t,
		"SELECT age AS years FROM users u",
		{
			Token{line = 1, column = 1, kind = .Select, text = "SELECT"},
			Token{line = 1, column = 8, kind = .Ident, text = "age"},
			Token{line = 1, column = 12, kind = .As, text = "AS"},
			Token{line = 1, column = 15, kind = .Ident, text = "years"},
			Token{line = 1, column = 21, kind = .From, text = "FROM"},
			Token{line = 1, column = 26, kind = .Ident, text = "users"},
			Token{line = 1, column = 32, kind = .Ident, text = "u"},
		},
	)
}

@(test)
tokenizer_test_not_operators :: proc(t: ^testing.T) {
	_tokenizer_test(
		t,
		"NOT IN NOT LIKE NOT BETWEEN",
		{
			Token{line = 1, column = 1, kind = .Not_In, text = "NOT IN"},
			Token{line = 1, column = 8, kind = .Not_Like, text = "NOT LIKE"},
			Token{line = 1, column = 17, kind = .Not_Between, text = "NOT BETWEEN"},
		},
	)
}

@(test)
tokenizer_test_insert :: proc(t: ^testing.T) {
	_tokenizer_test(
		t,
		"INSERT INTO users (name, age) VALUES ('Alice', 25)",
		{
			Token{line = 1, column = 1, kind = .Insert, text = "INSERT"},
			Token{line = 1, column = 8, kind = .Into, text = "INTO"},
			Token{line = 1, column = 13, kind = .Ident, text = "users"},
			Token{line = 1, column = 19, kind = .Open_Paren, text = "("},
			Token{line = 1, column = 20, kind = .Ident, text = "name"},
			Token{line = 1, column = 24, kind = .Comma, text = ","},
			Token{line = 1, column = 26, kind = .Ident, text = "age"},
			Token{line = 1, column = 29, kind = .Close_Paren, text = ")"},
			Token{line = 1, column = 31, kind = .Values, text = "VALUES"},
			Token{line = 1, column = 38, kind = .Open_Paren, text = "("},
			Token{line = 1, column = 39, kind = .String, text = "Alice"},
			Token{line = 1, column = 46, kind = .Comma, text = ","},
			Token{line = 1, column = 48, kind = .Number, text = "25"},
			Token{line = 1, column = 50, kind = .Close_Paren, text = ")"},
		},
	)
}

@(test)
tokenizer_test_update :: proc(t: ^testing.T) {
	_tokenizer_test(
		t,
		"UPDATE users SET age = 30 WHERE id = 5",
		{
			Token{line = 1, column = 1, kind = .Update, text = "UPDATE"},
			Token{line = 1, column = 8, kind = .Ident, text = "users"},
			Token{line = 1, column = 14, kind = .Set, text = "SET"},
			Token{line = 1, column = 18, kind = .Ident, text = "age"},
			Token{line = 1, column = 22, kind = .Equals, text = "="},
			Token{line = 1, column = 24, kind = .Number, text = "30"},
			Token{line = 1, column = 27, kind = .Where, text = "WHERE"},
			Token{line = 1, column = 33, kind = .Ident, text = "id"},
			Token{line = 1, column = 36, kind = .Equals, text = "="},
			Token{line = 1, column = 38, kind = .Number, text = "5"},
		},
	)
}

@(test)
tokenizer_test_delete :: proc(t: ^testing.T) {
	_tokenizer_test(
		t,
		"DELETE FROM users WHERE age < 18",
		{
			Token{line = 1, column = 1, kind = .Delete, text = "DELETE"},
			Token{line = 1, column = 8, kind = .From, text = "FROM"},
			Token{line = 1, column = 13, kind = .Ident, text = "users"},
			Token{line = 1, column = 19, kind = .Where, text = "WHERE"},
			Token{line = 1, column = 25, kind = .Ident, text = "age"},
			Token{line = 1, column = 29, kind = .Less_Than, text = "<"},
			Token{line = 1, column = 31, kind = .Number, text = "18"},
		},
	)
}

@(test)
tokenizer_test_join :: proc(t: ^testing.T) {
	_tokenizer_test(
		t,
		"SELECT * FROM users INNER JOIN orders ON users.id = orders.user_id",
		{
			Token{line = 1, column = 1, kind = .Select, text = "SELECT"},
			Token{line = 1, column = 8, kind = .Asterisk, text = "*"},
			Token{line = 1, column = 10, kind = .From, text = "FROM"},
			Token{line = 1, column = 15, kind = .Ident, text = "users"},
			Token{line = 1, column = 21, kind = .Inner, text = "INNER"},
			Token{line = 1, column = 27, kind = .Join, text = "JOIN"},
			Token{line = 1, column = 32, kind = .Ident, text = "orders"},
			Token{line = 1, column = 39, kind = .On, text = "ON"},
			Token{line = 1, column = 42, kind = .Ident, text = "users.id"},
			Token{line = 1, column = 51, kind = .Equals, text = "="},
			Token{line = 1, column = 53, kind = .Ident, text = "orders.user_id"},
		},
	)
}

@(test)
tokenizer_test_cross_join :: proc(t: ^testing.T) {
	_tokenizer_test(
		t,
		"SELECT * FROM users CROSS JOIN orders",
		{
			Token{line = 1, column = 1, kind = .Select, text = "SELECT"},
			Token{line = 1, column = 8, kind = .Asterisk, text = "*"},
			Token{line = 1, column = 10, kind = .From, text = "FROM"},
			Token{line = 1, column = 15, kind = .Ident, text = "users"},
			Token{line = 1, column = 21, kind = .Cross, text = "CROSS"},
			Token{line = 1, column = 27, kind = .Join, text = "JOIN"},
			Token{line = 1, column = 32, kind = .Ident, text = "orders"},
		},
	)
}

@(test)
tokenizer_test_and_or :: proc(t: ^testing.T) {
	_tokenizer_test(
		t,
		"WHERE age > 18 AND status = 'active' OR role = 'admin'",
		{
			Token{line = 1, column = 1, kind = .Where, text = "WHERE"},
			Token{line = 1, column = 7, kind = .Ident, text = "age"},
			Token{line = 1, column = 11, kind = .Greater_Than, text = ">"},
			Token{line = 1, column = 13, kind = .Number, text = "18"},
			Token{line = 1, column = 16, kind = .And, text = "AND"},
			Token{line = 1, column = 20, kind = .Ident, text = "status"},
			Token{line = 1, column = 27, kind = .Equals, text = "="},
			Token{line = 1, column = 29, kind = .String, text = "active"},
			Token{line = 1, column = 38, kind = .Or, text = "OR"},
			Token{line = 1, column = 41, kind = .Ident, text = "role"},
			Token{line = 1, column = 46, kind = .Equals, text = "="},
			Token{line = 1, column = 48, kind = .String, text = "admin"},
		},
	)
}

@(test)
tokenizer_test_create_table :: proc(t: ^testing.T) {
	_tokenizer_test(
		t,
		"CREATE TABLE users (id PRIMARY KEY, name)",
		{
			Token{line = 1, column = 1, kind = .Create, text = "CREATE"},
			Token{line = 1, column = 8, kind = .Table, text = "TABLE"},
			Token{line = 1, column = 14, kind = .Ident, text = "users"},
			Token{line = 1, column = 20, kind = .Open_Paren, text = "("},
			Token{line = 1, column = 21, kind = .Ident, text = "id"},
			Token{line = 1, column = 24, kind = .Primary, text = "PRIMARY"},
			Token{line = 1, column = 32, kind = .Key, text = "KEY"},
			Token{line = 1, column = 35, kind = .Comma, text = ","},
			Token{line = 1, column = 37, kind = .Ident, text = "name"},
			Token{line = 1, column = 41, kind = .Close_Paren, text = ")"},
		},
	)
}

@(test)
tokenizer_test_create_table_with_columnar_tag :: proc(t: ^testing.T) {
	_tokenizer_test(
		t,
		"CREATE TABLE @columnar users (id PRIMARY KEY, name)",
		{
			Token{line = 1, column = 1, kind = .Create, text = "CREATE"},
			Token{line = 1, column = 8, kind = .Table, text = "TABLE"},
			Token{line = 1, column = 14, kind = .Ident, text = "@columnar"},
			Token{line = 1, column = 24, kind = .Ident, text = "users"},
			Token{line = 1, column = 30, kind = .Open_Paren, text = "("},
			Token{line = 1, column = 31, kind = .Ident, text = "id"},
			Token{line = 1, column = 34, kind = .Primary, text = "PRIMARY"},
			Token{line = 1, column = 42, kind = .Key, text = "KEY"},
			Token{line = 1, column = 45, kind = .Comma, text = ","},
			Token{line = 1, column = 47, kind = .Ident, text = "name"},
			Token{line = 1, column = 51, kind = .Close_Paren, text = ")"},
		},
	)
}

@(test)
tokenizer_test_limit_offset :: proc(t: ^testing.T) {
	_tokenizer_test(
		t,
		"SELECT * FROM users LIMIT 10 OFFSET 20",
		{
			Token{line = 1, column = 1, kind = .Select, text = "SELECT"},
			Token{line = 1, column = 8, kind = .Asterisk, text = "*"},
			Token{line = 1, column = 10, kind = .From, text = "FROM"},
			Token{line = 1, column = 15, kind = .Ident, text = "users"},
			Token{line = 1, column = 21, kind = .Limit, text = "LIMIT"},
			Token{line = 1, column = 27, kind = .Number, text = "10"},
			Token{line = 1, column = 30, kind = .Offset, text = "OFFSET"},
			Token{line = 1, column = 37, kind = .Number, text = "20"},
		},
	)
}

@(test)
tokenizer_test_order_by_with_direction :: proc(t: ^testing.T) {
	_tokenizer_test(
		t,
		"SELECT * FROM users ORDER BY age DESC, name ASC",
		{
			Token{line = 1, column = 1, kind = .Select, text = "SELECT"},
			Token{line = 1, column = 8, kind = .Asterisk, text = "*"},
			Token{line = 1, column = 10, kind = .From, text = "FROM"},
			Token{line = 1, column = 15, kind = .Ident, text = "users"},
			Token{line = 1, column = 21, kind = .Order_By, text = "ORDER BY"},
			Token{line = 1, column = 30, kind = .Ident, text = "age"},
			Token{line = 1, column = 34, kind = .Desc, text = "DESC"},
			Token{line = 1, column = 38, kind = .Comma, text = ","},
			Token{line = 1, column = 40, kind = .Ident, text = "name"},
			Token{line = 1, column = 45, kind = .Asc, text = "ASC"},
		},
	)
}

@(test)
tokenizer_test_group_by_having :: proc(t: ^testing.T) {
	_tokenizer_test(
		t,
		"SELECT user_id, COUNT(*) FROM orders GROUP BY user_id HAVING COUNT(*) > 1",
		{
			Token{line = 1, column = 1, kind = .Select, text = "SELECT"},
			Token{line = 1, column = 8, kind = .Ident, text = "user_id"},
			Token{line = 1, column = 15, kind = .Comma, text = ","},
			Token{line = 1, column = 17, kind = .Ident, text = "COUNT"},
			Token{line = 1, column = 22, kind = .Open_Paren, text = "("},
			Token{line = 1, column = 23, kind = .Asterisk, text = "*"},
			Token{line = 1, column = 24, kind = .Close_Paren, text = ")"},
			Token{line = 1, column = 26, kind = .From, text = "FROM"},
			Token{line = 1, column = 31, kind = .Ident, text = "orders"},
			Token{line = 1, column = 38, kind = .Group_By, text = "GROUP BY"},
			Token{line = 1, column = 47, kind = .Ident, text = "user_id"},
			Token{line = 1, column = 55, kind = .Having, text = "HAVING"},
			Token{line = 1, column = 62, kind = .Ident, text = "COUNT"},
			Token{line = 1, column = 67, kind = .Open_Paren, text = "("},
			Token{line = 1, column = 68, kind = .Asterisk, text = "*"},
			Token{line = 1, column = 69, kind = .Close_Paren, text = ")"},
			Token{line = 1, column = 71, kind = .Greater_Than, text = ">"},
			Token{line = 1, column = 73, kind = .Number, text = "1"},
		},
	)
}

@(test)
tokenizer_test_create_index :: proc(t: ^testing.T) {
	_tokenizer_test(
		t,
		"CREATE INDEX users_age_idx ON users (age)",
		{
			Token{line = 1, column = 1, kind = .Create, text = "CREATE"},
			Token{line = 1, column = 8, kind = .Index, text = "INDEX"},
			Token{line = 1, column = 14, kind = .Ident, text = "users_age_idx"},
			Token{line = 1, column = 28, kind = .On, text = "ON"},
			Token{line = 1, column = 31, kind = .Ident, text = "users"},
			Token{line = 1, column = 37, kind = .Open_Paren, text = "("},
			Token{line = 1, column = 38, kind = .Ident, text = "age"},
			Token{line = 1, column = 41, kind = .Close_Paren, text = ")"},
		},
	)
}

@(test)
tokenizer_test_alter_and_drop_table_keywords :: proc(t: ^testing.T) {
	_tokenizer_test(
		t,
		"ALTER TABLE users ADD COLUMN score INT; DROP TABLE IF EXISTS users",
		{
			Token{line = 1, column = 1, kind = .Alter, text = "ALTER"},
			Token{line = 1, column = 7, kind = .Table, text = "TABLE"},
			Token{line = 1, column = 13, kind = .Ident, text = "users"},
			Token{line = 1, column = 19, kind = .Add, text = "ADD"},
			Token{line = 1, column = 23, kind = .Column, text = "COLUMN"},
			Token{line = 1, column = 30, kind = .Ident, text = "score"},
			Token{line = 1, column = 36, kind = .Ident, text = "INT"},
			Token{line = 1, column = 39, kind = .Semicolon, text = ";"},
			Token{line = 1, column = 41, kind = .Drop, text = "DROP"},
			Token{line = 1, column = 46, kind = .Table, text = "TABLE"},
			Token{line = 1, column = 52, kind = .If, text = "IF"},
			Token{line = 1, column = 55, kind = .Exists, text = "EXISTS"},
			Token{line = 1, column = 62, kind = .Ident, text = "users"},
		},
	)
}

@(test)
tokenizer_test_in_between_like :: proc(t: ^testing.T) {
	_tokenizer_test(
		t,
		"name IN age BETWEEN price LIKE",
		{
			Token{line = 1, column = 1, kind = .Ident, text = "name"},
			Token{line = 1, column = 6, kind = .In, text = "IN"},
			Token{line = 1, column = 9, kind = .Ident, text = "age"},
			Token{line = 1, column = 13, kind = .Between, text = "BETWEEN"},
			Token{line = 1, column = 21, kind = .Ident, text = "price"},
			Token{line = 1, column = 27, kind = .Like, text = "LIKE"},
		},
	)
}

@(test)
tokenizer_test_multiline :: proc(t: ^testing.T) {
	_tokenizer_test(
		t,
		"SELECT *\nFROM users\nWHERE age > 18",
		{
			Token{line = 1, column = 1, kind = .Select, text = "SELECT"},
			Token{line = 1, column = 8, kind = .Asterisk, text = "*"},
			Token{line = 2, column = 1, kind = .From, text = "FROM"},
			Token{line = 2, column = 6, kind = .Ident, text = "users"},
			Token{line = 3, column = 1, kind = .Where, text = "WHERE"},
			Token{line = 3, column = 7, kind = .Ident, text = "age"},
			Token{line = 3, column = 11, kind = .Greater_Than, text = ">"},
			Token{line = 3, column = 13, kind = .Number, text = "18"},
		},
	)
}

@(test)
tokenizer_test_semicolon :: proc(t: ^testing.T) {
	_tokenizer_test(
		t,
		"SELECT * FROM users;",
		{
			Token{line = 1, column = 1, kind = .Select, text = "SELECT"},
			Token{line = 1, column = 8, kind = .Asterisk, text = "*"},
			Token{line = 1, column = 10, kind = .From, text = "FROM"},
			Token{line = 1, column = 15, kind = .Ident, text = "users"},
			Token{line = 1, column = 20, kind = .Semicolon, text = ";"},
		},
	)
}

@(test)
tokenizer_test_complex_query :: proc(t: ^testing.T) {
	_tokenizer_test(
		t,
		"SELECT u.name, o.total FROM users u LEFT JOIN orders o ON u.id = o.user_id WHERE u.age >= 21 AND o.total > 100.50 ORDER BY o.total",
		{
			Token{line = 1, column = 1, kind = .Select, text = "SELECT"},
			Token{line = 1, column = 8, kind = .Ident, text = "u.name"},
			Token{line = 1, column = 14, kind = .Comma, text = ","},
			Token{line = 1, column = 16, kind = .Ident, text = "o.total"},
			Token{line = 1, column = 24, kind = .From, text = "FROM"},
			Token{line = 1, column = 29, kind = .Ident, text = "users"},
			Token{line = 1, column = 35, kind = .Ident, text = "u"},
			Token{line = 1, column = 37, kind = .Left, text = "LEFT"},
			Token{line = 1, column = 42, kind = .Join, text = "JOIN"},
			Token{line = 1, column = 47, kind = .Ident, text = "orders"},
			Token{line = 1, column = 54, kind = .Ident, text = "o"},
			Token{line = 1, column = 56, kind = .On, text = "ON"},
			Token{line = 1, column = 59, kind = .Ident, text = "u.id"},
			Token{line = 1, column = 64, kind = .Equals, text = "="},
			Token{line = 1, column = 66, kind = .Ident, text = "o.user_id"},
			Token{line = 1, column = 76, kind = .Where, text = "WHERE"},
			Token{line = 1, column = 82, kind = .Ident, text = "u.age"},
			Token{line = 1, column = 88, kind = .Gt_Eq, text = ">="},
			Token{line = 1, column = 91, kind = .Number, text = "21"},
			Token{line = 1, column = 94, kind = .And, text = "AND"},
			Token{line = 1, column = 98, kind = .Ident, text = "o.total"},
			Token{line = 1, column = 106, kind = .Greater_Than, text = ">"},
			Token{line = 1, column = 108, kind = .Number, text = "100.50"},
			Token{line = 1, column = 115, kind = .Order_By, text = "ORDER BY"},
			Token{line = 1, column = 124, kind = .Ident, text = "o.total"},
		},
	)
}

@(test)
tokenizer_test_standalone_not :: proc(t: ^testing.T) {
	_tokenizer_test(
		t,
		"NOT TRUE",
		{
			Token{line = 1, column = 1, kind = .Not, text = "NOT"},
			Token{line = 1, column = 5, kind = .True, text = "TRUE"},
		},
	)
}

@(test)
tokenizer_test_arithmetic :: proc(t: ^testing.T) {
	_tokenizer_test(
		t,
		"1 + 2 * 3 / 4",
		{
			Token{line = 1, column = 1, kind = .Number, text = "1"},
			Token{line = 1, column = 3, kind = .Plus, text = "+"},
			Token{line = 1, column = 5, kind = .Number, text = "2"},
			Token{line = 1, column = 7, kind = .Asterisk, text = "*"},
			Token{line = 1, column = 9, kind = .Number, text = "3"},
			Token{line = 1, column = 11, kind = .Slash, text = "/"},
			Token{line = 1, column = 13, kind = .Number, text = "4"},
		},
	)
}


// Characters outside the supported SQL subset must fail cleanly (no panic); tokenizer_errorf records why.
@(test)
tokenizer_test_invalid_char_at :: proc(t: ^testing.T) {
	defer main_finish()
	main_init()
	_, ok := tokenize("SELECT * FROM users WHERE x @ y")
	testing.expect(t, !ok)
}

@(test)
tokenizer_test_invalid_char_backslash :: proc(t: ^testing.T) {
	defer main_finish()
	main_init()
	_, ok := tokenize(`SELECT \`)
	testing.expect(t, !ok)
}

@(test)
tokenizer_test_invalid_char_bracket :: proc(t: ^testing.T) {
	defer main_finish()
	main_init()
	_, ok := tokenize("SELECT [col] FROM t")
	testing.expect(t, !ok)
}

@(test)
toeknizer_test_subquery :: proc(t: ^testing.T) {
	_tokenizer_test(
		t,
		"SELECT * FROM (SELECT name FROM users) WHERE age > 18",
		{
			Token{line = 1, column = 1, kind = .Select, text = "SELECT"},
			Token{line = 1, column = 8, kind = .Asterisk, text = "*"},
			Token{line = 1, column = 10, kind = .From, text = "FROM"},
			Token{line = 1, column = 15, kind = .Open_Paren, text = "("},
			Token{line = 1, column = 16, kind = .Select, text = "SELECT"},
			Token{line = 1, column = 23, kind = .Ident, text = "name"},
			Token{line = 1, column = 28, kind = .From, text = "FROM"},
			Token{line = 1, column = 33, kind = .Ident, text = "users"},
			Token{line = 1, column = 38, kind = .Close_Paren, text = ")"},
			Token{line = 1, column = 40, kind = .Where, text = "WHERE"},
			Token{line = 1, column = 46, kind = .Ident, text = "age"},
			Token{line = 1, column = 50, kind = .Greater_Than, text = ">"},
			Token{line = 1, column = 52, kind = .Number, text = "18"},
		},
	)
}

@(test)
tokenizer_test_transaction_keywords :: proc(t: ^testing.T) {
	_tokenizer_test(
		t,
		"BEGIN COMMIT ROLLBACK",
		{
			Token{line = 1, column = 1, kind = .Begin, text = "BEGIN"},
			Token{line = 1, column = 7, kind = .Commit, text = "COMMIT"},
			Token{line = 1, column = 14, kind = .Rollback, text = "ROLLBACK"},
		},
	)
}
