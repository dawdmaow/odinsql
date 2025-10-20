#+feature dynamic-literals
package main


import "core:log"
import "core:mem"
import "core:mem/virtual"
import "core:testing"

database_test_setup :: proc(db: ^DB) {
	// TODO: passing arena between tests to clear afterwards it is annoying.
	// arena := new(mem.Dynamic_Arena)
	// mem.dynamic_arena_init(arena)
	// allocator := mem.dynamic_arena_allocator(arena)
	// // allocator := context.allocator
	// context.allocator = allocator

	context.allocator = context.temp_allocator

	@(static) column_names := []string{"id", "name", "age", "status"}

	database_init(db)
	table := DB_Table {
		name         = "users",
		column_names = column_names,
		primary_key  = "id",
		rows         = make([dynamic]DB_Row),
	}

	append_elem(&table.rows, DB_Row{"id" = 1, "name" = "Matthew", "age" = 15, "status" = "active"})
	append_elem(&table.rows, DB_Row{"id" = 1, "name" = "John", "age" = 25, "status" = "active"})
	append_elem(&table.rows, DB_Row{"id" = 2, "name" = "Kate", "age" = 30, "status" = "inactive"})
	append_elem(&table.rows, DB_Row{"id" = 2, "name" = "Rose", "age" = 30, "status" = "inactive"})

	db.tables["users"] = table
}

database_test_teardown :: proc(db: ^DB) {
	free_all(db.allocator)
}

// @(test)
// database_test_select_1 :: proc(t: ^testing.T) {
// 	db: DB
// 	database_init(&db)
// 	db.tables["users"] = {
// 		name         = "users",
// 		column_names = []string{"id", "name", "age"},
// 		primary_key  = "id",
// 		rows         = make([dynamic]DB_Row),
// 	}
// 	fields := make(DB_Row)
// 	fields["id"] = DB_Value(1.0)
// 	fields["name"] = "John"
// 	fields["age"] = DB_Value(20.0)
// 	table := &db.tables["users"]
// 	append_elem(&table.rows, fields)
// 	tokens, ok := tokenize("SELECT * FROM users", context.temp_allocator)
// 	testing.expect(t, ok)
// 	p := parser_init(tokens[:])
// 	select, ok2 := parse_select(&p)
// 	testing.expect(t, ok2)
// 	result, ok3 := exec_select(&db, select)
// 	testing.expect(t, ok3)
// 	testing.expect_value(t, len(result), 1)
// 	log.infof("result: %#v", result)
// 	// testing.expect(t, result[0]["id"] == 1.0)
// 	// testing.expect(t, result[0]["name"] == "John")
// 	// testing.expect(t, result[0]["age"] == 20.0)
// }

@(test)
db_test_select_subset_of_columns :: proc(t: ^testing.T) {
	db: DB
	database_test_setup(&db)
	// defer database_test_teardown(&db)
	result, ok := exec_query(&db, "SELECT name, age FROM users")
	testing.expect(t, ok)
	{
		result := result.([dynamic]DB_Row)
		testing.expect_value(t, len(result), 4)
		testing.expect(t, result[0]["name"] == "Matthew")
		testing.expect(t, result[0]["age"] == 15)
		testing.expect(t, result[1]["name"] == "John")
		testing.expect(t, result[1]["age"] == 25)
		testing.expect(t, result[2]["name"] == "Kate")
		testing.expect(t, result[2]["age"] == 30)
		testing.expect(t, result[3]["name"] == "Rose")
		testing.expect(t, result[3]["age"] == 30)
	}
}

@(test)
db_test_select_subset_of_columns_qualified :: proc(t: ^testing.T) {
	db: DB
	database_test_setup(&db)
	defer database_test_teardown(&db)
	result, ok := exec_query(&db, "SELECT users.name, users.age FROM users")
	testing.expect(t, ok)
	{
		result := result.([dynamic]DB_Row)
		testing.expect_value(t, len(result), 4)
		testing.expect(t, result[0]["name"] == "Matthew")
		testing.expect(t, result[0]["age"] == 15)
		testing.expect(t, result[1]["name"] == "John")
		testing.expect(t, result[1]["age"] == 25)
		testing.expect(t, result[2]["name"] == "Kate")
		testing.expect(t, result[2]["age"] == 30)
		testing.expect(t, result[3]["name"] == "Rose")
		testing.expect(t, result[3]["age"] == 30)
	}
}

// // TODO:
// // @(test)
// // db_test_select_subset_of_columns_qualified_invalid_table_name :: proc(t: ^testing.T) {
// // 	db := _example_db()
// // 	result, ok := exec_query(&db, "SELECT users.name, x.age FROM users")
// // 	testing.expect(t, !ok)
// // }

@(test)
db_test_simple_where :: proc(t: ^testing.T) {
	db: DB
	database_test_setup(&db)
	defer database_test_teardown(&db)
	result, ok := exec_query(&db, "SELECT * FROM users WHERE age == 25")
	testing.expect(t, ok)
	{
		result := result.([dynamic]DB_Row)
		testing.expect_value(t, len(result), 1)
		testing.expect_value(t, result[0]["id"], 1)
		testing.expect_value(t, result[0]["name"], "John")
		testing.expect_value(t, result[0]["age"], 25)
		testing.expect_value(t, result[0]["status"], "active")
	}
}

@(test)
db_test_bracket_precedence_1 :: proc(t: ^testing.T) {
	db: DB
	database_test_setup(&db)
	defer database_test_teardown(&db)
	result, ok := exec_query(
		&db,
		"SELECT * FROM users WHERE age > 18 AND (age < 30 OR name = 'John')",
	)
	testing.expect(t, ok)
	{
		result := result.([dynamic]DB_Row)
		testing.expect_value(t, len(result), 1)
		testing.expect_value(t, result[0]["id"], 1)
		testing.expect_value(t, result[0]["name"], "John")
		testing.expect_value(t, result[0]["age"], 25)
		testing.expect_value(t, result[0]["status"], "active")
	}
}

@(test)
db_test_bracket_precedence_2 :: proc(t: ^testing.T) {
	db: DB
	database_test_setup(&db)
	defer database_test_teardown(&db)
	result, ok := exec_query(
		&db,
		"SELECT * FROM users WHERE (age > 18 AND age < 30) OR name = 'John'",
	)
	testing.expect(t, ok)
	{
		result := result.([dynamic]DB_Row)
		testing.expect_value(t, len(result), 1)
		testing.expect_value(t, result[0]["id"], 1)
		testing.expect_value(t, result[0]["name"], "John")
		testing.expect_value(t, result[0]["age"], 25)
		testing.expect_value(t, result[0]["status"], "active")
	}
}

@(test)
db_test_bracket_precedence_3 :: proc(t: ^testing.T) {
	db: DB
	database_test_setup(&db)
	defer database_test_teardown(&db)
	result, ok := exec_query(
		&db,
		"SELECT * FROM users WHERE age > 18 AND (age < 30 OR (name = 'John' AND status = 'active'))",
	)
	testing.expect(t, ok)
	{
		result := result.([dynamic]DB_Row)
		testing.expect_value(t, len(result), 1)
		testing.expect_value(t, result[0]["id"], 1)
		testing.expect_value(t, result[0]["name"], "John")
		testing.expect_value(t, result[0]["age"], 25)
		testing.expect_value(t, result[0]["status"], "active")
	}
}

@(test)
db_test_not_operator :: proc(t: ^testing.T) {
	db: DB
	database_test_setup(&db)
	defer database_test_teardown(&db)
	result, ok := exec_query(&db, "SELECT * FROM users WHERE NOT (age > 18 AND age < 30)")
	testing.expect(t, ok)
	{
		result := result.([dynamic]DB_Row)
		testing.expect_value(t, len(result), 3)
		testing.expect_value(t, result[0]["id"], 1)
		testing.expect_value(t, result[0]["name"], "Matthew")
		testing.expect_value(t, result[0]["age"], 15)
		testing.expect_value(t, result[0]["status"], "active")
		testing.expect_value(t, result[1]["id"], 2)
		testing.expect_value(t, result[1]["name"], "Kate")
		testing.expect_value(t, result[1]["age"], 30)
		testing.expect_value(t, result[1]["status"], "inactive")
		testing.expect_value(t, result[2]["id"], 2)
		testing.expect_value(t, result[2]["name"], "Rose")
		testing.expect_value(t, result[2]["age"], 30)
		testing.expect_value(t, result[2]["status"], "inactive")
	}
}

@(test)
db_test_greater_than_or_equal :: proc(t: ^testing.T) {
	db: DB
	database_test_setup(&db)
	defer database_test_teardown(&db)
	result, ok := exec_query(&db, "SELECT * FROM users WHERE age >= 25")
	testing.expect(t, ok)
	{
		result := result.([dynamic]DB_Row)
		testing.expect_value(t, len(result), 3)
		testing.expect_value(t, result[0]["id"], 1)
		testing.expect_value(t, result[0]["name"], "John")
		testing.expect_value(t, result[0]["age"], 25)
		testing.expect_value(t, result[0]["status"], "active")
		testing.expect_value(t, result[1]["id"], 2)
		testing.expect_value(t, result[1]["name"], "Kate")
		testing.expect_value(t, result[1]["age"], 30)
		testing.expect_value(t, result[1]["status"], "inactive")
		testing.expect_value(t, result[2]["id"], 2)
		testing.expect_value(t, result[2]["name"], "Rose")
		testing.expect_value(t, result[2]["age"], 30)
		testing.expect_value(t, result[2]["status"], "inactive")
	}
}

@(test)
db_test_equals :: proc(t: ^testing.T) {
	db: DB
	database_test_setup(&db)
	defer database_test_teardown(&db)
	result, ok := exec_query(&db, "SELECT * FROM users WHERE age = 30")
	testing.expect(t, ok)
	{
		result := result.([dynamic]DB_Row)
		testing.expect_value(t, len(result), 2)
		testing.expect_value(t, result[0]["id"], 2)
		testing.expect_value(t, result[0]["name"], "Kate")
		testing.expect_value(t, result[0]["age"], 30)
		testing.expect_value(t, result[0]["status"], "inactive")
		testing.expect_value(t, result[1]["id"], 2)
		testing.expect_value(t, result[1]["name"], "Rose")
		testing.expect_value(t, result[1]["age"], 30)
		testing.expect_value(t, result[1]["status"], "inactive")
	}
}

@(test)
db_test_string_comparison :: proc(t: ^testing.T) {
	db: DB
	database_test_setup(&db)
	defer database_test_teardown(&db)
	result, ok := exec_query(&db, "SELECT * FROM users WHERE status = 'active'")
	testing.expect(t, ok)
	{
		result := result.([dynamic]DB_Row)
		testing.expect_value(t, len(result), 2)
		testing.expect_value(t, result[0]["id"], 1)
		testing.expect_value(t, result[0]["name"], "Matthew")
		testing.expect_value(t, result[0]["age"], 15)
		testing.expect_value(t, result[0]["status"], "active")
		testing.expect_value(t, result[1]["id"], 1)
		testing.expect_value(t, result[1]["name"], "John")
		testing.expect_value(t, result[1]["age"], 25)
		testing.expect_value(t, result[1]["status"], "active")
	}
}

@(test)
db_test_not_equals :: proc(t: ^testing.T) {
	db: DB
	database_test_setup(&db)
	defer database_test_teardown(&db)
	result, ok := exec_query(&db, "SELECT * FROM users WHERE name != 'John'")
	testing.expect(t, ok)
	{
		result := result.([dynamic]DB_Row)
		testing.expect_value(t, len(result), 3)
		testing.expect_value(t, result[0]["id"], 1)
		testing.expect_value(t, result[0]["name"], "Matthew")
		testing.expect_value(t, result[0]["age"], 15)
		testing.expect_value(t, result[0]["status"], "active")
		testing.expect_value(t, result[1]["id"], 2)
		testing.expect_value(t, result[1]["name"], "Kate")
		testing.expect_value(t, result[1]["age"], 30)
		testing.expect_value(t, result[1]["status"], "inactive")
		testing.expect_value(t, result[2]["id"], 2)
		testing.expect_value(t, result[2]["name"], "Rose")
		testing.expect_value(t, result[2]["age"], 30)
		testing.expect_value(t, result[2]["status"], "inactive")
	}
}

@(test)
db_test_insert_without_columns :: proc(t: ^testing.T) {
	db: DB
	database_test_setup(&db)
	defer database_test_teardown(&db)
	testing.expect_value(t, len(db.tables["users"].rows), 4)
	result, ok := exec_query(&db, "INSERT INTO users VALUES (3, 'Alice', 28, 'active')")
	testing.expect(t, ok)
	testing.expect_value(t, result.(int), 1)

	testing.expect_value(t, len(db.tables["users"].rows), 5)

	result2, ok2 := exec_query(&db, "SELECT * FROM users")
	testing.expect(t, ok2)
	{
		result := result2.([dynamic]DB_Row)
		testing.expect_value(t, len(result), 5)
		testing.expect_value(t, result[0]["id"], 1)
		testing.expect_value(t, result[0]["name"], "Matthew")
		testing.expect_value(t, result[0]["age"], 15)
		testing.expect_value(t, result[0]["status"], "active")
		testing.expect_value(t, result[1]["id"], 1)
		testing.expect_value(t, result[1]["name"], "John")
		testing.expect_value(t, result[1]["age"], 25)
		testing.expect_value(t, result[1]["status"], "active")
		testing.expect_value(t, result[2]["id"], 2)
		testing.expect_value(t, result[2]["name"], "Kate")
		testing.expect_value(t, result[2]["age"], 30)
		testing.expect_value(t, result[2]["status"], "inactive")
		testing.expect_value(t, result[3]["id"], 2)
		testing.expect_value(t, result[3]["name"], "Rose")
		testing.expect_value(t, result[3]["age"], 30)
		testing.expect_value(t, result[3]["status"], "inactive")
		testing.expect_value(t, result[4]["id"], 3)
		testing.expect_value(t, result[4]["name"], "Alice")
		testing.expect_value(t, result[4]["age"], 28)
		testing.expect_value(t, result[4]["status"], "active")
	}
}

@(test)
db_test_insert_with_columns :: proc(t: ^testing.T) {
	db: DB
	database_test_setup(&db)
	defer database_test_teardown(&db)
	result, ok := exec_query(
		&db,
		"INSERT INTO users (id, name, age, status) VALUES (3, 'Bob', 35, 'inactive')",
	)
	testing.expect(t, ok)
	testing.expect_value(t, result.(int), 1)

	result2, ok2 := exec_query(&db, "SELECT * FROM users")
	testing.expect(t, ok2)
	{
		result := result2.([dynamic]DB_Row)
		testing.expect_value(t, len(result), 5)
		testing.expect_value(t, result[4]["id"], 3)
		testing.expect_value(t, result[4]["name"], "Bob")
		testing.expect_value(t, result[4]["age"], 35)
		testing.expect_value(t, result[4]["status"], "inactive")
	}
}

@(test)
db_test_insert_multiple_rows :: proc(t: ^testing.T) {
	db: DB
	database_test_setup(&db)
	defer database_test_teardown(&db)
	result, ok := exec_query(
		&db,
		"INSERT INTO users VALUES (4, 'Charlie', 22, 'active'), (5, 'Diana', 40, 'inactive')",
	)
	testing.expect(t, ok)
	testing.expect_value(t, result.(int), 2)

	result2, ok2 := exec_query(&db, "SELECT * FROM users")
	testing.expect(t, ok2)
	{
		result := result2.([dynamic]DB_Row)
		testing.expect_value(t, len(result), 6)
		testing.expect_value(t, result[4]["id"], 4)
		testing.expect_value(t, result[4]["name"], "Charlie")
		testing.expect_value(t, result[4]["age"], 22)
		testing.expect_value(t, result[4]["status"], "active")
		testing.expect_value(t, result[5]["id"], 5)
		testing.expect_value(t, result[5]["name"], "Diana")
		testing.expect_value(t, result[5]["age"], 40)
		testing.expect_value(t, result[5]["status"], "inactive")
	}
}

@(test)
db_test_insert_with_subset_of_columns :: proc(t: ^testing.T) {
	db: DB
	database_test_setup(&db)
	defer database_test_teardown(&db)
	result, ok := exec_query(&db, "INSERT INTO users (id, name) VALUES (4, 'Frank')")
	testing.expect(t, ok)
	testing.expect_value(t, result.(int), 1)

	result2, ok2 := exec_query(&db, "SELECT * FROM users")
	testing.expect(t, ok2)
	{
		result := result2.([dynamic]DB_Row)
		testing.expect_value(t, len(result), 5)
		testing.expect_value(t, result[4]["id"], 4)
		testing.expect_value(t, result[4]["name"], "Frank")
		testing.expect_value(t, result[4]["age"], Nil{})
		testing.expect_value(t, result[4]["status"], Nil{})
	}
}

@(test)
db_test_mixed_data_types :: proc(t: ^testing.T) {
	db: DB
	database_test_setup(&db)
	defer database_test_teardown(&db)
	result, ok := exec_query(
		&db,
		"INSERT INTO users (id, name, age, status) VALUES (5, 123, '23', NULL)",
	)
	testing.expect(t, ok)
	result_int, result_int_ok := result.(int)
	testing.expect_value(t, result_int_ok, true)
	testing.expect_value(t, result_int, 1)

	result2, ok2 := exec_query(&db, "SELECT * FROM users")
	testing.expect(t, ok2)
	{
		result := result2.([dynamic]DB_Row)
		testing.expect_value(t, len(result), 5)
		testing.expect_value(t, result[4]["id"], 5)
		testing.expect_value(t, result[4]["name"], 123)
		testing.expect_value(t, result[4]["age"], "23")
		testing.expect_value(t, result[4]["status"], Nil{})
	}
}

@(test)
db_test_update_single_column :: proc(t: ^testing.T) {
	db: DB
	database_test_setup(&db)
	defer database_test_teardown(&db)
	result, ok := exec_query(&db, "UPDATE users SET age = 35 WHERE name = 'John'")
	testing.expect(t, ok)
	testing.expect_value(t, result.(int), 1)

	result2, ok2 := exec_query(&db, "SELECT * FROM users")
	testing.expect(t, ok2)
	{
		result := result2.([dynamic]DB_Row)
		testing.expect_value(t, len(result), 4)
		testing.expect_value(t, result[1]["id"], 1)
		testing.expect_value(t, result[1]["name"], "John")
		testing.expect_value(t, result[1]["age"], 35)
		testing.expect_value(t, result[1]["status"], "active")
	}
}

@(test)
db_test_update_multiple_columns :: proc(t: ^testing.T) {
	db: DB
	database_test_setup(&db)
	defer database_test_teardown(&db)
	result, ok := exec_query(
		&db,
		"UPDATE users SET age = 40, status = 'inactive' WHERE name = 'Kate'",
	)
	testing.expect(t, ok)
	testing.expect_value(t, result.(int), 1)

	result2, ok2 := exec_query(&db, "SELECT * FROM users")
	testing.expect(t, ok2)
	{
		result := result2.([dynamic]DB_Row)
		testing.expect_value(t, len(result), 4)
		testing.expect_value(t, result[2]["id"], 2)
		testing.expect_value(t, result[2]["name"], "Kate")
		testing.expect_value(t, result[2]["age"], 40)
		testing.expect_value(t, result[2]["status"], "inactive")
	}
}

@(test)
db_test_update_without_where :: proc(t: ^testing.T) {
	db: DB
	database_test_setup(&db)
	defer database_test_teardown(&db)
	result, ok := exec_query(&db, "UPDATE users SET status = 'updated'")
	testing.expect(t, ok)
	testing.expect_value(t, result.(int), 4)

	result2, ok2 := exec_query(&db, "SELECT * FROM users")
	testing.expect(t, ok2)
	{
		result := result2.([dynamic]DB_Row)
		testing.expect_value(t, len(result), 4)
		testing.expect_value(t, result[0]["status"], "updated")
		testing.expect_value(t, result[1]["status"], "updated")
		testing.expect_value(t, result[2]["status"], "updated")
		testing.expect_value(t, result[3]["status"], "updated")
	}
}

@(test)
db_test_update_with_complex_where :: proc(t: ^testing.T) {
	db: DB
	database_test_setup(&db)
	defer database_test_teardown(&db)
	result, ok := exec_query(
		&db,
		"UPDATE users SET age = 50 WHERE age > 25 AND status = 'inactive'",
	)
	testing.expect(t, ok)
	testing.expect_value(t, result.(int), 2)

	result2, ok2 := exec_query(&db, "SELECT * FROM users")
	testing.expect(t, ok2)
	{
		result := result2.([dynamic]DB_Row)
		testing.expect_value(t, len(result), 4)
		testing.expect_value(t, result[2]["id"], 2)
		testing.expect_value(t, result[2]["name"], "Kate")
		testing.expect_value(t, result[2]["age"], 50)
		testing.expect_value(t, result[2]["status"], "inactive")
		testing.expect_value(t, result[3]["id"], 2)
		testing.expect_value(t, result[3]["name"], "Rose")
		testing.expect_value(t, result[3]["age"], 50)
		testing.expect_value(t, result[3]["status"], "inactive")
	}
}

@(test)
db_test_update_with_string_value :: proc(t: ^testing.T) {
	db: DB
	database_test_setup(&db)
	defer database_test_teardown(&db)
	result, ok := exec_query(&db, "UPDATE users SET age = '45' WHERE name = 'Matthew'")
	testing.expect(t, ok)
	testing.expect_value(t, result.(int), 1)

	result2, ok2 := exec_query(&db, "SELECT * FROM users")
	testing.expect(t, ok2)
	{
		result := result2.([dynamic]DB_Row)
		testing.expect_value(t, len(result), 4)
		testing.expect_value(t, result[0]["id"], 1)
		testing.expect_value(t, result[0]["name"], "Matthew")
		testing.expect_value(t, result[0]["age"], "45")
		testing.expect_value(t, result[0]["status"], "active")
	}
}


@(test)
db_test_delete_with_where :: proc(t: ^testing.T) {
	db: DB
	database_test_setup(&db)
	defer database_test_teardown(&db)
	result, ok := exec_query(&db, "DELETE FROM users WHERE name = 'John'")
	testing.expect(t, ok)
	testing.expect_value(t, result.(int), 1)

	result2, ok2 := exec_query(&db, "SELECT * FROM users")
	testing.expect(t, ok2)
	{
		result := result2.([dynamic]DB_Row)
		testing.expect_value(t, len(result), 3)
		testing.expect_value(t, result[0]["id"], 1)
		testing.expect_value(t, result[0]["name"], "Matthew")
		testing.expect_value(t, result[1]["id"], 2)
		testing.expect_value(t, result[1]["name"], "Kate")
		testing.expect_value(t, result[2]["id"], 2)
		testing.expect_value(t, result[2]["name"], "Rose")
	}
}

@(test)
db_test_delete_without_where :: proc(t: ^testing.T) {
	db: DB
	database_test_setup(&db)
	defer database_test_teardown(&db)
	result, ok := exec_query(&db, "DELETE FROM users")
	testing.expect(t, ok)
	testing.expect_value(t, result.(int), 4)

	result2, ok2 := exec_query(&db, "SELECT * FROM users")
	testing.expect(t, ok2)
	{
		result := result2.([dynamic]DB_Row)
		testing.expect_value(t, len(result), 0)
	}
}

@(test)
db_test_delete_with_complex_where :: proc(t: ^testing.T) {
	db: DB
	database_test_setup(&db)
	defer database_test_teardown(&db)
	result, ok := exec_query(&db, "DELETE FROM users WHERE age > 25 AND status = 'inactive'")
	testing.expect(t, ok)
	testing.expect_value(t, result.(int), 2)

	result2, ok2 := exec_query(&db, "SELECT * FROM users")
	testing.expect(t, ok2)
	{
		result := result2.([dynamic]DB_Row)
		testing.expect_value(t, len(result), 2)
		testing.expect_value(t, result[0]["id"], 1)
		testing.expect_value(t, result[0]["name"], "Matthew")
		testing.expect_value(t, result[0]["age"], 15)
		testing.expect_value(t, result[0]["status"], "active")
		testing.expect_value(t, result[1]["id"], 1)
		testing.expect_value(t, result[1]["name"], "John")
		testing.expect_value(t, result[1]["age"], 25)
		testing.expect_value(t, result[1]["status"], "active")
	}
}

@(test)
db_test_delete_with_or_condition :: proc(t: ^testing.T) {
	db: DB
	database_test_setup(&db)
	defer database_test_teardown(&db)
	result, ok := exec_query(&db, "DELETE FROM users WHERE name = 'Kate' OR name = 'Rose'")
	testing.expect(t, ok)
	testing.expect_value(t, result.(int), 2)

	result2, ok2 := exec_query(&db, "SELECT * FROM users")
	testing.expect(t, ok2)
	{
		result := result2.([dynamic]DB_Row)
		testing.expect_value(t, len(result), 2)
		testing.expect_value(t, result[0]["id"], 1)
		testing.expect_value(t, result[0]["name"], "Matthew")
		testing.expect_value(t, result[0]["age"], 15)
		testing.expect_value(t, result[0]["status"], "active")
		testing.expect_value(t, result[1]["id"], 1)
		testing.expect_value(t, result[1]["name"], "John")
		testing.expect_value(t, result[1]["age"], 25)
		testing.expect_value(t, result[1]["status"], "active")
	}
}

@(test)
db_test_create_table_without_column_types :: proc(t: ^testing.T) {
	test_db: DB
	database_init(&test_db)
	defer database_test_teardown(&test_db)

	result, ok := exec_query(
		&test_db,
		"CREATE TABLE products (id, name, price, category, primary key(id))",
	)
	testing.expect(t, ok)

	table, table_exists := test_db.tables["products"]
	testing.expect(t, table_exists)
	testing.expect_value(t, table.name, "products")
	testing.expect_value(t, len(table.column_names), 4)
	testing.expect_value(t, table.column_names[0], "id")
	testing.expect_value(t, table.column_names[1], "name")
	testing.expect_value(t, table.column_names[2], "price")
	testing.expect_value(t, table.column_names[3], "category")
	testing.expect_value(t, table.primary_key, "id")
	testing.expect_value(t, len(table.rows), 0)

	result2, ok2 := exec_query(
		&test_db,
		"INSERT INTO products VALUES (1, 'Widget', 9.99, 'Tools')",
	)
	testing.expect(t, ok2)
	testing.expect_value(t, result2.(int), 1)

	result3, ok3 := exec_query(&test_db, "SELECT * FROM products")
	testing.expect(t, ok3)
	{
		result := result3.([dynamic]DB_Row)
		testing.expect_value(t, len(result), 1)
		testing.expect_value(t, result[0]["id"], 1)
		testing.expect_value(t, result[0]["name"], "Widget")
		testing.expect_value(t, result[0]["price"], 9.99)
		testing.expect_value(t, result[0]["category"], "Tools")
	}
}

@(test)
db_test_create_table_with_column_types :: proc(t: ^testing.T) {
	test_db: DB
	database_init(&test_db)
	defer database_test_teardown(&test_db)

	result, ok := exec_query(
		&test_db,
		"CREATE TABLE inventory (item_id INTEGER, description TEXT, quantity INT, primary key(item_id))",
	)
	testing.expect(t, ok)

	table, table_exists := test_db.tables["inventory"]
	testing.expect(t, table_exists)
	testing.expect_value(t, table.name, "inventory")
	testing.expect_value(t, len(table.column_names), 3)
	testing.expect_value(t, table.column_names[0], "item_id")
	testing.expect_value(t, table.column_names[1], "description")
	testing.expect_value(t, table.column_names[2], "quantity")
	testing.expect_value(t, table.primary_key, "item_id")
	testing.expect_value(t, len(table.rows), 0)
}

// TODO:
// @(test)
// db_test_create_table_duplicate_error :: proc(t: ^testing.T) {
// 	test_db: DB
// 	database_init(&test_db)
// 	defer database_test_teardown(&test_db)

// 	result, ok := exec_query(&test_db, "CREATE TABLE test_table (id, name, primary key(id))")
// 	testing.expect(t, ok)

// 	result2, ok2 := exec_query(&test_db, "CREATE TABLE test_table (id, name)")
// 	testing.expect(t, !ok2)
// }

@(test)
db_test_inner_join :: proc(t: ^testing.T) {
	test_db: DB
	database_init(&test_db)
	defer database_test_teardown(&test_db)

	users_table := DB_Table {
		name         = "users",
		column_names = {"id", "name"},
		primary_key  = "id",
		rows         = make([dynamic]DB_Row),
	}
	append_elem(&users_table.rows, DB_Row{"id" = 1, "name" = "Alice"})
	append_elem(&users_table.rows, DB_Row{"id" = 2, "name" = "Bob"})
	append_elem(&users_table.rows, DB_Row{"id" = 3, "name" = "Charlie"})
	test_db.tables["users"] = users_table

	orders_table := DB_Table {
		name         = "orders",
		column_names = {"id", "user_id", "product"},
		primary_key  = "id",
		rows         = make([dynamic]DB_Row),
	}
	append_elem(&orders_table.rows, DB_Row{"id" = 101, "user_id" = 1, "product" = "Widget"})
	append_elem(&orders_table.rows, DB_Row{"id" = 102, "user_id" = 2, "product" = "Gadget"})
	append_elem(&orders_table.rows, DB_Row{"id" = 103, "user_id" = 1, "product" = "Tool"})
	test_db.tables["orders"] = orders_table

	result, ok := exec_query(
		&test_db,
		"SELECT * FROM users JOIN orders ON users.id = orders.user_id",
	)
	testing.expect(t, ok)
	{
		result := result.([dynamic]DB_Row)
		testing.expect_value(t, len(result), 3)
		testing.expect_value(t, result[0]["users.id"], 1)
		testing.expect_value(t, result[0]["users.name"], "Alice")
		testing.expect_value(t, result[0]["orders.id"], 101)
		testing.expect_value(t, result[0]["orders.user_id"], 1)
		testing.expect_value(t, result[0]["orders.product"], "Widget")
		testing.expect_value(t, result[2]["users.id"], 2)
		testing.expect_value(t, result[2]["users.name"], "Bob")
		testing.expect_value(t, result[2]["orders.id"], 102)
		testing.expect_value(t, result[2]["orders.user_id"], 2)
		testing.expect_value(t, result[2]["orders.product"], "Gadget")
		testing.expect_value(t, result[1]["users.id"], 1)
		testing.expect_value(t, result[1]["users.name"], "Alice")
		testing.expect_value(t, result[1]["orders.id"], 103)
		testing.expect_value(t, result[1]["orders.user_id"], 1)
		testing.expect_value(t, result[1]["orders.product"], "Tool")
	}
}

@(test)
db_test_left_join :: proc(t: ^testing.T) {
	test_db: DB
	database_init(&test_db)
	defer database_test_teardown(&test_db)

	users_table := DB_Table {
		name         = "users",
		column_names = {"id", "name"},
		primary_key  = "id",
		rows         = make([dynamic]DB_Row),
	}
	append_elem(&users_table.rows, DB_Row{"id" = 1, "name" = "Alice"})
	append_elem(&users_table.rows, DB_Row{"id" = 2, "name" = "Bob"})
	append_elem(&users_table.rows, DB_Row{"id" = 3, "name" = "Charlie"})
	test_db.tables["users"] = users_table

	orders_table := DB_Table {
		name         = "orders",
		column_names = {"id", "user_id", "product"},
		primary_key  = "id",
		rows         = make([dynamic]DB_Row),
	}
	append_elem(&orders_table.rows, DB_Row{"id" = 101, "user_id" = 1, "product" = "Widget"})
	append_elem(&orders_table.rows, DB_Row{"id" = 102, "user_id" = 2, "product" = "Gadget"})
	test_db.tables["orders"] = orders_table

	result, ok := exec_query(
		&test_db,
		"SELECT * FROM users LEFT JOIN orders ON users.id = orders.user_id",
	)
	testing.expect(t, ok)
	{
		result := result.([dynamic]DB_Row)
		testing.expect_value(t, len(result), 3)
		testing.expect_value(t, result[0]["users.id"], 1)
		testing.expect_value(t, result[0]["users.name"], "Alice")
		testing.expect_value(t, result[0]["orders.id"], 101)
		testing.expect_value(t, result[0]["orders.user_id"], 1)
		testing.expect_value(t, result[0]["orders.product"], "Widget")
		testing.expect_value(t, result[1]["users.id"], 2)
		testing.expect_value(t, result[1]["users.name"], "Bob")
		testing.expect_value(t, result[1]["orders.id"], 102)
		testing.expect_value(t, result[1]["orders.user_id"], 2)
		testing.expect_value(t, result[1]["orders.product"], "Gadget")
		testing.expect_value(t, result[2]["users.id"], 3)
		testing.expect_value(t, result[2]["users.name"], "Charlie")
		testing.expect_value(t, result[2]["orders.id"], Nil{})
		testing.expect_value(t, result[2]["orders.user_id"], Nil{})
		testing.expect_value(t, result[2]["orders.product"], Nil{})
	}
}

@(test)
db_test_join_with_where :: proc(t: ^testing.T) {
	test_db: DB
	database_init(&test_db)
	defer database_test_teardown(&test_db)

	users_table := DB_Table {
		name         = "users",
		column_names = {"id", "name", "age"},
		primary_key  = "id",
		rows         = make([dynamic]DB_Row),
	}
	append_elem(&users_table.rows, DB_Row{"id" = 1, "name" = "Alice", "age" = 25})
	append_elem(&users_table.rows, DB_Row{"id" = 2, "name" = "Bob", "age" = 30})
	test_db.tables["users"] = users_table

	orders_table := DB_Table {
		name         = "orders",
		column_names = {"id", "user_id", "amount"},
		primary_key  = "id",
		rows         = make([dynamic]DB_Row),
	}
	append_elem(&orders_table.rows, DB_Row{"id" = 101, "user_id" = 1, "amount" = 100})
	append_elem(&orders_table.rows, DB_Row{"id" = 102, "user_id" = 2, "amount" = 200})
	test_db.tables["orders"] = orders_table

	result, ok := exec_query(
		&test_db,
		"SELECT * FROM users JOIN orders ON users.id = orders.user_id WHERE users.age > 25",
	)
	testing.expect(t, ok)
	{
		result := result.([dynamic]DB_Row)
		testing.expect_value(t, len(result), 1)
		testing.expect_value(t, result[0]["users.id"], 2)
		testing.expect_value(t, result[0]["users.age"], 30)
		testing.expect_value(t, result[0]["users.name"], "Bob")
		testing.expect_value(t, result[0]["orders.id"], 102)
		testing.expect_value(t, result[0]["orders.user_id"], 2)
		testing.expect_value(t, result[0]["orders.amount"], 200)
	}
}

// TODO:
// @(test)
// db_test_ambiguous_column_in_join :: proc(t: ^testing.T) {
// 	test_db: DB
// 	database_init(&test_db)
// 	defer database_test_teardown(&test_db)

// 	users_table := DB_Table {
// 		name         = "users",
// 		column_names = {"id", "name", "status"},
// 		primary_key  = "id",
// 		rows         = make([dynamic]DB_Row),
// 	}
// 	append_elem(&users_table.rows, DB_Row{"id" = 1, "name" = "Alice", "status" = "active"})
// 	append_elem(&users_table.rows, DB_Row{"id" = 2, "name" = "Bob", "status" = "inactive"})
// 	test_db.tables["users"] = users_table

// 	orders_table := DB_Table {
// 		name         = "orders",
// 		column_names = {"id", "user_id", "status"},
// 		primary_key  = "id",
// 		rows         = make([dynamic]DB_Row),
// 	}
// 	append_elem(&orders_table.rows, DB_Row{"id" = 101, "user_id" = 1, "status" = "pending"})
// 	append_elem(&orders_table.rows, DB_Row{"id" = 102, "user_id" = 2, "status" = "completed"})
// 	test_db.tables["orders"] = orders_table

// 	result, ok := exec_query(
// 		&test_db,
// 		"SELECT status FROM users JOIN orders ON users.id = orders.user_id",
// 	)
// 	testing.expect(t, !ok)

// 	result2, ok2 := exec_query(
// 		&test_db,
// 		"SELECT users.status, orders.status FROM users JOIN orders ON users.id = orders.user_id",
// 	)
// 	testing.expect(t, ok2)
// 	{
// 		result := result2.([dynamic]DB_Row)
// 		testing.expect_value(t, len(result), 2)
// 		testing.expect_value(t, result[0]["users.status"], "active")
// 		testing.expect_value(t, result[0]["orders.status"], "pending")
// 		testing.expect_value(t, result[1]["users.status"], "inactive")
// 		testing.expect_value(t, result[1]["orders.status"], "completed")
// 	}
// }

// TODO:
// @(test)
// db_test_insert_duplicate_primary_key :: proc(t: ^testing.T) {
// 	test_db: DB
// 	database_init(&test_db)
// 	defer database_test_teardown(&test_db)

// 	users_table := DB_Table {
// 		name         = "users",
// 		column_names = {"id", "name", "age"},
// 		primary_key  = "id",
// 		rows         = make([dynamic]DB_Row),
// 	}
// 	append_elem(&users_table.rows, DB_Row{"id" = 1, "name" = "Alice", "age" = 25})
// 	append_elem(&users_table.rows, DB_Row{"id" = 2, "name" = "Bob", "age" = 30})
// 	test_db.tables["users"] = users_table

// 	result, ok := exec_query(&test_db, "INSERT INTO users VALUES (1, 'Charlie', 35)")
// 	testing.expect(t, !ok)

// 	result2, ok2 := exec_query(&test_db, "INSERT INTO users VALUES (3, 'David', 28)")
// 	testing.expect(t, ok2)
// 	testing.expect_value(t, result2.(int), 1)

// 	result3, ok3 := exec_query(&test_db, "SELECT * FROM users WHERE id = 3")
// 	testing.expect(t, ok3)
// 	{
// 		result := result3.([dynamic]DB_Row)
// 		testing.expect_value(t, len(result), 1)
// 		testing.expect_value(t, result[0]["id"], 3)
// 		testing.expect_value(t, result[0]["name"], "David")
// 		testing.expect_value(t, result[0]["age"], 28)
// 	}

// 	result4, ok4 := exec_query(&test_db, "INSERT INTO users (id, name, age) VALUES (2, 'Eve', 22)")
// 	testing.expect(t, !ok4)
// }

// TODO:
// @(test)
// db_test_create_table_without_primary_key :: proc(t: ^testing.T) {
// 	test_db: DB
// 	database_init(&test_db)
// 	defer database_test_teardown(&test_db)

// 	result, ok := exec_query(&test_db, "CREATE TABLE users (name, age)")
// 	testing.expect(t, !ok)
// }

@(test)
db_test_create_table_with_primary_key :: proc(t: ^testing.T) {
	test_db: DB
	database_init(&test_db)
	defer database_test_teardown(&test_db)

	result, ok := exec_query(&test_db, "CREATE TABLE users (name, age, PRIMARY KEY(name))")
	testing.expect(t, ok)

	table, table_exists := test_db.tables["users"]
	testing.expect(t, table_exists)
	testing.expect_value(t, table.name, "users")
	testing.expect_value(t, table.primary_key, "name")
	testing.expect_value(t, len(table.column_names), 2)
	testing.expect_value(t, table.column_names[0], "name")
	testing.expect_value(t, table.column_names[1], "age")
}

// TODO:
// @(test)
// db_test_create_table_primary_key_not_in_columns :: proc(t: ^testing.T) {
// 	test_db: DB
// 	database_init(&test_db)
// 	defer database_test_teardown(&test_db)

// 	result, ok := exec_query(&test_db, "CREATE TABLE users (name, age, PRIMARY KEY(id))")
// 	testing.expect(t, !ok)
// }

@(test)
db_test_null_parsing :: proc(t: ^testing.T) {
	test_db: DB
	database_init(&test_db)
	defer database_test_teardown(&test_db)

	users_table := DB_Table {
		name         = "users",
		column_names = {"id", "name", "age"},
		primary_key  = "id",
		rows         = make([dynamic]DB_Row),
	}
	append_elem(&users_table.rows, DB_Row{"id" = 1, "name" = "Alice", "age" = 25})
	append_elem(&users_table.rows, DB_Row{"id" = 2, "age" = 30})
	append_elem(&users_table.rows, DB_Row{"id" = 3, "name" = "Charlie"})
	test_db.tables["users"] = users_table

	result, ok := exec_query(&test_db, "INSERT INTO users (id, name, age) VALUES (4, NULL, 35)")
	testing.expect(t, ok)
	testing.expect_value(t, result.(int), 1)

	result2, ok2 := exec_query(&test_db, "SELECT * FROM users WHERE id = 4")
	testing.expect(t, ok2)
	{
		result := result2.([dynamic]DB_Row)
		testing.expect_value(t, len(result), 1)
		testing.expect_value(t, result[0]["id"], 4)
		testing.expect_value(t, result[0]["name"], Nil{})
		testing.expect_value(t, result[0]["age"], 35)
	}
}

@(test)
db_test_paranthesis_precedence :: proc(t: ^testing.T) {
	test_db: DB
	database_init(&test_db)
	defer database_test_teardown(&test_db)

	users_table := DB_Table {
		name         = "users",
		column_names = {"id", "name", "age", "status"},
		primary_key  = "id",
		rows         = make([dynamic]DB_Row),
	}
	append_elem(
		&users_table.rows,
		DB_Row{"id" = 1, "name" = "Alice", "age" = 25, "status" = "active"},
	)
	append_elem(
		&users_table.rows,
		DB_Row{"id" = 2, "name" = "Bob", "age" = 30, "status" = "inactive"},
	)
	append_elem(
		&users_table.rows,
		DB_Row{"id" = 3, "name" = "Charlie", "age" = 22, "status" = "active"},
	)
	append_elem(
		&users_table.rows,
		DB_Row{"id" = 4, "name" = "David", "age" = 35, "status" = "pending"},
	)
	test_db.tables["users"] = users_table

	result, ok := exec_query(&test_db, "SELECT * FROM users WHERE (age > 25)")
	testing.expect(t, ok)
	{
		result := result.([dynamic]DB_Row)
		testing.expect_value(t, len(result), 2)
	}

	result2, ok2 := exec_query(
		&test_db,
		"SELECT * FROM users WHERE (age > 25) AND (status = 'active')",
	)
	testing.expect(t, ok2)
	{
		result := result2.([dynamic]DB_Row)
		testing.expect_value(t, len(result), 0)
	}

	result3, ok3 := exec_query(
		&test_db,
		"SELECT * FROM users WHERE (age > 25) OR (status = 'active')",
	)
	testing.expect(t, ok3)
	{
		result := result3.([dynamic]DB_Row)
		testing.expect_value(t, len(result), 4)
	}

	result4, ok4 := exec_query(
		&test_db,
		"SELECT * FROM users WHERE ((age >= 22) AND (age < 35)) OR (name = 'Alice')",
	)
	testing.expect(t, ok4)
	{
		result := result4.([dynamic]DB_Row)
		testing.expect_value(t, len(result), 3)
	}

	result5, ok5 := exec_query(&test_db, "SELECT * FROM users WHERE NOT (age > 25)")
	testing.expect(t, ok5)
	{
		result := result5.([dynamic]DB_Row)
		testing.expect_value(t, len(result), 2)
	}

	result6, ok6 := exec_query(
		&test_db,
		"SELECT * FROM users WHERE ((age > 20) AND (age < 30)) OR ((name = 'David') AND (status = 'pending'))",
	)
	testing.expect(t, ok6)
	{
		result := result6.([dynamic]DB_Row)
		testing.expect_value(t, len(result), 3)
	}
}

@(test)
db_test_in_operator_with_subquery :: proc(t: ^testing.T) {
	test_db: DB
	database_init(&test_db)
	defer database_test_teardown(&test_db)

	users_table := DB_Table {
		name         = "users",
		column_names = {"id", "name", "age", "status"},
		primary_key  = "id",
		rows         = make([dynamic]DB_Row),
	}
	append_elem(
		&users_table.rows,
		DB_Row{"id" = 1, "name" = "Alice", "age" = 25, "status" = "active"},
	)
	append_elem(
		&users_table.rows,
		DB_Row{"id" = 2, "name" = "Bob", "age" = 30, "status" = "inactive"},
	)
	append_elem(
		&users_table.rows,
		DB_Row{"id" = 3, "name" = "Charlie", "age" = 35, "status" = "active"},
	)
	test_db.tables["users"] = users_table

	orders_table := DB_Table {
		name         = "orders",
		column_names = {"id", "user_id", "product"},
		primary_key  = "id",
		rows         = make([dynamic]DB_Row),
	}
	append_elem(&orders_table.rows, DB_Row{"id" = 101, "user_id" = 1, "product" = "Widget"})
	append_elem(&orders_table.rows, DB_Row{"id" = 102, "user_id" = 2, "product" = "Gadget"})
	test_db.tables["orders"] = orders_table

	result, ok := exec_query(
		&test_db,
		"SELECT * FROM users WHERE id IN (SELECT user_id FROM orders)",
	)
	testing.expect(t, ok)
	{
		result := result.([dynamic]DB_Row)
		testing.expect_value(t, len(result), 2)
	}
}

@(test)
db_test_not_in_operator_with_subquery :: proc(t: ^testing.T) {
	test_db: DB
	database_init(&test_db)
	defer database_test_teardown(&test_db)

	users_table := DB_Table {
		name         = "users",
		column_names = {"id", "name", "age", "status"},
		primary_key  = "id",
		rows         = make([dynamic]DB_Row),
	}
	append_elem(
		&users_table.rows,
		DB_Row{"id" = 1, "name" = "Alice", "age" = 25, "status" = "active"},
	)
	append_elem(
		&users_table.rows,
		DB_Row{"id" = 2, "name" = "Bob", "age" = 30, "status" = "inactive"},
	)
	append_elem(
		&users_table.rows,
		DB_Row{"id" = 3, "name" = "Charlie", "age" = 35, "status" = "active"},
	)
	test_db.tables["users"] = users_table

	orders_table := DB_Table {
		name         = "orders",
		column_names = {"id", "user_id", "product"},
		primary_key  = "id",
		rows         = make([dynamic]DB_Row),
	}
	append_elem(&orders_table.rows, DB_Row{"id" = 101, "user_id" = 1, "product" = "Widget"})
	append_elem(&orders_table.rows, DB_Row{"id" = 102, "user_id" = 2, "product" = "Gadget"})
	test_db.tables["orders"] = orders_table

	result, ok := exec_query(
		&test_db,
		"SELECT * FROM users WHERE id NOT IN (SELECT user_id FROM orders)",
	)
	testing.expect(t, ok)
	{
		result := result.([dynamic]DB_Row)
		testing.expect_value(t, len(result), 1)
		testing.expect_value(t, result[0]["id"], 3)
		testing.expect_value(t, result[0]["name"], "Charlie")
	}
}

@(test)
db_test_in_operator_with_complex_subquery :: proc(t: ^testing.T) {
	test_db: DB
	database_init(&test_db)
	defer database_test_teardown(&test_db)

	users_table := DB_Table {
		name         = "users",
		column_names = {"id", "name", "age", "status"},
		primary_key  = "id",
		rows         = make([dynamic]DB_Row),
	}
	append_elem(
		&users_table.rows,
		DB_Row{"id" = 1, "name" = "Alice", "age" = 25, "status" = "active"},
	)
	append_elem(
		&users_table.rows,
		DB_Row{"id" = 2, "name" = "Bob", "age" = 30, "status" = "inactive"},
	)
	append_elem(
		&users_table.rows,
		DB_Row{"id" = 3, "name" = "Charlie", "age" = 35, "status" = "active"},
	)
	append_elem(
		&users_table.rows,
		DB_Row{"id" = 4, "name" = "David", "age" = 40, "status" = "inactive"},
	)
	test_db.tables["users"] = users_table

	orders_table := DB_Table {
		name         = "orders",
		column_names = {"id", "user_id", "amount"},
		primary_key  = "id",
		rows         = make([dynamic]DB_Row),
	}
	append_elem(&orders_table.rows, DB_Row{"id" = 101, "user_id" = 1, "amount" = 100})
	append_elem(&orders_table.rows, DB_Row{"id" = 102, "user_id" = 2, "amount" = 200})
	append_elem(&orders_table.rows, DB_Row{"id" = 103, "user_id" = 1, "amount" = 150})
	test_db.tables["orders"] = orders_table

	result, ok := exec_query(
		&test_db,
		"SELECT * FROM users WHERE id IN (SELECT user_id FROM orders WHERE amount > 100)",
	)
	testing.expect(t, ok)
	{
		result := result.([dynamic]DB_Row)
		testing.expect_value(t, len(result), 2)
	}
}

@(test)
db_test_in_operator_with_empty_subquery :: proc(t: ^testing.T) {
	test_db: DB
	database_init(&test_db)
	defer database_test_teardown(&test_db)

	users_table := DB_Table {
		name         = "users",
		column_names = {"id", "name", "age", "status"},
		primary_key  = "id",
		rows         = make([dynamic]DB_Row),
	}
	append_elem(
		&users_table.rows,
		DB_Row{"id" = 1, "name" = "Alice", "age" = 25, "status" = "active"},
	)
	append_elem(
		&users_table.rows,
		DB_Row{"id" = 2, "name" = "Bob", "age" = 30, "status" = "inactive"},
	)
	test_db.tables["users"] = users_table

	orders_table := DB_Table {
		name         = "orders",
		column_names = {"id", "user_id", "product"},
		primary_key  = "id",
		rows         = make([dynamic]DB_Row),
	}
	test_db.tables["orders"] = orders_table

	result, ok := exec_query(
		&test_db,
		"SELECT * FROM users WHERE id IN (SELECT user_id FROM orders)",
	)
	testing.expect(t, ok)
	{
		result := result.([dynamic]DB_Row)
		testing.expect_value(t, len(result), 0)
	}
}

@(test)
db_test_in_operator_with_value_list :: proc(t: ^testing.T) {
	db: DB
	database_test_setup(&db)
	defer database_test_teardown(&db)

	result, ok := exec_query(&db, "SELECT * FROM users WHERE name IN ('John', 'Kate')")
	testing.expect(t, ok)
	{
		result := result.([dynamic]DB_Row)
		testing.expect_value(t, len(result), 2)
	}
}

@(test)
db_test_not_in_operator_with_value_list :: proc(t: ^testing.T) {
	db: DB
	database_test_setup(&db)
	defer database_test_teardown(&db)

	result, ok := exec_query(&db, "SELECT * FROM users WHERE name NOT IN ('John', 'Kate')")
	testing.expect(t, ok)
	{
		result := result.([dynamic]DB_Row)
		testing.expect_value(t, len(result), 2)
		testing.expect_value(t, result[0]["name"], "Matthew")
		testing.expect_value(t, result[1]["name"], "Rose")
	}
}

// TODO:
// @(test)
// db_test_insert_without_primary_key_value :: proc(t: ^testing.T) {
// 	test_db: DB
// 	database_init(&test_db)
// 	defer database_test_teardown(&test_db)

// 	users_table := DB_Table {
// 		name         = "users",
// 		column_names = {"id", "name", "age", "status"},
// 		primary_key  = "id",
// 		rows         = make([dynamic]DB_Row),
// 	}
// 	test_db.tables["users"] = users_table

// 	result, ok := exec_query(
// 		&test_db,
// 		"INSERT INTO users(name, age, status) VALUES ('Alice', 25, 'active')",
// 	)
// 	testing.expect(t, !ok)

// 	result2, ok2 := exec_query(&test_db, "INSERT INTO users VALUES (NULL, 'Alice', 25, 'active')")
// 	testing.expect(t, !ok2)
// }

@(test)
db_test_like_operator :: proc(t: ^testing.T) {
	test_db: DB
	database_init(&test_db)
	defer database_test_teardown(&test_db)

	users_table := DB_Table {
		name         = "users",
		column_names = {"id", "name", "email"},
		primary_key  = "id",
		rows         = make([dynamic]DB_Row),
	}
	append_elem(
		&users_table.rows,
		DB_Row{"id" = 1, "name" = "Alice", "email" = "alice@example.com"},
	)
	append_elem(&users_table.rows, DB_Row{"id" = 2, "name" = "Bob", "email" = "bob@test.org"})
	append_elem(
		&users_table.rows,
		DB_Row{"id" = 3, "name" = "Charlie", "email" = "charlie@demo.net"},
	)
	test_db.tables["users"] = users_table

	result, ok := exec_query(&test_db, "SELECT * FROM users WHERE name LIKE 'A%'")
	testing.expect(t, ok)
	{
		result := result.([dynamic]DB_Row)
		testing.expect_value(t, len(result), 1)
		testing.expect_value(t, result[0]["id"], 1)
		testing.expect_value(t, result[0]["name"], "Alice")
	}

	result2, ok2 := exec_query(&test_db, "SELECT * FROM users WHERE name LIKE 'B_b'")
	testing.expect(t, ok2)
	{
		result := result2.([dynamic]DB_Row)
		testing.expect_value(t, len(result), 1)
		testing.expect_value(t, result[0]["id"], 2)
		testing.expect_value(t, result[0]["name"], "Bob")
	}

	result3, ok3 := exec_query(&test_db, "SELECT * FROM users WHERE email LIKE '%@example.com'")
	testing.expect(t, ok3)
	{
		result := result3.([dynamic]DB_Row)
		testing.expect_value(t, len(result), 1)
		testing.expect_value(t, result[0]["id"], 1)
	}
}

@(test)
db_test_not_like_operator :: proc(t: ^testing.T) {
	test_db: DB
	database_init(&test_db)
	defer database_test_teardown(&test_db)

	users_table := DB_Table {
		name         = "users",
		column_names = {"id", "name", "email"},
		primary_key  = "id",
		rows         = make([dynamic]DB_Row),
	}
	append_elem(
		&users_table.rows,
		DB_Row{"id" = 1, "name" = "Alice", "email" = "alice@example.com"},
	)
	append_elem(&users_table.rows, DB_Row{"id" = 2, "name" = "Bob", "email" = "bob@test.org"})
	append_elem(
		&users_table.rows,
		DB_Row{"id" = 3, "name" = "Charlie", "email" = "charlie@demo.net"},
	)
	test_db.tables["users"] = users_table

	result, ok := exec_query(&test_db, "SELECT * FROM users WHERE name NOT LIKE 'A%'")
	testing.expect(t, ok)
	{
		result := result.([dynamic]DB_Row)
		testing.expect_value(t, len(result), 2)
	}
}

@(test)
db_test_between_operator :: proc(t: ^testing.T) {
	test_db: DB
	database_init(&test_db)
	defer database_test_teardown(&test_db)

	users_table := DB_Table {
		name         = "users",
		column_names = {"id", "name", "age"},
		primary_key  = "id",
		rows         = make([dynamic]DB_Row),
	}
	append_elem(&users_table.rows, DB_Row{"id" = 1, "name" = "Alice", "age" = 25})
	append_elem(&users_table.rows, DB_Row{"id" = 2, "name" = "Bob", "age" = 30})
	append_elem(&users_table.rows, DB_Row{"id" = 3, "name" = "Charlie", "age" = 35})
	test_db.tables["users"] = users_table

	result, ok := exec_query(&test_db, "SELECT * FROM users WHERE age BETWEEN 25 AND 30")
	testing.expect(t, ok)
	{
		result := result.([dynamic]DB_Row)
		testing.expect_value(t, len(result), 2)
		testing.expect_value(t, result[0]["id"], 1)
		testing.expect_value(t, result[0]["name"], "Alice")
		testing.expect_value(t, result[0]["age"], 25)
		testing.expect_value(t, result[1]["id"], 2)
		testing.expect_value(t, result[1]["name"], "Bob")
		testing.expect_value(t, result[1]["age"], 30)
	}

	result2, ok2 := exec_query(&test_db, "SELECT * FROM users WHERE age NOT BETWEEN 25 AND 30")
	testing.expect(t, ok2)
	{
		result := result2.([dynamic]DB_Row)
		testing.expect_value(t, len(result), 1)
		testing.expect_value(t, result[0]["id"], 3)
		testing.expect_value(t, result[0]["name"], "Charlie")
		testing.expect_value(t, result[0]["age"], 35)
	}
}

// TODO: order independent comparisons

@(test)
db_test_select_subquery_1 :: proc(t: ^testing.T) {
	test_db: DB
	database_test_setup(&test_db)
	defer database_test_teardown(&test_db)

	result, ok := exec_query(&test_db, "SELECT * FROM (SELECT name FROM users WHERE age > 25)")
	testing.expect(t, ok)
	{
		result := result.([dynamic]DB_Row)
		testing.expect_value(t, len(result), 2)
		testing.expect_value(t, result[0]["name"], "Kate")
		testing.expect_value(t, result[1]["name"], "Rose")
	}
}

@(test)
db_test_select_subquery_2 :: proc(t: ^testing.T) {
	test_db: DB
	database_test_setup(&test_db)
	defer database_test_teardown(&test_db)

	result, ok := exec_query(&test_db, "SELECT name FROM (SELECT * FROM users) WHERE age > 25")
	testing.expect(t, ok)
	{
		result := result.([dynamic]DB_Row)
		testing.expect_value(t, len(result), 2)
		testing.expect_value(t, result[0]["name"], "Kate")
		testing.expect_value(t, result[1]["name"], "Rose")
	}
}

@(test)
db_test_select_subquery_3 :: proc(t: ^testing.T) {
	test_db: DB
	database_test_setup(&test_db)
	defer database_test_teardown(&test_db)

	result, ok := exec_query(&test_db, "SELECT name FROM (SELECT * FROM users WHERE age > 25)")
	testing.expect(t, ok)
	{
		result := result.([dynamic]DB_Row)
		testing.expect_value(t, len(result), 2)
		testing.expect_value(t, result[0]["name"], "Kate")
		testing.expect_value(t, result[1]["name"], "Rose")
	}
}

@(test)
db_test_select_subquery_4 :: proc(t: ^testing.T) {
	test_db: DB
	database_test_setup(&test_db)
	defer database_test_teardown(&test_db)

	result, ok := exec_query(
		&test_db,
		"SELECT name FROM (SELECT name, age FROM users) WHERE age > 25",
	)
	testing.expect(t, ok)
	{
		result := result.([dynamic]DB_Row)
		testing.expect_value(t, len(result), 2)
		testing.expect_value(t, result[0]["name"], "Kate")
		testing.expect_value(t, result[1]["name"], "Rose")
	}
}

@(test)
db_test_alt_eq_op :: proc(t: ^testing.T) {
	test_db: DB
	database_test_setup(&test_db)
	defer database_test_teardown(&test_db)

	result, ok := exec_query(&test_db, "SELECT * FROM users WHERE name == 'Kate'")
	testing.expect(t, ok)
	{
		result := result.([dynamic]DB_Row)
		testing.expect_value(t, len(result), 1)
		testing.expect_value(t, result[0]["name"], "Kate")
	}
}

@(test)
db_test_alt_uneq_op :: proc(t: ^testing.T) {
	test_db: DB
	database_test_setup(&test_db)
	defer database_test_teardown(&test_db)

	result, ok := exec_query(
		&test_db,
		"SELECT * FROM users WHERE name <> 'Kate' AND name <> 'Rose' AND name <> 'John'",
	)
	testing.expect(t, ok)
	{
		result := result.([dynamic]DB_Row)
		testing.expect_value(t, len(result), 1)
		testing.expect_value(t, result[0]["name"], "Matthew")
	}
}

@(test)
db_test_subquery_with_multiple_filters :: proc(t: ^testing.T) {
	test_db: DB
	database_test_setup(&test_db)
	defer database_test_teardown(&test_db)

	result, ok := exec_query(
		&test_db,
		"SELECT name, age FROM (SELECT * FROM users WHERE age >= 25 AND status = 'inactive')",
	)
	testing.expect(t, ok)
	{
		result := result.([dynamic]DB_Row)
		testing.expect_value(t, len(result), 2)
		testing.expect_value(t, result[0]["name"], "Kate")
		testing.expect_value(t, result[0]["age"], 30)
		testing.expect_value(t, result[1]["name"], "Rose")
		testing.expect_value(t, result[1]["age"], 30)
	}
}

@(test)
db_test_subquery_column_projection :: proc(t: ^testing.T) {
	test_db: DB
	database_test_setup(&test_db)
	defer database_test_teardown(&test_db)

	result, ok := exec_query(
		&test_db,
		"SELECT * FROM (SELECT name, status FROM users WHERE age > 20)",
	)
	testing.expect(t, ok)
	{
		result := result.([dynamic]DB_Row)
		testing.expect_value(t, len(result), 3)
		testing.expect_value(t, result[0]["name"], "John")
		testing.expect_value(t, result[0]["status"], "active")
		testing.expect_value(t, result[1]["name"], "Kate")
		testing.expect_value(t, result[1]["status"], "inactive")
		testing.expect_value(t, result[2]["name"], "Rose")
		testing.expect_value(t, result[2]["status"], "inactive")
	}
}

@(test)
db_test_subquery_outer_filter_refines_inner :: proc(t: ^testing.T) {
	test_db: DB
	database_test_setup(&test_db)
	defer database_test_teardown(&test_db)

	result, ok := exec_query(
		&test_db,
		"SELECT name FROM (SELECT * FROM users WHERE age >= 25) WHERE status = 'inactive'",
	)
	testing.expect(t, ok)
	{
		result := result.([dynamic]DB_Row)
		testing.expect_value(t, len(result), 2)
		testing.expect_value(t, result[0]["name"], "Kate")
		testing.expect_value(t, result[1]["name"], "Rose")
	}
}

@(test)
db_test_join_with_complex_condition :: proc(t: ^testing.T) {
	test_db: DB
	database_init(&test_db)
	defer database_test_teardown(&test_db)

	_, ok1 := exec_query(&test_db, "CREATE TABLE users (id, name, age, PRIMARY KEY (id))")
	testing.expect(t, ok1)

	_, ok2 := exec_query(&test_db, "CREATE TABLE orders (id, user_id, product, PRIMARY KEY (id))")
	testing.expect(t, ok2)

	_, ok3 := exec_query(&test_db, "INSERT INTO users VALUES (1, 'Kate', 30)")
	testing.expect(t, ok3)

	_, ok4 := exec_query(&test_db, "INSERT INTO users VALUES (2, 'John', 25)")
	testing.expect(t, ok4)

	_, ok5 := exec_query(&test_db, "INSERT INTO orders VALUES (101, 1, 'Mouse')")
	testing.expect(t, ok5)

	_, ok6 := exec_query(&test_db, "INSERT INTO orders VALUES (102, 1, 'Keyboard')")
	testing.expect(t, ok6)

	result, ok := exec_query(
		&test_db,
		"SELECT users.name, orders.product FROM users INNER JOIN orders ON users.id = orders.user_id WHERE users.age >= 30 AND orders.product != 'Keyboard'",
	)
	testing.expect(t, ok)
	{
		result := result.([dynamic]DB_Row)
		testing.expect_value(t, len(result), 1)
		testing.expect_value(t, result[0]["users.name"], "Kate")
		testing.expect_value(t, result[0]["orders.product"], "Mouse")
	}
}

@(test)
db_test_in_with_multiple_values_complex :: proc(t: ^testing.T) {
	test_db: DB
	database_test_setup(&test_db)
	defer database_test_teardown(&test_db)

	result, ok := exec_query(
		&test_db,
		"SELECT name, age FROM users WHERE status IN ('active', 'pending', 'inactive') AND age > 25",
	)
	testing.expect(t, ok)
	{
		result := result.([dynamic]DB_Row)
		testing.expect_value(t, len(result), 2)
		testing.expect_value(t, result[0]["name"], "Kate")
		testing.expect_value(t, result[1]["name"], "Rose")
	}
}

@(test)
db_test_not_in_with_subquery_filter :: proc(t: ^testing.T) {
	test_db: DB
	database_test_setup(&test_db)
	defer database_test_teardown(&test_db)

	result, ok := exec_query(
		&test_db,
		"SELECT name FROM users WHERE status NOT IN ('active') AND age >= 25",
	)
	testing.expect(t, ok)
	{
		result := result.([dynamic]DB_Row)
		testing.expect_value(t, len(result), 2)
		testing.expect_value(t, result[0]["name"], "Kate")
		testing.expect_value(t, result[1]["name"], "Rose")
	}
}

@(test)
db_test_between_with_additional_conditions :: proc(t: ^testing.T) {
	test_db: DB
	database_test_setup(&test_db)
	defer database_test_teardown(&test_db)

	result, ok := exec_query(
		&test_db,
		"SELECT name, age FROM users WHERE age BETWEEN 20 AND 30 AND status = 'active'",
	)
	testing.expect(t, ok)
	{
		result := result.([dynamic]DB_Row)
		testing.expect_value(t, len(result), 1)
		testing.expect_value(t, result[0]["name"], "John")
		testing.expect_value(t, result[0]["age"], 25)
	}
}

@(test)
db_test_complex_or_and_precedence :: proc(t: ^testing.T) {
	test_db: DB
	database_test_setup(&test_db)
	defer database_test_teardown(&test_db)

	result, ok := exec_query(
		&test_db,
		"SELECT name FROM users WHERE (age < 20 OR age > 28) AND status = 'inactive'",
	)
	testing.expect(t, ok)
	{
		result := result.([dynamic]DB_Row)
		testing.expect_value(t, len(result), 2)
		testing.expect_value(t, result[0]["name"], "Kate")
		testing.expect_value(t, result[1]["name"], "Rose")
	}
}

@(test)
db_test_subquery_all_columns_specific_output :: proc(t: ^testing.T) {
	test_db: DB
	database_test_setup(&test_db)
	defer database_test_teardown(&test_db)

	result, ok := exec_query(&test_db, "SELECT id, name FROM (SELECT * FROM users) WHERE age = 25")
	testing.expect(t, ok)
	{
		result := result.([dynamic]DB_Row)
		testing.expect_value(t, len(result), 1)
		testing.expect_value(t, result[0]["id"], 1)
		testing.expect_value(t, result[0]["name"], "John")
	}
}

@(test)
db_test_update_with_complex_where2 :: proc(t: ^testing.T) {
	test_db: DB
	database_test_setup(&test_db)
	defer database_test_teardown(&test_db)

	result, ok := exec_query(
		&test_db,
		"UPDATE users SET status = 'archived' WHERE age > 25 AND status = 'inactive'",
	)
	testing.expect(t, ok)
	testing.expect_value(t, result.(int), 2)

	verify, verify_ok := exec_query(
		&test_db,
		"SELECT name, status FROM users WHERE status = 'archived'",
	)
	testing.expect(t, verify_ok)
	{
		verify := verify.([dynamic]DB_Row)
		testing.expect_value(t, len(verify), 2)
		testing.expect_value(t, verify[0]["name"], "Kate")
		testing.expect_value(t, verify[0]["status"], "archived")
		testing.expect_value(t, verify[1]["name"], "Rose")
		testing.expect_value(t, verify[1]["status"], "archived")
	}
}

@(test)
db_test_delete_with_not_between :: proc(t: ^testing.T) {
	test_db: DB
	database_test_setup(&test_db)
	defer database_test_teardown(&test_db)

	result, ok := exec_query(&test_db, "DELETE FROM users WHERE age NOT BETWEEN 20 AND 29")
	testing.expect(t, ok)
	testing.expect_value(t, result.(int), 3)

	verify, verify_ok := exec_query(&test_db, "SELECT name FROM users")
	testing.expect(t, verify_ok)
	{
		verify := verify.([dynamic]DB_Row)
		testing.expect_value(t, len(verify), 1)
		testing.expect_value(t, verify[0]["name"], "John")
	}
}

@(test)
db_test_left_join_with_like_filter :: proc(t: ^testing.T) {
	db: DB
	database_init(&db)
	defer free_all(db.allocator)

	_, ok1 := exec_query(&db, "CREATE TABLE users (id, name, PRIMARY KEY (id))")
	testing.expect(t, ok1)

	_, ok2 := exec_query(&db, "CREATE TABLE orders (id, user_id, product, PRIMARY KEY (id))")
	testing.expect(t, ok2)

	_, ok3 := exec_query(&db, "INSERT INTO users VALUES (1, 'Kate')")
	testing.expect(t, ok3)

	_, ok4 := exec_query(&db, "INSERT INTO users VALUES (2, 'Rose')")
	testing.expect(t, ok4)

	_, ok5 := exec_query(&db, "INSERT INTO users VALUES (3, 'John')")
	testing.expect(t, ok5)

	_, ok6 := exec_query(&db, "INSERT INTO orders VALUES (101, 1, 'Mouse')")
	testing.expect(t, ok6)

	result, ok := exec_query(
		&db,
		"SELECT users.name, orders.product FROM users LEFT JOIN orders ON users.id = orders.user_id WHERE users.name LIKE 'K%' OR users.name LIKE 'R%'",
	)
	testing.expect(t, ok)
	{
		result := result.([dynamic]DB_Row)
		testing.expect_value(t, len(result), 2)
		testing.expect_value(t, result[0]["users.name"], "Kate")
		testing.expect_value(t, result[0]["orders.product"], "Mouse")
		testing.expect_value(t, result[1]["users.name"], "Rose")
		testing.expect_value(t, result[1]["orders.product"], Nil{})
	}
}
