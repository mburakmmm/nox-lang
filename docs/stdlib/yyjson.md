# nox.yyjson

JSON reading and writing on top of [yyjson](https://github.com/ibireme/yyjson) (MIT), the fastest C JSON library. It lives **next to** `nox.json`, which is unchanged: the function names are the same (`parse`, `is_*`, `as_*`, `get`, `array_*`, `object_*`, `dump`, `dump_pretty`), but values are `YyValue` handles into the parsed document instead of `JsonValue` trees.

```text
import nox.yyjson
from nox.yyjson import YyValue, YyjsonError
```

**Capability:** none. The C library is shipped as a separate archive linked only into programs that import this module; it behaves identically on **macOS, Linux and Windows**. It is not available on WebAssembly, mobile and bare-metal targets (use `nox.json` there).

## Why a separate module

The document stays in yyjson's own memory layout: nothing is copied into Nox objects up front, a `YyValue` is created only for the nodes you touch, and the typed shortcuts `get_int`, `get_float`, `get_bool`, `get_str` read a field without creating a node at all. Parsing a 2.9 MB array of 20 000 records and reading three fields of each takes about 1.5 ms (C with yyjson directly: 0.9 ms; `nox.json`: 5.3 ms); parse and write take about 1.3 ms (C: 1.2 ms; `nox.json`: 5.5 ms; CPython: 16 ms). See `benchmarks/yyjson/run.py`.

A document is immutable, may be read from several threads, and lives as long as any `YyValue` taken from it (plain ARC; there is nothing to close).

## Functions

- `parse(s)`, `parse_relaxed(s)` (comments and trailing commas), `parse_json5(s)`. Invalid input raises `YyjsonError` with the yyjson message and the byte position.
- `is_null`, `is_bool`, `is_number`, `is_integer`, `is_string`, `is_array`, `is_object`; `as_bool`, `as_number`, `as_int` (exact int64, or an integral float such as `1e2`; anything else raises), `as_string`, `number_text`.
- `get(v, key)` (raises when missing), `get_or_none(v, key)`, `has_key(v, key)`; typed shortcuts `get_int`, `get_float`, `get_bool`, `get_str`; `read_int`, `read_float`, `read_bool`, `read_str`.
- `array_len`, `array_get(v, i)` (negative indexes count from the end, out of range raises `IndexError`); `object_len`, `object_key(v, i)`, `object_value(v, i)`. Sequential access is amortized O(1).
- `dump(v)` (compact) and `dump_pretty(v, indent)`.
- `is_supported()` returns `True` when the yyjson library is linked into the program (always, in a program that imports this module).
- Internals you will see in stack traces and signatures: `YyDoc` owns the parsed document (released when the last reference goes), `YyValue` is a value that keeps its `YyDoc` alive; `open_doc(s, mode)` is what `parse*` call; `expect_object`, `expect_array` and `field` are the shared type checks behind `get*`/`array_*`.

## Differences from nox.json

Duplicate object keys are accepted (`get` returns the first); there is no nesting depth limit; integers up to uint64 are read exactly (`as_int` raises outside int64); numbers are written in yyjson's shortest round-trip form. A document read with `parse_json5` that contains `Infinity` or `NaN` cannot be dumped.

```nox
import nox.yyjson
from nox.yyjson import YyValue

v: YyValue = nox.yyjson.parse("{\"id\": 7, \"tags\": [\"a\", \"b\"]}")
print(nox.yyjson.get_int(v, "id"))
print(nox.yyjson.dump(nox.yyjson.get(v, "tags")))
```

```output
7
["a","b"]
```
