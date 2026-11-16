/* stdlib_perf.nox'un C karşılığı (2.2 aşama 2; ölçüt C): aynı iş, aynı sağlama toplamı. clang -O2 (-lz). JSON, regex, url ve random/uuid için C standart kütüphanesinde karşılık yok (satırlar yok);
 * gzip sıkıştırma çıktı uzunluğu uygulamaya bağlı olduğundan C'de yalnızca açma ölçülür. Özetler macOS'ta CommonCrypto, Linux'ta OpenSSL (-lcrypto). */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <ctype.h>
#include <time.h>
#include <zlib.h>
#ifdef __APPLE__
#include <CommonCrypto/CommonDigest.h>
#else
#include <openssl/sha.h>
#endif

static double now_ms(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec * 1e3 + t.tv_nsec / 1e6; }
static void report(const char *n, double t0, long long c) { printf("%s\t%f\t%lld\n", n, now_ms() - t0, c); }

static char *src; static size_t srclen;
static volatile unsigned char sink; /* çıktıları gözlemlenebilir kılar: aksi halde clang kullanılmayan çıktıyı üreten döngüleri siler ve C sütunu gerçek dışı hızlı olur */

/* El yazımı tamsayı biçimlendirme (sprintf'in ek yükü olmadan; ölçüt C adil olmalı). */
static int fmt_i64(char *o, long long v) {
    char tmp[24]; int n = 0, l = 0; unsigned long long u = v < 0 ? 0ull - (unsigned long long)v : (unsigned long long)v;
    if (v < 0) o[l++] = '-';
    do { tmp[n++] = (char)('0' + u % 10); u /= 10; } while (u);
    while (n) o[l++] = tmp[--n];
    return l;
}

static void strings(void) {
    double t = now_ms();
    size_t cap = 200000 * 8; src = malloc(cap); size_t n = 0;
    for (int i = 0; i < 200000; i++) { if (i) src[n++] = ','; n += (size_t)fmt_i64(src + n, i); }
    src[n] = 0; srclen = n; report("str_build_join_200k", t, (long long)n);

    t = now_ms(); long long tot = 0;
    for (int r = 0; r < 5; r++) { /* Nox'un list[str] döndürmesine karşılık: her parça ayrı ayrılır (strndup) ve bir diziye konur. */
        char **pieces = malloc(200001 * sizeof *pieces); long long np = 0; size_t start = 0;
        for (size_t i = 0; i <= n; i++) if (i == n || src[i] == ',') { pieces[np++] = strndup(src + start, i - start); start = i + 1; }
        sink ^= (unsigned char)pieces[np / 2][0]; tot += np; for (long long k = 0; k < np; k++) free(pieces[k]); free(pieces);
    }
    report("str_split_200k_x5", t, tot);

    t = now_ms(); tot = 0;
    for (int r = 0; r < 5; r++) {
        char *o = malloc(n * 3 + 1); size_t m = 0;
        for (size_t i = 0; i < n; i++) { if (src[i] == '1') { memcpy(o + m, "xyz", 3); m += 3; } else o[m++] = src[i]; }
        sink ^= (unsigned char)o[m / 2]; tot += (long long)m; free(o);
    }
    report("str_replace_x5", t, tot);

    t = now_ms(); long long cnt = 0; char buf[64];
    for (int pos = 0; pos < 300000; pos++) { memcpy(buf, "item", 4); int l = 4 + fmt_i64(buf + 4, pos); memcpy(buf + l, "tail", 5); char *p = strchr(buf, '9'); if (p) cnt += p - buf; }
    report("str_find_300k_small", t, cnt);

    t = now_ms(); tot = 0;
    for (int r = 0; r < 20; r++) {
        char *u = malloc(n + 5), *l = malloc(n + 5), *w = malloc(n + 5);
        for (size_t i = 0; i < n; i++) { u[i] = (char)toupper((unsigned char)src[i]); l[i] = (char)tolower((unsigned char)src[i]); }
        w[0] = ' '; w[1] = ' '; memcpy(w + 2, src, n); w[n + 2] = ' '; w[n + 3] = ' '; size_t b = 0, e = n + 4; while (b < e && w[b] == ' ') b++; while (e > b && w[e - 1] == ' ') e--;
        sink ^= (unsigned char)(u[n / 2] ^ l[n / 3] ^ w[b + (e - b) / 2]); tot += (long long)n + (long long)n + (long long)(e - b); free(u); free(l); free(w);
    }
    report("str_upper_lower_trim_x20", t, tot);

    t = now_ms(); size_t acap = 16, alen = 0; char *acc = malloc(acap);
    for (int i = 0; i < 1000000; i++) { if (alen + 1 > acap) { acap *= 2; acc = realloc(acc, acap); } acc[alen++] = 'x'; }
    sink ^= (unsigned char)acc[alen / 2]; report("str_concat_1M", t, (long long)alen); free(acc);

    t = now_ms(); tot = 0;
    for (int i = 0; i < 300000; i++) { int l = fmt_i64(buf, i); buf[l++] = ':'; l += fmt_i64(buf + l, (long long)i * 2); tot += l; sink ^= (unsigned char)buf[l - 1]; }
    report("fstring_300k", t, tot);
}

static const char B64[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
static void codecs(void) {
    const char *phrase = "The quick brown fox jumps over the lazy dog. "; size_t pl = strlen(phrase), n = pl * 90000;
    char *blob = malloc(n + 1); for (int i = 0; i < 90000; i++) memcpy(blob + i * pl, phrase, pl); blob[n] = 0;
    double t = now_ms(); size_t el = (n + 2) / 3 * 4; char *enc = malloc(el + 1); size_t o = 0;
    for (size_t i = 0; i < n; i += 3) {
        uint32_t v = (uint32_t)(unsigned char)blob[i] << 16; if (i + 1 < n) v |= (uint32_t)(unsigned char)blob[i + 1] << 8; if (i + 2 < n) v |= (unsigned char)blob[i + 2];
        enc[o++] = B64[v >> 18]; enc[o++] = B64[(v >> 12) & 63]; enc[o++] = i + 1 < n ? B64[(v >> 6) & 63] : '='; enc[o++] = i + 2 < n ? B64[v & 63] : '=';
    }
    sink ^= (unsigned char)enc[o / 2]; report("base64_encode_4MB", t, (long long)o);
    int8_t rev[256]; memset(rev, -1, sizeof rev); for (int i = 0; i < 64; i++) rev[(unsigned char)B64[i]] = (int8_t)i;
    t = now_ms(); char *dec = malloc(n + 4); size_t d = 0;
    for (size_t i = 0; i + 3 < o + 0; i += 4) {
        uint32_t v = ((uint32_t)rev[(unsigned char)enc[i]] << 18) | ((uint32_t)rev[(unsigned char)enc[i + 1]] << 12);
        dec[d++] = (char)(v >> 16);
        if (enc[i + 2] != '=') { v |= (uint32_t)rev[(unsigned char)enc[i + 2]] << 6; dec[d++] = (char)(v >> 8); if (enc[i + 3] != '=') { v |= (uint32_t)rev[(unsigned char)enc[i + 3]]; dec[d++] = (char)v; } }
    }
    sink ^= (unsigned char)dec[d / 2]; report("base64_decode_4MB", t, (long long)d);
    char *chunk = malloc(65536); for (int i = 0; i < 8192; i++) memcpy(chunk + i * 8, "abcdefgh", 8);
    t = now_ms(); long long tot = 0; unsigned char out[32];
    for (int i = 0; i < 128; i++) {
#ifdef __APPLE__
        CC_SHA256(chunk, 65536, out);
#else
        SHA256((unsigned char *)chunk, 65536, out);
#endif
        tot += 64;
    }
    report("sha256_64KiB_x128", t, tot);
    uLongf zl = compressBound((uLong)n); unsigned char *z = malloc(zl); compress2(z, &zl, (const Bytef *)blob, (uLong)n, 6);
    t = now_ms(); uLongf ul = (uLongf)n; unsigned char *un = malloc(n); uncompress(un, &ul, z, zl);
    report("gzip_decompress_4MB", t, (long long)ul);
    free(blob); free(enc); free(dec); free(chunk); free(z); free(un);
}

static void csv_path(void) {
    size_t cap = 50000 * 48; char *txt = malloc(cap); size_t n = 0;
    for (int i = 0; i < 50000; i++) { if (i) txt[n++] = '\n'; n += (size_t)sprintf(txt + n, "%d,name%d,\"quoted, text\",%d,end", i, i, i * 3); }
    double t = now_ms(); long long rows = 1; int inq = 0;
    for (size_t i = 0; i < n; i++) { char c = txt[i]; if (c == '"') inq = !inq; else if (c == '\n' && !inq) rows++; }
    report("csv_parse_50k_rows", t, rows); free(txt);
    t = now_ms(); long long tot = 0; char buf[96];
    for (int i = 0; i < 300000; i++) { memcpy(buf, "/usr/local/lib/file", 19); int l = 19 + fmt_i64(buf + 19, i); memcpy(buf + l, ".txt", 5); const char *b = strrchr(buf, '/'); tot += (long long)strlen(b + 1); }
    report("path_join_basename_300k", t, tot);
}

static int cmp_i64(const void *a, const void *b) { int64_t x = *(const int64_t *)a, y = *(const int64_t *)b; return (x > y) - (x < y); }
static int cmp_str(const void *a, const void *b) { return strcmp(*(char *const *)a, *(char *const *)b); }
static void collections(void) {
    double t = now_ms(); enum { SC = 1 << 19 }; int32_t *tab = malloc(SC * sizeof *tab); for (int i = 0; i < SC; i++) tab[i] = -1; int size = 0;
    for (int i = 0; i < 200000; i++) { int32_t v = i % 150000; size_t p = ((uint32_t)v * 2654435761u) >> 13; while (tab[p] != -1 && tab[p] != v) p = (p + 1) & (SC - 1); if (tab[p] == -1) { tab[p] = v; size++; } }
    long long hits = 0;
    for (int i = 0; i < 200000; i++) { size_t p = ((uint32_t)i * 2654435761u) >> 13; while (tab[p] != -1 && tab[p] != i) p = (p + 1) & (SC - 1); if (tab[p] == i) hits++; }
    report("set_add_contains_200k", t, hits + size); free(tab);

    t = now_ms(); enum { DC = 1 << 20 }; char **keys = calloc(DC, sizeof *keys); int64_t *vals = malloc(DC * sizeof *vals); char kb[32];
    for (int i = 0; i < 300000; i++) { memcpy(kb, "key", 3); int l = 3 + fmt_i64(kb + 3, i); kb[l] = 0; uint64_t h = 1469598103934665603ull; for (int k = 0; k < l; k++) { h ^= (unsigned char)kb[k]; h *= 1099511628211ull; } size_t p = h & (DC - 1); while (keys[p]) p = (p + 1) & (DC - 1); keys[p] = strdup(kb); vals[p] = i; }
    long long tot = 0;
    for (int i = 0; i < 300000; i++) { memcpy(kb, "key", 3); int l = 3 + fmt_i64(kb + 3, i); kb[l] = 0; uint64_t h = 1469598103934665603ull; for (int k = 0; k < l; k++) { h ^= (unsigned char)kb[k]; h *= 1099511628211ull; } size_t p = h & (DC - 1); while (strcmp(keys[p], kb) != 0) p = (p + 1) & (DC - 1); tot += vals[p]; }
    report("dict_str_insert_lookup_300k", t, tot % 1000003);
    for (int i = 0; i < DC; i++) free(keys[i]); free(keys); free(vals);

    t = now_ms(); int64_t *nums = malloc(1000000 * sizeof *nums); int64_t x = 12345;
    for (int i = 0; i < 1000000; i++) { x = (x * 1103515245 + 12345) % 2147483648; nums[i] = x; }
    qsort(nums, 1000000, sizeof *nums, cmp_i64);
    report("sort_1M_ints", t, nums[0] + nums[999999] % 1000003); free(nums);

    t = now_ms(); char **strs = malloc(200000 * sizeof *strs);
    for (int i = 0; i < 200000; i++) { x = (x * 1103515245 + 12345) % 2147483648; char b[32]; b[0] = 's'; int bl = 1 + fmt_i64(b + 1, x); b[bl] = 0; strs[i] = strdup(b); }
    qsort(strs, 200000, sizeof *strs, cmp_str);
    report("sort_200k_strs", t, (long long)(strlen(strs[0]) + strlen(strs[199999]))); for (int i = 0; i < 200000; i++) free(strs[i]); free(strs);
}

int main(void) { strings(); codecs(); csv_path(); collections(); return 0; }
