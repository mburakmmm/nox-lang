# nox.json

Parse and generate JSON. Parsing is done by a battle-tested native parser; the result is a tree of `JsonValue` nodes that you inspect with typed accessors. For
generating JSON there are two styles: dump an existing tree, or build text incrementally with `JsonWriter`.

```text
import nox.json
from nox.json import JsonError, JsonWriter
```

**Capability:** none.

`JsonValue` is part of the prelude (it needs no import); `JsonError` is raised on malformed input.

## Parsing

| Function | Description |
|---|---|
| `parse(s)` | parses `s` into a `JsonValue`; raises `JsonError` for invalid JSON (any depth of nesting is supported) |

## Inspecting a `JsonValue`

Every node is exactly one of null, boolean, number, string, array or object. Test the kind first, then read it:

| Function | Description |
|---|---|
| `is_null(v)`, `is_bool(v)`, `is_number(v)`, `is_string(v)`, `is_array(v)`, `is_object(v)` | kind tests |
| `as_bool(v)`, `as_number(v)`, `as_string(v)` | the value; `as_number` is a `float` (use `int(...)` for integers) |
| `array_len(v)`, `array_get(v, i)` | array length and element |
| `object_len(v)`, `object_key(v, i)`, `object_value(v, i)` | an object's `i`-th entry, **in document order** |

```nox
import nox.json
from nox.json import JsonError

v: JsonValue = nox.json.parse("{\"name\": \"ada\", \"age\": 36, \"tags\": [\"a\", \"b\"], \"ok\": true, \"none\": null, \"pi\": 3.5}")
print(nox.json.is_object(v), nox.json.object_len(v))
i: int = 0
while i < nox.json.object_len(v):
    k: str = nox.json.object_key(v, i)
    x: JsonValue = nox.json.object_value(v, i)
    if nox.json.is_string(x):
        print(k, "string", nox.json.as_string(x))
    elif nox.json.is_number(x):
        print(k, "number", nox.json.as_number(x))
    elif nox.json.is_bool(x):
        print(k, "bool", nox.json.as_bool(x))
    elif nox.json.is_array(x):
        print(k, "array", nox.json.array_len(x), nox.json.as_string(nox.json.array_get(x, 1)))
    elif nox.json.is_null(x):
        print(k, "null")
    i += 1
try:
    nox.json.parse("{bad")
except JsonError as e:
    print("JsonError")
```

```output
True 6
name string ada
age number 36.0
tags array 2 b
ok bool True
none null
pi number 3.5
JsonError
```

To look a key up by name, loop over `object_key` (objects are small and ordered; there is no hash index).

## Dumping a tree

| Function | Description |
|---|---|
| `dump(v)` | compact JSON text |
| `dump_pretty(v, indent)` | indented JSON, `indent` spaces per level |
| `dump_string(s)` | a JSON string literal for `s`, with all required escapes |
| `dump_number(n)` | a JSON number for a `float` (whole values print without `.0`) |
| `dump_array(v)`, `dump_object(v)` | compact dump of an array / object node |
| `dump_pretty_at(v, indent, level)`, `dump_pretty_array(...)`, `dump_pretty_object(...)` | the recursive pretty-printing helpers behind `dump_pretty` |
| `indent_str(indent, level)` | the indentation string for a level |

```nox
import nox.json

v: JsonValue = nox.json.parse("{\"name\": \"ada\", \"tags\": [\"a\", \"b\"], \"pi\": 3.5}")
print(nox.json.dump(v))
print(nox.json.dump_pretty(v, 2))
print(nox.json.dump_string("a\"b\n"), nox.json.dump_number(3.0), nox.json.dump_number(2.5))
```

```output
{"name":"ada","tags":["a","b"],"pi":3.5}
{
  "name": "ada",
  "tags": [
    "a",
    "b"
  ],
  "pi": 3.5
}
"a\"b\n" 3 2.5
```

## `JsonWriter` — building JSON without a tree

`JsonWriter` appends pieces and joins them once at the end, so building a large document is linear in its size. Open containers with `begin_object` / `begin_array`
and close them in order; inside an object call `write_key` before each value.

| Method | Description |
|---|---|
| `JsonWriter()` | an empty writer |
| `begin_object()`, `end_object()`, `begin_array()`, `end_array()` | containers |
| `write_key(key)` | the key of the next value (inside an object) |
| `write_string(s)`, `write_int(n)`, `write_float(n)`, `write_bool(b)`, `write_null()` | scalar values |
| `write_value(v)` | embeds an existing `JsonValue` subtree |
| `build()` | the finished JSON text |

```nox
from nox.json import JsonWriter

w: JsonWriter = JsonWriter()
w.begin_object()
w.write_key("id")
w.write_int(7)
w.write_key("items")
w.begin_array()
w.write_string("x")
w.write_float(1.5)
w.write_bool(False)
w.write_null()
w.end_array()
w.end_object()
print(w.build())
```

```output
{"id":7,"items":["x",1.5,false,null]}
```

The writer does not validate your nesting: mismatched `end_*` calls or a missing `write_key` produce malformed text.

## Notes

- Numbers are doubles: integers above 2⁵³ lose precision. Strings are decoded to UTF-8 `str`.
- The names `decode`, `encode`, `encode_pretty` and the other `encode_*` forms were removed in 2.0 ([Migrating](../whatsnew/migrating.md)).
