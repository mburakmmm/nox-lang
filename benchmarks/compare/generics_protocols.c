#include <stdio.h>
typedef struct Shape { double (*area)(void *self); void *data; } Shape;
typedef struct Circle { double r; } Circle;
typedef struct Square { double s; } Square;
double circle_area(void *self) { Circle *c = (Circle *)self; return 3.14159 * c->r * c->r; }
double square_area(void *self) { Square *s = (Square *)self; return s->s * s->s; }
long long identity(long long x) { return x; }
double total_area(Shape shape, long long n) {
    double total = 0.0;
    long long i = 0;
    while (i < n) { total += shape.area(shape.data); i++; }
    return total;
}
double compute(long long n) {
    Circle c = { 2.0 };
    Square s = { 3.0 };
    Shape shape_c = { circle_area, &c };
    Shape shape_s = { square_area, &s };
    double total = 0.0;
    total += total_area(shape_c, n);
    total += total_area(shape_s, n);
    long long i = 0;
    while (i < n) { total += (double)identity(i) * 1.0; i++; }
    return total;
}
int main(void) {
    printf("%.17g\n", compute(15000000));
    return 0;
}
