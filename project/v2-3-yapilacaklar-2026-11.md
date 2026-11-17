# Nox 2.3 yol haritası ve yapılacaklar (2.2.0-rc.1 ile açıldı, 2026-11-17)

Kaynak: 2.2 öncesi limitasyon turu (VAULT, Pulse, Ember, Chronos, Nova, Aether, Nyx raporları + worker ölçek raporu), 2.2 yol haritasından açık kalanlar ve eski listelerde (`acik-isler-2026-11-14.md`, `yapilacaklar-2026-11.md`) açık görünenler. Bu dosya yalnızca **açık** işleri tutar; bir iş bitince kutu `[x]` yapılır ve sürümü yazılır. Yeni açık iş buraya eklenir.

Durum: `[ ]` açık · `[x]` bitti (sürümle) · `[-]` bayat/yapılmayacak (kanıtıyla) · `[K]` kullanıcı kararı/eylemi gerekir · `[W]` Windows PC gerekir.
Boyut: **S** (birkaç saat) · **M** (1-2 gün, tek sürüm) · **L** (birden çok sürüm, kendi tasarımı).
Kural (AGENTS §16): yeni dil özelliği / API biçimi / bellek modeli etkisi olan maddeler `[K]` ile başlar, önce sorulur. Tasarım gereği sınırlara dokunulmaz: kooperatif iptal, sabit 192 KiB fiber yığını, liste ataması kopyası, işçi başına modül durumu, QBE tek iş parçacığı. Her madde: önce güncel derleyicide yeniden üret (raporlar bayat olabilir), kök neden, iki backend'de golden, ölçümlerde C sütunu.

## Önerilen sıra

1. **Aşama 1 — Güvenilirlik ve CI** (hepsi S/M, karar gerektirmez): 2.2'nin kararlı yayını sonrası ilk iş; kırmızı/flaky CI sonraki her aşamayı yavaşlatıyor.
2. **Aşama 2 — Güvenli ağ API'sinin tamamlanması** (SSRF/DNS-rebinding hattı; 2.2'de `nox.dns` + `connect_ip` + `ca_file` ile açıldı).
3. **Aşama 3 — Veri tabanı/Redis/Windows boşlukları.**
4. **Aşama 4 — Dil** (iç içe `async def`, vb.; her biri önce tasarım onayı).
5. **Aşama 5 — Performans kalan açıkları.**
6. **Aşama 6 — Büyük/uzun vadeli** (REPL, preemption, FFI güvenli modu).

## Aşama 1 — Güvenilirlik ve CI

- [x] **1.1 `mobile` iş akışı: iOS simülatör ağ matrisi flaky** (v2.2.1). Kök nedenler: (a) `localhost` IPv6-önce sırasıyla `::1`'e bağlanma CI simülatöründe sessizce düşüp 4 sn bütçeyi tüketiyor, IPv4 yedeği hiç denenemiyordu (`dns_dual_stack`) → loopback bağlanma denemesi 750 ms ile sınırlandı (`net_dial.attemptCapMs`, birim test); (b) tek bir `simctl spawn` 80 sn sürebiliyor (`connect_blackhole`, duvar sınırı) → `scripts/mobile_network_probe.sh` senaryoları ilk başarısızlıkta BİR KEZ yeniden dener (gerçek hata iki denemede de düşer).
- [x] **1.2 GitHub Actions Node 24** (v2.2.1): `checkout@v5`, `upload-artifact@v6`, `download-artifact@v7`, `action-gh-release@v3`, `attest-build-provenance@v4` (tümü node24; `android-emulator-runner@v2` composite). Release iş akışı ilk gerçek koşusunda doğrulanır.
- [x] **1.3 Çok çekirdekli dağılım testi Windows'ta** (v2.2.1): sinyal yerine `child.kill`; dağılım yanıt zaman aralıklarından ölçülür. Windows CI koşusuyla doğrulanır. `[W]`
- [x] **1.4 (S) Yerel ön kontrol betiği** `scripts/precheck.sh` (v2.2.0-rc.2; v2.2.1'den beri `release.sh` adım 1b/3b'de çağrılır) CI'ın docs işindeki TÜM denetimleri koşturur: `check_docs.py`, `check_global_state.py`, `check_doc_contracts.py`, `check_reserved_symbols.py` + `gen_reserved_symbol_fixture.py --check`, `check_wasm_http_stubs.py`, `gen_sbom.py --check`, `build_site.py --verify`. v2.1.195 ve rc.1'de bunlar atlandı ve CI kırıldı (`_toc.yml`, global-durum listesi, wasm ABI tablosu, belge sözleşmesinin ön sürüm sürümü, ayrılmış semboller). Ayrıca yeni `codegen_cases` fixture'ları `fixture_corpus.zig`ye KAYDEDİLMEZSE `zig build test`te çalışmaz (v2.1.195-196'daki 11 fixture rc.2'de kaydedildi): yeni `.nox` eklenince kayıt kontrolü otomatikleştirilmeli.
- [x] **1.5 Eski listelerdeki bayat kayıtlar kapatıldı** (v2.2.1): `acik-isler-2026-11-14.md` A1/A2/A3/A5.
- [ ] **1.7 GERÇEK ÇALIŞMA ZAMANI HATASI: çalınan bir fiber modül-global değişkeni okurken ilklenmemiş bellek (Debug'da `0xAAAA...`) görebiliyor.** Bulgu (v2.2.1): `signal_install_take_wait` fixture'ı ağır CPU yarışında ~1/2000 düşüyordu; zaman damgalı yeniden üretimde `s: int = nox.signal.sigusr1()` modül-globali `run()` fiber'ında `-6148914691236517206` (= `0xAAAAAAAAAAAAAAAA`) okundu (`spawn killer(s)` çöp sinyal numarası aldı, `send_self` False, `wait` zaman aşımı). YENİDEN ÜRETİM: `NOX_POOL_WORKERS` AYARSIZ (varsayılan havuz, mod 0 = çoklu işçi + büyüyebilir) + 60-90 eşzamanlı süreç döngüsü (`for i in 1..25: ./prog`); `NOX_POOL_WORKERS=1/2/4/10` ve `+NOX_POOL_MAX_WORKERS=10` ile 9000+ koşuda yeniden üretilemedi. Şüphe: işçi başına modül-global kopyası (`globals_blocks[slot-1]`, `nox_globals_get` slot'a göre) başka bir işçinin henüz `globals_init_fn`i bitirmemiş kopyası (blok tahsis edilip işaretçi yazıldıktan SONRA ilkleyiciler çalışıyor, bkz. `pool_bridge.poolWorkerMain` + `$nox_init_globals`) ya da büyütülen (`growOne`, izleyici) işçi. Belirsiz yol: `runtime/alloc/asap.zig` `nox_globals_get/set` + `compiler/codegen_qbe/globals.zig` init sırası. Fixture şimdilik modül-globalini fiber'a PARAMETRE olarak geçiyor (bu yolu atlar); asıl hata AÇIK. Üretim etkisi: yalnızca çalınan fiber + başka işçinin kopyası + ağır yarış; `ReleaseFast` runtime'da çöp yerine bellek içeriği (genellikle 0) okunur.
- [ ] **1.8 (S) `clibs_*` fixture'ları (`clibs_brotli`, `clibs_lz4_zstd_xxhash`, `clibs_pcre2`, `clibs_yyjson`) standart `zig build test`te çalışmıyor** (`noxclibs-<hedef>.a` arşivini fixture harness'i bağlamıyor, `CcFailed`). Yerelde `noxc run` ile iki backend'de geçiyorlar. Harness'e arşiv yolunu ekle ya da ayrı bir `clibs-test` adımı aç.
- [x] **1.9 Kayıtsız fixture'lar kaydedildi** (v2.2.1): 12 fixture + önceki turdaki 13; kayıt kontrolü için `scripts/check_fixture_registration.py` (yeni `.nox` + `.expected` eklenip hiçbir test dosyasında anılmıyorsa precheck kırmızı).
- [x] **1.6 `.git/refs/.DS_Store`** silindi (`git fsck` temiz); Finder artığıydı, depoya girmez.

## Aşama 2 — Güvenli ağ API'si

- [x] **2.1 `nox.ip` — IP ayrıştırma + sınıflandırma** (v2.2.1; modül adı `nox.ip`, stdlib düz dosya düzeni): `parse`/`is_valid`/`is_global_text`, `IpAddress` (`is_global/private/loopback/link_local/cgnat/multicast/metadata/reserved/unspecified`, `unmap` IPv4-eşlemeli + NAT64). Belirsiz biçimler (`010.0.0.1`, `127.1`, `%bölge`) reddedilir. Python `ipaddress` ile 72 geçerli + 22 geçersiz adreste çapraz doğrulandı (golden `ip_classify`).
- [x] **2.2 `nox.tls.connect(host, port, connect_ip="")`** (v2.2.1): ad çözümlenmeden IP'ye bağlanır, SNI/sertifika `host`a karşı doğrulanır; wasm'da KAPALI başarısız (host TLS'i IP seçtirmez). Test: yerel `serve_tls` sunucusuna karşı sabitlenmiş bağlantı `CertificateHostMismatch` ile biter (sunucuya ulaşıldı + ad doğrulaması orijinal host'a karşı).
- [x] **2.3 `nox.http.Pool`** (v2.2.1): `new_pool(max_idle, idle_timeout_ms)` → `Pool` (`request/get/post/idle_connections/close`); kendi `std.http.Client`ı + bağlantı havuzu, süreç-geneli havuzla ve diğer `Pool`larla bağlantı PAYLAŞMAZ; uçuştaki isteklerle `close` başvuru sayacıyla güvenli (son bırakan yok eder). `connect_ip`/`ca_file`li istekler havuzu atladığından `Pool.request`te yok. Test: iki `Pool` + gerçek sunucu sayaçları (2 bağlantı / 7 istek), `client_idle_connections()` değişmez.
- [x] **2.4 AEAD bayt API'si** (v2.2.1): `aead_seal_bytes`/`aead_open_bytes` (`Buffer` girdi/çıktı; NUL ve 0x80-0xff baytları dahil; çalışma zamanında `hexio` kipi). `str` API'siyle birbirinin mührünü açar (golden `crypto_aead_bytes`).
- [x] **2.5 `nox.safehttp`** (v2.2.1): yalnızca yönlendirme yardımcısı değil, güvenilmeyen URL'ler için TAM güvenli istemci — her adımda (ilk istek + her yönlendirme) şema/kimlik bilgisi denetimi, tek çözümleme, çözülen HER adres `nox.ip.is_global`, doğrulanmış IP'ye `connect_ip` ile bağlanma, ana makine değişince `Authorization`/`Cookie` atma, `allow_hosts` (virgüllü ad listesi) / `allow_private`. Test: yerel üç sunucuyla loopback engeli, metadata adresine yönlendirme engeli (bağlantı hiç kurulmaz), izinli yönlendirme zinciri.
- [x] **2.6 `nox.http.clear_bind_address()`** (v2.2.1): `bind_address` artık geri alınabilir. Windows'ta IPv6 adres ayrı iş: 2.8.
- [ ] **2.8 (S) Windows'ta IPv6 dinleyici** (`bindAndListenV6` Windows'ta `null` döner; Winsock yolu `sockaddr_in6` işlemiyor): `bind_address="::1"` ve `ip_family` Windows'ta çalışmıyor. Windows PC ile doğrulanabilir. `[W]`
- [ ] **2.7 (S) `nox.dns` WASM:** bugün "desteklenmiyor" (durum 5). Tarayıcıda DoH (`fetch`) ile çözümleme düşünülebilir; YENİ bir `nox_host` içe aktarımı (host ABI'si; gömücüleri etkiler) gerektirir, bu yüzden bilinçli olarak ertelendi. `[K]`

## Aşama 3 — Redis / PostgreSQL / Windows

- [x] **3.1 Redis Cluster** (v2.2.2): `nox.redis_cluster` — CRC16 yuva (`{etiket}` dahil), yuva sahibine yönlendirme, `-MOVED` (tablo güncellenir) / `-ASK` (`ASKING` + komut) / bağlantı kopması (topoloji yenileme), tembel düğüm bağlantıları. Sınırlar: çok anahtarlı komutlar aynı yuvada olmalı, kopyalardan okuma/pub-sub yok. Test: gerçek 3 düğümlü küme (`scripts/redis_cluster_probe.py`; 12 anahtar için yuva sunucunun `CLUSTER KEYSLOT`ıyla çapraz, 200 anahtar 3 düğümde, MOVED kendini düzeltir, göç sırasında ASK; iki arka uç).
- [ ] **3.2 (S) Redis okuma zaman aşımı wasm'da yok** (host soketleri bloklar; zaman aşımı için yeni bir `nox_host` içe aktarımı gerekir, 2.7/3.9 ile aynı host ABI kararı). `[K]`
- [ ] **3.3 (S) Redis TLS: genel CA'lı yönetilen servis ve `rediss://` şeması** ile gerçek doğrulama: kodda eksik yok (doğrulama `nox.tls` ile aynı sistem CA deposunu kullanır); gerçek bir yönetilen Redis hesabı gerekir. `[K]`
- [x] **3.4 PostgreSQL mobil istemci zaman aşımı + iptal** (v2.2.2): saf Zig istemcisinde (iOS/Android yerel soketleri) `set_query_timeout`/`cancel()` çalışır — `BackendKeyData` saklanır, süre dolunca ayrı bağlantıdan `CancelRequest`, sunucunun `57014` yanıtı beklenir, bağlantı kullanılabilir kalır (10 sn payda yanıt gelmezse bağlantı kapanır). wasm ana makine soketlerinde etkisiz (host bloklar). Test: `zig build pg-mobile-test` gerçek PostgreSQL'e karşı (initdb/postgres yoksa atlanır): 400 ms zaman aşımı → 57014 + bağlantı yeniden kullanılır; başka iş parçacığından `cancel`.
- [x] **3.5 Taşınabilir kapanış olayı — Windows** (v2.2.2): `nox.signal` Windows konsol olaylarına eşlendi (`sigint()` 2 = Ctrl+C, `sigterm()` 15 = Ctrl+Break/kapatma/oturum kapatma/kapanış; `SetConsoleCtrlHandler`), `nox.http.serve*` aynı olaylarda zarif kapanır. Gerçek Windows'ta doğrulandı: `GenerateConsoleCtrlEvent(CTRL_BREAK)` → `wait(sigterm)` True; arka planda çalışan `serve` Ctrl+Break'te `serve returned`. WASM host iptali ve Windows HİZMET durdurma (SCM) AÇIK: ayrı madde 3.9 `[K]`.
- [x] **3.6 Windows: Pulse NOX-IO-001** — `write_raw` Windows'ta `supported=false` olduğundan HER ZAMAN `-1` dönüyordu (yönlendirme ile ilgisi yoktu). Düzeltildi v2.2.0-rc.2: Windows'ta CRT `_write`, wasm'da `wasm_host.write`/`write(1)`; gerçek Windows'ta dosya + boru byte-exact doğrulandı; golden `terminal_write_raw_redirected`.
- [x] **3.7 Windows: VAULT 1.5** — KÖK NEDEN: `nox.process.Command` çocuğu BOŞ ortamla başlatıyordu (paylaşılan `std.Io.Threaded` boş `Environ`); `noxc run` çocuğu `PATH`/`USERPROFILE`/`LOCALAPPDATA` göremeyip `zig`/`cc` bulamıyordu. POSIX'te de `HOME` boştu, `PATH` yalnızca varsayılandı; belge ise "ebeveynin ortamı miras alınır" diyordu. Düzeltildi v2.2.0-rc.2: çağıran iş parçacığında ortam anlık görüntüsü (`nox.os.set_var` dahil) çocuğa verilir; gerçek Windows'ta iç içe `noxc run` çalıştı; golden `process_child_inherits_env`.
- [ ] **3.9 (M) WASM host iptali + Windows hizmeti (SCM) için kapanış olayı:** WASM yeni bir `nox_host` içe aktarımı (host ABI; gömücüleri etkiler), Windows hizmeti `StartServiceCtrlDispatcher` ana işleviyle ilişkili tasarım ister. `[K]`
- [-] **3.8a Chronos NXL-006 (görev iptali beklemesiz hesaplamayı kesemez):** TASARIM GEREĞİ (kooperatif iptal; dokunulmaz). Sert iptal/yalıtım ilkeli ancak ayrı bir gelecek tasarımı (bkz. 6.2).
- [ ] **3.8b Chronos NXL-008 (modül görünürlüğü kamu API'sini zorlayamaz):** her üst düzey ad içe aktarılabilir; `_` öneki yalnızca gelenektir. Çözüm yeni bir dil özelliği (Python'daki `__all__` benzeri açık dışa aktarım listesi ya da `_` önekli adların paket dışına kapatılması); önerilen biçim ve kapsam kullanıcıyla konuşulmalı. `[K]`

## Aşama 4 — Dil

- [ ] **4.1 (S) İç içe `async def` için yönlendirici hata mesajı:** `a nested function definition CANNOT be 'async def'` yerine "modül düzeyine taşı, değerleri parametre olarak geçir". Risksiz.
- [ ] **4.2 (L) İç içe `async def` (değişmez yakalamalı).** Faz U.4.2 "v1 kesintisi", ilke değil. Güvenli ilk biçim: yalnızca `int/float/bool/str/None` yakalayan iç içe `async def`; heap nesnesi yakalayan "parametre olarak geçir" hatasıyla reddedilir. Neden temkinli: yakalanan `list/dict/sınıf` ARC ile paylaşılır ve `spawn` başka işçide çalışabilir; mevcut `SpawnSharedMutation` analizi yakalama yolunu görmüyor. İş: checker + closure codegen + spawn analizi + iki backend + wasm. `[K]`
- [ ] **4.3 (L) `list[Task[T]]`** (bilinçli desteklenmiyor, hata `TaskGroup`'a yönlendirir). Yalnızca tasarım kararıyla. `[K]`
- [ ] **4.4 (M) Yakalamada ARC dersleri için test genişletme:** `Channel/Task` yakalayan closure retain/release (v2.1.x'te bulunan aşırı serbest bırakma) iki backend + wasm32 taşma denetimiyle golden.

## Aşama 5 — Performans (2.2'den kalan yapısal açıklar)

- [ ] **5.1 (L) Sunucu için çok iş parçacıklı C ile adil kıyas + TLS/HTTP/2 sıcak yolu** (aşama 4/12'den). Worker ölçeği: macOS paylaşılan dinleyici v2.1.195; Linux'ta `SO_REUSEPORT` dağılımı aynı wrk şekliyle ölçülmeli (worker ölçek raporu madde 3).
- [ ] **5.2 (L) JSON `dump` ≈5×, gezinme ≈10× yyjson'un gerisinde** (düğüm kurma/atomik ARC; `putEscaped` taraması).
- [ ] **5.3 (L) Koleksiyon sınıf-alanı ARC'si ve `str` tahsis sayısı** (Set/Deque/Heap/Counter): C'ye göre kalan yapısal açıklar (`benchmarks/RESULTS.md`, nox/C geometrik ortalaması 2,05).
- [ ] **5.4 (L) M:N paylaşılan modül durumu kalan dilimler** (liste, sınıf; ad-üzerinden-kilit stratejisi): `project/faz9-kontrol-debug-analizi-2026-11.md`.
- [ ] **5.5 (M) WASM çok iş parçacıklı aşama 4:** Node `worker_threads`+`SharedArrayBuffer` farksal testi, ThreadSanitizer koşusu, `wasm32-wasi-threads` gerçek C testi. `[W]`
- [ ] **5.6 (S) WASM varsayılan kotaları çok-kiracılı kullanım için gevşek** (izleme): sıkı hazır ayar + capability sınırları.

## Aşama 6 — Büyük / uzun vadeli

- [ ] **6.1 (L) REPL — LLVM ORC JIT:** libLLVM'i çalışma anında tembel yükle, `noxrt.o`yu JIT'e ekle, satırlar arası durum modül-global + ARC. iOS'ta JIT yasak → masaüstü. Önce spike + tasarım onayı. `[K]`
- [ ] **6.2 (L) Preemption / fiber göçü:** başlamış fiber, başladığı işçiye bağlı; bloklayan FFI'da yalnızca başlamamış görevler kurtarılır. Kullanıcı "şimdilik gerekmez" dedi. `[K]`
- [ ] **6.3 (L) FFI "güvenli mod"/sandbox:** AGENTS §9.5; kapsamlı güvenlik tasarımı gerektirir, yarım eklenmez. `extern def` maliyeti zaten C ≈ 1,0×. `[K]`
- [ ] **6.4 (L) Mobil/Aura:** `project/aura-mobil-eksiklikleri.md` (fiziksel cihaz, 16 KiB sayfa, imzalı IPA/AAB). Ayrı depo, kendi planı.

## Dağıtım / kullanıcı eylemleri

- [ ] **D.1 Site arka ucunun sürüm seçimi düzeltmesini M4'e canlıya alma** (`services/noxlang-site/main.nox`): canlı dağıtım kullanıcı onayı ister. `[K]`
- [ ] **D.2 Temizlik:** PC'de WSL dağıtımı (`wsl --unregister nox-ubuntu`), `C:\nox-dev` (OpenSSL klasörleri), `noxdev` kullanıcısı; Mac scratchpad geçici dosyaları. `[K]`

## Bayat çıkanlar (yeniden açılmasın)

- `[-]` **Snap iş akışı "unable to contact snap store"** (eski A3/E1): v2.1.194/195/196'da `Snap package` yeşil.
- `[-]` **Windows CI duman testi `relocation truncated .rdata`** (eski A5): v2.1.194-195'te Windows işleri yeşil (tam `zig build test`, `.exe` çapraz derleme, Windows kurucu).
- `[-]` **Windows'ta fiber-uyumlu ağ G/Ç'si** (eski Ember NX-003): `fiber_net.enabled = net_dial.enabled`, Windows'ta v2.1.147'den beri açık (WSAPoll + `WindowsReactor`).
- `[-]` **`Release` iş akışı CI kırmızıyken yayın üretmiyor** (eski A2/7.7): tasarım gereği; eski sürümler yeniden yayınlanmaz (kullanıcı kararı 2026-11-14).
- `[-]` Pulse NOX-FMT-004, VAULT 2.3 (polimorfik liste literal + callback), VAULT 2.4 (Optional daraltma), Nova 15 (tembel iteratör: `yield`/`async for` 2.0'dan beri var), Nyx `except nox.http.HttpError` söz dizimi (2.1.195'te düzeldi).
- `[-]` Tasarım gereği sınırlar (dokunulmaz): kooperatif iptal, sabit 192 KiB fiber yığını, liste ataması kopyası, işçi başına modül durumu, QBE tek iş parçacığı.
