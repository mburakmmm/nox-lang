# Command line

The `nyx` executable is `bin/nyx` in a checkout, or the program `noxc install` puts on your path.

| Command | What it does |
|---|---|
| `nyx new blog` | writes a new app: `nox.json`, entry file, views |
| `nyx generate model Post title:string body:text` | model plus migration |
| `nyx generate scaffold Comment body:text` | model, routes and views for a resource |
| `nyx db migrate` | apply pending migrations |
| `nyx db rollback` | undo the last migration |
| `nyx db schema` | print the schema |
| `nyx db seed` | run seeds |
| `nyx jobs work` | run the job worker |
| `nyx server` | boot and serve |
| `nyx console` | a REPL against the booted app |
| `nyx version` | print the Nyx version |

Generate into an app `nyx new` created, so the paths (`app/views`, the migration directory) match what `nyx.ctrl.render` and `nyx db` already look for.

`nyx server` is the development entry. Production should still be a built binary: `noxc build` the entry file and run that, with `NYX_ENV=production` and a real `NYX_SECRET_KEY`. The framework does not hide the compiler.

Column types in `generate model` are the names the migration template knows: `string`, `text`, `integer`, and the other types that template lists. An unknown type is a generator error, not a column of type “whatever you typed”.
