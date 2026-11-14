/* 2.2 aşama 8: `nox.pcre2` — PCRE2 10.x (BSD-3 + istisna) 8-bit kütüphanesine ince sarmalayıcı; JIT (sljit) varsa kullanılır, yoksa/başarısızsa yorumlayıcıya sessizce düşülür (sonuçlar aynı).
 * Tutamaç Nox tarafında `int` (derlenmiş desen); derlenmiş desen değişmezdir ve birden çok iş parçacığından eşleştirilebilir (eşleştirme verisi çağrı başına, JIT yığını iş parçacığı-yerel).
 * Konumlar BAYT indeksidir (nox.regex ile aynı); UTF-8 modunda (varsayılan) özne bir kez doğrulanır. */
#include <stdlib.h>
#include "nxc_common.h"
#define PCRE2_CODE_UNIT_WIDTH 8
#include "pcre2.h"

extern void *nox_int_list_from_c(void *rt, const int64_t *vals, size_t n);

typedef struct {
    pcre2_code *re;
    uint32_t ngroups;
    int jit;
    int utf;
    char *names; /* grup 1..n adları "\n" ile birleşik (adsız grup = boş) */
    size_t names_len;
} nxc_re;

static NXC_TLS int g_ok = 1;
static NXC_TLS char g_msg[256];
static NXC_TLS int64_t g_pos = 0;
static NXC_TLS pcre2_jit_stack *g_jit_stack;
static NXC_TLS pcre2_match_context *g_mctx;

#define F_I 1
#define F_M 2
#define F_S 4
#define F_ANCHORED 8
#define F_FULL 16
#define F_X 32
#define F_BYTES 64

static void set_err(int code, int64_t pos) {
    PCRE2_UCHAR buf[200];
    int n = pcre2_get_error_message(code, buf, sizeof buf);
    if (n < 0) { strcpy(g_msg, "pcre2 error"); }
    else { memcpy(g_msg, buf, (size_t)n); g_msg[n] = 0; }
    g_pos = pos;
    g_ok = 0;
}

int64_t nxc_pcre2_available(void) { return 1; }
int64_t nxc_pcre2_ok(void) { return g_ok; }
int64_t nxc_pcre2_err_pos(void) { return g_pos; }
void *nxc_pcre2_err_msg(void *rt) { return nox_str_from_bytes_c(rt, (const uint8_t *)g_msg, strlen(g_msg)); }

int64_t nxc_pcre2_jit_supported(void) {
    uint32_t v = 0;
    if (pcre2_config(PCRE2_CONFIG_JIT, &v) < 0) return 0;
    return v ? 1 : 0;
}

/* Derleme. flags: bit düzeni üstte; jit != 0 ise JIT denenir. Hata → 0 + ileti/konum. */
int64_t nxc_pcre2_compile(const uint8_t *pat, int64_t flags, int64_t jit) {
    uint32_t opts = 0;
    if (flags & F_I) opts |= PCRE2_CASELESS;
    if (flags & F_M) opts |= PCRE2_MULTILINE;
    if (flags & F_S) opts |= PCRE2_DOTALL;
    if (flags & F_X) opts |= PCRE2_EXTENDED;
    int utf = (flags & F_BYTES) == 0;
    if (utf) opts |= PCRE2_UTF | PCRE2_UCP;
    int code = 0;
    PCRE2_SIZE eoff = 0;
    pcre2_code *re = pcre2_compile((PCRE2_SPTR)pat, nxc_slen(pat), opts, &code, &eoff, NULL);
    if (!re) { set_err(code, (int64_t)eoff); return 0; }
    nxc_re *r = (nxc_re *)calloc(1, sizeof *r);
    if (!r) { pcre2_code_free(re); strcpy(g_msg, "out of memory"); g_pos = 0; g_ok = 0; return 0; }
    r->re = re;
    r->utf = utf;
    pcre2_pattern_info(re, PCRE2_INFO_CAPTURECOUNT, &r->ngroups);
    if (jit && nxc_pcre2_jit_supported()) r->jit = pcre2_jit_compile(re, PCRE2_JIT_COMPLETE) == 0;
    /* grup adları */
    uint32_t cnt = 0, esz = 0;
    PCRE2_SPTR tab = NULL;
    pcre2_pattern_info(re, PCRE2_INFO_NAMECOUNT, &cnt);
    if (cnt > 0 && r->ngroups > 0) {
        pcre2_pattern_info(re, PCRE2_INFO_NAMEENTRYSIZE, &esz);
        pcre2_pattern_info(re, PCRE2_INFO_NAMETABLE, &tab);
        size_t total = r->ngroups; /* ayırıcılar */
        for (uint32_t i = 0; i < cnt; i++) total += strlen((const char *)tab + (size_t)i * esz + 2);
        char *nm = (char *)calloc(1, total + 1);
        if (nm) {
            /* her grup için ad (varsa) */
            for (uint32_t g = 1; g <= r->ngroups; g++) {
                const char *found = "";
                for (uint32_t i = 0; i < cnt; i++) {
                    const uint8_t *e = tab + (size_t)i * esz;
                    if ((uint32_t)((e[0] << 8) | e[1]) == g) { found = (const char *)e + 2; break; }
                }
                strcat(nm, found);
                if (g < r->ngroups) strcat(nm, "\n");
            }
            r->names = nm;
            r->names_len = strlen(nm);
        }
    }
    g_ok = 1;
    return (int64_t)(intptr_t)r;
}

void nxc_pcre2_free(int64_t h) {
    nxc_re *r = (nxc_re *)(intptr_t)h;
    if (!r) return;
    pcre2_code_free(r->re);
    free(r->names);
    free(r);
}

int64_t nxc_pcre2_ngroups(int64_t h) { return ((nxc_re *)(intptr_t)h)->ngroups; }
int64_t nxc_pcre2_is_jit(int64_t h) { return ((nxc_re *)(intptr_t)h)->jit; }
void *nxc_pcre2_group_names(void *rt, int64_t h) {
    nxc_re *r = (nxc_re *)(intptr_t)h;
    return nox_str_from_bytes_c(rt, (const uint8_t *)(r->names ? r->names : ""), r->names ? r->names_len : 0);
}

static pcre2_match_context *get_mctx(const nxc_re *r) {
    if (!r->jit) return NULL;
    if (!g_mctx) g_mctx = pcre2_match_context_create(NULL);
    if (!g_mctx) return NULL;
    if (!g_jit_stack) g_jit_stack = pcre2_jit_stack_create(32 * 1024, 1024 * 1024, NULL);
    if (g_jit_stack) pcre2_jit_stack_assign(g_mctx, NULL, g_jit_stack);
    return g_mctx;
}

/* Bir karakter ilerle (UTF-8 modunda devam baytlarını atla). */
static size_t next_off(const nxc_re *r, const uint8_t *s, size_t len, size_t off) {
    if (off >= len) return len + 1;
    off++;
    if (r->utf) while (off < len && (s[off] & 0xC0) == 0x80) off++;
    return off;
}

static uint32_t match_opts(int64_t flags) {
    uint32_t o = 0;
    if (flags & (F_ANCHORED | F_FULL)) o |= PCRE2_ANCHORED;
    if (flags & F_FULL) o |= PCRE2_ENDANCHORED;
    return o;
}

/* Tüm eşleşmeler: (ngroups+1)*2 sayılık dilimler (kullanılmayan grup -1,-1), en çok `limit` (0 = sınırsız), `from` bayt konumundan. Hata → boş liste + ok=0 + ileti.
 * ANCHORED bayrağıyla yalnızca tek (başta) eşleşme aranır. */
void *nxc_pcre2_exec_all(void *rt, int64_t h, const uint8_t *text, int64_t from, int64_t flags, int64_t limit) {
    nxc_re *r = (nxc_re *)(intptr_t)h;
    size_t len = nxc_slen(text);
    size_t pos = from < 0 ? 0 : (size_t)from;
    if (pos > len) pos = len;
    pcre2_match_data *md = pcre2_match_data_create_from_pattern(r->re, NULL);
    pcre2_match_context *mc = get_mctx(r);
    size_t per = ((size_t)r->ngroups + 1) * 2;
    size_t cap = 0, cnt = 0, n = 0;
    int64_t *out = NULL;
    uint32_t base = match_opts(flags);
    uint32_t extra = 0;
    int first = 1;
    g_ok = 1;
    if (!md) { strcpy(g_msg, "out of memory"); g_pos = 0; g_ok = 0; return nox_int_list_from_c(rt, NULL, 0); }
    while (pos <= len) {
        if (limit > 0 && (int64_t)cnt >= limit) break;
        uint32_t o = base | extra | (first ? 0 : PCRE2_NO_UTF_CHECK);
        int rc = pcre2_match(r->re, (PCRE2_SPTR)text, len, pos, o, md, mc);
        if (rc == PCRE2_ERROR_NOMATCH) {
            if (extra) { /* boş eşleşmeden sonra aynı konumda boş-olmayan denemesi başarısız: bir karakter ilerle */
                extra = 0;
                pos = next_off(r, text, len, pos);
                continue;
            }
            break;
        }
        if (rc < 0) {
            set_err(rc, (int64_t)pos);
            free(out);
            pcre2_match_data_free(md);
            return nox_int_list_from_c(rt, NULL, 0);
        }
        first = 0;
        PCRE2_SIZE *ov = pcre2_get_ovector_pointer(md);
        if (n + per > cap) {
            size_t ncap = cap ? cap * 2 : 64 * per;
            while (ncap < n + per) ncap *= 2;
            int64_t *nb = (int64_t *)realloc(out, ncap * sizeof(int64_t));
            if (!nb) { free(out); pcre2_match_data_free(md); strcpy(g_msg, "out of memory"); g_pos = 0; g_ok = 0; return nox_int_list_from_c(rt, NULL, 0); }
            out = nb; cap = ncap;
        }
        uint32_t rcn = (uint32_t)rc; /* yazılan çift sayısı */
        for (size_t g = 0; g <= r->ngroups; g++) {
            if (g < rcn && ov[g * 2] != PCRE2_UNSET) { out[n++] = (int64_t)ov[g * 2]; out[n++] = (int64_t)ov[g * 2 + 1]; }
            else { out[n++] = -1; out[n++] = -1; }
        }
        cnt++;
        if (flags & F_ANCHORED) break;
        if (ov[1] == ov[0]) {
            /* boş eşleşme: aynı konumda boş-olmayan dene, olmazsa bir karakter ilerle (Python 3.7+ ile aynı sonuçlar) */
            extra = PCRE2_NOTEMPTY_ATSTART | PCRE2_ANCHORED;
            pos = ov[1];
        } else {
            extra = 0;
            pos = ov[1];
        }
        if (flags & F_FULL) break;
    }
    pcre2_match_data_free(md);
    void *lst = nox_int_list_from_c(rt, out, n);
    free(out);
    return lst;
}

/* Yalnızca var/yok: 1 eşleşme, 0 yok, -1 hata (ok=0). */
int64_t nxc_pcre2_test(int64_t h, const uint8_t *text, int64_t from, int64_t flags) {
    nxc_re *r = (nxc_re *)(intptr_t)h;
    size_t len = nxc_slen(text);
    size_t pos = from < 0 ? 0 : (size_t)from;
    if (pos > len) pos = len;
    pcre2_match_data *md = pcre2_match_data_create_from_pattern(r->re, NULL);
    if (!md) { strcpy(g_msg, "out of memory"); g_pos = 0; g_ok = 0; return -1; }
    int rc = pcre2_match(r->re, (PCRE2_SPTR)text, len, pos, match_opts(flags), md, get_mctx(r));
    pcre2_match_data_free(md);
    g_ok = 1;
    if (rc >= 0) return 1;
    if (rc == PCRE2_ERROR_NOMATCH) return 0;
    set_err(rc, (int64_t)pos);
    return -1;
}

void *nxc_pcre2_slice(void *rt, const uint8_t *text, int64_t start, int64_t end) {
    size_t len = nxc_slen(text);
    size_t s = start < 0 ? 0 : (size_t)start;
    size_t e = end < 0 ? 0 : (size_t)end;
    if (s > len) s = len;
    if (e > len) e = len;
    if (e < s) e = s;
    return nox_str_from_bytes_c(rt, text + s, e - s);
}
