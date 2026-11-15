/* stdlib_perf2.nox'un C karşılığı (2.2 aşama 2; ölçüt C): aynı iş, aynı sağlama toplamı. clang -O2. toml ve unicode için C standart kütüphanesinde karşılık yok (satırlar yok).
 * Özetler macOS'ta CommonCrypto, Linux'ta OpenSSL (-lcrypto). */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <time.h>
#include <fnmatch.h>
#ifdef __APPLE__
#include <CommonCrypto/CommonDigest.h>
#include <CommonCrypto/CommonHMAC.h>
#else
#include <openssl/sha.h>
#include <openssl/md5.h>
#include <openssl/hmac.h>
#endif

static double now_ms(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec * 1e3 + t.tv_nsec / 1e6; }
static void report(const char *n, double t0, long long c) { printf("%s\t%f\t%lld\n", n, now_ms() - t0, c); }

/* ---- Deque: dizi + baş indeksi ---- */
static void deque(void) {
    double t = now_ms();
    int64_t *a = malloc(1000000 * sizeof *a); size_t head = 0, tail = 0;
    for (int64_t i = 0; i < 1000000; i++) a[tail++] = i;
    long long s = 0; while (head < tail) s += a[head++];
    free(a); report("deque_push_pop_1M", t, s);
}

/* ---- Heap: ikili min-yığın ---- */
static void heap(void) {
    double t = now_ms();
    int64_t *h = malloc(200000 * sizeof *h); size_t n = 0;
    for (int64_t i = 0; i < 200000; i++) {
        int64_t v = (i * 7919) % 100003; size_t k = n++;
        while (k > 0 && h[(k - 1) / 2] > v) { h[k] = h[(k - 1) / 2]; k = (k - 1) / 2; }
        h[k] = v;
    }
    long long s = 0;
    while (n > 0) {
        int64_t top = h[0], v = h[--n]; size_t k = 0;
        for (;;) { size_t c = 2 * k + 1; if (c >= n) break; if (c + 1 < n && h[c + 1] < h[c]) c++; if (h[c] >= v) break; h[k] = h[c]; k = c; }
        if (n > 0) h[k] = v;
        s += top % 7;
    }
    free(h); report("heap_push_pop_200k", t, s);
}

/* ---- Counter: açık adresli karma tablo (anahtar -> sayaç) ---- */
static void counter(void) {
    double t = now_ms();
    enum { CAP = 4096 };
    int64_t keys[CAP]; int64_t cnt[CAP]; char used[CAP] = {0}; int size = 0;
    for (int64_t i = 0; i < 500000; i++) {
        int64_t k = (i * 31) % 1009; size_t p = ((uint64_t)k * 0x9E3779B97F4A7C15ull) >> 52;
        while (used[p] && keys[p] != k) p = (p + 1) & (CAP - 1);
        if (!used[p]) { used[p] = 1; keys[p] = k; cnt[p] = 0; size++; }
        cnt[p]++;
    }
    size_t p = ((uint64_t)5 * 0x9E3779B97F4A7C15ull) >> 52; while (used[p] && keys[p] != 5) p = (p + 1) & (CAP - 1);
    report("counter_add_500k", t, (used[p] ? cnt[p] : 0) * 1000 + size);
}

/* ---- LRU: karma tablo + çift bağlı liste (dizilerle) ---- */
typedef struct { int64_t key, val; int prev, next; } LNode;
static void lru(void) {
    double t = now_ms();
    enum { CAP = 1000, HCAP = 4096 };
    LNode nodes[CAP + 1]; int table[HCAP]; for (int i = 0; i < HCAP; i++) table[i] = -1;
    int head = -1, tail = -1, count = 0, freelist = -1, nextfree = 0; long long s = 0;
    #define H(k) ((size_t)(((uint64_t)(k) * 0x9E3779B97F4A7C15ull) >> 52))
    for (int64_t i = 0; i < 300000; i++) {
        int64_t k = (i * 17) % 1500; if (i % 4 != 0) k = i % 300; size_t p = H(k); int found = -1;
        while (table[p] != -2 && table[p] != -1) { if (nodes[table[p]].key == k) { found = table[p]; break; } p = (p + 1) & (HCAP - 1); }
        if (found < 0) { /* tablo -1 = boş; -2 yok sayılır (silmede yeniden kurulur) */ }
        if (found >= 0) {
            s += nodes[found].val;
            if (tail != found) { /* sona taşı */
                LNode *n = &nodes[found];
                if (n->prev >= 0) nodes[n->prev].next = n->next; else head = n->next;
                if (n->next >= 0) nodes[n->next].prev = n->prev;
                n->prev = tail; n->next = -1; nodes[tail].next = found; tail = found;
            }
        } else {
            int id = freelist >= 0 ? freelist : nextfree++; if (freelist >= 0) freelist = nodes[id].next;
            nodes[id].key = k; nodes[id].val = i; nodes[id].prev = tail; nodes[id].next = -1;
            if (tail >= 0) nodes[tail].next = id; else head = id; tail = id; count++;
            size_t q = H(k); while (table[q] >= 0) q = (q + 1) & (HCAP - 1); table[q] = id;
            if (count > CAP) { /* en eskiyi at: tabloyu kaydırmalı silmeyle güncelle */
                int old = head; head = nodes[old].next; nodes[head].prev = -1; count--;
                size_t r = H(nodes[old].key); while (table[r] != old) r = (r + 1) & (HCAP - 1);
                size_t j = r; for (;;) { j = (j + 1) & (HCAP - 1); if (table[j] < 0) break; size_t home = H(nodes[table[j]].key);
                    if ((j > r && (home <= r || home > j)) || (j < r && (home <= r && home > j))) { table[r] = table[j]; r = j; } }
                table[r] = -1; nodes[old].next = freelist; freelist = old;
            }
        }
    }
    report("lru_get_put_300k", t, s);
}

/* ---- özetler ---- */
static void digests(void) {
    size_t n = 16 * 4096; char *data = malloc(n); for (size_t i = 0; i < 4096; i++) memcpy(data + i * 16, "abcdefghijklmnop", 16);
    double t = now_ms(); long long s = 0; unsigned char out[64];
    for (int i = 0; i < 16; i++) {
#ifdef __APPLE__
        CC_SHA512(data, (CC_LONG)n, out);
#else
        SHA512((unsigned char *)data, n, out);
#endif
        s += 128;
    }
    report("sha512_64KiB_x16", t, s);
    t = now_ms(); s = 0;
    for (int i = 0; i < 16; i++) {
#ifdef __APPLE__
        CC_SHA1(data, (CC_LONG)n, out); CC_MD5(data, (CC_LONG)n, out);
#else
        SHA1((unsigned char *)data, n, out); MD5((unsigned char *)data, n, out);
#endif
        s += 72;
    }
    report("sha1_md5_64KiB_x16", t, s);
    t = now_ms(); s = 0;
    for (int i = 0; i < 20000; i++) {
        char key[16], msg[32]; int kl = snprintf(key, sizeof key, "key%d", i % 10), ml = snprintf(msg, sizeof msg, "message-%d", i);
#ifdef __APPLE__
        CCHmac(kCCHmacAlgSHA256, key, kl, msg, ml, out);
#else
        unsigned int ol = 32; HMAC(EVP_sha256(), key, kl, (unsigned char *)msg, ml, out, &ol);
#endif
        s += 64;
    }
    report("hmac_sha256_20k", t, s); free(data);
}

/* ---- bigint: 3000! tabanı 1e9 ile hesaplanır, ondalık yazılır ---- */
static void bigint(void) {
    double t = now_ms(); enum { MAXL = 2000 }; uint32_t *d = calloc(MAXL, 4); int len = 1; d[0] = 1;
    for (uint32_t m = 2; m <= 3000; m++) { uint64_t carry = 0; for (int i = 0; i < len; i++) { uint64_t v = (uint64_t)d[i] * m + carry; d[i] = (uint32_t)(v % 1000000000u); carry = v / 1000000000u; } while (carry) { d[len++] = (uint32_t)(carry % 1000000000u); carry /= 1000000000u; } }
    char *buf = malloc(len * 9 + 2); int pos = sprintf(buf, "%u", d[len - 1]); for (int i = len - 2; i >= 0; i--) pos += sprintf(buf + pos, "%09u", d[i]);
    report("bigint_factorial_3000_str", t, pos); free(buf); free(d);
}

static void fnm(void) {
    double t = now_ms(); long long s = 0; char name[32];
    for (int i = 0; i < 200000; i++) { snprintf(name, sizeof name, "file%d.txt", i); if (fnmatch("file*9.t?t", name, 0) == 0) s++; }
    report("fnmatch_200k", t, s);
}

static void timefmt(void) {
    double t = now_ms(); long long s = 0; char buf[32];
    for (int64_t i = 0; i < 100000; i++) { time_t sec = (time_t)((1700000000000LL + i * 86400000LL) / 1000); struct tm tm; gmtime_r(&sec, &tm); s += (long long)strftime(buf, sizeof buf, "%Y-%m-%d %H:%M:%S", &tm); }
    report("time_from_epoch_to_str_100k", t, s);
}

static void fsio(void) {
    size_t n = 16 * 65536; char *body = malloc(n); for (size_t i = 0; i < 65536; i++) memcpy(body + i * 16, "0123456789abcdef", 16);
    char *rd = malloc(n); double t = now_ms(); long long s = 0;
    for (int i = 0; i < 8; i++) { FILE *f = fopen("/tmp/nox_stdlib_perf2.bin", "wb"); fwrite(body, 1, n, f); fclose(f); f = fopen("/tmp/nox_stdlib_perf2.bin", "rb"); s += (long long)fread(rd, 1, n, f); fclose(f); }
    report("fs_write_read_1MiB_x8", t, s); free(body); free(rd);
}

int main(void) { deque(); heap(); counter(); lru(); digests(); bigint(); fnm(); timefmt(); fsio(); return 0; }
