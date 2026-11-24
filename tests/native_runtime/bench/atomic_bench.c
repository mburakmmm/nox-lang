/* R2 ölçümü: ham-adres atomik maliyeti. (a) Nox leaf -> extern shim çağrısı, (b) C satır içi __atomic, (c) C -> shim (noinline çağrı).
 * Tek iş parçacığı, relaxed fetch_add, N=100M; çıktı ns/işlem. Çok iş parçacıklı doğruluk P05'te. */
#include <stdint.h>
#include <stdio.h>
#include <time.h>
typedef int64_t w;
extern void at_inc(w rt, void *p, w n);
extern w rtcore_atomic_fetch_add_u64(void *p, w v, w o);
static double now(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec * 1e9 + t.tv_nsec; }
int main(void) {
    enum { N = 100000000 };
    static _Alignas(8) uint64_t c;
    double t0 = now(); at_inc(0, &c, N); double a = (now() - t0) / N;
    c = 0; t0 = now(); for (long i = 0; i < N; i++) __atomic_fetch_add(&c, 1, __ATOMIC_RELAXED); double b = (now() - t0) / N;
    c = 0; t0 = now(); for (long i = 0; i < N; i++) rtcore_atomic_fetch_add_u64(&c, 1, 0); double d = (now() - t0) / N;
    printf("nox-leaf->shim: %.3f ns/op | C inline __atomic: %.3f ns/op | C->shim call: %.3f ns/op\n", a, b, d);
    return 0;
}
