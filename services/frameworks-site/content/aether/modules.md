# Modules and routes

A module is a class with `configure`. The `ModuleBuilder` is the only object that learns the routes. The application learns the module when `build` calls `configure` or `import_module`.

## Registering

```nox
class HealthModule:
    def configure(self: HealthModule, m: ModuleBuilder) -> None:
        m.get("/healthz", self._health())
```

`m.get`, `m.post`, `m.put` and `m.delete` take a path and a function `(HttpContext) -> HttpResponse`. Build that function in a method so it can capture `self` and anything `self` holds.

## Prefixes and imports

```nox
m.prefix("/api")
app.import_module(configure)
```

`import_module` and `import_configure` mount another module’s `configure` into this app. A prefix is applied to the routes that module registers. Compose the tree in `build`, not on the first request.

## Closures are the injector

Nox cannot subclass an imported base, so `class X(Injectable)` is not available. The official pattern:

1. Construct the service in the module and keep it in a field.
2. `m.provide("Users")` records the name for diagnostics and OpenAPI.
3. The handler closure captures the field.

```nox
def _show(self: UsersModule, users: UserService) -> (HttpContext) -> HttpResponse:
    def show(ctx: HttpContext) -> HttpResponse:
        return json_ok(users.find(ctx.param("id")))
    return show
```

There is no container that constructs `UserService` from a type. If two modules need the same service, construct it in `build` and pass it into both `configure` methods.

## Collisions

Two routes whose parameter shapes collide (`/:id` and `/:name` on the same method and prefix) fail at boot, not on the first request that happens to match. Framework routes and DTO names are also unique at boot. Trailing slashes are normalized, and the route key is computed again after that normalization, so `/users` and `/users/` are one route.
