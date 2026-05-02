# SQL impostor

An in-process engine. Syntax is SQLite-ish.

### Supported statements

- **Query**: `SELECT … FROM … [JOIN …]* [WHERE …] [GROUP BY …] [HAVING …] [ORDER BY …] [LIMIT …] [OFFSET …]`.
- **DML**: `INSERT INTO … [(cols)] VALUES (rows…)`, `UPDATE … SET … [, …] [WHERE …]`, `DELETE FROM … [WHERE …]`.
- **DDL**: `CREATE TABLE [@COLUMNAR] … (columns… [, PRIMARY KEY(col)])`, `CREATE INDEX name ON table (col)`, `ALTER TABLE … ADD COLUMN …`, `RENAME COLUMN … TO …`, `DROP COLUMN …`, `DROP TABLE [IF EXISTS] …`.
- **Transactions**: `BEGIN`, `COMMIT`, `ROLLBACK`.

### Select details

- Projections: `*`, qualified names, expressions (arithmetic, unary `-`), optional `AS` / implicit aliases.
- **Joins**: `INNER`/`JOIN`, `LEFT JOIN`, `RIGHT JOIN`, `CROSS JOIN`; `ON` join condition; table/column aliases.
- **Subqueries**: `IN (SELECT …)`, derived tables `(SELECT …) AS alias`, including nested `IN` and inner `ORDER BY`/`LIMIT`.
- **Aggregates**: `COUNT(*)` / `COUNT(expr)`, `SUM`, `AVG` - with `GROUP BY`, `HAVING`.
- **Not implemented** `SELECT DISTINCT`, `UNION`, window functions, `CASE`.

### Predicates and literals

- Comparisons: `=`, `<>`, `!=`, `<`, `>`, `<=`, `>=`.
- Boolean combos: `AND`, `OR`, `NOT` (with precedence).
- Sets / ranges: `IN (…)`, `NOT IN`, `BETWEEN`, `NOT BETWEEN`.
- **String matching**: `LIKE` / `NOT LIKE` with SQL `%` and `_` wildcards (not full POSIX/regex).
- Literals: integers, floats, single-quoted strings (with escaping rules), `NULL`, `TRUE`, `FALSE`.

### Schema and types

- Declared types: `INTEGER`/`INT`, `FLOAT`/`DOUBLE`/`REAL`, `BOOL`/`BOOLEAN`, `TEXT`/`STRING`.
- **Primary key** required per table.
- **`NOT NULL`** on column definitions where supported by `CREATE`/`ALTER`.
- **`DROP TABLE IF EXISTS`**.

### Indexes and planning

- Unique index on PK; `CREATE INDEX` builds a non-unique B+ tree on one column.
- Planner can use PK or secondary indexes for selective `WHERE` and for index-backed `ORDER BY` on PK or indexed columns when the query allows.

---

## WASM playground

```bash
./build_wasm.sh
```

```bash
python -m http.server 8000
```

---

## Tests

```bash
odin test . -sanitize:address -debug
```
