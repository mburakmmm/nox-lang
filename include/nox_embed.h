#ifndef NOX_EMBED_H
#define NOX_EMBED_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define NOX_EMBED_ABI 1

#define NOX_EMBED_OK 0
#define NOX_EMBED_ERR_VERSION (-1)
#define NOX_EMBED_ERR_INVAL (-2)
#define NOX_EMBED_ERR_EXISTS (-3)
#define NOX_EMBED_ERR_STATE (-4)
#define NOX_EMBED_ERR_REENTRANT (-5)
#define NOX_EMBED_ERR_NOMEM (-6)
#define NOX_EMBED_ERR_UTF8 (-7)
/* post_event: kuyruk dolu, olay kopyalanmadı; sonra yeniden denenebilir (eskiden ERR_STATE dönerdi). */
#define NOX_EMBED_ERR_FULL (-8)
/* start/pump: kullanıcı kodu dönerken bekleyen bir Nox istisnası var. Nesne nox_exception_take ile alınır; pump'ta kalan
   olaylar kuyrukta durur. */
#define NOX_EMBED_ERR_EXCEPTION (-9)

typedef struct NoxEmbedSlot {
    int32_t abi_version;
    void *app;
} NoxEmbedSlot;

/* İsteğe bağlı host ayırıcısı. alloc: en az len bayt, alignment hizalı bellek döner (sıfırlı olması gerekmez), yetersizse NULL.
   free: aynı len/alignment ile bırakır. Çağrılar farklı iş parçacıklarından gelebilir; ayırıcı iş parçacığı-güvenli olmalı ve
   nox_app_destroy dönene kadar yaşamalıdır. Nox yönetilen heap'i (liste/sözlük/ARC/RuntimeState) buradan ayırır; nox.thread
   çocukları ve havuz iş parçacıkları sistem ayırıcısını kullanmaya devam eder. */
typedef struct NoxHostAllocator {
    uint32_t size; /* sizeof(NoxHostAllocator) */
    void *ctx;
    void *(*alloc)(void *ctx, size_t len, size_t alignment);
    void (*free)(void *ctx, void *ptr, size_t len, size_t alignment);
} NoxHostAllocator;

/* size alanı düzeni ayırır; ABI numarası 1 kalır. Eski host sizeof(NoxHostConfigV1) verir ve sistem ayırıcısı kullanılır;
   yeni host sizeof(NoxHostConfig) verir ve allocator alanını (NULL olabilir) doldurur. */
typedef struct NoxHostConfigV1 {
    uint32_t size;
    uint32_t abi_version;
    NoxEmbedSlot *slot;
    const char *documents;
    const char *support;
    const char *cache;
    const char *temp_dir;
} NoxHostConfigV1;

typedef struct NoxHostConfig {
    uint32_t size;
    uint32_t abi_version;
    NoxEmbedSlot *slot;
    const char *documents;
    const char *support;
    const char *cache;
    const char *temp_dir;
    const NoxHostAllocator *allocator; /* NULL: sistem ayırıcısı */
} NoxHostConfig;

typedef void (*NoxEmbedEntry)(void *rt);
typedef void (*NoxEmbedEventFn)(void *rt, int32_t kind, const char *bytes, uint32_t len);

int32_t nox_embed_abi_version(void);
int32_t nox_app_create(const NoxHostConfig *config, void **out_app);
int32_t nox_app_start(void *app);
void *nox_app_runtime(void *app);
int32_t nox_app_post_event(void *app, int32_t kind, const char *bytes, uint32_t len);
int32_t nox_app_pump(void *app, uint64_t monotonic_time_ns);
int32_t nox_app_request_stop(void *app);
/* İkinci çağrı slot->app üzerinden yapılır. destroy slotu boşaltır;
   aynı serbest bırakılmış işaretçiyi tekrar vermek geçersizdir. */
int32_t nox_app_destroy(void *app);
void nox_app_set_entry(void *app, NoxEmbedEntry entry);
/* Nox kütüphanesi tanımlar, çalışma zamanı değil. start öncesinde app ile çağrılır. */
void nox_embed_bind(void *app);
void nox_app_set_event_fn(void *app, NoxEmbedEventFn fn);

/* Düz bir C dizisini Nox str'ine kopyalar. Çağıran nox_str_release ile bırakır. */
char *nox_str_from_cstr(void *rt, const char *text);
void nox_str_release(void *rt, char *text);
int32_t nox_exception_pending(void *rt);
void *nox_exception_take(void *rt);
/* nox_exception_take nesnesinin sahibi host'tur; işi bitince bırakır (NULL zararsız). */
void nox_exception_release(void *rt, void *exception);

#ifdef __cplusplus
}
#endif

#endif
