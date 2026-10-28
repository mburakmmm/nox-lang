# Install

Add Aether to the app’s `nox.json` and fetch it.

```json
{
  "name": "myapi",
  "entry": "main.nox",
  "requires": [
    {
      "alias": "aether",
      "repo": "github.com/mburakmmm/aether",
      "ref": "@@TAG@@"
    }
  ]
}
```

```sh
noxc fetch
AETHER_ENV=development AETHER_WORKERS=1 NOX_POOL_WORKERS=1 noxc run main.nox
```

## Scaffold

```sh
noxc install github.com/mburakmmm/aether@@@TAG@@
aether new myapi
cd myapi && noxc fetch && chmod +x run.sh && ./run.sh
```

`aether new` writes the entry file, a health module and `run.sh`. The script exports `NOX_POOL_WORKERS` from `AETHER_WORKERS` **before** starting the process. The pool size cannot be changed later.

## A local checkout

```json
{ "alias": "aether", "repo": "/absolute/path/to/aether", "ref": "master" }
```

## Requirements

- Nox **2.0.7** or newer. LLVM is the default backend. `AETHER_WORKERS` greater than 1 calls `serve_multicore` on both LLVM and QBE.
- On LLVM the process pool is fixed at startup. `NOX_POOL_WORKERS` must equal `AETHER_WORKERS`. A mismatch is an error.
- The language install is documented at [noxlang.com/docs/install](https://noxlang.com/docs/install/).

The dogfood app in the Aether repo is `examples/hello_api`: `GET`, `POST`, `PUT` and `DELETE` under `/api/users`.
