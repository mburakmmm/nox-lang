/* lang_perf.nox'un C karşılığı (cc -O2): AYNI işler, AYNI sağlama toplamları. Yalnızca C'de doğal karşılığı olan çekirdekler (sözlük/jeneratör/istisna kümeleri yok). */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

typedef int64_t i64;
static double now_ms(void) { struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts); return ts.tv_sec * 1000.0 + ts.tv_nsec / 1e6; }
static void report(const char *name, double t0, i64 check) { printf("%s\t%f\t%lld\n", name, now_ms() - t0, (long long)check); }

static i64 fib(i64 n) { return n < 2 ? n : fib(n - 1) + fib(n - 2); }
static i64 lcg(i64 s) { return (s * 1103515245 + 12345) % 2147483648LL; }

typedef struct { i64 total; } Counter;
static void counter_add(Counter *c, i64 x) { c->total = (c->total * 31 + x) % 1000000007; }

typedef struct Shape Shape;
struct Shape { i64 (*area)(const Shape *); i64 a, b; };
static i64 area_sq(const Shape *s) { return s->a * s->a; }
static i64 area_rect(const Shape *s) { return s->a * s->b; }
static i64 area_tri(const Shape *s) { return s->a * s->b / 2; }

typedef struct Node { struct Node *l, *r; } Node;
static Node *build(int d) { Node *n = malloc(sizeof(Node)); if (d == 0) { n->l = n->r = NULL; } else { n->l = build(d - 1); n->r = build(d - 1); } return n; }
static i64 count_free(Node *n) { if (!n) return 0; i64 c = 1 + count_free(n->l) + count_free(n->r); free(n); return c; }

static i64 apply(i64 (*f)(i64), i64 x) { return f(x); }
static i64 inc(i64 x) { return x + 1; }
static int cmp_i64(const void *a, const void *b) { i64 x = *(const i64 *)a, y = *(const i64 *)b; return (x > y) - (x < y); }

int main(int argc, char **argv) {
    i64 S = argc > 1 ? atoll(argv[1]) : 1;
    double t; i64 s;

    t = now_ms(); s = 0;
    for (i64 i = 0; i < 5000000 * S; i++) s += (i * i) % 7 + (i ^ (i >> 3));
    report("loop_arith_5M", t, s);

    t = now_ms(); s = 0;
    for (i64 r = 0; r < S; r++) s += fib(30 + r % 3);
    report("fib_rec_30_32", t, s);

    t = now_ms(); s = 0;
    for (i64 n = 1; n <= 300000 * S; n++) { i64 x = n, steps = 0; while (x != 1) { x = (x % 2 == 0) ? x / 2 : 3 * x + 1; steps++; } s += steps; }
    report("collatz_300k", t, s);

    t = now_ms();
    { i64 n = 4000000 * S; char *sv = malloc(n); memset(sv, 1, n); sv[0] = sv[1] = 0;
      for (i64 i = 2; i * i < n; i++) if (sv[i]) for (i64 j = i * i; j < n; j += i) sv[j] = 0;
      s = 0; for (i64 i = 0; i < n; i++) s += sv[i]; free(sv); }
    report("sieve_4M", t, s);

    t = now_ms();
    { enum { M = 100 }; static double a[M][M], b[M][M], c[M][M]; double tr = 0;
      for (int i = 0; i < M; i++) for (int j = 0; j < M; j++) { a[i][j] = (double)((i * j) % 7) + 0.5; b[i][j] = (double)((i + j) % 5) - 1.25; }
      for (i64 rr = 0; rr < S; rr++) { a[0][0] = (double)rr + 0.5;
        for (int i = 0; i < M; i++) for (int j = 0; j < M; j++) { double acc = 0; for (int k = 0; k < M; k++) acc += a[i][k] * b[k][j]; c[i][j] = acc; }
        tr = 0; for (int i = 0; i < M; i++) tr += c[i][i]; }
      report("matmul_100", t, (i64)(tr * 1000.0)); }

    t = now_ms();
    { double x = 0, y = 1; for (i64 i = 0; i < 3000000 * S; i++) { x = x * 0.999 + y * 0.001; y = y * 1.0001 - x * 0.0001; }
      report("float_loop_3M", t, (i64)(x * 1000000.0) + (i64)(y * 1000000.0)); }

    t = now_ms();
    { enum { CAP = 262144 }; i64 *keys = malloc(CAP * sizeof(i64)), *vals = calloc(CAP, sizeof(i64)); for (int i = 0; i < CAP; i++) keys[i] = -1; i64 used = 0;
      for (i64 i = 0; i < 1500000 * S; i++) { i64 k = (i * 7919) % 100003; unsigned h = (unsigned)((k * 2654435761u) & (CAP - 1));
        while (keys[h] != -1 && keys[h] != k) h = (h + 1) & (CAP - 1);
        if (keys[h] == -1) { keys[h] = k; vals[h] = 1; used++; } else vals[h]++; }
      i64 five = 0; { unsigned h = (unsigned)((5 * 2654435761u) & (CAP - 1)); while (keys[h] != 5) h = (h + 1) & (CAP - 1); five = vals[h]; }
      report("dict_int_1.5M", t, used * 1000 + five); free(keys); free(vals); }

    t = now_ms();
    { i64 n = 0, cap = 1024, *xs = malloc(cap * sizeof(i64)); for (i64 i = 0; i < 2000000 * S; i++) { if (n == cap) { cap *= 2; xs = realloc(xs, cap * sizeof(i64)); } xs[n++] = i * 3; }
      s = 0; for (i64 i = 0; i < n; i++) s += xs[i]; while (n > 1000000 * S) n--;
      report("list_append_sum_pop_2M", t, s + n); free(xs); }

    t = now_ms();
    { i64 total = 0; char buf[32]; for (i64 i = 0; i < 300000 * S; i++) { total += snprintf(buf, sizeof buf, "%lld", (long long)i); if (i > 0) total++; }
      report("str_build_join_300k", t, total); }

    t = now_ms();
    { Counter c = {0}; for (i64 i = 0; i < 3000000 * S; i++) counter_add(&c, i); report("method_calls_3M", t, c.total); }

    t = now_ms();
    { Shape shapes[1000]; for (int q = 0; q < 1000; q++) { if (q % 3 == 0) { shapes[q].area = area_sq; shapes[q].a = q; } else if (q % 3 == 1) { shapes[q].area = area_rect; shapes[q].a = q; shapes[q].b = 2; } else { shapes[q].area = area_tri; shapes[q].a = q; shapes[q].b = 4; } }
      s = 0; for (i64 r = 0; r < 2000 * S; r++) for (int q = 0; q < 1000; q++) s += shapes[q].area(&shapes[q]);
      report("virtual_dispatch_2M", t, s); }

    t = now_ms(); s = 0;
    { i64 (*volatile fp)(i64) = inc; for (i64 i = 0; i < 2000000 * S; i++) s += apply(fp, i); }
    report("func_value_calls_2M", t, s);

    t = now_ms(); s = 0;
    for (i64 r = 0; r < 4 * S; r++) s += count_free(build(17));
    report("alloc_tree_17x4", t, s);

    t = now_ms();
    { i64 n = 500000 * S, seed = 7, *arr = malloc(n * sizeof(i64)); for (i64 i = 0; i < n; i++) { seed = lcg(seed); arr[i] = seed; } qsort(arr, n, sizeof(i64), cmp_i64);
      report("sort_500k", t, arr[0] + arr[250000 * S] + arr[n - 1]); free(arr); }

    t = now_ms(); s = 0;
    for (i64 rr = 0; rr < S; rr++) { i64 seed = 11 + rr, small[3000]; for (int i = 0; i < 3000; i++) { seed = lcg(seed); small[i] = seed % 10000; }
      for (int i = 1; i < 3000; i++) { i64 v = small[i]; int j = i - 1; while (j >= 0 && small[j] > v) { small[j + 1] = small[j]; j--; } small[j + 1] = v; }
      s = small[0] + small[1500] + small[2999]; }
    report("insertion_sort_3k", t, s);

    t = now_ms();
    { i64 len = 1000000 * S; char *text = malloc(len + 1); for (i64 i = 0; i < len; i++) text[i] = "abcab"[i % 5]; i64 c = 0; for (i64 i = 0; i < len; i++) if (text[i] == 'a') c++;
      report("str_index_loop_1M", t, c); free(text); }
    return 0;
}
