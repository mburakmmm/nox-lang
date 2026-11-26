/* UR-009: `@export class` — kurucu, yöntemler, özellik, statik/classmethod, dunder'lar, özel istisna, `nox_host_handle_type_name` ve `NOX_HOST_VALUE_HANDLE`. */
#include "nox_host.h"
#include <stdio.h>
#include <string.h>

NoxHostStatus nox_host_module_init_cl(NoxHostContext *ctx, NoxHostError **err);
void nox_host_module_fini_cl(NoxHostContext *ctx);
NoxHostStatus nox_host_export_cl_Counter___new__(NoxHostContext *, int64_t, const uint8_t *, size_t, NoxHostHandle *, NoxHostError **);
NoxHostStatus nox_host_export_cl_Counter_inc(NoxHostContext *, NoxHostHandle, int64_t, int64_t *, NoxHostError **);
NoxHostStatus nox_host_export_cl_Counter_note(NoxHostContext *, NoxHostHandle, const uint8_t *, size_t, NoxHostError **);
NoxHostStatus nox_host_export_cl_Counter_get_value(NoxHostContext *, NoxHostHandle, int64_t *, NoxHostError **);
NoxHostStatus nox_host_export_cl_Counter_set_value(NoxHostContext *, NoxHostHandle, int64_t, NoxHostError **);
NoxHostStatus nox_host_export_cl_Counter_zero(NoxHostContext *, int64_t *, NoxHostError **);
NoxHostStatus nox_host_export_cl_Counter_make(NoxHostContext *, int64_t, NoxHostHandle *, NoxHostError **);
NoxHostStatus nox_host_export_cl_Counter_twin(NoxHostContext *, NoxHostHandle, NoxHostValue *, NoxHostError **);
NoxHostStatus nox_host_export_cl_Counter_merge(NoxHostContext *, NoxHostHandle, NoxHostValue, NoxHostHandle *, NoxHostError **);
NoxHostStatus nox_host_export_cl_Counter___repr__(NoxHostContext *, NoxHostHandle, NoxHostBuffer *, NoxHostError **);
NoxHostStatus nox_host_export_cl_Counter___len__(NoxHostContext *, NoxHostHandle, int64_t *, NoxHostError **);
NoxHostStatus nox_host_export_cl_Counter___eq__(NoxHostContext *, NoxHostHandle, NoxHostHandle, uint8_t *, NoxHostError **);
NoxHostStatus nox_host_export_cl_make_plain(NoxHostContext *, int64_t, NoxHostHandle *, NoxHostError **);
NoxHostStatus nox_host_export_cl_plains(NoxHostContext *, int64_t, NoxHostValue *, NoxHostError **);
NoxHostStatus nox_host_export_cl_make_sub(NoxHostContext *, int64_t, NoxHostHandle *, NoxHostError **);
NoxHostStatus nox_host_export_cl_first_or_none(NoxHostContext *, NoxHostValue, NoxHostValue *, NoxHostError **);

static int g_fail;
#define CHECK(c) do { if (!(c)) { printf("FAIL line %d: %s\n", __LINE__, #c); g_fail++; } } while (0)

static int span_eq(NoxHostSpan sp, const char *s) { return sp.len == strlen(s) && memcmp(sp.data, s, sp.len) == 0; }
static int type_is(NoxHostContext *c, NoxHostHandle h, const char *name) {
    NoxHostSpan sp = {0};
    return nox_host_handle_type_name(c, h, &sp) == NOX_HOST_OK && span_eq(sp, name);
}
static NoxHostHandle mk(NoxHostContext *c, int64_t start, const char *label) {
    NoxHostHandle h = 0;
    NoxHostError *e = NULL;
    CHECK(nox_host_export_cl_Counter___new__(c, start, (const uint8_t *)label, strlen(label), &h, &e) == NOX_HOST_OK);
    CHECK(h != 0);
    return h;
}
static int64_t val(NoxHostContext *c, NoxHostHandle h) {
    int64_t v = -1; NoxHostError *e = NULL;
    CHECK(nox_host_export_cl_Counter_get_value(c, h, &v, &e) == NOX_HOST_OK);
    return v;
}

int main(void) {
    NoxHostContextConfig cfg = { sizeof cfg, NOX_HOST_ABI_VERSION, NULL };
    NoxHostContext *c = NULL; NoxHostError *e = NULL;
    CHECK(nox_host_context_create(&cfg, &c) == NOX_HOST_OK);
    CHECK(nox_host_module_init_cl(c, &e) == NOX_HOST_OK);

    /* kurucu + tür adı + örnek yöntemi */
    NoxHostHandle a = mk(c, 5, "a");
    CHECK(type_is(c, a, "Counter"));
    { int64_t r = 0; CHECK(nox_host_export_cl_Counter_inc(c, a, 3, &r, &e) == NOX_HOST_OK); CHECK(r == 8); }
    CHECK(val(c, a) == 8);
    /* Nox istisnası: özel istisna sınıfı adı korunur */
    { int64_t r = 0; NoxHostSpan sp = {0};
      CHECK(nox_host_export_cl_Counter_inc(c, a, -1, &r, &e) == NOX_HOST_ERR_EXCEPTION && e != NULL);
      CHECK(nox_host_error_class_name(e, &sp) == NOX_HOST_OK && span_eq(sp, "CounterError"));
      CHECK(nox_host_error_message(e, &sp) == NOX_HOST_OK && span_eq(sp, "negative step"));
      nox_host_error_release(e); e = NULL; }
    CHECK(val(c, a) == 8); /* başarısız çağrı durumu değiştirmedi */

    /* özellik okuma/yazma + None dönen yöntem */
    CHECK(nox_host_export_cl_Counter_set_value(c, a, 40, &e) == NOX_HOST_OK);
    CHECK(val(c, a) == 40);
    CHECK(nox_host_export_cl_Counter_note(c, a, (const uint8_t *)"hello", 5, &e) == NOX_HOST_OK);

    /* statik yöntem + classmethod */
    { int64_t z = -1; CHECK(nox_host_export_cl_Counter_zero(c, &z, &e) == NOX_HOST_OK); CHECK(z == 0); }
    NoxHostHandle m = 0;
    CHECK(nox_host_export_cl_Counter_make(c, 7, &m, &e) == NOX_HOST_OK && type_is(c, m, "Counter") && val(c, m) == 7);

    /* dunder'lar */
    { NoxHostBuffer b = {0}; int64_t n = -1; uint8_t eq = 9;
      CHECK(nox_host_export_cl_Counter___repr__(c, a, &b, &e) == NOX_HOST_OK && b.len == 11 && memcmp(b.data, "Counter(40)", 11) == 0);
      nox_host_buffer_release(&b);
      CHECK(nox_host_export_cl_Counter___len__(c, a, &n, &e) == NOX_HOST_OK && n == 40);
      CHECK(nox_host_export_cl_Counter___eq__(c, a, m, &eq, &e) == NOX_HOST_OK && eq == 0);
      CHECK(nox_host_export_cl_Counter___eq__(c, a, a, &eq, &e) == NOX_HOST_OK && eq == 1); }

    /* `Counter | None` dönüşü: None ve HANDLE değeri */
    { NoxHostValue v = 0; int32_t k = -1;
      NoxHostHandle z = mk(c, 0, "z");
      CHECK(nox_host_export_cl_Counter_twin(c, z, &v, &e) == NOX_HOST_OK);
      CHECK(nox_host_value_kind(c, v, &k) == NOX_HOST_OK && k == NOX_HOST_VALUE_NONE);
      CHECK(nox_host_value_release(c, v) == NOX_HOST_OK);
      CHECK(nox_host_export_cl_Counter_twin(c, a, &v, &e) == NOX_HOST_OK);
      CHECK(nox_host_value_kind(c, v, &k) == NOX_HOST_OK && k == NOX_HOST_VALUE_HANDLE);
      NoxHostHandle t = 0;
      CHECK(nox_host_value_get_handle(c, v, &t) == NOX_HOST_OK && t != 0 && t != a);
      CHECK(type_is(c, t, "Counter") && val(c, t) == 40);
      CHECK(nox_host_value_release(c, v) == NOX_HOST_OK);
      CHECK(val(c, t) == 40); /* değer bırakılınca nesne handle ile yaşar */
      CHECK(nox_host_handle_release(c, t) == NOX_HOST_OK);
      CHECK(nox_host_handle_release(c, z) == NOX_HOST_OK); }

    /* `list[Counter]` parametresi: HANDLE değerleri */
    { NoxHostValue l = 0, hv = 0; NoxHostHandle out = 0;
      CHECK(nox_host_value_container(c, NOX_HOST_VALUE_LIST, &l) == NOX_HOST_OK);
      CHECK(nox_host_value_handle(c, m, &hv) == NOX_HOST_OK);
      CHECK(nox_host_value_append(c, l, hv) == NOX_HOST_OK && nox_host_value_release(c, hv) == NOX_HOST_OK);
      CHECK(nox_host_value_handle(c, a, &hv) == NOX_HOST_OK);
      CHECK(nox_host_value_append(c, l, hv) == NOX_HOST_OK && nox_host_value_release(c, hv) == NOX_HOST_OK);
      CHECK(nox_host_export_cl_Counter_merge(c, m, l, &out, &e) == NOX_HOST_OK);
      CHECK(type_is(c, out, "Counter") && val(c, out) == 7 + 7 + 40);
      CHECK(nox_host_handle_release(c, out) == NOX_HOST_OK);
      /* first_or_none: dolu liste → HANDLE, boş liste → None */
      NoxHostValue r = 0; int32_t k = -1; NoxHostHandle f = 0;
      CHECK(nox_host_export_cl_first_or_none(c, l, &r, &e) == NOX_HOST_OK);
      CHECK(nox_host_value_kind(c, r, &k) == NOX_HOST_OK && k == NOX_HOST_VALUE_HANDLE);
      CHECK(nox_host_value_get_handle(c, r, &f) == NOX_HOST_OK && val(c, f) == 7);
      CHECK(nox_host_handle_release(c, f) == NOX_HOST_OK && nox_host_value_release(c, r) == NOX_HOST_OK);
      NoxHostValue empty = 0;
      CHECK(nox_host_value_container(c, NOX_HOST_VALUE_LIST, &empty) == NOX_HOST_OK);
      CHECK(nox_host_export_cl_first_or_none(c, empty, &r, &e) == NOX_HOST_OK);
      CHECK(nox_host_value_kind(c, r, &k) == NOX_HOST_OK && k == NOX_HOST_VALUE_NONE);
      CHECK(nox_host_value_release(c, r) == NOX_HOST_OK && nox_host_value_release(c, empty) == NOX_HOST_OK);
      CHECK(nox_host_value_release(c, l) == NOX_HOST_OK); }

    /* `list[Counter]` dönüşü */
    { NoxHostValue l = 0; size_t n = 0;
      CHECK(nox_host_export_cl_plains(c, 3, &l, &e) == NOX_HOST_OK);
      CHECK(nox_host_value_len(c, l, &n) == NOX_HOST_OK && n == 3);
      for (size_t i = 0; i < n; i++) {
          NoxHostValue it = 0; NoxHostHandle h = 0;
          CHECK(nox_host_value_item(c, l, i, &it) == NOX_HOST_OK);
          CHECK(nox_host_value_get_handle(c, it, &h) == NOX_HOST_OK && type_is(c, h, "Counter") && val(c, h) == (int64_t)i);
          CHECK(nox_host_handle_release(c, h) == NOX_HOST_OK && nox_host_value_release(c, it) == NOX_HOST_OK);
      }
      CHECK(nox_host_value_release(c, l) == NOX_HOST_OK); }

    /* yanlış sınıf kapsayıcı içinde reddedilir (ValueError), süreç bozulmaz */
    { NoxHostHandle p = 0; NoxHostValue l = 0, hv = 0; NoxHostHandle out = 0;
      CHECK(nox_host_export_cl_make_plain(c, 1, &p, &e) == NOX_HOST_OK && type_is(c, p, "Plain"));
      CHECK(nox_host_value_container(c, NOX_HOST_VALUE_LIST, &l) == NOX_HOST_OK);
      CHECK(nox_host_value_handle(c, p, &hv) == NOX_HOST_OK && nox_host_value_append(c, l, hv) == NOX_HOST_OK && nox_host_value_release(c, hv) == NOX_HOST_OK);
      NoxHostSpan sp = {0};
      CHECK(nox_host_export_cl_Counter_merge(c, a, l, &out, &e) == NOX_HOST_ERR_EXCEPTION && e != NULL);
      CHECK(nox_host_error_class_name(e, &sp) == NOX_HOST_OK && span_eq(sp, "ValueError"));
      nox_host_error_release(e); e = NULL;
      CHECK(nox_host_value_release(c, l) == NOX_HOST_OK && nox_host_handle_release(c, p) == NOX_HOST_OK); }

    /* addendum: çok tutamaçlı yöntem (a.__eq__(b)) — her tutamaç ayrı doğrulanır (nesil + sınıf + bağlam) */
    { uint8_t eq = 9; NoxHostHandle p = 0, sub = 0, gone = mk(c, 1, "g"); int64_t r = 0;
      CHECK(nox_host_handle_release(c, gone) == NOX_HOST_OK);
      CHECK(nox_host_export_cl_Counter___eq__(c, a, gone, &eq, &e) == NOX_HOST_ERR_INVALID_HANDLE && e == NULL); /* ikinci tutamaç bırakılmış */
      CHECK(nox_host_export_cl_Counter___eq__(c, gone, a, &eq, &e) == NOX_HOST_ERR_INVALID_HANDLE);
      CHECK(nox_host_export_cl_make_plain(c, 1, &p, &e) == NOX_HOST_OK);
      CHECK(nox_host_export_cl_Counter___eq__(c, a, p, &eq, &e) == NOX_HOST_ERR_INVALID_HANDLE); /* yanlış sınıf */
      CHECK(nox_host_export_cl_Counter_inc(c, p, 1, &r, &e) == NOX_HOST_ERR_INVALID_HANDLE);
      /* alt sınıf örneği kabul edilir */
      CHECK(nox_host_export_cl_make_sub(c, 5, &sub, &e) == NOX_HOST_OK && type_is(c, sub, "SubCounter"));
      CHECK(nox_host_export_cl_Counter_inc(c, sub, 1, &r, &e) == NOX_HOST_OK && r == 6);
      CHECK(nox_host_export_cl_Counter___eq__(c, a, sub, &eq, &e) == NOX_HOST_OK && eq == 0);
      /* başka bağlamın tutamacı reddedilir */
      NoxHostContext *c2 = NULL; NoxHostHandle other = 0;
      CHECK(nox_host_context_create(&cfg, &c2) == NOX_HOST_OK && nox_host_module_init_cl(c2, &e) == NOX_HOST_OK);
      CHECK(nox_host_export_cl_Counter___new__(c2, 1, (const uint8_t *)"x", 1, &other, &e) == NOX_HOST_OK);
      CHECK(nox_host_export_cl_Counter___eq__(c, a, other, &eq, &e) == NOX_HOST_ERR_INVALID_HANDLE);
      CHECK(nox_host_export_cl_Counter___eq__(c2, other, a, &eq, &e) == NOX_HOST_ERR_INVALID_HANDLE);
      nox_host_module_fini_cl(c2); nox_host_context_destroy(c2);
      CHECK(nox_host_handle_release(c, p) == NOX_HOST_OK && nox_host_handle_release(c, sub) == NOX_HOST_OK); }

    /* hata yolları */
    { NoxHostValue iv = 0; NoxHostHandle h = 0; NoxHostSpan sp = {0};
      CHECK(nox_host_value_int(c, 3, &iv) == NOX_HOST_OK);
      CHECK(nox_host_value_get_handle(c, iv, &h) == NOX_HOST_ERR_INVAL && h == 0);
      CHECK(nox_host_value_release(c, iv) == NOX_HOST_OK);
      CHECK(nox_host_handle_type_name(c, 0, &sp) == NOX_HOST_ERR_INVALID_HANDLE);
      NoxHostHandle gone = mk(c, 1, "g");
      CHECK(nox_host_handle_release(c, gone) == NOX_HOST_OK);
      CHECK(nox_host_handle_type_name(c, gone, &sp) == NOX_HOST_ERR_INVALID_HANDLE);
      CHECK(nox_host_value_handle(c, gone, &iv) == NOX_HOST_ERR_INVALID_HANDLE); }

    /* açık bırakılan HANDLE değeri + açık tutamaç bağlam yok edilirken bırakılır (sızıntı/çift bırakma yok) */
    { NoxHostValue open_v = 0; CHECK(nox_host_value_handle(c, a, &open_v) == NOX_HOST_OK); }
    CHECK(nox_host_handle_release(c, a) == NOX_HOST_OK);
    nox_host_module_fini_cl(c);
    nox_host_context_destroy(c);
    if (g_fail) { printf("%d failure(s)\n", g_fail); return 1; }
    printf("ALL OK\n");
    return 0;
}
