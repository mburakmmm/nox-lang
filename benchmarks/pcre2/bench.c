/* C referansı: PCRE2 10.49 yorumlayıcı ve JIT; aynı iş yükü (eşleşme sayımı, metin kopyalamadan). */
#define PCRE2_CODE_UNIT_WIDTH 8
#include <pcre2.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
static char *build_numbers(int n) {
    size_t cap = (size_t)n * 12 + 16, len = 0; char *s = malloc(cap);
    for (int i = 0; i < n; i++) { int w = sprintf(s + len, "%sn%d", i ? " " : "", (int)((long)i * 37 % 100003)); len += (size_t)w; }
    s[len] = 0; return s;
}
static char *build_prose(int n) {
    const char *w[] = {"alpha", "beta", "foo", "gamma", "bar", "delta", "baz", "epsilon", "zeta", "contact", "bob@example.com", "eta"};
    size_t cap = (size_t)n * 17 + 16, len = 0; char *s = malloc(cap);
    for (int i = 0; i < n; i++) { int k = sprintf(s + len, "%s%s", i ? " " : "", w[((long)i * 7 + i / 3) % 12]); len += (size_t)k; }
    s[len] = 0; return s;
}
static double now_ms(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec * 1000.0 + t.tv_nsec / 1e6; }
static long count(pcre2_code *re, const char *s, size_t n) {
    pcre2_match_data *md = pcre2_match_data_create_from_pattern(re, NULL);
    long c = 0; size_t pos = 0; uint32_t extra = 0, chk = 0;
    while (pos <= n) {
        int rc = pcre2_match(re, (PCRE2_SPTR)s, n, pos, extra | chk, md, NULL);
        chk = PCRE2_NO_UTF_CHECK; /* özne bir kez doğrulanır (sarmalayıcıyla aynı) */
        if (rc == PCRE2_ERROR_NOMATCH) { if (extra) { extra = 0; pos++; continue; } break; }
        if (rc < 0) break;
        PCRE2_SIZE *ov = pcre2_get_ovector_pointer(md); c++;
        if (ov[1] == ov[0]) { extra = PCRE2_NOTEMPTY_ATSTART | PCRE2_ANCHORED; } else extra = 0;
        pos = ov[1];
    }
    pcre2_match_data_free(md); return c;
}
static void run(const char *name, const char *pat, int jit, const char *s) {
    int e; PCRE2_SIZE eo;
    pcre2_code *re = pcre2_compile((PCRE2_SPTR)pat, PCRE2_ZERO_TERMINATED, PCRE2_UTF | PCRE2_UCP, &e, &eo, NULL);
    if (jit) pcre2_jit_compile(re, PCRE2_JIT_COMPLETE);
    size_t n = strlen(s); long c = 0; double t0 = now_ms();
    for (int r = 0; r < 10; r++) c = count(re, s, n);
    printf("%s\t%f\t%ld\n", name, (now_ms() - t0) / 10, c);
    pcre2_code_free(re);
}
int main(void) {
    char *nums = build_numbers(50000), *prose = build_prose(200000);
    run("digits count pcre2 C interp", "[0-9]+", 0, nums);
    run("digits count pcre2 C jit", "[0-9]+", 1, nums);
    run("words count pcre2 C interp", "\\b(foo|bar|baz)\\b", 0, prose);
    run("words count pcre2 C jit", "\\b(foo|bar|baz)\\b", 1, prose);
    run("email count pcre2 C interp", "(\\w+)@(\\w+)\\.com", 0, prose);
    run("email count pcre2 C jit", "(\\w+)@(\\w+)\\.com", 1, prose);
    return 0;
}
