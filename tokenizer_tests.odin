package main

import "core:mem"
import "core:slice"
import "core:testing"

tokenizer_simple_test :: proc(t: ^testing.T, query: string, expected: []Token) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)

	allocator := mem.dynamic_arena_allocator(&arena)
	tokens, ok := tokenize(query, allocator)
	testing.expect(t, ok)
	testing.expectf(t, slice.equal(tokens[:], expected), "%#v", tokens)
}

@(test)
tokenizer_test_1 :: proc(t: ^testing.T) {
	tokenizer_simple_test(
		t,
		"SELECT * FROM users",
		[]Token {
			Token{line = 1, column = 1, kind = .Select, text = "SELECT"},
			Token{line = 1, column = 8, kind = .Asterisk, text = "*"},
			Token{line = 1, column = 10, kind = .From, text = "FROM"},
			Token{line = 1, column = 15, kind = .Ident, text = "users"},
		},
	)
}

@(test)
tokenizer_test_2 :: proc(t: ^testing.T) {
	tokenizer_simple_test(
		t,
		"SELECT * FROM users WHERE age > 18",
		[]Token {
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
tokenizer_test_numbers :: proc(t: ^testing.T) {
	tokenizer_simple_test(
		t,
		"42 3.14 0 100.5",
		[]Token {
			Token{line = 1, column = 1, kind = .Number, text = "42"},
			Token{line = 1, column = 4, kind = .Number, text = "3.14"},
			Token{line = 1, column = 9, kind = .Number, text = "0"},
			Token{line = 1, column = 11, kind = .Number, text = "100.5"},
		},
	)
}

@(test)
tokenizer_test_strings :: proc(t: ^testing.T) {
	tokenizer_simple_test(
		t,
		"'hello' \"world\" 'John Doe'",
		[]Token {
			Token{line = 1, column = 1, kind = .String, text = "hello"},
			Token{line = 1, column = 9, kind = .String, text = "world"},
			Token{line = 1, column = 17, kind = .String, text = "John Doe"},
		},
	)
}

@(test)
tokenizer_test_operators :: proc(t: ^testing.T) {
	tokenizer_simple_test(
		t,
		"= != < > <= >=",
		[]Token {
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
	tokenizer_simple_test(
		t,
		"( ) * ; ,",
		[]Token {
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
	tokenizer_simple_test(
		t,
		"users.id products.name",
		[]Token {
			Token{line = 1, column = 1, kind = .Ident, text = "users.id"},
			Token{line = 1, column = 10, kind = .Ident, text = "products.name"},
		},
	)
}

@(test)
tokenizer_test_order_by :: proc(t: ^testing.T) {
	tokenizer_simple_test(
		t,
		"SELECT * FROM users ORDER BY name",
		[]Token {
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
tokenizer_test_not_operators :: proc(t: ^testing.T) {
	tokenizer_simple_test(
		t,
		"NOT IN NOT LIKE NOT BETWEEN",
		[]Token {
			Token{line = 1, column = 1, kind = .Not_In, text = "NOT IN"},
			Token{line = 1, column = 8, kind = .Not_Like, text = "NOT LIKE"},
			Token{line = 1, column = 17, kind = .Not_Between, text = "NOT BETWEEN"},
		},
	)
}

@(test)
tokenizer_test_insert :: proc(t: ^testing.T) {
	tokenizer_simple_test(
		t,
		"INSERT INTO users (name, age) VALUES ('Alice', 25)",
		[]Token {
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
	tokenizer_simple_test(
		t,
		"UPDATE users SET age = 30 WHERE id = 5",
		[]Token {
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
	tokenizer_simple_test(
		t,
		"DELETE FROM users WHERE age < 18",
		[]Token {
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
	tokenizer_simple_test(
		t,
		"SELECT * FROM users INNER JOIN orders ON users.id = orders.user_id",
		[]Token {
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
tokenizer_test_and_or :: proc(t: ^testing.T) {
	tokenizer_simple_test(
		t,
		"WHERE age > 18 AND status = 'active' OR role = 'admin'",
		[]Token {
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
	tokenizer_simple_test(
		t,
		"CREATE TABLE users (id PRIMARY KEY, name)",
		[]Token {
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
tokenizer_test_limit_offset :: proc(t: ^testing.T) {
	tokenizer_simple_test(
		t,
		"SELECT * FROM users LIMIT 10 OFFSET 20",
		[]Token {
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
tokenizer_test_in_between_like :: proc(t: ^testing.T) {
	tokenizer_simple_test(
		t,
		"name IN age BETWEEN price LIKE",
		[]Token {
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
	tokenizer_simple_test(
		t,
		"SELECT *\nFROM users\nWHERE age > 18",
		[]Token {
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
	tokenizer_simple_test(
		t,
		"SELECT * FROM users;",
		[]Token {
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
	tokenizer_simple_test(
		t,
		"SELECT u.name, o.total FROM users u LEFT JOIN orders o ON u.id = o.user_id WHERE u.age >= 21 AND o.total > 100.50 ORDER BY o.total",
		[]Token {
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
	tokenizer_simple_test(
		t,
		"NOT TRUE",
		[]Token {
			Token{line = 1, column = 1, kind = .Not, text = "NOT"},
			Token{line = 1, column = 5, kind = .True, text = "TRUE"},
		},
	)
}

@(test)
tokenizer_test_arithmetic :: proc(t: ^testing.T) {
	tokenizer_simple_test(
		t,
		"1 + 2 * 3 / 4",
		[]Token {
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


@(test)
toeknizer_test_subquery :: proc(t: ^testing.T) {
	tokenizer_simple_test(
		t,
		"SELECT * FROM (SELECT name FROM users) WHERE age > 18",
		[]Token {
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
