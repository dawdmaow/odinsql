#+vet explicit-allocators

package main

import "core:log"

/*
	Pointers from index_tree_non_unique_find_refs_ptr are only valid until the next
	operation that may split/merge/rebalance nodes (same hazard class as holding a
	pointer into a reallocating slice).
*/

// Max routing keys per internal node; max keys stored in a leaf *between* splits.
// Internal nodes hold at most INDEX_BPLUS_MAX_KEYS keys and INDEX_BPLUS_MAX_KEYS+1 children.
INDEX_BPLUS_MAX_KEYS :: 31

// Leaf arrays need one extra slot: insert pushes to count MAX+1, then split runs.
INDEX_BPLUS_LEAF_SLOTS :: INDEX_BPLUS_MAX_KEYS + 1

INDEX_BPLUS_MAX_CHILDREN :: INDEX_BPLUS_MAX_KEYS + 1

// Minimum entries in a non-root leaf after borrow/merge (ceil(max/2) for max=31).
INDEX_BPLUS_MIN_LEAF_KEYS :: (INDEX_BPLUS_MAX_KEYS + 1) / 2

// Minimum routing keys in a non-root internal node (children floored similarly).
INDEX_BPLUS_MIN_INTERNAL_KEYS :: INDEX_BPLUS_MIN_LEAF_KEYS - 1

Index_Tree_Direction :: enum {
	Forward,
	Backward,
}

Index_Tree_Generic :: struct($T: typeid) {
	root:        T,
	entry_count: int,
}

Index_Tree :: union {
	Index_Tree_Generic(Index_Unique_Node),
	Index_Tree_Generic(Index_Non_Unique_Node),
}

Index_Tree_Unique :: Index_Tree_Generic(Index_Unique_Node)
Index_Tree_Non_Unique :: Index_Tree_Generic(Index_Non_Unique_Node)

Index_Unique_Entry :: struct {
	key:   Database_Value,
	value: Row_Index,
}

Index_Non_Unique_Entry :: struct {
	key:   Database_Value,
	value: [dynamic]Row_Index,
}

Index_Unique_Leaf :: struct {
	count: int,
	keys:  [INDEX_BPLUS_LEAF_SLOTS]Database_Value,
	vals:  [INDEX_BPLUS_LEAF_SLOTS]Row_Index,
	prev:  ^Index_Unique_Leaf,
	next:  ^Index_Unique_Leaf,
}

Index_Unique_Node :: union {
	^Index_Unique_Leaf,
	^Index_Unique_Internal,
}

Index_Non_Unique_Leaf :: struct {
	count: int,
	keys:  [INDEX_BPLUS_LEAF_SLOTS]Database_Value,
	refs:  [INDEX_BPLUS_LEAF_SLOTS][dynamic]Row_Index,
	prev:  ^Index_Non_Unique_Leaf,
	next:  ^Index_Non_Unique_Leaf,
}

Index_Internal :: struct($T: typeid) {
	count:    int,
	keys:     [INDEX_BPLUS_MAX_KEYS]Database_Value,
	children: [INDEX_BPLUS_MAX_CHILDREN]T,
}

Index_Unique_Internal :: Index_Internal(Index_Unique_Node)
Index_Non_Unique_Internal :: Index_Internal(Index_Non_Unique_Node)

Index_Non_Unique_Node :: union {
	^Index_Non_Unique_Leaf,
	^Index_Non_Unique_Internal,
}

Index_Tree_Pos :: struct($T: typeid) {
	leaf:  ^T,
	slot:  int,
	valid: bool,
}

Index_Tree_Unique_Pos :: Index_Tree_Pos(Index_Unique_Leaf)
Index_Tree_Non_Unique_Pos :: Index_Tree_Pos(Index_Non_Unique_Leaf)

Index_Tree_Iter :: struct($T: typeid) {
	leaf: ^T,
	slot: int,
	step: int,
}

Index_Tree_Unique_Iter :: Index_Tree_Iter(Index_Unique_Leaf)
Index_Tree_Non_Unique_Iter :: Index_Tree_Iter(Index_Non_Unique_Leaf)

// Narrow a child union to leaf; asserts if the subtree is internal (caller bug).
bplus_u_child_leaf :: proc(c: Index_Unique_Node) -> ^Index_Unique_Leaf {
	L, ok := c.(^Index_Unique_Leaf)
	assert(ok)
	return L
}

bplus_u_child_internal :: proc(c: Index_Unique_Node) -> ^Index_Unique_Internal {
	n, ok := c.(^Index_Unique_Internal)
	assert(ok)
	return n
}

bplus_nu_child_leaf :: proc(c: Index_Non_Unique_Node) -> ^Index_Non_Unique_Leaf {
	L, ok := c.(^Index_Non_Unique_Leaf)
	assert(ok)
	return L
}

bplus_nu_child_internal :: proc(c: Index_Non_Unique_Node) -> ^Index_Non_Unique_Internal {
	n, ok := c.(^Index_Non_Unique_Internal)
	assert(ok)
	return n
}

bplus_u_leftmost_leaf :: proc(root: Index_Unique_Node) -> ^Index_Unique_Leaf {
	switch root in root {
	case nil:
		return nil
	case ^Index_Unique_Leaf:
		return root
	case ^Index_Unique_Internal:
		inode := root
		for {
			ch := inode.children[0]
			L, ok := ch.(^Index_Unique_Leaf)
			if ok {
				return L
			}
			inode = ch.(^Index_Unique_Internal)
		}
	}
	unreachable()
}

bplus_u_rightmost_leaf :: proc(root: Index_Unique_Node) -> ^Index_Unique_Leaf {
	switch root in root {
	case nil:
		return nil
	case ^Index_Unique_Leaf:
		return root
	case ^Index_Unique_Internal:
		inode := root
		for {
			ch := inode.children[inode.count]
			L, ok := ch.(^Index_Unique_Leaf)
			if ok {
				return L
			}
			inode = ch.(^Index_Unique_Internal)
		}
	}
	unreachable()
}

// Descend internal nodes to the leaf that would contain `key`, and return (leaf, slot)
// where slot is the index for lower_bound (first position >= key).
bplus_u_find_leaf_lower_bound :: proc(
	root: Index_Unique_Node,
	key: Database_Value,
) -> (
	leaf: ^Index_Unique_Leaf,
	slot: int,
) {
	switch root in root {
	case nil:
		return nil, 0
	case ^Index_Unique_Leaf:
		return root, index_tree_unique_lower_bound_index_leaf(root, key)
	case ^Index_Unique_Internal:
		inode := root
		for {
			idx := bplus_u_internal_child_index_for_key(inode, key)
			ch := inode.children[idx]
			leaf, leaf_ok := ch.(^Index_Unique_Leaf)
			if leaf_ok {
				return leaf, index_tree_unique_lower_bound_index_leaf(leaf, key)
			}
			inode = ch.(^Index_Unique_Internal)
		}
	}
	unreachable()
}

// First internal child index for key: smallest i in [0..count] such that
// key < keys[i] (treating missing keys as +inf), else count.
bplus_u_internal_child_index_for_key :: proc(
	inode: ^Index_Unique_Internal,
	key: Database_Value,
) -> int {
	i := 0
	for i < inode.count {
		if value_ordering_for_column_sorting(key, inode.keys[i]) != .Greater {
			break
		}
		i += 1
	}
	return i
}

index_tree_unique_lower_bound_index_leaf :: proc(
	L: ^Index_Unique_Leaf,
	key: Database_Value,
) -> int {
	return index_tree_unique_lower_bound_index_entries(L.keys[:L.count], key)
}

index_tree_unique_upper_bound_index_leaf :: proc(
	L: ^Index_Unique_Leaf,
	key: Database_Value,
) -> int {
	return index_tree_unique_upper_bound_index_entries(L.keys[:L.count], key)
}

index_tree_unique_find_pos_entries :: proc(
	entries: []Database_Value,
	key: Database_Value,
) -> (
	pos: int,
	ok: bool,
) {
	left, right := 0, len(entries)
	for left < right {
		mid := left + (right - left) / 2
		switch value_ordering_for_column_sorting(entries[mid], key) {
		case .Less:
			left = mid + 1
		case .Equal:
			return mid, true
		case .Greater:
			right = mid
		}
	}
	return
}

index_tree_unique_lower_bound_index_entries :: proc(
	entries: []Database_Value,
	key: Database_Value,
) -> int {
	left, right := 0, len(entries)
	for left < right {
		mid := left + (right - left) / 2
		if value_ordering_for_column_sorting(entries[mid], key) == .Less {
			left = mid + 1
		} else {
			right = mid
		}
	}
	return left
}

index_tree_unique_upper_bound_index_entries :: proc(
	entries: []Database_Value,
	key: Database_Value,
) -> int {
	left, right := 0, len(entries)
	for left < right {
		mid := left + (right - left) / 2
		if value_ordering_for_column_sorting(entries[mid], key) == .Greater {
			right = mid
		} else {
			left = mid + 1
		}
	}
	return left
}

index_tree_unique_find_pos :: proc(
	entries: []Index_Unique_Entry,
	key: Database_Value,
) -> (
	pos: int,
	ok: bool,
) {
	left, right := 0, len(entries)
	for left < right {
		mid := left + (right - left) / 2
		switch value_ordering_for_column_sorting(entries[mid].key, key) {
		case .Less:
			left = mid + 1
		case .Equal:
			return mid, true
		case .Greater:
			right = mid
		}
	}
	return
}

index_tree_non_unique_find_index :: proc(
	entries: []Index_Non_Unique_Entry,
	key: Database_Value,
) -> (
	idx: int,
	ok: bool,
) {
	left, right := 0, len(entries)
	for left < right {
		mid := left + (right - left) / 2
		switch value_ordering_for_column_sorting(entries[mid].key, key) {
		case .Less:
			left = mid + 1
		case .Equal:
			return mid, true
		case .Greater:
			right = mid
		}
	}
	return
}

index_tree_unique_lower_bound_index :: proc(
	entries: []Index_Unique_Entry,
	key: Database_Value,
) -> int {
	left, right := 0, len(entries)
	for left < right {
		mid := left + (right - left) / 2
		if value_ordering_for_column_sorting(entries[mid].key, key) == .Less {
			left = mid + 1
		} else {
			right = mid
		}
	}
	return left
}

index_tree_unique_upper_bound_index :: proc(
	entries: []Index_Unique_Entry,
	key: Database_Value,
) -> int {
	left, right := 0, len(entries)
	for left < right {
		mid := left + (right - left) / 2
		if value_ordering_for_column_sorting(entries[mid].key, key) == .Greater {
			right = mid
		} else {
			left = mid + 1
		}
	}
	return left
}

index_tree_non_unique_lower_bound_index :: proc(
	entries: []Index_Non_Unique_Entry,
	key: Database_Value,
) -> int {
	left, right := 0, len(entries)
	for left < right {
		mid := left + (right - left) / 2
		if value_ordering_for_column_sorting(entries[mid].key, key) == .Less {
			left = mid + 1
		} else {
			right = mid
		}
	}
	return left
}

index_tree_non_unique_upper_bound_index :: proc(
	entries: []Index_Non_Unique_Entry,
	key: Database_Value,
) -> int {
	left, right := 0, len(entries)
	for left < right {
		mid := left + (right - left) / 2
		if value_ordering_for_column_sorting(entries[mid].key, key) == .Greater {
			right = mid
		} else {
			left = mid + 1
		}
	}
	return left
}

index_tree_non_unique_lower_bound_index_leaf :: proc(
	L: ^Index_Non_Unique_Leaf,
	key: Database_Value,
) -> int {
	return index_tree_unique_lower_bound_index_entries(L.keys[:L.count], key)
}

index_tree_non_unique_upper_bound_index_leaf :: proc(
	L: ^Index_Non_Unique_Leaf,
	key: Database_Value,
) -> int {
	return index_tree_unique_upper_bound_index_entries(L.keys[:L.count], key)
}

bplus_nu_internal_child_index_for_key :: proc(
	nu_inode: ^Index_Non_Unique_Internal,
	key: Database_Value,
) -> int {
	i := 0
	for i < nu_inode.count {
		if value_ordering_for_column_sorting(key, nu_inode.keys[i]) != .Greater {
			break
		}
		i += 1
	}
	return i
}

bplus_nu_leftmost_leaf :: proc(root: Index_Non_Unique_Node) -> ^Index_Non_Unique_Leaf {
	switch root in root {
	case nil:
		return nil
	case ^Index_Non_Unique_Leaf:
		return root
	case ^Index_Non_Unique_Internal:
		nu_inode := root
		for {
			ch := nu_inode.children[0]
			L, ok := ch.(^Index_Non_Unique_Leaf)
			if ok {
				return L
			}
			nu_inode = ch.(^Index_Non_Unique_Internal)
		}
	}
	unreachable()
}

bplus_nu_rightmost_leaf :: proc(root: Index_Non_Unique_Node) -> ^Index_Non_Unique_Leaf {
	switch root in root {
	case nil:
		return nil
	case ^Index_Non_Unique_Leaf:
		return root
	case ^Index_Non_Unique_Internal:
		nu_inode := root
		for {
			ch := nu_inode.children[nu_inode.count]
			L, ok := ch.(^Index_Non_Unique_Leaf)
			if ok {
				return L
			}
			nu_inode = ch.(^Index_Non_Unique_Internal)
		}
	}
	unreachable()
}

bplus_nu_find_leaf_lower_bound :: proc(
	root: Index_Non_Unique_Node,
	key: Database_Value,
) -> (
	leaf: ^Index_Non_Unique_Leaf,
	slot: int,
) {
	switch root in root {
	case nil:
		return nil, 0
	case ^Index_Non_Unique_Leaf:
		return root, index_tree_non_unique_lower_bound_index_leaf(root, key)
	case ^Index_Non_Unique_Internal:
		nu_inode := root
		for {
			idx := bplus_nu_internal_child_index_for_key(nu_inode, key)
			ch := nu_inode.children[idx]
			leaf, leaf_ok := ch.(^Index_Non_Unique_Leaf)
			if leaf_ok {
				return leaf, index_tree_non_unique_lower_bound_index_leaf(leaf, key)
			}
			nu_inode = ch.(^Index_Non_Unique_Internal)
		}
	}
	unreachable()
}

bplus_u_free_subtree :: proc(c: Index_Unique_Node) {
	switch c in c {
	case ^Index_Unique_Leaf:
		free(c, context.allocator)
	case ^Index_Unique_Internal:
		bplus_u_free_internal(c)
	}
}

bplus_u_free_internal :: proc(inode: ^Index_Unique_Internal) {
	for i := 0; i <= inode.count; i += 1 {
		bplus_u_free_subtree(inode.children[i])
	}
	free(inode, context.allocator)
}

bplus_u_free_root :: proc(root: Index_Unique_Node) {
	switch root in root {
	case nil:
		return
	case ^Index_Unique_Leaf:
		free(root, context.allocator)
	case ^Index_Unique_Internal:
		bplus_u_free_internal(root)
	}
}

bplus_nu_free_subtree :: proc(c: Index_Non_Unique_Node) {
	switch c in c {
	case ^Index_Non_Unique_Leaf:
		L := c
		for i := 0; i < L.count; i += 1 {
			delete(L.refs[i])
		}
		free(L, context.allocator)
	case ^Index_Non_Unique_Internal:
		bplus_nu_free_internal(c)
	}
}

bplus_nu_free_internal :: proc(nu_inode: ^Index_Non_Unique_Internal) {
	for i := 0; i <= nu_inode.count; i += 1 {
		bplus_nu_free_subtree(nu_inode.children[i])
	}
	free(nu_inode, context.allocator)
}

// destroy with on_remove callback for each key group (used when caller owns cleanup differently)
bplus_nu_free_root_with_callback :: proc(
	root: Index_Non_Unique_Node,
	on_remove: proc(key: Database_Value, value: [dynamic]Row_Index, user_data: rawptr),
	user_data: rawptr,
) {
	switch root in root {
	case nil:
		return
	case ^Index_Non_Unique_Leaf:
		L := root
		for i := 0; i < L.count; i += 1 {
			if on_remove != nil {
				on_remove(L.keys[i], L.refs[i], user_data)
			} else {
				delete(L.refs[i])
			}
		}
		free(L, context.allocator)
	case ^Index_Non_Unique_Internal:
		bplus_nu_free_internal(root)
	}
}

// Inserts (key,value) into leaf at sorted position; allows count == MAX before insert (then split).
bplus_u_leaf_insert_at :: proc(
	L: ^Index_Unique_Leaf,
	insert_pos: int,
	key: Database_Value,
	val: Row_Index,
) {
	n := L.count
	assert(n <= INDEX_BPLUS_MAX_KEYS)
	assert(insert_pos >= 0 && insert_pos <= n)
	for i := n; i > insert_pos; i -= 1 {
		L.keys[i] = L.keys[i - 1]
		L.vals[i] = L.vals[i - 1]
	}
	L.keys[insert_pos] = key
	L.vals[insert_pos] = val
	L.count = n + 1
}

// Removes slot from leaf; leaf.count must be > 0.
bplus_u_leaf_remove_at :: proc(L: ^Index_Unique_Leaf, remove_pos: int) {
	assert(L.count > 0)
	assert(remove_pos >= 0 && remove_pos < L.count)
	n := L.count
	for i := remove_pos; i < n - 1; i += 1 {
		L.keys[i] = L.keys[i + 1]
		L.vals[i] = L.vals[i + 1]
	}
	L.count = n - 1
}

bplus_u_leaf_link_between :: proc(left, mid, right: ^Index_Unique_Leaf) {
	// Insert `mid` between `left` and `right` in the leaf chain (either may be nil).
	if left != nil {
		left.next = mid
	}
	mid.prev = left
	mid.next = right
	if right != nil {
		right.prev = mid
	}
}

bplus_u_leaf_unlink :: proc(L: ^Index_Unique_Leaf) {
	if L.prev != nil {
		L.prev.next = L.next
	}
	if L.next != nil {
		L.next.prev = L.prev
	}
	L.prev = nil
	L.next = nil
}

// Split full leaf L (count == MAX) after logical overflow: keys distributed half/half.
// Returns separator key (copy of first key of right leaf) and new right leaf.
bplus_u_leaf_split :: proc(
	L: ^Index_Unique_Leaf,
) -> (
	sep_key: Database_Value,
	right: ^Index_Unique_Leaf,
	ok: bool,
) {
	assert(L.count == INDEX_BPLUS_MAX_KEYS + 1)
	total := INDEX_BPLUS_MAX_KEYS + 1
	left_n := total / 2
	right_n := total - left_n
	right = new(Index_Unique_Leaf, context.allocator)
	if right == nil {
		return {}, nil, false
	}
	right^ = {}
	// Copy right half to new leaf
	for i := 0; i < right_n; i += 1 {
		right.keys[i] = L.keys[left_n + i]
		right.vals[i] = L.vals[left_n + i]
	}
	right.count = right_n
	L.count = left_n
	sep_key = right.keys[0]
	// Leaf chain: insert right after L
	bplus_u_leaf_link_between(L, right, L.next)
	return sep_key, right, true
}

bplus_u_child_eq :: proc(a, b: Index_Unique_Node) -> bool {
	a_leaf, a_is_leaf := a.(^Index_Unique_Leaf)
	b_leaf, b_is_leaf := b.(^Index_Unique_Leaf)
	if a_is_leaf && b_is_leaf {
		return a_leaf == b_leaf
	}
	a_int, a_is_int := a.(^Index_Unique_Internal)
	b_int, b_is_int := b.(^Index_Unique_Internal)
	if a_is_int && b_is_int {
		return a_int == b_int
	}
	return false
}

bplus_u_find_parent_slot :: proc(
	root: Index_Unique_Node,
	child: Index_Unique_Node,
) -> (
	parent: ^Index_Unique_Internal,
	slot: int,
	ok: bool,
) {
	#partial switch root in root {
	case ^Index_Unique_Internal:
		return bplus_u_find_parent_slot_internal(root, child)
	case:
		return nil, 0, false
	}
}

bplus_u_find_parent_slot_internal :: proc(
	inode: ^Index_Unique_Internal,
	child: Index_Unique_Node,
) -> (
	parent: ^Index_Unique_Internal,
	slot: int,
	ok: bool,
) {
	for ci := 0; ci <= inode.count; ci += 1 {
		ch := inode.children[ci]
		if bplus_u_child_eq(ch, child) {
			return inode, ci, true
		}
		if ch_internal, ok := ch.(^Index_Unique_Internal); ok {
			if p, s, ok2 := bplus_u_find_parent_slot_internal(ch_internal, child); ok2 {
				return p, s, ok2
			}
		}
	}
	return nil, 0, false
}

bplus_u_internal_insert_shift :: proc(
	inode: ^Index_Unique_Internal,
	insert_at: int,
	sep: Database_Value,
	new_child: Index_Unique_Node,
) {
	assert(inode.count < INDEX_BPLUS_MAX_KEYS)
	assert(insert_at >= 0 && insert_at <= inode.count)
	for i := inode.count; i > insert_at; i -= 1 {
		inode.keys[i] = inode.keys[i - 1]
	}
	for i := inode.count + 1; i > insert_at + 1; i -= 1 {
		inode.children[i] = inode.children[i - 1]
	}
	inode.keys[insert_at] = sep
	inode.children[insert_at + 1] = new_child
	inode.count += 1
}

// `inode` is full (INDEX_BPLUS_MAX_KEYS keys); insert sep/new_child at `insert_at`.
bplus_u_internal_split_insert :: proc(
	inode: ^Index_Unique_Internal,
	insert_at: int,
	sep: Database_Value,
	new_child: Index_Unique_Node,
) -> (
	promoted: Database_Value,
	sibling: ^Index_Unique_Internal,
	ok: bool,
) {
	tk: [INDEX_BPLUS_MAX_KEYS + 1]Database_Value
	tc: [INDEX_BPLUS_MAX_CHILDREN + 1]Index_Unique_Node
	nk := inode.count
	for i := 0; i < nk; i += 1 {
		tk[i] = inode.keys[i]
	}
	nc := nk + 1
	for i := 0; i < nc; i += 1 {
		tc[i] = inode.children[i]
	}
	for i := nk; i > insert_at; i -= 1 {
		tk[i] = tk[i - 1]
	}
	tk[insert_at] = sep
	for i := nc; i > insert_at + 1; i -= 1 {
		tc[i] = tc[i - 1]
	}
	tc[insert_at + 1] = new_child
	total_keys := nk + 1
	split_idx := (total_keys - 1) / 2
	promoted = tk[split_idx]
	sibling = new(Index_Unique_Internal, context.allocator)
	if sibling == nil {
		return {}, nil, false
	}
	sibling^ = {}
	inode.count = split_idx
	for i := 0; i < split_idx; i += 1 {
		inode.keys[i] = tk[i]
	}
	for i := 0; i <= split_idx; i += 1 {
		inode.children[i] = tc[i]
	}
	right_k := total_keys - split_idx - 1
	sibling.count = right_k
	for i := 0; i < right_k; i += 1 {
		sibling.keys[i] = tk[split_idx + 1 + i]
	}
	for i := 0; i <= right_k; i += 1 {
		sibling.children[i] = tc[split_idx + 1 + i]
	}
	return promoted, sibling, true
}

bplus_u_propagate_split :: proc(
	impl: ^Index_Tree_Unique,
	left_child: Index_Unique_Node,
	sep: Database_Value,
	right_child: Index_Unique_Node,
) {
	child_left := left_child
	sep_up := sep
	right_up := right_child
	for {
		par, slot, has_par := bplus_u_find_parent_slot(impl.root, child_left)
		if !has_par {
			new_internal := new(Index_Unique_Internal, context.allocator)
			if new_internal == nil {
				return
			}
			new_internal^ = {}
			new_internal.count = 1
			new_internal.keys[0] = sep_up
			new_internal.children[0] = child_left
			new_internal.children[1] = right_up
			impl.root = new_internal
			return
		}
		if par.count < INDEX_BPLUS_MAX_KEYS {
			bplus_u_internal_insert_shift(par, slot, sep_up, right_up)
			return
		}
		promoted, sibling, spl_ok := bplus_u_internal_split_insert(par, slot, sep_up, right_up)
		if !spl_ok {
			return
		}
		child_left = par
		sep_up = promoted
		right_up = sibling
	}
}

bplus_u_insert :: proc(impl: ^Index_Tree_Unique, key: Database_Value, val: Row_Index) -> bool {
	if impl.root == nil {
		L := new(Index_Unique_Leaf, context.allocator)
		if L == nil {
			return false
		}
		L^ = {}
		L.keys[0] = key
		L.vals[0] = val
		L.count = 1
		impl.root = L
		impl.entry_count = 1
		return true
	}

	leaf, _ := bplus_u_find_leaf_lower_bound(impl.root, key)
	if leaf == nil {
		return false
	}
	if _, hit := index_tree_unique_find_pos_entries(leaf.keys[:leaf.count], key); hit {
		return false
	}
	insert_pos := index_tree_unique_lower_bound_index_entries(leaf.keys[:leaf.count], key)
	bplus_u_leaf_insert_at(leaf, insert_pos, key, val)
	impl.entry_count += 1

	if leaf.count <= INDEX_BPLUS_MAX_KEYS {
		return true
	}
	sep, right, spl_ok := bplus_u_leaf_split(leaf)
	if !spl_ok {
		return false
	}
	bplus_u_propagate_split(impl, leaf, sep, right)
	return true
}

bplus_u_internal_contains_leaf :: proc(
	inode: ^Index_Unique_Internal,
	leaf: ^Index_Unique_Leaf,
) -> bool {
	for ci := 0; ci <= inode.count; ci += 1 {
		ch := inode.children[ci]
		if L, ok := ch.(^Index_Unique_Leaf); ok && L == leaf {
			return true
		}
		if ch_int, ok := ch.(^Index_Unique_Internal);
		   ok && bplus_u_internal_contains_leaf(ch_int, leaf) {
			return true
		}
	}
	return false
}

bplus_u_root_from_child :: proc(ch: Index_Unique_Node) -> Index_Unique_Node {
	// Child and root are the same pointer union shapes but distinct types — branch, don't transmute.
	switch v in ch {
	case ^Index_Unique_Leaf:
		return v
	case ^Index_Unique_Internal:
		return v
	}
	unreachable()
}

bplus_u_maybe_collapse_root :: proc(impl: ^Index_Tree_Unique) {
	#partial switch r in impl.root {
	case ^Index_Unique_Internal:
		inode := r
		if inode.count != 0 {
			return
		}
		only := inode.children[0]
		free(inode, context.allocator)
		impl.root = bplus_u_root_from_child(only)
	case:
		return
	}
}

// Remove separator keys[s] and child[s+1] from internal node (after leaf merge).
bplus_u_internal_remove_child_after :: proc(inode: ^Index_Unique_Internal, s: int) {
	assert(s >= 0 && s < inode.count)
	for i := s; i < inode.count - 1; i += 1 {
		inode.keys[i] = inode.keys[i + 1]
	}
	for i := s + 1; i < inode.count; i += 1 {
		inode.children[i] = inode.children[i + 1]
	}
	inode.count -= 1
}

bplus_u_leaf_borrow_right :: proc(par: ^Index_Unique_Internal, s: int, L, R: ^Index_Unique_Leaf) {
	assert(R.count > INDEX_BPLUS_MIN_LEAF_KEYS)
	i := L.count
	L.keys[i] = R.keys[0]
	L.vals[i] = R.vals[0]
	L.count += 1
	bplus_u_leaf_remove_at(R, 0)
	par.keys[s] = R.keys[0]
}

bplus_u_leaf_borrow_left :: proc(
	par: ^Index_Unique_Internal,
	s: int,
	L_left, L: ^Index_Unique_Leaf,
) {
	assert(L_left.count > INDEX_BPLUS_MIN_LEAF_KEYS)
	last := L_left.count - 1
	k := L_left.keys[last]
	v := L_left.vals[last]
	bplus_u_leaf_remove_at(L_left, last)
	bplus_u_leaf_insert_at(L, 0, k, v)
	par.keys[s - 1] = L.keys[0]
}

bplus_u_leaf_merge_right :: proc(
	impl: ^Index_Tree_Unique,
	par: ^Index_Unique_Internal,
	s: int,
	L, R: ^Index_Unique_Leaf,
) {
	assert(L.count + R.count <= INDEX_BPLUS_MAX_KEYS)
	base := L.count
	for i := 0; i < R.count; i += 1 {
		L.keys[base + i] = R.keys[i]
		L.vals[base + i] = R.vals[i]
	}
	L.count += R.count
	bplus_u_leaf_unlink(R)
	free(R, context.allocator)
	bplus_u_internal_remove_child_after(par, s)
	bplus_u_maybe_collapse_root(impl)
}

bplus_u_rebalance_leaf :: proc(impl: ^Index_Tree_Unique, leaf: ^Index_Unique_Leaf) {
	for leaf.count < INDEX_BPLUS_MIN_LEAF_KEYS {
		_, root_is_leaf := impl.root.(^Index_Unique_Leaf)
		if root_is_leaf {
			break
		}
		par, s, ok := bplus_u_find_parent_slot(impl.root, leaf)
		if !ok {
			break
		}
		if s < par.count {
			R := bplus_u_child_leaf(par.children[s + 1])
			if R.count > INDEX_BPLUS_MIN_LEAF_KEYS {
				bplus_u_leaf_borrow_right(par, s, leaf, R)
				return
			}
			if leaf.count + R.count <= INDEX_BPLUS_MAX_KEYS {
				bplus_u_leaf_merge_right(impl, par, s, leaf, R)
				return
			}
		}
		if s > 0 {
			L_left := bplus_u_child_leaf(par.children[s - 1])
			if L_left.count > INDEX_BPLUS_MIN_LEAF_KEYS {
				bplus_u_leaf_borrow_left(par, s, L_left, leaf)
				return
			}
			if L_left.count + leaf.count <= INDEX_BPLUS_MAX_KEYS {
				base := L_left.count
				for i := 0; i < leaf.count; i += 1 {
					L_left.keys[base + i] = leaf.keys[i]
					L_left.vals[base + i] = leaf.vals[i]
				}
				L_left.count += leaf.count
				bplus_u_leaf_unlink(leaf)
				free(leaf, context.allocator)
				bplus_u_internal_remove_child_after(par, s - 1)
				bplus_u_maybe_collapse_root(impl)
				return
			}
		}
		break
	}
}

bplus_u_remove_key :: proc(impl: ^Index_Tree_Unique, key: Database_Value) -> bool {
	if impl.root == nil {
		return false
	}
	leaf, _ := bplus_u_find_leaf_lower_bound(impl.root, key)
	if leaf == nil {
		return false
	}
	idx, found := index_tree_unique_find_pos_entries(leaf.keys[:leaf.count], key)
	if !found {
		return false
	}
	bplus_u_leaf_remove_at(leaf, idx)
	impl.entry_count -= 1
	if leaf.count >= INDEX_BPLUS_MIN_LEAF_KEYS {
		return true
	}
	_, root_is_leaf := impl.root.(^Index_Unique_Leaf)
	if root_is_leaf {
		return true
	}
	bplus_u_rebalance_leaf(impl, leaf)
	return true
}

bplus_nu_child_eq :: proc(a, b: Index_Non_Unique_Node) -> bool {
	a_leaf, a_is_leaf := a.(^Index_Non_Unique_Leaf)
	b_leaf, b_is_leaf := b.(^Index_Non_Unique_Leaf)
	if a_is_leaf && b_is_leaf {
		return a_leaf == b_leaf
	}
	a_int, a_is_int := a.(^Index_Non_Unique_Internal)
	b_int, b_is_int := b.(^Index_Non_Unique_Internal)
	if a_is_int && b_is_int {
		return a_int == b_int
	}
	return false
}

bplus_nu_find_parent_slot :: proc(
	root: Index_Non_Unique_Node,
	child: Index_Non_Unique_Node,
) -> (
	parent: ^Index_Non_Unique_Internal,
	slot: int,
	ok: bool,
) {
	#partial switch root in root {
	case ^Index_Non_Unique_Internal:
		return bplus_nu_find_parent_slot_internal(root, child)
	case:
		return nil, 0, false
	}
}

bplus_nu_find_parent_slot_internal :: proc(
	nu_inode: ^Index_Non_Unique_Internal,
	child: Index_Non_Unique_Node,
) -> (
	parent: ^Index_Non_Unique_Internal,
	slot: int,
	ok: bool,
) {
	for ci := 0; ci <= nu_inode.count; ci += 1 {
		ch := nu_inode.children[ci]
		if bplus_nu_child_eq(ch, child) {
			return nu_inode, ci, true
		}
		if ch_int, ok := ch.(^Index_Non_Unique_Internal); ok {
			if p, s, ok2 := bplus_nu_find_parent_slot_internal(ch_int, child); ok2 {
				return p, s, ok2
			}
		}
	}
	return nil, 0, false
}

bplus_nu_internal_insert_shift :: proc(
	nu_inode: ^Index_Non_Unique_Internal,
	insert_at: int,
	sep: Database_Value,
	new_child: Index_Non_Unique_Node,
) {
	assert(nu_inode.count < INDEX_BPLUS_MAX_KEYS)
	assert(insert_at >= 0 && insert_at <= nu_inode.count)
	for i := nu_inode.count; i > insert_at; i -= 1 {
		nu_inode.keys[i] = nu_inode.keys[i - 1]
	}
	for i := nu_inode.count + 1; i > insert_at + 1; i -= 1 {
		nu_inode.children[i] = nu_inode.children[i - 1]
	}
	nu_inode.keys[insert_at] = sep
	nu_inode.children[insert_at + 1] = new_child
	nu_inode.count += 1
}

bplus_nu_internal_split_insert :: proc(
	nu_inode: ^Index_Non_Unique_Internal,
	insert_at: int,
	sep: Database_Value,
	new_child: Index_Non_Unique_Node,
) -> (
	promoted: Database_Value,
	sibling: ^Index_Non_Unique_Internal,
	ok: bool,
) {
	tk: [INDEX_BPLUS_MAX_KEYS + 1]Database_Value
	tc: [INDEX_BPLUS_MAX_CHILDREN + 1]Index_Non_Unique_Node
	nk := nu_inode.count
	for i := 0; i < nk; i += 1 {
		tk[i] = nu_inode.keys[i]
	}
	nc := nk + 1
	for i := 0; i < nc; i += 1 {
		tc[i] = nu_inode.children[i]
	}
	for i := nk; i > insert_at; i -= 1 {
		tk[i] = tk[i - 1]
	}
	tk[insert_at] = sep
	for i := nc; i > insert_at + 1; i -= 1 {
		tc[i] = tc[i - 1]
	}
	tc[insert_at + 1] = new_child
	total_keys := nk + 1
	split_idx := (total_keys - 1) / 2
	promoted = tk[split_idx]
	sibling = new(Index_Non_Unique_Internal, context.allocator)
	if sibling == nil {
		return {}, nil, false
	}
	sibling^ = {}
	nu_inode.count = split_idx
	for i := 0; i < split_idx; i += 1 {
		nu_inode.keys[i] = tk[i]
	}
	for i := 0; i <= split_idx; i += 1 {
		nu_inode.children[i] = tc[i]
	}
	right_k := total_keys - split_idx - 1
	sibling.count = right_k
	for i := 0; i < right_k; i += 1 {
		sibling.keys[i] = tk[split_idx + 1 + i]
	}
	for i := 0; i <= right_k; i += 1 {
		sibling.children[i] = tc[split_idx + 1 + i]
	}
	return promoted, sibling, true
}

bplus_nu_propagate_split :: proc(
	impl: ^Index_Tree_Non_Unique,
	left_child: Index_Non_Unique_Node,
	sep: Database_Value,
	right_child: Index_Non_Unique_Node,
) {
	child_left := left_child
	sep_up := sep
	right_up := right_child
	for {
		par, slot, has_par := bplus_nu_find_parent_slot(impl.root, child_left)
		if !has_par {
			new_internal := new(Index_Non_Unique_Internal, context.allocator)
			if new_internal == nil {
				return
			}
			new_internal^ = {}
			new_internal.count = 1
			new_internal.keys[0] = sep_up
			new_internal.children[0] = child_left
			new_internal.children[1] = right_up
			impl.root = new_internal
			return
		}
		if par.count < INDEX_BPLUS_MAX_KEYS {
			bplus_nu_internal_insert_shift(par, slot, sep_up, right_up)
			return
		}
		promoted, sibling, spl_ok := bplus_nu_internal_split_insert(par, slot, sep_up, right_up)
		if !spl_ok {
			return
		}
		child_left = par
		sep_up = promoted
		right_up = sibling
	}
}

bplus_nu_leaf_insert_at :: proc(
	L: ^Index_Non_Unique_Leaf,
	insert_pos: int,
	key: Database_Value,
	refs: [dynamic]Row_Index,
) {
	n := L.count
	assert(n <= INDEX_BPLUS_MAX_KEYS)
	assert(insert_pos >= 0 && insert_pos <= n)
	for i := n; i > insert_pos; i -= 1 {
		L.keys[i] = L.keys[i - 1]
		L.refs[i] = L.refs[i - 1]
	}
	L.keys[insert_pos] = key
	L.refs[insert_pos] = refs
	L.count = n + 1
}

bplus_nu_leaf_remove_at :: proc(L: ^Index_Non_Unique_Leaf, remove_pos: int) {
	assert(L.count > 0)
	delete(L.refs[remove_pos])
	n := L.count
	for i := remove_pos; i < n - 1; i += 1 {
		L.keys[i] = L.keys[i + 1]
		L.refs[i] = L.refs[i + 1]
	}
	L.count = n - 1
}

bplus_nu_leaf_split :: proc(
	L: ^Index_Non_Unique_Leaf,
) -> (
	sep_key: Database_Value,
	right: ^Index_Non_Unique_Leaf,
	ok: bool,
) {
	assert(L.count == INDEX_BPLUS_MAX_KEYS + 1)
	total := INDEX_BPLUS_MAX_KEYS + 1
	left_n := total / 2
	right_n := total - left_n
	right = new(Index_Non_Unique_Leaf, context.allocator)
	if right == nil {
		return {}, nil, false
	}
	right^ = {}
	for i := 0; i < right_n; i += 1 {
		right.keys[i] = L.keys[left_n + i]
		right.refs[i] = L.refs[left_n + i]
	}
	right.count = right_n
	L.count = left_n
	sep_key = right.keys[0]
	bplus_nu_leaf_link_between(L, right, L.next)
	return sep_key, right, true
}

bplus_nu_leaf_link_between :: proc(left, mid, right: ^Index_Non_Unique_Leaf) {
	if left != nil {
		left.next = mid
	}
	mid.prev = left
	mid.next = right
	if right != nil {
		right.prev = mid
	}
}

bplus_nu_leaf_unlink :: proc(L: ^Index_Non_Unique_Leaf) {
	if L.prev != nil {
		L.prev.next = L.next
	}
	if L.next != nil {
		L.next.prev = L.prev
	}
	L.prev = nil
	L.next = nil
}

bplus_nu_insert_new_key :: proc(
	impl: ^Index_Tree_Non_Unique,
	key: Database_Value,
	row_index: Row_Index,
) -> bool {
	dyn := make([dynamic]Row_Index, 0, 1, context.allocator)
	append(&dyn, row_index)
	if impl.root == nil {
		L := new(Index_Non_Unique_Leaf, context.allocator)
		if L == nil {
			delete(dyn)
			return false
		}
		L^ = {}
		L.keys[0] = key
		L.refs[0] = dyn
		L.count = 1
		impl.root = L
		impl.entry_count = 1
		return true
	}
	leaf, _ := bplus_nu_find_leaf_lower_bound(impl.root, key)
	if leaf == nil {
		delete(dyn)
		return false
	}
	insert_pos := index_tree_non_unique_lower_bound_index_leaf(leaf, key)
	bplus_nu_leaf_insert_at(leaf, insert_pos, key, dyn)
	impl.entry_count += 1
	if leaf.count <= INDEX_BPLUS_MAX_KEYS {
		return true
	}
	sep, right, spl_ok := bplus_nu_leaf_split(leaf)
	if !spl_ok {
		return false
	}
	bplus_nu_propagate_split(impl, leaf, sep, right)
	return true
}

bplus_nu_root_from_child :: proc(ch: Index_Non_Unique_Node) -> Index_Non_Unique_Node {
	switch v in ch {
	case ^Index_Non_Unique_Leaf:
		return v
	case ^Index_Non_Unique_Internal:
		return v
	}
	unreachable()
}

bplus_nu_maybe_collapse_root :: proc(impl: ^Index_Tree_Non_Unique) {
	nu_inode, ok := impl.root.(^Index_Non_Unique_Internal)
	if !ok {
		return
	}
	if nu_inode.count != 0 {
		return
	}
	only := nu_inode.children[0]
	free(nu_inode, context.allocator)
	impl.root = bplus_nu_root_from_child(only)
}

bplus_nu_internal_remove_child_after :: proc(nu_inode: ^Index_Non_Unique_Internal, s: int) {
	assert(s >= 0 && s < nu_inode.count)
	for i := s; i < nu_inode.count - 1; i += 1 {
		nu_inode.keys[i] = nu_inode.keys[i + 1]
	}
	for i := s + 1; i < nu_inode.count; i += 1 {
		nu_inode.children[i] = nu_inode.children[i + 1]
	}
	nu_inode.count -= 1
}

bplus_nu_leaf_borrow_right :: proc(
	par: ^Index_Non_Unique_Internal,
	s: int,
	L, R: ^Index_Non_Unique_Leaf,
) {
	assert(R.count > INDEX_BPLUS_MIN_LEAF_KEYS)
	i := L.count
	L.keys[i] = R.keys[0]
	L.refs[i] = R.refs[0]
	L.count += 1
	for i := 0; i < R.count - 1; i += 1 {
		R.keys[i] = R.keys[i + 1]
		R.refs[i] = R.refs[i + 1]
	}
	R.count -= 1
	par.keys[s] = R.keys[0]
}

bplus_nu_leaf_borrow_left :: proc(
	par: ^Index_Non_Unique_Internal,
	s: int,
	L_left, L: ^Index_Non_Unique_Leaf,
) {
	assert(L_left.count > INDEX_BPLUS_MIN_LEAF_KEYS)
	last := L_left.count - 1
	k := L_left.keys[last]
	rf := L_left.refs[last]
	L_left.count -= 1
	for i := L.count; i > 0; i -= 1 {
		L.keys[i] = L.keys[i - 1]
		L.refs[i] = L.refs[i - 1]
	}
	L.keys[0] = k
	L.refs[0] = rf
	L.count += 1
	par.keys[s - 1] = L.keys[0]
}

bplus_nu_leaf_merge_right :: proc(
	impl: ^Index_Tree_Non_Unique,
	par: ^Index_Non_Unique_Internal,
	s: int,
	L, R: ^Index_Non_Unique_Leaf,
) {
	base := L.count
	for i := 0; i < R.count; i += 1 {
		L.keys[base + i] = R.keys[i]
		L.refs[base + i] = R.refs[i]
	}
	L.count += R.count
	bplus_nu_leaf_unlink(R)
	free(R, context.allocator)
	bplus_nu_internal_remove_child_after(par, s)
	bplus_nu_maybe_collapse_root(impl)
}

bplus_nu_rebalance_leaf :: proc(impl: ^Index_Tree_Non_Unique, leaf: ^Index_Non_Unique_Leaf) {
	for leaf.count < INDEX_BPLUS_MIN_LEAF_KEYS {
		_, root_is_leaf := impl.root.(^Index_Non_Unique_Leaf)
		if root_is_leaf {
			break
		}
		par, s, ok := bplus_nu_find_parent_slot(impl.root, leaf)
		if !ok {
			break
		}
		if s < par.count {
			R := bplus_nu_child_leaf(par.children[s + 1])
			if R.count > INDEX_BPLUS_MIN_LEAF_KEYS {
				bplus_nu_leaf_borrow_right(par, s, leaf, R)
				return
			}
			if leaf.count + R.count <= INDEX_BPLUS_MAX_KEYS {
				bplus_nu_leaf_merge_right(impl, par, s, leaf, R)
				return
			}
		}
		if s > 0 {
			L_left := bplus_nu_child_leaf(par.children[s - 1])
			if L_left.count > INDEX_BPLUS_MIN_LEAF_KEYS {
				bplus_nu_leaf_borrow_left(par, s, L_left, leaf)
				return
			}
			if L_left.count + leaf.count <= INDEX_BPLUS_MAX_KEYS {
				base := L_left.count
				for i := 0; i < leaf.count; i += 1 {
					L_left.keys[base + i] = leaf.keys[i]
					L_left.refs[base + i] = leaf.refs[i]
				}
				L_left.count += leaf.count
				bplus_nu_leaf_unlink(leaf)
				free(leaf, context.allocator)
				bplus_nu_internal_remove_child_after(par, s - 1)
				bplus_nu_maybe_collapse_root(impl)
				return
			}
		}
		break
	}
}

bplus_nu_remove_key_slot :: proc(impl: ^Index_Tree_Non_Unique, key: Database_Value) -> bool {
	if impl.root == nil {
		return false
	}
	leaf, _ := bplus_nu_find_leaf_lower_bound(impl.root, key)
	if leaf == nil {
		return false
	}
	idx, found := index_tree_unique_find_pos_entries(leaf.keys[:leaf.count], key)
	if !found {
		return false
	}
	bplus_nu_leaf_remove_at(leaf, idx)
	impl.entry_count -= 1
	if leaf.count >= INDEX_BPLUS_MIN_LEAF_KEYS {
		return true
	}
	_, root_is_leaf := impl.root.(^Index_Non_Unique_Leaf)
	if root_is_leaf {
		return true
	}
	bplus_nu_rebalance_leaf(impl, leaf)
	return true
}

bplus_u_internal_child_index_upper :: proc(
	inode: ^Index_Unique_Internal,
	key: Database_Value,
) -> int {
	i := 0
	for i < inode.count && value_ordering_for_column_sorting(inode.keys[i], key) != .Greater {
		i += 1
	}
	return i
}

bplus_u_find_leaf_upper_bound :: proc(
	root: Index_Unique_Node,
	key: Database_Value,
) -> (
	leaf: ^Index_Unique_Leaf,
	slot: int,
) {
	switch root in root {
	case nil:
		return nil, 0
	case ^Index_Unique_Leaf:
		return root, index_tree_unique_upper_bound_index_leaf(root, key)
	case ^Index_Unique_Internal:
		inode := root
		for {
			idx := bplus_u_internal_child_index_upper(inode, key)
			ch := inode.children[idx]
			L, leaf_ok := ch.(^Index_Unique_Leaf)
			if leaf_ok {
				return L, index_tree_unique_upper_bound_index_leaf(L, key)
			}
			inode = ch.(^Index_Unique_Internal)
		}
	}
	unreachable()
}

bplus_nu_internal_child_index_upper :: proc(
	nu_inode: ^Index_Non_Unique_Internal,
	key: Database_Value,
) -> int {
	i := 0
	for i < nu_inode.count &&
	    value_ordering_for_column_sorting(nu_inode.keys[i], key) != .Greater {
		i += 1
	}
	return i
}

bplus_nu_find_leaf_upper_bound :: proc(
	root: Index_Non_Unique_Node,
	key: Database_Value,
) -> (
	leaf: ^Index_Non_Unique_Leaf,
	slot: int,
) {
	switch root in root {
	case nil:
		return nil, 0
	case ^Index_Non_Unique_Leaf:
		return root, index_tree_non_unique_upper_bound_index_leaf(root, key)
	case ^Index_Non_Unique_Internal:
		nu_inode := root
		for {
			idx := bplus_nu_internal_child_index_upper(nu_inode, key)
			ch := nu_inode.children[idx]
			L, leaf_ok := ch.(^Index_Non_Unique_Leaf)
			if leaf_ok {
				return L, index_tree_non_unique_upper_bound_index_leaf(L, key)
			}
			nu_inode = ch.(^Index_Non_Unique_Internal)
		}
	}
	unreachable()
}

bplus_nu_destroy_child :: proc(
	c: Index_Non_Unique_Node,
	on_remove: proc(key: Database_Value, value: [dynamic]Row_Index, user_data: rawptr),
	user_data: rawptr,
) {
	switch c in c {
	case ^Index_Non_Unique_Leaf:
		L := c
		for i := 0; i < L.count; i += 1 {
			if on_remove != nil {
				on_remove(L.keys[i], L.refs[i], user_data)
			} else {
				delete(L.refs[i])
			}
		}
		free(L, context.allocator)
	case ^Index_Non_Unique_Internal:
		nu_inode := c
		for i := 0; i <= nu_inode.count; i += 1 {
			bplus_nu_destroy_child(nu_inode.children[i], on_remove, user_data)
		}
		free(nu_inode, context.allocator)
	}
}

bplus_nu_destroy_root :: proc(
	root: Index_Non_Unique_Node,
	// on_remove: proc(key: Database_Value, value: [dynamic]Row_Index, user_data: rawptr),
	user_data: rawptr,
) {
	switch root in root {
	case nil:
		return
	case ^Index_Non_Unique_Leaf:
		bplus_nu_destroy_child(root, nil, user_data)
	case ^Index_Non_Unique_Internal:
		bplus_nu_destroy_child(root, nil, user_data)
	}
}

index_tree_destroy :: proc(tree: ^Index_Tree) {
	if t, ok := tree^.(Index_Tree_Unique); ok {
		bplus_u_free_root(t.root)
		tree^ = {}
		return
	}
	if t, ok := tree^.(Index_Tree_Non_Unique); ok {
		bplus_nu_destroy_root(t.root, nil)
		tree^ = {}
	}
}

@(require_results)
ensure_index_tree_is_unique :: proc(tree: ^Index_Tree) -> bool {
	_, ok := tree^.(Index_Tree_Unique)
	if !ok {
		log.errorf("Index tree is not unique")
	}
	return ok
}

index_tree_unique_value :: proc(tree: ^Index_Tree) -> (result: Index_Tree_Unique, ok: bool) {
	return tree^.(Index_Tree_Unique)
}

index_tree_non_unique_value :: proc(
	tree: ^Index_Tree,
) -> (
	result: Index_Tree_Non_Unique,
	ok: bool,
) {
	return tree^.(Index_Tree_Non_Unique)
}

index_tree_unique_contains :: proc(tree: ^Index_Tree, key: Database_Value) -> bool {
	t := index_tree_unique_value(tree) or_return
	if t.entry_count == 0 {
		return false
	}
	leaf, _ := bplus_u_find_leaf_lower_bound(t.root, key)
	if leaf == nil {
		return false
	}
	_, hit := index_tree_unique_find_pos_entries(leaf.keys[:leaf.count], key)
	return hit
}

index_tree_unique_find :: proc(
	tree: ^Index_Tree,
	key: Database_Value,
) -> (
	value: Row_Index,
	ok: bool,
) {
	unique_tree := index_tree_unique_value(tree) or_return
	if unique_tree.entry_count == 0 {
		return
	}
	leaf, _ := bplus_u_find_leaf_lower_bound(unique_tree.root, key)
	if leaf == nil {
		return
	}
	idx, hit := index_tree_unique_find_pos_entries(leaf.keys[:leaf.count], key)
	if !hit {
		return
	}
	return leaf.vals[idx], true
}

index_tree_unique_insert :: proc(
	table_name: string,
	tree: ^Index_Tree,
	key: Database_Value,
	value: Row_Index,
) -> (
	ok: bool,
) {
	unique_tree := tree^.(Index_Tree_Unique)
	if unique_tree.entry_count > 0 {
		leaf, _ := bplus_u_find_leaf_lower_bound(unique_tree.root, key)
		if leaf != nil {
			if _, hit := index_tree_unique_find_pos_entries(leaf.keys[:leaf.count], key); hit {
				msgf(
					.Error,
					.Database,
					"Primary key value already exists in table '%s'",
					table_name,
				)
				return false
			}
		}
	}
	if !bplus_u_insert(&unique_tree, key, value) {
		return false
	}
	tree^ = unique_tree
	return true
}

@(require_results)
index_tree_unique_remove_key :: proc(tree: ^Index_Tree, key: Database_Value) -> bool {
	t, ok := index_tree_unique_value(tree)
	if !ok {
		return false
	}
	if !bplus_u_remove_key(&t, key) {
		return false
	}
	tree^ = t
	return true
}

index_tree_unique_repoint :: proc(
	tree: ^Index_Tree,
	key: Database_Value,
	value: Row_Index,
) -> bool {
	t, ok := index_tree_unique_value(tree)
	if !ok {
		return false
	}
	if t.entry_count == 0 {
		return false
	}
	leaf, _ := bplus_u_find_leaf_lower_bound(t.root, key)
	if leaf == nil {
		return false
	}
	idx, hit := index_tree_unique_find_pos_entries(leaf.keys[:leaf.count], key)
	if !hit {
		return false
	}
	leaf.vals[idx] = value
	tree^ = t
	return true
}

index_tree_unique_len :: proc(tree: ^Index_Tree) -> int {
	t, ok := index_tree_unique_value(tree)
	if !ok {
		return 0
	}
	return t.entry_count
}

index_tree_unique_first_pos :: proc(tree: ^Index_Tree) -> Index_Tree_Unique_Pos {
	t, ok := index_tree_unique_value(tree)
	if !ok || t.entry_count == 0 {
		return {}
	}
	L := bplus_u_leftmost_leaf(t.root)
	if L == nil || L.count == 0 {
		return {}
	}
	return {leaf = L, slot = 0, valid = true}
}

index_tree_unique_last_pos :: proc(tree: ^Index_Tree) -> Index_Tree_Unique_Pos {
	t, ok := index_tree_unique_value(tree)
	if !ok || t.entry_count == 0 {
		return {}
	}
	L := bplus_u_rightmost_leaf(t.root)
	if L == nil || L.count == 0 {
		return {}
	}
	return {leaf = L, slot = L.count - 1, valid = true}
}

index_tree_unique_lower_bound_pos :: proc(
	tree: ^Index_Tree,
	key: Database_Value,
) -> Index_Tree_Unique_Pos {
	t, ok := index_tree_unique_value(tree)
	if !ok || t.entry_count == 0 {
		return {}
	}
	leaf, slot := bplus_u_find_leaf_lower_bound(t.root, key)
	if leaf == nil || slot >= leaf.count {
		return {}
	}
	return {leaf = leaf, slot = slot, valid = true}
}

index_tree_unique_upper_bound_pos :: proc(
	tree: ^Index_Tree,
	key: Database_Value,
) -> Index_Tree_Unique_Pos {
	t, ok := index_tree_unique_value(tree)
	if !ok || t.entry_count == 0 {
		return {}
	}
	leaf, slot := bplus_u_find_leaf_upper_bound(t.root, key)
	if leaf == nil || slot >= leaf.count {
		return {}
	}
	return {leaf = leaf, slot = slot, valid = true}
}

index_tree_unique_pos_valid :: proc(pos: Index_Tree_Unique_Pos) -> bool {
	return pos.valid
}

index_tree_unique_iter_from_pos :: proc(
	tree: ^Index_Tree,
	pos: Index_Tree_Unique_Pos,
	dir: Index_Tree_Direction,
) -> Index_Tree_Unique_Iter {
	t, ok := index_tree_unique_value(tree)
	if !ok || !pos.valid || pos.leaf == nil {
		return {}
	}
	slot := pos.slot
	if slot < 0 || slot >= pos.leaf.count {
		return {}
	}
	step := 1
	if dir == .Backward {
		step = -1
	}
	return {leaf = pos.leaf, slot = slot, step = step}
}

index_tree_unique_iter :: proc(
	tree: ^Index_Tree,
	dir: Index_Tree_Direction,
) -> (
	result: Index_Tree_Unique_Iter,
	ok: bool,
) {
	t := index_tree_unique_value(tree) or_return
	if t.entry_count == 0 {
		return
	}
	step := 1
	if dir == .Backward {
		L := bplus_u_rightmost_leaf(t.root)
		if L == nil || L.count == 0 {
			return
		}
		return {leaf = L, slot = L.count - 1, step = -1}, true
	}
	L := bplus_u_leftmost_leaf(t.root)
	if L == nil || L.count == 0 {
		return
	}
	return {leaf = L, slot = 0, step = 1}, true
}

index_tree_unique_iter_next :: proc(
	it: ^Index_Tree_Unique_Iter,
) -> (
	key: Database_Value,
	value: Row_Index,
	ok: bool,
) {
	if it.step == 0 {
		return
	}
	for it.leaf != nil {
		if it.step > 0 {
			if it.slot < it.leaf.count {
				k := it.leaf.keys[it.slot]
				v := it.leaf.vals[it.slot]
				it.slot += 1
				return k, v, true
			}
			it.leaf = it.leaf.next
			it.slot = 0
		} else {
			if it.slot < 0 {
				it.leaf = it.leaf.prev
				if it.leaf == nil {
					return
				}
				it.slot = it.leaf.count - 1
			}
			if it.slot >= 0 && it.slot < it.leaf.count {
				k := it.leaf.keys[it.slot]
				v := it.leaf.vals[it.slot]
				it.slot -= 1
				return k, v, true
			}
		}
	}
	return
}

index_tree_non_unique_find_refs_ptr :: proc(
	tree: ^Index_Tree,
	key: Database_Value,
) -> (
	refs: ^[dynamic]Row_Index,
	ok: bool,
) {
	t, is_non_unique := index_tree_non_unique_value(tree)
	if !is_non_unique {
		return
	}
	if t.entry_count == 0 {
		return
	}
	leaf, _ := bplus_nu_find_leaf_lower_bound(t.root, key)
	if leaf == nil {
		return
	}
	idx, hit := index_tree_unique_find_pos_entries(leaf.keys[:leaf.count], key)
	if !hit {
		return
	}
	return &leaf.refs[idx], true
}

index_tree_non_unique_add_ref :: proc(
	tree: ^Index_Tree,
	key: Database_Value,
	row_index: Row_Index,
) -> bool {
	if refs, exists := index_tree_non_unique_find_refs_ptr(tree, key); exists {
		append(refs, row_index)
		return true
	}
	t, ok := index_tree_non_unique_value(tree)
	if !ok {
		return false
	}
	if !bplus_nu_insert_new_key(&t, key, row_index) {
		return false
	}
	tree^ = t
	return true
}

index_tree_non_unique_remove_ref :: proc(
	tree: ^Index_Tree,
	key: Database_Value,
	row_index: Row_Index,
) -> bool {
	t, tree_ok := index_tree_non_unique_value(tree)
	if !tree_ok {
		return false
	}
	leaf, _ := bplus_nu_find_leaf_lower_bound(t.root, key)
	if leaf == nil {
		return false
	}
	idx, key_exists := index_tree_unique_find_pos_entries(leaf.keys[:leaf.count], key)
	if !key_exists {
		return false
	}
	refs := &leaf.refs[idx]
	ref_pos := -1
	for ref, i in refs^ {
		if ref == row_index {
			ref_pos = i
			break
		}
	}
	if ref_pos < 0 {
		return false
	}
	last := len(refs^) - 1
	refs^[ref_pos] = refs^[last]
	resize(refs, last)
	if len(refs^) > 0 {
		tree^ = t
		return true
	}
	removed_key := leaf.keys[idx]
	removed_refs := leaf.refs[idx]
	// Shift without delete(removed_refs): callback owns the dynamic array.
	for i := idx; i < leaf.count - 1; i += 1 {
		leaf.keys[i] = leaf.keys[i + 1]
		leaf.refs[i] = leaf.refs[i + 1]
	}
	leaf.count -= 1
	t.entry_count -= 1
	_, root_is_leaf := t.root.(^Index_Non_Unique_Leaf)
	if t.entry_count > 0 && leaf.count < INDEX_BPLUS_MIN_LEAF_KEYS && !root_is_leaf {
		bplus_nu_rebalance_leaf(&t, leaf)
	}
	// if t.impl.on_remove != nil {
	// 	// t.impl.on_remove(removed_key, removed_refs, nil)
	delete(removed_refs)
	// }
	tree^ = t
	return true
}

index_tree_non_unique_len :: proc(tree: ^Index_Tree) -> int {
	t, ok := index_tree_non_unique_value(tree)
	if !ok {
		return 0
	}
	return t.entry_count
}

index_tree_non_unique_first_pos :: proc(tree: ^Index_Tree) -> Index_Tree_Non_Unique_Pos {
	t, ok := index_tree_non_unique_value(tree)
	if !ok || t.entry_count == 0 {
		return {}
	}
	L := bplus_nu_leftmost_leaf(t.root)
	if L == nil || L.count == 0 {
		return {}
	}
	return {leaf = L, slot = 0, valid = true}
}

index_tree_non_unique_last_pos :: proc(tree: ^Index_Tree) -> Index_Tree_Non_Unique_Pos {
	t, ok := index_tree_non_unique_value(tree)
	if !ok || t.entry_count == 0 {
		return {}
	}
	L := bplus_nu_rightmost_leaf(t.root)
	if L == nil || L.count == 0 {
		return {}
	}
	return {leaf = L, slot = L.count - 1, valid = true}
}

index_tree_non_unique_lower_bound_pos :: proc(
	tree: ^Index_Tree,
	key: Database_Value,
) -> Index_Tree_Non_Unique_Pos {
	t, ok := index_tree_non_unique_value(tree)
	if !ok || t.entry_count == 0 {
		return {}
	}
	leaf, slot := bplus_nu_find_leaf_lower_bound(t.root, key)
	if leaf == nil || slot >= leaf.count {
		return {}
	}
	return {leaf = leaf, slot = slot, valid = true}
}

index_tree_non_unique_upper_bound_pos :: proc(
	tree: ^Index_Tree,
	key: Database_Value,
) -> Index_Tree_Non_Unique_Pos {
	t, ok := index_tree_non_unique_value(tree)
	if !ok || t.entry_count == 0 {
		return {}
	}
	leaf, slot := bplus_nu_find_leaf_upper_bound(t.root, key)
	if leaf == nil || slot >= leaf.count {
		return {}
	}
	return {leaf = leaf, slot = slot, valid = true}
}

index_tree_non_unique_pos_valid :: proc(pos: Index_Tree_Non_Unique_Pos) -> bool {
	return pos.valid
}

index_tree_non_unique_iter_from_pos :: proc(
	tree: ^Index_Tree,
	pos: Index_Tree_Non_Unique_Pos,
	dir: Index_Tree_Direction,
) -> Index_Tree_Non_Unique_Iter {
	t, ok := index_tree_non_unique_value(tree)
	if !ok || !pos.valid || pos.leaf == nil {
		return {}
	}
	if pos.slot < 0 || pos.slot >= pos.leaf.count {
		return {}
	}
	step := 1
	if dir == .Backward {
		step = -1
	}
	return {leaf = pos.leaf, slot = pos.slot, step = step}
}

index_tree_non_unique_iter :: proc(
	tree: ^Index_Tree,
	dir: Index_Tree_Direction,
) -> Index_Tree_Non_Unique_Iter {
	t, ok := index_tree_non_unique_value(tree)
	if !ok || t.entry_count == 0 {
		return {}
	}
	if dir == .Backward {
		L := bplus_nu_rightmost_leaf(t.root)
		if L == nil || L.count == 0 {
			return {}
		}
		return {leaf = L, slot = L.count - 1, step = -1}
	}
	L := bplus_nu_leftmost_leaf(t.root)
	if L == nil || L.count == 0 {
		return {}
	}
	return {leaf = L, slot = 0, step = 1}
}

index_tree_non_unique_iter_next :: proc(
	it: ^Index_Tree_Non_Unique_Iter,
) -> (
	key: Database_Value,
	refs: ^[dynamic]Row_Index,
	ok: bool,
) {
	if it.step == 0 {
		return
	}
	for it.leaf != nil {
		if it.step > 0 {
			if it.slot < it.leaf.count {
				k := it.leaf.keys[it.slot]
				r := &it.leaf.refs[it.slot]
				it.slot += 1
				return k, r, true
			}
			it.leaf = it.leaf.next
			it.slot = 0
		} else {
			if it.slot < 0 {
				it.leaf = it.leaf.prev
				if it.leaf == nil {
					return
				}
				it.slot = it.leaf.count - 1
			}
			if it.slot >= 0 && it.slot < it.leaf.count {
				k := it.leaf.keys[it.slot]
				r := &it.leaf.refs[it.slot]
				it.slot -= 1
				return k, r, true
			}
		}
	}
	return
}

index_tree_non_unique_update_ref :: proc(
	tree: ^Index_Tree,
	key: Database_Value,
	from, to: Row_Index,
) -> bool {
	refs, ok := index_tree_non_unique_find_refs_ptr(tree, key)
	if !ok {
		return false
	}
	for ref, i in refs^ {
		if ref == from {
			refs^[i] = to
			return true
		}
	}
	return false
}
