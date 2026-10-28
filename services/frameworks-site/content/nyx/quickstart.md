# Quick start

This is the smallest Nyx program that renders a page and inserts a row. Handlers live inside `setup`. The boot call sits at module scope.

```nox
import nox.http
from nox.http import HttpRequest, HttpResponse
from nox.router import Context
import nyx.app
import nyx.config
import nyx.ctrl
import nyx.ctx
import nyx.model
from nyx.app import Application
from nyx.config import Config
from nyx.ctx import AppContext
from nyx.model import Attributes

def setup(application: Application) -> None:
    def home(ctx: Context) -> HttpResponse:
        ac: AppContext = nyx.ctx.wrap(application, ctx)
        context: dict[str, str] = {}
        context["title"] = "Hello"
        context["env"] = ac.config().env
        return nyx.ctrl.render(200, "app/views/home.html", context)

    def create(ctx: Context) -> HttpResponse:
        ac: AppContext = nyx.ctx.wrap(application, ctx)
        attrs: Attributes = nyx.model.attributes()
        nyx.model.set_str(attrs, "title", ac.param("title", ""))
        nyx.model.create_attrs(ac.db(), "posts", attrs)
        return nyx.ctrl.redirect("/")

    application.router.get("/", home)
    application.router.post("/posts", create)

cfg: Config = nyx.config.load()
application: Application = nyx.app.boot(cfg, setup)

def handle(req: HttpRequest) -> HttpResponse:
    return nyx.app.dispatch(application, req)

nox.http.serve(8080, handle)
```

## Why the handler is nested

`setup` runs once, with the live `Application`. The functions defined there capture it. `nyx.ctx.wrap(application, ctx)` is how a handler reaches config, the database and the form parameters for this request. Do not stash the request on a module global; the next request would overwrite it, and under more than one worker each worker has its own globals anyway.

## A view

Nox templates substitute `{{name}}` and HTML-escape the value. There is no loop tag.

```html
<h1>{{title}}</h1>
<p>Environment: {{env}}</p>
```

Put the file at `app/views/home.html` relative to the process working directory, which is what `nyx.ctrl.render` reads. For a list of rows, see [Routes, views and forms](/docs/http/).

## Generating the app instead

```sh
./bin/nyx new blog
./bin/nyx generate model Post title:string body:text
./bin/nyx db migrate
./bin/nyx server
```

`nyx new` writes the `nox.json`, the entry file and the view directory the snippet above expects. The rest of this guide explains the pieces that generator emits.
