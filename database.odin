package main

import "back"

import "core:fmt"
import "core:log"
import "core:mem"
import "core:slice"
import "core:strconv"
import "core:strings"

Nil :: struct {}

DB_Value :: union #no_nil {
	Nil,
	string,
	int,
	f64,
	bool,
}

DB_Row :: distinct map[string]DB_Value

DB_Table :: struct {
	name:         string,
	column_names: []string,
	primary_key:  string,
	rows:         [dynamic]DB_Row,
}

DB_Error :: struct {
	message: string,
}

DB :: struct {
	tables:    map[string]DB_Table,
	allocator: mem.Allocator,
}

database_init :: proc(db: ^DB, allocator := context.allocator) {
	db^ = DB {
		tables    = make(map[string]DB_Table, allocator),
		allocator = allocator,
	}
}

exec_select :: proc(db: ^DB, select: ^Select) -> (rows: [dynamic]DB_Row, ok: bool) {
	context.allocator = db.allocator

	result_rows: [dynamic]DB_Row
	base_table_name: string
	has_joins := len(select.joins) > 0

	#partial switch v in select.table_or_subquery.value {
	case ^Select:
		result_rows = exec_select(db, v) or_return
		base_table_name = ""
	case ^AST_Ident:
		base_table_name = ident_tstring(v)

		if base_table_name not_in db.tables {
			log.errorf("Table '%s' does not exist", base_table_name)
			return nil, false
		}

		base_table := &db.tables[base_table_name]
		result_rows = make([dynamic]DB_Row)

		for table_row in base_table.rows {
			// qualify row keys with table name if there are any joins in the select statement
			if has_joins {
				row := make(DB_Row)
				for col, val in table_row {
					qualified_key := fmt.tprintf("%s.%s", base_table_name, col)
					row[qualified_key] = val
				}
				append(&result_rows, row)
			} else {
				row := make(DB_Row)
				for k, v in table_row {
					row[k] = v
				}
				append(&result_rows, row)
			}
		}
	case:
		log.error("Expected table to be Ident or Select subquery")
		return nil, false
	}

	for join in select.joins {
		result_rows = apply_join(db, result_rows, join) or_return
	}

	if select.where_clause != nil {
		filtered := make([dynamic]DB_Row)
		for row in result_rows {
			if evaluate_expression(db, select.where_clause, row) or_return {
				append(&filtered, row)
			}
		}
		result_rows = filtered
	}

	result_rows = apply_column_selection(
		db,
		result_rows,
		select.cols,
		has_joins,
		base_table_name,
	) or_return

	return result_rows, true
}

// for 'SELECT' statements, only keep columns that were actually requested.
apply_column_selection :: proc(
	db: ^DB,
	result_rows: [dynamic]DB_Row,
	cols: [dynamic]^AST_Ident,
	has_joins: bool,
	base_table_name: string,
) -> (
	rows: [dynamic]DB_Row,
	ok: bool,
) {
	context.allocator = db.allocator

	if len(result_rows) == 0 {
		return result_rows, true
	}

	for col in cols {
		if text := col.value.(^AST_Ident) or_else nil; text != nil && text.name == "*" {
			return result_rows, true
		}
	}

	all_filtered_rows := make([dynamic]DB_Row)

	for row in result_rows {
		filtered_row := make(DB_Row)

		for col in cols {
			ident := col.value.(^AST_Ident)

			value: DB_Value
			output_key := ident.name

			// TODO:  a bunch of hidden assumptions about key strings from result_rows in here...

			if ident.table_prefix != "" { 	// if identifier is unqualified
				qualified_str := ident_tstring(ident)
				if qualified_str in row { 	// if qualified identifier is in the results, keep it
					value = row[qualified_str]
					output_key = qualified_str
				} else if !has_joins && ident.table_prefix == base_table_name {
					if ident.name in row {
						// if there are no joins and table matches with the base table, keep the result without the table name
						value = row[ident.name]
						output_key = ident.name
					} else {
						log.errorf(
							"Unknown column '%s' in table '%s'",
							ident.name,
							ident.table_prefix,
						)
						return nil, false
					}
				} else {
					log.errorf(
						"Unknown table '%s' in column identifier '%s'",
						ident.table_prefix,
						qualified_str,
					)
					return nil, false
				}
			} else if has_joins {
				// if ident has no table name attached and there are joins, we need to find the matching table for this column name
				matching_keys := make([dynamic]string, allocator = context.temp_allocator)

				for key in row {
					suffix := fmt.tprintf(".%s", ident.name) // we're only interested in qualified results
					if strings.has_suffix(key, suffix) {
						append(&matching_keys, key)
					}
				}

				switch {
				case len(matching_keys) > 1:
					tables := make([dynamic]string, allocator = context.temp_allocator)
					for key in matching_keys {
						// TODO: splitting into parts to get table name is terrible, just keep the table name explicitly...
						parts := strings.split(key, ".", allocator = context.temp_allocator)
						if len(parts) > 0 {
							append(&tables, parts[0])
						}
					}
					log.errorf("Column '%s' is ambiguous between tables: %v", ident.name, tables)
					return nil, false
				case len(matching_keys) == 1:
					value = row[matching_keys[0]]
				case:
					log.errorf("Unknown column '%s'", ident.name)
					return nil, false
				}
			} else if ident.name in row {
				value = row[ident.name]
			} else {
				log.errorf("Unknown column '%s'", ident.name)
				return nil, false
			}

			filtered_row[output_key] = value
		}
		append(&all_filtered_rows, filtered_row)
	}

	return all_filtered_rows, true
}

exec_insert :: proc(db: ^DB, insert: ^Insert) -> (count: int, ok: bool) {
	context.allocator = db.allocator

	table_ident, table_ident_ok := insert.table.value.(^AST_Ident)
	if !table_ident_ok {
		log.errorf("Invalid table name")
		return 0, false
	}

	if table_ident.table_prefix != "" {
		log.errorf("Invalid table name: %s.%s", table_ident.table_prefix, table_ident.name)
		return 0, false
	}

	table_name := table_ident.name

	table, table_ok := &db.tables[table_name]
	if !table_ok {
		log.errorf("Table '%s' does not exist", table_name)
		return 0, false
	}

	rows_inserted := 0

	for value_list in insert.value_lists {
		new_row := make(DB_Row)
		for col in table.column_names {
			new_row[col] = {}
		}

		if len(insert.specified_columns) > 0 {
			if len(insert.specified_columns) != len(value_list) {
				log.errorf(
					"Column count (%d) doesn't match value count (%d)",
					len(insert.specified_columns),
					len(value_list),
				)
				return 0, false
			}

			for i := 0; i < len(insert.specified_columns); i += 1 {
				col_node := insert.specified_columns[i]
				val_node := value_list[i]

				col_ident, col_ok := col_node.value.(^AST_Ident)
				if !col_ok {
					log.error("Expected column to be Ident")
					return 0, false
				}
				col_name := col_ident.name

				val := evaluate_term(db, val_node, make(DB_Row)) or_return
				cell_val, cell_ok := val.(DB_Value)
				if !cell_ok {
					log.errorf("Expected term to evaluate to Cell, got %v", val)
					return 0, false
				}
				new_row[col_name] = cell_val
			}
		} else {
			if len(table.column_names) != len(value_list) {
				log.errorf(
					"Column count (%d) doesn't match value count (%d)",
					len(table.column_names),
					len(value_list),
				)
				return 0, false
			}

			for i := 0; i < len(table.column_names); i += 1 {
				col_name := table.column_names[i]
				val_node := value_list[i]

				val := evaluate_term(db, val_node, make(DB_Row)) or_return
				cell_val, cell_ok := val.(DB_Value)
				if !cell_ok {
					log.errorf("Unexpected term result: %v", val)
					return 0, false
				}
				new_row[col_name] = cell_val
			}
		}

		primary_key_value := new_row[table.primary_key]
		if primary_key_value == {} {
			log.errorf(
				"Primary key value for column '%s' must be provided and cannot be NULL",
				table.primary_key,
			)
			return 0, false
		}

		for existing_row in table.rows {
			if existing_pk := existing_row[table.primary_key]; existing_pk != {} {
				if new_pk := primary_key_value; new_pk != {} {
					if compare_cells_equal(existing_pk, new_pk) {
						log.errorf("Primary key value already exists in table '%s'", table_name)
						return 0, false
					}
				}
			}
		}

		prev_len := len(table.rows)
		append(&table.rows, new_row)
		assert(len(table.rows) == prev_len + 1)
		rows_inserted += 1
	}

	return rows_inserted, true
}

exec_update :: proc(db: ^DB, update: ^Update) -> (count: int, ok: bool) {
	context.allocator = db.allocator

	table_ident, ident_ok := update.table.value.(^AST_Ident)
	if !ident_ok {
		log.errorf("Invalid table name: %v", update.table.value)
		return 0, false
	}
	table_name := table_ident.name

	if table_name not_in db.tables {
		log.errorf("Table '%s' does not exist", table_name)
		return 0, false
	}

	table := &db.tables[table_name]
	rows_updated := 0

	for &row in table.rows {
		should_update := true
		if where_clause, has_where := update.where_clause.?; has_where {
			should_update = evaluate_expression(db, where_clause, row) or_return
		}

		if should_update {
			for set_clause in update.set_clauses {
				ident_node := set_clause.column
				term_node := set_clause.value

				ident, ident_ok := ident_node.value.(^AST_Ident)
				if !ident_ok {
					log.error("Expected column to be Ident")
					return 0, false
				}
				column_name := ident.name

				found := false
				for col in table.column_names {
					if col == column_name {
						found = true
						break
					}
				}
				if !found {
					log.errorf("Column '%s' does not exist in table '%s'", column_name, table_name)
					return 0, false
				}

				new_value := evaluate_term(db, term_node, row) or_return
				cell_val, cell_ok := new_value.(DB_Value)
				if !cell_ok {
					log.errorf("Unexpected term result: %v", new_value)
					return 0, false
				}
				row[column_name] = cell_val
			}

			rows_updated += 1
		}
	}

	return rows_updated, true
}

exec_delete :: proc(db: ^DB, delete_stmt: ^Delete) -> (count: int, ok: bool) {
	context.allocator = db.allocator

	table_ident, ident_ok := delete_stmt.table.value.(^AST_Ident)
	if !ident_ok {
		log.error("Expected table to be Ident")
		return 0, false
	}
	table_name := table_ident.name

	if table_name not_in db.tables {
		log.errorf("Table '%s' does not exist", table_name)
		return 0, false
	}

	table := &db.tables[table_name]
	rows_to_delete := make([dynamic]int)
	defer delete(rows_to_delete)

	for row, i in table.rows {
		should_delete := true
		if where_clause, has_where := delete_stmt.where_clause.?; has_where {
			should_delete = evaluate_expression(db, where_clause, row) or_return
		}

		if should_delete {
			append(&rows_to_delete, i)
		}
	}

	for i := len(rows_to_delete) - 1; i >= 0; i -= 1 {
		ordered_remove(&table.rows, rows_to_delete[i])
	}

	return len(rows_to_delete), true
}

exec_create_table :: proc(db: ^DB, create_table: ^Create_Table) -> bool {
	context.allocator = db.allocator

	table_name := create_table.table_name

	if table_name in db.tables {
		log.errorf("Table '%s' already exists", table_name)
		return false
	}

	primary_key, has_pk := create_table.primary_key.?
	if !has_pk {
		log.errorf("Table '%s' must have a PRIMARY KEY defined", table_name)
		return false
	}

	found := false
	for col in create_table.columns {
		if col == primary_key {
			found = true
			break
		}
	}
	if !found {
		log.errorf("Primary key column '%s' not found in table columns", primary_key)
		return false
	}

	table: DB_Table
	table.name = table_name
	table.column_names = make([]string, len(create_table.columns))
	for col, i in create_table.columns {
		table.column_names[i] = col
	}
	table.primary_key = primary_key
	table.rows = make([dynamic]DB_Row)

	db.tables[table_name] = table

	return true
}

apply_join :: proc(
	db: ^DB,
	left_rows: [dynamic]DB_Row,
	join: Join,
) -> (
	rows: [dynamic]DB_Row,
	ok: bool,
) {
	context.allocator = db.allocator

	join_ident, ident_ok := join.table.value.(^AST_Ident)
	if !ident_ok {
		log.error("Expected join table to be Ident")
		return nil, false
	}
	join_table_name := join_ident.name

	if join_table_name not_in db.tables {
		log.errorf("Table '%s' does not exist", join_table_name)
		return nil, false
	}

	join_table := &db.tables[join_table_name]
	result := make([dynamic]DB_Row)

	for lr in left_rows {
		matched := false

		for right_row in join_table.rows {
			combined_row := make(DB_Row)
			for k, v in lr {
				combined_row[k] = v
			}

			for name, val in right_row {
				qualified_name := fmt.tprintf("%s.%s", join_table_name, name)
				combined_row[qualified_name] = val
			}

			if evaluate_expression(db, join.condition, combined_row) or_return {
				append(&result, combined_row)
				matched = true
			}
		}

		if join.join_type == .Left && !matched {
			combined_row := make(DB_Row)
			for k, v in lr {
				combined_row[k] = v
			}

			for name in join_table.column_names {
				qualified_name := fmt.tprintf("%s.%s", join_table_name, name)
				combined_row[qualified_name] = {}
			}

			append(&result, combined_row)
		}
	}

	return result, true
}

compare_cells_equal :: proc(left: DB_Value, right: DB_Value) -> bool {
	switch l in left {
	case string:
		if r, ok := right.(string); ok {
			return l == r
		}
	case int:
		if r, ok := right.(int); ok {
			return l == r
		}
	case f64:
		if r, ok := right.(f64); ok {
			return l == r
		}
	case bool:
		if r, ok := right.(bool); ok {
			return l == r
		}
	case Nil:
		return right == {}
	}
	return false
}

compare_values :: proc(left, right: DB_Value, op_token: Token) -> (result: bool, ok: bool) {
	#partial switch op_token.kind {
	case .Equals:
		return compare_cells_equal(left, right), true
	case .Not_Equals:
		return !compare_cells_equal(left, right), true
	case .Greater_Than:
		left_num := cell_to_number(left) or_return
		right_num := cell_to_number(right) or_return
		return left_num > right_num, true
	case .Less_Than:
		left_num := cell_to_number(left) or_return
		right_num := cell_to_number(right) or_return
		return left_num < right_num, true
	case .Gt_Eq:
		left_num := cell_to_number(left) or_return
		right_num := cell_to_number(right) or_return
		return left_num >= right_num, true
	case .Lt_Eq:
		left_num := cell_to_number(left) or_return
		right_num := cell_to_number(right) or_return
		return left_num <= right_num, true
	}

	log.errorf("Unsupported operator: %s", op_token.text)
	return false, false
}

cell_to_number :: proc(cell: DB_Value) -> (f64, bool) {
	switch v in cell {
	case int:
		return f64(v), true
	case f64:
		return v, true
	case string, bool, Nil:
		return 0, false
	}
	log.errorf("Expected number, got %T", cell)
	return 0, false
}

evaluate_in_operation :: proc(
	db: ^DB,
	left_val: DB_Value,
	right_node: ^AST_Node,
) -> (
	result: bool,
	ok: bool,
) {
	context.allocator = db.allocator

	values := make([dynamic]DB_Value)
	defer delete(values)

	if select_stmt, is_select := right_node.value.(^Select); is_select {
		subquery_result := exec_select(db, select_stmt) or_return
		defer delete(subquery_result)

		for row in subquery_result {
			for _, val in row {
				append_elem(&values, val)
				break
			}
		}
	} else if node_list, is_list := right_node.value.([dynamic]^AST_Node); is_list {
		for val_node in node_list {
			val := evaluate_term(db, val_node, make(DB_Row)) or_return
			if cell_val, is_cell := val.(DB_Value); is_cell {
				append_elem(&values, cell_val)
			}
		}
	} else {
		log.error("IN operand must be a subquery or value list")
		return false, false
	}

	is_in := false
	if left_cell := left_val; left_cell != {} {
		for val in values {
			if compare_cells_equal(left_cell, val) {
				is_in = true
				break
			}
		}
	}

	return is_in, true
}

evaluate_like_operation :: proc(
	left_val: Maybe(DB_Value),
	right_val: Maybe(DB_Value),
) -> (
	result: bool,
	ok: bool,
) {
	left_cell, left_ok := left_val.?
	right_cell, right_ok := right_val.?

	if !left_ok || !right_ok {
		return false, true
	}

	left_str := cell_to_string(left_cell)
	right_str := cell_to_string(right_cell)

	matches := simple_like_match(left_str, right_str)

	return matches, true
}

cell_to_string :: proc(cell: DB_Value) -> string {
	switch v in cell {
	case string:
		return v
	case int:
		return fmt.tprintf("%d", v)
	case f64:
		return fmt.tprintf("%f", v)
	case bool:
		return fmt.tprintf("%t", v)
	case Nil:
		return "NULL"
	}
	return ""
}

simple_like_match :: proc(text: string, pattern: string) -> bool {
	ti := 0
	pi := 0

	for pi < len(pattern) && ti < len(text) {
		if pattern[pi] == '%' {
			if pi + 1 >= len(pattern) {
				return true
			}

			pi += 1
			for ti < len(text) {
				if simple_like_match(text[ti:], pattern[pi:]) {
					return true
				}
				ti += 1
			}
			return false
		} else if pattern[pi] == '_' {
			ti += 1
			pi += 1
		} else {
			if text[ti] != pattern[pi] {
				return false
			}
			ti += 1
			pi += 1
		}
	}

	for pi < len(pattern) && pattern[pi] == '%' {
		pi += 1
	}

	return ti == len(text) && pi == len(pattern)
}

evaluate_between_operation :: proc(
	db: ^DB,
	left_val: Maybe(DB_Value),
	right_node: ^AST_Node,
) -> (
	result: bool,
	ok: bool,
) {
	context.allocator = db.allocator

	left_cell, left_ok := left_val.?
	if !left_ok {
		return false, true
	}

	node_list, is_list := right_node.value.([dynamic]^AST_Node)
	if !is_list || len(node_list) != 2 {
		log.error("BETWEEN operation requires two values (low AND high)")
		return false, false
	}

	min_val := evaluate_term(db, node_list[0], make(DB_Row)) or_return
	max_val := evaluate_term(db, node_list[1], make(DB_Row)) or_return

	min_cell, min_ok := min_val.(DB_Value)
	max_cell, max_ok := max_val.(DB_Value)

	if !min_ok || !max_ok {
		return false, false
	}

	left_num, left_is_num := cell_to_number(left_cell)
	min_num, min_is_num := cell_to_number(min_cell)
	max_num, max_is_num := cell_to_number(max_cell)

	if !left_is_num || !min_is_num || !max_is_num {
		log.errorf(
			"Unexpected types for BETWEEN operation: %T, %T, %T",
			left_cell,
			min_cell,
			max_cell,
		)
		return false, false
	}

	is_between := min_num <= left_num && left_num <= max_num

	return is_between, true
}

Eval_Term_Result :: union {
	DB_Value,
	[dynamic]DB_Row,
	[dynamic]^AST_Node,
}

evaluate_expression :: proc(
	db: ^DB,
	expr_node: ^AST_Node,
	row: DB_Row,
) -> (
	result: bool,
	ok: bool,
) {
	context.allocator = db.allocator

	if cond, is_cond := expr_node.value.(^Condition); is_cond {
		op_token := cond.op.token
		if op_token.kind == .In {
			left_val := evaluate_term(db, cond.a, row) or_return
			left_cell := left_val.(DB_Value)
			return evaluate_in_operation(db, left_cell, cond.b)
		} else if op_token.kind == .Not_In {
			left_val := evaluate_term(db, cond.a, row) or_return
			left_cell := left_val.(DB_Value)
			result, ok = evaluate_in_operation(db, left_cell, cond.b)
			result = !result
			return
		} else {
			a := evaluate_term(db, cond.a, row) or_return
			b := evaluate_term(db, cond.b, row) or_return
			// TODO: these can be nil, in addition to Nil{}...

			a_cell, a_ok := a.(DB_Value)
			b_cell, b_ok := b.(DB_Value)

			if op_token.kind == .Equals ||
			   op_token.kind == .Not_Equals ||
			   op_token.kind == .Greater_Than ||
			   op_token.kind == .Less_Than ||
			   op_token.kind == .Gt_Eq ||
			   op_token.kind == .Lt_Eq {
				return compare_values(a_cell, b_cell, op_token)
			} else if op_token.kind == .Like {
				return evaluate_like_operation(a_cell, b_cell)
			} else if op_token.kind == .Not_Like {
				result, ok = evaluate_like_operation(a_cell, b_cell)
				result = !result
				return
			} else if op_token.kind == .Between {
				return evaluate_between_operation(db, a_cell, cond.b)
			} else if op_token.kind == .Not_Between {
				result, ok = evaluate_between_operation(db, a_cell, cond.b)
				result = !result
				return
			} else if op_token.kind == .And {
				left_bool := evaluate_expression(db, cond.a, row) or_return
				if !left_bool {
					return false, true
				}
				right_bool := evaluate_expression(db, cond.b, row) or_return
				return right_bool, true
			} else if op_token.kind == .Or {
				left_bool := evaluate_expression(db, cond.a, row) or_return
				if left_bool {
					return true, true
				}
				right_bool := evaluate_expression(db, cond.b, row) or_return
				return right_bool, true
			} else {
				log.errorf("Unsupported operator: %s", op_token.text)
				return false, false
			}
		}
	} else if unary, is_unary := expr_node.value.(^Unary_Expression); is_unary {
		operand_val := evaluate_expression(db, unary.operand, row) or_return
		op_text, op_ok := unary.op.value.(^AST_String)
		if !op_ok {
			log.error("Expected operator to be string")
			return false, false
		}

		if op_text.text == "NOT" {
			return !operand_val, true
		} else {
			log.errorf("Unsupported unary operator: %s", op_text)
			return false, false
		}
	}

	log.errorf("Unsupported expression type")
	return false, false
}

evaluate_term :: proc(
	db: ^DB,
	term_node: ^AST_Node,
	row: DB_Row,
) -> (
	result: Eval_Term_Result,
	ok: bool,
) {
	context.allocator = db.allocator

	if ident, is_ident := term_node.value.(^AST_Ident); is_ident {
		full_name := ident_tstring(ident)

		if full_name in row {
			return row[full_name], true
		} else {
			log.errorf("Unknown column '%s'", full_name)
			return nil, false
		}
	} else if text, is_text := term_node.value.(^AST_String); is_text {
		cell: DB_Value = text.text
		return cell, true
	} else if num, is_int := term_node.value.(^AST_Int); is_int {
		cell: DB_Value = num.int
		return cell, true
	} else if num, is_f64 := term_node.value.(^AST_Float); is_f64 {
		cell: DB_Value = num.float
		return cell, true
	} else if cond, is_cond := term_node.value.(^Condition); is_cond {
		result := evaluate_expression(db, term_node, row) or_return
		return nil, true // TODO: ?
	} else if unary, is_unary := term_node.value.(^Unary_Expression); is_unary {
		result := evaluate_expression(db, term_node, row) or_return
		return nil, true // TODO: ?
	} else if select_stmt, is_select := term_node.value.(^Select); is_select {
		subquery_result := exec_select(db, select_stmt) or_return
		return subquery_result, true
	} else if node_list, is_list := term_node.value.([dynamic]^AST_Node); is_list {
		return node_list, true
	} else if term_node.value == nil {
		return DB_Value(Nil{}), true
	} else if b, b_ok := term_node.value.(bool); b_ok {
		return DB_Value(b), true
	}

	log.errorf(
		"Unsupported term type: %v at %d:%d",
		term_node.value,
		term_node.token.line,
		term_node.token.column,
	)
	return nil, false
}

Exec_Result :: union {
	[dynamic]DB_Row,
	int,
}

exec_node :: proc(db: ^DB, node: ^AST_Node) -> (result: Exec_Result, ok: bool) {
	context.allocator = db.allocator

	#partial switch v in node.value {
	case ^Select:
		return exec_select(db, v)
	case ^Insert:
		return exec_insert(db, v)
	case ^Update:
		return exec_update(db, v)
	case ^Delete:
		return exec_delete(db, v)
	case ^Create_Table:
		ok = exec_create_table(db, v)
		return
	case:
		log.errorf("Unsupported node type: %T", v)
		return {}, false
	}
}

exec_query :: proc(db: ^DB, query: string) -> (result: Exec_Result, ok: bool) {
	context.allocator = db.allocator

	tokens := tokenize(query) or_return

	parser := parser_init(tokens[:]) // TODO: this memory actually escpaes to 'result'!
	node := parse_query(&parser) or_return

	result, ok = exec_node(db, node)
	// free_all(context.temp_allocator)
	return
}
