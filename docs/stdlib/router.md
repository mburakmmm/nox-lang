# nox.router

Path routing and middleware for `nox.http` handlers, written in Nox. A `Router` maps a method and a path pattern to a handler function; `dispatch` turns an
`HttpRequest` into an `HttpResponse`.

```text
from nox.router import Router, Context
```

**Capability:** none.

## Handlers and `Context`

A handler has the type `(Context) -> HttpResponse`. The `Context` gives it everything about the request:

| Member | Description |
|---|---|
| `request` | the underlying `HttpRequest` (`method`, `target`, `body`, `headers`, `peer_addr`) |
| `params` | `dict[str, str]` of captured path parameters |
| `param(name)` | one path parameter; `KeyError` if the pattern has no such name |
| `query` | `dict[str, str]` of the decoded query-string parameters (`?q=a%20b&n=3` → `{'q': 'a b', 'n': '3'}`) |

The query string is stripped before the path is matched, so `GET /search/books?q=x` matches the pattern `/search/:kind`. Read typed values with `nox.url.query_int(ctx.query, "n")`,
`query_float`, `query_bool` ([`nox.url`](url.md)).

## Routes

| Method | Description |
|---|---|
| `Router()` | an empty router |
| `get(pattern, handler)`, `post(...)`, `put(...)`, `delete(...)` | register a route for that HTTP method |
| `add(method, pattern, handler)` | register any method |
| `dispatch(req)` | route a request; returns the handler's response, or `404` with body `not found` when nothing matches |

**Patterns** are `/`-separated segments. A literal segment must match exactly; a segment starting with `:` captures that part of the path under the given name: `/users/:id/posts/:post`.
A pattern matches only paths with the **same number of segments**. Routes are tried in registration order and the first match wins; the method must also match (a path match with the wrong method is a `404`).

```nox
import nox.url
from nox.http import HttpRequest, HttpResponse
from nox.router import Router, Context

router: Router = Router()

def search(ctx: Context) -> HttpResponse:
    q: str = ""
    if "q" in ctx.query:
        q = ctx.query["q"]
    return HttpResponse(200, ctx.param("kind") + ":" + q + ":" + str(nox.url.query_int(ctx.query, "n")), {})

router.get("/search/:kind", search)
print(router.dispatch(HttpRequest("GET", "/search/books?q=a%20b&n=3", "", {}, "")).body)
print(router.dispatch(HttpRequest("GET", "/search/music?n=7", "", {}, "")).body)
print(router.dispatch(HttpRequest("GET", "/nope?x=1", "", {}, "")).status)
```

```output
books:a b:3
music::7
404
```

`Route` is the internal record (`method`, `pattern`, `handler`) a router keeps for each registered route; you normally never construct one.

## Middleware

Three hooks, run around the matched handler (they do **not** run for a `404`):

| Method | Signature | Description |
|---|---|---|
| `use_before(mw)` | `(Context) -> HttpResponse \| None` | runs first; returning a response **short-circuits** (the handler and the later hooks are skipped), returning `None` continues |
| `use(mw)` | `(Context, (Context) -> HttpResponse) -> HttpResponse` | wraps the handler: call `next(ctx)` to continue and inspect or replace the result. Several `use` calls nest — the first registered is the outermost |
| `use_after(mw)` | `(Context, HttpResponse) -> HttpResponse` | transforms the response after the handler |

Order of execution: all `use_before` hooks → the `use` chain around the handler → all `use_after` hooks.

```nox
from nox.http import HttpRequest, HttpResponse
from nox.router import Router, Context

router: Router = Router()

def ping(ctx: Context) -> HttpResponse:
    return HttpResponse(200, "pong", {})

def secret(ctx: Context) -> HttpResponse:
    return HttpResponse(200, "classified", {})

def need_token(ctx: Context) -> HttpResponse | None:
    if "X-Token" not in ctx.request.headers:
        return HttpResponse(401, "unauthorized", {})
    return None

def tag(ctx: Context, nxt: (Context) -> HttpResponse) -> HttpResponse:
    resp: HttpResponse = nxt(ctx)
    return HttpResponse(resp.status, resp.body + "!", resp.headers)

router.use_before(need_token)
router.use(tag)
router.get("/ping", ping)
router.get("/secret", secret)

print(router.dispatch(HttpRequest("GET", "/ping", "", {}, "")).status)
authed: HttpRequest = HttpRequest("GET", "/ping", "", {"X-Token": "t"}, "")
print(router.dispatch(authed).body)
```

```output
401
pong!
```

## Using a router with the server

Build the router in a function and assign it to a module variable; the handler calls it:

```nox
import nox.http
from nox.http import HttpRequest, HttpResponse
from nox.router import Router, Context

def home(ctx: Context) -> HttpResponse:
    return HttpResponse(200, "hello", {"Content-Type": "text/plain"})

def build_router() -> Router:
    r: Router = Router()
    r.get("/", home)
    return r

router: Router = build_router()

def handle(req: HttpRequest) -> HttpResponse:
    return router.dispatch(req)

nox.http.serve(8080, handle)
```

On the default LLVM backend connections run on several worker threads and each worker has its own copy of the module's variables ([Modules](../language/modules.md#module-level-state-and-the-multi-core-runtime)).
The variable's initialiser therefore runs for every worker, and so do the `router.get(...)`-style calls that **directly follow** the declaration (only `def`, `class` and
imports may sit between them), so this layout works too:

```nox
from nox.http import HttpResponse
from nox.router import Router, Context

def home(ctx: Context) -> HttpResponse:
    return HttpResponse(200, "hello", {})

def create_item(ctx: Context) -> HttpResponse:
    return HttpResponse(201, "created", {})

router: Router = Router()

router.get("/", home)
router.post("/items", create_item)

def count() -> int:
    return len(router.routes)

print(count())
```

```output
2
```

Keep the registrations together right after the declaration. A registration separated from it by any other statement (a `print`, an assignment) runs only on the main worker,
and the other workers would answer `404` for those routes. Building the router in a function, as above, is immune to this and is the better choice for larger routers.

`nox.reflect.router_from_decorators()` builds a router from `@get`/`@post`/`@put`/`@delete`-decorated functions ([Decorators](../language/decorators.md)).

## Limits

- No wildcard or regular-expression segments, no per-route middleware, no automatic `405`/`OPTIONS` handling; implement those in a `use_before` hook.
- Under `serve_multicore` each worker builds its own router (module-level state is per worker), which is what you want for a stateless routing table.
