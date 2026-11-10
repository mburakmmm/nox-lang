# nox.redis

A Redis client (RESP2) written in Zig: no `hiredis` needed. Plain TCP or TLS from the first byte, `AUTH` (password or user + password), `SELECT`, byte-safe commands
and replies, Streams and consumer groups, a script cache with `NOSCRIPT` recovery, and reconnecting.

```text
import nox.redis
from nox.redis import Client, Reply, RedisError
```

**Capability:** `network`.

## Connecting

`connect(host, port=6379, tls=False, username="", password="", db=0) -> Client`

- `tls=True` starts TLS immediately (a `rediss://`-style endpoint); the certificate and host name are checked against the system CA store.
- A non-empty `password` sends `AUTH` (`AUTH username password` when `username` is given); `db > 0` sends `SELECT`.
- Failure raises `RedisError` with `kind == "connection"`.

## Commands

| Member | Description |
|---|---|
| `command(args: list[str]) -> Reply` | any Redis command; the arguments are binary-safe (NUL bytes and non-UTF-8 bytes are sent as is) |
| `ping()`, `get(key) -> str \| None`, `set(key, value)`, `set_ex(key, value, seconds)`, `delete(key)`, `incr(key)`, `expire(key, seconds)` | common commands |
| `xadd(stream, fields, maxlen=0)` | `XADD` (approximate `MAXLEN ~` when `maxlen > 0`); returns the new entry id |
| `xgroup_create(stream, group, start_id="$", mkstream=True)` / `xgroup_ensure(...)` | `XGROUP CREATE`; `xgroup_ensure` returns `False` instead of raising when the group exists (`BUSYGROUP`) |
| `xreadgroup(group, consumer, stream, id=">", count=1, block_ms=-1)` | `XREADGROUP`; `block_ms < 0` does not block, `0` blocks forever. A timeout returns a nil `Reply` |
| `xautoclaim(stream, group, consumer, min_idle_ms, start="0-0", count=100)` | `XAUTOCLAIM`: `[next-id, [[id, [field, value, ...]], ...], [deleted ids]]` |
| `xack(stream, group, ids)` | `XACK`; returns how many entries were acknowledged |
| `script_load(script)`, `eval_cached(script, keys, args)` | `SCRIPT LOAD` + `EVALSHA`, caching the sha per connection; a `NOSCRIPT` reply (server restart, `SCRIPT FLUSH`) reloads the script and retries once |
| `is_ok()`, `reconnect()`, `close()` | connection management |

## Replies

A `Reply` is a tree: `kind()` is `0` nil, `1` simple string, `2` error, `3` integer, `4` bulk string, `5` array. `as_str()`, `as_int()`, `len()`, `at(i)` read it;
`to_str_list()` turns an array of strings into a `list[str]`. Bulk strings are byte-exact. A child returned by `at(i)` borrows the parent's memory and keeps the parent alive.

```text
r: Reply = client.xreadgroup("workers", "w1", "jobs", ">", 10, 2000)
if not r.is_nil():
    entry: Reply = r.at(0).at(1).at(0)          # first entry of the first stream
    print(entry.at(0).as_str(), entry.at(1).to_str_list())
```

## Errors

`RedisError` has `kind` and `code`:

- `kind == "server"`: the server answered with an error (`-WRONGTYPE ...`). `code` is its first word (`"WRONGTYPE"`, `"NOSCRIPT"`, `"BUSYGROUP"`, `"NOAUTH"`, `"NOPERM"`); helpers `is_wrongtype()`, `is_noscript()`, `is_busygroup()`.
- `kind == "connection"` (`is_connection_error()`): connecting failed, or the connection broke. The client is closed afterwards: call `reconnect()` (it repeats `AUTH`/`SELECT` and clears the script cache).
  A command interrupted by a broken connection may or may not have run on the server; whether to retry is up to the caller.

## Notes

- There is no read timeout: blocking commands such as `XREADGROUP ... BLOCK` legitimately wait. Inside a task only that task waits.
- RESP2 only; no pub/sub push messages, no pipelining and no cluster redirection (`MOVED`/`ASK` surface as `RedisError`).
- Verified against real `redis-server` for commands, binary payloads, Streams, scripts, `AUTH`/ACL and reconnecting. TLS reuses the client of [`nox.tls`](tls.md) (an untrusted
  certificate is rejected); a successful handshake with a publicly trusted server certificate has not been exercised against a Redis in this repository's tests.
