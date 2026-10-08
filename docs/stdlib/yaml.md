# nox.yaml

Parse and write a practical subset of YAML — enough for configuration files. The parser is written in Nox and rejects anything outside the supported subset with
a `YamlError` instead of guessing.

```text
import nox.yaml
from nox.yaml import YamlValue, YamlError
```

**Capability:** none. The module works on text; read files with [`nox.fs`](fs.md).

## Functions

| Function | Description |
|---|---|
| `parse(text)` | parses one document into a `YamlValue`; raises `YamlError` |
| `get(root, dotted_path)` | follows a dotted path through nested **mappings** (`"nested.deep"`); raises `YamlError` if a segment is missing. Index sequences through `.arr[i]` |
| `dump(v)` | writes a mapping or sequence as block-style YAML |
| `is_string(v)`, `is_int(v)`, `is_float(v)`, `is_bool(v)`, `is_null(v)`, `is_sequence(v)`, `is_mapping(v)` | kind tests |

## `YamlValue`

| Kind | Field | Type |
|---|---|---|
| string | `s` | `str` |
| integer | `i` | `int` |
| float | `f` | `float` |
| boolean | `b` | `bool` |
| null | — | — |
| sequence | `arr` | `list[YamlValue]` |
| mapping | `mapping` | `dict[str, YamlValue]` (keys are always strings) |

Plain scalars are converted automatically: `36` is an integer, `1.5` a float, `true`/`false` booleans, `null` a null; anything else is a string. Quote a value
(`"36"`) to force a string.

```nox
import nox.yaml
from nox.yaml import YamlValue, YamlError

y: YamlValue = nox.yaml.parse("name: ada\nage: 36\nlangs:\n  - nox\n  - zig\nnested:\n  deep: true\n  ratio: 1.5\nnothing: null\n")
print(nox.yaml.is_mapping(y), nox.yaml.get(y, "name").s, nox.yaml.get(y, "age").i, nox.yaml.get(y, "nested.deep").b, nox.yaml.is_null(nox.yaml.get(y, "nothing")))
langs: YamlValue = nox.yaml.get(y, "langs")
print(nox.yaml.is_sequence(langs), len(langs.arr), langs.arr[0].s)
print(nox.yaml.dump(y))
try:
    nox.yaml.get(y, "missing")
except YamlError as e:
    print("missing key")
```

```output
True ada 36 True True
True 2 nox
name: "ada"
age: 36
langs:
  - "nox"
  - "zig"
nested:
  deep: true
  ratio: 1.5
nothing: null

missing key
```

## Supported YAML

Supported: block mappings and sequences with nesting by indentation (including `- key: value` items), flow sequences and mappings (`[1, 2]`, `{a: 1}`), plain, single-
and double-quoted scalars, full-line comments, blank lines, and one optional leading `---`.

**Not supported:** trailing (same-line) comments, anchors and aliases (`&`/`*`), tags (`!!str`), merge keys (`<<`), block scalars (`|`, `>`), multiple documents (a second
`---` or `...` raises `YamlError`), non-string mapping keys and explicit keys (`? key`).
