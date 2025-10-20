package main

import "core:fmt"
import "core:log"
import "core:mem"
import "core:strconv"

// TODO: context.allocator = p.allocator everywhere is crazy.

// AST_String :: distinct // TODO:

// Ident :: struct {
// 	table_prefix: string,
// 	name:         string,
// }

AST_Ident :: struct {
	using node:   AST_Node,
	table_prefix: string,
	name:         string,
}

ident_tstring :: proc(ident: ^AST_Ident) -> string {
	if ident.table_prefix != "" {
		return fmt.tprintf("%s.%s", ident.table_prefix, ident.name)
	}
	return ident.name
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
	^Join,
	^Condition,
	^Unary_Expression,
	[dynamic]^AST_Node,
	// Ident_Node,
}

// Ident_Node :: struct {
// 	using node: AST_Node,
// 	ident:      Ident,
// }

AST_Node :: struct {
	token: Token,
	value: AST_Node_Value, // TODO: don't turn operator tokens etc. into string values... just leave this a nil
}

Condition :: struct {
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

Join_Type :: enum {
	Inner,
	Left,
	Right,
}

Join :: struct {
	join_type: Join_Type,
	table:     ^AST_Node,
	condition: ^AST_Node,
}

Select :: struct {
	using node:        AST_Node,
	table_or_subquery: ^AST_Node,
	cols:              [dynamic]^AST_Ident,
	joins:             [dynamic]Join,
	where_clause:      ^AST_Node,
	order_by:          [dynamic]^AST_Node,
	limit:             Maybe(int),
	offset:            Maybe(int),
}

make_node :: proc(value: $T, token: Token) -> ^T {
	result := new(T)
	result^ = value
	result.node.value = result
	result.node.token = token
	return result
}

// Node_Ident :: struct {
// 	using node: AST_Node,
// 	ident:      Ident,
// }

Insert :: struct {
	table:             ^AST_Node,
	specified_columns: [dynamic]^AST_Node,
	value_lists:       [dynamic][dynamic]^AST_Node,
}

Update :: struct {
	table:        ^AST_Node,
	set_clauses:  [dynamic]struct {
		column: ^AST_Node,
		value:  ^AST_Node,
	},
	where_clause: Maybe(^AST_Node),
}

Delete :: struct {
	table:        ^AST_Node, // TODO:  make it an Ident/Select union...
	where_clause: Maybe(^AST_Node), // TODO: remove all Maybe in this project
}

Create_Table :: struct {
	table_name:  string,
	columns:     [dynamic]string,
	primary_key: Maybe(string),
}

Parser_Error :: struct {
	message: string,
	token:   Maybe(Token),
}

Parser :: struct {
	tokens:    []Token,
	i:         int,
	allocator: mem.Allocator,
}

parser_init :: proc(tokens: []Token, allocator := context.allocator) -> Parser {
	return Parser{tokens = tokens, i = 0, allocator = allocator}
}

error_at_current :: proc(p: ^Parser, message: string) -> Parser_Error {
	context.allocator = p.allocator

	if eof(p) {
		return Parser_Error{message = "Unexpected EOF", token = nil}
	}
	token := p.tokens[p.i]
	return Parser_Error {
		message = fmt.tprintf("%s at %d:%d", message, token.line, token.column),
		token = token,
	}
}

consume_keyword :: proc(p: ^Parser, keyword: Token_Kind) -> (ok: bool) {
	context.allocator = p.allocator

	if p.tokens[p.i].kind != keyword {
		return false
	}
	p.i += 1
	return true
}

eof :: proc(p: ^Parser) -> bool {
	return p.i >= len(p.tokens)
}

consume_columns :: proc(p: ^Parser) -> [dynamic]^AST_Ident {
	context.allocator = p.allocator

	cols := make([dynamic]^AST_Ident)
	for !eof(p) && p.tokens[p.i].kind != .From {
		ident: ^AST_Ident
		#partial switch p.tokens[p.i].kind {
		case .Ident, .Asterisk:
			ident = parse_ident(p.tokens[p.i])
		// case .Asterisk:
		// 	node.value = p.tokens[p.i].text
		case:
			log.errorf("Expected a column name at %d:%d", p.tokens[p.i].line, p.tokens[p.i].column)
			break
		}
		// node.token = p.tokens[p.i]
		append(&cols, ident)
		p.i += 1
		try_consume_comma(p)
	}
	return cols
}

parse_ident :: proc(token: Token) -> ^AST_Ident {
	context.allocator = context.temp_allocator

	for i := 0; i < len(token.text); i += 1 {
		if token.text[i] == '.' {
			return make_node(
				AST_Ident{table_prefix = token.text[:i], name = token.text[i + 1:]},
				token,
			)
		}
	}
	return make_node(AST_Ident{table_prefix = "", name = token.text}, token)
}

consume_ident :: proc(p: ^Parser, msg: string) -> (^AST_Node, bool) {
	context.allocator = p.allocator

	if eof(p) {
		log.errorf("Expected %s at %d:%d", msg, p.tokens[p.i].line, p.tokens[p.i].column)
		return nil, false
	}
	if p.tokens[p.i].kind == .Ident {
		node := new(AST_Node)
		node.value = parse_ident(p.tokens[p.i])
		node.token = p.tokens[p.i]
		p.i += 1
		return node, true
	}
	log.errorf("Expected %s at %d:%d", msg, p.tokens[p.i].line, p.tokens[p.i].column)
	return nil, false
}

try_current_token :: proc(p: ^Parser) -> Maybe(Token) {
	context.allocator = p.allocator

	if eof(p) {
		return nil
	}
	return p.tokens[p.i]
}

try_consume_keyword :: proc(p: ^Parser, keyword: Token_Kind) -> bool {
	context.allocator = p.allocator

	token := try_current_token(p)
	if t, ok := token.?; ok {
		if t.kind == keyword {
			p.i += 1
			return true
		}
	}
	return false
}

try_consume_operator :: proc(p: ^Parser, operator: Token_Kind) -> bool {
	context.allocator = p.allocator

	if !eof(p) {
		if p.tokens[p.i].kind == operator {
			p.i += 1
			return true
		}
	}
	return false
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

consume_binary_operator :: proc(p: ^Parser) -> (^AST_Node, bool) {
	context.allocator = p.allocator

	if eof(p) {
		return nil, false
	}
	kind := p.tokens[p.i].kind
	if is_binary_operator(kind) {
		node := make_node(AST_String{text = p.tokens[p.i].text}, p.tokens[p.i]) // TODO: use a different node kind
		p.i += 1
		return node, true
	}
	return nil, false
}

consume_term :: proc(p: ^Parser) -> (^AST_Node, bool) {
	context.allocator = p.allocator

	if eof(p) {
		return nil, false
	}
	kind := p.tokens[p.i].kind

	if is_unary_operator(kind) {
		op_token := p.tokens[p.i]
		p.i += 1
		operand, ok := consume_term(p)
		if !ok {
			return nil, false
		}

		op_node := make_node(AST_String{text = op_token.text}, op_token) // TODO: use a different node kind

		unary_expr := make_node(Unary_Expression{op = op_node, operand = operand}, op_token)
		return unary_expr, true
	}

	if kind == .Open_Paren {
		p.i += 1

		if !eof(p) && p.tokens[p.i].kind == .Select {
			subquery, ok := parse_select(p)
			if !ok {
				return nil, false
			}
			if eof(p) || p.tokens[p.i].kind != .Close_Paren {
				log.error("Expected closing parenthesis after subquery")
				return nil, false
			}
			p.i += 1
			return subquery, true
		} else {
			expr, ok := consume_expression(p)
			if !ok {
				return nil, false
			}
			if eof(p) || p.tokens[p.i].kind != .Close_Paren {
				log.error("Expected closing parenthesis")
				return nil, false
			}
			p.i += 1
			return expr, true
		}
	}

	if kind == .Ident {
		node := new(AST_Node)
		node.value = parse_ident(p.tokens[p.i])
		node.token = p.tokens[p.i]
		p.i += 1
		return node, true
	} else if kind == .String {
		node := make_node(AST_String{text = p.tokens[p.i].text}, p.tokens[p.i])
		p.i += 1
		return node, true
	} else if kind == .Number {
		node := new(AST_Node)
		text := p.tokens[p.i].text

		has_dot := false
		for i := 0; i < len(text); i += 1 {
			if text[i] == '.' {
				has_dot = true
				break
			}
		}

		if has_dot {
			val, ok := strconv.parse_f64(text)
			if !ok {
				return nil, false
			}
			node.value = make_node(AST_Float{float = val}, p.tokens[p.i])
		} else {
			val, ok := strconv.parse_int(text)
			if !ok {
				return nil, false
			}
			node.value = make_node(AST_Int{int = val}, p.tokens[p.i])
		}
		node.token = p.tokens[p.i]
		p.i += 1
		return node, true
	} else if kind == .Null {
		node := new(AST_Node)
		node.value = nil
		node.token = p.tokens[p.i]
		p.i += 1
		return node, true
	} else if kind == .True {
		node := new(AST_Node)
		node.value = true
		node.token = p.tokens[p.i]
		p.i += 1
		return node, true
	} else if kind == .False {
		node := new(AST_Node)
		node.value = false
		node.token = p.tokens[p.i]
		p.i += 1
		return node, true
	}


	return nil, false
}

try_consume_comma :: proc(p: ^Parser) -> bool {
	context.allocator = p.allocator

	token := try_current_token(p)
	if t, ok := token.?; ok {
		if t.kind == .Comma {
			p.i += 1
			return true
		}
	}
	return false
}

consume_expression :: proc(p: ^Parser) -> (^AST_Node, bool) {
	context.allocator = p.allocator

	return consume_or_expression(p)
}

consume_or_expression :: proc(p: ^Parser) -> (^AST_Node, bool) {
	context.allocator = p.allocator

	left, ok := consume_and_expression(p)
	if !ok {
		return nil, false
	}

	for !eof(p) && try_consume_operator(p, .Or) {
		op_token := p.tokens[p.i - 1]
		right, right_ok := consume_and_expression(p)
		if !right_ok {
			return nil, false
		}

		op_node := make_node(AST_String{text = op_token.text}, op_token) // TODO: use a different node kind
		cond := make_node(Condition{a = left, op = op_node, b = right}, op_token) // TODO: token should probably be nil __INVALID__

		left = cond
	}

	return left, true
}

consume_and_expression :: proc(p: ^Parser) -> (^AST_Node, bool) {
	context.allocator = p.allocator

	left, ok := consume_comparison_expression(p)
	if !ok {
		return nil, false
	}

	for !eof(p) && try_consume_operator(p, .And) {
		op_token := p.tokens[p.i - 1]
		right, right_ok := consume_comparison_expression(p)
		if !right_ok {
			return nil, false
		}

		op_node := make_node(AST_String{text = op_token.text}, op_token) // TODO: use a different node kind

		cond := make_node(Condition{a = left, op = op_node, b = right}, op_token) // TODO: token should probably be nil __INVALID__

		left = cond
	}

	return left, true
}

consume_in_operand :: proc(p: ^Parser) -> (^AST_Node, bool) {
	context.allocator = p.allocator

	if eof(p) {
		return nil, false
	}

	if p.tokens[p.i].kind == .Open_Paren {
		p.i += 1

		if !eof(p) && p.tokens[p.i].kind == .Select {
			subquery, ok := parse_select(p)
			if !ok {
				return nil, false
			}
			if eof(p) || p.tokens[p.i].kind != .Close_Paren {
				log.error("Expected closing parenthesis after subquery")
				return nil, false
			}
			p.i += 1
			return subquery, true
		} else {
			values := make([dynamic]^AST_Node)
			for !eof(p) && p.tokens[p.i].kind != .Close_Paren {
				kind := p.tokens[p.i].kind
				if kind == .Ident || kind == .String || kind == .Number || kind == .Null {
					val_node, ok := consume_term(p)
					if !ok {
						return nil, false
					}
					append(&values, val_node)
					try_consume_comma(p)
				} else {
					log.error("Expected a value")
					return nil, false
				}
			}

			if eof(p) || p.tokens[p.i].kind != .Close_Paren {
				log.error("Expected closing parenthesis")
				return nil, false
			}
			p.i += 1

			node := new(AST_Node)
			node.value = values
			node.token = p.tokens[p.i - 1]
			return node, true
		}
	}

	return nil, false
}

consume_between_operand :: proc(p: ^Parser) -> (^AST_Node, bool) {
	context.allocator = p.allocator

	if eof(p) {
		return nil, false
	}

	low, ok := consume_term(p)
	if !ok {
		return nil, false
	}

	if !try_consume_keyword(p, .And) {
		log.error("Expected AND after BETWEEN low value")
		return nil, false
	}

	high, ok2 := consume_term(p)
	if !ok2 {
		return nil, false
	}

	values := make([dynamic]^AST_Node)
	append(&values, low)
	append(&values, high)

	node := new(AST_Node)
	node.value = values
	node.token = low.token
	return node, true
}

consume_comparison_expression :: proc(p: ^Parser) -> (^AST_Node, bool) {
	context.allocator = p.allocator

	left, ok := consume_term(p)
	if !ok {
		return nil, false
	}

	if !eof(p) {
		kind := p.tokens[p.i].kind
		if is_binary_operator(kind) && kind != .And && kind != .Or {
			op, op_ok := consume_binary_operator(p)
			if !op_ok {
				return nil, false
			}

			right: ^AST_Node
			if kind == .In || kind == .Not_In {
				right_val, right_ok := consume_in_operand(p)
				if !right_ok {
					return nil, false
				}
				right = right_val
			} else if kind == .Between || kind == .Not_Between {
				right_val, right_ok := consume_between_operand(p)
				if !right_ok {
					return nil, false
				}
				right = right_val
			} else {
				right_val, right_ok := consume_term(p)
				if !right_ok {
					return nil, false
				}
				right = right_val
			}

			cond := new(Condition)
			cond.a = left
			cond.op = op
			cond.b = right

			result := new(AST_Node)
			result.value = cond
			result.token = left.token
			return result, true
		}
	}

	return left, true
}

consume_condition_list :: proc(p: ^Parser) -> (^AST_Node, bool) {
	context.allocator = p.allocator

	if !eof(p) {
		return consume_expression(p)
	}
	return nil, false
}

consume_one_value_list :: proc(p: ^Parser) -> ([dynamic]^AST_Node, bool) {
	context.allocator = p.allocator

	if eof(p) || p.tokens[p.i].kind != .Open_Paren {
		return nil, false
	}
	p.i += 1

	values := make([dynamic]^AST_Node)
	for !eof(p) && p.tokens[p.i].kind != .Close_Paren {
		kind := p.tokens[p.i].kind
		if kind == .Ident ||
		   kind == .String ||
		   kind == .Number ||
		   kind == .Null ||
		   kind == .True ||
		   kind == .False {
			val, ok := consume_term(p)
			if !ok {
				log.errorf(
					"Expected a value at %d:%d, got %v",
					p.tokens[p.i].line,
					p.tokens[p.i].column,
					p.tokens[p.i],
				)
				return nil, false
			}
			append(&values, val)
			try_consume_comma(p) or_break // TODO: 'or_break' wasn't here before. good idea?
		} else {
			log.errorf(
				"Expected a value at %d:%d, got %v",
				p.tokens[p.i].line,
				p.tokens[p.i].column,
				p.tokens[p.i],
			)
			return nil, false
		}
	}

	if eof(p) || p.tokens[p.i].kind != .Close_Paren {
		return nil, false
	}
	p.i += 1

	return values, true
}

consume_multiple_value_lists :: proc(p: ^Parser) -> ([dynamic][dynamic]^AST_Node, bool) {
	context.allocator = p.allocator

	values_list := make([dynamic][dynamic]^AST_Node)

	for !eof(p) {
		vals, ok := consume_one_value_list(p)
		if !ok {
			log.errorf("Expected a value list at %d:%d", p.tokens[p.i].line, p.tokens[p.i].column)
			return nil, false
		}
		append(&values_list, vals)
		if !try_consume_comma(p) {
			break
		}
	}

	return values_list, true
}

parse_insert :: proc(p: ^Parser) -> (^AST_Node, bool) {
	context.allocator = p.allocator

	start := p.tokens[p.i]

	if !consume_keyword(p, .Insert) {
		return nil, false
	}
	if !consume_keyword(p, .Into) {
		return nil, false
	}

	table, ok := consume_ident(p, "Expected a table name")
	if !ok {
		return nil, false
	}

	columns: [dynamic]^AST_Node
	if !eof(p) && p.tokens[p.i].kind == .Open_Paren {
		p.i += 1
		cols := make([dynamic]^AST_Node)
		for !eof(p) && p.tokens[p.i].kind != .Close_Paren {
			col, col_ok := consume_ident(p, "Expected a column name")
			if !col_ok {
				log.errorf(
					"Expected a column name at %d:%d",
					p.tokens[p.i].line,
					p.tokens[p.i].column,
				)
				return nil, false
			}
			append(&cols, col)
			try_consume_comma(p)
		}

		if eof(p) || p.tokens[p.i].kind != .Close_Paren {
			return nil, false
		}
		p.i += 1
		columns = cols
	}

	if !consume_keyword(p, .Values) {
		return nil, false
	}
	values, vals_ok := consume_multiple_value_lists(p)
	if !vals_ok {
		return nil, false
	}

	insert := new(Insert)
	insert.table = table
	insert.specified_columns = columns
	insert.value_lists = values

	result := new(AST_Node)
	result.value = insert
	result.token = start
	return result, true
}

parse_update :: proc(p: ^Parser) -> (^AST_Node, bool) {
	context.allocator = p.allocator

	start := p.tokens[p.i]

	if !consume_keyword(p, .Update) {
		return nil, false
	}
	table, ok := consume_ident(p, "Expected a table name")
	if !ok {
		return nil, false
	}
	if !consume_keyword(p, .Set) {
		return nil, false
	}

	set_clauses := make([dynamic]struct {
			column: ^AST_Node,
			value:  ^AST_Node,
		})

	for !eof(p) {
		column, col_ok := consume_ident(p, "Expected a column name")
		if !col_ok {
			return nil, false
		}

		if eof(p) || p.tokens[p.i].kind != .Equals {
			log.error("Expected '=' after column name")
			return nil, false
		}
		p.i += 1

		value, val_ok := consume_term(p)
		if !val_ok {
			return nil, false
		}
		append(&set_clauses, struct {
			column: ^AST_Node,
			value:  ^AST_Node,
		}{column = column, value = value})

		if !try_consume_comma(p) {
			break
		}
	}

	where_clause: Maybe(^AST_Node) = nil
	if try_consume_keyword(p, .Where) {
		where_node, where_ok := consume_condition_list(p)
		if where_ok {
			where_clause = where_node
		}
	}

	update := new(Update)
	update.table = table
	update.set_clauses = set_clauses
	update.where_clause = where_clause

	result := new(AST_Node)
	result.value = update
	result.token = start
	return result, true
}

parse_delete :: proc(p: ^Parser) -> (^AST_Node, bool) {
	context.allocator = p.allocator

	start := p.tokens[p.i]

	if !consume_keyword(p, .Delete) {
		return nil, false
	}
	if !consume_keyword(p, .From) {
		return nil, false
	}
	table, ok := consume_ident(p, "Expected a table name")
	if !ok {
		return nil, false
	}

	where_clause: Maybe(^AST_Node) = nil
	if try_consume_keyword(p, .Where) {
		where_node, where_ok := consume_condition_list(p)
		if where_ok {
			where_clause = where_node
		}
	}

	delete_stmt := new(Delete)
	delete_stmt.table = table
	delete_stmt.where_clause = where_clause

	result := new(AST_Node)
	result.value = delete_stmt
	result.token = start
	return result, true
}

parse_create_table :: proc(p: ^Parser) -> (^AST_Node, bool) {
	context.allocator = p.allocator

	start := p.tokens[p.i]
	if !consume_keyword(p, .Create) {
		return nil, false
	}
	if !consume_keyword(p, .Table) {
		return nil, false
	}

	table_name_node, ok := consume_ident(p, "Expected table name")
	if !ok {
		return nil, false
	}

	table_name: string
	if ident, is_ident := table_name_node.value.(^AST_Ident); is_ident {
		table_name = ident.name
	} else {
		return nil, false
	}

	if eof(p) || p.tokens[p.i].kind != .Open_Paren {
		return nil, false
	}
	p.i += 1

	columns := make([dynamic]string)
	primary_key: Maybe(string) = nil

	for !eof(p) && p.tokens[p.i].kind != .Close_Paren {
		if p.tokens[p.i].kind == .Primary {
			p.i += 1
			if !consume_keyword(p, .Key) {
				return nil, false
			}
			if eof(p) || p.tokens[p.i].kind != .Open_Paren {
				return nil, false
			}
			p.i += 1

			pk_col_node, pk_ok := consume_ident(p, "Expected primary key column name")
			if !pk_ok {
				return nil, false
			}

			pk_col_name: string
			if ident, is_ident := pk_col_node.value.(^AST_Ident); is_ident {
				pk_col_name = ident.name
			} else {
				return nil, false
			}

			primary_key = pk_col_name
			if eof(p) || p.tokens[p.i].kind != .Close_Paren {
				return nil, false
			}
			p.i += 1
		} else {
			col_node, col_ok := consume_ident(p, "Expected column name")
			if !col_ok {
				return nil, false
			}

			col_name: string
			if ident, is_ident := col_node.value.(^AST_Ident); is_ident {
				col_name = ident.name
			} else {
				return nil, false
			}
			append(&columns, col_name)

			for !eof(p) &&
			    p.tokens[p.i].kind != .Comma &&
			    p.tokens[p.i].kind != .Close_Paren &&
			    p.tokens[p.i].kind != .Primary {
				p.i += 1
			}
		}

		if !eof(p) && p.tokens[p.i].kind == .Comma {
			p.i += 1
		}
	}

	if eof(p) || p.tokens[p.i].kind != .Close_Paren {
		return nil, false
	}
	p.i += 1

	create_table := new(Create_Table)
	create_table.table_name = table_name
	create_table.columns = columns
	create_table.primary_key = primary_key

	result := new(AST_Node)
	result.value = create_table
	result.token = start
	return result, true
}

is_join_keyword :: proc(p: ^Parser) -> bool {
	context.allocator = p.allocator

	if eof(p) {
		return false
	}
	kind := p.tokens[p.i].kind
	return kind == .Join || kind == .Inner || kind == .Left || kind == .Right
}

parse_join :: proc(p: ^Parser) -> (Join, bool) {
	context.allocator = p.allocator

	join_type := Join_Type.Inner

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
		}
	}

	if !consume_keyword(p, .Join) {
		return Join{}, false
	}

	table, ok := consume_ident(p, "Expected table name after JOIN")
	if !ok {
		return Join{}, false
	}

	if !consume_keyword(p, .On) {
		return Join{}, false
	}

	condition, cond_ok := consume_condition_list(p)
	if !cond_ok {
		return Join{}, false
	}

	return Join{join_type = join_type, table = table, condition = condition}, true
}

parse_select :: proc(p: ^Parser) -> (result: ^Select, ok: bool) {
	context.allocator = p.allocator

	start := p.tokens[p.i]
	if !consume_keyword(p, .Select) {
		return {}, false
	}
	cols := consume_columns(p)
	if !consume_keyword(p, .From) {
		return {}, false
	}

	table: ^AST_Node
	table_ok: bool

	if !eof(p) && p.tokens[p.i].kind == .Open_Paren {
		p.i += 1
		if !eof(p) && p.tokens[p.i].kind == .Select {
			subquery, subquery_ok := parse_select(p)
			if !subquery_ok {
				return {}, false
			}
			if eof(p) || p.tokens[p.i].kind != .Close_Paren {
				log.error("Expected closing parenthesis after subquery")
				return {}, false
			}
			p.i += 1
			table = subquery
			table_ok = true
		} else {
			log.error("Expected SELECT after opening parenthesis in FROM clause")
			return {}, false
		}
	} else {
		table = consume_ident(p, "Expected a table name") or_return
	}

	joins := make([dynamic]Join)
	for !eof(p) && is_join_keyword(p) {
		join, join_ok := parse_join(p)
		if !join_ok {
			return {}, false
		}
		append(&joins, join)
	}

	where_clause: ^AST_Node = nil
	if try_consume_keyword(p, .Where) {
		where_node, where_ok := consume_condition_list(p)
		if where_ok {
			where_clause = where_node
		}
	}

	select_stmt: Select
	select_stmt.table_or_subquery = table
	select_stmt.joins = joins
	select_stmt.where_clause = where_clause
	select_stmt.order_by = make([dynamic]^AST_Node)
	select_stmt.limit = nil
	select_stmt.offset = nil
	select_stmt.cols = cols

	return make_node(select_stmt, start), true
}

parse_query :: proc(p: ^Parser) -> (^AST_Node, bool) {
	context.allocator = p.allocator

	if eof(p) {
		log.errorf("Unexpected EOF at %d:%d", p.tokens[p.i].line, p.tokens[p.i].column)
		return nil, false
	}

	start_token := p.tokens[p.i]
	kind := start_token.kind

	if kind == .Select {
		return parse_select(p)
	} else if kind == .Insert {
		return parse_insert(p)
	} else if kind == .Update {
		return parse_update(p)
	} else if kind == .Delete {
		return parse_delete(p)
	} else if kind == .Create {
		return parse_create_table(p)
	}

	return nil, false
}
