# Modules and packages

## Programs and modules

A **module** is a `.nox` file. A **program** is an entry file plus every module it imports, directly or transitively. All modules of a
program are compiled **together as one unit**: there is no separate compilation, no linking of precompiled Nox objects and therefore no
ABI to keep stable between your own modules.

A **project** is a directory with a `nox.json` manifest:

```json
{
  "name": "demo",
  "entry": "main.nox",
  "requires": []
}
```

`noxc init demo` creates one. `name` and `entry` are required; `requires` lists third-party packages (see [Packages](../tools/packages.md)).
Single-file programs need no manifest and can import only the standard library.

## The entry point

There is no `main` function. The **top-level statements of the entry file** run in order and form the program. A top-level function named
`main` is rejected because the compiler synthesises its own entry symbol with that name. The top-level statements of *imported* modules run too, once, **before** the statements of the module that imports them (modules are merged in dependency order, imports first); keep imported modules to declarations unless you want
that side effect. Module-level variable initialisers always run before any other top-level statement.

## `import`

```nox
import nox.strings                  # qualified use: nox.strings.upper(s)
from nox.math import sqrt, pi       # direct use:    sqrt(2.0)
from nox.strings import upper as up # alias
import nox.time as t                # module alias
```

```nox-fragment
import util                  # <project>/util.nox
import app.models            # <project>/app/models.nox
from app.models import User, greet
x: util.Box = util.Box(2)    # qualified type names work in annotations
```

Forms:

| Statement | Effect |
|---|---|
| `import a.b` | makes the module's functions and classes available as `a.b.name(...)` and `a.b.Class` |
| `import a.b as m` | the same, under the alias `m` |
| `from a.b import x, y` | makes `x` and `y` available unqualified |
| `from a.b import x as z` | the same, renamed to `z` |

There is no `from … import *`. Imports are static: they must be at the top level of a module, are resolved before anything runs, and an
unresolved module is a compile error. Importing the same module twice is harmless. **Cyclic imports are rejected.**

### How names are resolved

A dotted module path is looked up in this order:

1. **The standard library** — the `nox.*` modules ([Standard library](../stdlib/index.md)).
2. **The current project** — `a/b.nox` under the project root (the directory containing `nox.json`); `import helpers` is
   `<root>/helpers.nox` and `import utils.mathy` is `<root>/utils/mathy.nox`.
3. **A dependency** — the `alias` of an entry in `requires` is a package name: `import nyx.app` loads module `app` of the package aliased
   `nyx`.

### Qualified access has two quirks

- A module's **functions and classes** can be used qualified (`util.double(4)`, `util.Box`), but its **module-level variables** are
  read with `from util import LIMIT` — `util.LIMIT` is not valid.
- `extern def` functions (raw native bindings, such as `sqrt` in `nox.math`) are never name-mangled, so they are used unqualified after the
  import — see the notes on each standard-library page.

## Module-level state

Variables declared at the top level of a module are **module-level variables**. Functions of the same module read and assign them without
any `global` keyword ([Statements](statements.md#scoping)). Initialisers run before any other top-level statement, in source order.

```nox
counter: int = 0

def bump() -> int:
    counter += 1
    return counter

print(bump(), bump())
```

```output
1 2
```

Under the multi-core runtime each worker keeps its own copy of module state; share data between tasks with channels, `nox.atomic` or
`nox.sharedmem` ([Concurrency](concurrency.md#the-scheduler)).

## Packages

A package is an ordinary project whose repository can be listed in another project's `requires`. Dependencies are fetched into a cache,
pinned to an exact commit in `nox.lock`, and compiled into your program with everything else. The registry, the lock file, `noxc add`,
`noxc publish` and the trust implications are in [Packages](../tools/packages.md) and [The noxpkg registry](../tools/noxpkg.md).
A package that declares `extern def` bindings runs native code with full authority — see [Security](../reference/security.md).

## Visibility

All top-level names of a module are importable; Nox has no `public`/`private` keywords. By convention a leading underscore marks a name as
internal, and names beginning with `__nox_` belong to the compiler's prelude. A leading-underscore name is not hidden from importers.
