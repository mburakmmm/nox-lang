/* 2.2 aşama 8: `noxclibs-<hedef>.a` (isteğe bağlı bağlanan C kütüphane arşivi) için ortak yardımcılar. Arşiv, ilgili `nox.*` modülünü içe aktaran programa
 * YALNIZCA derleyicinin bağlama adımında eklenir (programın IR'ı `nxc_` sembollerine başvuruyorsa); noxrt.o hiçbir `nxc_` sembolüne başvurmaz. Windows, Linux ve macOS'ta aynı kod. */
#ifndef NXC_COMMON_H
#define NXC_COMMON_H
#include <stdint.h>
#include <stddef.h>
#include <string.h>

/* Nox `str`: veri işaretçisi bayt dizisini (sıfır-sonlanan, ikili güvenli) gösterir; 8 bayt önceki paketlenmiş başlığın alt 52 biti bayt uzunluğudur (shared/abi_layout.zig). */
static inline size_t nxc_slen(const uint8_t *s) {
    if (!s) return 0;
    uint64_t h;
    memcpy(&h, s - 8, 8);
    return (size_t)(h & ((1ULL << 52) - 1));
}

/* runtime/str.zig `nox_str_from_bytes_c`: `p[0..n]`den yeni Nox str. */
extern void *nox_str_from_bytes_c(void *rt, const uint8_t *p, size_t n);

#if defined(_MSC_VER)
#define NXC_TLS __declspec(thread)
#else
#define NXC_TLS __thread
#endif
#endif
