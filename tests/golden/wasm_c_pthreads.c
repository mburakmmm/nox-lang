// 2.3 madde 5.5: Nox DIŞI bir araç zinciriyle (wasi-sdk, `wasm32-wasip1-threads`) derlenen GERÇEK bir C `pthread_create`/mutex/atomik/join programı, Nox'un Node host'unun
// (`compiler/wasm_host.mjs`: `env.memory` paylaşımlı bellek, `wasi::thread-spawn`, `wasi_thread_start`) wasi-threads sözleşmesine uyduğunu kanıtlar.
// Derleme: $WASI_SDK_PATH/bin/clang --target=wasm32-wasip1-threads -pthread -O2 wasm_c_pthreads.c -o t.wasm -Wl,--import-memory,--max-memory=268435456
// Beklenen çıktı: atomic=4000 locked=4000 joined=60
#include <pthread.h>
#include <stdio.h>
#include <stdatomic.h>

static atomic_int counter;
static int locked_counter;
static pthread_mutex_t mu = PTHREAD_MUTEX_INITIALIZER;

static void *work(void *arg) {
    long id = (long)arg;
    for (int i = 0; i < 1000; i++) {
        atomic_fetch_add(&counter, 1);
        pthread_mutex_lock(&mu);
        locked_counter += 1;
        pthread_mutex_unlock(&mu);
    }
    return (void *)(id * 10);
}

int main(void) {
    pthread_t th[4];
    for (long i = 0; i < 4; i++) {
        if (pthread_create(&th[i], NULL, work, (void *)i) != 0) { printf("create failed %ld\n", i); return 1; }
    }
    long sum = 0;
    for (int i = 0; i < 4; i++) {
        void *r;
        pthread_join(th[i], &r);
        sum += (long)r;
    }
    printf("atomic=%d locked=%d joined=%ld\n", atomic_load(&counter), locked_counter, sum);
    return 0;
}
