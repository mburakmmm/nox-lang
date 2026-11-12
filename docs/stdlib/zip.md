# nox.zip

Read and write ZIP archives.

```text
import nox.zip
from nox.zip import ZipEntry, ZipError, file_entry, dir_entry, pack, unpack
```

**Capability:** none. Archive contents are `str` values holding raw bytes (binary safe). Compression is deflate, the same engine as [`nox.gzip`](gzip.md).

| Function / type | Description |
|---|---|
| `file_entry(name, data)` | a file entry |
| `dir_entry(name)` | a directory entry (a trailing `/` is added if missing) |
| `pack(entries, compress=True)` | the archive bytes as a `str`; each entry is deflated when that makes it smaller, otherwise stored. `ZipError` for an empty name or more than 65535 entries |
| `unpack(data)` | a `list[ZipEntry]` read through the central directory; CRC-32 and sizes are verified. `ZipError` for corrupt, encrypted, ZIP64 or unsupported-method archives |
| `ZipEntry` | `name`, `data` and `is_dir()` (a name ending in `/`) |

`pack` writes the 1980-01-01 timestamp and Unix permissions (`0644` files, `0755` directories); names that are not ASCII are flagged as UTF-8. Archives written by `pack` are read by Python's `zipfile` and standard `unzip`; archives created by Python's `zipfile` (stored or deflated) are read by `unpack`. Not supported: ZIP64 (archives or entries of 4 GiB and more), encryption and methods other than stored and deflate. Each unpacked entry is limited to 1 GiB.

> **Security.** `unpack` works in memory only. When you write the entries to disk, confine each name with [`nox.path.safe_join`](path.md#confining-untrusted-paths): archive names may contain `..` or absolute paths ("zip slip").

```nox
import nox.strings
import nox.zip
from nox.zip import ZipEntry, file_entry, dir_entry, pack, unpack

entries: list[ZipEntry] = [dir_entry("docs"), file_entry("docs/hello.txt", "hello zip " * 100)]
blob: str = pack(entries)
for e in unpack(blob):
    print(e.name, e.is_dir(), nox.strings.byte_len(e.data))
```

```output
docs/ True 0
docs/hello.txt False 1000
```
