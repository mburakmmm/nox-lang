# Jobs, mail and the rest

These modules are part of the same package. They are not plugins you discover at runtime.

## Jobs

`nyx.job` is a database-backed queue. Enqueue from a request. A separate process runs the work:

```sh
./bin/nyx jobs work
```

Handler failures are caught with `except (ModelError, MailerError, …) as e` and the message is passed to `fail()`. The job row records the failure. Do not let an exception escape the worker and kill the process.

Run the worker as its own process, with the same `DATABASE_URL` as the web process. Do not start it inside the request.

## Mail

`nyx.mailer` sends through `nox.smtp`.

- Default is immediate TLS on port 465 (`NYX_MAIL_SMTP_PORT`).
- `NYX_MAIL_SMTP_STARTTLS=1` opens a plain connection and upgrades, which is what port 587 expects.
- HTML mail is built with `to_eml`. `nox.smtp.send` itself is plain text, so the HTML message is the MIME document Nyx assembles.

SMTP failures surface as the standard-library text, for example `smtp: TLS upgrade failed: …` or an unexpected SMTP code. Since Nox 2.0.1 those messages are English.

## Storage and cache

`nyx.storage` reads and writes files for uploads. Keep the directory outside the view folder so a request cannot fetch another user’s upload by guessing a template path.

`nyx.cache` is an application cache. Remember the worker rule from [Boot and dispatch](/docs/application/): an in-memory table is per worker. A value that must be visible to every process belongs in the database or in a file the cache module is configured to share.

## Locale

`nyx.i18n` looks up strings for `NYX_LOCALE`. The lookup happens when you render, not when you boot, so a request can select a locale and pass it through the template context.

## Cable

`nyx.cable` is the websocket entry for server-pushed updates. It sits on Nox’s websocket support. A frame handler is still a Nox function: it must not touch another worker’s module globals and expect them to be the same objects.

## Tests

`nyx.testing` builds a request and runs it through `dispatch` without opening a port. That is how you assert a status code and a body. It does not replace a migration against a real `DATABASE_URL` when the bug is in SQL.
