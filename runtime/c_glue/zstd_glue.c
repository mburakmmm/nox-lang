/* 2.2 aşama 8: `nox.zstd.compress` — zstd tek atımlık sıkıştırma; pencere `windowLog <= 23` (8 MiB), böylece `nox.zstd.decompress` (Zig) çıktıyı açabilir. */
#include <stdlib.h>
#include "nxc_common.h"
#include "zstd.h"

static NXC_TLS int g_ok = 1;
int64_t nxc_zstd_last_ok(void) { return g_ok; }
int64_t nxc_zstd_available(void) { return 1; }

/* `level` [-131072, 19]. Çerçeve içerik boyutu ve sağlama taşır. Hata → boş str + last_ok 0. */
void *nxc_zstd_compress_str(void *rt, const uint8_t *data, int64_t level) {
    size_t n = nxc_slen(data);
    if (level > 19) level = 19;
    if (level < ZSTD_minCLevel()) level = ZSTD_minCLevel();
    size_t cap = ZSTD_compressBound(n);
    uint8_t *dst = (uint8_t *)malloc(cap);
    ZSTD_CCtx *c = ZSTD_createCCtx();
    if (!dst || !c) { free(dst); if (c) ZSTD_freeCCtx(c); g_ok = 0; return nox_str_from_bytes_c(rt, NULL, 0); }
    ZSTD_CCtx_setParameter(c, ZSTD_c_compressionLevel, (int)level);
    ZSTD_CCtx_setParameter(c, ZSTD_c_windowLog, 23);
    ZSTD_CCtx_setParameter(c, ZSTD_c_checksumFlag, 1);
    size_t r = ZSTD_compress2(c, dst, cap, data, n);
    ZSTD_freeCCtx(c);
    if (ZSTD_isError(r)) { free(dst); g_ok = 0; return nox_str_from_bytes_c(rt, NULL, 0); }
    void *out = nox_str_from_bytes_c(rt, dst, r);
    free(dst);
    g_ok = 1;
    return out;
}
