# nox.validate

Validate JSON documents — typically HTTP request bodies — against a declarative schema. Validation returns a list of human-readable problems (empty means valid)
instead of raising, so a handler can report every problem at once.

```text
import nox.validate
from nox.validate import Schema
```

**Capability:** none.

## Building a schema

A `Schema` is a list of field rules. Add rules with `require` (the field must exist) or `optional`, naming the expected **kind**: `"string"`, `"number"`,
`"bool"`, `"array"`, `"object"` or `"null"`.

| Method | Description |
|---|---|
| `Schema()` | an empty schema |
| `require(name, kind)`, `optional(name, kind)` | a required / optional field of that kind |
| `require_object_schema(name, sub)`, `optional_object_schema(name, sub)` | a nested object validated against `sub` |
| `require_array_of_kind(name, elem_kind)`, `optional_array_of_kind(name, elem_kind)` | an array whose elements are all of one kind |
| `require_array_of_schema(name, sub)`, `optional_array_of_schema(name, sub)` | an array of objects, each validated against `sub` |

Constraints are attached to an already-added rule by name; applying one to a rule of the wrong kind (or naming an unknown rule or format) raises `ValueError` so typos
are not silently ignored:

| Method | Applies to | Description |
|---|---|---|
| `min(name, v)`, `max(name, v)` | `number` | inclusive bounds |
| `min_length(name, n)`, `max_length(name, n)` | `string` | length bounds (code points) |
| `pattern(name, regex)` | `string` | must match the [`nox.regex`](regex.md) pattern |
| `format(name, fmt)` | `string` | `"email"` or `"uuid"` |

`FieldRule` is the internal record that `Schema` keeps for each rule; you normally never construct one yourself.

## Validating

| Function | Description |
|---|---|
| `validate(v, schema)` | validates a parsed `JsonValue`; returns the list of problems |
| `validate_json_str(s, schema)` | parses `s` first; invalid JSON yields a single problem |

Problem messages name the field by its full path — `address.city`, `tags[1]`. The wording of the messages is currently Turkish; test for emptiness or count, and show
the list to the user rather than matching text.

```nox
import nox.validate
from nox.validate import Schema

addr: Schema = Schema()
addr.require("city", "string")

s: Schema = Schema()
s.require("name", "string")
s.min_length("name", 2)
s.require("age", "number")
s.min("age", 0.0)
s.max("age", 150.0)
s.optional("email", "string")
s.format("email", "email")
s.require_object_schema("address", addr)
s.require_array_of_kind("tags", "string")

bad: list[str] = nox.validate.validate_json_str("{\"name\": \"a\", \"age\": 200, \"email\": \"bad\", \"address\": {}, \"tags\": [\"x\", 1]}", s)
print(len(bad))
good: list[str] = nox.validate.validate_json_str("{\"name\": \"ada\", \"age\": 36, \"address\": {\"city\": \"x\"}, \"tags\": []}", s)
print(len(good), len(nox.validate.validate_json_str("not json", s)))
```

```output
5
0 1
```

## Use in a web handler

```nox-fragment
errors: list[str] = nox.validate.validate_json_str(ctx.request.body, schema)
if len(errors) > 0:
    return HttpResponse(400, nox.strings.join(errors, "; "), {"Content-Type": "text/plain"})
```
