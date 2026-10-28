# The pipeline

Every matched route runs the same steps. A step that returns a response stops the later steps.

1. Global guards, then the route’s guards.
2. Pipes, including DTO validation.
3. Interceptors, before. This step may return early.
4. The handler.
5. Interceptors, after.
6. Exception filters.

Guards, pipes and interceptors are functions you register on the module or on a single route, not subclasses of a framework base class. They close over the same services the handler closes over.

## Guards

A guard sees the `HttpContext` and either lets the pipeline continue or returns a response (typically 401 or 403). JWT checks belong here: `aether.jwt` verifies an HS256 bearer token. Time claims (`exp`, `nbf`, `iat`) are Aether’s; `nox.jwt` does not check them.

Use a constant-time compare for secrets and tokens. The auth helpers do.

## Pipes

A pipe turns the raw body, query or header into the value the handler wants. The body is decoded once. `ValidatedBody` keeps the `JsonValue` so a later step does not parse the JSON again. Flat validation short-circuits on the first failing field.

Query and header schemas accept strings, numbers and bools. A single-field body and a nested body report the same 422 detail, using the `nox.validate` sentences, so clients can match on one shape.

## Interceptors

Before-interceptors are the place for a cache hit or a metrics span that might skip the handler. After-interceptors see the response the handler returned. They must not assume they run when the before-step already answered.

## Filters

An exception filter turns a raised error into JSON. `aether.errors` is the structured `HttpError`. Uncaught exceptions hit the fallback filter. Development includes `line`. Production does not.

## CORS, size, 405

Before the pipeline, dispatch applies the body limit (`AETHER_MAX_BODY_BYTES`), answers CORS preflight from `AETHER_CORS_ORIGINS`, and returns 405 when the path exists for a different method. CORS in production is opt-in: an empty origin list does not reflect the request.
