#include <stdio.h>
typedef struct Box { long long items[8]; } Box;
long long box_sum(Box *b) {
    long long total = 0;
    for (int i = 0; i < 8; i++) total += b->items[i];
    return total;
}
long long compute(long long n) {
    Box b = { {1,2,3,4,5,6,7,8} };
    long long total = 0;
    long long i = 0;
    while (i < n) { total += box_sum(&b); i++; }
    return total;
}
int main(void) {
    printf("%lld\n", compute(300000));
    return 0;
}
