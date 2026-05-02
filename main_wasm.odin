#+build js
package main

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:strings"

SQL_SCRATCH_CAP :: 128 * 1024

wasm_ready := false

sql_scratch: [SQL_SCRATCH_CAP]u8
last_json: string
last_diagnostics_json: string
// Current database shape for the browser sidebar (tables, columns, indexes).
last_schema_json: string
wasm_context: runtime.Context

SQL_Statement :: struct {
	text:       string,
	start_line: int,
}

SQL_Diagnostic :: struct {
	line:       int,
	column:     int,
	end_line:   int,
	end_column: int,
	message:    string,
	source:     string,
	severity:   string,
}

// Keep this initialization separate from `main` so JS can call exports
// without depending on browser-side ordering details.
main :: proc() {
	// context = my_context
	main_init()

	wasm_context = context
	if wasm_ready {
		return
	}
	init_sample_db()
	wasm_ready = true
	msgs_clear()
	fmt.sbprintf(&msgs_builder, "WASM SQL engine ready")
	last_json = ""
	last_diagnostics_json = "[]"
	// Initial sample DB is ready before the first Run click.
	last_schema_json = serialize_schema_json()
}

db_value_to_json_value :: proc(value: ^Database_Value) -> json.Value {
	switch &v in value {
	case Database_String:
		return json.String(database_string_unwrap(v))
	case int:
		return json.Integer(i64(v))
	case f64:
		return json.Float(v)
	case bool:
		return json.Boolean(v)
	case nil:
		return json.Null(rawptr(nil))
	}

	return json.Null(rawptr(nil))
}

leading_line_offset :: proc(segment: string) -> int {
	offset := 0
	for ch in segment {
		if ch == ' ' || ch == '\t' || ch == '\r' {
			continue
		}
		if ch == '\n' {
			offset += 1
			continue
		}
		break
	}
	return offset
}

split_sql_statements :: proc(sql: string) -> [dynamic]SQL_Statement {
	statements := make([dynamic]SQL_Statement, context.allocator)

	start := 0
	start_line := 1
	line := 1
	in_single := false
	in_double := false
	escape_next := false

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
			segment := sql[start:i]
			stmt := strings.trim_space(segment)
			if len(stmt) > 0 {
				append(
					&statements,
					SQL_Statement {
						text = stmt,
						start_line = start_line + leading_line_offset(segment),
					},
				)
			}
			start = i + 1
			start_line = line
		}

		if ch == '\n' {
			line += 1
		}
	}

	segment := sql[start:]
	rest := strings.trim_space(segment)
	if len(rest) > 0 {
		append(
			&statements,
			SQL_Statement{text = rest, start_line = start_line + leading_line_offset(segment)},
		)
	}

	return statements
}

strip_ansi_codes :: proc(text: string) -> string {
	if len(text) == 0 {
		return ""
	}

	out: strings.Builder
	for i := 0; i < len(text); i += 1 {
		if text[i] == 0x1b && i + 1 < len(text) && text[i + 1] == '[' {
			i += 2
			for i < len(text) {
				ch := text[i]
				if (ch >= '0' && ch <= '9') || ch == ';' {
					i += 1
					continue
				}
				break
			}
			continue
		}
		strings.write_byte(&out, text[i])
	}

	return strings.to_string(out)
}

parse_positive_int_from :: proc(text: string, start: int) -> (value: int, next: int, ok: bool) {
	if start < 0 || start >= len(text) {
		return 0, start, false
	}
	if text[start] < '0' || text[start] > '9' {
		return 0, start, false
	}

	i := start
	v := 0
	for i < len(text) && text[i] >= '0' && text[i] <= '9' {
		v = v * 10 + int(text[i] - '0')
		i += 1
	}

	return v, i, true
}

parse_line_col_span :: proc(
	text: string,
) -> (
	line: int,
	column: int,
	end_line: int,
	end_column: int,
	ok: bool,
) {
	needle := "at "
	at_idx := strings.index(text, needle)
	if at_idx < 0 {
		return 0, 0, 0, 0, false
	}

	line_value, next, line_ok := parse_positive_int_from(text, at_idx + len(needle))
	if !line_ok {
		return 0, 0, 0, 0, false
	}
	if next >= len(text) || text[next] != ':' {
		return 0, 0, 0, 0, false
	}

	column_value, after_col, column_ok := parse_positive_int_from(text, next + 1)
	if !column_ok {
		return 0, 0, 0, 0, false
	}

	// Backward compatibility for legacy "at line:column" messages.
	if after_col >= len(text) || text[after_col] != '-' {
		return line_value, column_value, line_value, column_value + 1, true
	}

	range_end_line, range_next, range_line_ok := parse_positive_int_from(text, after_col + 1)
	if !range_line_ok {
		return line_value, column_value, line_value, column_value + 1, true
	}
	if range_next >= len(text) || text[range_next] != ':' {
		return line_value, column_value, line_value, column_value + 1, true
	}
	range_end_col, _, range_col_ok := parse_positive_int_from(text, range_next + 1)
	if !range_col_ok {
		return line_value, column_value, line_value, column_value + 1, true
	}

	return line_value, column_value, range_end_line, range_end_col, true
}

line_source :: proc(line: string) -> string {
	trimmed := strings.trim_space(line)
	if len(trimmed) < 3 || trimmed[0] != '[' {
		return "unknown"
	}

	end := strings.index(trimmed, "]")
	if end <= 1 {
		return "unknown"
	}

	return strings.to_lower(trimmed[1:end])
}

append_diagnostics_from_output :: proc(
	diags: ^[dynamic]SQL_Diagnostic,
	raw_output: string,
	statement_start_line: int,
) {
	clean_output := strip_ansi_codes(raw_output)
	if len(clean_output) == 0 {
		return
	}

	line_start := 0
	for i := 0; i <= len(clean_output); i += 1 {
		if i < len(clean_output) && clean_output[i] != '\n' {
			continue
		}
		line := clean_output[line_start:i]
		line_start = i + 1

		local_line, local_col, local_end_line, local_end_col, ok := parse_line_col_span(line)
		if !ok {
			continue
		}

		absolute_line := statement_start_line + local_line - 1
		if absolute_line < 1 {
			absolute_line = 1
		}
		if local_col < 1 {
			local_col = 1
		}
		if local_end_line < local_line {
			local_end_line = local_line
		}
		absolute_end_line := statement_start_line + local_end_line - 1
		if absolute_end_line < absolute_line {
			absolute_end_line = absolute_line
		}
		if local_end_col <= 0 {
			local_end_col = local_col + 1
		}
		if absolute_end_line == absolute_line && local_end_col <= local_col {
			local_end_col = local_col + 1
		}

		append(
			diags,
			SQL_Diagnostic {
				line = absolute_line,
				column = local_col,
				end_line = absolute_end_line,
				end_column = local_end_col,
				message = strings.trim_space(line),
				source = line_source(line),
				severity = "error",
			},
		)
	}
}

serialize_diagnostics_json :: proc(diags: [dynamic]SQL_Diagnostic) -> string {
	encoded, err := json.marshal(
		diags,
		allocator = context.allocator,
		opt = {sort_maps_by_key = true},
	)
	if err != nil {
		fmt.sbprintf(&msgs_builder, "Failed to encode diagnostics as JSON")
		return "[]"
	}

	return string(encoded)
}

serialize_rows_json :: proc(rows: Rows_With_Names) -> string {
	Rows_JSON :: struct {
		columns: [dynamic]string,
		rows:    [dynamic][dynamic]json.Value,
	}

	columns := make([dynamic]string, context.allocator)
	for col in rows.column_names {
		append(&columns, col)
	}

	json_rows := make([dynamic][dynamic]json.Value, context.allocator)
	for &row in rows.rows {
		json_row := make([dynamic]json.Value, context.allocator)
		for &cell in row {
			append(&json_row, db_value_to_json_value(&cell))
		}
		append(&json_rows, json_row)
	}

	payload := Rows_JSON {
		columns = columns,
		rows    = json_rows,
	}

	encoded, err := json.marshal(
		payload,
		allocator = context.allocator,
		opt = {sort_maps_by_key = true},
	)
	if err != nil {
		// Keep API output deterministic even when serialization fails.
		return "{\"columns\":[],\"rows\":[]}"
	}

	return string(encoded)

	// if len(rows) == 0 {
	// 	return "{\"columns\":[],\"rows\":[]}"
	// }

	// columns := make([dynamic]string, allocator = wasm_db.allocator)
	// for key in rows[0] {
	// 	append(&columns, key)
	// }
	// slice.sort_by(columns[:], proc(a, b: string) -> bool {
	// 	return a < b
	// })

	// json_rows := make([dynamic][dynamic]json.Value, allocator = wasm_db.allocator)
	// for row in rows {
	// 	json_row := make([dynamic]json.Value, allocator = wasm_db.allocator)
	// 	for col in columns {
	// 		value, ok := row[col]
	// 		if !ok {
	// 			append(&json_row, json.Null(rawptr(nil)))
	// 			continue
	// 		}
	// 		append(&json_row, db_value_to_json_value(value))
	// 	}
	// 	append(&json_rows, json_row)
	// }

	// Rows_JSON :: struct {
	// 	columns: [dynamic]string,
	// 	rows:    [dynamic][dynamic]json.Value,
	// }

	// payload := Rows_JSON {
	// 	columns = columns,
	// 	rows    = json_rows,
	// }

	// encoded, err := json.marshal(payload, allocator = wasm_db.allocator)
	// if err != nil {
	// 	// Keep API output deterministic even when serialization fails.
	// 	return "{\"columns\":[],\"rows\":[]}"
	// }

	// return string(encoded)
}

// Builds JSON describing every live table: column names, declared types, NOT NULL, PK flag,
// and all indexes (primary + secondary) for the playground schema browser.
serialize_schema_json :: proc() -> string {
	Schema_Column_JSON :: struct {
		name:          string `json:"name"`,
		declared_type: string `json:"type"`,
		not_null:      bool `json:"not_null"`,
		primary_key:   bool `json:"primary_key"`,
	}
	Schema_Index_JSON :: struct {
		name:       string `json:"name"`,
		column:     string `json:"column"`,
		is_primary: bool `json:"primary"`,
		is_unique:  bool `json:"unique"`,
	}
	Schema_Table_JSON :: struct {
		name:    string `json:"name"`,
		columns: [dynamic]Schema_Column_JSON `json:"columns"`,
		indexes: [dynamic]Schema_Index_JSON `json:"indexes"`,
	}
	Schema_Root_JSON :: struct {
		tables: [dynamic]Schema_Table_JSON `json:"tables"`,
	}

	root := Schema_Root_JSON {
		tables = make([dynamic]Schema_Table_JSON, 0, 8, context.allocator),
	}

	for table in database_tables_items() {
		tab := Schema_Table_JSON {
			name    = table.name,
			columns = make(
				[dynamic]Schema_Column_JSON,
				0,
				len(table.column_names),
				context.allocator,
			),
			indexes = make([dynamic]Schema_Index_JSON, 0, len(table.indexes), context.allocator),
		}

		for col_name, col_i in table.column_names {
			type_str := "UNSPECIFIED"
			if col_i < len(table.column_types) {
				if ct, ok := table.column_types[col_i].?; ok {
					type_str = database_column_type_as_string(ct)
				}
			}
			nn := false
			if col_i < len(table.column_not_null) {
				nn = table.column_not_null[col_i]
			}
			append(
				&tab.columns,
				Schema_Column_JSON {
					name = col_name,
					declared_type = type_str,
					not_null = nn,
					primary_key = col_i == table.primary_key_column_index,
				},
			)
		}

		for &idx in table.indexes {
			col_idx := idx.column_index
			col_nm := ""
			if col_idx >= 0 && col_idx < len(table.column_names) {
				col_nm = table.column_names[col_idx]
			}
			append(
				&tab.indexes,
				Schema_Index_JSON {
					name = idx.name,
					column = col_nm,
					is_primary = idx.is_primary,
					is_unique = ensure_index_tree_is_unique(&idx.tree),
				},
			)
		}

		append(&root.tables, tab)
	}

	encoded, err := json.marshal(
		root,
		allocator = context.allocator,
		opt = {sort_maps_by_key = true},
	)
	for &t in root.tables {
		delete(t.columns)
		delete(t.indexes)
	}
	delete(root.tables)

	if err != nil {
		return "{\"tables\":[]}"
	}
	return string(encoded)
}

@(export)
sql_scratch_base :: proc() -> int {
	context = wasm_context

	// TODO: this should be called by the wasm module automatically, maybe.
	// Otherwise, make main an export proc (and maybe rename)
	// TODO: if we rename this, odin complains there is no entrypoint procedure.
	// I need to chekc if WASM actually runs main and if so, dont call it again here.
	main()
	return int(uintptr(&sql_scratch[0]))
}

@(export)
sql_scratch_cap :: proc() -> int {
	context = wasm_context

	return SQL_SCRATCH_CAP
}

@(export)
sql_last_out_ptr :: proc() -> int {
	context = wasm_context

	last_out := strings.to_string(msgs_builder)
	if len(last_out) == 0 {
		return 0
	}
	return int(uintptr(raw_data(last_out)))
}

@(export)
sql_last_out_len :: proc() -> int {
	context = wasm_context

	last_out := strings.to_string(msgs_builder)
	return len(last_out)
}

@(export)
sql_last_json_ptr :: proc() -> int {
	context = wasm_context

	if len(last_json) == 0 {
		return 0
	}
	return int(uintptr(raw_data(last_json)))
}

@(export)
sql_last_json_len :: proc() -> int {
	context = wasm_context

	return len(last_json)
}

@(export)
sql_last_diagnostics_ptr :: proc() -> int {
	context = wasm_context

	if len(last_diagnostics_json) == 0 {
		return 0
	}
	return int(uintptr(raw_data(last_diagnostics_json)))
}

@(export)
sql_last_diagnostics_len :: proc() -> int {
	context = wasm_context

	return len(last_diagnostics_json)
}

@(export)
sql_last_schema_ptr :: proc() -> int {
	context = wasm_context

	if len(last_schema_json) == 0 {
		return 0
	}
	return int(uintptr(raw_data(last_schema_json)))
}

@(export)
sql_last_schema_len :: proc() -> int {
	context = wasm_context

	return len(last_schema_json)
}

// Restores the playground DB to the same tables/rows as a cold load (sample seed data).
// Clears any open transaction state so BEGIN/COMMIT leftovers cannot leak across resets.
@(export)
sql_reset_db :: proc() {
	context = wasm_context

	delete_all_tables()
	init_sample_db()
	last_schema_json = serialize_schema_json()
	last_json = ""
	last_diagnostics_json = "[]"
	msgs_clear()
	fmt.sbprintf(&msgs_builder, "Database reset to initial sample data.")
}

@(export)
sql_run :: proc(source_len: int) -> int {
	context = wasm_context

	// TODO: why do we need this? either document or remove.
	// (probably to reset the database state, which is undesirable since we WANT to persist the state and even show it in the UI.)
	main()

	defer {
		// Keep sidebar in sync after any batch, including partial progress before an error.
		last_schema_json = serialize_schema_json()
	}

	msgs_clear()
	last_json = ""
	last_diagnostics_json = "[]"

	if source_len <= 0 || source_len > SQL_SCRATCH_CAP {
		fmt.sbprintf(
			&msgs_builder,
			"Invalid source length: %v (cap: %v)",
			source_len,
			SQL_SCRATCH_CAP,
		)
		return 1
	}

	source := strings.trim_space(string(sql_scratch[:source_len]))
	if len(source) == 0 {
		fmt.sbprintf(&msgs_builder, "No SQL provided")
		return 1
	}

	statements := split_sql_statements(source)
	if len(statements) == 0 {
		fmt.sbprintf(&msgs_builder, "No SQL statements found")
		last_diagnostics_json = "[{\"line\":1,\"column\":1,\"end_line\":1,\"end_column\":2,\"message\":\"No SQL statements found\",\"source\":\"database\",\"severity\":\"error\"}]"
		return 1
	}

	out: strings.Builder

	had_select := false

	for statement, i in statements {
		result, ok := exec(statement.text, clear_msgs = false)
		if !ok {
			diags := make([dynamic]SQL_Diagnostic, context.allocator)
			append_diagnostics_from_output(
				&diags,
				strings.to_string(msgs_builder),
				statement.start_line,
			)
			if len(diags) == 0 {
				fallback_msg := strings.trim_space(
					strip_ansi_codes(strings.to_string(msgs_builder)),
				)
				if len(fallback_msg) == 0 {
					fallback_msg = "SQL execution failed"
				}
				append(
					&diags,
					SQL_Diagnostic {
						line = 1,
						column = 1,
						end_line = 1,
						end_column = 2,
						message = fallback_msg,
						source = "database",
						severity = "error",
					},
				)
			}
			last_diagnostics_json = serialize_diagnostics_json(diags)

			if out_str := strings.trim_right(strings.to_string(out), "\n"); len(out_str) > 0 {
				if len(strings.to_string(msgs_builder)) > 0 {
					fmt.sbprintln(&msgs_builder)
				}
				fmt.sbprintf(&msgs_builder, "%v", out_str)
			}
			last_json = ""
			return 1
		}

		switch r in result.result {
		case int:
			fmt.sbprintf(&out, "Statement %v OK (rows affected: %v)\n", i + 1, r)
		case nil:
			fmt.sbprintf(&out, "Statement %v OK\n", i + 1)
		case Rows_With_Names:
			fmt.sbprintf(&out, "Statement %v OK (rows returned: %v)\n", i + 1, len(r.rows))
			if len(result.execution_tree) > 0 {
				fmt.sbprintf(&out, "%v\n", result.execution_tree)
			}
			last_json = serialize_rows_json(r)
			had_select = true
		}
	}

	if !had_select {
		last_json = ""
	}

	msgs_clear()
	strings.write_string(&msgs_builder, strings.trim_right(strings.to_string(out), "\n"))
	return 0
}
