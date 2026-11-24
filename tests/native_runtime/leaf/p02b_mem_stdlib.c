#include <stdint.h>
#include <stdio.h>
#include <string.h>
typedef int64_t w;
extern void m_copy(w rt, w *d, w *s, w n);
extern void m_move(w rt, w *d, w *s, w n);
extern void m_set(w rt, w *d, w v, w n);
int main(void) {
    w a[32], r[32]; for (int i = 0; i < 32; i++) a[i] = r[i] = i * 11 + 3;
    m_move(0, a + 4, a, 20); memmove(r + 4, r, 20 * sizeof(w)); if (memcmp(a, r, sizeof a)) return 10;
    m_move(0, a, a + 5, 20); memmove(r, r + 5, 20 * sizeof(w)); if (memcmp(a, r, sizeof a)) return 11;
    w b[32]; memset(b, 0, sizeof b); m_copy(0, b, a, 32); if (memcmp(a, b, sizeof a)) return 12;
    m_set(0, b + 2, 77, 10); for (int i = 0; i < 32; i++) if (b[i] != ((i >= 2 && i < 12) ? 77 : a[i])) return 13;
    puts("ok"); return 0;
}
