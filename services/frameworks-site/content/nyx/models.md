# Models

Nyx models are typed attribute bags written to SQL. The default engine is SQLite. Postgres and MySQL are selected by `DATABASE_URL` and use their own modules, because the dialects are not the same language.

## Creating a row

```nox
attrs: Attributes = nyx.model.attributes()
nyx.model.set_str(attrs, "title", title)
nyx.model.set_int(attrs, "user_id", user_id)
nyx.model.set_null(attrs, "bio")
id: int = nyx.model.create_attrs(db, "posts", attrs)
```

`set_str`, `set_int` and `set_null` are the preferred writers. JSON-string `create` and `update` remain so older apps keep compiling. New code should not build a JSON object just to insert a row.

## Reading a row

```nox
row: Record | None = nyx.model.find(db, "posts", id)
if row == None:
    return nyx.ctrl.text(404, "not found")
bio: str | None = row.get_opt("bio")
title: str = row.get_or("title", "")
```

Narrow first. `get_opt` and `get_or` take a `Record`, not `Record | None`. `get_opt` turns SQL `NULL` into `None`. `get_or` returns the default when the column is missing or null.

## Associations

`nyx.assoc` describes belongs-to and has-many style links between tables and loads the related rows. It does not invent a query language beyond the SQL the model already runs. Declare the foreign key as a real column (`user_id` above) and load the parent with `find` when you need it.

## Migrations

Schema changes go through the CLI, not through a request:

```sh
./bin/nyx db migrate
./bin/nyx db rollback
./bin/nyx db schema
./bin/nyx db seed
```

`NYX_AUTO_MIGRATE=1` applies pending migrations at boot. Leave it off in production so a deploy does not change the schema as a side effect of starting the server.

## Which engine

| URL | Modules |
|---|---|
| `sqlite:///...` or `NYX_DB_PATH` | `nyx.model`, `nyx.session_store`, `nyx.auth_engine` |
| `postgres://...` | `nyx.pg_model`, `nyx.session_store_pg`, `nyx.auth_engine_pg` |
| `mysql://...` | `nyx.mysql_model`, `nyx.session_store_mysql`, `nyx.auth_engine_mysql` |

`nox.db.DbConnection` can close, execute, query and prepare against any of the three. The model layer stays split. Placeholders are `?` on SQLite and `$n` on Postgres. `RETURNING` and identifier quotes differ. `last_insert_rowid` exists for SQLite and is not on the shared protocol, which is why `create_attrs` returns the id itself.

SQL `bind_*` indexes are zero-based. An index past the statement raises the driver error.

Generated models come from `nyx generate model Post title:string body:text`, which writes the migration and the model file the commands above expect.
