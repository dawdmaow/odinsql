#+build !js
#+vet explicit-allocators

package main

import "core:encoding/json"
import "core:log"
import "core:mem"
import "core:slice"
import "core:strings"
import "core:testing"

@(rodata)
examples_json_string := #load("query_examples.json", string)

split_example_statements :: proc(sql: string, allocator := context.allocator) -> [dynamic]string {
	statements := make([dynamic]string, allocator)

	start := 0
	in_single := false
	in_double := false
	escape_next := false

	// Keep splitting logic aligned with the web runner: `;` ends a statement only
	// when we're not inside quoted text.
	for i := 0; i < len(sql); i += 1 {
		ch := sql[i]
		if escape_next {
			escape_next = false
			continue
		}
		if ch == '\\' && (in_single || in_double) {
			escape_next = true
			continue
		}
		if ch == '\'' && !in_double {
			in_single = !in_single
			continue
		}
		if ch == '"' && !in_single {
			in_double = !in_double
			continue
		}
		if ch == ';' && !in_single && !in_double {
			statement := strings.trim_space(sql[start:i])
			if len(statement) > 0 {
				append(&statements, statement)
			}
			start = i + 1
		}
	}

	last_statement := strings.trim_space(sql[start:])
	if len(last_statement) > 0 {
		append(&statements, last_statement)
	}
	return statements
}

testing_sort_rows :: proc(rows: [][]Database_Value) {
	slice.sort_by_cmp(
		rows[:],
		proc(a, b: []Database_Value) -> slice.Ordering {
			// Lexicographic row compare:
			// - compare first differing cell using the database value ordering
			// - if all shared cells match, shorter row sorts first
			assert(len(a) == len(b))
			for a_row, row_index in a {
				b_row := b[row_index]
				for a_value, value_index in a {
					b_value := b[value_index]
					cell_order := value_ordering_for_column_sorting(a_value, b_value)
					if cell_order != .Equal do return cell_order
				}
				return slice.cmp(len(a), len(b))
			}
			return .Equal
		},
	)
}

testing_compare_rows_ordered :: proc(
	t: ^testing.T,
	rows: Rows_With_Names,
	expected_column_names: []string,
	expected_rows: [][]Database_Value,
) -> bool {
	testing.expect_value(t, len(rows.column_names), len(expected_column_names))
	testing.expect_value(t, len(rows.rows), len(expected_rows))

	for row, row_index in rows.rows {
		expected_row := expected_rows[row_index]
		for value, value_index in row {
			expected_value := expected_row[value_index]
			testing.expectf(
				t,
				value_ordering_for_column_sorting(value, expected_value) == .Equal,
				"Expected %v, got %v",
				expected_value,
				value,
			) or_return
		}
	}

	return true
}

testing_compare_rows_UNordered :: proc(
	t: ^testing.T,
	rows: Rows_With_Names,
	expected_column_names: []string,
	expected_rows: [][]Database_Value,
) -> bool {
	rows_tmp := make([dynamic][]Database_Value, database_query_allocator)
	for row in rows.rows do append(&rows_tmp, row[:])
	testing_sort_rows(rows_tmp[:])
	testing_sort_rows(expected_rows[:])

	testing.expectf(
		t,
		len(rows_tmp) == len(expected_rows),
		"Expected %v rows, got %v",
		len(expected_rows),
		len(rows_tmp),
	) or_return

	for row, row_index in rows_tmp {
		expected_row := expected_rows[row_index]
		for value, value_index in row {
			expected_value := expected_row[value_index]
			testing.expect(
				t,
				value_ordering_for_column_sorting(value, expected_value) == .Equal,
			) or_return
		}
	}

	return true
}

testing_run_query :: proc(
	t: ^testing.T,
	query: string,
	user_data: rawptr,
	init_proc: proc(),
	test_proc: proc(t: ^testing.T, result: Exec_Result, user_data: rawptr),
) {
	main_init()
	defer main_finish()
	init_proc()

	result, ok := exec(query, clear_msgs = true)
	if !testing.expectf(t, ok, "Source: ###\n%s\n###\n\nResult: %#v.\n", query, result.result) {
		return
	}

	test_proc(t, result, user_data)
}

@(test)
examples :: proc(t: ^testing.T) {
	arena: mem.Arena
	buffer := new([1024 * 1024]u8, context.allocator)
	defer free(buffer, context.allocator)
	mem.arena_init(&arena, buffer[:])

	Example :: struct {
		id:    string,
		label: string,
		code:  []string,
	}
	examples: []Example

	// TODO: just use temp_allocator
	if !testing.expect_value(
		t,
		json.unmarshal_string(
			examples_json_string,
			&examples,
			allocator = mem.arena_allocator(&arena),
		),
		nil,
	) {
		return
	}

	for &example in examples {
		// TODO: just use temp_allocator
		source := strings.join(example.code, "\n", allocator = mem.arena_allocator(&arena))

		testing_run_query(t, source, &example, proc() {
			init_sample_db()
		}, proc(t: ^testing.T, result: Exec_Result, user_data: rawptr) {
			example := cast(^Example)user_data
			log.infof("EXAMPLE: %v", example.id)
			switch example.id {
			case "basic-select-all":
				testing_compare_rows_UNordered(
					t,
					result.result.(Rows_With_Names),
					[]string{"id", "name", "age", "status"},
					[][]Database_Value {
						{1, database_string_make("Alice"), 25, database_string_make("active")},
						{2, database_string_make("Bob"), 30, database_string_make("inactive")},
						{3, database_string_make("Charlie"), 35, database_string_make("active")},
						{4, database_string_make("Diana"), 28, database_string_make("active")},
						{5, database_string_make("Ethan"), 41, database_string_make("vip")},
						{6, database_string_make("Fiona"), 22, database_string_make("trial")},
					},
				)
			case "basic-filter-order-limit":
				testing_compare_rows_ordered(
					t,
					result.result.(Rows_With_Names),
					[]string{"id", "name", "age", "status"},
					[][]Database_Value {
						{5, database_string_make("Ethan"), 41, database_string_make("vip")},
						{3, database_string_make("Charlie"), 35, database_string_make("active")},
						{4, database_string_make("Diana"), 28, database_string_make("active")},
					},
				)
			case "basic-arithmetic-aliases":
				testing_compare_rows_ordered(
					t,
					result.result.(Rows_With_Names),
					[]string{"user_id", "user_name", "age_in_5_years"},
					[][]Database_Value {
						{1, database_string_make("Alice"), 30},
						{2, database_string_make("Bob"), 35},
						{3, database_string_make("Charlie"), 40},
						{4, database_string_make("Diana"), 33},
						{5, database_string_make("Ethan"), 46},
						{6, database_string_make("Fiona"), 27},
					},
				)
			case "join-inner-users-orders":
				testing_compare_rows_ordered(
					t,
					result.result.(Rows_With_Names),
					[]string{"name", "order_id", "product", "amount"},
					[][]Database_Value {
						{database_string_make("Diana"), 106, database_string_make("Desk"), 420},
						{
							database_string_make("Charlie"),
							104,
							database_string_make("Monitor"),
							350,
						},
						{database_string_make("Ethan"), 107, database_string_make("Chair"), 260},
						{database_string_make("Bob"), 102, database_string_make("Gadget"), 200},
						{database_string_make("Alice"), 103, database_string_make("Tool"), 150},
						{database_string_make("Alice"), 101, database_string_make("Widget"), 100},
						{database_string_make("Diana"), 105, database_string_make("Keyboard"), 80},
						{database_string_make("Fiona"), 108, database_string_make("Mouse"), 60},
					},
				)
			case "join-left-payments-shipments":
				testing_compare_rows_ordered(
					t,
					result.result.(Rows_With_Names),
					[]string{"order_id", "product", "payment_status", "shipment_state"},
					[][]Database_Value {
						{
							101,
							database_string_make("Widget"),
							database_string_make("settled"),
							database_string_make("delivered"),
						},
						{102, database_string_make("Gadget"), database_string_make("failed"), nil},
						{
							103,
							database_string_make("Tool"),
							database_string_make("settled"),
							database_string_make("in_transit"),
						},
						{
							104,
							database_string_make("Monitor"),
							database_string_make("pending"),
							nil,
						},
						{
							105,
							database_string_make("Keyboard"),
							database_string_make("settled"),
							database_string_make("packed"),
						},
						{106, database_string_make("Desk"), database_string_make("pending"), nil},
						{
							107,
							database_string_make("Chair"),
							database_string_make("settled"),
							database_string_make("delivered"),
						},
						{108, database_string_make("Mouse"), database_string_make("failed"), nil},
					},
				)
			case "join-cross-preview":
				testing_compare_rows_ordered(
					t,
					result.result.(Rows_With_Names),
					[]string{"name", "carrier"},
					[][]Database_Value {
						{database_string_make("Alice"), database_string_make("DHL")},
						{database_string_make("Alice"), database_string_make("DHL")},
						{database_string_make("Alice"), database_string_make("InPost")},
						{database_string_make("Alice"), database_string_make("UPS")},
						{database_string_make("Bob"), database_string_make("DHL")},
						{database_string_make("Bob"), database_string_make("DHL")},
						{database_string_make("Bob"), database_string_make("InPost")},
						{database_string_make("Bob"), database_string_make("UPS")},
						{database_string_make("Charlie"), database_string_make("DHL")},
						{database_string_make("Charlie"), database_string_make("DHL")},
						{database_string_make("Charlie"), database_string_make("InPost")},
						{database_string_make("Charlie"), database_string_make("UPS")},
					},
				)
			case "subquery-in-orders":
				testing_compare_rows_ordered(
					t,
					result.result.(Rows_With_Names),
					[]string{"id", "name", "status"},
					[][]Database_Value {
						{2, database_string_make("Bob"), database_string_make("inactive")},
						{3, database_string_make("Charlie"), database_string_make("active")},
						{4, database_string_make("Diana"), database_string_make("active")},
						{5, database_string_make("Ethan"), database_string_make("vip")},
					},
				)
			case "subquery-derived-table":
				testing_compare_rows_ordered(
					t,
					result.result.(Rows_With_Names),
					[]string{"user_id", "amount"},
					[][]Database_Value{{4, 420}, {3, 350}, {5, 260}},
				)
			case "subquery-double-nested":
				testing_compare_rows_ordered(
					t,
					result.result.(Rows_With_Names),
					[]string{"id", "name", "status"},
					[][]Database_Value {
						{2, database_string_make("Bob"), database_string_make("inactive")},
						{3, database_string_make("Charlie"), database_string_make("active")},
						{4, database_string_make("Diana"), database_string_make("active")},
						{5, database_string_make("Ethan"), database_string_make("vip")},
					},
				)
			case "aggregate-count-sum":
				testing_compare_rows_ordered(
					t,
					result.result.(Rows_With_Names),
					[]string{"user_id", "orders_count", "total_amount"},
					[][]Database_Value {
						{4, 2, 500},
						{3, 1, 350},
						{5, 1, 260},
						{1, 2, 250},
						{2, 1, 200},
						{6, 1, 60},
					},
				)
			case "aggregate-having":
				testing_compare_rows_ordered(
					t,
					result.result.(Rows_With_Names),
					[]string{"user_id", "order_count"},
					[][]Database_Value{{1, 2}, {4, 2}},
				)
			case "aggregate-joined-revenue":
				testing_compare_rows_ordered(
					t,
					result.result.(Rows_With_Names),
					[]string{"payer_user_id", "settled_total"},
					[][]Database_Value{{1, 250}, {5, 260}},
				)
			case "dml-batch-insert-update-delete":
				testing.expect_value(t, len(result.statement_results), 5)
				testing_compare_rows_ordered(
					t,
					result.result.(Rows_With_Names),
					[]string{"id", "name", "age", "status"},
					[][]Database_Value {
						{7, database_string_make("Gina"), 33, database_string_make("vip")},
					},
				)
			case "dml-update-join-check":
				testing.expect_value(t, len(result.statement_results), 2)
				testing_compare_rows_ordered(
					t,
					result.result.(Rows_With_Names),
					[]string{"order_id", "product", "status", "method"},
					[][]Database_Value {
						{
							106,
							database_string_make("Desk"),
							database_string_make("settled"),
							database_string_make("card"),
						},
					},
				)
			case "ddl-create-alter-index":
				testing.expect_value(t, len(result.statement_results), 9)
				testing_compare_rows_ordered(
					t,
					result.result.(Rows_With_Names),
					[]string{"item_id", "description", "quantity", "warehouse"},
					[][]Database_Value {
						{2, database_string_make("USB-C dock"), 14, database_string_make("BER-2")},
						{1, database_string_make("SSD 1TB"), 5, database_string_make("WAW-1")},
					},
				)
			case "ddl-rename-column":
				testing.expect_value(t, len(result.statement_results), 6)
				testing_compare_rows_ordered(
					t,
					result.result.(Rows_With_Names),
					[]string{"id", "full_name"},
					[][]Database_Value {
						{1, database_string_make("Ann")},
						{2, database_string_make("Ben")},
					},
				)
			case "tx-commit-flow":
				testing.expect_value(t, len(result.statement_results), 7)
				testing_compare_rows_ordered(
					t,
					result.result.(Rows_With_Names),
					[]string{"id", "name"},
					[][]Database_Value {
						{1, database_string_make("Committed Alice")},
						{2, database_string_make("Committed Bob")},
					},
				)
			case "tx-rollback-flow":
				testing.expect_value(t, len(result.statement_results), 6)
				testing_compare_rows_ordered(
					t,
					result.result.(Rows_With_Names),
					[]string{"id", "name"},
					[][]Database_Value{},
				)
			case "comprehensive-order-lifecycle":
				testing.expect_value(t, len(result.statement_results), 19)
				testing_compare_rows_UNordered(
					t,
					result.result.(Rows_With_Names),
					[]string{"user_id", "settled_orders", "settled_amount"},
					[][]Database_Value{{1, 1, 450}, {2, 1, 420}},
				)
			case "comprehensive-schema-evolution":
				testing.expect_value(t, len(result.statement_results), 12)
				testing_compare_rows_UNordered(
					t,
					result.result.(Rows_With_Names),
					[]string{"grp", "status", "rows_in_bucket", "total_score"},
					[][]Database_Value {
						{1, database_string_make("low"), 1, 10},
						{1, database_string_make("mid"), 1, 25},
						{2, database_string_make("high"), 1, 55},
						{2, database_string_make("mid"), 1, 40},
					},
				)
			case:
				testing.expectf(t, false, "Missing assertion case for example id '%v'", example.id)
			}
		})
	}
}
