#ifndef NOX_HOST_H
#define NOX_HOST_H

/* nox_host.h — Nox kütüphanesini bir C/Python ana makinesinden ÇAĞIRMA ABI'si (v1, DENEYSEL).
 *
 * KARARLILIK: deneysel. `abi_version`/`size` alanları sürümlemeyi taşır; NoxPy gerçek kullanımla doğrulayana kadar uyumsuz değişiklik OLABİLİR (bkz. docs/apis/stability.md).
 * GÜVEN SINIRI (AGENTS.md §9.5): bu başlıkla çağrılan Nox kodu TAM yerel yetkiyle çalışır; host Nox'un tip/sahiplik garantilerinin DIŞINDADIR. Nox nesnelerinin iç bellek
 * düzeni burada ASLA görünmez: yalnızca opak işaretçiler, (veri, uzunluk) span'leri ve host'a AİT kopya tamponlar geçer.
 *
 * KULLANIM:
 *   1) Nox kaynağı `@export` ile işaretlenir ve `noxc build --emit-obj|--emit-static-lib|--emit-shared-lib --host-abi [--module-name <ad>] <dosya.nox>` ile derlenir.
 *   2) `nox_host_context_create` ile bir bağlam kurulur; `nox_host_module_init_<modül>(ctx)` modülün üst-düzey kodunu çalıştırır.
 *   3) Her `@export def f(...)` için `nox_host_export_<modül>_f` çağrılır (aşağıdaki tip eşlemesi).
 *   4) `nox_host_module_fini_<modül>(ctx)`, sonra `nox_host_context_destroy(ctx)`.
 *
 * TİP EŞLEMESİ (parametre → C):  int → int64_t | float → double | bool → uint8_t (0/1) | str → const uint8_t *data, size_t len (UTF-8; geçersizse NOX_HOST_ERR_UTF8)
 *                                 | bytes → const uint8_t *data, size_t len (ham bayt; gömülü 0 korunur)
 *                                 | sınıf örneği → NoxHostHandle (uint64_t; bağlama ait, nesil-denetimli opak tutamaç)
 *                                 | T | None, list[T], dict[K, V], tuple[...] → NoxHostValue (uint64_t, v2; bkz. "değer ağaçları" bölümü)
 *                         (dönüş → `out` işaretçisi): int → int64_t* | float → double* | bool → uint8_t* | str → NoxHostBuffer* (UTF-8, host serbest bırakır)
 *                                 | bytes → NoxHostBuffer* | sınıf örneği → NoxHostHandle* (host `nox_host_handle_release` ile bırakır) | None → `out` parametresi YOKTUR.
 * İŞLEV İMZASI:  NoxHostStatus nox_host_export_<modül>_<ad>(NoxHostContext *ctx, <parametreler...>, [<dönüş> *out,] NoxHostError **err);
 *                `err` NULL olabilir (hata ayrıntısı istenmiyorsa). Dönüş NOX_HOST_ERR_EXCEPTION ise `*err` doludur ve `nox_host_error_release` ile bırakılmalıdır.
 *
 * İŞ PARÇACIĞI: bir NoxHostContext AYNI ANDA yalnızca TEK iş parçacığından kullanılabilir (yabancı iş parçacığı bağlama sözleşmesi ayrı bir sürümün konusudur).
 * ÖLÜMCÜL DURUMLAR: bellek yetersizliği ve sabit-genişlikli tamsayı taşma tuzağı süreci sonlandırır (kurtarılabilir hataya ÇEVRİLEMEZ); Nox istisnaları status olarak döner.
 */

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* v2 (UR-008) v1'e GERİYE UYUMLU eklemedir: `NoxHostContextConfig.abi_version` olarak 1 ya da 2 verilebilir; değer-ağacı API'si (aşağıda) yalnızca eklenmiştir. */
#define NOX_HOST_ABI_VERSION 2u

typedef int32_t NoxHostStatus;
#define NOX_HOST_OK 0
#define NOX_HOST_ERR_EXCEPTION 1 /* bir Nox istisnası fırlatıldı; *err'e bakın */
#define NOX_HOST_ERR_NOMEM 2
#define NOX_HOST_ERR_INVAL 3 /* NULL/geçersiz bağlam ya da argüman */
#define NOX_HOST_ERR_VERSION 4
#define NOX_HOST_ERR_UTF8 5 /* `str` parametresi geçerli UTF-8 değil */
#define NOX_HOST_ERR_STATE 6
#define NOX_HOST_ERR_INVALID_HANDLE 7 /* bırakılmış, sahte ya da başka bağlamın handle'ı */

/* Nox sınıf örneğine opak, nesil-denetimli tutamaç (0 geçersizdir). Bir tutamaç yalnızca ÜRETEN bağlamda geçerlidir; ham işaretçi/bellek düzeni görünmez. */
typedef uint64_t NoxHostHandle;

typedef struct NoxHostContext NoxHostContext; /* opak */
typedef struct NoxHostError NoxHostError;     /* opak; nox_host_error_release ile bırakılır */

/* Borçlu bayt görünümü: veri çağıranındır (ya da ilgili nesne bırakılana kadar geçerlidir). */
typedef struct NoxHostSpan {
    const uint8_t *data;
    size_t len;
} NoxHostSpan;

/* Host'a ait kopya: nox_host_buffer_release ile bırakılır (data NULL ve len 0 boş içeriktir). */
typedef struct NoxHostBuffer {
    uint8_t *data;
    size_t len;
} NoxHostBuffer;

/* v1: size = sizeof(NoxHostContextConfig), abi_version = NOX_HOST_ABI_VERSION, allocator NULL OLMALIDIR (host ayırıcısı sonraki sürüm). */
typedef struct NoxHostContextConfig {
    uint32_t size;
    uint32_t abi_version;
    const void *allocator;
} NoxHostContextConfig;

uint32_t nox_host_abi_version(void);
NoxHostStatus nox_host_context_create(const NoxHostContextConfig *config, NoxHostContext **out);
void nox_host_context_destroy(NoxHostContext *ctx);

void nox_host_buffer_release(NoxHostBuffer *buf);

/* Handle yönetimi. Bırakılan/sahte/başka bağlamın handle'ı üzerindeki her işlem NOX_HOST_ERR_INVALID_HANDLE döner (serbest kalmış belleğe dokunulmaz). Bağlamdan ÖNCE
 * tüm NoxHostError'lar bırakılmalıdır; bağlam yok edilirken açık kalan handle'lar otomatik bırakılır. */
NoxHostStatus nox_host_handle_release(NoxHostContext *ctx, NoxHostHandle h);
NoxHostStatus nox_host_handle_retain(NoxHostContext *ctx, NoxHostHandle h, NoxHostHandle *out); /* aynı nesneye ikinci handle */
int32_t nox_host_handle_is_valid(NoxHostContext *ctx, NoxHostHandle h);

/* ---- v2: değer ağaçları (`T | None`, `list[T]`, `dict[K, V]`, `tuple[...]` parametre/dönüşleri) ----
 * `@export def f(xs: list[int], o: int | None) -> dict[str, int]` için C imzası: `nox_host_export_<modül>_f(ctx, NoxHostValue xs, NoxHostValue o, NoxHostValue *out, NoxHostError **err)`.
 * Bir NoxHostValue, host tarafında kurulan/okunan OPAK, nesil-denetimli bir ağaçtır (Nox nesnesi değildir; iç düzen görünmez). Türler: none, int, float, bool, str, bytes, list, dict, tuple.
 * `T | None`: değer `none` ise None, değilse T değeridir. Parametre handle'ları çağrı boyunca ÖDÜNÇTÜR (host bırakır); dönüş handle'ı host'undur ve `nox_host_value_release` ile bırakılır.
 * SAHİPLİK: host'un elindeki her handle bırakılmalıdır. `append`/`dict_set` alt değeri başvuru sayar (host kendi handle'ını yine bırakır); `item`/`dict_entry` YENİ handle verir. Bir değeri kendi
 * altına eklemek (döngü) NOX_HOST_ERR_INVAL'dır. Yanlış tür/aralık NOX_HOST_ERR_INVAL, bırakılmış/sahte handle NOX_HOST_ERR_INVALID_HANDLE'dır. Nox tarafında beklenmeyen bir değer türü
 * (ör. list yerine str) bir ValueError olarak (NOX_HOST_ERR_EXCEPTION) döner. Sınıf örnekleri konteyner İÇİNDE desteklenmez (üst-düzey parametre olarak NoxHostHandle geçer). */
typedef uint64_t NoxHostValue;
#define NOX_HOST_VALUE_NONE 0
#define NOX_HOST_VALUE_INT 1
#define NOX_HOST_VALUE_FLOAT 2
#define NOX_HOST_VALUE_BOOL 3
#define NOX_HOST_VALUE_STR 4
#define NOX_HOST_VALUE_BYTES 5
#define NOX_HOST_VALUE_LIST 6
#define NOX_HOST_VALUE_DICT 7
#define NOX_HOST_VALUE_TUPLE 8

NoxHostStatus nox_host_value_none(NoxHostContext *ctx, NoxHostValue *out);
NoxHostStatus nox_host_value_int(NoxHostContext *ctx, int64_t v, NoxHostValue *out);
NoxHostStatus nox_host_value_float(NoxHostContext *ctx, double v, NoxHostValue *out);
NoxHostStatus nox_host_value_bool(NoxHostContext *ctx, uint8_t v, NoxHostValue *out);
/* is_bytes = 0: UTF-8 `str` (geçersizse NOX_HOST_ERR_UTF8); is_bytes != 0: ham `bytes` (gömülü 0 korunur). Veri KOPYALANIR. */
NoxHostStatus nox_host_value_str(NoxHostContext *ctx, const uint8_t *data, size_t len, int32_t is_bytes, NoxHostValue *out);
/* kind: NOX_HOST_VALUE_LIST / _DICT / _TUPLE. */
NoxHostStatus nox_host_value_container(NoxHostContext *ctx, int32_t kind, NoxHostValue *out);
NoxHostStatus nox_host_value_append(NoxHostContext *ctx, NoxHostValue container, NoxHostValue item);                  /* list/tuple */
NoxHostStatus nox_host_value_dict_set(NoxHostContext *ctx, NoxHostValue dict, NoxHostValue key, NoxHostValue value);  /* anahtar skaler; aynı anahtar değeri değiştirir */

NoxHostStatus nox_host_value_kind(NoxHostContext *ctx, NoxHostValue v, int32_t *out);
NoxHostStatus nox_host_value_get_int(NoxHostContext *ctx, NoxHostValue v, int64_t *out);   /* int ya da bool */
NoxHostStatus nox_host_value_get_float(NoxHostContext *ctx, NoxHostValue v, double *out);
NoxHostStatus nox_host_value_get_span(NoxHostContext *ctx, NoxHostValue v, NoxHostSpan *out); /* str/bytes; değer bırakılana kadar geçerli */
NoxHostStatus nox_host_value_len(NoxHostContext *ctx, NoxHostValue v, size_t *out);           /* list/tuple elemanı, dict çifti sayısı */
NoxHostStatus nox_host_value_item(NoxHostContext *ctx, NoxHostValue v, size_t index, NoxHostValue *out);
NoxHostStatus nox_host_value_dict_entry(NoxHostContext *ctx, NoxHostValue v, size_t index, NoxHostValue *key_out, NoxHostValue *value_out); /* eklenme sırası */
NoxHostStatus nox_host_value_release(NoxHostContext *ctx, NoxHostValue v);
int32_t nox_host_value_is_valid(NoxHostContext *ctx, NoxHostValue v);

/* Hata incelemesi. Span'ler nox_host_error_release'e kadar geçerlidir; class_name/message UTF-8'dir. */
void nox_host_error_release(NoxHostError *err);
int64_t nox_host_error_line(const NoxHostError *err); /* `raise` satırı (bilinmiyorsa 0) */
NoxHostStatus nox_host_error_class_name(const NoxHostError *err, NoxHostSpan *out);
NoxHostStatus nox_host_error_message(const NoxHostError *err, NoxHostSpan *out);

/* `--host-abi` ile modül başına ÜRETİLİR (yukarıdaki KULLANIM): bu başlıkta bildirilmezler.
 *   NoxHostStatus nox_host_module_init_<modül>(NoxHostContext *ctx, NoxHostError **err);
 *   void          nox_host_module_fini_<modül>(NoxHostContext *ctx);
 *   NoxHostStatus nox_host_export_<modül>_<ad>(NoxHostContext *ctx, ...); */

#ifdef __cplusplus
}
#endif

#endif
