#include <stdio.h>
long long compute(long long n) {
    long long total = 0;
    long long i = 0;
    long long nums[8] = {1,2,3,4,5,6,7,8};
    while (i < n) {
        long long x = i, y = i + 1;
        long long inner = 0;
        for (int j = 0; j < 8; j++) inner += nums[j];
        total += x + y + inner;
        i++;
    }
    return total;
}
int main(void) {
    printf("%lld\n", compute(5000000));
    return 0;
}
