#include "nox_host.h"
#include <stdio.h>
#include <string.h>
#include <pthread.h>
NoxHostStatus nox_host_module_init_fm(NoxHostContext *ctx, NoxHostError **err);
void nox_host_module_fini_fm(NoxHostContext *ctx);
NoxHostStatus nox_host_export_fm_add(NoxHostContext *, int64_t, int64_t, int64_t *, NoxHostError **);
NoxHostStatus nox_host_export_fm_scale(NoxHostContext *, double, double, double *, NoxHostError **);
NoxHostStatus nox_host_export_fm_is_even(NoxHostContext *, int64_t, uint8_t *, NoxHostError **);
NoxHostStatus nox_host_export_fm_greet(NoxHostContext *, const uint8_t *, size_t, NoxHostBuffer *, NoxHostError **);
NoxHostStatus nox_host_export_fm_total(NoxHostContext *, const uint8_t *, size_t, int64_t *, NoxHostError **);
NoxHostStatus nox_host_export_fm_rev(NoxHostContext *, const uint8_t *, size_t, NoxHostBuffer *, NoxHostError **);
NoxHostStatus nox_host_export_fm_boom(NoxHostContext *, const uint8_t *, size_t, NoxHostError **);
NoxHostStatus nox_host_export_fm_idiv(NoxHostContext *, int64_t, int64_t, int64_t *, NoxHostError **);
NoxHostStatus nox_host_export_fm_noop(NoxHostContext *, NoxHostError **);
NoxHostStatus nox_host_export_fm_bump(NoxHostContext *, int64_t *, NoxHostError **);
NoxHostStatus nox_host_export_fm_make_point(NoxHostContext *, int64_t, int64_t, NoxHostHandle *, NoxHostError **);
NoxHostStatus nox_host_export_fm_point_sum(NoxHostContext *, NoxHostHandle, int64_t *, NoxHostError **);
NoxHostStatus nox_host_export_fm_point_move(NoxHostContext *, NoxHostHandle, int64_t, NoxHostError **);

/* UR-004: bir bağlam herhangi bir iş parçacığından (sırayla) kullanılabilir; her iş parçacığı kendi bağlamını kurarak paralel çalışabilir. */
#define NTHREADS 8
#define NITERS 300
static NoxHostContext *g_shared;
static int g_thread_fail;
static void *shared_worker(void *arg) {
    long id = (long)arg;
    for (int k = 0; k < NITERS; k++) {
        int64_t r = 0; NoxHostError *e = NULL; NoxHostBuffer b = {0};
        if (nox_host_export_fm_add(g_shared, id, k, &r, &e) != NOX_HOST_OK || r != id + k) { g_thread_fail++; return NULL; }
        if (nox_host_export_fm_greet(g_shared, (const uint8_t *)"t", 1, &b, &e) != NOX_HOST_OK || b.len != 8) { g_thread_fail++; return NULL; }
        nox_host_buffer_release(&b);
        if (k % 50 == 0) {
            if (nox_host_export_fm_boom(g_shared, (const uint8_t *)"x", 1, &e) != NOX_HOST_ERR_EXCEPTION || !e) { g_thread_fail++; return NULL; }
            nox_host_error_release(e);
        }
    }
    return NULL;
}
static void *own_worker(void *arg) {
    long id = (long)arg;
    NoxHostContextConfig cfg = { sizeof cfg, NOX_HOST_ABI_VERSION, NULL };
    NoxHostContext *c = NULL; NoxHostError *e = NULL;
    if (nox_host_context_create(&cfg, &c) != NOX_HOST_OK) { g_thread_fail++; return NULL; }
    if (nox_host_module_init_fm(c, &e) != NOX_HOST_OK) { g_thread_fail++; return NULL; }
    for (int k = 0; k < NITERS; k++) {
        int64_t r = 0;
        if (nox_host_export_fm_bump(c, &r, &e) != NOX_HOST_OK || r != k + 1) { g_thread_fail++; break; } /* modül globali bağlam başına */
        if (nox_host_export_fm_add(c, id, 1, &r, &e) != NOX_HOST_OK || r != id + 1) { g_thread_fail++; break; }
    }
    nox_host_module_fini_fm(c);
    nox_host_context_destroy(c);
    return NULL;
}
static int thread_tests(void) {
    NoxHostContextConfig cfg = { sizeof cfg, NOX_HOST_ABI_VERSION, NULL };
    NoxHostError *e = NULL;
    pthread_t th[NTHREADS];
    g_thread_fail = 0;
    if (nox_host_context_create(&cfg, &g_shared) != NOX_HOST_OK || nox_host_module_init_fm(g_shared, &e) != NOX_HOST_OK) return 1;
    for (long i = 0; i < NTHREADS; i++) pthread_create(&th[i], NULL, shared_worker, (void *)i);
    for (int i = 0; i < NTHREADS; i++) pthread_join(th[i], NULL);
    nox_host_module_fini_fm(g_shared);
    nox_host_context_destroy(g_shared);
    for (long i = 0; i < NTHREADS; i++) pthread_create(&th[i], NULL, own_worker, (void *)i);
    for (int i = 0; i < NTHREADS; i++) pthread_join(th[i], NULL);
    return g_thread_fail;
}
static int fails = 0;
#define CHECK(c) do { if (!(c)) { printf("FAIL line %d: %s\n", __LINE__, #c); fails++; } } while (0)
int main(void) {
    NoxHostContextConfig cfg = { sizeof cfg, NOX_HOST_ABI_VERSION, NULL };
    NoxHostContext *ctx = NULL;
    CHECK(nox_host_context_create(&cfg, &ctx) == NOX_HOST_OK && ctx);
    NoxHostError *err = NULL;
    CHECK(nox_host_module_init_fm(ctx, &err) == NOX_HOST_OK);
    int64_t i = 0; double d = 0; uint8_t b = 9; NoxHostBuffer buf = {0};
    CHECK(nox_host_export_fm_add(ctx, 20, 22, &i, &err) == NOX_HOST_OK && i == 42);
    CHECK(nox_host_export_fm_scale(ctx, 1.5, 4.0, &d, &err) == NOX_HOST_OK && d == 6.0);
    CHECK(nox_host_export_fm_is_even(ctx, 10, &b, &err) == NOX_HOST_OK && b == 1);
    CHECK(nox_host_export_fm_is_even(ctx, 7, &b, &err) == NOX_HOST_OK && b == 0);
    CHECK(nox_host_export_fm_greet(ctx, (const uint8_t *)"w\xc3\xb6rld", 6, &buf, &err) == NOX_HOST_OK && buf.len == 13 && memcmp(buf.data, "hello, w\xc3\xb6rld", 13) == 0);
    nox_host_buffer_release(&buf);
    CHECK(nox_host_export_fm_greet(ctx, (const uint8_t *)"\xff\xfe", 2, &buf, &err) == NOX_HOST_ERR_UTF8);
    const uint8_t raw[5] = {1, 0, 255, 0, 3};
    CHECK(nox_host_export_fm_total(ctx, raw, 5, &i, &err) == NOX_HOST_OK && i == 259);
    CHECK(nox_host_export_fm_rev(ctx, raw, 5, &buf, &err) == NOX_HOST_OK && buf.len == 5 && buf.data[0] == 3 && buf.data[1] == 0 && buf.data[2] == 255 && buf.data[4] == 1);
    nox_host_buffer_release(&buf);
    CHECK(nox_host_export_fm_total(ctx, NULL, 0, &i, &err) == NOX_HOST_OK && i == 0);
    NoxHostSpan sp;
    CHECK(nox_host_export_fm_boom(ctx, (const uint8_t *)"bad input", 9, &err) == NOX_HOST_ERR_EXCEPTION && err);
    CHECK(nox_host_error_class_name(err, &sp) == NOX_HOST_OK && sp.len == 10 && memcmp(sp.data, "ValueError", 10) == 0);
    CHECK(nox_host_error_message(err, &sp) == NOX_HOST_OK && sp.len == 9 && memcmp(sp.data, "bad input", 9) == 0);
    CHECK(nox_host_error_line(err) > 0);
    nox_host_error_release(err); err = NULL;
    CHECK(nox_host_export_fm_idiv(ctx, 7, 0, &i, &err) == NOX_HOST_ERR_EXCEPTION && err);
    nox_host_error_class_name(err, &sp); printf("idiv(7,0): %.*s line %lld\n", (int)sp.len, sp.data, (long long)nox_host_error_line(err));
    nox_host_error_release(err); err = NULL;
    CHECK(nox_host_export_fm_idiv(ctx, 7, 2, &i, NULL) == NOX_HOST_OK && i == 3);
    CHECK(nox_host_export_fm_boom(ctx, (const uint8_t *)"x", 1, NULL) == NOX_HOST_ERR_EXCEPTION);
    CHECK(nox_host_export_fm_noop(ctx, &err) == NOX_HOST_OK);
    CHECK(nox_host_export_fm_bump(ctx, &i, &err) == NOX_HOST_OK && i == 1);
    CHECK(nox_host_export_fm_bump(ctx, &i, &err) == NOX_HOST_OK && i == 2);
    CHECK(nox_host_export_fm_add(NULL, 1, 2, &i, &err) == NOX_HOST_ERR_INVAL);
    /* UR-006: sınıf örnekleri handle olarak; nesil denetimi ve sahip doğrulaması */
    NoxHostHandle p1 = 0, p2 = 0;
    CHECK(nox_host_export_fm_make_point(ctx, 3, 4, &p1, &err) == NOX_HOST_OK && p1 != 0);
    CHECK(nox_host_export_fm_point_sum(ctx, p1, &i, &err) == NOX_HOST_OK && i == 7);
    CHECK(nox_host_export_fm_point_move(ctx, p1, 10, &err) == NOX_HOST_OK);
    CHECK(nox_host_export_fm_point_sum(ctx, p1, &i, &err) == NOX_HOST_OK && i == 17);
    CHECK(nox_host_handle_retain(ctx, p1, &p2) == NOX_HOST_OK && p2 != 0 && p2 != p1);
    CHECK(nox_host_handle_release(ctx, p1) == NOX_HOST_OK);
    CHECK(nox_host_export_fm_point_sum(ctx, p1, &i, &err) == NOX_HOST_ERR_INVALID_HANDLE);   /* bırakılmış */
    CHECK(nox_host_handle_release(ctx, p1) == NOX_HOST_ERR_INVALID_HANDLE);                 /* çift bırakma */
    CHECK(nox_host_export_fm_point_sum(ctx, p2, &i, &err) == NOX_HOST_OK && i == 17);        /* ikinci handle hâlâ geçerli */
    CHECK(nox_host_handle_is_valid(ctx, p2) == 1 && nox_host_handle_is_valid(ctx, 12345) == 0);
    CHECK(nox_host_export_fm_point_sum(ctx, 0xDEADBEEFCAFEull, &i, &err) == NOX_HOST_ERR_INVALID_HANDLE); /* sahte */
    {
        NoxHostContext *other = NULL;
        CHECK(nox_host_context_create(&cfg, &other) == NOX_HOST_OK && nox_host_module_init_fm(other, &err) == NOX_HOST_OK);
        CHECK(nox_host_export_fm_point_sum(other, p2, &i, &err) == NOX_HOST_ERR_INVALID_HANDLE); /* başka bağlamın handle'ı */
        nox_host_module_fini_fm(other);
        nox_host_context_destroy(other);
    }
    CHECK(nox_host_handle_release(ctx, p2) == NOX_HOST_OK);
    NoxHostHandle p3 = 0; /* yuva yeniden kullanılır ama nesil farklıdır: eski handle geçersiz kalır */
    CHECK(nox_host_export_fm_make_point(ctx, 1, 1, &p3, &err) == NOX_HOST_OK && p3 != p2);
    CHECK(nox_host_export_fm_point_sum(ctx, p2, &i, &err) == NOX_HOST_ERR_INVALID_HANDLE);
    /* p3 bilerek açık bırakılır: nox_host_context_destroy onu otomatik bırakır */
    nox_host_module_fini_fm(ctx);
    nox_host_context_destroy(ctx);
    CHECK(thread_tests() == 0);
    printf(fails ? "FAILED (%d)\n" : "ALL OK\n", fails);
    return fails != 0;
}
