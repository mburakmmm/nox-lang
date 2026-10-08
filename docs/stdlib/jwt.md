# nox.jwt

JSON Web Tokens signed with HMAC-SHA-256 (`HS256`).

```text
import nox.jwt
from nox.jwt import JwtError
```

**Capability:** none registered (pure Nox over [`nox.crypto`](crypto.md), [`nox.base64`](base64.md) and [`nox.json`](json.md)); not on the freestanding allow-list.

## Functions

| Function | Description |
|---|---|
| `sign(payload_json, secret)` | returns `header.payload.signature` for the JSON text `payload_json`, signed with `secret` |
| `verify(token, secret)` | checks the signature (in constant time) and returns the payload JSON text; raises `JwtError` for a malformed token, a wrong algorithm or a bad signature |

The token is three Base64url parts separated by dots. `verify` does **not** interpret claims: it does not check `exp`, `nbf` or `aud` — parse the returned payload with
[`nox.json`](json.md) and enforce them yourself.

```nox
import nox.jwt
from nox.jwt import JwtError

tok: str = nox.jwt.sign("{\"sub\":\"ada\"}", "secret")
print(tok.count("."), nox.jwt.verify(tok, "secret"))
try:
    nox.jwt.verify(tok, "wrong-secret")
except JwtError as e:
    print("rejected")
```

```output
2 {"sub":"ada"}
rejected
```

## Notes

- Only `HS256` is implemented; tokens that declare another algorithm (including `none`) are rejected.
- Use a secret of at least 32 random bytes (`nox.crypto.secure_random_hex(32)`) and keep it out of source control.
