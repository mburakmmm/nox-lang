# Sessions, CSRF and auth

Security middleware runs inside `dispatch`, before your handler. You configure it with environment variables and call it when you need a user, a token or a password hash. You do not reimplement the cookie.

## Session

`nyx.session` stores the session in the same database as the models (SQLite, Postgres or MySQL, matching the engine). The cookie carries the id, not the payload.

`NYX_SESSION=0` skips the middleware. That is the right switch for a fair benchmark or a pure API process. It is the wrong switch for a browser app: `NYX_CSRF` forces the session back on, because the CSRF token is stored there.

## CSRF

State-changing requests must present the token `nyx.form` embeds. A missing or wrong token is rejected in the middleware.

`NYX_CSRF_API_EXEMPT` opts paths under `/api/` out of that check. Use it for token-authenticated JSON routes, not for browser forms that happen to live under `/api/`.

## Headers

`nyx.security` sets the usual browser headers (frame, content type, referrer) and the `NYX_CSP` policy. `NYX_SECURITY_HEADERS=0` skips that after-middleware. The noxlang.com container sets an explicit CSP that allows only same-origin resources; copy that strictness for a public site.

`nyx.cors` answers cross-origin browser calls. Configure the allowed origins rather than reflecting the request origin.

## Passwords and users

`nyx.password` hashes and checks passwords. `nyx.auth` is the login session on top of that hash and the user row. The engine module follows the database: `nyx.auth_engine`, `nyx.auth_engine_pg`, or `nyx.auth_engine_mysql`.

A successful login writes the user id into the session. A later request reads it back through the auth helper. Logging out deletes that session row.

## JWT

`nyx.jwt` signs and checks HS256 tokens and honours `exp`, `nbf` and `iat`. The standard-library `nox.jwt` is also HS256 and does **not** check those time claims. If a token can expire, use `nyx.jwt`.

## The edge

Rate limiting keys off `HttpRequest.peer_addr` unless you have opted into forwarded headers. See [Configuration](/docs/configuration/) for `NYX_TRUST_X_FORWARDED_FOR` and `NYX_TRUSTED_PROXIES`. Trusting the header from the open internet lets any client pick their own address.
