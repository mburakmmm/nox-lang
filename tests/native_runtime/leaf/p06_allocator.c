/* P06/P08 harness: allocator spike dogrulama. noxrt.o YOK. Referans model + kanarya + fault injection + durum makinesi. */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <time.h>
#include <fcntl.h>
#include <unistd.h>
typedef int64_t w;
extern long g_fail_after, g_mapped_bytes, g_map_calls;
extern w rt_init(w rt, void *st, w flags);
extern w rt_fini(w rt, void *st);
extern w rt_state_code(w rt, void *st);
extern w ra_alloc(w rt, void *st, w size, w align);
extern void ra_free(w rt, void *st, w p);
extern w ra_realloc(w rt, void *st, w p, w ns);
extern w ra_live_count(w rt, void *st);
extern w ra_live_bytes(w rt, void *st);
#define FAIL(n) do { fprintf(stderr, "FAIL line %d (code %d)\n", __LINE__, n); return n; } while (0)

static w A(w *st, w sz) { return ra_alloc(0, st, sz, 16); }
static void F(w *st, w p) { ra_free(0, st, p); }

static int bench(void) {
    _Alignas(16) w st[16] = {0};
    rt_init(0, st, 0);
    struct timespec a, b; const long N = 5000000; w keep[8];
    clock_gettime(CLOCK_MONOTONIC, &a);
    for (long i = 0; i < N; i++) { w p = A(st, 64); keep[i & 7] = p; F(st, p); }
    clock_gettime(CLOCK_MONOTONIC, &b);
    double ns = ((b.tv_sec - a.tv_sec) * 1e9 + (b.tv_nsec - a.tv_nsec)) / (double)N;
    clock_gettime(CLOCK_MONOTONIC, &a);
    for (long i = 0; i < N; i++) { void *p = malloc(64); keep[i & 7] = (w)(intptr_t)p; __asm__ volatile("" : : "r"(p) : "memory"); free(p); } /* bariyer: malloc/free cifti elenmesin */
    clock_gettime(CLOCK_MONOTONIC, &b);
    double ns2 = ((b.tv_sec - a.tv_sec) * 1e9 + (b.tv_nsec - a.tv_nsec)) / (double)N;
    printf("nox-alloc alloc+free(64B): %.2f ns/pair | libc malloc+free: %.2f ns/pair\n", ns, ns2);
    rt_fini(0, st);
    return 0;
}

static int child_expect(int expect, int mode) { /* fatal yolu: cocuk surecte; cikis kodu 80+kod, stderr mesaji */
    pid_t c = fork();
    if (c == 0) {
        _Alignas(16) w st[16] = {0}; int dn = open("/dev/null", 1); dup2(dn, 2);
        rt_init(0, st, 1);
        w p = A(st, 20);
        if (mode == 0) { F(st, p); F(st, p); }                /* double free */
        else if (mode == 1) { ((char *)(intptr_t)p)[32] = 7; F(st, p); } /* tam yuk (32 B) SONRASI: canary tasmasi */
        else if (mode == 2) { A(st, 8); (void)ra_alloc(0, st, 8, 64); } /* desteklenmeyen hizalama */
        _exit(0);
    }
    int s = 0; waitpid(c, &s, 0);
    return WIFEXITED(s) && WEXITSTATUS(s) == expect;
}

int main(int argc, char **argv) {
    if (argc > 1 && !strcmp(argv[1], "--bench")) return bench();
    _Alignas(16) w st[16]; memset(st, 0, sizeof st);
    /* --- durum makinesi / kismi init --- */
    g_fail_after = 0;
    if (rt_init(0, st, 0) != -2 || rt_state_code(0, st) != 0 || g_mapped_bytes != 0) FAIL(10); /* OOM'da geri alindi */
    g_fail_after = -1;
    if (A(st, 16) != 0) FAIL(11);                                    /* init'siz alloc = 0 */
    if (rt_init(0, st, 1) != 0 || rt_state_code(0, st) != 2) FAIL(12);
    if (rt_init(0, st, 1) != -1 || rt_state_code(0, st) != 2) FAIL(13); /* cift init reddedilir, durum bozulmaz */
    /* --- tahsis: desen/ust uste binme/hizalama/referans model --- */
    enum { M = 600 };
    static w ptr_[M]; static w sz[M]; long live = 0, livebytes = 0; srand(12345);
    for (int i = 0; i < M; i++) ptr_[i] = 0;
    for (int it = 0; it < 60000; it++) {
        int i = rand() % M;
        if (ptr_[i]) {
            unsigned char *q = (unsigned char *)(intptr_t)ptr_[i];
            for (w k = 0; k < sz[i]; k++) if (q[k] != (unsigned char)(i * 31 + k)) FAIL(20); /* bozulma/ust uste binme */
            F(st, ptr_[i]); live--; livebytes -= sz[i]; ptr_[i] = 0;
        } else {
            int big = rand() % 50 == 0;
            sz[i] = big ? 3000 + rand() % 9000 : 1 + rand() % 700;
            ptr_[i] = A(st, sz[i]);
            if (!ptr_[i] || (ptr_[i] & 15)) FAIL(21);
            unsigned char *q = (unsigned char *)(intptr_t)ptr_[i];
            for (w k = 0; k < sz[i]; k++) q[k] = (unsigned char)(i * 31 + k);
            live++; livebytes += sz[i];
        }
        if (ra_live_count(0, st) != live || ra_live_bytes(0, st) != livebytes) FAIL(22);
    }
    /* freelist yeniden kullanimi */
    w p1 = A(st, 100); F(st, p1); w p2 = A(st, 100); if (p1 != p2) FAIL(23); F(st, p2);
    /* sifir-boyut, tasma korumasi */
    w z = A(st, 0); if (!z) FAIL(24); F(st, z);
    if (A(st, (w)1 << 62) != 0 || A(st, -1) != 0 || A(st, INT64_MAX) != 0) FAIL(25);
    /* OOM enjeksiyonu: yeni chunk gerektiren istek 0 doner, allocator tutarli kalir */
    long before = ra_live_count(0, st);
    g_fail_after = 0;
    w big1 = A(st, 100000); w many = 0; for (int i = 0; i < 4000 && (many = A(st, 2000)); i++) { }
    g_fail_after = -1;
    if (big1 != 0) FAIL(26);
    if (many != 0) FAIL(27);                                         /* sonunda OOM 0 */
    if (ra_live_count(0, st) < before) FAIL(28);                     /* tutarlilik */
    /* realloc: icerik korunur; basarisizlikta ESKI blok sahipligi korunur */
    w r = A(st, 40); memset((void *)(intptr_t)r, 0x5A, 40);
    w r2 = ra_realloc(0, st, r, 500); if (!r2 || memcmp((void *)(intptr_t)r2, "ZZZZZZZZ", 0) < 0) FAIL(29);
    for (int k = 0; k < 40; k++) if (((unsigned char *)(intptr_t)r2)[k] != 0x5A) FAIL(30);
    g_fail_after = 0; w r3 = ra_realloc(0, st, r2, 200000); g_fail_after = -1;
    if (r3 != 0) FAIL(31);
    for (int k = 0; k < 40; k++) if (((unsigned char *)(intptr_t)r2)[k] != 0x5A) FAIL(32);
    F(st, r2);
    /* kalan canli bloklari birak ve bilincli bir sizinti birak */
    for (int i = 0; i < M; i++) if (ptr_[i]) F(st, ptr_[i]);
    /* (many zinciri OOM'a kadar tahsis edildi: serbest birakilmadi -> sizinti sayisi fini'de gorunmeli) */
    w leaks = ra_live_count(0, st);
    w fr = rt_fini(0, st);
    if (fr != leaks || leaks < 1) FAIL(33);
    if (g_mapped_bytes != 0) FAIL(34);                               /* tum chunk'lar platforma iade */
    if (rt_state_code(0, st) != 4) FAIL(35);                          /* DEAD */
    if (rt_fini(0, st) != -1) FAIL(36);                               /* cift fini */
    if (A(st, 16) != 0) FAIL(37);                                     /* DEAD'de alloc yok */
    /* tekrar runtime yarat/yik (ayni surecte) */
    for (int rr = 0; rr < 3; rr++) {
        w st2[16]; memset(st2, 0, sizeof st2);
        if (rt_init(0, st2, 0) != 0) FAIL(38);
        w a = A(st2, 64), b = A(st2, 64); F(st2, a); F(st2, b);
        if (rt_fini(0, st2) != 0 || g_mapped_bytes != 0) FAIL(39);
    }
    /* Debug fatal yollari (tahsissiz sink; cocuk surec) */
    if (!child_expect(82, 0)) FAIL(40);   /* double free -> kod 2 */
    if (!child_expect(83, 1)) FAIL(41);   /* canary tasmasi -> kod 3 */
    if (!child_expect(84, 2)) FAIL(42);   /* hizalama > 16 -> kod 4 */
    puts("ok");
    return 0;
}
