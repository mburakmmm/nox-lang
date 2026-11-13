# Faz 9 — Kontrol / debug fazı: harici analizlerden (GPT, 2026-11-12/13) çıkan bulgular

Kaynak: `analizler.rtf` (5 sürüm grubu: v2.1.78, v2.1.79–84, v2.1.96–104, v2.1.105–108, v2.1.109–114) + 2026-11-13 tarihli 6. analiz (v2.1.115–118; kullanıcının yapıştırdığı metin). Her bulgu 2026-11-13'te güncel kodla (v2.1.118) karşılaştırıldı.
Analizlerin KENDİ kaydı: sürümler bağımsız derlenmedi, CI/yük/güvenlik denetimi yok — bulgular kaynak okumasına dayanır; bu yüzden aşağıda "DOĞRULANDI" yalnızca bizim kodda görüldüğü anlamına gelir.
Amaç: yeni özellik değil, doğruluk/dayanıklılık/ölçüm. Her madde "kanıt (test) + düzeltme" ister; düzeltmeler iki backend'de doğrulanır.

## A. Güncel (bayat olmayan) bulgular → TODO bölüm 9

| # | Bulgu | Kanıt (güncel kod) | Öncelik |
|---|---|---|---|
| 9.1 | WASM `Instance.close()` sonrası kullanım: `result`, `result_count`, `exports`, `signature`, `mem_size` serbest bırakılmış tutamacı kullanır | `stdlib/nox/wasm.nox` satır 115–135: bu yöntemler `_check()` çağırmıyor (call/mem_read/mem_write çağırıyor) | Yüksek |
| 9.2 | WASM host callback yönlendirmesi modül-düzeyi `_active` yığınına dayanır; host işlevi görevi askıya alırsa (`sleep_ms`, I/O) araya giren görev yığını bozar ve yanlış örneğin host işlevi çalışabilir | `stdlib/nox/wasm.nox` `_active`/`_host_dispatch` | Yüksek |
| 9.3 | QUIC istemcisi: `SSL_set1_host` dönüşü denetlenmiyor; `Conn.connect` ALPN `h3`ü zorunlu kılmıyor (çağıranlar `alpnIsH3` bakıyor) | `runtime/stdlib_shims/quic.zig` `_ = g_funcs.SSL_set1_host(...)` | Yüksek |
| 9.4 | Nox → C `Callback[F]`: `close()` sonrası C hâlâ çağırırsa serbest bırakılmış kutu okunur | `ffi_cb.zig` `nox_cb_box_free` kutuyu `nox_rc_release` eder | Orta |
| 9.5 | bindgen dizi alanı erişimcileri sınır denetimsiz (`Name_get_f(p, i)` → `p->f[i]`) | `compiler/bindgen.zig` dizi erişimcileri | Orta |
| 9.6 | bindgen `Name_free` = `free()`; kütüphane yıkıcısı gerektiren/ödünç işaretçiler için güvenli değil, içte tahsisli alanlar bırakılmaz — belgede uyarı yok | `docs/tools/bindgen.md` "zeroed memory ... release it" | Orta (belge + başlık notu) |
| 9.7 | QPACK/HTTP/3 çözme bütçesi: `readQString` Huffman açılımı alan toplam denetiminden ÖNCE tahsis eder (başlık bloğu boyutu sunucuda önceden sınırlı ama tek alanın açılımı ve alan sayısı için kalan bütçe yok) | `runtime/stdlib_shims/h3.zig` `readQString`/`decode` | Orta |
| 9.8 | M:N yarış stres test ailesi yok: ortak dict/list, çok işçili Channel, iptal, işçi kapanışı; ARC gölge korpusu eşzamanlı senaryoları dışlar | `tests/stress/` yalnız tek-akışlı + http_fiber_load; v2.1.114–117 hataları bu boşluktan çıktı | Orta |
| 9.9 | LLVM TBAA doğruluğu: `lowlevel`/`ptr_of`/FFI ile liste belleğine yazma yollarında alias bildirimi regresyonu yok (yalnızca `list_tbaa_len_elem_mix`) | `tests/golden/codegen_cases/` | Orta |
| 9.10 | `RuntimeState` sıcak bloğu: yalnızca `@sizeOf` doğrulanıyor; alan OFSETLERİ/hizalama derleyici sabitleriyle `comptime` doğrulanmıyor | `runtime/alloc/asap.zig` `HotState` assert | Orta |
| 9.11 | Döngü çözücü kök tablosu: `shrink/clearRetainingCapacity` kapasiteyi bırakmaz; yüksek tepe → düşük kararlı yük sonrası RSS ölçülmemiş | `runtime/alloc/cycle_detector.zig` | Düşük-orta |
| 9.12 | Uzun süreli soak testi yok (milyonlarca istek; RSS, canlı nesne, kapasite; HTTP/1.1, h2, h3) | `tests/stress/` | Orta |
| 9.13 | bindgen yyjson kıyası eşit iş değil: `walk_nox` alanları sırayla gezip anahtar karşılaştırır, `walk_yyjson` `yyjson_obj_get` ile doğrudan arar (4,8×/8,4× yorumu) | `benchmarks/yyjson/bench.nox`, `benchmarks/RESULTS.md` | Düşük (ölçüm notu/eşdeğer varyant) |
| 9.14 | Windows'ta bindgen uçtan uca (LLP64 `long`, `unsigned char*` ptr) gerçek doğrulaması hâlâ yok (kod düzeltildi, test Windows'ta atlanıyor) | `tests/golden/bindgen_golden_test.zig` Windows'ta atlanır | Windows oturumu → TODO 6.8 |
| 9.15 | WASM varsayılan kotalar (2 milyar yakıt, 16 384 derinlik, 256 MiB) çok-kiracılı kullanım için gevşek; sıkı bir hazır ayar ve capability sınırları W2/W3 ile tasarlanmalı | `runtime/wasm_bridge` `Config` | İzleme (Nexus) |

Küçük/isteğe bağlı: `parseSettings` bilinmeyen SETTINGS kimliği tekrarını yok sayar (RFC bunu zorunlu kılmaz; sıkılaştırma tercihidir) — 9.7 ile birlikte düşünülür.

## A2. 6. analizden (v2.1.115–118) doğrulanan YENİ bulgular

| # | Bulgu | Doğrulama (2026-11-13, kod) | Öncelik |
|---|---|---|---|
| 9.0 | **M:N tek-işçi ödünleşimi** (kullanıcı önceliği 1): modül düzeyinde değişken durumu olan her program QBE ve LLVM'de tek işçiye düşer; `NOX_POOL_WORKERS` bu seçimi ezince eski yarış geri gelir | `compiler/codegen_qbe/codegen.zig` `pin_single_worker`, `registration.zig` `hasSharedMutableGlobals`, `async_rt/pool_bridge.zig` mod 2 | **EN YÜKSEK** — tasarım belgesi aşağıda (D bölümü) |
| 9.16 | HTTP/3 istemcisi: `attempt()` `st.writeAll` HERHANGİ bir hatada `.presend` döner; `Stream.writeAll` parça parça yazdığından kısmi gönderim "hiç gönderilmedi" sayılıp TCP'ye düşülebilir (POST tekrarı) | `h3_client.zig:342` + `quic.zig:565` (kısmi yazımı izlemiyor). Not: RFC 9114 sunucunun eksik (FIN'siz) isteği işlememesini gerektirir, risk bu yüzden sınırlı; yine de bayt sayacı ile kesinleştirilmeli | Yüksek |
| 9.17 | `EventQueue.close()` büyük olay tamponunu bırakmıyor (yalnız `closed=true`, `len=0`); olay 80 B, kapasite üst sınırı 2^20 → ~80 MiB | `ffi_events.zig` `nox_evq_close` (`buf` tutuluyor) | Yüksek (kolay) |
| 9.18 | HTTP/3 gzip/deflate açma: `streamRemaining(&Allocating)` bittikten SONRA 512 MiB denetimi (sıkıştırma bombası). H1/H2 yolunda (`http_client.zig:1107`) aynı desen var mı kontrol edilecek | `h3_client.zig:288-289` | Yüksek |
| 9.19 | `ctlTrailers` kısmi tahsis hata yolu: `freeHeaders(copy[0..n])` dilimi (yanlış uzunluk) bırakır, ardından `free(copy)` aynı tahsisi tekrar bırakır → çift serbest bırakma | `h3_server.zig:192-195` | Orta (yalnız OOM yolu) |
| — | `SSL_set1_host` dönüşü (9.3 ile aynı) | `quic.zig` | 9.3 |
| — | `NOX_POOL_WORKERS` ile çok işçi + değişken modül durumu stres testi | 9.0 kapsamında + 9.8 | 9.0 |
| — | HTTP/3 hata yolu testleri: kesilen akış, yarım POST, beklenmedik EOF, bozuk QPACK, bağlantı iptali, tahsis hatası | `h3*` birim testleri mutlu yol ağırlıklı | 9.7'ye eklendi |

## B. Bayat / kapanmış bulgular (iş yazılmadı)

| Bulgu | Durum |
|---|---|
| "Paylaşılan globals worker'lar arasında" (v2.1.114) | Paylaşım v2.1.115'te GERİ ALINDI (yarış); v2.1.117 geçici kuralı: paylaşılan değişken modül durumu → TEK işçi. Bu kural **kalıcı çözüm bekliyor → 9.0 (öncelik 1)** |
| HTTP/3 henüz kullanıcıya açık değil, sunucu/istemci/uyumluluk bekliyor; QPACK dinamik tablo yok | v2.1.115–116: sunucu + istemci, Alt-Svc, QPACK dinamik tablo çözücü, gerçek curl 8.23 ile uyumluluk |
| FFI yabancı iş parçacığı callback'i yok | v2.1.118 `nox.ffi.EventQueue` |
| bindgen Windows `long` 64 bit, `const unsigned char*` → `str` | v2.1.107'de düzeltildi (testle); yalnızca Windows uçtan uca doğrulaması açık (9.14) |
| bindgen: `...`, `_Complex`, `__int128`, `long double`, bit alanı atlanıyor | v2.1.118 (bit alanı v2.1.107'den beri vardı) |
| `docs/internals/mobile-matrix.md` PostgreSQL/MySQL tutarsızlığı | Metin güncel görünüyor (satır 34 mobil hedeflerde ana makine kütüphanesi yüklenmediğini ve WASM için saf Zig istemciyi anlatıyor) |
| `list[T]` parametresi büyütme sınırları (metot/işlev değeri/yeniden bağlama; ortak liste ayrışması) | Bilinçli, `docs/language/functions.md`'de belgeli (TODO 7.8) |
| ASAP kapsamı dar (%98 ARC), liste büyütme sahiplik sözleşmesi | TODO 4.5.4: ölçüldü, kazanç düşük/riskli → ertelendi (kullanıcı kararı) |
| QBE'de M:N yok | v2.1.112 (+ v2.1.117 kuralı) |
| Döngü çözücü RSS büyümesi, dict churn RSS, istisna denetimi maliyeti, pinned retain | v2.1.79–84'te düzeltildi |
| WASM threads (gerçek paralel örnek yok), `@derive` ↔ Noxen şema entegrasyonu, Nexus W2/W3 | Tasarım kararı bekleyen yol haritası maddeleri; hata değil (TODO 5/7 bölümlerinde) |

## C. Yöntem (faz çalışma kuralları)

1. Her madde önce AÇIK bir yeniden üretim/kanıt testiyle kırmızıya çevrilir (iki backend ya da runtime birim testi), sonra düzeltilir.
2. Düzeltme semantiği değiştiriyorsa (ör. 9.5 varsayılan denetim) kullanıcıya sorulur.
3. Bitince TODO kutusu işaretlenir, sürüm yazılır; çözülemeyenler gerekçesiyle "bilinçli" diye kayda geçer.

## D. 9.0 — M:N: tek-işçi kuralının KALICI çözümü (tasarım taslağı, karar bekliyor)

**Hedef (kullanıcı, 2026-11-13):** LLVM ve QBE'de tam denk, performans kısmayan, paylaşılan/değişken modül durumunu da paralel çalıştıran M:N. v2.1.117'deki "tek işçi" kuralı kalkar; `NOX_POOL_WORKERS` ile işçi sayısı artırmak güvenli olur.

**Bugünkü model:** her işçi modül globals bloğunun KENDİ kopyasını taşır (`globals_blocks[slot]`, `pool_bridge` `globals_init_fn`). `serve_multicore` fabrika modelinde bu istenir (işçi başına izole durum). Ama görevler işçiler arasında göç ettiğinden, tek bir mantıksal global (ör. modül düzeyinde `cache: dict`) işçi başına AYRI kopya olur → yanlış/boş durum. v2.1.114'te kopyayı ortaklaştırmak denendi: dict/list/sınıf ve RateLimiter yarış verdi (kapsayıcılar iş parçacığı güvenli değil) → v2.1.115'te geri alındı → v2.1.117: tek işçi.

**Çözümün üç ayrı sınıfı (derleyici otomatik ayırır, yeni sözdizimi yok — İlke 1):**
1. **Değişmez-sonra-paylaşılan:** başlatıldıktan sonra HİÇBİR yerde yeniden atanmayan/yazılmayan global → tek ortak kopya, kilitsiz okuma. Nesne ağları için "ölümsüz/donmuş" işareti (ARC trafiği ve çekişme yok).
2. **İşçi-yerel:** yalnız bir işçinin yaşam süresince erişilen/önbellek niteliğindeki durum (`serve_multicore` fabrikası). Bugünkü kopya modeli korunur.
3. **Paylaşılan-senkronize:** değişken ve görevler arası paylaşılan → TEK ortak kopya + senkronizasyon.

**Sınıf 3 için seçenekler:**
- **A (öneri):** kapsayıcı/nesnede "paylaşılan" bayrağı + kısa kritik bölümlü ince taneli kilit (dict/list/set işlemi, sınıf alan yazımı). Kilit YALNIZ bayraklı nesnelerde alınır; bayrak, paylaşılan bir global'den ULAŞILABİLEN nesnelere yayılır (depolama anında grafiğin işaretlenmesi, bir kez). Sıcak yolda maliyet yalnız tahmin edilebilir bir dal. Tip-tabanlı durağan analiz ("bu sınıf bir paylaşılan global'e hiç girebilir mi?") yayılmayan sınıflarda HİÇ kod üretmez → sıfır maliyet. Anlam: tek işlemler atomik, bileşik işlemler (`d[k] = d[k] + 1`) Go/Python-benzeri atomik DEĞİL ama bellek-güvenli.
- **B:** büyük modül kilidi (paylaşılan duruma dokunan kod bölgesi tek kilit; ilk günün hızlı yolu). Basit, ama ölçeklenmez → "performans kısmama" hedefine aykırı.
- **C:** RCU/kopya-yaz (okuma-ağırlıklı); yazma maliyeti yüksek, karmaşık.
- **D:** aktör (evi işçide, mesajlaşma); en yavaş.

**Kritik zorluklar:** (i) paylaşım "bulaşıcıdır" (paylaşılan kapsayıcıya konan nesne de paylaşılır → depolama anı işaretlemesi); (ii) kilit tutarken fiber yield EDİLMEMELİ (askıya alma noktalarında kilit yok denetimi); (iii) ARC zaten atomik (MN.1), döngü çözücü ve STW bariyeri paylaşılan bayrakla uyumlu olmalı; (iv) ASAP arena/`lowlevel` kaçışları paylaşılan nesne üretmemeli; (v) iki backend'de aynı ABI (QBE `qbe*` dikişi + LLVM).

**Aşamalar:** 9.0.1 ölçüm tabanı (paylaşılan dict/list/sınıf iş yükü, işçi 1/2/4/8, iki backend, bugünkü tek-işçi sonucu) → 9.0.2 tasarım kararı (kullanıcı onayı: sınıf 3 seçeneği, bileşik-işlem anlamı) → 9.0.3 değişmez/donmuş sınıf + ölçülü kazanç → 9.0.4 işçi-yerel sınıf netleştirme → 9.0.5 paylaşılan-senkronize (A) → 9.0.6 stres/TSan/golden (iki backend, `NOX_POOL_WORKERS` 1/2/4/8) → 9.0.7 tek-işçi kuralını sil, `docs/language/concurrency.md` + spesifikasyon güncelle.
**Kabul ölçütleri:** (a) tek-işçi pini YOK; (b) paylaşılan değişken dict/list iş yükünde 4 işçide ölçeklenme (tek işçiden belirgin hızlı) ve paylaşılan-OLMAYAN programlarda ölçülebilir yavaşlama YOK (benchmarks/ + `RESULTS.md`); (c) LLVM ve QBE çıktıları ve hata yolları aynı; (d) yarış stres paketi + ThreadSanitizer temiz; (e) todo-backend/Aether/Nyx örnekleri çok işçide yeşil.
