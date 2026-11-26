/* UR-015 (kurtarılabilir taşma) + UR-013 (host ayırıcısı, yetenek yoklaması, bağlam yalıtımı). */
#include "nox_host.h"
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

NoxHostStatus nox_host_module_init_tr(NoxHostContext *ctx, NoxHostError **err);
void nox_host_module_fini_tr(NoxHostContext *ctx);
NoxHostStatus nox_host_export_tr_add(NoxHostContext *, int64_t, int64_t, int64_t *, NoxHostError **);
NoxHostStatus nox_host_export_tr_sub(NoxHostContext *, int64_t, int64_t, int64_t *, NoxHostError **);
NoxHostStatus nox_host_export_tr_mul(NoxHostContext *, int64_t, int64_t, int64_t *, NoxHostError **);
NoxHostStatus nox_host_export_tr_narrow(NoxHostContext *, int64_t, int64_t *, NoxHostError **);
NoxHostStatus nox_host_export_tr_guarded(NoxHostContext *, int64_t, int64_t, int64_t *, NoxHostError **);
NoxHostStatus nox_host_export_tr_with_finally(NoxHostContext *, int64_t, int64_t, int64_t *, NoxHostError **);
NoxHostStatus nox_host_export_tr_loop_sum(NoxHostContext *, int64_t, int64_t, int64_t *, NoxHostError **);

static int g_fail;
#define CHECK(c) do { if (!(c)) { printf("FAIL line %d: %s\n", __LINE__, #c); g_fail++; } } while (0)

static int is_overflow(NoxHostStatus st, NoxHostError *e) {
    NoxHostSpan sp = {0};
    if (st != NOX_HOST_ERR_OVERFLOW || !e) return 0;
    if (nox_host_error_class_name(e, &sp) != NOX_HOST_OK || sp.len != 13 || memcmp(sp.data, "OverflowError", 13) != 0) return 0;
    if (nox_host_error_message(e, &sp) != NOX_HOST_OK || sp.len < 16 || memcmp(sp.data, "integer overflow", 16) != 0) return 0;
    return nox_host_error_host_token(e) == 0;
}

/* sayaçlı host ayırıcısı */
typedef struct { size_t allocs, frees; long live_bytes; pthread_mutex_t mu; } Counting;
static void *c_alloc(void *ud, size_t len, size_t align) {
    Counting *c = ud; void *p = NULL;
    if (align < sizeof(void *)) align = sizeof(void *);
    if (posix_memalign(&p, align, len ? len : 1) != 0) return NULL;
    pthread_mutex_lock(&c->mu); c->allocs++; c->live_bytes += (long)len; pthread_mutex_unlock(&c->mu);
    return p;
}
static void c_free(void *ud, void *p, size_t len, size_t align) {
    Counting *c = ud; (void)align;
    pthread_mutex_lock(&c->mu); c->frees++; c->live_bytes -= (long)len; pthread_mutex_unlock(&c->mu);
    free(p);
}

typedef struct { int ok; } Worker;
static void *worker(void *arg) {
    Worker *w = arg; w->ok = 1;
    NoxHostContextConfig cfg = { sizeof cfg, NOX_HOST_ABI_VERSION, NULL };
    NoxHostContext *c = NULL; NoxHostError *e = NULL;
    if (nox_host_context_create(&cfg, &c) != NOX_HOST_OK || nox_host_module_init_tr(c, &e) != NOX_HOST_OK) { w->ok = 0; return NULL; }
    for (int i = 0; i < 3000; i++) {
        int64_t r = 0;
        if (nox_host_export_tr_add(c, i, 1, &r, &e) != NOX_HOST_OK || r != i + 1) w->ok = 0;
        if (i % 500 == 0) {
            if (!is_overflow(nox_host_export_tr_add(c, INT64_MAX, i + 1, &r, &e), e)) w->ok = 0;
            nox_host_error_release(e); e = NULL;
        }
    }
    nox_host_module_fini_tr(c); nox_host_context_destroy(c);
    return NULL;
}

int main(void) {
    NoxHostContextConfig cfg = { sizeof cfg, NOX_HOST_ABI_VERSION, NULL };
    NoxHostContext *c = NULL, *c2 = NULL; NoxHostError *e = NULL; int64_t r = 0;

    /* yetenek yoklaması */
    { uint64_t caps = nox_host_capabilities();
      CHECK((caps & NOX_HOST_CAP_VALUE_TREE) && (caps & NOX_HOST_CAP_CLASSES) && (caps & NOX_HOST_CAP_CALLBACKS) && (caps & NOX_HOST_CAP_ASYNC_TASKS));
      CHECK((caps & NOX_HOST_CAP_PINNED_BUFFERS) && (caps & NOX_HOST_CAP_TYPED_ARRAYS) && (caps & NOX_HOST_CAP_CUSTOM_ALLOCATOR) && (caps & NOX_HOST_CAP_SUBINTERPRETERS));
      CHECK(caps & NOX_HOST_CAP_RECOVERABLE_TRAPS); }
    /* düzen: donmuş durum kodları */
    CHECK(NOX_HOST_ERR_BUSY == 10 && NOX_HOST_ERR_OVERFLOW == 11 && NOX_HOST_ERR_CANCELLED == 9 && NOX_HOST_ERR_HOST_EXCEPTION == 8);

    CHECK(nox_host_context_create(&cfg, &c) == NOX_HOST_OK && nox_host_module_init_tr(c, &e) == NOX_HOST_OK);
    CHECK(nox_host_context_create(&cfg, &c2) == NOX_HOST_OK && nox_host_module_init_tr(c2, &e) == NOX_HOST_OK);

    /* taşma: süreç yaşar, hata ayrıntısı verir, bağlam sağlıklı kalır */
    CHECK(is_overflow(nox_host_export_tr_add(c, INT64_MAX, 1, &r, &e), e)); nox_host_error_release(e); e = NULL;
    CHECK(nox_host_export_tr_add(c, 20, 22, &r, &e) == NOX_HOST_OK && r == 42);
    CHECK(is_overflow(nox_host_export_tr_sub(c, INT64_MIN, 1, &r, &e), e)); nox_host_error_release(e); e = NULL;
    CHECK(is_overflow(nox_host_export_tr_mul(c, INT64_MAX, 2, &r, &e), e)); nox_host_error_release(e); e = NULL;
    CHECK(is_overflow(nox_host_export_tr_mul(c, INT64_MIN, -1, &r, &e), e)); nox_host_error_release(e); e = NULL;
    CHECK(nox_host_export_tr_mul(c, 3, 4, &r, &e) == NOX_HOST_OK && r == 12);
    CHECK(nox_host_export_tr_mul(c, -3, 4, &r, &e) == NOX_HOST_OK && r == -12);
    CHECK(nox_host_export_tr_sub(c, INT64_MIN, -1, &r, &e) == NOX_HOST_OK && r == INT64_MIN + 1);
    CHECK(nox_host_export_tr_add(c, INT64_MAX, INT64_MIN, &r, &e) == NOX_HOST_OK && r == -1);
    CHECK(is_overflow(nox_host_export_tr_narrow(c, (int64_t)1 << 40, &r, &e), e)); nox_host_error_release(e); e = NULL; /* i32(x) daraltma */
    CHECK(nox_host_export_tr_narrow(c, 1234, &r, &e) == NOX_HOST_OK && r == 1234);
    /* except ile YAKALANAMAZ (tuzak sınıf değil), finally çalışır, döngü içinde de çıkar */
    CHECK(is_overflow(nox_host_export_tr_guarded(c, INT64_MAX, 1, &r, &e), e)); nox_host_error_release(e); e = NULL;
    CHECK(nox_host_export_tr_guarded(c, 1, 2, &r, &e) == NOX_HOST_OK && r == 3);
    CHECK(is_overflow(nox_host_export_tr_with_finally(c, INT64_MAX, 1, &r, &e), e)); nox_host_error_release(e); e = NULL;
    CHECK(is_overflow(nox_host_export_tr_loop_sum(c, 5, INT64_MAX, &r, &e), e)); nox_host_error_release(e); e = NULL;
    CHECK(nox_host_export_tr_loop_sum(c, 3, 10, &r, &e) == NOX_HOST_OK && r == 30);
    CHECK(nox_host_export_tr_add(c, 20, 22, &r, &e) == NOX_HOST_OK && r == 42);
    /* e == NULL ile (ayrıntı istenmiyor) */
    CHECK(nox_host_export_tr_add(c, INT64_MAX, 1, &r, NULL) == NOX_HOST_ERR_OVERFLOW);
    /* ikinci bağlam etkilenmedi */
    CHECK(nox_host_export_tr_add(c2, 1, 2, &r, &e) == NOX_HOST_OK && r == 3);
    nox_host_module_fini_tr(c); nox_host_context_destroy(c);
    CHECK(nox_host_export_tr_add(c2, 5, 6, &r, &e) == NOX_HOST_OK && r == 11);
    nox_host_module_fini_tr(c2); nox_host_context_destroy(c2);

    /* UR-013: host ayırıcısı — Nox'un yönetilen heap'i oradan beslenir ve bağlam yok edilince tamamen geri verilir */
    { Counting cnt = { 0, 0, 0, PTHREAD_MUTEX_INITIALIZER };
      NoxHostAllocator ha = { sizeof ha, &cnt, c_alloc, c_free };
      NoxHostContextConfig acfg = { sizeof acfg, NOX_HOST_ABI_VERSION, &ha };
      NoxHostContext *ca = NULL;
      CHECK(nox_host_context_create(&acfg, &ca) == NOX_HOST_OK && nox_host_module_init_tr(ca, &e) == NOX_HOST_OK);
      for (int i = 0; i < 200; i++) CHECK(nox_host_export_tr_add(ca, i, 1, &r, &e) == NOX_HOST_OK && r == i + 1);
      CHECK(is_overflow(nox_host_export_tr_add(ca, INT64_MAX, 1, &r, &e), e)); nox_host_error_release(e); e = NULL;
      CHECK(cnt.allocs > 0);
      nox_host_module_fini_tr(ca); nox_host_context_destroy(ca);
      CHECK(cnt.allocs == cnt.frees && cnt.live_bytes == 0);
      /* sürüm/şekil denetimleri */
      NoxHostContextConfig old = { sizeof old, 2, &ha };       CHECK(nox_host_context_create(&old, &ca) == NOX_HOST_ERR_INVAL); /* v2 ana makinesi ayırıcı veremez */
      NoxHostAllocator bad = { sizeof bad, NULL, NULL, c_free }; NoxHostContextConfig bcfg = { sizeof bcfg, 3, &bad };
      CHECK(nox_host_context_create(&bcfg, &ca) == NOX_HOST_ERR_INVAL);
      NoxHostAllocator small = { 4, NULL, c_alloc, c_free };   NoxHostContextConfig scfg = { sizeof scfg, 3, &small };
      CHECK(nox_host_context_create(&scfg, &ca) == NOX_HOST_ERR_VERSION); }
    /* v1/v2 ana makineleri (NULL ayırıcı) çalışmaya devam eder */
    { NoxHostContextConfig v1 = { sizeof v1, 1, NULL }, v2 = { sizeof v2, 2, NULL }; NoxHostContext *x = NULL;
      CHECK(nox_host_context_create(&v1, &x) == NOX_HOST_OK); nox_host_context_destroy(x);
      CHECK(nox_host_context_create(&v2, &x) == NOX_HOST_OK); nox_host_context_destroy(x);
      NoxHostContextConfig v9 = { sizeof v9, 4, NULL }; CHECK(nox_host_context_create(&v9, &x) == NOX_HOST_ERR_VERSION); }

    /* UR-013: bağlam yalıtımı — farklı iş parçacıklarındaki bağımsız bağlamlar hiçbir durumu paylaşmaz (alt yorumlayıcı vekili) */
    { pthread_t th[4]; Worker w[4];
      for (int i = 0; i < 4; i++) pthread_create(&th[i], NULL, worker, &w[i]);
      for (int i = 0; i < 4; i++) { pthread_join(th[i], NULL); CHECK(w[i].ok); } }

    if (g_fail) { printf("%d failure(s)\n", g_fail); return 1; }
    printf("ALL OK\n");
    return 0;
}
