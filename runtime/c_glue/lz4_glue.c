/* 2.2 aşama 8: `nox.lz4` — LZ4 çerçeve (frame) API'sine ince sarmalayıcı; Nox `str` değerleriyle doğrudan çalışır. Gerçek başlıklarla derlenir. */
#include <stdlib.h>
#include "nxc_common.h"
#include "lz4frame.h"

static NXC_TLS int g_ok = 1;
int64_t nxc_lz4_last_ok(void) { return g_ok; }
int64_t nxc_lz4_available(void) { return 1; }

/* `level`: 0 = hızlı varsayılan; 1..12 = HC. Çerçeve içerik boyutu ve içerik sağlaması taşır. Hata → boş str + last_ok 0. */
void *nxc_lz4_compress_str(void *rt, const uint8_t *data, int64_t level) {
    size_t n = nxc_slen(data);
    if (level < 0) level = 0;
    if (level > 12) level = 12;
    LZ4F_preferences_t p;
    memset(&p, 0, sizeof p);
    p.compressionLevel = (int)level;
    p.frameInfo.contentSize = n;
    p.frameInfo.contentChecksumFlag = LZ4F_contentChecksumEnabled;
    size_t cap = LZ4F_compressFrameBound(n, &p) + 64;
    uint8_t *dst = (uint8_t *)malloc(cap);
    if (!dst) { g_ok = 0; return nox_str_from_bytes_c(rt, NULL, 0); }
    size_t r = LZ4F_compressFrame(dst, cap, data, n, &p);
    if (LZ4F_isError(r)) { free(dst); g_ok = 0; return nox_str_from_bytes_c(rt, NULL, 0); }
    void *out = nox_str_from_bytes_c(rt, dst, r);
    free(dst);
    g_ok = 1;
    return out;
}

#define NXC_LZ4_LIMIT ((size_t)1 << 30)

void *nxc_lz4_decompress_str(void *rt, const uint8_t *data) {
    size_t n = nxc_slen(data);
    LZ4F_dctx *ctx = NULL;
    g_ok = 0;
    if (LZ4F_isError(LZ4F_createDecompressionContext(&ctx, LZ4F_VERSION))) return nox_str_from_bytes_c(rt, NULL, 0);
    /* Başlığı önce oku: içerik boyutu biliniyorsa çıktı tamponu tek seferde doğru boyutta ayrılır. */
    LZ4F_frameInfo_t fi;
    memset(&fi, 0, sizeof fi);
    size_t pos = n;
    size_t gi = LZ4F_getFrameInfo(ctx, &fi, data, &pos);
    if (LZ4F_isError(gi)) { LZ4F_freeDecompressionContext(ctx); return nox_str_from_bytes_c(rt, NULL, 0); }
    size_t cap = n * 4 + 4096, len = 0;
    if (fi.contentSize > 0 && fi.contentSize <= NXC_LZ4_LIMIT) cap = (size_t)fi.contentSize + 65536 + 64;
    uint8_t *buf = (uint8_t *)malloc(cap);
    if (!buf) { LZ4F_freeDecompressionContext(ctx); return nox_str_from_bytes_c(rt, NULL, 0); }
    int rc = 0;
    size_t hint = 1;
    while (pos < n || hint != 0) {
        if (pos >= n && hint != 0) { rc = 1; break; } /* girdi bitti ama çerçeve tamamlanmadı */
        if (cap - len < 65536) {
            size_t ncap = cap * 2;
            if (ncap <= cap || ncap > NXC_LZ4_LIMIT + 65536) { rc = 3; break; }
            uint8_t *nb = (uint8_t *)realloc(buf, ncap);
            if (!nb) { rc = 2; break; }
            buf = nb; cap = ncap;
        }
        size_t dsz = cap - len, ssz = n - pos;
        hint = LZ4F_decompress(ctx, buf + len, &dsz, data + pos, &ssz, NULL);
        if (LZ4F_isError(hint)) { rc = 1; break; }
        len += dsz; pos += ssz;
        if (len > NXC_LZ4_LIMIT) { rc = 3; break; }
        if (hint == 0) break; /* çerçeve tamam */
        if (dsz == 0 && ssz == 0) { rc = 1; break; }
    }
    LZ4F_freeDecompressionContext(ctx);
    if (rc == 0 && pos != n) rc = 1; /* çerçeveden sonra artık baytlar */
    if (rc != 0) { free(buf); return nox_str_from_bytes_c(rt, NULL, 0); }
    void *out = nox_str_from_bytes_c(rt, buf, len);
    free(buf);
    g_ok = 1;
    return out;
}
