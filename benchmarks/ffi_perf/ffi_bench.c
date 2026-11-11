/* FFI benchmark kütüphanesi: ayrı çeviri birimi (LTO yok) — çağrı gerçek bir çağrıdır, satır içine alınamaz. */
#include <stdint.h>
#include <stdlib.h>

int64_t c_add(int64_t a, int64_t b) { return a + b; }
double c_fmul(double a, double b) { return a * b; }
int64_t c_first(const char *s) { return (unsigned char)s[0]; }
int64_t c_sum(const int64_t *p, int64_t n) {
    int64_t s = 0;
    for (int64_t i = 0; i < n; i++) s += p[i];
    return s;
}
void *c_make(int64_t n) {
    int64_t *p = (int64_t *)malloc((size_t)n * sizeof(int64_t));
    for (int64_t i = 0; i < n; i++) p[i] = i;
    return p;
}
void c_free(void *p) { free(p); }
int64_t c_apply_n(int64_t (*cb)(int64_t, int64_t, void *), int64_t n, void *ud) {
    int64_t s = 0;
    for (int64_t i = 0; i < n; i++) s += cb(i, 1, ud);
    return s;
}
void *c_null(void) { return 0; }
