# Ajan rehberi: bayat, tasarım gereği ve yapılmamış limitasyonlar

Bu dosya `project/limitasyon-kaydi-2026-11.md` kaydını tamamlar. Kayıt "ne kapandı" der; bu rehber **ajanın neye dokunmaması, neyi sormadan yapmaması ve neyi yeniden doğrulaması gerektiğini** açıklar. Güncel durum: `v2.1.28`.

Kısa kurallar:

1. Aşağıdaki **D grubu** (bayat / tasarım gereği) için kod değiştirme. Kullanıcı bir davranışı değiştirmeyi açıkça istemedikçe iş yoktur; belge notu yeterlidir.
2. **E grubu** (yapılmamış) maddelerin çoğu AGENTS.md §16 gereği mimari karar ister. Sormadan başlama.
3. Bir maddeyi "açık" diye kaydetmeden önce `noxc` ile **bugünkü derlemede yeniden üret**. Kayıttaki satırlar `v2.1.1` anına aittir; birçoğu sonradan kapandı (aşağıda "Sonradan değişti" sütunları).
4. Varsayılan backend LLVM'dir. QBE'ye özgü sınırlar (D3) QBE'de kalır; bir davranışı "düzeltmek" için QBE'yi LLVM'e eşitlemeye çalışma.
5. Kapatılan her madde: iki backend'de doğrula, golden test ekle, CHANGELOG + spesifikasyon + kayıt güncelle, patch sürümü etiketle (AGENTS.md ve `feedback_tag_every_commit`).

---

## D. Bayat ya da tasarım gereği (iş yok)

### D1. Dil tasarımı kararları

| Madde | Ne diyor | Neden iş yok | Ajan ne yapmalı |
|---|---|---|---|
| aether 4 / nyx 2.6 | `b = a` liste ataması bağımsız kopya (`b.append` `a`yı büyütmez) | Değer semantiği: Nox'ta liste ataması kopyadır, referans paylaşımı yoktur | Davranışı değiştirme. Kullanıcıya "referans gibi paylaşılsın" önerme; paylaşım gerekiyorsa sınıf alanı ya da `AtomicRef` kullan. Belge notu zaten var. |
| aura L6 | `isinstance` ve `weakref` yok | `docs/language/classes.md`: "çalışma zamanı tip testi yok" tasarım kararı. Tip ayrımı protokol, sanal metot veya `type_id` ile yapılır | `isinstance` ekleme. Protokol artık değer tipi (`Navigates | None` çalışır), `match` + `enum` de var (v2.1.21): ayrım gerekiyorsa enum/protokol öner. |
| nova 1-7, nyx bölüm 1/5 | Çerçeve notları | Kapanmış, yeniden üretilmiyor | Yok. |

### D2. Pulse'un belgelenmiş tasarım sınırları

Kaynak: pulse deposunun `NOX_LIMITATIONS` belgesi (`DESIGN-LIMIT`). Hepsi "Nox bunu böyle yapar, çağıran davranışı buna göre kurar" anlamındadır. **Sonradan değişenler işaretli.**

| Kod | Sınır | Durum bugün |
|---|---|---|
| FIBER-001 | Fiber yığını sabit 192 KiB (`runtime/async_rt/fiber.zig` `STACK_SIZE`); derin özyinelemeli kodlayıcı/ayrıştırıcı taşarsa süreç sonlanır | **Geçerli.** Kod özyineleme yerine döngü kullanmalı ve derinlik sınırı koymalı. `STACK_SIZE` küçültülmez (bkz. bellek: fiber-stack sertleştirmesi). |
| HTTP-001 | HTTP istemcisi HTTP/1.1; yalnız GET/POST/PUT/PATCH/DELETE/HEAD/OPTIONS; gövde yalnız POST/PUT/PATCH; `timeout_ms=0` DNS/bağlanmayı sınırsız bırakır; akışsız çağrı tüm gövdeyi tamponlar | **Geçerli.** Akışlı okuma sonradan eklendi (Faz 8), ama yöntem kümesi değişmedi. |
| HTTP-002 | HTTP/2 yalnız sunucu tarafında; istemci HTTP/1.1; gRPC taşıması değil | **Kısmen bayat:** `nox.grpc` (v2.1.33) HTTP/2 `h2c` istemcisi sağlar; `nox.http` istemcisi hâlâ HTTP/1.1. |
| FS-001 | Dosya yolları sınırlanmaz (mutlak yol, `..`, symlink doğrudan işletim sistemine gider) | **Geçerli ve AGENTS.md §9.5'te güven sınırı olarak belgeli.** Güvenilmeyen `path`i çağıran taraf kanonikleştirmelidir; `nox.fs` bunu otomatik yapmaz. "Kolaylık" olarak sandbox ekleme. |
| STR-001 | `char_from_byte(0)` boş dize döner | **Bayat:** v2.1.30'da düzeltildi (tek NUL baytlı `str`). |
| TASKLOCAL-002 | Doğan görev ebeveynin `TaskLocal` değerini miras almaz; bağlamı açıkça geçir | **Geçerli, tasarım.** Otomatik miras ekleme. |
| TASKLOCAL-003 | `TaskLocal[T]` içinde çıplak `int`/`float`/`bool` saklanamaz | **Geçerli.** Sınıf/`str`/`list`/`dict` kullan. |
| QBE-001 / QBE-002 | QBE zamanlayıcısı kooperatif, paralel değil; QBE `spawn`/`thread` aktarımı LLVM'den dar | **Geçerli.** Bkz. D3. |
| MODULE-001 | Çok çekirdekli LLVM'de değişebilir modül durumu worker başına kopyadır | **Kısmen yumuşadı:** `serve_multicore` işleyici fabrikası (v2.1.20) ve `AtomicRef` (v2.1.20) eklendi. Modül düzeyi değişkenin süreç-geneli olmaması **hâlâ tasarım**; paylaşım için kanal, veritabanı, `nox.sharedmem` ya da `AtomicRef`. |
| CLOCK-001 | Saatler milisaniye çözünürlüklü | **Bayat:** `now_ns`, `monotonic_ns` v2.1.13'te geldi. |
| JSON-001 | JSON sayıları binary64; 2^53 üstü bozulur | **Bayat:** `as_int`, `number_text`, `dump` tam metni korur (v2.1.7). |
| TYPE-001 | Etiketli birlik / `enum` yok | **Bayat:** `enum` + `match/case` v2.1.21'den beri var (jenerik v2.1.24, iç içe/literal/koruma v2.1.25). |
| (CAP) protobuf | Genel protobuf kodlayıcısı yok | **Bayat:** `nox.protobuf` tel formatı v2.1.18. |

### D3. QBE ile LLVM arasında bilinen farklar (bunları "hata" diye düzeltme)

- LLVM varsayılandır; QBE `--backend qbe` ya da freestanding / `--emit-asm` / `-g` / Windows / `clang` yoksa devreye girer (AGENTS.md §3).
- QBE'de `spawn` yalnız skaler/`str`/`Task`/`Channel`/`ThreadChannel` paketler; LLVM `list`/`class`/`dict` de taşır. Bu farkı aşmak için `spawn` mesajı derleme zamanında anlamlı bir hata verir; bu beklenen davranıştır.
- Tamsayı taşması ve `spawn` davranış farkları `project_default_backend_llvm_v1_143` belleğinde kayıtlı.
- Her codegen değişikliği **iki backend'de** doğrulanır; fixture korpusu ikisini de çalıştırır.

---

## E. Yapılmamış ya da kısmen yapılmış maddeler

Her satır: durum, neden bekliyor, ajanın ilk adımı.

### E1. A13 — aura L7 (KAPANDI v2.1.30)

Kök neden: `return _global` retain etmiyordu; çağıran sonucu kendi sahipliği sanıp bırakınca global'in tek referansı sıfırlanıyor, `nox_deinit_globals` ikinci kez serbest bırakıyordu. Düzeltme: `returnNeedsRetain` (ownership.zig). Golden: `module_global_returned_borrowed`. Kayıttaki "Aura'ya özgü olabilir" varsayımı yanlıştı; ders: modül globalleri de parametre/alan gibi **ödünç referanstır** ve dönüşte retain ister.

### E2. C12 — gRPC (KAPANDI v2.1.33, kısmen)

`nox.grpc`: HTTP/2 `h2c` istemcisi (`runtime/stdlib_shims/grpc.zig`, HPACK/kare yardımcıları `http2.zig`'den), unary + sunucu/istemci akışı (mesajlar toplanır), üst veri, trailer, akış denetimi. Gerçek `grpcio` sunucusuna karşı `scripts/grpc_probe.py` (iki arka uç).

**TLS (v2.1.35):** `connect_tls` — vendor `tls_client.zig`ye ALPN `h2` yaması (üçüncü NOX PATCH; dosya Zig kurulumundan salt-okunur kopyalanmıştı, `chmod u+w` gerekti) ve `tcp_native.startTlsEx` (ALPN + `ca_file`). **Hâlâ açık:** (1) **mTLS** (istemci sertifikası) ve wasm'da TLS. (2) Çift yönlü akışta istek/yanıt araya girmesi (şimdi: önce istekler gider, sonra yanıtlar toplanır). (3) `grpc-encoding: gzip` sıkıştırması (`gzip.zig` hazır). (4) Sunucu tarafı gRPC (trailer desteği `respstream_trailers` ile var; çerçeve ve iletim biçimi yazılmadı). Kullanıcı istemedikçe sunucu tarafına girme.

### E3. IPv6 çok çekirdekli dinleme (KAPANDI v2.1.32)

`nox.http.configure(ip_family=1|2)`: her `serve_multicore*` worker'ı kendi `SO_REUSEPORT` IPv6 soketini açar (`bindAndListenMulticore`). Windows'ta yok sayılır (Winsock yolu `sockaddr_in6` işlemiyor ve CI'da doğrulanamıyor). Test: `scripts/http_ipv6_probe.py` (iki arka uç × dual-stack/yalnızca-IPv6).

### E4. `list`/`dict` paylaşımı worker'lar arasında

- **Durum:** Kapsam dışı (kullanıcı kararı: worker başına kopya + fabrika + `AtomicRef`).
- **Ajan:** Paylaşımlı değişebilir `list`/`dict` ekleme; bu ARC atomikliği (Faz X.3 kategorisi) ve bellek modeli kararıdır.

### E5. Sınıf/metot dekoratörlerinin işleyici olması

- **Durum:** Kapsam dışı (kullanıcı kararı, 2026-11-10). Yalnız **üst-düzey** fonksiyon dekoratörleri işleyici kaydeder (`router_from_decorators`/`decorator_handler`).

### E6. Çıplak `list[Task[T]]`

- **Durum:** Hâlâ yazılamaz (codegen `Unsupported`); `nox.tasks.TaskGroup[T]` (v2.1.10) tutamak sınıfı kullanır.
- **Ajan:** Çözüm olarak `TaskGroup` öner. Gerçek `list[Task[T]]` desteği ARC/yıkım semantiğini etkiler; ayrı tasarım gerektirir.

### E7. `Channel` zaman aşımı (KAPANDI v2.1.34)

`ch.wait(ms) -> bool` (bir `recv` bloklamadan dönebilecek mi; tüketmez) — `Task.wait` ile aynı kooperatif yoklama (`runtime/stdlib_shims/task_wait.zig` `nox_channel_wait`, `bridge*.zig` `nox_channel_ready`). Zaman aşımlı `recv` doğrudan **yok**: `wait` + `await recv` ikilisi; birden çok alıcıda `wait` ile `recv` arasında değer başkasına gidebilir (belgeli).

### E8. `match` / enum açık kenarları

- Kapsamlılık artık **iç içe desenleri** de analiz eder (v2.1.31, desen matrisi); yalnızca korumalı ve literal kollar varyantı kapsamaz (bilinçli, koşul çalışma zamanında değerlendirilir).
- `match` bağlamaları üreteç (`yield`) fonksiyonlarında kullanılamaz.
- Koruma ifadesinde lambda, comprehension ve sözlük sabiti desteklenmez.
- Yeni `StmtKind` **eklenmedi** (≈25 dosya, 90+ yürüyücü); `match` mevcut `IfStmt` zincirine indirgenir. Bunu bozacak değişiklik büyük refaktördür, sormadan yapma.

### E9. Redis TLS gerçek sertifikayla denenmedi

- **Durum:** `nox.redis` TLS (v2.1.9) başarılı el sıkışması **güvenilir sertifikalı** bir Redis'e karşı doğrulanmadı.
- **İlk adım:** Elinde güvenilir sertifikalı bir Redis (örn. yönetilen servis) varsa bir kez dene; yoksa "denenmedi" notunu kaldırma.

### E10. Platform açıkları

- **Windows `nox.terminal`:** denetim yok, `TerminalError` döner (C8).
- **Android API 26 çökmesi:** açık (bkz. `project_limitation_round_2026_11_10`); cihaz/emülatör gerektirir.
- **Windows CI zaman aşımı:** v2.1.19 `wasm_frontend_test`, v2.1.23 ve v2.1.31 `codegen_golden_test` "TÜM golden fixture'lar" 300 sn'yi aştı. v2.1.36'da `-Dwin-test-timeout=900`. Bu test tek parçadır ve korpusla büyür: 900 sn'yi de aşarsa fixture'ları birkaç teste bölmek (kalıcı çözüm) gerekir.
- **aarch64 stack-smash:** KAPANDI (2026-10-08); "çözüldü" kabul et, yeniden açma.

---

## Karar prosedürü (özet)

| Durum | Yap |
|---|---|
| D grubu maddesi için "düzeltme" fikri | Yapma; kullanıcıya gerekçeyle sor |
| E1 (A13) | Önce yeniden üret, sonra karar ver |
| E2/E3/E4/E6/E7 gibi mimari etkisi olan | Tasarım notu yaz, kullanıcıya özetle, sonra uygula |
| Küçük, geri alınabilir düzeltme | Makul varsayımla ilerle (AGENTS.md §16.2) |
| Bir madde bayat çıktı | Kaydı `[-]` yap, bu rehberin D2 tablosuna sürümüyle ekle |

İlgili dosyalar: `project/limitasyon-kaydi-2026-11.md`, `project/v2-hazirlik-yol-haritasi.md`, `AGENTS.md` §2, §9.5, §16, `nox-teknik-spesifikasyon.md` §3.381-3.393.
