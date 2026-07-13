#include <stdio.h>
const char *pick(long long i) {
    if (i % 3 == 0) return "alpha";
    if (i % 3 == 1) return "beta";
    return "gamma";
}
const char *pass_through(const char *s) { return s; }
long long compute(long long n) {
    long long count = 0;
    long long i = 0;
    while (i < n) {
        const char *s = pass_through(pass_through(pick(i)));
        (void)s;
        if (i % 3 == 0) count++;
        i++;
    }
    return count;
}
int main(void) {
    printf("%lld\n", compute(15000000));
    return 0;
}
