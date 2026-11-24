/* P05 harness: Nox leaf'leri (ham atomik + TLS, gecici C shim uzerinden) COK is parcacigi altinda.
 * - sayac: 4 is parcacigi x N relaxed fetch_add == tam toplam
 * - CAS: 4 x M basarili artis == tam toplam
 * - mesaj gecirme (release store / acquire load): tuketici HER ZAMAN yayimlanan degeri gorur
 * - store-buffering litmus (seq_cst fence): (r1==0 && r2==0) YASAK sonuc, 0 olmali
 * - TLS: her is parcacigi kendi yuvasini gorur; ana is parcacigi etkilenmez
 */
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
typedef int64_t w;
extern void at_inc(w rt, void *p, w n);
extern void at_cas_inc(w rt, void *p, w n);
extern void at_publish(w rt, w *data, void *flag, w v);
extern w at_consume(w rt, w *data, void *flag);
extern w at_tls_roundtrip(w rt, w v);
extern w at_fence_pair(w rt, void *mine, void *other);

#define T 4
static _Alignas(8) uint64_t g_cnt, g_cas;
static void *th_inc(void *a) { (void)a; at_inc(0, &g_cnt, 500000); return 0; }
static void *th_cas(void *a) { (void)a; at_cas_inc(0, &g_cas, 100000); return 0; }

#define R 200000
static w g_data[R]; static _Alignas(8) uint64_t g_flag[R];
static void *th_prod(void *a) { (void)a; for (w i = 0; i < R; i++) at_publish(0, &g_data[i], &g_flag[i], i * 3 + 1); return 0; }
static volatile int g_bad_mp;
static void *th_cons(void *a) { (void)a; for (w i = 0; i < R; i++) if (at_consume(0, &g_data[i], &g_flag[i]) != i * 3 + 1) g_bad_mp = 1; return 0; }

#define L 100000
static _Alignas(8) uint64_t X[L], Y[L]; static w r1[L], r2[L];
static atomic_int sb_go;
static void *th_sb1(void *a) { (void)a; for (int i = 0; i < L; i++) { while (atomic_load(&sb_go) < i) ; r1[i] = at_fence_pair(0, &X[i], &Y[i]); } return 0; }
static void *th_sb2(void *a) { (void)a; for (int i = 0; i < L; i++) { while (atomic_load(&sb_go) < i) ; r2[i] = at_fence_pair(0, &Y[i], &X[i]); } return 0; }

static volatile int g_bad_tls;
static void *th_tls(void *a) {
    w id = (w)(intptr_t)a + 100;
    for (int i = 0; i < 20000; i++) if (at_tls_roundtrip(0, id) != id) g_bad_tls = 1;
    return 0;
}

int main(void) {
    pthread_t t[T];
    for (int i = 0; i < T; i++) pthread_create(&t[i], 0, th_inc, 0);
    for (int i = 0; i < T; i++) pthread_join(t[i], 0);
    if (g_cnt != (uint64_t)T * 500000) { fprintf(stderr, "counter %llu\n", (unsigned long long)g_cnt); return 10; }
    for (int i = 0; i < T; i++) pthread_create(&t[i], 0, th_cas, 0);
    for (int i = 0; i < T; i++) pthread_join(t[i], 0);
    if (g_cas != (uint64_t)T * 100000) { fprintf(stderr, "cas %llu\n", (unsigned long long)g_cas); return 11; }
    pthread_t p, c;
    pthread_create(&c, 0, th_cons, 0); pthread_create(&p, 0, th_prod, 0);
    pthread_join(p, 0); pthread_join(c, 0);
    if (g_bad_mp) return 12;
    pthread_t s1, s2;
    pthread_create(&s1, 0, th_sb1, 0); pthread_create(&s2, 0, th_sb2, 0);
    for (int i = 0; i < L; i++) atomic_store(&sb_go, i);
    pthread_join(s1, 0); pthread_join(s2, 0);
    long both0 = 0; for (int i = 0; i < L; i++) if (r1[i] == 0 && r2[i] == 0) both0++;
    if (both0) { fprintf(stderr, "SB litmus: %ld yasak sonuc\n", both0); return 13; }
    for (int i = 0; i < T; i++) pthread_create(&t[i], 0, th_tls, (void *)(intptr_t)i);
    for (int i = 0; i < T; i++) pthread_join(t[i], 0);
    if (g_bad_tls) return 14;
    puts("ok");
    return 0;
}
