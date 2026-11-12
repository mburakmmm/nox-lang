# nox.glob

Expand file name patterns against the file system.

```text
import nox.glob
from nox.glob import glob
```

**Capability:** `filesystem`. Directories are read with [`nox.fs`](fs.md).

`glob(pattern, root_dir="", recursive=False)` returns the matching paths as a **sorted** `list[str]` (Python's order is unspecified). Patterns use the [`nox.fnmatch`](fnmatch.md) syntax per path component; components are separated by `/`.

- `*`, `?` and `[...]` do not match names that start with `.` unless the pattern component itself starts with `.`.
- With `recursive=True`, a `**` component matches zero or more directories (hidden directories are not entered). A trailing `**` also matches every file and directory below, and `dir/**` includes `dir/` itself.
- A trailing `/` keeps directories only and keeps the slash in the result.
- With `root_dir`, relative patterns are resolved there and the results stay relative to it.
- The behaviour matches Python's `glob.glob(pattern, root_dir=..., recursive=...)` on the covered feature set (a randomised golden test compares them on a fixed tree).

> **Security.** Like `nox.fs`, `glob` does no sandboxing. If the pattern or `root_dir` comes from an untrusted source, confine it first with [`nox.path.safe_join`](path.md#confining-untrusted-paths).

```nox
import nox.fs
import nox.tempfile
from nox.tempfile import TemporaryDirectory
from nox.glob import glob

with TemporaryDirectory("glob-demo-") as t:
    nox.fs.create_dir_all(t.path + "/src/util")
    nox.fs.write_string(t.path + "/src/main.nox", "")
    nox.fs.write_string(t.path + "/src/util/io.nox", "")
    nox.fs.write_string(t.path + "/notes.txt", "")
    print(glob("*", t.path))
    print(glob("src/*.nox", t.path))
    print(glob("**/*.nox", t.path, True))
```

```output
['notes.txt', 'src']
['src/main.nox']
['src/main.nox', 'src/util/io.nox']
```
