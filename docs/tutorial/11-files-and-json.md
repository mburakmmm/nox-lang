# 11. Files and JSON

Most real programs read something from disk and write something back. This chapter covers text files, directories and JSON — the three things you will
reach for first. Everything here lives in two modules: [`nox.fs`](../stdlib/fs.md) and [`nox.json`](../stdlib/json.md).

## Reading and writing text

A file is read or written as one `str`. `write_string` creates the file or truncates it; `append_string` adds to the end; `read_to_string` returns the
whole content:

```nox
import nox.fs

path: str = "/tmp/nox_tutorial_notes.txt"

nox.fs.write_string(path, "first line\nsecond line\n")
nox.fs.append_string(path, "third line\n")

text: str = nox.fs.read_to_string(path)
print(len(text), "bytes")

lines: list[str] = text.split("\n")
for line in lines:
    if len(line) > 0:
        print("-", line)

nox.fs.remove_file(path)
print(nox.fs.exists(path))
```

```output
34 bytes
- first line
- second line
- third line
False
```

`split("\n")` leaves an empty string after the final newline, which is why the loop skips empty lines. Paths are plain strings; use [`nox.path`](../stdlib/path.md)
to join and take them apart without worrying about separators.

## When something goes wrong

Every file operation that can fail raises `FsError`. Catch it where you can do something useful about it:

```nox
import nox.fs
from nox.fs import FsError

def load(path: str) -> str:
    try:
        return nox.fs.read_to_string(path)
    except FsError as e:
        print("could not read", path)
        return ""

print(len(load("/tmp/nox_tutorial_definitely_missing.txt")))
```

```output
could not read /tmp/nox_tutorial_definitely_missing.txt
0
```

## Directories

`create_dir_all` is `mkdir -p`; `read_dir` returns the *names* of the entries in no particular order, so sort them if the order matters; `remove_dir_all`
cleans up:

```nox
import nox.fs

root: str = "/tmp/nox_tutorial_dir"
nox.fs.create_dir_all(root + "/sub/deeper")
nox.fs.write_string(root + "/b.txt", "bee")
nox.fs.write_string(root + "/a.txt", "ay")

for name in sorted(nox.fs.read_dir(root)):
    kind: str = "file"
    if nox.fs.is_dir(root + "/" + name):
        kind = "dir"
    print(name, kind)

nox.fs.remove_dir_all(root)
print(nox.fs.exists(root))
```

```output
a.txt file
b.txt file
sub dir
False
```

> **Untrusted paths.** `nox.fs` hands paths to the operating system unchecked. If a path comes from a user or a network request, confine it to a
> directory you choose before you open it (see [Security](../reference/security.md)).

## Parsing JSON

`nox.json.parse` turns text into a tree of `JsonValue` nodes. You ask a node what it is, then read it with a typed accessor — there is no implicit
conversion, in keeping with the rest of the language:

```nox
import nox.json
from nox.json import JsonError

text: str = "{\"name\": \"Ada\", \"langs\": [\"nox\", \"python\"], \"age\": 36}"
doc: JsonValue = nox.json.parse(text)

for i in range(nox.json.object_len(doc)):
    key: str = nox.json.object_key(doc, i)
    value: JsonValue = nox.json.object_value(doc, i)
    if nox.json.is_string(value):
        print(key, "=", nox.json.as_string(value))
    elif nox.json.is_number(value):
        print(key, "=", int(nox.json.as_number(value)))
    elif nox.json.is_array(value):
        print(key, "has", nox.json.array_len(value), "items")

try:
    nox.json.parse("{oops")
except JsonError as e:
    print("invalid JSON")
```

```output
name = Ada
langs has 2 items
age = 36
invalid JSON
```

Objects keep their keys **in document order**, and there is no lookup by name — you loop over the entries. For small documents that is all you need; for
anything you look up often, copy the entries into a `dict[str, str]` once.

## Writing JSON

Two styles. `JsonWriter` builds text piece by piece and is the one to use when you produce JSON from your own data:

```nox
from nox.json import JsonWriter

w: JsonWriter = JsonWriter()
w.begin_object()
w.write_key("title")
w.write_string("Nox tutorial")
w.write_key("chapter")
w.write_int(11)
w.write_key("topics")
w.begin_array()
w.write_string("files")
w.write_string("json")
w.end_array()
w.end_object()
print(w.build())
```

```output
{"title":"Nox tutorial","chapter":11,"topics":["files","json"]}
```

The other style is to `parse` text and `dump` or `dump_pretty` the tree again — handy for reformatting:

```nox
import nox.json

doc: JsonValue = nox.json.parse("{\"a\":1,\"b\":[true,null]}")
print(nox.json.dump_pretty(doc, 2))
```

```output
{
  "a": 1,
  "b": [
    true,
    null
  ]
}
```

## Putting it together: a tiny settings file

Read a JSON settings file if it exists, fall back to defaults otherwise, and save it back:

```nox
import nox.fs
import nox.json
from nox.fs import FsError
from nox.json import JsonWriter, JsonError

class Settings:
    name: str
    volume: int

    def __init__(self, name: str, volume: int) -> None:
        self.name = name
        self.volume = volume

def load_settings(path: str) -> Settings:
    result: Settings = Settings("default", 5)
    try:
        doc: JsonValue = nox.json.parse(nox.fs.read_to_string(path))
        for i in range(nox.json.object_len(doc)):
            key: str = nox.json.object_key(doc, i)
            value: JsonValue = nox.json.object_value(doc, i)
            if key == "name" and nox.json.is_string(value):
                result.name = nox.json.as_string(value)
            if key == "volume" and nox.json.is_number(value):
                result.volume = int(nox.json.as_number(value))
    except FsError as e:
        print("no settings file yet")
    except JsonError as e:
        print("settings file is damaged")
    return result

def save_settings(path: str, s: Settings) -> None:
    w: JsonWriter = JsonWriter()
    w.begin_object()
    w.write_key("name")
    w.write_string(s.name)
    w.write_key("volume")
    w.write_int(s.volume)
    w.end_object()
    nox.fs.write_string_atomic(path, w.build())

path: str = "/tmp/nox_tutorial_settings.json"
settings: Settings = load_settings(path)
print(settings.name, settings.volume)
settings.volume = 9
save_settings(path, settings)
again: Settings = load_settings(path)
print(again.name, again.volume)
nox.fs.remove_file(path)
```

```output
no settings file yet
default 5
default 9
```

`write_string_atomic` writes to a temporary file and renames it over the target, so a crash half-way never leaves a truncated settings file behind.

Next: [12. Testing](12-testing.md).
