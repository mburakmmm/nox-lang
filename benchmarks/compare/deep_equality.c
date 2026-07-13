#include <stdio.h>
#include <string.h>
typedef struct Point { long long x, y; } Point;
int point_eq(Point a, Point b) { return a.x == b.x && a.y == b.y; }
long long count_equal(long long n) {
    Point a = {1, 2}, b = {1, 2};
    long long la[8] = {1,2,3,4,5,6,7,8};
    long long lb[8] = {1,2,3,4,5,6,7,8};
    long long total = 0;
    long long i = 0;
    while (i < n) {
        if (point_eq(a, b)) total++;
        if (memcmp(la, lb, sizeof(la)) == 0) total++;
        i++;
    }
    return total;
}
int main(void) {
    printf("%lld\n", count_equal(500000));
    return 0;
}
