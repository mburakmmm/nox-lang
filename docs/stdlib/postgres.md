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
| `Connection.is_ok()` | is the connection still usable (not dropped)? |
| `Connection.set_statement_timeout(ms)` | server-side limit: a statement running longer than `ms` milliseconds is cancelled by the server (`kind == "query_canceled"`); `0` removes the limit. The connection stays usable |
| `Connection.set_lock_timeout(ms)` | the same for waiting on locks |
| `Connection.transaction()` | a [`Transaction`](#transactions) for `with` |
| `pool(conninfo, size, acquire_timeout_ms)` | a bounded [`Pool`](#connection-pool) |

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

## Errors

`PostgresError` is structured. For errors reported by the server the fields come from the protocol, so you never have to parse the message:

| Field / method | Meaning |
|---|---|
| `sqlstate` | the five-character SQLSTATE (`"23505"`); empty when no server was involved |
| `severity`, `detail`, `hint`, `table`, `column`, `constraint` | the server's diagnostic fields (empty when absent) |
| `kind` | `"unique_violation"` (23505), `"foreign_key_violation"` (23503), `"not_null_violation"` (23502), `"check_violation"` (23514), `"serialization_failure"` (40001), `"deadlock"` (40P01), `"query_canceled"` (57014: `statement_timeout`, cancel), `"connection"` (class 08, 57P01–57P03, and failures to connect or load libpq), otherwise `"other"` |
| `is_unique_violation()`, `is_serialization_failure()`, `is_deadlock()`, `is_query_canceled()`, `is_connection_error()` | shortcuts for `kind` |
| `is_retryable()` | `True` for serialization failures and deadlocks: retry the whole transaction. A connection error needs a **new connection** instead |

```text
try:
    conn.execute("INSERT INTO users (id) VALUES (1)")
except PostgresError as e:
    if e.is_unique_violation():
        print("duplicate", e.constraint)
```

## Transactions

`with conn.transaction() as tx:` runs `BEGIN`, and `__exit__` rolls back unless the body called `tx.commit()` first (Nox's `__exit__` cannot see an
exception, so the rule is "anything not explicitly committed is rolled back", like Go's `defer tx.Rollback()`). `tx` has `execute`, `query`, `prepare`, `commit` and `rollback`.

```text
with conn.transaction() as tx:
    tx.execute("UPDATE accounts SET balance = balance - 10 WHERE id = 1")
    tx.execute("UPDATE accounts SET balance = balance + 10 WHERE id = 2")
    tx.commit()        # leave the block without this and both updates are rolled back
```

## Connection pool

`nox.postgres.pool(conninfo, size, acquire_timeout_ms)` returns a `Pool` that opens at most `size` connections on demand. `acquire()` hands out an idle connection or a new one; when all
`size` are in use it waits **cooperatively** (other tasks keep running) and raises `PostgresError` after `acquire_timeout_ms`. Give the connection back with `give_back(conn)`: a
dropped connection is discarded (and replaced on the next `acquire`), an open transaction is rolled back. `close()` closes the idle connections. The pool's bookkeeping is protected by an
atomic lock, so one pool may be shared by tasks running on different workers; a single connection must be used by one task at a time.

```text
pool: Pool = nox.postgres.pool("host=localhost dbname=app", 4, 5000)
conn: Connection = pool.acquire()
try:
    rows: list[Row] = conn.query("SELECT 1")
finally:
    pool.give_back(conn)
```

## Notes

- libpq calls are synchronous: a slow query blocks its worker thread. With the default multi-core scheduler other tasks keep running on other workers; with QBE's single-threaded scheduler everything waits. Use `set_statement_timeout` to bound queries on the server. There is no client-side cancel (`PQcancel`) yet.

- `libpq` (the PostgreSQL client library) must be installed on machines that call `open` — for example the `libpq5` package on Debian/Ubuntu.
- Prefer `Statement` parameters over concatenating SQL; they travel to the server separately from the SQL text.
- Do not share a connection between tasks that may run on different workers.
- For application code that should run on any driver, accept a [`DbConnection`](db.md#dbconnection-the-common-connection-interface).

## On a mobile target (iOS, Android)

There is no `libpq` on a phone, so on `ios-*` and `android-*` targets `nox.postgres` uses a PostgreSQL protocol 3.0 client written in Zig, over the operating system's sockets. The API and the `conninfo` forms are the same; nothing has to be installed. Authentication: trust, cleartext, MD5 and SCRAM-SHA-256. Queries use the simple protocol (`execute`, `query`) and the extended protocol (`prepare` with `bind_*`).

- **TLS** is used only for `sslmode=require` and `verify-*`: the connection asks the server for TLS, then verifies its certificate and host name against the system CA store, and fails if it cannot (a self-signed certificate is refused; the client never falls back to plain text when `require` is set). Every other `sslmode`, including the default, is plain text, unlike libpq's `prefer`. **Use `sslmode=require` for any server that is not on a trusted local network.**
- Calls block the calling thread, and there is no read timeout: a server that never answers keeps the call waiting.
- Verified on the iOS simulator and the Android emulator against a real PostgreSQL server (`scripts/mobile_db_probe.py`).
