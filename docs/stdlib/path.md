# nox.path

Lexical operations on file-system path strings. Nothing here touches the disk except `canonicalize`.

```text
import nox.path
from nox.path import PathError
```

**Capability:** none.

## Functions

| Function | Description |
|---|---|
| `join(a, b)` | joins two parts with exactly one `/` between them (`join("a/", "b")` is `a/b`; an empty `a` gives `b`; an absolute `b` is appended, not treated specially) |
| `basename(p)` | the last component (`"/x/y/z.txt"` → `"z.txt"`) |
| `dirname(p)` | everything before the last component (`"/x/y/z.txt"` → `"/x/y"`) |
| `extension(p)` | the part after the last dot of the last component (`"z.tar.gz"` → `".gz"`), or `""` |
| `is_absolute(p)` | whether `p` starts at the root |
| `components(p)` | the non-empty components as a list (`"/x/y/z"` → `['x','y','z']`) |
| `strip_prefix(p, prefix)` | `p` without the leading `prefix` and the separator after it; if `p` does not start with `prefix` it is returned unchanged |
| `canonicalize(p)` | the absolute path with `.`, `..` and symbolic links resolved; **the path must exist** (`PathError` otherwise) |

```nox
import nox.path

print(nox.path.join("a", "b"), nox.path.basename("/x/y/z.txt"), nox.path.dirname("/x/y/z.txt"), nox.path.extension("z.tar.gz"), nox.path.is_absolute("/x"))
print(nox.path.strip_prefix("/x/y/z", "/x"), nox.path.components("/x/y/z"))
print(nox.path.canonicalize(".") != "")
try:
    nox.path.canonicalize("/definitely/not/here")
except Exception as e:
    print("no such path")
```

```output
a/b z.txt /x/y .gz True
y/z ['x', 'y', 'z']
True
no such path
```

## Confining untrusted paths

`canonicalize` is the building block for safely serving files: resolve the requested path and require the result to start with your root.

```nox
import nox.path
import nox.strings

def inside(root: str, requested: str) -> bool:
    full: str = nox.path.canonicalize(nox.path.join(root, requested))
    return nox.strings.starts_with(full, root)
```

Remember that the check must run on the *canonicalised* path, after `..` and symlinks are resolved.
