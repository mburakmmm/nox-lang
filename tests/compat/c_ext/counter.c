/* Nox'un `extern def` opak `ptr` tipi (Faz 20'nin ikinci artımı, bkz.
 * nox-teknik-spesifikasyon.md §3.20) için GERÇEK, minimal bir "handle
 * tabanlı C API" örneği — `FILE*`/`sqlite3*` gibi gerçek C API'lerinin
 * yaygın deseni: bir "create" opak bir işaretçi döner, kullanıcı bunu
 * yalnızca BAŞKA API çağrılarına GEÇİRİR (İÇİNİ HİÇ bilmeden), bir
 * "destroy" onu serbest bırakır.
 */
#include <stdlib.h>

typedef struct {
    long value;
} Counter;

void *counter_create(long initial)
{
    Counter *c = malloc(sizeof(Counter));
    c->value = initial;
    return c;
}

long counter_get(void *handle)
{
    Counter *c = (Counter *)handle;
    return c->value;
}

void counter_increment(void *handle)
{
    Counter *c = (Counter *)handle;
    c->value += 1;
}

void counter_destroy(void *handle)
{
    free(handle);
}
