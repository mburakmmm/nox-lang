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

- [ ] **1.1 (M) `mobile` iş akışı: iOS simülatör ağ matrisi flaky.** Son koşular: v2.1.188 / v2.1.193 / v2.1.196 kırmızı, v2.1.187 / v2.1.190 yeşil; her seferinde FARKLI senaryo (`connect_blackhole` duvar 84 sn, `dns_dual_stack` duvar 32 sn) → macOS koşucusunun DNS/ağ yavaşlığı, kod hatası değil. Yapılacak: senaryo başına yeniden deneme + duvar süresi bütçesi, ya da DNS bağımlı senaryoları yerel çözümlemeye (`localhost`/hosts) çevirmek; `scripts/mobile_network_probe.sh`.
- [ ] **1.2 (S) GitHub Actions Node 20 uyarısı:** `actions/checkout@v4` vb. Node 24'e zorlanıyor; eylem sürümlerini güncelle (`.github/workflows/*.yml`).
- [ ] **1.3 (S) Çok çekirdekli dağılım testi Windows'ta atlanıyor** (`http_serve_multicore_golden_test.zig`: sinyal yok). `nox.http.shutdown()` ya da bütçeli sunucu + hata toleransıyla Windows'a taşı. `[W]`
- [x] **1.4 (S) Yerel ön kontrol betiği** `scripts/precheck.sh` (v2.2.0-rc.2; `release.sh`e henüz bağlı DEĞİL — bağlanacak) CI'ın docs işindeki TÜM denetimleri koşturur: `check_docs.py`, `check_global_state.py`, `check_doc_contracts.py`, `check_reserved_symbols.py` + `gen_reserved_symbol_fixture.py --check`, `check_wasm_http_stubs.py`, `gen_sbom.py --check`, `build_site.py --verify`. v2.1.195 ve rc.1'de bunlar atlandı ve CI kırıldı (`_toc.yml`, global-durum listesi, wasm ABI tablosu, belge sözleşmesinin ön sürüm sürümü, ayrılmış semboller). Ayrıca yeni `codegen_cases` fixture'ları `fixture_corpus.zig`ye KAYDEDİLMEZSE `zig build test`te çalışmaz (v2.1.195-196'daki 11 fixture rc.2'de kaydedildi): yeni `.nox` eklenince kayıt kontrolü otomatikleştirilmeli.
- [ ] **1.5 (S) Eski listelerdeki bayat kayıtları kapat:** `[-]` aşağıda "Bayat çıkanlar".
- [ ] **1.7 (S) `signal_install_take_wait` fixture'ı yük altında bir kez düştü** (`wait(s, 2000)` False; v2.2.0-rc.2 yerel koşusu, sonraki koşularda geçti): zamanlama bağımlı; kök neden araştırılmalı (yük altında `killer` görevi 2 sn içinde çalışmıyor mu?).
- [ ] **1.6 (S) `.git/refs/.DS_Store`** Finder artığı `git fsck` uyarısı veriyor; sil + `.gitignore` zaten dışlıyor (yalnızca yerel temizlik).

## Aşama 2 — Güvenli ağ API'si

- [ ] **2.1 (M) `nox.net.ip` — IP ayrıştırma + sınıflandırma** (Nova 14 madde 3): IPv4/IPv6 literal, özel/loopback/link-local/çok noktaya yayın/bulut metadata (`169.254.169.254`) sınıfları; Nova `ssrf.nox` ve VAULT `SystemDnsResolver` referans. Böylece `resolve → doğrula → connect_ip` döngüsü her paketin yeniden yazmasına gerek kalmadan tamamlanır. `[K]` (API biçimi)
- [ ] **2.2 (M) `nox.tls.connect` için IP sabitleme / ayrı SNI** (VAULT 1.1'in `nox.tls` yarısı; `nox.http` yarısı v2.1.195). `[K]`
- [ ] **2.3 (M) `nox.http.Pool`** — istemci başına bağlantı havuzu (Nova 17): bugün `client_pool(...)` süreç geneli. `pool.request(...)` / `request(..., pool=p)`; sabitlenmiş (`connect_ip`) ve `ca_file` istekleri havuzu atlıyor, `Pool` bunları da kapsamalı. `[K]`
- [ ] **2.4 (S) AEAD için bayt API'si:** `aead_seal/open` `str` (UTF-8) alır; ikili veri hex'lenmeli. `nox.bytes.Buffer` ile `aead_seal_bytes/open_bytes` + RFC vektörlerinde ikili AAD'li doğrulama.
- [ ] **2.5 (S) `connect_ip` + yönlendirme:** `request` yönlendirmeleri izlemiyor (çağıran yeniden çözer); tek adımda "yönlendirmeyi yeniden doğrula" yardımcısı (`follow_redirects_validated(...)`) düşün. `[K]`
- [ ] **2.6 (S) `configure(bind_address)` sıfırlama:** boş değer "ayarsız" sayıldığı için process içinde tüm arayüzlere geri dönülemiyor; `reset_bind_address()` ya da `None`. Windows'ta IPv6 adres desteği (`sockaddr_in6` yolu). `[W]`
- [ ] **2.7 (S) `nox.dns` WASM:** bugün "desteklenmiyor" (durum 5). Tarayıcıda DoH (`fetch`) ile çözümleme düşünülebilir; host köprüsü gerekir. `[K]`

## Aşama 3 — Redis / PostgreSQL / Windows

- [ ] **3.1 (L) Redis Cluster** (Ember NX-002): slot keşfi, `MOVED`/`ASK`, topoloji tazeleme, aynı-slot doğrulaması, gerçek çok düğümlü test. Pipeline ve okuma zaman aşımı v2.1.195'te bitti. `[K]`
- [ ] **3.2 (S) Redis okuma zaman aşımı wasm'da yok** (host soketleri bloklar); WebSocket-TCP köprüsünde köprü tarafında zaman aşımı.
- [ ] **3.3 (S) Redis TLS: genel CA'lı yönetilen servis ve `rediss://` şeması** ile gerçek doğrulama.
- [ ] **3.4 (M) PostgreSQL mobil/WASM istemci zaman aşımı + iptal** (Ember NX-005): bloklamayan protokol G/Ç'si, gerçek okuma süresi sınırı, çalışan sorgu iptali; gerçek emulator/WASM host testi.
- [ ] **3.5 (M) Taşınabilir kapanış olayı** (Ember NX-004): `nox.signal.install` Windows/WASM/freestanding'de `False` döner. Windows console/servis durdurma + WASM host iptali için tek bir soyutlama; drain/zaman aşımı testi. `[K]` `[W]`
- [x] **3.6 Windows: Pulse NOX-IO-001** — `write_raw` Windows'ta `supported=false` olduğundan HER ZAMAN `-1` dönüyordu (yönlendirme ile ilgisi yoktu). Düzeltildi v2.2.0-rc.2: Windows'ta CRT `_write`, wasm'da `wasm_host.write`/`write(1)`; gerçek Windows'ta dosya + boru byte-exact doğrulandı; golden `terminal_write_raw_redirected`.
- [x] **3.7 Windows: VAULT 1.5** — KÖK NEDEN: `nox.process.Command` çocuğu BOŞ ortamla başlatıyordu (paylaşılan `std.Io.Threaded` boş `Environ`); `noxc run` çocuğu `PATH`/`USERPROFILE`/`LOCALAPPDATA` göremeyip `zig`/`cc` bulamıyordu. POSIX'te de `HOME` boştu, `PATH` yalnızca varsayılandı; belge ise "ebeveynin ortamı miras alınır" diyordu. Düzeltildi v2.2.0-rc.2: çağıran iş parçacığında ortam anlık görüntüsü (`nox.os.set_var` dahil) çocuğa verilir; gerçek Windows'ta iç içe `noxc run` çalıştı; golden `process_child_inherits_env`.
- [ ] **3.8 (S) Chronos NXL-006/008:** görünürlük/dışa aktarım listesi ve yetenek kapsamı. Tasarım kararı. `[K]`

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
