# Yapılacaklar listesi (2026-11-11'den)

Tek takip noktası: 2026-11-11 oturumundaki analizlerden çıkan ve konuşulan **tüm işler**. Her iş bittikçe işaretlenir ve sürümü yazılır. Durum: `[ ]` açık, `[x]` bitti (sürümle), `[~]` karar/onay bekliyor, `[-]` yapılmayacak/bayat.
Kaynak raporlar: `project/freestanding-kapsam-analizi-2026-11.md`, `project/stdlib-performans-analizi-2026-11.md`, `project/ffi-performans-analizi-2026-11.md`, `project/wasm-import-kapsam-analizi-2026-11.md`.

**Kullanıcı kararları (2026-11-12): 3. bölümden sonra 3.5 (dil performans analizi + agresif ama semantik değiştirmeyen optimizasyonlar), 4. bölümden sonra 4.5 (ARC/ASAP analizi + stres testleri) eklendi; sıra 1 → 2 → 3 → 3.5 → 4 → 4.5.** **Kullanıcı kararları (2026-11-11):** WASM için seçenek A (kendi Zig yorumlayıcısını MVP'ye tamamla) onaylandı · kusurlar önerilen sırayla düzeltilecek (`%llu` → liste bozulması → `base64`/`upper-lower` Zig'e) · ~~gzip için yeni bağımlılık YOK~~ (2026-11-11 sonradan geri alındı: libdeflate eklendi, v2.1.63) · bu liste takip aracıdır.

## 0. Tamamlananlar (analiz turu)

- [x] **0.1** `noxc upgrade` downgrade (releases listesinden en yüksek semver; install.sh/ps1; site kaynağı) — **v2.1.47**
- [x] **0.2** CI: wasm `nox.http` stub'ı, Windows sürücü yol kaçışı — **v2.1.47**; Linux gzip testi (gerçek fiber), `grpc_server` belge kapsamı — **v2.1.49**
- [x] **0.3** Freestanding kapsam analizi (araç + rapor) — **v2.1.48**
- [x] **0.4** Stdlib performans analizi (araç + rapor) — **v2.1.50**
- [x] **0.5** FFI performans analizi (araç + rapor) — **v2.1.51**
- [x] **0.6** WASM içe aktarma kapsam denetimi (rapor) — **v2.1.52**
- [x] **0.7** `nox-lang` gRPC sunucusu üst veri/süre/trailer/gzip (v2.1.44), `nox.redis` wasm'da (v2.1.45), tarayıcı WebSocket-TCP köprüsü (v2.1.46)

## 1. Freestanding kusurları (rapor: freestanding-kapsam-analizi)

- [x] **1.1 F1** `printf` yorumlayıcısına `%llu` (unsigned yazdırma; 16 fixture) — **v2.1.53**
- [x] **1.2 F2** Liste 128 elemanı aşınca bozuluyordu — **KAPANDI v2.1.54**: kök neden `kernelAlloc` (4096 bayt sınırı, `free` yok) + denetlenmeyen `null`; boyut-sınıflı heap + OOM'da net hata
- [x] **1.3 F3** `Set/OrderedDict/Counter` ~1000 elemanda `IndexError` — **KAPANDI v2.1.54** (aynı kök neden)
- [x] **1.4 F4** `pinned_string_passthrough`, `str_append_in_place` — **KAPANDI v2.1.54** (aynı kök neden)
- [x] **1.5 F5** Biçim belirteçli f-string / `str.format` çökmesi — **KAPANDI v2.1.55**: kök neden 64 KiB boot yığını; 1 MiB
- [x] **1.6 F6** `dict[float, …]` değer listesinde #GP — **KAPANDI v2.1.54** (aynı kök neden)
- [x] **1.7 F7** `async_task_churn_long` #UD — **KAPANDI v2.1.54** (aynı kök neden)
- [x] **1.8 F8** `exp(1.0)` 1 ULP farkı — kullanıcı kararı: doğru yuvarlamalı exp; **v2.1.59** (f128, 632 referansla bit-bit)
- [x] **1.9** `strings`, `json`, `regex`, `base64`, `path`, `random` kabuklarını freestanding köküne bağla (`scratchAllocator`, `TlsSlot`) + `docs/tools/freestanding.md` — **v2.1.57** (PASS 345 → 396, LINK 76 → 13)
- [x] **1.9b** `nox.gzip`/`nox.bytes` freestanding'de (statik 768 KiB yığınlı mini-fiber) — **v2.1.58**
- [x] **1.9c** `nox.crypto` freestanding'de (özetler; argon2/scrypt/hash'ler çıplak çekirdekte desteklenmez) — **v2.1.58**
- [x] **1.9d** `nox.os` freestanding'de (bellek içi ortam, `arg(0)`="nox", `exit` = durdur) — **v2.1.58**
- [x] **1.10** QEMU'da fatal hatada `isa-debug-exit` ile çıkış kodu 35 — **v2.1.59**
- [~] **1.11** aarch64 / riscv64 için QEMU boot zinciri — kullanıcı kararı: şimdilik yapılmayacak, 2-3-4. bölümlerden sonra yeniden sorulacak
- [x] **1.12** Yeniden ölçüm tamam (v2.1.58): **PASS 423/525** (başlangıç 323); DIFF 20→1 (yalnız F8), LINK 76→1 (yalnız `wasm_call`, freestanding'de yok = beklenen), HALT 3→0, FAULT 2→0. Kalanlar tasarım gereği: CAP 69, negatif fixture 17, HALT-OK 12 (işlenmemiş istisna makineyi durdurur), NOEXP 2

## 2. Stdlib performans (rapor: stdlib-performans-analizi)

- [x] **2.1** `nox.base64` encode/decode → Zig kabuğu (26x/36x yavaştı; artık 1.0x/2.0x) — **v2.1.56**
- [x] **2.2** `strings.upper/lower` ASCII SIMD yolu — **v2.1.56** (kalan maliyet büyük tahsis: 2.9)
- [x] **2.3** `csv.parse` Zig'e (24.8 → 6.1 ms, 0.34x) — **v2.1.61**; `strings.replace` 1.35x: iki geçişli tarama sınırlı, kabul edildi (CPython tek geçiş memchr)
- [x] **2.4** `json` parse 34.2 → 16.9 ms (0.91x), dump 27.2 → 18.3 ms (1.14x) — doğrudan düğüm ayrıştırıcı + Zig dump — **v2.1.61**
- [x] **2.5** `regex` find_all 1.72 → 1.32x, replace 1.54 → 1.15x (ASCII bitmap + ilk-bayt ön süzgeci) — **v2.1.61**
- [x] **2.6** `gzip` libdeflate ile (kullanıcı kararı 2026-11-11: gerekirse bağımlılık) — sıkıştırma ≈16.5 → 2.6 ms (0.39x), açma 0.9 ms (0.98x) — **v2.1.63**; Windows/wasm/mobil/çıplak çekirdek Zig flate'te
- [x] **2.7** Eksik modül adayları: kullanıcı seçimi (2026-11-11): bigint+decimal/fraction, argparse, tempfile+glob/fnmatch, zip/tar/zstd+md5/sha3/blake3 (aşağıda 2.10-2.13); `XML/HTML`, `Mutex/Semaphore`, `.env/ini` istenmedi
- [x] **2.10** `nox.bigint` (**v2.1.66**, Zig std.math.big + Python `int` ile birebir golden) + `nox.decimal`/`nox.fraction` (**v2.1.67**, saf Nox)
- [x] **2.11** `nox.argparse` (komut satırı ayrıştırıcı) — **v2.1.68** (Python `argparse` ile 140 rastgele argv'de birebir)
- [x] **2.12** `nox.tempfile` + `nox.glob`/`fnmatch` — **v2.1.69** (Python `fnmatch`/`glob` ile birebir golden)
- [x] **2.13** `md5`/`sha384`/`sha3`/`blake3` (**v2.1.70**), `tar` + `zstd` açma (**v2.1.71**), `zip` (**v2.1.72**): hepsi Python referanslarıyla birebir golden; zstd sıkıştırma Zig std'de yok (yalnız açma)
- [x] **2.9** Büyük tahsis maliyeti: tam-eşit-boyutlu büyük blok önbelleği + SIMD ASCII taraması — **v2.1.60** (1 MB concat+len 0.36 → 0.10 ms; upper/lower/trim 55 → 5.4 ms)
- [x] **2.8** Yeniden ölçüm (v2.1.61): geometrik ortalama **0.68**; ≤ 1.5x hedefi: gzip 2.5x/2.2x (bağımlılık yok kararı) ve base64.decode 2.0x dışında sağlandı. (base64.decode SIMD tek geçişe alındı: 2.6 → 1.2 ms, 0.91x — v2.1.63; yeniden ölçüm geometrik ortalama 0.58)

## 3. FFI (rapor: ffi-performans-analizi)

- [x] **3.1** `lowlevel` içinde `ptr_of(liste)` sıfır-kopya veri işaretçisi — **v2.1.62** (0.36 → 0.08 ns/eleman; `Buffer` için `ptr_of(buf.data)` alan erişimiyle)
- [-] **3.2** QBE'de `lowlevel` `ptr_read/ptr_write` döngüsü (0.58 vs 0.36 ns/eleman, toplam 2.4x): QBE'nin optimizasyonsuz çıktısı; varsayılan LLVM'de sorun yok, QBE için ayrı iş yok (backend eşitliği hedefi madde 5.3'te ele alınır)
- [x] **3.3** Callback: yeniden ölçüm 1.9 ns (C'nin 2.5x'i; ilk ölçüm 5 ns idi) — ek profil gerekmez, yeterli
- [ ] **3.4** Struct-by-value ve saklanan (kayıtlı) callback tasarımı — madde 5.1 ile birlikte

## 3.5 Dil performans analizi ve agresif (semantik korumalı) optimizasyonlar (kullanıcı isteği 2026-11-12)

İlke: **dilin yüzeyi ve anlamı DEĞİŞMEZ** (yeni sözdizimi yok, gözlemlenebilir davranış aynı, hata/istisna sırası aynı, taşma/NaN/sıralama anlamı aynı); yalnızca daha hızlı kod/çalışma zamanı. AGENTS §2 değişmez ilkeleri geçerlidir (ownership görünmez, unwind tablosu yok...). Her optimizasyon için: iki backend (LLVM varsayılan + QBE) golden/fark testi, önce-sonra çıktı eşitliği, ölçülmüş kazanç; kazanç ölçülmezse geri alınır.

- [x] **3.5.1** (**v2.1.73**: `benchmarks/lang_perf/` — 19 çekirdek, Nox LLVM/QBE vs C -O2 vs CPython 3.15, sağlama doğrulamalı `run.py`; rapor `project/dil-performans-analizi-2026-11.md`; tur 1: llvm/c ~1.9x, en uzaklar func_value_calls 9x, dict_int 7x, str_index_loop 6.5x, list_append 4.4x) Ölçüm altyapısı: dil çekirdeği için kapsamlı, yeniden üretilebilir benchmark paketi — sayısal döngüler (int/float), çağrı maliyeti, sınıf/metot/vtable, generic/monomorphization, closure/yüksek-dereceli işlev, `str` işlemleri (birleştirme, dilimleme, f-string, `find/replace`), `list/dict/set` (ekleme, indeksleme, yineleme, silme), jeneratör, istisna yolu, `spawn/Task/Channel`, `nox.json`/`regex`/`csv` karşılaştırmaları; referanslar: CPython 3.15, C (`-O2`), Go/Rust mümkünse. Çıktı: `benchmarks/lang_perf/` + çalıştırıcı + `project/dil-performans-analizi-2026-11.md`
- [x] **3.5.2** (**v2.1.75**: rapor `project/dil-performans-analizi-2026-11.md` — 7 bulgu, sıralı fırsat listesi: pinned-dize atomik release, yakalamasız işlev değeri tahsisi, liste büyütmesi, sözlük 3 arama, istisna denetimi, sınır denetimi) Profil ve darboğaz analizi: sıcak yolların örneklemeli profili (`sample`/`perf`), LLVM vs QBE üretilen kod kalitesi farkı, runtime çağrı yoğunluğu (tahsis, retain/release, sınır denetimi, dize kopyası), kaçınılabilir kopyalar; sonuç sıralı bir fırsat listesi (kazanç × risk)
- [~] **3.5.3** (tur 2 **v2.1.80/81/82** (82: LLVM TBAA liste uzunluk/eleman; liste büyütme realloc denendi, uygulanmadı): satır içi istisna denetimi (sıcak blok) v2.1.81'de yapıldı; `s[i]=="c"` birleştirmesi yapıldı, sözlük satır içi anahtar denendi/reddedildi; sıradaki: tek hedefli işlev değeri → doğrudan çağrı, satır içi istisna denetimi [RuntimeState ABI kararı gerekir], sınır denetimi/TBAA [sieve bellek-bağımlı, kazanç düşük], QBE satır içi açma; tur 1 **v2.1.76**; analiz düzeltmeleri raporda: sözlükte last_idx zaten var, istisna denetimi doğrudan çağrılarda zaten kalkıyor, liste büyütme sözleşmesi → 4.5: fırsat #1 pinned-dize release + satır içi literal karşılaştırma, #2 statik işlev-değeri kapanışı; kalan: #3 liste büyütme, #4 sözlük, #5 istisna denetimi, #6 sınır denetimi) Uygulama turu (ölçüm sırasına göre): ör. sınır denetimi eleme, küçük işlevlerin ve runtime ilkellerinin satır içi açılması / bitcode ile bağ-zamanı optimizasyonu (LTO), `noalias/readonly/nounwind/nonnull` LLVM öznitelikleri, `list[int]/list[float]` ve `dict[str,*]` özel yolları, dize özet önbelleği, sabit katlama / döngü-değişmezi taşıma, `str +=` zincirinin builder'a indirgenmesi, küçük-nesne tahsis havuzları, dallanma ipuçları, PGO denemesi. Her biri ayrı sürüm, ölçüm + fark testiyle
- [x] **3.5.4** (**v2.1.77**: `run.py --check baseline.json --tolerance` — llvm/c oranı tabanlı, donanımdan bağımsız; yerel denetim, CI'ya bağlanmadı) Gerileme koruması: benchmark eşik denetimi (CI'da veya `scripts/` ile), "optimizasyonlu / optimizasyonsuz çıktı aynı" fark düzeneği, rastgele program fuzz'ı (iki backend + `-O0` karşılaştırması)

## 4. WASM içe aktarma (rapor: wasm-import-kapsam-analizi; seçenek A onaylandı)

- [x] **4.1 W1** (**v2.1.65**) Tam ikili çözümleme + doğrulama; `i32/i64/f32/f64` tüm sayısal işlemler + dönüşümler; `br_table`; bellek; global; tablo + `call_indirect`; veri/eleman; `start`; çok değerli dönüş; trap anlamı
- [x] **4.2 W1** (**v2.1.65**) Node `WebAssembly` ile farksal test düzeneği: 36904 sayısal vektör + gerçek `zig cc` programı; CI Linux işi yeniden doğrular
- [~] **4.3 W2** Dil yüzeyi: `wasm_open` / `wasm_call_on` / bellek erişimi / `close` (yeni dil özelliği, **onay gerekir**)
- [ ] **4.4 W3** Host işlevleri (import) Nox işlevleriyle + WASI preview1 alt kümesi (varsayılan kapalı)
- [~] **4.5 W4** bulk-memory, sign-extension, reference types, yakıt/yığın/bellek sınırı **v2.1.65'te W1 ile birlikte yapıldı**; kalan: fuzz hedefine `Instance.init` ekleme, performans ölçümü
- [~] **4.6** SIMD ve threads kapsamı (karar)

## 4.5 ARC / ASAP analizi, güçlendirme ve stres testleri (kullanıcı isteği 2026-11-12)

Hedef: sahiplik piramidinin (ASAP → ARC → döngü çözücü → `lowlevel`) performansını artırmak, eksiklerini bulmak ve kanıtlamak. İlke 1 korunur: ownership kullanıcıya görünmez; belirsizlikte sessizce ARC'ye düşülür; ASAP "yanlış pozitif güvenli" karar vermez.

- [x] **4.5.1** (**v2.1.78**: `scripts/arc_inventory.py`, `NOX_FORCE_ARC`; 541 programda %98 ARC / %1.2 yığın / %0.8 arena; atomik sayaç maliyeti Apple M'de ölçülemedi; rapor `project/arc-asap-analizi-2026-11.md`) Envanter ve ölçüm: ASAP kararlarının kapsamı (hangi kalıplar ASAP, hangileri neden ARC'ye düşüyor — kapsam/escape/container/closure/işlev sınırı), derleyici içi sayaçlar (ASAP vs ARC değişken oranı, derleme zamanı retain/release sayısı), çalışma zamanı sayaçları (retain/release/atomik işlem/çevrim taraması/ara bellek yüksek-su-işareti) ve hepsini raporlayan bir araç (`NOX_ARC_STATS`); çıktı: `project/arc-asap-analizi-2026-11.md`
- [x] **4.5.2** (**v2.1.78**: 6 bulgu — kapsam darlığı, döngü çözücü tepe bellek/kapasite, sözlük büyümesi, liste büyütme sözleşmesi, pinned retain, ödünç parametre yok) Eksiklik analizi: ASAP'ın kaçırdığı güvenli durumlar (işlevler arası sahiplik özetleri, ödünç çıkarımı, son kullanımda taşıma), gereksiz retain/release çiftleri (eşleştirip eleme), atomik ARC maliyeti (M:N), `str`/`list` paylaşımı ve kopya-yazma fırsatları, döngü çözücü tetikleme sezgisi ve duraklama süreleri, istisna/`defer`/jeneratör yollarında sızıntı ya da fazla iş; her bulgu için risk sınıfı ve öneri
- [x] **4.5.3** (**v2.1.78**: `tests/stress/` 6 program + `scripts/arc_stress.py` (LLVM/QBE/gölge mod, RSS tavanı, büyüme) + `scripts/arc_shadow_test.py` (437 program aynı, 0 fark, Debug sızıntı denetimiyle); Debug çalışma zamanında hepsi temiz; bulgu: deep_structures RSS ölçekle büyüyor) Stres/soak test düzeneği: (a) tahsis fırtınası ve parçalanma, (b) döngüsel yapılar (çift bağlı liste, graf, closure döngüleri, sınıf-sınıf döngüleri) ile çevrim çözücü doğruluğu ve süre, (c) derin/geniş nesne grafikleri ve derin özyineleme ile serbest bırakma, (d) M:N zamanlayıcı altında paylaşılan nesne yarışları (çok iş parçacıklı ARC; sızıntı/çift serbest bırakma tespiti), (e) istisna ve iptal yollarında sızıntı, (f) **gölge mod fark testi**: aynı program ASAP açık ve "her şey ARC" zorlanmış çalışır — çıktı özdeş ve sızıntısız olmalı, (g) `DebugAllocator` altında sızıntı/çift serbest bırakma, (h) bellek yüksek-su-işareti gerileme eşiği; rastgele program üreteciyle fuzz
- [ ] **4.5.4** (madde 1 döngü çözücü tombstone sıkıştırması v2.1.79'da yapıldı; kalan: dize/dönüş değeri ASAP kapsamı, liste büyütme sahiplik sözleşmesi, pinned retain, dict churn) İyileştirme turu: 4.5.2'nin bulgularından kazancı ölçülenler (ör. retain/release eleme, ASAP kapsam genişletme, atomik yerine ayrı-iş-parçacığı yerel sayım, çevrim tetikleyici ayarı); her biri ayrı sürüm, 4.5.3 düzeneğinden geçmeden birleşmez

## 5. Tartışılacak büyük başlıklar (henüz karar/tasarım yok)

- [~] **5.1** C/C++/Rust kütüphanelerinden otomatik Nox binding üretimi (SDK/araç) — kapsam: başlık ayrıştırma, struct, callback, hata sözleşmesi
- [~] **5.2** Metaprogramlama altyapısını güçlendirme (comptime, derive, AST makro; İlke 1 ve 2 ile uyum)
- [~] **5.3** QBE için M:N scheduler — hedef: iki backend tam eşit, Windows'ta paralellik, Nox'un kendini derlemesi için ön aşama (atomik ARC'nin QBE'de runtime çağrısı olması, `spawn` paketleme eşitliği)
- [~] **5.4** HTTP/3 (QUIC, UDP, QPACK, TLS 1.3 QUIC) — istemci mi sunucu mu, gerçekten gerekli mi?

## 6. Windows (akşam, kullanıcıyla birlikte, SSH; hafıza planı hazır)

- [ ] **6.1** HTTP/2 sunucusu Windows'ta (uyandırma boruları → loopback soket çifti, `supported = enabled or windows`)
- [ ] **6.2** Fiber-farkındalıklı ağ G/Ç (Windows)
- [ ] **6.4** Windows: `glob_python_equivalence` ve `tempfile_basic` golden fixture'ları v2.1.79 CI'da (TMPDIR düzeltmesinden sonra) "TÜM golden fixture'lar" testini 900 s zaman aşımına uğrattı (v2.1.75'te getenv hatasıyla hızlı düşüyordu); v2.1.81'de geçici `skip_windows`. Windows oturumunda gerçek nedeni bul (takılan döngü / yol ayırıcı) ve atlamayı kaldır
- [ ] **6.5** `linux-riscv64 qemu-user duman` işi v2.1.84 CI'da runner CPU'suna bağlı olarak düştü: `zig build` (Debug, native) sırasında libdeflate `x86/adler32_template.h` AVX-512 (`evex512`) hatası; v2.1.82'de geçmişti. Kalıcı çözüm: libdeflate C kaynaklarını native yerine taban CPU ile derlemek ya da AVX-512 yolunu kapatmak (araştır)
- [ ] **6.3** Windows'ta atlanan ~6 h2c testini aç (`tests/compat/http_serve_golden_test.zig`)

## 7. İşletim / bekleyenler

- [~] **7.1** Site arka ucunun sürüm seçimi düzeltmesini M4'e canlıya alma (`services/noxlang-site/main.nox`) — **kullanıcı onayı gerekir**
- [x] **7.4** (**v2.1.69**: son iki satır sıra-bağımsız doğrulanıyor) `http_serve_golden_test` h2c SSE testi macOS CI'da sıra yarışı yaşadı (v2.1.57: `events aborted`/`forever closed` satır sırası); testi sıra-bağımsız yap ya da senkronla
- [x] **7.5** CI `apt-get` yeniden-deneme sarmalayıcısı (ağ hatası) — **v2.1.60**
- [x] **7.2** CI yeşil: **v2.1.64** (11/11 iş). Kırmızı nedenleri: GitHub apt DNS kesintisi (v2.1.56–60, v2.1.62'de `continue-on-error`), `ptr_of` fixture'ında `memcmp` dönüş genişliği (Linux/Windows, v2.1.63), riscv64 işinde `qemu-user-static` paketinin kalkması, `ci.yml` YAML hatası (v2.1.64'te düzeldi). Her sürüm sonrası `gh run list` ile kontrol sürer
- [ ] **7.6** `Snap package` iş akışı "unable to contact snap store" ile kırmızı (v2.1.62–64; CI değil, yayın iş akışı): Snap Store kimlik bilgisi/ağ kullanıcıda kontrol edilmeli
- [ ] **7.7** `Release` iş akışı CI kırmızıyken atlanır: v2.1.56–63 için GitHub Release oluşmadı (v2.1.64 ile yeniden başladı); gerekirse boşluk sürümleri tek tek yayımlanmaz, v2.1.64 notları yeterli
- [ ] **7.8** Derleyici kısıtı: serbest işlevde `list[T]` PARAMETRESİNİ değiştirmek (`def f(acc: list[int]) -> None: acc.append(1)`) `codegen: ... not supported at the moment` veriyor (HEAD'de, her iki backend); ayrı inceleme gerekir (v2.1.69'da stdlib çözümü: yeni liste döndürmek)
- [ ] **7.3** `list[Task[T]]` (bilinçli desteklenmiyor; hata `TaskGroup`'a yönlendirir) — değişmedi
