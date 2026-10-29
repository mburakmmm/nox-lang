# nox.toml

Parse and write TOML 1.0 documents. The parser is written in Nox; invalid input is rejected with a clear `TomlError` (including duplicate keys
and tables defined twice) rather than silently misread.

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
| `is_string(v)`, `is_int(v)`, `is_float(v)`, `is_bool(v)`, `is_array(v)`, `is_table(v)`, `is_datetime(v)` | kind tests |

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
| date / time | `s` | `str` (the raw text, e.g. `1979-05-27T07:32:00-08:00`, `1979-05-27`, `07:32:00`) |

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

Comments; `[table]` and `[[array of tables]]` headers (dotted, with quoted segments); bare, `"basic"` and `'literal'` keys and dotted keys on
a `key = value` line (`a.b.c = 1`); basic, literal and multi-line (`"""`, `'''`) strings with all escapes (`\b \t \n \f \r \" \\ \uXXXX \UXXXXXXXX`, line-ending
backslash); decimal, `0x`, `0o` and `0b` integers (with `_`); floats (exponents, `inf`, `nan`); booleans; arrays (mixed types, several lines);
inline tables (`{k = v}`); and date/time values (offset date-time, local date-time, local date, local time), which are kept as their raw text
(`is_datetime`). In an array of tables, `get` follows the **last** element. `dump` writes arrays of tables back as `[[name]]` blocks.

```nox
import nox.toml
from nox.toml import TomlValue

t: TomlValue = nox.toml.parse("owner.name = \"Tom\"\nport = 0x1F90\nwhen = 1979-05-27\ninline = { x = 1, y = { z = \"deep\" } }\n[[servers]]\nname = \"a\"\n[[servers]]\nname = \"b\"\n")
print(nox.toml.get(t, "owner.name").s, nox.toml.get(t, "port").i, nox.toml.get(t, "when").s, nox.toml.get(t, "inline.y.z").s)
servers: TomlValue = nox.toml.get(t, "servers")
print(len(servers.arr), servers.arr[1].tbl["name"].s)
```

```output
Tom 8080 1979-05-27 deep
2 b
```
