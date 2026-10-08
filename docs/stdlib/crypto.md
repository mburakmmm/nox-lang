# nox.crypto

Hashes, message authentication, secure randomness and password hashing — built on the Zig standard library's cryptography, with no external dependency.

```text
import nox.crypto
from nox.crypto import CryptoError
```

**Capability:** none for the module; functions that need operating-system entropy — `secure_random_hex`, `argon2_hash`, `bcrypt_hash`, `scrypt_hash` (which generate a random salt) — are marked
`entropy` and are unavailable in freestanding profiles. Hashing and verification of existing data are pure.

## Hashes

All return a lowercase hexadecimal string of the digest of the UTF-8 bytes of `data`.

| Function | Digest |
|---|---|
| `sha256(data)` | SHA-256 (64 hex characters) |
| `sha512(data)` | SHA-512 (128 hex characters) |
| `sha1(data)` | SHA-1 — **broken for security** (practical collisions exist); only for legacy interoperability |

## Message authentication and comparison

| Function | Description |
|---|---|
| `hmac_sha256(key, data)` | HMAC-SHA-256 as hex |
| `constant_time_eq(a, b)` | equality that takes time independent of where the strings differ — use it to compare secrets, MACs and tokens |

## Randomness

| Function | Description |
|---|---|
| `secure_random_hex(n_bytes)` | `n_bytes` cryptographically secure random bytes as `2 * n_bytes` hex characters |

Use this (never [`nox.random`](random.md)) for session ids, tokens, salts and keys.

## Password hashing

Each scheme has a `*_hash(password)` that generates a random salt and returns a self-describing string, and a `*_verify(hash, password)` that checks a candidate:

| Hash | Verify | Notes |
|---|---|---|
| `argon2_hash(password)` | `argon2_verify(hash, password)` | Argon2id, the recommended default |
| `bcrypt_hash(password)` | `bcrypt_verify(hash, password)` | bcrypt |
| `scrypt_hash(password)` | `scrypt_verify(hash, password)` | scrypt |

Store the returned string as is. Verification is constant-time with respect to the password. Hashing is deliberately slow (tens of milliseconds); do not call it in a hot loop.

```nox
import nox.crypto

print(nox.crypto.sha256("abc"))
print(nox.crypto.sha1("abc"))
print(nox.crypto.sha512("abc")[0:16])
print(nox.crypto.hmac_sha256("key", "data"))
print(nox.crypto.constant_time_eq("a", "a"), nox.crypto.constant_time_eq("a", "b"), len(nox.crypto.secure_random_hex(8)))
h: str = nox.crypto.argon2_hash("hunter2")
print(nox.crypto.argon2_verify(h, "hunter2"), nox.crypto.argon2_verify(h, "wrong"), h.startswith("$argon2id$"))
```

```output
ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad
a9993e364706816aba3e25717850c26c9cd0d89d
ddaf35a193617aba
5031fe3d989c6d1537a013fa6e739da23463fdaec3b70137d828e36ace221bd0
True False 16
True False True
```

## Notes

- `nox.crypto` offers primitives, not protocols: there is no encryption cipher, signature scheme or TLS here (TLS is [`nox.tls`](tls.md)); JSON Web Tokens are [`nox.jwt`](jwt.md).
- Strings are hashed as UTF-8 bytes; for binary data build the string from bytes first.
