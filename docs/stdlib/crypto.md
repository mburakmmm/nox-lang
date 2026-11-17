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
| `sha384(data)` | SHA-384 (96 hex characters) |
| `sha3_256(data)`, `sha3_512(data)` | SHA-3 (64 / 128 hex characters) |
| `blake3(data)` | BLAKE3 with a 32-byte output (64 hex characters) |
| `md5(data)` | MD5 (32 hex characters). **Not collision resistant**: use it only for checksums and legacy compatibility, never for security |
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

## Authenticated encryption (AEAD)

| Function | Description |
|---|---|
| `aead_seal(key_hex, nonce_hex, plaintext, aad="", algorithm="chacha20-poly1305") -> str` | encrypts and authenticates; returns `hex(ciphertext \|\| 16-byte tag)` |
| `aead_open(key_hex, nonce_hex, sealed_hex, aad="", algorithm="chacha20-poly1305") -> str` | verifies and decrypts; raises `CryptoError` for a wrong key, nonce, `aad`, a modified or truncated seal |

Algorithms (Zig `std.crypto.aead`): `"chacha20-poly1305"` (32-byte key, 12-byte nonce), `"xchacha20-poly1305"` (32-byte key, **24-byte** nonce, safe to pick at random), `"aes-256-gcm"` (32, 12), `"aes-128-gcm"` (16, 12).
Keys and nonces are hex strings (`secure_random_hex(32)` makes a key, `secure_random_hex(12)` a nonce). **Never reuse a nonce with the same key.** `aad` is authenticated but not encrypted (use it to bind a seal to its context:
a user id, a record name). `plaintext`, `aad` and the opened result are `str` values, so they hold valid UTF-8; encode binary data (hex/base64) before sealing it.
Binary data: `aead_seal_bytes(key, nonce, plaintext, aad, algorithm=...)` and `aead_open_bytes(key, nonce, sealed, aad, algorithm=...)` take and return `Buffer`s (`nox.buffer`), so keys, nonces and plaintext need no hex and the plaintext may hold any byte, NUL included. The seal is the same `ciphertext || tag` as the `str` functions produce, so the two families open each other's output.
The known-answer tests are RFC 8439 §2.8.2 (ChaCha20-Poly1305) and McGrew–Viega test case 16 (AES-256-GCM).

## Notes

- `nox.crypto` offers primitives, not protocols: there is no encryption cipher, signature scheme or TLS here (TLS is [`nox.tls`](tls.md)); JSON Web Tokens are [`nox.jwt`](jwt.md).
- Strings are hashed as UTF-8 bytes; for binary data build the string from bytes first.
