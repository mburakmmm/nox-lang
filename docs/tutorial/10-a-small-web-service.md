# 10. A small web service

Nox's standard library includes an HTTP server (`nox.http`), a path router (`nox.router`) and a JSON module (`nox.json`). This chapter builds a tiny
to-do API with them.

## Hello, HTTP

```nox
import nox.http
from nox.http import HttpRequest, HttpResponse
from nox.router import Router, Context

router: Router = Router()

def hello(ctx: Context) -> HttpResponse:
    return HttpResponse(200, "hello from nox\n", {"Content-Type": "text/plain"})

router.get("/", hello)

def handle(req: HttpRequest) -> HttpResponse:
    return router.dispatch(req)

nox.http.serve(8080, handle)
```

Run it with `noxc run server.nox` and open `http://localhost:8080/`. `nox.http.serve(port, handler)` accepts connections forever and calls `handler` for each request (an optional third argument caps the number of
connections served, `0` meaning unlimited). A `Router` maps method and path to handler functions; `:name` segments capture path parameters.

## Path parameters and JSON

```nox
import nox.http
import nox.json
from nox.http import HttpRequest, HttpResponse
from nox.json import JsonWriter
from nox.router import Router, Context

todos: list[str] = ["write docs", "ship 2.0"]
router: Router = Router()

def json_response(status: int, body: str) -> HttpResponse:
    return HttpResponse(status, body, {"Content-Type": "application/json"})

def list_todos(ctx: Context) -> HttpResponse:
    w: JsonWriter = JsonWriter()
    w.begin_array()
    for t in todos:
        w.write_string(t)
    w.end_array()
    return json_response(200, w.build())

def show_todo(ctx: Context) -> HttpResponse:
    i: int = int(ctx.param("id"))
    if i < 0 or i >= len(todos):
        return json_response(404, "{\"error\":\"not found\"}")
    w: JsonWriter = JsonWriter()
    w.begin_object()
    w.write_key("id")
    w.write_int(i)
    w.write_key("title")
    w.write_string(todos[i])
    w.end_object()
    return json_response(200, w.build())

def add_todo(ctx: Context) -> HttpResponse:
    title: str = ctx.request.body
    if title == "":
        return json_response(400, "{\"error\":\"empty body\"}")
    todos.append(title)
    return json_response(201, "{\"id\":" + str(len(todos) - 1) + "}")

router.get("/todos", list_todos)
router.get("/todos/:id", show_todo)
router.post("/todos", add_todo)

def handle(req: HttpRequest) -> HttpResponse:
    return router.dispatch(req)

nox.http.serve(8080, handle)
```

Try it:

```sh
curl localhost:8080/todos                      # ["write docs","ship 2.0"]
curl localhost:8080/todos/1                    # {"id":1,"title":"ship 2.0"}
curl -X POST -d 'try nox' localhost:8080/todos # {"id":2}
```

Notes:

- `ctx.param("id")` returns a path parameter as a `str`; `ctx.request` is the underlying `HttpRequest` (`method`, `target`, `body`, `headers`).
- `JsonWriter` builds JSON incrementally and `build()` returns the text. To *parse* JSON use `nox.json.parse` ([JSON](../stdlib/json.md)).
- `todos` is module-level state. `serve` runs a single thread, so it is shared safely; with `serve_multicore` each worker has its own copy, so keep
  shared state in a database or use `nox.atomic` / `nox.sharedmem`.

## Middleware

`Router.use(...)` wraps every handler — for logging, authentication or timing:

```nox
import nox.http
import nox.time
from nox.http import HttpRequest, HttpResponse
from nox.router import Router, Context

router: Router = Router()

def logging(ctx: Context, nxt: (Context) -> HttpResponse) -> HttpResponse:
    start: int = nox.time.now_ms()
    resp: HttpResponse = nxt(ctx)
    print(ctx.request.method, ctx.request.target, resp.status, nox.time.now_ms() - start, "ms")
    return resp

def ping(ctx: Context) -> HttpResponse:
    return HttpResponse(200, "pong", {"Content-Type": "text/plain"})

router.use(logging)
router.get("/ping", ping)

def handle(req: HttpRequest) -> HttpResponse:
    return router.dispatch(req)

nox.http.serve(8080, handle)
```

## Going further

- **Scale across cores:** `nox.http.serve_multicore(port, handler, threads, max_connections)` runs a pool of worker threads ([HTTP](../stdlib/http.md)).
- **TLS and WebSockets:** `serve_tls`, `serve_ws` and the `nox.websocket` module.
- **Databases:** `nox.sqlite`, `nox.postgres`, `nox.mysql` and the `nox.orm` layer.
- **Validation:** `nox.validate` checks request bodies against a schema.
- **A framework:** [Nyx](https://github.com/mburakmmm/nyx) is a batteries-included web framework written in Nox — this very website runs on it.
