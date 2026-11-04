# 14. Databases

Nox ships drivers for SQLite, PostgreSQL and MySQL/MariaDB. They share one shape — open a connection, run SQL, read rows — so what you learn with SQLite
carries straight over. This chapter uses SQLite because it needs no server: a database is a file (or, for experiments, just memory).

## Open, create, insert

```nox
import nox.sqlite
from nox.sqlite import Connection

db: Connection = nox.sqlite.open(":memory:")
db.execute("CREATE TABLE books (id INTEGER PRIMARY KEY, title TEXT NOT NULL, year INTEGER, rating REAL)")
db.execute("INSERT INTO books (title, year, rating) VALUES ('Dune', 1965, 4.5)")
print("inserted row", db.last_insert_rowid())
print("rows changed", db.changes())
db.close()
```

```output
inserted row 1
rows changed 1
```

`":memory:"` is a private database that disappears when the connection closes; pass a path such as `"library.db"` and the data stays on disk. `execute` runs a
statement and returns the number of rows it changed.

## Never build SQL from user input

Joining strings into SQL is how injection bugs happen. Use a **prepared statement**: write `?` where a value goes and bind the value separately. The driver
sends it as data, never as SQL, so quotes in the value cannot change the query:

```nox
import nox.sqlite
from nox.sqlite import Connection
from nox.db import Statement

db: Connection = nox.sqlite.open(":memory:")
db.execute("CREATE TABLE books (id INTEGER PRIMARY KEY, title TEXT, year INTEGER, rating REAL)")

insert: Statement = db.prepare("INSERT INTO books (title, year, rating) VALUES (?, ?, ?)")
insert.bind_str(0, "Dune")
insert.bind_int(1, 1965)
insert.bind_float(2, 4.5)
insert.execute()

tricky: Statement = db.prepare("INSERT INTO books (title, year, rating) VALUES (?, ?, ?)")
tricky.bind_str(0, "Robert'); DROP TABLE books;--")
tricky.bind_int(1, 2007)
tricky.bind_null(2)
tricky.execute()

count: int = db.query("SELECT COUNT(*) FROM books")[0].get_int(0)
print("books still there:", count)
db.close()
```

```output
books still there: 2
```

Placeholders are numbered from **zero** (`bind_str(0, …)` fills the first `?`), and there is a `bind_*` for each type plus `bind_null`.

## Reading rows

`query` returns a list of `Row`. Read each column by position with the typed getter that matches it, and ask `is_null` before reading a column that may be `NULL`:

```nox
import nox.sqlite
from nox.sqlite import Connection
from nox.db import Row, Statement

db: Connection = nox.sqlite.open(":memory:")
db.execute("CREATE TABLE books (id INTEGER PRIMARY KEY, title TEXT, year INTEGER, rating REAL)")
db.execute("INSERT INTO books (title, year, rating) VALUES ('Dune', 1965, 4.5)")
db.execute("INSERT INTO books (title, year, rating) VALUES ('Neuromancer', 1984, NULL)")
db.execute("INSERT INTO books (title, year, rating) VALUES ('Snow Crash', 1992, 4.0)")

rows: list[Row] = db.query("SELECT id, title, year, rating FROM books ORDER BY year")
for r in rows:
    rating: str = "unrated"
    if not r.is_null(3):
        rating = str(r.get_float(3))
    print(r.get_int(0), r.get_str(1), r.get_int(2), rating)

newer: Statement = db.prepare("SELECT title FROM books WHERE year > ? ORDER BY title")
newer.bind_int(0, 1980)
for r in newer.query():
    print("after 1980:", r.get_str(0))
db.close()
```

```output
1 Dune 1965 4.5
2 Neuromancer 1984 unrated
3 Snow Crash 1992 4.0
after 1980: Neuromancer
after 1980: Snow Crash
```

## Errors

A syntax error, a constraint violation, a locked database or a missing file raises `SqliteError` with SQLite's own message. Catch it where you can react:

```nox
import nox.sqlite
from nox.sqlite import Connection, SqliteError

db: Connection = nox.sqlite.open(":memory:")
db.execute("CREATE TABLE users (name TEXT PRIMARY KEY)")
db.execute("INSERT INTO users VALUES ('ada')")
try:
    db.execute("INSERT INTO users VALUES ('ada')")
except SqliteError as e:
    print("duplicate user rejected")
db.close()
```

```output
duplicate user rejected
```

## Transactions

Group related writes so they happen together or not at all with plain SQL:

```nox
import nox.sqlite
from nox.sqlite import Connection, SqliteError

def transfer(db: Connection, source: int, target: int, amount: int) -> bool:
    db.execute("BEGIN")
    try:
        db.execute("UPDATE accounts SET balance = balance - " + str(amount) + " WHERE id = " + str(source))
        db.execute("UPDATE accounts SET balance = balance + " + str(amount) + " WHERE id = " + str(target))
        db.execute("COMMIT")
        return True
    except SqliteError as e:
        db.execute("ROLLBACK")
        return False

db: Connection = nox.sqlite.open(":memory:")
db.execute("CREATE TABLE accounts (id INTEGER PRIMARY KEY, balance INTEGER CHECK (balance >= 0))")
db.execute("INSERT INTO accounts VALUES (1, 100)")
db.execute("INSERT INTO accounts VALUES (2, 0)")
print(transfer(db, 1, 2, 30))
print(transfer(db, 1, 2, 500))
for r in db.query("SELECT id, balance FROM accounts ORDER BY id"):
    print(r.get_int(0), r.get_int(1))
db.close()
```

```output
True
False
1 70
2 30
```

The second transfer would overdraw account 1, the `CHECK` constraint fails, and `ROLLBACK` undoes the first `UPDATE` too. (The amounts here are integers formatted
into the SQL, which is safe; for anything that came from outside, bind it instead.)

## PostgreSQL and MySQL

The other drivers have the same `execute`, `query` and `prepare`. Only the way you connect differs:

```text
import nox.postgres
conn: Connection = nox.postgres.open("host=127.0.0.1 port=5432 user=app password=secret dbname=app")

import nox.mysql
conn: Connection = nox.mysql.open_url("mysql://app:secret@127.0.0.1:3306/app")
```

On a native build the drivers load `libpq` / `libmysqlclient` the first time you connect, so a program that never opens a database needs neither. When you
compile to WebAssembly the same modules work through a host-provided network capability instead — see the [WebAssembly guide](../tools/wasm.md#postgresql).
For object mapping on top of these drivers there is [`nox.orm`](../stdlib/orm.md).

Next: [15. Command-line tools](15-command-line-tools.md).
