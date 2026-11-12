# nox.tar

Read and write tar archives (ustar).

```text
import nox.tar
from nox.tar import TarEntry, TarError, file_entry, dir_entry, pack, unpack
```

**Capability:** none. Archive contents are `str` values holding raw bytes (binary safe). For a `.tar.gz`, compress the result of `pack` with [`nox.gzip`](gzip.md).

| Function / type | Description |
|---|---|
| `file_entry(name, data)` | a file entry |
| `dir_entry(name)` | a directory entry (a trailing `/` is added if missing) |
| `pack(entries)` | the archive bytes as a `str`; `TarError` for an empty name or a name that cannot be split into a 155-byte prefix and a 100-byte name |
| `unpack(data)` | a `list[TarEntry]`; `TarError` for a corrupt (bad checksum) or truncated archive |
| `TarEntry` | `name`, `data` and `is_dir()` (a name ending in `/`) |

`pack` produces exactly what Python's `tarfile` writes in `USTAR_FORMAT` with zero timestamps and ids (mode `0644` for files, `0755` for directories), padded to 10240 bytes. `unpack` also understands GNU long names and PAX headers (`path`, `size`); entries other than regular files and directories (links, devices) are skipped.

> **Security.** `unpack` works in memory only. When you write the entries to disk, confine each name with [`nox.path.safe_join`](path.md#confining-untrusted-paths): archive names may contain `..` or absolute paths.

```nox
import nox.strings
import nox.tar
from nox.tar import TarEntry, file_entry, dir_entry, pack, unpack

entries: list[TarEntry] = [dir_entry("docs"), file_entry("docs/hello.txt", "hello tar")]
blob: str = pack(entries)
print(nox.strings.byte_len(blob))
for e in unpack(blob):
    print(e.name, e.is_dir(), e.data)
```

```output
10240
docs/ True 
docs/hello.txt False hello tar
```
