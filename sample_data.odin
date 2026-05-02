package main

// FIXME: remove
init_sample_db :: proc() {
	seed_sample_tables()
}

seed_sample_tables :: proc(allocator := context.allocator) {
	assert(database_tables_count == 0, "Database tables must be empty")

	// Keep schema slices static so column order and names stay stable for the
	// lifetime of the DB, even when runtime temp allocators are reused heavily.
	users_column_names := make([dynamic]string, allocator)
	append_elems(&users_column_names, ..[]string{"id", "name", "age", "status"})

	orders_column_names := make([dynamic]string, allocator)
	append_elems(&orders_column_names, ..[]string{"id", "user_id", "product", "amount"})

	payments_column_names := make([dynamic]string, allocator)
	append_elems(
		&payments_column_names,
		..[]string{"id", "order_id", "payer_user_id", "method", "status", "amount"},
	)

	shipments_column_names := make([dynamic]string, allocator)
	append_elems(
		&shipments_column_names,
		..[]string{"id", "order_id", "warehouse", "carrier", "state"},
	)

	// users_table := Table {
	// 	name                     = "users",
	// 	column_names             = users_column_names,
	// 	primary_key_column_index = 0,
	// }
	// table_init(&users_table, allocator)
	users_table: Table
	table_init(
		&users_table,
		name = "users",
		column_names = users_column_names,
		primary_key_column_index = 0,
	)
	assert(
		database_insert_row(
			&users_table,
			users_column_names[:],
			[]Database_Value{1, database_string_make("Alice"), 25, database_string_make("active")},
		),
	)
	assert(
		database_insert_row(
			&users_table,
			users_column_names[:],
			[]Database_Value{2, database_string_make("Bob"), 30, database_string_make("inactive")},
		),
	)
	assert(
		database_insert_row(
			&users_table,
			users_column_names[:],
			[]Database_Value {
				3,
				database_string_make("Charlie"),
				35,
				database_string_make("active"),
			},
		),
	)
	assert(
		database_insert_row(
			&users_table,
			users_column_names[:],
			[]Database_Value{4, database_string_make("Diana"), 28, database_string_make("active")},
		),
	)
	assert(
		database_insert_row(
			&users_table,
			users_column_names[:],
			[]Database_Value{5, database_string_make("Ethan"), 41, database_string_make("vip")},
		),
	)
	assert(
		database_insert_row(
			&users_table,
			users_column_names[:],
			[]Database_Value{6, database_string_make("Fiona"), 22, database_string_make("trial")},
		),
	)
	assert(database_tables_append(users_table))

	// orders_table := Table {
	// 	name                     = "orders",
	// 	column_names             = orders_column_names,
	// 	primary_key_column_index = 0,
	// }
	orders_table: Table
	table_init(
		&orders_table,
		name = "orders",
		column_names = orders_column_names,
		primary_key_column_index = 0,
	)
	assert(
		database_insert_row(
			&orders_table,
			orders_column_names[:],
			[]Database_Value{101, 1, database_string_make("Widget"), 100},
		),
	)
	assert(
		database_insert_row(
			&orders_table,
			orders_column_names[:],
			[]Database_Value{102, 2, database_string_make("Gadget"), 200},
		),
	)
	assert(
		database_insert_row(
			&orders_table,
			orders_column_names[:],
			[]Database_Value{103, 1, database_string_make("Tool"), 150},
		),
	)
	assert(
		database_insert_row(
			&orders_table,
			orders_column_names[:],
			[]Database_Value{104, 3, database_string_make("Monitor"), 350},
		),
	)
	assert(
		database_insert_row(
			&orders_table,
			orders_column_names[:],
			[]Database_Value{105, 4, database_string_make("Keyboard"), 80},
		),
	)
	assert(
		database_insert_row(
			&orders_table,
			orders_column_names[:],
			[]Database_Value{106, 4, database_string_make("Desk"), 420},
		),
	)
	assert(
		database_insert_row(
			&orders_table,
			orders_column_names[:],
			[]Database_Value{107, 5, database_string_make("Chair"), 260},
		),
	)
	assert(
		database_insert_row(
			&orders_table,
			orders_column_names[:],
			[]Database_Value{108, 6, database_string_make("Mouse"), 60},
		),
	)
	assert(database_tables_append(orders_table))

	// Keep payment rows separate from orders so nested subqueries can model
	// business state transitions (pending, settled, failed) independently.
	// payments_table := Table {
	// 	name                     = "payments",
	// 	column_names             = payments_column_names,
	// 	primary_key_column_index = 0,
	// }
	payments_table: Table
	table_init(
		&payments_table,
		name = "payments",
		column_names = payments_column_names,
		primary_key_column_index = 0,
	)
	assert(
		database_insert_row(
			&payments_table,
			payments_column_names[:],
			[]Database_Value {
				9001,
				101,
				1,
				database_string_make("card"),
				database_string_make("settled"),
				100,
			},
		),
	)
	assert(
		database_insert_row(
			&payments_table,
			payments_column_names[:],
			[]Database_Value {
				9002,
				102,
				2,
				database_string_make("bank"),
				database_string_make("failed"),
				200,
			},
		),
	)
	assert(
		database_insert_row(
			&payments_table,
			payments_column_names[:],
			[]Database_Value {
				9003,
				103,
				1,
				database_string_make("card"),
				database_string_make("settled"),
				150,
			},
		),
	)
	assert(
		database_insert_row(
			&payments_table,
			payments_column_names[:],
			[]Database_Value {
				9004,
				104,
				3,
				database_string_make("bank"),
				database_string_make("pending"),
				350,
			},
		),
	)
	assert(
		database_insert_row(
			&payments_table,
			payments_column_names[:],
			[]Database_Value {
				9005,
				105,
				4,
				database_string_make("wallet"),
				database_string_make("settled"),
				80,
			},
		),
	)
	assert(
		database_insert_row(
			&payments_table,
			payments_column_names[:],
			[]Database_Value {
				9006,
				106,
				4,
				database_string_make("card"),
				database_string_make("pending"),
				420,
			},
		),
	)
	assert(
		database_insert_row(
			&payments_table,
			payments_column_names[:],
			[]Database_Value {
				9007,
				107,
				5,
				database_string_make("card"),
				database_string_make("settled"),
				260,
			},
		),
	)
	assert(
		database_insert_row(
			&payments_table,
			payments_column_names[:],
			[]Database_Value {
				9008,
				108,
				6,
				database_string_make("wallet"),
				database_string_make("failed"),
				60,
			},
		),
	)
	assert(database_tables_append(payments_table))

	// Shipments intentionally omit payment status so joins have to combine both
	// tables to answer "paid and shipped" style questions.
	// shipments_table := Table {
	// 	name                     = "shipments",
	// 	column_names             = shipments_column_names,
	// 	primary_key_column_index = "id",
	// }
	shipments_table: Table
	table_init(
		&shipments_table,
		name = "shipments",
		column_names = shipments_column_names,
		primary_key_column_index = 0,
	)
	assert(
		database_insert_row(
			&shipments_table,
			shipments_column_names[:],
			[]Database_Value {
				5001,
				101,
				database_string_make("WAW-1"),
				database_string_make("DHL"),
				database_string_make("delivered"),
			},
		),
	)
	assert(
		database_insert_row(
			&shipments_table,
			shipments_column_names[:],
			[]Database_Value {
				5002,
				103,
				database_string_make("WAW-1"),
				database_string_make("UPS"),
				database_string_make("in_transit"),
			},
		),
	)
	assert(
		database_insert_row(
			&shipments_table,
			shipments_column_names[:],
			[]Database_Value {
				5003,
				105,
				database_string_make("BER-2"),
				database_string_make("InPost"),
				database_string_make("packed"),
			},
		),
	)
	assert(
		database_insert_row(
			&shipments_table,
			shipments_column_names[:],
			[]Database_Value {
				5004,
				107,
				database_string_make("PRG-4"),
				database_string_make("DHL"),
				database_string_make("delivered"),
			},
		),
	)
	assert(database_tables_append(shipments_table))
}
