# Native runtime readiness — capability audit (R0–R3)

> Kaynak görev belgesi: `project/native-runtime-readiness-gorev-belgesi-2026-11.md` (Bölüm L formatı).
> Bu belge **readiness** kanıtıdır: "Nox runtime yazmaya HAZIR" ilanının dayanağı. "Runtime Nox ile yazıldı" iddiası DEĞİLDİR (R4+ port kapsam dışı).
> Referans sabitleme: v2.2.63 (`6521fa7d`) üzerine bu çalışma (v2.2.64). Görev belgesinin v2.2.44 bağlantıları tarihseldir; güncel kaynak bu depodur.
> Ortam: macOS arm64 (Apple clang, LLVM backend, `noxc 2.2.64` ReleaseFast). Linux x86-64: CI (bkz. `.github/workflows/ci.yml`, "Dokümanlar" işi). Atlanan/ölçülmeyen her şey "KANITLANMADI" olarak ayrıca yazılmıştır; ortak crash/skip başarı sayılmadı.

## 1. Yöntem ve araçlar (yeniden üretilebilir)

| Araç | Ne kanıtlar | Komut |
|---|---|---|
| `scripts/runtime_leaf_audit.py` | LLVM IR'da kök→yasak sembol zinciri (transitif; doğrudan+dolaylı çağrı, fonksiyon adresi, global başlatıcı), gizli `%rt` durumu, `noxrt.o`'suz link+çalıştırma, son ikilide `nox_*` sızıntısı | `python3 scripts/runtime_leaf_audit.py suite` |
| `tests/native_runtime/leaf/*.nox,*.c` | P01–P06 olumlu + olumsuz (kapı reddi) fixture'ları | (yukarıdaki suite) |
| `scripts/native_runtime_inventory.py` | Zig runtime envanteri (loc/export/atomik/TLS/extern/allocator/OS/comptime/asm) + `@import` DAG/SCC | `python3 scripts/native_runtime_inventory.py [--dag]` |
| `scripts/gen_runtime_abi_manifest.py` | Makine-okunur sembol + layout manifesti, drift denetimi | `python3 scripts/gen_runtime_abi_manifest.py --check` |

Denetim üç katmandadır: (1) IR kaynak-grafı, (2) nesne (`nm`), (3) link+run (`-dead_strip`/`--gc-sections`, `noxrt.o` link satırında YOK; nesne `-ffunction-sections` ile). Hiçbiri tek başına yeterli sayılmaz; "tesadüfen runtime'sız derlenen" programı sözleşme gibi sunmamak için olumsuz fixture'lar kapının gerçekten reddettiğini kanıtlar.

## 2. Capability matrisi (özet)

Durum: **MEVCUT / KISMİ / KANITLANMADI / EKSİK / GEREKLİ DEĞİL**. "Kanıt" sütunu komut/fixture/commit içerir.

| ID | Başlık | Durum | Kanıt |
|---|---|---|---|
| C01 | `int` skaler aritmetik (toplama/çıkarma/çarpma sarar, karşılaştırma, `& \| ^ ~`) leaf'te runtime'sız | MEVCUT | P01 `p01_scalar` (hash `leaf_fnv` C ile bit-eşit) |
| C02 | Sabit literal kaydırma / pozitif literal bölen | MEVCUT | `exceptions.zig:692-694` analizi (literal ⇒ güvenli) |
| C03 | Değişken kaydırma miktarı, `//`, `%` | EKSİK (leaf'te) | `neg_forbidden:neg_div`; `q_shift` probu (ValueError/ZeroDivision yolu) — GAP-3 |
| C04 | Sabit-genişlikli aritmetik + daraltma/genişletme | KISMİ | P04: her dönüşüm `nox_int_overflow_trap(rt,ad)` referansı taşır (genişletme/sabit dahil); tahsissiz fatal sink ile geçer — GAP-2 |
| C05 | `ptr[T]` okuma/yazma/ofset, adres↔int, `lowlevel` dışında yasak | MEVCUT | P02 `p02_rawbuf`, P02b `p02b_mem_stdlib` |
| C06 | `ptr_write_volatile`, `memory_fence`, `compiler_fence` | MEVCUT (LLVM) / QBE KANITLANMADI | P02 `buf_zero`; `llvm_emit.zig:797,806` (`fence seq_cst`, `singlethread`) |
| C07 | `sizeof/alignof/offsetof`, `@repr("C")` | KISMİ | P03: nesne = [8 B ARC başlığı \| alanlar]; başlıksız tanımlayıcı yok — GAP-7 |
| C08 | Ham kayıt: `ptr` sınıf alanı, iç içe kayıt, sabit dizi alanı | EKSİK / KANITLANMADI | `v3/v4` probu: codegen "unsupported"; usize alan çalışır (P03) — GAP-7 |
| C09 | Ham-adres atomikler (load/store/xchg/CAS/fetch_*/fence) | EKSİK (dil), shim ile MEVCUT | P05 (4 iş parçacığı: sayaç, CAS, release/acquire, SB litmus) — GAP-5 |
| C10 | Bellek sıralama sözleşmesi (relaxed…seq_cst, CAS fail kuralı) | KISMİ (shim) | `rtcore_atomic_shim.c`: geçersiz sıra ⇒ fail-stop (sessiz fallback yok) |
| C11 | Thread-local / runtime-yerel durum | EKSİK (dil), sağlayıcı shim ile MEVCUT | P05 `at_tls_roundtrip`; runtime'da 107 `threadlocal` (envanter) — GAP-6 |
| C12 | Platform sağlayıcı (link-zamanı sembol: map/unmap/fatal) | MEVCUT | P06 `rtcore_provider.c`; P04 fatal sink |
| C13 | `extern def` ↔ C ABI çağrısı (gizli `rt` extern'e GEÇMEZ) | MEVCUT | P05/P06 |
| C14 | Nox `def` dışa aktarımı: sembol adı (üst düzey, adlandırılmamış) | MEVCUT | `_leaf_add` (Mach-O) / `leaf_add`; jenerik örnekler `nox_mem_copy__u8` |
| C15 | Nox `def` ABI: hidden `rt` ilk argüman = runtime `rt`-alan export'larıyla aynı | MEVCUT (rt'li export'lar) | `nox_rc_alloc(rt, size)` ↔ `leaf(i64 %rt,…)` |
| C16 | `rt`'siz C-ABI export (tam sembol, rt argümanı YOK) | EKSİK | 1014 export'un 574'ü rt'siz (manifest) — GAP-4 |
| C17 | `noreturn` (derleyici bilir) | EKSİK | tanıtıcı yok; `rtcore_fatal` sonrası `return` gerekir — GAP-9 |
| C18 | C ABI fonksiyon işaretçisi çağrısı | EKSİK | Nox fn işaretçisi `rt` taşır: `call i64 %f(i64 %rt,…)`; kapı "indirect" der — GAP-10 |
| C19 | İstisna yayılımı leaf'te (`raise`, bölme sıfır, çağrı sonrası pending) | EKSİK (tasarım gereği) | `neg_raise/neg_div/neg_helper`; leaf hata modeli = kod/fatal (Bölüm B.4) |
| C20 | Yönetilen tahsis (str/list/dict/sınıf kaçan) leaf'te | EKSİK (tasarım gereği) | `neg_str/neg_list/neg_cls/neg_dict/neg_print` kapıda reddedilir |
| C21 | ASAP ile yığına inen kaçmayan sınıf örneği | "tesadüfen runtime'sız" | `p_cls` probu: sözleşme DEĞİL, optimizasyon sonucu (R0.1'in kanıtı) |
| C22 | Nesne üretimi `--selfhost-obj` | KISMİ | yalnız LLVM+hosted+`--target`'sız; prelude'un tamamı nesneye girer (leaf için ~100 tanımsız `nox_*`); `-dead_strip`/`--gc-sections` ile link edilebilir — GAP-8 |
| C23 | Derleyici içi leaf kapısı (profil/attribute) | EKSİK (bilinçli) | kullanıcı kararı M.1: şimdilik DIŞ denetim aracı; derleyici düzeltmesi yalnız analiz kesinliği (v2.2.64) |
| C24 | Hedef bilgisi (OS/arch/endian/CPU özellik) derleme zamanında | EKSİK | yalnız `sizeof(usize)`; üretilmiş sabit modülü önerisi — GAP-11 |
| C25 | QBE tarafında leaf nesne/denetim | KANITLANMADI | hosted QBE nesne çıktısı yok (`--emit-obj` yalnız mobil); freestanding QBE+Zig runtime — GAP-12 |
| C26 | Assembly bağlama (`swap_*.S`, `boot.S`) | MEVCUT (Zig'den), Nox'tan KANITLANMADI | `runtime/async_rt/swap_*.S`; P11 (fiber bağlam) R6 öncesi spike — GAP-13 |
| C27 | Freestanding/QEMU'da Zig managed runtime'sız Nox çekirdeği (P12) | KANITLANMADI | QEMU mevcut (x86_64/aarch64/riscv64); plan: migration-plan R3b — GAP-12 |
| C28 | Bootstrap allocator (provider, durum makinesi, OOM, debug oracle) | MEVCUT (spike) | P06/P08 `p06_allocator` + `rtcore_provider.c` |
| C29 | İş parçacığı güvenliği / ISR yeniden giriş (allocator) | KANITLANMADI (bilinçli kapsam dışı) | spike tek sahipli; çok-işçili kullanım R5 |
| C30 | DebugAllocator eşdeğeri (ledger, double-free, canary, fault injection) | KISMİ | P06: ledger+double-free+canary+N'inci-map OOM; redzone/leak-trace/stack-trace yok |

## 3. Çalışma sırasında bulunan ve düzeltilen bir kesinlik kusuru (v2.2.64)

**Bulgu (R0.1 / B.2):** `collectRaiseInfoExpr` (`compiler/codegen_qbe/exceptions.zig`) tanınmayan her yerleşik çağrıyı "belki fırlatır" sayıyordu. `ptr_read/ptr_write/ptr_offset/…` bu sınıfa düştüğünden, bunları saran en küçük `def` bile çağıranlarına çağrı-sonrası `nox_exception_pending` + `%rt` sıcak-blok okuması ekletiyordu — runtime-core yardımcılarını (ve genel `nox.mem.copy/move/set`'i) runtime'sız yazmayı imkânsız kılıyordu.

**Değişiklik (kullanıcı onayı, M.1):** ham-bellek yerleşikleri `isRawMemoryBuiltin` listesine alındı: *asla fırlatmaz*, ama bellek etkisi olduğundan `direct_mutates` kalır. Dil/ABI değişmez; çalışan program davranışı aynıdır; yalnız gereksiz denetim kalkar. Kanıt: önce `p06_allocator` kapıdan geçmiyordu (`nox_exception_pending`, `%rt` ihlali), sonra geçti. Tam test: bkz. §7.

## 4. Boşluk kayıtları (Bölüm L formatı — yalnız gerçek boşluklar)

### GAP-2 — Kayıpsız dönüşümler dahil her sabit-genişlik dönüşümü `nox_int_overflow_trap` referansı taşır
- **Durum:** KISMİ. **Kaynak:** `compiler/codegen_qbe` (dönüşüm/`mul` daraltma emisyonu), `u8→int`, `u32(7)`, `int(sizeof(int))` hepsi.
- **Runtime'daki yer:** allocator/ARC/scheduler algoritmaları `u32/u64` alanları yoğun kullanır (RC bayrakları, hash).
- **Minimal reproducer:** `def n_widen(a: u8) -> int: return int(a)` → `audit` sonucu `checked-arith-trap` (`probe5`, R0 günlüğü; fixture: P04).
- **Mevcut dille çözüm:** leaf `int` (64-bit sarar) ile yazılır; sabit-genişlik gerekirse `nox_int_overflow_trap(rt, ad)` açıkça onaylı, tahsissiz bir fatal sink sağlayıcısına bağlanır (P04: `write(2)+_exit(70)`; taşma yolu çocuk süreçte kanıtlı).
- **Kalan eksiklik:** kayıpsız genişletmede ölü dal bile referans üretir (kod boyutu + bağımlılık); açık sarmalı (wrapping) aritmetik ilkelleri yok.
- **Önerilen minimal değişiklik:** (a) kayıpsız dönüşümlerde denetimi hiç üretme (davranış-koruyucu); (b) runtime-core için açık `wrapping_*` iç ilkelleri. **Public değişim:** (a) yok, (b) internal. **Onay:** (a) golden IR güncellemesi içerdiğinden ayrı onay; (b) M.1 tasarımı.
- **LLVM/QBE:** her ikisinde dönüşüm yolu; **Hedef:** hepsi. **ABI:** yok. **Risk:** sink yeniden giriş/tahsis yapmamalı (P04'te yapmıyor).
- **Kapanış:** açık; sonraki adım R4 öncesi onaylı küçük codegen değişikliği.

### GAP-3 — Değişken kaydırma miktarı ve `//`, `%` istisna yolu taşır
- **Durum:** EKSİK (leaf'te). Literal kaydırma/pozitif literal bölen güvenlidir (`exceptions.zig:692-694`).
- **Reproducer:** `neg_div`: `a // b`; `q_shift` probu. **Mevcut çözüm:** literal kaydırma, çarpma/maske, çıkarmalı algoritmalar (P01 `leaf_gcd`).
- **Öneri:** runtime-core için maskeli, istisnasız iç `shl/shr/udiv/urem`. **Public:** yok (internal). **Onay:** M.1 tasarımıyla birlikte.
- **Kapanış:** açık.

### GAP-4 — `rt`'siz C-ABI export edilemiyor (1014 export'un 574'ü rt'siz)
- **Durum:** EKSİK. Nox `def` HER ZAMAN gizli `rt` ilk argümanını alır (`define i64 @leaf_add(i64 %rt, …)`). Bu, `rt` alan export'larla (440 / 1014) bire bir uyumludur (`nox_rc_alloc(rt, size)`), fakat stdlib shim'lerinin (414 rt'siz) ve `lib_freestanding`/`nox_atomic_*` gibi API'lerin çoğu rt almaz.
- **Reproducer:** manifest: `python3 scripts/gen_runtime_abi_manifest.py --summary`.
- **Mevcut çözüm:** C/asm ince sarmalayıcı (`rt` düşüren thunk); geçiş ara çözümü.
- **Öneri:** internal `export` niteliği (`@export("sym", rt=False)` benzeri; public sözdizimi DEĞİL) veya derleyicinin rt'siz imza üretmesi. **Onay:** gerekli (ABI/dil yüzeyi) — R4 öncesi.
- **ABI:** private; fingerprint (bkz. `native-runtime-abi.md`). **Kapanış:** açık.

### GAP-5 — Ham-adres atomik ilkelleri (kullanıcı kararı: PUBLIC sistem programlama API'si)
- **Durum:** EKSİK (dil), shim ile MEVCUT. Derleyici yalnız ARC için `atomicrmw add/sub imm acq_rel` (`llvm_emit.zig:571-588`) ve `fence` (797/806) üretir.
- **Runtime kullanımı (envanter):** 482 atomik site; işlemler load/store/add/sub/and/or/xor/xchg/CAS(strong+weak) ve fence; sıralamalar monotonic/acquire/release/acq_rel/seq_cst; genişlikler `bool/u8/u32/u64/usize/i64/i32`.
- **Kanıt:** P05 (4 iş parçacığı: 2.000.000 relaxed fetch_add, 400.000 CAS artışı, 200.000 release/acquire mesajı, 100.000 store-buffering litmus'ta yasak sonuç 0, TLS izolasyonu). **Statistik** kanıt; biçimsel ispat DEĞİL.
- **Karar (M.3):** kalıcı yol public API. **Bu çalışmada UYGULANMADI:** dil/API yüzeyi tasarımı `project/native-runtime-abi.md` §6'da ÖNERİ olarak; uygulama ayrı iş (spesifikasyon + her iki backend + litmus CI).
- **Geçici bağımlılık:** `tests/native_runtime/shim/rtcore_atomic_shim.c` (manifestte "geçici"). **Kapanış:** açık (tasarım onayı + uygulama).

### GAP-6 — TLS / runtime-yerel durum ilkeli yok
- **Durum:** EKSİK (dil); sağlayıcı ile MEVCUT. Runtime 107 `threadlocal` site (`asap.zig:782 g_worker_slot` en kritik).
- **Kanıt:** P05 `rtcore_tls_get/set` (`_Thread_local`), izolasyon testi. **Öneri:** `RuntimeState*` açık parametre + platform TLS sağlayıcı sözleşmesi (`rtcore_tls_*`); public `threadlocal` anahtar sözcüğü GEREKLİ DEĞİL. WASM threads/Windows/freestanding tek çekirdek ayrı kayıt (dependencies belgesi).
- **Kapanış:** açık (sağlayıcı sözleşmesi R6'da).

### GAP-7 — Ham kayıt depolaması
- **Durum:** KISMİ. **Bulgular:** (1) `ptr`/`ptr[T]` sınıf alanı codegen'de desteklenmiyor (`v3/v4` probu), `usize` alan çalışır; (2) `@repr("C")` nesne 8 B ARC başlığı yuvası içerir (`offsetof(rc)=8`), başlıksız kayıt (RuntimeState öneki, ARC başlığının kendisi) ifade edilemez; (3) iç içe satır-içi kayıt/sabit dizi alanı KANITLANMADI.
- **Kanıt:** P03 (Nox `sizeof/alignof/offsetof` == C struct, bayt deseni, komşu alan taşması yok).
- **Karar (M.2):** "internal başlıksız `@raw` layout önerisi hazırla" → `project/native-runtime-abi.md` §7. Public `struct/union/value` anahtar sözcüğü EKLENMEZ.
- **Kapanış:** açık (öneri onayı).

### GAP-8 — Nesne üretim kipi runtime nesnesi için yetersiz
- **Durum:** KISMİ. `--selfhost-obj`: `main`siz LLVM nesnesi, ama prelude/core'un tamamı nesneye girer (leaf `.o`'da ~100 tanımsız `nox_*`; `-dead_strip`/`--gc-sections` olmadan link edilemez), hosted + `--target`'sız (`compiler/main.zig:4081`), entry/`nox_lib_init` zinciri sabit.
- **Öneri (Bölüm E.2):** mevcut kipi genişlet: prelude'suz "leaf-only" emisyon + `--target` + QBE; ikinci derleyici YAZMA. **Onay:** gerekli (driver yüzeyi). **Kapanış:** açık.

### GAP-9 — `noreturn` yok
`rtcore_fatal` dönüşü derleyici için bilinmez; fatal sonrası sahte `return` gerekir (P06). **Öneri:** internal niteliğe bağlı; R4 öncesi. **Kapanış:** açık.

### GAP-10 — C ABI fonksiyon işaretçisi çağrısı yok
Nox işaretçisi `rt` taşır; C işaretçisi taşımaz; `@ffi.callback` trampolini yalnız FFI sınırı içindir. Kapı "indirect" der. **Karar yolu:** runtime-core'da fonksiyon işaretçisi yerine LINK-ZAMANI sembol sağlayıcı (P06 deseni). Tablo gereken yerler (dispatch registry) için ayrı capability. **Kapanış:** açık (R5, dispatch).

### GAP-11 — Derleme zamanı hedef bilgisi
Yalnız `sizeof(usize)`; OS/arch/endian/CPU özelliği yok. **Öneri:** `scripts/gen_*` ile üretilmiş sabit modülü (build-time) — Zig `comptime` taşımaya GEREK YOK. **Kapanış:** açık (R2b).

### GAP-12 / GAP-13 — QBE/freestanding leaf ve fiber bağlamı (KANITLANMADI)
Hosted QBE nesne çıktısı yok; freestanding profil QBE + Zig managed runtime ile gelir; QEMU (3 mimari) elde var. Planlı spike'lar `native-runtime-migration-plan.md` R3b/R6 öncesi. Skip/başarısız ayrımı: bu turda **koşulmadı**, başarı sayılmadı.

## 5. R1–R3 kapıları — sonuç

| Kapı | Kanıt | Sonuç |
|---|---|---|
| R1: yasak bağımlılık kaynak/IR/nesne seviyesinde yok, `noxrt.o`/allocator gerekmez | suite (8 fixture) + son ikilide sızıntı taraması | GEÇTİ (macOS arm64 LLVM) |
| R1 olumsuz: managed alloc/gizli helper/indirect reddedilir | `neg_forbidden` 9 kök, 7 sınıf | GEÇTİ |
| R2: ham allocator/RC başlığı/kayıt temsil edilebilir, atomik sözleşme | P03/P05 | GEÇTİ (atomik: geçici shim; GAP-5/7 açık) |
| R3: cycle'sız bootstrap allocator, allocation-free fatal/OOM, kısmi init/fini | P06/P08 | GEÇTİ |

## 6. Performans ve güvenlik notları

Ölçümler `project/native-runtime-performance.md`'de. Güvenlik stratejisi (Debug oracle, fault injection) `native-runtime-architecture.md` §5'te.

## 7. Doğrulama kaydı (v2.2.64)

- `NOX_TEST_FAST=1 zig build test -Dtrace-frames=0 --summary all` (çıkış kodu 0): `Build Summary: 875/875 steps succeeded; 2351/2367 tests passed (16 skipped)`; 15 kasıtlı IR anlık görüntüsü yeniden üretildi (`pending` denetimi 1719→1682).
- `python3 scripts/runtime_leaf_audit.py suite`: `VERDICT: GREEN (8 fixture, 0 sapma)`.
- `scripts/precheck.sh`: sonuç CHANGELOG girişinde. Linux x86-64: CI koşusu (commit sonrası `gh run list --workflow=ci.yml`).
