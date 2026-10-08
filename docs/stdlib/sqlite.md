# nox.sqlite

An SQLite driver. It loads the system `libsqlite3` **at run time, the first time you call `open`**, so programs that never use SQLite have no dependency on it; if the library is not
installed, `open` raises a clean `SqliteError` instead of failing at build or start-up.

```text
import nox.sqlite
from nox.sqlite import Connection, SqliteError
```

**Capability:** `filesystem`.

## Functions and methods

| Member | Description |
|---|---|
| `open(path)` | opens (creating if needed) a database file, or `":memory:"` for a private in-memory database; raises `SqliteError` on failure |
| `Connection.execute(sql)` | runs a statement without parameters; returns the number of rows it changed |
| `Connection.query(sql)` | runs a query; returns `list[Row]` |
| `Connection.prepare(sql)` | a parameterised [`Statement`](db.md#statement) with `?` placeholders |
| `Connection.last_insert_rowid()` | the rowid of the most recent `INSERT` on this connection |
| `Connection.changes()` | the number of rows changed by the most recent statement |
| `Connection.close()` | closes the database |

Errors — a syntax error, a constraint violation, a locked database, a missing file — raise `SqliteError` carrying SQLite's message. Result rows are the shared [`Row`](db.md#row) type; parameters
are bound by **zero-based** index (`bind_str(0, …)` is the first `?`), and an out-of-range index raises `SqliteError`.

```nox
import nox.sqlite
from nox.sqlite import Connection, SqliteError
from nox.db import Row, Statement

conn: Connection = nox.sqlite.open(":memory:")
conn.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT, score REAL, note TEXT)")
print(conn.execute("INSERT INTO users (name, score) VALUES ('ada', 9.5)"), conn.last_insert_rowid(), conn.changes())

st: Statement = conn.prepare("INSERT INTO users (name, score, note) VALUES (?, ?, ?)")
st.bind_str(0, "alan")
st.bind_float(1, 7.25)
st.bind_null(2)
print(st.execute())

for r in conn.query("SELECT id, name, score, note FROM users ORDER BY id"):
    print(r.get_int(0), r.get_str(1), r.get_float(2), r.is_null(3))

q: Statement = conn.prepare("SELECT name FROM users WHERE id = ?")
q.bind_int(0, 2)
print(q.query()[0].get_str(0))

try:
    conn.execute("NOT SQL")
except SqliteError as e:
    print("SqliteError")
conn.close()
```

```output
1 1 1
1
1 ada 9.5 True
2 alan 7.25 True
alan
SqliteError
```

## Notes

- **Always pass values through `bind_*`**, never by building SQL from strings — see [Security](../reference/security.md).
- A connection is not safe to share between tasks that may run on different workers; open one per task, or serialise access through a channel.
- For the file-backed database, SQLite's own journalling gives you durability; wrap related changes in `BEGIN` / `COMMIT` with `execute`.
- To back up a live SQLite database safely use SQLite's `VACUUM INTO 'file'` or its online-backup API, not a plain file copy.
