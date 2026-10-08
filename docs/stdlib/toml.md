# nox.toml

Parse and write TOML configuration files. The parser is written in Nox and covers the everyday subset of TOML; unsupported constructs are rejected with a
clear `TomlError` rather than silently misread.

```text
import nox.toml
from nox.toml import TomlValue, TomlError
```

**Capability:** none. The module works on text; read files with [`nox.fs`](fs.md).

## Functions

| Function | Description |
|---|---|
| `parse(text)` | parses a document into a `TomlValue` (a table); raises `TomlError` on a syntax error |
| `get(root, dotted_path)` | follows a dotted path through nested tables (`"server.tls.enabled"`); raises `TomlError` if a segment is missing or not a table |
| `dump(v)` | writes a table back to TOML text |
| `is_string(v)`, `is_int(v)`, `is_float(v)`, `is_bool(v)`, `is_array(v)`, `is_table(v)` | kind tests |

## `TomlValue`

A node has public fields; read the one that matches its kind:

| Kind | Field | Type |
|---|---|---|
| string | `s` | `str` |
| integer | `i` | `int` |
| float | `f` | `float` |
| boolean | `b` | `bool` |
| array | `arr` | `list[TomlValue]` |
| table | `tbl` | `dict[str, TomlValue]` |

```nox
import nox.toml
from nox.toml import TomlValue, TomlError

t: TomlValue = nox.toml.parse("title = \"demo\"\n[server]\nport = 8080\nhosts = [\"a\", \"b\"]\n[server.tls]\nenabled = true\nratio = 0.5\n")
print(nox.toml.is_table(t), nox.toml.get(t, "title").s, nox.toml.get(t, "server.port").i, nox.toml.get(t, "server.tls.enabled").b, nox.toml.get(t, "server.tls.ratio").f)
hosts: TomlValue = nox.toml.get(t, "server.hosts")
print(nox.toml.is_array(hosts), len(hosts.arr), hosts.arr[1].s)
print(nox.toml.dump(t))
try:
    nox.toml.get(t, "x.y")
except TomlError as e:
    print("missing key")
```

```output
True demo 8080 True 0.5
True 2 b
title = "demo"
[server]
port = 8080
hosts = ["a", "b"]
[server.tls]
enabled = true
ratio = 0.5

missing key
```

## Supported TOML

Supported: comments, `[table]` and nested `[a.b.c]` headers, bare and quoted keys, basic strings with escapes, integers (with `_` separators), floats
(including exponents), booleans and arrays (which may span several lines).

**Not supported** (rejected with `TomlError` or out of scope): arrays of tables (`[[name]]`), inline tables (`{k = v}`), multi-line and literal strings, dates and
times, hexadecimal/octal/binary integers, and dotted keys on a `key = value` line.
