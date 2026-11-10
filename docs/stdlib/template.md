# nox.template

A minimal text template engine: `{{ name }}` placeholders replaced from a dictionary. By default every value is **HTML-escaped**, which is the basic defence against
cross-site scripting. `render` / `render_unescaped` only substitute placeholders; `render_blocks` / `render_blocks_unescaped` also understand `{% for %}` and `{% if %}`.

```text
import nox.template
from nox.template import TemplateError
```

**Capability:** none.

## Functions

| Function | Description |
|---|---|
| `render(tmpl, context)` | replaces each `{{ name }}` with the HTML-escaped value from `context`; raises `TemplateError` for an unterminated placeholder or an unknown name |
| `render_unescaped(tmpl, context)` | the same, but inserts values verbatim — for fragments you built yourself and know to be safe |
| `escape_html(s)` | escapes `&`, `<`, `>`, `"` and `'` |

Whitespace inside the braces is ignored (`{{name}}` and `{{ name }}` are equal).

```nox
import nox.template

print(nox.template.render("Hello {{ name }}! {{ x }}", {"name": "<Ada>", "x": "1"}))
print(nox.template.render_unescaped("{{ html }}", {"html": "<b>bold</b>"}))
print(nox.template.escape_html("a<b>&\"'"))
```

```output
Hello &lt;Ada&gt;! 1
<b>bold</b>
a&lt;b&gt;&amp;&quot;&#39;
```

## Building a list

```nox
import nox.template

items: list[str] = ["a", "b"]
rows: str = ""
for it in items:
    rows = rows + nox.template.render("<li>{{ v }}</li>", {"v": it})
print(nox.template.render_unescaped("<ul>{{ rows }}</ul>", {"rows": rows}))
```

```output
<ul><li>a</li><li>b</li></ul>
```

## Blocks: loops and conditions

`render_blocks(template, scalars, lists)` adds two block tags. Data comes in two dictionaries: `scalars: dict[str, str]` for `{{ name }}` and conditions, and
`lists: dict[str, list[dict[str, str]]]` for loops (each item is a dictionary of fields).

| Syntax | Meaning |
|---|---|
| `{% for u in users %}…{% endfor %}` | repeats the body for each item of `lists["users"]`; `{{ u.name }}` reads the item's field `name` |
| `loop.index`, `loop.index0`, `loop.first`, `loop.last` | inside a loop: 1-based and 0-based position, and `"true"`/`"false"` flags |
| `{% if name %}…{% else %}…{% endif %}` | true when the scalar is non-empty and not `"0"`/`"false"`/`"False"`, or the named list is non-empty; an undefined name is false |
| `{% if not name %}…{% endif %}` | negation |

Blocks nest. A missing `endfor`/`endif`, a stray `endfor`/`endif`/`else`, an unknown tag, an undefined `{{ name }}` and an undefined loop list all raise
`TemplateError`. Values are HTML-escaped by `render_blocks`; `render_blocks_unescaped` writes them as is. Plain `render` leaves `{% … %}` untouched.

```nox
import nox.template

users: list[dict[str, str]] = [{"name": "Ada"}, {"name": "Bob"}]
html: str = nox.template.render_blocks("{% for u in users %}{{ loop.index }}:{{ u.name }}{% if loop.last %}.{% else %}, {% endif %}{% endfor %}", {}, {"users": users})
print(html)
```

```output
1:Ada, 2:Bob.
```

## Notes

- Only `str` values are supported; convert numbers with `str(...)` first.
- Escape for the context you are writing into: HTML-escaping protects HTML text and quoted attributes, not JavaScript or URL contexts.
- Web frameworks such as Nyx provide richer view layers on top of the same idea.
