# Install

Nyx is installed the same way as any other Nox package: a `requires` entry, then `noxc fetch`.

## From the registry pin

```json
{
  "name": "myapp",
  "entry": "main.nox",
  "requires": [
    {
      "alias": "nyx",
      "repo": "github.com/mburakmmm/nyx",
      "ref": "@@TAG@@"
    }
  ]
}
```

```sh
noxc fetch
noxc run main.nox
```

The alias should stay `nyx`. Imports in the framework and in these docs are `import nyx.app`. Nox allows a consumer to pick another alias; the package’s own files still say `nyx`.

You can also install the CLI onto `PATH`:

```sh
noxc install github.com/mburakmmm/nyx@@@TAG@@
```

## A local checkout

While changing Nyx itself, point `repo` at a directory and `ref` at the branch you are on:

```json
{ "alias": "nyx", "repo": "/absolute/path/to/nyx", "ref": "master" }
```

## What you need first

- Nox **2.0.7** or newer. Nyx @@VERSION@@’s CI installs that package.
- A writable path for the SQLite file if you use the default ORM. Set `NYX_DB_PATH` or `DATABASE_URL`.
- In production, `NYX_SECRET_KEY` of at least 32 characters. Boot refuses a short secret when `NYX_ENV=production`.

The language install itself is on [noxlang.com/docs/install](https://noxlang.com/docs/install/). Nyx does not ship a compiler.
