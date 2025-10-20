# Tiny SQL engine

- tokenizer, parser
- `SELECT`, `INSERT`, `UPDATE`, `DELETE`, `CREATE` queries/commands with SQLite-like syntax and, somtimes, even semantics
- joins (inner, left, right)
- subqueries
- REPL-only 
- where conditions - logical/comparison/set/range/regex operators
- columns/rows are dynamically typed
- primary keys

# Setup
```bash
odin build .
odin run .
odin test . -sanitize:address -debug
```