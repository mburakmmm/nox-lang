# ADR-012 WASM derleme hedefi

Durum: kabul. Nox kodu `--target wasm32-wasi` ile LLVM üzerinden WebAssembly'ye derlenir.

## Karar

- WASM bir **derleme hedefidir**, ikinci bir arka uç değildir. Yol: aynı tiplenmiş IR → `.ll` → `zig cc -target wasm32-wasi` (wasi-libc + `noxrt-wasm32-wasi.o`) → `.wasm`. QBE'ye WASM arka ucu eklenmez (AGENTS İlke #5); `--backend qbe`, `--emit-asm` ve `-g` bu hedefte hatadır.
- Hedef `wasm32`'dir, `wasm64` değildir. Nox'un derlenmiş kodu her yerde 64-bit sözcük kullanır (işaretçiler dahil); wasm32'de işaretçi 4 bayttır. İkisi şöyle bağdaşır:
  - **Çağrı noktası uyarlaması.** `scripts/gen_wasm_abi.py` runtime'ın `export fn` imzalarını tarar ve `compiler/codegen_qbe/wasm_abi_table.zig` tablosunu yazar (`--check` CI'da güncelliği doğrular). `llvm_emit.zig` bir `$sembol` çağrısında tablodaki gerçek imzayı bildirir: işaretçi/`usize`/32-bit argümanlar `trunc i64→i32`, sonuçlar `zext`. libc için (`printf`, `strcmp`) küçük bir elle tablo vardır; `printf` her çağrıda variadic imzayla yazılır.
  - **Geri çağrı tipleri.** Derlenmiş kodun adresini runtime'a verdiği yerlerde (`$Sınıf_release`, dispatch tabloları, kapanış başlıkları, görev girişleri) fonksiyon işaretçisinin imzası derlenmiş fonksiyonunkidir (işaretçi = `i64`). Runtime bu tiplerde `abi_ptr.Arg` (`wasm32`'de `u64`) kullanır.
  - **Sekiz baytlık yuvalar.** Nesne alanları, liste elemanları, iz arabelleği çocukları ve global yuvalar her zaman 8 bayttır (`FIELD_SLOT_SIZE`); runtime bunları `abi_ptr.Slot` ile okur/yazar.
  - **Statik veri.** `ptrtoint ... to i64` wasm32'de statik ilklendiricide desteklenmez; vtable ve metadata sabitleri `{ i32 adres, i32 0 }` çiftleri olarak yazılır.
- ARC düz (atomik olmayan) yükle-topla-sakla ile çalışır: wasm32-wasi tek iş parçacıklıdır. M:N havuzu, `nox.thread` OS iş parçacıkları ve fiber yığın değiştirme yoktur.
- Asenkron (`spawn`/`await`/`Channel`) `runtime/async_rt/bridge_wasm.zig`deki **iç içe çalıştırma benzetimiyle** çalışır: bir görev, onu bekleyen görevin yığınında sonuna kadar çalışır. Bir görev, yığında kendi altında bloke olan bir görevin sonucunu bekliyorsa ilerleyemez ve "deadlock" bildirilir. Sıra FIFO'dur ve deterministiktir.
- Runtime dar bir kümedir (`runtime/lib_wasm.zig`): asap/arc/döngü çözücü/errors/str/format/dict/list, ve stdlib kabuklarından strings, math, os, path, time, random, json, unicode, atomic, io, fs, crypto, regex, gzip. Soket, süreç, `dlopen`, paylaşılan bellek, HPy/WASM köprüleri ve OpenSSL yoktur.
- Olmayan modüller (`nox.http`, `transfer`, `reflect`, `router`, `tls`, `websocket`, `smtp`, `sqlite`, `postgres`, `mysql`, `process`, `sharedmem`, `native`, `plugin`, `hpy`) ve `hpy_*`/`wasm_call` yerleşikleri **derleme zamanında** açık bir iletiyle reddedilir (`Checker.wasm_target`); bağlayıcı hatası kullanıcıya sızmaz.
- Değişmez ilkeler aynen geçerlidir: ownership sözdizimi eklenmedi, `lowlevel` dinamik tip kaçışı değildir, unwind tablosu / landing pad üretilmez (hata yayılımı örtük error-union zinciri), C eklentilerine ham işaretçi verilmez, gizli global durum yoktur. Gömülü WASM yorumlayıcısı (`wasm_call`, bir WASM modülünü Nox'a içe aktarma) ayrı bir mekanizmadır ve bu hedefte yoktur.

## Doğrulama

`zig build test` içinde `tests/golden/wasm_target_test.zig` (duman kümesi), opt-in `zig build wasm-corpus-test` ile tüm `codegen_cases/` korpusu (`node` + WASI). Korpusta üç bilinçli fark: `thread_spawn_ordering` (gerçek iş parçacığı yok), `task_local_basic` (zamanlayıcı sırası), `mathx_trig_log_constants` (musl `exp(1.0)` 1 ULP).

## Bilinen sınırlar

- Transandantal matematikte (`exp`, `sin`, ...) sonuçlar wasi-libc/musl'e aittir ve platform libm'den son basamakta ayrılabilir.
- Kullanıcı `extern def` ile native kütüphane bağlayamaz; wasm32 ABI tablosunda olmayan bir sembol çağrısı 64-bit işaretçi tipleriyle kalır.
- Nox'un çekirdeğindeki `round` fonksiyonu, wasi-libc/compiler_rt'nin `round` sembolüyle aynı ada sahiptir; bağlayıcı bir imza uyarısı verir (çağrılar Nox tarafına çözülür, runtime `@round`u kendi içinde çözer).

Geri alma: `qbe_target.hostedTargetInfo`daki `wasm32-wasi` kaydını ve `build.zig`deki `wasm-rt` adımını silmek.
