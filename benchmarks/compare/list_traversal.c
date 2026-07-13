#include <stdio.h>
void make_data(long long *out) {
    long long data[20] = {3,1,4,1,5,9,2,6,5,3,5,8,9,7,9,3,2,3,8,4};
    for (int i = 0; i < 20; i++) out[i] = data[i];
}
long long sum_list(long long *xs, int len) {
    long long total = 0;
    for (int i = 0; i < len; i++) total += xs[i];
    return total;
}
long long compute(long long n) {
    long long total = 0;
    long long i = 0;
    long long buf[20];
    while (i < n) {
        make_data(buf);
        total += sum_list(buf, 20);
        i++;
    }
    return total;
}
int main(void) {
    printf("%lld\n", compute(5000000));
    return 0;
}
