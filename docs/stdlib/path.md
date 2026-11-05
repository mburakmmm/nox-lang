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
| `strip_prefix(p, prefix)` | `p` without the leading `prefix` and the separator after it; if `prefix` is not a prefix of `p` **at a component boundary** (`/srv/dataevil` does not start with `/srv/data`) it is returned unchanged |
| `canonicalize(p)` | the absolute path with `.`, `..` and symbolic links resolved; **the path must exist** (`PathError` otherwise) |
| `safe_join(root, requested)` | `requested` resolved under `root`, or `PathError` if the result would leave `root` (see [Confining untrusted paths](#confining-untrusted-paths)) |

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

`safe_join` is the standard way to turn a path that came from outside (a request, a form, a configuration file) into one that is guaranteed to stay under a root directory:

```nox
import nox.path
from nox.path import PathError

def open_upload(name: str) -> str:
    try:
        return nox.path.safe_join("/srv/uploads", name)
    except PathError:
        return ""
```

It canonicalises `root` (which must exist), joins `requested`, resolves `..` and symbolic links, and compares **path components**, not string prefixes: `/srv/dataevil` is not inside `/srv/data`. An absolute `requested` is treated as relative to `root` (`/etc/passwd` becomes `<root>/etc/passwd`). A target that does not exist yet (a file you are about to write) is allowed: its parent directory is resolved and checked instead. Anything that would end up outside `root` raises `PathError`.

Do not confine a path with `starts_with(canonicalize(...), root)`: that accepts siblings such as `/srv/dataevil` and misjudges a root that is itself a symbolic link. `safe_join` does neither.
