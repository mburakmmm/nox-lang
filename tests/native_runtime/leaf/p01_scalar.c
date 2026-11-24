/* P01 harness: noxrt.o OLMADAN; gizli rt parametresi (ilk arguman) 0 gecilir. */
#include <stdint.h>
#include <stdio.h>
extern int64_t leaf_add(int64_t rt, int64_t a, int64_t b);
extern int64_t leaf_sum(int64_t rt, int64_t n);
extern int64_t leaf_fnv(int64_t rt, int64_t n);
extern int64_t leaf_gcd(int64_t rt, int64_t a, int64_t b);
extern int64_t leaf_clamp(int64_t rt, int64_t v, int64_t lo, int64_t hi);
int main(void) {
    printf("%lld %lld %lld %lld %lld\n", (long long)leaf_add(0, 40, 2), (long long)leaf_sum(0, 10),
           (long long)leaf_fnv(0, 100), (long long)leaf_gcd(0, 252, 105), (long long)leaf_clamp(0, 15, 0, 7));
    return 0;
}
