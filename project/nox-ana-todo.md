# Nox ana TODO ve gelişim sırası

> **Durum tarihi:** 25 Ekim 2026  
> **Başlangıç sürümü:** v2.0.27  
> **Amaç:** Nox'taki doğrulanmış açık işleri tek bir yürütme kuyruğunda
> toplamak. Bu dosya 2.0 öncesi yol haritasının devamıdır.  
> **Kapsam:** Derleyici, runtime, standart kütüphane, platformlar, FFI,
> güvenlik, CI ve belgeler. Aura işleri ayrı olarak
> [`aura-mobil-eksiklikleri.md`](aura-mobil-eksiklikleri.md) dosyasındadır.

## Durum işaretleri

- `[ ]` açık
- `[~]` sürüyor
- `[x]` kanıtla tamamlandı
- `[!]` kullanıcı kararı, cihaz, hesap veya dış sistem bekliyor

## Yürütme kuralları

1. Aşağıdaki sıra bağımlılık sırasıdır. Aynı anda yalnız ilk engelsiz madde
   üzerinde çalışılır.
2. Her görevden önce `AGENTS.md`, bu dosya ve ilgili teknik spesifikasyon
   bölümü okunur.
3. Mimari, dil semantiği veya ABI kararı gerektiren maddede önce kullanıcıya
   kısa tasarım sunulur; onay alınmadan kod yazılmaz.
4. Tamamlanan her madde test komutu, gerçek sonuç, sürüm ve commit/tag ile
   bu dosyada işaretlenir.
5. Dil/codegen değişikliği QBE ve LLVM'de, en az bir golden test ile
   doğrulanır. Bellek değişikliği leak/double-free/GPA safety kanıtı ister.
6. Kullanıcıya ait kirli çalışma ağacı sahiplenilmez; körlemesine `git add -A`,
   `amend`, reset veya dosya silme yapılmaz.
7. Bilinçli Nox tasarımı olan dinamik tip reddi, ownership sözdiziminin
   olmaması ve WASM'in backend olmaması birer eksik değildir.

8. **Sıra kararı (2026-10-28, kullanıcı "sen karar ver" dedi):** Faz 1A (Nova) →
   Faz 1.3–1.6 → Faz 2.1–2.3 (onaylı) → Aura A0/A3/A5'in cihazsız kısımları
   (`aura-mobil-eksiklikleri.md`). Gerekçe: Aura gömme ABI'sini tüketir; 1.3
   (allocator sözleşmesi) ve 1.6 (hata/OOM sözleşmesi) ABI'yi değiştirebilir,
   bu yüzden Aura işi bunlardan SONRA yapılır. Aura A1/A2/A6'nın fiziksel
   cihaz/signing/TestFlight/Play kısımları `[!]` olarak kullanıcıda kalır.

## Doğrulanmış başlangıç durumu

- Masaüstü Nox 2.0 yayınlanmış ve ana dil/stdlib yol haritası kapanmıştır.
- Mobil hedefler vardır fakat dördü de `experimental`dır.
- Eski `project/uretim-hazirlik-analizi.md` ve Claude memory kayıtları
  tarihsel kaynaklardır; güncel durum yerine kullanılamaz.
- `NOX_MOBILE_ROADMAP.md` 190 boş kutu taşır; uygulamanın önemli bir kısmı
  v2.0.19'da yapılmış olmasına rağmen belge güncellenmemiştir.
- İnceleme anında ana checkout kullanıcıya ait 39 değiştirilmiş dosya ve çok
  sayıda izlenmeyen dosya taşımaktadır. Aşağıdaki ilk kapı bu nedenle temiz
  bir baseline oluşturulmadan geçilemez.

## Faz 0 — Çalışma alanı ve kanıt tabanı

- [x] **0.1 Ana backlog'u oluştur.** Bu dosya ve ayrı Aura devir belgesi
  oluşturuldu.
- [x] **0.2 Mevcut kirli çalışma ağacının sahipliğini ayır (25 Ekim 2026).**
  Hedef başlamadan önce var olan bütün değişiklikler kullanıcı/Cursor işi
  olarak ayrıldı ve korunacak: VS Code eklentisi; noxpkg/site/deployment;
  backup betikleri; compiler/runtime/testlerdeki küçük inceleme-atıf
  düzeltmeleri; framework sitesi; yeni debug testi ve HPy Windows
  artifaktları. Repo kökündeki `.o/.obj/.exe/.pdb/.s/.ssa` dosyaları üretilmiş
  build artifaktlarıdır ve kaynak değildir; yine de izinsiz silinmeyecek.
  Bu hedefin Codex kapsamı yalnız bu ana TODO, Aura devir belgesi ve iki eski
  yol haritasına eklenen yönlendirme notlarıyla başladı. Baseline ve sonraki
  kod işleri temiz, ayrı bir worktree üzerinde yürütülecek.
- [x] **0.3 Temiz, yeniden üretilebilir baseline doğrula (25 Ekim 2026,
  `e2ea7098`, Zig 0.16.0).** Ayrı `nox-master-todo` worktree'sinde dört
  komut da ayrı ayrı exit code 0 verdi: `zig build`, `zig build test`,
  `zig build -Doptimize=ReleaseFast`,
  `zig build test -Doptimize=ReleaseFast`. Debug ve ReleaseFast IR-diff:
  411 karşılaştırıldı, 0 yeni snapshot, 12 kasıtlı atlama/derlenmeme.
- [x] **0.4 Yol haritalarını gerçek durumla eşleştir (25 Ekim 2026).** Mobil
  plana M0–M10 için güncel Nox durumu ve kanıt/sahiplik tablosu eklendi.
  Nox işleri bu dosyanın Faz 1–4'üne, Aura işleri yalnız ayrı devir
  belgesinin A0–A6 fazlarına bağlandı.
- [x] **0.5 Güncel olmayan durum belgelerini işaretle (25 Ekim 2026).** Eski
  üretim-hazırlık analizine tarihsel belge uyarısı eklendi. Platform tablosu
  Windows Debug tam korpusunu ve riscv64 QEMU smoke CI'ını doğru yansıtacak
  şekilde düzeltildi. Eski `noxc 1.26.6` benchmark ölçümünün yenilenmesi,
  kullanıcıdaki mevcut benchmark değişikliklerine dokunmamak için Faz 9.1'de
  ayrı açık görev olarak bırakıldı.

**Faz 0 çıkış kapısı:** Sahibi belirsiz dosya yok; test edilecek commit belli;
Debug ve ReleaseFast baseline sonucu kayıtlı.

## Faz 1 — P0 invariant ve runtime durum modeli

Bu faz diğer bütün yeni özelliklerden önce gelir.

- [x] **1.1 Runtime context tasarımını onaylat.** (Onaylandı 2026-10-28, uygulandı v2.0.29.) `runtime/embed.zig` içindeki
  `threadlocal active_rt`, mobil FS/SQLite sandbox köklerini gizli mutable
  state üzerinden seçiyor. Bu, `AGENTS.md` §2.6 ile çelişme riski taşır.
  Önerilen ve onay bekleyen yön:
  1. Public `nox_embed.h` ABI v1 değişmeden kalır.
  2. `allowsPath(rt, path)` runtime'ı açık parametre alır; FS/SQLite'ın private
     runtime ABI fonksiyonlarına `with_rt` eklenir.
  3. `nox.thread` veya bağımsız worker pool yeni bir `RuntimeState`
     oluşturduğunda `nox_runtime_init_child(parent)` benzeri tek bir yol,
     immutable mobil policy'yi ebeveynden kopyalar.
  4. Çocuk runtime kök dizelerini kendi allocator'ıyla sahiplenir; host/app
     yok olurken dangling pointer bırakmaz ve deinit'te kendisi serbest bırakır.
  5. Aynı process'teki iki embed app ve çocuk thread'leri için kök izolasyonu,
     desktop davranışının değişmemesi ve iki-backend golden/integration
     testleri eklenir.
  Bu private runtime ABI değişikliği olsa da public embed ABI bump'ı gerektirmez;
  uygulamaya geçmek kullanıcı onayı gerektirir.
- [x] **1.2 Mobil sandbox durumunu açık taşı.** (v2.0.29: `zig build test` Debug yeşil — embed.zig 6 yeni birim testi + thread_bridge çocuk-politika testi + 9 IR anlık görüntüsü her iki backend fixture korpusunda.) `embed.allowsPath` ve bütün
  FS/SQLite çağrılarını doğru `RuntimeState`/app context ile ilişkilendir;
  iki eşzamanlı uygulama ve iki OS thread'i birbirinin köklerini göremesin.
- [x] **1.3 Embed allocator sözleşmesini düzelt.** (v2.0.32: `NoxHostAllocator` + `size`-ayrımlı config, ABI 1 kalır; ADR-MOB-009; 3 birim testi.) `nox_app_create` şu anda
  içeride `std.heap.page_allocator` seçiyor. Host allocator'ı veya runtime
  allocator'ının nasıl açık taşınacağı ADR ve sürümlü ABI ile belirlenmeli.
- [x] **1.4 Global/gizli state ve allocator denetimi yap.** (v2.0.32: 82 bildirim sınıflandırıldı, `docs/internals/global-state-audit.md`; CI kapısı `scripts/check_global_state.py`; tek açık borç `tl-errno` -> 1.5 ölçer.) İlk taramada
  `compiler/` + `runtime/` altında 32 dosyada `page_allocator`, 15 dosyada
  `threadlocal var` bulundu. Test-only, immutable/provider registry ve gerçek
  invariant ihlallerini ayır; gerçek ihlalleri küçük, testli dilimlerle kaldır.
- [x] **1.5 Çoklu runtime izolasyon korpusu ekle.** (v2.0.33: `runtime/multi_runtime_test.zig` — allocator/istisna/entropi/sandbox/zamanlayıcı, 4 iş parçacığı stres + HPy context iş parçacıklı testi; JSON/FS `last_op_ok` YALNIZCA belgeli `tl-errno` borcu olarak kaldı, ölçüm bunu doğrular: aynı iş parçacığındaki iki runtime fiber dışında paylaşır.) Allocator, hata durumu,
  JSON/FS sonuç durumu, HPy context, entropy ve scheduler state için iki
  runtime + çoklu thread stres testi oluştur.
- [x] **1.6 Embed hata/OOM sözleşmesini tamamla.** (v2.0.32: `ERR_FULL`, `ERR_EXCEPTION`, start OOM yeniden denenebilir; 4 birim testi, testing.allocator sızıntı denetimli.) Kısmi init, host callback
  hatası, Nox exception çevirisi, queue doluluğu, stop sırasında olay ve OOM
  yollarının tamamı açık hata kodu ve leak/double-free testi taşısın.

**Faz 1 çıkış kapısı:** Mobil/embed yolu gizli runtime seçimine dayanmaz;
allocator sahipliği açık; iki runtime izolasyon ve sanitizer testleri yeşil.

## Faz 1A — Nova (HTTP istemci çerçevesi) gereksinimleri

Kaynak: `~/Documents/nox-packages/nova/NOX_LIMITATIONS.md` (kullanıcı talebi,
2026-10-28: "TODO'ya uygun yerlere ekle, gerçekleştirelim"). Sıra kararı
(kullanıcı "sen karar ver" dedi): bu şerit Faz 1'in kalanından (1.3–1.6) ÖNCE
yürütülür, çünkü Nova aktif olarak bunlar yüzünden engelli, işler küçük ve
bağımsızdır (embed ABI/allocator durumuna dokunmaz). Faz 1'in "her şeyden önce"
kuralı bu istisna için kullanıcı kararıyla aşıldı. Her madde ÖNCE kodda doğrulanır
(belgedeki iddialar bayat çıkabiliyor); yanlış/bayat iddia olduğu gibi kapatılır.

- [x] **N.1 Genel HTTP metodu: `nox.http.request(method, url, body, headers)`.**
  Zig `doRequest` zaten tüm metodları çalıştırabiliyor; yalnız GET/POST export
  ediliyor. `nox_http_request_raw` + `request` + `put/patch/delete/head/options`
  sarmalayıcıları; bilinmeyen metod adı sessizce GET'e düşmez, `HttpError` verir.
  (v2.0.31: `nox_http_request_raw` + `request/put/patch/delete/head/options`; gövde yalnızca
  POST/PUT/PATCH — `std.http` kısıtı, diğerlerinde gövde `HttpError`.)
- [x] **N.2 Gerçek istek zaman aşımı.** `timeout_ms` soket seviyesinde
  (`SO_RCVTIMEO`/`SO_SNDTIMEO` veya poll'lu bekleme); dönüşten sonra süre ölçen
  sahte timeout YASAK. Zaman aşımı ayrı bir `HttpTimeoutError` ile bildirilir.
  (v2.0.31: bekçi iş parçacığı süre dolunca açık soketi `shutdown` eder; DNS/TCP
  connect aşaması `std.http.Client` içinde olduğundan OS süresiyle sınırlı kalır —
  N.2b olarak açık, `std.http.Client` fork'u gerektirir.)
- [x] **N.3 İkili (bayt) yanıt gövdesi.** `str` NUL-sonlandırmalı olduğundan
  gömülü `\0` kesiliyor/boyut uyuşmazlığı doğuruyor. Önce kodda doğrula; sonra
  `nox.buffer`/bayt tabanlı ikinci erişimci. Gzip/PNG/protobuf fixture'ı ile test.
  (v2.0.31: `str` gömülü NUL/geçersiz UTF-8'i zaten taşıyor; asıl hata gövdede NUL varsa
  isteğin BAŞARISIZ sayılmasıydı — kaldırıldı; `nox.bytes.from_str(s) -> Buffer` eklendi.
  Zig testi + gerçek sunucuyla iki-backend doğrulaması.)
- [!] **N.4 Akışlı indirme/yükleme (streaming).** Yeni API yüzeyi + handle ömrü
  tasarımı gerekir (N.3'ten sonra kısa tasarım sunulacak).
- [x] **N.5 Yönlendirme politikası.** (v2.0.31: iddia BAYAT çıktı, kapatıldı; docs'taki "yönlendirmeler izlenir" cümlesi YANLIŞTI, düzeltildi.) Belgedeki iddia büyük olasılıkla BAYAT:
  istemci `redirect_behavior = .unhandled` ile hiç yönlendirme takip etmez (3xx
  olduğu gibi döner), dolayısıyla çapraz-origin başlık sızıntısı yok. Doğrula ve
  kapat; `max_redirects` takibi YENİ bir özelliktir (Authorization/Cookie'yi
  çapraz-origin'de silme dahil) — istenirse ayrıca onaylanır.
- [x] **N.6 `nox.url.parse` IPv6 literal hatası.** `http://[::1]:8080/` host:port
  ayrımı `[`'li host'ta eşleşen `]`dan SONRAKİ `:`'ı aramalı. Bayat olabilir
  (v1.142.x opt-in IPv6 turu); önce reproducer, sonra düzelt + golden. (v2.0.30: `nox.url.parse` köşeli parantezli host + port ayrımı; golden `url_parse_ipv6_literal`, iki backend.)
- [x] **N.7 `int(" 5 ")` / `int("5\n")` boşluk toleransı.** Python gibi baştaki/
  sondaki ASCII boşlukları yok say. Yalnız bu sınır; `float()` tutarlılığı da
  bakılır. İki backend golden'ı. (v2.0.30: `int()`/`float()` ASCII boşluğu yok sayar; golden `int_float_parse_whitespace` + birim testi.)
- [x] **N.8 Bileşik koşulda Optional daraltması.** `x is not None and x.f()`
  sağ operandda daraltılmış tiple denetlensin (`and` sol → sağ; `or` için
  `x is None or ...`). Yalnız kanıtlanabilir yerel değişken/alan yolları;
  belirsizse eski davranış. Checker testleri + iki backend golden'ı. (v2.0.30: `checkBinary` sağ operandı `collectNarrows` ile daraltır; golden `optional_narrowing_and_or_operand` + sızıntı-yok typecheck testi.)
- [x] **N.9 `\xHH` kaçış dizisi.** (v2.0.30: `\x00`–`\x7F` çözülür, gömülü NUL çalışır, QBE kontrol baytlarını sekizlik kaçışla yazar; `\x80`–`\xFF` ve bozuk `\x` net derleme hatasıdır — ham bayt kararı kullanıcıya bırakıldı.) `\x00`–`\x7F` Python gibi tek bayt/kod noktası.
  `\x80`–`\xFF` için karar GEREKİR [!]: Python semantiği kod noktası (UTF-8'de 2
  bayt) iken Nova ham bayt istiyor — `str` UTF-8 farkında olduğundan ham bayt
  geçersiz UTF-8 üretir. Gömülü `\x00` yalnız `str` uzunluk-alanı gömülü NUL'a
  izin veriyorsa kabul edilir (doğrulanacak); aksi halde derleme hatası.
- [x] **N.10 `def f(x: dict[str,str] = {})` yasağı korunur.** Belgedeki "C" maddesi
  bilinçli tasarımdır (değişmez varsayılan paylaşımı); değişiklik YOK.

## Faz 2 — P1 tip sistemi ve AGENTS sözleşmesi boşlukları

- [x] **2.1 Heterojen protokol koleksiyonunu tasarla.** (Tasarım ONAYLANDI 2026-10-28: iki kelimeli fat-pointer `(nesne*, vtable*)`, vtable statik veri, kullanıcı sözdizimi değişmez; ARC nesne yarısı üzerinden; değer protokol tipli saklandığında fat-pointer, statik somut tipte monomorphization.) `AGENTS.md` §12,
  `list[Shape]` için örtük fat-pointer/vtable fallback ister; güncel belgeler
  protokol tipli koleksiyonları reddediyor. Temsil, ARC davranışı, ABI ve
  dispatch seçimi onaylanmadan uygulanmaz.
- [x] **2.2 Protokol dispatch'in iki yolunu tamamla.** (v2.0.34: temsil = sentezlenen `P__Base` soyut sınıfı + dönüşümde sentezlenen delege eden `P__Box_C` alt sınıfı; yani fat-pointer mevcut tekli-kalıtım vtable altyapısıyla temsil edilir, yeni codegen yok. Statik-somut çağrılar monomorphize kalır. Golden: `protocol_heterogeneous_list` (iki yol yan yana) ve `protocol_values_fields_dict_optional`, QBE+LLVM; typecheck golden'ları.) Tek/az somut tipte
  monomorphization; gerçekten heterojen koleksiyonda fat-pointer fallback.
  Her protokol için iki backend'de iki yolun golden testi zorunlu.
- [x] **2.3 Protokol değerleri için ownership analizi ekle.** (v2.0.34: kutu/taban sıradan sınıf olduğundan ASAP/ARC/döngü çözücü/istisna/closure yolları değişmeden çalışır; 2000 turluk kutulama-bırakma döngüsü ve istisna yolu golden'da, Debug allocator sızıntı raporlamadı. Sınır: imzası başka protokol içeren protokol değer tipi olamaz.) Container'a
  girme/çıkma, closure, return, exception ve cycle collector davranışını
  doğrula; belirsizlikte sessiz ARC fallback kullan.
- [x] **2.4 Generic sınıfta generic metod kararını ver.** (v2.0.38: KARAR: desteklenir. Somut sınıf örneği oluşturulurken metodun kendi tip parametresi serbest bırakılıp `generic_methods`e taşınır, çağrı sitesinde bağlanır (açık/çıkarımlı); anahtar `Box__int.map_to`. Tek tip parametresi sınırı sürer; lambda argümanı açık biçimi ister.) Güncel sınır
  `Box[T].map_to[U]` desteğinin olmamasıdır. Monomorphization anahtarı ve
  type-argument inference tasarımı onay ister.
- [x] **2.5 Task/Channel koleksiyonları kararını ver.** (v2.0.38: KARAR: `list[Task[T]]`/`dict[..., Channel[T]]` DESTEKLENMEZ. Gerekçe: görev tutamacının yaşam süresi ve işçiler-arası sahiplik kanıtlanmadan koleksiyon yüzeyi açmak ARC dengesini (tutamaç `await` ile bir kez tüketilir) bozar; dilin kendi kuralı "kanıtlanmadan yüzey eklenmez". Yol: görevleri bir sınıf alanında tek tek tut ya da `Channel`la sonuçları topla. Kalıcı ret `docs/language/concurrency.md` sınırları arasında kalır.) `list[Task[T]]`
  desteklenmiyor. Runtime handle yaşam süresi ve cross-worker ownership
  kanıtlanmadan yüzey eklenmez.

**Faz 2 çıkış kapısı:** AGENTS §12 ile public belgeler/kod aynı sözleşmeyi
anlatır; her dispatch yolu iki backend'de testlidir.

## Faz 3 — P1 Nox mobil runtime ve ABI doğruluğu

- [x] **3.1 Mobil ABI primitive korpusunu tamamla.** (v2.0.35: `tests/cli/embed_abi_corpus_test.zig`, iOS simülatöründe C host: int/float/bool, yanlış ABI sürümü ve boyut. C-layout struct dönüşü/geri çağrı Nox kütüphane ABI'sinde yok, kapsam dışı.) `int`, `float`, `bool`,
  C-layout struct return/argument, callback ve yanlış ABI sürümü.
- [x] **3.2 String/buffer sınırını tamamla.** (v2.0.35: Türkçe+emoji, geçersiz UTF-8 bayt semantiği, boş dize, kapanıştan sonra kullanım yok; gömülü NUL C dizesiyle taşınamaz — `nox.bytes` yolu ayrı.) Türkçe/Unicode, embedded NUL,
  invalid UTF-8, borrow/copy ömrü ve kapanıştan sonra kullanım.
- [x] **3.3 Exception sınırını tamamla.** (v2.0.35: istisna kod+nesne olarak döner; host `nox_exception_take`/yeni `nox_exception_release` ile alıp bırakır — önceden bırakma API'si olmadığı için sızıntı vardı, korpus bulup düzeltti.) Nox exception'ı C/Swift/JNI
  çerçevesinden kaçmadan kod + okunabilir hata nesnesine dönüşsün; başarı ve
  hata yolu testleri olsun.
- [x] **3.4 ARC/ASAP/cycle mobil stresini tamamla.** (v2.0.35: 10.000 create/start/destroy simülatörde, host ayırıcısı sayacı sıfıra iner. Cihaz/sanitizer koşusu ayrı.) 10.000 lifecycle testi
  cihaz/simülatör sanitizer koşusuna, collection/cycle ve callback baskısına
  genişletilsin.
- [ ] **3.5 Fiber/TLS/stack doğrulamasını tamamla.** Apple pointer
  authentication, Android ARM64, guard page, stack overflow ve TLS destructor
  gerçek hedefte sınansın.
- [x] **3.6 UI-thread pump bütçesini doğrula.** (v2.0.35: bütçe geçmişse 0 teslim, sonra 64; kuyruk dolu `ERR_FULL`; durdurulmuş `ERR_STATE`.) Yoğun event/async altında
  `pump` frame bütçesini aşmasın; suspend/resume sonrası queue sırası
  deterministik olsun.
- [~] **3.7 Mobil stdlib sandbox testlerini tamamla.** (v2.0.36: kök sınırı, `..`, SEMBOLİK BAĞ kaçışı (gerçek açık, kapatıldı) ve kanonik yol testli. v2.0.42: `nox.fs.write_string_atomic` (geçici dosya + rename) eklendi ve testli. Açık: gerçek disk-dolu simülasyonu, SQLite cache/temp davranışı.) Kök sınırı, `..`,
  symlink/canonical path, atomic write, disk-full, SQLite ve cache/temp
  davranışı.
- [ ] **3.8 Mobil ağ matrisini tamamla.** DNS IPv4/IPv6, offline, timeout,
  TLS sertifika reddi, ağ değişimi ve background/resume.
- [~] **3.9 Entropy/clock/log sözleşmesini tamamla.** (v2.0.45: `nox.log.redact`/`mask_assignments` ile gizli değer maskeleme, iki backend golden. Zaten var: `nox.crypto.secure_random_hex` (OS CSPRNG), `nox.time.Instant` (monotonic), debug-only `nox_log_debug_raw`. Açık: askıya alma farkı ölçümü (cihaz gerekir), log seviye filtresi.) Güvenli RNG, monotonic
  saat, suspend farkı, debug/release log ayrımı ve secret redaction.

**Faz 3 çıkış kapısı:** Nox mobil runtime/stdlib kabul korpusu simülatör ve
emülatörde otomatik, fiziksel hedeflerde tekrarlanabilir çalışır.

## Faz 4 — P1 mobil hedefler, CI ve destek seviyesi

- [ ] **4.1 Android x64'ü emülatörde çalıştır.** Bugünkü kanıt link-only.
- [!] **4.2 Android ARM64 fiziksel cihaz kanıtı.** Cihaz laboratuvarı gerekir.
- [!] **4.3 iOS ARM64 fiziksel cihaz kanıtı.** Apple signing/provisioning ve
  cihaz gerekir; build-only kanıt yeterli değildir.
- [ ] **4.4 Android 16 KiB'yi çalışma anında doğrula.** Yalnız ELF header
  ölçümü değil, uyumlu emulator/device açılışı ve bağımlı bütün `.so`lar.
- [ ] **4.5 Mobil CI matrisini tamamla.** PR'da iOS simulator run + Android
  emulator smoke; nightly sanitizer/lifecycle/network; watchdog ve cleanup.
- [~] **4.6 Kanıt zincirini sertleştir.** (v2.0.38: stable iddiasında kanıt dosyası temiz Nox ağacından olmalı (`nox_tree=clean`), `nox_head` git'te bulunmalı, `date`/`backend` yazılmalı, imzalı artifact'lar için SHA-256 şart. Açık: Aura commit'i ve toolchain alanlarının zorunluluğu — Aura deposu ayrı.) Kanıt dosyası temiz/tagli Nox ve
  Aura commit'i, toolchain, target, backend, run/build ayrımı ve artifact
  SHA-256 taşısın. Bayat/kirli kanıt stable kapısını açamasın.
- [x] **4.7 Stable gate'i fail-closed yap.** (v2.0.38: `scripts/check_mobile_stable.py` zorunlu 8 anahtarı arar, eksik anahtar `=no` gibi hata; `--self-test` CI'da (mobile.yml). `supported` yazmak için cihaz laboratuvarı/imzalı IPA-APK-AAB kanıtı yine `[!]` kullanıcıda.) Zorunlu anahtar eksikliği de
  `=no` gibi hata olsun; signed IPA/APK/AAB ve device lab olmadan
  `supported` yazılamasın.
- [!] **4.8 Destek seviyesi yükseltme kararı.** Bütün kapılar yeşil olduktan
  sonra her target ayrı ayrı `preview`/`supported` ilan edilir.

## Faz 5 — P2 masaüstü ve mimari platform kapsaması

- [ ] **5.1 Windows guard-page repro testini ekle.** Fiber testi bugün
  Windows'ta TODO ile skip ediliyor.
- [x] **5.2 Windows belge/CI gerçeğini eşleştir.** (v2.0.37: `platforms.md`, `stability.md`, `releasing.md`, `faq.md` aynı ifadeyi kullanır: Debug `zig build test` korpusu + uçtan uca smoke; Release modları Windows'ta koşmaz.) CI tam `zig build test`
  çalıştırırken platform belgesi hâlâ yalnız smoke/full-suite yok diyor;
  gerçek kapsam ölçülüp tek doğru ifade kullanılmalı.
- [x] **5.3 macOS x86-64 CI ekle veya açıkça destek dışına çıkar.** (v2.0.39 KARAR: destek matrisinin dışında; `platforms.md` "çalışması beklenir, CI/release matrisinde yok" der ve `scripts/check_doc_contracts.py` hedefin belgede geçmesini denetler. CI eklemek runner maliyeti ister.) Bugünkü
  durum “çalışması bekleniyor”, release matrisi yok.
- [ ] **5.4 Hosted riscv64 korpusunu genişlet.** Dört smoke fixture yerine
  temsilî dil/runtime/exception/ARC/async matrisi ve düzenli CI.
- [!] **5.5 Freestanding riscv64 hedefini kararlaştır.** Şu anda assembly
  only; boot zinciri isteniyorsa linker/runtime/QEMU kapıları tasarlanmalı.
- [ ] **5.6 Freestanding aarch64 boot kanıtını tamamla.** ELF üretimi ile
  gerçek QEMU/device boot kanıtını ayır.
- [!] **5.7 LLVM debug-info politikasını kararlaştır.** `-g` yalnız QBE'de;
  LLVM DWARF/CodeView desteği ayrı tasarım ve test ister.

## Faz 6 — P2 FFI, HPy, WASM ve native ekosistem

- [x] **6.1 HPy profilinin ürün hedefini seç.** (v2.0.39 KARAR: `nox-hpy-host-v1` PREVIEW kalır; ölçütler `docs/internals/hpy-tier-gap.md`.) `nox-hpy-host-v1` çalışıyor
  fakat public stdlib'de preview. Stabilize etme ölçütleri ve sürüm politikası
  belirlenmeli.
- [x] **6.2 AGENTS HPy Tier tablosuyla gap matrisi çıkar.** (v2.0.39: `docs/internals/hpy-tier-gap.md` — var olan: HPy 0.9 Universal ABI host (180 ctx_*), paket akışı, gerçek fixture; YOK: `cpython_compat` katmanı, Tier 1-3 CPython emülasyonu.) Tier 0–3 API'leri
  mevcut host surface ile tek tek karşılaştır; destek iddiasını gerçek C
  extension fixture'larına bağla.
- [ ] **6.3 HPy container/call surface'i genişlet.** List/tuple/dict,
  defaults/overload/variadic ve gelişmiş buffer davranışları yalnız ownership
  sözleşmesi ve gerçek extension testiyle eklenir.
- [x] **6.4 CPython uyumluluk iddiasını dürüstçe sınırla.** (v2.0.39: aynı sayfa; NumPy/Pandas desteklenmez, "as-is çalışır" denmez; AGENTS Tier tablosu yol haritası olarak işaretlendi.) NumPy/Pandas
  hedefi için gereken gerçek API matrisi, eksik semboller ve test programı
  hazırlanmalı; “as-is çalışır” denmemeli.
- [~] **6.5 WASM interpreter kapsam matrisi çıkar.** (v2.0.39: `docs/internals/wasm-coverage.md` matrisi ve hedef yüzey sırası yazıldı; v2.0.41: i32 karşılaştırma/bölme/bit/kaydırma/select/drop eklendi, trap ve taşma testli. v2.0.44: block/loop/if/else/br/br_if + yakıt sınırı (50M komut) eklendi. Açık: bellek, i64, br_table.) Bugünkü parser/interpreter
  yalnız sınırlı instruction/value türlerini destekliyor. İstenen WASM
  surface'i belirle, trap/error ve fuzz korpusunu genişlet. WASM backend
  kesinlikle eklenmez.
- [!] **6.6 Asenkron native callback tasarımını kararlaştır.** Mevcut callback
  yalnız senkron ve primitive imzalıdır; timer/event-loop callback'leri ayrı
  handle/lifetime/reentrancy tasarımı olmadan açılmaz.

## Faz 7 — P2 güvenlik ve tedarik zinciri

- [x] **7.1 Paket imzalama tasarımı.** (v2.0.43, kullanıcı onayladı: ADR-011 + `noxc sign keygen/lock/trust/revoke/verify`, Ed25519 ayrık imza, açık güven, iptal listesi, çevrimdışı doğrulama; birim + uçtan uca CLI testi. Açık: `fetch` imzayı zorunlu kılsın, noxpkg yayıncı anahtarını hesaba bağlasın.) (Ajan önerisi 2026-10-28: (Ajan önerisi 2026-10-28, uygulanmadı: yayıncı başına ed25519 anahtarı noxpkg hesabına bağlanır, `nox.lock` imzayı ve anahtar parmak izini saklar, iptal listesi indeksle birlikte sunulur; ilk kullanımda güven (TOFU) + çevrimdışı doğrulama. Hesap altyapısı (noxpkg hesapları v2.0.28) hazır; trust root ve anahtar yenileme politikası kullanıcı kararı.) `nox.lock` commit/hash pinler ancak
  paket imzası/audit yoktur. Trust root, key rotation, revocation ve offline
  doğrulama ADR'si gerekir.
- [x] **7.2 Capability enforcement tasarımı.** (v2.0.43, kullanıcı onayladı: ADR-010; `noxc run --sandbox` OS düzeyinde uygular, `extern def`e yarım mod eklenmedi.) (Ajan önerisi: (Ajan önerisi: önce Linux seccomp/macOS sandbox profilini `noxc run --sandbox` olarak ayrı süreç başlatıcıda dene; `extern def`e yarım mod ekleme. İşletim sistemi başına ayrı tasarım gerekir.) Plugin capability'leri bugün
  consent metadata'sıdır, sandbox değildir. OS-level enforcement ayrı tasarım
  olmadan vaat edilmez.
- [x] **7.3 Untrusted source çalışma modeli.** (v2.0.43, kullanıcı onayladı: aynı başlatıcı; varsayılan ağsız + yalnız TMPDIR yazma + ev dizini okunamaz, macOS testli, Linux bwrap birim testli.) (Ajan önerisi: (Ajan önerisi: 7.2 ile aynı başlatıcı; kapsayıcı imajı + salt-okunur kök + ağsız varsayılan. Ürün yüzeyi kararı kullanıcıda.) `noxc run` tam süreç yetkisiyle
  çalışır. İstenirse container/seccomp/sandbox launcher ayrı ürün yüzeyi
  olarak tasarlanır; `extern def`e yarım “safe mode” eklenmez.
- [~] **7.4 Registry güvenlik kapılarını genişlet.** (v2.0.39: moderasyon, "metadata onayı kod incelemesi değildir", kilit dosyası = provenance, olay müdahale adımları `docs/reference/security.md`de. Açık: otomatik tarama, yayıncı imzası, üretilmiş SBOM — 7.1 tasarımına bağlı.) Metadata approval,
  malware/native-code uyarısı, provenance/SBOM ve incident response akışı
  belgelenip test edilmeli.
- [~] **7.5 FFI sınır fuzzing'i ekle.** (v2.0.37: embed ABI için 300 turluk deterministik rastgele çağrı dizisi + bozuk yapılandırma/UTF-8/uzunluk fuzz testi; WASM ayrıştırıcı ve lexer/parser fuzz önceden vardı. Açık: NNI, Plugin API, HPy sınırı.) NNI, Plugin API, HPy, WASM ve embed
  ABI için length/null/version/ownership girdileri fuzz edilmelidir.

## Faz 8 — P3 dil/stdlib kapsam kararları

Bu maddeler doğruluk açığı değil, belgelenmiş kapsam genişletmeleridir. Her biri
ayrı kullanıcı kararı ve dil özelliği süreci gerektirir.

- [!] **8.1 `*args` / `**kwargs`, keyword-only ve call-site unpacking.**
- [!] **8.2 Çoklu kalıtım.** MRO, field layout, protocol ve ARC etkisi.
- [!] **8.3 Class-level attributes ve static/class/property yüzeyi.**
- [~] **8.4 Annotated `self.x: T = v` ve nested empty literal inference.** (v2.0.39: `self.x: T = v` UYGULANDI — alanı tanımlar, boş literal/Optional için beklenen tip verir, formatter yüzey biçimini korur, iki backend golden + 2 typecheck hatası; `__init__` dışında yeni alan reddedilir. Açık: iç içe boş literal çıkarımı (`list[list[int]]` içinde `[]`).)
- [!] **8.5 Closure içinde dış değişkene yazma (`nonlocal` eşdeğeri).**
- [!] **8.6 Lazy generator/yield ve arbitrary await/async iteration.**
- [!] **8.7 Unicode genişletmesi.** ASCII-only identifiers/case işlemleri,
  shaping/normalization kapsamı ayrı ayrı seçilmeli.
- [!] **8.8 Regex/TOML/YAML tamlık hedefleri.** Mevcut belgeli subset'ler
  “tam standart” diye sunulmaz; ihtiyaç halinde ayrı uyumluluk matrisleriyle
  genişletilir.

## Faz 9 — P3 performans, gözlemlenebilirlik ve belge doğruluğu

- [x] **9.1 Benchmark baseline'ını v2.0.27 ile yenile.** (v2.0.39: v2.0.38 ile koşuldu, 30/30+10/10+8/8+4/4; metadata RESULTS.md başında; bayat beklentiler ve kaldırılmış json API düzeltildi.) Güncel sonuç dosyası
  hâlâ eski `noxc 1.26.6` metadata'sı taşıyor. Makine, Zig, backend ve
  min/avg/max aynı koşuda kaydedilmeli.
- [x] **9.2 QBE/LLVM/C farklarını yeniden ölç.** (v2.0.39: `cross_lang` 5 tekrar ortanca, ReleaseFast; gerileme yok; en büyük açıklar sieve/matmul/dict.) Debug sonuç kullanılmaz;
  ReleaseFast, uzun çalışan kernel ve istatistiksel tekrar zorunlu.
- [ ] **9.3 Dict iki-lookup maliyetini incele.** Insertion order ve hash seed
  semantiğini bozmadan tek-lookup tasarımının değeri ölçülür.
- [ ] **9.4 Matmul/list dolaylama ve bounds-check maliyetini profille.** Ancak
  ölçüm ve iki-backend semantik testi sonrası optimizasyon yapılır.
- [x] **9.5 Doküman sözleşme testi ekle.** (v2.0.37: `scripts/check_doc_contracts.py` CI'da: `--target` değerleri, mobil matris, varsayılan backend ve üç yerdeki sürüm çapraz doğrulanır.) Platform destek tablosu, CLI target
  listesi, backend seçimi, versiyon ve mobile matrix koddan türetilmeli veya
  CI'da çapraz doğrulanmalı.
- [x] **9.6 Tarihsel spesifikasyonu normatif başvurudan ayır.** (v2.0.37: spesifikasyon başına "tarihsel, normatif değil" bildirimi ve `docs/` indeksi; çelişkide öncelik sırası yazıldı.) Kronolojik
  uygulama günlüğü korunurken güncel dil sözleşmesine tek, indeksli giriş
  sağlanmalı.

## Her görev için kapanış şablonu

- Değişen alan:
- İlgili AGENTS bölümü:
- Tasarım kararı/ADR:
- QBE testi:
- LLVM testi:
- Golden/integration testi:
- Bellek/sanitizer testi:
- Platform/cihaz kanıtı:
- Doküman/spec güncellemesi:
- `zig fmt`:
- `zig build`:
- `zig build test`:
- ReleaseFast:
- Sürüm/commit/tag:
- Değişmez ilke ihlali: **hayır**

