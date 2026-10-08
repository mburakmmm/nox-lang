# nox.db

The vocabulary shared by every SQL driver: **`Row`** and **`Statement`** classes, and the `DbConnection` protocol that [`nox.sqlite`](sqlite.md), [`nox.postgres`](postgres.md) and
[`nox.mysql`](mysql.md) connections all satisfy. Code written against `DbConnection` — such as [`nox.orm`](orm.md) — works with any of the three.

```text
from nox.db import Row, Statement, DbConnection
```

**Capability:** none for the module itself (the drivers carry `filesystem` or `network`).

## `DbConnection` — the common connection interface

A structural [protocol](../language/protocols-generics.md#protocols): any connection with these methods fits, no declaration needed.

| Method | Description |
|---|---|
| `execute(sql)` | runs a statement without parameters and returns the number of affected rows |
| `query(sql)` | runs a query and returns its rows as a `list[Row]` |
| `prepare(sql)` | prepares a parameterised statement and returns a `Statement` |
| `close()` | closes the connection |

A function with a `DbConnection` parameter is compiled once for each driver it is called with.

## `Row`

One result row. Every column is available through typed getters by **zero-based index**:

| Method | Description |
|---|---|
| `get_str(i)` | the column as text |
| `get_int(i)` | the column parsed as an `int` (`ValueError` if it is not a number or is `NULL`) |
| `get_float(i)` | the column parsed as a `float` |
| `is_null(i)` | whether the column is SQL `NULL` — check this before reading a nullable column |
| `column_count()` | the number of columns |
| `column_name(i)` | the name of column `i` |

Rows hold their values as text internally, so the getters convert on demand and a database that returns a number as text is read the same way.

## `Statement`

A prepared, parameterised statement. Placeholders are `?` (SQLite, MySQL) or `$1`, `$2`, … (PostgreSQL). Bind values by **zero-based** parameter index, then run it once:

| Method | Description |
|---|---|
| `bind_int(idx, value)`, `bind_float(idx, value)`, `bind_str(idx, value)`, `bind_null(idx)` | set parameter number `idx` (the first `?` is `0`). Values are passed as parameters, never concatenated into the SQL, so they cannot cause SQL injection. An out-of-range index raises the driver's error |
| `execute()` | runs the statement; returns the affected row count |
| `query()` | runs it and returns the rows |

A `Statement` is **single use**: it is finished by `execute()` or `query()`; prepare a new one to run again.

```nox
import nox.sqlite
from nox.sqlite import Connection
from nox.db import Row, Statement

conn: Connection = nox.sqlite.open(":memory:")
conn.execute("CREATE TABLE t (name TEXT, n INTEGER)")
ins: Statement = conn.prepare("INSERT INTO t (name, n) VALUES (?, ?)")
ins.bind_str(0, "ada")
ins.bind_int(1, 36)
print(ins.execute())
rows: list[Row] = conn.query("SELECT name, n FROM t")
print(rows[0].get_str(0), rows[0].get_int(1), rows[0].column_count(), rows[0].column_name(1), rows[0].is_null(1))
conn.close()
```

```output
1
ada 36 2 n False
```

## Writing driver-independent code

```nox
import nox.sqlite
from nox.sqlite import Connection
from nox.db import DbConnection, Row

def count_rows(db: DbConnection, table: str) -> int:
    rows: list[Row] = db.query("SELECT COUNT(*) FROM " + table)
    return rows[0].get_int(0)

c: Connection = nox.sqlite.open(":memory:")
c.execute("CREATE TABLE a (x INTEGER)")
c.execute("INSERT INTO a VALUES (1)")
c.execute("INSERT INTO a VALUES (2)")
print(count_rows(c, "a"))
c.close()
```

```output
2
```

(Table and column names cannot be bound as parameters — validate them yourself before concatenating.)
