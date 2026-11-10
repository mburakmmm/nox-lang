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
| HTTP-002 | HTTP/2 yalnız sunucu tarafında; istemci HTTP/1.1; gRPC taşıması değil | **Geçerli.** gRPC için E2'ye bak. |
| FS-001 | Dosya yolları sınırlanmaz (mutlak yol, `..`, symlink doğrudan işletim sistemine gider) | **Geçerli ve AGENTS.md §9.5'te güven sınırı olarak belgeli.** Güvenilmeyen `path`i çağıran taraf kanonikleştirmelidir; `nox.fs` bunu otomatik yapmaz. "Kolaylık" olarak sandbox ekleme. |
| STR-001 | `char_from_byte(0)` boş dize döner | **Doğrulanmadı bu turda.** `chr(0)` ya da ara bellek dönüşümü kullan; düzeltme istenirse önce yeniden üret. |
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

### E1. A13 — aura L7: modül düzeyi `str` atamasında çıkışta `nox_rc_pool_drain` çökmesi

- **Durum:** Açık, kanıtlanmamış. Bağımsız küçük repro yok; belirti yalnız aura içinde görülmüştü.
- **Bağlam:** İlgili A6 (döngüde `dict[str, Node]` çıkış askısı) v2.1.2'de çözüldü; A15 (v2.1.16) çıkışta global yıkım sırasını düzeltti (`nox_deinit_globals` artık `nox_async_deinit`ten önce). L7 bunlardan sonra kendiliğinden kapanmış olabilir.
- **İlk adım:** `~/Documents/aura` içinde self-check'i (`files` testi, `_roots[0]` yamasını geri alıp) güncel `noxc` ile yeniden çalıştır. Çökme yoksa kaydı `[x] bayat` yap. Çökme sürerse stack iziyle küçük repro çıkar, sonra ayrı hata olarak aç.

### E2. C12 — gRPC (karar bekliyor)

- **Durum:** `[~]`. Protobuf (v2.1.18), UDP, saat, bytes köprüleri bitti; gRPC yok.
- **Neden bekliyor:** HTTP/2 **istemcisi** ve HTTP **trailer** desteği mimari karardır (§16): sunucu H2'si var, istemci yok; gRPC durum bilgisi trailer'da gelir.
- **Kullanıcı yetkisi:** Kullanıcı "sen karar ver, hepsini yapalım" dedi. Yine de bu, yeni bir ağ protokolü katmanıdır; **tasarım notunu yazıp (`project/` altında) kullanıcıya özetle, sonra uygula.**
- **Önerilen kapsam (sade başlangıç):** (1) HTTP/2 istemci çerçeveleme (yalnız TLS/ALPN `h2`, mevcut sunucu çerçeve kodunu yeniden kullan), (2) trailer okuma, (3) `nox.grpc` unary çağrı + `nox.protobuf` ile mesaj, (4) akışlı RPC sonra. Önce wasm/QBE etkisini ölç: wasm hedefinde reddedilmeli (bkz. `wasm_abi_table`).

### E3. IPv6 çok çekirdekli dinleme

- **Durum:** Kapsam dışı bırakıldı (C9 notu). `serve_multicore` yalnız IPv4 dinler; IPv6 tek çekirdekli yolda opt-in vardır (v1.142.x).
- **Neden:** Çok çekirdekli yol `SO_REUSEPORT` dağıtımına bağlı; IPv6 ek soket ailesi ve platform farkları getirir.
- **İlk adım:** Kullanıcı isterse `http_serve_multicore` içinde ikinci bir dinleyici ailesi ekleme tasarımını yaz; istemeden başlama.

### E4. `list`/`dict` paylaşımı worker'lar arasında

- **Durum:** Kapsam dışı (kullanıcı kararı: worker başına kopya + fabrika + `AtomicRef`).
- **Ajan:** Paylaşımlı değişebilir `list`/`dict` ekleme; bu ARC atomikliği (Faz X.3 kategorisi) ve bellek modeli kararıdır.

### E5. Sınıf/metot dekoratörlerinin işleyici olması

- **Durum:** Kapsam dışı (kullanıcı kararı, 2026-11-10). Yalnız **üst-düzey** fonksiyon dekoratörleri işleyici kaydeder (`router_from_decorators`/`decorator_handler`).

### E6. Çıplak `list[Task[T]]`

- **Durum:** Hâlâ yazılamaz (codegen `Unsupported`); `nox.tasks.TaskGroup[T]` (v2.1.10) tutamak sınıfı kullanır.
- **Ajan:** Çözüm olarak `TaskGroup` öner. Gerçek `list[Task[T]]` desteği ARC/yıkım semantiğini etkiler; ayrı tasarım gerektirir.

### E7. `Channel` için zaman aşımlı `recv` yok

- **Durum:** `Task.wait` / `wait_any` zaman aşımlıdır (v2.1.6); Channel'da yok.
- **Ajan:** Görev sarmalayıcısı kullanmayı öner. Channel zaman aşımı eklemek istenirse zamanlayıcı ve reaktör etkileşimi (reaktör yalnız hazır kuyruk boşken yoklanır) hesaba katılmalı.

### E8. `match` / enum açık kenarları

- Kapsamlılık denetimi **muhafazakâr**: literal, iç içe veya korumalı kol, varyantı kapsamış sayılmaz; `case _:` ile bitirmek gerekir. Tam iç içe kapsamlılık analizi yapılmadı.
- `match` bağlamaları üreteç (`yield`) fonksiyonlarında kullanılamaz.
- Koruma ifadesinde lambda, comprehension ve sözlük sabiti desteklenmez.
- Yeni `StmtKind` **eklenmedi** (≈25 dosya, 90+ yürüyücü); `match` mevcut `IfStmt` zincirine indirgenir. Bunu bozacak değişiklik büyük refaktördür, sormadan yapma.

### E9. Redis TLS gerçek sertifikayla denenmedi

- **Durum:** `nox.redis` TLS (v2.1.9) başarılı el sıkışması **güvenilir sertifikalı** bir Redis'e karşı doğrulanmadı.
- **İlk adım:** Elinde güvenilir sertifikalı bir Redis (örn. yönetilen servis) varsa bir kez dene; yoksa "denenmedi" notunu kaldırma.

### E10. Platform açıkları

- **Windows `nox.terminal`:** denetim yok, `TerminalError` döner (C8).
- **Android API 26 çökmesi:** açık (bkz. `project_limitation_round_2026_11_10`); cihaz/emülatör gerektirir.
- **Windows CI zaman aşımı:** v2.1.19 `wasm_frontend_test` (300 sn) ve v2.1.23 `codegen_golden_test` "TÜM golden fixture'lar" (300 sn, `NOX_WIN_TEST_TIMEOUT_SEC`) zaman aşımı. Yük kaynaklı olabilir; korpus büyüdükçe Debug Windows'ta eşik yaklaşıyor. **İzle:** art arda iki Windows koşusunda tekrar ederse eşiği/korpusu böl; tek seferlik ise yük say.
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
