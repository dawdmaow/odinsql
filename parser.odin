#+vet explicit-allocators

package main

import "core:fmt"
import "core:mem"
import "core:strconv"
import "core:strings"

// TODO: context.allocator = p.allocator everywhere is crazy.

// AST_String :: distinct // TODO:

// Ident :: struct {
// 	table_prefix: string,
// 	name:         string,
// }

// TODO: experiement with #all_or_none on structs with node (just explicitly set node to nil there - unless the compiler will reuqire setting every node INTERNAL field?)

// FIXME: we should EXPLICITLY (with a union) differentiate between a scalar ident and a table.column kind of ident.... so we don't have this table_name/column_name madness
AST_Ident :: struct {
	using node:  AST_Node,
	table_name:  string,
	column_name: string,
	slot_id:     int, // TODO: this should be a Maybe(int), me thinks
}

ast_ident_as_string :: proc(ident: ^AST_Ident) -> string {
	// FIXME: isntead of using temp_allocator it should use parser specific arena.
	if ident.table_name != "" {
		return fmt.tprintf("%s.%s", ident.table_name, ident.column_name)
	}
	return ident.column_name
}

AST_String :: struct {
	using node: AST_Node,
	text:       string,
}

AST_Int :: struct {
	using node: AST_Node,
	int:        int,
}

AST_Float :: struct {
	using node: AST_Node,
	float:      f64,
}

AST_Node_Value :: union {
	^AST_String,
	^AST_Int,
	^AST_Float,
	bool,
	^AST_Ident,
	^Select,
	^Insert,
	^Update,
	^Delete,
	^Create_Table,
	^Create_Index,
	^Alter_Table,
	^Drop_Table,
	^Begin_Transaction,
	^Commit_Transaction,
	^Rollback_Transaction,
	^Join,
	^Condition,
	^Binary_Expression,
	^Unary_Expression,
	^AST_Aggregate_Call,
	[dynamic]^AST_Node,
	// Ident_Node,
}

// Ident_Node :: struct {
// 	using node: AST_Node,
// 	ident:      Ident,
// }

// TODO: #all_or_none
AST_Node :: struct {
	token:       Token,
	span_start:  int, // byte offset into parser.source, inclusive
	span_end:    int, // byte offset into parser.source, exclusive
	source_text: string, // exact query slice for this AST node span
	value:       AST_Node_Value, // TODO: don't turn operator tokens etc. into string values... just leave this a nil
}

Condition :: struct {
	using node: AST_Node,
	a:          ^AST_Node,
	op:         ^AST_Node,
	b:          ^AST_Node,
}

Binary_Expression :: struct {
	using node: AST_Node,
	a:          ^AST_Node,
	op:         ^AST_Node,
	b:          ^AST_Node,
}

Unary_Expression :: struct {
	using node: AST_Node,
	op:         ^AST_Node,
	operand:    ^AST_Node,
}

AST_Aggregate_Call :: struct {
	using node: AST_Node,
	name:       string,
	args:       [dynamic]^AST_Node,
}

Join_Type :: enum {
	Inner,
	Left,
	Right,
	Cross,
}

Join :: struct #all_or_none {
	token:       Token,
	join_type:   Join_Type,
	table:       ^AST_Node,
	table_alias: Maybe(string),
	condition:   ^AST_Node,
}

Select_Item :: struct #all_or_none {
	expr:  ^AST_Node,
	alias: Maybe(string),
}

Select :: struct {
	using node:        AST_Node,
	table_or_subquery: ^AST_Node,
	table_alias:       Maybe(string),
	cols:              [dynamic]Select_Item,
	joins:             [dynamic]Join,
	where_clause:      ^AST_Node,
	group_by:          [dynamic]^AST_Node,
	having:            ^AST_Node,
	order_by:          [dynamic]Order_By_Item,
	limit:             Maybe(int),
	offset:            Maybe(int),
}

Order_By_Item :: struct #all_or_none {
	expr:       ^AST_Node,
	descending: bool,
}

// TODO: this seems convoltued. i dont think node should even contain to pointer to itself
make_node_from :: proc(parser: Parser, value: $T, token: Token) -> ^T {
	result := new(T, parser.query_allocator)
	result^ = value
	result.node = AST_Node {
		value       = result,
		token       = token,
		span_start  = token.start,
		span_end    = token.end,
		source_text = token.text,
	}
	return result
}

// set_node_span_from_parser :: proc(node: ^AST_Node, p: ^Parser, span_start, span_end: int) {
// 	node.span_start = span_start
// 	node.span_end = span_end

// 	if span_start >= 0 && span_end >= span_start && span_end <= len(p.source) {
// 		node.source_text = p.source[span_start:span_end]
// 	}
// }

// Node_Ident :: struct {
// 	using node: AST_Node,
// 	ident:      Ident,
// }

Insert :: struct {
	using node:        AST_Node,
	table:             ^AST_Node,
	specified_columns: [dynamic]^AST_Node,
	value_lists:       [dynamic][dynamic]^AST_Node,
}

Update_Set_Clause :: struct #all_or_none {
	column: ^AST_Node,
	value:  ^AST_Node,
}

Update :: struct {
	using node:   AST_Node,
	table:        ^AST_Node,
	set_clauses:  [dynamic]Update_Set_Clause,
	where_clause: Maybe(^AST_Node),
}

Delete :: struct {
	using node:   AST_Node,
	table:        ^AST_Node, // TODO:  make it an Ident/Select union...
	where_clause: Maybe(^AST_Node), // TODO: remove all Maybe in this project
}

Create_Table :: struct {
	using node:      AST_Node,
	table_name:      string,
	is_columnar:     bool,
	columns:         [dynamic]string,
	column_types:    [dynamic]Maybe(Database_Column_Type),
	column_not_null: [dynamic]bool,
	primary_key:     Maybe(string),
}

Create_Index :: struct {
	using node:  AST_Node,
	index_name:  string,
	table_name:  string,
	column_name: string,
}

Alter_Table_Operation :: enum {
	Add_Column,
	Drop_Column,
	Rename_Column,
}

Alter_Table :: struct {
	using node:            AST_Node,
	table_name:            string,
	operation:             Alter_Table_Operation,
	column_name:           string,
	column_type:           Maybe(Database_Column_Type),
	column_not_null:       bool,
	rename_to_column_name: string,
}

Drop_Table :: struct {
	using node: AST_Node,
	table_name: string,
	if_exists:  bool,
}

Begin_Transaction :: struct {
	using node: AST_Node,
}

Commit_Transaction :: struct {
	using node: AST_Node,
}

Rollback_Transaction :: struct {
	using node: AST_Node,
}

Parser_Error :: struct {
	message: string,
	token:   Maybe(Token),
}

Parser :: struct #all_or_none {
	tokens:          []Token,
	i:               int,
	source:          string,
	query_allocator: mem.Allocator,
}

parser_init :: proc(tokens: []Token, source: string, query_allocator: mem.Allocator) -> Parser {
	return Parser{tokens = tokens, i = 0, source = source, query_allocator = query_allocator}
}

error_at_current :: proc(p: ^Parser, message: string) -> Parser_Error {
	if eof(p) {
		return Parser_Error{message = "Unexpected EOF", token = nil}
	}
	token := p.tokens[p.i]
	start_col := int(token.column)
	end_col := start_col + len(token.text)
	if end_col <= start_col {
		end_col = start_col + 1
	}
	return Parser_Error {
		message = fmt.tprintf(
			"%v at %v:%v-%v:%v",
			message,
			token.line,
			start_col,
			token.line,
			end_col,
		),
		token = token,
	}
}

parser_msgf_at_current :: proc(p: ^Parser, format: string, args: ..any) {
	message := fmt.tprintf(format, ..args)
	if eof(p) {
		if len(p.tokens) == 0 {
			msgf(.Error, .Parser, "%v (end of input)", message)
			return
		}
		// Cursor is past the last token; column is where the next token would start.
		last := p.tokens[len(p.tokens) - 1]
		start_col := int(last.column) + len(last.text)
		end_col := start_col + 1
		msgf(
			.Error,
			.Parser,
			"%v at %v:%v-%v:%v (end of input)",
			message,
			last.line,
			start_col,
			last.line,
			end_col,
		)
		return
	}
	t := p.tokens[p.i]
	start_col := int(t.column)
	end_col := start_col + len(t.text)
	if end_col <= start_col {
		end_col = start_col + 1
	}
	msgf(.Error, .Parser, "%v at %v:%v-%v:%v", message, t.line, start_col, t.line, end_col)
}

ensure_not_eof :: proc(p: ^Parser, fmt: string, args: ..any) -> bool {
	if eof(p) {
		parser_msgf_at_current(p, fmt, ..args)
		return false
	}
	return true
}

consume_token :: proc(p: ^Parser, token: Token_Kind, error_message: string) -> (ok: bool) {
	ensure_not_eof(p, error_message) or_return

	if p.tokens[p.i].kind != token {
		// Keep callsites free to provide plain messages while still surfacing enough
		// detail to debug tokenizer/parser boundaries in one error line.
		parser_msgf_at_current(
			p,
			"%v, got %v (%v)",
			error_message,
			p.tokens[p.i].kind,
			p.tokens[p.i].text,
		)
		return false
	}
	p.i += 1
	return true
}

consume_keyword :: proc(p: ^Parser, keyword: Token_Kind) -> (ok: bool) {
	ensure_not_eof(p, "Expected keyword '%v'", keyword) or_return

	if p.tokens[p.i].kind != keyword {
		parser_msgf_at_current(p, "Expected keyword '%v', got '%v'", keyword, p.tokens[p.i].kind)
		return false
	}
	p.i += 1
	return true
}

eof :: proc(p: ^Parser) -> bool {
	return p.i >= len(p.tokens)
}

consume_optional_alias :: proc(
	p: ^Parser,
	stop_tokens: []Token_Kind,
) -> (
	alias: Maybe(string),
	ok: bool,
) {
	if eof(p) {
		return nil, true
	}

	if maybe_consume_token(p, .As) {
		alias_ident := consume_ident(p, "Expected alias name after AS") or_return
		return alias_ident.column_name, true
	}

	for stop_token in stop_tokens {
		if p.tokens[p.i].kind == stop_token {
			return nil, true
		}
	}

	if p.tokens[p.i].kind == .Ident {
		alias_ident := consume_ident(p, "Expected alias name") or_return
		return alias_ident.column_name, true
	}

	return nil, true
}

consume_columns :: proc(p: ^Parser) -> (cols: [dynamic]Select_Item, ok: bool) {
	cols = make([dynamic]Select_Item, database_query_allocator)

	for !eof(p) && p.tokens[p.i].kind != .From {
		col_expr: ^AST_Node
		if p.tokens[p.i].kind == .Asterisk {
			col_expr = new(AST_Node, database_query_allocator)
			col_expr.value = parse_ident(p^, p.tokens[p.i])
			col_expr.token = p.tokens[p.i]
			p.i += 1
		} else {
			// SELECT list supports full expressions (literals, identifiers, unary/binary conditions, subqueries).
			// TODO: consider passing the error message string to consume_expession
			col_expr, ok = consume_expression(p)
			if !ok {
				parser_msgf_at_current(p, "Expected a SELECT expression")
				return
			}
		}
		alias, alias_ok := consume_optional_alias(p, []Token_Kind{.Comma, .From})
		if !alias_ok {
			return
		}
		append(&cols, Select_Item{expr = col_expr, alias = alias})

		if !eof(p) && p.tokens[p.i].kind != .From {
			consume_token(p, .Comma, "Expected ',' or FROM after SELECT expression") or_return
		}
	}

	// Should we assert a FROM token here?

	return cols, true
}

// TODO: probablys hould be inline in consume_ident
parse_ident :: proc(p: Parser, token: Token) -> ^AST_Ident {
	for i := 0; i < len(token.text); i += 1 {
		if token.text[i] == '.' {
			return make_node_from(
				p,
				AST_Ident {
					table_name = token.text[:i],
					column_name = token.text[i + 1:],
					slot_id = -1,
				},
				token,
			)
		}
	}
	return make_node_from(
		p,
		AST_Ident{table_name = "", column_name = token.text, slot_id = -1},
		token,
	)
}

// TODO: this REALLY should return AST_Ident rather than node directly...
consume_ident :: proc(p: ^Parser, msg: string) -> (result: ^AST_Ident, result_ok: bool) {
	ensure_not_eof(p, msg) or_return

	if p.tokens[p.i].kind == .Ident {
		result = parse_ident(p^, p.tokens[p.i])
		p.i += 1
		return result, true
	}

	parser_msgf_at_current(p, msg)
	return
}

consume_table_name :: proc(p: ^Parser) -> (^AST_Node, bool) {
	return consume_ident(p, "Expected a table name")
}

maybe_current_token :: proc(p: ^Parser) -> Maybe(Token) {
	if eof(p) do return nil
	return p.tokens[p.i]
}

maybe_consume_token :: proc(p: ^Parser, keyword: Token_Kind) -> bool {
	token := maybe_current_token(p)
	if t, ok := token.?; ok {
		if t.kind == keyword {
			p.i += 1
			return true
		}
	}
	return false
}

// TODO: why not use maybe_consume_token?
maybe_consume_operator :: proc(p: ^Parser, operator: Token_Kind) -> bool {
	if eof(p) do return false

	t := p.tokens[p.i]

	if t.kind == operator {
		p.i += 1
		return true
	}
	return false
}

// TODO: why not use maybe_consume_token?
maybe_consume_logical_connective :: proc(p: ^Parser, want_and: bool) -> bool {
	op: Token_Kind = want_and ? .And : .Or
	return maybe_consume_operator(p, op)
}

is_binary_operator :: proc(kind: Token_Kind) -> bool {
	return(
		kind == .Equals ||
		kind == .Equals ||
		kind == .Not_Equals ||
		kind == .Greater_Than ||
		kind == .Less_Than ||
		kind == .Gt_Eq ||
		kind == .Lt_Eq ||
		kind == .In ||
		kind == .Not_In ||
		kind == .Between ||
		kind == .Not_Between ||
		kind == .Like ||
		kind == .Not_Like ||
		kind == .And ||
		kind == .Or \
	)
}

is_unary_operator :: proc(kind: Token_Kind) -> bool {
	return kind == .Not
}

is_comparison_operator :: proc(kind: Token_Kind) -> bool {
	return(
		kind == .Equals ||
		kind == .Not_Equals ||
		kind == .Greater_Than ||
		kind == .Less_Than ||
		kind == .Gt_Eq ||
		kind == .Lt_Eq ||
		kind == .In ||
		kind == .Not_In ||
		kind == .Between ||
		kind == .Not_Between ||
		kind == .Like ||
		kind == .Not_Like \
	)
}

consume_binary_operator :: proc(p: ^Parser) -> (result: ^AST_Node, result_ok: bool) {
	ensure_not_eof(p, "Expected binary operator") or_return

	kind := p.tokens[p.i].kind
	if is_binary_operator(kind) {
		node := make_node_from(p^, AST_String{text = p.tokens[p.i].text}, p.tokens[p.i]) // TODO: use a different node kind
		p.i += 1
		return node, true
	}
	parser_msgf_at_current(p, "Expected binary operator")
	return
}

consume_term :: proc(
	p: ^Parser,
	error_fmt: string,
	args: ..any,
) -> (
	result: ^AST_Node,
	result_ok: bool,
) {
	ensure_not_eof(p, error_fmt, ..args) or_return
	kind := p.tokens[p.i].kind

	if is_unary_operator(kind) {
		op_token := p.tokens[p.i]
		p.i += 1
		operand := consume_term(p, error_fmt, ..args) or_return

		op_node := make_node_from(p^, AST_String{text = op_token.text}, op_token) // TODO: use a different node kind

		unary_expr := make_node_from(
			p^,
			Unary_Expression {
				op = op_node,
				operand = operand,
				token = op_token,
				span_start = op_token.start,
				span_end = operand.span_end,
				source_text = p.source[op_token.start:operand.span_end],
			},
			op_token,
		)
		return unary_expr, true
	}

	if kind == .Open_Paren {
		open_paren := p.tokens[p.i]
		p.i += 1

		if !eof(p) && p.tokens[p.i].kind == .Select {
			subquery := parse_select(p) or_return
			if eof(p) || p.tokens[p.i].kind != .Close_Paren {
				parser_msgf_at_current(p, "Expected closing parenthesis after subquery")
				return
			}
			close_paren := p.tokens[p.i]
			p.i += 1
			subquery.span_start = open_paren.start
			subquery.span_end = close_paren.end
			subquery.source_text = p.source[open_paren.start:close_paren.end]
			return subquery, true
		} else {
			expr := consume_expression(p) or_return
			if eof(p) || p.tokens[p.i].kind != .Close_Paren {
				parser_msgf_at_current(p, "Expected closing parenthesis")
				return
			}
			close_paren := p.tokens[p.i]
			p.i += 1
			expr.span_start = open_paren.start
			expr.span_end = close_paren.end
			expr.source_text = p.source[open_paren.start:close_paren.end]
			return expr, true
		}
	}

	if kind == .Ident {
		ident_token := p.tokens[p.i]
		p.i += 1

		if !eof(p) && p.tokens[p.i].kind == .Open_Paren {
			call_name := strings.to_upper(ident_token.text, database_query_allocator)
			if !aggregate_name_supported(call_name) {
				parser_msgf_at_current(
					p,
					"Unsupported function '%v', only COUNT/SUM/AVG are supported",
					ident_token.text,
				)
				return
			}

			p.i += 1 // consume '('
			call_args := make([dynamic]^AST_Node, database_query_allocator)
			for !eof(p) && p.tokens[p.i].kind != .Close_Paren {
				if p.tokens[p.i].kind == .Asterisk {
					append_elem(
						&call_args,
						make_node_from(
							p^,
							AST_Ident{table_name = "", column_name = "*", slot_id = -1},
							p.tokens[p.i],
						),
					)
					p.i += 1
				} else {
					append_elem(&call_args, consume_expression(p) or_return)
				}
				maybe_consume_comma(p) or_break
			}
			consume_token(p, .Close_Paren, "Expected ')' to close function call") or_return

			node := make_node_from(
				p^,
				AST_Aggregate_Call{name = call_name, args = call_args},
				ident_token,
			)
			node.span_start = ident_token.start
			node.span_end = p.tokens[p.i - 1].end
			node.source_text = p.source[node.span_start:node.span_end]
			return node, true
		}

		node := new(AST_Node, database_query_allocator)
		node^ = AST_Node {
			token       = ident_token,
			span_start  = ident_token.start,
			span_end    = ident_token.end,
			source_text = ident_token.text,
			value       = parse_ident(p^, ident_token),
		}
		return node, true
	} else if kind == .String {
		node := make_node_from(p^, AST_String{text = p.tokens[p.i].text}, p.tokens[p.i])
		p.i += 1
		return node, true
	} else if kind == .Number {
		// node := new(AST_Node, database_query_allocator)
		text := p.tokens[p.i].text

		has_dot := false
		for i := 0; i < len(text); i += 1 {
			if text[i] == '.' {
				has_dot = true
				break
			}
		}

		node: ^AST_Node
		if has_dot {
			val, ok := strconv.parse_f64(text)
			if !ok {
				parser_msgf_at_current(p, "Invalid float literal '%v'", text)
				return
			}
			node = make_node_from(p^, AST_Float{float = val}, p.tokens[p.i])
		} else {
			val, ok := strconv.parse_int(text)
			if !ok {
				parser_msgf_at_current(p, "Invalid integer literal '%v'", text)
				return
			}
			node = make_node_from(p^, AST_Int{int = val}, p.tokens[p.i])
		}
		node.token = p.tokens[p.i]
		node.span_start = p.tokens[p.i].start
		node.span_end = p.tokens[p.i].end
		node.source_text = p.tokens[p.i].text
		p.i += 1
		return node, true
	} else if kind == .Null {
		node := new(AST_Node, database_query_allocator)
		node^ = AST_Node {
			token       = p.tokens[p.i],
			span_start  = p.tokens[p.i].start,
			span_end    = p.tokens[p.i].end,
			source_text = p.tokens[p.i].text,
			value       = nil,
		}
		p.i += 1
		return node, true
	} else if kind == .True {
		node := new(AST_Node, database_query_allocator)
		node^ = AST_Node {
			token       = p.tokens[p.i],
			span_start  = p.tokens[p.i].start,
			span_end    = p.tokens[p.i].end,
			source_text = p.tokens[p.i].text,
			value       = true,
		}
		p.i += 1
		return node, true
	} else if kind == .False {
		node := new(AST_Node, database_query_allocator)
		node^ = AST_Node {
			token       = p.tokens[p.i],
			span_start  = p.tokens[p.i].start,
			span_end    = p.tokens[p.i].end,
			source_text = p.tokens[p.i].text,
			value       = false,
		}
		p.i += 1
		return node, true
	}

	parser_msgf_at_current(p, error_fmt, ..args)
	return
}

maybe_consume_comma :: proc(p: ^Parser) -> bool {
	token := maybe_current_token(p)
	if t, ok := token.?; ok {
		if t.kind == .Comma {
			p.i += 1
			return true
		}
	}
	return false
}

aggregate_name_supported :: proc(name: string) -> bool {
	name_upper := strings.to_upper(name, database_query_allocator)
	return name_upper == "COUNT" || name_upper == "SUM" || name_upper == "AVG"
}

consume_expression :: proc(p: ^Parser) -> (^AST_Node, bool) {
	return consume_or_expression(p)
}

consume_additive_expression :: proc(p: ^Parser) -> (result: ^AST_Node, result_ok: bool) {
	left := consume_multiplicative_expression(p) or_return

	for !eof(p) && (p.tokens[p.i].kind == .Plus || p.tokens[p.i].kind == .Minus) {
		span_start := left.span_start
		op_token := p.tokens[p.i]
		p.i += 1

		right := consume_multiplicative_expression(p) or_return

		op_node := make_node_from(p^, AST_String{text = op_token.text}, op_token)
		left = make_node_from(p^, Binary_Expression{a = left, op = op_node, b = right}, op_token)
		left.span_start = span_start
		left.span_end = right.span_end
		left.source_text = p.source[span_start:right.span_end]
	}

	return left, true
}

consume_multiplicative_expression :: proc(p: ^Parser) -> (result: ^AST_Node, result_ok: bool) {
	left := consume_term(p, "Expected a term") or_return

	for !eof(p) && (p.tokens[p.i].kind == .Asterisk || p.tokens[p.i].kind == .Slash) {
		span_start := left.span_start
		op_token := p.tokens[p.i]
		p.i += 1

		right := consume_term(p, "Expected a term") or_return

		op_node := make_node_from(p^, AST_String{text = op_token.text}, op_token)
		left = make_node_from(p^, Binary_Expression{a = left, op = op_node, b = right}, op_token)
		left.span_start = span_start
		left.span_end = right.span_end
		left.source_text = p.source[span_start:right.span_end]
	}

	return left, true
}

consume_or_expression :: proc(p: ^Parser) -> (result: ^AST_Node, result_ok: bool) {
	left := consume_and_expression(p) or_return

	for !eof(p) && maybe_consume_logical_connective(p, false) {
		op_token := p.tokens[p.i - 1]
		right := consume_and_expression(p) or_return

		op_node := make_node_from(p^, AST_String{text = op_token.text}, op_token) // TODO: use a different node kind

		// TODO: token should probably be nil __INVALID__?
		cond := make_node_from(
			p^,
			Condition {
				a = left,
				op = op_node,
				b = right,
				token = op_token,
				span_start = left.span_start,
				span_end = right.span_end,
				source_text = p.source[left.span_start:right.span_end],
			},
			op_token,
		)

		left = cond
	}

	return left, true
}

consume_and_expression :: proc(p: ^Parser) -> (result: ^AST_Node, result_ok: bool) {
	left := consume_comparison_expression(p) or_return

	for !eof(p) && maybe_consume_logical_connective(p, true) {
		op_token := p.tokens[p.i - 1]
		right := consume_comparison_expression(p) or_return

		// TODO: use a different node kind
		op_node := make_node_from(p^, AST_String{text = op_token.text}, op_token)

		// TODO: token should probably be nil __INVALID__?
		cond := make_node_from(
			p^,
			Condition {
				a = left,
				op = op_node,
				b = right,
				token = op_token,
				span_start = left.span_start,
				span_end = right.span_end,
				source_text = p.source[left.span_start:right.span_end],
			},
			op_token,
		)

		left = cond
	}

	return left, true
}

consume_in_operand :: proc(p: ^Parser) -> (result: ^AST_Node, result_ok: bool) {
	if eof(p) {
		parser_msgf_at_current(p, "Expected IN operand")
		return
	}

	if p.tokens[p.i].kind == .Open_Paren {
		open_paren := p.tokens[p.i]
		p.i += 1

		if !eof(p) && p.tokens[p.i].kind == .Select {
			subquery := parse_select(p) or_return
			if eof(p) || p.tokens[p.i].kind != .Close_Paren {
				parser_msgf_at_current(p, "Expected closing parenthesis after subquery")
				return
			}
			close_paren := p.tokens[p.i]
			p.i += 1
			subquery.span_start = open_paren.start
			subquery.span_end = close_paren.end
			subquery.source_text = p.source[open_paren.start:close_paren.end]
			return subquery, true
		} else {
			values := make([dynamic]^AST_Node, database_query_allocator)
			for !eof(p) && p.tokens[p.i].kind != .Close_Paren {
				kind := p.tokens[p.i].kind
				if kind == .Ident || kind == .String || kind == .Number || kind == .Null {
					val_node := consume_term(p, "Expected a value") or_return
					append(&values, val_node)
					maybe_consume_comma(p)
				} else {
					parser_msgf_at_current(p, "Expected a value")
					return
				}
			}

			if eof(p) || p.tokens[p.i].kind != .Close_Paren {
				parser_msgf_at_current(p, "Expected closing parenthesis")
				return
			}
			close_paren := p.tokens[p.i]
			p.i += 1

			node := new(AST_Node, database_query_allocator)
			node^ = AST_Node {
				token       = open_paren,
				span_start  = open_paren.start,
				span_end    = close_paren.end,
				source_text = open_paren.text,
				value       = values,
			}
			return node, true
		}
	}

	parser_msgf_at_current(p, "Expected parenthesized IN operand")
	return
}

consume_between_operand :: proc(p: ^Parser) -> (result: ^AST_Node, result_ok: bool) {
	if eof(p) {
		parser_msgf_at_current(p, "Expected BETWEEN low value")
		return
	}

	low := consume_term(p, "Expected BETWEEN low value") or_return

	// TODO: it's lame to have try_consume_keyword just to show a different error.
	// let's try making consume_keyword() take an optional custom error message so we can or_return here.
	consume_token(p, .And, "Expected AND after BETWEEN low value") or_return

	high := consume_term(p, "Expected BETWEEN high value") or_return

	values := make([dynamic]^AST_Node, database_query_allocator)
	append(&values, low)
	append(&values, high)

	node := new(AST_Node, database_query_allocator)
	node^ = AST_Node {
		token       = low.token,
		span_start  = low.span_start,
		span_end    = high.span_end,
		source_text = p.source[low.span_start:high.span_end],
		value       = values,
	}
	return node, true
}

consume_comparison_expression :: proc(p: ^Parser) -> (result: ^AST_Node, result_ok: bool) {
	left := consume_additive_expression(p) or_return

	if !eof(p) {
		kind := p.tokens[p.i].kind
		if is_comparison_operator(kind) {
			op := consume_binary_operator(p) or_return

			right: ^AST_Node
			if kind == .In || kind == .Not_In {
				right = consume_in_operand(p) or_return
			} else if kind == .Between || kind == .Not_Between {
				right = consume_between_operand(p) or_return
			} else {
				right = consume_additive_expression(p) or_return
			}

			cond := new(Condition, database_query_allocator)
			cond^ = Condition {
				a  = left,
				op = op,
				b  = right,
			}

			result := new(AST_Node, database_query_allocator)
			result^ = AST_Node {
				token       = left.token,
				span_start  = left.span_start,
				span_end    = right.span_end,
				source_text = p.source[left.span_start:right.span_end],
				value       = cond,
			}
			return result, true
		}
	}

	return left, true
}

consume_condition_list :: proc(p: ^Parser) -> (result: ^AST_Node, result_ok: bool) {
	if !eof(p) {
		return consume_expression(p)
	}
	return
}

consume_one_value_list :: proc(p: ^Parser) -> (result: [dynamic]^AST_Node, result_ok: bool) {
	// // TODO: an ensure_not_eof() helper would be nice.
	// if eof(p) do return

	consume_keyword(p, .Open_Paren) or_return
	// if p.tokens[p.i].kind != .Open_Paren do return

	values := make([dynamic]^AST_Node, database_query_allocator)
	for !eof(p) && p.tokens[p.i].kind != .Close_Paren {
		kind := p.tokens[p.i].kind
		if kind == .Ident ||
		   kind == .String ||
		   kind == .Number ||
		   kind == .Null ||
		   kind == .True ||
		   kind == .False {
			val := consume_term(p, "Expected a value") or_return
			append(&values, val)
			maybe_consume_comma(p) or_break
		} else {
			parser_msgf_at_current(p, "Expected a value")
			return
		}
	}

	consume_keyword(p, .Close_Paren) or_return
	// if eof(p) || p.tokens[p.i].kind != .Close_Paren {
	// 	return nil, false
	// }

	return values, true
}

consume_multiple_value_lists :: proc(
	p: ^Parser,
) -> (
	result: [dynamic][dynamic]^AST_Node,
	result_ok: bool,
) {
	values_list := make([dynamic][dynamic]^AST_Node, database_query_allocator)

	for !eof(p) {
		// vals := consume_one_value_list(p) or_return

		// NOTE: this error is probably unnecessary since consume_one_value_list should print ann error anyway
		// if !ok {
		// 	parser_msgf_at_current(p, "Expected a value list")
		// 	return nil, false
		// }

		append(&values_list, consume_one_value_list(p) or_return)
		maybe_consume_comma(p) or_break
	}

	return values_list, true
}

parse_insert :: proc(p: ^Parser) -> (result: ^AST_Node, result_ok: bool) {
	start := p.tokens[p.i]

	consume_keyword(p, .Insert) or_return
	consume_keyword(p, .Into) or_return

	table := consume_table_name(p) or_return

	columns := make([dynamic]^AST_Node, database_query_allocator)

	if !eof(p) && p.tokens[p.i].kind == .Open_Paren {
		p.i += 1
		cols := make([dynamic]^AST_Node, database_query_allocator)

		for !eof(p) && p.tokens[p.i].kind != .Close_Paren {
			col := consume_ident(p, "Expected a column name") or_return
			append(&cols, col)
			maybe_consume_comma(p)
		}

		if eof(p) || p.tokens[p.i].kind != .Close_Paren {
			parser_msgf_at_current(p, "Expected closing parenthesis after column list")
			return
		}
		p.i += 1
		columns = cols
	}

	consume_keyword(p, .Values) or_return
	values := consume_multiple_value_lists(p) or_return

	return make_node_from(
			p^,
			Insert{table = table, specified_columns = columns, value_lists = values},
			start,
		),
		true
}

parse_update :: proc(p: ^Parser) -> (result: ^AST_Node, result_ok: bool) {
	start := p.tokens[p.i]

	consume_keyword(p, .Update) or_return
	table := consume_table_name(p) or_return
	consume_keyword(p, .Set) or_return

	set_clauses := make([dynamic]Update_Set_Clause, database_query_allocator)
	for !eof(p) {
		column := consume_ident(p, "Expected a column name") or_return

		// TODO: just use consume_keyword here (with a custom error string)
		if eof(p) || p.tokens[p.i].kind != .Equals {
			parser_msgf_at_current(p, "Expected '=' after column name")
			return
		}
		p.i += 1

		value := consume_term(p, "Expected a value") or_return

		append(&set_clauses, Update_Set_Clause{column = column, value = value})

		maybe_consume_comma(p) or_break
	}

	where_clause: Maybe(^AST_Node) = nil

	if maybe_consume_token(p, .Where) {
		where_clause = consume_condition_list(p) or_return
	}

	return make_node_from(
			p^,
			Update{table = table, set_clauses = set_clauses, where_clause = where_clause},
			start,
		),
		true
}

parse_delete :: proc(p: ^Parser) -> (result: ^AST_Node, result_ok: bool) {
	start := p.tokens[p.i]

	consume_keyword(p, .Delete) or_return
	consume_keyword(p, .From) or_return
	table := consume_table_name(p) or_return

	where_clause: Maybe(^AST_Node)
	if maybe_consume_token(p, .Where) {
		where_clause = consume_condition_list(p) or_return
	}

	return make_node_from(p^, Delete{table = table, where_clause = where_clause}, start), true
}

parse_create_table :: proc(p: ^Parser) -> (result: ^AST_Node, result_ok: bool) {
	start := p.tokens[p.i]

	consume_keyword(p, .Create) or_return
	consume_keyword(p, .Table) or_return
	is_columnar := false
	if !eof(p) && p.tokens[p.i].kind == .Ident && strings.has_prefix(p.tokens[p.i].text, "@") {
		tag := strings.to_upper(p.tokens[p.i].text, database_query_allocator)
		if tag != "@COLUMNAR" {
			parser_msgf_at_current(p, "Unknown CREATE TABLE tag '%v'", p.tokens[p.i].text)
			return
		}
		is_columnar = true
		p.i += 1
	}
	table_ident := consume_ident(p, "Expected table name") or_return

	// TODO: .column_name is a terrible, terrible field name...
	table_name := table_ident.column_name

	// TODO: use a consume_keyword with a custom error string
	if eof(p) || p.tokens[p.i].kind != .Open_Paren {
		parser_msgf_at_current(p, "Expected '(' after CREATE TABLE table name")
		return
	}
	p.i += 1

	columns := make([dynamic]string, database_query_allocator)
	column_types := make([dynamic]Maybe(Database_Column_Type), database_query_allocator)
	column_not_null := make([dynamic]bool, database_query_allocator)
	primary_key: Maybe(string)

	for !eof(p) && p.tokens[p.i].kind != .Close_Paren {
		if p.tokens[p.i].kind == .Primary {
			p.i += 1
			consume_keyword(p, .Key) or_return
			// TODO: use a consume_keyword with a custom error string
			if eof(p) || p.tokens[p.i].kind != .Open_Paren {
				parser_msgf_at_current(p, "Expected '(' after PRIMARY KEY")
				return
			}
			p.i += 1

			pk_col_ident := consume_ident(p, "Expected primary key column name") or_return
			pk_col_name := pk_col_ident.column_name

			primary_key = pk_col_name
			// TODO: use a consume_keyword with a custom error string
			if eof(p) || p.tokens[p.i].kind != .Close_Paren {
				parser_msgf_at_current(p, "Expected ')' after PRIMARY KEY column")
				return
			}
			p.i += 1
		} else {
			col_node := consume_ident(p, "Expected column name") or_return
			col_name := col_node.column_name
			append(&columns, col_name)
			declared_type: Maybe(Database_Column_Type)
			is_not_null := false
			scan_i := p.i
			for scan_i < len(p.tokens) &&
			    p.tokens[scan_i].kind != .Comma &&
			    p.tokens[scan_i].kind != .Close_Paren &&
			    p.tokens[scan_i].kind != .Primary {
				if _, has_type := declared_type.?; !has_type {
					parsed_type := database_column_type_from_decl(p.tokens[scan_i].text)
					declared_type = parsed_type
					scan_i += 1
					continue
				}
				if scan_i + 1 < len(p.tokens) &&
				   p.tokens[scan_i].kind == .Not &&
				   p.tokens[scan_i + 1].kind == .Null {
					is_not_null = true
					scan_i += 2
					continue
				}
				scan_i += 1
			}
			p.i = scan_i
			append(&column_types, declared_type)
			append(&column_not_null, is_not_null)
		}

		if !eof(p) && p.tokens[p.i].kind == .Comma {
			p.i += 1
		}
	}

	// TODO: use a consume_keyword with a custom error string
	if eof(p) || p.tokens[p.i].kind != .Close_Paren {
		parser_msgf_at_current(p, "Expected ')' to close CREATE TABLE column list")
		return
	}
	p.i += 1

	create_table := Create_Table {
		table_name      = table_name,
		is_columnar     = is_columnar,
		columns         = columns,
		column_types    = column_types,
		column_not_null = column_not_null,
		primary_key     = primary_key,
	}
	return make_node_from(p^, create_table, start), true
}

parse_create_index :: proc(p: ^Parser) -> (result: ^AST_Node, result_ok: bool) {
	start := p.tokens[p.i]
	consume_keyword(p, .Create) or_return
	consume_keyword(p, .Index) or_return
	index_name := consume_ident(p, "Expected index name") or_return
	consume_keyword(p, .On) or_return
	table_name := consume_ident(p, "Expected table name after ON") or_return

	// TODO: use a consume_keyword with a custom error string
	if eof(p) || p.tokens[p.i].kind != .Open_Paren {
		parser_msgf_at_current(p, "Expected '(' after table name in CREATE INDEX")
		return
	}
	p.i += 1
	column_name := consume_ident(p, "Expected indexed column name") or_return

	// TODO: use a consume_keyword with a custom error string
	if eof(p) || p.tokens[p.i].kind != .Close_Paren {
		parser_msgf_at_current(p, "Expected ')' after indexed column in CREATE INDEX")
		return
	}
	p.i += 1

	create_index := Create_Index {
		index_name  = index_name.column_name,
		table_name  = table_name.column_name,
		column_name = column_name.column_name,
	}
	return make_node_from(p^, create_index, start), true
}

parse_create :: proc(p: ^Parser) -> (result: ^AST_Node, result_ok: bool) {
	if len(p.tokens) - p.i < 2 {
		parser_msgf_at_current(p, "Expected TABLE or INDEX after CREATE")
		return
	}
	next_kind := p.tokens[p.i + 1].kind
	#partial switch next_kind {
	case .Table:
		return parse_create_table(p)
	case .Index:
		return parse_create_index(p)
	case:
		parser_msgf_at_current(p, "Expected TABLE or INDEX after CREATE")
		return
	}
}

parse_alter_table :: proc(p: ^Parser) -> (result: ^AST_Node, result_ok: bool) {
	start := p.tokens[p.i]
	consume_keyword(p, .Alter) or_return
	consume_keyword(p, .Table) or_return

	table_name := consume_ident(p, "Expected table name after ALTER TABLE") or_return

	operation: Alter_Table_Operation
	column_name := ""
	column_type: Maybe(Database_Column_Type) = nil
	column_not_null := false
	rename_to_column_name := ""

	if maybe_consume_token(p, .Add) {
		consume_keyword(p, .Column) or_return
		column := consume_ident(p, "Expected column name after ADD COLUMN") or_return
		column_name = column.column_name
		operation = .Add_Column
		if !eof(p) {
			type_token := p.tokens[p.i]
			parsed_type := database_column_type_from_decl(type_token.text)
			column_type = parsed_type
			p.i += 1
		}
		for !eof(p) {
			if p.i + 1 < len(p.tokens) &&
			   p.tokens[p.i].kind == .Not &&
			   p.tokens[p.i + 1].kind == .Null {
				column_not_null = true
				p.i += 2
				continue
			}
			p.i += 1
		}
	} else if maybe_consume_token(p, .Drop) {
		consume_keyword(p, .Column) or_return
		column := consume_ident(p, "Expected column name after DROP COLUMN") or_return
		column_name = column.column_name
		operation = .Drop_Column
	} else if maybe_consume_token(p, .Rename) {
		consume_keyword(p, .Column) or_return
		old_column := consume_ident(p, "Expected source column name after RENAME COLUMN") or_return
		consume_keyword(p, .To) or_return
		new_column := consume_ident(p, "Expected destination column name after TO") or_return
		column_name = old_column.column_name
		rename_to_column_name = new_column.column_name
		operation = .Rename_Column
	} else {
		parser_msgf_at_current(
			p,
			"Expected ADD COLUMN, DROP COLUMN, or RENAME COLUMN after ALTER TABLE table name",
		)
		return
	}

	return make_node_from(
			p^,
			Alter_Table {
				table_name = table_name.column_name,
				operation = operation,
				column_name = column_name,
				column_type = column_type,
				column_not_null = column_not_null,
				rename_to_column_name = rename_to_column_name,
			},
			start,
		),
		true
}

parse_drop_table :: proc(p: ^Parser) -> (result: ^AST_Node, result_ok: bool) {
	start := p.tokens[p.i]
	consume_keyword(p, .Drop) or_return
	consume_keyword(p, .Table) or_return

	if_exists := false
	if maybe_consume_token(p, .If) {
		consume_keyword(p, .Exists) or_return
		if_exists = true
	}

	table_name := consume_ident(p, "Expected table name after DROP TABLE") or_return
	return make_node_from(
			p^,
			Drop_Table{table_name = table_name.column_name, if_exists = if_exists},
			start,
		),
		true
}

parse_begin_transaction :: proc(p: ^Parser) -> (result: ^AST_Node, result_ok: bool) {
	start := p.tokens[p.i]
	consume_keyword(p, .Begin) or_return
	return make_node_from(p^, Begin_Transaction{}, start), true
}

parse_commit_transaction :: proc(p: ^Parser) -> (result: ^AST_Node, result_ok: bool) {
	start := p.tokens[p.i]
	consume_keyword(p, .Commit) or_return
	return make_node_from(p^, Commit_Transaction{}, start), true
}

parse_rollback_transaction :: proc(p: ^Parser) -> (result: ^AST_Node, result_ok: bool) {
	start := p.tokens[p.i]
	consume_keyword(p, .Rollback) or_return
	return make_node_from(p^, Rollback_Transaction{}, start), true
}

is_join_keyword :: proc(p: ^Parser) -> bool {
	if eof(p) {
		return false
	}
	kind := p.tokens[p.i].kind
	return kind == .Join || kind == .Inner || kind == .Left || kind == .Right || kind == .Cross
}

parse_join :: proc(p: ^Parser) -> (result: Join, result_ok: bool) {
	if eof(p) {
		return
	}
	start := p.tokens[p.i]
	join_type := Join_Type.Inner

	// TODO: early return?
	if !eof(p) {
		kind := p.tokens[p.i].kind
		if kind == .Left {
			join_type = .Left
			p.i += 1
		} else if kind == .Right {
			join_type = .Right
			p.i += 1
		} else if kind == .Inner {
			join_type = .Inner
			p.i += 1
		} else if kind == .Cross {
			join_type = .Cross
			p.i += 1
		}
	}

	consume_keyword(p, .Join) or_return
	table := consume_ident(p, "Expected table name after JOIN") or_return
	table_alias, alias_ok := consume_optional_alias(
		p,
		[]Token_Kind {
			.On,
			.Join,
			.Inner,
			.Left,
			.Right,
			.Cross,
			.Where,
			.Group_By,
			.Having,
			.Order_By,
			.Limit,
			.Offset,
			.Semicolon,
		},
	)
	if !alias_ok {
		return
	}
	condition: ^AST_Node
	if join_type != .Cross {
		consume_keyword(p, .On) or_return
		condition = consume_condition_list(p) or_return
	}

	return Join {
			token = start,
			join_type = join_type,
			table = table,
			table_alias = table_alias,
			condition = condition,
		},
		true
}

consume_non_negative_int :: proc(
	p: ^Parser,
	keyword: Token_Kind,
) -> (
	result: int,
	result_ok: bool,
) {
	consume_keyword(p, keyword) or_return

	if eof(p) {
		parser_msgf_at_current(p, "Expected integer after '%v'", keyword)
		return
	}

	node := consume_term(p, "Expected a non-negative integer after '%v'", keyword) or_return

	int_ast, int_ok := node.value.(^AST_Int)
	if !int_ok {
		parser_msgf_at_current(p, "Expected integer value after '%v'", keyword)
		return
	}
	if int_ast.int < 0 {
		parser_msgf_at_current(p, "Expected non-negative integer after '%v'", keyword)
		return
	}
	return int_ast.int, true
}

consume_order_by :: proc(p: ^Parser) -> (result: [dynamic]Order_By_Item, result_ok: bool) {
	result = make([dynamic]Order_By_Item, database_query_allocator)

	if !maybe_consume_token(p, .Order_By) {
		return result, true
	}

	for !eof(p) {
		expr := consume_expression(p) or_return

		descending := false
		if maybe_consume_token(p, .Desc) {
			descending = true
		} else {
			maybe_consume_token(p, .Asc)
		}

		append(&result, Order_By_Item{expr = expr, descending = descending})

		maybe_consume_comma(p) or_break
	}
	if len(result) == 0 {
		parser_msgf_at_current(p, "ORDER BY requires at least one expression")
		return
	}

	return result, true
}

consume_group_by :: proc(p: ^Parser) -> (result: [dynamic]^AST_Node, result_ok: bool) {
	result = make([dynamic]^AST_Node, database_query_allocator)

	if !maybe_consume_token(p, .Group_By) {
		return result, true
	}

	for !eof(p) {
		expr := consume_expression(p) or_return
		append_elem(&result, expr)
		maybe_consume_comma(p) or_break
	}

	if len(result) == 0 {
		parser_msgf_at_current(p, "GROUP BY requires at least one expression")
		return
	}
	return result, true
}

parse_select :: proc(p: ^Parser) -> (result: ^Select, result_ok: bool) {
	start := p.tokens[p.i]
	consume_keyword(p, .Select) or_return

	cols := consume_columns(p) or_return
	consume_keyword(p, .From) or_return

	table: ^AST_Node
	table_ok: bool

	if !eof(p) && p.tokens[p.i].kind == .Open_Paren {
		p.i += 1
		if !eof(p) && p.tokens[p.i].kind == .Select {
			subquery := parse_select(p) or_return
			if eof(p) || p.tokens[p.i].kind != .Close_Paren {
				parser_msgf_at_current(p, "Expected closing parenthesis after subquery")
				return
			}
			p.i += 1
			table = subquery
			table_ok = true
		} else {
			parser_msgf_at_current(p, "Expected SELECT after opening parenthesis in FROM clause")
			return
		}
	} else {
		table = consume_table_name(p) or_return
	}
	table_alias, table_alias_ok := consume_optional_alias(
		p,
		[]Token_Kind {
			.Join,
			.Inner,
			.Left,
			.Right,
			.Cross,
			.Where,
			.Group_By,
			.Having,
			.Order_By,
			.Limit,
			.Offset,
			.Semicolon,
		},
	)
	if !table_alias_ok {
		return
	}

	joins := make([dynamic]Join, database_query_allocator)
	for !eof(p) && is_join_keyword(p) {
		join := parse_join(p) or_return
		append(&joins, join)
	}

	where_clause: ^AST_Node
	if maybe_consume_token(p, .Where) {
		where_clause = consume_condition_list(p) or_return
	}

	group_by := consume_group_by(p) or_return

	having: ^AST_Node
	if maybe_consume_token(p, .Having) {
		having = consume_condition_list(p) or_return
	}

	order_by := consume_order_by(p) or_return

	limit: Maybe(int) = nil
	if !eof(p) && p.tokens[p.i].kind == .Limit {
		lim := consume_non_negative_int(p, .Limit) or_return
		limit = lim
	}

	offset: Maybe(int) = nil
	if !eof(p) && p.tokens[p.i].kind == .Offset {
		off := consume_non_negative_int(p, .Offset) or_return
		offset = off
	}

	select_stmt := Select {
		table_or_subquery = table,
		table_alias       = table_alias,
		joins             = joins,
		where_clause      = where_clause,
		group_by          = group_by,
		having            = having,
		order_by          = order_by,
		limit             = limit,
		offset            = offset,
		cols              = cols,
	}

	return make_node_from(p^, select_stmt, start), true
}

parse_query :: proc(p: ^Parser) -> (result: ^AST_Node, result_ok: bool) {
	defer if result_ok do assert(result != nil)

	if eof(p) {
		msgf(.Error, .Parser, "Unexpected end of input")
		return
	}

	start_token := p.tokens[p.i]
	kind := start_token.kind

	node: ^AST_Node
	ok := false
	if kind == .Select {
		node, ok = parse_select(p)
	} else if kind == .Insert {
		node, ok = parse_insert(p)
	} else if kind == .Update {
		node, ok = parse_update(p)
	} else if kind == .Delete {
		node, ok = parse_delete(p)
	} else if kind == .Create {
		node, ok = parse_create(p)
	} else if kind == .Alter {
		node, ok = parse_alter_table(p)
	} else if kind == .Drop {
		node, ok = parse_drop_table(p)
	} else if kind == .Begin {
		node, ok = parse_begin_transaction(p)
	} else if kind == .Commit {
		node, ok = parse_commit_transaction(p)
	} else if kind == .Rollback {
		node, ok = parse_rollback_transaction(p)
	} else {
		msgf(
			.Error,
			.Parser,
			"Expected SELECT, INSERT, UPDATE, DELETE, CREATE, ALTER, DROP, BEGIN, COMMIT, or ROLLBACK at %v:%v",
			start_token.line,
			start_token.column,
		)
		return
	}

	if !ok {
		return
	}

	if !eof(p) && p.tokens[p.i].kind == .Semicolon {
		p.i += 1
	}

	if !eof(p) {
		t := p.tokens[p.i]
		msgf(.Error, .Parser, "Unexpected token '%v' at %v:%v", t.text, t.line, t.column)
		return
	}

	return node, true

}
