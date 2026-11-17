# Nox 2.3 yapılacaklar listesi (2.2.0-rc.1 ile açıldı, 2026-11-17)

Kaynak: 2.2 öncesi limitasyon turu (VAULT, Pulse, Ember, Chronos, Nova, Aether, Nyx raporları + worker ölçek raporu) ve eski listelerde (`acik-isler-2026-11-14.md`, `yapilacaklar-2026-11.md`) açık kalanlar. Bu dosya yalnızca **açık** işleri tutar; bir iş bitince kutu `[x]` yapılır ve sürümü yazılır.

Durum: `[ ]` açık · `[K]` kullanıcı kararı/eylemi gerekir · `[W]` Windows PC gerekir · `[?]` kayıtta açık görünüyor, önce doğrulanmalı.
Kural (AGENTS §16): yeni dil özelliği / API biçimi / bellek modeli etkisi olan maddeler `[K]` ile başlar, önce sorulur. Tasarım gereği sınırlara dokunulmaz (kooperatif iptal, sabit 192 KiB fiber yığını, liste ataması kopyası, işçi başına modül durumu, QBE tek iş parçacığı).

## A. Dil

- [ ] **A1. İç içe `async def`.** Bugün `a nested function definition CANNOT be 'async def'` (Faz U.4.2 "v1 kesintisi", ilke değil). Güvenli ilk biçim: yalnızca **değişmez yakalamalı** (`int/float/bool/str/None`) iç içe `async def`; heap nesnesi yakalayan, "parametre olarak geçir" hatasıyla reddedilir. Neden temkinli: yakalanan `list/dict/sınıf` ARC ile paylaşılır ve `spawn` başka işçide çalışabilir; mevcut `SpawnSharedMutation` analizi yakalama yolunu görmüyor. İş: checker + closure codegen + spawn analizi + iki backend + wasm. `[K]` Önce küçük iş: hata mesajını "modül düzeyine taşı, değerleri parametre geç" diye yönlendirmek.
- [ ] **A2. `list[Task[T]]`** (bilinçli desteklenmiyor, hata `TaskGroup`'a yönlendirir). Yalnızca tasarım kararıyla. `[K]`
- [ ] **A3. REPL — LLVM ORC JIT** (eski C1). Önce spike + tasarım onayı; iOS'ta JIT yasak → masaüstü. `[K]`
- [ ] **A4. Preemption / fiber göçü** (eski B8/C6): başlamış fiber, başladığı işçiye bağlı; bloklayan FFI'da yalnızca başlamamış görevler kurtarılır. Kullanıcı "şimdilik gerekmez" dedi. `[K]`

## B. `nox.http` / ağ

- [ ] **B1. Bağlantı havuzu nesnesi `nox.http.Pool`** (Nova 17): bugün `client_pool(...)` süreç geneli; per-client havuz için `pool.request(...)` / `request(..., pool=p)`. API tasarımı gerekir. `[K]`
- [ ] **B2. IP sınıflandırma yardımcıları `nox.net.ip`** (Nova 14 madde 3): IPv4/IPv6 ayrıştırma + özel/loopback/link-local/metadata sınıflandırması; Nova `ssrf.nox` referans. `nox.dns.resolve` + `connect_ip` (2.1.195) bu işin temelini attı. `[K]`
- [ ] **B3. `nox.tls.connect` için IP sabitleme / ayrı SNI** (VAULT 1.1'in `nox.tls` yarısı): `nox.http` yarısı v2.1.195'te bitti.
- [ ] **B4. Redis Cluster** (Ember NX-002): slot keşfi, `MOVED`/`ASK`, topoloji tazeleme, gerçek çok düğümlü test. Pipeline v2.1.195'te bitti. `[K]`
- [ ] **B5. Redis TLS: genel CA'lı yönetilen servis ve `rediss://` şeması** ile gerçek doğrulama (`ca_file` yolu v2.1.39-195'te doğrulandı).
- [ ] **B6. PostgreSQL mobil/WASM istemci zaman aşımı ve iptal** (Ember NX-005): bloklamayan protokol G/Ç'si, gerçek okuma süresi sınırı, çalışan sorgu iptali; gerçek emulator/WASM host testi.
- [ ] **B7. Taşınabilir kapanış olayı** (Ember NX-004): `nox.signal.install` Windows/WASM/freestanding'de `False` döner. Windows console/servis durdurma + WASM host iptali için tek bir taşınabilir soyutlama; drain/zaman aşımı testi. `[K]`
- [ ] **B8. Fiber-uyumlu ağ G/Ç'si Windows'ta** (Ember NX-003): POSIX'te var; Windows'ta HTTP/2 + HTTP istemci + TLS ayrı iş. **v2.1.147'de büyük kısmı bitti** (Nyx notu): önce `[?]` doğrula, kalan farkı yaz. `[W]`

## C. Platform / Windows

- [ ] **C1. Pulse NOX-IO-001: terminal `write_raw` yönlendirilmiş çıktıda** (Windows). `[W]`
- [ ] **C2. VAULT 1.5: derlenmiş `.nox` ikilisinden iç içe `noxc run` → `FileNotFound` (Windows).** `Command("noxc").arg("run")` başarısız, `--version`/`check` çalışıyor: PATH/çalışma dizini/`noxc run` önbellek yolu araştırılmalı. `[W]`
- [ ] **C3. A5 Windows CI duman testi:** GNU ld `relocation truncated ... against .rdata` (Debug `noxrt.o`, `noxc run --backend qbe`). Kayıt: `acik-isler-2026-11-14.md` A5. `[W]`
- [ ] **C4. Chronos NXL-006/008:** görünürlük/dışa aktarım listesi ve yetenek (capability) kapsamı. Tasarım kararı. `[K]`

## D. Çalışma zamanı / performans

- [ ] **D1. Sunucu için çok iş parçacıklı C ile adil kıyas + TLS/HTTP/2 sıcak yolu** (2.2 aşama 4/12'den açık kalan).
- [ ] **D2. JSON `dump` ≈5×, gezinme ≈10× yyjson'un gerisinde** (düğüm kurma/atomik ARC; `putEscaped` taraması) (aşama 3/12'den).
- [ ] **D3. Koleksiyon sınıf-alanı ARC'si ve `str` tahsis sayısı** (Set/Deque/Heap/Counter, str tahsisi): C'ye göre kalan yapısal açıklar (`benchmarks/RESULTS.md`).
- [ ] **D4. M:N paylaşılan modül durumu:** kalan dilimler (liste, sınıf; ad-üzerinden-kilit stratejisi) — `project/faz9-kontrol-debug-analizi-2026-11.md`.
- [ ] **D5. WASM çok iş parçacıklı, aşama 4** (eski B6): Node `worker_threads`+`SharedArrayBuffer` farksal testi, ThreadSanitizer koşusu, Windows PC doğrulaması, `wasm32-wasi-threads` gerçek C testi. `[W]`
- [ ] **D6. WASM varsayılan kotaları çok-kiracılı kullanım için gevşek** (eski B7/9.15; izleme): sıkı hazır ayar + capability sınırları.
- [ ] **D7. FFI maliyetini sıfıra yaklaştır** (eski C2): 2.2'de ölçüldü (`extern def` ≈ C 1,0×); tasarım seçenekleri açık. AGENTS §9.5: sandbox/"güvenli mod" yarım eklenmez. `[K]`

## E. Dağıtım / altyapı

- [ ] **E1. `Snap package` iş akışı "unable to contact snap store"** (eski A3/7.6): Snap Store kimlik bilgisi/ağ kullanıcıda. `[K]`
- [ ] **E2. Site arka ucunun sürüm seçimi düzeltmesini M4'e canlıya alma** (eski A4/7.1): canlı dağıtım kullanıcı onayı ister. `[K]`
- [ ] **E3. Mobil/Aura:** `project/aura-mobil-eksiklikleri.md` (fiziksel cihaz, 16 KiB sayfa, imzalı IPA/AAB). Ayrı depo, kendi planı.
- [ ] **E4. Temizlik:** PC'de WSL dağıtımı/`C:\nox-dev`/OpenSSL klasörleri/`noxdev` kullanıcısı; Mac scratchpad geçici dosyaları. `[K]`

## Bu turda bayat çıkanlar (yeniden açılmasın)

Pulse NOX-FMT-004, VAULT 2.3 (polimorfik liste literal + callback), VAULT 2.4 (Optional daraltma), Nova 15 (tembel iteratör/üreteç: `yield`/`async for` 2.0'dan beri var), Nyx `except nox.http.HttpError` söz dizimi (2.1.195'te düzeldi).
