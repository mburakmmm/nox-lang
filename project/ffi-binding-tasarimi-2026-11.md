# FFI ergonomisi ve otomatik binding üretimi — tasarım (TODO 3.4 + 5.1)

Tarih: 2026-11-12. Kullanıcı kararları (aynı gün): struct-by-value = **üretilen C kabuğu**; saklanan callback = **closure da desteklenir**; başlık
ayrıştırma = **kendi C bildirim ayrıştırıcımız** (`cc -E` çıktısı üzerinde, dış bağımlılık yok); hata sözleşmesi = **dilde bildirim sözdizimi**; doğrulama =
**yyjson** (kabul testi) ve en sonda **`nox.json` ile benchmark**.

Girdi: `project/ffi-performans-analizi-2026-11.md` (kalan ergonomi eksikleri: struct-by-value, saklanan callback, hata sözleşmesi, `list`/`bytes` görünümü).

## Mevcut durum (yoklandı)

- `@ffi.callback("cb", "userdata")`: derleyici trampoline üretir (`compiler/codegen_qbe/ffi_callback.zig`); son parametre (`userdata`) trampoline'a `%rt`
  olarak gelir. Belge "senkron çalışır, kayıt edilip sonra çağrılan desteklenmez" diyordu ama **yoklama: C işlevi saklayıp sonra çağırınca üst-düzey
  `def` ile ZATEN çalışıyor** (`reg_set(on_event)` sonra `reg_fire(20)` → doğru sonuç). Yani yasak teknik değil belge/koruma eksiği. Gerçek sınırlar:
  (1) `%rt` yalnızca kaydı yapan iş parçacığında/program ömründe geçerli, yabancı OS iş parçacığından çağrı güvenli değil; (2) closure/lambda/bağlı metot
  callback olamaz (trampoline derleme zamanında bilinen bir `def`e bağlı); (3) program çıkışından sonra çağrı tanımsız.
- `@repr("C")` sınıflar yalnızca `ptr` ile geçer; struct değerle geçirme yok.
- Hata sözleşmesi elle sarmalanıyor.

## Aşamalar (her biri ayrı patch sürümü, golden iki backend)

**F1 — Saklanan callback (üst-düzey `def`)**: belge/kural düzeltmesi + korumalar (yabancı iş parçacığı notu, `userdata` ömrü), golden `ffi_stored_callback`.
**F2 — Closure callback**: bkz. "Closure callback tasarımı".
**F3 — `@ffi.errors`**: bkz. "Hata bildirimi".
**F4 — `noxc bindgen`**: C ayrıştırıcı + üretici + kabuk üretimi.
**F5 — yyjson kabul testi + benchmark** (en son): yyjson başlığından binding üret, JSON okuma/yazma/gezinme örnekleri, `nox.json` ile aynı korpus üzerinde ölçüm.

## Closure callback tasarımı (F2)

Sorun: trampoline sabit bir `def`e bağlı; closure'ın ortamı (yakalanan değişkenler) bir ARC nesnesi ve C'nin tuttuğu `userdata` yuvasına sığmalı.

Önerilen yüzey (İlke 1: sahiplik sözdiziminde görünmez; açık `release` bir *kaynak yaşam döngüsü*, ownership anotasyonu değil — `Socket.close()` ile aynı sınıf):

```nox
import nox.ffi
cb: nox.ffi.Callback = nox.ffi.callback(lambda x: x * 2)   # closure'ı pinler (ARC +1), kutu oluşturur
reg_set(cb)                                                 # @ffi.callback parametresine Callback verilebilir
...
cb.release()                                                # kutuyu ve closure'ı bırakır (idempotent; with desteği)
```

- Kutu: `{ rt, closure }` (rt-bağımsız malloc bloğu); `userdata` = kutu işaretçisi. Trampoline imza başına bir kez üretilir ve kutudan `rt`/closure'ı yükleyip closure işlev işaretçisini çağırır. Üst-düzey `def` için mevcut yol aynen sürer.
- `Callback` tutamacı ARC'ye göre kendiliğinden serbest kalmaz (C hâlâ tutuyor olabilir) → `release()` açıktır; program çıkışı sızıntıyı toplar.
- Tip denetimi: `@ffi.callback` parametresine (a) üst-düzey `def` adı, (b) imzası uyan bir `Callback` değeri verilebilir; imza = callback tipinin son `ptr` parametresi HARİÇ kalanı.

Açık sorular: `Callback[F]` jenerik yüzeyi mi yoksa imzasız `Callback` mı (imza uyuşmazlığını çağrı yerinde denetlemek için jenerik tercih edilir); yabancı OS iş parçacığından çağrı (v1: desteklenmez, belgelenir).

## Hata bildirimi (F3)

```nox
@ffi.errors(ok=0, raises=SqliteError, message="sqlite3_errmsg")   # taslak
extern def sqlite3_open(path: str, db: ptr) -> int from "sqlite3"
```

Derleyici çağrı yerinde dönüş değerini denetler: `ok` kümesinde değilse (veya `errno` modunda `-1`/`NULL` + `errno`) `raises` sınıfından istisna fırlatır; mesaj
için isteğe bağlı bir `message` işlevi (ek `extern def`) çağrılır. Dil yüzeyi değişikliği: yeni dekoratör (İlke 1/2 etkilenmez: tip sistemi aynı, yalnızca otomatik
sarmalayıcı). **Ayrıntılar kullanıcıyla netleştirilir** (hata kodunun değer olarak da okunması, `errno` modu, `raises` sınıfının kurucu imzası).

## Struct-by-value (F4'ün parçası)

Derleyiciye dokunulmaz. Üretici, değerle struct alan/döndüren (ve `static inline`) her C işlevi için bir kabuk üretir:

```c
void nox_shim_vec_add(const Vec* a, const Vec* b, Vec* out) { *out = vec_add(*a, *b); }
```

Nox tarafı `@repr("C")` sınıfı iki yerde işaretçiyle geçirir; ham `extern def` yanında kullanıcıya dönen sarmalayıcı (`def vec_add(a: Vec, b: Vec) -> Vec`) üretilir. ABI sınıflandırmasını C derleyicisi yapar. Kabuk `.c` dosyası `cc -c` ile derlenip `from "..."` ile bağlanır (cc zaten linkleme için gerekli).

## `noxc bindgen` (F4)

`noxc bindgen <başlık.h> [-I dir] [-D ad=değer] --lib <ad|yol> --out <dosya.nox> [--shim <dosya.c>] [--config bindgen.json]`

1. `cc -E` ile ön işleme (kullanıcı başlıklarına dokunmadan); `#define` sabitleri ayrı bir geçişte (`cc -E -dM`) toplanır.
2. Küçük C bildirim ayrıştırıcısı (Zig, `compiler/bindgen/`): fonksiyon bildirimi/tanımı, `struct`/`union`/`enum`, `typedef`, işaretçi/dizi/fonksiyon-işaretçisi türleri, bit alanı (atlanır + uyarı), `static inline`.
3. Tür eşleme: `int/long/short/char` aileleri → `i8…i64`/`u8…u64`; `float/double` → `float`; `bool/_Bool` → `bool`; `T*`/`void*` → `ptr`/`ptr[T]`; `const char*` → `str` (girdi); `char*` dönüşü → `ptr` (sahiplik bilinmez, uyarı); enum → `int` sabitleri; fonksiyon işaretçisi → `@ffi.callback` kalıbı (sondaki `void*` userdata bulunursa) aksi halde `ptr` + uyarı; opak `struct X;` → `ptr` tutamacı; tam tanımlı struct → `@repr("C")` sınıf.
4. Desteklenmeyenler (alan atlanır, uyarı): `long double`, `_Complex`, SIMD türleri, bit alanları, çok boyutlu dizi parametreleri, değişken argümanlı (`...`) işlevler (kabuk ile sabit sürümleri yapılandırmadan).
5. C++: yalnızca `extern "C"` yüzeyi; Rust: `cbindgen` çıktısı olan C başlığı. Ad dönüştürme/önek kaldırma ve hata sözleşmesi `bindgen.json` ile (`strip_prefix`, `errors` kuralları → `@ffi.errors` üretir).

## F5 — yyjson doğrulaması

yyjson: tek `.c/.h` çifti, MIT. Başlıkta çok sayıda `static inline` (`yyjson_api_inline`) işlev, `yyjson_read_err` struct'ı (işaretçiyle), `yyjson_alc` (işlev işaretçili struct) var → kabuk üretiminin ve tür eşlemenin gerçek sınavı. Kabul ölçütü: üretilen binding ile bir JSON belgesi okunur, gezilir, değiştirilip yazılır; çıktı `nox.json` ile bit-bit karşılaştırılır. Benchmark: `benchmarks/json_bench.nox`un korpusu + daha büyük (≥ 1 MB) belgeler üzerinde parse / serialize / gezinme, `nox.json`, yyjson (Nox binding üzerinden) ve C'de doğrudan yyjson; sonuçlar `benchmarks/RESULTS.md`ye. Kaynak indirme: kullanıcı onayıyla (kaynak + boyut belirtilir).
