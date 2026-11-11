# Nox'tan WASM modülü içe aktarma — kapsam denetimi (2026-11-11)

Soru: `.wasm` modüllerini Nox'a kütüphane gibi içe aktarma (AGENTS.md İlke 5 / §11: "gömülü WASM yorumlayıcısı") ne kadar kapsıyor ve tam kapsama için ne gerekir?

> Bu, **WASM'a derleme** (`--target wasm32-wasi/freestanding`; tam çalışıyor, bkz. `docs/tools/wasm.md`) ile **WASM içe aktarma** arasındaki ayrımdır. Burada yalnızca ikincisi ele alınıyor.

## Mevcut durum (koddan okundu)

Yüzey: tek yerleşik, `wasm_call(yol: str, işlev: str, argüman: int) -> int` (checker 9214, codegen `calls.zig`, çalışma zamanı `foreign_bridge.zig:nox_wasm_call`). Örnek fixture: `tests/compat/wasm_ext/addone.wasm`.

| Alan | Durum |
|---|---|
| Modül çözümleme (`module.zig`) | Yalnızca **Type, Function, Export, Code**; **Import, Table, Memory, Global, Start, Element, Data** bölümleri **atlanır** (anlaşılmaz) |
| Değer tipleri | `ValType` dört tipi tanımlı ama yorumlayıcı **yalnızca `i32`** parametre/dönüş destekler |
| Kontrol akışı | `block`, `loop`, `if/else`, `br`, `br_if`, `return`, `call`, `drop`, `select`, `unreachable`, `nop` **var** (yorumlayıcı başlık yorumu bayat: "dallanmasız" diyor, kod destekliyor). **Yok:** `br_table`, `call_indirect` |
| Sayısal | `i32`: `const`, `add/sub/mul`, `div/rem` (s/u), `and/or/xor`, `shl/shr_s/shr_u`, `eqz` + 10 karşılaştırma. **Yok:** `clz/ctz/popcnt/rotl/rotr`; **`i64`, `f32`, `f64` işlemlerinin hiçbiri**; dönüşümler |
| Bellek | **Yok** (yükleme/depolama/`memory.size/grow`, veri parçaları, doğrusal bellek) |
| Global/Tablo/Start | **Yok** |
| İçe aktarmalar (host işlevleri, WASI) | **Yok** (modül içe aktarma isterse yüklenemez) |
| Dışa aktarılan çağrı | Tek işlev adı + **tek `i32` argüman**; çağrı başına modül yeniden çözümlenir, **kalıcı örnek (instance) yok** |
| Dize/tampon geçişi | **Yok** (bellek olmadığından) |
| Çok değerli dönüş, bulk-memory, reference types, SIMD, threads, exceptions, GC, component model | **Yok** |

Sonuç: bugünkü bridge, `(i32)->i32` türünden saf hesap işlevleri için bir kavram kanıtıdır. Gerçek bir `.wasm` (Rust/Zig/C derlemesi) çalıştırmak için **yetersizdir**: böyle bir modül neredeyse her zaman bellek, global ve `i64`/`f64` kullanır.

Ek bulgu (temizlik): `interp.zig` ve `module.zig` başlık yorumları bayat ("dallanmasız", "import yok"); davranışla uyumlu değil.

## Seçenekler

| Seçenek | Artı | Eksi |
|---|---|---|
| **A. Mevcut Zig yorumlayıcısını MVP'ye tamamlamak** | Sıfır yeni bağımlılık; saf Zig (AGENTS §6); iOS/Android'de çalışır (JIT yok); opak handle ilkesi (İlke 4) ve sandbox üzerinde tam denetim | En çok kod (tahmin: ~3-5 K satır); hızı bir `switch` yorumlayıcısı kadar (JIT'ten ~20-50x yavaş); doğruluk için kapsamlı test şart |
| B. `wasm3` (C, MIT) vendor'lamak | Hızlı bir yorumlayıcı, MVP'yi geçiyor, küçük | Bakımı yavaş; C bağımlılığı; WASI sınırlı; Nox'un tip/handle sözleşmesine bir sarmalayıcı gerekir |
| C. Zig-yerel kütüphane (`zware`/`bytebox`) vendor'lamak | Saf Zig | Zig 0.16 uyumu ve spec kapsamı **doğrulanmadı**; bakım riski |
| D. `wasmtime` C API | Hızlı (JIT), WASI/Component | Büyük ikili ve derleme süresi; **iOS JIT yasak**, Android kısıtlı; AGENTS "gömülü" amacına ağır; çapraz hedef sayısı yüksek |

**Öneri: A.** Gerekçe: bağımlılıksız, mobil hedefleri (JIT'siz) kapsar, sandbox ve handle ilkelerini tam kontrol eder; doğruluk güvencesi için **Node'un yerleşik `WebAssembly` motoruna karşı farksal test** (CI'de zaten Node var) ve bir spec-testsuite alt kümesi kullanılabilir. Hız gerekirse sonra B/D ile değiştirilebilir (`/runtime/wasm_bridge` izole, AGENTS §11).

## Önerilen fazlar (A seçilirse)

1. **W1 — çekirdek:** tam ikili çözümleme ve doğrulama; `i32/i64/f32/f64` tüm sayısal işlemler ve dönüşümler; `br_table`; bellek (`load/store`, `size/grow`); global; tablo + `call_indirect`; veri/eleman parçaları; `start`; çok değerli dönüş; tuzaklar (trap) için doğru anlam. Farksal test: Node `WebAssembly` ile aynı modüller, aynı sonuçlar.
2. **W2 — Nox yüzeyi (dil/ABI kararı):** `hpy_open/hpy_call_on` ailesiyle uyumlu **kalıcı örnek tutamacı**: `wasm_open(yol) -> handle`, `wasm_call_on(h, ad, args…)` (`int/float` ve çoklu argüman), bellek okuma/yazma (`str`/bayt kopyası), `close`. Sahiplik yine görünmez (İlke 1).
3. **W3 — host işlevleri:** modülün içe aktarmalarını Nox üst düzey işlevleriyle bağlamak (mevcut `@ffi.callback` kalıbıyla), ve yetenek tabanlı (capability) bir WASI preview1 alt kümesi (`fd_write`, `args`, `clock`, `random`) — varsayılan **kapalı**.
4. **W4 — uzantılar:** bulk-memory, sign-extension, reference types; SIMD ve threads ayrı karar; çökme/DoS dayanıklılığı (`fuel`/yığın sınırı, bellek tavanı) ve fuzz.

## Kullanıcıdan gereken kararlar

- Seçenek A (önerilen) mi, B/C/D mi?
- W2'nin dil yüzeyi (yeni yerleşikler) — AGENTS §16 gereği yeni dil özelliği; onayınla uygulanır.
- WASI kapsamı ve varsayılan yetenek politikası.

## Yeniden ölçüm / doğrulama

Bugünkü sınırı görmek için: `tests/golden/codegen_cases/wasm_call_builtin.nox` (tek `i32`); `runtime/wasm_bridge/interp.zig` opcode kolları. Tam kapsam hedefi için ölçü: W1 sonunda Node `WebAssembly` ile farksal uyum oranı ve spec-testsuite alt kümesi geçme sayısı.
