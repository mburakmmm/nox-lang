# nox.template

A minimal text template engine: `{{ name }}` placeholders replaced from a dictionary. By default every value is **HTML-escaped**, which is the basic defence against
cross-site scripting. There are no conditionals or loops — build repeated markup in Nox and substitute the result with `render_unescaped`.

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

## Notes

- Only `str` values are supported; convert numbers with `str(...)` first.
- Escape for the context you are writing into: HTML-escaping protects HTML text and quoted attributes, not JavaScript or URL contexts.
- Web frameworks such as Nyx provide richer view layers on top of the same idea.
