#include <stdio.h>
long long fib(long long n) {
    if (n < 2) return n;
    return fib(n - 1) + fib(n - 2);
}
int main(void) {
    printf("%lld\n", fib(34));
    return 0;
}
