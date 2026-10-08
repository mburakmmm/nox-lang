# nox.postgres

A PostgreSQL driver over `libpq`, loaded at run time on the first `open` (no link-time dependency; a missing library raises a clean `PostgresError`).

```text
import nox.postgres
from nox.postgres import Connection, PostgresError
```

**Capability:** `network`.

## Functions and methods

| Member | Description |
|---|---|
| `open(conninfo)` | connects; `conninfo` is passed to libpq unchanged, so both forms work: `"host=localhost user=app dbname=mydb"` and `"postgres://user:pass@host:5432/db"`; raises `PostgresError` on failure |
| `Connection.execute(sql)` | runs a statement; returns the affected row count |
| `Connection.query(sql)` | runs a query; returns `list[Row]` |
| `Connection.prepare(sql)` | a parameterised [`Statement`](db.md#statement) with **`$1`, `$2`, …** placeholders |
| `Connection.close()` | closes the connection |

Parameters are bound by **zero-based** index in the Nox API (`bind_str(0, …)` fills `$1`), accumulated and sent together when you call `execute()` or `query()`. Each `Statement` execution is an
independent request; there are no server-side named prepared statements.

There is no `last_insert_rowid()`: use PostgreSQL's idiom `INSERT … RETURNING id` and read the id from `query()`.

```nox
import nox.postgres
from nox.postgres import Connection, PostgresError
from nox.db import Row, Statement

def create_user(conn: Connection, name: str) -> int:
    st: Statement = conn.prepare("INSERT INTO users (name) VALUES ($1) RETURNING id")
    st.bind_str(0, name)
    rows: list[Row] = st.query()
    return rows[0].get_int(0)

def connect() -> Connection:
    return nox.postgres.open("postgres://app:secret@localhost:5432/appdb")
```

## Notes

- `libpq` (the PostgreSQL client library) must be installed on machines that call `open` — for example the `libpq5` package on Debian/Ubuntu.
- Prefer `Statement` parameters over concatenating SQL; they travel to the server separately from the SQL text.
- Do not share a connection between tasks that may run on different workers.
- For application code that should run on any driver, accept a [`DbConnection`](db.md#dbconnection-the-common-connection-interface).
