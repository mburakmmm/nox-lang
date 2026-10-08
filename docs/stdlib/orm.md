# nox.orm

A micro-ORM: describe a table once, then create it and run parameterised insert/update/delete/select helpers over any [`DbConnection`](db.md#dbconnection-the-common-connection-interface). It is a
**query builder with typed values**, not an object mapper — there is no reflection in Nox, so results come back as [`Row`](db.md#row)s and you convert them to your own types.

```text
from nox.orm import Table, Column, Value
import nox.orm
```

**Capability:** none (it works over whichever driver you pass).

## Describing a table

| Constructor | Description |
|---|---|
| `Column(name, kind, is_primary_key)` | a column; `kind` is `0` integer, `1` text, `2` real (float) |
| `Table(name, columns)` | a table with its columns |

## Values

SQL values are wrapped in `Value`s so every statement is parameterised:

| Function | Description |
|---|---|
| `val_str(s)`, `val_int(i)`, `val_float(f)`, `val_bool(b)`, `val_null()` | construct a `Value` |

## Operations

| Function | Description |
|---|---|
| `create_table_sql(table)` | the `CREATE TABLE IF NOT EXISTS …` text |
| `create_table(conn, table)` | runs it |
| `insert(conn, table, values)` | inserts one row from a `dict[str, Value]` (column → value); returns the affected row count |
| `update(conn, table, values, where_sql, where_params)` | sets the given columns on rows matching `where_sql` (using `?` placeholders filled from `where_params`); returns the affected row count |
| `delete(conn, table, where_sql, where_params)` | deletes matching rows; returns the affected row count |
| `select(conn, table, where_sql, where_params)` | returns the matching rows as `list[Row]` in column order |

`where_sql` is a fragment such as `"age > ? AND name = ?"`; its values always come from `where_params`. Pass `""` for no condition. Column and table names are placed into the SQL text, so they must
come from your code, never from user input. Errors raise `OrmError` (or the driver's error).

```nox
import nox.sqlite
import nox.orm
from nox.sqlite import Connection
from nox.db import Row
from nox.orm import Table, Column, Value

conn: Connection = nox.sqlite.open(":memory:")
people: Table = Table("people", [Column("id", 0, True), Column("name", 1, False), Column("age", 0, False)])
print(nox.orm.create_table_sql(people))
nox.orm.create_table(conn, people)

vals: dict[str, Value] = {"name": nox.orm.val_str("grace"), "age": nox.orm.val_int(85)}
print(nox.orm.insert(conn, people, vals))
print(nox.orm.update(conn, people, {"age": nox.orm.val_int(86)}, "name = ?", [nox.orm.val_str("grace")]))
found: list[Row] = nox.orm.select(conn, people, "age > ?", [nox.orm.val_int(50)])
print(found[0].get_str(1), found[0].get_int(2))
print(nox.orm.delete(conn, people, "name = ?", [nox.orm.val_str("grace")]))
conn.close()
```

```output
CREATE TABLE IF NOT EXISTS people (id INTEGER PRIMARY KEY, name TEXT, age INTEGER)
1
1
grace 86
1
```

## Notes

- The SQL it generates uses `?` placeholders; with PostgreSQL use `Statement` directly, or a driver that accepts `?` (SQLite, MySQL).
- For anything beyond single-table CRUD (joins, aggregates) write the SQL yourself with `query` and `prepare`.
