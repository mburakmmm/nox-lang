/* P04 harness: tahsissiz fatal sink. nox_int_overflow_trap'i BU dosya saglar (yalniz write + _exit; malloc/stdio YOK).
 * Normal yol: sonuclar dogru. Tasma yolu: fork'lu cocuk 70 ile cikar ve stderr'e mesaj yazar. */
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>
typedef int64_t w;
extern uint32_t fx_mul(w rt, uint32_t a, uint32_t b);
extern w fx_widen(w rt, uint8_t a);
void nox_int_overflow_trap(w rt, w what) {
    (void)rt;
    static const char pre[] = "fatal: integer overflow converting to ";
    write(2, pre, sizeof pre - 1);
    const char *s = (const char *)(intptr_t)what; /* NUL-sonlu ad (fmt_lit) */
    size_t n = 0; while (s[n]) n++;
    write(2, s, n); write(2, "\n", 1);
    _exit(70);
}
int main(void) {
    if (fx_mul(0, 3, 4) != 12 || fx_widen(0, 41) != 42) return 10;
    int p[2]; if (pipe(p)) return 11;
    pid_t c = fork();
    if (c == 0) { dup2(p[1], 2); close(p[0]); (void)fx_mul(0, 0x10000, 0x10000); _exit(99); /* ulasilmamali */ }
    close(p[1]);
    char buf[128] = {0}; ssize_t got = read(p[0], buf, sizeof buf - 1); (void)got;
    int st = 0; waitpid(c, &st, 0);
    if (!WIFEXITED(st) || WEXITSTATUS(st) != 70) return 12;
    if (!strstr(buf, "fatal: integer overflow")) return 13;
    puts("ok");
    return 0;
}
