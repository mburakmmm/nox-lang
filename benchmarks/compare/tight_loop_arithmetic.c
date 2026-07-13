#include <stdio.h>
int main(void) {
    unsigned long long i = 0, total = 0;
    unsigned long long n = 20000000ULL;
    while (i < n) {
        total = total + i * i - i;
        i = i + 1;
    }
    printf("%lld\n", (long long)total);
    return 0;
}
