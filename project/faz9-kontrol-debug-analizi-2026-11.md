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

### D.2 Kod incelemesiyle inceltilmiş uygulama stratejisi (2026-11-13, kullanıcı: "A ile devam")

Karar: **A** (tek işlemler atomik, bileşik işlemler değil; çökme/bellek bozulması yok). Koda bakınca "nesne başına bayrak" yerine **ad üzerinden senkronize global** stratejisi seçildi:

- **Neden bayrak değil:** `list[T]` tek bloktur (başlık + elemanlar) ve büyürken YENİDEN TAHSİS edilir; global yuvası yeni işaretçiyle güncellenir (belgeli "ortak liste ayrışması"). Yani paylaşılan bir listede nesne kimliği sabit değildir; nesne başına kilit/bayrak anlamsızlaşır. Ayrıca bayrak, her satır içi liste/sınıf erişimine bir dal koyardı (sıcak yolda maliyet, "performans kısmama" hedefine aykırı).
- **Strateji:** her modül global'i derleme zamanında sınıflanır: (1) sabit skaler/str (bugünkü gibi), (2) YALNIZ izinli biçimlerde kullanılan paylaşılan-değişken global ("senkronize"), (3) diğerleri (bugünkü gibi tek işçi). Tüm kullanımları izinli listede olan globaller TEK ortak blokta yaşar ve her ilkel işlem (dict get/set/in/len, list append/index/len, sınıf alanı okuma/yazma, skaler yeniden atama) o global'e ait bir kilit altında yapılır; kilit sözcüğü global bloğunun içindedir (yeni global durum yok, İlke 6). Argümanlar kilit DIŞINDA hesaplanır, kilit altında asla askıya alma/yield olmaz.
- **Sıfır maliyet:** global'e ad üzerinden dokunmayan hiçbir kod tek komut bile ek maliyet taşımaz (bayrak yok, satır içi dal yok).
- **Kaçış analizi (güvenli yedek):** global bir yerel değişkene atanıyor, argüman olarak geçiyor, döndürülüyor, kapanışa yakalanıyor, listeye konuyor, `for` ile gezilip gövdede yield ediliyorsa → bu global "senkronize" OLAMAZ → program bugünkü gibi tek işçiye sabitlenir (kapsamı genişletmek sonraki dilimler: yinelenen koleksiyonlar için anlık görüntü, argüman geçirme için bayrak tabanlı P3).
- **Dilimler:** (1) `dict[skaler|str, skaler|str]` + skaler yeniden atama; (2) `list[skaler|str]`; (3) sınıf örneği (skaler alanlı); (4) iç içe/yinelenen/argüman olarak geçen (bayrak tabanlı P3). Her dilim iki backend'de golden + stres + tek-işçi pininin kalkması ile biter.
- **Çalışma zamanı:** yeni mod `nox_pool_main_init(3)` = "paylaşılan tek blok": `nox_globals_get/set` tüm işçiler için slot 0 bloğunu verir; kardeş işçiler globals init/deinit çalıştırmaz. `pickMainWorkerCount(3)` modu 0 gibi (küçük varsayılan); ölçeklemek için `NOX_POOL_WORKERS` ya da ileride CPU sayısı politikası.
- **Ölçüm tabanı:** `benchmarks/mn_shared/` (v2.1.119): paylaşılan sözlüklü program bugün LLVM 2.37 s (tek işçi) / `NOX_POOL_WORKERS=2` → YANLIŞ çıktı (işçi başına kopya), 4+ → çökme; paylaşımsız aynı iş yükü 8 işçide 0.40 s. Hedef: aynı çıktı + 8 işçide ~0.4-0.6 s (kilit çekişmesi payı hariç).

### D.3 KALICI mimari: tip-yönlendirmeli dinamik paylaşım (kullanıcı kararı 2026-11-13: "hiçbir istisna bırakmayacağız, Rust/Tokio/Go gibi korkusuz paralellik")

Monitör/kapsam-dışı listeli yaklaşım REDDEDİLDİ (tek kilit serileştirir, istisna bırakır). Hedef: HERHANGİ bir nesne grafiği iki görev arasında paylaşılabilir; programlar HİÇBİR koşulda tek işçiye sabitlenmez; bellek güvenliği (UAF/çift bırakma/yırtık yapı yok) ve ölçeklenme. Rust'ın `Send/Sync` tipleri İlke 1'i (görünmez sahiplik) bozar; bu yüzden güvenlik ÇALIŞMA ZAMANINDA sağlanır (Java / Python free-threading ailesi).

**Çekirdek fikirler**
1. **Dinamik "paylaşılan" bayrağı + nesne kilidi.** Her yığın nesnesinin ARC başlık sözcüğünde iki bit: `SHARED` (nesne ≥2 görevden erişilebilir) ve `LOCK` (nesne başına döndürme kilidi). Düşük 32 bit refcount, 32-57 döngü çözücü yuva indeksi (28 → 26 bit), 58 `SHARED`, 59 `LOCK`, 60-61 renk, 62 tamponlu. Bayrak yoksa erişim maliyeti: tek yükleme + öngörülür dal.
2. **Yayımlama bariyeri (publish).** Bir işaretçi paylaşılan bir yere yazıldığında (paylaşılan nesnenin alanı/listesi/sözlüğü, modül globali, kanal gönderimi, `spawn` argümanı/yakalaması, görev sonucu) gösterilen grafik **geçişli olarak** `SHARED` işaretlenir (yapışkan; bir nesne en çok bir kez gezilir). Tip bilgisi derleme zamanında bilindiğinden derleyici tip başına bir `$T_publish` üretir.
3. **Paylaşılan nesnede erişim = sahipli okuma / kilitli yazma.** Yığın tipli alan/eleman okuması kilit altında retain eder (okuyan kendi referansını tutar); yazma kilit altında yeni işaretçiyi koyar, ESKİYİ kilit DIŞINDA bırakır (kullanıcı kodu çağrısı kilit içinde asla çalışmaz → kilitlenme yok). `list` büyümesi paylaşılan bloğu kopyalar (eski blok başka tutucuda yaşar, serbest bırakılmaz).
4. **Tip-yönlendirmeli ödeme.** Yayımlama noktalarının statik tiplerinden (global tipleri, kanal eleman tipleri, `spawn` argüman/sonuç tipleri, yakalama tipleri) başlayıp alan/eleman tiplerine, alt sınıflara ve protokolü gerçekleyen sınıflara kapanan "paylaşım-yetenekli tipler" kümesi `S` hesaplanır. Bariyerler YALNIZ `S` tipleri için üretilir; paylaşım yapmayan programlar/tipler SIFIR maliyetlidir.
5. **Mevcut ad-üzerinden yönlendirilen hücreler (dilim 1-7) HIZLI YOL olarak kalır** (kilit-sıfır/hücre); genel model onların kapsamadığı HER ŞEYİ kapsar ve v2.1.117 tek-işçi sabitlemesini KALDIRIR.

**Aşamalar (her biri tek başına yeşil ve yayınlanabilir; bayrak hiç kurulmadan davranış değişmez)**
- F1 Temel: başlık bitleri + çalışma zamanı ilkelleri (`isShared/lock/unlock/publish`), birim + iş parçacığı testleri; `S` tip kümesi analizi.
- F2 Sınıf örneği alanları: sahipli okuma / kilitli yazma bariyerleri, `$T_publish`, eşitlik/yazdırma sarmalayıcıları (kilit altında).
- F3 `list`: tüm satır içi liste işlemleri için paylaşılan yavaş yol (indeks/atama/append/pop/len/for/dilim/sort/…), iç içe listeler, listeyi alan/değişken/argüman olarak taşıma.
- F4 Yayımlama noktaları: kanal gönderimi, `spawn` argüman/yakalama, görev sonucu, global atama.
- F5 Kalıtım/protokoller, closure, `TaskLocal`, `Task`/kanal tutamaç tipli alanlar; tek-işçi sabitlemesinin kaldırılması (`pinned` KALMAZ).
- F6 Yük/yarış/soak testleri, ThreadSanitizer, performans ölçümü (paylaşım yapmayan programda ≤%1; paylaşılan iş yükünde ölçekleme), belgeler.

**F2-F5 için saha denetimi (2026-11-13; hiçbir kaynak değişmeden okuyarak çıkarıldı).** Sınıf alanını HAM okuyan/yazan üreteç noktaları — her biri paylaşılan örnek için ya bariyer ya da kilit-altı anlık görüntü gerektirir:
- Bariyer (sahipli okuma / yayımlayıp kilitli yazma): `expr.zig` `genFieldRead`, `genFieldReadFromValue`; `stmt.zig` `genAssign` `.attribute` dalı; `calls.zig` alan-alıcılı `append`/liste işlemleri (`genListAppend` `field_recv`), `genRefListArgAddr`, `calls.zig:1516/2144/2629` alan adresi hesapları; `simple_init`/kurucu depolamaları (taze nesne: bariyer gerekmez).
- Kilit-altı gezginler (eşitlik, yazdırma, JSON/yansıma): `layout.zig` `genClassEq` (satır ~1076, ~1338), `expr.zig` `genPrintClass` (~2677, ~2738), `exceptions.zig:51`, `decorators.zig` `genReflectFieldGetter`; kullanıcı `__eq__/__repr__/__str__` çağıran yollar kilidi TUTARAK çağırmamalı (anlık görüntü al, kilidi bırak, sonra çağır).
- Zaten güvenli: sınıf serbest bırakma (rc=0: dışlayıcı), iz/gc-free (STW).
- Liste: `list[T]` alanı için alan-hücresi (`nox_slist_*` ailesi alan başına) ve genel `list` işlemleri için paylaşılan yavaş yol.

