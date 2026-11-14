/* 2.2 aşama 8: `nox.xxhash` — XXH32/XXH64/XXH3-64/XXH3-128. Şifreleme amaçlı DEĞİL. 64 bit sonuçlar Nox `int`e bit düzeniyle aktarılır. */
#include <stdio.h>
#define XXH_STATIC_LINKING_ONLY
#include "nxc_common.h"
#include "xxhash.h"

int64_t nxc_xxhash_available(void) { return 1; }
int64_t nxc_xxh32(const uint8_t *s, int64_t seed) { return (int64_t)XXH32(s, nxc_slen(s), (uint32_t)(uint64_t)seed); }
int64_t nxc_xxh64(const uint8_t *s, int64_t seed) { return (int64_t)XXH64(s, nxc_slen(s), (uint64_t)seed); }
int64_t nxc_xxh3_64(const uint8_t *s, int64_t seed) { return (int64_t)XXH3_64bits_withSeed(s, nxc_slen(s), (uint64_t)seed); }

static void *hex64(void *rt, uint64_t v) {
    char b[17];
    static const char H[] = "0123456789abcdef";
    for (int i = 15; i >= 0; i--) { b[i] = H[v & 15]; v >>= 4; }
    return nox_str_from_bytes_c(rt, (const uint8_t *)b, 16);
}
void *nxc_xxh64_hex(void *rt, const uint8_t *s, int64_t seed) { return hex64(rt, XXH64(s, nxc_slen(s), (uint64_t)seed)); }
void *nxc_xxh3_64_hex(void *rt, const uint8_t *s, int64_t seed) { return hex64(rt, XXH3_64bits_withSeed(s, nxc_slen(s), (uint64_t)seed)); }

/* 128 bit: 32 küçük-harf onaltılık karakter (kanonik/büyük-endian sıra). */
void *nxc_xxh3_128_hex(void *rt, const uint8_t *s, int64_t seed) {
    XXH128_hash_t h = XXH3_128bits_withSeed(s, nxc_slen(s), (uint64_t)seed);
    XXH128_canonical_t c;
    XXH128_canonicalFromHash(&c, h);
    static const char H[] = "0123456789abcdef";
    char b[32];
    for (int i = 0; i < 16; i++) { b[2 * i] = H[c.digest[i] >> 4]; b[2 * i + 1] = H[c.digest[i] & 15]; }
    return nox_str_from_bytes_c(rt, (const uint8_t *)b, 32);
}
