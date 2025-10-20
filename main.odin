#+feature dynamic-literals
package main

import "core:bufio"
import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"

import "back"

// TODO: pretty ugly output of tables in repl

/*
- In-memory only (no persistence)
- No transactions or ACID guarantees
- No indexes (linear scans for all queries)
- Limited data type system
- No GROUP BY, ORDER BY, or LIMIT (yet)
- No aggregate functions (COUNT, SUM, AVG, etc.)
- No ALTER TABLE or DROP TABLE
- ORDER BY and LIMIT clauses
- Aggregate functions
- GROUP BY and HAVING
- More JOIN types (FULL OUTER, CROSS)
- Subqueries in WHERE clauses (IN subqueries partially supported)
- Table persistence (file I/O)
- Indexes for performance
- More sophisticated type system
- Better error messages with line/column info
*/

main :: proc() {
	context.logger = log.create_console_logger()
	context.assertion_failure_proc = back.assertion_failure_proc
	// assert(3 == 2)
	repl()
}

repl :: proc() {
	fmt.println("SQL Impostor REPL - Type 'exit' to quit, 'help' for commands")
	fmt.println("Sample tables: users, orders (if created)")

	repl_db: DB
	database_init(&repl_db)

	users_table := DB_Table {
		name         = "users",
		column_names = {"id", "name", "age", "status"},
		primary_key  = "id",
		rows         = make([dynamic]DB_Row),
	}
	append_elem(
		&users_table.rows,
		DB_Row{"id" = 1, "name" = "Alice", "age" = 25, "status" = "active"},
	)
	append_elem(
		&users_table.rows,
		DB_Row{"id" = 2, "name" = "Bob", "age" = 30, "status" = "inactive"},
	)
	append_elem(
		&users_table.rows,
		DB_Row{"id" = 3, "name" = "Charlie", "age" = 35, "status" = "active"},
	)
	repl_db.tables["users"] = users_table

	orders_table := DB_Table {
		name         = "orders",
		column_names = {"id", "user_id", "product", "amount"},
		primary_key  = "id",
		rows         = make([dynamic]DB_Row),
	}
	append_elem(
		&orders_table.rows,
		DB_Row{"id" = 101, "user_id" = 1, "product" = "Widget", "amount" = 100},
	)
	append_elem(
		&orders_table.rows,
		DB_Row{"id" = 102, "user_id" = 2, "product" = "Gadget", "amount" = 200},
	)
	append_elem(
		&orders_table.rows,
		DB_Row{"id" = 103, "user_id" = 1, "product" = "Tool", "amount" = 150},
	)
	repl_db.tables["orders"] = orders_table

	stdin_reader: bufio.Reader
	bufio.reader_init(&stdin_reader, os.stream_from_handle(os.stdin))
	defer bufio.reader_destroy(&stdin_reader)

	for {
		fmt.print("\nsql> ")
		query_bytes, err := bufio.reader_read_string(&stdin_reader, '\n')
		if err != nil && err != .None {
			break
		}

		query := strings.trim_space(string(query_bytes))
		query_lower := strings.to_lower(query, context.temp_allocator)

		if query_lower == "exit" {
			fmt.println("Goodbye!")
			break
		} else if query_lower == "help" {
			fmt.println("Commands:")
			fmt.println("  exit - quit the REPL")
			fmt.println("  help - show this help")
			fmt.println("  tables - show available tables")
			fmt.println("  sample - show sample queries")
			fmt.println("  Any SQL query (SELECT, INSERT, UPDATE, DELETE, CREATE TABLE)")
			continue
		} else if query_lower == "tables" {
			fmt.println("Available tables:")
			for table_name, table in repl_db.tables {
				fmt.printf("  %s: %v\n", table_name, table.column_names)
			}
			continue
		} else if query_lower == "sample" {
			fmt.println("Sample queries:")
			fmt.println("  SELECT * FROM users")
			fmt.println("  SELECT * FROM users WHERE age > 25")
			fmt.println("  SELECT * FROM users WHERE id IN (SELECT user_id FROM orders)")
			fmt.println("  SELECT * FROM users WHERE name IN ('Alice', 'Bob')")
			fmt.println("  INSERT INTO users VALUES (4, 'David', 40, 'active')")
			continue
		} else if len(query) == 0 {
			continue
		}

		result, ok := exec_query(&repl_db, query)

		if !ok {
			fmt.println("Error: Query execution failed")
			continue
		}

		switch r in result {
		case int:
			fmt.printf("Query executed successfully. Rows affected: %d\n", r)
		case [dynamic]DB_Row:
			if len(r) == 0 {
				fmt.println("No results")
			} else {
				for row, i in r {
					if i == 0 {
						first_row := true
						for key in row {
							if !first_row do fmt.print(" | ")
							fmt.printf("%10s", key)
							first_row = false
						}
						fmt.println()

						header_len := len(row) * 12 - 2
						for j := 0; j < header_len; j += 1 {
							fmt.print("-")
						}
						fmt.println()
					}

					first_val := true
					for _, value in row {
						if !first_val do fmt.print(" | ")
						switch v in value {
						case string:
							fmt.printf("%10s", v)
						case int:
							fmt.printf("%10d", v)
						case f64:
							fmt.printf("%10.2f", v)
						case bool:
							fmt.printf("%10v", v)
						case Nil:
							fmt.printf("%10s", "NULL")
						}
						first_val = false
					}
					fmt.println()
				}
				fmt.printf("\n%d row(s) returned\n", len(r))
			}
		}
	}
}
