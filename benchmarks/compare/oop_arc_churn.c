#include <stdio.h>
#include <stdlib.h>
typedef struct Engine { long long hp; } Engine;
typedef struct Car { Engine *engine; } Car;
Car *make_car(long long hp) {
    Engine *e = malloc(sizeof(Engine));
    e->hp = hp;
    Car *c = malloc(sizeof(Car));
    c->engine = e;
    return c;
}
long long compute(long long n) {
    long long total = 0;
    Engine *e0 = malloc(sizeof(Engine));
    e0->hp = 0;
    Car *c = malloc(sizeof(Car));
    c->engine = e0;
    long long i = 0;
    while (i < n) {
        Car *tmp = make_car(i);
        Engine *old = c->engine;
        c->engine = tmp->engine;
        free(old);
        free(tmp);
        total += c->engine->hp;
        i++;
    }
    free(c->engine);
    free(c);
    return total;
}
int main(void) {
    printf("%lld\n", compute(3000000));
    return 0;
}
