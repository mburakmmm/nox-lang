/* 2.2 aşama 8: `nox.brotli` — brotli (MIT) AÇICISI (HTTP `Content-Encoding: br`, `.br` dosyaları). Akışlı çözücü, büyüyen çıktı tamponu; çıktı sınırı açma bombasına karşı. Bozuk/kesik girdi ve akıştan
 * sonra artık bayt hata sayılır (nox.zstd/nox.lz4 ile aynı sıkılık). */
#include <stdlib.h>
#include "nxc_common.h"
#include "brotli/decode.h"

static NXC_TLS int g_ok = 1;
int64_t nxc_brotli_last_ok(void) { return g_ok; }
int64_t nxc_brotli_available(void) { return 1; }

#define NXC_BROTLI_LIMIT ((size_t)1 << 30)

void *nxc_brotli_decompress_str(void *rt, const uint8_t *data, int64_t limit) {
    size_t n = nxc_slen(data);
    size_t max_out = limit > 0 && (uint64_t)limit < NXC_BROTLI_LIMIT ? (size_t)limit : NXC_BROTLI_LIMIT;
    BrotliDecoderState *st = BrotliDecoderCreateInstance(NULL, NULL, NULL);
    g_ok = 0;
    if (!st) return nox_str_from_bytes_c(rt, NULL, 0);
    size_t cap = n * 4 + 4096, len = 0;
    if (cap > max_out) cap = max_out + 1;
    uint8_t *buf = (uint8_t *)malloc(cap);
    if (!buf) { BrotliDecoderDestroyInstance(st); return nox_str_from_bytes_c(rt, NULL, 0); }
    const uint8_t *in = data;
    size_t avail_in = n;
    int ok = 0;
    for (;;) {
        if (cap - len < 4096) {
            size_t ncap = cap * 2;
            if (ncap > max_out + 1) ncap = max_out + 1;
            if (ncap <= cap) break; /* çıktı sınırı aşıldı */
            uint8_t *nb = (uint8_t *)realloc(buf, ncap);
            if (!nb) break;
            buf = nb; cap = ncap;
        }
        size_t avail_out = cap - len;
        uint8_t *out = buf + len;
        BrotliDecoderResult r = BrotliDecoderDecompressStream(st, &avail_in, &in, &avail_out, &out, NULL);
        len = (size_t)(out - buf);
        if (len > max_out) break;
        if (r == BROTLI_DECODER_RESULT_SUCCESS) { ok = avail_in == 0; break; }
        if (r == BROTLI_DECODER_RESULT_ERROR || r == BROTLI_DECODER_RESULT_NEEDS_MORE_INPUT) break; /* bozuk / kesik */
        /* NEEDS_MORE_OUTPUT: döngü tamponu büyütür */
    }
    BrotliDecoderDestroyInstance(st);
    if (!ok) { free(buf); return nox_str_from_bytes_c(rt, NULL, 0); }
    void *res = nox_str_from_bytes_c(rt, buf, len);
    free(buf);
    g_ok = 1;
    return res;
}
