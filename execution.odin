#+vet explicit-allocators
package main

import "core:fmt"
import "core:log"
import "core:slice"
import "core:sort"
import "core:strings"

// TODO: Consider making it a union of value types (even if it means each node has the maximum possible size).
Execution_Node :: union {
	^Execution_Join,
	^Execution_Table_Scan,
	^Execution_Filter,
	^Execution_Aggregate,
	^Execution_Project,
	^Execution_Merge_Sort,
	^Execution_Limit_Offset,
	^Execution_Pk_Scan,
	^Execution_Index_Scan,
	^Execution_Subquery_Scan,
	^Execution_Insert,
	^Execution_Update,
	^Execution_Delete,
	^Execution_Create_Table,
	^Execution_Create_Index,
	^Execution_Alter_Table,
	^Execution_Drop_Table,
	^Execution_Begin_Transaction,
	^Execution_Commit_Transaction,
	^Execution_Rollback_Transaction,
}

Execution_Join :: struct {
	left, right:              Execution_Node,
	condition:                ^AST_Node,
	join_type:                Join_Type,
	algorithm:                Join_Algorithm,
	// Join keeps state so rows can be pulled incrementally.
	initialized:              bool,
	// Condition/binding setup is split so expression binding happens once per node.
	condition_bound:          bool,
	bindings_ready:           bool,
	join_bindings:            Bindings,
	// Materialized side buffers used by hash/merge and by outer-join post processing.
	left_rows, right_rows:    [dynamic]Table_Row,
	// Cached widths let us synthesize NULL-padded rows without re-deriving schemas.
	left_width, right_width:  int,
	// Current probe positions for nested-loop/hash join pair generation.
	left_i, right_i:          int,
	// Tracks whether the current left row matched at least one right row.
	left_row_matched:         bool,
	// True while RIGHT/FULL join emits right rows that never matched any left row.
	emitting_unmatched_right: bool,
	// Cursor into right_rows during the unmatched-right emission phase.
	unmatched_right_i:        int,
	// Per-right-row match bitmap, used to decide which rows remain unmatched.
	matched_right_rows:       []bool,
	// Cursor over precomputed match pairs when join phase is replayed incrementally.
	pair_i:                   int,
	// Stored (left_idx, right_idx) pairs so pull-based consumers can resume cleanly.
	matched_pairs:            [dynamic][2]int,
}

Execution_Table_Scan :: struct {
	table_name:            string,
	source_name:           string,
	required_column_names: []string,
	required_column_slots: [dynamic]int,
	// Iterator state is kept on the node so callers can pull rows incrementally.
	table:                 ^Table,
	row_i:                 Row_Index,
	chunk_i:               int,
	block_rows:            [dynamic]Table_Row,
	block_row_i:           int,
	initialized:           bool,
}

Join_Algorithm :: enum {
	Nested_Loop,
	Hash,
	Merge,
}

Execution_Filter :: struct {
	// Filter rows always come from a single upstream node so evaluation stays streaming-friendly.
	input:           Execution_Node,
	conjuncts:       [dynamic; 255]^AST_Node,
	// Conjunct expressions are bound once against the filter's source bindings.
	conjuncts_bound: bool,
	filter_bindings: Bindings,
	bindings_ready:  bool,
	// Rows are batched from upstream so predicates are evaluated block-by-block.
	block_rows:      [dynamic]Table_Row,
	block_row_i:     int,
}

Execution_Aggregate :: struct {
	input:               Execution_Node,
	group_by:            [dynamic]^AST_Node,
	projections:         [dynamic]^AST_Node,
	having:              ^AST_Node,
	// Determines whether result column naming needs fully-qualified join-aware handling.
	has_joins:           bool,
	base_table_name:     string,
	initialized:         bool,
	// Aggregate output is materialized once, then streamed to parent nodes.
	output_rows:         [dynamic]Table_Row,
	output_column_names: []string,
	row_i:               int,
	// Scratch block used while consuming input rows.
	block_rows:          [dynamic]Table_Row,
	block_row_i:         int,
}

Execution_Project :: struct {
	input:               Execution_Node,
	projections:         [dynamic]^AST_Node,
	// Determines whether unqualified column references need join-disambiguation rules.
	has_joins:           bool,
	base_table_name:     string,
	output_column_names: []string,
	// Projection expressions run against these prepared per-row bindings.
	input_bindings:      Bindings,
	bindings_ready:      bool,
	// Projection ASTs are bound once, then reused for each incoming row.
	expressions_bound:   bool,
	// Input rows are buffered in blocks for pull-based incremental projection.
	block_rows:          [dynamic]Table_Row,
	block_row_i:         int,
}

Execution_Merge_Sort :: struct {
	input:               Execution_Node,
	order_items:         [dynamic]Order_By_Item,
	has_joins:           bool,
	base_table_name:     string,
	// Number of leading ORDER BY terms guaranteed by upstream scan/join order.
	// Remaining terms (if any) are refined only within tied prefix groups.
	prefix_sorted_terms: int,
	initialized:         bool,
	// Cached once so downstream pulls don't repeatedly rescan/sort upstream rows.
	sorted_rows:         [dynamic]Table_Row,
	row_i:               int,
}

Execution_Order_Guarantee :: struct {
	available:           bool,
	source_table_name:   string,
	column_name:         string,
	descending:          bool,
	// True when upstream order may repeat key values (not a strict total ordering).
	duplicates_possible: bool,
	// How many ORDER BY terms are already guaranteed sorted by the source plan.
	prefix_sorted_terms: int,
}

Execution_Limit_Offset :: struct {
	input:     Execution_Node,
	offset:    int,
	limit:     int,
	has_limit: bool,
	// Number of input rows discarded to satisfy OFFSET.
	skipped:   int,
	// Number of rows already returned downstream (used to enforce LIMIT).
	emitted:   int,
}

Execution_Pk_Scan :: struct {
	table_name:  string,
	source_name: string,
	plan:        Pk_Where_Plan,
	descending:  bool,
	table:       ^Table,
	initialized: bool,
	scan:        Pk_Scan_Stream,
}

Execution_Index_Scan :: struct {
	table_name:  string,
	source_name: string,
	plan:        Index_Filter_Plan,
	descending:  bool,
	table:       ^Table,
	initialized: bool,
	scan:        Index_Filter_Scan_Stream,
}

Execution_Subquery_Scan :: struct {
	select:      ^Select,
	initialized: bool,
	// Subquery result is materialized once so scan can behave like a regular table source.
	rows:        Rows_With_Names,
	row_i:       int,
}

Execution_Insert :: struct {
	insert: ^Insert,
}

Execution_Update :: struct {
	update: ^Update,
}

Execution_Delete :: struct {
	delete_stmt: ^Delete,
}

Execution_Create_Table :: struct {
	create_table: ^Create_Table,
}

Execution_Create_Index :: struct {
	create_index: ^Create_Index,
}

Execution_Alter_Table :: struct {
	alter_table: ^Alter_Table,
}

Execution_Drop_Table :: struct {
	drop_table: ^Drop_Table,
}

Execution_Begin_Transaction :: struct {
	begin_transaction: ^Begin_Transaction,
}

Execution_Commit_Transaction :: struct {
	commit_transaction: ^Commit_Transaction,
}

Execution_Rollback_Transaction :: struct {
	rollback_transaction: ^Rollback_Transaction,
}

// ANSI colors make deep plans easier to scan quickly in terminal output.
// If needed, this can be toggled off centrally.
EXECUTION_TREE_COLOR_ENABLED :: true
EXECUTION_TREE_ANSI_RESET :: "\x1b[0m"
EXECUTION_TREE_ANSI_BRANCH :: "\x1b[90m"
EXECUTION_TREE_ANSI_NODE :: "\x1b[96m"
EXECUTION_TREE_ANSI_META :: "\x1b[94m"
EXECUTION_TREE_ANSI_SUBQUERY :: "\x1b[95m"
EXECUTION_TREE_ANSI_WARNING :: "\x1b[93m"
EXECUTION_TREE_ANSI_NIL :: "\x1b[91m"

execution_tree_colorize :: proc(text: string, color: string) -> string {
	if !EXECUTION_TREE_COLOR_ENABLED || color == "" do return text
	return fmt.tprintf("%s%s%s", color, text, EXECUTION_TREE_ANSI_RESET)
}

execution_tree_append_prefix :: proc(
	out: ^strings.Builder,
	ancestor_has_more_siblings: []bool,
	is_last_sibling: bool,
) {
	for has_more_siblings in ancestor_has_more_siblings {
		if has_more_siblings {
			fmt.sbprintf(out, "%s", execution_tree_colorize("│  ", EXECUTION_TREE_ANSI_BRANCH))
		} else {
			fmt.sbprintf(out, "   ")
		}
	}
	// Root is printed without a branch connector.
	if len(ancestor_has_more_siblings) == 0 do return

	if is_last_sibling {
		fmt.sbprintf(out, "%s", execution_tree_colorize("└─ ", EXECUTION_TREE_ANSI_BRANCH))
	} else {
		fmt.sbprintf(out, "%s", execution_tree_colorize("├─ ", EXECUTION_TREE_ANSI_BRANCH))
	}
}

execution_tree_next_ancestor_guides :: proc(
	ancestor_has_more_siblings: []bool,
	is_last_sibling: bool,
) -> []bool {
	next := make([]bool, len(ancestor_has_more_siblings) + 1, database_query_allocator)
	copy(next, ancestor_has_more_siblings)

	// If this node is not the last sibling, descendants should keep drawing a vertical guide.
	next[len(ancestor_has_more_siblings)] = !is_last_sibling

	return next
}

Execution_Filter_Subquery_Ref :: struct {
	select_stmt: ^Select,
	is_not_in:   bool,
}

execution_expr_collect_filter_subqueries :: proc(
	node: ^AST_Node,
	out: ^[dynamic]Execution_Filter_Subquery_Ref,
) {
	assert(node != nil)

	#partial switch value in node.value {
	case ^Condition:
		block: {
			(value.op != nil) or_break block
			(value.op.token.kind == .In || value.op.token.kind == .Not_In) or_break block
			subquery_select := value.b.value.(^Select) or_break block
			append_elem(
				out,
				Execution_Filter_Subquery_Ref {
					select_stmt = subquery_select,
					is_not_in = value.op.token.kind == .Not_In,
				},
			)
		}
		execution_expr_collect_filter_subqueries(value.a, out)
		execution_expr_collect_filter_subqueries(value.b, out)

	case ^Unary_Expression:
		execution_expr_collect_filter_subqueries(value.operand, out)

	case ^Binary_Expression:
		execution_expr_collect_filter_subqueries(value.a, out)
		execution_expr_collect_filter_subqueries(value.b, out)

	case [dynamic]^AST_Node:
		for child in value do execution_expr_collect_filter_subqueries(child, out)
	}

	return
}

execution_tree_append_filter_subquery_visual :: proc(
	out: ^strings.Builder,
	subquery_ref: Execution_Filter_Subquery_Ref,
	ancestor_has_more_siblings: []bool,
	is_last_sibling: bool,
) {
	execution_tree_append_prefix(out, ancestor_has_more_siblings, is_last_sibling)
	if subquery_ref.is_not_in {
		fmt.sbprintf(
			out,
			"%s\n",
			execution_tree_colorize("NOT_IN_Subquery", EXECUTION_TREE_ANSI_SUBQUERY),
		)
	} else {
		fmt.sbprintf(
			out,
			"%s\n",
			execution_tree_colorize("IN_Subquery", EXECUTION_TREE_ANSI_SUBQUERY),
		)
	}

	subquery_root, _, _, subquery_ok := plan_select_execution_tree(subquery_ref.select_stmt)
	next_guides := execution_tree_next_ancestor_guides(ancestor_has_more_siblings, is_last_sibling)
	if subquery_ok {
		execution_tree_append_visual(out, subquery_root, next_guides, true)
	} else {
		execution_tree_append_prefix(out, next_guides, true)
		fmt.sbprintf(
			out,
			"%s\n",
			execution_tree_colorize("<subquery plan unavailable>", EXECUTION_TREE_ANSI_WARNING),
		)
	}
}

execution_tree_append_visual :: proc(
	out: ^strings.Builder,
	node: ^Execution_Node,
	ancestor_has_more_siblings: []bool,
	is_last_sibling: bool,
) {
	assert(node != nil)

	execution_tree_append_prefix(out, ancestor_has_more_siblings, is_last_sibling)
	next_guides := execution_tree_next_ancestor_guides(ancestor_has_more_siblings, is_last_sibling)

	#partial switch n in node {
	case ^Execution_Project:
		fmt.sbprintf(out, "%s\n", execution_tree_colorize("Project", EXECUTION_TREE_ANSI_NODE))
		execution_tree_append_visual(out, &n.input, next_guides, true)

	case ^Execution_Limit_Offset:
		switch {
		case n.has_limit:
			fmt.sbprintf(
				out,
				"%s(%s)\n",
				execution_tree_colorize("Limit_Offset", EXECUTION_TREE_ANSI_NODE),
				execution_tree_colorize(
					fmt.tprintf("offset=%v, limit=%v", n.offset, n.limit),
					EXECUTION_TREE_ANSI_META,
				),
			)
		case:
			fmt.sbprintf(
				out,
				"%s(%s)\n",
				execution_tree_colorize("Limit_Offset", EXECUTION_TREE_ANSI_NODE),
				execution_tree_colorize(
					fmt.tprintf("offset=%v", n.offset),
					EXECUTION_TREE_ANSI_META,
				),
			)
		}

		execution_tree_append_visual(out, &n.input, next_guides, true)

	case ^Execution_Merge_Sort:
		fmt.sbprintf(
			out,
			"%s(%s)\n",
			execution_tree_colorize("Merge_Sort", EXECUTION_TREE_ANSI_NODE),
			execution_tree_colorize(
				fmt.tprintf("order_items=%v", len(n.order_items)),
				EXECUTION_TREE_ANSI_META,
			),
		)

		execution_tree_append_visual(out, &n.input, next_guides, true)

	case ^Execution_Filter:
		fmt.sbprintf(
			out,
			"%s(%s)\n",
			execution_tree_colorize("Filter", EXECUTION_TREE_ANSI_NODE),
			execution_tree_colorize(
				fmt.tprintf("conjuncts=%v", len(n.conjuncts)),
				EXECUTION_TREE_ANSI_META,
			),
		)

		subqueries := make([dynamic]Execution_Filter_Subquery_Ref, database_query_allocator)
		for conjunct in n.conjuncts {
			execution_expr_collect_filter_subqueries(conjunct, &subqueries)
		}

		child_count := len(subqueries) + 1
		for subquery_ref, subquery_i in subqueries {
			is_subquery_last_child := subquery_i == child_count - 1
			execution_tree_append_filter_subquery_visual(
				out,
				subquery_ref,
				next_guides,
				is_subquery_last_child,
			)
		}

		execution_tree_append_visual(out, &n.input, next_guides, true)

	case ^Execution_Aggregate:
		fmt.sbprintf(
			out,
			"%s(%s)\n",
			execution_tree_colorize("Aggregate", EXECUTION_TREE_ANSI_NODE),
			execution_tree_colorize(
				fmt.tprintf("group_by=%v, projections=%v", len(n.group_by), len(n.projections)),
				EXECUTION_TREE_ANSI_META,
			),
		)
		execution_tree_append_visual(out, &n.input, next_guides, true)

	case ^Execution_Join:
		fmt.sbprintf(
			out,
			"%s(%s)\n",
			execution_tree_colorize("Join", EXECUTION_TREE_ANSI_NODE),
			execution_tree_colorize(
				fmt.tprintf("type=%v, algorithm=%v", n.join_type, n.algorithm),
				EXECUTION_TREE_ANSI_META,
			),
		)
		execution_tree_append_visual(out, &n.left, next_guides, false)
		execution_tree_append_visual(out, &n.right, next_guides, true)
	case ^Execution_Table_Scan:
		fmt.sbprintf(
			out,
			"%s(%s)\n",
			execution_tree_colorize("Table_Scan", EXECUTION_TREE_ANSI_NODE),
			execution_tree_colorize(
				fmt.tprintf("table=%v, source=%v", n.table_name, n.source_name),
				EXECUTION_TREE_ANSI_META,
			),
		)

	case ^Execution_Pk_Scan:
		fmt.sbprintf(
			out,
			"%s(%s)\n",
			execution_tree_colorize("Pk_Scan", EXECUTION_TREE_ANSI_NODE),
			execution_tree_colorize(
				fmt.tprintf(
					"table=%v, source=%v, strategy=%v",
					n.table_name,
					n.source_name,
					n.plan.strategy,
				),
				EXECUTION_TREE_ANSI_META,
			),
		)
	case ^Execution_Index_Scan:
		fmt.sbprintf(
			out,
			"%s(%s)\n",
			execution_tree_colorize("Index_Scan", EXECUTION_TREE_ANSI_NODE),
			execution_tree_colorize(
				fmt.tprintf(
					"table=%v, source=%v, index=%v, strategy=%v",
					n.table_name,
					n.source_name,
					n.plan.index_position,
					n.plan.strategy,
				),
				EXECUTION_TREE_ANSI_META,
			),
		)

	case ^Execution_Subquery_Scan:
		fmt.sbprintf(
			out,
			"%s\n",
			execution_tree_colorize("Subquery_Scan", EXECUTION_TREE_ANSI_NODE),
		)

	case ^Execution_Insert:
		fmt.sbprintf(out, "%s\n", execution_tree_colorize("Insert", EXECUTION_TREE_ANSI_NODE))

	case ^Execution_Update:
		fmt.sbprintf(out, "%s\n", execution_tree_colorize("Update", EXECUTION_TREE_ANSI_NODE))

	case ^Execution_Delete:
		fmt.sbprintf(out, "%s\n", execution_tree_colorize("Delete", EXECUTION_TREE_ANSI_NODE))

	case ^Execution_Create_Table:
		fmt.sbprintf(
			out,
			"%s\n",
			execution_tree_colorize("Create_Table", EXECUTION_TREE_ANSI_NODE),
		)

	case ^Execution_Create_Index:
		fmt.sbprintf(
			out,
			"%s\n",
			execution_tree_colorize("Create_Index", EXECUTION_TREE_ANSI_NODE),
		)

	case ^Execution_Alter_Table:
		fmt.sbprintf(out, "%s\n", execution_tree_colorize("Alter_Table", EXECUTION_TREE_ANSI_NODE))

	case ^Execution_Drop_Table:
		fmt.sbprintf(out, "%s\n", execution_tree_colorize("Drop_Table", EXECUTION_TREE_ANSI_NODE))

	case ^Execution_Begin_Transaction:
		fmt.sbprintf(
			out,
			"%s\n",
			execution_tree_colorize("Begin_Transaction", EXECUTION_TREE_ANSI_NODE),
		)

	case ^Execution_Commit_Transaction:
		fmt.sbprintf(
			out,
			"%s\n",
			execution_tree_colorize("Commit_Transaction", EXECUTION_TREE_ANSI_NODE),
		)

	case ^Execution_Rollback_Transaction:
		fmt.sbprintf(
			out,
			"%s\n",
			execution_tree_colorize("Rollback_Transaction", EXECUTION_TREE_ANSI_NODE),
		)
	}
}

execution_tree_visual_string :: proc(root: ^Execution_Node) -> string {
	assert(root != nil)

	out := strings.builder_make(database_query_allocator)
	defer strings.builder_destroy(&out)

	execution_tree_append_visual(&out, root, {}, true)
	return strings.to_string(out)
}

Binding :: struct {
	source_name: string,
	slot_id:     int,
}

Bindings :: struct {
	bindings: [dynamic; 255]Binding,
}

execution_row_clone :: proc(row: []Database_Value) -> Table_Row {
	cloned := make(Table_Row, len(row), database_query_allocator)
	for value, i in row do cloned[i] = value
	return cloned
}

// One batch column: same layout as a single `Column_Chunk_Parametric` slice (typed payload + null bitmap).
// `Database_Value` only appears when materializing `Table_Row` via `execution_data_block_row_into`.
Execution_Block_Column :: union {
	Column_Chunk(int),
	Column_Chunk(f64),
	Column_Chunk(bool),
	Column_Chunk(Database_String),
}

// Resolves SQL storage type for one output column when bridging row batches into blocks.
// Declared `Maybe` wins when present and not `.Unspecified`; otherwise we infer from the first
// non-NULL cell. All-NULL columns default to INTEGER as an unused carrier (validity bits stay 0).
execution_data_block_resolve_column_type :: proc(
	rows: []Table_Row,
	col_i: int,
	declared_column_types: []Maybe(Database_Column_Type),
) -> (
	t: Database_Column_Type,
	ok: bool,
) {
	if len(declared_column_types) > 0 {
		if col_i < 0 || col_i >= len(declared_column_types) do return .Unspecified, false
		if column_type, has := declared_column_types[col_i].?; has && column_type != .Unspecified do return column_type, true
	}
	// TODO: Should we ever infer?
	for row in rows {
		(col_i < len(row)) or_continue
		value := row[col_i]
		(value != nil) or_continue
		return database_value_type_for_column(value)
	}
	return .Integer, true // TODO: error TODO: or_return
}

// Fills one typed execution column from a batch of `Table_Row` cells (may widen via coerce).
execution_block_column_fill_from_rows :: proc(
	col_type: Database_Column_Type,
	rows: []Table_Row,
	col_i: int,
	width: int,
) -> (
	col: Execution_Block_Column,
	ok: bool,
) {
	// TODO: defer -> error msg if not ok
	assert(len(rows) >= 0 && col_i >= 0 && col_i < width)

	impl :: proc(
		$T: typeid,
		col_type: Database_Column_Type,
		rows: []Table_Row,
		col_i: int,
		width: int,
	) -> (
		result: Execution_Block_Column,
		ok: bool,
	) {
		mut: Column_Chunk(T)
		resize(&mut.values, len(rows))
		column_chunk_validity_resize_for_row_count(&mut.valid_bits, len(rows))

		for row, row_i in rows {
			if col_i >= len(row) {
				mut.values[row_i] = {}
				column_chunk_validity_set_inbounds(&mut.valid_bits, row_i, false)
				continue
			}

			cell := row[col_i]
			if cell == nil {
				mut.values[row_i] = {}
				column_chunk_validity_set_inbounds(&mut.valid_bits, row_i, false)
				continue
			}

			coerced := database_coerce_value_for_column_type(cell, col_type) or_return
			(coerced != nil) or_return

			v := coerced.(T) or_return

			mut.values[row_i] = v
			column_chunk_validity_set_inbounds(&mut.valid_bits, row_i, true)
		}
		return mut, true
	}

	switch col_type {
	case .Integer:
		return impl(int, col_type, rows, col_i, width)
	case .Float:
		return impl(f64, col_type, rows, col_i, width)
	case .Boolean:
		return impl(bool, col_type, rows, col_i, width)
	case .Text:
		return impl(Database_String, col_type, rows, col_i, width)
	case .Unspecified:
		panic("Unspecified column type")
	}
	unreachable()
}

// Data blocks are the vectorized contract between operators.
// Invariants:
// - All columns have at least row_count values available.
// - selection_count is in [0, row_count].
// - selection entries are valid row indexes for this block.
// - valid_bits may be empty only for synthesized all-valid vectors.
Execution_Data_Block :: struct {
	columns:         [dynamic]Execution_Block_Column,
	row_count:       int,
	selection:       [dynamic]int,
	selection_count: int,
}

execution_data_block_is_valid :: proc(block: ^Execution_Data_Block) -> bool {
	if block.row_count < 0 do return false
	if block.selection_count < 0 || block.selection_count > block.row_count do return false
	if len(block.columns) == 0 do return block.row_count == 0 && block.selection_count == 0
	for col in block.columns {
		// Union `switch` uses value variant types, not `^Column_Chunk_Parametric(T)`.

		impl :: proc(c: Column_Chunk($T), block: ^Execution_Data_Block) -> bool {
			if len(c.values) < block.row_count do return false
			if len(c.valid_bits) > 0 &&
			   len(c.valid_bits) < column_chunk_validity_word_count_needed(block.row_count) {
				return false
			}
			return true
		}

		switch c in col {
		case Column_Chunk(int):
			return impl(c, block)
		case Column_Chunk(f64):
			return impl(c, block)
		case Column_Chunk(bool):
			return impl(c, block)
		case Column_Chunk(Database_String):
			return impl(c, block)
		case:
			unreachable()
		}
	}
	(len(block.selection) >= block.selection_count) or_return

	for selected_i in 0 ..< block.selection_count {
		row_i := block.selection[selected_i]
		if row_i < 0 || row_i >= block.row_count {
			return false
		}
	}
	return true
}

execution_data_block_set_identity_selection :: proc(block: ^Execution_Data_Block) {
	block.selection = make([dynamic]int, block.row_count, database_query_allocator)
	for i in 0 ..< block.row_count {
		block.selection[i] = i
	}
	block.selection_count = block.row_count
}

execution_data_block_row_into :: proc(
	block: ^Execution_Data_Block,
	row_i: int,
	row: ^Table_Row,
) -> bool {
	(row_i >= 0) or_return
	(row_i < block.row_count) or_return

	if len(row^) != len(block.columns) {
		row^ = make(Table_Row, len(block.columns), database_query_allocator)
	}

	for col, col_i in block.columns {
		// Switch binds a non-addressable temp; copy to `ch` so `valid_bits[:]` is legal.
		#partial switch c in col {
		case Column_Chunk(int):
			ch := c
			valid := true
			if len(ch.valid_bits) > 0 {
				valid = column_chunk_validity_get(ch.valid_bits[:], row_i)
			}
			if !valid {
				row^[col_i] = nil
				continue
			}
			row^[col_i] = ch.values[row_i]
		case Column_Chunk(f64):
			ch := c
			valid := true
			if len(ch.valid_bits) > 0 {
				valid = column_chunk_validity_get(ch.valid_bits[:], row_i)
			}
			if !valid {
				row^[col_i] = nil
				continue
			}
			row^[col_i] = ch.values[row_i]
		case Column_Chunk(bool):
			ch := c
			valid := true
			if len(ch.valid_bits) > 0 {
				valid = column_chunk_validity_get(ch.valid_bits[:], row_i)
			}
			if !valid {
				row^[col_i] = nil
				continue
			}
			row^[col_i] = ch.values[row_i]
		case Column_Chunk(Database_String):
			ch := c
			valid := true
			if len(ch.valid_bits) > 0 {
				valid = column_chunk_validity_get(ch.valid_bits[:], row_i)
			}
			if !valid {
				row^[col_i] = nil
				continue
			}
			row^[col_i] = ch.values[row_i]
		case:
			return false
		}
	}
	return true
}

execution_data_block_selected_row_into :: proc(
	block: ^Execution_Data_Block,
	selected_i: int,
	row: ^Table_Row,
) -> bool {
	if selected_i < 0 || selected_i >= block.selection_count {
		return false
	}
	row_i := block.selection[selected_i]
	return execution_data_block_row_into(block, row_i, row)
}

// Boundary helper only (result sink / row APIs). Vector operators should consume
// vectors + selection directly rather than materializing rows in hot paths.
execution_data_block_row_at :: proc(
	block: ^Execution_Data_Block,
	row_i: int,
) -> (
	row: Table_Row,
	ok: bool,
) {
	row = nil
	ok = execution_data_block_row_into(block, row_i, &row)
	return
}

// Boundary helper only (result sink / row APIs). Vector operators should consume
// vectors + selection directly rather than materializing rows in hot paths.
execution_data_block_selected_row :: proc(
	block: ^Execution_Data_Block,
	selected_i: int,
) -> (
	row: Table_Row,
	ok: bool,
) {
	row = nil
	ok = execution_data_block_selected_row_into(block, selected_i, &row)
	return
}

execution_data_block_to_rows :: proc(block: ^Execution_Data_Block) -> (rows: [dynamic]Table_Row) {
	rows = make([dynamic]Table_Row, 0, block.selection_count, database_query_allocator)
	for selected_i in 0 ..< block.selection_count {
		row, row_ok := execution_data_block_selected_row(block, selected_i)
		if !row_ok {
			continue
		}
		append_elem(&rows, row)
	}
	return rows
}

// Bridges row-oriented batches into typed vector columns. `declared_column_types` may be nil or
// empty to infer each column from data (see `execution_data_block_resolve_column_type`); otherwise
// its length must equal `width` and each slot may still leave inference to the row batch when empty.
execution_data_block_from_rows :: proc(
	rows: []Table_Row,
	width: int,
	declared_column_types: []Maybe(Database_Column_Type),
) -> (
	block: Execution_Data_Block,
	ok: bool,
) {
	ok = true
	if len(rows) == 0 || width <= 0 {
		return block, true
	}
	if len(declared_column_types) != 0 && len(declared_column_types) != width {
		return {}, false
	}
	block.columns = make([dynamic]Execution_Block_Column, width, database_query_allocator)
	for col_i in 0 ..< width {
		col_type, t_ok := execution_data_block_resolve_column_type(
			rows,
			col_i,
			declared_column_types,
		)
		if !t_ok {
			return {}, false
		}
		col, fill_ok := execution_block_column_fill_from_rows(col_type, rows, col_i, width)
		if !fill_ok {
			return {}, false
		}
		block.columns[col_i] = col
	}
	block.row_count = len(rows)
	execution_data_block_set_identity_selection(&block)
	return block, true
}

execution_expr_contains_aggregate :: proc(node: ^AST_Node) -> bool {
	if node == nil {
		return false
	}
	if _, is_aggregate := node.value.(^AST_Aggregate_Call); is_aggregate {
		return true
	}
	if cond, is_cond := node.value.(^Condition); is_cond {
		return(
			execution_expr_contains_aggregate(cond.a) ||
			execution_expr_contains_aggregate(cond.b) \
		)
	}
	if unary, is_unary := node.value.(^Unary_Expression); is_unary {
		return execution_expr_contains_aggregate(unary.operand)
	}
	if binary, is_binary := node.value.(^Binary_Expression); is_binary {
		return(
			execution_expr_contains_aggregate(binary.a) ||
			execution_expr_contains_aggregate(binary.b) \
		)
	}
	if node_list, is_list := node.value.([dynamic]^AST_Node); is_list {
		for child in node_list {
			if execution_expr_contains_aggregate(child) {
				return true
			}
		}
	}
	return false
}

execution_select_has_aggregate :: proc(select_stmt: ^Select) -> bool {
	for projection in select_stmt.cols {
		if execution_expr_contains_aggregate(projection.expr) {
			return true
		}
	}
	if execution_expr_contains_aggregate(select_stmt.having) {
		return true
	}
	for order_item in select_stmt.order_by {
		if execution_expr_contains_aggregate(order_item.expr) {
			return true
		}
	}
	return false
}

execution_expr_equivalent_for_grouping :: proc(a: ^AST_Node, b: ^AST_Node) -> bool {
	if a == nil || b == nil {
		return false
	}
	if a.source_text != "" && b.source_text != "" {
		return a.source_text == b.source_text
	}
	if a_ident, a_ok := a.value.(^AST_Ident); a_ok {
		if b_ident, b_ok := b.value.(^AST_Ident); b_ok {
			return(
				a_ident.table_name == b_ident.table_name &&
				a_ident.column_name == b_ident.column_name \
			)
		}
	}
	return projection_expr_name(a) == projection_expr_name(b)
}

execution_validate_grouped_projection_rules :: proc(select_stmt: ^Select) -> bool {
	// SQL rule enforcement for grouped SELECTs:
	// - plain projections must be listed in GROUP BY
	// - aggregate projections are always allowed
	// We do this in planning/execution prep so bad queries fail before row materialization.
	if len(select_stmt.group_by) == 0 {
		return true
	}
	for projection in select_stmt.cols {
		if execution_expr_contains_aggregate(projection.expr) {
			continue
		}
		is_grouped := false
		for group_expr in select_stmt.group_by {
			if execution_expr_equivalent_for_grouping(projection.expr, group_expr) {
				is_grouped = true
				break
			}
		}
		if !is_grouped {
			db_msgf_at(
				.Error,
				projection.expr.token,
				"Non-aggregate projection '%v' must appear in GROUP BY",
				projection_expr_name(projection.expr),
			)
			return false
		}
	}
	return true
}

execution_group_key_of_row :: proc(exprs: []^AST_Node, row: []Database_Value) -> (string, bool) {
	if len(exprs) == 0 {
		return "__single_group__", true
	}
	key := ""
	for expr, i in exprs {
		value_any, value_ok := evaluate_term_bound(expr, row)
		if !value_ok {
			return "", false
		}
		value := value_any.(Database_Value)
		if i > 0 {
			key = fmt.tprintf("%v|%v", key, value)
		} else {
			key = fmt.tprintf("%v", value)
		}
	}
	return key, true
}

execution_aggregate_sum_as_value :: proc(sum: f64, has_float: bool) -> Database_Value {
	if has_float {
		return sum
	}
	return int(sum)
}

execution_evaluate_group_term :: proc(
	expr: ^AST_Node,
	first_row: []Database_Value,
	sum_values: map[string]f64,
	sum_counts: map[string]int,
	sum_has_float: map[string]bool,
) -> (
	result: Database_Value,
	ok: bool,
) {
	// Evaluates one expression in "group context" (projection/HAVING after grouping).
	//
	// Important behavior:
	// - aggregate calls read from precomputed maps (sum_values/sum_counts/sum_has_float),
	//   never from the raw row stream at this stage.
	// - non-aggregate terms are resolved against first_row, which acts as the
	//   representative row for grouped scalar expressions.
	// - arithmetic is intentionally numeric-only and reports clear diagnostics
	//   for mixed/invalid types and division-by-zero.
	if expr == nil {
		return Database_Value(nil), true
	}
	if aggregate, is_aggregate := expr.value.(^AST_Aggregate_Call); is_aggregate {
		arg_key := projection_expr_name(expr)
		if aggregate.name == "COUNT" {
			return sum_counts[arg_key], true
		}
		if aggregate.name == "SUM" {
			count := sum_counts[arg_key]
			if count <= 0 {
				return Database_Value(nil), true
			}
			return execution_aggregate_sum_as_value(sum_values[arg_key], sum_has_float[arg_key]),
				true
		}
		if aggregate.name == "AVG" {
			count := sum_counts[arg_key]
			if count <= 0 {
				return Database_Value(nil), true
			}
			return sum_values[arg_key] / f64(count), true
		}
		db_msgf_at(.Error, expr.token, "Unsupported aggregate function '%v'", aggregate.name)
		return
	}
	if binary, is_binary := expr.value.(^Binary_Expression); is_binary {
		left := execution_evaluate_group_term(
			binary.a,
			first_row,
			sum_values,
			sum_counts,
			sum_has_float,
		) or_return
		right := execution_evaluate_group_term(
			binary.b,
			first_row,
			sum_values,
			sum_counts,
			sum_has_float,
		) or_return

		// TODO: separate branch/output type for int vs float columns?
		cell_to_number :: proc(cell: Database_Value) -> (result: f64, ok: bool) {
			#partial switch v in cell {
			case int:
				return f64(v), true
			case f64:
				return v, true
			case:
				return 0, false
			}
		}

		left_num, left_ok := cell_to_number(left)
		right_num, right_ok := cell_to_number(right)
		if !left_ok || !right_ok {
			db_msgf_at(
				.Error,
				expr.token,
				"Aggregate expression arithmetic requires numeric values",
			)
			return
		}
		op_text := binary.op.value.(^AST_String) or_return
		switch op_text.text {
		case "+":
			return left_num + right_num, true
		case "-":
			return left_num - right_num, true
		case "*":
			return left_num * right_num, true
		case "/":
			if right_num == 0 {
				db_msgf_at(.Error, expr.token, "Division by zero in aggregate expression")
				return
			}
			return left_num / right_num, true
		case:
			db_msgf_at(.Error, expr.token, "Unsupported arithmetic operator '%v'", op_text.text)
			return
		}
	}
	if _, is_cond := expr.value.(^Condition); is_cond {
		cond_bool := execution_evaluate_group_bool(
			expr,
			first_row,
			sum_values,
			sum_counts,
			sum_has_float,
		) or_return
		return Database_Value(cond_bool), true
	}
	term_value_any, term_ok := evaluate_term_bound(expr, first_row)
	if !term_ok {
		return
	}
	term_value := term_value_any.(Database_Value)
	return term_value, true
}

execution_evaluate_group_bool :: proc(
	expr: ^AST_Node,
	first_row: []Database_Value,
	sum_values: map[string]f64,
	sum_counts: map[string]int,
	sum_has_float: map[string]bool,
) -> (
	result: bool,
	ok: bool,
) {
	if expr == nil {
		return true, true
	}
	cond, is_cond := expr.value.(^Condition)
	if !is_cond {
		term := execution_evaluate_group_term(
			expr,
			first_row,
			sum_values,
			sum_counts,
			sum_has_float,
		) or_return
		if as_bool, is_bool := term.(bool); is_bool {
			return as_bool, true
		}
		db_msgf_at(.Error, expr.token, "HAVING expression must evaluate to boolean")
		return
	}
	op_kind := cond.op.token.kind
	if op_kind == .And {
		left := execution_evaluate_group_bool(
			cond.a,
			first_row,
			sum_values,
			sum_counts,
			sum_has_float,
		) or_return
		if !left {
			return false, true
		}
		return execution_evaluate_group_bool(
			cond.b,
			first_row,
			sum_values,
			sum_counts,
			sum_has_float,
		)
	}
	if op_kind == .Or {
		left := execution_evaluate_group_bool(
			cond.a,
			first_row,
			sum_values,
			sum_counts,
			sum_has_float,
		) or_return
		if left {
			return true, true
		}
		return execution_evaluate_group_bool(
			cond.b,
			first_row,
			sum_values,
			sum_counts,
			sum_has_float,
		)
	}

	left := execution_evaluate_group_term(
		cond.a,
		first_row,
		sum_values,
		sum_counts,
		sum_has_float,
	) or_return
	right := execution_evaluate_group_term(
		cond.b,
		first_row,
		sum_values,
		sum_counts,
		sum_has_float,
	) or_return
	if op_kind == .Like do return evaluate_like_operation(left, right)
	if op_kind == .Not_Like {
		value, compare_ok := evaluate_like_operation(left, right)
		return !value, compare_ok
	}
	return binary_operator_evaluate(left, right, cond.op.token, cond.b.token)
}

execution_node_has_wildcard_projection :: proc(projections: [dynamic]^AST_Node) -> bool {
	for col in projections {
		ident := col.value.(^AST_Ident) or_continue
		(ident.column_name == "*") or_continue
		return true
	}
	return false
}

execution_project_resolve_output_name :: proc(
	projection: ^AST_Node,
	input_column_names: []string,
	has_joins: bool,
	base_table_name: string,
) -> (
	name: string,
	ok: bool,
) {
	ident, is_ident := projection.value.(^AST_Ident)
	if !is_ident {
		return projection_expr_name(projection), true
	}

	if ident.column_name == "*" {
		return "", false
	}

	if ident.table_name != "" {
		full_name := ast_ident_as_string(ident)
		if slice.contains(input_column_names, full_name) {
			return full_name, true
		}
		if !has_joins &&
		   ident.table_name == base_table_name &&
		   slice.contains(input_column_names, ident.column_name) {
			return ident.column_name, true
		}
		return "", false
	}

	if !has_joins {
		if slice.contains(input_column_names, ident.column_name) {
			return ident.column_name, true
		}
		return "", false
	}

	match := ""
	ambiguous := false
	match, _, ambiguous = execution_resolve_unqualified_column_name(
		ident.column_name,
		input_column_names,
	)
	if ambiguous {
		db_msgf_at(
			.Error,
			ident.token,
			"Column '%v' is ambiguous between joined tables",
			ident.column_name,
		)
		return "", false
	}
	if match == "" {
		return "", false
	}
	return match, true
}

execution_project_prepare_output_names :: proc(
	node: ^Execution_Project,
	bindings: Bindings,
) -> bool {
	has_explicit_output_names := len(node.output_column_names) > 0
	if len(node.projections) == 0 || execution_node_has_wildcard_projection(node.projections) {
		node.output_column_names = execution_column_names_from_bindings(bindings)
		return true
	}

	input_column_names := execution_column_names_from_bindings(bindings)
	names := make([]string, len(node.projections), database_query_allocator)
	if has_explicit_output_names {
		if len(node.output_column_names) != len(node.projections) {
			db_msgf_at(
				.Error,
				node.projections[0].token,
				"Projection output names count mismatch: expected %v, got %v",
				len(node.projections),
				len(node.output_column_names),
			)
			return false
		}
		for output_name, i in node.output_column_names {
			names[i] = output_name
		}
	}
	for projection, i in node.projections {
		resolved_name, ok := execution_project_resolve_output_name(
			projection,
			input_column_names,
			node.has_joins,
			node.base_table_name,
		)
		if !ok {
			db_msgf_at(
				.Error,
				projection.token,
				"Unknown projection '%v'",
				projection_expr_name(projection),
			)
			return false
		}
		if !has_explicit_output_names || names[i] == "" {
			names[i] = resolved_name
		}
	}
	node.output_column_names = names
	return true
}

execution_bind_aggregate_expression_slots :: proc(node: ^AST_Node, bindings: Bindings) -> bool {
	if node == nil {
		return true
	}
	if aggregate, is_aggregate := node.value.(^AST_Aggregate_Call); is_aggregate {
		for arg in aggregate.args {
			if !execution_bind_expression_slots(arg, bindings) {
				return false
			}
		}
		return true
	}
	if cond, is_cond := node.value.(^Condition); is_cond {
		if !execution_bind_aggregate_expression_slots(cond.a, bindings) {
			return false
		}
		return execution_bind_aggregate_expression_slots(cond.b, bindings)
	}
	if unary, is_unary := node.value.(^Unary_Expression); is_unary {
		return execution_bind_aggregate_expression_slots(unary.operand, bindings)
	}
	if binary, is_binary := node.value.(^Binary_Expression); is_binary {
		if !execution_bind_aggregate_expression_slots(binary.a, bindings) {
			return false
		}
		return execution_bind_aggregate_expression_slots(binary.b, bindings)
	}
	if list, is_list := node.value.([dynamic]^AST_Node); is_list {
		for child in list {
			if !execution_bind_aggregate_expression_slots(child, bindings) {
				return false
			}
		}
		return true
	}
	return execution_bind_expression_slots(node, bindings)
}

execution_collect_aggregate_calls :: proc(
	node: ^AST_Node,
	aggregate_calls: ^map[string]^AST_Aggregate_Call,
) {
	if node == nil {
		return
	}
	if aggregate, is_aggregate := node.value.(^AST_Aggregate_Call); is_aggregate {
		arg_key := projection_expr_name(node)
		// Canonical keys let repeated aggregate expressions share one accumulator.
		if _, exists := aggregate_calls[arg_key]; !exists {
			aggregate_calls[arg_key] = aggregate
		}
		return
	}
	if cond, is_cond := node.value.(^Condition); is_cond {
		execution_collect_aggregate_calls(cond.a, aggregate_calls)
		execution_collect_aggregate_calls(cond.b, aggregate_calls)
		return
	}
	if unary, is_unary := node.value.(^Unary_Expression); is_unary {
		execution_collect_aggregate_calls(unary.operand, aggregate_calls)
		return
	}
	if binary, is_binary := node.value.(^Binary_Expression); is_binary {
		execution_collect_aggregate_calls(binary.a, aggregate_calls)
		execution_collect_aggregate_calls(binary.b, aggregate_calls)
		return
	}
	if list, is_list := node.value.([dynamic]^AST_Node); is_list {
		for child in list {
			execution_collect_aggregate_calls(child, aggregate_calls)
		}
	}
}

execution_aggregate_accumulate_call :: proc(
	aggregate_call: ^AST_Aggregate_Call,
	row: []Database_Value,
	group_counts: ^map[string]int,
	group_values: ^map[string]f64,
	group_has_float: ^map[string]bool,
) -> bool {
	if len(aggregate_call.args) == 0 {
		db_msgf_at(
			.Error,
			aggregate_call.token,
			"Aggregate '%v' requires an argument",
			aggregate_call.name,
		)
		return false
	}
	arg_expr := aggregate_call.args[0]
	arg_key := aggregate_call.source_text
	if arg_key == "" {
		arg_key = fmt.tprintf("%v(%v)", aggregate_call.name, projection_expr_name(arg_expr))
	}
	if aggregate_call.name == "COUNT" {
		if ident, is_ident := arg_expr.value.(^AST_Ident); is_ident && ident.column_name == "*" {
			group_counts[arg_key] += 1
		} else {
			arg_value_any := evaluate_term_bound(arg_expr, row[:]) or_return
			arg_value := arg_value_any.(Database_Value)
			if arg_value != nil {
				group_counts[arg_key] += 1
			}
		}
		return true
	}

	arg_value_any := evaluate_term_bound(arg_expr, row[:]) or_return
	arg_value := arg_value_any.(Database_Value)
	if arg_value == nil {
		return true
	}
	// TODO: separate branch/output type for int vs float columns?
	#partial switch v in arg_value {
	case int:
		group_values[arg_key] += f64(v)
		group_counts[arg_key] += 1
		return true
	case f64:
		group_values[arg_key] += v
		group_counts[arg_key] += 1
		group_has_float[arg_key] = true
	case:
		db_msgf_at(
			.Error,
			arg_expr.token,
			"Aggregate '%v' expects numeric input",
			aggregate_call.name,
		)
		return false
	}
	// arg_number, number_ok := cell_to_number(arg_value)
	// if !number_ok {
	// 	db_msgf_at(
	// 		.Error,
	// 		arg_expr.token,
	// 		"Aggregate '%v' expects numeric input",
	// 		aggregate_call.name,
	// 	)
	// 	return false
	// }
	// group_values[arg_key] += arg_number
	// group_counts[arg_key] += 1
	// if _, is_float := arg_value.(f64); is_float {
	// 	group_has_float[arg_key] = true
	// }
	return true
}

execution_aggregate_materialize_rows :: proc(node: ^Execution_Aggregate) -> bool {
	// Blocking aggregate operator:
	// 1) bind all expressions (projection/group/having) to input slots
	// 2) discover unique aggregate calls and allocate per-group accumulator maps
	// 3) consume full input (row path or block path), building group state
	// 4) evaluate HAVING + projection expressions from finalized group accumulators
	//
	// Node is initialized once and caches output_rows for downstream pull semantics.
	if node.initialized {
		return true
	}
	input_bindings, input_ok := execution_tree_bindings(&node.input)
	if !input_ok {
		return false
	}

	for projection in node.projections {
		if !execution_bind_aggregate_expression_slots(projection, input_bindings) {
			return false
		}
	}
	for group_expr in node.group_by {
		if !execution_bind_aggregate_expression_slots(group_expr, input_bindings) {
			return false
		}
	}
	if !execution_bind_aggregate_expression_slots(node.having, input_bindings) {
		return false
	}
	aggregate_calls := make(map[string]^AST_Aggregate_Call, database_query_allocator)
	for projection in node.projections {
		execution_collect_aggregate_calls(projection, &aggregate_calls)
	}
	execution_collect_aggregate_calls(node.having, &aggregate_calls)

	group_first_rows := make(map[string]Table_Row, database_query_allocator)
	group_sum_values := make(map[string]map[string]f64, database_query_allocator)
	group_sum_counts := make(map[string]map[string]int, database_query_allocator)
	group_sum_has_float := make(map[string]map[string]bool, database_query_allocator)

	if execution_tree_has_row_storage_scan(&node.input) {
		for {
			values, has_row := execution_tree_next_row(&node.input)
			if !has_row {
				break
			}
			row := execution_row_clone(values)
			group_key, key_ok := execution_group_key_of_row(node.group_by[:], row[:])
			if !key_ok {
				return false
			}
			if _, exists := group_first_rows[group_key]; !exists {
				group_first_rows[group_key] = row
				group_sum_values[group_key] = make(map[string]f64, database_query_allocator)
				group_sum_counts[group_key] = make(map[string]int, database_query_allocator)
				group_sum_has_float[group_key] = make(map[string]bool, database_query_allocator)
			}
			group_counts := group_sum_counts[group_key]
			group_values := group_sum_values[group_key]
			group_has_float := group_sum_has_float[group_key]
			for _, aggregate_call in aggregate_calls {
				if !execution_aggregate_accumulate_call(
					aggregate_call,
					row[:],
					&group_counts,
					&group_values,
					&group_has_float,
				) {
					return false
				}
			}
			group_sum_values[group_key] = group_values
			group_sum_counts[group_key] = group_counts
			group_sum_has_float[group_key] = group_has_float
		}
	} else {
		for {
			input_block, block_ok := execution_tree_next_block(&node.input)
			if !block_ok {
				break
			}
			if !execution_data_block_is_valid(&input_block) {
				return false
			}
			row := make(Table_Row, len(input_block.columns), database_query_allocator)
			for selected_i in 0 ..< input_block.selection_count {
				if !execution_data_block_selected_row_into(&input_block, selected_i, &row) {
					continue
				}
				group_key, key_ok := execution_group_key_of_row(node.group_by[:], row[:])
				if !key_ok {
					return false
				}
				if _, exists := group_first_rows[group_key]; !exists {
					group_first_rows[group_key] = execution_row_clone(row[:])
					group_sum_values[group_key] = make(map[string]f64, database_query_allocator)
					group_sum_counts[group_key] = make(map[string]int, database_query_allocator)
					group_sum_has_float[group_key] = make(
						map[string]bool,
						database_query_allocator,
					)
				}
				group_counts := group_sum_counts[group_key]
				group_values := group_sum_values[group_key]
				group_has_float := group_sum_has_float[group_key]
				for _, aggregate_call in aggregate_calls {
					if !execution_aggregate_accumulate_call(
						aggregate_call,
						row[:],
						&group_counts,
						&group_values,
						&group_has_float,
					) {
						return false
					}
				}
				group_sum_values[group_key] = group_values
				group_sum_counts[group_key] = group_counts
				group_sum_has_float[group_key] = group_has_float
			}
		}
	}

	node.output_rows = make([dynamic]Table_Row, database_query_allocator)
	for group_key, first_row in group_first_rows {
		out_row := make(Table_Row, len(node.projections), database_query_allocator)
		for projection, projection_i in node.projections {
			value, eval_ok := execution_evaluate_group_term(
				projection,
				first_row[:],
				group_sum_values[group_key],
				group_sum_counts[group_key],
				group_sum_has_float[group_key],
			)
			if !eval_ok {
				return false
			}
			out_row[projection_i] = value
		}

		if node.having != nil {
			having_passes := execution_evaluate_group_bool(
				node.having,
				first_row[:],
				group_sum_values[group_key],
				group_sum_counts[group_key],
				group_sum_has_float[group_key],
			) or_return
			if !having_passes {
				continue
			}
		}
		append_elem(&node.output_rows, out_row)
	}
	node.initialized = true
	node.row_i = 0
	node.block_row_i = 0
	return true
}

execution_table_scan_resolve_required_columns :: proc(scan: ^Execution_Table_Scan) {
	if len(scan.required_column_names) == 0 {
		return
	}

	resolved_slots := make([dynamic]int, database_query_allocator)
	resolved_names := make([dynamic]string, database_query_allocator)
	for required_name in scan.required_column_names {
		required_i := -1
		for column_name, column_i in scan.table.column_names {
			if column_name == required_name {
				required_i = column_i
				break
			}
		}
		if required_i < 0 {
			// Projection pushdown may conservatively over-approximate for joins.
			// Unknown names are left for expression binding to report precisely.
			continue
		}
		append_elem(&resolved_slots, required_i)
		append_elem(&resolved_names, required_name)
	}
	scan.required_column_slots = resolved_slots
	scan.required_column_names = resolved_names[:]
}

execution_table_scan_ensure_initialized :: proc(scan: ^Execution_Table_Scan) -> bool {
	if scan.initialized {
		return true
	}
	table, table_ok := database_find_table(scan.table_name, false)
	if !table_ok {
		msgf(.Error, .Database, "Table '%v' does not exist", scan.table_name)
		return false
	}
	scan.table = table
	table_storage_ensure(scan.table)
	execution_table_scan_resolve_required_columns(scan)
	scan.row_i = 0
	scan.chunk_i = 0
	scan.block_rows = nil
	scan.block_row_i = 0
	scan.initialized = true
	return true
}

execution_scan_row_block_from_storage_rows :: proc(
	scan: ^Execution_Table_Scan,
	block: ^Execution_Data_Block,
) -> bool {
	block^ = {}
	#partial switch storage in scan.table.storage {
	case [dynamic]Table_Row:
		rows := storage
		if int(scan.row_i) >= len(rows) {
			return false
		}
		remaining := len(rows) - int(scan.row_i)
		limit := COLUMN_CHUNK_SIZE
		if remaining < limit {
			limit = remaining
		}
		block_rows := make([dynamic]Table_Row, 0, limit, database_query_allocator)
		for i in 0 ..< limit {
			source_row := rows[int(scan.row_i) + i]
			if len(scan.required_column_slots) == 0 {
				append_elem(&block_rows, execution_row_clone(source_row[:]))
				continue
			}
			projected := make(Table_Row, len(scan.required_column_slots), database_query_allocator)
			for source_i, output_i in scan.required_column_slots {
				if source_i < 0 || source_i >= len(source_row) {
					continue
				}
				projected[output_i] = source_row[source_i]
			}
			append_elem(&block_rows, projected)
		}
		scan.row_i += Row_Index(limit)
		width := 0
		if len(block_rows) > 0 {
			width = len(block_rows[0])
		}
		decl := make([]Maybe(Database_Column_Type), width, database_query_allocator)
		if len(scan.required_column_slots) == 0 {
			for i in 0 ..< width {
				if i < len(scan.table.column_types) do decl[i] = scan.table.column_types[i]
			}
		} else {
			for source_i, output_i in scan.required_column_slots {
				if source_i >= 0 && source_i < len(scan.table.column_types) {
					decl[output_i] = scan.table.column_types[source_i]
				}
			}
		}
		new_block, fr_ok := execution_data_block_from_rows(block_rows[:], width, decl[:])
		if !fr_ok {
			return false
		}
		block^ = new_block
		return block.row_count > 0
	case:
		return false
	}
}

// Copies one storage chunk into a fresh typed execution column (temp allocator; no `Database_Value`).
execution_scan_columnar_fill_block_column :: proc(
	chunks: Column_Chunks,
	chunk_i: int,
	out_col: ^Execution_Block_Column,
) -> (
	row_count: int,
	ok: bool,
) {
	impl :: proc(
		chunks: [dynamic]Column_Chunk($T),
		chunk_i: int,
		out_col: ^Execution_Block_Column,
	) -> (
		row_count: int,
		ok: bool,
	) {
		if chunk_i < 0 || chunk_i >= len(chunks) {
			return -1, false
		}
		ch := chunks[chunk_i]
		mut: Column_Chunk(T)
		resize(&mut.values, len(ch.values))
		copy(mut.values[:], ch.values[:])
		resize(&mut.valid_bits, len(ch.valid_bits))
		copy(mut.valid_bits[:], ch.valid_bits[:])
		out_col^ = mut
		return len(ch.values), true
	}

	switch chunks_concrete in chunks {
	case [dynamic]Column_Chunk(int):
		return impl(chunks_concrete, chunk_i, out_col)
	case [dynamic]Column_Chunk(f64):
		return impl(chunks_concrete, chunk_i, out_col)
	case [dynamic]Column_Chunk(bool):
		return impl(chunks_concrete, chunk_i, out_col)
	case [dynamic]Column_Chunk(Database_String):
		return impl(chunks_concrete, chunk_i, out_col)
	case:
		unreachable()
	}
}

execution_scan_column_block_from_storage_columns :: proc(
	scan: ^Execution_Table_Scan,
	block: ^Execution_Data_Block,
) -> bool {
	block^ = {}
	#partial switch storage in scan.table.storage {
	case [dynamic]Column_Chunks:
		cols := storage
		if len(cols) == 0 {
			return false
		}
		first_col := cols[0]
		chunk_exists := false
		#partial switch chunks in first_col {
		case [dynamic]Column_Chunk(int):
			chunk_exists = scan.chunk_i >= 0 && scan.chunk_i < len(chunks)
		case [dynamic]Column_Chunk(f64):
			chunk_exists = scan.chunk_i >= 0 && scan.chunk_i < len(chunks)
		case [dynamic]Column_Chunk(bool):
			chunk_exists = scan.chunk_i >= 0 && scan.chunk_i < len(chunks)
		case [dynamic]Column_Chunk(Database_String):
			chunk_exists = scan.chunk_i >= 0 && scan.chunk_i < len(chunks)
		}
		if !chunk_exists {
			return false
		}
		column_slots := scan.required_column_slots
		if len(column_slots) == 0 {
			column_slots = make([dynamic]int, len(cols), database_query_allocator)
			for i in 0 ..< len(cols) {
				column_slots[i] = i
			}
		}
		block.columns = make(
			[dynamic]Execution_Block_Column,
			len(column_slots),
			database_query_allocator,
		)
		chunk_rows := -1
		for source_col_i, out_col_i in column_slots {
			if source_col_i < 0 || source_col_i >= len(cols) {
				return false
			}
			col: Execution_Block_Column
			n_rows, fill_ok := execution_scan_columnar_fill_block_column(
				cols[source_col_i],
				scan.chunk_i,
				&col,
			)
			if !fill_ok {
				return false
			}
			if chunk_rows < 0 {
				chunk_rows = n_rows
			} else if n_rows != chunk_rows {
				return false
			}
			block.columns[out_col_i] = col
		}
		if chunk_rows < 0 {
			return false
		}
		block.row_count = chunk_rows
		execution_data_block_set_identity_selection(block)
		scan.chunk_i += 1
		return true
	case:
		return false
	}
}

execution_tree_next_block :: proc(
	node: ^Execution_Node,
) -> (
	block: Execution_Data_Block,
	ok: bool,
) {
	#partial switch n in node^ {
	case ^Execution_Table_Scan:
		execution_table_scan_ensure_initialized(n) or_return

		#partial switch storage in n.table.storage {
		case [dynamic]Column_Chunks:
			ok = execution_scan_column_block_from_storage_columns(n, &block)
			return block, ok
		case [dynamic]Table_Row:
			// Vectorized block scan is a strict columnar path; row storage is handled
			// only via execution_tree_next_row-based execution.
			msgf(
				.Error,
				.Database,
				"Block execution requires columnar storage for table '%v'",
				n.table_name,
			)
			return {}, false
		}
		return {}, false
	case ^Execution_Filter:
		if !n.bindings_ready {
			n.filter_bindings, ok = execution_tree_bindings(&n.input)
			if !ok {
				return {}, false
			}
			n.bindings_ready = true
		}
		if !n.conjuncts_bound {
			if !execution_filter_bind_conjunct_slots(n, n.filter_bindings) {
				return {}, false
			}
		}
		for {
			input_block, input_ok := execution_tree_next_block(&n.input)
			if !input_ok {
				return {}, false
			}
			if !execution_data_block_is_valid(&input_block) {
				return {}, false
			}
			out_sel := make([dynamic]int, 0, input_block.selection_count, database_query_allocator)
			row := make(Table_Row, len(input_block.columns), database_query_allocator)
			for selected_i in 0 ..< input_block.selection_count {
				row_ok := execution_data_block_selected_row_into(&input_block, selected_i, &row)
				if !row_ok {
					continue
				}
				matches_all := true
				for conjunct in n.conjuncts {
					passes := evaluate_expression_bound(conjunct, row[:]) or_return
					if !passes {
						matches_all = false
						break
					}
				}
				if matches_all {
					append_elem(&out_sel, input_block.selection[selected_i])
				}
			}
			if len(out_sel) == 0 {
				continue
			}
			input_block.selection = out_sel
			input_block.selection_count = len(out_sel)
			return input_block, true
		}
	case ^Execution_Project:
		input_bindings, bindings_ok := execution_tree_bindings(&n.input)
		if !bindings_ok {
			return {}, false
		}
		if !execution_project_prepare_output_names(n, input_bindings) {
			return {}, false
		}
		input_block, input_ok := execution_tree_next_block(&n.input)
		if !input_ok {
			return {}, false
		}
		if !execution_data_block_is_valid(&input_block) {
			return {}, false
		}
		if len(n.projections) == 0 || execution_node_has_wildcard_projection(n.projections) {
			return input_block, true
		}
		projected_rows := make(
			[dynamic]Table_Row,
			0,
			input_block.selection_count,
			database_query_allocator,
		)
		row := make(Table_Row, len(input_block.columns), database_query_allocator)
		for selected_i in 0 ..< input_block.selection_count {
			row_ok := execution_data_block_selected_row_into(&input_block, selected_i, &row)
			if !row_ok {
				continue
			}
			row_data := Rows_With_Names {
				column_names = execution_column_names_from_bindings(input_bindings),
				rows         = make([dynamic]Table_Row, database_query_allocator),
			}
			append_elem(&row_data.rows, row)
			filtered_rows, filtered_ok := apply_column_selection(
				row_data,
				n.projections,
				n.has_joins,
				n.base_table_name,
			)
			if !filtered_ok || len(filtered_rows.rows) == 0 {
				return {}, false
			}
			append_elem(&projected_rows, filtered_rows.rows[0])
		}
		width := 0
		if len(projected_rows) > 0 {
			width = len(projected_rows[0])
		}
		fr_block, fr_ok := execution_data_block_from_rows(projected_rows[:], width, nil)
		if !fr_ok {
			return {}, false
		}
		return fr_block, fr_block.row_count > 0
	case ^Execution_Aggregate:
		if !execution_aggregate_materialize_rows(n) {
			return {}, false
		}
		if n.block_row_i >= len(n.output_rows) {
			return {}, false
		}
		remaining := len(n.output_rows) - n.block_row_i
		limit := COLUMN_CHUNK_SIZE
		if remaining < limit {
			limit = remaining
		}
		rows := make([dynamic]Table_Row, 0, limit, database_query_allocator)
		for i in 0 ..< limit {
			append_elem(&rows, execution_row_clone(n.output_rows[n.block_row_i + i][:]))
		}
		n.block_row_i += limit
		width := 0
		if len(rows) > 0 {
			width = len(rows[0])
		}
		fr_block, fr_ok := execution_data_block_from_rows(rows[:], width, nil)
		if !fr_ok {
			return {}, false
		}
		return fr_block, fr_block.row_count > 0
	case ^Execution_Join:
		if !n.bindings_ready {
			_, ok = execution_tree_bindings(node)
			if !ok {
				return {}, false
			}
		}
		if !n.initialized {
			if !execution_join_init_state(n) {
				return {}, false
			}
		}
		rows := make([dynamic]Table_Row, database_query_allocator)
		if n.algorithm != .Nested_Loop {
			for len(rows) < COLUMN_CHUNK_SIZE && n.pair_i < len(n.matched_pairs) {
				pair := n.matched_pairs[n.pair_i]
				n.pair_i += 1
				append_elem(
					&rows,
					execution_row_clone(
						execution_join_build_row(n.left_rows[pair[0]], n.right_rows[pair[1]]),
					),
				)
			}
		} else {
			for len(rows) < COLUMN_CHUNK_SIZE {
				row, row_ok := execution_tree_next_row(node)
				if !row_ok {
					break
				}
				append_elem(&rows, execution_row_clone(row))
			}
		}
		if len(rows) == 0 {
			return {}, false
		}
		width := len(rows[0])
		fr_block, fr_ok := execution_data_block_from_rows(rows[:], width, nil)
		if !fr_ok {
			return {}, false
		}
		return fr_block, true
	case:
		// Non-vectorized operators keep row semantics; bridge rows into blocks.
		rows := make([dynamic]Table_Row, database_query_allocator)
		for len(rows) < COLUMN_CHUNK_SIZE {
			row, row_ok := execution_tree_next_row(node)
			if !row_ok {
				break
			}
			append_elem(&rows, execution_row_clone(row))
		}
		if len(rows) == 0 {
			return {}, false
		}
		width := len(rows[0])
		fr_block, fr_ok := execution_data_block_from_rows(rows[:], width, nil)
		if !fr_ok {
			return {}, false
		}
		return fr_block, true
	}
}

execution_tree_next_row :: proc(node: ^Execution_Node) -> (row: []Database_Value, ok: bool) {
	switch n in node^ {
	case ^Execution_Table_Scan:
		if !n.initialized {
			n.table, ok = database_find_table(n.table_name, true)
			if !ok {
				return
			}
			table_storage_ensure(n.table)
			execution_table_scan_resolve_required_columns(n)
			n.row_i = 0
			n.initialized = true
		}

		if int(n.row_i) >= table_row_count(n.table) {
			return nil, false
		}

		source_row, row_ok := table_get_row(n.table, n.row_i)
		if !row_ok {
			return nil, false
		}
		n.row_i += 1

		// row = make([dynamic]Database_Value, database_query_allocator)
		// reserve(&row, len(source_row))
		// for cell in source_row {
		// 	append_elem(&row, cell.value)
		// }
		if len(n.required_column_slots) == 0 {
			return source_row[:], true
		}
		projected_row := make([dynamic]Database_Value, database_query_allocator)
		resize(&projected_row, len(n.required_column_slots))
		for source_i, output_i in n.required_column_slots {
			if source_i < 0 || source_i >= len(source_row) {
				continue
			}
			projected_row[output_i] = source_row[source_i]
		}
		return projected_row[:], true

	case ^Execution_Filter:
		if !n.bindings_ready {
			n.filter_bindings, ok = execution_tree_bindings(&n.input)
			if !ok {
				return nil, false
			}
			n.bindings_ready = true
		}
		if !n.conjuncts_bound {
			if !execution_filter_bind_conjunct_slots(n, n.filter_bindings) {
				return nil, false
			}
		}

		for {
			candidate_row, candidate_ok := execution_tree_next_row(&n.input)
			if !candidate_ok {
				return nil, false
			}

			candidate_cells := make(Table_Row, len(candidate_row), database_query_allocator)
			for value, i in candidate_row {
				candidate_cells[i] = value
			}

			matches_all := true
			for conjunct in n.conjuncts {
				passes := evaluate_expression_bound(conjunct, candidate_cells[:]) or_return
				if !passes {
					matches_all = false
					break
				}
			}
			if matches_all {
				return candidate_row, true
			}
		}
	case ^Execution_Aggregate:
		if !execution_aggregate_materialize_rows(n) {
			return nil, false
		}
		if n.row_i >= len(n.output_rows) {
			return nil, false
		}
		row := n.output_rows[n.row_i]
		n.row_i += 1
		return row[:], true
	case ^Execution_Join:
		if !n.bindings_ready {
			_, ok = execution_tree_bindings(node)
			if !ok {
				return nil, false
			}
		}
		if !n.initialized {
			if !execution_join_init_state(n) {
				return nil, false
			}
		}
		if n.algorithm != .Nested_Loop {
			if n.pair_i >= len(n.matched_pairs) {
				return nil, false
			}
			pair := n.matched_pairs[n.pair_i]
			n.pair_i += 1
			return execution_join_build_row(n.left_rows[pair[0]], n.right_rows[pair[1]]), true
		}

		for {
			if n.emitting_unmatched_right {
				for n.unmatched_right_i < len(n.right_rows) {
					right_i := n.unmatched_right_i
					n.unmatched_right_i += 1
					if n.matched_right_rows[right_i] {
						continue
					}

					joined_row := make([dynamic]Database_Value, database_query_allocator)
					joined_row_len := n.left_width + len(n.right_rows[right_i])
					reserve(&joined_row, joined_row_len)
					resize(&joined_row, n.left_width)
					append_elems(&joined_row, ..n.right_rows[right_i][:])
					return joined_row[:], true
				}
				return nil, false
			}

			if n.left_i >= len(n.left_rows) {
				if n.join_type == .Right {
					n.emitting_unmatched_right = true
					continue
				}
				return nil, false
			}

			left_row := n.left_rows[n.left_i]
			for n.right_i < len(n.right_rows) {
				right_i := n.right_i
				right_row := n.right_rows[right_i]
				n.right_i += 1

				candidate_row := execution_join_build_row(left_row, right_row)
				passes := true
				if n.condition != nil {
					passes = evaluate_expression_bound(n.condition, candidate_row) or_return
				}
				if !passes {
					continue
				}

				n.left_row_matched = true
				if n.join_type == .Right {
					n.matched_right_rows[right_i] = true
				}
				return candidate_row, true
			}

			if n.join_type == .Left && !n.left_row_matched {
				joined_row := make([dynamic]Database_Value, database_query_allocator)
				joined_row_len := len(left_row) + n.right_width
				reserve(&joined_row, joined_row_len)
				append_elems(&joined_row, ..left_row[:])
				resize(&joined_row, joined_row_len)

				n.left_i += 1
				n.right_i = 0
				n.left_row_matched = false
				return joined_row[:], true
			}

			n.left_i += 1
			n.right_i = 0
			n.left_row_matched = false
		}
	case ^Execution_Project:
		input_bindings, bindings_ok := execution_tree_bindings(&n.input)
		if !bindings_ok {
			return nil, false
		}
		if !execution_project_prepare_output_names(n, input_bindings) {
			return nil, false
		}

		input_row, input_ok := execution_tree_next_row(&n.input)
		if !input_ok {
			return nil, false
		}
		if len(n.projections) == 0 || execution_node_has_wildcard_projection(n.projections) {
			return execution_row_clone(input_row)[:], true
		}

		row_data := Rows_With_Names {
			column_names = execution_column_names_from_bindings(input_bindings),
			rows         = make([dynamic]Table_Row, database_query_allocator),
		}
		append_elem(&row_data.rows, execution_row_clone(input_row))

		filtered_rows, filtered_ok := apply_column_selection(
			row_data,
			n.projections,
			n.has_joins,
			n.base_table_name,
		)
		if !filtered_ok || len(filtered_rows.rows) == 0 {
			return nil, false
		}
		return filtered_rows.rows[0][:], true
	case ^Execution_Merge_Sort:
		if !n.initialized {
			if !execution_merge_sort_materialize_rows(n, 0, false) {
				return nil, false
			}
		}
		if n.row_i >= len(n.sorted_rows) {
			return nil, false
		}
		row := n.sorted_rows[n.row_i]
		n.row_i += 1
		return row[:], true
	case ^Execution_Limit_Offset:
		if n.has_limit && n.limit > 0 {
			if merge_sort, is_merge_sort := n.input.(^Execution_Merge_Sort); is_merge_sort {
				if !merge_sort.initialized {
					bound := n.limit
					if n.offset > 0 {
						bound += n.offset
					}
					if !execution_merge_sort_materialize_rows(merge_sort, bound, true) {
						return nil, false
					}
				}
			}
		}
		for n.skipped < n.offset {
			_, has_row := execution_tree_next_row(&n.input)
			if !has_row {
				return nil, false
			}
			n.skipped += 1
		}
		if n.has_limit && n.emitted >= n.limit {
			return nil, false
		}
		row, row_ok := execution_tree_next_row(&n.input)
		if !row_ok {
			return nil, false
		}
		n.emitted += 1
		return row, true
	case ^Execution_Pk_Scan:
		if !n.initialized {
			n.table, ok = database_find_table(n.table_name, true)
			if !ok {
				return nil, false
			}
			pk_scan_stream_init(&n.scan, n.table, n.plan, n.descending)
			n.initialized = true
		}
		row, row_ok := pk_scan_stream_next(&n.scan)
		if !row_ok {
			return nil, false
		}
		return row[:], true
	case ^Execution_Index_Scan:
		if !n.initialized {
			n.table, ok = database_find_table(n.table_name, true)
			if !ok {
				return nil, false
			}
			index_filter_scan_stream_init(&n.scan, n.table, n.plan, n.descending)
			n.initialized = true
		}
		row, row_ok := index_filter_scan_stream_next(&n.scan)
		if !row_ok {
			return nil, false
		}
		return row[:], true
	case ^Execution_Subquery_Scan:
		if !n.initialized {
			subquery_root, _, _, plan_ok := plan_select_execution_tree(n.select)
			if !plan_ok {
				return nil, false
			}
			n.rows, ok = exec_execution_tree_rows(subquery_root)
			if !ok {
				return nil, false
			}
			n.row_i = 0
			n.initialized = true
		}
		if n.row_i >= len(n.rows.rows) {
			return nil, false
		}
		row := n.rows.rows[n.row_i]
		n.row_i += 1
		return row[:], true
	case ^Execution_Insert,
	     ^Execution_Update,
	     ^Execution_Delete,
	     ^Execution_Create_Table,
	     ^Execution_Create_Index,
	     ^Execution_Alter_Table,
	     ^Execution_Drop_Table,
	     ^Execution_Begin_Transaction,
	     ^Execution_Commit_Transaction,
	     ^Execution_Rollback_Transaction:
		// Command nodes are side-effect operators and intentionally never emit row streams.
		return nil, false
	case:
		unreachable()
	}
	return nil, false
}

execution_bindings_find_slot :: proc(
	bindings: Bindings,
	source_name: string,
) -> (
	slot_id: int,
	ok: bool,
) {
	for binding in bindings.bindings {
		if binding.source_name == source_name {
			return binding.slot_id, true
		}
	}
	return -1, false
}

execution_binding_name_is_qualified :: proc(name: string) -> bool {
	for c in name {
		if c == '.' {
			return true
		}
	}
	return false
}

execution_resolve_unqualified_column_name :: proc(
	column_name: string,
	candidate_names: []string,
) -> (
	resolved_name: string,
	found: bool,
	ambiguous: bool,
) {
	for candidate_name in candidate_names {
		candidate_match := candidate_name == column_name
		if !candidate_match {
			suffix := fmt.tprintf(".%s", column_name)
			candidate_match = strings.has_suffix(candidate_name, suffix)
		}
		if !candidate_match {
			continue
		}
		if found {
			return "", false, true
		}
		resolved_name = candidate_name
		found = true
	}
	return resolved_name, found, false
}

execution_bindings_are_unqualified_only :: proc(bindings: Bindings) -> bool {
	for binding in bindings.bindings {
		if execution_binding_name_is_qualified(binding.source_name) {
			return false
		}
	}
	return true
}

execution_bind_ident_slot :: proc(ident: ^AST_Ident, bindings: Bindings) -> bool {
	if ident.column_name == "*" {
		// COUNT(*) is a row-count semantic marker, not a column lookup.
		ident.slot_id = -1
		return true
	}
	// Binding once up front removes repeated name scans from row evaluation.
	full_name := ast_ident_as_string(ident)
	slot_id, found := execution_bindings_find_slot(bindings, full_name)
	if !found && ident.table_name != "" && execution_bindings_are_unqualified_only(bindings) {
		// Predicate pushdown binds against per-table scans whose local slots are unqualified.
		// Falling back only in single-source scopes preserves strictness for join bindings.
		slot_id, found = execution_bindings_find_slot(bindings, ident.column_name)
	}
	if !found && ident.table_name == "" && !execution_bindings_are_unqualified_only(bindings) {
		binding_names := make([dynamic]string, database_query_allocator)
		reserve(&binding_names, len(bindings.bindings))
		for binding in bindings.bindings {
			append_elem(&binding_names, binding.source_name)
		}
		resolved_name, resolved_found, ambiguous := execution_resolve_unqualified_column_name(
			ident.column_name,
			binding_names[:],
		)
		if ambiguous {
			db_msgf_at(
				.Error,
				ident.token,
				"Column '%v' is ambiguous between joined tables",
				ident.column_name,
			)
			return false
		}
		if resolved_found {
			slot_id, found = execution_bindings_find_slot(bindings, resolved_name)
		}
	}
	if !found {
		db_msgf_at(.Error, ident.token, "Unknown column '%v'", full_name)
		return false
	}
	ident.slot_id = slot_id
	return true
}

execution_bind_expression_slots :: proc(node: ^AST_Node, bindings: Bindings) -> bool {
	if ident, is_ident := node.value.(^AST_Ident); is_ident {
		return execution_bind_ident_slot(ident, bindings)
	}
	if cond, is_cond := node.value.(^Condition); is_cond {
		if !execution_bind_expression_slots(cond.a, bindings) {
			return false
		}
		return execution_bind_expression_slots(cond.b, bindings)
	}
	if unary, is_unary := node.value.(^Unary_Expression); is_unary {
		return execution_bind_expression_slots(unary.operand, bindings)
	}
	if binary, is_binary := node.value.(^Binary_Expression); is_binary {
		if !execution_bind_expression_slots(binary.a, bindings) {
			return false
		}
		return execution_bind_expression_slots(binary.b, bindings)
	}
	if node_list, is_list := node.value.([dynamic]^AST_Node); is_list {
		for child in node_list {
			if !execution_bind_expression_slots(child, bindings) {
				return false
			}
		}
	}
	return true
}

execution_filter_bind_conjunct_slots :: proc(
	filter: ^Execution_Filter,
	bindings: Bindings,
) -> bool {
	for conjunct in filter.conjuncts {
		if !execution_bind_expression_slots(conjunct, bindings) {
			return false
		}
	}
	filter.conjuncts_bound = true
	return true
}

execution_join_source_name :: proc(node: ^Execution_Node, source_name: string) -> string {
	for c in source_name {
		if c == '.' {
			return source_name
		}
	}

	if scan, is_scan := node^.(^Execution_Table_Scan); is_scan {
		return fmt.tprintf(
			"%s.%s",
			execution_alias_or_name_string(scan.table_name, scan.source_name),
			source_name,
		)
	}
	if scan, is_scan := node^.(^Execution_Pk_Scan); is_scan {
		return fmt.tprintf(
			"%s.%s",
			execution_alias_or_name_string(scan.table_name, scan.source_name),
			source_name,
		)
	}
	if scan, is_scan := node^.(^Execution_Index_Scan); is_scan {
		return fmt.tprintf(
			"%s.%s",
			execution_alias_or_name_string(scan.table_name, scan.source_name),
			source_name,
		)
	}
	if filter, is_filter := node^.(^Execution_Filter); is_filter {
		// Join-side predicate pushdown can wrap scans in filters.
		// Qualifying through passthrough nodes keeps join ON bindings stable.
		return execution_join_source_name(&filter.input, source_name)
	}
	if aggregate, is_aggregate := node^.(^Execution_Aggregate); is_aggregate {
		return execution_join_source_name(&aggregate.input, source_name)
	}
	if sort, is_sort := node^.(^Execution_Merge_Sort); is_sort {
		return execution_join_source_name(&sort.input, source_name)
	}
	if lim, is_limit := node^.(^Execution_Limit_Offset); is_limit {
		return execution_join_source_name(&lim.input, source_name)
	}
	if proj, is_project := node^.(^Execution_Project); is_project {
		if len(proj.projections) == 0 || execution_node_has_wildcard_projection(proj.projections) {
			return execution_join_source_name(&proj.input, source_name)
		}
	}
	return source_name
}

execution_join_build_row :: proc(left_row: Table_Row, right_row: Table_Row) -> []Database_Value {
	joined_row := make([dynamic]Database_Value, database_query_allocator)
	append_elems(&joined_row, ..left_row[:])
	append_elems(&joined_row, ..right_row[:])
	return joined_row[:]
}

execution_join_pull_all_rows :: proc(
	node: ^Execution_Node,
) -> (
	rows: [dynamic]Table_Row,
	ok: bool,
) {
	// Normalizes any execution source into a fully materialized row slice.
	// This is intentionally blocking and is used by join/sort paths that need
	// random access or repeated passes over their inputs.
	//
	// Supports both execution modes:
	// - row-storage pull (`execution_tree_next_row`)
	// - column-block pull (`execution_tree_next_block` + selected row extraction)
	rows = make([dynamic]Table_Row, database_query_allocator)
	if execution_tree_has_row_storage_scan(node) {
		for {
			values, has_row := execution_tree_next_row(node)
			if !has_row {
				return rows, true
			}
			row := make(Table_Row, len(values), database_query_allocator)
			for value, i in values {
				row[i] = value
			}
			append_elem(&rows, row)
		}
	}
	for {
		block, block_ok := execution_tree_next_block(node)
		if !block_ok {
			return rows, true
		}
		if !execution_data_block_is_valid(&block) {
			return rows, false
		}
		row := make(Table_Row, len(block.columns), database_query_allocator)
		for selected_i in 0 ..< block.selection_count {
			if !execution_data_block_selected_row_into(&block, selected_i, &row) {
				continue
			}
			append_elem(&rows, execution_row_clone(row[:]))
		}
	}
}

execution_keep_best_k_rows :: proc(
	rows: ^[dynamic]Table_Row,
	row: Table_Row,
	max_rows: int,
	order_items: []Order_By_Item,
	column_names: []string,
	has_joins: bool,
	base_table_name: string,
) -> bool {
	// Maintains an in-memory "best K" buffer ordered by ORDER BY comparator.
	//
	// Invariant: rows^ stays sorted ascending according to compare_rows_for_order_by,
	// so the worst kept row is always at the end. This lets us do:
	// - O(K) insertion while growing to K
	// - O(K) replacement + bubble-up when a better candidate arrives
	//
	// Used for LIMIT/OFFSET pushdown so we avoid full materialization when possible.
	if max_rows <= 0 {
		return true
	}

	row_clone := execution_row_clone(row[:])
	if len(rows^) < max_rows {
		append_elem(rows, row_clone)
		insert_at := len(rows^) - 1
		for insert_at > 0 {
			cmp, cmp_ok := compare_rows_for_order_by(
				rows^[insert_at],
				rows^[insert_at - 1],
				order_items,
				column_names,
				has_joins,
				base_table_name,
			)
			if !cmp_ok {
				return false
			}
			if cmp != .Less {
				break
			}
			rows^[insert_at], rows^[insert_at - 1] = rows^[insert_at - 1], rows^[insert_at]
			insert_at -= 1
		}
		return true
	}

	worst_i := len(rows^) - 1
	cmp_to_worst, cmp_ok := compare_rows_for_order_by(
		row_clone,
		rows^[worst_i],
		order_items,
		column_names,
		has_joins,
		base_table_name,
	)
	if !cmp_ok {
		return false
	}
	if cmp_to_worst != .Less {
		return true
	}

	rows^[worst_i] = row_clone
	for i := worst_i; i > 0; i -= 1 {
		cmp, row_cmp_ok := compare_rows_for_order_by(
			rows^[i],
			rows^[i - 1],
			order_items,
			column_names,
			has_joins,
			base_table_name,
		)
		if !row_cmp_ok {
			return false
		}
		if cmp != .Less {
			break
		}
		rows^[i], rows^[i - 1] = rows^[i - 1], rows^[i]
	}
	return true
}

execution_join_pull_top_k_rows :: proc(
	node: ^Execution_Node,
	max_rows: int,
	order_items: []Order_By_Item,
	column_names: []string,
	has_joins: bool,
	base_table_name: string,
) -> (
	rows: [dynamic]Table_Row,
	ok: bool,
) {
	rows = make([dynamic]Table_Row, database_query_allocator)
	if max_rows <= 0 {
		return rows, true
	}
	if execution_tree_has_row_storage_scan(node) {
		for {
			values, has_row := execution_tree_next_row(node)
			if !has_row {
				return rows, true
			}
			row := make(Table_Row, len(values), database_query_allocator)
			for value, i in values {
				row[i] = value
			}
			if !execution_keep_best_k_rows(
				&rows,
				row,
				max_rows,
				order_items,
				column_names,
				has_joins,
				base_table_name,
			) {
				return rows, false
			}
		}
	}
	for {
		block, block_ok := execution_tree_next_block(node)
		if !block_ok {
			return rows, true
		}
		if !execution_data_block_is_valid(&block) {
			return rows, false
		}
		row := make(Table_Row, len(block.columns), database_query_allocator)
		for selected_i in 0 ..< block.selection_count {
			if !execution_data_block_selected_row_into(&block, selected_i, &row) {
				continue
			}
			if !execution_keep_best_k_rows(
				&rows,
				row,
				max_rows,
				order_items,
				column_names,
				has_joins,
				base_table_name,
			) {
				return rows, false
			}
		}
	}
}

execution_merge_sort_bind_order_items :: proc(
	order_items: []Order_By_Item,
	column_names: []string,
	has_joins: bool,
	base_table_name: string,
) -> bool {
	for item in order_items {
		if !bind_expression_slots_to_row_columns(
			item.expr,
			column_names,
			has_joins,
			base_table_name,
		) {
			return false
		}
	}
	return true
}

execution_merge_sort_materialize_rows :: proc(
	sort_node: ^Execution_Merge_Sort,
	row_bound: int,
	has_row_bound: bool,
) -> bool {
	// Materializes and orders rows for ORDER BY once, then serves cached pulls.
	//
	// Two execution paths:
	// - bounded (top-k): when LIMIT/OFFSET above provides a safe row bound
	// - full sort: when global ordering requires consuming full input
	//
	// If prefix_sorted_terms > 0, upstream already guarantees a sorted prefix.
	// In that case we only refine tie groups for remaining ORDER BY terms.
	if sort_node.initialized {
		return true
	}
	input_bindings, input_bindings_ok := execution_tree_bindings(&sort_node.input)
	if !input_bindings_ok {
		return false
	}
	column_names := execution_column_names_from_bindings(input_bindings)
	if !execution_merge_sort_bind_order_items(
		sort_node.order_items[:],
		column_names,
		sort_node.has_joins,
		sort_node.base_table_name,
	) {
		return false
	}
	if has_row_bound {
		// LIMIT/OFFSET above this node can ask sort to retain only top-k rows.
		bounded_rows, bounded_ok := execution_join_pull_top_k_rows(
			&sort_node.input,
			row_bound,
			sort_node.order_items[:],
			column_names,
			sort_node.has_joins,
			sort_node.base_table_name,
		)
		if !bounded_ok {
			return false
		}
		sort_node.sorted_rows = bounded_rows
	} else {
		// ORDER BY is intentionally blocking here: we need the full input before
		// producing deterministic globally ordered output rows.
		all_rows, all_rows_ok := execution_join_pull_all_rows(&sort_node.input)
		if !all_rows_ok {
			return false
		}
		sort_node.sorted_rows = all_rows
	}
	if sort_node.prefix_sorted_terms > 0 &&
	   sort_node.prefix_sorted_terms < len(sort_node.order_items) {
		if !order_by_tie_group_refine(
			&sort_node.sorted_rows,
			sort_node.order_items[:],
			sort_node.prefix_sorted_terms,
			column_names,
			sort_node.has_joins,
			sort_node.base_table_name,
		) {
			return false
		}
	} else {
		if !merge_sort_rows_for_order_by(
			&sort_node.sorted_rows,
			sort_node.order_items[:],
			column_names,
			sort_node.has_joins,
			sort_node.base_table_name,
		) {
			return false
		}
	}
	sort_node.initialized = true
	sort_node.row_i = 0
	return true
}

execution_join_value_key :: proc(value: Database_Value) -> string {
	return fmt.tprintf("%v", value)
}

execution_join_build_hash_pairs :: proc(join: ^Execution_Join, left_slot: int, right_slot: int) {
	// Builds join.matched_pairs using a hash build/probe strategy on equality keys.
	//
	// Design choices:
	// - hash the smaller side to reduce bucket memory footprint
	// - store row indexes (not row copies) so pair materialization is cheap
	// - canonicalize resulting (left_i,right_i) order to match nested-loop semantics,
	//   which keeps output deterministic across algorithm switches
	// Classic build/probe: materialize the hash on the smaller input so bucket index storage
	// scales with min(|L|, |R|) instead of always |R|.
	buckets := make(map[string][dynamic]int, database_query_allocator)
	defer delete(buckets)

	build_left := len(join.left_rows) <= len(join.right_rows)
	if build_left {
		for left_row, left_i in join.left_rows {
			key := execution_join_value_key(left_row[left_slot])
			bucket, found := buckets[key]
			if !found {
				bucket = make([dynamic]int, database_query_allocator)
			}
			append_elem(&bucket, left_i)
			buckets[key] = bucket
		}
		join.matched_pairs = make([dynamic][2]int, database_query_allocator)
		for right_row, right_i in join.right_rows {
			key := execution_join_value_key(right_row[right_slot])
			bucket, found := buckets[key]
			if !found {
				continue
			}
			for left_i in bucket {
				append_elem(&join.matched_pairs, [2]int{left_i, right_i})
			}
		}
	} else {
		for right_row, right_i in join.right_rows {
			key := execution_join_value_key(right_row[right_slot])
			bucket, found := buckets[key]
			if !found {
				bucket = make([dynamic]int, database_query_allocator)
			}
			append_elem(&bucket, right_i)
			buckets[key] = bucket
		}
		join.matched_pairs = make([dynamic][2]int, database_query_allocator)
		for left_row, left_i in join.left_rows {
			key := execution_join_value_key(left_row[left_slot])
			bucket, found := buckets[key]
			if !found {
				continue
			}
			for right_i in bucket {
				append_elem(&join.matched_pairs, [2]int{left_i, right_i})
			}
		}
	}
	// Build/probe order depends on which side was hashed; canonicalize so results match
	// nested-loop order (all matches for earlier left rows before later ones).
	if len(join.matched_pairs) > 1 {
		sort.merge_sort_proc(join.matched_pairs[:], proc(a, b: [2]int) -> int {
			switch {
			case a[0] < b[0]:
				return -1
			case a[0] > b[0]:
				return 1
			case a[1] < b[1]:
				return -1
			case a[1] > b[1]:
				return 1
			}
			return 0
		})
	}
}

execution_join_build_merge_pairs :: proc(join: ^Execution_Join, left_slot: int, right_slot: int) {
	// Builds join.matched_pairs with a merge-join style sweep over sorted key indexes.
	//
	// Approach:
	// - index+sort both sides by join key (stable row index retained in slot 1)
	// - walk both sorted lists with two pointers
	// - for each equal-key run, emit full cross product of matching left/right runs
	//
	// This keeps comparisons linear after sorting and naturally handles duplicate keys.
	left_indexed := make([dynamic][2]int, database_query_allocator)
	right_indexed := make([dynamic][2]int, database_query_allocator)
	for _, left_i in join.left_rows {
		append_elem(&left_indexed, [2]int{left_i, left_i})
	}
	for _, right_i in join.right_rows {
		append_elem(&right_indexed, [2]int{right_i, right_i})
	}

	sort_pairs := proc(indexed: ^[dynamic][2]int, rows: [dynamic]Table_Row, slot: int) {
		for i := 1; i < len(indexed); i += 1 {
			j := i
			for j > 0 {
				prev := indexed[j - 1][1]
				curr := indexed[j][1]
				prev_key := execution_join_value_key(rows[prev][slot])
				curr_key := execution_join_value_key(rows[curr][slot])
				if prev_key <= curr_key {
					break
				}
				indexed[j - 1], indexed[j] = indexed[j], indexed[j - 1]
				j -= 1
			}
		}
	}

	sort_pairs(&left_indexed, join.left_rows, left_slot)
	sort_pairs(&right_indexed, join.right_rows, right_slot)

	join.matched_pairs = make([dynamic][2]int, database_query_allocator)
	left_i, right_i := 0, 0
	for left_i < len(left_indexed) && right_i < len(right_indexed) {
		left_row_i := left_indexed[left_i][1]
		right_row_i := right_indexed[right_i][1]
		left_key := execution_join_value_key(join.left_rows[left_row_i][left_slot])
		right_key := execution_join_value_key(join.right_rows[right_row_i][right_slot])
		if left_key < right_key {
			left_i += 1
			continue
		}
		if left_key > right_key {
			right_i += 1
			continue
		}

		right_start := right_i
		for right_i < len(right_indexed) {
			key_row_i := right_indexed[right_i][1]
			key := execution_join_value_key(join.right_rows[key_row_i][right_slot])
			if key != left_key {
				break
			}
			right_i += 1
		}

		for left_i < len(left_indexed) {
			match_left_row_i := left_indexed[left_i][1]
			key := execution_join_value_key(join.left_rows[match_left_row_i][left_slot])
			if key != left_key {
				break
			}
			for match_right_i := right_start; match_right_i < right_i; match_right_i += 1 {
				match_right_row_i := right_indexed[match_right_i][1]
				append_elem(&join.matched_pairs, [2]int{match_left_row_i, match_right_row_i})
			}
			left_i += 1
		}
	}
}

execution_join_build_strategy_state :: proc(join: ^Execution_Join) {
	// Precomputes algorithm-specific pair state for joins that support it.
	//
	// We only specialize when ON is a simple equality between identifiable slots.
	// If slot extraction fails (or condition is non-equality), we intentionally
	// fall back to nested-loop so correctness wins over optimization.
	if join.algorithm == .Nested_Loop || join.condition == nil {
		return
	}
	left_ident, right_ident, eq_ok := execution_join_condition_idents_for_equality(join.condition)
	if !eq_ok {
		join.algorithm = .Nested_Loop
		return
	}
	left_slot := left_ident.slot_id
	right_slot := right_ident.slot_id - join.left_width
	if left_slot < 0 || right_slot < 0 {
		join.algorithm = .Nested_Loop
		return
	}

	if join.algorithm == .Hash {
		execution_join_build_hash_pairs(join, left_slot, right_slot)
	} else if join.algorithm == .Merge {
		execution_join_build_merge_pairs(join, left_slot, right_slot)
	}
	join.pair_i = 0
}

execution_join_init_state :: proc(join: ^Execution_Join) -> bool {
	// One-time join initialization before first row pull:
	// - materialize both children
	// - compute left/right widths from bindings (needed for slot math)
	// - allocate right-side match tracking for RIGHT JOIN null-extension
	// - reset iteration cursors and precompute strategy state (hash/merge pairs)
	//
	// After this returns true, join node can be consumed incrementally.
	left_rows, left_ok := execution_join_pull_all_rows(&join.left)
	if !left_ok {
		return false
	}
	right_rows, right_ok := execution_join_pull_all_rows(&join.right)
	if !right_ok {
		return false
	}
	join.left_rows = left_rows
	join.right_rows = right_rows

	left_bindings, left_bindings_ok := execution_tree_bindings(&join.left)
	if !left_bindings_ok {
		return false
	}
	right_bindings, right_bindings_ok := execution_tree_bindings(&join.right)
	if !right_bindings_ok {
		return false
	}
	join.left_width = len(left_bindings.bindings)
	join.right_width = len(right_bindings.bindings)

	if join.join_type == .Right {
		join.matched_right_rows = make([]bool, len(join.right_rows), database_query_allocator)
	}

	join.left_i = 0
	join.right_i = 0
	join.left_row_matched = false
	join.emitting_unmatched_right = false
	join.unmatched_right_i = 0
	execution_join_build_strategy_state(join)
	join.initialized = true
	return true
}

@(require_results)
execution_tree_bindings :: proc(node: ^Execution_Node) -> (result: Bindings, ok: bool) {
	// Computes the output binding layout (column name -> slot id) for any node.
	//
	// This is the contract that keeps expression binding stable across the tree:
	// every operator downstream depends on slot ids produced here. For nodes that
	// reshape schemas (join/project/aggregate), we build fresh bindings; passthrough
	// nodes (filter/sort/limit) delegate to input bindings.
	//
	// Some branches lazily initialize node metadata (table handles/output names)
	// so the binding pass can remain the single source of truth for schema shape.
	switch n in node^ {
	case ^Execution_Table_Scan:
		if !n.initialized {
			n.table = database_find_table(n.table_name, true) or_return
			execution_table_scan_resolve_required_columns(n)
			n.row_i = 0
			n.initialized = true
		}
		if len(n.required_column_names) == 0 {
			resize(&result.bindings, len(n.table.column_names))
			for col_name, i in n.table.column_names {
				result.bindings[i] = Binding {
					source_name = col_name,
					slot_id     = i,
				}
			}
			return result, true
		}
		resize(&result.bindings, len(n.required_column_names))
		for col_name, i in n.required_column_names {
			result.bindings[i] = Binding {
				source_name = col_name,
				slot_id     = i,
			}
		}
		return result, true
	case ^Execution_Filter:
		return execution_tree_bindings(&n.input)
	case ^Execution_Aggregate:
		if len(n.output_column_names) == 0 {
			n.output_column_names = make([]string, len(n.projections), database_query_allocator)
			for projection, i in n.projections {
				n.output_column_names[i] = projection_expr_name(projection)
			}
		}
		resize(&result.bindings, len(n.output_column_names))
		for col_name, i in n.output_column_names {
			result.bindings[i] = Binding {
				source_name = col_name,
				slot_id     = i,
			}
		}
		return result, true
	case ^Execution_Project:
		input_bindings := execution_tree_bindings(&n.input) or_return
		execution_project_prepare_output_names(n, input_bindings) or_return
		if len(n.projections) == 0 || execution_node_has_wildcard_projection(n.projections) {
			return input_bindings, true
		}
		resize(&result.bindings, len(n.output_column_names))
		for col_name, i in n.output_column_names {
			result.bindings[i] = Binding {
				source_name = col_name,
				slot_id     = i,
			}
		}
		return result, true
	case ^Execution_Merge_Sort:
		return execution_tree_bindings(&n.input)
	case ^Execution_Limit_Offset:
		return execution_tree_bindings(&n.input)
	case ^Execution_Pk_Scan:
		table := n.table
		if table == nil {
			table = database_find_table(n.table_name, true) or_return
		}
		resize(&result.bindings, len(table.column_names))
		for col_name, i in table.column_names {
			result.bindings[i] = Binding {
				source_name = col_name,
				slot_id     = i,
			}
		}
		return result, true
	case ^Execution_Index_Scan:
		table := n.table
		if table == nil {
			table = database_find_table(n.table_name, true) or_return
		}
		resize(&result.bindings, len(table.column_names))
		for col_name, i in table.column_names {
			result.bindings[i] = Binding {
				source_name = col_name,
				slot_id     = i,
			}
		}
		return result, true
	case ^Execution_Subquery_Scan:
		rows := n.rows
		if len(rows.column_names) == 0 {
			subquery_root, _, _ := plan_select_execution_tree(n.select) or_return
			rows = exec_execution_tree_rows(subquery_root) or_return
		}
		resize(&result.bindings, len(rows.column_names))
		for col_name, i in rows.column_names {
			result.bindings[i] = Binding {
				source_name = col_name,
				slot_id     = i,
			}
		}
		return result, true
	case ^Execution_Join:
		if n.bindings_ready do return n.join_bindings, true

		left_bindings := execution_tree_bindings(&n.left) or_return
		right_bindings := execution_tree_bindings(&n.right) or_return

		left_offset := len(result.bindings)
		resize(&result.bindings, left_offset + len(left_bindings.bindings))
		for left_binding, i in left_bindings.bindings {
			result.bindings[left_offset + i] = Binding {
				source_name = execution_join_source_name(&n.left, left_binding.source_name),
				slot_id     = left_offset + i,
			}
		}

		right_offset := len(result.bindings)
		resize(&result.bindings, right_offset + len(right_bindings.bindings))
		for right_binding, i in right_bindings.bindings {
			result.bindings[right_offset + i] = Binding {
				source_name = execution_join_source_name(&n.right, right_binding.source_name),
				slot_id     = right_offset + i,
			}
		}

		if n.condition != nil && !n.condition_bound {
			execution_bind_expression_slots(n.condition, result) or_return
			n.condition_bound = true
		}

		n.join_bindings = result
		n.bindings_ready = true
		return result, true

	case ^Execution_Insert,
	     ^Execution_Update,
	     ^Execution_Delete,
	     ^Execution_Create_Table,
	     ^Execution_Create_Index,
	     ^Execution_Alter_Table,
	     ^Execution_Drop_Table,
	     ^Execution_Begin_Transaction,
	     ^Execution_Commit_Transaction,
	     ^Execution_Rollback_Transaction:
		// Command nodes are not row sources, so bindings are undefined by design.
		return
	case:
		unreachable()
	}
}

execution_tree_has_row_storage_scan :: proc(node: ^Execution_Node) -> bool {
	#partial switch n in node^ {
	case ^Execution_Table_Scan:
		table := database_find_table(n.table_name, true) or_return
		table_storage_ensure(table)
		_, is_rows := table.storage.([dynamic]Table_Row)
		return is_rows
	case ^Execution_Filter:
		return execution_tree_has_row_storage_scan(&n.input)
	case ^Execution_Project:
		return execution_tree_has_row_storage_scan(&n.input)
	case ^Execution_Aggregate:
		return execution_tree_has_row_storage_scan(&n.input)
	case ^Execution_Merge_Sort:
		return execution_tree_has_row_storage_scan(&n.input)
	case ^Execution_Limit_Offset:
		return execution_tree_has_row_storage_scan(&n.input)
	case ^Execution_Join:
		return(
			execution_tree_has_row_storage_scan(&n.left) ||
			execution_tree_has_row_storage_scan(&n.right) \
		)
	case:
		return false
	}
}

exec_execution_tree_rows :: proc(node: ^Execution_Node) -> (result: Rows_With_Names, ok: bool) {
	if execution_tree_has_row_storage_scan(node) {
		// Keep row and vectorized execution physically separate.
		bindings := execution_tree_bindings(node) or_return
		return execution_tree_collect_rows_from_next(node)
	}

	bindings := execution_tree_bindings(node) or_return
	column_names := execution_column_names_from_bindings(bindings)
	result = Rows_With_Names {
		column_names = column_names,
		rows         = make([dynamic]Table_Row, database_query_allocator),
	}

	for {
		block, block_ok := execution_tree_next_block(node)
		if !block_ok {
			return result, true
		}
		if !execution_data_block_is_valid(&block) {
			return result, false
		}
		for selected_i in 0 ..< block.selection_count {
			row, row_ok := execution_data_block_selected_row(&block, selected_i)
			if !row_ok {
				continue
			}
			append_elem(&result.rows, row)
		}
	}
}

execution_column_names_from_bindings :: proc(bindings: Bindings) -> []string {
	column_names := make([dynamic]string, database_query_allocator)
	resize(&column_names, len(bindings.bindings))
	for binding in bindings.bindings {
		if binding.slot_id >= 0 && binding.slot_id < len(column_names) {
			column_names[binding.slot_id] = binding.source_name
		}
	}
	return column_names[:]
}

execution_make_table_scan_node :: proc(
	table_name: string,
	source_name: string,
	required_columns: []string,
) -> ^Execution_Node {
	scan := new(Execution_Table_Scan, database_query_allocator)
	scan^ = Execution_Table_Scan {
		table_name            = table_name,
		source_name           = source_name,
		required_column_names = required_columns,
	}
	root := new(Execution_Node, database_query_allocator)
	root^ = scan
	return root
}

execution_make_insert_node :: proc(insert: ^Insert) -> ^Execution_Node {
	insert_node := new(Execution_Insert, database_query_allocator)
	insert_node^ = Execution_Insert {
		insert = insert,
	}
	root := new(Execution_Node, database_query_allocator)
	root^ = insert_node
	return root
}

execution_make_update_node :: proc(update: ^Update) -> ^Execution_Node {
	update_node := new(Execution_Update, database_query_allocator)
	update_node^ = Execution_Update {
		update = update,
	}
	root := new(Execution_Node, database_query_allocator)
	root^ = update_node
	return root
}

execution_make_delete_node :: proc(delete_stmt: ^Delete) -> ^Execution_Node {
	delete_node := new(Execution_Delete, database_query_allocator)
	delete_node^ = Execution_Delete {
		delete_stmt = delete_stmt,
	}
	root := new(Execution_Node, database_query_allocator)
	root^ = delete_node
	return root
}

execution_make_create_table_node :: proc(create_table: ^Create_Table) -> ^Execution_Node {
	create_table_node := new(Execution_Create_Table, database_query_allocator)
	create_table_node^ = Execution_Create_Table {
		create_table = create_table,
	}
	root := new(Execution_Node, database_query_allocator)
	root^ = create_table_node
	return root
}

execution_make_create_index_node :: proc(create_index: ^Create_Index) -> ^Execution_Node {
	create_index_node := new(Execution_Create_Index, database_query_allocator)
	create_index_node^ = Execution_Create_Index {
		create_index = create_index,
	}
	root := new(Execution_Node, database_query_allocator)
	root^ = create_index_node
	return root
}

execution_make_alter_table_node :: proc(alter_table: ^Alter_Table) -> ^Execution_Node {
	alter_table_node := new(Execution_Alter_Table, database_query_allocator)
	alter_table_node^ = Execution_Alter_Table {
		alter_table = alter_table,
	}
	root := new(Execution_Node, database_query_allocator)
	root^ = alter_table_node
	return root
}

execution_make_drop_table_node :: proc(drop_table: ^Drop_Table) -> ^Execution_Node {
	drop_table_node := new(Execution_Drop_Table, database_query_allocator)
	drop_table_node^ = Execution_Drop_Table {
		drop_table = drop_table,
	}
	root := new(Execution_Node, database_query_allocator)
	root^ = drop_table_node
	return root
}

execution_make_begin_transaction_node :: proc(
	begin_transaction: ^Begin_Transaction,
) -> ^Execution_Node {
	begin_transaction_node := new(Execution_Begin_Transaction, database_query_allocator)
	begin_transaction_node^ = Execution_Begin_Transaction {
		begin_transaction = begin_transaction,
	}
	root := new(Execution_Node, database_query_allocator)
	root^ = begin_transaction_node
	return root
}

execution_make_commit_transaction_node :: proc(
	commit_transaction: ^Commit_Transaction,
) -> ^Execution_Node {
	commit_transaction_node := new(Execution_Commit_Transaction, database_query_allocator)
	commit_transaction_node^ = Execution_Commit_Transaction {
		commit_transaction = commit_transaction,
	}
	root := new(Execution_Node, database_query_allocator)
	root^ = commit_transaction_node
	return root
}

execution_make_rollback_transaction_node :: proc(
	rollback_transaction: ^Rollback_Transaction,
) -> ^Execution_Node {
	rollback_transaction_node := new(Execution_Rollback_Transaction, database_query_allocator)
	rollback_transaction_node^ = Execution_Rollback_Transaction {
		rollback_transaction = rollback_transaction,
	}
	root := new(Execution_Node, database_query_allocator)
	root^ = rollback_transaction_node
	return root
}

plan_command_execution_tree :: proc(node: ^AST_Node) -> (root: ^Execution_Node, ok: bool) {
	#partial switch v in node.value {
	case ^Insert:
		return execution_make_insert_node(v), true
	case ^Update:
		return execution_make_update_node(v), true
	case ^Delete:
		return execution_make_delete_node(v), true
	case ^Create_Table:
		return execution_make_create_table_node(v), true
	case ^Create_Index:
		return execution_make_create_index_node(v), true
	case ^Alter_Table:
		return execution_make_alter_table_node(v), true
	case ^Drop_Table:
		return execution_make_drop_table_node(v), true
	case ^Begin_Transaction:
		return execution_make_begin_transaction_node(v), true
	case ^Commit_Transaction:
		return execution_make_commit_transaction_node(v), true
	case ^Rollback_Transaction:
		return execution_make_rollback_transaction_node(v), true
	case:
		db_msgf_at(.Error, node.token, "Unsupported command node type: %T", v)
		return nil, false
	}
}

exec_execution_tree_command :: proc(node: ^Execution_Node) -> (result: Maybe(int), ok: bool) {
	#partial switch n in node^ {
	case ^Execution_Insert:
		count := exec_insert(n.insert) or_return
		return count, true
	case ^Execution_Update:
		count := exec_update(n.update) or_return
		return count, true
	case ^Execution_Delete:
		count := exec_delete(n.delete_stmt) or_return
		return count, true
	case ^Execution_Create_Table:
		if !exec_create_table(n.create_table) {
			return {}, false
		}
		return nil, true
	case ^Execution_Create_Index:
		if !exec_create_index(n.create_index) {
			return {}, false
		}
		return nil, true
	case ^Execution_Alter_Table:
		if !exec_alter_table(n.alter_table) {
			return {}, false
		}
		return nil, true
	case ^Execution_Drop_Table:
		if !exec_drop_table(n.drop_table) {
			return {}, false
		}
		return nil, true
	case ^Execution_Begin_Transaction:
		if !exec_begin_transaction() {
			return {}, false
		}
		return nil, true
	case ^Execution_Commit_Transaction:
		if !exec_commit_transaction() {
			return {}, false
		}
		return nil, true
	case ^Execution_Rollback_Transaction:
		if !exec_rollback_transaction() {
			return {}, false
		}
		return nil, true
	case:
		msgf(.Error, .Database, "Expected command execution node, got %T", n)
		return {}, false
	}
}

execution_append_where_filter_node :: proc(
	root: ^Execution_Node,
	where_expr: ^AST_Node,
) -> ^Execution_Node {
	filter := new(Execution_Filter, database_query_allocator)
	filter^ = Execution_Filter {
		input = root^,
	}
	conjunct_i := len(filter.conjuncts)
	resize(&filter.conjuncts, conjunct_i + 1)
	filter.conjuncts[conjunct_i] = where_expr

	filter_node := new(Execution_Node, database_query_allocator)
	filter_node^ = filter
	return filter_node
}

Execution_Projection_Requirement :: struct {
	table_name: string,
	columns:    [dynamic]string,
}

Execution_Optimized_Select :: struct {
	joins:                        [dynamic]Join,
	where_clause:                 ^AST_Node,
	projections:                  [dynamic]^AST_Node,
	projection_output_names:      [dynamic]string,
	per_table_projection_require: [dynamic]Execution_Projection_Requirement,
	per_table_filter_clauses:     [dynamic]Execution_Table_Filter_Clause,
}

Execution_Table_Filter_Clause :: struct {
	table_name:   string,
	where_clause: ^AST_Node,
}

execution_collect_identifiers :: proc(node: ^AST_Node, out: ^[dynamic]^AST_Ident) {
	if node == nil {
		return
	}
	if ident, is_ident := node.value.(^AST_Ident); is_ident {
		append_elem(out, ident)
		return
	}
	if cond, is_cond := node.value.(^Condition); is_cond {
		execution_collect_identifiers(cond.a, out)
		execution_collect_identifiers(cond.b, out)
		return
	}
	if unary, is_unary := node.value.(^Unary_Expression); is_unary {
		execution_collect_identifiers(unary.operand, out)
		return
	}
	if binary, is_binary := node.value.(^Binary_Expression); is_binary {
		execution_collect_identifiers(binary.a, out)
		execution_collect_identifiers(binary.b, out)
		return
	}
	if aggregate, is_aggregate := node.value.(^AST_Aggregate_Call); is_aggregate {
		for arg in aggregate.args {
			execution_collect_identifiers(arg, out)
		}
		return
	}
	if list, is_list := node.value.([dynamic]^AST_Node); is_list {
		for list_node in list {
			execution_collect_identifiers(list_node, out)
		}
	}
}

execution_expression_has_wildcard :: proc(expr: ^AST_Node) -> bool {
	idents := make([dynamic]^AST_Ident, database_query_allocator)
	execution_collect_identifiers(expr, &idents)
	for ident in idents {
		if ident.column_name == "*" {
			return true
		}
	}
	return false
}

execution_projection_requirement_get_or_insert :: proc(
	requirements: ^[dynamic]Execution_Projection_Requirement,
	table_name: string,
) -> ^Execution_Projection_Requirement {
	for i := 0; i < len(requirements^); i += 1 {
		if requirements^[i].table_name == table_name {
			return &requirements^[i]
		}
	}
	append_elem(
		requirements,
		Execution_Projection_Requirement {
			table_name = table_name,
			columns = make([dynamic]string, database_query_allocator),
		},
	)
	return &requirements^[len(requirements^) - 1]
}

execution_projection_requirement_add_column :: proc(
	requirements: ^[dynamic]Execution_Projection_Requirement,
	table_name: string,
	column_name: string,
) {
	req := execution_projection_requirement_get_or_insert(requirements, table_name)
	for existing in req.columns {
		if existing == column_name {
			return
		}
	}
	append_elem(&req.columns, column_name)
}

execution_flatten_and_conjuncts :: proc(node: ^AST_Node, out: ^[dynamic]^AST_Node) {
	if node == nil {
		return
	}
	cond, is_cond := node.value.(^Condition)
	if !is_cond || cond.op.token.kind != .And {
		append_elem(out, node)
		return
	}
	execution_flatten_and_conjuncts(cond.a, out)
	execution_flatten_and_conjuncts(cond.b, out)
}

execution_rebuild_and_conjuncts :: proc(conjuncts: []^AST_Node) -> ^AST_Node {
	if len(conjuncts) == 0 {
		return nil
	}
	root := conjuncts[0]
	for i := 1; i < len(conjuncts); i += 1 {
		root = execution_tree_ast_condition(root, .And, "AND", conjuncts[i])
	}
	return root
}

execution_tables_contains :: proc(tables: []string, table_name: string) -> bool {
	for candidate in tables {
		if candidate == table_name {
			return true
		}
	}
	return false
}

execution_expr_single_table_reference :: proc(expr: ^AST_Node) -> (table_name: string, ok: bool) {
	idents := make([dynamic]^AST_Ident, database_query_allocator)
	execution_collect_identifiers(expr, &idents)
	if len(idents) == 0 {
		return "", false
	}
	referenced_table := ""
	for ident in idents {
		if ident.table_name == "" {
			// Keeping unqualified columns above the join avoids ambiguity surprises in multi-table queries.
			return "", false
		}
		if referenced_table == "" {
			referenced_table = ident.table_name
			continue
		}
		if referenced_table != ident.table_name {
			return "", false
		}
	}
	return referenced_table, true
}

execution_join_predicate_push_down_enabled :: proc(joins: []Join) -> bool {
	for join in joins {
		if join.join_type == .Left || join.join_type == .Right {
			return false
		}
	}
	return true
}

execution_table_filter_clause_get_or_insert :: proc(
	clauses: ^[dynamic]Execution_Table_Filter_Clause,
	table_name: string,
) -> ^Execution_Table_Filter_Clause {
	for i := 0; i < len(clauses^); i += 1 {
		if clauses^[i].table_name == table_name {
			return &clauses^[i]
		}
	}
	append_elem(clauses, Execution_Table_Filter_Clause{table_name = table_name})
	return &clauses^[len(clauses^) - 1]
}

execution_push_down_join_predicates :: proc(
	leftmost_table_name: string,
	joins: []Join,
	where_clause: ^AST_Node,
) -> (
	per_table_filter_clauses: [dynamic]Execution_Table_Filter_Clause,
	residual_where_clause: ^AST_Node,
) {
	per_table_filter_clauses = make(
		[dynamic]Execution_Table_Filter_Clause,
		database_query_allocator,
	)
	if where_clause == nil ||
	   len(joins) == 0 ||
	   !execution_join_predicate_push_down_enabled(joins) {
		return per_table_filter_clauses, where_clause
	}
	known_tables := make([dynamic]string, database_query_allocator)
	append_elem(&known_tables, leftmost_table_name)
	for join in joins {
		join_source_name, join_source_ok := execution_join_source_name_from_ast(join)
		if !join_source_ok {
			continue
		}
		append_elem(&known_tables, join_source_name)
	}

	conjuncts := make([dynamic]^AST_Node, database_query_allocator)
	execution_flatten_and_conjuncts(where_clause, &conjuncts)
	residual_conjuncts := make([dynamic]^AST_Node, database_query_allocator)
	for conjunct in conjuncts {
		table_name, single_table_ok := execution_expr_single_table_reference(conjunct)
		if !single_table_ok {
			append_elem(&residual_conjuncts, conjunct)
			continue
		}
		if !execution_tables_contains(known_tables[:], table_name) {
			append_elem(&residual_conjuncts, conjunct)
			continue
		}
		clause := execution_table_filter_clause_get_or_insert(
			&per_table_filter_clauses,
			table_name,
		)
		if clause.where_clause == nil {
			clause.where_clause = conjunct
		} else {
			clause.where_clause = execution_tree_ast_condition(
				clause.where_clause,
				.And,
				"AND",
				conjunct,
			)
		}
	}

	return per_table_filter_clauses, execution_rebuild_and_conjuncts(residual_conjuncts[:])
}

execution_required_filter_for_table :: proc(
	per_table_filter_clauses: []Execution_Table_Filter_Clause,
	table_name: string,
) -> ^AST_Node {
	for table_filter in per_table_filter_clauses {
		if table_filter.table_name != table_name {
			continue
		}
		return table_filter.where_clause
	}
	return nil
}

execution_maybe_wrap_with_table_filter :: proc(
	node: ^Execution_Node,
	per_table_filter_clauses: []Execution_Table_Filter_Clause,
	table_name: string,
) -> ^Execution_Node {
	filter_expr := execution_required_filter_for_table(per_table_filter_clauses, table_name)
	if filter_expr == nil {
		return node
	}
	return execution_append_where_filter_node(node, filter_expr)
}

execution_join_condition_idents_for_equality :: proc(
	condition: ^AST_Node,
) -> (
	left_ident: ^AST_Ident,
	right_ident: ^AST_Ident,
	ok: bool,
) {
	if condition == nil {
		return nil, nil, false
	}
	cond, is_cond := condition.value.(^Condition)
	if !is_cond || cond.op.token.kind != .Equals {
		return nil, nil, false
	}
	left_ident_local, left_ok := cond.a.value.(^AST_Ident)
	if !left_ok {
		return nil, nil, false
	}
	right_ident_local, right_ok := cond.b.value.(^AST_Ident)
	if !right_ok {
		return nil, nil, false
	}
	if left_ident_local.table_name == "" || right_ident_local.table_name == "" {
		return nil, nil, false
	}
	return left_ident_local, right_ident_local, true
}

execution_collect_projection_requirements_from_expr :: proc(
	requirements: ^[dynamic]Execution_Projection_Requirement,
	expr: ^AST_Node,
	select_table_name: string,
	joins: []Join,
	join_query: bool,
) {
	idents := make([dynamic]^AST_Ident, database_query_allocator)
	execution_collect_identifiers(expr, &idents)
	for ident in idents {
		if ident.column_name == "*" {
			return
		}
		if ident.table_name != "" {
			execution_projection_requirement_add_column(
				requirements,
				ident.table_name,
				ident.column_name,
			)
			continue
		}
		if join_query {
			// Unqualified columns in join queries remain visible on every source to avoid ambiguity regressions.
			execution_projection_requirement_add_column(
				requirements,
				select_table_name,
				ident.column_name,
			)
			for join in joins {
				join_source_name, join_source_ok := execution_join_source_name_from_ast(join)
				if !join_source_ok {
					continue
				}
				execution_projection_requirement_add_column(
					requirements,
					join_source_name,
					ident.column_name,
				)
			}
		} else {
			execution_projection_requirement_add_column(
				requirements,
				select_table_name,
				ident.column_name,
			)
		}
	}
}

execution_optimize_cross_joins :: proc(
	joins: ^[dynamic]Join,
	where_clause: ^AST_Node,
	leftmost_table_name: string,
) -> ^AST_Node {
	if len(joins) == 0 || where_clause == nil {
		return where_clause
	}
	known_tables := make([dynamic]string, database_query_allocator)
	append_elem(&known_tables, leftmost_table_name)
	conjuncts := make([dynamic]^AST_Node, database_query_allocator)
	execution_flatten_and_conjuncts(where_clause, &conjuncts)

	for join_i := 0; join_i < len(joins^); join_i += 1 {
		if joins^[join_i].join_type != .Cross {
			if join_source_name, source_ok := execution_join_source_name_from_ast(joins^[join_i]);
			   source_ok {
				append_elem(&known_tables, join_source_name)
			}
			continue
		}

		right_table, right_table_ok := execution_join_source_name_from_ast(joins^[join_i])
		if !right_table_ok {
			continue
		}

		for conjunct_i := 0; conjunct_i < len(conjuncts); conjunct_i += 1 {
			left_ident, right_ident, eq_ok := execution_join_condition_idents_for_equality(
				conjuncts[conjunct_i],
			)
			if !eq_ok {
				continue
			}
			left_is_right_table := left_ident.table_name == right_table
			right_is_right_table := right_ident.table_name == right_table
			if left_is_right_table == right_is_right_table {
				continue
			}
			other_table := left_ident.table_name
			if left_is_right_table {
				other_table = right_ident.table_name
			}
			if !execution_tables_contains(known_tables[:], other_table) {
				continue
			}

			// Rewriting this CROSS join to INNER lets downstream strategy selection pick faster operators.
			joins^[join_i].join_type = .Inner
			joins^[join_i].condition = conjuncts[conjunct_i]
			for shift_i := conjunct_i; shift_i + 1 < len(conjuncts); shift_i += 1 {
				conjuncts[shift_i] = conjuncts[shift_i + 1]
			}
			resize(&conjuncts, len(conjuncts) - 1)
			break
		}

		append_elem(&known_tables, right_table)
	}

	return execution_rebuild_and_conjuncts(conjuncts[:])
}

execution_collect_projection_requirements :: proc(
	select_table_name: string,
	joins: []Join,
	projections: []^AST_Node,
	where_clause: ^AST_Node,
	group_by: []^AST_Node,
	having: ^AST_Node,
	per_table_filters: []Execution_Table_Filter_Clause,
	order_by: []Order_By_Item,
) -> [dynamic]Execution_Projection_Requirement {
	requirements := make([dynamic]Execution_Projection_Requirement, database_query_allocator)
	join_query := len(joins) > 0

	for projection in projections {
		if execution_expression_has_wildcard(projection) {
			return requirements
		}
	}
	for order_item in order_by {
		if execution_expression_has_wildcard(order_item.expr) {
			return requirements
		}
	}

	for projection in projections {
		execution_collect_projection_requirements_from_expr(
			&requirements,
			projection,
			select_table_name,
			joins,
			join_query,
		)
	}
	execution_collect_projection_requirements_from_expr(
		&requirements,
		where_clause,
		select_table_name,
		joins,
		join_query,
	)
	for group_expr in group_by {
		execution_collect_projection_requirements_from_expr(
			&requirements,
			group_expr,
			select_table_name,
			joins,
			join_query,
		)
	}
	execution_collect_projection_requirements_from_expr(
		&requirements,
		having,
		select_table_name,
		joins,
		join_query,
	)
	for order_item in order_by {
		execution_collect_projection_requirements_from_expr(
			&requirements,
			order_item.expr,
			select_table_name,
			joins,
			join_query,
		)
	}
	for join in joins {
		execution_collect_projection_requirements_from_expr(
			&requirements,
			join.condition,
			select_table_name,
			joins,
			join_query,
		)
	}
	for table_filter in per_table_filters {
		execution_collect_projection_requirements_from_expr(
			&requirements,
			table_filter.where_clause,
			select_table_name,
			joins,
			join_query,
		)
	}
	return requirements
}

execution_alias_or_name :: proc(name: string, alias: Maybe(string)) -> string {
	if alias_name, has_alias := alias.?; has_alias {
		return alias_name
	}
	return name
}

execution_alias_or_name_string :: proc(name: string, alias: string) -> string {
	if alias != "" {
		return alias
	}
	return name
}

execution_join_physical_table_name :: proc(join: Join) -> (table_name: string, ok: bool) {
	join_ident, ident_ok := join.table.value.(^AST_Ident)
	if !ident_ok {
		return "", false
	}
	return join_ident.column_name, true
}

execution_join_source_name_from_ast :: proc(join: Join) -> (source_name: string, ok: bool) {
	table_name, table_ok := execution_join_physical_table_name(join)
	if !table_ok {
		return "", false
	}
	return execution_alias_or_name(table_name, join.table_alias), true
}

execution_required_columns_for_table :: proc(
	requirements: []Execution_Projection_Requirement,
	table_name: string,
) -> []string {
	for requirement in requirements {
		if requirement.table_name == table_name {
			return requirement.columns[:]
		}
	}
	return nil
}

execution_choose_join_algorithm :: proc(join: Join) -> Join_Algorithm {
	if join.join_type != .Inner {
		return .Nested_Loop
	}
	left_ident, right_ident, ok := execution_join_condition_idents_for_equality(join.condition)
	if !ok {
		return .Nested_Loop
	}
	if left_ident.column_name == "id" && right_ident.column_name == "id" {
		return .Merge
	}
	return .Hash
}

execution_order_guarantee_for_scan :: proc(
	select: ^Select,
	table: ^Table,
	table_name: string,
	order_plan: Order_Index_Plan,
) -> Execution_Order_Guarantee {
	guarantee := Execution_Order_Guarantee{}
	if len(select.order_by) <= 0 {
		return guarantee
	}
	first_item := select.order_by[0]
	first_ident, is_ident := first_item.expr.value.(^AST_Ident)
	if !is_ident {
		return guarantee
	}
	if first_item.descending != order_plan.descending {
		return guarantee
	}

	matches := false
	switch order_plan.strategy {
	case .Primary:
		matches = ident_matches_table_column(
			first_ident,
			table,
			table_name,
			table.primary_key_column_index,
		)
		if matches {
			guarantee.duplicates_possible = false
		}
	case .Indexed:
		if order_plan.index_position < 0 || order_plan.index_position >= len(table.indexes) {
			return guarantee
		}
		idx := table.indexes[order_plan.index_position]
		matches = ident_matches_table_column(first_ident, table, table_name, idx.column_index)
		if matches {
			guarantee.duplicates_possible = true
		}
	case .None:
		return guarantee
	}
	if !matches {
		return Execution_Order_Guarantee{}
	}

	guarantee.available = true
	guarantee.source_table_name = table_name
	guarantee.column_name = first_ident.column_name
	guarantee.descending = first_item.descending
	guarantee.prefix_sorted_terms = 1
	return guarantee
}

execution_join_preserves_left_order :: proc(
	join_type: Join_Type,
	algorithm: Join_Algorithm,
) -> bool {
	return algorithm == .Nested_Loop && join_type != .Right
}

execution_order_guarantee_matches_first_item :: proc(
	guarantee: Execution_Order_Guarantee,
	select: ^Select,
) -> bool {
	guarantee.available or_return
	(len(select.order_by) > 0) or_return

	first_item := select.order_by[0]
	first_ident := first_item.expr.value.(^AST_Ident) or_return

	(first_item.descending == guarantee.descending) or_return
	(first_ident.column_name == guarantee.column_name) or_return
	(first_ident.table_name == "" ||
		first_ident.table_name == guarantee.source_table_name) or_return

	return true
}

execution_wrap_node_ptr :: proc(node: $T) -> ^Execution_Node {
	wrapped := new(Execution_Node, database_query_allocator)
	wrapped^ = node
	return wrapped
}

execution_make_pk_order_scan_node :: proc(
	table_name: string,
	source_name: string,
	order_plan: Order_Index_Plan,
) -> ^Execution_Node {
	pk_scan := new(Execution_Pk_Scan, database_query_allocator)
	pk_scan^ = Execution_Pk_Scan {
		table_name = table_name,
		source_name = source_name,
		descending = order_plan.descending,
		plan = Pk_Where_Plan{strategy = .Interval, interval = pk_interval_unbounded()},
	}
	return execution_wrap_node_ptr(pk_scan)
}

execution_make_index_order_scan_node :: proc(
	table_name: string,
	source_name: string,
	order_plan: Order_Index_Plan,
) -> ^Execution_Node {
	index_scan := new(Execution_Index_Scan, database_query_allocator)
	index_scan^ = Execution_Index_Scan {
		table_name = table_name,
		source_name = source_name,
		descending = order_plan.descending,
		plan = Index_Filter_Plan {
			index_position = order_plan.index_position,
			strategy = .Interval,
			interval = pk_interval_unbounded(),
		},
	}
	return execution_wrap_node_ptr(index_scan)
}

execution_try_make_order_scan_node :: proc(
	select: ^Select,
	table: ^Table,
	table_name: string,
	source_name: string,
	order_plan: Order_Index_Plan,
) -> (
	root: ^Execution_Node,
	guarantee: Execution_Order_Guarantee,
	ok: bool,
) {
	switch order_plan.strategy {
	case .Primary:
		root = execution_make_pk_order_scan_node(table_name, source_name, order_plan)
	case .Indexed:
		root = execution_make_index_order_scan_node(table_name, source_name, order_plan)
	case .None:
		return
	}

	guarantee = execution_order_guarantee_for_scan(select, table, source_name, order_plan)
	return root, guarantee, true
}

// Builds the SELECT execution tree in explicit planner phases.
// 1) validate semantics, 2) optimize/push down predicates,
// 3) plan FROM source (single-table plan when possible),
// 4) attach joins, 5) apply post-relational operators.
//
// - have_plan/applied_plan are only meaningful for single-table (no JOIN) planning.
// - where_done_from_clause tracks whether WHERE was fully consumed by base scan planning.
// - order_guarantee tracks whether current root preserves a useful ORDER BY prefix.
plan_select_execution_tree :: proc(
	select: ^Select,
) -> (
	root: ^Execution_Node,
	applied_plan: Single_Table_Select_Plan,
	have_plan: bool,
	ok: bool,
) {
	select_table_name := ""
	select_source_name := ""
	where_done_from_clause := false
	order_guarantee: Execution_Order_Guarantee

	has_aggregate := false
	{
		// validation_phase: reject invalid aggregate usage before planning.
		has_aggregate = execution_select_has_aggregate(select)
		if execution_expr_contains_aggregate(select.where_clause) {
			db_msgf_at(.Error, select.token, "Aggregate functions are not allowed in WHERE")
			return
		}

		if select.having != nil && len(select.group_by) == 0 && !has_aggregate {
			db_msgf_at(.Error, select.token, "HAVING requires GROUP BY or aggregate expressions")
			return
		}

		if (len(select.group_by) > 0 || has_aggregate) &&
		   !execution_validate_grouped_projection_rules(select) {
			return
		}
	}

	optimized := Execution_Optimized_Select {
		joins                   = make([dynamic]Join, database_query_allocator),
		where_clause            = select.where_clause,
		projections             = make([dynamic]^AST_Node, database_query_allocator),
		projection_output_names = make([dynamic]string, database_query_allocator),
	}
	{
		// logical_optimization_phase: capture projected expressions and join list.
		for item in select.cols {
			append_elem(&optimized.projections, item.expr)
			if alias_name, has_alias := item.alias.?; has_alias {
				append_elem(&optimized.projection_output_names, alias_name)
			} else {
				append_elem(&optimized.projection_output_names, projection_expr_name(item.expr))
			}
		}
		append_elems(&optimized.joins, ..select.joins[:])
	}
	{
		// from_source_phase: seed root from FROM item and evaluate single-table access paths.
		#partial switch source in select.table_or_subquery.value {
		case ^Select:
			subquery_scan := new(Execution_Subquery_Scan, database_query_allocator)
			subquery_scan^ = Execution_Subquery_Scan {
				select = source,
			}
			root = execution_wrap_node_ptr(subquery_scan)

		case ^AST_Ident:
			select_table_name = ast_ident_as_string(source)
			select_source_name = execution_alias_or_name(select_table_name, select.table_alias)
			optimized.where_clause = execution_optimize_cross_joins(
				&optimized.joins,
				optimized.where_clause,
				select_source_name,
			)
			optimized.per_table_filter_clauses, optimized.where_clause =
				execution_push_down_join_predicates(
					select_source_name,
					optimized.joins[:],
					optimized.where_clause,
				)
			optimized.per_table_projection_require = execution_collect_projection_requirements(
				select_source_name,
				optimized.joins[:],
				optimized.projections[:],
				optimized.where_clause,
				select.group_by[:],
				select.having,
				optimized.per_table_filter_clauses[:],
				select.order_by[:],
			)

			required_columns := execution_required_columns_for_table(
				optimized.per_table_projection_require[:],
				select_source_name,
			)

			if len(select.joins) == 0 {
				select_table, table_ok := database_find_table(select_table_name, false)
				if !table_ok {
					db_msgf_at(
						.Error,
						select.table_or_subquery.token,
						"Table '%v' does not exist",
						select_table_name,
					)
					return nil, {}, false, false
				}

				// Single-table plan is fully materialized into applied_plan/have_plan.
				applied_plan = single_table_select_plan_init()
				applied_plan.order_plan, applied_plan.order_plan_available =
					order_index_plan_for_select(select, select_table, select_table_name)
				if optimized.where_clause != nil {
					pk_plan_ok := false
					applied_plan.pk_plan, pk_plan_ok = analyze_pk_where_for_table(
						optimized.where_clause,
						select_table,
						select_source_name,
					)
					if pk_plan_ok {
						applied_plan.where_plan_kind = .Pk
					} else {
						index_filter_ok := false
						applied_plan.index_filter_plan, index_filter_ok =
							analyze_index_where_for_table(
								optimized.where_clause,
								select_table,
								select_source_name,
							)
						if index_filter_ok {
							applied_plan.where_plan_kind = .Index
						} else {
							applied_plan.where_plan_kind = .None
						}
					}
				} else {
					applied_plan.where_plan_kind = .None
				}
				single_table_select_plan_set_index_positions(&applied_plan, select_table)

				if optimized.where_clause == nil && applied_plan.order_plan_available {
					// Without WHERE, ORDER index scan is the only meaningful access path.
					applied_plan.chosen_strategy = .Where_First
					applied_plan.used_order_scan = true
				} else {
					applied_plan.chosen_strategy = choose_single_table_scan_strategy(
						select_table,
						applied_plan.order_plan_available,
						applied_plan.order_plan,
						applied_plan.where_plan_kind,
						applied_plan.pk_plan,
						applied_plan.index_filter_plan,
						select.limit,
						select.offset,
					)
					applied_plan.used_order_scan =
						applied_plan.order_plan_available &&
						optimized.where_clause != nil &&
						applied_plan.chosen_strategy == .Order_First
				}

				if applied_plan.used_order_scan {
					// ORDER-first strategy scans in key order and leaves residual WHERE above.
					order_scan_root, scan_order_guarantee, scan_ok :=
						execution_try_make_order_scan_node(
							select,
							select_table,
							select_table_name,
							select_source_name,
							applied_plan.order_plan,
						)
					if scan_ok {
						root = order_scan_root
						order_guarantee = scan_order_guarantee
					} else {
						root = execution_make_table_scan_node(
							select_table_name,
							select_source_name,
							required_columns,
						)
					}
				} else {
					switch applied_plan.where_plan_kind {
					case .Pk:
						pk_scan := new(Execution_Pk_Scan, database_query_allocator)
						pk_scan^ = Execution_Pk_Scan {
							table_name  = select_table_name,
							source_name = select_source_name,
							plan        = applied_plan.pk_plan,
						}
						root = execution_wrap_node_ptr(pk_scan)
						where_done_from_clause = !applied_plan.pk_plan.residual_where
					case .Index:
						index_scan := new(Execution_Index_Scan, database_query_allocator)
						index_scan^ = Execution_Index_Scan {
							table_name  = select_table_name,
							source_name = select_source_name,
							plan        = applied_plan.index_filter_plan,
						}
						root = execution_wrap_node_ptr(index_scan)
						where_done_from_clause = !applied_plan.index_filter_plan.residual_where
					case .None:
						if optimized.where_clause == nil && applied_plan.order_plan_available {
							order_scan_root, scan_order_guarantee, scan_ok :=
								execution_try_make_order_scan_node(
									select,
									select_table,
									select_table_name,
									select_source_name,
									applied_plan.order_plan,
								)
							if scan_ok {
								root = order_scan_root
								order_guarantee = scan_order_guarantee
							} else {
								root = execution_make_table_scan_node(
									select_table_name,
									select_source_name,
									required_columns,
								)
							}
						} else {
							root = execution_make_table_scan_node(
								select_table_name,
								select_source_name,
								required_columns,
							)
						}
					}
				}
				have_plan = true
			} else {
				root = execution_make_table_scan_node(
					select_table_name,
					select_source_name,
					required_columns,
				)
				// Keep join planning metadata-only when schema isn't seeded (planner tests).
				if select_table, table_ok := database_find_table(
					select_table_name,
					log_error = false,
				); table_ok {
					base_order_plan, base_order_ok := order_index_plan_for_select(
						select,
						select_table,
						select_source_name,
					)
					if base_order_ok {
						order_scan_root, scan_order_guarantee, scan_ok :=
							execution_try_make_order_scan_node(
								select,
								select_table,
								select_table_name,
								select_source_name,
								base_order_plan,
							)
						if scan_ok {
							root = order_scan_root
							order_guarantee = scan_order_guarantee
						}
					}
				}
				root = execution_maybe_wrap_with_table_filter(
					root,
					optimized.per_table_filter_clauses[:],
					select_source_name,
				)
			}

		case:
			db_msgf_at(
				.Error,
				select.token,
				"Invalid table name: %v",
				select.table_or_subquery.value,
			)
			return nil, {}, false, false
		}
	}

	{
		// join_attachment_phase: add every JOIN as a binary node above current root.
		for join in optimized.joins {
			// TODO: the proc should show an error instead of the caller
			join_table_name, table_ok := execution_join_physical_table_name(join)
			if !table_ok {
				db_msgf_at(.Error, join.token, "Expected join table to be Ident")
				return
			}

			// TODO: the proc should show an error instead of the caller
			join_source_name, source_ok := execution_join_source_name_from_ast(join)
			if !source_ok {
				db_msgf_at(.Error, join.token, "Expected join source name")
				return
			}

			right_node := execution_make_table_scan_node(
				join_table_name,
				join_source_name,
				execution_required_columns_for_table(
					optimized.per_table_projection_require[:],
					join_source_name,
				),
			)
			right_node = execution_maybe_wrap_with_table_filter(
				right_node,
				optimized.per_table_filter_clauses[:],
				join_source_name,
			)

			join_algorithm := execution_choose_join_algorithm(join)
			join_node := new_clone(
				Execution_Join {
					left = root^,
					right = right_node^,
					condition = join.condition,
					join_type = join.join_type,
					algorithm = join_algorithm,
				},
				database_query_allocator,
			)
			root = execution_wrap_node_ptr(join_node)

			// Once order-sensitive joins appear, base scan ordering is no longer guaranteed.
			if order_guarantee.available &&
			   !execution_join_preserves_left_order(join.join_type, join_algorithm) {
				order_guarantee = Execution_Order_Guarantee{}
			}
		}
	}
	{
		// post_relational_phase: add operators that always sit above FROM/JOIN planning.
		if optimized.where_clause != nil && !where_done_from_clause {
			root = execution_append_where_filter_node(root, optimized.where_clause)
		}

		if len(select.group_by) > 0 || has_aggregate {
			aggregate_node := new_clone(
				Execution_Aggregate {
					input = root^,
					group_by = select.group_by,
					projections = optimized.projections,
					having = select.having,
					has_joins = len(select.joins) > 0,
					base_table_name = select_source_name,
					output_column_names = optimized.projection_output_names[:],
				},
				database_query_allocator,
			)
			root = execution_wrap_node_ptr(aggregate_node)

			// Aggregation output is now projected by output aliases/expr names.
			optimized.projections = make([dynamic]^AST_Node, database_query_allocator)
			for projection, projection_i in select.cols {
				projection_name := optimized.projection_output_names[projection_i]
				append_elem(&optimized.projections, execution_tree_ast_ident(projection_name))
			}

			// ORDER BY aggregate expressions must be rewritten to post-aggregate names.
			if len(select.order_by) > 0 {
				rewritten_order := make([dynamic]Order_By_Item, database_query_allocator)
				for item in select.order_by {
					rewritten_expr := item.expr
					if execution_expr_contains_aggregate(item.expr) {
						rewritten_expr = execution_tree_ast_ident(projection_expr_name(item.expr))
					}
					append_elem(
						&rewritten_order,
						Order_By_Item{expr = rewritten_expr, descending = item.descending},
					)
				}
				select.order_by = rewritten_order
			}
		}

		needs_merge_sort := len(select.order_by) > 0
		prefix_sorted_terms := 0
		if needs_merge_sort &&
		   execution_order_guarantee_matches_first_item(order_guarantee, select) {
			prefix_sorted_terms = order_guarantee.prefix_sorted_terms
			if len(select.order_by) <= prefix_sorted_terms {
				needs_merge_sort = false
			}
		}
		if needs_merge_sort {
			sort_node := new(Execution_Merge_Sort, database_query_allocator)
			sort_node^ = Execution_Merge_Sort {
				input               = root^,
				order_items         = select.order_by,
				has_joins           = len(select.joins) > 0,
				base_table_name     = select_source_name,
				prefix_sorted_terms = prefix_sorted_terms,
			}
			root = execution_wrap_node_ptr(sort_node)
		}

		_, has_offset := select.offset.?
		_, has_limit := select.limit.?
		if has_offset || has_limit {
			limit_node := new(Execution_Limit_Offset, database_query_allocator)
			limit_node.input = root^
			if off, has_off := select.offset.?; has_off {
				limit_node.offset = off
			}
			if lim, has_lim := select.limit.?; has_lim {
				limit_node.has_limit = true
				limit_node.limit = lim
			}
			root = execution_wrap_node_ptr(limit_node)
		}

		project_node := new(Execution_Project, database_query_allocator)
		project_node^ = Execution_Project {
			input               = root^,
			projections         = optimized.projections,
			has_joins           = len(select.joins) > 0,
			base_table_name     = select_source_name,
			output_column_names = optimized.projection_output_names[:],
		}
		root = execution_wrap_node_ptr(project_node)
	}

	return root, applied_plan, have_plan, true
}

execution_tree_ast_ident :: proc(column_name: string) -> ^AST_Node {
	ident := new(AST_Ident, database_query_allocator)
	ident^ = AST_Ident {
		node = AST_Node{value = ident},
		table_name = "",
		column_name = column_name,
		slot_id = -1,
	}
	return &ident.node
}


execution_tree_ast_qualified_ident :: proc(table_name: string, column_name: string) -> ^AST_Node {
	ident := new(AST_Ident, database_query_allocator)
	ident^ = AST_Ident {
		node = AST_Node{value = ident},
		table_name = table_name,
		column_name = column_name,
		slot_id = -1,
	}
	return &ident.node
}


execution_tree_ast_int :: proc(value: int) -> ^AST_Node {
	number := new(AST_Int, database_query_allocator)
	number^ = AST_Int {
		node = AST_Node{value = number},
		int = value,
	}
	return &number.node
}


execution_tree_ast_string :: proc(value: string) -> ^AST_Node {
	text := new(AST_String, database_query_allocator)
	text^ = AST_String {
		node = AST_Node{value = text},
		text = value,
	}
	return &text.node
}


execution_tree_ast_operator :: proc(kind: Token_Kind, text: string) -> ^AST_Node {
	op := new(AST_String, database_query_allocator)
	op^ = AST_String {
		node = AST_Node{token = Token{kind = kind, text = text}, value = op},
		text = text,
	}
	return &op.node
}


execution_tree_ast_condition :: proc(
	left: ^AST_Node,
	op_kind: Token_Kind,
	op_text: string,
	right: ^AST_Node,
) -> ^AST_Node {
	op := execution_tree_ast_operator(op_kind, op_text)
	condition := new(Condition, database_query_allocator)
	condition^ = Condition {
		node = AST_Node{value = condition},
		a = left,
		op = op,
		b = right,
	}
	return &condition.node
}


execution_tree_rows_cell :: proc(
	rows: Rows_With_Names,
	row_i: int,
	column_name: string,
) -> Database_Value {
	col_i := -1
	for name, i in rows.column_names {
		if name == column_name {
			col_i = i
			break
		}
	}
	assert(col_i >= 0)
	return rows.rows[row_i][col_i]
}


execution_tree_collect_rows_from_next :: proc(
	node: ^Execution_Node,
) -> (
	result: Rows_With_Names,
	ok: bool,
) {
	bindings := execution_tree_bindings(node) or_return
	column_names := execution_column_names_from_bindings(bindings)

	result = Rows_With_Names {
		column_names = column_names,
		rows         = make([dynamic]Table_Row, database_query_allocator),
	}

	for values in execution_tree_next_row(node) {
		append(&result.rows, slice.clone_to_dynamic(values, database_query_allocator))
	}

	ok = true
	return
}

// TODO: consider removing this, we already have procs for parsing a query
execution_tree_parse_select :: proc(query: string) -> (result: ^Select, ok: bool) {
	tokens := tokenize(query) or_return
	parser := parser_init(tokens[:], query, database_query_allocator)
	query_node := parse_query(&parser) or_return
	select_stmt := query_node.value.(^Select) or_return
	return select_stmt, true
}

execution_tree_find_join_node :: proc(
	node: ^Execution_Node,
) -> (
	result: ^Execution_Join,
	ok: bool,
) {
	switch n in node^ {
	case ^Execution_Join:
		return n, true

	case ^Execution_Project:
		return execution_tree_find_join_node(&n.input)

	case ^Execution_Aggregate:
		return execution_tree_find_join_node(&n.input)

	case ^Execution_Filter:
		return execution_tree_find_join_node(&n.input)

	case ^Execution_Merge_Sort:
		return execution_tree_find_join_node(&n.input)

	case ^Execution_Limit_Offset:
		return execution_tree_find_join_node(&n.input)

	case ^Execution_Table_Scan,
	     ^Execution_Pk_Scan,
	     ^Execution_Index_Scan,
	     ^Execution_Subquery_Scan,
	     ^Execution_Insert,
	     ^Execution_Update,
	     ^Execution_Delete,
	     ^Execution_Create_Table,
	     ^Execution_Create_Index,
	     ^Execution_Alter_Table,
	     ^Execution_Drop_Table,
	     ^Execution_Begin_Transaction,
	     ^Execution_Commit_Transaction,
	     ^Execution_Rollback_Transaction:
		return

	case:
		unreachable()
	}
}

execution_tree_find_merge_sort_node :: proc(
	node: ^Execution_Node,
) -> (
	result: ^Execution_Merge_Sort,
	ok: bool,
) {
	switch n in node^ {

	case ^Execution_Merge_Sort:
		return n, true

	case ^Execution_Project:
		return execution_tree_find_merge_sort_node(&n.input)

	case ^Execution_Aggregate:
		return execution_tree_find_merge_sort_node(&n.input)

	case ^Execution_Filter:
		return execution_tree_find_merge_sort_node(&n.input)

	case ^Execution_Limit_Offset:
		return execution_tree_find_merge_sort_node(&n.input)

	case ^Execution_Join:
		return execution_tree_find_merge_sort_node(&n.left)

	case ^Execution_Table_Scan,
	     ^Execution_Pk_Scan,
	     ^Execution_Index_Scan,
	     ^Execution_Subquery_Scan,
	     ^Execution_Insert,
	     ^Execution_Update,
	     ^Execution_Delete,
	     ^Execution_Create_Table,
	     ^Execution_Create_Index,
	     ^Execution_Alter_Table,
	     ^Execution_Drop_Table,
	     ^Execution_Begin_Transaction,
	     ^Execution_Commit_Transaction,
	     ^Execution_Rollback_Transaction:
		return

	case:
		unreachable()
	}
}

execution_tree_find_table_scan :: proc(
	node: ^Execution_Node,
	table_name: string,
) -> (
	result: ^Execution_Table_Scan,
	ok: bool,
) {
	switch n in node^ {
	case ^Execution_Table_Scan:
		if n.table_name == table_name do return n, true
		return

	case ^Execution_Join:
		left_scan, left_ok := execution_tree_find_table_scan(&n.left, table_name)
		if left_ok do return left_scan, true
		return execution_tree_find_table_scan(&n.right, table_name)

	case ^Execution_Project:
		return execution_tree_find_table_scan(&n.input, table_name)

	case ^Execution_Aggregate:
		return execution_tree_find_table_scan(&n.input, table_name)

	case ^Execution_Filter:
		return execution_tree_find_table_scan(&n.input, table_name)

	case ^Execution_Merge_Sort:
		return execution_tree_find_table_scan(&n.input, table_name)

	case ^Execution_Limit_Offset:
		return execution_tree_find_table_scan(&n.input, table_name)

	case ^Execution_Pk_Scan,
	     ^Execution_Index_Scan,
	     ^Execution_Subquery_Scan,
	     ^Execution_Insert,
	     ^Execution_Update,
	     ^Execution_Delete,
	     ^Execution_Create_Table,
	     ^Execution_Create_Index,
	     ^Execution_Alter_Table,
	     ^Execution_Drop_Table,
	     ^Execution_Begin_Transaction,
	     ^Execution_Commit_Transaction,
	     ^Execution_Rollback_Transaction:
		return

	case:
		unreachable()
	}
}

execution_tree_find_filter_directly_above_table_scan :: proc(
	node: ^Execution_Node,
	table_name: string,
) -> (
	result: ^Execution_Filter,
	ok: bool,
) {
	switch n in node^ {

	case ^Execution_Filter:
		scan, scan_ok := n.input.(^Execution_Table_Scan)
		if scan_ok && scan.table_name == table_name do return n, true
		return execution_tree_find_filter_directly_above_table_scan(&n.input, table_name)

	case ^Execution_Join:
		left_filter, left_ok := execution_tree_find_filter_directly_above_table_scan(
			&n.left,
			table_name,
		)
		if left_ok do return left_filter, true
		return execution_tree_find_filter_directly_above_table_scan(&n.right, table_name)

	case ^Execution_Project:
		return execution_tree_find_filter_directly_above_table_scan(&n.input, table_name)

	case ^Execution_Merge_Sort:
		return execution_tree_find_filter_directly_above_table_scan(&n.input, table_name)

	case ^Execution_Aggregate:
		return execution_tree_find_filter_directly_above_table_scan(&n.input, table_name)

	case ^Execution_Limit_Offset:
		return execution_tree_find_filter_directly_above_table_scan(&n.input, table_name)

	case ^Execution_Table_Scan,
	     ^Execution_Pk_Scan,
	     ^Execution_Index_Scan,
	     ^Execution_Subquery_Scan,
	     ^Execution_Insert,
	     ^Execution_Update,
	     ^Execution_Delete,
	     ^Execution_Create_Table,
	     ^Execution_Create_Index,
	     ^Execution_Alter_Table,
	     ^Execution_Drop_Table,
	     ^Execution_Begin_Transaction,
	     ^Execution_Commit_Transaction,
	     ^Execution_Rollback_Transaction:
		return

	case:
		unreachable()
	}
}
