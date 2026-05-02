#+build !js

package main

import "core:testing"

@(private)
_parser_test :: proc(
	t: ^testing.T,
	source: string,
	expected_ok: bool,
	test_ast: proc(t: ^testing.T, ast: ^AST_Node),
) {
	defer main_finish()
	main_init()
	tokens, tokens_ok := tokenize(source)
	testing.expect(t, tokens_ok)
	if !tokens_ok do return
	// defer delete(tokens)
	p := parser_init(tokens[:], source, database_query_allocator)
	ast, ast_ok := parse_query(&p)
	testing.expect(t, ast_ok == expected_ok)
	if !ast_ok do return
	if test_ast != nil do test_ast(t, ast)
}

@(test)
parser_test_empty_tokens_should_not_panic :: proc(t: ^testing.T) {
	_parser_test(t, "", false, nil)
}

@(test)
parser_test_invalid_start_token :: proc(t: ^testing.T) {
	_parser_test(t, "42", false, nil)
}

@(test)
parser_test_incomplete_select_missing_from :: proc(t: ^testing.T) {
	_parser_test(t, "SELECT *", false, nil)
}

@(test)
parser_test_select_1 :: proc(t: ^testing.T) {
	_parser_test(t, "SELECT * FROM users", true, nil)
}

@(test)
parser_test_select_literal_projection :: proc(t: ^testing.T) {
	_parser_test(t, "SELECT 1 FROM users", true, proc(t: ^testing.T, ast: ^AST_Node) {
		select_stmt := ast.value.(^Select)
		testing.expect_value(t, len(select_stmt.cols), 1)
		_, is_int := select_stmt.cols[0].expr.value.(^AST_Int)
		testing.expect(t, is_int)
	})
}

@(test)
parser_test_select_arithmetic_projection :: proc(t: ^testing.T) {
	_parser_test(t, "SELECT id + 1 FROM users", true, proc(t: ^testing.T, ast: ^AST_Node) {
		select_stmt := ast.value.(^Select)
		testing.expect_value(t, len(select_stmt.cols), 1)
		_, is_binary := select_stmt.cols[0].expr.value.(^Binary_Expression)
		testing.expect(t, is_binary)
	})
}

@(test)
parser_test_select_subquery :: proc(t: ^testing.T) {
	_parser_test(
		t,
		"SELECT * FROM (SELECT name FROM users) WHERE age > 18",
		true,
		proc(t: ^testing.T, ast: ^AST_Node) {
			select_stmt := ast.value.(^Select)
			select_subquery := select_stmt.table_or_subquery.value.(^Select)
			subquery_table := select_subquery.table_or_subquery.value.(^AST_Ident)
			testing.expect_value(t, subquery_table.column_name, "users")
		},
	)
}

@(test)
parser_test_select_order_by_limit_offset :: proc(t: ^testing.T) {
	_parser_test(
		t,
		"SELECT name FROM users ORDER BY age DESC, name ASC LIMIT 10 OFFSET 5",
		true,
		proc(t: ^testing.T, ast: ^AST_Node) {
			select_node := ast.value.(^Select)

			testing.expect_value(t, len(select_node.order_by), 2)
			testing.expect(t, select_node.order_by[0].descending)
			testing.expect(t, !select_node.order_by[1].descending)

			testing.expect_value(t, select_node.limit, 10)
			testing.expect_value(t, select_node.offset, 5)
		},
	)
}

@(test)
parser_test_create_index :: proc(t: ^testing.T) {
	_parser_test(
		t,
		"CREATE INDEX users_age_idx ON users(age)",
		true,
		proc(t: ^testing.T, ast: ^AST_Node) {
			create_idx := ast.value.(^Create_Index)
			testing.expect_value(t, create_idx.index_name, "users_age_idx")
			testing.expect_value(t, create_idx.table_name, "users")
			testing.expect_value(t, create_idx.column_name, "age")
		},
	)
}

@(test)
parser_test_create_table_keeps_declared_column_types :: proc(t: ^testing.T) {
	_parser_test(
		t,
		"CREATE TABLE inventory(item_id INTEGER, description TEXT, quantity INT, PRIMARY KEY(item_id))",
		true,
		proc(t: ^testing.T, ast: ^AST_Node) {
			create_table := ast.value.(^Create_Table)
			testing.expect_value(t, len(create_table.columns), 3)
			testing.expect_value(t, len(create_table.column_types), 3)
			testing.expect_value(t, len(create_table.column_not_null), 3)

			testing.expect_value(t, create_table.column_types[0], Database_Column_Type.Integer)
			testing.expect(t, !create_table.column_not_null[0])

			testing.expect_value(t, create_table.column_types[1], Database_Column_Type.Text)
			testing.expect(t, !create_table.column_not_null[1])

			testing.expect_value(t, create_table.column_types[2], Database_Column_Type.Integer)
			testing.expect(t, !create_table.column_not_null[2])
		},
	)
}

@(test)
parser_test_create_table_tracks_not_null_constraints :: proc(t: ^testing.T) {
	_parser_test(
		t,
		"CREATE TABLE users(id INTEGER NOT NULL, name TEXT NOT NULL, nickname TEXT, PRIMARY KEY(id))",
		true,
		proc(t: ^testing.T, ast: ^AST_Node) {
			create_table := ast.value.(^Create_Table)
			testing.expect_value(t, len(create_table.column_not_null), 3)
			testing.expect(t, create_table.column_not_null[0])
			testing.expect(t, create_table.column_not_null[1])
			testing.expect(t, !create_table.column_not_null[2])
		},
	)
}

@(test)
parser_test_create_table_with_columnar_tag :: proc(t: ^testing.T) {
	_parser_test(
		t,
		"CREATE TABLE @columnar users(id, PRIMARY KEY(id))",
		true,
		proc(t: ^testing.T, ast: ^AST_Node) {
			create_table := ast.value.(^Create_Table)
			testing.expect(t, create_table.is_columnar)
		},
	)
}

@(test)
parser_test_alter_table_add_column :: proc(t: ^testing.T) {
	_parser_test(
		t,
		"ALTER TABLE users ADD COLUMN score INT",
		true,
		proc(t: ^testing.T, ast: ^AST_Node) {
			alter := ast.value.(^Alter_Table)
			testing.expect_value(t, alter.table_name, "users")
			testing.expect_value(t, alter.operation, Alter_Table_Operation.Add_Column)
			testing.expect_value(t, alter.column_name, "score")
			col_type := alter.column_type
			testing.expect_value(t, col_type, Database_Column_Type.Integer)
			testing.expect(t, !alter.column_not_null)
		},
	)
}

@(test)
parser_test_alter_table_add_column_not_null :: proc(t: ^testing.T) {
	_parser_test(
		t,
		"ALTER TABLE users ADD COLUMN email TEXT NOT NULL",
		true,
		proc(t: ^testing.T, ast: ^AST_Node) {
			alter := ast.value.(^Alter_Table)
			testing.expect_value(t, alter.operation, Alter_Table_Operation.Add_Column)
			testing.expect_value(t, alter.column_name, "email")
			testing.expect(t, alter.column_not_null)
		},
	)
}

@(test)
parser_test_alter_table_rename_column :: proc(t: ^testing.T) {
	_parser_test(
		t,
		"ALTER TABLE users RENAME COLUMN name TO full_name",
		true,
		proc(t: ^testing.T, ast: ^AST_Node) {
			alter := ast.value.(^Alter_Table)
			testing.expect_value(t, alter.operation, Alter_Table_Operation.Rename_Column)
			testing.expect_value(t, alter.column_name, "name")
			testing.expect_value(t, alter.rename_to_column_name, "full_name")
		},
	)
}

@(test)
parser_test_drop_table_if_exists :: proc(t: ^testing.T) {
	_parser_test(t, "DROP TABLE IF EXISTS users", true, proc(t: ^testing.T, ast: ^AST_Node) {
		drop_stmt := ast.value.(^Drop_Table)
		testing.expect(t, drop_stmt.if_exists)
		testing.expect_value(t, drop_stmt.table_name, "users")
	})
}

@(test)
parser_test_insert_stmt_keeps_statement_token :: proc(t: ^testing.T) {
	_parser_test(
		t,
		"\n\n\nINSERT INTO users VALUES (1)",
		true,
		proc(t: ^testing.T, ast: ^AST_Node) {
			insert_stmt := ast.value.(^Insert)
			testing.expect_value(t, ast.token.line, 4)
			testing.expect_value(t, ast.token.column, 1)
			testing.expect_value(t, insert_stmt.token.line, 4)
			testing.expect_value(t, insert_stmt.token.column, 1)
		},
	)
}

@(test)
parser_test_join_keeps_join_clause_token :: proc(t: ^testing.T) {
	_parser_test(
		t,
		"SELECT * FROM users LEFT JOIN posts ON users.id = posts.user_id",
		true,
		proc(t: ^testing.T, ast: ^AST_Node) {
			select_stmt := ast.value.(^Select)
			testing.expect_value(t, len(select_stmt.joins), 1)
			testing.expect_value(t, select_stmt.joins[0].token.kind, Token_Kind.Left)
			testing.expect_value(t, select_stmt.joins[0].token.column, 21)
		},
	)
}

@(test)
parser_test_cross_join_without_on :: proc(t: ^testing.T) {
	_parser_test(
		t,
		"SELECT * FROM users CROSS JOIN orders",
		true,
		proc(t: ^testing.T, ast: ^AST_Node) {
			select_stmt := ast.value.(^Select)
			testing.expect_value(t, len(select_stmt.joins), 1)
			testing.expect_value(t, select_stmt.joins[0].join_type, Join_Type.Cross)
			testing.expect(t, select_stmt.joins[0].condition == nil)
		},
	)
}

@(test)
parser_test_cross_join_with_on_is_rejected :: proc(t: ^testing.T) {
	_parser_test(
		t,
		"SELECT * FROM users CROSS JOIN orders ON users.id = orders.user_id",
		false,
		nil,
	)
}

@(test)
parser_test_select_aliases_as_and_implicit :: proc(t: ^testing.T) {
	_parser_test(
		t,
		"SELECT u.name AS user_name, u.age years FROM users AS u JOIN orders o ON u.id = o.user_id",
		true,
		proc(t: ^testing.T, ast: ^AST_Node) {
			select_stmt := ast.value.(^Select)

			testing.expect_value(
				t,
				select_stmt.table_or_subquery.value.(^AST_Ident).column_name,
				"users",
			)
			testing.expect_value(t, select_stmt.table_alias, "u")

			testing.expect_value(t, select_stmt.cols[0].alias, "user_name")
			testing.expect_value(t, select_stmt.cols[1].alias, "years")

			testing.expect_value(t, len(select_stmt.joins), 1)
			testing.expect_value(t, select_stmt.joins[0].table_alias, "o")
		},
	)
}

@(test)
parser_test_rejects_trailing_tokens :: proc(t: ^testing.T) {
	_parser_test(t, "SELECT * FROM users junk more_junk", false, nil)
}

@(test)
parser_test_select_group_by_having_aggregate_calls :: proc(t: ^testing.T) {
	_parser_test(
		t,
		"SELECT user_id, COUNT(*) FROM orders GROUP BY user_id HAVING COUNT(*) > 1",
		true,
		proc(t: ^testing.T, ast: ^AST_Node) {
			select_stmt := ast.value.(^Select)

			testing.expect_value(t, len(select_stmt.group_by), 1)

			{
				group_by_ident := select_stmt.group_by[0].value.(^AST_Ident)
				testing.expect_value(t, group_by_ident.table_name, "")
				testing.expect_value(t, group_by_ident.column_name, "user_id")
			}

			having_condition := select_stmt.having.value.(^Condition)

			{
				having_lhs_call := having_condition.a.value.(^AST_Aggregate_Call)
				testing.expect_value(t, having_lhs_call.name, "COUNT")
				testing.expect_value(t, len(having_lhs_call.args), 1)

				having_lhs_arg := having_lhs_call.args[0].value.(^AST_Ident)
				testing.expect_value(t, having_lhs_arg.column_name, "*")
			}

			testing.expect_value(t, having_condition.op.value.(^AST_String).text, ">")
			testing.expect_value(t, having_condition.b.value.(^AST_Int).int, 1)

			testing.expect_value(t, len(select_stmt.cols), 2)
			_ = select_stmt.cols[1].expr.value.(^AST_Aggregate_Call)
		},
	)
}

@(test)
parser_test_select_sum_without_group_by :: proc(t: ^testing.T) {
	_parser_test(t, "SELECT SUM(id) FROM users;", true, proc(t: ^testing.T, ast: ^AST_Node) {
		select_stmt := ast.value.(^Select)
		testing.expect_value(t, len(select_stmt.cols), 1)
		_ = select_stmt.cols[0].expr.value.(^AST_Aggregate_Call)
	})
}

@(test)
parser_test_transaction_commands :: proc(t: ^testing.T) {
	_parser_test(t, "BEGIN", true, proc(t: ^testing.T, ast: ^AST_Node) {
		_, begin_ok := ast.value.(^Begin_Transaction)
		testing.expect(t, begin_ok)
	})
	_parser_test(t, "COMMIT", true, proc(t: ^testing.T, ast: ^AST_Node) {
		_, commit_ok := ast.value.(^Commit_Transaction)
		testing.expect(t, commit_ok)
	})
	_parser_test(t, "ROLLBACK", true, proc(t: ^testing.T, ast: ^AST_Node) {
		_, rollback_ok := ast.value.(^Rollback_Transaction)
		testing.expect(t, rollback_ok)
	})
}
