# nox.transfer

Stream HTTP bodies to and from files without holding them in memory.

```text
import nox.transfer
```

**Capability:** `network` and `filesystem` (unavailable in freestanding profiles). It is built on [`nox.http`](http.md)'s streams and [`nox.fs`](fs.md)'s file handles; use those
directly when you need control over the chunks. The security note of `nox.fs` applies to `path`.

| Function | Description |
|---|---|
| `download_to_file(url, path, headers, timeout_ms=0)` | downloads `url` into `path` and returns the HTTP status |
| `upload_file(method, url, path, headers, timeout_ms=0)` | uploads the file at `path` as the request body (`POST`, `PUT` or `PATCH`) and returns the `HttpResponse` |

Memory use is bounded by a 64 KiB chunk, so the file can be many gigabytes.

- **`download_to_file`** writes to `path + ".nox-part"` and renames it over `path` only after a **2xx** response arrived completely. For any other status, or when the transfer fails (connection error,
  timeout, truncated body), `path` is left untouched, the temporary file is removed, and the status is returned (or `HttpError` / `HttpTimeoutError` raised for a failure).
- **`upload_file`** sends a fixed `Content-Length` taken from the file size, reading the file in chunks. The response body is read into memory; for a large response open a stream with
  `nox.http.stream_upload` yourself. A file that shrinks while it is being sent raises `HttpError`.
- `timeout_ms > 0` is the idle timeout per operation described in [`nox.http`](http.md#streaming-large-bodies).

```text
import nox.transfer
from nox.http import HttpResponse

status: int = nox.transfer.download_to_file("https://example.com/big.iso", "big.iso", {})
if status != 200:
    print("download failed:", status)

r: HttpResponse = nox.transfer.upload_file("PUT", "https://example.com/files/big.iso", "big.iso", {"Content-Type": "application/octet-stream"})
print(r.status)
```
