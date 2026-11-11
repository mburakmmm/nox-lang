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

**TLS (v2.1.35):** `connect_tls` — vendor `tls_client.zig`ye ALPN `h2` yaması (üçüncü NOX PATCH; dosya Zig kurulumundan salt-okunur kopyalanmıştı, `chmod u+w` gerekti) ve `tcp_native.startTlsEx` (ALPN + `ca_file`). **mTLS (v2.1.40/42):** `cert_file`/`key_file` (ECDSA P-256/P-384, Ed25519, RSA-PSS; parolasız PEM). wasm'da gRPC TLS v2.1.43'te eklendi (Node konağı). Tarayıcıda ham TCP v2.1.46'da `compiler/wasm_tcp_bridge.mjs` + `browserTcp` ile eklendi (köprüde TLS sonlanır, izin listesi zorunlu). **Hâlâ açık:** `nox.redis` wasm'da v2.1.45'te bağlandı (host TCP/TLS, gerçek redis-server testi). (2) ~~Çift yönlü akış~~ v2.1.38'de `Client.open_stream`/`Stream` ile KAPANDI. (3) ~~`grpc-encoding: gzip`~~ istemcide v2.1.39, sunucuda v2.1.44. (4) ~~Sunucu tarafı gRPC~~ v2.1.41'de `nox.grpc_server`, gerçek çift yönlü akış v2.1.43'te KAPANDI (`StreamMethod`/`Call`; HTTP/2 sunucusu gRPC isteklerini gövde bitmeden handler'a verir). v2.1.44: `Call.header/timeout_ms/set_header/set_trailer/use_compression`, `CtxMethod`, `dispatch_full` (süre sınırı zorlanır, yanıt gzip'lenir) KAPANDI; ayrıca `nox.gzip` sıkıştırmasının fiber içinde SIGBUS vermesi düzeltildi (iş büyük yığınlı iş parçacığında). Hâlâ: süre sınırı kooperatif (recv/send çağırmayan döngü kesilmez), Windows'ta HTTP/2 sunucusu yok.

### E3. IPv6 çok çekirdekli dinleme (KAPANDI v2.1.32)

`nox.http.configure(ip_family=1|2)`: her `serve_multicore*` worker'ı kendi `SO_REUSEPORT` IPv6 soketini açar (`bindAndListenMulticore`). Windows'ta yok sayılır (Winsock yolu `sockaddr_in6` işlemiyor ve CI'da doğrulanamıyor). Test: `scripts/http_ipv6_probe.py` (iki arka uç × dual-stack/yalnızca-IPv6).

### E4. `list`/`dict` paylaşımı worker'lar arasında

- **Durum:** Kapsam dışı (kullanıcı kararı: worker başına kopya + fabrika + `AtomicRef`).
- **Ajan:** Paylaşımlı değişebilir `list`/`dict` ekleme; bu ARC atomikliği (Faz X.3 kategorisi) ve bellek modeli kararıdır.

### E5. Sınıf/metot dekoratörlerinin işleyici olması

- **Durum:** Kapsam dışı (kullanıcı kararı, 2026-11-10). Yalnız **üst-düzey** fonksiyon dekoratörleri işleyici kaydeder (`router_from_decorators`/`decorator_handler`).

### E6. Çıplak `list[Task[T]]` (KARARLI OLARAK YAPILMADI, v2.1.38)

Karar: gerçek destek verilmez. Liste eleman bilgisi (`ElemHeapInfo`) ~230 yerde, 16 dosyada kullanılıyor; Task yaşam döngüsü ARC dışı (`retainNonArcValue`/`destroyNonArcValue`) olduğundan her liste yolu (append, indeks, for, pop, kopya, döngü çözücü izleme) için ayrı doğrulama gerekir. İhtiyaç `nox.tasks.TaskGroup[T]` ile karşılanıyor (`add`, `finished`, `wait_all`, `wait_below`, `cancel_all`, sonuçlar için `handles()`). Yapılan: `list[Task|Channel|ThreadHandle|ThreadChannel|TaskLocal]` artık codegen'in anlaşılmaz hatası yerine yönlendiren bir TİP hatası verir (`checker.typeExprToType`). Gerçek destek istenirse tasarım: `set[T]` gibi derleyici-içi `list[__nox_TaskBox[T]]` indirgemesi (sınıf kutusu; append/indeks/for/len/pop yeniden yazımları).

### E7. `Channel` zaman aşımı (KAPANDI v2.1.34)

`ch.wait(ms) -> bool` (bir `recv` bloklamadan dönebilecek mi; tüketmez) — `Task.wait` ile aynı kooperatif yoklama (`runtime/stdlib_shims/task_wait.zig` `nox_channel_wait`, `bridge*.zig` `nox_channel_ready`). Zaman aşımlı `recv` doğrudan **yok**: `wait` + `await recv` ikilisi; birden çok alıcıda `wait` ile `recv` arasında değer başkasına gidebilir (belgeli).

### E8. `match` / enum açık kenarları

- Kapsamlılık artık **iç içe desenleri** de analiz eder (v2.1.31, desen matrisi); yalnızca korumalı ve literal kollar varyantı kapsamaz (bilinçli, koşul çalışma zamanında değerlendirilir).
- `match` bağlamaları üreteç (`yield`) fonksiyonlarında kullanılamaz.
- Koruma ifadesinde lambda, comprehension ve sözlük sabiti desteklenmez.
- Yeni `StmtKind` **eklenmedi** (≈25 dosya, 90+ yürüyücü); `match` mevcut `IfStmt` zincirine indirgenir. Bunu bozacak değişiklik büyük refaktördür, sormadan yapma.

### E9. Redis TLS (v2.1.39: büyük ölçüde doğrulandı)

`connect(..., tls=True, ca_file=...)` gerçek bir TLS `redis-server`'a karşı çalışır, kendinden imzalı sertifika `ca_file` olmadan reddedilir (`scripts/redis_probe.py`). Hâlâ denenmeyen: genel CA'lı (Let's Encrypt vb.) yönetilen bir servis ve `rediss://` şeması; sistem CA deposu yolu `nox.tls` ile aynı olduğundan düşük risk. Aynı turda TLS 1.3 oturum bileti kaydının `readSome`da "read failed" ürettiği kök hata (postgres/mysql TLS'ini de etkiliyordu) düzeltildi.

### E10. Platform açıkları

- **Windows `nox.terminal`:** denetim yok, `TerminalError` döner (C8).
- **Windows'ta fiber içi kooperatif UYKU** v2.1.39'da eklendi (`fiber_net.sleepCooperativeWindows`, `WSAPoll` + loopback soket çifti); `Task.wait`, `Channel.wait`, `TaskGroup`, `sleep_ms` goldenları Windows'ta çalışır. **Hâlâ yok:** fiber-uyumlu AĞ G/Ç'si (`fiber_net.enabled == false`: Windows'ta `std.Io` net vtable yaması, HTTP/2 sunucusu uyandırma borusu, proxy). `signal_install_take_wait` ve `http_request_body_on_get_rejected` goldenları Windows'ta `skip_windows` ile atlanır (Windows'ta sinyal/refused-bağlantı davranışı farklı).
- **Android:** en düşük API 29 (v2.1.39, kullanıcı kararı); API 26'daki ikincil iş parçacığı SEGV'si (ELF TLS yok) bu kararla kapandı, API 24-28 desteklenmez.
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

### Freestanding kapsam analizi (2026-11-11)

Tam ölçüm ve açık kusur listesi (F1–F8): `project/freestanding-kapsam-analizi-2026-11.md`; araç: `scripts/freestanding_survey.py`. Bir freestanding "düzeltmesi"ne başlamadan önce oraya bak (özellikle F2: liste 128 elemanı aşınca sessiz bozulma, kök neden henüz bilinmiyor).
