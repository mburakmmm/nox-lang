/* UR-008: `NoxHostValue` değer ağaçlarıyla konteyner/Optional/tuple imzalı Nox işlevlerini çağıran C ana makinesi. */
#include "nox_host.h"
#include <stdio.h>
#include <string.h>
#include <math.h>

NoxHostStatus nox_host_module_init_ct(NoxHostContext *ctx, NoxHostError **err);
void nox_host_module_fini_ct(NoxHostContext *ctx);
NoxHostStatus nox_host_export_ct_opt_int(NoxHostContext *, NoxHostValue, NoxHostValue *, NoxHostError **);
NoxHostStatus nox_host_export_ct_opt_str(NoxHostContext *, NoxHostValue, NoxHostBuffer *, NoxHostError **);
NoxHostStatus nox_host_export_ct_sum_list(NoxHostContext *, NoxHostValue, int64_t *, NoxHostError **);
NoxHostStatus nox_host_export_ct_echo_list(NoxHostContext *, NoxHostValue, NoxHostValue *, NoxHostError **);
NoxHostStatus nox_host_export_ct_scale(NoxHostContext *, NoxHostValue, double, NoxHostValue *, NoxHostError **);
NoxHostStatus nox_host_export_ct_map_dict(NoxHostContext *, NoxHostValue, NoxHostValue *, NoxHostError **);
NoxHostStatus nox_host_export_ct_swap_pair(NoxHostContext *, NoxHostValue, NoxHostValue *, NoxHostError **);
NoxHostStatus nox_host_export_ct_nested(NoxHostContext *, NoxHostValue, NoxHostValue *, NoxHostError **);
NoxHostStatus nox_host_export_ct_blobs(NoxHostContext *, NoxHostValue, NoxHostValue, NoxHostValue *, NoxHostError **);
NoxHostStatus nox_host_export_ct_boom_list(NoxHostContext *, NoxHostValue, NoxHostValue *, NoxHostError **);
NoxHostStatus nox_host_export_ct_no_return(NoxHostContext *, NoxHostValue, NoxHostError **);

static int g_fail;
#define CHECK(c) do { if (!(c)) { printf("FAIL line %d: %s\n", __LINE__, #c); g_fail++; } } while (0)

static NoxHostValue vint(NoxHostContext *c, int64_t v) { NoxHostValue h = 0; CHECK(nox_host_value_int(c, v, &h) == NOX_HOST_OK); return h; }
static NoxHostValue vstr(NoxHostContext *c, const char *s) { NoxHostValue h = 0; CHECK(nox_host_value_str(c, (const uint8_t *)s, strlen(s), 0, &h) == NOX_HOST_OK); return h; }
static NoxHostValue vnone(NoxHostContext *c) { NoxHostValue h = 0; CHECK(nox_host_value_none(c, &h) == NOX_HOST_OK); return h; }
static NoxHostValue vcont(NoxHostContext *c, int kind) { NoxHostValue h = 0; CHECK(nox_host_value_container(c, kind, &h) == NOX_HOST_OK); return h; }
/* kapsayıcıya ekler ve yerel handle'ı bırakır */
static void push(NoxHostContext *c, NoxHostValue cont, NoxHostValue item) { CHECK(nox_host_value_append(c, cont, item) == NOX_HOST_OK); CHECK(nox_host_value_release(c, item) == NOX_HOST_OK); }
static int64_t geti(NoxHostContext *c, NoxHostValue v) { int64_t x = -1; CHECK(nox_host_value_get_int(c, v, &x) == NOX_HOST_OK); return x; }
static int kind_of(NoxHostContext *c, NoxHostValue v) { int32_t k = -1; CHECK(nox_host_value_kind(c, v, &k) == NOX_HOST_OK); return k; }
static size_t len_of(NoxHostContext *c, NoxHostValue v) { size_t n = 999; CHECK(nox_host_value_len(c, v, &n) == NOX_HOST_OK); return n; }
static NoxHostValue item(NoxHostContext *c, NoxHostValue v, size_t i) { NoxHostValue h = 0; CHECK(nox_host_value_item(c, v, i, &h) == NOX_HOST_OK); return h; }
static int str_eq(NoxHostContext *c, NoxHostValue v, const char *s) {
    NoxHostSpan sp; if (nox_host_value_get_span(c, v, &sp) != NOX_HOST_OK) return 0;
    return sp.len == strlen(s) && (sp.len == 0 || memcmp(sp.data, s, sp.len) == 0);
}

int main(void) {
    NoxHostContextConfig cfg = { sizeof cfg, NOX_HOST_ABI_VERSION, NULL };
    NoxHostContext *c = NULL; NoxHostError *e = NULL;
    CHECK(nox_host_context_create(&cfg, &c) == NOX_HOST_OK);
    CHECK(nox_host_module_init_ct(c, &e) == NOX_HOST_OK);

    /* Optional[int]: None ve değer */
    { NoxHostValue in = vnone(c), out = 0;
      CHECK(nox_host_export_ct_opt_int(c, in, &out, &e) == NOX_HOST_OK); CHECK(kind_of(c, out) == NOX_HOST_VALUE_NONE);
      nox_host_value_release(c, in); nox_host_value_release(c, out);
      in = vint(c, 7);
      CHECK(nox_host_export_ct_opt_int(c, in, &out, &e) == NOX_HOST_OK); CHECK(kind_of(c, out) == NOX_HOST_VALUE_INT && geti(c, out) == 7);
      nox_host_value_release(c, in); nox_host_value_release(c, out); }

    /* Optional[str] parametresi, str dönüşü */
    { NoxHostValue in = vnone(c); NoxHostBuffer b = {0};
      CHECK(nox_host_export_ct_opt_str(c, in, &b, &e) == NOX_HOST_OK); CHECK(b.len == 4 && memcmp(b.data, "none", 4) == 0); nox_host_buffer_release(&b); nox_host_value_release(c, in);
      in = vstr(c, "hi");
      CHECK(nox_host_export_ct_opt_str(c, in, &b, &e) == NOX_HOST_OK); CHECK(b.len == 6 && memcmp(b.data, "got hi", 6) == 0); nox_host_buffer_release(&b); nox_host_value_release(c, in); }

    /* list[int] -> int ve list[int] -> list[int] */
    { NoxHostValue l = vcont(c, NOX_HOST_VALUE_LIST), out = 0; int64_t s = 0;
      for (int i = 1; i <= 4; i++) push(c, l, vint(c, i));
      CHECK(nox_host_export_ct_sum_list(c, l, &s, &e) == NOX_HOST_OK); CHECK(s == 10);
      CHECK(nox_host_export_ct_echo_list(c, l, &out, &e) == NOX_HOST_OK);
      CHECK(kind_of(c, out) == NOX_HOST_VALUE_LIST && len_of(c, out) == 4);
      for (size_t i = 0; i < 4; i++) { NoxHostValue x = item(c, out, i); CHECK(geti(c, x) == (int64_t)i + 1); nox_host_value_release(c, x); }
      nox_host_value_release(c, out); nox_host_value_release(c, l); }

    /* list[float] + skaler parametre */
    { NoxHostValue l = vcont(c, NOX_HOST_VALUE_LIST), out = 0, f = 0;
      CHECK(nox_host_value_float(c, 1.5, &f) == NOX_HOST_OK); push(c, l, f);
      CHECK(nox_host_export_ct_scale(c, l, 2.0, &out, &e) == NOX_HOST_OK);
      NoxHostValue x = item(c, out, 0); double d = 0; CHECK(nox_host_value_get_float(c, x, &d) == NOX_HOST_OK); CHECK(fabs(d - 3.0) < 1e-12);
      nox_host_value_release(c, x); nox_host_value_release(c, out); nox_host_value_release(c, l); }

    /* dict[str, int] */
    { NoxHostValue d = vcont(c, NOX_HOST_VALUE_DICT), out = 0, k = vstr(c, "a"), v = vint(c, 21);
      CHECK(nox_host_value_dict_set(c, d, k, v) == NOX_HOST_OK); nox_host_value_release(c, k); nox_host_value_release(c, v);
      CHECK(nox_host_export_ct_map_dict(c, d, &out, &e) == NOX_HOST_OK);
      CHECK(kind_of(c, out) == NOX_HOST_VALUE_DICT && len_of(c, out) == 1);
      NoxHostValue ko = 0, vo = 0; CHECK(nox_host_value_dict_entry(c, out, 0, &ko, &vo) == NOX_HOST_OK);
      CHECK(str_eq(c, ko, "a") && geti(c, vo) == 42);
      nox_host_value_release(c, ko); nox_host_value_release(c, vo); nox_host_value_release(c, out); nox_host_value_release(c, d); }

    /* tuple[int, str] -> tuple[str, int] */
    { NoxHostValue t = vcont(c, NOX_HOST_VALUE_TUPLE), out = 0;
      push(c, t, vint(c, 5)); push(c, t, vstr(c, "x"));
      CHECK(nox_host_export_ct_swap_pair(c, t, &out, &e) == NOX_HOST_OK);
      CHECK(kind_of(c, out) == NOX_HOST_VALUE_TUPLE && len_of(c, out) == 2);
      NoxHostValue a = item(c, out, 0), b = item(c, out, 1); CHECK(str_eq(c, a, "x") && geti(c, b) == 5);
      nox_host_value_release(c, a); nox_host_value_release(c, b);
      /* yanlış uzunluk -> ValueError */
      NoxHostValue t1 = vcont(c, NOX_HOST_VALUE_TUPLE), out2 = 0; push(c, t1, vint(c, 1));
      CHECK(nox_host_export_ct_swap_pair(c, t1, &out2, &e) == NOX_HOST_ERR_EXCEPTION && e); nox_host_error_release(e); e = NULL;
      nox_host_value_release(c, t1); nox_host_value_release(c, out); nox_host_value_release(c, t); }

    /* iç içe: list[tuple[int, str]] -> dict[str, list[int | None]] */
    { NoxHostValue l = vcont(c, NOX_HOST_VALUE_LIST), out = 0;
      NoxHostValue t = vcont(c, NOX_HOST_VALUE_TUPLE); push(c, t, vint(c, 9)); push(c, t, vstr(c, "k")); push(c, l, t);
      CHECK(nox_host_export_ct_nested(c, l, &out, &e) == NOX_HOST_OK);
      NoxHostValue ko = 0, vo = 0; CHECK(nox_host_value_dict_entry(c, out, 0, &ko, &vo) == NOX_HOST_OK);
      CHECK(str_eq(c, ko, "k") && kind_of(c, vo) == NOX_HOST_VALUE_LIST && len_of(c, vo) == 2);
      NoxHostValue e0 = item(c, vo, 0), e1 = item(c, vo, 1); CHECK(str_eq(c, e0, "k") && kind_of(c, e1) == NOX_HOST_VALUE_NONE);
      nox_host_value_release(c, e0); nox_host_value_release(c, e1); nox_host_value_release(c, ko); nox_host_value_release(c, vo);
      nox_host_value_release(c, out); nox_host_value_release(c, l); }

    /* list[bytes] (gömülü 0) + list[bool] */
    { NoxHostValue l = vcont(c, NOX_HOST_VALUE_LIST), f = vcont(c, NOX_HOST_VALUE_LIST), out = 0, b = 0, t = 0;
      CHECK(nox_host_value_str(c, (const uint8_t *)"a\0b", 3, 1, &b) == NOX_HOST_OK); push(c, l, b);
      CHECK(nox_host_value_bool(c, 1, &t) == NOX_HOST_OK); push(c, f, t);
      CHECK(nox_host_export_ct_blobs(c, l, f, &out, &e) == NOX_HOST_OK); CHECK(len_of(c, out) == 2);
      NoxHostValue x = item(c, out, 0), y = item(c, out, 1); NoxHostSpan sp;
      CHECK(nox_host_value_get_span(c, x, &sp) == NOX_HOST_OK && sp.len == 3 && memcmp(sp.data, "a\0b", 3) == 0);
      CHECK(nox_host_value_get_span(c, y, &sp) == NOX_HOST_OK && sp.len == 2 && sp.data[0] == 0 && sp.data[1] == 'z');
      nox_host_value_release(c, x); nox_host_value_release(c, y); nox_host_value_release(c, out); nox_host_value_release(c, l); nox_host_value_release(c, f); }

    /* None dönüşlü işlev, Nox istisnası ve hatalı girdiler */
    { NoxHostValue l = vcont(c, NOX_HOST_VALUE_LIST), out = 0; push(c, l, vint(c, 1));
      CHECK(nox_host_export_ct_no_return(c, l, &e) == NOX_HOST_OK);
      CHECK(nox_host_export_ct_boom_list(c, l, &out, &e) == NOX_HOST_ERR_EXCEPTION && e);
      NoxHostSpan cn, msg; CHECK(nox_host_error_class_name(e, &cn) == NOX_HOST_OK && nox_host_error_message(e, &msg) == NOX_HOST_OK);
      CHECK(cn.len == 10 && memcmp(cn.data, "ValueError", 10) == 0 && msg.len == 4 && memcmp(msg.data, "boom", 4) == 0);
      nox_host_error_release(e); e = NULL;
      NoxHostValue s = vstr(c, "not a list"); int64_t sum = 0;
      CHECK(nox_host_export_ct_sum_list(c, s, &sum, &e) == NOX_HOST_ERR_EXCEPTION && e); nox_host_error_release(e); e = NULL; /* list yerine str: ValueError */
      CHECK(nox_host_export_ct_sum_list(c, 12345, &sum, &e) == NOX_HOST_ERR_EXCEPTION && e); nox_host_error_release(e); e = NULL; /* sahte handle */
      NoxHostValue bad = vcont(c, NOX_HOST_VALUE_LIST); push(c, bad, vstr(c, "x")); /* list[int] içinde str */
      CHECK(nox_host_export_ct_sum_list(c, bad, &sum, &e) == NOX_HOST_ERR_EXCEPTION && e); nox_host_error_release(e); e = NULL;
      nox_host_value_release(c, bad); nox_host_value_release(c, s); nox_host_value_release(c, l); }

    /* API kuralları: döngü, tür, nesil, bağlam */
    { NoxHostValue l = vcont(c, NOX_HOST_VALUE_LIST), i = vint(c, 1);
      CHECK(nox_host_value_append(c, l, l) == NOX_HOST_ERR_INVAL);
      CHECK(nox_host_value_append(c, i, l) == NOX_HOST_ERR_INVAL);
      CHECK(nox_host_value_release(c, i) == NOX_HOST_OK);
      CHECK(nox_host_value_release(c, i) == NOX_HOST_ERR_INVALID_HANDLE && nox_host_value_is_valid(c, i) == 0);
      CHECK(nox_host_value_str(c, (const uint8_t *)"\xff", 1, 0, &i) == NOX_HOST_ERR_UTF8);
      nox_host_value_release(c, l); }

    nox_host_module_fini_ct(c);
    nox_host_context_destroy(c);
    if (g_fail) { printf("%d failure(s)\n", g_fail); return 1; }
    printf("ALL OK\n");
    return 0;
}
