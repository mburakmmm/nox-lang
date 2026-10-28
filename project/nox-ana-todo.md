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

- [!] **1.1 Runtime context tasarımını onaylat.** `runtime/embed.zig` içindeki
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
- [ ] **1.2 Mobil sandbox durumunu açık taşı.** `embed.allowsPath` ve bütün
  FS/SQLite çağrılarını doğru `RuntimeState`/app context ile ilişkilendir;
  iki eşzamanlı uygulama ve iki OS thread'i birbirinin köklerini göremesin.
- [ ] **1.3 Embed allocator sözleşmesini düzelt.** `nox_app_create` şu anda
  içeride `std.heap.page_allocator` seçiyor. Host allocator'ı veya runtime
  allocator'ının nasıl açık taşınacağı ADR ve sürümlü ABI ile belirlenmeli.
- [ ] **1.4 Global/gizli state ve allocator denetimi yap.** İlk taramada
  `compiler/` + `runtime/` altında 32 dosyada `page_allocator`, 15 dosyada
  `threadlocal var` bulundu. Test-only, immutable/provider registry ve gerçek
  invariant ihlallerini ayır; gerçek ihlalleri küçük, testli dilimlerle kaldır.
- [ ] **1.5 Çoklu runtime izolasyon korpusu ekle.** Allocator, hata durumu,
  JSON/FS sonuç durumu, HPy context, entropy ve scheduler state için iki
  runtime + çoklu thread stres testi oluştur.
- [ ] **1.6 Embed hata/OOM sözleşmesini tamamla.** Kısmi init, host callback
  hatası, Nox exception çevirisi, queue doluluğu, stop sırasında olay ve OOM
  yollarının tamamı açık hata kodu ve leak/double-free testi taşısın.

**Faz 1 çıkış kapısı:** Mobil/embed yolu gizli runtime seçimine dayanmaz;
allocator sahipliği açık; iki runtime izolasyon ve sanitizer testleri yeşil.

## Faz 2 — P1 tip sistemi ve AGENTS sözleşmesi boşlukları

- [!] **2.1 Heterojen protokol koleksiyonunu tasarla.** `AGENTS.md` §12,
  `list[Shape]` için örtük fat-pointer/vtable fallback ister; güncel belgeler
  protokol tipli koleksiyonları reddediyor. Temsil, ARC davranışı, ABI ve
  dispatch seçimi onaylanmadan uygulanmaz.
- [ ] **2.2 Protokol dispatch'in iki yolunu tamamla.** Tek/az somut tipte
  monomorphization; gerçekten heterojen koleksiyonda fat-pointer fallback.
  Her protokol için iki backend'de iki yolun golden testi zorunlu.
- [ ] **2.3 Protokol değerleri için ownership analizi ekle.** Container'a
  girme/çıkma, closure, return, exception ve cycle collector davranışını
  doğrula; belirsizlikte sessiz ARC fallback kullan.
- [!] **2.4 Generic sınıfta generic metod kararını ver.** Güncel sınır
  `Box[T].map_to[U]` desteğinin olmamasıdır. Monomorphization anahtarı ve
  type-argument inference tasarımı onay ister.
- [!] **2.5 Task/Channel koleksiyonları kararını ver.** `list[Task[T]]`
  desteklenmiyor. Runtime handle yaşam süresi ve cross-worker ownership
  kanıtlanmadan yüzey eklenmez.

**Faz 2 çıkış kapısı:** AGENTS §12 ile public belgeler/kod aynı sözleşmeyi
anlatır; her dispatch yolu iki backend'de testlidir.

## Faz 3 — P1 Nox mobil runtime ve ABI doğruluğu

- [ ] **3.1 Mobil ABI primitive korpusunu tamamla.** `int`, `float`, `bool`,
  C-layout struct return/argument, callback ve yanlış ABI sürümü.
- [ ] **3.2 String/buffer sınırını tamamla.** Türkçe/Unicode, embedded NUL,
  invalid UTF-8, borrow/copy ömrü ve kapanıştan sonra kullanım.
- [ ] **3.3 Exception sınırını tamamla.** Nox exception'ı C/Swift/JNI
  çerçevesinden kaçmadan kod + okunabilir hata nesnesine dönüşsün; başarı ve
  hata yolu testleri olsun.
- [ ] **3.4 ARC/ASAP/cycle mobil stresini tamamla.** 10.000 lifecycle testi
  cihaz/simülatör sanitizer koşusuna, collection/cycle ve callback baskısına
  genişletilsin.
- [ ] **3.5 Fiber/TLS/stack doğrulamasını tamamla.** Apple pointer
  authentication, Android ARM64, guard page, stack overflow ve TLS destructor
  gerçek hedefte sınansın.
- [ ] **3.6 UI-thread pump bütçesini doğrula.** Yoğun event/async altında
  `pump` frame bütçesini aşmasın; suspend/resume sonrası queue sırası
  deterministik olsun.
- [ ] **3.7 Mobil stdlib sandbox testlerini tamamla.** Kök sınırı, `..`,
  symlink/canonical path, atomic write, disk-full, SQLite ve cache/temp
  davranışı.
- [ ] **3.8 Mobil ağ matrisini tamamla.** DNS IPv4/IPv6, offline, timeout,
  TLS sertifika reddi, ağ değişimi ve background/resume.
- [ ] **3.9 Entropy/clock/log sözleşmesini tamamla.** Güvenli RNG, monotonic
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
- [ ] **4.6 Kanıt zincirini sertleştir.** Kanıt dosyası temiz/tagli Nox ve
  Aura commit'i, toolchain, target, backend, run/build ayrımı ve artifact
  SHA-256 taşısın. Bayat/kirli kanıt stable kapısını açamasın.
- [ ] **4.7 Stable gate'i fail-closed yap.** Zorunlu anahtar eksikliği de
  `=no` gibi hata olsun; signed IPA/APK/AAB ve device lab olmadan
  `supported` yazılamasın.
- [!] **4.8 Destek seviyesi yükseltme kararı.** Bütün kapılar yeşil olduktan
  sonra her target ayrı ayrı `preview`/`supported` ilan edilir.

## Faz 5 — P2 masaüstü ve mimari platform kapsaması

- [ ] **5.1 Windows guard-page repro testini ekle.** Fiber testi bugün
  Windows'ta TODO ile skip ediliyor.
- [ ] **5.2 Windows belge/CI gerçeğini eşleştir.** CI tam `zig build test`
  çalıştırırken platform belgesi hâlâ yalnız smoke/full-suite yok diyor;
  gerçek kapsam ölçülüp tek doğru ifade kullanılmalı.
- [ ] **5.3 macOS x86-64 CI ekle veya açıkça destek dışına çıkar.** Bugünkü
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

- [!] **6.1 HPy profilinin ürün hedefini seç.** `nox-hpy-host-v1` çalışıyor
  fakat public stdlib'de preview. Stabilize etme ölçütleri ve sürüm politikası
  belirlenmeli.
- [ ] **6.2 AGENTS HPy Tier tablosuyla gap matrisi çıkar.** Tier 0–3 API'leri
  mevcut host surface ile tek tek karşılaştır; destek iddiasını gerçek C
  extension fixture'larına bağla.
- [ ] **6.3 HPy container/call surface'i genişlet.** List/tuple/dict,
  defaults/overload/variadic ve gelişmiş buffer davranışları yalnız ownership
  sözleşmesi ve gerçek extension testiyle eklenir.
- [ ] **6.4 CPython uyumluluk iddiasını dürüstçe sınırla.** NumPy/Pandas
  hedefi için gereken gerçek API matrisi, eksik semboller ve test programı
  hazırlanmalı; “as-is çalışır” denmemeli.
- [ ] **6.5 WASM interpreter kapsam matrisi çıkar.** Bugünkü parser/interpreter
  yalnız sınırlı instruction/value türlerini destekliyor. İstenen WASM
  surface'i belirle, trap/error ve fuzz korpusunu genişlet. WASM backend
  kesinlikle eklenmez.
- [!] **6.6 Asenkron native callback tasarımını kararlaştır.** Mevcut callback
  yalnız senkron ve primitive imzalıdır; timer/event-loop callback'leri ayrı
  handle/lifetime/reentrancy tasarımı olmadan açılmaz.

## Faz 7 — P2 güvenlik ve tedarik zinciri

- [!] **7.1 Paket imzalama tasarımı.** `nox.lock` commit/hash pinler ancak
  paket imzası/audit yoktur. Trust root, key rotation, revocation ve offline
  doğrulama ADR'si gerekir.
- [!] **7.2 Capability enforcement tasarımı.** Plugin capability'leri bugün
  consent metadata'sıdır, sandbox değildir. OS-level enforcement ayrı tasarım
  olmadan vaat edilmez.
- [!] **7.3 Untrusted source çalışma modeli.** `noxc run` tam süreç yetkisiyle
  çalışır. İstenirse container/seccomp/sandbox launcher ayrı ürün yüzeyi
  olarak tasarlanır; `extern def`e yarım “safe mode” eklenmez.
- [ ] **7.4 Registry güvenlik kapılarını genişlet.** Metadata approval,
  malware/native-code uyarısı, provenance/SBOM ve incident response akışı
  belgelenip test edilmeli.
- [ ] **7.5 FFI sınır fuzzing'i ekle.** NNI, Plugin API, HPy, WASM ve embed
  ABI için length/null/version/ownership girdileri fuzz edilmelidir.

## Faz 8 — P3 dil/stdlib kapsam kararları

Bu maddeler doğruluk açığı değil, belgelenmiş kapsam genişletmeleridir. Her biri
ayrı kullanıcı kararı ve dil özelliği süreci gerektirir.

- [!] **8.1 `*args` / `**kwargs`, keyword-only ve call-site unpacking.**
- [!] **8.2 Çoklu kalıtım.** MRO, field layout, protocol ve ARC etkisi.
- [!] **8.3 Class-level attributes ve static/class/property yüzeyi.**
- [!] **8.4 Annotated `self.x: T = v` ve nested empty literal inference.**
- [!] **8.5 Closure içinde dış değişkene yazma (`nonlocal` eşdeğeri).**
- [!] **8.6 Lazy generator/yield ve arbitrary await/async iteration.**
- [!] **8.7 Unicode genişletmesi.** ASCII-only identifiers/case işlemleri,
  shaping/normalization kapsamı ayrı ayrı seçilmeli.
- [!] **8.8 Regex/TOML/YAML tamlık hedefleri.** Mevcut belgeli subset'ler
  “tam standart” diye sunulmaz; ihtiyaç halinde ayrı uyumluluk matrisleriyle
  genişletilir.

## Faz 9 — P3 performans, gözlemlenebilirlik ve belge doğruluğu

- [ ] **9.1 Benchmark baseline'ını v2.0.27 ile yenile.** Güncel sonuç dosyası
  hâlâ eski `noxc 1.26.6` metadata'sı taşıyor. Makine, Zig, backend ve
  min/avg/max aynı koşuda kaydedilmeli.
- [ ] **9.2 QBE/LLVM/C farklarını yeniden ölç.** Debug sonuç kullanılmaz;
  ReleaseFast, uzun çalışan kernel ve istatistiksel tekrar zorunlu.
- [ ] **9.3 Dict iki-lookup maliyetini incele.** Insertion order ve hash seed
  semantiğini bozmadan tek-lookup tasarımının değeri ölçülür.
- [ ] **9.4 Matmul/list dolaylama ve bounds-check maliyetini profille.** Ancak
  ölçüm ve iki-backend semantik testi sonrası optimizasyon yapılır.
- [ ] **9.5 Doküman sözleşme testi ekle.** Platform destek tablosu, CLI target
  listesi, backend seçimi, versiyon ve mobile matrix koddan türetilmeli veya
  CI'da çapraz doğrulanmalı.
- [ ] **9.6 Tarihsel spesifikasyonu normatif başvurudan ayır.** Kronolojik
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

