#+build !js
#+vet explicit-allocators

package main

import "core:slice"
import "core:strings"
import "core:testing"

@(private)
rows_cell :: proc(r: Rows_With_Names, row_i: int, col: string) -> Database_Value {
	idx, ok := slice.linear_search(r.column_names[:], col)
	assert(ok)
	return r.rows[row_i][idx]
}

@(private)
database_tests_clear :: proc() {
	database_tables_clear()
}

@(private)
set_database_tables :: proc(tables: ..Table) {
	database_tables_clear() // TODO: why?
	for table in tables {
		ok := database_tables_append(table)
		assert(ok)
	}
}

@(private)
must_insert_row :: proc(table: ^Table, column_names: []string, row: []Database_Value) {
	ok := database_insert_row(table, column_names, row)
	assert(ok)
}

Testing_Table_Prototype :: struct #all_or_none {
	name:                     string,
	column_names:             []string,
	primary_key_column_index: int,
	rows:                     [][]Database_Value,
}

testing_prepare_database :: proc(table_prototypes: ..Testing_Table_Prototype) {
	tables := make([dynamic]Table, database_query_allocator)
	for table_prototype in table_prototypes {
		table: Table
		column_names := make([dynamic]string, context.allocator)
		append_elems(&column_names, ..table_prototype.column_names)
		table_init(
			&table,
			name = table_prototype.name, // TODO: isnt this deallocated in destroy_table?
			column_names = column_names,
			primary_key_column_index = table_prototype.primary_key_column_index,
		)
		for row in table_prototype.rows {
			must_insert_row(&table, column_names[:], row)
		}
		ensure(database_tables_append(table))
	}
}

@(private)
seed_database :: proc() {
	// TODO: passing arena between tests to clear afterwards it is annoying.
	// arena := new(mem.Dynamic_Arena)
	// mem.dynamic_arena_init(arena)
	// allocator := mem.dynamic_arena_allocator(arena)
	// // allocator := context.allocator
	// context.allocator = allocator

	column_names := make([dynamic]string, context.allocator)
	append_elems(&column_names, ..[]string{"id", "name", "age", "status"})
	assert(len(column_names) == 4)

	// table := Table {
	// 	name                     = "users",
	// 	column_names             = column_names,
	// 	primary_key_column_index = 0,
	// }
	// table_init(&table, allocator)
	table: Table
	table_init(&table, name = "users", column_names = column_names, primary_key_column_index = 0)

	must_insert_row(
		&table,
		column_names[:],
		[]Database_Value{1, database_string_make("Matthew"), 15, database_string_make("active")},
	)
	must_insert_row(
		&table,
		column_names[:],
		[]Database_Value{2, database_string_make("John"), 25, database_string_make("active")},
	)
	must_insert_row(
		&table,
		column_names[:],
		[]Database_Value{3, database_string_make("Kate"), 30, database_string_make("inactive")},
	)
	must_insert_row(
		&table,
		column_names[:],
		[]Database_Value{4, database_string_make("Rose"), 30, database_string_make("inactive")},
	)

	set_database_tables(table)
}

// TODO: consider table creation and row insertion for database preparation in tests only using SQL statements.

@(test)
db_select_asterisk :: proc(t: ^testing.T) {
	testing_run_query(t, "SELECT * FROM users", nil, proc() {
		testing_prepare_database(
			{
				name = "users",
				column_names = {"id", "name", "age", "status"},
				primary_key_column_index = 0,
				rows = {
					{1, database_string_make("Matthew"), 15, database_string_make("active")},
					{2, database_string_make("John"), 25, database_string_make("active")},
					{3, database_string_make("Kate"), 30, database_string_make("inactive")},
					{4, database_string_make("Rose"), 30, database_string_make("inactive")},
				},
			},
		)
	}, proc(t: ^testing.T, result: Exec_Result, user_data: rawptr) {
		testing_compare_rows_UNordered(
			t,
			result.result.(Rows_With_Names),
			{"id", "name", "age", "status"},
			{
				{1, database_string_make("Matthew"), 15, database_string_make("active")},
				{2, database_string_make("John"), 25, database_string_make("active")},
				{3, database_string_make("Kate"), 30, database_string_make("inactive")},
				{4, database_string_make("Rose"), 30, database_string_make("inactive")},
			},
		)
	})
}

@(test)
db_test_select_subset_of_columns :: proc(t: ^testing.T) {
	testing_run_query(t, "SELECT name, age FROM users", nil, proc() {
		testing_prepare_database(
			{
				name = "users",
				column_names = {"id", "name", "age", "status"},
				primary_key_column_index = 0,
				rows = {
					{1, database_string_make("Matthew"), 15, database_string_make("active")},
					{2, database_string_make("John"), 25, database_string_make("active")},
					{3, database_string_make("Kate"), 30, database_string_make("inactive")},
					{4, database_string_make("Rose"), 30, database_string_make("inactive")},
				},
			},
		)
	}, proc(t: ^testing.T, result: Exec_Result, user_data: rawptr) {
		testing_compare_rows_UNordered(
			t,
			result.result.(Rows_With_Names),
			{"name", "age"},
			{
				{database_string_make("Matthew"), 15},
				{database_string_make("John"), 25},
				{database_string_make("Kate"), 30},
				{database_string_make("Rose"), 30},
			},
		)
	})
}

@(test)
db_test_select_arithmetic_projection :: proc(t: ^testing.T) {
	testing_run_query(t, "SELECT id+1 FROM users", nil, proc() {
		testing_prepare_database(
			{
				name = "users",
				column_names = {"id", "name", "age", "status"},
				primary_key_column_index = 0,
				rows = {
					{1, database_string_make("Matthew"), 15, database_string_make("active")},
					{2, database_string_make("John"), 25, database_string_make("active")},
					{3, database_string_make("Kate"), 30, database_string_make("inactive")},
					{4, database_string_make("Rose"), 30, database_string_make("inactive")},
				},
			},
		)
	}, proc(t: ^testing.T, result: Exec_Result, user_data: rawptr) {
		testing_compare_rows_UNordered(
			t,
			result.result.(Rows_With_Names),
			{"id+1"},
			{{2}, {3}, {4}, {5}},
		)
	})
}

@(test)
db_test_select_projection_with_parenthesized_arithmetic :: proc(t: ^testing.T) {
	testing_run_query(t, "SELECT id, (id+1)*2 FROM users;", nil, proc() {
		testing_prepare_database(
			{
				name = "users",
				column_names = {"id", "name", "age", "status"},
				primary_key_column_index = 0,
				rows = {
					{1, database_string_make("Matthew"), 15, database_string_make("active")},
					{2, database_string_make("John"), 25, database_string_make("active")},
					{3, database_string_make("Kate"), 30, database_string_make("inactive")},
					{4, database_string_make("Rose"), 30, database_string_make("inactive")},
				},
			},
		)
	}, proc(t: ^testing.T, result: Exec_Result, user_data: rawptr) {
		testing_compare_rows_UNordered(
			t,
			result.result.(Rows_With_Names),
			{"id", "(id+1)*2"},
			{{1, 4}, {2, 6}, {3, 8}, {4, 10}},
		)
	})
}

@(test)
db_test_select_mixed_projection_expression_name :: proc(t: ^testing.T) {
	testing_run_query(t, "SELECT id+1,id,name FROM users;", nil, proc() {
		testing_prepare_database(
			{
				name = "users",
				column_names = {"id", "name", "age", "status"},
				primary_key_column_index = 0,
				rows = {
					{1, database_string_make("Matthew"), 15, database_string_make("active")},
					{2, database_string_make("John"), 25, database_string_make("active")},
					{3, database_string_make("Kate"), 30, database_string_make("inactive")},
					{4, database_string_make("Rose"), 30, database_string_make("inactive")},
				},
			},
		)
	}, proc(t: ^testing.T, result: Exec_Result, user_data: rawptr) {
		testing_compare_rows_UNordered(
			t,
			result.result.(Rows_With_Names),
			{"id+1", "id", "name"},
			{
				{2, 1, database_string_make("Matthew")},
				{3, 2, database_string_make("John")},
				{4, 3, database_string_make("Kate")},
				{5, 4, database_string_make("Rose")},
			},
		)
	})
}

@(test)
db_test_select_subset_of_columns_qualified :: proc(t: ^testing.T) {
	testing_run_query(t, "SELECT users.name, users.age FROM users", nil, proc() {
		testing_prepare_database(
			{
				name = "users",
				column_names = {"id", "name", "age", "status"},
				primary_key_column_index = 0,
				rows = {
					{1, database_string_make("Matthew"), 15, database_string_make("active")},
					{2, database_string_make("John"), 25, database_string_make("active")},
					{3, database_string_make("Kate"), 30, database_string_make("inactive")},
					{4, database_string_make("Rose"), 30, database_string_make("inactive")},
				},
			},
		)
	}, proc(t: ^testing.T, result: Exec_Result, user_data: rawptr) {
		testing_compare_rows_UNordered(
			t,
			result.result.(Rows_With_Names),
			{"users.name", "users.age"},
			{
				{database_string_make("Matthew"), 15},
				{database_string_make("John"), 25},
				{database_string_make("Kate"), 30},
				{database_string_make("Rose"), 30},
			},
		)
	})
}

@(test)
db_test_select_projection_aliases_are_used_as_output_names :: proc(t: ^testing.T) {
	testing_run_query(t, "SELECT id AS user_id, age years FROM users ORDER BY id", nil, proc() {
		testing_prepare_database(
			{
				name = "users",
				column_names = {"id", "name", "age", "status"},
				primary_key_column_index = 0,
				rows = {
					{1, database_string_make("Matthew"), 15, database_string_make("active")},
					{2, database_string_make("John"), 25, database_string_make("active")},
					{3, database_string_make("Kate"), 30, database_string_make("inactive")},
					{4, database_string_make("Rose"), 30, database_string_make("inactive")},
				},
			},
		)
	}, proc(t: ^testing.T, result: Exec_Result, user_data: rawptr) {
		testing_compare_rows_UNordered(
			t,
			result.result.(Rows_With_Names),
			{"user_id", "years"},
			{{1, 15}, {2, 25}, {3, 30}, {4, 30}},
		)
	})
}

@(test)
db_test_join_aliases_resolve_in_select_and_on :: proc(t: ^testing.T) {
	testing_run_query(
		t,
		"SELECT u.name AS username, o.product FROM users AS u JOIN orders o ON u.id = o.user_id ORDER BY u.id, o.id",
		nil,
		proc() {
			testing_prepare_database(
				{
					name = "users",
					column_names = {"id", "name", "age", "status"},
					primary_key_column_index = 0,
					rows = {
						{1, database_string_make("Matthew"), 15, database_string_make("active")},
						{2, database_string_make("John"), 25, database_string_make("active")},
						{3, database_string_make("Kate"), 30, database_string_make("inactive")},
						{4, database_string_make("Rose"), 30, database_string_make("inactive")},
					},
				},
				{
					name = "orders",
					column_names = {"id", "user_id", "product"},
					primary_key_column_index = 0,
					rows = {
						{104, 1, database_string_make("X-Ray")},
						{101, 1, database_string_make("Widget")},
						{102, 2, database_string_make("Gadget")},
						{103, 1, database_string_make("Tool")},
					},
				},
			)
		},
		proc(t: ^testing.T, result: Exec_Result, user_data: rawptr) {
			rows := result.result.(Rows_With_Names)
			testing_compare_rows_ordered(
				t,
				rows,
				{"username", "o.product"},
				{
					{database_string_make("Matthew"), database_string_make("Widget")},
					{database_string_make("Matthew"), database_string_make("Tool")},
					{database_string_make("Matthew"), database_string_make("X-Ray")},
					{database_string_make("John"), database_string_make("Gadget")},
				},
			)
		},
	)
}

@(test)
db_test_simple_where :: proc(t: ^testing.T) {
	testing_run_query(t, "SELECT id FROM users WHERE age == 25", nil, proc() {
		testing_prepare_database(
			{
				name = "users",
				column_names = {"id", "name", "age", "status"},
				primary_key_column_index = 0,
				rows = {
					{1, database_string_make("Matthew"), 15, database_string_make("active")},
					{2, database_string_make("John"), 25, database_string_make("active")},
					{3, database_string_make("Kate"), 30, database_string_make("inactive")},
					{4, database_string_make("Rose"), 30, database_string_make("inactive")},
				},
			},
		)
	}, proc(t: ^testing.T, result: Exec_Result, user_data: rawptr) {
		testing_compare_rows_UNordered(t, result.result.(Rows_With_Names), {"id"}, {{2}})
	})
}

@(test)
db_test_bracket_precedence_1 :: proc(t: ^testing.T) {
	testing_run_query(
		t,
		"SELECT id FROM users WHERE age > 18 AND (age < 30 OR name = 'John')",
		nil,
		proc() {
			testing_prepare_database(
				{
					name = "users",
					column_names = {"id", "name", "age", "status"},
					primary_key_column_index = 0,
					rows = {
						{1, database_string_make("Matthew"), 15, database_string_make("active")},
						{2, database_string_make("John"), 25, database_string_make("active")},
						{3, database_string_make("Kate"), 30, database_string_make("inactive")},
						{4, database_string_make("Rose"), 30, database_string_make("inactive")},
					},
				},
			)
		},
		proc(t: ^testing.T, result: Exec_Result, user_data: rawptr) {
			testing_compare_rows_UNordered(t, result.result.(Rows_With_Names), {"id"}, {{2}})
		},
	)
}

@(test)
db_test_bracket_precedence_2 :: proc(t: ^testing.T) {
	testing_run_query(
		t,
		"SELECT id FROM users WHERE (age > 18 AND age <= 30) OR name = 'John'",
		nil,
		proc() {
			testing_prepare_database(
				{
					name = "users",
					column_names = {"id", "name", "age", "status"},
					primary_key_column_index = 0,
					rows = {
						{1, database_string_make("Matthew"), 15, database_string_make("active")},
						{2, database_string_make("John"), 25, database_string_make("active")},
						{3, database_string_make("Kate"), 30, database_string_make("inactive")},
						{4, database_string_make("Rose"), 35, database_string_make("inactive")},
					},
				},
			)
		},
		proc(t: ^testing.T, result: Exec_Result, user_data: rawptr) {
			res := result.result.(Rows_With_Names)
			testing_compare_rows_UNordered(t, res, {"id"}, {{2}, {3}})
		},
	)
}

@(test)
db_test_bracket_precedence_3 :: proc(t: ^testing.T) {
	testing_run_query(
		t,
		"SELECT * FROM users WHERE age > 18 AND (age < 30 OR (name = 'John' AND status = 'active'))",
		nil,
		proc() {
			testing_prepare_database(
				{
					name = "users",
					column_names = {"id", "name", "age", "status"},
					primary_key_column_index = 0,
					rows = {
						{1, database_string_make("Matthew"), 15, database_string_make("active")},
						{2, database_string_make("John"), 25, database_string_make("active")},
						{3, database_string_make("Kate"), 30, database_string_make("inactive")},
						{4, database_string_make("Rose"), 30, database_string_make("inactive")},
					},
				},
			)
		},
		proc(t: ^testing.T, result: Exec_Result, user_data: rawptr) {
			testing_compare_rows_UNordered(
				t,
				result.result.(Rows_With_Names),
				{"id", "name", "age", "status"},
				{{2, database_string_make("John"), 25, database_string_make("active")}},
			)
		},
	)
}

@(test)
db_test_not_operator :: proc(t: ^testing.T) {
	testing_run_query(t, "SELECT * FROM users WHERE NOT (age > 18 AND age < 30)", nil, proc() {
		testing_prepare_database(
			{
				name = "users",
				column_names = {"id", "name", "age", "status"},
				primary_key_column_index = 0,
				rows = {
					{1, database_string_make("Matthew"), 15, database_string_make("active")},
					{2, database_string_make("John"), 25, database_string_make("active")},
					{3, database_string_make("Kate"), 30, database_string_make("inactive")},
					{4, database_string_make("Rose"), 30, database_string_make("inactive")},
				},
			},
		)
	}, proc(t: ^testing.T, result: Exec_Result, user_data: rawptr) {
		testing_compare_rows_UNordered(
			t,
			result.result.(Rows_With_Names),
			{"id", "name", "age", "status"},
			{
				{1, database_string_make("Matthew"), 15, database_string_make("active")},
				{3, database_string_make("Kate"), 30, database_string_make("inactive")},
				{4, database_string_make("Rose"), 30, database_string_make("inactive")},
			},
		)
	})
}

@(test)
db_test_greater_than_or_equal :: proc(t: ^testing.T) {
	testing_run_query(t, "SELECT * FROM users WHERE age >= 25", nil, proc() {
		testing_prepare_database(
			{
				name = "users",
				column_names = {"id", "name", "age", "status"},
				primary_key_column_index = 0,
				rows = {
					{1, database_string_make("Matthew"), 15, database_string_make("active")},
					{2, database_string_make("John"), 25, database_string_make("active")},
					{3, database_string_make("Kate"), 30, database_string_make("inactive")},
					{4, database_string_make("Rose"), 30, database_string_make("inactive")},
				},
			},
		)
	}, proc(t: ^testing.T, result: Exec_Result, user_data: rawptr) {
		testing_compare_rows_UNordered(
			t,
			result.result.(Rows_With_Names),
			{"id", "name", "age", "status"},
			{
				{2, database_string_make("John"), 25, database_string_make("active")},
				{3, database_string_make("Kate"), 30, database_string_make("inactive")},
				{4, database_string_make("Rose"), 30, database_string_make("inactive")},
			},
		)
	})
}

@(test)
db_test_equals :: proc(t: ^testing.T) {
	testing_run_query(t, "SELECT * FROM users WHERE age = 30", nil, proc() {
		testing_prepare_database(
			{
				name = "users",
				column_names = {"id", "name", "age", "status"},
				primary_key_column_index = 0,
				rows = {
					{1, database_string_make("Matthew"), 15, database_string_make("active")},
					{2, database_string_make("John"), 25, database_string_make("active")},
					{3, database_string_make("Kate"), 30, database_string_make("inactive")},
					{4, database_string_make("Rose"), 30, database_string_make("inactive")},
				},
			},
		)
	}, proc(t: ^testing.T, result: Exec_Result, user_data: rawptr) {
		testing_compare_rows_UNordered(
			t,
			result.result.(Rows_With_Names),
			{"id", "name", "age", "status"},
			{
				{3, database_string_make("Kate"), 30, database_string_make("inactive")},
				{4, database_string_make("Rose"), 30, database_string_make("inactive")},
			},
		)
	})
}

@(test)
db_test_string_comparison :: proc(t: ^testing.T) {
	testing_run_query(t, "SELECT * FROM users WHERE status = 'active'", nil, proc() {
		testing_prepare_database(
			{
				name = "users",
				column_names = {"id", "name", "age", "status"},
				primary_key_column_index = 0,
				rows = {
					{1, database_string_make("Matthew"), 15, database_string_make("active")},
					{2, database_string_make("John"), 25, database_string_make("active")},
					{3, database_string_make("Kate"), 30, database_string_make("inactive")},
					{4, database_string_make("Rose"), 30, database_string_make("inactive")},
				},
			},
		)
	}, proc(t: ^testing.T, result: Exec_Result, user_data: rawptr) {
		testing_compare_rows_UNordered(
			t,
			result.result.(Rows_With_Names),
			{"id", "name", "age", "status"},
			{
				{1, database_string_make("Matthew"), 15, database_string_make("active")},
				{2, database_string_make("John"), 25, database_string_make("active")},
			},
		)
	})
}

@(test)
db_test_not_equals :: proc(t: ^testing.T) {
	testing_run_query(t, "SELECT * FROM users WHERE name != 'John'", nil, proc() {
		testing_prepare_database(
			{
				name = "users",
				column_names = {"id", "name", "age", "status"},
				primary_key_column_index = 0,
				rows = {
					{1, database_string_make("Matthew"), 15, database_string_make("active")},
					{2, database_string_make("John"), 25, database_string_make("active")},
					{3, database_string_make("Kate"), 30, database_string_make("inactive")},
					{4, database_string_make("Rose"), 30, database_string_make("inactive")},
				},
			},
		)
	}, proc(t: ^testing.T, result: Exec_Result, user_data: rawptr) {
		testing_compare_rows_UNordered(
			t,
			result.result.(Rows_With_Names),
			{"id", "name", "age", "status"},
			{
				{1, database_string_make("Matthew"), 15, database_string_make("active")},
				{3, database_string_make("Kate"), 30, database_string_make("inactive")},
				{4, database_string_make("Rose"), 30, database_string_make("inactive")},
			},
		)
	})
}

@(test)
db_test_insert_without_columns :: proc(t: ^testing.T) {
	testing_run_query(t, "INSERT INTO users VALUES (5, 'Alice', 28, 'active')", nil, proc() {
			testing_prepare_database({name = "users", column_names = {"id", "name", "age", "status"}, primary_key_column_index = 0, rows = {{1, database_string_make("Matthew"), 15, database_string_make("active")}, {2, database_string_make("John"), 25, database_string_make("active")}, {3, database_string_make("Kate"), 30, database_string_make("inactive")}, {4, database_string_make("Rose"), 30, database_string_make("inactive")}}})
		}, proc(t: ^testing.T, result: Exec_Result, user_data: rawptr) {
			testing.expect_value(t, result.result.(int), 1)
			verify, ok := exec("SELECT * FROM users", clear_msgs = true)
			testing.expect(t, ok)
			if !ok do return
			testing_compare_rows_UNordered(t, verify.result.(Rows_With_Names), {"id", "name", "age", "status"}, {{1, database_string_make("Matthew"), 15, database_string_make("active")}, {2, database_string_make("John"), 25, database_string_make("active")}, {3, database_string_make("Kate"), 30, database_string_make("inactive")}, {4, database_string_make("Rose"), 30, database_string_make("inactive")}, {5, database_string_make("Alice"), 28, database_string_make("active")}})
		})
}

@(test)
db_test_insert_with_columns :: proc(t: ^testing.T) {
	testing_run_query(t, "INSERT INTO users (id, name, age, status) VALUES (5, 'Bob', 35, 'inactive')", nil, proc() {testing_prepare_database({name = "users", column_names = {"id", "name", "age", "status"}, primary_key_column_index = 0, rows = {{1, database_string_make("Matthew"), 15, database_string_make("active")}, {2, database_string_make("John"), 25, database_string_make("active")}, {3, database_string_make("Kate"), 30, database_string_make("inactive")}, {4, database_string_make("Rose"), 30, database_string_make("inactive")}}})}, proc(t: ^testing.T, result: Exec_Result, user_data: rawptr) {
		testing.expect_value(t, result.result.(int), 1)
		verify, ok := exec("SELECT * FROM users WHERE id = 5", clear_msgs = true)
		testing.expect(t, ok)
		if !ok do return
		testing_compare_rows_ordered(t, verify.result.(Rows_With_Names), {"id", "name", "age", "status"}, {{5, database_string_make("Bob"), 35, database_string_make("inactive")}})
	})
}
@(test)
db_test_insert_multiple_rows :: proc(t: ^testing.T) {
	testing_run_query(t, "INSERT INTO users VALUES (5, 'Charlie', 22, 'active'), (6, 'Diana', 40, 'inactive')", nil, proc() {testing_prepare_database({name = "users", column_names = {"id", "name", "age", "status"}, primary_key_column_index = 0, rows = {{1, database_string_make("Matthew"), 15, database_string_make("active")}, {2, database_string_make("John"), 25, database_string_make("active")}, {3, database_string_make("Kate"), 30, database_string_make("inactive")}, {4, database_string_make("Rose"), 30, database_string_make("inactive")}}})}, proc(t: ^testing.T, result: Exec_Result, user_data: rawptr) {
		testing.expect_value(t, result.result.(int), 2)
		verify, ok := exec("SELECT * FROM users WHERE id IN (5, 6)", clear_msgs = true)
		testing.expect(t, ok)
		if !ok do return
		testing_compare_rows_UNordered(t, verify.result.(Rows_With_Names), {"id", "name", "age", "status"}, {{5, database_string_make("Charlie"), 22, database_string_make("active")}, {6, database_string_make("Diana"), 40, database_string_make("inactive")}})
	})
}

@(test)
db_test_insert_with_subset_of_columns :: proc(t: ^testing.T) {
	testing_run_query(t, "INSERT INTO users (id, name) VALUES (5, 'Frank')", nil, proc() {
		testing_prepare_database({name = "users", column_names = {"id", "name", "age", "status"}, primary_key_column_index = 0, rows = {{1, database_string_make("Matthew"), 15, database_string_make("active")}, {2, database_string_make("John"), 25, database_string_make("active")}, {3, database_string_make("Kate"), 30, database_string_make("inactive")}, {4, database_string_make("Rose"), 30, database_string_make("inactive")}}})
	}, proc(t: ^testing.T, result: Exec_Result, user_data: rawptr) {
		testing.expect_value(t, result.result.(int), 1)
		verify, ok := exec("SELECT * FROM users WHERE id = 5", clear_msgs = true)
		testing.expect(t, ok)
		if !ok do return
		testing_compare_rows_ordered(t, verify.result.(Rows_With_Names), {"id", "name", "age", "status"}, {{5, database_string_make("Frank"), nil, nil}})
	})
}

@(test)
db_test_mixed_data_types :: proc(t: ^testing.T) {
	testing_run_query(t, "INSERT INTO users (id, name, age, status) VALUES (5, 123, '23', NULL)", nil, proc() {
		testing_prepare_database({name = "users", column_names = {"id", "name", "age", "status"}, primary_key_column_index = 0, rows = {{1, database_string_make("Matthew"), 15, database_string_make("active")}, {2, database_string_make("John"), 25, database_string_make("active")}, {3, database_string_make("Kate"), 30, database_string_make("inactive")}, {4, database_string_make("Rose"), 30, database_string_make("inactive")}}})
	}, proc(t: ^testing.T, result: Exec_Result, user_data: rawptr) {
		testing.expect_value(t, result.result.(int), 1)
		verify, ok := exec("SELECT * FROM users WHERE id = 5", clear_msgs = true)
		testing.expect(t, ok)
		if !ok do return
		testing_compare_rows_ordered(t, verify.result.(Rows_With_Names), {"id", "name", "age", "status"}, {{5, 123, database_string_make("23"), nil}})
	})
}

@(test)
db_test_update_single_column :: proc(t: ^testing.T) {
	testing_run_query(t, "UPDATE users SET age = 35 WHERE name = 'John'", nil, proc() {
		testing_prepare_database({name = "users", column_names = {"id", "name", "age", "status"}, primary_key_column_index = 0, rows = {{1, database_string_make("Matthew"), 15, database_string_make("active")}, {2, database_string_make("John"), 25, database_string_make("active")}, {3, database_string_make("Kate"), 30, database_string_make("inactive")}, {4, database_string_make("Rose"), 30, database_string_make("inactive")}}})
	}, proc(t: ^testing.T, result: Exec_Result, user_data: rawptr) {
		testing.expect_value(t, result.result.(int), 1)
		verify, ok := exec("SELECT * FROM users WHERE name = 'John'", clear_msgs = true)
		testing.expect(t, ok)
		if !ok do return
		testing_compare_rows_ordered(t, verify.result.(Rows_With_Names), {"id", "name", "age", "status"}, {{2, database_string_make("John"), 35, database_string_make("active")}})
	})
}

@(test)
db_test_update_multiple_columns :: proc(t: ^testing.T) {
	testing_run_query(t, "UPDATE users SET age = 40, status = 'inactive' WHERE name = 'Kate'", nil, proc() {
		testing_prepare_database({name = "users", column_names = {"id", "name", "age", "status"}, primary_key_column_index = 0, rows = {{1, database_string_make("Matthew"), 15, database_string_make("active")}, {2, database_string_make("John"), 25, database_string_make("active")}, {3, database_string_make("Kate"), 30, database_string_make("inactive")}, {4, database_string_make("Rose"), 30, database_string_make("inactive")}}})
	}, proc(t: ^testing.T, result: Exec_Result, user_data: rawptr) {
		testing.expect_value(t, result.result.(int), 1)
		verify, ok := exec("SELECT * FROM users WHERE id = 3", clear_msgs = true)
		testing.expect(t, ok)
		if !ok do return
		testing_compare_rows_ordered(t, verify.result.(Rows_With_Names), {"id", "name", "age", "status"}, {{3, database_string_make("Kate"), 40, database_string_make("inactive")}})
	})
}

@(test)
db_test_update_without_where :: proc(t: ^testing.T) {
	testing_run_query(t, "UPDATE users SET status = 'updated'", nil, proc() {
		testing_prepare_database({name = "users", column_names = {"id", "name", "age", "status"}, primary_key_column_index = 0, rows = {{1, database_string_make("Matthew"), 15, database_string_make("active")}, {2, database_string_make("John"), 25, database_string_make("active")}, {3, database_string_make("Kate"), 30, database_string_make("inactive")}, {4, database_string_make("Rose"), 30, database_string_make("inactive")}}})
	}, proc(t: ^testing.T, result: Exec_Result, user_data: rawptr) {
		testing.expect_value(t, result.result.(int), 4)
		verify, ok := exec("SELECT id, status FROM users", clear_msgs = true)
		testing.expect(t, ok)
		if !ok do return
		testing_compare_rows_UNordered(t, verify.result.(Rows_With_Names), {"id", "status"}, {{1, database_string_make("updated")}, {2, database_string_make("updated")}, {3, database_string_make("updated")}, {4, database_string_make("updated")}})
	})
}

@(test)
db_test_update_with_complex_where :: proc(t: ^testing.T) {
	testing_run_query(t, "UPDATE users SET age = 50 WHERE age > 25 AND status = 'inactive'", nil, proc() {
		testing_prepare_database({name = "users", column_names = {"id", "name", "age", "status"}, primary_key_column_index = 0, rows = {{1, database_string_make("Matthew"), 15, database_string_make("active")}, {2, database_string_make("John"), 25, database_string_make("active")}, {3, database_string_make("Kate"), 30, database_string_make("inactive")}, {4, database_string_make("Rose"), 30, database_string_make("inactive")}}})
	}, proc(t: ^testing.T, result: Exec_Result, user_data: rawptr) {
		testing.expect_value(t, result.result.(int), 2)
		verify, ok := exec("SELECT id, age FROM users", clear_msgs = true)
		testing.expect(t, ok)
		if !ok do return
		testing_compare_rows_UNordered(t, verify.result.(Rows_With_Names), {"id", "age"}, {{1, 15}, {2, 25}, {3, 50}, {4, 50}})
	})
}

@(test)
db_test_update_with_string_value :: proc(t: ^testing.T) {
	testing_run_query(t, "UPDATE users SET age = '45' WHERE name = 'Matthew'", nil, proc() {
		testing_prepare_database({name = "users", column_names = {"id", "name", "age", "status"}, primary_key_column_index = 0, rows = {{1, database_string_make("Matthew"), 15, database_string_make("active")}, {2, database_string_make("John"), 25, database_string_make("active")}, {3, database_string_make("Kate"), 30, database_string_make("inactive")}, {4, database_string_make("Rose"), 30, database_string_make("inactive")}}})
	}, proc(t: ^testing.T, result: Exec_Result, user_data: rawptr) {
		testing.expect_value(t, result.result.(int), 1)
		verify, ok := exec("SELECT id, name, age, status FROM users WHERE id = 1", clear_msgs = true)
		testing.expect(t, ok)
		if !ok do return
		testing_compare_rows_ordered(t, verify.result.(Rows_With_Names), {"id", "name", "age", "status"}, {{1, database_string_make("Matthew"), database_string_make("45"), database_string_make("active")}})
	})
}

@(test)
db_test_delete_with_where :: proc(t: ^testing.T) {
	testing_run_query(
		t,
		"DELETE FROM users WHERE name = 'John'",
		nil,
		proc() {
			testing_prepare_database(
				{
					name = "users",
					column_names = {"id", "name", "age", "status"},
					primary_key_column_index = 0,
					rows = {
						{1, database_string_make("Matthew"), 15, database_string_make("active")},
						{2, database_string_make("John"), 25, database_string_make("active")},
						{3, database_string_make("Kate"), 30, database_string_make("inactive")},
						{4, database_string_make("Rose"), 30, database_string_make("inactive")},
					},
				},
			)
		},
		proc(t: ^testing.T, result: Exec_Result, user_data: rawptr) {
			testing.expect_value(t, result.result.(int), 1)
			verify, ok := exec("SELECT id, name FROM users", clear_msgs = true)
			testing.expect(t, ok)
			if !ok do return
			// Row order is not stable after swap-with-last deletes.
			testing_compare_rows_UNordered(
				t,
				verify.result.(Rows_With_Names),
				{"id", "name"},
				{
					{1, database_string_make("Matthew")},
					{3, database_string_make("Kate")},
					{4, database_string_make("Rose")},
				},
			)
		},
	)
}

@(test)
db_test_delete_without_where :: proc(t: ^testing.T) {
	testing_run_query(t, "DELETE FROM users", nil, proc() {
			testing_prepare_database({name = "users", column_names = {"id", "name", "age", "status"}, primary_key_column_index = 0, rows = {{1, database_string_make("Matthew"), 15, database_string_make("active")}, {2, database_string_make("John"), 25, database_string_make("active")}, {3, database_string_make("Kate"), 30, database_string_make("inactive")}, {4, database_string_make("Rose"), 30, database_string_make("inactive")}}})
		}, proc(t: ^testing.T, result: Exec_Result, user_data: rawptr) {
			testing.expect_value(t, result.result.(int), 4)
			verify, ok := exec("SELECT * FROM users", clear_msgs = true)
			testing.expect(t, ok)
			if !ok do return
			testing_compare_rows_ordered(t, verify.result.(Rows_With_Names), {"id", "name", "age", "status"}, {})
		})
}

@(test)
db_test_delete_with_complex_where :: proc(t: ^testing.T) {
	testing_run_query(t, "DELETE FROM users WHERE age > 25 AND status = 'inactive'", nil, proc() {
		testing_prepare_database({name = "users", column_names = {"id", "name", "age", "status"}, primary_key_column_index = 0, rows = {{1, database_string_make("Matthew"), 15, database_string_make("active")}, {2, database_string_make("John"), 25, database_string_make("active")}, {3, database_string_make("Kate"), 30, database_string_make("inactive")}, {4, database_string_make("Rose"), 30, database_string_make("inactive")}}})
	}, proc(t: ^testing.T, result: Exec_Result, user_data: rawptr) {
		testing.expect_value(t, result.result.(int), 2)
		verify, ok := exec("SELECT id, name, age, status FROM users", clear_msgs = true)
		testing.expect(t, ok)
		if !ok do return
		testing_compare_rows_UNordered(t, verify.result.(Rows_With_Names), {"id", "name", "age", "status"}, {{1, database_string_make("Matthew"), 15, database_string_make("active")}, {2, database_string_make("John"), 25, database_string_make("active")}})
	})
}

@(test)
db_test_delete_with_or_condition :: proc(t: ^testing.T) {
	testing_run_query(t, "DELETE FROM users WHERE name = 'Kate' OR name = 'Rose'", nil, proc() {
		testing_prepare_database({name = "users", column_names = {"id", "name", "age", "status"}, primary_key_column_index = 0, rows = {{1, database_string_make("Matthew"), 15, database_string_make("active")}, {2, database_string_make("John"), 25, database_string_make("active")}, {3, database_string_make("Kate"), 30, database_string_make("inactive")}, {4, database_string_make("Rose"), 30, database_string_make("inactive")}}})
	}, proc(t: ^testing.T, result: Exec_Result, user_data: rawptr) {
		testing.expect_value(t, result.result.(int), 2)
		verify, ok := exec("SELECT id, name, age, status FROM users", clear_msgs = true)
		testing.expect(t, ok)
		if !ok do return
		testing_compare_rows_UNordered(t, verify.result.(Rows_With_Names), {"id", "name", "age", "status"}, {{1, database_string_make("Matthew"), 15, database_string_make("active")}, {2, database_string_make("John"), 25, database_string_make("active")}})
	})
}

@(test)
db_test_create_table_without_column_types :: proc(t: ^testing.T) {
	defer main_finish()
	main_init()
	database_tests_clear()
	create_result, ok := exec(
		query = "CREATE TABLE products (id, name, price, category, primary key(id))",
		clear_msgs = true,
	)
	testing.expect(t, ok)
	{
		got_nil := create_result.result == nil
		// got_nil := false
		// #partial switch r in create_result.result {
		// case int:
		// 	_, has_count := r.?
		// 	got_nil = !has_count
		// }
		testing.expect(t, got_nil)
	}

	table, table_exists := database_find_table("products", log_error = false)
	testing.expect(t, table_exists)
	testing.expect_value(t, table.name, "products")
	testing.expect_value(t, len(table.column_names), 4)
	testing.expect_value(t, table.column_names[0], "id")
	testing.expect_value(t, table.column_names[1], "name")
	testing.expect_value(t, table.column_names[2], "price")
	testing.expect_value(t, table.column_names[3], "category")
	testing.expect_value(t, table.primary_key_column_index, 0)
	testing.expect_value(t, table_row_count(table), 0)

	result2, ok2 := exec(
		"INSERT INTO products VALUES (1, 'Widget', 9.99, 'Tools')",
		clear_msgs = true,
	)
	testing.expect(t, ok2)
	testing.expect_value(t, result2.result.(int), 1)

	result3, ok3 := exec("SELECT * FROM products", clear_msgs = true)
	testing.expect(t, ok3)
	{
		result := result3.result.(Rows_With_Names)
		testing.expect_value(t, len(result.rows), 1)
		testing.expect(t, value_exactly_equal(result.rows[0][0], 1))
		testing.expect(t, value_exactly_equal(result.rows[0][1], database_string_make("Widget")))
		testing.expect(t, value_exactly_equal(result.rows[0][2], f64(9.99)))
		testing.expect(t, value_exactly_equal(result.rows[0][3], database_string_make("Tools")))
	}
}

@(test)
db_test_create_table_with_column_types :: proc(t: ^testing.T) {
	defer main_finish()
	main_init()
	database_tests_clear()
	create_result, ok := exec(
		"CREATE TABLE inventory (item_id INTEGER, description TEXT, quantity INT, primary key(item_id))",
		clear_msgs = true,
	)
	testing.expect(t, ok)
	{
		got_nil := create_result.result == nil
		// got_nil := false
		// #partial switch r in create_result.result {
		// case Maybe(int):
		// 	_, has_count := r.?
		// 	got_nil = !has_count
		// }
		testing.expect(t, got_nil)
	}

	table, table_exists := database_find_table("inventory", log_error = false)
	testing.expect(t, table_exists)
	testing.expect_value(t, table.name, "inventory")
	testing.expect_value(t, len(table.column_names), 3)
	testing.expect_value(t, table.column_names[0], "item_id")
	testing.expect_value(t, table.column_names[1], "description")
	testing.expect_value(t, table.column_names[2], "quantity")
	testing.expect_value(t, table.primary_key_column_index, 0)
	testing.expect_value(t, table_row_count(table), 0)
}

@(test)
db_test_create_table_columnar_tag_controls_storage_mode :: proc(t: ^testing.T) {
	defer main_finish()
	main_init()
	database_tests_clear()

	_, row_ok := exec(query = "CREATE TABLE users_row (id, primary key(id))", clear_msgs = true)
	testing.expect(t, row_ok)
	users_row, has_row := database_find_table("users_row", log_error = false)
	testing.expect(t, has_row)
	if has_row {
		#partial switch storage in users_row.storage {
		case [dynamic]Table_Row:
			testing.expect(t, true)
		case [dynamic]Column_Chunks:
			testing.expect(t, false, "untagged CREATE TABLE should not be columnar")
		}
	}

	_, col_ok := exec(
		query = "CREATE TABLE @columnar users_col (id INTEGER, name TEXT, primary key(id))",
		clear_msgs = true,
	)
	testing.expect(t, col_ok)
	users_col, has_col := database_find_table("users_col", log_error = false)
	testing.expect(t, has_col)
	if has_col {
		#partial switch storage in users_col.storage {
		case [dynamic]Column_Chunks:
			testing.expect(t, true)
		case [dynamic]Table_Row:
			testing.expect(t, false, "@columnar CREATE TABLE should be columnar")
		}
	}
}

@(test)
db_test_alter_table_add_drop_rename_column_and_drop_table :: proc(t: ^testing.T) {
	defer main_finish()
	main_init()
	database_tests_clear()

	_, ok := exec("CREATE TABLE users (id INTEGER, name TEXT, primary key(id))", clear_msgs = true)
	testing.expect(t, ok)
	if !ok {
		return
	}

	_, ok = exec("INSERT INTO users VALUES (1, 'Ada')", clear_msgs = true)
	testing.expect(t, ok)

	_, ok = exec("ALTER TABLE users ADD COLUMN score INT", clear_msgs = true)
	testing.expect(t, ok)
	_, ok = exec("ALTER TABLE users RENAME COLUMN score TO points", clear_msgs = true)
	testing.expect(t, ok)
	_, ok = exec("ALTER TABLE users DROP COLUMN points", clear_msgs = true)
	testing.expect(t, ok)

	table, exists := database_find_table("users", log_error = false)
	testing.expect(t, exists)
	if !exists {
		return
	}
	testing.expect_value(t, len(table.column_names), 2)
	testing.expect_value(t, table.column_names[0], "id")
	testing.expect_value(t, table.column_names[1], "name")

	rows, rows_ok := exec("SELECT id, name FROM users", clear_msgs = true)
	testing.expect(t, rows_ok)
	if rows_ok {
		result := rows.result.(Rows_With_Names)
		testing.expect_value(t, len(result.rows), 1)
		if len(result.rows) == 1 {
			testing.expect(t, value_exactly_equal(result.rows[0][0], 1))
			testing.expect(t, value_exactly_equal(result.rows[0][1], database_string_make("Ada")))
		}
	}

	_, ok = exec("DROP TABLE users", clear_msgs = true)
	testing.expect(t, ok)
	_, exists = database_find_table("users", log_error = false)
	testing.expect(t, !exists)

	_, ok = exec("DROP TABLE IF EXISTS users", clear_msgs = true)
	testing.expect(t, ok)

	_, ok = exec("DROP TABLE users", clear_msgs = true)
	testing.expect(t, !ok)
}

// Regression: table_rebuild_with_schema used to alias freed memory for table.name after ALTER, causing UB on the next statement (bogus “table does not exist”, esp. first UPDATE after ADD COLUMN).
@(test)
db_test_alter_add_column_then_update_new_column :: proc(t: ^testing.T) {
	defer main_finish()
	main_init()
	database_tests_clear()

	_, ok := exec(
		"CREATE TABLE demo_metrics (id INTEGER, grp INTEGER, score INTEGER, PRIMARY KEY(id))",
		clear_msgs = true,
	)
	testing.expect(t, ok)
	if !ok do return

	_, ok = exec("INSERT INTO demo_metrics VALUES (1, 1, 10)", clear_msgs = true)
	testing.expect(t, ok)
	if !ok do return

	_, ok = exec("ALTER TABLE demo_metrics ADD COLUMN status TEXT", clear_msgs = true)
	testing.expect(t, ok)
	if !ok do return

	_, ok = exec("UPDATE demo_metrics SET status = 'low' WHERE score < 20", clear_msgs = true)
	testing.expect(t, ok)
	if !ok do return

	tab, exists := database_find_table("demo_metrics", log_error = false)
	testing.expect(t, exists)
	if exists {
		testing.expect_value(t, tab.name, "demo_metrics")
	}

	rows, rows_ok := exec("SELECT id, status FROM demo_metrics", clear_msgs = true)
	testing.expect(t, rows_ok)
	if !rows_ok do return
	result := rows.result.(Rows_With_Names)
	testing.expect_value(t, len(result.rows), 1)
	if len(result.rows) == 1 {
		testing.expect(t, value_exactly_equal(result.rows[0][0], 1))
		testing.expect(t, value_exactly_equal(result.rows[0][1], database_string_make("low")))
	}
}

@(test)
db_test_not_null_insert_and_update_enforcement :: proc(t: ^testing.T) {
	defer main_finish()
	main_init()
	database_tests_clear()

	_, ok := exec(
		"CREATE TABLE users_nn (id INTEGER, name TEXT NOT NULL, primary key(id))",
		clear_msgs = true,
	)
	testing.expect(t, ok)
	if !ok {
		return
	}

	_, ok = exec("INSERT INTO users_nn (id) VALUES (1)", clear_msgs = true)
	testing.expect(t, !ok)

	_, ok = exec("INSERT INTO users_nn (id, name) VALUES (1, NULL)", clear_msgs = true)
	testing.expect(t, !ok)

	_, ok = exec("INSERT INTO users_nn VALUES (1, 'Ada')", clear_msgs = true)
	testing.expect(t, ok)
	if !ok {
		return
	}

	_, ok = exec("UPDATE users_nn SET name = NULL WHERE id = 1", clear_msgs = true)
	testing.expect(t, !ok)

	rows_result, rows_ok := exec("SELECT id, name FROM users_nn WHERE id = 1", clear_msgs = true)
	testing.expect(t, rows_ok)
	if !rows_ok {
		return
	}
	rows := rows_result.result.(Rows_With_Names)
	testing.expect_value(t, len(rows.rows), 1)
	if len(rows.rows) == 1 {
		testing.expect(t, value_exactly_equal(rows.rows[0][0], 1))
		testing.expect(t, value_exactly_equal(rows.rows[0][1], database_string_make("Ada")))
	}
}

@(test)
db_test_primary_key_is_implicitly_not_null :: proc(t: ^testing.T) {
	defer main_finish()
	main_init()
	database_tests_clear()

	_, ok := exec(
		"CREATE TABLE users_pk (id INTEGER, name TEXT, primary key(id))",
		clear_msgs = true,
	)
	testing.expect(t, ok)
	if !ok {
		return
	}

	_, ok = exec("INSERT INTO users_pk (id, name) VALUES (NULL, 'Nope')", clear_msgs = true)
	testing.expect(t, !ok)
}

@(test)
db_test_alter_table_add_not_null_column_rejects_non_empty_table :: proc(t: ^testing.T) {
	defer main_finish()
	main_init()
	database_tests_clear()

	_, ok := exec("CREATE TABLE users_alter_nn (id INTEGER, primary key(id))", clear_msgs = true)
	testing.expect(t, ok)
	if !ok {
		return
	}

	_, ok = exec("INSERT INTO users_alter_nn VALUES (1)", clear_msgs = true)
	testing.expect(t, ok)
	if !ok {
		return
	}

	_, ok = exec("ALTER TABLE users_alter_nn ADD COLUMN email TEXT NOT NULL", clear_msgs = true)
	testing.expect(t, !ok)
}

@(test)
db_test_alter_table_add_not_null_column_on_empty_table_enforces_future_writes :: proc(
	t: ^testing.T,
) {
	defer main_finish()
	main_init()
	database_tests_clear()

	_, ok := exec(
		"CREATE TABLE users_alter_nn_empty (id INTEGER, primary key(id))",
		clear_msgs = true,
	)
	testing.expect(t, ok)
	if !ok {
		return
	}

	_, ok = exec(
		"ALTER TABLE users_alter_nn_empty ADD COLUMN email TEXT NOT NULL",
		clear_msgs = true,
	)
	testing.expect(t, ok)
	if !ok {
		return
	}

	_, ok = exec("INSERT INTO users_alter_nn_empty (id) VALUES (1)", clear_msgs = true)
	testing.expect(t, !ok)

	_, ok = exec(
		"INSERT INTO users_alter_nn_empty (id, email) VALUES (1, 'ada@site.test')",
		clear_msgs = true,
	)
	testing.expect(t, ok)
}

@(test)
db_test_column_storage_uses_declared_types_and_coercion :: proc(t: ^testing.T) {
	defer main_finish()
	main_init()
	database_tests_clear()

	column_names := make([dynamic]string, context.allocator)
	append_elems(&column_names, ..[]string{"id", "score", "name"})
	column_types := make([dynamic]Maybe(Database_Column_Type), context.allocator)
	append(&column_types, Database_Column_Type.Integer)
	append(&column_types, Database_Column_Type.Float)
	append(&column_types, Database_Column_Type.Text)

	table: Table
	table_init(
		&table,
		name = "typed_scores",
		column_names = column_names,
		primary_key_column_index = 0,
		column_types = column_types,
	)
	defer table_destroy(&table)
	table.storage = make([dynamic]Column_Chunks, context.allocator)

	ok := database_insert_row(
		&table,
		column_names[:],
		[]Database_Value{1, 2, database_string_make("Ada")},
	)
	testing.expect(t, ok)
	testing.expect_value(t, table_row_count(&table), 1)

	row, row_ok := table_get_row(&table, 0)
	testing.expect(t, row_ok)
	if row_ok {
		testing.expect(t, value_exactly_equal(row[1], f64(2.0)))
	}

	cols := table.storage.([dynamic]Column_Chunks)
	#partial switch typed in cols[1] {
	case [dynamic]Column_Chunk(f64):
		testing.expect_value(t, len(typed), 1)
		if len(typed) == 1 {
			testing.expect_value(t, len(typed[0].values), 1)
			testing.expect_value(t, typed[0].values[0], f64(2.0))
			testing.expect(t, column_chunk_validity_get(typed[0].valid_bits[:], 0))
		}
	case:
		testing.expect(t, false, "score column must be f64 storage")
	}
}

@(test)
db_test_column_storage_rejects_invalid_declared_type_write :: proc(t: ^testing.T) {
	defer main_finish()
	main_init()
	database_tests_clear()

	column_names := make([dynamic]string, context.allocator)
	append_elems(&column_names, ..[]string{"id", "score"})
	column_types := make([dynamic]Maybe(Database_Column_Type), context.allocator)
	append(&column_types, Database_Column_Type.Integer)
	append(&column_types, Database_Column_Type.Float)

	table: Table
	table_init(
		&table,
		name = "typed_scores_strict",
		column_names = column_names,
		primary_key_column_index = 0,
		column_types = column_types,
	)
	defer table_destroy(&table)
	table.storage = make([dynamic]Column_Chunks, context.allocator)

	ok := database_insert_row(
		&table,
		column_names[:],
		[]Database_Value{1, database_string_make("not-a-number")},
	)
	testing.expect(t, !ok)
	testing.expect_value(t, table_row_count(&table), 0)
}

@(test)
db_test_columnar_chunk_boundary_and_row_reads :: proc(t: ^testing.T) {
	defer main_finish()
	main_init()
	database_tests_clear()

	table: Table
	col_names := make([dynamic]string, context.allocator)
	append_elems(&col_names, ..[]string{"id", "note"})
	col_types := make([dynamic]Maybe(Database_Column_Type), context.allocator)
	append(&col_types, Database_Column_Type.Integer)
	append(&col_types, Database_Column_Type.Text)
	table_init(
		&table,
		name = "chunk_boundary",
		column_names = col_names,
		primary_key_column_index = 0,
		column_types = col_types,
	)
	defer table_destroy(&table)
	table.storage = make([dynamic]Column_Chunks, context.allocator)

	for i := 0; i < COLUMN_CHUNK_SIZE + 1; i += 1 {
		ok := database_insert_row(
			&table,
			table.column_names[:],
			[]Database_Value{i, database_string_make("v")},
		)
		testing.expect(t, ok)
	}

	testing.expect_value(t, table_row_count(&table), COLUMN_CHUNK_SIZE + 1)
	row_a, ok_a := table_get_row(&table, COLUMN_CHUNK_SIZE - 1)
	testing.expect(t, ok_a)
	if ok_a {
		testing.expect(t, value_exactly_equal(row_a[0], COLUMN_CHUNK_SIZE - 1))
	}
	row_b, ok_b := table_get_row(&table, COLUMN_CHUNK_SIZE)
	testing.expect(t, ok_b)
	if ok_b {
		testing.expect(t, value_exactly_equal(row_b[0], COLUMN_CHUNK_SIZE))
	}
}

@(test)
db_test_columnar_validity_bitmap_tracks_null_and_non_null :: proc(t: ^testing.T) {
	defer main_finish()
	main_init()
	database_tests_clear()

	table: Table
	col_names := make([dynamic]string, context.allocator)
	append_elems(&col_names, ..[]string{"id", "score"})
	col_types := make([dynamic]Maybe(Database_Column_Type), context.allocator)
	append(&col_types, Database_Column_Type.Integer)
	append(&col_types, Database_Column_Type.Float)
	table_init(
		&table,
		name = "validity_bits",
		column_names = col_names,
		primary_key_column_index = 0,
		column_types = col_types,
	)
	defer table_destroy(&table)
	table.storage = make([dynamic]Column_Chunks, context.allocator)

	testing.expect(t, database_insert_row(&table, table.column_names[:], []Database_Value{1, nil}))
	testing.expect(
		t,
		database_insert_row(&table, table.column_names[:], []Database_Value{2, f64(3.5)}),
	)

	cols := table.storage.([dynamic]Column_Chunks)
	#partial switch typed in cols[1] {
	case [dynamic]Column_Chunk(f64):
		testing.expect_value(t, len(typed), 1)
		if len(typed) == 1 {
			testing.expect(t, !column_chunk_validity_get(typed[0].valid_bits[:], 0))
			testing.expect(t, column_chunk_validity_get(typed[0].valid_bits[:], 1))
		}
	case:
		testing.expect(t, false, "expected float chunk storage")
	}
}

@(test)
db_test_columnar_set_row_toggles_nullability :: proc(t: ^testing.T) {
	defer main_finish()
	main_init()
	database_tests_clear()

	table: Table
	col_names := make([dynamic]string, context.allocator)
	append_elems(&col_names, ..[]string{"id", "score"})
	col_types := make([dynamic]Maybe(Database_Column_Type), context.allocator)
	append(&col_types, Database_Column_Type.Integer)
	append(&col_types, Database_Column_Type.Float)
	table_init(
		&table,
		name = "toggle_null",
		column_names = col_names,
		primary_key_column_index = 0,
		column_types = col_types,
	)
	defer table_destroy(&table)
	table.storage = make([dynamic]Column_Chunks, context.allocator)
	testing.expect(t, database_insert_row(&table, table.column_names[:], []Database_Value{1, nil}))
	row_non_null := make(Table_Row, 2, database_query_allocator)
	row_non_null[0] = 1
	row_non_null[1] = f64(4.0)
	testing.expect(t, table_set_row(&table, 0, row_non_null))
	row_null := make(Table_Row, 2, database_query_allocator)
	row_null[0] = 1
	row_null[1] = nil
	testing.expect(t, table_set_row(&table, 0, row_null))

	cols := table.storage.([dynamic]Column_Chunks)
	#partial switch typed in cols[1] {
	case [dynamic]Column_Chunk(f64):
		testing.expect_value(t, len(typed), 1)
		if len(typed) == 1 {
			testing.expect(t, !column_chunk_validity_get(typed[0].valid_bits[:], 0))
		}
	case:
		testing.expect(t, false, "expected float chunk storage")
	}
}

@(test)
db_test_columnar_delete_row_unordered_across_chunk_boundary :: proc(t: ^testing.T) {
	defer main_finish()
	main_init()
	database_tests_clear()

	table: Table
	col_names := make([dynamic]string, context.allocator)
	append(&col_names, "id")
	col_types := make([dynamic]Maybe(Database_Column_Type), context.allocator)
	append(&col_types, Database_Column_Type.Integer)
	table_init(
		&table,
		name = "delete_boundary",
		column_names = col_names,
		primary_key_column_index = 0,
		column_types = col_types,
	)
	defer table_destroy(&table)
	table.storage = make([dynamic]Column_Chunks, context.allocator)

	for i := 0; i < COLUMN_CHUNK_SIZE + 2; i += 1 {
		testing.expect(t, database_insert_row(&table, table.column_names[:], []Database_Value{i}))
	}
	testing.expect_value(t, table_row_count(&table), COLUMN_CHUNK_SIZE + 2)

	_, _, _, _, del_ok := table_delete_row_unordered(&table, COLUMN_CHUNK_SIZE - 1)
	testing.expect(t, del_ok)
	testing.expect_value(t, table_row_count(&table), COLUMN_CHUNK_SIZE + 1)
	testing.expect(t, table_columnar_validate_columns(table.storage.([dynamic]Column_Chunks)))
}

@(test)
db_test_inner_join :: proc(t: ^testing.T) {
	defer main_finish()
	main_init()
	database_tests_clear()
	users_cols := make([dynamic]string, context.allocator)
	append_elems(&users_cols, ..[]string{"id", "name"})
	// users_table := Table {
	// 	name                     = "users",
	// 	column_names             = users_cols,
	// 	primary_key_column_index = 0,
	// }
	users_table: Table
	table_init(
		&users_table,
		name = "users",
		column_names = users_cols,
		primary_key_column_index = 0,
	)
	must_insert_row(
		&users_table,
		users_cols[:],
		[]Database_Value{1, database_string_make("Alice")},
	)
	must_insert_row(&users_table, users_cols[:], []Database_Value{2, database_string_make("Bob")})
	must_insert_row(
		&users_table,
		users_cols[:],
		[]Database_Value{3, database_string_make("Charlie")},
	)

	orders_cols := make([dynamic]string, context.allocator)
	append_elems(&orders_cols, ..[]string{"id", "user_id", "product"})
	// orders_table := Table {
	// 	name                     = "orders",
	// 	column_names             = orders_cols,
	// 	primary_key_column_index = 0,
	// }
	// table_init(&orders_table, alloc)
	orders_table: Table
	table_init(
		&orders_table,
		name = "orders",
		column_names = orders_cols,
		primary_key_column_index = 0,
	)
	must_insert_row(
		&orders_table,
		orders_cols[:],
		[]Database_Value{101, 1, database_string_make("Widget")},
	)
	must_insert_row(
		&orders_table,
		orders_cols[:],
		[]Database_Value{102, 2, database_string_make("Gadget")},
	)
	must_insert_row(
		&orders_table,
		orders_cols[:],
		[]Database_Value{103, 1, database_string_make("Tool")},
	)

	set_database_tables(users_table, orders_table)

	result, ok := exec(
		"SELECT * FROM users JOIN orders ON users.id = orders.user_id",
		clear_msgs = true,
	)
	testing.expect(t, ok)
	{
		result := result.result.(Rows_With_Names)
		testing.expect_value(t, len(result.rows), 3)
		testing.expect(t, value_exactly_equal(rows_cell(result, 0, "users.id"), 1))
		testing.expect(
			t,
			value_exactly_equal(rows_cell(result, 0, "users.name"), database_string_make("Alice")),
		)
		testing.expect(t, value_exactly_equal(rows_cell(result, 0, "orders.id"), 101))
		testing.expect(t, value_exactly_equal(rows_cell(result, 0, "orders.user_id"), 1))
		testing.expect(
			t,
			value_exactly_equal(
				rows_cell(result, 0, "orders.product"),
				database_string_make("Widget"),
			),
		)
		testing.expect(t, value_exactly_equal(rows_cell(result, 2, "users.id"), 2))
		testing.expect(
			t,
			value_exactly_equal(rows_cell(result, 2, "users.name"), database_string_make("Bob")),
		)
		testing.expect(t, value_exactly_equal(rows_cell(result, 2, "orders.id"), 102))
		testing.expect(t, value_exactly_equal(rows_cell(result, 2, "orders.user_id"), 2))
		testing.expect(
			t,
			value_exactly_equal(
				rows_cell(result, 2, "orders.product"),
				database_string_make("Gadget"),
			),
		)
		testing.expect(t, value_exactly_equal(rows_cell(result, 1, "users.id"), 1))
		testing.expect(
			t,
			value_exactly_equal(rows_cell(result, 1, "users.name"), database_string_make("Alice")),
		)
		testing.expect(t, value_exactly_equal(rows_cell(result, 1, "orders.id"), 103))
		testing.expect(t, value_exactly_equal(rows_cell(result, 1, "orders.user_id"), 1))
		testing.expect(
			t,
			value_exactly_equal(
				rows_cell(result, 1, "orders.product"),
				database_string_make("Tool"),
			),
		)
	}
}

@(test)
db_test_left_join :: proc(t: ^testing.T) {
	defer main_finish()
	main_init()
	database_tests_clear()
	users_cols := make([dynamic]string, context.allocator)
	append_elems(&users_cols, ..[]string{"id", "name"})
	// users_table := Table {
	// 	name                     = "users",
	// 	column_names             = users_cols,
	// 	primary_key_column_index = 0,
	// }
	// table_init(&users_table, alloc)
	users_table: Table
	table_init(
		&users_table,
		name = "users",
		column_names = users_cols,
		primary_key_column_index = 0,
	)
	must_insert_row(
		&users_table,
		users_cols[:],
		[]Database_Value{1, database_string_make("Alice")},
	)
	must_insert_row(&users_table, users_cols[:], []Database_Value{2, database_string_make("Bob")})
	must_insert_row(
		&users_table,
		users_cols[:],
		[]Database_Value{3, database_string_make("Charlie")},
	)

	orders_cols := make([dynamic]string, context.allocator)
	append_elems(&orders_cols, ..[]string{"id", "user_id", "product"})
	// orders_table := Table {
	// 	name                     = "orders",
	// 	column_names             = orders_cols,
	// 	primary_key_column_index = 0,
	// }
	// table_init(&orders_table, alloc)
	orders_table: Table
	table_init(
		&orders_table,
		name = "orders",
		column_names = orders_cols,
		primary_key_column_index = 0,
	)
	must_insert_row(
		&orders_table,
		orders_cols[:],
		[]Database_Value{101, 1, database_string_make("Widget")},
	)
	must_insert_row(
		&orders_table,
		orders_cols[:],
		[]Database_Value{102, 2, database_string_make("Gadget")},
	)

	set_database_tables(users_table, orders_table)

	result, ok := exec(
		"SELECT * FROM users LEFT JOIN orders ON users.id = orders.user_id",
		clear_msgs = true,
	)
	testing.expect(t, ok)
	{
		result := result.result.(Rows_With_Names)
		testing.expect_value(t, len(result.rows), 3)
		testing.expect(t, value_exactly_equal(rows_cell(result, 0, "users.id"), 1))
		testing.expect(
			t,
			value_exactly_equal(rows_cell(result, 0, "users.name"), database_string_make("Alice")),
		)
		testing.expect(t, value_exactly_equal(rows_cell(result, 0, "orders.id"), 101))
		testing.expect(t, value_exactly_equal(rows_cell(result, 0, "orders.user_id"), 1))
		testing.expect(
			t,
			value_exactly_equal(
				rows_cell(result, 0, "orders.product"),
				database_string_make("Widget"),
			),
		)
		testing.expect(t, value_exactly_equal(rows_cell(result, 1, "users.id"), 2))
		testing.expect(
			t,
			value_exactly_equal(rows_cell(result, 1, "users.name"), database_string_make("Bob")),
		)
		testing.expect(t, value_exactly_equal(rows_cell(result, 1, "orders.id"), 102))
		testing.expect(t, value_exactly_equal(rows_cell(result, 1, "orders.user_id"), 2))
		testing.expect(
			t,
			value_exactly_equal(
				rows_cell(result, 1, "orders.product"),
				database_string_make("Gadget"),
			),
		)
		testing.expect(t, value_exactly_equal(rows_cell(result, 2, "users.id"), 3))
		testing.expect(
			t,
			value_exactly_equal(
				rows_cell(result, 2, "users.name"),
				database_string_make("Charlie"),
			),
		)
		testing.expect(t, value_exactly_equal(rows_cell(result, 2, "orders.id"), nil))
		testing.expect(t, value_exactly_equal(rows_cell(result, 2, "orders.user_id"), nil))
		testing.expect(t, value_exactly_equal(rows_cell(result, 2, "orders.product"), nil))
	}
}

@(test)
db_test_right_join :: proc(t: ^testing.T) {
	defer main_finish()
	main_init()
	database_tests_clear()
	users_cols := make([dynamic]string, context.allocator)
	append_elems(&users_cols, ..[]string{"id", "name"})
	users_table: Table
	table_init(
		&users_table,
		name = "users",
		column_names = users_cols,
		primary_key_column_index = 0,
	)
	must_insert_row(
		&users_table,
		users_cols[:],
		[]Database_Value{1, database_string_make("Alice")},
	)
	must_insert_row(&users_table, users_cols[:], []Database_Value{2, database_string_make("Bob")})

	orders_cols := make([dynamic]string, context.allocator)
	append_elems(&orders_cols, ..[]string{"id", "user_id", "product"})
	orders_table: Table
	table_init(
		&orders_table,
		name = "orders",
		column_names = orders_cols,
		primary_key_column_index = 0,
	)
	must_insert_row(
		&orders_table,
		orders_cols[:],
		[]Database_Value{101, 1, database_string_make("Widget")},
	)
	must_insert_row(
		&orders_table,
		orders_cols[:],
		[]Database_Value{102, 2, database_string_make("Gadget")},
	)
	must_insert_row(
		&orders_table,
		orders_cols[:],
		[]Database_Value{103, 99, database_string_make("Orphan")},
	)

	set_database_tables(users_table, orders_table)

	result, ok := exec(
		"SELECT * FROM users RIGHT JOIN orders ON users.id = orders.user_id",
		clear_msgs = true,
	)
	testing.expect(t, ok)
	{
		result := result.result.(Rows_With_Names)
		testing.expect_value(t, len(result.rows), 3)
		testing.expect(t, value_exactly_equal(rows_cell(result, 0, "users.id"), 1))
		testing.expect(
			t,
			value_exactly_equal(rows_cell(result, 0, "users.name"), database_string_make("Alice")),
		)
		testing.expect(t, value_exactly_equal(rows_cell(result, 0, "orders.id"), 101))
		testing.expect(t, value_exactly_equal(rows_cell(result, 0, "orders.user_id"), 1))
		testing.expect(
			t,
			value_exactly_equal(
				rows_cell(result, 0, "orders.product"),
				database_string_make("Widget"),
			),
		)
		testing.expect(t, value_exactly_equal(rows_cell(result, 1, "users.id"), 2))
		testing.expect(
			t,
			value_exactly_equal(rows_cell(result, 1, "users.name"), database_string_make("Bob")),
		)
		testing.expect(t, value_exactly_equal(rows_cell(result, 1, "orders.id"), 102))
		testing.expect(t, value_exactly_equal(rows_cell(result, 1, "orders.user_id"), 2))
		testing.expect(
			t,
			value_exactly_equal(
				rows_cell(result, 1, "orders.product"),
				database_string_make("Gadget"),
			),
		)
		testing.expect(t, value_exactly_equal(rows_cell(result, 2, "users.id"), nil))
		testing.expect(t, value_exactly_equal(rows_cell(result, 2, "users.name"), nil))
		testing.expect(t, value_exactly_equal(rows_cell(result, 2, "orders.id"), 103))
		testing.expect(t, value_exactly_equal(rows_cell(result, 2, "orders.user_id"), 99))
		testing.expect(
			t,
			value_exactly_equal(
				rows_cell(result, 2, "orders.product"),
				database_string_make("Orphan"),
			),
		)
	}
}

@(test)
db_test_join_with_where :: proc(t: ^testing.T) {
	defer main_finish()
	main_init()
	database_tests_clear()
	users_cols := make([dynamic]string, context.allocator)
	append_elems(&users_cols, ..[]string{"id", "name", "age"})
	users_table: Table
	table_init(
		&users_table,
		name = "users",
		column_names = users_cols,
		primary_key_column_index = 0,
	)

	must_insert_row(
		&users_table,
		users_cols[:],
		[]Database_Value{1, database_string_make("Alice"), 25},
	)
	must_insert_row(
		&users_table,
		users_cols[:],
		[]Database_Value{2, database_string_make("Bob"), 30},
	)

	orders_cols := make([dynamic]string, context.allocator)
	append_elems(&orders_cols, ..[]string{"id", "user_id", "amount"})
	// orders_table := Table {
	// 	name                     = "orders",
	// 	column_names             = orders_cols,
	// 	primary_key_column_index = 0,
	// }
	orders_table: Table
	table_init(
		&orders_table,
		name = "orders",
		column_names = orders_cols,
		primary_key_column_index = 0,
	)
	must_insert_row(&orders_table, orders_cols[:], []Database_Value{101, 1, 100})
	must_insert_row(&orders_table, orders_cols[:], []Database_Value{102, 2, 200})

	set_database_tables(users_table, orders_table)

	result, ok := exec(
		"SELECT * FROM users JOIN orders ON users.id = orders.user_id WHERE users.age > 25",
		clear_msgs = true,
	)
	testing.expect(t, ok)
	{
		result := result.result.(Rows_With_Names)
		testing.expect_value(t, len(result.rows), 1)
		testing.expect(t, value_exactly_equal(rows_cell(result, 0, "users.id"), 2))
		testing.expect(t, value_exactly_equal(rows_cell(result, 0, "users.age"), 30))
		testing.expect(
			t,
			value_exactly_equal(rows_cell(result, 0, "users.name"), database_string_make("Bob")),
		)
		testing.expect(t, value_exactly_equal(rows_cell(result, 0, "orders.id"), 102))
		testing.expect(t, value_exactly_equal(rows_cell(result, 0, "orders.user_id"), 2))
		testing.expect(t, value_exactly_equal(rows_cell(result, 0, "orders.amount"), 200))
	}
}

@(test)
db_test_create_table_with_primary_key :: proc(t: ^testing.T) {
	defer main_finish()
	main_init()
	database_tests_clear()
	_, ok := exec("CREATE TABLE users (name, age, PRIMARY KEY(name))", clear_msgs = true)
	testing.expect(t, ok)

	table, table_exists := database_find_table("users", log_error = false)
	testing.expect(t, table_exists)
	testing.expect_value(t, table.name, "users")
	testing.expect_value(t, table.primary_key_column_index, 0)
	testing.expect_value(t, len(table.column_names), 2)
	testing.expect_value(t, table.column_names[0], "name")
	testing.expect_value(t, table.column_names[1], "age")
}

@(test)
db_test_null_parsing :: proc(t: ^testing.T) {
	defer main_finish()
	main_init()
	database_tests_clear()
	users_cols := make([dynamic]string, context.allocator)
	append_elems(&users_cols, ..[]string{"id", "name", "age"})
	// users_table := Table {
	// 	name                     = "users",
	// 	column_names             = users_cols,
	// 	primary_key_column_index = 0,
	// }
	// table_init(&users_table, alloc)
	users_table: Table
	table_init(
		&users_table,
		name = "users",
		column_names = users_cols,
		primary_key_column_index = 0,
	)
	must_insert_row(
		&users_table,
		users_cols[:],
		[]Database_Value{1, database_string_make("Alice"), 25},
	)
	must_insert_row(
		&users_table,
		users_cols[:],
		[]Database_Value{2, database_string_make("Bob"), 30},
	)
	must_insert_row(
		&users_table,
		users_cols[:],
		[]Database_Value{3, database_string_make("Charlie"), 22},
	)
	set_database_tables(users_table)

	result, ok := exec("INSERT INTO users (id, name, age) VALUES (4, NULL, 35)", clear_msgs = true)
	testing.expect(t, ok)
	testing.expect_value(t, result.result.(int), 1)

	result2, ok2 := exec("SELECT * FROM users WHERE id = 4", clear_msgs = true)
	testing.expect(t, ok2)
	{
		result := result2.result.(Rows_With_Names)
		testing.expect_value(t, len(result.rows), 1)
		testing.expect(t, value_exactly_equal(result.rows[0][0], 4))
		testing.expect(t, value_exactly_equal(result.rows[0][1], nil))
		testing.expect(t, value_exactly_equal(result.rows[0][2], 35))
	}
}

@(test)
db_test_order_by_nulls_first_is_deterministic :: proc(t: ^testing.T) {
	defer main_finish()
	main_init()
	database_tests_clear()

	_, ok := exec("CREATE TABLE users (id, age, PRIMARY KEY(id))", clear_msgs = true)
	testing.expect(t, ok)
	if !ok {
		return
	}

	_, ok = exec(
		"INSERT INTO users (id, age) VALUES (1, 30), (2, NULL), (3, 25), (4, NULL)",
		clear_msgs = true,
	)
	testing.expect(t, ok)
	if !ok {
		return
	}

	result, ok3 := exec("SELECT id, age FROM users ORDER BY age ASC, id ASC", clear_msgs = true)
	testing.expect(t, ok3)
	if !ok3 {
		return
	}

	rows := result.result.(Rows_With_Names)
	testing.expect_value(t, len(rows.rows), 4)
	if len(rows.rows) != 4 {
		return
	}
	testing.expect(t, value_exactly_equal(rows.rows[0][0], 2))
	testing.expect(t, value_exactly_equal(rows.rows[0][1], nil))
	testing.expect(t, value_exactly_equal(rows.rows[1][0], 4))
	testing.expect(t, value_exactly_equal(rows.rows[1][1], nil))
	testing.expect(t, value_exactly_equal(rows.rows[2][0], 3))
	testing.expect(t, value_exactly_equal(rows.rows[2][1], 25))
	testing.expect(t, value_exactly_equal(rows.rows[3][0], 1))
	testing.expect(t, value_exactly_equal(rows.rows[3][1], 30))
}

@(test)
db_test_paranthesis_precedence :: proc(t: ^testing.T) {
	defer main_finish()
	main_init()
	database_tests_clear()
	users_cols := make([dynamic]string, context.allocator)
	append_elems(&users_cols, ..[]string{"id", "name", "age", "status"})
	// users_table := Table {
	// 	name                     = "users",
	// 	column_names             = users_cols,
	// 	primary_key_column_index = 0,
	// }
	users_table: Table
	table_init(
		&users_table,
		name = "users",
		column_names = users_cols,
		primary_key_column_index = 0,
	)
	must_insert_row(
		&users_table,
		users_cols[:],
		[]Database_Value{1, database_string_make("Alice"), 25, database_string_make("active")},
	)
	must_insert_row(
		&users_table,
		users_cols[:],
		[]Database_Value{2, database_string_make("Bob"), 30, database_string_make("inactive")},
	)
	must_insert_row(
		&users_table,
		users_cols[:],
		[]Database_Value{3, database_string_make("Charlie"), 22, database_string_make("active")},
	)
	must_insert_row(
		&users_table,
		users_cols[:],
		[]Database_Value{4, database_string_make("David"), 35, database_string_make("pending")},
	)
	set_database_tables(users_table)

	result, ok := exec("SELECT * FROM users WHERE (age > 25)", clear_msgs = true)
	testing.expect(t, ok)
	{
		result := result.result.(Rows_With_Names)
		testing.expect_value(t, len(result.rows), 2)
	}

	result2, ok2 := exec(
		"SELECT * FROM users WHERE (age > 25) AND (status = 'active')",
		clear_msgs = true,
	)
	testing.expect(t, ok2)
	{
		result := result2.result.(Rows_With_Names)
		testing.expect_value(t, len(result.rows), 0)
	}

	result3, ok3 := exec(
		"SELECT * FROM users WHERE (age > 25) OR (status = 'active')",
		clear_msgs = true,
	)
	testing.expect(t, ok3)
	{
		result := result3.result.(Rows_With_Names)
		testing.expect_value(t, len(result.rows), 4)
	}

	result4, ok4 := exec(
		"SELECT * FROM users WHERE ((age >= 22) AND (age < 35)) OR (name = 'Alice')",
		clear_msgs = true,
	)
	testing.expect(t, ok4)
	{
		result := result4.result.(Rows_With_Names)
		testing.expect_value(t, len(result.rows), 3)
	}

	result5, ok5 := exec("SELECT * FROM users WHERE NOT (age > 25)", clear_msgs = true)
	testing.expect(t, ok5)
	{
		result := result5.result.(Rows_With_Names)
		testing.expect_value(t, len(result.rows), 2)
	}

	result6, ok6 := exec(
		"SELECT * FROM users WHERE ((age > 20) AND (age < 30)) OR ((name = 'David') AND (status = 'pending'))",
		clear_msgs = true,
	)
	testing.expect(t, ok6)
	{
		result := result6.result.(Rows_With_Names)
		testing.expect_value(t, len(result.rows), 3)
	}
}

@(test)
db_test_in_operator_with_subquery :: proc(t: ^testing.T) {
	defer main_finish()
	main_init()
	database_tests_clear()
	users_cols := make([dynamic]string, context.allocator)
	append_elems(&users_cols, ..[]string{"id", "name", "age", "status"})
	// users_table := Table {
	// 	name                     = "users",
	// 	column_names             = users_cols,
	// 	primary_key_column_index = 0,
	// }
	// table_init(&users_table, alloc)
	users_table: Table
	table_init(
		&users_table,
		name = "users",
		column_names = users_cols,
		primary_key_column_index = 0,
	)
	must_insert_row(
		&users_table,
		users_cols[:],
		[]Database_Value{1, database_string_make("Alice"), 25, database_string_make("active")},
	)
	must_insert_row(
		&users_table,
		users_cols[:],
		[]Database_Value{2, database_string_make("Bob"), 30, database_string_make("inactive")},
	)
	must_insert_row(
		&users_table,
		users_cols[:],
		[]Database_Value{3, database_string_make("Charlie"), 35, database_string_make("active")},
	)
	orders_cols := make([dynamic]string, context.allocator)
	append_elems(&orders_cols, ..[]string{"id", "user_id", "product"})
	// orders_table := Table {
	// 	name                     = "orders",
	// 	column_names             = orders_cols,
	// 	primary_key_column_index = 0,
	// 	allocator = context.allocator,
	// )
	// table_init(&orders_table, alloc)
	orders_table: Table
	table_init(
		&orders_table,
		name = "orders",
		column_names = orders_cols,
		primary_key_column_index = 0,
	)
	must_insert_row(
		&orders_table,
		orders_cols[:],
		[]Database_Value{101, 1, database_string_make("Widget")},
	)
	must_insert_row(
		&orders_table,
		orders_cols[:],
		[]Database_Value{102, 2, database_string_make("Gadget")},
	)
	set_database_tables(users_table, orders_table)

	result, ok := exec(
		"SELECT * FROM users WHERE id IN (SELECT user_id FROM orders)",
		clear_msgs = true,
	)
	testing.expect(t, ok)
	{
		result := result.result.(Rows_With_Names)
		testing.expect_value(t, len(result.rows), 2)
	}
}

@(test)
db_test_not_in_operator_with_subquery :: proc(t: ^testing.T) {
	defer main_finish()
	main_init()
	database_tests_clear()
	users_cols := make([dynamic]string, context.allocator)
	append_elems(&users_cols, ..[]string{"id", "name", "age", "status"})
	// users_table := Table {
	// 	name                     = "users",
	// 	column_names             = users_cols,
	// 	primary_key_column_index = 0,
	// }
	users_table: Table
	table_init(
		&users_table,
		name = "users",
		column_names = users_cols,
		primary_key_column_index = 0,
	)
	must_insert_row(
		&users_table,
		users_cols[:],
		[]Database_Value{1, database_string_make("Alice"), 25, database_string_make("active")},
	)
	must_insert_row(
		&users_table,
		users_cols[:],
		[]Database_Value{2, database_string_make("Bob"), 30, database_string_make("inactive")},
	)
	must_insert_row(
		&users_table,
		users_cols[:],
		[]Database_Value{3, database_string_make("Charlie"), 35, database_string_make("active")},
	)
	orders_cols := make([dynamic]string, context.allocator)
	append_elems(&orders_cols, ..[]string{"id", "user_id", "product"})
	// orders_table := Table {
	// 	name                     = "orders",
	// 	column_names             = orders_cols,
	// 	primary_key_column_index = 0,
	// }
	// table_init(&orders_table, alloc)
	orders_table: Table
	table_init(
		&orders_table,
		name = "orders",
		column_names = orders_cols,
		primary_key_column_index = 0,
	)
	must_insert_row(
		&orders_table,
		orders_cols[:],
		[]Database_Value{101, 1, database_string_make("Widget")},
	)
	must_insert_row(
		&orders_table,
		orders_cols[:],
		[]Database_Value{102, 2, database_string_make("Gadget")},
	)
	set_database_tables(users_table, orders_table)

	result, ok := exec(
		"SELECT * FROM users WHERE id NOT IN (SELECT user_id FROM orders)",
		clear_msgs = true,
	)
	testing.expect(t, ok)
	{
		result := result.result.(Rows_With_Names)
		testing.expect_value(t, len(result.rows), 1)
		testing.expect(t, value_exactly_equal(result.rows[0][0], 3))
		testing.expect(t, value_exactly_equal(result.rows[0][1], database_string_make("Charlie")))
	}
}

@(test)
db_test_in_operator_with_complex_subquery :: proc(t: ^testing.T) {
	defer main_finish()
	main_init()
	database_tests_clear()
	users_cols := make([dynamic]string, context.allocator)
	append_elems(&users_cols, ..[]string{"id", "name", "age", "status"})
	// users_table := Table {
	// 	name                     = "users",
	// 	column_names             = users_cols,
	// 	primary_key_column_index = 0,
	// }
	// table_init(&users_table, alloc)
	users_table: Table
	table_init(
		&users_table,
		name = "users",
		column_names = users_cols,
		primary_key_column_index = 0,
	)
	must_insert_row(
		&users_table,
		users_cols[:],
		[]Database_Value{1, database_string_make("Alice"), 25, database_string_make("active")},
	)
	must_insert_row(
		&users_table,
		users_cols[:],
		[]Database_Value{2, database_string_make("Bob"), 30, database_string_make("inactive")},
	)
	must_insert_row(
		&users_table,
		users_cols[:],
		[]Database_Value{3, database_string_make("Charlie"), 35, database_string_make("active")},
	)
	must_insert_row(
		&users_table,
		users_cols[:],
		[]Database_Value{4, database_string_make("David"), 40, database_string_make("inactive")},
	)
	orders_cols := make([dynamic]string, context.allocator)
	append_elems(&orders_cols, ..[]string{"id", "user_id", "amount"})
	// orders_table := Table {
	// 	name                     = "orders",
	// 	column_names             = orders_cols,
	// 	primary_key_column_index = 0,
	// }
	// table_init(&orders_table, alloc)
	orders_table: Table
	table_init(
		&orders_table,
		name = "orders",
		column_names = orders_cols,
		primary_key_column_index = 0,
	)
	must_insert_row(&orders_table, orders_cols[:], []Database_Value{101, 1, 100})
	must_insert_row(&orders_table, orders_cols[:], []Database_Value{102, 2, 200})
	must_insert_row(&orders_table, orders_cols[:], []Database_Value{103, 1, 150})
	set_database_tables(users_table, orders_table)

	result, ok := exec(
		"SELECT * FROM users WHERE id IN (SELECT user_id FROM orders WHERE amount > 100)",
		clear_msgs = true,
	)
	testing.expect(t, ok)
	{
		result := result.result.(Rows_With_Names)
		testing.expect_value(t, len(result.rows), 2)
	}
}

@(test)
db_test_in_operator_with_empty_subquery :: proc(t: ^testing.T) {
	defer main_finish()
	main_init()
	database_tests_clear()
	users_cols := make([dynamic]string, context.allocator)
	append_elems(&users_cols, ..[]string{"id", "name", "age", "status"})
	// users_table := Table {
	// 	name                     = "users",
	// 	column_names             = users_cols,
	// 	primary_key_column_index = 0,
	// }
	// table_init(&users_table, alloc)
	users_table: Table
	table_init(
		&users_table,
		name = "users",
		column_names = users_cols,
		primary_key_column_index = 0,
	)
	must_insert_row(
		&users_table,
		users_cols[:],
		[]Database_Value{1, database_string_make("Alice"), 25, database_string_make("active")},
	)
	must_insert_row(
		&users_table,
		users_cols[:],
		[]Database_Value{2, database_string_make("Bob"), 30, database_string_make("inactive")},
	)
	orders_cols := make([dynamic]string, context.allocator)
	append_elems(&orders_cols, ..[]string{"id", "user_id", "product"})
	// orders_table := Table {
	// 	name                     = "orders",
	// 	column_names             = orders_cols,
	// 	primary_key_column_index = 0,
	// }
	// table_init(&orders_table, alloc)
	orders_table: Table
	table_init(
		&orders_table,
		name = "orders",
		column_names = orders_cols,
		primary_key_column_index = 0,
	)
	set_database_tables(users_table, orders_table)

	result, ok := exec(
		"SELECT * FROM users WHERE id IN (SELECT user_id FROM orders)",
		clear_msgs = true,
	)
	testing.expect(t, ok)
	{
		result := result.result.(Rows_With_Names)
		testing.expect_value(t, len(result.rows), 0)
	}
}

@(test)
db_test_in_operator_with_value_list :: proc(t: ^testing.T) {
	defer main_finish()
	main_init()
	seed_database()
	result, ok := exec("SELECT * FROM users WHERE name IN ('John', 'Kate')", clear_msgs = true)
	testing.expect(t, ok)
	{
		result := result.result.(Rows_With_Names)
		testing.expect_value(t, len(result.rows), 2)
	}
}

@(test)
db_test_not_in_operator_with_value_list :: proc(t: ^testing.T) {
	defer main_finish()
	main_init()
	seed_database()
	result, ok := exec("SELECT * FROM users WHERE name NOT IN ('John', 'Kate')", clear_msgs = true)
	testing.expect(t, ok)
	{
		result := result.result.(Rows_With_Names)
		testing.expect_value(t, len(result.rows), 2)
		testing.expect(t, value_exactly_equal(result.rows[0][1], database_string_make("Matthew")))
		testing.expect(t, value_exactly_equal(result.rows[1][1], database_string_make("Rose")))
	}
}

@(test)
db_test_like_operator :: proc(t: ^testing.T) {
	defer main_finish()
	main_init()
	database_tests_clear()
	users_cols := make([dynamic]string, context.allocator)
	append_elems(&users_cols, ..[]string{"id", "name", "email"})
	// users_table := Table {
	// 	name                     = "users",
	// 	column_names             = users_cols,
	// 	primary_key_column_index = 0,
	// }
	// table_init(&users_table, alloc)
	users_table: Table
	table_init(
		&users_table,
		name = "users",
		column_names = users_cols,
		primary_key_column_index = 0,
	)
	must_insert_row(
		&users_table,
		users_cols[:],
		[]Database_Value {
			1,
			database_string_make("Alice"),
			database_string_make("alice@example.com"),
		},
	)
	must_insert_row(
		&users_table,
		users_cols[:],
		[]Database_Value{2, database_string_make("Bob"), database_string_make("bob@test.org")},
	)
	must_insert_row(
		&users_table,
		users_cols[:],
		[]Database_Value {
			3,
			database_string_make("Charlie"),
			database_string_make("charlie@demo.net"),
		},
	)
	set_database_tables(users_table)

	result, ok := exec("SELECT * FROM users WHERE name LIKE 'A%'", clear_msgs = true)
	testing.expect(t, ok)
	{
		result := result.result.(Rows_With_Names)
		testing.expect_value(t, len(result.rows), 1)
		testing.expect(t, value_exactly_equal(result.rows[0][0], 1))
		testing.expect(t, value_exactly_equal(result.rows[0][1], database_string_make("Alice")))
	}

	result2, ok2 := exec("SELECT * FROM users WHERE name LIKE 'B_b'", clear_msgs = true)
	testing.expect(t, ok2)
	{
		result := result2.result.(Rows_With_Names)
		testing.expect_value(t, len(result.rows), 1)
		testing.expect(t, value_exactly_equal(result.rows[0][0], 2))
		testing.expect(t, value_exactly_equal(result.rows[0][1], database_string_make("Bob")))
	}

	result3, ok3 := exec("SELECT * FROM users WHERE email LIKE '%@example.com'", clear_msgs = true)
	testing.expect(t, ok3)
	{
		result := result3.result.(Rows_With_Names)
		testing.expect_value(t, len(result.rows), 1)
		testing.expect(t, value_exactly_equal(result.rows[0][0], 1))
	}
}

@(test)
db_test_not_like_operator :: proc(t: ^testing.T) {
	defer main_finish()
	main_init()
	database_tests_clear()
	users_cols := make([dynamic]string, context.allocator)
	append_elems(&users_cols, ..[]string{"id", "name", "email"})
	// users_table := Table {
	// 	name                     = "users",
	// 	column_names             = users_cols,
	// 	primary_key_column_index = 0,
	// }
	// table_init(&users_table, alloc)
	users_table: Table
	table_init(
		&users_table,
		name = "users",
		column_names = users_cols,
		primary_key_column_index = 0,
	)
	must_insert_row(
		&users_table,
		users_cols[:],
		[]Database_Value {
			1,
			database_string_make("Alice"),
			database_string_make("alice@example.com"),
		},
	)
	must_insert_row(
		&users_table,
		users_cols[:],
		[]Database_Value{2, database_string_make("Bob"), database_string_make("bob@test.org")},
	)
	must_insert_row(
		&users_table,
		users_cols[:],
		[]Database_Value {
			3,
			database_string_make("Charlie"),
			database_string_make("charlie@demo.net"),
		},
	)
	set_database_tables(users_table)

	result, ok := exec("SELECT * FROM users WHERE name NOT LIKE 'A%'", clear_msgs = true)
	testing.expect(t, ok)
	{
		result := result.result.(Rows_With_Names)
		testing.expect_value(t, len(result.rows), 2)
	}
}

@(test)
db_test_between_operator :: proc(t: ^testing.T) {
	defer main_finish()
	main_init()
	database_tests_clear()
	users_cols := make([dynamic]string, context.allocator)
	append_elems(&users_cols, ..[]string{"id", "name", "age"})
	// users_table := Table {
	// 	name                     = "users",
	// 	column_names             = users_cols,
	// 	primary_key_column_index = 0,
	// }
	// table_init(&users_table, alloc)
	users_table: Table
	table_init(
		&users_table,
		name = "users",
		column_names = users_cols,
		primary_key_column_index = 0,
	)
	must_insert_row(
		&users_table,
		users_cols[:],
		[]Database_Value{1, database_string_make("Alice"), 25},
	)
	must_insert_row(
		&users_table,
		users_cols[:],
		[]Database_Value{2, database_string_make("Bob"), 30},
	)
	must_insert_row(
		&users_table,
		users_cols[:],
		[]Database_Value{3, database_string_make("Charlie"), 35},
	)
	set_database_tables(users_table)

	result, ok := exec("SELECT * FROM users WHERE age BETWEEN 25 AND 30", clear_msgs = true)
	testing.expect(t, ok)
	{
		result := result.result.(Rows_With_Names)
		testing.expect_value(t, len(result.rows), 2)
		testing.expect(t, value_exactly_equal(result.rows[0][0], 1))
		testing.expect(t, value_exactly_equal(result.rows[0][1], database_string_make("Alice")))
		testing.expect(t, value_exactly_equal(result.rows[0][2], 25))
		testing.expect(t, value_exactly_equal(result.rows[1][0], 2))
		testing.expect(t, value_exactly_equal(result.rows[1][1], database_string_make("Bob")))
		testing.expect(t, value_exactly_equal(result.rows[1][2], 30))
	}

	result2, ok2 := exec("SELECT * FROM users WHERE age NOT BETWEEN 25 AND 30", clear_msgs = true)
	testing.expect(t, ok2)
	{
		result := result2.result.(Rows_With_Names)
		testing.expect_value(t, len(result.rows), 1)
		testing.expect(t, value_exactly_equal(result.rows[0][0], 3))
		testing.expect(t, value_exactly_equal(result.rows[0][1], database_string_make("Charlie")))
		testing.expect(t, value_exactly_equal(result.rows[0][2], 35))
	}
}

@(test)
db_test_select_subquery_1 :: proc(t: ^testing.T) {
	defer main_finish()
	main_init()
	seed_database()
	result, ok := exec("SELECT * FROM (SELECT name FROM users WHERE age > 25)", clear_msgs = true)
	testing.expect(t, ok)
	{
		result := result.result.(Rows_With_Names)
		testing.expect_value(t, len(result.rows), 2)
		testing.expect(t, value_exactly_equal(result.rows[0][0], database_string_make("Kate")))
		testing.expect(t, value_exactly_equal(result.rows[1][0], database_string_make("Rose")))
	}
}

@(test)
db_test_select_subquery_2 :: proc(t: ^testing.T) {
	defer main_finish()
	main_init()
	seed_database()
	result, ok := exec("SELECT name FROM (SELECT * FROM users) WHERE age > 25", clear_msgs = true)
	testing.expect(t, ok)
	{
		result := result.result.(Rows_With_Names)
		testing.expect_value(t, len(result.rows), 2)
		testing.expect(t, value_exactly_equal(result.rows[0][0], database_string_make("Kate")))
		testing.expect(t, value_exactly_equal(result.rows[1][0], database_string_make("Rose")))
	}
}

@(test)
db_test_select_subquery_3 :: proc(t: ^testing.T) {
	defer main_finish()
	main_init()
	seed_database()
	result, ok := exec("SELECT name FROM (SELECT * FROM users WHERE age > 25)", clear_msgs = true)
	testing.expect(t, ok)
	{
		result := result.result.(Rows_With_Names)
		testing.expect_value(t, len(result.rows), 2)
		testing.expect(t, value_exactly_equal(result.rows[0][0], database_string_make("Kate")))
		testing.expect(t, value_exactly_equal(result.rows[1][0], database_string_make("Rose")))
	}
}

@(test)
db_test_select_subquery_4 :: proc(t: ^testing.T) {
	defer main_finish()
	main_init()
	seed_database()
	result, ok := exec(
		"SELECT name FROM (SELECT name, age FROM users) WHERE age > 25",
		clear_msgs = true,
	)
	testing.expect(t, ok)
	{
		result := result.result.(Rows_With_Names)
		testing.expect_value(t, len(result.rows), 2)
		testing.expect(t, value_exactly_equal(result.rows[0][0], database_string_make("Kate")))
		testing.expect(t, value_exactly_equal(result.rows[1][0], database_string_make("Rose")))
	}
}

@(test)
db_test_alt_eq_op :: proc(t: ^testing.T) {
	defer main_finish()
	main_init()
	seed_database()
	result, ok := exec("SELECT * FROM users WHERE name == 'Kate'", clear_msgs = true)
	testing.expect(t, ok)
	{
		result := result.result.(Rows_With_Names)
		testing.expect_value(t, len(result.rows), 1)
		testing.expect(t, value_exactly_equal(result.rows[0][1], database_string_make("Kate")))
	}
}

@(test)
db_test_alt_uneq_op :: proc(t: ^testing.T) {
	defer main_finish()
	main_init()
	seed_database()
	result, ok := exec(
		"SELECT * FROM users WHERE name <> 'Kate' AND name <> 'Rose' AND name <> 'John'",
		clear_msgs = true,
	)
	testing.expect(t, ok)
	{
		result := result.result.(Rows_With_Names)
		testing.expect_value(t, len(result.rows), 1)
		testing.expect(t, value_exactly_equal(result.rows[0][1], database_string_make("Matthew")))
	}
}

@(test)
db_test_subquery_with_multiple_filters :: proc(t: ^testing.T) {
	defer main_finish()
	main_init()
	seed_database()
	result, ok := exec(
		"SELECT name, age FROM (SELECT * FROM users WHERE age >= 25 AND status = 'inactive')",
		clear_msgs = true,
	)
	testing.expect(t, ok)
	{
		result := result.result.(Rows_With_Names)
		testing.expect_value(t, len(result.rows), 2)
		testing.expect(t, value_exactly_equal(result.rows[0][0], database_string_make("Kate")))
		testing.expect(t, value_exactly_equal(result.rows[0][1], 30))
		testing.expect(t, value_exactly_equal(result.rows[1][0], database_string_make("Rose")))
		testing.expect(t, value_exactly_equal(result.rows[1][1], 30))
	}
}

@(test)
db_test_subquery_column_projection :: proc(t: ^testing.T) {
	defer main_finish()
	main_init()
	seed_database()
	result, ok := exec(
		"SELECT * FROM (SELECT name, status FROM users WHERE age > 20)",
		clear_msgs = true,
	)
	testing.expect(t, ok)
	{
		result := result.result.(Rows_With_Names)
		testing.expect_value(t, len(result.rows), 3)
		testing.expect(t, value_exactly_equal(result.rows[0][0], database_string_make("John")))
		testing.expect(t, value_exactly_equal(result.rows[0][1], database_string_make("active")))
		testing.expect(t, value_exactly_equal(result.rows[1][0], database_string_make("Kate")))
		testing.expect(t, value_exactly_equal(result.rows[1][1], database_string_make("inactive")))
		testing.expect(t, value_exactly_equal(result.rows[2][0], database_string_make("Rose")))
		testing.expect(t, value_exactly_equal(result.rows[2][1], database_string_make("inactive")))
	}
}

@(test)
db_test_subquery_outer_filter_refines_inner :: proc(t: ^testing.T) {
	defer main_finish()
	main_init()
	seed_database()
	result, ok := exec(
		"SELECT name FROM (SELECT * FROM users WHERE age >= 25) WHERE status = 'inactive'",
		clear_msgs = true,
	)
	testing.expect(t, ok)
	{
		result := result.result.(Rows_With_Names)
		testing.expect_value(t, len(result.rows), 2)
		testing.expect(t, value_exactly_equal(result.rows[0][0], database_string_make("Kate")))
		testing.expect(t, value_exactly_equal(result.rows[1][0], database_string_make("Rose")))
	}
}

@(test)
db_test_join_with_complex_condition :: proc(t: ^testing.T) {
	defer main_finish()
	main_init()
	database_tests_clear()
	_, ok1 := exec("CREATE TABLE users (id, name, age, PRIMARY KEY (id))", clear_msgs = true)
	testing.expect(t, ok1)

	_, ok2 := exec(
		"CREATE TABLE orders (id, user_id, product, PRIMARY KEY (id))",
		clear_msgs = true,
	)
	testing.expect(t, ok2)

	_, ok3 := exec("INSERT INTO users VALUES (1, 'Kate', 30)", clear_msgs = true)
	testing.expect(t, ok3)

	_, ok4 := exec("INSERT INTO users VALUES (2, 'John', 25)", clear_msgs = true)
	testing.expect(t, ok4)

	_, ok5 := exec("INSERT INTO orders VALUES (101, 1, 'Mouse')", clear_msgs = true)
	testing.expect(t, ok5)

	_, ok6 := exec("INSERT INTO orders VALUES (102, 1, 'Keyboard')", clear_msgs = true)
	testing.expect(t, ok6)

	result, ok := exec(
		"SELECT users.name, orders.product FROM users INNER JOIN orders ON users.id = orders.user_id WHERE users.age >= 30 AND orders.product != 'Keyboard'",
		clear_msgs = true,
	)
	testing.expect(t, ok)
	{
		result := result.result.(Rows_With_Names)
		testing.expect_value(t, len(result.rows), 1)
		testing.expect(
			t,
			value_exactly_equal(rows_cell(result, 0, "users.name"), database_string_make("Kate")),
		)
		testing.expect(
			t,
			value_exactly_equal(
				rows_cell(result, 0, "orders.product"),
				database_string_make("Mouse"),
			),
		)
	}
}

@(test)
db_test_in_with_multiple_values_complex :: proc(t: ^testing.T) {
	defer main_finish()
	main_init()
	seed_database()
	result, ok := exec(
		"SELECT name, age FROM users WHERE status IN ('active', 'pending', 'inactive') AND age > 25",
		clear_msgs = true,
	)
	testing.expect(t, ok)
	{
		result := result.result.(Rows_With_Names)
		testing.expect_value(t, len(result.rows), 2)
		testing.expect(t, value_exactly_equal(result.rows[0][0], database_string_make("Kate")))
		testing.expect(t, value_exactly_equal(result.rows[1][0], database_string_make("Rose")))
	}
}

@(test)
db_test_not_in_with_subquery_filter :: proc(t: ^testing.T) {
	defer main_finish()
	main_init()
	seed_database()
	result, ok := exec(
		"SELECT name FROM users WHERE status NOT IN ('active') AND age >= 25",
		clear_msgs = true,
	)
	testing.expect(t, ok)
	{
		result := result.result.(Rows_With_Names)
		testing.expect_value(t, len(result.rows), 2)
		testing.expect(t, value_exactly_equal(result.rows[0][0], database_string_make("Kate")))
		testing.expect(t, value_exactly_equal(result.rows[1][0], database_string_make("Rose")))
	}
}

@(test)
db_test_between_with_additional_conditions :: proc(t: ^testing.T) {
	defer main_finish()
	main_init()
	seed_database()
	result, ok := exec(
		"SELECT name, age FROM users WHERE age BETWEEN 20 AND 30 AND status = 'active'",
		clear_msgs = true,
	)
	testing.expect(t, ok)
	{
		result := result.result.(Rows_With_Names)
		testing.expect_value(t, len(result.rows), 1)
		testing.expect(t, value_exactly_equal(result.rows[0][0], database_string_make("John")))
		testing.expect(t, value_exactly_equal(result.rows[0][1], 25))
	}
}

@(test)
db_test_complex_or_and_precedence :: proc(t: ^testing.T) {
	defer main_finish()
	main_init()
	seed_database()
	result, ok := exec(
		"SELECT name FROM users WHERE (age < 20 OR age > 28) AND status = 'inactive'",
		clear_msgs = true,
	)
	testing.expect(t, ok)
	{
		result := result.result.(Rows_With_Names)
		testing.expect_value(t, len(result.rows), 2)
		testing.expect(t, value_exactly_equal(result.rows[0][0], database_string_make("Kate")))
		testing.expect(t, value_exactly_equal(result.rows[1][0], database_string_make("Rose")))
	}
}

@(test)
db_test_subquery_all_columns_specific_output :: proc(t: ^testing.T) {
	defer main_finish()
	main_init()
	seed_database()
	result, ok := exec(
		"SELECT id, name FROM (SELECT * FROM users) WHERE age = 25",
		clear_msgs = true,
	)
	testing.expect(t, ok)
	{
		result := result.result.(Rows_With_Names)
		testing.expect_value(t, len(result.rows), 1)
		testing.expect(t, value_exactly_equal(result.rows[0][0], 2))
		testing.expect(t, value_exactly_equal(result.rows[0][1], database_string_make("John")))
	}
}

@(test)
db_test_update_with_complex_where2 :: proc(t: ^testing.T) {
	defer main_finish()
	main_init()
	seed_database()
	result, ok := exec(
		"UPDATE users SET status = 'archived' WHERE age > 25 AND status = 'inactive'",
		clear_msgs = true,
	)
	testing.expect(t, ok)
	testing.expect_value(t, result.result.(int), 2)

	verify, verify_ok := exec(
		"SELECT name, status FROM users WHERE status = 'archived'",
		clear_msgs = true,
	)
	testing.expect(t, verify_ok)
	{
		verify := verify.result.(Rows_With_Names)
		testing.expect_value(t, len(verify.rows), 2)
		testing.expect(t, value_exactly_equal(verify.rows[0][0], database_string_make("Kate")))
		testing.expect(t, value_exactly_equal(verify.rows[0][1], database_string_make("archived")))
		testing.expect(t, value_exactly_equal(verify.rows[1][0], database_string_make("Rose")))
		testing.expect(t, value_exactly_equal(verify.rows[1][1], database_string_make("archived")))
	}
}

@(test)
db_test_delete_with_not_between :: proc(t: ^testing.T) {
	defer main_finish()
	main_init()
	seed_database()
	result, ok := exec("DELETE FROM users WHERE age NOT BETWEEN 20 AND 29", clear_msgs = true)
	testing.expect(t, ok)
	testing.expect_value(t, result.result.(int), 3)

	verify, verify_ok := exec("SELECT name FROM users", clear_msgs = true)
	testing.expect(t, verify_ok)
	{
		verify := verify.result.(Rows_With_Names)
		testing.expect_value(t, len(verify.rows), 1)
		testing.expect(t, value_exactly_equal(verify.rows[0][0], database_string_make("John")))
	}
}

@(test)
db_test_left_join_with_like_filter :: proc(t: ^testing.T) {
	defer main_finish()
	main_init()
	database_tests_clear()
	_, ok1 := exec("CREATE TABLE users (id, name, PRIMARY KEY (id))", clear_msgs = true)
	testing.expect(t, ok1)

	_, ok2 := exec(
		"CREATE TABLE orders (id, user_id, product, PRIMARY KEY (id))",
		clear_msgs = true,
	)
	testing.expect(t, ok2)

	_, ok3 := exec("INSERT INTO users VALUES (1, 'Kate')", clear_msgs = true)
	testing.expect(t, ok3)

	_, ok4 := exec("INSERT INTO users VALUES (2, 'Rose')", clear_msgs = true)
	testing.expect(t, ok4)

	_, ok5 := exec("INSERT INTO users VALUES (3, 'John')", clear_msgs = true)
	testing.expect(t, ok5)

	_, ok6 := exec("INSERT INTO orders VALUES (101, 1, 'Mouse')", clear_msgs = true)
	testing.expect(t, ok6)

	result, ok := exec(
		"SELECT users.name, orders.product FROM users LEFT JOIN orders ON users.id = orders.user_id WHERE users.name LIKE 'K%' OR users.name LIKE 'R%'",
		clear_msgs = true,
	)
	testing.expect(t, ok)
	{
		result := result.result.(Rows_With_Names)
		testing.expect_value(t, len(result.rows), 2)
		testing.expect(
			t,
			value_exactly_equal(rows_cell(result, 0, "users.name"), database_string_make("Kate")),
		)
		testing.expect(
			t,
			value_exactly_equal(
				rows_cell(result, 0, "orders.product"),
				database_string_make("Mouse"),
			),
		)
		testing.expect(
			t,
			value_exactly_equal(rows_cell(result, 1, "users.name"), database_string_make("Rose")),
		)
		testing.expect(t, value_exactly_equal(rows_cell(result, 1, "orders.product"), nil))
	}
}

@(test)
db_test_pk_where_eq_uses_tree :: proc(t: ^testing.T) {
	testing_run_query(t, "SELECT * FROM users WHERE id = 3", nil, proc() {
		testing_prepare_database(
			{
				name = "users",
				column_names = {"id", "name", "age", "status"},
				primary_key_column_index = 0,
				rows = {
					{1, database_string_make("Matthew"), 15, database_string_make("active")},
					{2, database_string_make("John"), 25, database_string_make("active")},
					{3, database_string_make("Kate"), 30, database_string_make("inactive")},
					{4, database_string_make("Rose"), 30, database_string_make("inactive")},
				},
			},
		)
	}, proc(t: ^testing.T, result: Exec_Result, user_data: rawptr) {
		testing_compare_rows_UNordered(
			t,
			result.result.(Rows_With_Names),
			{"id", "name", "age", "status"},
			{{3, database_string_make("Kate"), 30, database_string_make("inactive")}},
		)
	})
}

@(test)
db_test_pk_where_range :: proc(t: ^testing.T) {
	testing_run_query(t, "SELECT * FROM users WHERE id >= 2 AND id <= 3", nil, proc() {
		testing_prepare_database(
			{
				name = "users",
				column_names = {"id", "name", "age", "status"},
				primary_key_column_index = 0,
				rows = {
					{1, database_string_make("Matthew"), 15, database_string_make("active")},
					{2, database_string_make("John"), 25, database_string_make("active")},
					{3, database_string_make("Kate"), 30, database_string_make("inactive")},
					{4, database_string_make("Rose"), 30, database_string_make("inactive")},
				},
			},
		)
	}, proc(t: ^testing.T, result: Exec_Result, user_data: rawptr) {
		testing_compare_rows_UNordered(
			t,
			result.result.(Rows_With_Names),
			{"id", "name", "age", "status"},
			{
				{2, database_string_make("John"), 25, database_string_make("active")},
				{3, database_string_make("Kate"), 30, database_string_make("inactive")},
			},
		)
	})
}

@(test)
db_test_pk_where_in :: proc(t: ^testing.T) {
	testing_run_query(t, "SELECT * FROM users WHERE id IN (1, 4)", nil, proc() {
		testing_prepare_database(
			{
				name = "users",
				column_names = {"id", "name", "age", "status"},
				primary_key_column_index = 0,
				rows = {
					{1, database_string_make("Matthew"), 15, database_string_make("active")},
					{2, database_string_make("John"), 25, database_string_make("active")},
					{3, database_string_make("Kate"), 30, database_string_make("inactive")},
					{4, database_string_make("Rose"), 30, database_string_make("inactive")},
				},
			},
		)
	}, proc(t: ^testing.T, result: Exec_Result, user_data: rawptr) {
		testing_compare_rows_UNordered(
			t,
			result.result.(Rows_With_Names),
			{"id", "name", "age", "status"},
			{
				{1, database_string_make("Matthew"), 15, database_string_make("active")},
				{4, database_string_make("Rose"), 30, database_string_make("inactive")},
			},
		)
	})
}

@(test)
db_test_pk_where_and_non_pk :: proc(t: ^testing.T) {
	testing_run_query(t, "SELECT * FROM users WHERE id = 2 AND name = 'John'", nil, proc() {
		testing_prepare_database(
			{
				name = "users",
				column_names = {"id", "name", "age", "status"},
				primary_key_column_index = 0,
				rows = {
					{1, database_string_make("Matthew"), 15, database_string_make("active")},
					{2, database_string_make("John"), 25, database_string_make("active")},
					{3, database_string_make("Kate"), 30, database_string_make("inactive")},
					{4, database_string_make("Rose"), 30, database_string_make("inactive")},
				},
			},
		)
	}, proc(t: ^testing.T, result: Exec_Result, user_data: rawptr) {
		testing_compare_rows_UNordered(
			t,
			result.result.(Rows_With_Names),
			{"id", "name", "age", "status"},
			{{2, database_string_make("John"), 25, database_string_make("active")}},
		)
	})
}

@(test)
db_test_pk_where_or_equals :: proc(t: ^testing.T) {
	testing_run_query(t, "SELECT * FROM users WHERE id = 1 OR id = 4", nil, proc() {
		testing_prepare_database(
			{
				name = "users",
				column_names = {"id", "name", "age", "status"},
				primary_key_column_index = 0,
				rows = {
					{1, database_string_make("Matthew"), 15, database_string_make("active")},
					{2, database_string_make("John"), 25, database_string_make("active")},
					{3, database_string_make("Kate"), 30, database_string_make("inactive")},
					{4, database_string_make("Rose"), 30, database_string_make("inactive")},
				},
			},
		)
	}, proc(t: ^testing.T, result: Exec_Result, user_data: rawptr) {
		testing_compare_rows_UNordered(
			t,
			result.result.(Rows_With_Names),
			{"id", "name", "age", "status"},
			{
				{1, database_string_make("Matthew"), 15, database_string_make("active")},
				{4, database_string_make("Rose"), 30, database_string_make("inactive")},
			},
		)
	})
}

@(test)
db_test_delete_maintains_pk_tree :: proc(t: ^testing.T) {
	defer main_finish()
	main_init()
	seed_database()
	//
	del, ok := exec("DELETE FROM users WHERE id = 3", clear_msgs = true)
	testing.expect(t, ok)
	testing.expect_value(t, del.result.(int), 1)

	empty, ok2 := exec("SELECT * FROM users WHERE id = 3", clear_msgs = true)
	testing.expect(t, ok2)
	testing.expect_value(t, len(empty.result.(Rows_With_Names).rows), 0)

	by_id, ok3 := exec("SELECT * FROM users WHERE id = 1", clear_msgs = true)
	testing.expect(t, ok3)
	r := by_id.result.(Rows_With_Names)
	testing.expect_value(t, len(r.rows), 1)
	testing.expect(
		t,
		value_exactly_equal(rows_cell(r, 0, "name"), database_string_make("Matthew")),
	)
}

@(test)
db_test_select_order_by_limit_offset :: proc(t: ^testing.T) {
	testing_run_query(
		t,
		"SELECT name, age FROM users ORDER BY age DESC, name ASC LIMIT 2 OFFSET 1",
		nil,
		proc() {
			testing_prepare_database(
				{
					name = "users",
					column_names = {"id", "name", "age", "status"},
					primary_key_column_index = 0,
					rows = {
						{1, database_string_make("Matthew"), 15, database_string_make("active")},
						{2, database_string_make("John"), 25, database_string_make("active")},
						{3, database_string_make("Kate"), 30, database_string_make("inactive")},
						{4, database_string_make("Rose"), 30, database_string_make("inactive")},
					},
				},
			)
		},
		proc(t: ^testing.T, result: Exec_Result, user_data: rawptr) {
			testing_compare_rows_ordered(
				t,
				result.result.(Rows_With_Names),
				{"name", "age"},
				{{database_string_make("Rose"), 30}, {database_string_make("John"), 25}},
			)
		},
	)
}

@(test)
db_test_create_index_supports_where_and_order_by :: proc(t: ^testing.T) {
	defer main_finish()
	main_init()
	seed_database()


	create_result, create_ok := exec(
		"CREATE INDEX users_age_idx ON users (age)",
		clear_msgs = true,
	)
	testing.expect(t, create_ok)
	{
		got_nil := create_result.result == nil
		testing.expect(t, got_nil)
	}

	filtered, filtered_ok := exec(
		"SELECT name FROM users WHERE age = 30 ORDER BY name ASC",
		clear_msgs = true,
	)
	testing.expect(t, filtered_ok)
	filtered_rows := filtered.result.(Rows_With_Names)
	testing.expect_value(t, len(filtered_rows.rows), 2)
	testing.expect(
		t,
		value_exactly_equal(rows_cell(filtered_rows, 0, "name"), database_string_make("Kate")),
	)
	testing.expect(
		t,
		value_exactly_equal(rows_cell(filtered_rows, 1, "name"), database_string_make("Rose")),
	)

	ordered, ordered_ok := exec(
		"SELECT id, age FROM users ORDER BY age ASC, id ASC",
		clear_msgs = true,
	)
	testing.expect(t, ordered_ok)
	ordered_rows := ordered.result.(Rows_With_Names)
	testing.expect(t, value_exactly_equal(rows_cell(ordered_rows, 0, "id"), 1))
	testing.expect(t, value_exactly_equal(rows_cell(ordered_rows, 1, "id"), 2))
	testing.expect(t, value_exactly_equal(rows_cell(ordered_rows, 2, "id"), 3))
	testing.expect(t, value_exactly_equal(rows_cell(ordered_rows, 3, "id"), 4))
}

@(test)
db_test_secondary_index_kept_consistent_after_update_and_delete :: proc(t: ^testing.T) {
	defer main_finish()
	main_init()
	seed_database()


	index_result, idx_ok := exec(
		"CREATE INDEX users_status_idx ON users (status)",
		clear_msgs = true,
	)
	testing.expect(t, idx_ok)
	{
		got_nil := index_result.result == nil
		testing.expect(t, got_nil)
	}

	upd, upd_ok := exec("UPDATE users SET status = 'archived' WHERE id = 3", clear_msgs = true)
	testing.expect(t, upd_ok)
	testing.expect_value(t, upd.result.(int), 1)

	archived, arch_ok := exec("SELECT id FROM users WHERE status = 'archived'", clear_msgs = true)
	testing.expect(t, arch_ok)
	arch_rows := archived.result.(Rows_With_Names)
	testing.expect_value(t, len(arch_rows.rows), 1)
	testing.expect(t, value_exactly_equal(rows_cell(arch_rows, 0, "id"), 3))

	del, del_ok := exec("DELETE FROM users WHERE id = 4", clear_msgs = true)
	testing.expect(t, del_ok)
	testing.expect_value(t, del.result.(int), 1)

	inactive, inactive_ok := exec(
		"SELECT id FROM users WHERE status = 'inactive'",
		clear_msgs = true,
	)
	testing.expect(t, inactive_ok)
	inactive_rows := inactive.result.(Rows_With_Names)
	testing.expect_value(t, len(inactive_rows.rows), 0)
}

@(test)
db_test_secondary_index_interval_bounds :: proc(t: ^testing.T) {
	defer main_finish()
	main_init()
	seed_database()

	_, idx_ok := exec("CREATE INDEX users_age_idx ON users (age)", clear_msgs = true)
	testing.expect(t, idx_ok)

	users, users_ok := database_find_table("users", log_error = false)
	testing.expect(t, users_ok)
	age_idx_pos, age_ix_ok := index_find_by_column(users, 2)
	testing.expect(t, age_ix_ok)
	_, pk_idx_pos := table_primary_index(users)

	ge, ge_ok := exec("SELECT id FROM users WHERE age >= 25 ORDER BY id ASC", clear_msgs = true)
	testing.expect(t, ge_ok)
	testing.expect(t, len(ge.plans) > 0)
	ge_plan := ge.plans[len(ge.plans) - 1]
	testing.expect_value(t, ge_plan.where_index_position, age_idx_pos)
	testing.expect_value(t, ge_plan.order_index_position, pk_idx_pos)
	ge_rows := ge.result.(Rows_With_Names)
	testing.expect_value(t, len(ge_rows.rows), 3)
	testing.expect(t, value_exactly_equal(rows_cell(ge_rows, 0, "id"), 2))
	testing.expect(t, value_exactly_equal(rows_cell(ge_rows, 1, "id"), 3))
	testing.expect(t, value_exactly_equal(rows_cell(ge_rows, 2, "id"), 4))

	gt, gt_ok := exec("SELECT id FROM users WHERE age > 25 ORDER BY id ASC", clear_msgs = true)
	testing.expect(t, gt_ok)
	testing.expect(t, len(gt.plans) > 0)
	gt_plan := gt.plans[len(gt.plans) - 1]
	testing.expect_value(t, gt_plan.where_index_position, age_idx_pos)
	testing.expect_value(t, gt_plan.order_index_position, pk_idx_pos)
	gt_rows := gt.result.(Rows_With_Names)
	testing.expect_value(t, len(gt_rows.rows), 2)
	testing.expect(t, value_exactly_equal(rows_cell(gt_rows, 0, "id"), 3))
	testing.expect(t, value_exactly_equal(rows_cell(gt_rows, 1, "id"), 4))

	bounded, bounded_ok := exec(
		"SELECT id FROM users WHERE age >= 25 AND age < 30 ORDER BY id ASC",
		clear_msgs = true,
	)
	testing.expect(t, bounded_ok)
	testing.expect(t, len(bounded.plans) > 0)
	bounded_plan := bounded.plans[len(bounded.plans) - 1]
	testing.expect_value(t, bounded_plan.where_index_position, age_idx_pos)
	testing.expect_value(t, bounded_plan.order_index_position, pk_idx_pos)
	bounded_rows := bounded.result.(Rows_With_Names)
	testing.expect_value(t, len(bounded_rows.rows), 1)
	testing.expect(t, value_exactly_equal(rows_cell(bounded_rows, 0, "id"), 2))

	dupes, dupes_ok := exec(
		"SELECT id FROM users WHERE age = 30 ORDER BY id ASC",
		clear_msgs = true,
	)
	testing.expect(t, dupes_ok)
	testing.expect(t, len(dupes.plans) > 0)
	dupes_plan := dupes.plans[len(dupes.plans) - 1]
	testing.expect_value(t, dupes_plan.where_index_position, age_idx_pos)
	testing.expect_value(t, dupes_plan.order_index_position, pk_idx_pos)
	dupe_rows := dupes.result.(Rows_With_Names)
	testing.expect_value(t, len(dupe_rows.rows), 2)
	testing.expect(t, value_exactly_equal(rows_cell(dupe_rows, 0, "id"), 3))
	testing.expect(t, value_exactly_equal(rows_cell(dupe_rows, 1, "id"), 4))
}

@(test)
db_test_where_order_by_uses_limit_offset_safely :: proc(t: ^testing.T) {
	defer main_finish()
	main_init()
	seed_database()

	_, age_idx_ok := exec("CREATE INDEX users_age_idx ON users (age)", clear_msgs = true)
	testing.expect(t, age_idx_ok)

	result, ok := exec(
		"SELECT id, age FROM users WHERE age >= 15 ORDER BY age ASC LIMIT 2 OFFSET 1",
		clear_msgs = true,
	)
	testing.expect(t, ok)
	rows := result.result.(Rows_With_Names)
	testing.expect_value(t, len(rows.rows), 2)
	testing.expect(t, value_exactly_equal(rows_cell(rows, 0, "id"), 2))
	testing.expect(t, value_exactly_equal(rows_cell(rows, 0, "age"), 25))
	testing.expect(t, value_exactly_equal(rows_cell(rows, 1, "id"), 3))
	testing.expect(t, value_exactly_equal(rows_cell(rows, 1, "age"), 30))

	users, users_ok := database_find_table("users", log_error = false)
	testing.expect(t, users_ok)
	age_idx_pos, age_ix_ok := index_find_by_column(users, 2)
	testing.expect(t, age_ix_ok)

	testing.expect(t, len(result.plans) > 0)
	plan := result.plans[len(result.plans) - 1]
	testing.expect(t, plan.order_plan_available)
	testing.expect_value(t, plan.where_plan_kind, Where_Plan_Kind.Index)
	testing.expect_value(t, plan.chosen_strategy, Select_Scan_Strategy.Order_First)
	testing.expect(t, plan.used_order_scan)
	testing.expect_value(t, plan.where_index_position, age_idx_pos)
	testing.expect_value(t, plan.order_index_position, age_idx_pos)
}

@(test)
db_test_where_order_by_different_indexes_with_residual_predicate :: proc(t: ^testing.T) {
	defer main_finish()
	main_init()
	seed_database()

	_, status_idx_ok := exec("CREATE INDEX users_status_idx ON users (status)", clear_msgs = true)
	testing.expect(t, status_idx_ok)
	_, age_idx_ok := exec("CREATE INDEX users_age_idx ON users (age)", clear_msgs = true)
	testing.expect(t, age_idx_ok)

	result, ok := exec(
		"SELECT id, age FROM users WHERE status = 'inactive' AND name = 'Rose' ORDER BY age ASC LIMIT 1",
		clear_msgs = true,
	)
	testing.expect(t, ok)
	rows := result.result.(Rows_With_Names)
	testing.expect_value(t, len(rows.rows), 1)
	testing.expect(t, value_exactly_equal(rows_cell(rows, 0, "id"), 4))
	testing.expect(t, value_exactly_equal(rows_cell(rows, 0, "age"), 30))

	users, users_ok := database_find_table("users", log_error = false)
	testing.expect(t, users_ok)
	status_idx_pos, status_ix_ok := index_find_by_column(users, 3)
	testing.expect(t, status_ix_ok)
	age_idx_pos, age_ix_ok := index_find_by_column(users, 2)
	testing.expect(t, age_ix_ok)

	testing.expect(t, len(result.plans) > 0)
	plan := result.plans[len(result.plans) - 1]
	testing.expect(t, plan.order_plan_available)
	testing.expect_value(t, plan.where_plan_kind, Where_Plan_Kind.Index)
	testing.expect_value(t, plan.chosen_strategy, Select_Scan_Strategy.Where_First)
	testing.expect(t, !plan.used_order_scan)
	testing.expect_value(t, plan.where_index_position, status_idx_pos)
	testing.expect_value(t, plan.order_index_position, age_idx_pos)
}

@(test)
db_test_where_order_by_desc_uses_order_first_with_matching_index :: proc(t: ^testing.T) {
	defer main_finish()
	main_init()
	seed_database()

	_, age_idx_ok := exec("CREATE INDEX users_age_idx ON users (age)", clear_msgs = true)
	testing.expect(t, age_idx_ok)

	result, ok := exec(
		"SELECT id, age FROM users WHERE age >= 15 ORDER BY age DESC LIMIT 2",
		clear_msgs = true,
	)
	testing.expect(t, ok)
	rows := result.result.(Rows_With_Names)
	testing.expect_value(t, len(rows.rows), 2)
	testing.expect(t, value_exactly_equal(rows_cell(rows, 0, "id"), 3))
	testing.expect(t, value_exactly_equal(rows_cell(rows, 0, "age"), 30))
	testing.expect(t, value_exactly_equal(rows_cell(rows, 1, "id"), 4))
	testing.expect(t, value_exactly_equal(rows_cell(rows, 1, "age"), 30))

	testing.expect(t, len(result.plans) > 0)
	plan := result.plans[len(result.plans) - 1]
	testing.expect(t, plan.order_plan_available)
	testing.expect_value(t, plan.where_plan_kind, Where_Plan_Kind.Index)
	testing.expect_value(t, plan.chosen_strategy, Select_Scan_Strategy.Order_First)
	testing.expect(t, plan.used_order_scan)
}

@(test)
db_test_multikey_order_by_refines_ties_after_index_order_scan :: proc(t: ^testing.T) {
	defer main_finish()
	main_init()
	seed_database()

	_, age_idx_ok := exec("CREATE INDEX users_age_idx ON users (age)", clear_msgs = true)
	testing.expect(t, age_idx_ok)

	result, ok := exec(
		"SELECT id, age FROM users ORDER BY age DESC, id DESC LIMIT 2 OFFSET 1",
		clear_msgs = true,
	)
	testing.expect(t, ok)
	rows := result.result.(Rows_With_Names)
	testing.expect_value(t, len(rows.rows), 2)
	testing.expect(t, value_exactly_equal(rows_cell(rows, 0, "id"), 3))
	testing.expect(t, value_exactly_equal(rows_cell(rows, 0, "age"), 30))
	testing.expect(t, value_exactly_equal(rows_cell(rows, 1, "id"), 2))
	testing.expect(t, value_exactly_equal(rows_cell(rows, 1, "age"), 25))

	users, users_ok := database_find_table("users", log_error = false)
	testing.expect(t, users_ok)
	age_idx_pos, age_ix_ok := index_find_by_column(users, 2)
	testing.expect(t, age_ix_ok)

	testing.expect(t, len(result.plans) > 0)
	plan := result.plans[len(result.plans) - 1]
	testing.expect(t, plan.order_plan_available)
	testing.expect_value(t, plan.where_plan_kind, Where_Plan_Kind.None)
	testing.expect_value(t, plan.chosen_strategy, Select_Scan_Strategy.Where_First)
	testing.expect(t, plan.used_order_scan)
	testing.expect_value(t, plan.where_index_position, -1)
	testing.expect_value(t, plan.order_index_position, age_idx_pos)

	// Single-table plan metadata says we scan in `age` index order; the remaining ORDER BY key
	// is handled by a merge-sort node that only refines within equal-`age` tie groups.
	select_stmt, select_ok := execution_tree_parse_select(
		"SELECT id, age FROM users ORDER BY age DESC, id DESC LIMIT 2 OFFSET 1",
	)
	testing.expect(t, select_ok)
	if !select_ok {
		return
	}
	tree_root, _, _, tree_ok := plan_select_execution_tree(select_stmt)
	testing.expect(t, tree_ok)
	if !tree_ok {
		return
	}
	sort_node, sort_ok := execution_tree_find_merge_sort_node(tree_root)
	testing.expect(t, sort_ok)
	if !sort_ok {
		return
	}
	testing.expect_value(t, sort_node.prefix_sorted_terms, 1)
}

@(test)
db_test_where_order_by_large_limit_stays_where_first :: proc(t: ^testing.T) {
	defer main_finish()
	main_init()
	seed_database()

	_, age_idx_ok := exec("CREATE INDEX users_age_idx ON users (age)", clear_msgs = true)
	testing.expect(t, age_idx_ok)

	result, ok := exec(
		"SELECT id, age FROM users WHERE age >= 15 ORDER BY age DESC LIMIT 100 OFFSET 20",
		clear_msgs = true,
	)
	testing.expect(t, ok)
	testing.expect(t, len(result.plans) > 0)
	plan := result.plans[len(result.plans) - 1]
	testing.expect_value(t, plan.chosen_strategy, Select_Scan_Strategy.Where_First)
	testing.expect(t, !plan.used_order_scan)
}

@(test)
db_test_create_index_rejects_bad_definitions :: proc(t: ^testing.T) {
	defer main_finish()
	main_init()
	seed_database()

	_, missing_col_ok := exec(
		"CREATE INDEX users_missing_idx ON users (missing_col)",
		clear_msgs = true,
	)
	testing.expect(t, !missing_col_ok)

	_, first_ok := exec("CREATE INDEX users_name_idx ON users (name)", clear_msgs = true)
	testing.expect(t, first_ok)
	_, dup_ok := exec("CREATE INDEX users_name_idx ON users (age)", clear_msgs = true)
	testing.expect(t, !dup_ok)
}

// Invalid SQL should surface as `ok == false` (tokenizer / parser / database messages) without panicking.
@(test)
db_test_exec_rejects_tokenizer_invalid_char :: proc(t: ^testing.T) {
	defer main_finish()
	main_init()
	database_tests_clear()
	_, ok := exec("SELECT * FROM t WHERE a ~ b", clear_msgs = true)
	testing.expect(t, !ok)
}

@(test)
db_test_exec_rejects_parser_unsupported_start :: proc(t: ^testing.T) {
	defer main_finish()
	main_init()
	database_tests_clear()
	_, ok := exec("TABLE x", clear_msgs = true)
	testing.expect(t, !ok)
}

@(test)
db_test_exec_rejects_missing_table :: proc(t: ^testing.T) {
	defer main_finish()
	main_init()
	database_tests_clear()
	seed_database()

	_, ok := exec("SELECT * FROM not_a_table", clear_msgs = true)
	testing.expect(t, !ok)
}

@(test)
db_test_exec_rejects_unknown_column :: proc(t: ^testing.T) {
	defer main_finish()
	main_init()
	seed_database()

	_, ok := exec("SELECT nonsense FROM users", clear_msgs = true)
	testing.expect(t, !ok)
}

@(test)
db_test_transaction_rollback_after_mixed_dml_ddl_error :: proc(t: ^testing.T) {
	defer main_finish()
	main_init()
	seed_database()

	_, ok := exec("BEGIN", clear_msgs = true)
	testing.expect(t, ok)
	if !ok {
		return
	}

	_, ok = exec(
		"INSERT INTO users (id, name, age, status) VALUES (10, 'Txn', 20, 'active')",
		clear_msgs = true,
	)
	testing.expect(t, ok)
	if !ok {
		return
	}

	_, ok = exec("CREATE TABLE tx_err (id INTEGER, primary key(id))", clear_msgs = true)
	testing.expect(t, ok)
	if !ok {
		return
	}

	_, ok = exec(
		"INSERT INTO users (id, name, age, status) VALUES (10, 'Dup', 30, 'active')",
		clear_msgs = true,
	)
	testing.expect(t, !ok)

	_, ok = exec("ROLLBACK", clear_msgs = true)
	testing.expect(t, ok)
	if !ok {
		return
	}

	users, exists := database_find_table("users", log_error = false)
	testing.expect(t, exists)
	if !exists {
		return
	}
	testing.expect_value(t, table_row_count(users), 4)

	_, tmp_exists := database_find_table("tx_err", log_error = false)
	testing.expect(t, !tmp_exists)
}

@(test)
db_test_exec_emits_execution_tree_for_select_only :: proc(t: ^testing.T) {
	defer main_finish()
	main_init()
	seed_database()

	select_result, select_ok := exec("SELECT id, name FROM users WHERE id = 1", clear_msgs = true)
	testing.expect(t, select_ok)
	if !select_ok {
		return
	}

	// TODO: this basically proves nothing, consider removing the test
	testing.expect(t, strings.index(select_result.execution_tree, "Project") >= 0)

	insert_result, insert_ok := exec(
		"INSERT INTO users (id, name, age, status) VALUES (200, 'X', 20, 'active')",
		clear_msgs = true,
	)
	testing.expect(t, insert_ok)
	if !insert_ok {
		return
	}
	testing.expect_value(t, len(insert_result.execution_tree), 0)
}
