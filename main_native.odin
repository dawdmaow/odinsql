#+ignore
#+build !js
#+feature dynamic-literals
package main

import "core:bufio"
import "core:fmt"
import "core:io"
import "core:os"
import "core:strings"

main :: proc() {
	context = my_context

	fmt.println("SQL Impostor REPL - Type 'exit' to quit, 'help' for commands")
	fmt.println("Sample tables: users, orders (if created)")

	// FIXME:
	// repl_db: Database
	// init_sample_db(&repl_db)

	stdin_reader: bufio.Reader
	bufio.reader_init(&stdin_reader, io.to_reader(os.to_stream(os.stdin)))
	defer bufio.reader_destroy(&stdin_reader)

	for {
		fmt.print("\nsql> ")
		query_bytes, err := bufio.reader_read_string(&stdin_reader, '\n')
		if err != .None {
			break
		}

		query := strings.trim_space(string(query_bytes))
		query_lower := strings.to_lower(query, database_query_allocator)

		if query_lower == "exit" {
			fmt.println("Goodbye!")
			break
		} else if query_lower == "help" {
			fmt.println("Commands:")
			fmt.println("  exit - quit the REPL")
			fmt.println("  help - show this help")
			fmt.println("  tables - show available tables")
			fmt.println("  sample - show sample queries")
			fmt.println(
				"  Any SQL query (SELECT, INSERT, UPDATE, DELETE, CREATE TABLE, CREATE INDEX)",
			)
			continue
		} else if query_lower == "tables" {
			fmt.println("Available tables:")
			for table in database_tables_items() {
				fmt.printf("  %v: %v\n", table.name, table.column_names)
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

		// Errors are automatically printed to the console.
		result, ok := exec(query, clear_msgs = true, allocator = context.allocator)

		if !ok {
			fmt.println("Query execution failed.")
			continue
		}

		switch r in result.result {
		case int:
			fmt.printf("Query executed successfully. Rows affected: %v\n", r)
		case Maybe(int):
			fmt.println("Query executed successfully.")
		case Rows_With_Names:
			if len(r.rows) == 0 {
				fmt.println("No results")
			} else {
				for row, i in r.rows {
					if i == 0 {
						first_row := true
						for key in row {
							if !first_row do fmt.print(" | ")
							fmt.printf("%10v", key)
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
					for value in row {
						if !first_val do fmt.print(" | ")
						switch &v in value {
						case Database_String:
							fmt.printf("%10s", database_string_unwrap(v))
						// case string:
						// 	fmt.printf("%10v", v)
						case int:
							fmt.printf("%10v", v)
						case f64:
							fmt.printf("%10v", v)
						case bool:
							fmt.printf("%10v", v)
						case nil:
							fmt.printf("%10v", "NULL")
						}
						first_val = false
					}
					fmt.println()
				}
				fmt.printf("\n%v row(s) returned\n", len(r.rows))
			}
			if len(result.execution_tree) > 0 {
				fmt.println(result.execution_tree)
			}
		}
	}
}
