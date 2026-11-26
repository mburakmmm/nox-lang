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
 *                                 | nox.host.HostObject → NoxHostExternalRef (uint64_t, v3)
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

/* v2 (UR-008) ve v3 (UR-009..UR-014) v1'e GERİYE UYUMLU eklemelerdir: `NoxHostContextConfig.abi_version` olarak 1, 2 ya da 3 verilebilir; v2/v3 API'si (aşağıda) yalnızca eklenmiştir. */
#define NOX_HOST_ABI_VERSION 3u

typedef int32_t NoxHostStatus;
#define NOX_HOST_OK 0
#define NOX_HOST_ERR_EXCEPTION 1 /* bir Nox istisnası fırlatıldı; *err'e bakın */
#define NOX_HOST_ERR_NOMEM 2
#define NOX_HOST_ERR_INVAL 3 /* NULL/geçersiz bağlam ya da argüman */
#define NOX_HOST_ERR_VERSION 4
#define NOX_HOST_ERR_UTF8 5 /* `str` parametresi geçerli UTF-8 değil */
#define NOX_HOST_ERR_STATE 6
#define NOX_HOST_ERR_INVALID_HANDLE 7 /* bırakılmış, sahte ya da başka bağlamın handle'ı */
#define NOX_HOST_ERR_BUSY 10 /* v3 (UR-012): arabellekte çakışan sabitleme var (yazma/okuma) */
#define NOX_HOST_ERR_CANCELLED 9 /* v3 (UR-011): asenkron görev iptal edildi (nihai durum; ayrıntı yok) */
#define NOX_HOST_ERR_HOST_EXCEPTION 8 /* v3 (UR-010): bir host geri çağrısı istisna fırlattı; nox_host_error_host_token ile özgün jeton alınır */

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
#define NOX_HOST_VALUE_TYPED_ARRAY 10 /* v3 (UR-012): bitişik tek-dtype'lı sayısal dizi (bkz. nox_host_value_typed_array) */
#define NOX_HOST_VALUE_EXTERNAL_REF 11 /* v3 (UR-010): host nesne belirteci (bkz. NoxHostExternalRef) */
#define NOX_HOST_VALUE_HANDLE 9 /* v3 (UR-009): bir sınıf örneğini tutan değer (`Class | None`, `list[Class]`; bkz. aşağıdaki nox_host_value_handle) */

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

/* ---- v3 (UR-009): sınıf örnekleri `NoxHostHandle` olarak, kapsayıcı içinde `NOX_HOST_VALUE_HANDLE` olarak geçer ----
 * `nox_host_value_handle`: `h` tutamacının nesnesini tutan yeni bir değer (nesne ARC +1; host kendi `h`ini yine bırakır). `nox_host_value_get_handle`: `NOX_HOST_VALUE_HANDLE` değerinin
 * nesnesine YENİ bir tutamaç verir (host `nox_host_handle_release` ile bırakır). `Class | None` için `None`, `nox_host_value_none` ile kurulur. Kapsayıcı İÇİNDE yalnızca TAM sınıf
 * örnekleri kabul edilir (alt sınıf örneği Nox tarafında ValueError olarak döner; üst-düzey `NoxHostHandle` parametrelerinde bu kısıt yoktur). */
NoxHostStatus nox_host_value_handle(NoxHostContext *ctx, NoxHostHandle h, NoxHostValue *out);
NoxHostStatus nox_host_value_get_handle(NoxHostContext *ctx, NoxHostValue v, NoxHostHandle *out);
/* Tutamacın Nox sınıf adı (UTF-8, ör. "Counter"; `h` geçerliyken geçerli). Host, tutamacın beklenen sınıfa ait olduğunu bununla doğrular: üst-düzey `NoxHostHandle` parametrelerinde
 * tür denetimi HOST'un sorumluluğundadır (yanlış sınıfın tutamacını vermek tanımsız davranıştır). */
NoxHostStatus nox_host_handle_type_name(NoxHostContext *ctx, NoxHostHandle h, NoxHostSpan *out);

/* ---- v3 (UR-010): host nesneleri ve yeniden-girişli geri çağrılar ----
 * `NoxHostExternalRef`, host'un yönettiği opak bir nesneyi (ör. Python çağrılabilir) betimleyen belirteçtir (0 geçersiz); Nox onu hiçbir zaman çözmez. Nox `nox.host.HostObject` ile tutar ve çağırır.
 * Geri çağrılar (invoke/retain/release) bağlam kilidi TUTULURKEN çağrılır; kilit YENİDEN-GİRİŞLİdir: geri çağrıyı yapan iş parçacığı içinden aynı bağlamda `nox_host_value_*` / `nox_host_export_*` çağırabilir
 * (ör. Python'un GIL'i tutan iş parçacığı); BAŞKA iş parçacıkları geri çağrı bitene dek BEKLER (askıdaki Nox çerçevelerine yabancı iş parçacığı giremez). Geri çağrı içinden `nox_host_context_destroy` en dıştaki çağrı bitince yapılır.
 * `invoke`: `args` ödünç bir TUPLE değeridir; sonucu `*out_result`a host kurar (Nox sahip olur ve bırakır; 0 = None). Hata için NOX_HOST_ERR_HOST_EXCEPTION döndürüp `*out_err_token`a host'un
 * istisna belirtecini (Nox'a +1 başvuru geçer; HostError yok edilince `release` alır) ve isteğe bağlı UTF-8 ileti `*out_err_msg`a (ÖDÜNÇ: `invoke` dönünce kopyalanır; nox_host_buffer_release GEREKMEZ) yazılır.
 * Başka her hata durumu RuntimeError olur. `retain`/`release` null olabilir. `struct_size` >= sizeof(NoxHostCallbackOps) olmalıdır (aksi NOX_HOST_ERR_VERSION). ops == NULL geri çağrıları kaldırır. */
typedef uint64_t NoxHostExternalRef;
typedef struct NoxHostCallbackOps {
    uint32_t struct_size;
    void *user_data;
    NoxHostStatus (*invoke)(void *user_data, NoxHostContext *ctx, NoxHostExternalRef target, NoxHostValue args_tuple,
                            NoxHostValue *out_result, uint64_t *out_err_token, NoxHostBuffer *out_err_msg);
    void (*retain)(void *user_data, NoxHostExternalRef ref);
    void (*release)(void *user_data, NoxHostExternalRef ref);
} NoxHostCallbackOps;
NoxHostStatus nox_host_context_set_callbacks(NoxHostContext *ctx, const NoxHostCallbackOps *ops);
/* NOX_HOST_ERR_HOST_EXCEPTION'da host'un `*out_err_token` değeri (Nox kaynaklı istisnada 0); `nox_host_error_release`e kadar geçerlidir. Host özgün istisnayı jetondan geri kurar. */
uint64_t nox_host_error_host_token(const NoxHostError *err);
/* NOX_HOST_VALUE_EXTERNAL_REF: değer belirteci tutar (host `retain` alır; değer bırakılınca `release`). `get`: belirteç ÖDÜNÇTÜR. Geri çağrılar kurulu değilse NOX_HOST_ERR_STATE. */
NoxHostStatus nox_host_value_external_ref(NoxHostContext *ctx, NoxHostExternalRef ref, NoxHostValue *out);
NoxHostStatus nox_host_value_get_external_ref(NoxHostContext *ctx, NoxHostValue v, NoxHostExternalRef *out);

/* ---- v3 (UR-011): `@export async def` görevleri ----
 * Her `@export async def foo(...)` için `--host-abi` şunu üretir (parametre eşlemesi senkron ihracatla aynıdır; sonuç ayrı alınır):
 *   NoxHostStatus nox_host_async_start_<modül>_foo(NoxHostContext *ctx, <parametreler...>, NoxHostTaskCallback on_done, void *user_data, NoxHostTask *out_task, NoxHostError **err);
 * Başarıda `*out_task` doludur (0 geçersiz) ve `on_done` görev başına ENAZ VE ENÇOK bir kez çağrılır (`nox_host_task_release` ile ilgilenmekten vazgeçmediğiniz sürece): işçi iş parçacığından, bağlam kilidi
 * AÇIKKEN (içinden `nox_host_task_take_result`, `nox_host_value_*`, `nox_host_export_*` çağrılabilir; görev kodu çalışmıyorken: iki görev kodu arası). `final_status`: OK, ERR_EXCEPTION, ERR_HOST_EXCEPTION, ERR_CANCELLED ya da ERR_STATE (çıkmaz: Nox
 * RuntimeError("deadlock in async task"); süreç ölmez, ancak o bağlamda yeni görev başlatılamaz). Başlatma hatası yalnızca durum kodudur (`*err` NULL'lanır; NOX_HOST_ERR_UTF8/INVALID_HANDLE/INVAL/STATE/NOMEM).
 * Parametre değerleri başlatma sırasında kopyalanır/çoğaltılır (host `NoxHostValue`/`NoxHostHandle`larını hemen bırakabilir); `NoxHostExternalRef` belirteçlerini ise görev bitene kadar canlı tutmak host'un işidir.
 * Sonuç her zaman bir `NoxHostValue`dur (sınıf dönüşü NOX_HOST_VALUE_HANDLE; None → `*out_val == 0`). `nox_host_task_take_result` bağlam kilidini BEKLEMEZ, sonucu bir kez devreder (tekrar: NOX_HOST_ERR_STATE) ve nihai durumu
 * döndürür; ERR_EXCEPTION/ERR_HOST_EXCEPTION/ERR_STATE'te `*out_err` istisnayı verir (`nox_host_error_release`). `nox_host_task_cancel` kooperatiftir (görev bir sonraki `await`inde `CancelledError` alır) ve yine kilit beklemez.
 * `nox_host_task_release` çalışan görevi iptal eder ve `on_done`u susturur; bitmiş görevde sonucu/hatayı (alınmadıysa) bırakır. Bağlamı yok etmek çalışan görevleri iptal eder ve işçiyi bekler.
 * Bağlam kilidi görev Nox kodu çalıştırırken tutulur (G/Ç/zamanlayıcı beklerken ve geri çağrılarda açılır): paralel iş yükleri için bağlam başına bir iş parçacığı kullanın. */
typedef uint64_t NoxHostTask;
typedef void (*NoxHostTaskCallback)(void *user_data, NoxHostContext *ctx, NoxHostTask task, NoxHostStatus final_status);
NoxHostStatus nox_host_task_cancel(NoxHostContext *ctx, NoxHostTask task);
NoxHostStatus nox_host_task_take_result(NoxHostContext *ctx, NoxHostTask task, NoxHostValue *out_val, NoxHostError **out_err);
NoxHostStatus nox_host_task_release(NoxHostContext *ctx, NoxHostTask task);

/* ---- v3 (UR-012): bulk sayısal diziler ve SIFIR KOPYA sabitlenmiş arabellekler (PEP 3118 / NumPy / Arrow) ----
 * TYPED_ARRAY değeri `count` elemanı TEK bellek kopyasıyla taşır (N kutulama çağrısı yerine). Nox'ta `list[int]`/`list[float]`/`list[bool]` parametreleri `list` değeri YA DA uygun dtype'lı TYPED_ARRAY kabul eder
 * (int: tamsayı/BOOL dtype'ları, float: tüm sayısal dtype'lar, bool: yalnız BOOL; uyumsuz dtype Nox'ta ValueError). `get`: veri değer bırakılana kadar geçerli BORÇ görünümdür.
 * Sabitleme: Nox'un `nox.host.F64Buffer`/`I64Buffer`/`I32Buffer`/`U8Buffer` örneklerinin (bir `NoxHostHandle` olarak tutulan) verisine zero-copy görünüm verir. Çok sayıda OKUMA sabitlemesi serbesttir; en çok bir ÖZEL YAZMA
 * sabitlemesi (aksi `NOX_HOST_ERR_BUSY`). Sabitleme nesneyi canlı tutar; sabitliyken Nox'ta `resize` RuntimeError verir (veri adresi sabit kalır). Veri `nox_host_buffer_unpin`e kadar geçerlidir. Sınıf desteklenmiyorsa NOX_HOST_ERR_INVAL. */
typedef enum NoxHostDType {
    NOX_HOST_DTYPE_U8 = 1, NOX_HOST_DTYPE_I8 = 2, NOX_HOST_DTYPE_U16 = 3, NOX_HOST_DTYPE_I16 = 4, NOX_HOST_DTYPE_U32 = 5, NOX_HOST_DTYPE_I32 = 6,
    NOX_HOST_DTYPE_U64 = 7, NOX_HOST_DTYPE_I64 = 8, NOX_HOST_DTYPE_F32 = 9, NOX_HOST_DTYPE_F64 = 10, NOX_HOST_DTYPE_BOOL = 11
} NoxHostDType;
#define NOX_HOST_BUF_READONLY 0u
#define NOX_HOST_BUF_WRITABLE 1u
#define NOX_HOST_BUF_CONTIGUOUS_C 2u
typedef struct NoxHostBufferView {
    uint32_t struct_size;
    int32_t dtype;
    void *data;
    size_t byte_len;
    size_t itemsize;
    int32_t ndim;      /* 1..8 */
    uint32_t flags;    /* NOX_HOST_BUF_* */
    int64_t shape[8];
    int64_t strides[8]; /* bayt */
    uint64_t pin_id;
} NoxHostBufferView;
NoxHostStatus nox_host_handle_pin_buffer(NoxHostContext *ctx, NoxHostHandle h, uint32_t req_flags, NoxHostBufferView *out_view, NoxHostError **err);
NoxHostStatus nox_host_buffer_unpin(NoxHostContext *ctx, uint64_t pin_id);
NoxHostStatus nox_host_value_typed_array(NoxHostContext *ctx, int32_t dtype, const void *data, size_t count, NoxHostValue *out);
NoxHostStatus nox_host_value_get_typed_array(NoxHostContext *ctx, NoxHostValue v, int32_t *out_dtype, const void **out_data, size_t *out_count);

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
