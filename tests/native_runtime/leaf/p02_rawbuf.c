/* P02 harness: kanarya + referans (memmove) ile karsilastirma; sifir uzunluk, ust uste binme (ileri/geri). */
#include <stdint.h>
#include <stdio.h>
#include <string.h>
typedef int64_t w;
extern void buf_fill(w rt, w *p, w n, w seed);
extern void buf_copy(w rt, w *d, w *s, w n);
extern void buf_move(w rt, w *d, w *s, w n);
extern w buf_sum(w rt, w *p, w n);
extern w buf_eq(w rt, w *a, w *b, w n);
extern void buf_zero(w rt, w *p, w n);
#define CAN 0x5AFEC0DE5AFEC0DELL
#define N 64
int main(void) {
    w a[N + 2], ref[N + 2], b[N + 2];
    for (int i = 0; i < N + 2; i++) a[i] = ref[i] = b[i] = CAN;
    buf_fill(0, a + 1, 40, 5);
    for (int i = 0; i < 40; i++) ref[1 + i] = 5 + (w)i * 7;
    if (!buf_eq(0, a + 1, ref + 1, 40)) return 10;
    /* sifir uzunluk: hicbir sey degismez */
    buf_fill(0, a + 1, 0, 99); buf_copy(0, b + 1, a + 1, 0); buf_move(0, a + 2, a + 1, 0);
    if (!buf_eq(0, a + 1, ref + 1, 40)) return 11;
    /* ust uste binen tasima: ileri (dst>src) ve geri (dst<src) */
    buf_move(0, a + 1 + 5, a + 1, 30); memmove(ref + 1 + 5, ref + 1, 30 * sizeof(w));
    if (memcmp(a, ref, sizeof a) != 0) return 12;
    buf_move(0, a + 1, a + 1 + 3, 30); memmove(ref + 1, ref + 1 + 3, 30 * sizeof(w));
    if (memcmp(a, ref, sizeof a) != 0) return 13;
    buf_copy(0, b + 1, a + 1, 40);
    if (!buf_eq(0, b + 1, a + 1, 40)) return 14;
    w s = 0; for (int i = 0; i < 40; i++) s += a[1 + i] * (w)(i + 1);
    if (buf_sum(0, a + 1, 40) != s) return 15;
    buf_zero(0, b + 1, 40);
    for (int i = 0; i < 40; i++) if (b[1 + i] != 0) return 16;
    if (b[0] != CAN || b[41] != CAN || a[0] != CAN || a[N + 1] != CAN) return 17; /* kanaryalar */
    puts("ok");
    return 0;
}
