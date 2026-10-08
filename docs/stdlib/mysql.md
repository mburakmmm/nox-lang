# nox.mysql

A MySQL / MariaDB driver over `libmysqlclient` (or the binary-compatible MariaDB connector), loaded at run time on the first `open_url`. A missing library raises a clean `MysqlError`.

```text
import nox.mysql
from nox.mysql import Connection, MysqlError
```

**Capability:** `network`.

## Functions and methods

| Member | Description |
|---|---|
| `open_url(conn_url)` | connects using `mysql://user:pass@host:port/database` (the port defaults to 3306); raises `MysqlError` on failure |
| `Connection.execute(sql)` | runs a statement; returns the affected row count |
| `Connection.query(sql)` | runs a query; returns `list[Row]` |
| `Connection.prepare(sql)` | a parameterised [`Statement`](db.md#statement) with `?` placeholders |
| `Connection.last_insert_rowid()` | the auto-increment id of the last `INSERT` |
| `Connection.changes()` | rows changed by the last statement |
| `Connection.close()` | closes the connection |

Parameters are bound by **zero-based** index. This driver escapes string values on the client with the library's own `mysql_real_escape_string` and substitutes them into the statement, so
bound values are protected from SQL injection even though there is no server-side prepared statement.

```nox
import nox.mysql
from nox.mysql import Connection, MysqlError
from nox.db import Row, Statement

def add_user(conn: Connection, name: str) -> int:
    st: Statement = conn.prepare("INSERT INTO users (name) VALUES (?)")
    st.bind_str(0, name)
    st.execute()
    return conn.last_insert_rowid()

def connect() -> Connection:
    return nox.mysql.open_url("mysql://app:secret@localhost:3306/appdb")
```

## Notes

- Install `libmysqlclient` (or MariaDB Connector/C) on machines that connect.
- Do not build SQL by concatenating untrusted text; use `bind_*`.
- Do not share a connection between tasks that may run on different workers.
