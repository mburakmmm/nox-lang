# nox.csv

Read and write CSV text following RFC 4180: comma-separated fields, optional double-quoted fields that may contain commas, quotes and line breaks, and `""` as an
escaped quote.

```text
import nox.csv
from nox.csv import CsvError
```

**Capability:** none. The module works on text; read files with [`nox.fs`](fs.md).

## Functions

| Function | Description |
|---|---|
| `parse(text)` | parses the whole text into rows of fields (`list[list[str]]`); raises `CsvError` for an unterminated quoted field |
| `parse_dicts(text)` | treats the first row as the header and returns one `dict[str, str]` per following row |
| `dump_row(fields)` | formats one row, quoting fields that need it (no trailing newline) |
| `dump(rows)` | formats all rows, one per line, each followed by `\n` |

Input may use `\n` or `\r\n` line endings; output always uses `\n`. All values are strings — convert with `int(...)` / `float(...)` yourself.

```nox
import nox.csv
from nox.csv import CsvError

rows: list[list[str]] = nox.csv.parse("a,b,c\n1,\"x,y\",3\n")
print(rows, len(rows))
dicts: list[dict[str, str]] = nox.csv.parse_dicts("name,age\nada,36\nalan,41\n")
print(dicts[1]["name"], len(dicts))
print(nox.csv.dump_row(["a", "b,c", "d\"e"]))
print(nox.csv.dump([["x", "y"], ["1", "2"]]), end="")
try:
    nox.csv.parse("a,\"unterminated")
except CsvError as e:
    print("bad csv")
```

```output
[['a', 'b', 'c'], ['1', 'x,y', '3']] 2
alan 2
a,"b,c","d""e"
x,y
1,2
bad csv
```

## Out of scope

Custom delimiters (`;`, tab), a byte-order mark, and reading files directly (pass the text from [`nox.fs.read_to_string`](fs.md)).

The names `write` and `write_row` were removed in 2.0; use `dump` and `dump_row` ([Migrating](../whatsnew/migrating.md)).
