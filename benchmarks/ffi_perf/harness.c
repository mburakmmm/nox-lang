/* C tabanı: aynı çağrılar, aynı döngü; ns/çağrı. */
#include <stdint.h>
#include <stdio.h>
#include <time.h>
extern int64_t c_add(int64_t, int64_t);
extern double c_fmul(double, double);
extern int64_t c_first(const char *);
extern int64_t c_sum(const int64_t *, int64_t);
extern void *c_make(int64_t);
extern void c_free(void *);
extern int64_t c_apply_n(int64_t (*)(int64_t, int64_t, void *), int64_t, void *);
static double now_ms(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec * 1e3 + t.tv_nsec / 1e6; }
static int64_t cb_add(int64_t a, int64_t b, void *u) { (void)u; return a + b; }
static void report(const char *n, double t0, int64_t calls, int64_t chk) { printf("%s\t%f\t%lld\n", n, (now_ms() - t0) * 1e6 / (double)calls, (long long)chk); }
int main(void) {
    const int64_t N = 50000000;
    double t = now_ms(); int64_t acc = 0;
    for (int64_t i = 0; i < N; i++) acc += c_add(i, 1);
    report("ffi_scalar_int", t, N, acc);
    t = now_ms(); double f = 1.0;
    for (int64_t i = 0; i < N; i++) f = c_fmul(f, 1.0000001);
    report("ffi_scalar_float", t, N, f > 1.0);
    char s[1025]; for (int i = 0; i < 1024; i++) s[i] = 'a'; s[1024] = 0;
    t = now_ms(); acc = 0;
    for (int64_t i = 0; i < N; i++) acc += c_first(s);
    report("ffi_str_arg_1KB", t, N, acc);
    void *arr = c_make(1000000);
    t = now_ms(); acc = 0;
    for (int r = 0; r < 100; r++) acc += c_sum(arr, 1000000);
    report("ffi_bulk_sum_1M_x100", t, 100, acc % 1000003);
    c_free(arr);
    t = now_ms();
    acc = c_apply_n(cb_add, N, 0);
    report("ffi_callback", t, N, acc);
    {
        int64_t *xs = (int64_t *)c_make(1000000); int64_t *buf = (int64_t *)c_make(1000000);
        t = now_ms(); acc = 0;
        for (int r = 0; r < 20; r++) { for (int m = 0; m < 1000000; m++) buf[m] = xs[m]; acc += c_sum(buf, 1000000); }
        report("marshal_list_to_ptr_per_elem", t, 20 * 1000000, acc % 1000003);
        t = now_ms(); acc = 0;
        for (int r = 0; r < 20; r++) acc += c_sum(xs, 1000000);
        report("marshal_list_zero_copy_per_elem", t, 20 * 1000000, acc % 1000003);
        c_free(xs); c_free(buf);
    }
    return 0;
}
