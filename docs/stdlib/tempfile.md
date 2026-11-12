# nox.tempfile

Temporary files and directories.

```text
import nox.tempfile
from nox.tempfile import TemporaryDirectory, TempFileError, mkdtemp, mkstemp, gettempdir
```

**Capability:** `filesystem` (it also reads environment variables and draws random names, which are allowed wherever the file system is).

| Function / class | Description |
|---|---|
| `gettempdir()` | the directory for temporary files: `TMPDIR`, `TEMP`, `TMP` in that order, else `/tmp` |
| `mkdtemp(prefix="tmp", suffix="", dir="")` | creates a new empty directory and returns its path |
| `mkstemp(prefix="tmp", suffix="", dir="")` | creates a new empty file and returns its path |
| `TemporaryDirectory(prefix, suffix, dir)` | a directory removed with its contents on leaving a `with` block; `.path` is its path, `.cleanup()` removes it early |

Names are `prefix` + 12 random hex digits + `suffix`, drawn from the operating system's secure random source. Directory creation is atomic (an existing name is retried); file creation is `exists` followed by a write. `TempFileError` is raised if no unique name is found after 100 tries. File permissions are the operating system defaults (not forced to `0600`). `mkstemp` returns only the path: remove the file yourself with `nox.fs.remove_file`.

```nox
import nox.fs
import nox.tempfile
from nox.tempfile import TemporaryDirectory

kept: str = ""
with TemporaryDirectory("demo-") as t:
    nox.fs.write_string(t.path + "/data.txt", "hello")
    print(nox.fs.read_to_string(t.path + "/data.txt"))
    kept = t.path
print(nox.fs.exists(kept))
```

```output
hello
False
```
