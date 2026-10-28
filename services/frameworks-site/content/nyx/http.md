# Routes, views and forms

Routes are registered on `application.router` inside `setup`. Views are HTML files with `{{name}}` substitutions. Forms are read through `AppContext.param` or `nyx.form`.

## Routes

```nox
application.router.get("/", home)
application.router.post("/posts", create)
```

The method is the HTTP verb. The path is matched after the query string has been removed. Dynamic segments follow the router that ships with Nox; Nyx does not invent a second pattern language.

`nyx.ctrl` builds the response:

| Call | Result |
|---|---|
| `nyx.ctrl.render(status, path, context)` | HTML from a template, escaped |
| `nyx.ctrl.redirect(location)` | redirect response |
| `nyx.ctrl.text(status, body)` | plain text |

`render_with_layout` wraps a view in a layout. The layout’s body slot is filled first and then substituted, so `{{...}}` written inside the view body is not parsed a second time.

## Escaping

`render`, `render_with_layout` and `render_records` HTML-escape every substitution. The `*_unescaped` variants exist for a fragment you already know is safe, such as a partial this same app just rendered. Never pass raw request input to an unescaped render.

## Lists

Templates have no loop. Render one partial per row, or pass a `list[dict[str, str]]`.

```nox
fields: list[str] = []
fields.append("title")
fields.append("body")
html: str = nyx.view.render_records("app/views/posts/_item.html", rows, fields)
```

`nyx.view.render_each(path, contexts)` takes `list[dict[str, str]]` and concatenates the rendered partials. The partial itself is still a normal template:

```html
<article>
  <h2>{{title}}</h2>
  <p>{{body}}</p>
</article>
```

## Forms

```nox
title: str = ac.param("title", "")
```

`param` reads the parsed form body. A `+` in that body is a space. That decoding is Nyx’s, on `runtime.request_target`, because `nox.url.query_decode` keeps `+` literal.

`nyx.form` is the helper for building the form markup and the CSRF field that `nyx.csrf` expects. If CSRF is on, a state-changing request without the token is rejected before the handler runs. Setting `NYX_SESSION=0` does not disable CSRF; CSRF turns the session back on, because the token has to live somewhere.

## Flash

`nyx.flash` stores a one-request message in the session: a notice after `redirect`, consumed on the next `render`. It is not a second channel beside the template context. Read it in the layout and it is gone.
