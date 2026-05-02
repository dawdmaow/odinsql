#+vet explicit-allocators

package main

import "core:fmt"
import "core:log"
import "core:math"
import "core:mem"
import "core:slice"
import "core:sort"
import "core:strings"

// TODO: 24 is probably way too small - try to make it 64-bit in total (including length) (L1 cache size).
TINY_STRING_MAX_SIZE :: 24
// TODO: store len explicitly so it's u8 and not int
Tiny_String :: [dynamic; TINY_STRING_MAX_SIZE]u8 // this has to be distinct and cooperating with fmt.
Database_String :: union {
	Tiny_String, // Small strings are stored inline to avoid pointer chasing.
	string,
}

// Stores short strings inline and leaves longer strings as regular string values.
// (We assume `s` is a string that is not static and allocated with the same allocator as all other database/table data.)
database_string_make :: proc(s: string) -> Database_String {
	switch {
	case len(s) <= TINY_STRING_MAX_SIZE:
		result: Tiny_String
		resize(&result, len(s))
		copy(result[:len(s)], s)
		return result
	case:
		return string(s)
	}
}

// Returns the plain string view for either Database_String storage variant.
database_string_unwrap :: proc(s: Database_String) -> string {
	switch &s in s {
	case Tiny_String:
		return string(s[:])
	case string:
		return s
	case:
		unreachable()
	}
}

Rows_With_Names :: struct {
	column_names: []string,
	rows:         [dynamic]Table_Row,
	// FIXME: slice of table name for each column name (in order to have information on where the column actually comes from, even if column id is unqualified)
}

// TODO: database values should contain an optional token/string field for error reporting - maybe?
// term_node: ^AST_Node sorely needed...
Database_Value :: union {
	Database_String,
	int,
	f64,
	bool,
}

Database_Column_Type :: enum {
	Unspecified,
	Integer,
	Float,
	Boolean,
	Text,
}

// Formats a declared column type as the SQL-ish name used in messages.
database_column_type_as_string :: proc(t: Database_Column_Type) -> string {
	switch t {
	case .Unspecified:
		return "UNSPECIFIED"
	case .Integer:
		return "INTEGER"
	case .Float:
		return "FLOAT"
	case .Boolean:
		return "BOOLEAN"
	case .Text:
		return "TEXT"
	case:
		unreachable()
	}
}

// Parses a column type declaration from CREATE/ALTER TABLE syntax.
database_column_type_from_decl :: proc(text: string) -> Database_Column_Type {
	switch strings.to_upper(text, database_query_allocator) {
	case "INT", "INTEGER":
		return .Integer
	case "FLOAT", "DOUBLE", "REAL":
		return .Float
	case "BOOL", "BOOLEAN":
		return .Boolean
	case "TEXT", "STRING":
		return .Text
	case:
		unreachable()
	}
}

Table_Row :: [dynamic]Database_Value

TABLE_MAX_COLUMNS :: 255
MAX_TABLES :: 255

Row_Index :: distinct int

// Columnar tables split each column into fixed-capacity chunks so operators can work
// on cache-friendly slices instead of one monolithic allocation.
COLUMN_CHUNK_SIZE :: 1024

// TODO: consider making chunk size parametric (using `where`) based on size of $T (so the actual size is rougly similiar even if different types have very different sizes).
Column_Chunk :: struct($T: typeid) {
	values:     [dynamic; COLUMN_CHUNK_SIZE]T,
	valid_bits: [dynamic; COLUMN_CHUNK_SIZE / 64]u64,
}

// TODO: don't include [dynamic] in the union, this makes generic code more convoluted.
// TODO: [dynamic] should be outside of the union, so we can iterate without knowing the actual type.
// Nullability is tracked separately from values so expression paths can stay branch-light.
Column_Chunks :: union {
	[dynamic]Column_Chunk(int),
	[dynamic]Column_Chunk(f64),
	[dynamic]Column_Chunk(bool),
	[dynamic]Column_Chunk(Database_String),
}

// Table_Storage_Columns :: [dynamic]Table_Storage_Column_Chunk
// Table_Storage_Rows :: [dynamic]Table_Row
Table_Storage :: union {
	[dynamic]Column_Chunks,
	[dynamic]Table_Row,
}

// Computes how many u64 words are needed to store row validity bits.
column_chunk_validity_word_count_needed :: proc(row_count: int) -> int {
	if row_count <= 0 do return 0
	return (row_count + 63) / 64
}

// Reads the NULL/non-NULL validity bit for one row inside a column chunk.
column_chunk_validity_get :: proc(bits: []u64, row_in_chunk: int) -> bool {
	if row_in_chunk < 0 do return false
	wi := row_in_chunk / 64
	bi := row_in_chunk % 64
	if wi < 0 || wi >= len(bits) do return false
	return ((bits[wi] >> uint(bi)) & 1) != 0
}

// Writes a validity bit after the caller has already proven the row is in-bounds.
column_chunk_validity_set_inbounds :: proc(
	bits: ^[dynamic; COLUMN_CHUNK_SIZE / 64]u64,
	row_in_chunk: int,
	valid: bool,
) {
	wi := row_in_chunk / 64
	bi := row_in_chunk % 64
	if valid {
		bits^[wi] |= u64(1) << uint(bi)
	} else {
		bits^[wi] &~= u64(1) << uint(bi)
	}
}

// Resizes a chunk validity bitmap to match the current number of stored rows.
column_chunk_validity_resize_for_row_count :: proc(
	bits: ^[dynamic; COLUMN_CHUNK_SIZE / 64]u64,
	row_count: int,
) {
	need := column_chunk_validity_word_count_needed(row_count)
	if len(bits^) < need {
		prev := len(bits^)
		resize(bits, need)
		for i in prev ..< need do bits^[i] = 0
	} else if len(bits^) > need {
		resize(bits, need)
	}
}

// Counts all rows in a columnar table by walking the first storage column.
table_columnar_total_rows_first_col :: proc(first_col: Column_Chunks) -> int {
	impl :: proc(chunks: [dynamic]Column_Chunk($T)) -> int {
		n := 0
		for ch in chunks do n += len(ch.values)
		return n
	}
	#partial switch chunks in first_col {
	case [dynamic]Column_Chunk(int):
		return impl(chunks)
	case [dynamic]Column_Chunk(f64):
		return impl(chunks)
	case [dynamic]Column_Chunk(bool):
		return impl(chunks)
	case [dynamic]Column_Chunk(Database_String):
		return impl(chunks)
	}
	log.errorf("Unknown column chunk type: %T", first_col)
	return 0
}

// Maps a flat row index to the chunk index and offset inside columnar storage.
table_columnar_flat_to_loc :: proc(
	first_col: Column_Chunks,
	row_index: Row_Index,
) -> (
	chunk_i: int,
	offset: int,
	ok: bool,
) {
	if row_index < 0 do return

	impl :: proc(
		chunks: ^[dynamic]Column_Chunk($T),
		row_index: Row_Index,
	) -> (
		chunk_i: int,
		offset: int,
		ok: bool,
	) {
		running := 0
		for ch, ci in chunks {
			ch_rows := len(ch.values)
			if int(row_index) < running + ch_rows {
				return ci, int(row_index) - running, true
			}
			running += ch_rows
		}
		return
	}

	switch &chunks in first_col {
	case [dynamic]Column_Chunk(int):
		return impl(&chunks, row_index)
	case [dynamic]Column_Chunk(f64):
		return impl(&chunks, row_index)
	case [dynamic]Column_Chunk(bool):
		return impl(&chunks, row_index)
	case [dynamic]Column_Chunk(Database_String):
		return impl(&chunks, row_index)
	case:
		unreachable()
	}
}

// Verifies that every column chunk has legal chunk lengths and aligned validity bits.
table_columnar_validate_columns :: proc(cols: [dynamic]Column_Chunks) -> bool {
	if len(cols) == 0 do return true

	target_rows := table_columnar_total_rows_first_col(cols[0])

	// Checks the chunk-local invariants for one concrete typed column.
	validate_column :: proc(chunks: [dynamic]Column_Chunk($T)) -> bool {
		for ch, ch_i in chunks {
			if len(ch.values) > COLUMN_CHUNK_SIZE {
				msgf(
					.Error,
					.Database,
					"Corrupted %T chunk %v: len %v > %v",
					typeid_of(T),
					ch_i,
					len(ch.values),
					COLUMN_CHUNK_SIZE,
				)
				return false
			}
			if ch_i < len(chunks) - 1 && len(ch.values) != COLUMN_CHUNK_SIZE {
				msgf(
					.Error,
					.Database,
					"Corrupted %T chunk %v: non-final chunk must be full",
					typeid_of(T),
					ch_i,
				)
				return false
			}
			if len(ch.valid_bits) != column_chunk_validity_word_count_needed(len(ch.values)) {
				msgf(
					.Error,
					.Database,
					"Corrupted %T chunk %v: validity bitmap size mismatch",
					typeid_of(T),
					ch_i,
				)
				return false
			}
		}
		return true
	}

	for col, col_i in cols {
		rows := table_columnar_total_rows_first_col(col)
		ensure(rows == target_rows)
		// if table_columnar_total_rows_first_col(col) != target_rows {
		// 	msgf(.Database, "Corrupted column storage: row count mismatch in column %v", col_i)
		// 	return false
		// }
		switch chunks in col {
		case [dynamic]Column_Chunk(int):
			validate_column(chunks)
		case [dynamic]Column_Chunk(f64):
			validate_column(chunks)
		case [dynamic]Column_Chunk(bool):
			validate_column(chunks)
		case [dynamic]Column_Chunk(Database_String):
			validate_column(chunks)
		}
	}
	return true
}

Table :: struct {
	needs_to_dealloc_strings: bool, // this is a bodge, ALL table name and column anme strings should be copied, and always adellaocated on removal (or use static strings!)
	name:                     string,
	column_names:             [dynamic]string,
	column_types:             [dynamic]Maybe(Database_Column_Type),
	column_not_null:          [dynamic]bool,
	primary_key_column_index: int,
	storage:                  Table_Storage,
	indexes:                  [dynamic]Table_Index,
}

Table_Index :: struct {
	name:         string,
	column_index: int,
	is_primary:   bool,
	tree:         Index_Tree,
}

// The mandatory PK index; is_primary distinguishes it from user CREATE INDEX entries.
// Finds the primary index entry and its position in the table index list.
table_primary_index :: proc(table: ^Table) -> (index: ^Table_Index, pos: int) {
	for &entry, pos in table.indexes {
		entry.is_primary or_continue
		return &entry, pos
	}
	panic("Primary index not found")
}

// Returns the unique tree backing the table primary key, or nil if it is missing.
table_primary_unique_tree_ptr :: proc(table: ^Table) -> (result: ^Index_Tree) {
	defer assert(result != nil)

	idx, _ := table_primary_index(table)

	_, ok := idx.tree.(Index_Tree_Unique)
	ensure(ok)

	return &idx.tree
}

@(thread_local)
database_query_allocator: mem.Allocator
@(thread_local)
database_tables: [MAX_TABLES]Table
@(thread_local)
database_tables_count: int
@(thread_local)
txn_active: bool
@(thread_local)
txn_tables: [MAX_TABLES]Table
@(thread_local)
txn_tables_count: int

// Selects the live table set, switching to the transaction copy while a txn is active.
database_active_tables_and_count_ptr :: proc() -> (^[MAX_TABLES]Table, ^int) {
	if txn_active {
		return &txn_tables, &txn_tables_count
	}
	return &database_tables, &database_tables_count
}

// Destroys all tables in the currently active database view.
database_tables_clear :: proc() {
	tables, count := database_active_tables_and_count_ptr()
	table_set_destroy_all(tables, count)
}

// Returns a slice over the tables visible to the current transaction state.
database_tables_items :: proc() -> []Table {
	tables, count := database_active_tables_and_count_ptr()
	return tables^[0:count^]
}

// Appends a table to the active table set if the fixed table capacity allows it.
@(require_results)
database_tables_append :: proc(table: Table) -> bool {
	tables, count := database_active_tables_and_count_ptr()
	if count^ >= MAX_TABLES {
		msgf(.Error, .Database, "Maximum number of tables reached (%v)", MAX_TABLES)
		return false
	}
	tables^[count^] = table
	count^ += 1
	return true
}

// Emits a database message with the source token's single-line span attached.
// TODO: add an error bool field and a conditional intrinsics.debug_trap call inside if the error bool is true.
// TODO: also log.error (or use an enum with error kind as part of it) (actually do it in msgf directly)
db_msgf_at :: proc(kind: Msg_Kind, token: Token, format: string, args: ..any) {
	start_col := int(token.column)
	end_col := start_col + len(token.text)
	if end_col <= start_col do end_col = start_col + 1
	msgf(
		kind,
		.Database,
		"%v at %v:%v-%v:%v",
		fmt.tprintf(format, ..args),
		token.line,
		start_col,
		token.line,
		end_col,
	)
}

// // We don't support multiple types in the same column, but this might be useful later.
// // Gives Database_Value variants a stable ordering rank for mixed-type comparisons.
// database_value_type_rank :: proc(v: Database_Value) -> int {
// 	switch _ in v {
// 	case nil:
// 		return 0
// 	case Database_String:
// 		return 1
// 	case int:
// 		return 2
// 	case f64:
// 		return 3
// 	case bool:
// 		return 4
// 	case:
// 		unreachable()
// 	}
// }

string_lexographic_ordering :: proc(a, b: Database_String) -> slice.Ordering {
	a := database_string_unwrap(a)
	b := database_string_unwrap(b)

	for i in 0 ..< min(len(a), len(b)) {
		if a[i] < b[i] do return .Less
		if a[i] > b[i] do return .Greater
	}

	// Shared prefix = shorter string sorts first.
	if len(a) < len(b) do return .Less
	if len(a) > len(b) do return .Greater
	return .Equal
}

// int_comparison :: proc(a, b: int) -> slice.Ordering {
// 	return slice.cmp(a, b)
// }

// cmp_f64 :: proc(a, b: f64) -> slice.Ordering {
// 	return slice.cmp(a, b)
// }

// cmp_bool :: proc(a, b: bool) -> slice.Ordering {
// 	return slice.cmp(a, b)
// }

// cmp_value :: proc(
// 	value_a, value_b: Database_Value,
// 	op_token: Token,
// ) -> (
// 	result: slice.Ordering,
// 	result_ok: bool,
// ) {
// 	// SQL predicate comparisons with NULL evaluate to unknown; in WHERE that behaves
// 	// like false without raising an execution error.
// 	// TODO: Add a "Unknown" case to the union Database_Value and use it here.
// 	// TODO: or use Maybe for ordering?
// 	if value_a == nil || value_b == nil do return .Not_, true

// 	switch a in value_a {
// 	case Database_String:
// 		#partial switch b in value_b {
// 		case Database_String:
// 			return string_lexographic_comparison(a, b), true
// 		case:
// 			db_msgf_at(.Error, token, "Expected a string, got %T", value_b)
// 			return
// 		}
// 	case int:
// 		#partial switch b in value_b {
// 		case int:
// 			return cmp_int(a, b), true
// 		case f64:
// 			return cmp_f64(f64(a), b), true
// 		case:
// 			db_msgf_at(.Error, token, "Expected a number, got %T", value_b)
// 			return
// 		}
// 	case f64:
// 		#partial switch b in value_b {
// 		case f64:
// 			return cmp_f64(a, b), true
// 		case int:
// 			return cmp_f64(a, f64(b)), true
// 		case:
// 			db_msgf_at(.Error, token, "Expected a float, got %T", value_b)
// 			return
// 		}
// 	case bool:
// 		#partial switch b in value_b {
// 		case bool:
// 			return cmp_bool(a, b), true
// 		case:
// 			db_msgf_at(.Error, token, "Expected a boolean, got %T", value_b)
// 			return
// 		}
// 	case:
// 		unreachable()
// 	}
// }

// TODO: separte value_equal for when we don't care about SQL semantics?

value_equal_including_conversion :: proc(
	a, b: Database_Value,
	b_token: Token,
) -> (
	equal: bool,
	ok: bool,
) {
	ordering := value_ordering_evaluate(a, b, b_token) or_return
	return ordering == .Equal, true
}

// This proc does NOT assume both values to be of the same type.
value_ordering_evaluate :: proc(
	a, b: Database_Value,
	// show_errors: bool,
	b_token: Token,
) -> (
	ordering: slice.Ordering,
	ok: bool,
) {
	// NULLs can't be compared, even with other nulls.
	// TODO: return .Unknown here?
	// if a == nil || b == nil do return nil
	(a != nil && b != nil) or_return

	switch a_value in a {
	case Database_String:
		#partial switch b_value in b {
		case Database_String:
			return string_lexographic_ordering(a_value, b_value), true
		case:
			db_msgf_at(.Error, b_token, "Expected a string, got %T", b)
			return
		}
	case int:
		#partial switch b_value in b {
		case int:
			return slice.cmp(a_value, b_value), true
		case f64:
			return slice.cmp(f64(a_value), b_value), true
		case:
			db_msgf_at(.Error, b_token, "Expected a number, got %T", b)
			return
		}
	case f64:
		#partial switch b_value in b {
		case f64:
			return slice.cmp(a_value, b_value), true
		case int:
			return slice.cmp(a_value, f64(b_value)), true
		case:
			db_msgf_at(.Error, b_token, "Expected a number, got %T", b)
			return
		}
	case bool:
		#partial switch b_value in b {
		case bool:
			return slice.cmp(cast(int)a_value, cast(int)b_value), true
		case int:
			return slice.cmp(cast(int)a_value, b_value), true
		case:
			db_msgf_at(.Error, b_token, "Expected a boolean or an integer, got %T", b)
			return
		}
	case:
		unreachable()
	}
}

// Compares two database values with the ordering used by primary and secondary indexes.
value_ordering_for_column_sorting :: proc(a, b: Database_Value) -> slice.Ordering {
	if a == nil && b == nil do return .Equal

	// Sorting needs to be deterministic, so we don't return .Equal here.
	if a == nil do return .Less
	if b == nil do return .Greater

	// // Mixed runtime types are ordered by stable type rank.
	// // TODO: probably unused, consider removing ranks
	// a_rank := database_value_type_rank(a)
	// b_rank := database_value_type_rank(b)
	// if a_rank != b_rank do return slice.cmp(a_rank, b_rank)

	// We assume all values in a column to be of the same type.
	switch a_value in a {
	case Database_String:
		b_value := b.(Database_String)
		return string_lexographic_ordering(a_value, b_value)
	case int:
		b_value := b.(int)
		return slice.cmp(a_value, b_value)
	case f64:
		b_value := b.(f64)
		return slice.cmp(a_value, b_value)
	case bool:
		b_value := b.(bool)
		return slice.cmp(cast(int)a_value, cast(int)b_value)
	case:
		unreachable()
	}
}

// Returns the logical number of rows regardless of row or columnar storage.
table_row_count :: proc(table: ^Table) -> int {
	table_storage_ensure(table)
	switch storage in table.storage {
	case [dynamic]Table_Row:
		rows := storage
		return len(rows)
	case [dynamic]Column_Chunks:
		cols := storage
		if len(cols) == 0 do return 0
		return table_columnar_total_rows_first_col(cols[0])
	case:
		unreachable()
	}
}

// Initializes table metadata, storage, and the mandatory unique primary index.
// TODO: tables should have IDs (automatically assigned) and only be referenced by said IDs (in execution nodes etc.)
table_init :: proc(
	table: ^Table,
	name: string,
	column_names: [dynamic]string, // TODO: this should be dynamic;N or slice
	primary_key_column_index: int,
	column_types: [dynamic]Maybe(Database_Column_Type) = nil, // TODO: this should be dynamic;N or slice
	column_not_null: [dynamic]bool = nil, // TODO: this should be dynamic;N or slice
) {
	inferred_column_types := column_types
	if len(inferred_column_types) != len(column_names) {
		inferred_column_types = make(
			[dynamic]Maybe(Database_Column_Type),
			0,
			len(column_names),
			context.allocator,
		)
		for _ in column_names {
			append(&inferred_column_types, Maybe(Database_Column_Type){})
		}
	}
	inferred_column_not_null := column_not_null
	if len(inferred_column_not_null) != len(column_names) {
		inferred_column_not_null = make([dynamic]bool, 0, len(column_names), context.allocator)
		for _, col_i in column_names {
			append(&inferred_column_not_null, col_i == primary_key_column_index)
		}
	}
	if primary_key_column_index >= 0 && primary_key_column_index < len(inferred_column_not_null) {
		inferred_column_not_null[primary_key_column_index] = true
	}
	table^ = {
		name                     = name,
		column_names             = column_names,
		column_types             = inferred_column_types,
		column_not_null          = inferred_column_not_null,
		primary_key_column_index = primary_key_column_index,
		storage                  = make_dynamic_array_len_cap(
			[dynamic]Table_Row,
			0,
			0,
			context.allocator,
		),
		indexes                  = make([dynamic]Table_Index, context.allocator),
	}
	append(
		&table.indexes,
		Table_Index {
			name         = "",
			column_index = primary_key_column_index,
			is_primary   = true,
			// Union zero literal `{}` does not pick `Index_Tree_Unique`; PK lookups need this variant.
			tree         = Index_Tree_Unique{},
		},
	)
}

// Infers the declared column type that can hold one runtime Database_Value.
database_value_type_for_column :: proc(value: Database_Value) -> (Database_Column_Type, bool) {
	switch value in value {
	case int:
		return .Integer, true
	case f64:
		return .Float, true
	case bool:
		return .Boolean, true
	case Database_String:
		return .Text, true
	case:
		return .Unspecified, false
	}
}

// Converts a runtime value to the declared column type accepted by storage.
database_coerce_value_for_column_type :: proc(
	value: Database_Value,
	column_type: Database_Column_Type,
) -> (
	coerced: Database_Value,
	ok: bool,
) {
	if value == nil do return nil, true

	switch column_type {
	case .Integer:
		if int, ok := value.(int); ok do return int, true

		float := value.(f64) or_return

		(!math.is_nan(float)) or_return
		(math.trunc(float) == float) or_return

		return int(float), true

	case .Float:
		if float, ok := value.(f64); ok do return float, true
		if int, ok := value.(int); ok do return f64(int), true
		return

	case .Boolean:
		return value.(bool)

	case .Text:
		return value.(Database_String)

	case .Unspecified:
		unreachable()

	case:
		unreachable()
	}
}

// Allocates an empty typed column-chunk array for a declared column type.
table_storage_column_make_for_type :: proc(
	column_type: Database_Column_Type,
) -> (
	column: Column_Chunks,
	ok: bool,
) {
	switch column_type {
	case .Integer:
		return make([dynamic]Column_Chunk(int), 0, 4, context.allocator), true
	case .Float:
		return make([dynamic]Column_Chunk(f64), 0, 4, context.allocator), true
	case .Boolean:
		return make([dynamic]Column_Chunk(bool), 0, 4, context.allocator), true
	case .Text:
		return make([dynamic]Column_Chunk(Database_String), 0, 4, context.allocator), true
	case .Unspecified:
		unreachable()
	case:
		unreachable()
	}
}

// Resolves or records the storage type for a column before writing a value.
table_column_type_resolve_for_write :: proc(
	table: ^Table,
	column_index: int,
	// value: Database_Value,
) -> (
	column_type: Database_Column_Type,
	ok: bool,
) {
	ensure(column_index >= 0)
	ensure(column_index < len(table.column_types))

	return table.column_types[column_index].?
	// inferred, infer_ok := database_value_type_for_column(value)
	// if !infer_ok {
	// 	return .Unspecified, false
	// }
	// table.column_types[column_index] = inferred
	// return inferred, true
}

// Ensures a table has initialized storage matching its schema before reads or writes.
// TODO: make sure this proc is actually needed
table_storage_ensure :: proc(table: ^Table) {
	switch storage in table.storage {
	case [dynamic]Table_Row:
		rows := transmute([dynamic]Table_Row)storage
		if cap(rows) == 0 && len(rows) == 0 {
			table.storage = make_dynamic_array_len_cap([dynamic]Table_Row, 0, 0, context.allocator)
		}
	case [dynamic]Column_Chunks:
		cols := storage
		if len(cols) == 0 &&
		   len(table.column_names) > 0 &&
		   len(table.column_types) == len(table.column_names) {
			can_initialize := true
			for ct in table.column_types {
				_, has_type := ct.?
				if !has_type {
					can_initialize = false
					break
				}
			}
			if !can_initialize {
				return
			}
			new_cols := make([dynamic]Column_Chunks, 0, len(table.column_names), context.allocator)
			for ct in table.column_types {
				column_type, _ := ct.?
				new_col, make_ok := table_storage_column_make_for_type(column_type)
				if !make_ok {
					return
				}
				append(&new_cols, new_col)
			}
			table.storage = new_cols
		}
		if len(cols) > 0 && !table_columnar_validate_columns(cols) {
			return
		}
	}
}

// Materializes a row by index from either row storage or typed column chunks.
table_get_row :: proc(table: ^Table, row_index: Row_Index) -> (row: Table_Row, ok: bool) {
	table_storage_ensure(table)
	if row_index < 0 || int(row_index) >= table_row_count(table) {
		return nil, false
	}
	switch storage in table.storage {
	case [dynamic]Table_Row:
		rows := storage
		return rows[row_index], true
	case [dynamic]Column_Chunks:
		cols := storage
		if len(cols) != len(table.column_names) {
			msgf(.Error, .Database, "Corrupted table storage: column count mismatch")
			return nil, false
		}
		if !table_columnar_validate_columns(cols) {
			return nil, false
		}
		chunk_i, off, loc_ok := table_columnar_flat_to_loc(cols[0], row_index)
		if !loc_ok {
			return nil, false
		}
		out := make(Table_Row, len(cols), database_query_allocator)
		for col, col_i in cols {
			switch typed in col {
			case [dynamic]Column_Chunk(int):
				ch := &typed[chunk_i]
				if column_chunk_validity_get(ch.valid_bits[:], off) {
					out[col_i] = ch.values[off]
				}
			case [dynamic]Column_Chunk(f64):
				ch := &typed[chunk_i]
				if column_chunk_validity_get(ch.valid_bits[:], off) {
					out[col_i] = ch.values[off]
				}
			case [dynamic]Column_Chunk(bool):
				ch := &typed[chunk_i]
				if column_chunk_validity_get(ch.valid_bits[:], off) {
					out[col_i] = ch.values[off]
				}
			case [dynamic]Column_Chunk(Database_String):
				ch := &typed[chunk_i]
				if column_chunk_validity_get(ch.valid_bits[:], off) {
					out[col_i] = ch.values[off]
				}
			}
		}
		return out, true
	}
	return nil, false
}

// Writes a single value into a typed column at an existing row index.
table_storage_column_set :: proc(
	column: Column_Chunks,
	column_type: Database_Column_Type,
	row_index: Row_Index,
	value: Database_Value,
) -> (
	updated: Column_Chunks,
	ok: bool,
) {
	coerced, coerce_ok := database_coerce_value_for_column_type(value, column_type)
	if !coerce_ok {
		msgf(
			.Error,
			.Database,
			"Unable to coerce value for column type: %v, into %v",
			value,
			column_type,
		)
		return column, false
	}
	switch typed in column {
	case [dynamic]Column_Chunk(int):
		chunks := typed
		col_u := Column_Chunks(chunks)
		ci, off :=
			table_columnar_flat_to_loc(col_u, row_index) or_else fmt.panicf(
				"Unable to get location for row index: %v",
				row_index,
			)
		if coerced == nil {
			chunks[ci].values[off] = 0
			column_chunk_validity_resize_for_row_count(
				&chunks[ci].valid_bits,
				len(chunks[ci].values),
			)
			column_chunk_validity_set_inbounds(&chunks[ci].valid_bits, off, false)
		} else {
			v, v_ok := coerced.(int)
			if !v_ok {
				return column, false
			}
			chunks[ci].values[off] = v
			column_chunk_validity_resize_for_row_count(
				&chunks[ci].valid_bits,
				len(chunks[ci].values),
			)
			column_chunk_validity_set_inbounds(&chunks[ci].valid_bits, off, true)
		}
		return Column_Chunks(chunks), true
	case [dynamic]Column_Chunk(f64):
		chunks := typed
		col_u := Column_Chunks(chunks)
		ci, off, loc_ok := table_columnar_flat_to_loc(col_u, row_index)
		if !loc_ok {
			return column, false
		}
		if coerced == nil {
			chunks[ci].values[off] = 0
			column_chunk_validity_resize_for_row_count(
				&chunks[ci].valid_bits,
				len(chunks[ci].values),
			)
			column_chunk_validity_set_inbounds(&chunks[ci].valid_bits, off, false)
		} else {
			v, v_ok := coerced.(f64)
			if !v_ok {
				return column, false
			}
			chunks[ci].values[off] = v
			column_chunk_validity_resize_for_row_count(
				&chunks[ci].valid_bits,
				len(chunks[ci].values),
			)
			column_chunk_validity_set_inbounds(&chunks[ci].valid_bits, off, true)
		}
		return Column_Chunks(chunks), true
	case [dynamic]Column_Chunk(bool):
		chunks := typed
		col_u := Column_Chunks(chunks)
		ci, off, loc_ok := table_columnar_flat_to_loc(col_u, row_index)
		if !loc_ok {
			return column, false
		}
		if coerced == nil {
			chunks[ci].values[off] = false
			column_chunk_validity_resize_for_row_count(
				&chunks[ci].valid_bits,
				len(chunks[ci].values),
			)
			column_chunk_validity_set_inbounds(&chunks[ci].valid_bits, off, false)
		} else {
			v, v_ok := coerced.(bool)
			if !v_ok {
				return column, false
			}
			chunks[ci].values[off] = v
			column_chunk_validity_resize_for_row_count(
				&chunks[ci].valid_bits,
				len(chunks[ci].values),
			)
			column_chunk_validity_set_inbounds(&chunks[ci].valid_bits, off, true)
		}
		return Column_Chunks(chunks), true
	case [dynamic]Column_Chunk(Database_String):
		chunks := typed
		col_u := Column_Chunks(chunks)
		ci, off, loc_ok := table_columnar_flat_to_loc(col_u, row_index)
		if !loc_ok {
			return column, false
		}
		// Overwriting text cells does not need delete() for fixed-cap strings.
		if coerced == nil {
			chunks[ci].values[off] = {}
			column_chunk_validity_resize_for_row_count(
				&chunks[ci].valid_bits,
				len(chunks[ci].values),
			)
			column_chunk_validity_set_inbounds(&chunks[ci].valid_bits, off, false)
		} else {
			v, v_ok := coerced.(Database_String)
			if !v_ok {
				return column, false
			}
			chunks[ci].values[off] = v
			column_chunk_validity_resize_for_row_count(
				&chunks[ci].valid_bits,
				len(chunks[ci].values),
			)
			column_chunk_validity_set_inbounds(&chunks[ci].valid_bits, off, true)
		}
		return Column_Chunks(chunks), true
	}
	return column, false
}

// Appends one value to a typed column, allocating a new chunk when the tail fills.
table_storage_column_append :: proc(
	column: Column_Chunks,
	column_type: Database_Column_Type,
	value: Database_Value,
) -> (
	updated: Column_Chunks,
	ok: bool,
) {
	coerced, coerce_ok := database_coerce_value_for_column_type(value, column_type)
	if !coerce_ok {
		return column, false
	}
	switch typed in column {
	case [dynamic]Column_Chunk(int):
		chunks := typed
		need_new := len(chunks) == 0 || len(chunks[len(chunks) - 1].values) >= COLUMN_CHUNK_SIZE
		if need_new {
			append(&chunks, Column_Chunk(int){})
		}
		tail := &chunks[len(chunks) - 1]
		if coerced == nil {
			append(&tail.values, 0)
		} else {
			v, v_ok := coerced.(int)
			if !v_ok {
				return column, false
			}
			append(&tail.values, v)
		}
		idx := len(tail.values) - 1
		column_chunk_validity_resize_for_row_count(&tail.valid_bits, len(tail.values))
		column_chunk_validity_set_inbounds(&tail.valid_bits, idx, coerced != nil)
		return Column_Chunks(chunks), true
	case [dynamic]Column_Chunk(f64):
		chunks := typed
		need_new := len(chunks) == 0 || len(chunks[len(chunks) - 1].values) >= COLUMN_CHUNK_SIZE
		if need_new {
			append(&chunks, Column_Chunk(f64){})
		}
		tail := &chunks[len(chunks) - 1]
		if coerced == nil {
			append(&tail.values, 0)
		} else {
			v, v_ok := coerced.(f64)
			if !v_ok {
				return column, false
			}
			append(&tail.values, v)
		}
		idx := len(tail.values) - 1
		column_chunk_validity_resize_for_row_count(&tail.valid_bits, len(tail.values))
		column_chunk_validity_set_inbounds(&tail.valid_bits, idx, coerced != nil)
		return Column_Chunks(chunks), true
	case [dynamic]Column_Chunk(bool):
		chunks := typed
		need_new := len(chunks) == 0 || len(chunks[len(chunks) - 1].values) >= COLUMN_CHUNK_SIZE
		if need_new {
			append(&chunks, Column_Chunk(bool){})
		}
		tail := &chunks[len(chunks) - 1]
		if coerced == nil {
			append(&tail.values, false)
		} else {
			v, v_ok := coerced.(bool)
			if !v_ok {
				return column, false
			}
			append(&tail.values, v)
		}
		idx := len(tail.values) - 1
		column_chunk_validity_resize_for_row_count(&tail.valid_bits, len(tail.values))
		column_chunk_validity_set_inbounds(&tail.valid_bits, idx, coerced != nil)
		return Column_Chunks(chunks), true
	case [dynamic]Column_Chunk(Database_String):
		chunks := typed
		need_new := len(chunks) == 0 || len(chunks[len(chunks) - 1].values) >= COLUMN_CHUNK_SIZE
		if need_new {
			append(&chunks, Column_Chunk(Database_String){})
		}
		tail := &chunks[len(chunks) - 1]
		if coerced == nil {
			append(&tail.values, Database_String{})
		} else {
			v, v_ok := coerced.(Database_String)
			if !v_ok {
				return column, false
			}
			append(&tail.values, v)
		}
		idx := len(tail.values) - 1
		column_chunk_validity_resize_for_row_count(&tail.valid_bits, len(tail.values))
		column_chunk_validity_set_inbounds(&tail.valid_bits, idx, coerced != nil)
		return Column_Chunks(chunks), true
	}
	return column, false
}

// Removes the last logical value from a typed column and drops empty tail chunks.
table_storage_column_pop :: proc(column_chunks: ^Column_Chunks) {
	// TODO: try to consolidate logic

	switch &chunks in column_chunks {
	case [dynamic]Column_Chunk(int):
		assert(len(chunks) > 0)

		tail_i := len(chunks) - 1
		tail := &chunks[tail_i]
		assert(len(tail.values) > 0)

		new_len := len(tail.values) - 1
		resize(&tail.values, new_len)
		column_chunk_validity_resize_for_row_count(&tail.valid_bits, new_len)
		if new_len == 0 do resize(&chunks, len(chunks) - 1)

	case [dynamic]Column_Chunk(f64):
		assert(len(chunks) > 0)

		tail_i := len(chunks) - 1
		tail := &chunks[tail_i]
		assert(len(tail.values) > 0)

		new_len := len(tail.values) - 1
		resize(&tail.values, new_len)
		column_chunk_validity_resize_for_row_count(&tail.valid_bits, new_len)
		if new_len == 0 do resize(&chunks, len(chunks) - 1)

	case [dynamic]Column_Chunk(bool):
		assert(len(chunks) > 0)

		tail_i := len(chunks) - 1
		tail := &chunks[tail_i]
		assert(len(tail.values) > 0)

		new_len := len(tail.values) - 1
		resize(&tail.values, new_len)
		column_chunk_validity_resize_for_row_count(&tail.valid_bits, new_len)
		if new_len == 0 do resize(&chunks, len(chunks) - 1)

	case [dynamic]Column_Chunk(Database_String):
		assert(len(chunks) > 0)

		tail_i := len(chunks) - 1
		tail := &chunks[tail_i]
		assert(len(tail.values) > 0)

		last_vi := len(tail.values) - 1
		_ = column_chunk_validity_get(tail.valid_bits[:], last_vi)
		new_len := last_vi
		resize(&tail.values, new_len)
		column_chunk_validity_resize_for_row_count(&tail.valid_bits, new_len)
		if new_len == 0 do resize(&chunks, len(chunks) - 1)

	}
}

// Removes a column value by swapping in the last value, preserving dense storage.
table_storage_column_remove_unordered :: proc(
	column_chunks: ^Column_Chunks,
	row_index: Row_Index,
) {
	switch &chunks in column_chunks {
	case [dynamic]Column_Chunk(int):
		n := table_columnar_total_rows_first_col(chunks)
		assert(n > 0)

		last := Row_Index(n - 1)
		if row_index == last {
			table_storage_column_pop(column_chunks)
			return
		}
		ci_r, off_r, ok_r := table_columnar_flat_to_loc(column_chunks^, row_index)
		ci_l, off_l, ok_l := table_columnar_flat_to_loc(column_chunks^, last)
		assert(ok_r)
		assert(ok_l)
		v_last := chunks[ci_l].values[off_l]
		valid_last := column_chunk_validity_get(chunks[ci_l].valid_bits[:], off_l)
		chunks[ci_r].values[off_r] = v_last
		column_chunk_validity_resize_for_row_count(
			&chunks[ci_r].valid_bits,
			len(chunks[ci_r].values),
		)
		column_chunk_validity_set_inbounds(&chunks[ci_r].valid_bits, off_r, valid_last)
		table_storage_column_pop(column_chunks)

	case [dynamic]Column_Chunk(f64):
		n := table_columnar_total_rows_first_col(chunks)
		assert(n > 0)

		last := Row_Index(n - 1)
		if row_index == last {
			table_storage_column_pop(column_chunks)
			return
		}
		ci_r, off_r, ok_r := table_columnar_flat_to_loc(column_chunks^, row_index)
		ci_l, off_l, ok_l := table_columnar_flat_to_loc(column_chunks^, last)
		assert(ok_r)
		assert(ok_l)
		v_last := chunks[ci_l].values[off_l]
		valid_last := column_chunk_validity_get(chunks[ci_l].valid_bits[:], off_l)
		chunks[ci_r].values[off_r] = v_last
		column_chunk_validity_resize_for_row_count(
			&chunks[ci_r].valid_bits,
			len(chunks[ci_r].values),
		)
		column_chunk_validity_set_inbounds(&chunks[ci_r].valid_bits, off_r, valid_last)
		table_storage_column_pop(column_chunks)
	case [dynamic]Column_Chunk(bool):
		n := table_columnar_total_rows_first_col(chunks)
		assert(n > 0)

		last := Row_Index(n - 1)
		if row_index == last {
			table_storage_column_pop(column_chunks)
			return
		}
		ci_r, off_r, ok_r := table_columnar_flat_to_loc(column_chunks^, row_index)
		ci_l, off_l, ok_l := table_columnar_flat_to_loc(column_chunks^, last)
		assert(ok_r)
		assert(ok_l)
		v_last := chunks[ci_l].values[off_l]
		valid_last := column_chunk_validity_get(chunks[ci_l].valid_bits[:], off_l)
		chunks[ci_r].values[off_r] = v_last
		column_chunk_validity_resize_for_row_count(
			&chunks[ci_r].valid_bits,
			len(chunks[ci_r].values),
		)
		column_chunk_validity_set_inbounds(&chunks[ci_r].valid_bits, off_r, valid_last)
		table_storage_column_pop(column_chunks)

	case [dynamic]Column_Chunk(Database_String):
		n := table_columnar_total_rows_first_col(chunks)
		assert(n > 0)

		last := Row_Index(n - 1)
		if row_index == last {
			table_storage_column_pop(column_chunks)
			return
		}
		ci_r, off_r, ok_r := table_columnar_flat_to_loc(column_chunks^, row_index)
		ci_l, off_l, ok_l := table_columnar_flat_to_loc(column_chunks^, last)
		assert(ok_r)
		assert(ok_l)
		// Destination is fixed-cap string storage; replace in-place.
		valid_last := column_chunk_validity_get(chunks[ci_l].valid_bits[:], off_l)
		if valid_last {
			src_s := database_string_unwrap(chunks[ci_l].values[off_l])
			chunks[ci_r].values[off_r] = database_string_make(src_s)
		} else {
			chunks[ci_r].values[off_r] = {}
		}
		column_chunk_validity_resize_for_row_count(
			&chunks[ci_r].valid_bits,
			len(chunks[ci_r].values),
		)
		column_chunk_validity_set_inbounds(&chunks[ci_r].valid_bits, off_r, valid_last)
		table_storage_column_pop(column_chunks)
	}
}

// Replaces an existing row without changing row count or row-ref index positions.
table_set_row :: proc(table: ^Table, row_index: Row_Index, row: Table_Row) -> (ok: bool) {
	table_storage_ensure(table)
	if row_index < 0 || int(row_index) >= table_row_count(table) {
		log.errorf(
			"Row index out of bounds: %v, expected 0..%v",
			row_index,
			table_row_count(table) - 1,
		)
		return false
	}
	switch storage in table.storage {
	case [dynamic]Table_Row:
		rows := storage
		assert(rows.allocator == context.allocator)
		// Row storage owns persistent row buffers. Never store temp-backed rows directly.
		owned_row := make(Table_Row, len(row), context.allocator)
		copy(owned_row[:], row[:])
		delete(rows[row_index])
		rows[row_index] = owned_row
		table.storage = rows
		return true
	case [dynamic]Column_Chunks:
		cols := storage
		if len(cols) != len(row) {
			log.errorf("Row length mismatch: %v != %v", len(cols), len(row))
			return false
		}
		for _, col_i in cols {
			column_type, type_ok := table_column_type_resolve_for_write(table, col_i)
			if !type_ok {
				log.errorf(
					"Unable to resolve storage type for column '%v' in table '%v'",
					table.column_names[col_i],
					table.name,
				)
				return false
			}
			updated := table_storage_column_set(
				cols[col_i],
				column_type,
				row_index,
				row[col_i],
			) or_return
			cols[col_i] = updated
		}
		table.storage = cols
		return true
	}
	return false
}

// Appends a row to row storage or splits it into the table's column chunks.
table_append_row :: proc(
	table: ^Table,
	row: Table_Row, // TODO: maybe this should be a slice istead
) -> (
	result: bool,
) {
	defer {
		if !result do msgf(.Error, .Database, "Failed to append row into table '%s'", table.name)
		// For columnar storage, the row won't be appended as is, but rather each element will be copied into the columns.
		// If we don't delete the row here, it will leak memory. TODO: double check
		if storage, ok := table.storage.([dynamic]Column_Chunks); ok do delete(row)
	}

	table_storage_ensure(table)

	switch &storage in table.storage {
	case [dynamic]Table_Row:
		assert(len(table.column_types) == len(row))
		append(&storage, row)
		return true

	case [dynamic]Column_Chunks:
		assert(len(table.column_types) == len(row))
		assert(len(storage) == len(row))

		appended_count := 0
		for _, col_i in storage {
			column_type, type_ok := table_column_type_resolve_for_write(table, col_i)
			if !type_ok {
				// Keep all columns length-aligned when a row append fails mid-way.
				for rollback_i in 0 ..< appended_count {
					table_storage_column_pop(&storage[rollback_i])
				}
				return
			}
			updated, append_ok := table_storage_column_append(
				storage[col_i],
				column_type,
				row[col_i],
			)
			if !append_ok {
				// Write path is all-or-nothing per row to avoid storage corruption.
				for rollback_i := 0; rollback_i < appended_count; rollback_i += 1 {
					table_storage_column_pop(&storage[rollback_i])
				}
				return
			}
			storage[col_i] = updated
			appended_count += 1
		}
		return true
	}
	return
}

// Removes the current last row from whichever storage layout the table uses.
@(require_results)
table_remove_last_row :: proc(table: ^Table) -> bool {
	count := table_row_count(table)
	if count <= 0 {
		return false
	}
	switch storage in table.storage {
	case [dynamic]Table_Row:
		rows := transmute([dynamic]Table_Row)storage
		resize(&rows, len(rows) - 1)
		table.storage = rows
		return true
	case [dynamic]Column_Chunks:
		cols := transmute([dynamic]Column_Chunks)storage
		for _, col_i in cols {
			table_storage_column_pop(&cols[col_i])
		}
		table.storage = cols
		return true
	}
	return false
}

// Deletes a row with swap-with-last semantics and reports the moved row metadata.
table_delete_row_unordered :: proc(
	table: ^Table,
	row_index: Row_Index,
) -> (
	deleted_row: Table_Row,
	moved_row: Table_Row,
	moved_from: Row_Index,
	moved: bool,
	ok: bool,
) {
	moved_from = -1

	table_storage_ensure(table)
	count := table_row_count(table)
	assert(count > 0)
	assert(row_index >= 0)
	assert(int(row_index) < count)

	last_i := Row_Index(count - 1)
	deleted_row = table_get_row(table, row_index) or_return

	if row_index != last_i {
		moved_row = table_get_row(table, last_i) or_return
	}

	switch &storage in table.storage {
	case [dynamic]Table_Row:
		dynamic_array_unoredered_remove(&storage, int(row_index))

	case [dynamic]Column_Chunks:
		for _, col_i in storage {
			table_storage_column_remove_unordered(&storage[col_i], row_index)
		}
	}

	return deleted_row, moved_row, last_i, row_index != last_i, true
}

// Finds a user-created secondary index by name, skipping the primary key index.
// TODO: we should probably have the same procs for dealing with both types of indexes...
index_find_by_name :: proc(table: ^Table, index_name: string) -> (int, bool) {
	for idx, i in table.indexes {
		(!idx.is_primary) or_continue
		(idx.name == index_name) or_continue
		return i, true
	}
	return -1, false
}

// Finds the secondary index that covers a specific table column.
// TODO: we should probably have the same procs for dealing with both types of indexes...
index_find_by_column :: proc(table: ^Table, column_index: int) -> (int, bool) {
	for idx, i in table.indexes {
		(!idx.is_primary) or_continue
		(idx.column_index == column_index) or_continue
		return i, true
	}
	return -1, false
}

// // Frees the duplicate-row list owned by a non-unique index tree node.
// // TODO: inline where it's used
// index_non_unique_tree_on_remove :: proc(
// 	key: Database_Value,
// 	value: [dynamic]Row_Index,
// 	user_data: rawptr,
// ) {
// 	// Non-unique index nodes own their row-ref slices; the tree only frees node storage.
// 	delete(value)
// }

// Adds one row reference under a secondary-index key.
// TODO: the error shoudl be part of the proc that is being called so that we don't need to have this proc here.
index_non_unique_insert_row_ref :: proc(
	index: ^Table_Index,
	key: Database_Value,
	row_index: Row_Index,
) -> bool {
	if !index_tree_non_unique_add_ref(&index.tree, key, row_index) {
		msgf(.Error, .Database, "Failed to update index '%s'", index.name)
		return false
	}
	return true
}

// Removes one row reference from a secondary-index key.
// TODO: remove the proc, use the one inside and make sure it prints errors when it fails.
index_non_unique_remove_row_ref :: proc(
	index: ^Table_Index,
	key: Database_Value,
	row_index: Row_Index,
) -> bool {
	return index_tree_non_unique_remove_ref(&index.tree, key, row_index)
}

// Inserts a row reference into every non-primary index on the table.
// TODO: why not handle primary key index here as well?
table_indexes_insert_row_non_primary :: proc(
	table: ^Table,
	row: Table_Row,
	row_index: Row_Index,
) -> bool {
	for &idx in table.indexes {
		(!idx.is_primary) or_continue
		key := row[idx.column_index]
		index_non_unique_insert_row_ref(&idx, key, row_index) or_return
	}
	return true
}

// Removes a row reference from every non-primary index on the table.
table_indexes_remove_row_non_primary :: proc(
	table: ^Table,
	row: Table_Row,
	row_index: Row_Index,
) -> bool {
	for &idx in table.indexes {
		(!idx.is_primary) or_continue
		key := row[idx.column_index]
		// TODO: remove row ref should print the error instead
		index_non_unique_remove_row_ref(&idx, key, row_index) or_return
		// 	msgf(.Error, .Database, "Corrupted index '%s' while removing row", idx.name)
		// 	return false
		// }
	}
	return true
}

// Repoints secondary indexes after unordered row deletion moves the last row.
table_indexes_repoint_row_non_primary :: proc(
	table: ^Table,
	row: Table_Row,
	from, to: Row_Index,
) -> bool {
	if from == to {
		return true
	}
	for &idx in table.indexes {
		(!idx.is_primary) or_continue
		key := row[idx.column_index]
		// TODO: update ref should print the error instead
		index_tree_non_unique_update_ref(&idx.tree, key, from, to) or_return
		// 	msgf(.Error, .Database, "Corrupted index '%s' while repointing row", idx.name)
		// 	return false
		// }
	}
	return true
}

// Values get copied into the new row - their source can get deleted afterwards.
// Builds a full table row from caller-supplied column/value slices.
table_row :: proc(table: ^Table, column_names: []string, values: []Database_Value) -> Table_Row {
	result := make(Table_Row, len(column_names), context.allocator)
	for _, column_index in column_names {
		result[column_index] = values[column_index]
	}
	return result
}

// Returns the first NOT NULL column violated by a candidate row.
table_not_null_violation_column_index :: proc(
	table: ^Table,
	row: Table_Row, // TODO: maybe this should be a slice instead
) -> (
	result_column_index: int,
	found: bool,
) {
	assert(len(row) == len(table.column_not_null))
	for is_not_null, col_i in table.column_not_null {
		is_not_null or_continue
		(row[col_i] == nil) or_continue
		return col_i, true
	}
	return -1, false
}

// Inserts a fully validated row and updates primary plus secondary indexes.
database_insert_row :: proc(
	table: ^Table,
	column_names: []string,
	values: []Database_Value,
) -> (
	ok: bool,
) {
	table_storage_ensure(table)

	_, is_storage_columns := table.storage.([dynamic]Column_Chunks)
	row_allocator := context.allocator // TODO: I don't like making this split here.
	row_needs_delete := true
	if is_storage_columns {
		// Columnar writes copy row values into column chunks immediately.
		// Keep the transient row in temp memory and avoid per-row delete churn.
		row_allocator = database_query_allocator // TODO: I don't like making this split here.
		row_needs_delete = false
	}

	primary_key_value: Database_Value
	{
		primary_key_index_in_values := -1
		for name, i in column_names {
			if name == table.column_names[table.primary_key_column_index] {
				primary_key_index_in_values = i
				break
			}
		}
		if primary_key_index_in_values == -1 {
			msgf(
				.Error,
				.Database,
				"Primary key value for column '%v' must be provided and cannot be NULL",
				table.primary_key_column_index,
			)
			return false
		}
		primary_key_value = values[primary_key_index_in_values]
	}

	pk_tree := table_primary_unique_tree_ptr(table)

	if index_tree_unique_contains(pk_tree, primary_key_value) {
		msgf(.Error, .Database, "Primary key value already exists in table '%s'", table.name)
		return false
	}

	new_row := table_row(table, column_names, values)
	defer if !ok && row_needs_delete do delete(new_row)

	if violation_col, has_violation := table_not_null_violation_column_index(table, new_row);
	   has_violation {
		msgf(
			.Error,
			.Database,
			"Column '%v' in table '%v' cannot be NULL during INSERT",
			table.column_names[violation_col],
			table.name,
		)
		return false
	}

	// TODO: table_append_row should be inlined into this proc maybe?
	table_append_row(table, new_row) or_return
	defer if !ok {
		remove_ok := table_remove_last_row(table)
		assert(remove_ok)
	}

	row_index := Row_Index(table_row_count(table) - 1)

	index_tree_unique_insert(table.name, pk_tree, primary_key_value, row_index) or_return
	defer if !ok {
		remove_ok := index_tree_unique_remove_key(pk_tree, primary_key_value)
		assert(remove_ok)
	}

	// Other indexes must be updated in the same write path as PK to keep all lookup plans coherent.
	table_indexes_insert_row_non_primary(table, new_row, row_index) or_return

	return true
}

// database_string_equal :: proc(a: ^Database_String, b: string) -> bool {
// 	right := database_string_make(b)
// 	return slice.simple_equal(a^[:], right[:])
// }

// Finds a table visible to the current transaction state.
database_find_table :: proc(table_name: string, log_error: bool) -> (result: ^Table, ok: bool) {
	items := database_tables_items()
	for i := 0; i < len(items); i += 1 {
		(items[i].name == table_name) or_continue
		return &items[i], true
	}
	// TODO: should this log_error thing exist
	if log_error {
		msgf(.Error, .Database, "Table '%s' does not exist", table_name)
	}
	return
}

Index_Filter_Strategy :: enum {
	None,
	Points,
	Interval,
}

Index_Filter_Plan :: struct {
	index_position: int,
	strategy:       Index_Filter_Strategy,
	points:         [dynamic]Database_Value,
	interval:       Pk_Interval,
	residual_where: bool,
}

// Walks a secondary index in filter order one row at a time (execution pulls).
Index_Filter_Scan_Stream :: struct {
	table:        ^Table,
	tree:         ^Index_Tree,
	descending:   bool,
	strategy:     Index_Filter_Strategy,
	points:       []Database_Value,
	point_idx:    int,
	dup_i:        int,
	current_refs: ^[dynamic]Row_Index,
	interval:     Pk_Interval,
	iter:         Index_Tree_Non_Unique_Iter,
	iter_valid:   bool,
}

Order_Index_Strategy :: enum {
	None,
	Primary,
	Indexed,
}

Order_Index_Plan :: struct {
	strategy:       Order_Index_Strategy,
	index_position: int,
	descending:     bool,
}

Where_Plan_Kind :: enum {
	None,
	Pk,
	Index,
}

Select_Scan_Strategy :: enum {
	Where_First,
	Order_First,
}

Single_Table_Select_Plan :: struct {
	order_plan_available: bool,
	order_plan:           Order_Index_Plan,
	where_plan_kind:      Where_Plan_Kind,
	pk_plan:              Pk_Where_Plan,
	index_filter_plan:    Index_Filter_Plan,
	chosen_strategy:      Select_Scan_Strategy,
	used_order_scan:      bool,
	// Positions into table.indexes for the WHERE and ORDER plans (not necessarily the scan order).
	where_index_position: int,
	order_index_position: int,
}

// Constructs a select plan with "no index position" sentinels filled in.
single_table_select_plan_init :: proc() -> Single_Table_Select_Plan {
	return Single_Table_Select_Plan{where_index_position = -1, order_index_position = -1}
}

// Records table.indexes positions for whichever WHERE and ORDER plans were chosen.
single_table_select_plan_set_index_positions :: proc(
	plan: ^Single_Table_Select_Plan,
	table: ^Table,
) {
	switch plan.where_plan_kind {
	case .None:
		plan.where_index_position = -1
	case .Pk:
		_, pos := table_primary_index(table)
		plan.where_index_position = pos
	case .Index:
		plan.where_index_position = plan.index_filter_plan.index_position
	}

	if plan.order_plan_available {
		#partial switch plan.order_plan.strategy {
		case .Primary:
			_, pos := table_primary_index(table)
			plan.order_index_position = pos
		case .Indexed:
			plan.order_index_position = plan.order_plan.index_position
		case .None:
			plan.order_index_position = -1
		}
	} else {
		plan.order_index_position = -1
	}
}

@(thread_local)
exec_select_plans: [dynamic]Single_Table_Select_Plan

// Checks whether an AST identifier names a specific table column.
ident_matches_table_column :: proc(
	ident: ^AST_Ident,
	table: ^Table,
	table_name: string,
	column_index: int,
) -> bool {
	if ident.column_name != table.column_names[column_index] {
		return false
	}
	if ident.table_name != "" && ident.table_name != table_name {
		return false
	}
	return true
}

// Recognizes WHERE predicates that can be served by a secondary index.
// TODO: consider calling assert on invalid AST rather than ignoring it.
analyze_index_where_for_table :: proc(
	where_clause: ^AST_Node,
	table: ^Table,
	table_name: string,
) -> (
	plan: Index_Filter_Plan,
	ok: bool,
) {
	plan.index_position = -1
	plan.strategy = .None
	plan.points = make([dynamic]Database_Value, database_query_allocator)
	plan.interval = pk_interval_unbounded()
	plan.residual_where = false

	conjuncts := make([dynamic]^AST_Node, allocator = database_query_allocator)
	flatten_and_conjuncts(where_clause, &conjuncts)

	for node, conj_i in conjuncts {
		cond, is_cond := node.value.(^Condition)
		if !is_cond {
			continue
		}

		for idx, index_pos in table.indexes {
			if idx.is_primary {
				continue
			}
			column_index := idx.column_index
			op_kind := cond.op.token.kind
			l_ident, l_is_ident := cond.a.value.(^AST_Ident)
			r_ident, r_is_ident := cond.b.value.(^AST_Ident)

			pk_on_left :=
				l_is_ident && ident_matches_table_column(l_ident, table, table_name, column_index)
			pk_on_right :=
				r_is_ident && ident_matches_table_column(r_ident, table, table_name, column_index)
			if !pk_on_left && !pk_on_right {
				continue
			}

			selected := Index_Filter_Plan {
				index_position = index_pos,
				strategy       = .None,
				points         = make([dynamic]Database_Value, database_query_allocator),
				interval       = pk_interval_unbounded(),
				residual_where = len(conjuncts) > 1,
			}

			if op_kind == .In && pk_on_left {
				values, is_list := cond.b.value.([dynamic]^AST_Node)
				is_list or_continue
				selected.strategy = .Points
				for n in values {
					v, v_ok := try_evaluate_constant_term(n)
					if !v_ok {
						clear(&selected.points)
						selected.strategy = .None
						break
					}
					append(&selected.points, v)
				}
			} else if op_kind == .Between && pk_on_left {
				values, is_list := cond.b.value.([dynamic]^AST_Node)
				if is_list && len(values) == 2 {
					lo, ok_lo := try_evaluate_constant_term(values[0])
					hi, ok_hi := try_evaluate_constant_term(values[1])
					if ok_lo && ok_hi {
						selected.strategy = .Interval
						selected.interval.lo = lo
						selected.interval.hi = hi
						selected.interval.lo_strict = false
						selected.interval.hi_strict = false
					}
				}
			} else if op_kind == .Equals ||
			   op_kind == .Greater_Than ||
			   op_kind == .Gt_Eq ||
			   op_kind == .Less_Than ||
			   op_kind == .Lt_Eq {
				const_node: ^AST_Node
				if pk_on_left && !r_is_ident {
					const_node = cond.b
				} else if pk_on_right && !l_is_ident {
					const_node = cond.a
				} else {
					continue
				}

				const_val, const_ok := try_evaluate_constant_term(const_node)
				if !const_ok {
					continue
				}

				if op_kind == .Equals {
					selected.strategy = .Points
					append(&selected.points, const_val)
				} else {
					selected.strategy = .Interval
					merge_interval_from_comparison(
						&selected.interval,
						op_kind,
						pk_on_left,
						const_val,
					)
				}
			}

			if selected.strategy == .None {
				continue
			}

			if conj_i + 1 < len(conjuncts) {
				selected.residual_where = true
			}
			return selected, true
		}
	}
	return plan, false
}

// Initializes a pull stream for rows produced by a secondary-index filter plan.
index_filter_scan_stream_init :: proc(
	s: ^Index_Filter_Scan_Stream,
	table: ^Table,
	plan: Index_Filter_Plan,
	descending: bool,
) {
	s.table = table
	s.descending = descending
	s.strategy = plan.strategy
	s.current_refs = nil
	s.dup_i = 0
	s.iter_valid = false
	if plan.index_position < 0 || plan.index_position >= len(table.indexes) {
		s.strategy = .None
		return
	}
	idx := &table.indexes[plan.index_position]
	s.tree = &idx.tree
	switch plan.strategy {
	case .None:
		return
	case .Points:
		s.points = plan.points[:]
		if descending {
			s.point_idx = len(s.points) - 1
		} else {
			s.point_idx = 0
		}
		return
	case .Interval:
		s.interval = plan.interval
		if !pk_interval_nonempty(s.interval) || index_tree_non_unique_len(s.tree) == 0 {
			return
		}
		start: Index_Tree_Non_Unique_Pos
		if descending {
			start = index_tree_non_unique_last_pos(s.tree)
		} else if lo, has_lo := s.interval.lo.?; has_lo {
			if s.interval.lo_strict {
				start = index_tree_non_unique_upper_bound_pos(s.tree, lo)
			} else {
				start = index_tree_non_unique_lower_bound_pos(s.tree, lo)
			}
		} else {
			start = index_tree_non_unique_first_pos(s.tree)
		}
		if !index_tree_non_unique_pos_valid(start) {
			return
		}
		dir := Index_Tree_Direction.Forward
		if descending {
			dir = .Backward
		}
		s.iter = index_tree_non_unique_iter_from_pos(s.tree, start, dir)
		s.iter_valid = true
		return
	}
	unreachable()
}

// Pulls the next row matching a secondary-index point or interval scan.
index_filter_scan_stream_next :: proc(s: ^Index_Filter_Scan_Stream) -> (row: Table_Row, ok: bool) {
	switch s.strategy {
	case .None:
		return
	case .Points:
		for {
			if s.current_refs != nil {
				if s.dup_i < len(s.current_refs^) {
					ri := s.current_refs^[s.dup_i]
					s.dup_i += 1
					return table_get_row(s.table, ri)
				}
				s.current_refs = nil
				s.dup_i = 0
			}
			if s.descending {
				(s.point_idx >= 0) or_return

				key := s.points[s.point_idx]
				s.point_idx -= 1
				if refs, ok := index_tree_non_unique_find_refs_ptr(s.tree, key);
				   ok && len(refs^) > 0 {
					s.current_refs = refs
				}
				continue
			}
			if s.point_idx >= len(s.points) {
				return {}, false
			}
			key := s.points[s.point_idx]
			s.point_idx += 1
			if refs, ok := index_tree_non_unique_find_refs_ptr(s.tree, key); ok && len(refs^) > 0 {
				s.current_refs = refs
			}
			continue
		}
	case .Interval:
		if !s.iter_valid {
			return {}, false
		}
		for {
			if s.current_refs != nil && s.dup_i < len(s.current_refs^) {
				ri := s.current_refs^[s.dup_i]
				s.dup_i += 1
				return table_get_row(s.table, ri)
			}
			s.current_refs = nil
			s.dup_i = 0
			key, refs, has := index_tree_non_unique_iter_next(&s.iter)
			if !has {
				s.iter_valid = false
				return {}, false
			}
			if s.descending {
				if hi, has_hi := s.interval.hi.?; has_hi {
					cmp_hi := value_ordering_for_column_sorting(key, hi)
					if cmp_hi == .Greater || (cmp_hi == .Equal && s.interval.hi_strict) {
						continue
					}
				}
				if lo, has_lo := s.interval.lo.?; has_lo {
					cmp_lo := value_ordering_for_column_sorting(key, lo)
					if cmp_lo == .Less || (cmp_lo == .Equal && s.interval.lo_strict) {
						s.iter_valid = false
						return {}, false
					}
				}
			} else if !pk_value_in_interval(key, s.interval) {
				s.iter_valid = false
				return {}, false
			}
			s.current_refs = refs
		}
	}
	unreachable()
}

// Appends all rows produced by a secondary-index filter plan.
append_rows_from_index_filter_plan :: proc(
	table: ^Table,
	plan: Index_Filter_Plan,
	descending: bool,
	out: ^[dynamic]Table_Row,
) {
	stream: Index_Filter_Scan_Stream
	index_filter_scan_stream_init(&stream, table, plan, descending)
	for {
		row, row_ok := index_filter_scan_stream_next(&stream)
		if !row_ok {
			break
		}
		append(out, row)
	}
}

// Resolves an ORDER BY identifier against projected column names and join names.
resolve_order_ident_column_index :: proc(
	ident: ^AST_Ident,
	column_names: []string,
	has_joins: bool,
	base_table_name: string,
) -> (
	int,
	bool,
) {
	if ident.table_name != "" {
		full_name := ast_ident_as_string(ident)
		if full_idx, found := slice.linear_search(column_names, full_name); found {
			return full_idx, true
		}
		if !has_joins && ident.table_name == base_table_name {
			return slice.linear_search(column_names, ident.column_name)
		}
		return -1, false
	}

	if !has_joins {
		return slice.linear_search(column_names, ident.column_name)
	}

	match := -1
	for key, i in column_names {
		suffix := fmt.tprintf(".%s", ident.column_name)
		if strings.has_suffix(key, suffix) {
			if match >= 0 {
				return -1, false
			}
			match = i
		}
	}
	if match < 0 {
		return -1, false
	}
	return match, true
}

// Compares two result rows according to the full ORDER BY list.
compare_rows_for_order_by :: proc(
	left: Table_Row,
	right: Table_Row,
	order_items: []Order_By_Item,
	column_names: []string,
	has_joins: bool,
	base_table_name: string,
) -> (
	ordering: slice.Ordering,
	ok: bool,
) {
	for item in order_items {
		left_val: Database_Value
		right_val: Database_Value

		if ident, is_ident := item.expr.value.(^AST_Ident); is_ident {
			idx, found := resolve_order_ident_column_index(
				ident,
				column_names,
				has_joins,
				base_table_name,
			)
			if !found {
				db_msgf_at(
					.Error,
					ident.token,
					"Unknown ORDER BY column '%v'",
					ast_ident_as_string(ident),
				)
				return .Equal, false
			}
			left_val = left[idx]
			right_val = right[idx]
		} else {
			left_eval := evaluate_term_bound(item.expr, left[:]) or_return
			right_eval := evaluate_term_bound(item.expr, right[:]) or_return
			left_ok, right_ok: bool
			left_val, left_ok = left_eval.(Database_Value)
			right_val, right_ok = right_eval.(Database_Value)
			if !left_ok || !right_ok {
				db_msgf_at(
					.Error,
					item.expr.token,
					"ORDER BY expression must resolve to comparable values",
				)
				return .Equal, false
			}
		}

		cmp := value_ordering_for_column_sorting(left_val, right_val)
		if cmp != .Equal {
			if item.descending {
				if cmp == .Less {
					return .Greater, true
				}
				return .Less, true
			}
			return cmp, true
		}
	}
	return .Equal, true
}

// Sorts a row slice by ORDER BY terms and reports comparator failures.
merge_sort_row_slice_for_order_by :: proc(
	rows: []Table_Row,
	order_items: []Order_By_Item,
	column_names: []string,
	has_joins: bool,
	base_table_name: string,
) -> bool {
	if len(rows) <= 1 || len(order_items) <= 0 {
		return true
	}

	@(static) sort_failed := false
	sort_failed = false
	Data :: struct {
		order_items:     []Order_By_Item,
		column_names:    []string,
		has_joins:       bool,
		base_table_name: string,
	}
	context.user_ptr = &Data {
		order_items = order_items,
		column_names = column_names,
		has_joins = has_joins,
		base_table_name = base_table_name,
	}
	// Adapter for core:sort: convert slice.Ordering to the -1/0/1 comparator contract.
	sort.merge_sort_proc(rows, proc(left: Table_Row, right: Table_Row) -> int {
		data := cast(^Data)context.user_ptr
		cmp, ok := compare_rows_for_order_by(
			left,
			right,
			data.order_items,
			data.column_names,
			data.has_joins,
			data.base_table_name,
		)
		if !ok {
			sort_failed = true
			return 0
		}
		switch cmp {
		case .Less:
			return -1
		case .Greater:
			return 1
		case .Equal:
			return 0
		}
		return 0
	})
	return !sort_failed
}

// Sorts the dynamic result row array by ORDER BY terms.
merge_sort_rows_for_order_by :: proc(
	rows: ^[dynamic]Table_Row,
	order_items: []Order_By_Item,
	column_names: []string,
	has_joins: bool,
	base_table_name: string,
) -> bool {
	return merge_sort_row_slice_for_order_by(
		rows^[:],
		order_items,
		column_names,
		has_joins,
		base_table_name,
	)
}

// Refines tied groups when an index scan already satisfies an ORDER BY prefix.
order_by_tie_group_refine :: proc(
	rows: ^[dynamic]Table_Row,
	order_items: []Order_By_Item,
	prefix_sorted_terms: int,
	column_names: []string,
	has_joins: bool,
	base_table_name: string,
) -> bool {
	if len(rows^) <= 1 {
		return true
	}
	if prefix_sorted_terms <= 0 || prefix_sorted_terms >= len(order_items) {
		return true
	}

	prefix_items := order_items[:prefix_sorted_terms]
	suffix_items := order_items[prefix_sorted_terms:]
	if len(suffix_items) <= 0 {
		return true
	}

	group_start := 0
	for group_start < len(rows^) {
		group_end := group_start + 1
		for group_end < len(rows^) {
			// Prefix order is already established by scan order, so only tied windows need refinement.
			prefix_cmp, cmp_ok := compare_rows_for_order_by(
				rows^[group_start],
				rows^[group_end],
				prefix_items,
				column_names,
				has_joins,
				base_table_name,
			)
			if !cmp_ok {
				return false
			}
			if prefix_cmp != .Equal {
				break
			}
			group_end += 1
		}
		if group_end - group_start > 1 {
			if !merge_sort_row_slice_for_order_by(
				rows^[group_start:group_end],
				suffix_items,
				column_names,
				has_joins,
				base_table_name,
			) {
				return false
			}
		}
		group_start = group_end
	}
	return true
}

// Applies ORDER BY sorting to a Rows_With_Names result.
apply_order_by :: proc(
	result_rows: ^Rows_With_Names,
	order_items: []Order_By_Item,
	has_joins: bool,
	base_table_name: string,
) -> bool {
	if len(order_items) == 0 || len(result_rows.rows) <= 1 {
		return true
	}

	return merge_sort_rows_for_order_by(
		&result_rows.rows,
		order_items,
		result_rows.column_names,
		has_joins,
		base_table_name,
	)
}

// Applies OFFSET/LIMIT by returning a window over the result rows.
apply_offset_limit :: proc(
	result_rows: Rows_With_Names,
	offset: Maybe(int),
	limit: Maybe(int),
) -> Rows_With_Names {
	rows := result_rows
	start := 0
	if off, has_off := offset.?; has_off {
		start = off
	}
	if start >= len(rows.rows) {
		rows.rows = make([dynamic]Table_Row, database_query_allocator)
		return rows
	}

	stop := len(rows.rows)
	if lim, has_lim := limit.?; has_lim {
		stop = min(stop, start + lim)
	}

	window := make_dynamic_array_len_cap(
		[dynamic]Table_Row,
		0,
		max(0, stop - start),
		database_query_allocator,
	)
	for i := start; i < stop; i += 1 {
		append(&window, rows.rows[i])
	}
	rows.rows = window
	return rows
}

// Reverses row order in-place, used for descending index-order scans.
reverse_table_rows :: proc(rows: ^[dynamic]Table_Row) {
	for left := 0; left < len(rows^) / 2; left += 1 {
		right := len(rows^) - left - 1
		rows[left], rows[right] = rows[right], rows[left]
	}
}

// Appends rows in primary-key index order.
append_rows_from_pk_index_order :: proc(table: ^Table, out: ^[dynamic]Table_Row) -> bool {
	pk := table_primary_unique_tree_ptr(table)
	it := index_tree_unique_iter(pk, .Forward) or_return
	for {
		_, row_ref, has := index_tree_unique_iter_next(&it)
		if !has {
			break
		}
		row, ok := table_get_row(table, row_ref)
		if !ok do continue
		append(out, row)
	}
	return true
}

// Appends rows in a secondary index's key order, including duplicate key refs.
append_rows_from_index_order :: proc(
	table: ^Table,
	index_position: int,
	out: ^[dynamic]Table_Row,
) {
	idx := &table.indexes[index_position]
	it := index_tree_non_unique_iter(&idx.tree, .Forward)
	for {
		_, refs, has := index_tree_non_unique_iter_next(&it)
		if !has {
			break
		}
		for row_ref in refs^ {
			row, ok := table_get_row(table, row_ref)
			if !ok do continue
			append(out, row)
		}
	}
}

// Chooses an index-backed ORDER BY plan for the leading ORDER BY term if available.
order_index_plan_for_select :: proc(
	select: ^Select,
	table: ^Table,
	table_name: string,
) -> (
	plan: Order_Index_Plan,
	ok: bool,
) {
	if len(select.order_by) <= 0 {
		return plan, false
	}
	order_ident, ident_ok := select.order_by[0].expr.value.(^AST_Ident)
	if !ident_ok {
		return plan, false
	}

	plan.descending = select.order_by[0].descending
	if ident_matches_table_column(order_ident, table, table_name, table.primary_key_column_index) {
		plan.strategy = .Primary
		return plan, true
	}

	column_index, found := slice.linear_search(table.column_names[:], order_ident.column_name)
	if !found || (order_ident.table_name != "" && order_ident.table_name != table_name) {
		return plan, false
	}
	if ix_pos, ix_found := index_find_by_column(table, column_index); ix_found {
		plan.strategy = .Indexed
		plan.index_position = ix_pos
		return plan, true
	}
	return plan, false
}

// Appends rows using a prepared ORDER index plan, reversing for DESC when needed.
append_rows_from_order_plan :: proc(
	table: ^Table,
	order_plan: Order_Index_Plan,
	out: ^[dynamic]Table_Row,
) {
	switch order_plan.strategy {
	case .Primary:
		append_rows_from_pk_index_order(table, out)
	case .Indexed:
		append_rows_from_index_order(table, order_plan.index_position, out)
	case .None:
		return
	}
	if order_plan.descending {
		reverse_table_rows(out)
	}
}

// Collapses available WHERE access paths into the selected plan kind.
where_plan_kind :: proc(pk_plan_ok, index_filter_ok: bool) -> Where_Plan_Kind {
	if pk_plan_ok {
		return .Pk
	}
	if index_filter_ok {
		return .Index
	}
	return .None
}

// Reports whether a WHERE plan should usually beat scanning an ORDER index first.
where_plan_is_selective :: proc(
	kind: Where_Plan_Kind,
	pk_plan: Pk_Where_Plan,
	index_filter_plan: Index_Filter_Plan,
) -> bool {
	switch kind {
	case .Pk:
		switch pk_plan.strategy {
		case .Points:
			return true
		case .Interval:
			return true
		case .Full_Scan:
			return false
		}
	case .Index:
		switch index_filter_plan.strategy {
		case .Points:
			return true
		case .Interval:
			return true
		case .None:
			return false
		}
	case .None:
		return false
	}
	return false
}

// Chooses between filtering first or scanning an ORDER index first for one table.
choose_single_table_scan_strategy :: proc(
	table: ^Table,
	order_plan_ok: bool,
	order_plan: Order_Index_Plan,
	where_kind: Where_Plan_Kind,
	pk_plan: Pk_Where_Plan,
	index_filter_plan: Index_Filter_Plan,
	limit: Maybe(int),
	offset: Maybe(int),
) -> Select_Scan_Strategy {
	if !order_plan_ok || where_kind == .None {
		return .Where_First
	}

	// Point and interval lookups are usually much cheaper than ORDER index traversal.
	if where_plan_is_selective(where_kind, pk_plan, index_filter_plan) {
		if where_kind == .Pk && pk_plan.residual_where {
			return .Where_First
		}
		if where_kind == .Index && index_filter_plan.residual_where {
			return .Where_First
		}
	}

	lim, has_lim := limit.?
	if !has_lim || lim <= 0 {
		return .Where_First
	}
	off, has_off := offset.?
	needed := lim
	if has_off && off > 0 {
		needed += off
	}

	// ORDER-first only wins here when we can stop early and avoid sorting a larger candidate set.
	table_rows_n := table_row_count(table)
	if table_rows_n <= 0 {
		return .Where_First
	}
	scan_budget := needed * 8
	switch where_kind {
	case .Pk:
		switch pk_plan.strategy {
		case .Points:
			scan_budget = needed * 4
		case .Interval:
			scan_budget = needed * 6
		case .Full_Scan:
			scan_budget = needed * 10
		}
	case .Index:
		switch index_filter_plan.strategy {
		case .Points:
			scan_budget = needed * 4
		case .Interval:
			scan_budget = needed * 6
		case .None:
			scan_budget = needed * 10
		}
	case .None:
		scan_budget = needed * 10
	}
	if needed <= 32 || scan_budget <= table_rows_n {
		return .Order_First
	}
	return .Where_First
}

// database_ensure_table_exists :: proc(table_name: string) -> bool {
// 	result, ok := database_find_table(table_name)
// 	if !ok {
// 		database_errorf("Table '%s' does not exist", table_name)
// 		return false
// 	}
// 	return true
// }

// Executes a SELECT by building its execution tree and materializing result rows.
exec_select :: proc(select: ^Select) -> (result_rows: Rows_With_Names, result_ok: bool) {
	root, applied_plan, have_plan := plan_select_execution_tree(select) or_return

	result_rows = exec_execution_tree_rows(root) or_return

	if have_plan {
		append(&exec_select_plans, applied_plan)
	}
	return result_rows, true
}

// for 'SELECT' statements, only keep columns that were actually requested.
// FIXME: actually use index-tree indexes for this.
// Projects SELECT-list expressions out of raw table/join rows.
apply_column_selection :: proc(
	result_rows: Rows_With_Names,
	ast_select_columns: [dynamic]^AST_Node,
	has_joins: bool,
	base_table_name: string,
) -> (
	rows: Rows_With_Names,
	ok: bool,
) {
	if len(result_rows.rows) == 0 do return result_rows, true

	for col in ast_select_columns {
		text := col.value.(^AST_Ident) or_else nil
		if text != nil && text.column_name == "*" {
			return result_rows, true
		}
	}

	for col_expr in ast_select_columns {
		bind_expression_slots_to_row_columns(
			col_expr,
			result_rows.column_names,
			has_joins,
			base_table_name,
		) or_return
	}

	all_filtered_rows := make([dynamic]Table_Row, database_query_allocator)
	output_column_names := make([]string, len(ast_select_columns), database_query_allocator)

	for row in result_rows.rows {
		// One cell per SELECT list entry, in written order (not the source table's column indices).
		filtered_row := make(Table_Row, len(ast_select_columns), database_query_allocator)

		for col_expr, out_i in ast_select_columns {
			select_column_id, is_ident := col_expr.value.(^AST_Ident)

			value: Database_Value
			output_key := projection_expr_name(col_expr)
			if is_ident {
				output_key = select_column_id.column_name

				// TODO:  a bunch of hidden assumptions about key strings from result_rows in here...

				// if identifier is unqualified:
				if select_column_id.table_name != "" {
					full_name := ast_ident_as_string(select_column_id)
					column_index_in_row, found_full := slice.linear_search(
						result_rows.column_names,
						full_name,
					)

					if found_full {
						value = row[column_index_in_row]
						output_key = full_name
					} else if !has_joins && select_column_id.table_name == base_table_name {
						if slice.contains(result_rows.column_names, select_column_id.column_name) {
							// if there are no joins and table matches with the base table, keep the result without the table name
							column_index, column_index_found := slice.linear_search(
								result_rows.column_names,
								select_column_id.column_name,
							)
							if !column_index_found {
								db_msgf_at(
									.Error,
									select_column_id.token,
									"Column '%v' not found in table '%v'",
									select_column_id.column_name,
									result_rows.column_names,
								)
								return
							}

							value = row[column_index]
							output_key = select_column_id.column_name
						} else {
							db_msgf_at(
								.Error,
								select_column_id.token,
								"Unknown column '%v' in table '%v'",
								select_column_id.column_name,
								select_column_id.table_name,
							)
							return
						}
					} else {
						db_msgf_at(
							.Error,
							select_column_id.token,
							"Unknown table '%v' in column identifier '%v'",
							select_column_id.table_name,
							select_column_id.column_name,
						)
						return
					}
				} else if has_joins {
					// If column identifier has no table name attached (it's unqualified) and there are +1 join tables involved, we need to find the matching table for this column name (after the fact) since it is ambiguous to which table this column name refers to.
					// (This should only be valid if we're selecting from subqueries?)
					qualified_column_name_candidates := make(
						[dynamic]string,
						database_query_allocator,
					)

					for result_rows in result_rows.column_names {
						suffix := fmt.tprintf(".%s", select_column_id.column_name)
						is_qualified := strings.has_suffix(result_rows, suffix)
						if is_qualified {
							append(&qualified_column_name_candidates, result_rows)
						}
					}

					switch {
					case len(qualified_column_name_candidates) > 1:
						tables := make([dynamic]string, database_query_allocator)

						for key in qualified_column_name_candidates {
							// FIXME: splitting into parts to get table name is terrible, just keep the table name explicitly (in result rows we get into this proc as an arg)...
							parts := strings.split(key, ".", database_query_allocator)
							if len(parts) > 0 {
								append(&tables, parts[0])
							}
						}

						msgf(
							.Error,
							.Database,
							"Column '%s' is ambiguous between tables: %v",
							select_column_id.column_name,
							tables,
						)
						return

					case len(qualified_column_name_candidates) == 1:
						result_rows_column_index, _ := slice.linear_search(
							result_rows.column_names,
							qualified_column_name_candidates[0],
						)
						value = row[result_rows_column_index]

					case:
						db_msgf_at(
							.Error,
							select_column_id.token,
							"Unknown column '%v'",
							select_column_id.column_name,
						)
						return
					}
				} else if slice.contains(result_rows.column_names, select_column_id.column_name) {
					// TODO: double search, unnecesary
					column_index, _ := slice.linear_search(
						result_rows.column_names,
						select_column_id.column_name,
					)
					value = row[column_index]
				} else {
					db_msgf_at(
						.Error,
						select_column_id.token,
						"Unknown column '%v'",
						select_column_id.column_name,
					)
					return
				}
			} else {
				// Non-identifier projections (e.g. SELECT 1, SELECT age > 18) are evaluated per row.
				evaluated := evaluate_term_bound(col_expr, row[:]) or_return
				scalar_value, scalar_ok := evaluated.(Database_Value)
				if !scalar_ok {
					db_msgf_at(
						.Error,
						col_expr.token,
						"SELECT expression '%v' must evaluate to a scalar value",
						col_expr.token.text,
					)
					return
				}
				value = scalar_value
			}

			output_column_names[out_i] = output_key
			filtered_row[out_i] = value
		}
		append(&all_filtered_rows, filtered_row)
	}

	rows = Rows_With_Names {
		column_names = output_column_names,
		rows         = all_filtered_rows,
	}

	return rows, true
}

// Binds identifiers inside an expression tree to column slots in a result row.
bind_expression_slots_to_row_columns :: proc(
	node: ^AST_Node,
	column_names: []string,
	has_joins: bool,
	base_table_name: string,
) -> bool {
	#partial switch value in node.value {
	case ^AST_Ident:
		if value.column_name == "*" do return true

		if value.table_name != "" {
			full_name := ast_ident_as_string(value)
			slot_id, found_full := slice.linear_search(column_names, full_name)
			if found_full {
				value.slot_id = slot_id
				return true
			}
			if !has_joins && value.table_name == base_table_name {
				slot_id, found_col := slice.linear_search(column_names, value.column_name)
				if !found_col {
					db_msgf_at(
						.Error,
						value.token,
						"Unknown column '%v' in table '%v'",
						value.column_name,
						value.table_name,
					)
					return false
				}
				value.slot_id = slot_id
				return true
			}
			db_msgf_at(
				.Error,
				value.token,
				"Unknown table '%v' in column identifier '%v'",
				value.table_name,
				value.column_name,
			)
			return false
		}

		slot_id, found := slice.linear_search(column_names, value.column_name)
		if found {
			value.slot_id = slot_id
			return true
		}
		if has_joins {
			match_slot := -1
			suffix := fmt.tprintf(".%s", value.column_name)
			for col_name, i in column_names {
				strings.has_suffix(col_name, suffix) or_continue
				if match_slot >= 0 {
					db_msgf_at(
						.Error,
						value.token,
						"Column '%v' is ambiguous between joined tables",
						value.column_name,
					)
					return false
				}
				match_slot = i
			}
			if match_slot >= 0 {
				value.slot_id = match_slot
				return true
			}
		}
		db_msgf_at(.Error, value.token, "Unknown column '%v'", value.column_name)
		return false
	case ^Condition:
		bind_expression_slots_to_row_columns(
			value.a,
			column_names,
			has_joins,
			base_table_name,
		) or_return
		return bind_expression_slots_to_row_columns(
			value.b,
			column_names,
			has_joins,
			base_table_name,
		)
	case ^Unary_Expression:
		return bind_expression_slots_to_row_columns(
			value.operand,
			column_names,
			has_joins,
			base_table_name,
		)
	case ^Binary_Expression:
		bind_expression_slots_to_row_columns(
			value.a,
			column_names,
			has_joins,
			base_table_name,
		) or_return
		return bind_expression_slots_to_row_columns(
			value.b,
			column_names,
			has_joins,
			base_table_name,
		)
	case ^AST_Aggregate_Call:
		for arg in value.args {
			bind_expression_slots_to_row_columns(
				arg,
				column_names,
				has_joins,
				base_table_name,
			) or_return
		}
		return true
	case [dynamic]^AST_Node:
		for child in value {
			bind_expression_slots_to_row_columns(
				child,
				column_names,
				has_joins,
				base_table_name,
			) or_return
		}
		return true
	case:
		return true
	}
}

// Builds the display/output name for a projected expression.
projection_expr_name :: proc(expr: ^AST_Node) -> string {
	assert(expr != nil)
	if expr.source_text != "" do return expr.source_text

	#partial switch value in expr.value {
	case ^AST_Ident:
		return ast_ident_as_string(value)
	case ^Unary_Expression:
		// Keep unary expressions compact so generated names match SQL intent (e.g. NOTactive, -id).
		return fmt.tprintf(
			"%s%s",
			projection_expr_name(value.op),
			projection_expr_name(value.operand),
		)
	case ^Binary_Expression:
		// Preserve operator-based shape so computed projection columns stay human-readable.
		return fmt.tprintf(
			"%s%s%s",
			projection_expr_name(value.a),
			projection_expr_name(value.op),
			projection_expr_name(value.b),
		)
	case ^Condition:
		return fmt.tprintf(
			"%s%s%s",
			projection_expr_name(value.a),
			projection_expr_name(value.op),
			projection_expr_name(value.b),
		)
	case ^AST_Aggregate_Call:
		if len(value.args) == 0 {
			return fmt.tprintf("%v()", value.name)
		}
		if len(value.args) == 1 {
			return fmt.tprintf("%v(%v)", value.name, projection_expr_name(value.args[0]))
		}
		return fmt.tprintf("%v(%v)", value.name, len(value.args))
	case ^AST_String:
		return value.text
	case ^AST_Int:
		return fmt.tprintf("%v", value.int)
	case ^AST_Float:
		return fmt.tprintf("%v", value.float)
	case bool:
		return fmt.tprintf("%v", value)
	case nil:
		return "NULL"
	case:
		return expr.token.text
	}
}

// Executes INSERT, evaluating value expressions and inserting each requested row.
exec_insert :: proc(insert: ^Insert) -> (count: int, ok: bool) {
	table_ident, table_ident_ok := insert.table.value.(^AST_Ident)
	if !table_ident_ok {
		db_msgf_at(.Error, insert.token, "Invalid table name")
		return
	}

	if table_ident.table_name != "" {
		db_msgf_at(
			.Error,
			insert.table.token,
			"Invalid table name: %v.%v",
			table_ident.table_name,
			table_ident.column_name,
		)
		return
	}

	table_name := table_ident.column_name
	table := database_find_table(table_name, log_error = true) or_return

	table_storage_ensure(table)

	rows_inserted := 0

	for value_list in insert.value_lists {
		new_row := make_dynamic_array_len(
			[dynamic]Database_Value,
			len(table.column_names),
			database_query_allocator,
		)

		if len(insert.specified_columns) > 0 {
			if len(insert.specified_columns) != len(value_list) {
				db_msgf_at(
					.Error,
					insert.token,
					"Column count (%v) doesn't match value count (%v)",
					len(insert.specified_columns),
					len(value_list),
				)
				return
			}

			for i := 0; i < len(insert.specified_columns); i += 1 {
				col_node := insert.specified_columns[i]
				val_node := value_list[i]

				col_ident, col_ok := col_node.value.(^AST_Ident)
				if !col_ok {
					db_msgf_at(.Error, col_node.token, "Expected column to be Ident")
					return
				}
				col_name := col_ident.column_name

				// FIXME: this is only requrired for arithmetic etc, so how about making a special proc for limited evaluation? or at least a boolean flag.
				// val := evaluate_term_bound(val_node, {}) or_return
				val := evaluate_term_bound(val_node, {}) or_return

				cell_val, cell_ok := val.(Database_Value)
				if !cell_ok {
					db_msgf_at(
						.Error,
						val_node.token,
						"Expected term to evaluate to Cell, got %v",
						val,
					)
					return
				}

				col_index, col_index_found := slice.linear_search(table.column_names[:], col_name)
				if !col_index_found {
					db_msgf_at(
						.Error,
						col_node.token,
						"Column '%v' not found in table '%v'",
						col_name,
						table.name,
					)
					return
				}

				new_row[col_index] = cell_val
			}
		} else {
			if len(table.column_names) != len(value_list) {
				db_msgf_at(
					.Error,
					insert.token,
					"Column count (%v) doesn't match value count (%v)",
					len(table.column_names),
					len(value_list),
				)
				return
			}

			for i := 0; i < len(table.column_names); i += 1 {
				col_name := table.column_names[i]
				val_node := value_list[i]

				// we don't pass a row here because insertion is not supposed to use the row values
				// FIXME: why not?
				val := evaluate_term_bound(val_node, {}) or_return

				cell_val, cell_ok := val.(Database_Value)
				if !cell_ok {
					db_msgf_at(.Error, val_node.token, "Unexpected term result: %v", val)
					return
				}

				column_index, _ := slice.linear_search(table.column_names[:], col_name)
				new_row[column_index] = cell_val
			}
		}

		primary_key_value := new_row[table.primary_key_column_index]
		if primary_key_value == nil {
			db_msgf_at(
				.Error,
				insert.token,
				"Primary key value for column '%v' must be provided and cannot be NULL",
				table.primary_key_column_index,
			)
			return
		}

		prev_len := table_row_count(table)
		if !database_insert_row(table, table.column_names[:], new_row[:]) {
			return
		}
		assert(table_row_count(table) == prev_len + 1)
		rows_inserted += 1
	}

	return rows_inserted, true
}

// Executes UPDATE, preserving primary and secondary index consistency.
exec_update :: proc(update: ^Update) -> (count: int, ok: bool) {
	table_ident, ident_ok := update.table.value.(^AST_Ident)
	if !ident_ok {
		db_msgf_at(.Error, update.token, "Invalid table name: '%v'", update.table.value)
		return
	}
	table_name := table_ident.column_name

	table := database_find_table(table_name, log_error = true) or_return

	table_storage_ensure(table)
	pk_tree := table_primary_unique_tree_ptr(table)
	if pk_tree == nil {
		db_msgf_at(.Error, update.token, "Table '%v' has no primary index", table.name)
		return 0, false
	}
	rows_updated := 0

	keys_to_update := make([dynamic]Database_Value, database_query_allocator)

	for set_clause in update.set_clauses {
		bind_expression_slots_to_row_columns(
			set_clause.value,
			table.column_names[:],
			false,
			table_name,
		) or_return
	}

	if where_clause, has_where := update.where_clause.?; has_where {
		bind_expression_slots_to_row_columns(
			where_clause,
			table.column_names[:],
			false,
			table_name,
		) or_return
		pk_plan, pk_ok := analyze_pk_where_for_table(where_clause, table, table_name)
		if pk_ok {
			collect_pk_keys_from_plan(table, pk_plan, &keys_to_update)
			if pk_plan.residual_where {
				filtered_keys := make([dynamic]Database_Value, database_query_allocator)
				for k in keys_to_update {
					row_ref, row_ok := index_tree_unique_find(pk_tree, k)
					if !row_ok do continue
					row, row_found := table_get_row(table, row_ref)
					if !row_found do continue
					if evaluate_expression_bound(where_clause, row[:]) or_return {
						append(&filtered_keys, k)
					}
				}
				keys_to_update = filtered_keys
			}
		} else {
			for row_i in Row_Index(0) ..< Row_Index(table_row_count(table)) {
				row, row_ok := table_get_row(table, row_i)
				if !row_ok do continue
				should_update := evaluate_expression_bound(where_clause, row[:]) or_return
				if should_update {
					append(&keys_to_update, row[table.primary_key_column_index])
				}
			}
		}
	} else {
		for row_i in Row_Index(0) ..< Row_Index(table_row_count(table)) {
			row := table_get_row(table, row_i) or_continue
			append(&keys_to_update, row[table.primary_key_column_index])
		}
	}

	for key in keys_to_update {
		row_index := index_tree_unique_find(pk_tree, key) or_continue
		row, row_ok := table_get_row(table, row_index)
		if !row_ok do continue
		old_row := make(Table_Row, len(row), database_query_allocator)
		copy(old_row[:], row[:])
		working_row := make(Table_Row, len(row), database_query_allocator)
		copy(working_row[:], row[:])

		for set_clause in update.set_clauses {
			ident_node := set_clause.column
			term_node := set_clause.value

			col_ident, col_ident_ok := ident_node.value.(^AST_Ident)
			if !col_ident_ok {
				db_msgf_at(.Error, ident_node.token, "Expected column to be Ident")
				return 0, false
			}
			column_name := col_ident.column_name

			found := false
			for col in table.column_names {
				if col == column_name {
					found = true
					break
				}
			}
			if !found {
				db_msgf_at(
					.Error,
					ident_node.token,
					"Column '%v' does not exist in table '%v'",
					column_name,
					table_name,
				)
				return 0, false
			}

			new_value := evaluate_term_bound(term_node, row[:]) or_return
			cell_val, cell_ok := new_value.(Database_Value)
			if !cell_ok {
				db_msgf_at(.Error, term_node.token, "Unexpected term result: %v", new_value)
				return 0, false
			}

			column_index, _ := slice.linear_search(table.column_names[:], column_name)
			working_row[column_index] = cell_val
		}

		new_primary_key := working_row[table.primary_key_column_index]
		if violation_col, has_violation := table_not_null_violation_column_index(
			table,
			working_row,
		); has_violation {
			db_msgf_at(
				.Error,
				update.token,
				"Column '%v' in table '%v' cannot be NULL during UPDATE",
				table.column_names[violation_col],
				table.name,
			)
			return 0, false
		}
		if new_primary_key == nil {
			db_msgf_at(
				.Error,
				update.token,
				"Primary key value for column '%v' must be provided and cannot be NULL",
				table.primary_key_column_index,
			)
			return 0, false
		}

		old_primary_key := old_row[table.primary_key_column_index]

		if !value_exactly_equal(old_primary_key, new_primary_key) {
			if index_tree_unique_contains(pk_tree, new_primary_key) {
				db_msgf_at(
					.Error,
					update.token,
					"Primary key value already exists in table '%v'",
					table.name,
				)
				return 0, false
			}

			if !index_tree_unique_remove_key(pk_tree, old_primary_key) {
				db_msgf_at(
					.Error,
					update.token,
					"Failed to remove row while updating table '%v'",
					table.name,
				)
				return 0, false
			}

			index_tree_unique_insert(
				table.name,
				pk_tree,
				new_primary_key,
				Row_Index(row_index),
			) or_return
		}

		for &idx in table.indexes {
			if idx.is_primary {
				continue
			}
			old_key := old_row[idx.column_index]
			new_key := working_row[idx.column_index]
			if value_exactly_equal(old_key, new_key) {
				continue
			}
			if !index_non_unique_remove_row_ref(&idx, old_key, Row_Index(row_index)) {
				db_msgf_at(
					.Error,
					update.token,
					"Failed to remove old key from index '%v'",
					idx.name,
				)
				return 0, false
			}
			if !index_non_unique_insert_row_ref(&idx, new_key, Row_Index(row_index)) {
				db_msgf_at(
					.Error,
					update.token,
					"Failed to insert new key into index '%v'",
					idx.name,
				)
				return 0, false
			}
		}
		if !table_set_row(table, row_index, working_row) {
			db_msgf_at(
				.Error,
				update.token,
				"Failed to write updated row into table '%v'",
				table.name,
			)
			return 0, false
		}

		rows_updated += 1
	}

	return rows_updated, true
}

// Removes an element by swapping in the last dynamic-array element.
dynamic_array_unoredered_remove :: proc(dynamic_array: ^[dynamic]$T, index: int) {
	da := dynamic_array^
	last := len(da) - 1
	da[index] = da[last]
	resize(dynamic_array, last)
}

// Removes the row at index; keeps row-ref indexes stable via swap-with-last semantics.
// Deletes one table row and keeps primary plus secondary row refs synchronized.
database_delete_row_at :: proc(table: ^Table, row_index: Row_Index) -> bool {
	pk_tree := table_primary_unique_tree_ptr(table)
	row_to_delete, moved_row, moved_from, moved, remove_ok := table_delete_row_unordered(
		table,
		row_index,
	)
	if !remove_ok {
		return false
	}
	pk_ix := table.primary_key_column_index
	del_pk := row_to_delete[pk_ix]

	if !table_indexes_remove_row_non_primary(table, row_to_delete, Row_Index(row_index)) {
		return false
	}

	if !index_tree_unique_remove_key(pk_tree, del_pk) {
		msgf(.Error, .Database, "Failed to remove primary key from tree for delete")
		return false
	}
	if moved {
		moved_pk := moved_row[pk_ix]
		index_tree_unique_repoint(pk_tree, moved_pk, Row_Index(row_index))
		if !table_indexes_repoint_row_non_primary(
			table,
			moved_row,
			Row_Index(moved_from),
			Row_Index(row_index),
		) {
			return false
		}
	}
	delete(row_to_delete)
	return true
}

// Executes DELETE by collecting matching primary keys before mutating table storage.
exec_delete :: proc(delete_stmt: ^Delete) -> (count: int, ok: bool) {
	table_ident, ident_ok := delete_stmt.table.value.(^AST_Ident)
	if !ident_ok {
		db_msgf_at(.Error, delete_stmt.token, "Expected table to be Ident")
		return
	}
	table_name := table_ident.column_name
	table := database_find_table(table_name, log_error = true) or_return

	table_storage_ensure(table)
	pk_tree := table_primary_unique_tree_ptr(table)
	rows_deleted := 0

	keys_to_delete := make([dynamic]Database_Value, allocator = database_query_allocator)

	if where_clause, has_where := delete_stmt.where_clause.?; has_where {
		if !bind_expression_slots_to_row_columns(
			where_clause,
			table.column_names[:],
			false,
			table_name,
		) {
			return 0, false
		}
		pk_plan, pk_ok := analyze_pk_where_for_table(where_clause, table, table_name)
		if pk_ok {
			collect_pk_keys_from_plan(table, pk_plan, &keys_to_delete)
			if pk_plan.residual_where {
				filtered := make([dynamic]Database_Value, allocator = database_query_allocator)
				for k in keys_to_delete {
					row_ref, row_ok := index_tree_unique_find(pk_tree, k)
					if !row_ok do continue
					row, row_found := table_get_row(table, row_ref)
					if !row_found do continue
					if evaluate_expression_bound(where_clause, row[:]) or_return {
						append(&filtered, k)
					}
				}
				keys_to_delete = filtered
			}
		} else {
			for row_i in Row_Index(0) ..< Row_Index(table_row_count(table)) {
				row, row_ok := table_get_row(table, row_i)
				if !row_ok do continue
				if evaluate_expression_bound(where_clause, row[:]) or_return {
					append(&keys_to_delete, row[table.primary_key_column_index])
				}
			}
		}
	} else {
		for row_i in Row_Index(0) ..< Row_Index(table_row_count(table)) {
			row, row_ok := table_get_row(table, row_i)
			if !row_ok do continue
			append(&keys_to_delete, row[table.primary_key_column_index])
		}
	}

	for k in keys_to_delete {
		row_ref, row_ok := index_tree_unique_find(pk_tree, k)
		if !row_ok do continue
		if database_delete_row_at(table, row_ref) {
			rows_deleted += 1
		}
	}

	return rows_deleted, true
}

// Builds and attaches a secondary index, backfilling refs for existing rows.
table_add_non_primary_index :: proc(table: ^Table, index_name: string, column_index: int) -> bool {
	new_index := Table_Index {
		name         = index_name,
		column_index = column_index,
		is_primary   = false,
		tree         = Index_Tree_Non_Unique{},
	}
	for row_idx in Row_Index(0) ..< Row_Index(table_row_count(table)) {
		row, row_ok := table_get_row(table, row_idx)
		if !row_ok do continue
		if !index_non_unique_insert_row_ref(&new_index, row[column_index], Row_Index(row_idx)) {
			return false
		}
	}

	append(&table.indexes, new_index)
	return true
}

// Executes CREATE INDEX after validating table, index name, and target column.
exec_create_index :: proc(create_index: ^Create_Index) -> bool {
	table := database_find_table(create_index.table_name, log_error = true) or_return
	if _, exists := index_find_by_name(table, create_index.index_name); exists {
		db_msgf_at(
			.Error,
			create_index.token,
			"Index '%v' already exists on table '%v'",
			create_index.index_name,
			create_index.table_name,
		)
		return false
	}

	column_index, found := slice.linear_search(table.column_names[:], create_index.column_name)
	if !found {
		db_msgf_at(
			.Error,
			create_index.token,
			"Column '%v' does not exist in table '%v'",
			create_index.column_name,
			create_index.table_name,
		)
		return false
	}

	if column_index == table.primary_key_column_index {
		db_msgf_at(
			.Error,
			create_index.token,
			"Column '%v' is already indexed by the primary key",
			create_index.column_name,
		)
		return false
	}

	return table_add_non_primary_index(table, create_index.index_name, column_index)
}

// Carries only the index data that survives a table rebuild.
// We snapshot these definitions before destroying the old table, then replay
// them after rows are reinserted into the rebuilt schema.
Secondary_Index_Definition :: struct {
	name:         string,
	column_index: int,
}

// Captures non-primary indexes from the current table in a rebuild-friendly form.
// If a column is being dropped, this also remaps index column positions so replay
// uses the post-drop schema. Returning ok=false signals an index pointed at the
// dropped column, so the caller can fail instead of silently losing index intent.
// Returns the secondary-index definitions that should be replayed after ALTER.
table_secondary_index_definitions :: proc(
	table: ^Table,
	dropped_column_index: Maybe(int),
) -> (
	result: [dynamic]Secondary_Index_Definition,
	ok: bool,
) {
	result = make([dynamic]Secondary_Index_Definition, database_query_allocator)
	for idx in table.indexes {
		if idx.is_primary {
			continue
		}
		column_index := idx.column_index
		if drop_col, has_drop_col := dropped_column_index.?; has_drop_col {
			if column_index == drop_col {
				return nil, false
			}
			if column_index > drop_col {
				column_index -= 1
			}
		}
		append(&result, Secondary_Index_Definition{name = idx.name, column_index = column_index})
	}
	return result, true
}

// Recreates a table from a prepared target schema and row set.
// This is the common path for schema mutations where in-place edits are riskier
// than rebuild-and-replay (drop/rename/change column layout, etc.).
// The proc destroys the old table, initializes the new shape, reinserts rows,
// then restores secondary indexes to keep behavior consistent after the rebuild.
// Rebuilds a table using caller-owned schema buffers and a temp row snapshot.
table_rebuild_with_schema :: proc(
	table: ^Table,
	new_column_names: [dynamic]string,
	new_column_types: [dynamic]Maybe(Database_Column_Type), // TODO: column types shouldnt be optional.
	new_column_not_null: [dynamic]bool,
	new_primary_key_column_index: int,
	new_rows: [dynamic]Table_Row,
	secondary_indexes: [dynamic]Secondary_Index_Definition,
	keep_columnar_storage: bool,
) -> bool {
	// `exec_alter_table` fills `new_column_names` with `append_elems(..table.column_names[:])` — those
	// entries alias the same allocations as `table.column_names`. `table_destroy` frees those strings,
	// so we must snapshot independent copies before destroy (same for `table.name`).
	// TODO: consider just setting needs_to_dealloc_strings to false, so we dont need to copy the strings
	table_name_owned := strings.clone(table.name, context.allocator)
	column_names_owned := make([dynamic]string, 0, len(new_column_names), context.allocator)
	for col in new_column_names {
		append(&column_names_owned, strings.clone(col, context.allocator))
	}
	// `table_init` takes `column_names_owned`, not this buffer - it only aliased old table names until clone.
	delete(new_column_names)
	table_destroy(table)
	table_init(
		table,
		table_name_owned,
		column_names_owned,
		new_primary_key_column_index,
		column_types = new_column_types,
		column_not_null = new_column_not_null,
	)
	table.needs_to_dealloc_strings = true
	if keep_columnar_storage {
		table.storage = make([dynamic]Column_Chunks, context.allocator)
	}

	row_values := make([dynamic]Database_Value, allocator = database_query_allocator)
	for row in new_rows {
		resize(&row_values, len(row))
		for value, i in row {
			row_values[i] = value
		}
		if !database_insert_row(table, table.column_names[:], row_values[:]) {
			return false
		}
	}

	for idx in secondary_indexes {
		if !table_add_non_primary_index(table, idx.name, idx.column_index) {
			return false
		}
	}
	return true
}

// Executes ALTER TABLE by snapshotting rows, editing schema, and rebuilding safely.
exec_alter_table :: proc(alter_table: ^Alter_Table) -> bool {
	table := database_find_table(alter_table.table_name, log_error = true) or_return

	keep_columnar_storage := false
	#partial switch storage in table.storage {
	case [dynamic]Column_Chunks:
		keep_columnar_storage = true
	case:
		_ = storage
	}

	column_index, has_column := slice.linear_search(table.column_names[:], alter_table.column_name)
	row_count := table_row_count(table)
	rows := make([dynamic]Table_Row, 0, row_count, database_query_allocator)
	for row_i in Row_Index(0) ..< Row_Index(row_count) {
		row, row_ok := table_get_row(table, row_i)
		if !row_ok {
			return false
		}
		// Snapshot must own its own row buffers. `table_get_row` on row-storage returns
		// headers into table-owned memory, and ALTER destroys the table before replay.
		row_copy := make(Table_Row, len(row), database_query_allocator)
		copy(row_copy[:], row[:])
		append(&rows, row_copy)
	}

	new_column_names := make([dynamic]string, 0, len(table.column_names), context.allocator)
	append_elems(&new_column_names, ..table.column_names[:])
	new_column_types := make(
		[dynamic]Maybe(Database_Column_Type),
		0,
		len(table.column_types),
		context.allocator,
	)
	append_elems(&new_column_types, ..table.column_types[:])
	new_column_not_null := make([dynamic]bool, 0, len(table.column_not_null), context.allocator)
	append_elems(&new_column_not_null, ..table.column_not_null[:])
	new_primary_key_column_index := table.primary_key_column_index
	schema_handed_off := false
	defer {
		// These buffers are owned locally until table rebuild takes ownership.
		if !schema_handed_off {
			delete(new_column_names)
			delete(new_column_types)
			delete(new_column_not_null)
		}
	}

	dropped_column_index: Maybe(int) = nil
	switch alter_table.operation {
	case .Add_Column:
		if _, exists := slice.linear_search(new_column_names[:], alter_table.column_name); exists {
			db_msgf_at(
				.Error,
				alter_table.token,
				"Column '%v' already exists in table '%v'",
				alter_table.column_name,
				alter_table.table_name,
			)
			return false
		}
		if keep_columnar_storage {
			_, has_declared_type := alter_table.column_type.?
			if !has_declared_type {
				db_msgf_at(
					.Error,
					alter_table.token,
					"ALTER TABLE ADD COLUMN on columnar table '%v' requires an explicit column type",
					alter_table.table_name,
				)
				return false
			}
		}
		if alter_table.column_not_null && len(rows) > 0 {
			db_msgf_at(
				.Error,
				alter_table.token,
				"Cannot add NOT NULL column '%v' to non-empty table '%v' without backfilling values",
				alter_table.column_name,
				alter_table.table_name,
			)
			return false
		}
		append(&new_column_names, alter_table.column_name)
		append(&new_column_types, alter_table.column_type)
		append(&new_column_not_null, alter_table.column_not_null)
		for &row in rows {
			append(&row, Database_Value{})
		}
	case .Drop_Column:
		if !has_column {
			db_msgf_at(
				.Error,
				alter_table.token,
				"Column '%v' does not exist in table '%v'",
				alter_table.column_name,
				alter_table.table_name,
			)
			return false
		}
		if len(new_column_names) <= 1 {
			db_msgf_at(
				.Error,
				alter_table.token,
				"Cannot drop the last column from table '%v'",
				alter_table.table_name,
			)
			return false
		}
		if column_index == table.primary_key_column_index {
			db_msgf_at(
				.Error,
				alter_table.token,
				"Cannot drop primary key column '%v' from table '%v'",
				alter_table.column_name,
				alter_table.table_name,
			)
			return false
		}
		delete(new_column_names)
		delete(new_column_types)
		delete(new_column_not_null)
		new_column_names = make([dynamic]string, 0, len(table.column_names) - 1, context.allocator)
		new_column_types = make(
			[dynamic]Maybe(Database_Column_Type),
			0,
			len(table.column_types) - 1,
			context.allocator,
		)
		new_column_not_null = make(
			[dynamic]bool,
			0,
			len(table.column_not_null) - 1,
			context.allocator,
		)
		for old_i := 0; old_i < len(table.column_names); old_i += 1 {
			if old_i == column_index {
				continue
			}
			append(&new_column_names, table.column_names[old_i])
			append(&new_column_types, table.column_types[old_i])
			append(&new_column_not_null, table.column_not_null[old_i])
		}
		if column_index < new_primary_key_column_index {
			new_primary_key_column_index -= 1
		}
		for row_i := 0; row_i < len(rows); row_i += 1 {
			row := rows[row_i]
			new_row := make(Table_Row, 0, len(row) - 1, database_query_allocator)
			for old_i := 0; old_i < len(table.column_names); old_i += 1 {
				if old_i == column_index {
					continue
				}
				append(&new_row, row[old_i])
			}
			rows[row_i] = new_row
		}
		dropped_column_index = column_index
	case .Rename_Column:
		if !has_column {
			db_msgf_at(
				.Error,
				alter_table.token,
				"Column '%v' does not exist in table '%v'",
				alter_table.column_name,
				alter_table.table_name,
			)
			return false
		}
		if _, exists := slice.linear_search(
			new_column_names[:],
			alter_table.rename_to_column_name,
		); exists {
			db_msgf_at(
				.Error,
				alter_table.token,
				"Column '%v' already exists in table '%v'",
				alter_table.rename_to_column_name,
				alter_table.table_name,
			)
			return false
		}
		new_column_names[column_index] = alter_table.rename_to_column_name
	}

	secondary_indexes, indexes_ok := table_secondary_index_definitions(table, dropped_column_index)
	if !indexes_ok {
		db_msgf_at(
			.Error,
			alter_table.token,
			"Cannot drop column '%v' because it has a secondary index",
			alter_table.column_name,
		)
		return false
	}

	schema_handed_off = true
	return table_rebuild_with_schema(
		table,
		new_column_names,
		new_column_types,
		new_column_not_null,
		new_primary_key_column_index,
		rows,
		secondary_indexes,
		keep_columnar_storage,
	)
}

// Executes DROP TABLE, honoring IF EXISTS and compacting the active table array.
exec_drop_table :: proc(drop_table: ^Drop_Table) -> bool {
	tables, count := database_active_tables_and_count_ptr()
	table_index := -1
	for i := 0; i < count^; i += 1 {
		if tables^[i].name == drop_table.table_name {
			table_index = i
			break
		}
	}

	if table_index < 0 {
		if drop_table.if_exists {
			return true
		}
		db_msgf_at(.Error, drop_table.token, "Table '%v' does not exist", drop_table.table_name)
		return false
	}

	table_destroy(&tables^[table_index])
	for i := table_index; i < count^ - 1; i += 1 {
		tables^[i] = tables^[i + 1]
	}
	count^ -= 1
	return true
}

// Executes CREATE TABLE and installs the initialized table into the active set.
exec_create_table :: proc(create_table: ^Create_Table) -> bool {
	if _, ok := database_find_table(create_table.table_name, log_error = false); ok {
		db_msgf_at(
			.Error,
			create_table.token,
			"Table '%v' already exists",
			create_table.table_name,
		)
		return false
	}

	primary_key, has_pk := create_table.primary_key.?
	if !has_pk {
		db_msgf_at(
			.Error,
			create_table.token,
			"Table '%v' must have a PRIMARY KEY defined",
			create_table.table_name,
		)
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
		db_msgf_at(
			.Error,
			create_table.token,
			"Primary key column '%v' not found in table columns",
			primary_key,
		)
		return false
	}

	if len(create_table.column_types) != len(create_table.columns) {
		db_msgf_at(.Error, create_table.token, "CREATE TABLE column type metadata is corrupted")
		return false
	}
	if len(create_table.column_not_null) != len(create_table.columns) {
		db_msgf_at(.Error, create_table.token, "CREATE TABLE NOT NULL metadata is corrupted")
		return false
	}

	// table: Table
	// table.name = table_name
	// table.column_names = make([dynamic]string, len(create_table.columns), allocator = allocator)
	// for col, i in create_table.columns {
	// 	table.column_names[i] = col
	// }
	// table.primary_key_column_index, _ = slice.linear_search(table.column_names[:], primary_key)
	// Keep CREATE TABLE column order exact, because PK lookup and row mapping
	// assume these indexes stay stable across parsing and execution.
	column_names := make([dynamic]string, 0, len(create_table.columns), context.allocator)
	for col in create_table.columns {
		append(&column_names, strings.clone(col, context.allocator))
	}
	column_types := make(
		[dynamic]Maybe(Database_Column_Type),
		0,
		len(create_table.column_types),
		context.allocator,
	)
	append_elems(&column_types, ..create_table.column_types[:])
	column_not_null := make([dynamic]bool, 0, len(create_table.column_not_null), context.allocator)
	append_elems(&column_not_null, ..create_table.column_not_null[:])

	primary_key_index := -1
	for col, i in column_names {
		if col == primary_key {
			primary_key_index = i
			break
		}
	}
	assert(primary_key_index >= 0)
	column_not_null[primary_key_index] = true

	table: Table
	table_init(
		&table,
		strings.clone(create_table.table_name, context.allocator),
		column_names,
		primary_key_index,
		column_types = column_types,
		column_not_null = column_not_null,
	)
	table.needs_to_dealloc_strings = true
	if create_table.is_columnar {
		table.storage = make([dynamic]Column_Chunks, context.allocator)
	}

	if !database_tables_append(table) {
		return false
	}

	return true
}

// Deep-copies a table's schema, rows, storage mode, and secondary indexes.
table_clone_deep :: proc(source: ^Table) -> (cloned: Table, ok: bool) {
	cloned_built := false
	defer {
		// Failed clone attempts must release partially initialized storage.
		if !cloned_built {
			table_destroy(&cloned)
		}
	}

	// Own copies of all identifier strings. Without this, BEGIN's snapshot shares `name` /
	// column slices with `database_tables`; COMMIT destroys those allocations first and the
	// txn copy becomes use-after-free before we assign it back into `database_tables`.
	column_names := make([dynamic]string, len(source.column_names), context.allocator)
	for col, i in source.column_names {
		column_names[i] = strings.clone(col, context.allocator)
	}
	column_types := make(
		[dynamic]Maybe(Database_Column_Type),
		len(source.column_types),
		context.allocator,
	)
	copy(column_types[:], source.column_types[:])
	column_not_null := make([dynamic]bool, len(source.column_not_null), context.allocator)
	copy(column_not_null[:], source.column_not_null[:])

	table_init(
		&cloned,
		strings.clone(source.name, context.allocator),
		column_names,
		source.primary_key_column_index,
		column_types = column_types,
		column_not_null = column_not_null,
	)
	cloned.needs_to_dealloc_strings = true

	#partial switch storage in source.storage {
	case [dynamic]Column_Chunks:
		cloned.storage = make([dynamic]Column_Chunks, context.allocator)
	case:
		_ = storage
	}

	row_values := make([dynamic]Database_Value, context.allocator)
	defer delete(row_values)
	for row_i in Row_Index(0) ..< Row_Index(table_row_count(source)) {
		source_row, row_ok := table_get_row(source, row_i)
		if !row_ok {
			return {}, false
		}
		resize(&row_values, len(source_row))
		for value, i in source_row {
			row_values[i] = value
		}
		if !database_insert_row(&cloned, cloned.column_names[:], row_values[:]) {
			return {}, false
		}
	}

	for idx in source.indexes {
		if idx.is_primary {
			continue
		}
		// Same aliasing issue as table/column names: index labels must not point into `source`
		// once the committed table may be destroyed during COMMIT.
		if !table_add_non_primary_index(
			&cloned,
			strings.clone(idx.name, context.allocator),
			idx.column_index,
		) {
			return {}, false
		}
	}

	cloned_built = true
	return cloned, true
}

// Releases all allocations owned by a table and clears its struct.
table_destroy :: proc(table: ^Table) {
	if table.needs_to_dealloc_strings {
		delete(table.name, context.allocator)
		for &col in table.column_names {
			delete(col, context.allocator)
		}
	}
	delete(table.column_names)
	delete(table.column_types)
	delete(table.column_not_null)
	switch storage in table.storage {
	case [dynamic]Table_Row:
		rows := storage
		for row in rows {
			delete(row)
		}
		delete(rows)
	case [dynamic]Column_Chunks:
		cols := transmute([dynamic]Column_Chunks)storage
		for col in cols {
			switch typed in col {
			case [dynamic]Column_Chunk(int):
				delete(typed)
			case [dynamic]Column_Chunk(f64):
				delete(typed)
			case [dynamic]Column_Chunk(bool):
				delete(typed)
			case [dynamic]Column_Chunk(Database_String):
				delete(typed)
			}
		}
		delete(cols)
	}
	for &idx in table.indexes {
		index_tree_destroy(&idx.tree)
	}
	delete(table.indexes)
	table^ = {}
}

// Destroys every table in a fixed table set and resets its count.
table_set_destroy_all :: proc(tables: ^[MAX_TABLES]Table, count: ^int) {
	for i := 0; i < count^; i += 1 {
		table_destroy(&tables^[i])
	}
	count^ = 0
}

// Starts a transaction by deep-cloning the committed tables into txn storage.
exec_begin_transaction :: proc() -> bool {
	if txn_active {
		msgf(.Error, .Database, "Cannot BEGIN: transaction is already active")
		return false
	}
	txn_tables_count = 0
	for i := 0; i < database_tables_count; i += 1 {
		cloned, clone_ok := table_clone_deep(&database_tables[i])
		if !clone_ok {
			table_set_destroy_all(&txn_tables, &txn_tables_count)
			return false
		}
		txn_tables[txn_tables_count] = cloned
		txn_tables_count += 1
	}
	txn_active = true
	return true
}

// Commits the transaction copy over the committed table set.
exec_commit_transaction :: proc() -> bool {
	if !txn_active {
		msgf(.Error, .Database, "Cannot COMMIT: no active transaction")
		return false
	}

	table_set_destroy_all(&database_tables, &database_tables_count)
	for i := 0; i < txn_tables_count; i += 1 {
		database_tables[i] = txn_tables[i]
		txn_tables[i] = {}
	}
	database_tables_count = txn_tables_count
	txn_tables_count = 0
	txn_active = false
	return true
}

// Rolls back the transaction copy and returns execution to committed tables.
exec_rollback_transaction :: proc() -> bool {
	if !txn_active {
		msgf(.Error, .Database, "Cannot ROLLBACK: no active transaction")
		return false
	}
	table_set_destroy_all(&txn_tables, &txn_tables_count)
	txn_active = false
	return true
}

// Applies one JOIN to an existing left-side row set.
apply_join :: proc(
	left_rows: Rows_With_Names,
	join: Join,
) -> (
	result_rows: Rows_With_Names,
	ok: bool,
) {
	join_ident, ident_ok := join.table.value.(^AST_Ident)
	if !ident_ok {
		db_msgf_at(.Error, join.token, "Expected join table to be Ident")
		return
	}
	join_table_name := join_ident.column_name
	join_table := database_find_table(join_table_name, log_error = true) or_return

	table_storage_ensure(join_table)

	join_column_names := make([]string, len(join_table.column_names), database_query_allocator)
	for col_name, i in join_table.column_names {
		join_column_names[i] = fmt.tprintf("%s.%s", join_table_name, col_name)
	}

	result_rows = Rows_With_Names {
		column_names = slice.concatenate(
			[][]string{left_rows.column_names, join_column_names},
			database_query_allocator,
		),
		rows         = make([dynamic]Table_Row, database_query_allocator),
	}

	matched_right_rows := make([]bool, table_row_count(join_table), database_query_allocator)

	for left_row in left_rows.rows {
		matched_some := false

		// FIXME: use index tree
		// right_iter := index_tree_iter(...)
		// for right_node, has_right := index_tree_iter_next(&right_iter);
		//     has_right;
		//     right_node, has_right = index_tree_iter_next(&right_iter) {
		for right_i in Row_Index(0) ..< Row_Index(table_row_count(join_table)) {
			right_row, right_ok := table_get_row(join_table, right_i)
			if !right_ok do continue
			// right_row := right_node.value
			potential_joined_row := make([dynamic]Database_Value, database_query_allocator)
			append_elems(&potential_joined_row, ..left_row[:])
			append_elems(&potential_joined_row, ..right_row[:])

			// for left_row_cell, left_row_primary_key in left_row {
			// 	combined_row[left_row_cell] = Table_Cell {
			// 		value = left_row_cell,
			// 	}
			// }

			// for column_value, column_name in right_row {
			// 	// FIXME: tprint or sprint?
			// 	// qualified_name := fmt.aprintf(
			// 	// 	"%s.%s",
			// 	// 	join_table_name,
			// 	// 	column_name,
			// 	// 	allocator = allocator,
			// 	// )
			// 	append(&combined_row, Table_Cell{value = column_value.value})
			// }

			evaluated_ON_expression := evaluate_expression_bound(
				join.condition,
				potential_joined_row[:],
			) or_return

			if evaluated_ON_expression {
				append(&result_rows.rows, potential_joined_row)
				matched_some = true
				if join.join_type == .Right {
					matched_right_rows[right_i] = true
				}
			}
		}

		if join.join_type == .Left && !matched_some {
			joined_row := make([dynamic]Database_Value, database_query_allocator)

			joined_row_len := len(join_table.column_names) + len(left_row)
			reserve(&joined_row, joined_row_len)
			append_elems(&joined_row, ..left_row[:])
			resize(&joined_row, joined_row_len)

			append(&result_rows.rows, joined_row)
		}
	}

	if join.join_type == .Right {
		for right_i in Row_Index(0) ..< Row_Index(table_row_count(join_table)) {
			right_row, right_ok := table_get_row(join_table, right_i)
			if !right_ok do continue
			(!matched_right_rows[right_i]) or_continue

			joined_row := make([dynamic]Database_Value, database_query_allocator)
			joined_row_len := len(left_rows.column_names) + len(right_row)
			reserve(&joined_row, joined_row_len)
			resize(&joined_row, len(left_rows.column_names))
			append_elems(&joined_row, ..right_row[:])
			append(&result_rows.rows, joined_row)
		}
	}

	return result_rows, true
}

// Compares two scalar database values for SQL equality semantics used here.
// TODO: consider removing and use cmp_int, cmp_f64 etc.
value_exactly_equal :: proc(left: Database_Value, right: Database_Value) -> bool {
	switch &l in left {
	case Database_String:
		r := right.(Database_String) or_return
		return database_string_unwrap(l) == database_string_unwrap(r)
	case int:
		r := right.(int) or_return
		return l == r
	case f64:
		r := right.(f64) or_return
		return l == r
	case bool:
		r := right.(bool) or_return
		return l == r
	case nil:
		return right == nil
	}
	return false
}

// @(require_results)
// database_value_expect_int :: proc(
// 	value: Database_Value,
// 	op_token: Token,
// ) -> (
// 	result: int,
// 	ok: bool,
// ) {
// 	result, ok = value.(int)
// 	if !ok do db_msgf_at(.Error, op_token, "Expected an integer, got %T", value)
// 	return
// }

// @(require_results)
// database_value_expect_f64 :: proc(
// 	value: Database_Value,
// 	op_token: Token,
// ) -> (
// 	result: f64,
// 	ok: bool,
// ) {
// 	result, ok = value.(f64)
// 	if !ok do db_msgf_at(.Error, op_token, "Expected a float, got %T", value)
// 	return
// }

// @(require_results)
// database_value_expect_bool :: proc(
// 	value: Database_Value,
// 	op_token: Token,
// ) -> (
// 	result: bool,
// 	ok: bool,
// ) {
// 	result, ok = value.(bool)
// 	if !ok do db_msgf_at(.Error, op_token, "Expected a boolean, got %T", value)
// 	return
// }

// @(require_results)
// database_value_expect_string :: proc(
// 	value: Database_Value,
// 	op_token: Token,
// ) -> (
// 	result: Database_String,
// 	ok: bool,
// ) {
// 	result, ok = value.(Database_String)
// 	if !ok do db_msgf_at(.Error, op_token, "Expected a string, got %T", value)
// 	return
// }

// database_value_greated_than :: proc(
// 	left, right: Database_Value,
// 	op_token: Token,
// ) -> (
// 	result: bool,
// ) {
// 	switch l in left {
// 	case int:
// 		switch r in right {
// 		case int:
// 			return l > r
// 		case f64:
// 			return f64(l) > r
// 		case:
// 			db_msgf_at(.Error, op_token, "Expected a number, got %T", right)
// 			return false
// 		}
// 	case f64:
// 		r := database_value_expect_f64(right, op_token) or_return
// 		return l > r
// 	case:
// 		db_msgf_at(.Error, op_token, "Expected a number, got %T", left)
// 		return false
// 	}
// }

// Evaluates a binary predicate comparison between scalar values.
// TODO: just use the proc that return slice.Ordering
// TODO: avoid unncesarry convertions
binary_operator_evaluate :: proc(
	left, right: Database_Value,
	op_token, right_token: Token,
) -> (
	result: bool,
	ok: bool,
) {
	// SQL predicate comparisons involving NULL evaluate to unknown, which WHERE treats as false.
	if left == nil || right == nil do return false, true

	ordering := value_ordering_evaluate(left, right, right_token) or_return

	#partial switch op_token.kind {
	case .Equals:
		return ordering == .Equal, true
	case .Not_Equals:
		return ordering != .Equal, true
	case .Greater_Than:
		return ordering == .Greater, true
	case .Less_Than:
		return ordering == .Less, true
	case .Gt_Eq:
		return ordering == .Greater || ordering == .Equal, true
	case .Lt_Eq:
		return ordering == .Less || ordering == .Equal, true
	}
	db_msgf_at(.Error, op_token, "Unsupported operator: %v", op_token.text)
	return
}

// TODO: remove, this is coal
// // Converts numeric database values to f64 for arithmetic/comparison operators.
// cell_to_number :: proc(cell: Database_Value) -> (result: f64, ok: bool) {
// 	switch v in cell {
// 	case int:
// 		return f64(v), true
// 	case f64:
// 		return v, true
// 	case Database_String, bool, nil:
// 		msgf(.Error, .Database, "Expected number, got %T", cell)
// 		return
// 	case:
// 		msgf(.Error, .Database, "Expected number, got %T", cell)
// 		return
// 	}
// }

// Evaluates SQL LIKE/NOT LIKE operands after NULL handling.
evaluate_like_operation :: proc(
	left_val: Maybe(Database_Value),
	right_val: Maybe(Database_Value),
) -> (
	result: bool,
	ok: bool,
) {
	left_cell, left_ok := left_val.?
	right_cell, right_ok := right_val.?

	if !left_ok || !right_ok {
		return false, true
	}

	left_str := database_value_tprint(left_cell)
	right_str := database_value_tprint(right_cell)

	matches := simple_like_match(left_str, right_str)

	return matches, true
}

// FIXME: should it use tprint?
// Converts a database value into the temporary string form used by display/LIKE.
database_value_tprint :: proc(cell: Database_Value) -> string {
	switch &v in cell {
	case Database_String:
		return database_string_unwrap(v)
	case int:
		return fmt.aprintf("%d", v, allocator = database_query_allocator)
	case f64:
		return fmt.aprintf("%f", v, allocator = database_query_allocator)
	case bool:
		return fmt.aprintf("%t", v, allocator = database_query_allocator)
	case nil:
		return "NULL"
	}
	unreachable()
}

// Matches a string against the simple SQL LIKE pattern language (% and _).
simple_like_match :: proc(text: string, pattern: string) -> bool {
	ti := 0
	pi := 0

	for pi < len(pattern) && ti < len(text) {
		if pattern[pi] == '%' {
			if pi + 1 >= len(pattern) do return true

			pi += 1
			for ti < len(text) {
				if simple_like_match(text[ti:], pattern[pi:]) do return true
				ti += 1
			}
			return false
		} else if pattern[pi] == '_' {
			ti += 1
			pi += 1
		} else {
			if text[ti] != pattern[pi] do return false
			ti += 1
			pi += 1
		}
	}

	for pi < len(pattern) && pattern[pi] == '%' do pi += 1

	return ti == len(text) && pi == len(pattern)
}

// TODO: consider having a distint type for EVALUATED TERMS
// TODO: use distinct types for all the the things
Eval_Term_Result :: union {
	Database_Value,
	bool, // TODO: document what this represents exactly
	[dynamic]Table_Row, // TODO: document what this represents exactly
	[dynamic]^AST_Node, // TODO: document what this is exactly
	Rows_With_Names, // TODO: document what this represents exactly
}

// Coerces an evaluated term result into a scalar value for predicate operators.
// TODO: confusing name, there is no evaluation going on. same for some other procs with `eval/uate` in their name.
eval_term_result_as_database_value :: proc(
	value: Eval_Term_Result,
	op_token: Token,
) -> (
	cell: Database_Value,
	ok: bool,
) {
	switch v in value {
	case Database_Value:
		return v, true
	case bool:
		// TODO: panic, this bool is not a database value...
		return Database_Value(v), true
	case [dynamic]Table_Row, [dynamic]^AST_Node, Rows_With_Names:
		db_msgf_at(.Error, op_token, "Expression term is not a scalar value")
		return nil, false
	}
	unreachable()
}

// Evaluates arithmetic binary expressions and preserves integer results when possible.
evaluate_binary_expression_bound :: proc(
	binary: ^Binary_Expression,
	row: []Database_Value,
) -> (
	result: Database_Value,
	ok: bool,
) {
	left_eval := evaluate_term_bound(binary.a, row) or_return
	right_eval := evaluate_term_bound(binary.b, row) or_return

	left_val, left_ok := left_eval.(Database_Value)
	right_val, right_ok := right_eval.(Database_Value)
	if !left_ok || !right_ok {
		db_msgf_at(.Error, binary.token, "Arithmetic expression expects scalar operands")
		return
	}

	// left_num := cell_to_number(left_val) or_return
	// right_num := cell_to_number(right_val) or_return
	// op_kind := binary.op.token.kind

	#partial switch binary.op.token.kind {
	case .Plus:
		#partial switch l in left_val {
		case int:
			#partial switch r in right_val {
			case int:
				return l + r, true
			case f64:
				return f64(l) + r, true
			case:
				db_msgf_at(.Error, binary.b.token, "Expected a number, got %T", right_val)
				return
			}
		case f64:
			#partial switch r in right_val {
			case int:
				return l + f64(r), true
			case f64:
				return l + r, true
			case:
				db_msgf_at(.Error, binary.b.token, "Expected a number, got %T", right_val)
				return
			}
		case:
			db_msgf_at(.Error, binary.a.token, "Expected a number, got %T", left_val)
			return
		}
	case .Minus:
		#partial switch l in left_val {
		case int:
			#partial switch r in right_val {
			case int:
				return l - r, true
			case f64:
				return f64(l) - r, true
			case:
				db_msgf_at(.Error, binary.b.token, "Expected a number, got %T", right_val)
				return
			}
		case f64:
			#partial switch r in right_val {
			case int:
				return l - f64(r), true
			case f64:
				return l - r, true
			case:
				db_msgf_at(.Error, binary.b.token, "Expected a number, got %T", right_val)
				return
			}
		case:
			db_msgf_at(.Error, binary.a.token, "Expected a number, got %T", left_val)
			return
		}
	case .Asterisk:
		#partial switch l in left_val {
		case int:
			#partial switch r in right_val {
			case int:
				return l * r, true
			case f64:
				return f64(l) * r, true
			case:
				db_msgf_at(.Error, binary.b.token, "Expected a number, got %T", right_val)
				return
			}
		case f64:
			#partial switch r in right_val {
			case int:
				return l * f64(r), true
			case f64:
				return l * r, true
			case:
				db_msgf_at(.Error, binary.b.token, "Expected a number, got %T", right_val)
				return
			}
		case:
			db_msgf_at(.Error, binary.a.token, "Expected a number, got %T", left_val)
			return
		}
	case .Slash:
		@(require_results)
		ensure_not_zero :: proc(value: $T, token: Token) -> bool {
			if value == 0 {
				db_msgf_at(.Error, token, "Division by zero")
				return false
			}
			return true
		}

		#partial switch l in left_val {
		case int:
			#partial switch r in right_val {
			case int:
				ensure_not_zero(r, binary.b.token) or_return
				return l / r, true
			case f64:
				ensure_not_zero(r, binary.b.token) or_return
				return f64(l) / r, true
			case:
				db_msgf_at(.Error, binary.b.token, "Expected a number, got %T", right_val)
				return
			}
		case f64:
			#partial switch r in right_val {
			case int:
				ensure_not_zero(r, binary.b.token) or_return
				return l / f64(r), true
			case f64:
				ensure_not_zero(r, binary.b.token) or_return
				return l / r, true
			case:
				db_msgf_at(.Error, binary.b.token, "Expected a number, got %T", right_val)
				return
			}
		case:
			db_msgf_at(.Error, binary.a.token, "Expected a number, got %T", left_val)
			return
		}
	case:
		db_msgf_at(
			.Error,
			binary.op.token,
			"Unsupported arithmetic operator: %v",
			binary.op.token.text,
		)
		return
	}
}

// Evaluates IN/NOT IN membership against a value list or subquery result.
evaluate_in_operation_bound :: proc(
	left_val: Database_Value,
	right_node: ^AST_Node,
	row: []Database_Value,
) -> (
	result: bool,
	ok: bool,
) {
	values := make([dynamic]Database_Value, database_query_allocator)

	if select_stmt, is_subquery := right_node.value.(^Select); is_subquery {
		subquery_result := exec_select(select_stmt) or_return

		for subquery_row in subquery_result.rows {
			for cell in subquery_row {
				append_elem(&values, cell)
				break
			}
		}
	} else if node_list, is_list := right_node.value.([dynamic]^AST_Node); is_list {
		for val_node in node_list {
			val := evaluate_term_bound(val_node, row) or_return
			if cell_val, is_cell := val.(Database_Value); is_cell {
				append_elem(&values, cell_val)
			}
		}
	} else {
		db_msgf_at(.Error, right_node.token, "IN operand must be a subquery or value list")
		return
	}

	#partial switch _ in left_val {
	case nil:
		return false, true
	case:
	}

	for val in values {
		if value_equal_including_conversion(left_val, val, right_node.token) or_return {
			return true, true
		}
	}
	return false, true
}

value_between_including_conversion :: proc(
	value: Database_Value,
	min_val, max_val: Database_Value,
	min_token, max_token: Token,
) -> (
	between: bool,
	ok: bool,
) {
	ordering := value_ordering_evaluate(value, min_val, min_token) or_return
	if ordering == .Less do return false, true
	ordering = value_ordering_evaluate(value, max_val, max_token) or_return
	return ordering != .Greater, true
}

// Evaluates BETWEEN/NOT BETWEEN using numeric bounds.
evaluate_between_operation_bound :: proc(
	a_eval, b_eval: Eval_Term_Result,
	condition: Condition,
	row: []Database_Value,
) -> (
	result: bool,
	ok: bool,
) {
	node_list, is_list := b_eval.([dynamic]^AST_Node)
	if !is_list || len(node_list) != 2 {
		db_msgf_at(
			.Error,
			condition.b.token,
			"BETWEEN operation requires two values (low AND high)",
		)
		return
	}

	min_eval := evaluate_term_bound(node_list[0], row) or_return
	max_eval := evaluate_term_bound(node_list[1], row) or_return

	min_value, min_value_ok := min_eval.(Database_Value)
	if !min_value_ok {
		db_msgf_at(.Error, node_list[0].token, "Expected a value, got %T", min_eval)
		return
	}
	max_value, max_value_ok := max_eval.(Database_Value)
	if !max_value_ok {
		db_msgf_at(.Error, node_list[1].token, "Expected a value, got %T", max_eval)
		return
	}

	a_value := eval_term_result_as_database_value(a_eval, condition.a.token) or_return

	return value_between_including_conversion(
		a_value,
		min_value,
		max_value,
		condition.a.token,
		condition.b.token,
	)
}

// Evaluates a boolean SQL expression tree against a bound row.
evaluate_expression_bound :: proc(
	expr_node: ^AST_Node,
	row: []Database_Value,
) -> (
	result: bool,
	ok: bool,
) {
	if cond, is_cond := expr_node.value.(^Condition); is_cond {
		op_token := cond.op.token
		// TODO: use switch
		if op_token.kind == .In {
			left_val := evaluate_term_bound(cond.a, row) or_return

			left_cell := left_val.(Database_Value)

			return evaluate_in_operation_bound(left_cell, cond.b, row)

		} else if op_token.kind == .Not_In {
			left_val := evaluate_term_bound(cond.a, row) or_return

			left_cell := left_val.(Database_Value)

			result, ok = evaluate_in_operation_bound(left_cell, cond.b, row)

			return !result, ok
		} else if op_token.kind == .And {
			left_bool := evaluate_expression_bound(cond.a, row) or_return

			if !left_bool {
				return false, true
			}

			return evaluate_expression_bound(cond.b, row)
		} else if op_token.kind == .Or {
			left_bool := evaluate_expression_bound(cond.a, row) or_return

			if left_bool {
				return true, true
			}

			return evaluate_expression_bound(cond.b, row)
		} else {
			a := evaluate_term_bound(cond.a, row) or_return

			b := evaluate_term_bound(cond.b, row) or_return

			if op_token.kind == .Equals ||
			   op_token.kind == .Not_Equals ||
			   op_token.kind == .Greater_Than ||
			   op_token.kind == .Less_Than ||
			   op_token.kind == .Gt_Eq ||
			   op_token.kind == .Lt_Eq {

				a_cell := eval_term_result_as_database_value(a, op_token) or_return
				b_cell := eval_term_result_as_database_value(b, op_token) or_return

				return binary_operator_evaluate(a_cell, b_cell, op_token, cond.b.token)
			} else if op_token.kind == .Like {
				a_cell := eval_term_result_as_database_value(a, op_token) or_return
				b_cell := eval_term_result_as_database_value(b, op_token) or_return

				return evaluate_like_operation(a_cell, b_cell)
			} else if op_token.kind == .Not_Like {
				a_cell := eval_term_result_as_database_value(a, op_token) or_return
				b_cell := eval_term_result_as_database_value(b, op_token) or_return

				result, ok = evaluate_like_operation(a_cell, b_cell)
				return !result, ok
			} else if op_token.kind == .Between {
				return evaluate_between_operation_bound(a, b, cond^, row)
			} else if op_token.kind == .Not_Between {
				result := evaluate_between_operation_bound(a, b, cond^, row) or_return
				return !result, true
			} else {
				db_msgf_at(.Error, op_token, "Unsupported operator: %v", op_token.text)
				return
			}
		}
	} else if unary, is_unary := expr_node.value.(^Unary_Expression); is_unary {
		operand_val := evaluate_expression_bound(unary.operand, row) or_return
		op_text, op_ok := unary.op.value.(^AST_String)
		if !op_ok {
			db_msgf_at(.Error, unary.op.token, "Expected operator to be string")
			return false, false
		}
		if op_text.text == "NOT" {
			return !operand_val, true
		}
		db_msgf_at(.Error, unary.op.token, "Unsupported unary operator: %v", op_text.text)
		return false, false
	}

	db_msgf_at(.Error, expr_node.token, "Unsupported expression type")
	return false, false
}

// Evaluates a scalar term, subquery, list, or boolean expression against a row.
evaluate_term_bound :: proc(
	term_node: ^AST_Node,
	row: []Database_Value,
) -> (
	result: Eval_Term_Result,
	ok: bool,
) {
	#partial switch value in term_node.value {
	case ^AST_Ident:
		if value.slot_id < 0 || value.slot_id >= len(row) {
			full_name := ast_ident_as_string(value)
			db_msgf_at(.Error, term_node.token, "Unknown column '%v'", full_name)
			return
		}
		return row[value.slot_id], true
	case ^AST_String:
		return Database_Value(database_string_make(value.text)), true
	case ^AST_Int:
		return Database_Value(value.int), true
	case ^AST_Float:
		return Database_Value(value.float), true
	case ^Binary_Expression:
		return evaluate_binary_expression_bound(value, row)
	case ^Condition:
		return evaluate_expression_bound(value, row)
	case ^Unary_Expression:
		return evaluate_expression_bound(value, row)
	case ^Select:
		return exec_select(value)
	case [dynamic]^AST_Node:
		return value, true
	case ^AST_Aggregate_Call:
		db_msgf_at(
			.Error,
			term_node.token,
			"Aggregate '%v' cannot be evaluated in row context before GROUP BY",
			value.name,
		)
		return
	case nil:
		return Database_Value(nil), true
	case bool:
		return Database_Value(value), true
	case:
		msgf(
			.Error,
			.Database,
			"Invalid term: %v at %v:%v",
			term_node.token.text,
			term_node.token.line,
			term_node.token.column,
		)
		return
	}
}

// Single_Exec_Result_Row_Count :: distinct int

Single_Exec_Result :: struct {
	result:         union {
		Rows_With_Names, // TODO: document
		// Single_Exec_Result_Row_Count, // TODO: document
		// Maybe(int), // TODO: document
		int,
	},
	plans:          [dynamic]Single_Table_Select_Plan,
	execution_tree: string,
}

Exec_Result :: struct {
	// Full per-statement results for batched SQL input.
	statement_results: [dynamic]Single_Exec_Result,
	// Backwards-compatible view of the last statement result. TODO: remove in the future
	result:            union {
		Rows_With_Names, // TODO: document
		int, // TODO: documen
		// Maybe(int), // TODO: document
	},
	plans:             [dynamic]Single_Table_Select_Plan,
	execution_tree:    string,
}

// Executes a parsed AST node and returns rows, row counts, plans, and tree text.
exec_node :: proc(node: ^AST_Node) -> (result: Single_Exec_Result, ok: bool) {
	#partial switch v in node.value {
	case ^Select:
		root, applied_plan, have_plan := plan_select_execution_tree(v) or_return
		if have_plan do append(&exec_select_plans, applied_plan)
		rows := exec_execution_tree_rows(root) or_return
		return Single_Exec_Result {
				result = rows,
				plans = exec_select_plans,
				execution_tree = execution_tree_visual_string(root),
			},
			true
	case ^Insert,
	     ^Update,
	     ^Delete,
	     ^Create_Table,
	     ^Create_Index,
	     ^Alter_Table,
	     ^Drop_Table,
	     ^Begin_Transaction,
	     ^Commit_Transaction,
	     ^Rollback_Transaction:
		command_root := plan_command_execution_tree(node) or_return
		command_result := exec_execution_tree_command(command_root) or_return
		command_result_int, command_result_int_ok := command_result.?

		return Single_Exec_Result {
				result = command_result_int if command_result_int_ok else nil,
				plans = exec_select_plans,
				execution_tree = "",
			},
			true
	case:
		db_msgf_at(.Error, node.token, "Unsupported node type: %T", v)
		return
	}
}

exec_single_statement :: proc(query: string) -> (result: Single_Exec_Result, result_ok: bool) {
	exec_select_plans = make([dynamic]Single_Table_Select_Plan, database_query_allocator)

	tokens, tok_ok := tokenize(query)
	if !tok_ok {
		if !had_error_msg do msgf(.Error, .Tokenizer, "Tokenization failed")
		return
	}

	parser := parser_init(tokens[:], query, database_query_allocator) // TODO: this memory actually escpaes to 'result'!
	node, parse_ok := parse_query(&parser)
	if !parse_ok {
		if !had_error_msg do msgf(.Error, .Parser, "Failed to parse query")
		return
	}

	result, result_ok = exec_node(node)
	if !result_ok {
		if !had_error_msg do msgf(.Error, .Database, "Query execution failed")
		return
	}
	return result, true
}

// Tokenizes, parses, plans, and executes one or more SQL statements.
exec :: proc(query: string, clear_msgs: bool) -> (result: Exec_Result, result_ok: bool) {
	// FIXME: use a custom arena TIED TO THE EXEC RESULT so caller can clear all query-relevant memory
	// FIXME: also need a proc for clearing all memoery FROM THE DATABASE itself
	if clear_msgs do msgs_clear()

	statements := split_exec_statements(query, database_query_allocator)
	if len(statements) <= 0 {
		if !had_error_msg do msgf(.Error, .Parser, "No SQL statements found")
		return
	}

	result.statement_results = make([dynamic]Single_Exec_Result, database_query_allocator)
	for statement in statements {
		statement_result, statement_ok := exec_single_statement(statement)
		if !statement_ok do return
		append(&result.statement_results, statement_result)
	}

	last_result := result.statement_results[len(result.statement_results) - 1]
	last_result_int, last_result_int_ok := last_result.result.(int)
	result.result = last_result_int if last_result_int_ok else last_result.result
	result.plans = last_result.plans
	result.execution_tree = last_result.execution_tree
	return result, true
}

// Clears all committed tables and any active transaction state.
delete_all_tables :: proc() {
	table_set_destroy_all(&database_tables, &database_tables_count)
	if txn_active {
		table_set_destroy_all(&txn_tables, &txn_tables_count)
		txn_active = false
	}
}
