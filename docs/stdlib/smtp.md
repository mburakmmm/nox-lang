# nox.smtp

An SMTP client for sending plain-text e-mail: connect, optionally upgrade with STARTTLS, authenticate and send.

```text
from nox.smtp import connect, send_mail, SmtpClient, SmtpError
```

**Capability:** `network`.

## One call

| Function | Description |
|---|---|
| `send_mail(host, port, use_tls, use_starttls, ehlo_domain, username, password, from_addr, to_addrs, subject, body)` | connects, greets, optionally upgrades, authenticates (when `username` is non-empty), sends one message and disconnects; raises `SmtpError` on any failure |

`use_tls` selects implicit TLS (typically port 465); `use_starttls` starts in plain text and upgrades (typically port 587). Pass `False` for both only for trusted local relays.

## `SmtpClient`

For finer control:

| Function / method | Description |
|---|---|
| `connect(host, port, use_tls)` | opens the connection and reads the server greeting; returns an `SmtpClient` |
| `ehlo(domain)` | introduces the client |
| `starttls()` | upgrades the connection to TLS |
| `auth_login(username, password)`, `auth_plain(username, password)` | authenticate with `AUTH LOGIN` / `AUTH PLAIN` |
| `send(from_addr, to_addrs, subject, body)` | sends one plain-text message to every address in `to_addrs` |
| `quit()` | ends the session politely |
| `close()` | closes the socket |

```nox
from nox.smtp import send_mail, SmtpError

def notify(address: str, text: str) -> bool:
    try:
        send_mail("smtp.example.com", 587, False, True, "client.example.com", "user", "app-password", "noreply@example.com", [address], "Hello", text)
        return True
    except SmtpError as e:
        return False
```

## Scope

Plain-text bodies only: no MIME multipart, attachments or `Date` header. Only `EHLO` (no `HELO` fallback) and the `AUTH LOGIN` / `AUTH PLAIN` mechanisms are implemented. All methods
are synchronous at the call site.

> **Credentials.** Do not hard-code passwords; read them from the environment ([`nox.os`](os.md)) or a secrets store.
