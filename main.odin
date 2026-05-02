#+vet explicit-allocators

package main

// import "back"
import "base:runtime"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:strings"

split_exec_statements :: proc(sql: string, query_allocator: mem.Allocator) -> []string {
	statements := make([dynamic]string, query_allocator)

	start := 0
	in_single := false
	in_double := false
	escape_next := false

	for ch, ch_i in sql {
		switch {
		case escape_next:
			escape_next = false

		case ch == '\\' && (in_single || in_double):
			escape_next = true

		case ch == '\'' && !in_double:
			in_single = !in_single

		case ch == '"' && !in_single:
			in_double = !in_double

		case ch == ';' && !in_single && !in_double:
			statement := strings.trim_space(sql[start:ch_i])
			if len(statement) > 0 do append(&statements, statement)
			start = ch_i + 1
		}
	}

	last_statement := strings.trim_space(sql[start:])
	if len(last_statement) > 0 do append(&statements, last_statement)

	return statements[:]
}

Msg_Source :: enum {
	Tokenizer,
	Parser,
	Database,
}

@(thread_local)
msgs_builder: strings.Builder

@(thread_local)
had_error_msg: bool

// TODO: use dynamic arena instead
@(thread_local)
query_arena_buffer: [1024 * 1024 * 50]byte
@(thread_local)
query_arena: mem.Arena

// @(init)
main_init :: proc() {
	when !ODIN_TEST {
		context.logger = log.create_console_logger(allocator = context.allocator)
	}
	mem.arena_init(&query_arena, query_arena_buffer[:])
	database_query_allocator = mem.arena_allocator(&query_arena) // This is fine,  if the allocator already existed this just reuses the same buffer.
	strings.builder_init(&msgs_builder, mem.arena_allocator(&query_arena)) // my_context = context
}

// @(fini)
main_finish :: proc() {
	strings.builder_destroy(&msgs_builder)
	delete_all_tables()
	when !ODIN_TEST {
		log.destroy_console_logger(context.logger, context.allocator)
	}
	free_all(database_query_allocator)
	mem.arena_free_all(&query_arena)
}

msgs_clear :: proc() {
	strings.builder_reset(&msgs_builder)
	had_error_msg = false
}

Msg_Kind :: enum {
	Error,
	Info,
}

msgf :: proc(
	kind: Msg_Kind,
	from: Msg_Source,
	format: string,
	args: ..any,
	loc := #caller_location,
) {
	source_color := "\x1b[0m"
	switch from {
	case .Tokenizer:
		source_color = "\x1b[96m"
	case .Parser:
		source_color = "\x1b[95m"
	case .Database:
		source_color = "\x1b[91m"
	}

	switch kind {
	case .Error:
		// TODO: make it red
		// TODO: use log.errorf, but only call it if a global expect_errors if not true. (in order to not make tests fail due to calling log.error when an error is actually expected)
		log.warnf(
			"%s[%v]\x1b[0m %s",
			source_color,
			from,
			fmt.tprintf(format, ..args),
			location = loc,
		)
	case .Info:
		log.infof(
			"%s[%v]\x1b[0m %s",
			source_color,
			from,
			fmt.tprintf(format, ..args),
			location = loc,
		)
	}

	// TODO: make it red if error
	fmt.sbprintf(&msgs_builder, "%s[%v]\x1b[0m ", source_color, from)
	fmt.sbprintf(&msgs_builder, format, ..args)
	fmt.sbprintln(&msgs_builder)

	had_error_msg = true
}
