# 8. Modules and packages

## Splitting a program into files

Every `.nox` file is a module. A project is a directory with a `nox.json`:

```text
geometry/
├── nox.json
├── main.nox
├── mathutil.nox
├── mathutil_test.nox
└── shapes/
    └── rect.nox
```

```json
{
  "name": "geometry",
  "version": "0.1.0",
  "entry": "main.nox"
}
```

`shapes/rect.nox` defines a class, `mathutil.nox` a constant and a function:

```nox-fragment
# shapes/rect.nox
class Rect:
    w: int
    h: int

    def __init__(self, w: int, h: int) -> None:
        self.w = w
        self.h = h

    def area(self) -> int:
        return self.w * self.h
```

```nox-fragment
# mathutil.nox
SCALE: int = 10

def scaled(n: int) -> int:
    return n * SCALE
```

`main.nox` imports them:

```nox-fragment
# main.nox
import mathutil
from shapes.rect import Rect
from mathutil import SCALE

r: Rect = Rect(3, 4)
print(r.area(), mathutil.scaled(5), SCALE)
```

```sh
noxc run main.nox
```

```text
12 50 10
```

- `import mathutil` loads `mathutil.nox` from the project root; call its functions as `mathutil.scaled(5)`.
- `from shapes.rect import Rect` loads `shapes/rect.nox` and brings `Rect` into scope directly.
- A module's constants are read with `from mathutil import SCALE`.
- All the files compile together into one program, and the statements at the top level of `main.nox` are what runs.

## Using the standard library

Standard-library modules live under `nox.`: `import nox.strings`, `from nox.math import sqrt`, `import nox.json`. The full list is the
[standard library reference](../stdlib/index.md).

```nox
import nox.time
from nox.math import sqrt, pi

print(sqrt(16.0), pi() > 3.14, nox.time.now_ms() > 0)
```

```output
4.0 True True
```

## Tests

`noxc test` finds every `*_test.nox` file under the current directory and runs it. A test file is an ordinary program that fails
(raises) when an expectation is wrong:

```nox-fragment
# mathutil_test.nox
import nox.test
import mathutil

nox.test.assert_eq_int(mathutil.scaled(2), 20, "scaled(2)")
nox.test.assert_true(mathutil.scaled(0) == 0, "scaled(0)")
print("mathutil ok")
```

```sh
noxc test
```

## Third-party packages

Packages are ordinary Nox projects in a Git repository. Add one with `noxc add`, which records it in `nox.json`:

```sh
noxc search http          # search the central index
noxc add nyx              # add a package by name (the index knows its repository)
noxc fetch                # download dependencies; pins exact commits in nox.lock
```

```json
{
  "name": "geometry",
  "entry": "main.nox",
  "requires": [
    { "alias": "nyx", "repo": "github.com/mburakmmm/nyx", "ref": "v0.21.0" }
  ]
}
```

```nox-fragment
import nyx.app          # module "app" of the package aliased "nyx"
```

`nox.lock` pins every dependency to an exact commit, so builds are reproducible; commit it to your repository. See
[Packages](../tools/packages.md) for the full workflow, including `noxc update`, global installs and publishing your own package.
A package that contains `extern def` declarations runs native code — read [Security](../reference/security.md) before adding
dependencies you do not trust.
