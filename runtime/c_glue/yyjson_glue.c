/* 2.2 aşama 8: `nox.yyjson` — yyjson (MIT) okuyucu/yazıcısına ince sarmalayıcı. Tüm tutamaçlar Nox tarafında `int`tir (0 = yok): belge sarmalayıcısı ve belge içindeki değer
 * işaretçileri. Değişmez belge birden çok iş parçacığından okunabilir; sıralı gezinme önbelleği iş parçacığı-yerelidir (paylaşılan değişken durum yok). Belge ömrü Nox tarafındaki
 * `YyDoc.__del__` ile ARC'ye bağlıdır; değer tutamaçları yalnızca belgeyi tutan `YyValue` içinden kullanılır. */
#include <stdlib.h>
#include "nxc_common.h"
#include "yyjson.h"

typedef struct {
    yyjson_doc *doc;
    uint64_t id; /* süreç boyunca benzersiz (asla yeniden kullanılmaz): önbellek anahtarı sarkan adreslere karşı güvenli */
} nxc_yydoc;

static uint64_t g_next_id = 1; /* yalnızca atomik artırılır; Nox runtime durumu değil, C kütüphanesi içi benzersiz kimlik üreteci */

static NXC_TLS int g_ok = 1;
static NXC_TLS const char *g_err_msg = "";
static NXC_TLS int64_t g_err_pos = 0;

int64_t nxc_yy_available(void) { return 1; }
int64_t nxc_yy_ok(void) { return g_ok; }
int64_t nxc_yy_err_pos(void) { return g_err_pos; }
void *nxc_yy_err_msg(void *rt) { return nox_str_from_bytes_c(rt, (const uint8_t *)g_err_msg, strlen(g_err_msg)); }

/* mode: 0 = katı JSON; 1 = yorum + sondaki virgül; 2 = JSON5. Geçersiz girdide 0 döner (hata metni/konumu okunur). */
int64_t nxc_yy_parse(const uint8_t *s, int64_t mode) {
    yyjson_read_flag fl = YYJSON_READ_NOFLAG;
    if (mode == 1) fl = YYJSON_READ_ALLOW_COMMENTS | YYJSON_READ_ALLOW_TRAILING_COMMAS;
    else if (mode == 2) fl = YYJSON_READ_JSON5;
    yyjson_read_err err;
    memset(&err, 0, sizeof err);
    yyjson_doc *d = yyjson_read_opts((char *)(uintptr_t)s, nxc_slen(s), fl, NULL, &err);
    if (!d) {
        g_ok = 0;
        g_err_msg = err.msg ? err.msg : "invalid JSON";
        g_err_pos = (int64_t)err.pos;
        return 0;
    }
    nxc_yydoc *w = (nxc_yydoc *)malloc(sizeof *w);
    if (!w) { yyjson_doc_free(d); g_ok = 0; g_err_msg = "out of memory"; g_err_pos = 0; return 0; }
    w->doc = d;
    w->id = __atomic_fetch_add(&g_next_id, 1, __ATOMIC_RELAXED);
    g_ok = 1;
    return (int64_t)(intptr_t)w;
}

void nxc_yy_free(int64_t d) {
    nxc_yydoc *w = (nxc_yydoc *)(intptr_t)d;
    if (!w) return;
    yyjson_doc_free(w->doc);
    free(w);
}

int64_t nxc_yy_root(int64_t d) {
    nxc_yydoc *w = (nxc_yydoc *)(intptr_t)d;
    return (int64_t)(intptr_t)yyjson_doc_get_root(w->doc);
}

#define V(h) ((yyjson_val *)(intptr_t)(h))

/* 0 null, 1 bool, 2 sayı, 3 dize, 4 dizi, 5 nesne (nox.json `JsonValue.kind` ile aynı). */
int64_t nxc_yy_kind(int64_t v) {
    switch (yyjson_get_type(V(v))) {
    case YYJSON_TYPE_NULL: return 0;
    case YYJSON_TYPE_BOOL: return 1;
    case YYJSON_TYPE_NUM: return 2;
    case YYJSON_TYPE_STR: return 3;
    case YYJSON_TYPE_ARR: return 4;
    case YYJSON_TYPE_OBJ: return 5;
    default: return 0;
    }
}

int64_t nxc_yy_bool(int64_t v) { return yyjson_get_bool(V(v)) ? 1 : 0; }
double nxc_yy_num(int64_t v) { return yyjson_get_num(V(v)); }
int64_t nxc_yy_is_integer(int64_t v) { return yyjson_is_int(V(v)) ? 1 : 0; }

/* Tamsayı değeri: int64'e sığan tamsayı ya da tamsayı değerli ondalık (`1.0`, `1e2`); aksi halde ok=0. */
int64_t nxc_yy_int(int64_t h) {
    yyjson_val *v = V(h);
    g_ok = 1;
    if (yyjson_is_sint(v)) return yyjson_get_sint(v);
    if (yyjson_is_uint(v)) {
        uint64_t u = yyjson_get_uint(v);
        if (u <= (uint64_t)INT64_MAX) return (int64_t)u;
        g_ok = 0;
        return 0;
    }
    if (yyjson_is_real(v)) {
        double d = yyjson_get_real(v);
        if (d >= -9223372036854775808.0 && d < 9223372036854775808.0) {
            int64_t i = (int64_t)d;
            if ((double)i == d) return i;
        }
    }
    g_ok = 0;
    return 0;
}

void *nxc_yy_str(void *rt, int64_t v) {
    const char *p = yyjson_get_str(V(v));
    return nox_str_from_bytes_c(rt, (const uint8_t *)p, yyjson_get_len(V(v)));
}

int64_t nxc_yy_len(int64_t v) {
    yyjson_val *x = V(v);
    if (yyjson_is_arr(x)) return (int64_t)yyjson_arr_size(x);
    if (yyjson_is_obj(x)) return (int64_t)yyjson_obj_size(x);
    return 0;
}

/* Sıralı gezinme önbelleği: değişmez belgede bir kapsayıcının i'inci çocuğuna ulaşmak çocukların boyutlarına bağlı (O(i)); `for i in range(n): array_get(v, i)` gibi döngüler
 * ikinci dereceden olmasın diye son erişilen konum iş parçacığı-yerel küçük bir tabloda tutulur. Anahtar (belge kimliği, kapsayıcı adresi): kimlik yeniden kullanılmaz.
 * Yalnızca BÜYÜK kapsayıcılar (>= NXC_YY_MIN çocuk) önbelleğe girer: küçük nesneler (kayıt alanları) yuvaları dış diziden koparmasın; tam ilişkisel + en az yakın kullanılan değiştirme. */
#define NXC_YY_SLOTS 8
#define NXC_YY_MIN 16
typedef struct {
    uint64_t doc_id;
    const yyjson_val *ctn;
    size_t idx;
    const yyjson_val *cur; /* dizi: i'inci eleman; nesne: i'inci anahtar */
    uint64_t used;
} nxc_yycur;
static NXC_TLS nxc_yycur g_cur[NXC_YY_SLOTS];
static NXC_TLS uint64_t g_tick;

static nxc_yycur *find_slot(uint64_t id, const yyjson_val *ctn, int *hit) {
    nxc_yycur *victim = &g_cur[0];
    for (int k = 0; k < NXC_YY_SLOTS; k++) {
        nxc_yycur *c = &g_cur[k];
        if (c->doc_id == id && c->ctn == ctn) { *hit = 1; c->used = ++g_tick; return c; }
        if (c->used < victim->used) victim = c;
    }
    *hit = 0;
    victim->used = ++g_tick;
    return victim;
}

/* i, [0, len) içinde olmalıdır (Nox tarafı sınırları denetler). */
int64_t nxc_yy_arr_get(int64_t d, int64_t a, int64_t i) {
    const nxc_yydoc *w = (const nxc_yydoc *)(intptr_t)d;
    yyjson_val *arr = V(a);
    size_t idx = (size_t)i;
    if (yyjson_arr_size(arr) < NXC_YY_MIN) return (int64_t)(intptr_t)yyjson_arr_get(arr, idx);
    int hit;
    nxc_yycur *c = find_slot(w->id, arr, &hit);
    const yyjson_val *p;
    if (hit && c->idx <= idx) {
        p = c->cur;
        for (size_t k = c->idx; k < idx; k++) p = unsafe_yyjson_get_next(p);
    } else {
        p = yyjson_arr_get(arr, idx);
    }
    c->doc_id = w->id; c->ctn = arr; c->idx = idx; c->cur = p;
    return (int64_t)(intptr_t)p;
}

static const yyjson_val *obj_key_at(const nxc_yydoc *w, yyjson_val *obj, size_t idx) {
    const yyjson_val *k;
    size_t from = 0;
    nxc_yycur *c = NULL;
    if (yyjson_obj_size(obj) >= NXC_YY_MIN) {
        int hit;
        c = find_slot(w->id, obj, &hit);
        if (hit && c->idx <= idx) { k = c->cur; from = c->idx; }
        else k = unsafe_yyjson_get_first(obj);
    } else {
        k = unsafe_yyjson_get_first(obj);
    }
    for (; from < idx; from++) k = unsafe_yyjson_get_next(unsafe_yyjson_get_next(k));
    if (c) { c->doc_id = w->id; c->ctn = obj; c->idx = idx; c->cur = k; }
    return k;
}

int64_t nxc_yy_obj_key(int64_t d, int64_t o, int64_t i) {
    return (int64_t)(intptr_t)obj_key_at((const nxc_yydoc *)(intptr_t)d, V(o), (size_t)i);
}

int64_t nxc_yy_obj_val(int64_t d, int64_t o, int64_t i) {
    return (int64_t)(intptr_t)unsafe_yyjson_get_next(obj_key_at((const nxc_yydoc *)(intptr_t)d, V(o), (size_t)i));
}

/* Anahtara göre arama (doğrusal, belge sırasındaki ilk eşleşme); yoksa 0. */
int64_t nxc_yy_obj_get(int64_t o, const uint8_t *key) {
    return (int64_t)(intptr_t)yyjson_obj_getn(V(o), (const char *)key, nxc_slen(key));
}

/* indent < 0: sıkı; 0..: girintili (4 ve 2 doğrudan, diğerleri 4'lü çıktının yeniden girintilenmesiyle). Hata (ör. Infinity/NaN) → ok=0 + boş. */
void *nxc_yy_dump(void *rt, int64_t h, int64_t indent) {
    yyjson_write_flag fl = YYJSON_WRITE_NOFLAG;
    if (indent == 4) fl = YYJSON_WRITE_PRETTY;
    else if (indent == 2) fl = YYJSON_WRITE_PRETTY_TWO_SPACES;
    else if (indent >= 0) fl = YYJSON_WRITE_PRETTY;
    size_t len = 0;
    yyjson_write_err err;
    memset(&err, 0, sizeof err);
    char *out = yyjson_val_write_opts(V(h), fl, NULL, &len, &err);
    if (!out) { g_ok = 0; return nox_str_from_bytes_c(rt, NULL, 0); }
    g_ok = 1;
    if (indent < 0 || indent == 4 || indent == 2) {
        void *s = nox_str_from_bytes_c(rt, (const uint8_t *)out, len);
        free(out);
        return s;
    }
    if (indent > 256) indent = 256;
    /* 4'lü girintiyi `indent`e çevir: satır başlarındaki boşluklar yapısaldır (dize içi satır sonu kaçışlıdır). */
    size_t cap = len + 16;
    if (indent > 4) cap = len * (size_t)(indent / 4 + 1) + 16;
    uint8_t *buf = (uint8_t *)malloc(cap);
    if (!buf) { free(out); g_ok = 0; return nox_str_from_bytes_c(rt, NULL, 0); }
    size_t o = 0, i = 0;
    int at_line_start = 1;
    while (i < len) {
        if (at_line_start) {
            size_t sp = 0;
            while (i < len && out[i] == ' ') { sp++; i++; }
            size_t n = sp / 4 * (size_t)indent;
            memset(buf + o, ' ', n);
            o += n;
            at_line_start = 0;
            continue;
        }
        buf[o++] = (uint8_t)out[i];
        if (out[i] == '\n') at_line_start = 1;
        i++;
    }
    void *s = nox_str_from_bytes_c(rt, buf, o);
    free(buf);
    free(out);
    return s;
}
