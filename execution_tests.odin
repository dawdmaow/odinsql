#+build !js
#+vet explicit-allocators

package main

import "core:fmt"
import "core:testing"

__testing_execution_tree_seed_orders_table :: proc() {
	table: Table
	column_names := make([dynamic]string, database_query_allocator)
	append_elems(&column_names, ..[]string{"id", "user_id", "product"})

	table_init(&table, "orders", column_names, 0)

	ok := database_insert_row(
		&table,
		column_names[:],
		[]Database_Value{101, 1, database_string_make("Widget")},
	)
	assert(ok)
	ok = database_insert_row(
		&table,
		column_names[:],
		[]Database_Value{102, 2, database_string_make("Gadget")},
	)
	assert(ok)
	ok = database_insert_row(
		&table,
		column_names[:],
		[]Database_Value{103, 1, database_string_make("Tool")},
	)
	assert(ok)

	ok = database_tables_append(table)
	assert(ok)
}

__testing__execution_tree_seed_users_table :: proc() {
	table: Table
	column_names := make([dynamic]string, database_query_allocator)
	append_elems(&column_names, ..[]string{"id", "name", "age"})

	table_init(&table, "users", column_names, 0)

	ok := database_insert_row(
		&table,
		column_names[:],
		[]Database_Value{1, database_string_make("Ada"), 20},
	)
	assert(ok)
	ok = database_insert_row(
		&table,
		column_names[:],
		[]Database_Value{2, database_string_make("Bob"), 35},
	)
	assert(ok)
	ok = database_insert_row(
		&table,
		column_names[:],
		[]Database_Value{3, database_string_make("Cid"), 40},
	)
	assert(ok)

	database_tables_clear()
	ok = database_tables_append(table)
	assert(ok)
}

@(test)
execution_tree_test_create_table_persists_declared_column_types :: proc(t: ^testing.T) {
	defer main_finish()
	main_init()
	database_tables_clear()

	_, ok := exec(
		"CREATE TABLE typed_inventory (item_id INTEGER, price FLOAT, active BOOLEAN, name TEXT, primary key(item_id))",
		clear_msgs = true,
	)
	testing.expect(t, ok)
	if !ok {
		return
	}

	table, exists := database_find_table("typed_inventory", log_error = false)
	testing.expect(t, exists)
	if !exists {
		return
	}
	testing.expect_value(t, len(table.column_types), 4)

	item_type, item_ok := table.column_types[0].?
	testing.expect(t, item_ok)
	testing.expect_value(t, item_type, Database_Column_Type.Integer)

	price_type, price_ok := table.column_types[1].?
	testing.expect(t, price_ok)
	testing.expect_value(t, price_type, Database_Column_Type.Float)

	active_type, active_ok := table.column_types[2].?
	testing.expect(t, active_ok)
	testing.expect_value(t, active_type, Database_Column_Type.Boolean)

	name_type, name_ok := table.column_types[3].?
	testing.expect(t, name_ok)
	testing.expect_value(t, name_type, Database_Column_Type.Text)
}

@(test)
execution_tree_test_alter_and_drop_table_commands_execute :: proc(t: ^testing.T) {
	defer main_finish()
	main_init()
	database_tables_clear()

	_, ok := exec("CREATE TABLE users (id INTEGER, name TEXT, primary key(id))", clear_msgs = true)
	testing.expect(t, ok)
	if !ok {
		return
	}

	_, ok = exec("ALTER TABLE users ADD COLUMN score INT", clear_msgs = true)
	testing.expect(t, ok)
	users, exists := database_find_table("users", log_error = false)
	testing.expect(t, exists)
	if exists {
		testing.expect_value(t, len(users.column_names), 3)
		testing.expect_value(t, users.column_names[2], "score")
	}

	_, ok = exec("DROP TABLE users", clear_msgs = true)
	testing.expect(t, ok)
	_, exists = database_find_table("users", log_error = false)
	testing.expect(t, !exists)
}

@(test)
execution_tree_test_cross_join_executes_cartesian_product :: proc(t: ^testing.T) {
	defer main_finish()
	main_init()
	__testing__execution_tree_seed_users_table()
	__testing_execution_tree_seed_orders_table()

	result, ok := exec(
		"SELECT users.id, orders.id FROM users CROSS JOIN orders",
		clear_msgs = true,
	)
	testing.expect(t, ok)
	rows, rows_ok := result.result.(Rows_With_Names)
	testing.expect(t, rows_ok)
	testing.expect_value(t, len(rows.rows), 9)
}

@(test)
execution_tree_test_join_allows_unqualified_unique_column_in_where :: proc(t: ^testing.T) {
	defer main_finish()
	main_init()
	__testing__execution_tree_seed_users_table()
	__testing_execution_tree_seed_orders_table()

	result, ok := exec(
		"SELECT product FROM users JOIN orders ON users.id = orders.user_id WHERE product = 'Gadget' ORDER BY product",
		clear_msgs = true,
	)
	testing.expect(t, ok)
	if !ok {
		return
	}
	rows, rows_ok := result.result.(Rows_With_Names)
	testing.expect(t, rows_ok)
	if !rows_ok {
		return
	}
	testing.expect_value(t, len(rows.rows), 1)
	testing.expect(t, value_exactly_equal(rows.rows[0][0], database_string_make("Gadget")))
}

@(test)
execution_tree_test_join_allows_unqualified_unique_column_in_on :: proc(t: ^testing.T) {
	defer main_finish()
	main_init()
	__testing__execution_tree_seed_users_table()
	__testing_execution_tree_seed_orders_table()

	result, ok := exec(
		"SELECT users.id, orders.id FROM users JOIN orders ON users.id = user_id ORDER BY users.id, orders.id",
		clear_msgs = true,
	)
	testing.expect(t, ok)
	if !ok {
		return
	}
	rows, rows_ok := result.result.(Rows_With_Names)
	testing.expect(t, rows_ok)
	if !rows_ok {
		return
	}
	testing.expect_value(t, len(rows.rows), 3)
	testing.expect(t, value_exactly_equal(rows.rows[0][0], 1))
	testing.expect(t, value_exactly_equal(rows.rows[0][1], 101))
	testing.expect(t, value_exactly_equal(rows.rows[1][0], 1))
	testing.expect(t, value_exactly_equal(rows.rows[1][1], 103))
	testing.expect(t, value_exactly_equal(rows.rows[2][0], 2))
	testing.expect(t, value_exactly_equal(rows.rows[2][1], 102))
}

@(test)
execution_tree_test_join_rejects_unqualified_ambiguous_column :: proc(t: ^testing.T) {
	defer main_finish()
	main_init()
	__testing__execution_tree_seed_users_table()
	__testing_execution_tree_seed_orders_table()

	_, ok := exec(
		"SELECT id FROM users JOIN orders ON users.id = orders.user_id",
		clear_msgs = true,
	)
	testing.expect(t, !ok)
}

@(test)
execution_tree_test_join_aliases_resolve_for_on_where_and_select :: proc(t: ^testing.T) {
	defer main_finish()
	main_init()
	__testing__execution_tree_seed_users_table()
	__testing_execution_tree_seed_orders_table()

	result, ok := exec(
		"SELECT u.id AS uid, o.id AS oid FROM users AS u JOIN orders o ON u.id = o.user_id WHERE u.id >= 1 ORDER BY u.id, o.id",
		clear_msgs = true,
	)
	testing.expect(t, ok)
	if !ok {
		return
	}
	rows, rows_ok := result.result.(Rows_With_Names)
	testing.expect(t, rows_ok)
	if !rows_ok {
		return
	}
	testing.expect_value(t, rows.column_names[0], "uid")
	testing.expect_value(t, rows.column_names[1], "oid")
	testing.expect_value(t, len(rows.rows), 3)
}

@(test)
execution_tree_test_rejects_unknown_table_alias_reference :: proc(t: ^testing.T) {
	defer main_finish()
	main_init()
	__testing__execution_tree_seed_users_table()
	__testing_execution_tree_seed_orders_table()

	_, ok := exec("SELECT x.id FROM users u JOIN orders o ON u.id = o.user_id", clear_msgs = true)
	testing.expect(t, !ok)
}

@(test)
execution_tree_test_optimizer_rewrites_cross_join_to_inner_join :: proc(t: ^testing.T) {
	defer main_finish()
	main_init()
	select_stmt, select_ok := execution_tree_parse_select(
		"SELECT users.id FROM users CROSS JOIN orders WHERE users.id = orders.user_id",
	)
	testing.expect(t, select_ok)
	if !select_ok {
		return
	}

	root, _, _, plan_ok := plan_select_execution_tree(select_stmt)
	testing.expect(t, plan_ok)
	if !plan_ok {
		return
	}

	join_node, join_ok := execution_tree_find_join_node(root)
	testing.expect(t, join_ok)
	if !join_ok {
		return
	}
	testing.expect(t, join_node.join_type == .Inner)
	testing.expect(t, join_node.condition != nil)
}

@(test)
execution_tree_test_optimizer_chooses_merge_join_for_id_equality :: proc(t: ^testing.T) {
	defer main_finish()
	main_init()
	select_stmt, select_ok := execution_tree_parse_select(
		"SELECT users.id FROM users JOIN orders ON users.id = orders.id",
	)
	testing.expect(t, select_ok)
	if !select_ok {
		return
	}
	root, _, _, plan_ok := plan_select_execution_tree(select_stmt)
	testing.expect(t, plan_ok)
	if !plan_ok {
		return
	}
	join_node, join_ok := execution_tree_find_join_node(root)
	testing.expect(t, join_ok)
	if !join_ok {
		return
	}
	testing.expect(t, join_node.algorithm == .Merge)
}

@(test)
execution_tree_test_optimizer_chooses_hash_join_for_non_id_equality :: proc(t: ^testing.T) {
	defer main_finish()
	main_init()
	select_stmt, select_ok := execution_tree_parse_select(
		"SELECT users.id FROM users JOIN orders ON users.age = orders.user_id",
	)
	testing.expect(t, select_ok)
	if !select_ok {
		return
	}
	root, _, _, plan_ok := plan_select_execution_tree(select_stmt)
	testing.expect(t, plan_ok)
	if !plan_ok {
		return
	}
	join_node, join_ok := execution_tree_find_join_node(root)
	testing.expect(t, join_ok)
	if !join_ok {
		return
	}
	testing.expect(t, join_node.algorithm == .Hash)
}

@(test)
execution_tree_test_optimizer_pushes_projection_requirements_to_scan :: proc(t: ^testing.T) {
	defer main_finish()
	main_init()
	__testing__execution_tree_seed_users_table()
	select_stmt, select_ok := execution_tree_parse_select(
		"SELECT id FROM users WHERE age > 20 ORDER BY id",
	)
	testing.expect(t, select_ok)
	if !select_ok {
		return
	}
	root, _, _, plan_ok := plan_select_execution_tree(select_stmt)
	testing.expect(t, plan_ok)
	if !plan_ok {
		return
	}
	scan, scan_ok := execution_tree_find_table_scan(root, "users")
	testing.expect(t, scan_ok)
	if !scan_ok {
		return
	}
	testing.expect_value(t, len(scan.required_column_names), 2)
}

@(test)
execution_tree_test_optimizer_inserts_merge_sort_for_order_by :: proc(t: ^testing.T) {
	defer main_finish()
	main_init()
	// Planner now resolves metadata and can satisfy ORDER BY id via PK order scan directly.
	__testing__execution_tree_seed_users_table()
	select_stmt, select_ok := execution_tree_parse_select("SELECT id FROM users ORDER BY id")
	testing.expect(t, select_ok)
	if !select_ok {
		return
	}

	root, _, _, plan_ok := plan_select_execution_tree(select_stmt)
	testing.expect(t, plan_ok)
	if !plan_ok {
		return
	}

	sort_node, sort_ok := execution_tree_find_merge_sort_node(root)
	testing.expect(t, !sort_ok)
	_ = sort_node
}

@(test)
execution_tree_test_optimizer_inserts_merge_sort_for_non_index_order_by :: proc(t: ^testing.T) {
	defer main_finish()
	main_init()
	__testing__execution_tree_seed_users_table()
	select_stmt, select_ok := execution_tree_parse_select("SELECT id FROM users ORDER BY age")
	testing.expect(t, select_ok)
	if !select_ok {
		return
	}

	root, _, _, plan_ok := plan_select_execution_tree(select_stmt)
	testing.expect(t, plan_ok)
	if !plan_ok {
		return
	}

	sort_node, sort_ok := execution_tree_find_merge_sort_node(root)
	testing.expect(t, sort_ok)
	if !sort_ok {
		return
	}
	testing.expect_value(t, len(sort_node.order_items), 1)
}

@(test)
execution_tree_test_optimizer_skips_merge_sort_for_pk_desc_order_by :: proc(t: ^testing.T) {
	defer main_finish()
	main_init()
	__testing__execution_tree_seed_users_table()
	select_stmt, select_ok := execution_tree_parse_select("SELECT id FROM users ORDER BY id DESC")
	testing.expect(t, select_ok)
	if !select_ok {
		return
	}

	root, _, _, plan_ok := plan_select_execution_tree(select_stmt)
	testing.expect(t, plan_ok)
	if !plan_ok {
		return
	}

	_, sort_ok := execution_tree_find_merge_sort_node(root)
	testing.expect(t, !sort_ok)
}

@(test)
execution_tree_test_optimizer_skips_merge_sort_for_where_order_by_desc_index_scan :: proc(
	t: ^testing.T,
) {
	defer main_finish()
	main_init()
	seed_database()
	_, index_ok := exec("CREATE INDEX users_age_idx ON users (age)", clear_msgs = true)
	testing.expect(t, index_ok)
	if !index_ok {
		return
	}
	select_stmt, select_ok := execution_tree_parse_select(
		"SELECT id, age FROM users WHERE age >= 15 ORDER BY age DESC LIMIT 2",
	)
	testing.expect(t, select_ok)
	if !select_ok {
		return
	}

	root, _, _, plan_ok := plan_select_execution_tree(select_stmt)
	testing.expect(t, plan_ok)
	if !plan_ok {
		return
	}

	_, sort_ok := execution_tree_find_merge_sort_node(root)
	testing.expect(t, !sort_ok)
}

@(test)
execution_tree_test_optimizer_keeps_merge_sort_for_expression_order_by :: proc(t: ^testing.T) {
	defer main_finish()
	main_init()
	__testing__execution_tree_seed_users_table()
	select_stmt, select_ok := execution_tree_parse_select(
		"SELECT id FROM users ORDER BY id + 1 DESC",
	)
	testing.expect(t, select_ok)
	if !select_ok {
		return
	}

	root, _, _, plan_ok := plan_select_execution_tree(select_stmt)
	testing.expect(t, plan_ok)
	if !plan_ok {
		return
	}

	_, sort_ok := execution_tree_find_merge_sort_node(root)
	testing.expect(t, sort_ok)
}

@(test)
execution_tree_test_optimizer_uses_tie_refine_for_multikey_indexed_leading_order :: proc(
	t: ^testing.T,
) {
	defer main_finish()
	main_init()
	seed_database()
	_, index_ok := exec("CREATE INDEX users_age_idx ON users (age)", clear_msgs = true)
	testing.expect(t, index_ok)
	if !index_ok {
		return
	}

	select_stmt, select_ok := execution_tree_parse_select(
		"SELECT id, age FROM users ORDER BY age ASC, id ASC",
	)
	testing.expect(t, select_ok)
	if !select_ok {
		return
	}

	root, _, _, plan_ok := plan_select_execution_tree(select_stmt)
	testing.expect(t, plan_ok)
	if !plan_ok {
		return
	}

	sort_node, sort_ok := execution_tree_find_merge_sort_node(root)
	testing.expect(t, sort_ok)
	if !sort_ok {
		return
	}
	testing.expect_value(t, sort_node.prefix_sorted_terms, 1)
}

@(test)
execution_tree_test_optimizer_skips_merge_sort_for_left_join_ordered_left_scan :: proc(
	t: ^testing.T,
) {
	defer main_finish()
	main_init()
	__testing__execution_tree_seed_users_table()
	__testing_execution_tree_seed_orders_table()
	select_stmt, select_ok := execution_tree_parse_select(
		"SELECT users.id, orders.id FROM users LEFT JOIN orders ON users.id = orders.user_id ORDER BY users.id",
	)
	testing.expect(t, select_ok)
	if !select_ok {
		return
	}

	root, _, _, plan_ok := plan_select_execution_tree(select_stmt)
	testing.expect(t, plan_ok)
	if !plan_ok {
		return
	}

	_, sort_ok := execution_tree_find_merge_sort_node(root)
	testing.expect(t, !sort_ok)
}

@(test)
execution_tree_test_optimizer_keeps_merge_sort_for_hash_join_even_with_pk_order_key :: proc(
	t: ^testing.T,
) {
	defer main_finish()
	main_init()
	__testing__execution_tree_seed_users_table()
	__testing_execution_tree_seed_orders_table()
	select_stmt, select_ok := execution_tree_parse_select(
		"SELECT users.id, orders.id FROM users JOIN orders ON users.age = orders.user_id ORDER BY users.id",
	)
	testing.expect(t, select_ok)
	if !select_ok {
		return
	}

	root, _, _, plan_ok := plan_select_execution_tree(select_stmt)
	testing.expect(t, plan_ok)
	if !plan_ok {
		return
	}
	join_node, join_ok := execution_tree_find_join_node(root)
	testing.expect(t, join_ok)
	if !join_ok {
		return
	}
	testing.expect(t, join_node.algorithm == .Hash)
	_, sort_ok := execution_tree_find_merge_sort_node(root)
	testing.expect(t, sort_ok)
}

@(test)
execution_tree_test_merge_sort_node_iterates_buffered_rows :: proc(t: ^testing.T) {
	defer main_finish()
	main_init()
	__testing__execution_tree_seed_users_table()

	select_stmt, select_ok := execution_tree_parse_select("SELECT id FROM users ORDER BY age")
	testing.expect(t, select_ok)
	if !select_ok {
		return
	}
	root, _, _, plan_ok := plan_select_execution_tree(select_stmt)
	testing.expect(t, plan_ok)
	if !plan_ok {
		return
	}

	sort_node, sort_ok := execution_tree_find_merge_sort_node(root)
	testing.expect(t, sort_ok)
	if !sort_ok {
		return
	}

	_, first_ok := execution_tree_next_row(root)
	testing.expect(t, first_ok)
	testing.expect(t, sort_node.initialized)
	testing.expect(t, len(sort_node.sorted_rows) > 0)
	testing.expect_value(t, sort_node.row_i, 1)

	_, second_ok := execution_tree_next_row(root)
	testing.expect(t, second_ok)
	testing.expect_value(t, sort_node.row_i, 2)
}

@(test)
execution_tree_test_merge_sort_limit_bounds_buffered_rows :: proc(t: ^testing.T) {
	defer main_finish()
	main_init()
	__testing__execution_tree_seed_users_table()

	select_stmt, select_ok := execution_tree_parse_select(
		"SELECT id FROM users ORDER BY age + 1 DESC LIMIT 1 OFFSET 1",
	)
	testing.expect(t, select_ok)
	if !select_ok {
		return
	}

	root, _, _, plan_ok := plan_select_execution_tree(select_stmt)
	testing.expect(t, plan_ok)
	if !plan_ok {
		return
	}

	sort_node, sort_ok := execution_tree_find_merge_sort_node(root)
	testing.expect(t, sort_ok)
	if !sort_ok {
		return
	}

	_, first_ok := execution_tree_next_row(root)
	testing.expect(t, first_ok)
	if !first_ok {
		return
	}

	testing.expect_value(t, len(sort_node.sorted_rows), 2)
}

@(test)
execution_tree_test_merge_sort_limit_offset_bounded_materialization_preserves_output :: proc(
	t: ^testing.T,
) {
	defer main_finish()
	main_init()
	__testing__execution_tree_seed_users_table()

	select_stmt, select_ok := execution_tree_parse_select(
		"SELECT id FROM users ORDER BY age + 1 DESC LIMIT 1 OFFSET 1",
	)
	testing.expect(t, select_ok)
	if !select_ok {
		return
	}

	root, _, _, plan_ok := plan_select_execution_tree(select_stmt)
	testing.expect(t, plan_ok)
	if !plan_ok {
		return
	}

	sort_node, sort_ok := execution_tree_find_merge_sort_node(root)
	testing.expect(t, sort_ok)
	if !sort_ok {
		return
	}

	first_row, first_ok := execution_tree_next_row(root)
	testing.expect(t, first_ok)
	if !first_ok {
		return
	}
	testing.expect(t, value_exactly_equal(first_row[0], 2))

	_, second_ok := execution_tree_next_row(root)
	testing.expect(t, !second_ok)

	// LIMIT 1 OFFSET 1 should ask merge sort to retain only top-2 rows.
	testing.expect_value(t, len(sort_node.sorted_rows), 2)
}

@(test)
execution_tree_test_optimizer_pushes_single_table_join_predicates_to_inputs :: proc(
	t: ^testing.T,
) {
	defer main_finish()
	main_init()
	select_stmt, select_ok := execution_tree_parse_select(
		"SELECT users.id FROM users JOIN orders ON users.id = orders.user_id WHERE users.age > 20 AND orders.total > 100",
	)
	testing.expect(t, select_ok)
	if !select_ok {
		return
	}

	root, _, _, plan_ok := plan_select_execution_tree(select_stmt)
	testing.expect(t, plan_ok)
	if !plan_ok {
		return
	}

	users_filter, users_filter_ok := execution_tree_find_filter_directly_above_table_scan(
		root,
		"users",
	)
	testing.expect(t, users_filter_ok)
	if !users_filter_ok {
		return
	}
	orders_filter, orders_filter_ok := execution_tree_find_filter_directly_above_table_scan(
		root,
		"orders",
	)
	testing.expect(t, orders_filter_ok)
	if !orders_filter_ok {
		return
	}
	execution_tree_expect_single_qualified_int_conjunct(
		t,
		users_filter,
		"users",
		"age",
		.Greater_Than,
		20,
	)
	execution_tree_expect_single_qualified_int_conjunct(
		t,
		orders_filter,
		"orders",
		"total",
		.Greater_Than,
		100,
	)
}

execution_tree_expect_single_qualified_int_conjunct :: proc(
	t: ^testing.T,
	filter: ^Execution_Filter,
	expected_table_name: string,
	expected_column_name: string,
	expected_op_kind: Token_Kind,
	expected_rhs_value: int,
) {
	testing.expect_value(t, len(filter.conjuncts), 1)
	if len(filter.conjuncts) != 1 {
		return
	}
	conjunct, conjunct_is_condition := filter.conjuncts[0].value.(^Condition)
	testing.expect(t, conjunct_is_condition)
	if !conjunct_is_condition {
		return
	}
	left_ident, left_is_ident := conjunct.a.value.(^AST_Ident)
	testing.expect(t, left_is_ident)
	if !left_is_ident {
		return
	}
	testing.expect_value(t, left_ident.table_name, expected_table_name)
	testing.expect_value(t, left_ident.column_name, expected_column_name)
	testing.expect_value(t, conjunct.op.token.kind, expected_op_kind)
	right_int, right_is_int := conjunct.b.value.(^AST_Int)
	testing.expect(t, right_is_int)
	if !right_is_int {
		return
	}
	testing.expect_value(t, right_int.int, expected_rhs_value)
}

@(test)
execution_tree_test_scan_produces_rows :: proc(t: ^testing.T) {
	defer main_finish()
	main_init()
	__testing__execution_tree_seed_users_table()

	scan := new(Execution_Table_Scan, database_query_allocator)
	scan^ = {
		table_name = "users",
	}
	root := new(Execution_Node, database_query_allocator)
	root^ = scan

	rows, rows_ok := execution_tree_collect_rows_from_next(root)
	testing.expect(t, rows_ok)

	testing.expect_value(t, len(rows.column_names), 3)
	testing.expect_value(t, len(rows.rows), 3)
	testing.expect(t, value_exactly_equal(execution_tree_rows_cell(rows, 0, "id"), 1))
	testing.expect(
		t,
		value_exactly_equal(
			execution_tree_rows_cell(rows, 2, "name"),
			database_string_make("Cid"),
		),
	)
}

@(test)
execution_tree_test_filter_passes_matching_rows :: proc(t: ^testing.T) {
	defer main_finish()
	main_init()
	__testing__execution_tree_seed_users_table()

	scan := new(Execution_Table_Scan, database_query_allocator)
	scan^ = {
		table_name = "users",
	}
	scan_node := new(Execution_Node, database_query_allocator)
	scan_node^ = scan

	conjunct := execution_tree_ast_condition(
		execution_tree_ast_ident("age"),
		.Gt_Eq,
		">=",
		execution_tree_ast_int(35),
	)
	filter := new(Execution_Filter, database_query_allocator)
	filter^ = {
		input = scan_node^,
	}
	conjunct_i := len(filter.conjuncts)
	resize(&filter.conjuncts, conjunct_i + 1)
	filter.conjuncts[conjunct_i] = conjunct
	root := new(Execution_Node, database_query_allocator)
	root^ = filter

	rows, rows_ok := execution_tree_collect_rows_from_next(root)
	testing.expect(t, rows_ok)

	testing.expect_value(t, len(rows.rows), 2)
	testing.expect(
		t,
		value_exactly_equal(
			execution_tree_rows_cell(rows, 0, "name"),
			database_string_make("Bob"),
		),
	)
	testing.expect(
		t,
		value_exactly_equal(
			execution_tree_rows_cell(rows, 1, "name"),
			database_string_make("Cid"),
		),
	)
}

@(test)
execution_tree_test_filter_can_remove_all_rows :: proc(t: ^testing.T) {
	defer main_finish()
	main_init()
	__testing__execution_tree_seed_users_table()

	scan := new(Execution_Table_Scan, database_query_allocator)
	scan^ = {
		table_name = "users",
	}
	scan_node := new(Execution_Node, database_query_allocator)
	scan_node^ = scan

	conjunct := execution_tree_ast_condition(
		execution_tree_ast_ident("age"),
		.Greater_Than,
		">",
		execution_tree_ast_int(99),
	)
	filter := new(Execution_Filter, database_query_allocator)
	filter^ = {
		input = scan_node^,
	}
	conjunct_i := len(filter.conjuncts)
	resize(&filter.conjuncts, conjunct_i + 1)
	filter.conjuncts[conjunct_i] = conjunct
	root := new(Execution_Node, database_query_allocator)
	root^ = filter

	rows, rows_ok := execution_tree_collect_rows_from_next(root)
	testing.expect(t, rows_ok)

	testing.expect_value(t, len(rows.rows), 0)
}

@(test)
execution_tree_test_filter_supports_nested_boolean_conditions :: proc(t: ^testing.T) {
	defer main_finish()
	main_init()
	__testing__execution_tree_seed_users_table()

	scan := new(Execution_Table_Scan, database_query_allocator)
	scan^ = {
		table_name = "users",
	}
	scan_node := new(Execution_Node, database_query_allocator)
	scan_node^ = scan

	age_gte_35 := execution_tree_ast_condition(
		execution_tree_ast_ident("age"),
		.Gt_Eq,
		">=",
		execution_tree_ast_int(35),
	)
	id_lt_3 := execution_tree_ast_condition(
		execution_tree_ast_ident("id"),
		.Less_Than,
		"<",
		execution_tree_ast_int(3),
	)
	left_and := execution_tree_ast_condition(age_gte_35, .And, "AND", id_lt_3)
	name_is_ada := execution_tree_ast_condition(
		execution_tree_ast_ident("name"),
		.Equals,
		"==",
		execution_tree_ast_string("Ada"),
	)
	conjunct := execution_tree_ast_condition(left_and, .Or, "OR", name_is_ada)

	filter := new(Execution_Filter, database_query_allocator)
	filter^ = {
		input = scan_node^,
	}
	conjunct_i := len(filter.conjuncts)
	resize(&filter.conjuncts, conjunct_i + 1)
	filter.conjuncts[conjunct_i] = conjunct
	root := new(Execution_Node, database_query_allocator)
	root^ = filter

	rows, rows_ok := execution_tree_collect_rows_from_next(root)
	testing.expect(t, rows_ok)

	testing.expect_value(t, len(rows.rows), 2)
	testing.expect(
		t,
		value_exactly_equal(
			execution_tree_rows_cell(rows, 0, "name"),
			database_string_make("Ada"),
		),
	)
	testing.expect(
		t,
		value_exactly_equal(
			execution_tree_rows_cell(rows, 1, "name"),
			database_string_make("Bob"),
		),
	)
}

@(test)
execution_tree_test_filter_binding_fails_on_unknown_column :: proc(t: ^testing.T) {
	defer main_finish()
	main_init()
	__testing__execution_tree_seed_users_table()

	scan := new(Execution_Table_Scan, database_query_allocator)
	scan^ = {
		table_name = "users",
	}
	scan_node := new(Execution_Node, database_query_allocator)
	scan_node^ = scan

	conjunct := execution_tree_ast_condition(
		execution_tree_ast_ident("missing_col"),
		.Equals,
		"==",
		execution_tree_ast_int(123),
	)
	filter := new(Execution_Filter, database_query_allocator)
	filter^ = {
		input = scan_node^,
	}
	conjunct_i := len(filter.conjuncts)
	resize(&filter.conjuncts, conjunct_i + 1)
	filter.conjuncts[conjunct_i] = conjunct
	root := new(Execution_Node, database_query_allocator)
	root^ = filter

	_, ok := execution_tree_next_row(root)
	testing.expect(t, !ok)
	testing.expect(t, !filter.conjuncts_bound)
}

@(test)
execution_tree_test_inner_join_produces_matching_rows :: proc(t: ^testing.T) {
	defer main_finish()
	main_init()
	__testing__execution_tree_seed_users_table()
	__testing_execution_tree_seed_orders_table()

	users_scan := new(Execution_Table_Scan, database_query_allocator)
	users_scan^ = {
		table_name = "users",
	}
	users_node := new(Execution_Node, database_query_allocator)
	users_node^ = users_scan

	orders_scan := new(Execution_Table_Scan, database_query_allocator)
	orders_scan^ = {
		table_name = "orders",
	}
	orders_node := new(Execution_Node, database_query_allocator)
	orders_node^ = orders_scan

	join := new(Execution_Join, database_query_allocator)
	join^ = {
		left      = users_node^,
		right     = orders_node^,
		condition = execution_tree_ast_condition(
			execution_tree_ast_qualified_ident("users", "id"),
			.Equals,
			"==",
			execution_tree_ast_qualified_ident("orders", "user_id"),
		),
		join_type = .Inner,
	}
	root := new(Execution_Node, database_query_allocator)
	root^ = join

	rows, ok := exec_execution_tree_rows(root)
	testing.expect(t, ok)
	testing.expect_value(t, len(rows.rows), 3)
	testing.expect(t, value_exactly_equal(execution_tree_rows_cell(rows, 0, "users.id"), 1))
	testing.expect(
		t,
		value_exactly_equal(
			execution_tree_rows_cell(rows, 0, "users.name"),
			database_string_make("Ada"),
		),
	)
	testing.expect(t, value_exactly_equal(execution_tree_rows_cell(rows, 0, "users.age"), 20))
	testing.expect(t, value_exactly_equal(execution_tree_rows_cell(rows, 0, "orders.id"), 101))
	testing.expect(t, value_exactly_equal(execution_tree_rows_cell(rows, 0, "orders.user_id"), 1))
	testing.expect(
		t,
		value_exactly_equal(
			execution_tree_rows_cell(rows, 0, "orders.product"),
			database_string_make("Widget"),
		),
	)

	testing.expect(t, value_exactly_equal(execution_tree_rows_cell(rows, 1, "users.id"), 1))
	testing.expect(
		t,
		value_exactly_equal(
			execution_tree_rows_cell(rows, 1, "users.name"),
			database_string_make("Ada"),
		),
	)
	testing.expect(t, value_exactly_equal(execution_tree_rows_cell(rows, 1, "users.age"), 20))
	testing.expect(t, value_exactly_equal(execution_tree_rows_cell(rows, 1, "orders.id"), 103))
	testing.expect(t, value_exactly_equal(execution_tree_rows_cell(rows, 1, "orders.user_id"), 1))
	testing.expect(
		t,
		value_exactly_equal(
			execution_tree_rows_cell(rows, 1, "orders.product"),
			database_string_make("Tool"),
		),
	)

	testing.expect(t, value_exactly_equal(execution_tree_rows_cell(rows, 2, "users.id"), 2))
	testing.expect(
		t,
		value_exactly_equal(
			execution_tree_rows_cell(rows, 2, "users.name"),
			database_string_make("Bob"),
		),
	)
	testing.expect(t, value_exactly_equal(execution_tree_rows_cell(rows, 2, "users.age"), 35))
	testing.expect(t, value_exactly_equal(execution_tree_rows_cell(rows, 2, "orders.id"), 102))
	testing.expect(t, value_exactly_equal(execution_tree_rows_cell(rows, 2, "orders.user_id"), 2))
	testing.expect(
		t,
		value_exactly_equal(
			execution_tree_rows_cell(rows, 2, "orders.product"),
			database_string_make("Gadget"),
		),
	)
}

@(test)
execution_tree_test_left_join_pads_unmatched_right_columns :: proc(t: ^testing.T) {
	defer main_finish()
	main_init()
	__testing__execution_tree_seed_users_table()
	__testing_execution_tree_seed_orders_table()

	users_scan := new(Execution_Table_Scan, database_query_allocator)
	users_scan^ = {
		table_name = "users",
	}
	users_node := new(Execution_Node, database_query_allocator)
	users_node^ = users_scan

	orders_scan := new(Execution_Table_Scan, database_query_allocator)
	orders_scan^ = {
		table_name = "orders",
	}
	orders_node := new(Execution_Node, database_query_allocator)
	orders_node^ = orders_scan

	join := new(Execution_Join, database_query_allocator)
	join^ = {
		left      = users_node^,
		right     = orders_node^,
		condition = execution_tree_ast_condition(
			execution_tree_ast_qualified_ident("users", "id"),
			.Equals,
			"==",
			execution_tree_ast_qualified_ident("orders", "user_id"),
		),
		join_type = .Left,
	}
	root := new(Execution_Node, database_query_allocator)
	root^ = join

	rows, ok := exec_execution_tree_rows(root)
	testing.expect(t, ok)
	testing.expect_value(t, len(rows.rows), 4)
	testing.expect(t, value_exactly_equal(execution_tree_rows_cell(rows, 0, "users.id"), 1))
	testing.expect(
		t,
		value_exactly_equal(
			execution_tree_rows_cell(rows, 0, "users.name"),
			database_string_make("Ada"),
		),
	)
	testing.expect(t, value_exactly_equal(execution_tree_rows_cell(rows, 0, "users.age"), 20))
	testing.expect(t, value_exactly_equal(execution_tree_rows_cell(rows, 0, "orders.id"), 101))
	testing.expect(t, value_exactly_equal(execution_tree_rows_cell(rows, 0, "orders.user_id"), 1))
	testing.expect(
		t,
		value_exactly_equal(
			execution_tree_rows_cell(rows, 0, "orders.product"),
			database_string_make("Widget"),
		),
	)

	testing.expect(t, value_exactly_equal(execution_tree_rows_cell(rows, 1, "users.id"), 1))
	testing.expect(
		t,
		value_exactly_equal(
			execution_tree_rows_cell(rows, 1, "users.name"),
			database_string_make("Ada"),
		),
	)
	testing.expect(t, value_exactly_equal(execution_tree_rows_cell(rows, 1, "users.age"), 20))
	testing.expect(t, value_exactly_equal(execution_tree_rows_cell(rows, 1, "orders.id"), 103))
	testing.expect(t, value_exactly_equal(execution_tree_rows_cell(rows, 1, "orders.user_id"), 1))
	testing.expect(
		t,
		value_exactly_equal(
			execution_tree_rows_cell(rows, 1, "orders.product"),
			database_string_make("Tool"),
		),
	)

	testing.expect(t, value_exactly_equal(execution_tree_rows_cell(rows, 2, "users.id"), 2))
	testing.expect(
		t,
		value_exactly_equal(
			execution_tree_rows_cell(rows, 2, "users.name"),
			database_string_make("Bob"),
		),
	)
	testing.expect(t, value_exactly_equal(execution_tree_rows_cell(rows, 2, "users.age"), 35))
	testing.expect(t, value_exactly_equal(execution_tree_rows_cell(rows, 2, "orders.id"), 102))
	testing.expect(t, value_exactly_equal(execution_tree_rows_cell(rows, 2, "orders.user_id"), 2))
	testing.expect(
		t,
		value_exactly_equal(
			execution_tree_rows_cell(rows, 2, "orders.product"),
			database_string_make("Gadget"),
		),
	)

	testing.expect(t, value_exactly_equal(execution_tree_rows_cell(rows, 3, "users.id"), 3))
	testing.expect(
		t,
		value_exactly_equal(
			execution_tree_rows_cell(rows, 3, "users.name"),
			database_string_make("Cid"),
		),
	)
	testing.expect(t, value_exactly_equal(execution_tree_rows_cell(rows, 3, "users.age"), 40))
	testing.expect(t, value_exactly_equal(execution_tree_rows_cell(rows, 3, "orders.id"), nil))
	testing.expect(
		t,
		value_exactly_equal(execution_tree_rows_cell(rows, 3, "orders.user_id"), nil),
	)
	testing.expect(
		t,
		value_exactly_equal(execution_tree_rows_cell(rows, 3, "orders.product"), nil),
	)
}

@(test)
execution_tree_test_right_join_pads_unmatched_left_columns :: proc(t: ^testing.T) {
	defer main_finish()
	main_init()
	__testing__execution_tree_seed_users_table()

	table: Table
	column_names := make([dynamic]string, database_query_allocator)
	append_elems(&column_names, ..[]string{"id", "user_id", "product"})
	table_init(&table, "orders", column_names, 0)
	ok := database_insert_row(
		&table,
		column_names[:],
		[]Database_Value{101, 1, database_string_make("Widget")},
	)
	assert(ok)
	ok = database_insert_row(
		&table,
		column_names[:],
		[]Database_Value{102, 99, database_string_make("Orphan")},
	)
	assert(ok)
	ok = database_tables_append(table)
	assert(ok)

	users_scan := new(Execution_Table_Scan, database_query_allocator)
	users_scan^ = {
		table_name = "users",
	}
	users_node := new(Execution_Node, database_query_allocator)
	users_node^ = users_scan

	orders_scan := new(Execution_Table_Scan, database_query_allocator)
	orders_scan^ = {
		table_name = "orders",
	}
	orders_node := new(Execution_Node, database_query_allocator)
	orders_node^ = orders_scan

	join := new(Execution_Join, database_query_allocator)
	join^ = {
		left      = users_node^,
		right     = orders_node^,
		condition = execution_tree_ast_condition(
			execution_tree_ast_qualified_ident("users", "id"),
			.Equals,
			"==",
			execution_tree_ast_qualified_ident("orders", "user_id"),
		),
		join_type = .Right,
	}
	root := new(Execution_Node, database_query_allocator)
	root^ = join

	{
		rows, ok := exec_execution_tree_rows(root)
		testing.expect(t, ok)
		testing.expect_value(t, len(rows.rows), 2)
		testing.expect(t, value_exactly_equal(execution_tree_rows_cell(rows, 0, "users.id"), 1))
		testing.expect(
			t,
			value_exactly_equal(
				execution_tree_rows_cell(rows, 0, "users.name"),
				database_string_make("Ada"),
			),
		)
		testing.expect(t, value_exactly_equal(execution_tree_rows_cell(rows, 0, "users.age"), 20))
		testing.expect(t, value_exactly_equal(execution_tree_rows_cell(rows, 0, "orders.id"), 101))
		testing.expect(
			t,
			value_exactly_equal(execution_tree_rows_cell(rows, 0, "orders.user_id"), 1),
		)
		testing.expect(
			t,
			value_exactly_equal(
				execution_tree_rows_cell(rows, 0, "orders.product"),
				database_string_make("Widget"),
			),
		)

		testing.expect(t, value_exactly_equal(execution_tree_rows_cell(rows, 1, "orders.id"), 102))
		testing.expect(
			t,
			value_exactly_equal(execution_tree_rows_cell(rows, 1, "orders.user_id"), 99),
		)
		testing.expect(
			t,
			value_exactly_equal(
				execution_tree_rows_cell(rows, 1, "orders.product"),
				database_string_make("Orphan"),
			),
		)
		testing.expect(t, value_exactly_equal(execution_tree_rows_cell(rows, 1, "users.id"), nil))
		testing.expect(
			t,
			value_exactly_equal(execution_tree_rows_cell(rows, 1, "users.name"), nil),
		)
		testing.expect(t, value_exactly_equal(execution_tree_rows_cell(rows, 1, "users.age"), nil))
	}
}

@(test)
execution_tree_test_select_projects_expressions :: proc(t: ^testing.T) {
	defer main_finish()
	main_init()
	__testing__execution_tree_seed_users_table()

	result, ok := exec("SELECT id, age + 1 FROM users ORDER BY id", clear_msgs = true)
	testing.expect(t, ok)

	rows, rows_ok := result.result.(Rows_With_Names)
	testing.expect(t, rows_ok)
	testing.expect_value(t, len(rows.column_names), 2)
	testing.expect_value(t, len(rows.rows), 3)
	testing.expect(t, value_exactly_equal(rows.rows[0][0], 1))
	testing.expect(t, value_exactly_equal(rows.rows[0][1], 21))
}

@(test)
execution_tree_test_select_order_limit_offset :: proc(t: ^testing.T) {
	defer main_finish()
	main_init()
	__testing__execution_tree_seed_users_table()

	result, ok := exec(
		"SELECT id FROM users ORDER BY age DESC LIMIT 1 OFFSET 1",
		clear_msgs = true,
	)
	testing.expect(t, ok)

	rows, rows_ok := result.result.(Rows_With_Names)
	testing.expect(t, rows_ok)
	testing.expect_value(t, len(rows.rows), 1)
	testing.expect(t, value_exactly_equal(rows.rows[0][0], 2))
}

@(test)
execution_tree_test_select_uses_pk_plan_for_primary_key_where :: proc(t: ^testing.T) {
	defer main_finish()
	main_init()
	__testing__execution_tree_seed_users_table()

	result, ok := exec("SELECT id, name FROM users WHERE id = 2", clear_msgs = true)
	testing.expect(t, ok)

	rows, rows_ok := result.result.(Rows_With_Names)
	testing.expect(t, rows_ok)
	testing.expect_value(t, len(rows.rows), 1)
	testing.expect(t, value_exactly_equal(rows.rows[0][0], 2))
	testing.expect_value(t, len(result.plans), 1)
	testing.expect(t, result.plans[0].where_plan_kind == .Pk)
}

@(test)
execution_tree_test_select_uses_index_plan_for_secondary_index_where :: proc(t: ^testing.T) {
	defer main_finish()
	main_init()
	__testing__execution_tree_seed_users_table()
	_, index_ok := exec("CREATE INDEX users_age_idx ON users (age)", clear_msgs = true)
	testing.expect(t, index_ok)

	result, ok := exec("SELECT id FROM users WHERE age = 35", clear_msgs = true)
	testing.expect(t, ok)
	rows, rows_ok := result.result.(Rows_With_Names)
	testing.expect(t, rows_ok)
	testing.expect_value(t, len(rows.rows), 1)
	testing.expect(t, value_exactly_equal(rows.rows[0][0], 2))
	testing.expect_value(t, len(result.plans), 1)
	testing.expect(t, result.plans[0].where_plan_kind == .Index)
}

@(test)
execution_tree_test_select_from_subquery_and_in_subquery :: proc(t: ^testing.T) {
	defer main_finish()
	main_init()
	__testing__execution_tree_seed_users_table()
	__testing_execution_tree_seed_orders_table()

	from_subquery_result, from_subquery_ok := exec(
		"SELECT id FROM (SELECT id, age FROM users) WHERE id > 1 ORDER BY id",
		clear_msgs = true,
	)
	testing.expect(t, from_subquery_ok)
	from_rows, from_rows_ok := from_subquery_result.result.(Rows_With_Names)
	testing.expect(t, from_rows_ok)
	testing.expect_value(t, len(from_rows.rows), 2)
	testing.expect(t, value_exactly_equal(from_rows.rows[0][0], 2))
	testing.expect(t, value_exactly_equal(from_rows.rows[1][0], 3))

	in_subquery_result, in_subquery_ok := exec(
		"SELECT id FROM users WHERE id IN (SELECT user_id FROM orders) ORDER BY id",
		clear_msgs = true,
	)
	testing.expect(t, in_subquery_ok)
	in_rows, in_rows_ok := in_subquery_result.result.(Rows_With_Names)
	testing.expect(t, in_rows_ok)
	testing.expect_value(t, len(in_rows.rows), 2)
	testing.expect(t, value_exactly_equal(in_rows.rows[0][0], 1))
	testing.expect(t, value_exactly_equal(in_rows.rows[1][0], 2))
}

@(test)
execution_tree_test_group_by_count_sum_avg :: proc(t: ^testing.T) {
	defer main_finish()
	main_init()
	__testing_execution_tree_seed_orders_table()

	result, ok := exec(
		"SELECT user_id, COUNT(*), SUM(id), AVG(id) FROM orders GROUP BY user_id ORDER BY user_id",
		clear_msgs = true,
	)
	testing.expect(t, ok)
	if !ok {
		return
	}
	rows, rows_ok := result.result.(Rows_With_Names)
	testing.expect(t, rows_ok)
	if !rows_ok {
		return
	}
	testing.expect_value(t, len(rows.rows), 2)
	testing.expect(t, value_exactly_equal(rows.rows[0][0], 1))
	testing.expect(t, value_exactly_equal(rows.rows[0][1], 2))
	testing.expect(t, value_exactly_equal(rows.rows[0][2], 204))
	testing.expect(t, value_exactly_equal(rows.rows[0][3], 102.0))
	testing.expect(t, value_exactly_equal(rows.rows[1][0], 2))
	testing.expect(t, value_exactly_equal(rows.rows[1][1], 1))
	testing.expect(t, value_exactly_equal(rows.rows[1][2], 102))
	testing.expect(t, value_exactly_equal(rows.rows[1][3], 102.0))
}

@(test)
execution_tree_test_group_by_having_count :: proc(t: ^testing.T) {
	defer main_finish()
	main_init()
	__testing_execution_tree_seed_orders_table()

	result, ok := exec(
		"SELECT user_id, COUNT(*) FROM orders GROUP BY user_id HAVING COUNT(*) > 1 ORDER BY user_id",
		clear_msgs = true,
	)
	testing.expect(t, ok)
	if !ok {
		return
	}
	rows, rows_ok := result.result.(Rows_With_Names)
	testing.expect(t, rows_ok)
	if !rows_ok {
		return
	}
	testing.expect_value(t, len(rows.rows), 1)
	testing.expect(t, value_exactly_equal(rows.rows[0][0], 1))
	testing.expect(t, value_exactly_equal(rows.rows[0][1], 2))
}

@(test)
execution_tree_test_aggregate_arithmetic_expression_returns_row :: proc(t: ^testing.T) {
	defer main_finish()
	main_init()
	__testing__execution_tree_seed_users_table()

	result, ok := exec("SELECT SUM(age)/COUNT(age), AVG(age) FROM users", clear_msgs = true)
	testing.expect(t, ok)
	if !ok {
		return
	}
	rows, rows_ok := result.result.(Rows_With_Names)
	testing.expect(t, rows_ok)
	if !rows_ok {
		return
	}
	testing.expect_value(t, len(rows.rows), 1)
	testing.expect(t, value_exactly_equal(rows.rows[0][0], 95.0 / 3.0))
	testing.expect(t, value_exactly_equal(rows.rows[0][1], 95.0 / 3.0))
}

@(test)
execution_tree_test_aggregate_in_where_is_rejected :: proc(t: ^testing.T) {
	defer main_finish()
	main_init()
	__testing_execution_tree_seed_orders_table()
	_, ok := exec(
		"SELECT user_id, COUNT(*) FROM orders WHERE COUNT(*) > 0 GROUP BY user_id",
		clear_msgs = true,
	)
	testing.expect(t, !ok)
}

@(test)
execution_tree_test_columnar_filter_projection_handles_null_selection :: proc(t: ^testing.T) {
	defer main_finish()
	main_init()
	database_tables_clear()
	_, ok := exec(
		"CREATE TABLE @columnar events (id INTEGER, score FLOAT, primary key(id))",
		clear_msgs = true,
	)
	testing.expect(t, ok)
	if !ok {
		return
	}
	_, ok = exec(
		"INSERT INTO events (id, score) VALUES (1, 4.5), (2, NULL), (3, 9.25), (4, NULL), (5, 1.0)",
		clear_msgs = true,
	)
	testing.expect(t, ok)
	if !ok {
		return
	}
	{
		result, ok := exec(
			"SELECT id, score FROM events WHERE score > 2 ORDER BY id",
			clear_msgs = true,
		)
		testing.expect(t, ok)
		if !ok {
			return
		}
		rows, rows_ok := result.result.(Rows_With_Names)
		testing.expect(t, rows_ok)
		if !rows_ok {
			return
		}
		testing.expect_value(t, len(rows.rows), 2)
		testing.expect(t, value_exactly_equal(rows.rows[0][0], 1))
		testing.expect(t, value_exactly_equal(rows.rows[0][1], 4.5))
		testing.expect(t, value_exactly_equal(rows.rows[1][0], 3))
		testing.expect(t, value_exactly_equal(rows.rows[1][1], 9.25))
	}
}

@(test)
execution_tree_test_columnar_aggregate_spans_multiple_chunks :: proc(t: ^testing.T) {
	defer main_finish()
	main_init()
	database_tables_clear()
	_, ok := exec(
		"CREATE TABLE @columnar metrics (id INTEGER, grp INTEGER, primary key(id))",
		clear_msgs = true,
	)
	testing.expect(t, ok)
	if !ok {
		return
	}
	for i := 0; i < COLUMN_CHUNK_SIZE + 17; i += 1 {
		_, insert_ok := exec(
			fmt.tprintf("INSERT INTO metrics (id, grp) VALUES (%v, %v)", i + 1, i % 3),
			clear_msgs = true,
		)
		testing.expect(t, insert_ok)
		if !insert_ok {
			return
		}
	}
	{
		result, ok := exec(
			"SELECT grp, COUNT(*) FROM metrics GROUP BY grp ORDER BY grp",
			clear_msgs = true,
		)
		testing.expect(t, ok)
		if !ok {
			return
		}
		rows, rows_ok := result.result.(Rows_With_Names)
		testing.expect(t, rows_ok)
		if !rows_ok {
			return
		}
		testing.expect_value(t, len(rows.rows), 3)
		testing.expect(t, value_exactly_equal(rows.rows[0][0], 0))
		testing.expect(t, value_exactly_equal(rows.rows[1][0], 1))
		testing.expect(t, value_exactly_equal(rows.rows[2][0], 2))
	}
}

@(test)
execution_tree_test_row_and_columnar_results_match_for_join_pipeline :: proc(t: ^testing.T) {
	defer main_finish()
	main_init()
	database_tables_clear()
	_, ok := exec(
		"CREATE TABLE users_row (id INTEGER, age INTEGER, primary key(id))",
		clear_msgs = true,
	)
	testing.expect(t, ok)
	if !ok {
		return
	}
	_, ok = exec(
		"CREATE TABLE @columnar users_col (id INTEGER, age INTEGER, primary key(id))",
		clear_msgs = true,
	)
	testing.expect(t, ok)
	if !ok {
		return
	}
	_, ok = exec(
		"CREATE TABLE orders_row (id INTEGER, user_id INTEGER, primary key(id))",
		clear_msgs = true,
	)
	testing.expect(t, ok)
	if !ok {
		return
	}
	_, ok = exec(
		"CREATE TABLE @columnar orders_col (id INTEGER, user_id INTEGER, primary key(id))",
		clear_msgs = true,
	)
	testing.expect(t, ok)
	if !ok {
		return
	}
	_, ok = exec(
		"INSERT INTO users_row (id, age) VALUES (1, 30), (2, 24), (3, 41)",
		clear_msgs = true,
	)
	testing.expect(t, ok)
	_, ok = exec(
		"INSERT INTO users_col (id, age) VALUES (1, 30), (2, 24), (3, 41)",
		clear_msgs = true,
	)
	testing.expect(t, ok)
	_, ok = exec(
		"INSERT INTO orders_row (id, user_id) VALUES (10, 1), (11, 1), (12, 3)",
		clear_msgs = true,
	)
	testing.expect(t, ok)
	_, ok = exec(
		"INSERT INTO orders_col (id, user_id) VALUES (10, 1), (11, 1), (12, 3)",
		clear_msgs = true,
	)
	testing.expect(t, ok)
	if !ok {
		return
	}
	query_row := "SELECT users_row.id, COUNT(*) FROM users_row JOIN orders_row ON users_row.id = orders_row.user_id GROUP BY users_row.id ORDER BY users_row.id"
	query_col := "SELECT users_col.id, COUNT(*) FROM users_col JOIN orders_col ON users_col.id = orders_col.user_id GROUP BY users_col.id ORDER BY users_col.id"
	row_result, row_ok := exec(query_row, clear_msgs = true)
	testing.expect(t, row_ok)
	col_result, col_ok := exec(query_col, clear_msgs = true)
	testing.expect(t, col_ok)
	if !row_ok || !col_ok {
		return
	}
	row_rows, row_rows_ok := row_result.result.(Rows_With_Names)
	col_rows, col_rows_ok := col_result.result.(Rows_With_Names)
	testing.expect(t, row_rows_ok)
	testing.expect(t, col_rows_ok)
	if !row_rows_ok || !col_rows_ok {
		return
	}
	testing.expect_value(t, len(row_rows.rows), len(col_rows.rows))
	for i in 0 ..< len(row_rows.rows) {
		testing.expect_value(t, len(row_rows.rows[i]), len(col_rows.rows[i]))
		for j in 0 ..< len(row_rows.rows[i]) {
			testing.expect(t, value_exactly_equal(row_rows.rows[i][j], col_rows.rows[i][j]))
		}
	}
}

@(test)
execution_tree_test_transaction_commit_persists_dml :: proc(t: ^testing.T) {
	defer main_finish()
	main_init()
	database_tables_clear()
	_, ok := exec(
		"CREATE TABLE tx_users (id INTEGER, name TEXT, primary key(id))",
		clear_msgs = true,
	)
	testing.expect(t, ok)
	if !ok {
		return
	}
	_, ok = exec("BEGIN", clear_msgs = true)
	testing.expect(t, ok)
	_, ok = exec("INSERT INTO tx_users (id, name) VALUES (1, 'Alice')", clear_msgs = true)
	testing.expect(t, ok)
	_, ok = exec("COMMIT", clear_msgs = true)
	testing.expect(t, ok)
	if !ok {
		return
	}
	{
		result, ok := exec("SELECT id FROM tx_users WHERE id = 1", clear_msgs = true)
		testing.expect(t, ok)
		if !ok {
			return
		}
		rows, rows_ok := result.result.(Rows_With_Names)
		testing.expect(t, rows_ok)
		if !rows_ok {
			return
		}
		testing.expect_value(t, len(rows.rows), 1)
	}
}

@(test)
execution_tree_test_transaction_rollback_reverts_dml_and_ddl :: proc(t: ^testing.T) {
	defer main_finish()
	main_init()
	database_tables_clear()
	_, ok := exec(
		"CREATE TABLE tx_users (id INTEGER, name TEXT, primary key(id))",
		clear_msgs = true,
	)
	testing.expect(t, ok)
	if !ok {
		return
	}
	_, ok = exec("BEGIN", clear_msgs = true)
	testing.expect(t, ok)
	_, ok = exec("INSERT INTO tx_users (id, name) VALUES (2, 'Bob')", clear_msgs = true)
	testing.expect(t, ok)
	_, ok = exec("CREATE TABLE tx_tmp (id INTEGER, primary key(id))", clear_msgs = true)
	testing.expect(t, ok)
	_, ok = exec("ROLLBACK", clear_msgs = true)
	testing.expect(t, ok)
	if !ok {
		return
	}
	{
		result, ok := exec("SELECT id FROM tx_users WHERE id = 2", clear_msgs = true)
		testing.expect(t, ok)
		if !ok {
			return
		}
		rows, rows_ok := result.result.(Rows_With_Names)
		testing.expect(t, rows_ok)
		if !rows_ok {
			return
		}
		testing.expect_value(t, len(rows.rows), 0)
		_, table_exists := database_find_table("tx_tmp", log_error = false)
		testing.expect(t, !table_exists)
	}
}

@(test)
execution_tree_test_transaction_command_validation_and_autocommit :: proc(t: ^testing.T) {
	defer main_finish()
	main_init()
	database_tables_clear()
	_, ok := exec("COMMIT", clear_msgs = true)
	testing.expect(t, !ok)
	_, ok = exec("ROLLBACK", clear_msgs = true)
	testing.expect(t, !ok)
	_, ok = exec("BEGIN", clear_msgs = true)
	testing.expect(t, ok)
	_, ok = exec("BEGIN", clear_msgs = true)
	testing.expect(t, !ok)
	_, _ = exec("ROLLBACK", clear_msgs = true)

	_, ok = exec("CREATE TABLE tx_auto (id INTEGER, primary key(id))", clear_msgs = true)
	testing.expect(t, ok)
	_, ok = exec("INSERT INTO tx_auto (id) VALUES (7)", clear_msgs = true)
	testing.expect(t, ok)
	{
		result, ok := exec("SELECT id FROM tx_auto WHERE id = 7", clear_msgs = true)
		testing.expect(t, ok)
		if !ok {
			return
		}
		rows, rows_ok := result.result.(Rows_With_Names)
		testing.expect(t, rows_ok)
		if !rows_ok {
			return
		}
		testing.expect_value(t, len(rows.rows), 1)
	}
}
