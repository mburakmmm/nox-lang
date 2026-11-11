# Yapılacaklar listesi (2026-11-11'den)

Tek takip noktası: 2026-11-11 oturumundaki analizlerden çıkan ve konuşulan **tüm işler**. Her iş bittikçe işaretlenir ve sürümü yazılır. Durum: `[ ]` açık, `[x]` bitti (sürümle), `[~]` karar/onay bekliyor, `[-]` yapılmayacak/bayat.
Kaynak raporlar: `project/freestanding-kapsam-analizi-2026-11.md`, `project/stdlib-performans-analizi-2026-11.md`, `project/ffi-performans-analizi-2026-11.md`, `project/wasm-import-kapsam-analizi-2026-11.md`.

**Kullanıcı kararları (2026-11-11):** WASM için seçenek A (kendi Zig yorumlayıcısını MVP'ye tamamla) onaylandı · kusurlar önerilen sırayla düzeltilecek (`%llu` → liste bozulması → `base64`/`upper-lower` Zig'e) · **gzip için yeni bağımlılık YOK** (Zig flate kalır) · bu liste takip aracıdır.

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
- [ ] **2.3** `strings.replace` (1.44x), `csv.parse` (1.35x) tahsis azaltma
- [ ] **2.4** `json` parse/dump (1.7x) profil + optimize
- [ ] **2.5** `regex` find_all/replace (1.5-1.7x) profil + optimize
- [-] **2.6** `gzip` (2.5x/3.4x) — **yeni bağımlılık eklenmeyecek** (kullanıcı kararı); Zig flate kalır. İsteğe bağlı: bağımlılıksız ince ayar (düzey/tampon)
- [~] **2.7** Eksik modül adaylarından hangileri gerçek talep: `bigint`/`decimal`, argüman ayrıştırma, `tempfile`/`glob`, XML/HTML, zip/tar/zstd, md5/sha3/blake3, `Mutex/Semaphore`, `.env`/ini
- [ ] **2.9** Büyük (≥ ~64 KB) tahsislerde sayfa-hatası maliyeti: `"  " + 1MB + "  "` 0.44 ms (CPython 0.02 ms) — büyük blok önbelleği/yeniden kullanımı araştır (`nox_rc_alloc` büyük yol)
- [ ] **2.8** Her düzeltmeden sonra `benchmarks/stdlib_perf/run.py` ile yeniden ölç (hedef: tüm kalemler ≤ ~1.5x)

## 3. FFI (rapor: ffi-performans-analizi)

- [~] **3.1** `Buffer`/`list[u8]`/`list[int]` için `lowlevel` içinde veri işaretçisi (sıfır-kopya) — **dil/ABI kararı**
- [ ] **3.2** QBE'de `lowlevel` `ptr_read/ptr_write` döngü maliyeti (0.87 vs 0.40 ns/eleman) incele
- [ ] **3.3** Callback trampoline'ı profile et (4.99 ns, C'nin 7x'i)
- [ ] **3.4** Struct-by-value ve saklanan (kayıtlı) callback tasarımı — madde 5.1 ile birlikte

## 4. WASM içe aktarma (rapor: wasm-import-kapsam-analizi; seçenek A onaylandı)

- [ ] **4.1 W1** Tam ikili çözümleme + doğrulama; `i32/i64/f32/f64` tüm sayısal işlemler + dönüşümler; `br_table`; bellek; global; tablo + `call_indirect`; veri/eleman; `start`; çok değerli dönüş; trap anlamı
- [ ] **4.2 W1** Node `WebAssembly` ile farksal test düzeneği (CI'de)
- [~] **4.3 W2** Dil yüzeyi: `wasm_open` / `wasm_call_on` / bellek erişimi / `close` (yeni dil özelliği, **onay gerekir**)
- [ ] **4.4 W3** Host işlevleri (import) Nox işlevleriyle + WASI preview1 alt kümesi (varsayılan kapalı)
- [ ] **4.5 W4** bulk-memory, sign-extension, reference types; yakıt/yığın/bellek sınırı, fuzz
- [~] **4.6** SIMD ve threads kapsamı (karar)

## 5. Tartışılacak büyük başlıklar (henüz karar/tasarım yok)

- [~] **5.1** C/C++/Rust kütüphanelerinden otomatik Nox binding üretimi (SDK/araç) — kapsam: başlık ayrıştırma, struct, callback, hata sözleşmesi
- [~] **5.2** Metaprogramlama altyapısını güçlendirme (comptime, derive, AST makro; İlke 1 ve 2 ile uyum)
- [~] **5.3** QBE için M:N scheduler — hedef: iki backend tam eşit, Windows'ta paralellik, Nox'un kendini derlemesi için ön aşama (atomik ARC'nin QBE'de runtime çağrısı olması, `spawn` paketleme eşitliği)
- [~] **5.4** HTTP/3 (QUIC, UDP, QPACK, TLS 1.3 QUIC) — istemci mi sunucu mu, gerçekten gerekli mi?

## 6. Windows (akşam, kullanıcıyla birlikte, SSH; hafıza planı hazır)

- [ ] **6.1** HTTP/2 sunucusu Windows'ta (uyandırma boruları → loopback soket çifti, `supported = enabled or windows`)
- [ ] **6.2** Fiber-farkındalıklı ağ G/Ç (Windows)
- [ ] **6.3** Windows'ta atlanan ~6 h2c testini aç (`tests/compat/http_serve_golden_test.zig`)

## 7. İşletim / bekleyenler

- [~] **7.1** Site arka ucunun sürüm seçimi düzeltmesini M4'e canlıya alma (`services/noxlang-site/main.nox`) — **kullanıcı onayı gerekir**
- [~] **7.2** CI takibi: v2.1.49–55 yeşil (v2.1.48 beklenen kırmızı, v2.1.49'da düzeldi); v2.1.56 bekleniyor — her sürüm sonrası `gh run list --workflow CI` ile kontrol
- [ ] **7.3** `list[Task[T]]` (bilinçli desteklenmiyor; hata `TaskGroup`'a yönlendirir) — değişmedi
