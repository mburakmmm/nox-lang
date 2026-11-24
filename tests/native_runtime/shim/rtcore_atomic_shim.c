/* rtcore_atomic_shim.c — GEÇİCİ platform sağlayıcısı (native-runtime readiness R2).
 *
 * Nox'ta ham-adres atomik YOK (yalnız ARC için imm-add `atomicrmw acq_rel`, bkz. llvm_emit.zig). Bu shim, dil/ABI değişikliği
 * OLMADAN `extern def` ile ham adres atomiklerini sağlar; yalnız R2 fizibilite kanıtıdır, KALICI çözüm DEĞİLDİR
 * (project/native-runtime-dependencies.md: "geçici shim"). extern def çağrı kuralı: gizli `rt` extern'e GEÇİRİLMEZ (yalnız `with_rt` ile). Her işlev bir bellek-sıralama argümanı alır:
 * 0=relaxed 1=acquire 2=release 3=acq_rel 4=seq_cst (geçersiz sıra -> fail-stop, SESSİZ plain fallback YOK).
 * Yalnız onaylı yüzey: u32/u64 (native pointer = u64). Tahsis YOK, libc YOK (yalnız _exit/write fatal için).
 */
#include <stdint.h>
#include <stdlib.h>
#include <unistd.h>

typedef int64_t w;
static int mo(w o) {
    switch (o) {
    case 0: return __ATOMIC_RELAXED;
    case 1: return __ATOMIC_ACQUIRE;
    case 2: return __ATOMIC_RELEASE;
    case 3: return __ATOMIC_ACQ_REL;
    case 4: return __ATOMIC_SEQ_CST;
    default: { static const char m[] = "fatal: invalid atomic ordering\n"; write(2, m, sizeof m - 1); _exit(71); }
    }
}
/* load ordering yalniz relaxed/acquire/seq_cst; store yalniz relaxed/release/seq_cst (acq_rel gecersiz -> fail-stop). */
static int mo_load(w o) { if (o == 2 || o == 3) { mo(99); } return mo(o); }
static int mo_store(w o) { if (o == 1 || o == 3) { mo(99); } return mo(o); }
static int mo_cas_fail(w o) { if (o == 2 || o == 3) { mo(99); } return mo(o); }

#define OPS(SUF, T) \
w rtcore_atomic_load_##SUF(void *p, w o) { return (w)__atomic_load_n((T *)p, mo_load(o)); } \
void rtcore_atomic_store_##SUF(void *p, w v, w o) { __atomic_store_n((T *)p, (T)v, mo_store(o)); } \
w rtcore_atomic_xchg_##SUF(void *p, w v, w o) { return (w)__atomic_exchange_n((T *)p, (T)v, mo(o)); } \
w rtcore_atomic_cas_##SUF(void *p, w expected, w desired, w so, w fo) { /* eski degeri doner */ \
    T e = (T)expected; \
    __atomic_compare_exchange_n((T *)p, &e, (T)desired, 0, mo(so), mo_cas_fail(fo)); return (w)e; } \
w rtcore_atomic_fetch_add_##SUF(void *p, w v, w o) { return (w)__atomic_fetch_add((T *)p, (T)v, mo(o)); } \
w rtcore_atomic_fetch_sub_##SUF(void *p, w v, w o) { return (w)__atomic_fetch_sub((T *)p, (T)v, mo(o)); } \
w rtcore_atomic_fetch_and_##SUF(void *p, w v, w o) { return (w)__atomic_fetch_and((T *)p, (T)v, mo(o)); } \
w rtcore_atomic_fetch_or_##SUF(void *p, w v, w o) { return (w)__atomic_fetch_or((T *)p, (T)v, mo(o)); } \
w rtcore_atomic_fetch_xor_##SUF(void *p, w v, w o) { return (w)__atomic_fetch_xor((T *)p, (T)v, mo(o)); }
OPS(u32, uint32_t)
OPS(u64, uint64_t)

void rtcore_atomic_fence(w o) { __atomic_thread_fence(mo(o)); }
void rtcore_cpu_relax(void) {
   
#if defined(__x86_64__)
    __asm__ __volatile__("pause");
#elif defined(__aarch64__)
    __asm__ __volatile__("yield");
#endif
}

/* TLS saglayici: runtime-yerel `worker_slot` (asap.zig `threadlocal g_worker_slot` karsiligi). */
static _Thread_local w g_slot;
w rtcore_tls_get(void) { return g_slot; }
void rtcore_tls_set(w v) { g_slot = v; }
