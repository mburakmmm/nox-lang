# nox.fs

Files and directories: read, write, append, copy, rename, delete, list, and inspect.

```text
import nox.fs
from nox.fs import FsError, FileMetadata, FileReader, FileWriter
```

**Capability:** `filesystem` (unavailable in freestanding profiles).

> **Security.** `nox.fs` passes paths straight to the operating system. It does **no** validation, canonicalisation or sandboxing: `..` segments, symbolic links
> and absolute paths all work. If a path comes from an untrusted source (user input, a network request), you must confine it yourself — for example by
> canonicalising it with [`nox.path.canonicalize`](path.md) and checking that it stays inside an allowed root. See [Security](../reference/security.md).

## Reading and writing

| Function | Description |
|---|---|
| `read_to_string(path)` | the whole file as a `str`; raises `FsError` if it cannot be read |
| `write_string(path, content)` | creates or **truncates** the file and writes `content` |
| `write_string_atomic(path, content)` | writes to `path + ".nox-tmp"` and renames it over `path`: a failed write leaves the old contents intact and removes the temporary file |
| `append_string(path, content)` | appends `content`, creating the file if needed |

Files are read and written as text bytes; `content` is written exactly as given (no newline translation).

## Querying

| Function | Description |
|---|---|
| `exists(path)` | whether anything exists at `path` (never raises) |
| `is_file(path)`, `is_dir(path)` | type tests (never raise; `False` when absent) |
| `metadata(path)` | a `FileMetadata`; raises `FsError` if absent |
| `read_dir(path)` | the entry **names** of a directory (not full paths, unspecified order); raises `FsError` |

`FileMetadata` has two fields: `size` (bytes) and `modified_ms` (modification time, milliseconds since the Unix epoch).

## Changing the file system

| Function | Description |
|---|---|
| `copy(src, dst)` | copies a file; raises `FsError` on failure |
| `rename(old, new)` | renames or moves; raises `FsError` on failure |
| `remove_file(path)` | deletes a file; raises `FsError` on failure |
| `create_dir(path)` | creates one directory (the parent must exist); raises `FsError` on failure |

## Streaming large files

`read_to_string` and `write_string` hold the whole file in memory. For large files open a handle and move the content in chunks; memory use is bounded by the chunk size.

| Function / method | Description |
|---|---|
| `open_read(path)` | a `FileReader`; raises `FsError` if the file cannot be opened |
| `open_write(path)` | a `FileWriter` that creates or **truncates** the file |
| `open_append(path)` | a `FileWriter` that appends (creating the file if needed) |
| `reader.read_chunk(n)` | up to `n` bytes as a `str`: exactly `n` unless the end of the file is reached, then the remaining bytes, then `""` |
| `reader.seek(offset)` | moves to `offset` bytes from the start (for resuming a transfer) |
| `reader.size()` | the current size of the file in bytes |
| `writer.write(content)` | writes every byte of `content` (unbuffered: each call goes straight to the operating system) |
| `close()` | closes the file; calling it twice is harmless |

A chunk is a `str` that carries **raw bytes** (including `\x00` and bytes that are not valid UTF-8, see [`nox.bytes`](bytes.md)), so a chunk can end in the middle of a multi-byte UTF-8
character, and `len(chunk)` counts code points: use `nox.strings.byte_len(chunk)` for the number of bytes. The end of the file is the empty chunk.

A handle owns an operating-system file descriptor and is **not** closed automatically: use `with` (which closes it even when the body raises) or call `close()`. Using a closed
handle raises `FsError`. The security note above applies to `open_*` paths too.

```nox
import nox.fs
import nox.strings
import nox.path
import nox.os
from nox.fs import FsError, FileReader, FileWriter

p: str = nox.path.join(nox.os.current_dir(), "streamdemo.bin")
with nox.fs.open_write(p) as w:
    for i in range(1000):
        w.write("row " + str(i) + "\n")

total: int = 0
chunks: int = 0
r: FileReader = nox.fs.open_read(p)
while True:
    c: str = r.read_chunk(4096)
    n: int = nox.strings.byte_len(c)
    if n == 0:
        break
    total = total + n
    chunks = chunks + 1
print(total, chunks, r.size())
r.seek(4)
print(r.read_chunk(5) == "0\nrow")
r.close()
try:
    r.read_chunk(1)
except FsError:
    print("closed")
nox.fs.remove_file(p)
```

```output
7890 2 7890
True
closed
```

## Errors

`FsError` (a subclass of `Exception`) is raised by every operation that can fail. `exists`, `is_file` and `is_dir` never raise.

```nox
import nox.fs
import nox.path
import nox.os
from nox.fs import FsError, FileMetadata

d: str = nox.path.join(nox.os.current_dir(), "fsdemo")
nox.fs.create_dir(d)
f: str = nox.path.join(d, "a.txt")
nox.fs.write_string(f, "hello")
nox.fs.append_string(f, " world")
print(nox.fs.read_to_string(f), nox.fs.exists(f), nox.fs.is_file(f), nox.fs.is_dir(d), nox.fs.exists(d + "/nope"))

m: FileMetadata = nox.fs.metadata(f)
print(m.size, m.modified_ms > 0)

nox.fs.copy(f, nox.path.join(d, "b.txt"))
nox.fs.rename(nox.path.join(d, "b.txt"), nox.path.join(d, "c.txt"))
print(sorted(nox.fs.read_dir(d)))
nox.fs.remove_file(nox.path.join(d, "c.txt"))
print(sorted(nox.fs.read_dir(d)))

try:
    nox.fs.read_to_string(d + "/missing")
except FsError as e:
    print("FsError")
```

```output
hello world True True True False
11 True
['a.txt', 'c.txt']
['a.txt']
FsError
```

## Notes

- There is no recursive delete or recursive create; walk with `read_dir` and `is_dir`.
- `read_to_string` reads the whole file into memory; for large files use the streaming handles above.
- Operations are synchronous; under the multi-core scheduler they block only their worker.
- Catch the exception with `from nox.fs import FsError` — qualified names such as `nox.fs.FsError` are not accepted in an `except` clause.
