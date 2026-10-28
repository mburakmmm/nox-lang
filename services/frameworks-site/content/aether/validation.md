# Validation and OpenAPI

DTOs are schemas checked by `aether.dto`. The OpenAPI document is the same schema, written once at boot by `aether.openapi` and served, with Swagger UI, by `aether.swagger`.

## What a schema can say

- Required and optional fields.
- String formats: `email`, `uuid`, `uri`.
- Number ranges.
- Query and header parameters, including number and bool, not only strings.

A failure is HTTP 422 with the same detail text `nox.validate` would produce for a scalar or a nested value. Do not invent a second error dialect in the handler; let the pipe return it.

## OpenAPI

`AETHER_OPENAPI` turns the document on. `AETHER_OPENAPI_TITLE` and `AETHER_OPENAPI_VERSION` are the info block. Routes you registered, their path parameters, and the success and error statuses are included. Security schemes are part of the document when a route declares one.

Swagger UI is mounted at `/docs` when OpenAPI is enabled. The document itself is the JSON route the UI fetches. Both are built at boot, so a request does not walk the route table to regenerate them.

## JSON names

Nox 1.171 removed `nox.json.decode` / `encode` / `encode_string`. Aether 0.7.2 and later call `parse`, `dump` and `dump_string`. If you drop to the standard library inside a handler, use those names too.

## One decode

`dispatch_from_parts` plus the body cache means a validated body is parsed once even if a pipe and the handler both look at it. `ValidatedBody` is that cache. Reading `ctx.body` as a string and parsing it yourself parses it a second time; prefer the value the pipe already checked.
