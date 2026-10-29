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
| `parse(text)` | parses one document into a `YamlValue`; raises `YamlError` (also when the text holds several documents) |
| `parse_all(text)` | parses every document of a `---` separated stream into a `list[YamlValue]` |
| `get(root, dotted_path)` | follows a dotted path through nested mappings and sequences (`"nested.deep"`, `"servers.0.name"`); raises `YamlError` if a segment is missing |
| `dump(v)` | writes a mapping or sequence as block-style YAML (strings are always double-quoted, aliases are written out in full) |
| `dump_all(docs)` | writes several documents separated by `---` |
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

YAML 1.2 (core schema): block mappings and sequences (including `- key: value` items and a sequence at the same indent as its key); flow
sequences and mappings (multi-line, nested); plain, single- and double-quoted scalars (all double-quote escapes: `\n \t \r \0 \" \\ \xHH \uHHHH \UHHHHHHHH`),
multi-line plain and quoted scalars (line folding); block scalars `|` and `>` with chomping (`-`, `+`) and indentation indicators; trailing
comments; anchors (`&a`), aliases (`*a`) and merge keys (`<<: *a`, `<<: [*a, *b]`); the tags `!!str`, `!!int`, `!!float`, `!!bool` and `!!null`
(other tags are ignored); several documents in one stream (`---`, `...`, see `parse_all`); `%` directives are skipped.

Plain scalars follow the 1.2 core schema: `true`/`false`, `null`/`~`, decimal and `0x`/`0o` integers, floats (`1.5e3`, `.5`), `.inf`, `-.inf` and
`.nan`; everything else (including `yes`, `no`, `1_000` and dates) is a string. Mapping keys are always stored as strings (a scalar key by its text).

**Not supported:** explicit keys (`? key`) and collection keys, complex tags and `!!binary`/`!!timestamp` types (a date stays a string), and `%TAG`
handles. An alias is the **same** value as its anchor, not a copy.

```nox
import nox.yaml
from nox.yaml import YamlValue

cfg: YamlValue = nox.yaml.parse("base: &b\n  retries: 3\nprod:\n  <<: *b\n  host: example.org  # live\nmsg: |\n  hello\n  world\n")
print(nox.yaml.get(cfg, "prod.retries").i, nox.yaml.get(cfg, "prod.host").s, nox.yaml.get(cfg, "msg").s == "hello\nworld\n")
docs: list[YamlValue] = nox.yaml.parse_all("---\na: 1\n---\nb: 2\n")
print(len(docs), nox.yaml.get(docs[1], "b").i)
```

```output
3 example.org True
2 2
```
