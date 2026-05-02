#+vet explicit-allocators

package main

import "core:log"
import "core:slice"

// Half-open style bounds in PK sort order (value_index_cmp). Nil bound = unbounded on that side.
Pk_Interval :: struct {
	lo:        Maybe(Database_Value),
	lo_strict: bool, // if lo has value: true => key > lo; false => key >= lo
	hi:        Maybe(Database_Value),
	hi_strict: bool, // if hi has value: true => key < hi; false => key <= hi
}

Pk_Tree_Strategy :: enum {
	Full_Scan,
	Interval,
	Points,
}

// When strategy is Interval or Points, the tree can narrow candidate rows. residual_where means
// evaluate_expression must still run (non-PK conjuncts or forms we did not fold).
Pk_Where_Plan :: struct {
	strategy:       Pk_Tree_Strategy,
	interval:       Pk_Interval,
	points:         [dynamic]Database_Value,
	residual_where: bool,
}

pk_interval_unbounded :: proc() -> Pk_Interval {
	return {}
}

pk_interval_intersect :: proc(a, b: Pk_Interval) -> Pk_Interval {
	cmp :: value_ordering_for_column_sorting
	r: Pk_Interval

	la_val, la_ok := a.lo.?
	lb_val, lb_ok := b.lo.?
	if !la_ok {
		r.lo = b.lo
		r.lo_strict = b.lo_strict
	} else if !lb_ok {
		r.lo = a.lo
		r.lo_strict = a.lo_strict
	} else {
		o := cmp(la_val, lb_val)
		switch o {
		case .Less:
			r.lo = b.lo
			r.lo_strict = b.lo_strict
		case .Greater:
			r.lo = a.lo
			r.lo_strict = a.lo_strict
		case .Equal:
			r.lo = a.lo
			r.lo_strict = a.lo_strict || b.lo_strict
		}
	}

	ha_val, ha_ok := a.hi.?
	hb_val, hb_ok := b.hi.?
	if !ha_ok {
		r.hi = b.hi
		r.hi_strict = b.hi_strict
	} else if !hb_ok {
		r.hi = a.hi
		r.hi_strict = a.hi_strict
	} else {
		o := cmp(ha_val, hb_val)
		switch o {
		case .Less:
			r.hi = a.hi
			r.hi_strict = a.hi_strict
		case .Greater:
			r.hi = b.hi
			r.hi_strict = b.hi_strict
		case .Equal:
			r.hi = a.hi
			r.hi_strict = a.hi_strict || b.hi_strict
		}
	}

	return r
}

// Returns false if no Database_Value can satisfy the interval (including lo > hi).
pk_interval_nonempty :: proc(it: Pk_Interval) -> bool {
	lo_v, has_lo := it.lo.?
	if !has_lo do return true

	hi_v, has_hi := it.hi.?
	if !has_hi do return true

	o := value_ordering_for_column_sorting(lo_v, hi_v)
	switch o {
	case .Less:
		return true
	case .Greater:
		return false
	case .Equal:
		// lo == hi: need both inclusive for a single key, else empty
		if it.lo_strict do return false
		if it.hi_strict do return false
		return true
	}
	return false
}

ident_matches_primary_key :: proc(ident: ^AST_Ident, table: ^Table, table_name: string) -> bool {
	pk_col := table.column_names[table.primary_key_column_index]
	(ident.column_name == pk_col) or_return
	(ident.table_name == "" || ident.table_name == table_name) or_return
	return true
}

try_evaluate_constant_term :: proc(node: ^AST_Node) -> (val: Database_Value, ok: bool) {
	res := evaluate_term_bound(node, {}) or_return
	return res.(Database_Value), true
}

flatten_and_conjuncts :: proc(node: ^AST_Node, out: ^[dynamic]^AST_Node) {
	if cond, ok := node.value.(^Condition); ok && cond.op.token.kind == .And {
		flatten_and_conjuncts(cond.a, out)
		flatten_and_conjuncts(cond.b, out)
		return
	}
	append(out, node)
}

// Tries to collect pk = lit leaves from a tree of ORs; fails if any leaf is not pk = constant.
try_collect_or_pk_equals :: proc(
	node: ^AST_Node,
	table: ^Table,
	table_name: string,
	out: ^[dynamic]Database_Value,
) -> bool {
	if cond, ok := node.value.(^Condition); ok && cond.op.token.kind == .Or {
		if !try_collect_or_pk_equals(cond.a, table, table_name, out) {
			return false
		}
		return try_collect_or_pk_equals(cond.b, table, table_name, out)
	}
	if cond, ok := node.value.(^Condition); ok && cond.op.token.kind == .Equals {
		l_ident, l_ok := cond.a.value.(^AST_Ident)
		r_ident, r_ok := cond.b.value.(^AST_Ident)
		if l_ok && ident_matches_primary_key(l_ident, table, table_name) && !r_ok {
			v, cok := try_evaluate_constant_term(cond.b)
			if cok {
				append(out, v)
				return true
			}
		}
		if r_ok && ident_matches_primary_key(r_ident, table, table_name) && !l_ok {
			v, cok := try_evaluate_constant_term(cond.a)
			if cok {
				append(out, v)
				return true
			}
		}
	}
	return false
}

merge_interval_from_comparison :: proc(
	it: ^Pk_Interval,
	op: Token_Kind,
	pk_on_left: bool,
	const_val: Database_Value,
) {
	#partial switch op {
	case .Equals:
		it.lo = const_val
		it.lo_strict = false
		it.hi = const_val
		it.hi_strict = false
	case .Greater_Than:
		if pk_on_left {
			it.lo = const_val
			it.lo_strict = true
		} else {
			// const > pk  =>  pk < const
			it.hi = const_val
			it.hi_strict = true
		}
	case .Gt_Eq:
		if pk_on_left {
			it.lo = const_val
			it.lo_strict = false
		} else {
			// const >= pk  =>  pk <= const
			it.hi = const_val
			it.hi_strict = false
		}
	case .Less_Than:
		if pk_on_left {
			it.hi = const_val
			it.hi_strict = true
		} else {
			// const < pk  =>  pk > const
			it.lo = const_val
			it.lo_strict = true
		}
	case .Lt_Eq:
		if pk_on_left {
			it.hi = const_val
			it.hi_strict = false
		} else {
			// const <= pk  =>  pk >= const
			it.lo = const_val
			it.lo_strict = false
		}
	case:
		panic("merge_interval_from_comparison: unexpected op")
	}
}

try_merge_conjunct :: proc(
	it: ^Pk_Interval,
	strategy: ^Pk_Tree_Strategy,
	points: ^[dynamic]Database_Value,
	node: ^AST_Node,
	table: ^Table,
	table_name: string,
) -> (
	residual: bool,
	impossible: bool,
) {
	if unary, is_u := node.value.(^Unary_Expression); is_u {
		_ = is_u
		return true, false
	}

	if cond, okc := node.value.(^Condition); okc && cond.op.token.kind == .And {
		subs := make([dynamic]^AST_Node, database_query_allocator)
		flatten_and_conjuncts(node, &subs)
		any_res := false
		any_imp := false
		for s in subs {
			r, imp := try_merge_conjunct(it, strategy, points, s, table, table_name)
			if r do any_res = true
			if imp do any_imp = true
		}
		return any_res, any_imp
	}

	if cond, okc := node.value.(^Condition); okc {
		op_token := cond.op.token
		#partial switch op_token.kind {
		case .Or:
			return true, false
		case .In:
			l_ident, li_ok := cond.a.value.(^AST_Ident)
			if !li_ok || !ident_matches_primary_key(l_ident, table, table_name) {
				return true, false
			}
			list, is_list := cond.b.value.([dynamic]^AST_Node)
			if !is_list {
				return true, false
			}
			vals := make([dynamic]Database_Value, database_query_allocator)
			for n in list {
				v, vok := try_evaluate_constant_term(n)
				if !vok do return true, false
				append(&vals, v)
			}
			if strategy^ == .Full_Scan {
				strategy^ = .Points
				append(points, ..vals[:])
			} else if strategy^ == .Interval {
				strategy^ = .Points
				clear(points)
				for v in vals {
					if pk_value_in_interval(v, it^) do append(points, v)
				}
			} else if strategy^ == .Points {
				new_pts := make([dynamic]Database_Value, database_query_allocator)
				for pv in points {
					for v in vals {
						if value_exactly_equal(pv, v) {
							append(&new_pts, pv)
							break
						}
					}
				}
				clear(points)
				append(points, ..new_pts[:])
			}
			return false, len(points) == 0
		case .Between:
			l_ident, li_ok := cond.a.value.(^AST_Ident)
			if !li_ok do return true, false
			if !ident_matches_primary_key(l_ident, table, table_name) do return true, false

			node_list, is_list := cond.b.value.([dynamic]^AST_Node)
			if !is_list do return true, false
			if len(node_list) != 2 do return true, false

			low_v, ok1 := try_evaluate_constant_term(node_list[0])
			high_v, ok2 := try_evaluate_constant_term(node_list[1])
			if !ok1 do return true, false
			if !ok2 do return true, false

			sub: Pk_Interval
			sub.lo = low_v
			sub.lo_strict = false
			sub.hi = high_v
			sub.hi_strict = false

			if strategy^ == .Points {
				i := 0
				for i < len(points) {
					if pk_value_in_interval(points[i], sub) {
						i += 1
					} else {
						ordered_remove(points, i)
					}
				}
				return false, len(points) == 0
			}
			if strategy^ == .Full_Scan {
				strategy^ = .Interval
				it^ = sub
				return false, !pk_interval_nonempty(it^)
			}
			if strategy^ == .Interval {
				it^ = pk_interval_intersect(it^, sub)
				return false, !pk_interval_nonempty(it^)
			}
			unreachable()
		case .Equals, .Greater_Than, .Less_Than, .Gt_Eq, .Lt_Eq:
			l_ident, l_ok := cond.a.value.(^AST_Ident)
			r_ident, r_ok := cond.b.value.(^AST_Ident)

			pk_left := l_ok && ident_matches_primary_key(l_ident, table, table_name)
			pk_right := r_ok && ident_matches_primary_key(r_ident, table, table_name)

			if pk_left && !r_ok {
				v, vok := try_evaluate_constant_term(cond.b)
				if !vok do return true, false
				piece: Pk_Interval
				merge_interval_from_comparison(&piece, op_token.kind, true, v)
				return merge_interval_piece(it, strategy, points, piece)
			}

			if pk_right && !l_ok {
				v, vok := try_evaluate_constant_term(cond.a)
				if !vok do return true, false
				piece: Pk_Interval
				merge_interval_from_comparison(&piece, op_token.kind, false, v)
				return merge_interval_piece(it, strategy, points, piece)
			}
			return true, false
		case:
			return true, false
		}
	}
	return true, false
}

// TODO: doesn't core:slice have this?
ordered_remove :: proc(da: ^[dynamic]Database_Value, index: int) {
	if index < 0 do return
	if index >= len(da) do return

	for j in index ..< len(da) - 1 {
		da[j] = da[j + 1]
	}

	resize(da, len(da) - 1)
}

merge_interval_piece :: proc(
	it: ^Pk_Interval,
	strategy: ^Pk_Tree_Strategy,
	points: ^[dynamic]Database_Value,
	piece: Pk_Interval,
) -> (
	residual: bool,
	impossible: bool,
) {
	if strategy^ == .Points {
		i := 0
		for i < len(points) {
			if pk_value_in_interval(points[i], piece) {
				i += 1
			} else {
				ordered_remove(points, i)
			}
		}
		return false, len(points) == 0
	}

	if strategy^ == .Full_Scan {
		strategy^ = .Interval
		it^ = piece
		return false, !pk_interval_nonempty(it^)
	}

	it^ = pk_interval_intersect(it^, piece)

	return false, !pk_interval_nonempty(it^)
}

pk_value_in_interval :: proc(key: Database_Value, it: Pk_Interval) -> bool {
	if lv, has_lo := it.lo.?; has_lo {
		o := value_ordering_for_column_sorting(key, lv)
		if it.lo_strict {
			(o == .Greater) or_return
		} else {
			(o != .Less) or_return
		}
	}

	if hv, has_hi := it.hi.?; has_hi {
		o := value_ordering_for_column_sorting(key, hv)
		if it.hi_strict {
			(o == .Less) or_return
		} else {
			(o != .Greater) or_return
		}
	}
	return true
}

analyze_pk_where_for_table :: proc(
	where_expr: ^AST_Node,
	table: ^Table,
	table_name: string,
) -> (
	plan: Pk_Where_Plan,
	ok: bool,
) {
	plan = {
		strategy       = .Full_Scan,
		interval       = pk_interval_unbounded(),
		points         = make([dynamic]Database_Value, database_query_allocator),
		residual_where = false,
	}

	// Top-level OR of pk = lit only
	if cond, okc := where_expr.value.(^Condition); okc && cond.op.token.kind == .Or {
		pts := make([dynamic]Database_Value, database_query_allocator)

		// TODO: reverse order of conditions?
		if try_collect_or_pk_equals(where_expr, table, table_name, &pts) && len(pts) > 0 {
			delete(plan.points)

			plan.strategy = .Points
			plan.points = slice.clone_to_dynamic(pts[:], database_query_allocator)
			plan.residual_where = false

			return plan, true
		}
	}

	// Unary NOT etc. at root
	// TODO: we should not even create plan.point if where_expr is unary...
	if _, is_unary := where_expr.value.(^Unary_Expression); is_unary {
		delete(plan.points)
		return plan, false
	}

	conjuncts := make([dynamic]^AST_Node, database_query_allocator)
	flatten_and_conjuncts(where_expr, &conjuncts)

	impossible := false

	for c in conjuncts {
		res, imp := try_merge_conjunct(
			&plan.interval,
			&plan.strategy,
			&plan.points,
			c,
			table,
			table_name,
		)
		if res do plan.residual_where = true
		if imp do impossible = true
	}

	if impossible do clear(&plan.points)

	if plan.strategy == .Full_Scan {
		delete(plan.points)
		return plan, false
	}

	ok = true
	return
}

// Incremental PK scan over points or interval (used by exec pulls and bulk append).
Pk_Scan_Stream_Mode :: enum {
	Points,
	Interval,
}

Pk_Scan_Stream :: struct {
	table:      ^Table,
	descending: bool,
	mode:       Pk_Scan_Stream_Mode,
	points:     []Database_Value,
	point_i:    int,
	interval:   Pk_Interval,
	iter:       Index_Tree_Unique_Iter,
	iter_valid: bool,
}

pk_scan_stream_init_points :: proc(
	s: ^Pk_Scan_Stream,
	table: ^Table,
	points: []Database_Value,
	descending: bool,
) {
	s.table = table
	s.descending = descending
	s.mode = .Points
	s.points = points

	if descending {
		s.point_i = len(s.points) - 1
	} else {
		s.point_i = 0
	}
}

pk_scan_stream_init :: proc(
	s: ^Pk_Scan_Stream,
	table: ^Table,
	plan: Pk_Where_Plan,
	descending: bool,
) -> (
	result: bool,
) {
	s.table = table
	s.descending = descending

	switch plan.strategy {
	case .Full_Scan:
		s.mode = .Interval
		s.iter_valid = false
		return true

	case .Points:
		pk_scan_stream_init_points(s, table, plan.points[:], descending)
		return true

	case .Interval:
		s.mode = .Interval
		s.interval = plan.interval

		if !pk_interval_nonempty(s.interval) {
			s.iter_valid = false
			return false
		}

		t := table_primary_unique_tree_ptr(table)

		if t == nil || index_tree_unique_len(t) == 0 {
			s.iter_valid = false
			return false
		}

		start: Index_Tree_Unique_Pos

		if descending {
			start = index_tree_unique_last_pos(t)
		} else {
			if lo, has_lo := s.interval.lo.?; has_lo {
				if s.interval.lo_strict {
					start = index_tree_unique_upper_bound_pos(t, lo)
				} else {
					start = index_tree_unique_lower_bound_pos(t, lo)
				}
			} else {
				start = index_tree_unique_first_pos(t)
			}
		}

		if !index_tree_unique_pos_valid(start) {
			s.iter_valid = false
			return false
		}

		dir := Index_Tree_Direction.Forward

		if descending {
			dir = .Backward
		}

		s.iter = index_tree_unique_iter_from_pos(t, start, dir)
		s.iter_valid = true

		return true
	}

	unreachable()
}

pk_scan_stream_next :: proc(s: ^Pk_Scan_Stream) -> (row: Table_Row, ok: bool) {
	switch s.mode {
	case .Points:
		pk_tree := table_primary_unique_tree_ptr(s.table)

		if s.descending {
			for s.point_i >= 0 {
				key := s.points[s.point_i]
				s.point_i -= 1
				row_ref := index_tree_unique_find(pk_tree, key) or_continue
				return table_get_row(s.table, row_ref)
			}
			return
		}

		for s.point_i < len(s.points) {
			key := s.points[s.point_i]
			s.point_i += 1
			row_ref := index_tree_unique_find(pk_tree, key) or_continue
			return table_get_row(s.table, row_ref)
		}

		return
	case .Interval:
		s.iter_valid or_return

		for {
			key, row_ref, has := index_tree_unique_iter_next(&s.iter)
			if !has {
				s.iter_valid = false
				return
			}

			if s.descending {
				if hi, has_hi := s.interval.hi.?; has_hi {
					cmp_hi := value_ordering_for_column_sorting(key, hi)
					(cmp_hi != .Greater && (cmp_hi != .Equal || !s.interval.hi_strict)) or_continue
				}

				if lo, has_lo := s.interval.lo.?; has_lo {
					cmp_lo := value_ordering_for_column_sorting(key, lo)
					if cmp_lo == .Less || (cmp_lo == .Equal && s.interval.lo_strict) {
						s.iter_valid = false
						return
					}
				}
			} else if !pk_value_in_interval(key, s.interval) {
				s.iter_valid = false
				return
			}
			return table_get_row(s.table, row_ref)
		}
	}
	return
}

append_candidate_rows_for_pk_plan :: proc(
	table: ^Table,
	plan: Pk_Where_Plan,
	descending: bool,
	out: ^[dynamic]Table_Row,
) {
	stream: Pk_Scan_Stream
	pk_scan_stream_init(&stream, table, plan, descending)
	for row in pk_scan_stream_next(&stream) do append(out, row)
}

collect_pk_keys_from_interval :: proc(
	table: ^Table,
	interval: Pk_Interval,
	out: ^[dynamic]Database_Value,
) -> (
	ok: bool,
) {
	pk_interval_nonempty(interval) or_return

	t := table_primary_unique_tree_ptr(table)
	(index_tree_unique_len(t) > 0) or_return

	start: Index_Tree_Unique_Pos
	if lo, has_lo := interval.lo.?; has_lo {
		if interval.lo_strict {
			start = index_tree_unique_upper_bound_pos(t, lo)
		} else {
			start = index_tree_unique_lower_bound_pos(t, lo)
		}
	} else {
		start = index_tree_unique_first_pos(t)
	}

	index_tree_unique_pos_valid(start) or_return

	iter := index_tree_unique_iter_from_pos(t, start, .Forward)
	for key, _ in index_tree_unique_iter_next(&iter) {
		pk_value_in_interval(key, interval) or_break
		append(out, key)
	}

	return true
}

collect_pk_keys_from_plan :: proc(
	table: ^Table,
	plan: Pk_Where_Plan,
	out: ^[dynamic]Database_Value,
) -> (
	ok: bool,
) {
	switch plan.strategy {
	case .Full_Scan:
		return true
	case .Interval:
		collect_pk_keys_from_interval(table, plan.interval, out) or_return
		return true
	case .Points:
		append(out, ..plan.points[:])
		return true
	case:
		unreachable()
	}
}
