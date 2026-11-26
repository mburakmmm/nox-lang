/* UR-010: NoxHostCallbackOps — host nesnesi çağırma, yeniden giriş (kilit açık), host istisnası + jeton, retain/release dengesi. */
#include "nox_host.h"
#include <stdio.h>
#include <string.h>

NoxHostStatus nox_host_module_init_cb(NoxHostContext *ctx, NoxHostError **err);
void nox_host_module_fini_cb(NoxHostContext *ctx);
NoxHostStatus nox_host_export_cb_add(NoxHostContext *, int64_t, int64_t, int64_t *, NoxHostError **);
NoxHostStatus nox_host_export_cb_apply_twice(NoxHostContext *, NoxHostExternalRef, int64_t, int64_t *, NoxHostError **);
NoxHostStatus nox_host_export_cb_describe(NoxHostContext *, NoxHostExternalRef, const uint8_t *, size_t, double, NoxHostBuffer *, NoxHostError **);
NoxHostStatus nox_host_export_cb_try_call(NoxHostContext *, NoxHostExternalRef, NoxHostBuffer *, NoxHostError **);
NoxHostStatus nox_host_export_cb_call_uncaught(NoxHostContext *, NoxHostExternalRef, int64_t *, NoxHostError **);
NoxHostStatus nox_host_export_cb_passthrough(NoxHostContext *, NoxHostExternalRef, NoxHostExternalRef *, NoxHostError **);
NoxHostStatus nox_host_export_cb_call_all(NoxHostContext *, NoxHostValue, int64_t, NoxHostValue *, NoxHostError **);
NoxHostStatus nox_host_export_cb_maybe(NoxHostContext *, NoxHostValue, int64_t *, NoxHostError **);
NoxHostStatus nox_host_export_cb_child(NoxHostContext *, NoxHostExternalRef, NoxHostExternalRef *, NoxHostError **);

static int g_fail;
#define CHECK(c) do { if (!(c)) { printf("FAIL line %d: %s\n", __LINE__, #c); g_fail++; } } while (0)

/* host nesne tablosu: ref -> (tür, sayaçlar) */
enum { DOUBLER = 1, DESCRIBER = 2, RAISER = 3, REENTER = 4, NONER = 5, PARENT = 6, CHILD = 7, ERRTOK = 100 };
static int g_retain[256], g_release[256];
static int g_invoked;

static void on_retain(void *ud, NoxHostExternalRef r) { (void)ud; g_retain[r]++; }
static void on_release(void *ud, NoxHostExternalRef r) { (void)ud; g_release[r]++; }

static NoxHostStatus on_invoke(void *ud, NoxHostContext *ctx, NoxHostExternalRef target, NoxHostValue args,
                               NoxHostValue *out, uint64_t *tok, NoxHostBuffer *msg) {
    (void)ud; g_invoked++;
    size_t n = 0; nox_host_value_len(ctx, args, &n);
    switch (target) {
    case DOUBLER: { NoxHostValue a = 0; int64_t x = 0;
        if (n != 1 || nox_host_value_item(ctx, args, 0, &a) != NOX_HOST_OK) return NOX_HOST_ERR_INVAL;
        nox_host_value_get_int(ctx, a, &x); nox_host_value_release(ctx, a);
        return nox_host_value_int(ctx, x * 2, out); }
    case DESCRIBER: { NoxHostValue s = 0, f = 0, b = 0, z = 0; NoxHostSpan sp; double d = 0; int64_t bb = 0; int32_t k = -1; char buf[128];
        if (n != 4) return NOX_HOST_ERR_INVAL;
        nox_host_value_item(ctx, args, 0, &s); nox_host_value_item(ctx, args, 1, &f); nox_host_value_item(ctx, args, 2, &b); nox_host_value_item(ctx, args, 3, &z);
        nox_host_value_get_span(ctx, s, &sp); nox_host_value_get_float(ctx, f, &d); nox_host_value_get_int(ctx, b, &bb); nox_host_value_kind(ctx, z, &k);
        snprintf(buf, sizeof buf, "%.*s|%.1f|%lld|%d", (int)sp.len, (const char *)sp.data, d, (long long)bb, (int)k);
        nox_host_value_release(ctx, s); nox_host_value_release(ctx, f); nox_host_value_release(ctx, b); nox_host_value_release(ctx, z);
        return nox_host_value_str(ctx, (const uint8_t *)buf, strlen(buf), 0, out); }
    case RAISER: { static const char m[] = "boom from host";
        *tok = ERRTOK; g_retain[ERRTOK]++; /* jeton +1 Nox'a geçer */
        msg->data = (uint8_t *)m; msg->len = sizeof m - 1; /* ödünç: invoke dönünce kopyalanır */
        return NOX_HOST_ERR_HOST_EXCEPTION; }
    case REENTER: { /* geri çağrı içinden AYNI bağlamdaki Nox işlevini çağır: kilit açık olmalı */
        int64_t r = 0; NoxHostError *e = NULL;
        if (nox_host_export_cb_add(ctx, 40, 2, &r, &e) != NOX_HOST_OK) return NOX_HOST_ERR_STATE;
        return nox_host_value_int(ctx, r, out); }
    case NONER: return NOX_HOST_OK; /* *out == 0 → None */
    case PARENT: return nox_host_value_external_ref(ctx, CHILD, out);
    default: return NOX_HOST_ERR_INVAL;
    }
}

static int span_eq(NoxHostBuffer b, const char *s) { return b.len == strlen(s) && memcmp(b.data, s, b.len) == 0; }

int main(void) {
    NoxHostContextConfig cfg = { sizeof cfg, NOX_HOST_ABI_VERSION, NULL };
    NoxHostContext *c = NULL; NoxHostError *e = NULL;
    NoxHostCallbackOps ops = { sizeof ops, NULL, on_invoke, on_retain, on_release };
    CHECK(sizeof(NoxHostCallbackOps) == 40);
    CHECK(nox_host_context_create(&cfg, &c) == NOX_HOST_OK);
    CHECK(nox_host_module_init_cb(c, &e) == NOX_HOST_OK);

    /* geri çağrı kurulmadan: RuntimeError (çökme yok) */
    { int64_t r = 0; NoxHostSpan sp;
      CHECK(nox_host_export_cb_apply_twice(c, DOUBLER, 1, &r, &e) == NOX_HOST_ERR_EXCEPTION && e);
      CHECK(nox_host_error_class_name(e, &sp) == NOX_HOST_OK && sp.len == 12 && memcmp(sp.data, "RuntimeError", 12) == 0);
      CHECK(nox_host_error_host_token(e) == 0);
      nox_host_error_release(e); e = NULL; }
    /* geçersiz tablo reddedilir */
    { NoxHostCallbackOps bad = { 8, NULL, on_invoke, NULL, NULL }; CHECK(nox_host_context_set_callbacks(c, &bad) == NOX_HOST_ERR_VERSION); }
    { NoxHostCallbackOps bad = { sizeof bad, NULL, NULL, NULL, NULL }; CHECK(nox_host_context_set_callbacks(c, &bad) == NOX_HOST_ERR_INVAL); }
    CHECK(nox_host_context_set_callbacks(c, &ops) == NOX_HOST_OK);

    /* host nesnesini iki kez çağır */
    { int64_t r = 0; CHECK(nox_host_export_cb_apply_twice(c, DOUBLER, 5, &r, &e) == NOX_HOST_OK && r == 20); }
    CHECK(g_retain[DOUBLER] == g_release[DOUBLER] && g_retain[DOUBLER] > 0); /* HostObject ömrü dengeli */

    /* çok türlü argümanlar */
    { NoxHostBuffer b = {0};
      CHECK(nox_host_export_cb_describe(c, DESCRIBER, (const uint8_t *)"ann", 3, 2.5, &b, &e) == NOX_HOST_OK && span_eq(b, "ann|2.5|1|0"));
      nox_host_buffer_release(&b); }

    /* yeniden giriş: geri çağrı içinden aynı bağlama çağrı (kilitlenme yok) */
    { int64_t r = 0; CHECK(nox_host_export_cb_call_uncaught(c, REENTER, &r, &e) == NOX_HOST_OK && r == 42); }

    /* host istisnası Nox içinde yakalanır */
    { NoxHostBuffer b = {0}; CHECK(nox_host_export_cb_try_call(c, RAISER, &b, &e) == NOX_HOST_OK && span_eq(b, "caught: boom from host")); nox_host_buffer_release(&b); }
    CHECK(g_retain[ERRTOK] == g_release[ERRTOK] && g_retain[ERRTOK] == 1); /* jeton, HostError yok edilince bırakıldı */

    /* yakalanmayan host istisnası: ERR_HOST_EXCEPTION + jeton */
    { int64_t r = 0; NoxHostSpan sp;
      int before = g_release[ERRTOK];
      CHECK(nox_host_export_cb_call_uncaught(c, RAISER, &r, &e) == NOX_HOST_ERR_HOST_EXCEPTION && e);
      CHECK(nox_host_error_host_token(e) == ERRTOK);
      CHECK(nox_host_error_message(e, &sp) == NOX_HOST_OK && sp.len == 14 && memcmp(sp.data, "boom from host", 14) == 0);
      CHECK(g_release[ERRTOK] == before); /* jeton hata bırakılana kadar yaşar */
      nox_host_error_release(e); e = NULL;
      CHECK(g_release[ERRTOK] == before + 1); }
    CHECK(g_retain[ERRTOK] == g_release[ERRTOK]);

    /* None sonuç → Nox tarafında ValueError (as_int) */
    { int64_t r = 0; CHECK(nox_host_export_cb_call_uncaught(c, NONER, &r, &e) == NOX_HOST_ERR_EXCEPTION && e); nox_host_error_release(e); e = NULL; }

    /* HostObject dönüşü: host yeni bir başvuru alır (kendi release'ini çağırır) */
    { NoxHostExternalRef out = 0; int rb = g_retain[DOUBLER], rl = g_release[DOUBLER];
      CHECK(nox_host_export_cb_passthrough(c, DOUBLER, &out, &e) == NOX_HOST_OK && out == DOUBLER);
      CHECK(g_retain[DOUBLER] - rb == 2 && g_release[DOUBLER] - rl == 1); /* ctor + export_ref retain; ctor sahibi bırakıldı */ }
    g_release[DOUBLER]++; /* host kendi başvurusunu bırakır */

    /* list[HostObject] ve HostObject | None */
    { NoxHostValue l = 0, out = 0, r0 = 0, r1 = 0, x = 0; int64_t v0 = 0, v1 = 0;
      CHECK(nox_host_value_container(c, NOX_HOST_VALUE_LIST, &l) == NOX_HOST_OK);
      CHECK(nox_host_value_external_ref(c, DOUBLER, &x) == NOX_HOST_OK && nox_host_value_append(c, l, x) == NOX_HOST_OK && nox_host_value_release(c, x) == NOX_HOST_OK);
      CHECK(nox_host_value_external_ref(c, REENTER, &x) == NOX_HOST_OK && nox_host_value_append(c, l, x) == NOX_HOST_OK && nox_host_value_release(c, x) == NOX_HOST_OK);
      /* REENTER hedefi tek argüman almıyor ama argümanı yok sayar */
      CHECK(nox_host_export_cb_call_all(c, l, 7, &out, &e) == NOX_HOST_OK);
      CHECK(nox_host_value_item(c, out, 0, &r0) == NOX_HOST_OK && nox_host_value_get_int(c, r0, &v0) == NOX_HOST_OK && v0 == 14);
      CHECK(nox_host_value_item(c, out, 1, &r1) == NOX_HOST_OK && nox_host_value_get_int(c, r1, &v1) == NOX_HOST_OK && v1 == 42);
      nox_host_value_release(c, r0); nox_host_value_release(c, r1); nox_host_value_release(c, out); nox_host_value_release(c, l);
      NoxHostValue none = 0; int64_t m = 0;
      CHECK(nox_host_value_none(c, &none) == NOX_HOST_OK && nox_host_export_cb_maybe(c, none, &m, &e) == NOX_HOST_OK && m == -1);
      nox_host_value_release(c, none);
      CHECK(nox_host_value_external_ref(c, REENTER, &x) == NOX_HOST_OK && nox_host_export_cb_maybe(c, x, &m, &e) == NOX_HOST_OK && m == 42);
      NoxHostExternalRef got = 0; CHECK(nox_host_value_get_external_ref(c, x, &got) == NOX_HOST_OK && got == REENTER);
      nox_host_value_release(c, x); }

    /* sonuç olarak dönen host nesnesi */
    { NoxHostExternalRef ch = 0; CHECK(nox_host_export_cb_child(c, PARENT, &ch, &e) == NOX_HOST_OK && ch == CHILD); g_release[CHILD]++; }

    /* geçersiz kullanım */
    { NoxHostValue v = 0; CHECK(nox_host_value_external_ref(c, 0, &v) == NOX_HOST_ERR_INVAL);
      CHECK(nox_host_value_int(c, 1, &v) == NOX_HOST_OK);
      NoxHostExternalRef r = 9; CHECK(nox_host_value_get_external_ref(c, v, &r) == NOX_HOST_ERR_INVAL && r == 0);
      nox_host_value_release(c, v); }

    nox_host_module_fini_cb(c);
    nox_host_context_destroy(c);
    for (int i = 0; i < 256; i++) if (g_retain[i] != g_release[i]) { printf("FAIL unbalanced ref %d: retain %d release %d\n", i, g_retain[i], g_release[i]); g_fail++; }
    if (g_fail) { printf("%d failure(s)\n", g_fail); return 1; }
    printf("ALL OK\n");
    return 0;
}
