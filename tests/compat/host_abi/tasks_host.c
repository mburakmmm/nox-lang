/* UR-011: `@export async def` — nox_host_async_start_*, on_done, take_result, cancel, release, ctx kilidinin görev beklerken açık olması, çıkmaz koruması. */
#include "nox_host.h"
#include <pthread.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

NoxHostStatus nox_host_module_init_tk(NoxHostContext *ctx, NoxHostError **err);
void nox_host_module_fini_tk(NoxHostContext *ctx);
NoxHostStatus nox_host_async_start_tk_add_later(NoxHostContext *, int64_t, int64_t, int64_t, NoxHostTaskCallback, void *, NoxHostTask *, NoxHostError **);
NoxHostStatus nox_host_async_start_tk_shout(NoxHostContext *, const uint8_t *, size_t, int64_t, NoxHostTaskCallback, void *, NoxHostTask *, NoxHostError **);
NoxHostStatus nox_host_async_start_tk_boom(NoxHostContext *, int64_t, NoxHostTaskCallback, void *, NoxHostTask *, NoxHostError **);
NoxHostStatus nox_host_async_start_tk_nothing(NoxHostContext *, int64_t, NoxHostTaskCallback, void *, NoxHostTask *, NoxHostError **);
NoxHostStatus nox_host_async_start_tk_sums(NoxHostContext *, NoxHostValue, int64_t, NoxHostTaskCallback, void *, NoxHostTask *, NoxHostError **);
NoxHostStatus nox_host_async_start_tk_stuck(NoxHostContext *, NoxHostTaskCallback, void *, NoxHostTask *, NoxHostError **);
NoxHostStatus nox_host_async_start_tk_slow(NoxHostContext *, int64_t, NoxHostTaskCallback, void *, NoxHostTask *, NoxHostError **);
NoxHostStatus nox_host_async_start_tk_Worker_later(NoxHostContext *, NoxHostHandle, int64_t, int64_t, NoxHostTaskCallback, void *, NoxHostTask *, NoxHostError **);
NoxHostStatus nox_host_export_tk_sync_add(NoxHostContext *, int64_t, int64_t, int64_t *, NoxHostError **);
NoxHostStatus nox_host_export_tk_Worker___new__(NoxHostContext *, int64_t, NoxHostHandle *, NoxHostError **);

static int g_fail;
#define CHECK(c) do { if (!(c)) { printf("FAIL line %d: %s\n", __LINE__, #c); g_fail++; } } while (0)

typedef struct { pthread_mutex_t mu; pthread_cond_t cv; int calls; NoxHostStatus status; NoxHostTask task; } Waiter;
static void wait_init(Waiter *w) { pthread_mutex_init(&w->mu, NULL); pthread_cond_init(&w->cv, NULL); w->calls = 0; w->status = -1; w->task = 0; }
static void on_done(void *ud, NoxHostContext *ctx, NoxHostTask task, NoxHostStatus st) {
    (void)ctx; Waiter *w = ud;
    pthread_mutex_lock(&w->mu); w->calls++; w->status = st; w->task = task; pthread_cond_broadcast(&w->cv); pthread_mutex_unlock(&w->mu);
}
/* en çok `ms` bekler; geri çağrı geldiyse 1 */
static int wait_done(Waiter *w, int ms) {
    struct timespec ts; clock_gettime(CLOCK_REALTIME, &ts);
    ts.tv_sec += ms / 1000; ts.tv_nsec += (long)(ms % 1000) * 1000000L; if (ts.tv_nsec >= 1000000000L) { ts.tv_sec++; ts.tv_nsec -= 1000000000L; }
    pthread_mutex_lock(&w->mu);
    while (w->calls == 0) if (pthread_cond_timedwait(&w->cv, &w->mu, &ts) != 0) break;
    int got = w->calls > 0; pthread_mutex_unlock(&w->mu); return got;
}
static double now_ms(void) { struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts); return ts.tv_sec * 1000.0 + ts.tv_nsec / 1e6; }
static int span_eq(NoxHostSpan sp, const char *s) { return sp.len == strlen(s) && memcmp(sp.data, s, sp.len) == 0; }

int main(void) {
    NoxHostContextConfig cfg = { sizeof cfg, NOX_HOST_ABI_VERSION, NULL };
    NoxHostContext *c = NULL; NoxHostError *e = NULL;
    CHECK(nox_host_context_create(&cfg, &c) == NOX_HOST_OK);
    CHECK(nox_host_module_init_tk(c, &e) == NOX_HOST_OK);

    /* 1) başarılı görev: on_done tam bir kez, take_result değeri verir */
    { Waiter w; wait_init(&w); NoxHostTask t = 0; NoxHostValue v = 0; int64_t x = 0; NoxHostError *er = NULL;
      CHECK(nox_host_async_start_tk_add_later(c, 2, 3, 10, on_done, &w, &t, &e) == NOX_HOST_OK && t != 0 && e == NULL);
      CHECK(wait_done(&w, 5000));
      CHECK(w.status == NOX_HOST_OK && w.task == t);
      CHECK(nox_host_task_take_result(c, t, &v, &er) == NOX_HOST_OK && v != 0 && er == NULL);
      CHECK(nox_host_value_get_int(c, v, &x) == NOX_HOST_OK && x == 5);
      CHECK(nox_host_value_release(c, v) == NOX_HOST_OK);
      CHECK(nox_host_task_take_result(c, t, &v, &er) == NOX_HOST_ERR_STATE); /* ikinci alım */
      CHECK(nox_host_task_release(c, t) == NOX_HOST_OK);
      CHECK(nox_host_task_release(c, t) == NOX_HOST_ERR_INVALID_HANDLE);
      pthread_mutex_lock(&w.mu); CHECK(w.calls == 1); pthread_mutex_unlock(&w.mu); }

    /* 2) str parametresi/dönüşü, None dönüşü, list parametresi/dönüşü */
    { Waiter w; wait_init(&w); NoxHostTask t = 0; NoxHostValue v = 0; NoxHostError *er = NULL; NoxHostSpan sp;
      CHECK(nox_host_async_start_tk_shout(c, (const uint8_t *)"hey", 3, 1, on_done, &w, &t, NULL) == NOX_HOST_OK);
      CHECK(wait_done(&w, 5000) && w.status == NOX_HOST_OK);
      CHECK(nox_host_task_take_result(c, t, &v, &er) == NOX_HOST_OK && nox_host_value_get_span(c, v, &sp) == NOX_HOST_OK && span_eq(sp, "hey!"));
      nox_host_value_release(c, v); nox_host_task_release(c, t); }
    { Waiter w; wait_init(&w); NoxHostTask t = 0; NoxHostValue v = 99; NoxHostError *er = NULL;
      CHECK(nox_host_async_start_tk_nothing(c, 1, on_done, &w, &t, &e) == NOX_HOST_OK);
      CHECK(wait_done(&w, 5000) && w.status == NOX_HOST_OK);
      CHECK(nox_host_task_take_result(c, t, &v, &er) == NOX_HOST_OK && v == 0); /* None → NULL değer */
      nox_host_task_release(c, t); }
    { Waiter w; wait_init(&w); NoxHostTask t = 0; NoxHostValue l = 0, it = 0, v = 0, r = 0; NoxHostError *er = NULL; size_t n = 0; int64_t x = 0;
      CHECK(nox_host_value_container(c, NOX_HOST_VALUE_LIST, &l) == NOX_HOST_OK);
      for (int i = 1; i <= 3; i++) { nox_host_value_int(c, i, &it); nox_host_value_append(c, l, it); nox_host_value_release(c, it); }
      CHECK(nox_host_async_start_tk_sums(c, l, 1, on_done, &w, &t, &e) == NOX_HOST_OK);
      CHECK(nox_host_value_release(c, l) == NOX_HOST_OK); /* host handle'ını hemen bırakabilir: görev kendi kopyasını tutar */
      CHECK(wait_done(&w, 5000) && w.status == NOX_HOST_OK);
      CHECK(nox_host_task_take_result(c, t, &v, &er) == NOX_HOST_OK);
      CHECK(nox_host_value_len(c, v, &n) == NOX_HOST_OK && n == 3);
      CHECK(nox_host_value_item(c, v, 2, &r) == NOX_HOST_OK && nox_host_value_get_int(c, r, &x) == NOX_HOST_OK && x == 6);
      nox_host_value_release(c, r); nox_host_value_release(c, v); nox_host_task_release(c, t); }

    /* 3) istisna: ERR_EXCEPTION + ayrıntı */
    { Waiter w; wait_init(&w); NoxHostTask t = 0; NoxHostValue v = 5; NoxHostError *er = NULL; NoxHostSpan sp;
      CHECK(nox_host_async_start_tk_boom(c, 1, on_done, &w, &t, &e) == NOX_HOST_OK);
      CHECK(wait_done(&w, 5000) && w.status == NOX_HOST_ERR_EXCEPTION);
      CHECK(nox_host_task_take_result(c, t, &v, &er) == NOX_HOST_ERR_EXCEPTION && er && v == 0);
      CHECK(nox_host_error_class_name(er, &sp) == NOX_HOST_OK && span_eq(sp, "ValueError"));
      CHECK(nox_host_error_message(er, &sp) == NOX_HOST_OK && span_eq(sp, "async boom"));
      nox_host_error_release(er); nox_host_task_release(c, t); }

    /* 4) eşzamanlılık: 3 görev 200 ms bekler; bu sırada senkron çağrılar (kilit AÇIK) çalışır; toplam süre ~1 görev kadar */
    { Waiter w[3]; NoxHostTask t[3]; double t0 = now_ms(); int64_t s = 0;
      for (int i = 0; i < 3; i++) { wait_init(&w[i]); CHECK(nox_host_async_start_tk_add_later(c, i, 10, 200, on_done, &w[i], &t[i], &e) == NOX_HOST_OK); }
      for (int k = 0; k < 20; k++) { CHECK(nox_host_export_tk_sync_add(c, k, 1, &s, &e) == NOX_HOST_OK && s == k + 1); }
      for (int i = 0; i < 3; i++) CHECK(wait_done(&w[i], 5000) && w[i].status == NOX_HOST_OK);
      double dt = now_ms() - t0;
      CHECK(dt < 500.0); /* ardışık olsaydı >= 600 ms */
      for (int i = 0; i < 3; i++) {
          NoxHostValue v = 0; int64_t x = 0; NoxHostError *er = NULL;
          CHECK(nox_host_task_take_result(c, t[i], &v, &er) == NOX_HOST_OK && nox_host_value_get_int(c, v, &x) == NOX_HOST_OK && x == i + 10);
          nox_host_value_release(c, v); nox_host_task_release(c, t[i]);
      } }

    /* 5) iptal: görev bir sonraki await'inde CancelledError alır */
    { Waiter w; wait_init(&w); NoxHostTask t = 0; NoxHostValue v = 7; NoxHostError *er = NULL; double t0;
      CHECK(nox_host_async_start_tk_slow(c, 3000, on_done, &w, &t, &e) == NOX_HOST_OK);
      { struct timespec ts = {0, 30 * 1000000L}; nanosleep(&ts, NULL); }
      t0 = now_ms();
      CHECK(nox_host_task_cancel(c, t) == NOX_HOST_OK);
      CHECK(wait_done(&w, 5000));
      CHECK(w.status == NOX_HOST_ERR_CANCELLED);
      CHECK(nox_host_task_take_result(c, t, &v, &er) == NOX_HOST_ERR_CANCELLED && v == 0 && er == NULL);
      nox_host_task_release(c, t);
      (void)t0; }

    /* 6) release, tamamlanmadan: on_done ÇAĞRILMAZ, kaynaklar bırakılır */
    { Waiter w; wait_init(&w); NoxHostTask t = 0;
      CHECK(nox_host_async_start_tk_slow(c, 100, on_done, &w, &t, &e) == NOX_HOST_OK);
      CHECK(nox_host_task_release(c, t) == NOX_HOST_OK);
      CHECK(!wait_done(&w, 600)); }

    /* 7) sınıf: asenkron örnek yöntemi */
    { NoxHostHandle h = 0; Waiter w; wait_init(&w); NoxHostTask t = 0; NoxHostValue v = 0; NoxHostError *er = NULL; int64_t x = 0;
      CHECK(nox_host_export_tk_Worker___new__(c, 40, &h, &e) == NOX_HOST_OK);
      CHECK(nox_host_async_start_tk_Worker_later(c, h, 2, 1, on_done, &w, &t, &e) == NOX_HOST_OK);
      CHECK(nox_host_handle_release(c, h) == NOX_HOST_OK); /* görev nesneyi tutar */
      CHECK(wait_done(&w, 5000) && w.status == NOX_HOST_OK);
      CHECK(nox_host_task_take_result(c, t, &v, &er) == NOX_HOST_OK && nox_host_value_get_int(c, v, &x) == NOX_HOST_OK && x == 42);
      nox_host_value_release(c, v); nox_host_task_release(c, t); }

    /* 8) hatalı kullanım */
    { Waiter w; wait_init(&w); NoxHostTask t = 5; NoxHostValue bad = 12345;
      CHECK(nox_host_async_start_tk_add_later(c, 1, 2, 1, on_done, &w, NULL, NULL) == NOX_HOST_ERR_INVAL);
      CHECK(nox_host_async_start_tk_add_later(c, 1, 2, 1, NULL, &w, &t, NULL) == NOX_HOST_ERR_INVAL);
      CHECK(nox_host_async_start_tk_shout(c, (const uint8_t *)"\xff\xfe", 2, 1, on_done, &w, &t, NULL) == NOX_HOST_ERR_UTF8);
      CHECK(nox_host_async_start_tk_sums(c, bad, 1, on_done, &w, &t, NULL) == NOX_HOST_ERR_INVALID_HANDLE);
      CHECK(nox_host_task_cancel(c, 0) == NOX_HOST_ERR_INVALID_HANDLE);
      CHECK(nox_host_task_take_result(c, 777, NULL, NULL) == NOX_HOST_ERR_INVALID_HANDLE); }

    /* 9) çalışan görevli bağlamı yok etmek: iptal edilir, takılmaz */
    { Waiter w; wait_init(&w); NoxHostTask t = 0; double t0 = now_ms();
      CHECK(nox_host_async_start_tk_slow(c, 400, on_done, &w, &t, &e) == NOX_HOST_OK);
      nox_host_module_fini_tk(c);
      nox_host_context_destroy(c);
      CHECK(now_ms() - t0 < 3000.0); }

    /* 10) çıkmaz: süreç ölmez, görev ERR_STATE + RuntimeError, sonraki başlatmalar reddedilir */
    { NoxHostContext *c2 = NULL; Waiter w; wait_init(&w); NoxHostTask t = 0, t2 = 0; NoxHostValue v = 0; NoxHostError *er = NULL; NoxHostSpan sp;
      CHECK(nox_host_context_create(&cfg, &c2) == NOX_HOST_OK && nox_host_module_init_tk(c2, &e) == NOX_HOST_OK);
      CHECK(nox_host_async_start_tk_stuck(c2, on_done, &w, &t, &e) == NOX_HOST_OK);
      CHECK(wait_done(&w, 5000) && w.status == NOX_HOST_ERR_STATE);
      CHECK(nox_host_task_take_result(c2, t, &v, &er) == NOX_HOST_ERR_STATE && er);
      CHECK(nox_host_error_class_name(er, &sp) == NOX_HOST_OK && span_eq(sp, "RuntimeError"));
      CHECK(nox_host_error_message(er, &sp) == NOX_HOST_OK && span_eq(sp, "deadlock in async task"));
      nox_host_error_release(er);
      { Waiter w2; wait_init(&w2); CHECK(nox_host_async_start_tk_slow(c2, 1, on_done, &w2, &t2, &e) == NOX_HOST_ERR_STATE); }
      CHECK(nox_host_task_release(c2, t) == NOX_HOST_OK);
      nox_host_module_fini_tk(c2); nox_host_context_destroy(c2); }

    if (g_fail) { printf("%d failure(s)\n", g_fail); return 1; }
    printf("ALL OK\n");
    return 0;
}
