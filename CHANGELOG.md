# Değişiklik Günlüğü (Changelog)

Bu proje [Semantic Versioning](https://semver.org/lang/tr/)yi izler —
semver politikası/stabilite garantisi İÇİN bkz. `VERSIONING.md`.
`v1.0.0`dan ÖNCEKİ değişiklikler (Faz Q'dan itibaren, temel
sağlamlaştırmadan paket ekosistemi olgunlaşmasına kadar TÜM üretim-
hazırlığı yol haritası — bkz. `docs/uretim-hazirlik-analizi.md`) TEK bir
`[1.0.0]` girişi altında toplanmıştır; öncesi için
`nox-teknik-spesifikasyon.md`nin tam geliştirme geçmişine bakın.

`v1.0.0`dan SONRA (2026-07-24'ten itibaren) `VERSIONING.md` §4'ün "her
commit bir sürümdür" politikası GEÇERLİDİR — `main`e giden HER commit
KENDİ sürüm başlığı altında (aşağıya SIRAYLA eklenir, EN YENİ EN
ÜSTTE) gerçek bir git tag'i + GitHub Release olarak yayımlanır; artık
BİRİKEN, henüz etiketlenmemiş bir `[Yayımlanmamış]` bölümü YOKTUR.

## [1.99.6]

### Düzeltildi

- `binary_size_test`nin dead-stripping bekçisi (`tests/cli/binary_size_
  test.zig`) — v1.99.5'in push'unun GERÇEK CI koşusunda (Linux/aarch64,
  ReleaseFast) İkili `10.588.104` bayt ölçüldü, ESKİ 10 MB sınırını
  SADECE ~%1 AŞTI. Dead-stripping'in KENDİSİ HÂLÂ ÇALIŞIYOR (AYNI testin
  KESİN kontrolü — smtp/postgres sembollerinin `nm` çıktısında HİÇ
  bulunmaması — AYRICA GEÇTİ) — bu SADECE kod tabanının zamanla (yeni
  stdlib modülleri/dil özellikleri) BÜYÜMESİYLE eski sınırın DOĞAL olarak
  aşılması. Sınır 14 MB'a yükseltildi (defans-derinliği bekçisi, KESİN
  kanıt DEĞİŞMEDİ).

## [1.99.5]

### Düzeltildi

- v1.99.4'ün push'unun GERÇEK CI koşusu İKİ AYRI, YENİ bulguyu ortaya
  çıkardı — İKİSİ de düzeltildi:
  - `nox_pool_run` backoff'u (üç site: `pool_bridge.zig`nin İKİ testi +
    `worker_pool.zig`nin `StealTestCtx`si) v1.99.4'ün ~3.175 saniyelik
    penceresiyle DE (bu SEFER macOS/aarch64'te) TEKRAR `stolen_count ==
    0` İLE BAŞARISIZ OLDU — DÖRDÜNCÜ recurrence. Pencere TEKRAR ~4 KATINA
    (~12.775 saniyeye) ÇIKARILDI; BAŞARILI koşularda SIFIR ek maliyet
    DEĞİŞMEDİ. Kök sorun (GERÇEK CI host'unun DEĞİŞKEN/AŞIRI-abone
    kaynak-çekişmesi) hâlâ KANITLANMIŞ değil — bu DAHA GENİŞ bir pencere,
    KESİN bir düzeltme DEĞİL.
  - GERÇEK CI'de (aarch64/Linux) `http_serve_multicore` N=2 testinin
    GERÇEK stack-smashing çöküşü BİR KEZ DAHA TETİKLENDİ VE v1.99.3'ün
    core-dump mekanizması GERÇEKTEN bir `core.prog.<pid>` dosyası
    ÜRETTİ — AMA analiz adımının İKİ AYRI hatası YÜZÜNDEN doğru
    sembolize EDİLEMEDİ: (1) `ls glob* 2>/dev/null | head -n1`, glob
    HİÇBİR ŞEYE eşleşmediğinde `ls`in ARGÜMANSIZ ÇALIŞMA DİZİNİNİ
    listelemesine yol AÇIYORDU ("AGENTS.md"yi "ikili" SANDI); (2)
    `maybeSaveCrashArtifact` (http_serve_multicore_golden_test.zig)
    ÇAĞIRAN test SÜRECİNİN PID'ini kaydediyordu, AMA core dosyasının
    PID'i ÇÖKEN ALT SÜRECİN (`prog`) PID'i — İKİSİ HİÇBİR ZAMAN eşleşmez.
    Düzeltme: yardımcı ARTIK sabit bir isimle kaydediyor, analiz adımı
    PID EŞLEŞTİRMEYE ÇALIŞMIYOR (kaydedilmiş HER ikiliyi HER core
    dosyasına karşı DENİYOR) VE TÜM glob genişlemeleri bash DİZİLERİYLE
    yapılıyor (`ls`e HİÇ PIPE EDİLMİYOR). GERÇEK core+ikili çifti (bu
    turda İNDİRİLİP `lldb` İLE YEREL olarak İNCELENDİ) çöküşün GERÇEKTEN
    `SIGABRT` (glibc'nin `abort()`/`tkill` yolu, "stack smashing
    detected"le TUTARLI) OLDUĞUNU DOĞRULADI — AMA TÜM unwind edilen
    çerçeveler libc'nin İÇİNDE kaldı (Nox-üretimi hiçbir çerçeve
    GÖRÜNMÜYOR): BU, stack-smashing bug SINIFININ KENDİ, YAPISAL bir
    sınırı — bozulma, ÇERÇEVE zincirinin KENDİSİNİ yok ettiğinden,
    HİÇBİR backtrace (sembolize edilmiş OLSA bile) bozulma ANINI/
    ORİJİNAL çağrı-sitesini GERİ getiremez. Kök neden HÂLÂ AÇIK.

## [1.99.4]

### Düzeltildi

- v1.99.3'ün `maybeSaveCrashArtifact`ı (core-dump teşhis mekanizması)
  GERÇEK, kendi-sebep-olduğumuz bir bellek sızıntısı İçEriyordu — `dest`
  yol dizesi `allocator.free` EDİLMİYORDU VE `NOX_CRASH_ARTIFACTS_DIR`
  ortam değişkeni yanlışlıkla TÜM platformlarda (SADECE Linux DEĞİL)
  ayarlanmıştı — GERÇEK CI'de (v1.99.3'ün İLK koşusu) ÜÇ platformun
  ÜÇÜNDE de (`DebugAllocator`'ın leak-tespiti) `zig build test (Debug)`i
  BAŞARISIZ ETTİ. `dest` artık serbest bırakılıyor, `std.process.run`ın
  `mkdir`/`cp` sonuçları da AYNI şekilde serbest bırakılıyor (savunmacı),
  VE ortam değişkeni SADECE Linux'ta ayarlanıyor.
- `nox_pool_run`nin "Faz MN.8 Bulgu A" testi (`runtime/async_rt/pool_
  bridge.zig`) VE `nox_pool_run`nin "GERÇEK spawn/await İÇEREN bir
  entry" testinin backoff'u (`pool_bridge.zig`) VE `worker_pool.zig`nin
  `StealTestCtx`si — v1.99.2'nin 5-adımlı/375ms'lik geri-çekilme (backoff)
  penceresi GERÇEK CI'de (v1.99.2/v1.99.3'ün AYNI push'unda, Linux
  x86-64'te) BİR KEZ DAHA `stolen_count == 0` İLE BAŞARISIZ OLDU — ÜÇ
  sitenin de penceresi ~4 KATINA (~3.175 saniyeye, `5,20,50,100,200,400,
  800,1600`ms) ÇIKARILDI. Başarılı koşularda SIFIR ek maliyet (erken
  çıkış DEĞİŞMEDİ) — bu, AYNI race sınıfının ÜÇÜNCÜ recurrence'i, HÂLÂ
  KESİN kök nedeni ÇÖZMÜYOR (gerçek CI kaynak-çekişmesinin ÖNGÖRÜLEMEZ
  değişkenliği), SADECE gözlem penceresini GENİŞLETİYOR.

## [1.99.3]

### Eklendi (bkz. nox-teknik-spesifikasyon.md §3.185)

- `http_serve_multicore` N=2 testinin Linux/aarch64'teki stack-smashing
  çöküşü İçİn GERÇEK CI'de bir core-dump/backtrace toplama mekanizması
  eklendi — §3.184'ün KENDİ "gelecekteki tur" notunun yerine getirilmesi.
  YEREL Docker reprodüksiyonu (§3.183) güvenilmez olduğundan (valgrind/
  GDB enstrümantasyonu çöküşü BAZEN MASKELİYORDU), teşhis ARTIK GERÇEK
  CI runner'ının kendisinden toplanıyor: test, ÇÖKEN `prog` ikilisini
  (tmpDir silinmeden ÖNCE) kalıcı bir yola kopyalıyor (`NOX_CRASH_
  ARTIFACTS_DIR`); CI (Linux işleri) `kernel.core_pattern`i yapılandırıp
  `ulimit -c unlimited` ayarlıyor, test adımı BAŞARISIZ olsa BİLE
  (`if: always()`) core dosyalarını bulup `gdb`yle GERÇEK bir backtrace'i
  CI logina yazdırıyor VE core+ikiliyi 14 gün saklanan bir artefact
  olarak yüklüyor. SAF bir teşhis-altyapısı eklemesi — runtime/derleyici
  davranışı DEĞİŞMEDİ, henüz aarch64'ün KENDİ kök nedeni ÇÖZÜLMEDİ (bir
  SONRAKİ gerçek çöküşte artık GERÇEK bir backtrace elde edilecek).

## [1.99.2]

### Düzeltildi (bkz. nox-teknik-spesifikasyon.md §3.184)

- **GÜNCELLEME (dürüst düzeltme)**: v1.99.1'in "x18 düzeltmesi çöküşü
  ORTADAN KALDIRDI (10/10 temiz)" iddiası GERÇEK CI TARAFINDAN ÇÜRÜTÜLDÜ
  — v1.99.1 push edildikten SONRAKİ GERÇEK CI koşusu (`35912506219`),
  `x18` düzeltmesi YERİNDEYKEN BİLE, `http_serve_multicore`'un N=2 testinin
  Linux(aarch64) işinde AYNI `stack smashing detected` çöküşüyle TEKRAR
  başarısız OLDU. Bu testin Linux/aarch64'teki GERÇEK kök nedeni HÂLÂ
  KANITLANAMAMIŞ, AÇIK bir sorun olarak KALIYOR — `x18` kaydı zararsız
  olduğundan GERİ ALINMADI, ama "sorunu çözdü" iddiası GERİ ÇEKİLDİ.
- **GERÇEKTEN işe yarayan düzeltme**: AYNI CI koşusu, `nox_pool_run`'ın
  v1.98.0'da ZATEN düzeltilmiş bir testinin Linux(x86-64) işinde AYNI
  risk sınıfıyla (SABİT `sleepMs(5)` bariyeri yetersiz kaldı) TEKRAR
  başarısız olduğunu gösterdi — "task_66e267b4" ailesinin ÜÇÜNCÜ tekrarı.
  SABİT gecikme, üç sitenin (`worker_pool.zig`'in `StealTestCtx`si +
  `pool_bridge.zig`'in iki testi) HEPSİNDE artan bir geri-çekilmeyle
  (5,20,50,100,200ms, "herhangi bir görev çalındı mı" kontrolüyle erken
  çıkan) DEĞİŞTİRİLDİ.

### Doğrulama

`zig ast-check`; `zig build worker-pool-test`/`async-rt-test`
(Debug+ReleaseFast) TEMİZ; TAM paket `zig build test` (Debug+ReleaseFast)
SIFIR regresyon.

### Kritik dosyalar

`runtime/async_rt/worker_pool.zig`, `runtime/async_rt/pool_bridge.zig`.

## [1.99.1]

### Düzeltildi (bkz. nox-teknik-spesifikasyon.md §3.183)

- **GÜNCELLEME**: v1.99.0'ın eklediği teşhis-yazdırma, `http_serve_
  multicore`'un N=2 testinin bir SONRAKİ GERÇEK CI başarısızlığında
  (Linux/aarch64) TAM olarak amaçlandığı GİBİ işe YARADI — v1.99.0'da
  "kesin kök neden KANITLANAMADI, muhtemelen SO_REUSEPORT/`SharedServeBudget`
  zamanlaması" OLARAK belgelenen hipotez **YANLIŞTI**: gerçek çıktı `***
  stack smashing detected ***: terminated` idi — GERÇEK bir bellek-bozulması
  hatası, bir zamanlama sorunu DEĞİL.
- OrbStack İçİnde bir Linux/aarch64 konteynerinde YALITILMIŞ bir
  reprodüksiyonla kanıtlandı: çöküş `runtime/async_rt/thread_bridge.zig`nin
  `nox_thread_join`ında (çapraz-OS-iş-parçacığı tamamlanma pipe'ını
  BEKLERKEN bir fiber GERÇEKTEN askıya alınıp SONRA devam ettirildiğinde)
  Zig'in KENDİ yığın-koruyucusu (stack-protector) TARAFINDAN yakalanıyordu.
  `runtime/async_rt/swap_aarch64.S`nin (fiber bağlam-değişimi) `x18`i
  (AAPCS64'ün "platform yazmacı") HİÇ kaydedip geri YÜKLEMEDİĞİ bulundu
  — `Context`e EKLENİP kaydedildi/geri yüklendi. **Dürüstçe belirtilir**:
  kesin, tek-satırlık bir mekanik kanıt (hangi kodun x18'e GÜVENDİĞİ)
  BULUNAMADI (yeniden-üretme oranı ortama göre DEĞİŞKENDİ) — bu SIFIR-
  riskli/SIFIR-maliyetli bir savunma-derinliği düzeltmesi OLARAK, düşük
  risk + gözlemsel destek (AYNI reprodüksiyon senaryosunda 10/10 temiz
  koşu, ÖNCESİNDE GERÇEK çöküşler VARDI) temelinde uygulandı.
- `runtime/async_rt/pool_bridge.zig`nin İKİNCİ, v1.98.0'da DEĞİŞTİRİLMEMİŞ
  bir testi ("Faz MN.8 Bulgu A") AYNI risk sınıfını (zayıf "8 kez yield"
  zorlaması) taşıyordu VE GERÇEKTEN başarısız oldu — v1.98.0'ın KANITLANMIŞ
  "bariyer + gerçek 5ms uyku" deseni buna da uygulandı.

### Doğrulama

`zig ast-check`; TAM paket `zig build test` (Debug+ReleaseFast, SIFIR
regresyon); Linux/aarch64 konteynerinde 20 `yes`-süreciyle CPU DOYURULUP
`zig build async-rt-test -Doptimize=ReleaseFast` 40/40 temiz; N=2 HTTP
reprodüksiyonu 10/10 temiz (x18 düzeltmesiyle).

### Kritik dosyalar

`runtime/async_rt/fiber.zig`, `runtime/async_rt/swap_aarch64.S`,
`runtime/async_rt/pool_bridge.zig`.

## [1.99.0]

### Değiştirildi (kalan bilinen CI hataları/flake'lerinin toplu düzeltmesi)

Kullanıcının "release'in neden 1.80.1'de takıldığı" sorusu ÜZERİNE
`gh run list --workflow=ci.yml --limit 50` İLE YAPILAN GERÇEK bir
denetim, `ci.yml`'in son ~50 push'un NEREDEYSE TAMAMINDA kırmızı
OLDUĞUNU (v1.95.1'in ci-gate düzeltmesi ARTIK doğru — GERÇEKTEN polling
yapıp GERÇEK CI sonucunu BEKLİYOR — ama arkasındaki CI'nin KENDİSİ
sürekli KIRMIZI olduğundan HİÇBİR release yayımlanamadığını) ORTAYA
ÇIKARDI. Bu, GERÇEK CI loglarından SAMPLE alınarak İNCELENDİ VE üç
AYRI, GERÇEK kök nedene sahip hata BULUNDU/DÜZELTİLDİ:

1. **Faz F.5'in QEMU objcopy hatası (Linux/aarch64)**: `kernel_boot_
   x86_64_test.zig`'in `objcopy -O elf32-i386` POST-LINK dönüşümü,
   Linux (aarch64) runner'ının ÖNTANIMLI `binutils`ında `objcopy:
   invalid bfd target` İLE BAŞARISIZ oluyordu (v1.97.0'ın GERÇEK CI
   koşusunda GÖZLEMLENDİ) — ARM64 İçİn paketlenen `objcopy`, x86 BFD
   hedeflerini (elf32-i386) İÇERMİYOR. `ci.yml`'e `binutils-multiarch`
   kurulum adımı EKLENDİ (Debian/Ubuntu'nun KENDİ standart çözümü);
   AYRICA testin KENDİSİ de savunma-derinliği OLARAK GÜÇLENDİRİLDİ —
   `objcopy` yine de bu hedefi desteklemezse (paket kurulumu HERHANGİ
   bir NEDENLE başarısız olursa) test SERT bir hata YERİNE `SkipZigTest`
   OLUR (`qbe`/`qemu-system-x86_64` PATH'te YOKKEN ZATEN uygulanan AYNI
   "harici araç yetersizse ana takımı KIRMA" ilkesiyle TUTARLI).
2. **`binary_size_test.zig`'in "failed without output" hatası**: KÖK
   NEDEN bulundu — `nm_result`in İDDİALARINDAN (VE boyut kontrolünden)
   ÖNCE, `build_result`in AKSİNE, HİÇBİR `std.debug.print` teşhis
   çağrısı YOKTU. `nm` GERÇEKTEN sıfır-dışı bir çıkışla BAŞARISIZ
   olursa (VEYA beklenmedik semboller BULUNURSA) teşhis TAMAMEN
   SESSİZCE kayboluyordu (GERÇEK CI'de TAM OLARAK bu görüldü). Tüm
   iddialardan ÖNCE `build_result`in KENDİ desenini İZLEYEN diagnostik
   yazdırma EKLENDİ (HEM bu testte HEM `nox.json`/cycle-collector
   testinin İKİ ÇIPLAK iddiasında).
3. **HTTP golden test ailesinin (6 dosya, 16 çağrı sitesi — Faz TEST.3'ün
   `ChildWatchdog`ının ZATEN korduğu, AYNI orijinal liste) `term ==
   .exited` İDDİASINDAN ÖNCE HİÇBİR teşhis YAZDIRMAMASI**: `http_serve_
   multicore_golden_test.zig`'in N=2 eşzamanlı-istemci testi GERÇEK
   CI'de (v1.95.0/v1.95.1'in koşularında) İKİ KEZ `term == .exited`
   İDDİASINDA (watchdog'un çocuk süreci 20 saniye SONRA ÖLDÜRMESİYLE)
   BAŞARISIZ OLDU — SIFIR teşhis metniyle. Bu 16 sitenin HEPSİNE (a)
   `term != .exited` İSE `term`/mevcut stdout(VARSA)/stderr'i yazdıran
   bir teşhis bloğu (`binary_size_test`in AYNI deseni) VE (b) watchdog
   zaman aşımının 20s'den **45s**'ye ÇIKARILMASI (GERÇEK CI'nin — özellikle
   sınırlı vCPU'lu Linux/aarch64 runner'ının, ÇOK sayıda paralel `zig
   build test` ikilisiyle YARIŞIRKEN — bu oturumun 20-`yes`-süreçlik
   YEREL simülasyonundan DAHA AĞIR bir kaynak-çekişmesi yaşadığının
   GÖZLEMLENMESİYLE ORANTILI, makul bir ek pay) EKLENDİ. Kök neden (HANGİ
   worker'ın `SO_REUSEPORT` altında bağlantı ALAMADIĞI/`SharedServeBudget`
   polling'inin NEDEN yeterli olmadığı) KESİN olarak KANITLANAMADI —
   GERÇEK CI'nin kaynak-çekişme PROFİLİ bu makinede TEKRARLANAMADI (20
   `yes`-süreciyle 25 ardışık çalıştırma TEMİZ geçti) — bu YÜZDEN bu
   madde DÜRÜSTÇE "zamanlama-duyarlı, kesin kök nedeni KANITLANAMAYAN"
   OLARAK belgelenir; teşhis EKLENMESİ, BİR SONRAKİ gerçek başarısızlıkta
   (varsa) KESİN teşhisi SAĞLAYACAKTIR.

4. **Windows'un `IoReactor.registerWithTimeout` zaman-aşımı testi**: v1.98.0'ın
   GERÇEK CI koşusunda (Windows işi) `expected 1, found 0` İLE BAŞARISIZ
   OLDU — `WindowsReactor.poll`nin `WSAPoll`e geçirdiği zaman aşımı,
   Windows'un KENDİ varsayılan zamanlayıcı granülerliği (~15.6ms) YÜZÜNDEN
   İSTENEN sürenin TAMAMI DOLMADAN (birkaç ms ERKEN) dönebiliyor — BU
   durumda `now_after >= ctx.deadline_ms` KOŞULU henüz SAĞLANMADIĞINDAN
   TEK bir `poll()` çağrısı `n=0` döner (kqueue/epoll'un DAHA İNCE
   zamanlayıcı çözünürlüğü YÜZÜNDEN macOS/Linux'ta pratikte tetiklenmez).
   Düzeltme: test, ÜRETİM kodunun (`Scheduler.run()`) ZATEN yaptığı GİBİ
   `poll()`ü `n >= 1` OLANA kadar (SINIRLI, 20 deneme İLE) bir DÖNGÜDE
   çağıracak şekilde GÜNCELLENDİ — TEK-çağrı varsayımı KALDIRILDI.

Doğrulama: `zig ast-check` (9 dosya); TAM paket `zig build test`
(Debug: RC=0; ReleaseFast: RC=0) SIFIR regresyonla geçti; `.github/
workflows/ci.yml`'in YAML söz dizimi geçerliliği kontrol edildi.

### Kritik dosyalar

`.github/workflows/ci.yml` (`binutils-multiarch` kurulum adımı),
`runtime/async_rt/io_reactor.zig` (Windows zaman-aşımı testi döngüye alındı),
`tests/golden/kernel_boot_x86_64_test.zig` (objcopy hata-mesajı
kontrolüyle `SkipZigTest`), `tests/cli/binary_size_test.zig` (3 YENİ
teşhis bloğu), `tests/compat/http_serve_multicore_golden_test.zig`/
`http_serve_multicore_pool_golden_test.zig`/`http_serve_golden_test.
zig`/`http_serve_tls_golden_test.zig`/`http_serve_ws_golden_test.zig`/
`router_module_state_golden_test.zig` (16 çağrı sitesinin HEPSİNE
teşhis bloğu + 45s watchdog zaman aşımı).

## [1.98.0]

### Değiştirildi (`nox_pool_run` çapraz-worker çalma testinin (task_66e267b4) kalıcı düzeltmesi)

- `runtime/async_rt/pool_bridge.zig`nin "GERÇEK spawn/await İÇEREN bir
  entry, TÜM sonuçlar doğru VE kanıtlanmış çapraz-worker çalma" testi
  (`stolen_count > 0` iddiası), `runtime/async_rt/worker_pool.zig`nin
  v1.95.0'da düzeltilen `StealTestCtx` yarışıyla AYNI SINIFTAN, AMA
  AYRI/BAĞIMSIZ bir kök nedene sahip GERÇEK bir yarıştı: `poolRunDriverThreadMain`
  `entry_task`i (bu testin `Global.realEntry`i) kardeş worker'lar
  `spawnWorkers` İLE başlatılmadan ÖNCE spawn EDİYOR (Faz MN.8 Bulgu A'nın
  KENDİ, doğru düzeltmesi) — AMA `realEntry`nin KENDİSİ 30 alt-görevi
  HİÇBİR yield noktası OLMADAN spawn EDİP HEMEN ardından SIRAYLA `await`
  ÇAĞIRDIĞINDAN, driver'ın `run()` döngüsü kardeşler OS TARAFINDAN
  GERÇEKTEN ZAMANLANMADAN TÜM 30 görevi KENDİ deque'İNDEN TEK BAŞINA
  tüketebiliyordu — `stolen_count == 0`, özellikle CI'nin ağır paralel
  yükü ALTINDA ARA SIRA gözlemlenen bir başarısızlık.
- Düzeltme, `worker_pool.zig`nin KANITLANMIŞ "bariyer + GERÇEK uyku"
  desenini BURAYA taşır: `nox_pool_run`a ARTIK `null` YERİNE bir
  `globals_init_fn` geçirilir — bu callback (HEM driver HEM HER kardeş
  TARAFINDAN, `poolRunDriverThreadMain`/`poolWorkerMain`nin KENDİ, ZATEN
  VAR OLAN çağrı noktalarından TAM OLARAK BİR KEZ çağrılır) bir "worker
  başladı" sayacını ARTIRIR. `realEntry`, TÜM 4 worker (1 driver + 3
  kardeş) KENDİ çağrısını yapana KADAR bir bariyerde bekler, SONRA 30
  görevi spawn edip 5ms'lik GERÇEK bir uyku (`sleepMs`, `worker_pool.zig`nin
  AYNI `nanosleep`-tabanlı yardımcısı) İLE kardeşlere GERÇEK bir OS
  zaman dilimi tanır, ANCAK SONRA `await` döngüsüne başlar.
- Doğrulama: `zig build async-rt-test` (Debug+ReleaseFast) TEMİZ;
  20 `yes`-süreci İLE TÜM CPU çekirdekleri DOYURULUP (`worker_pool.zig`nin
  v1.95.0'daki AYNI reprodüksiyon yöntemi) `zig build async-rt-test
  -Doptimize=ReleaseFast` **40/40 KEZ** TEMİZ geçti (ÖNCEKİ davranışla
  KARŞILAŞTIRMA İçİn ELLE doğrulanan orijinal, DÜZELTİLMEMİŞ kod bu AYNI
  yük altında ARA SIRA `stolen_count == 0` İLE başarısız oluyordu); TAM
  paket `zig build test` (Debug+ReleaseFast) SIFIR regresyonla geçti.
- `tests/compat/http_serve_multicore_golden_test.zig`nin N=2 eşzamanlı-
  istemci testi de (v1.95.1'in CI koşusunda GÖZLEMLENEN İKİNCİ aday)
  AYNI yöntemle (20 `yes`-süreci ALTINDA, 25 ARDIŞIK çalıştırma)
  İNCELENDİ — TEK bir başarısızlık BİLE ÜRETİLEMEDİ. Bu testin mekanizması
  (İKİ BAĞIMSIZ OS iş parçacığının AYNI, GERÇEK bir `listen()` fd'sinde
  kernel-seviyesi `accept()` + TCP dinleme kuyruğu (backlog) çağırması)
  `nox_pool_run`/`worker_pool.zig`nin fiber-seviyesi, kullanıcı-alanı
  work-stealing yarışıyla YAPISAL olarak FARKLIDIR — "bariyer+gerçek-
  uyku" deseninin BURADA doğrudan bir karşılığı YOK, VE bu test Faz
  TEST.3'ün `ChildWatchdog`ı TARAFINDAN ZATEN korunuyor (GERÇEK bir
  mekanizma bozulursa test SESSİZCE geçmez, 20 saniye SONRA HIZLI/AÇIK
  bir şekilde başarısız olur). `task_66e267b4`nin CHANGELOG'daki KENDİ,
  ÖNCEDEN yazılmış tanımı (v1.80.8) da BUNU zaten SADECE `pool_bridge`/
  `worker_pool`in İÇ çapraz-worker yarışı OLARAK sınırlıyordu — bu YÜZDEN
  BU testte BİLİNÇLİ olarak HİÇBİR DEĞİŞİKLİK YAPILMADI (spekülatif bir
  "düzeltme" İCAT ETMEK yerine, dürüstçe "reprodüklenemedi" OLARAK
  raporlanıyor).

## [1.97.0]

### Eklendi (Faz F.5 — GERÇEK QEMU bare-metal boot testi ARTIK CI'de çalışıyor)

- `tests/golden/kernel_boot_x86_64_test.zig` (Faz F.4'ün, x86_64
  bare-metal kernel'i GERÇEK bir QEMU'da çalıştırıp 6 checkpoint string'ini
  VE `isa-debug-exit`in KESİN çıkış kodunu doğrulayan testi) ZATEN
  `build.zig`nin `test_step`ine BAĞLIYDI, AMA `qemu-system-x86_64` PATH'te
  BULUNAMADIĞINDA `SkipZigTest` İLE SESSİZCE atlanıyordu — CI'de qemu HİÇ
  KURULMUYORDU, bu YÜZDEN bu test v1.92.0'DAN (Faz F.4) BERİ CI'de HİÇ
  GERÇEKTEN ÇALIŞMAMIŞTI (sadece geliştirici makinelerinde, qemu ELLE
  kurulduğunda). `ci.yml`nin ana matrisine (macOS: `brew install qemu`,
  Linux: `apt-get install qemu-system-x86` — HER İKİSİ de x86_64'ü, HOST
  mimarisinden BAĞIMSIZ olarak EMÜLE eder) YENİ birer kurulum adımı
  eklendi — `build.zig`ye/test koduna HİÇBİR DEĞİŞİKLİK GEREKMEDİ (test
  ZATEN doğru bağlıydı, sadece ortam eksikti).

## [1.96.0]

### Düzeltildi (GPT-5.6 incelemesinde bulunup DOĞRULANAN iki GERÇEK hata)

- **Release paketi freestanding runtime nesnesini TAŞIMIYORDU**: `zig
  build` HER platformda KOŞULSUZ olarak `zig-out/lib/noxrt-freestanding.o`
  ÜRETİYOR (`compiler/project.zig`nin `resolveResourceDirs`ı `noxc build
  --profile freestanding`nin linker adımı İçİn BUNU ARAR) AMA `.github/
  workflows/release.yml`nin paketleme adımı (HEM macOS/Linux HEM Windows)
  BUNU HİÇ kopyalamıyordu — GitHub Release'den `install.sh`/`install.ps1`
  İLE kurulan bir `noxc`, `--profile freestanding` derlemesinde "dosya
  bulunamadı" İLE BAŞARISIZ olurdu (kaynaktan derleyenler ETKİLENMİYORDU).
  Düzeltme: HER İKİ paketleme adımına da `noxrt-freestanding.o` EKLENDİ.
- **`noxc check`/`noxc build` `lowlevel:` kısıtlamasında ANLAŞMAZ HALDEYDİ**:
  `ptr_from_int`/`ptr_to_int`/`ptr_add`/`ptr_read_int`/`ptr_read_float`/
  `ptr_read_bool`/`ptr_write_int`/`ptr_write_float`/`ptr_write_bool`/
  `detach`/`adopt`in "yalnızca bir `lowlevel:` bloğu İçİnde kullanılabilir"
  kısıtlaması SADECE codegen'in `in_lowlevel_depth`inde uygulanıyordu —
  `noxc check` BU builtin'leri BİR `lowlevel:` bloğunun DIŞINDA da (tür
  olarak GEÇERLİ sayıp) SESSİZCE KABUL EDİYORDU, SADECE `noxc build`
  codegen aşamasında GENEL/YANILTICI bir "desteklenmeyen yapı" mesajıyla
  reddediyordu (GERÇEK NEDENİ HİÇ GÖSTERMEDEN) — GERÇEK, ampirik olarak
  DOĞRULANAN bir `check`/`build` semantik tutarsızlığı. Düzeltme: checker'a
  YENİ bir `in_lowlevel_depth` sayacı (`.lowlevel_stmt`in KENDİ gövdesinde
  artırılıp/azaltılan, codegen'in KENDİ, AYRI sayacıyla AYNI İSİM/AMAÇ AMA
  BAĞIMSIZ) + YENİ `LowlevelRequired` tanı kodu EKLENDİ — BU 11 builtin'in
  HER BİRİ ARTIK `noxc check`TE de, `noxc build`DA da AYNI, DOĞRU/AÇIKLAYICI
  mesajla ("'{isim}' yalnızca bir 'lowlevel:' bloğu içinde kullanılabilir")
  reddedilir.

## [1.95.1]

### Düzeltildi (GERÇEK — `release.yml`nin ci-gate'i v1.80.2'DEN BERİ, 15 SÜRÜM BOYUNCA, İSTİSNASIZ HER releasei engelledi)

- Kullanıcı GitHub'da "latest release"in HÂLÂ v1.80.1'de takılı KALDIĞINI
  fark ETTİ — `gh run list --workflow=release.yml` İLE DOĞRULANDI:
  v1.80.2'den (Faz CI.1, ci-gate'in EKLENDİĞİ sürüm) v1.95.0'A KADAR HER
  TEK release çalışması **6-8 saniyede** BAŞARISIZ olmuş. **Kök neden**:
  `ci-gate`'in ORİJİNAL kontrolü TEK-ATIŞLIKTI (poll YOK) — `release.yml`
  `v*` etiketi push edildiğinde ANINDA tetiklenirken, `ci.yml` (AYNI
  commit'in `main`e push'uyla TETİKLENEN, TAMAMEN AYRI bir workflow)
  17-30 DAKİKA sürüyor — gate HER ZAMAN "ci.yml HENÜZ tamamlanmadı" İLE
  BAŞARISIZ oluyordu, CI'nin GERÇEKTEN yeşil olup OLMAMASINDAN TAMAMEN
  BAĞIMSIZ olarak. **Bu, CI'nin kendisinin kırmızı olmasından KAYNAKLANMIYORDU
  — gate'in KENDİSİ, tasarım gereği, ASLA geçemiyordu.**
- **Düzeltme**: `ci-gate` ARTIK bir `while` DÖNGÜSÜNDE poll eder (30
  saniyede bir, EN FAZLA 35 dakika — `ci.yml`nin KENDİ HER-işteki 30-
  dakikalık sınırının ÜZERİNDE CÖMERT bir pay) — `ci.yml`nin BU commit
  İçİn GERÇEKTEN `completed` duruma ULAŞMASINI BEKLER, SONRA sonucunu
  kontrol eder. Güvenlik garantisi DEĞİŞMEDİ (HÂLÂ `conclusion==success`
  OLMADAN release YAYIMLANMAZ) — SADECE "henüz bitmedi" İLE "gerçekten
  başarısız" AYIRT edilir hale geldi.
- **Sonuç**: v1.80.2-v1.94.0 arasındaki 14 sürüm HİÇBİR ZAMAN GERÇEK bir
  GitHub Release olarak yayımlanmadı (kod `main`de VE her commit'in KENDİ
  git tag'i VARDI, SADECE `gh release` varlık paketleri EKSİKTİ) — BU
  düzeltme SONRASI `v1.95.1` (VE sonraki HER sürüm) ARTIK GERÇEKTEN
  yayımlanacak. Geçmiş sürümlerin GERİYE DÖNÜK yayımlanıp YAYIMLANMAYACAĞI
  (workflow_dispatch İLE) kullanıcının AYRI kararı.

## [1.95.0]

### Düzeltildi (v1.94.0'ın GERÇEK CI koşusuyla bulunan iki AYRI, İLGİSİZ test flake'i)

- **`worker_pool.zig`'in TEK-turlu çapraz-worker çalma testi**
  (`"WorkerPool: GERÇEK spawn/await, TÜM sonuçlar doğru VE kanıtlanmış
  çapraz-worker çalma"`) — bu test KENDİ, ÖNCEDEN belgelenmiş bir yarışa
  SAHİPTİ: worker 0 200 önemsiz görev spawn edip HEMEN KENDİ `sched.run()`
  ÇAĞRISINA GEÇİYORDU, kardeşlerin `std.Thread.spawn`ının OS TARAFINDAN
  GERÇEKTEN ZAMANLANDIĞINI SADECE 8 `std.Thread.yield()` İLE "UMUYORDU" —
  BU HİÇBİR ZAMAN GERÇEK bir GARANTİ DEĞİLDİ. YEREL olarak, TÜM CPU
  çekirdeklerini DOYURAN GERÇEK bir yük ALTINDA (`yes` süreçleriyle)
  BU AÇIKÇA yeniden ÜRETİLDİ (2/40 başarısızlık) — GERÇEK CI koşusunun
  (v1.94.0 push'u) TAM OLARAK BU testte gördüğü hatayla BİREBİR AYNI.
  **Düzeltme (iki parça, BİRLİKTE ZORUNLU)**: (1) YENİ bir `siblings_
  started` atomik SAYAÇ — worker 0 ARTIK görev spawn ETMEDEN/`ready`i
  AYARLAMADAN ÖNCE, TÜM kardeşlerin `attachToPool` SONRASI GERÇEKTEN
  ÇALIŞMAYA BAŞLAYIP `ready`i SPIN-WAIT İLE beklemeye BAŞLADIĞINI
  KANITLAR (8-yield TAHMİNİNİN yerini alan GERÇEK bir bariyer); (2) YENİ
  bir GERÇEK zaman uykusu (`sleepMs(5)`, `std.Thread.yield()`in AKSİNE
  OS zamanlayıcısına "BU iş parçacığını BİR SÜRELİĞİNE ÇALIŞTIRMA"
  GARANTİSİ VEREN) — `ready`i AYARLADIKTAN SONRA, worker 0'ın KENDİ
  `sched.run()`una BAŞLAMASINI ERTELEYİP ZATEN spin-wait'teki kardeşlere
  GERÇEK bir çalışma PENCERESİ TANIR. **YALNIZ (1) YETERSİZDİ** (ELLE,
  GERÇEK bir break→red→fix denemesiyle KANITLANDI: bariyer TEK BAŞINA
  AYNI yük altında 4/40 başarısızlık ÜRETTİ) — (1)+(2) BİRLİKTE, AYNI
  yük altında (VE DAHA AĞIR, 20x CPU aşırı-doyurma) 140/140 denemede
  SIFIR başarısızlık VERDİ.
- **`binary_size_test`nin GERÇEK CI'de "failed without output" İLE
  BAŞARISIZ olması** — v1.93.1'in `-j4`yi geri alması (STW-bariyeri
  deadlock düzeltmesi İçİn ZORUNLU, v1.94.0) `zig build test`i TEKRAR
  TAM paralellikte çalıştırmaya BAŞLADI — bu testin KENDİ `std.process.
  run` çağrıları (`noxc build`/`nm`), ÇOK sayıda eşzamanlı test ikilisinin
  spawn/exec baskısı ALTINDA, ARA SIRA GEÇİCİ bir hatayla (`error.
  SystemResources`/benzeri) BAŞARISIZ olabiliyordu (dosyanın KENDİ,
  ÖNCEDEN eklenmiş teşhis notunun AÇIKÇA belgelediği kök neden). **Düzeltme**:
  YENİ, PAYLAŞILAN `runWithRetry` yardımcısı — HER `std.process.run`
  çağrısını (4 site) EN FAZLA 3 deneme, ARTAN kısa gecikmelerle (200/400ms)
  SARAR — GEÇİCİ spawn hatalarını GÜVENLE aşar, GERÇEK/kalıcı bir hata
  (noxc'nin KENDİ bir derleme hatası VB.) İSE HER denemede AYNI şekilde
  BAŞARISIZ OLACAĞINDAN retry YANLIŞ bir "başarı" ÜRETMEZ.

## [1.94.0]

### Düzeltildi (GERÇEK, önceden var olan bir STW-bariyeri deadlock'u — Faz MN.6/MN.7/MN.8/MN.11'in ÜÇÜNCÜ, DAHA DERİN bir varyantı, gdb İLE KANITLANDI)

- v1.93.1'in `-j4` geri alımı SONRASI GERÇEK CI'de Linux'un (HEM x86-64
  HEM aarch64) `zig build test -Doptimize=ReleaseFast`i HÂLÂ 30-dakikalık
  job-zaman-aşımına takılıyordu — `-j4`nin İLGİSİZ OLDUĞU AÇIKÇA
  kanıtlandı. Kullanıcının "şimdi derinlemesine araştır" talimatıyla
  YEREL bir aarch64 Docker konteynerinde (`--cpus=4`, GERÇEK `clang`
  kurulu, TAM `zig build test` yükü altında) hang 5/6 denemede
  YENİDEN üretildi VE `gdb -p <pid> -batch -ex 'thread apply all bt'`
  İLE HER worker iş parçacığının canlı yığın izi ALINDI.
- **Kök neden**: `runtime/async_rt/scheduler.zig`nin `stwParticipate()`
  bariyerinin katılımcı SAYISI (`n`), `self.sibling_deques.len`
  (HAVUZ-OLUŞTURMA anındaki SABİT worker SAYISI) İDİ — bir worker
  `run()`dan KALICI olarak (TÜM görevler bitince, `plc==0`) çıktığında
  BU sayı HİÇBİR ZAMAN azaltılmıyordu. EĞER bir worker'ın "artık
  hiç görev yok, kalıcı çık" kararı İLE BAŞKA bir worker'ın (cycle-
  collector eşiği aşıldığında) "yeni bir STW round'u BAŞLAT" kararı TAM
  OLARAK AYNI ANDA (İKİ BAĞIMSIZ atomik ÜZERİNDE, ARALARINDA HİÇBİR
  happens-before İLİŞKİSİ OLMADAN) gerçekleşirse, çıkan worker
  `stw_requested==false`i GÖRÜP round'a HİÇ KATILMADAN AYRILIYORDU —
  kalan worker'lar ARTIK ULAŞILAMAZ bir katılımcı sayısını BEKLEYEREK
  `stwParticipate()`in İçİnde SONSUZA KADAR dönüyordu. Faz MN.11'in
  MEVCUT düzeltmesi SADECE "AYNI fiber'ın KENDİSİ `plc`yi 0'a
  İNDİRDİĞİ VE `stw_requested`i de KENDİSİ AYARLADIĞI" durumu (release-
  acquire sıralamasıyla) kapsıyordu — BU turun bulduğu, GERÇEKTEN
  eşzamanlı, ÇAPRAZ-worker yarışını KAPSAMIYORDU.
- **Düzeltme**: `runtime/async_rt/asap.zig`'in `PoolExtension`ına YENİ
  `pool_stw_lock: SpinLock`, `pool_active_workers: atomic(usize)`,
  `pool_stw_round_n: atomic(usize)` alanları EKLENDİ — bir worker'ın
  "kalıcı olarak çık" kararı (`pool_active_workers`i AZALTMAK) İLE
  cycle-collector'ın "YENİ bir STW round'u İSTE" kararı (`stw_
  requested`i AYARLAYIP O ANKİ `pool_active_workers`i `pool_stw_
  round_n`e KAYDETMEK) AYNI kilit ALTINDA, birbirini DIŞLAYARAK
  yapılıyor. `stwParticipate()` ARTIK SABİT `sibling_deques.len`
  YERİNE, HER round İçİn AYRI KAYDEDİLEN `stw_round_n`i okuyor — bu
  YÜZDEN katılımcı sayısı HER ZAMAN O ANDA GERÇEKTEN AYAKTA olan
  worker sayısını YANSITIYOR, ULAŞILAMAZ bir sayıya YAKALANAMAZ.
  `Scheduler`e YENİ `tryPermanentExit()` yardımcısı (KİLİT altında,
  `stw_requested`i KONTROL EDİP GÜVENLİYSE `pool_active_workers`i
  azaltıyor) EKLENDİ, `run()`nun İKİ KALICI-çıkış NOKTASI (`plc==0` VE
  `poolWideDeadlockCheck`) BUNU KULLANACAK şekilde SADELEŞTİRİLDİ.
- **Doğrulama**: DÜZELTMEDEN ÖNCE AYNI Docker ortamında (4-CPU, GERÇEK
  `clang`, TAM `zig build test` yükü) hang 5/6 denemede üretiliyordu;
  DÜZELTMEDEN SONRA 15/15 ardışık deneme (HİÇBİRİ 900 saniyeyi
  AŞMADAN, 17-330 saniye ARASINDA) TEMİZ tamamlandı — SIFIR hang.
  Debug+ReleaseFast TAM paket + `NOX_STRESS_ROUNDS`/MN.6'nın KENDİ
  regresyon testi DEĞİŞMEDEN geçiyor.

## [1.93.1]

### Düzeltildi (v1.93.0'ın KENDİ push'unun GERÇEK CI koşusuyla bulunan bir kendi-kendine-neden-olunan regresyon)

- `ci.yml`ye v1.93.0'da eklenen `-j4` sınırı GERİ ALINDI — GERÇEK bir CI
  koşusuyla (`gh run view`) KANITLANDI: `-j4`, Linux (x86-64)'te `zig
  build test`in NORMALDE birkaç dakikada bittiği yerde 30-dakikalık
  job-zaman-aşımına KADAR ASILI KALMASINA yol AÇTI (`worker_pool.zig`nin
  KENDİ çapraz-worker çalma testi "failed without output" İLE başarısız
  OLDUKTAN HEMEN SONRA, İKİ AYRI 10+ DAKİKALIK SESSİZ boşluk gözlemlendi),
  VE Linux (aarch64)'ta AYRI, İLGİSİZ bir HTTP eşzamanlılık testinde
  (`http_serve_multicore_golden_test.zig`) YENİ bir başarısızlığa NEDEN
  OLDU. AZALTILMIŞ build-paralelliği, "kaynak-çekişmesini AZALTMAK"
  YERİNE M:N zamanlayıcının KENDİ, ÖNCEDEN VAR OLAN iç-zamanlama
  varsayımlarını FARKLI/DAHA KÖTÜ şekilde ETKİLEMİŞ görünüyor — `-j`
  sınırı TAMAMEN kaldırılıp ESKİ (sınırsız/otomatik) davranışa DÖNÜLDÜ.
  `nox_pool_serve`nin çapraz-worker yarışı düzeltmesi (`spawnPinned`,
  v1.93.0) İLE `nox.http`nin HH.7 zaman-aşımı marjı genişletmesi
  DEĞİŞMEDEN/DOĞRU kalıyor — SADECE CI paralellik denemesi GERİ ALINDI.

## [1.93.0]

### Düzeltildi (Release'i bloke eden üç CI hatası — hepsi GERÇEK bir CI koşusuyla bulundu)

- **`nox_pool_serve`nin (`nox.http.serve_multicore`nin havuz-tabanlı,
  havuzsuz varyantı) çapraz-worker "entry çalınması" yarışı** (GERÇEK bir
  bug): HER worker'ın KENDİ accept-döngüsü (`entry_fn`) `scheduler_mod.
  spawn`nin GENEL, ÇALINABİLİR yolu ("spawn-anında çal, İLK-çalıştırmadan
  SONRA sabitlen" modeli) İLE spawn ediliyordu — worker'ın KENDİ `run()`u
  BAŞLAMADAN ÖNCE (`WorkerPool.spawnWorkers`in SIRALI thread-oluşturma
  döngüsü SÜRERKEN), ZATEN BAŞLAMIŞ VE HIZLI biten BAŞKA bir worker BU
  entry görevini ÇALABİLİYORDU — bir worker İKİ accept-döngüsü çalıştırıp
  BAŞKA biri HİÇ çalıştırmıyordu, `nox_pool_serve`nin "HER worker KENDİ
  accept-döngüsünü ÇALIŞTIRIR" garantisini BOZUYORDU. **Düzeltme**: YENİ
  `scheduler_mod.spawnPinned` — `spawn()`nin BİREBİR kopyası, TEK farkla:
  YENİ fiber ÇALINABİLİR deque'e DEĞİL, `markReady` (SADECE `run()`nin
  KENDİ döngüsü TARAFINDAN YEREL olarak pop edilen, `tryStealFromSiblings`in
  ASLA dokunmadığı `self.ready`) İLE yerleştirilir — bu YÜZDEN entry görevi
  YAPISAL olarak ÇALINAMAZ hale gelir. `nox.thread.pool_run`ın (AYNI GENEL
  yolu KULLANAN, AMA entry-affinity GEREKTİRMEYEN) KENDİ, ÖNCEDEN BULUNUP
  ("globals'ı KONUMDAN BAĞIMSIZ yap" İLE) ÇÖZÜLMÜŞ AYNI yarışına
  DOKUNULMADI — SADECE `nox_pool_serve`nin İKİ entry-spawn sitesi (driver +
  sibling worker) güncellendi.
- **`nox.http`nin HH.7 zaman-aşımı testinin ÇOK dar bir CI-zamanlama
  marjı**: "zaman aşımı İçİnde tamamlanan normal bir istek" testi 100ms'lik
  bir sunucu-taraflı okuma zaman aşımına karşı istemcinin SADECE 40ms
  gecikmeyle isteği göndermesini bekliyordu (60ms MARJ) — YÜKLÜ bir CI
  runner'ında iş parçacığı zamanlama gecikmesi BUNU AŞABİLİYORDU. MUTLAK
  değerler `2000ms`/`200ms`ye (1800ms MARJ) büyütüldü, ORANTI (%10)
  KORUNARAK.
- **`binary_size_test`nin "failed without output" hatası**: `std.process.
  run`nin (`noxc build`/`nm` alt-süreçlerini başlatan) KENDİSİ, kaynak-
  çekişmesi ALTINDA (CI'nin `zig build test`i HİÇBİR `-j` sınırı OLMADAN
  çalıştırdığından, TÜM test ikilileri AYNI ANDA kendi alt-süreçlerini
  spawn ediyordu) BAŞARISIZ olduğunda HİÇBİR HATA MESAJI yazdırmıyordu
  (Zig'in test runner'ı BOŞ bir stderr'i "failed without output" olarak
  raporluyor). `catch |err|` İLE AÇIKÇA teşhis mesajı EKLENDİ, VE `ci.yml`nin
  `zig build test` çağrılarına `-j4` eklendi — bu projenin KENDİ, ZATEN
  kanıtlanmış "GERÇEK doğrulama İçİn `-j1` KULLAN" disiplininin (BU turda
  `http_serve_golden_test`nin YEREL bir flake'i BU AYNI teknikle DOĞRULANIP
  RAPORLANDI) CI'YE UYGULANMASI — TAM `-j1` 30-dakikalık job-zaman-aşımını
  RİSKE atabileceğinden, ORTA bir sınır (`-j4`) seçildi.

## [1.92.3]

### Düzeltildi (v1.92.2'nin push'unun GERÇEK CI koşusuyla bulunan bir kendi-kendine-neden-olunan regresyon)

- `tracked-files-check`in v1.92.2'de KENDİSİ TARAFINDAN tetiklenen bir
  YANLIŞ-POZİTİF: `build.zig`ye eklenen bir Türkçe AÇIKLAMA yorumu, GERÇEK
  bir `b.path("...")` çağrısı OLMADAN, `` `b.path("literal-string")` ``
  METNİNİ SÖZ KONUSU EDİYORDU — Faz CI.1'in `tracked-files-check`
  script'inin `grep -oE 'b\.path\("[^"]+"\)'` deseni YORUM/KOD AYRIMI
  YAPMADIĞINDAN, bu METNİ GERÇEK bir kod çağrısı SANIP "literal-string"
  adlı git'te İZLENMEYEN bir dosyaya referans VERİLDİĞİNİ İDDİA ETTİ.
  Yorum, AYNI fikri `b.path("...")`in TAM sözdizimini YAZMADAN AKTARACAK
  şekilde YENİDEN yazıldı (`gh run view` İLE GERÇEK CI'de KANITLANDI).

## [1.92.2]

### Düzeltildi (GERÇEK CI koşusuyla bulunan İKİ regresyon — v1.92.1'in push'u)

- **`tracked-files-check`nin YANLIŞLIKLA reddi**: `build.zig`nin
  `noxrt_kernel_mod`ına `runtime/async_rt/swap_x86_64_kernel.o`yu (bir
  build-artefaktı, `.gitignore`de) ekleyen satır, Faz CI.1'in
  `tracked-files-check`inin `grep -oE 'b\.path\("[^"]+"\)'` deseninin
  YAKALADIĞI bir LİTERAL string kullanıyordu — MEVCUT, ÇALIŞAN İKİ
  benzer zincirin (`swap_asm_o_path`/`swap_asm_freestanding_o_path`)
  KENDİ, ÖNCEDEN kanıtlanmış deseni (yolu bir `const` DEĞİŞKENE
  ÇIKARIP `b.path(değişken)` OLARAK geçirmek — regex'in YAKALAMADIĞI
  şekil) BURAYA da uygulandı (`swap_asm_kernel_o_path`).
- **`kernel.zig`nin x86_64 Linux CI host'larında YANLIŞLIKLA İKİNCİ
  (host-arch, genel-amaçlı) freestanding zincirine force-ref edilmesi**:
  `runtime/lib_freestanding.zig`'in `kernel_x86_64` force-ref'i
  `if (builtin.cpu.arch == .x86_64)` KOŞULUNA BAĞLIYDI — bu koşul
  "SADECE ÜÇÜNCÜ (kernel-özel) zincir x86_64 hedefler" VARSAYIMINA
  DAYANIYORDU, AMA `builtin.cpu.arch` HANGİ build.zig ZİNCİRİNİN
  çalıştığını DEĞİL, SADECE derleme HEDEFİNİN mimarisini yansıtır —
  İKİNCİ (host-arch) zincir de HOST mimarisi TESADÜFEN x86_64 OLDUĞUNDA
  (ör. bir x86_64 Linux CI runner'ı — bu projenin GELİŞTİRME makinesi
  aarch64 OLDUĞUNDAN YEREL olarak HİÇ tetiklenmemişti) AYNI koşulu
  SAĞLAR, `kernel.zig`yi (boot.S'e bağımlı `_kernel_end`/`nox_isr_table`
  extern'leriyle) YANLIŞLIKLA force-ref eder — `tests/cli/
  freestanding_build_test.zig`nin İKİ testi (spawn/await + spawn'sız
  ELF-link testleri) BU YÜZDEN Linux (x86-64) CI job'unda "undefined
  symbol: _kernel_end" / "undefined symbol: nox_isr_table" İLE
  BAŞARISIZ OLUYORDU. **Düzeltme**: `kernel_x86_64`in force-ref'i
  `lib_freestanding.zig`nin KENDİSİNDEN tamamen ÇIKARILIP, YENİ,
  KÜÇÜK bir kök dosyaya (`runtime/lib_freestanding_kernel.zig`,
  `noxrt_kernel_mod`nin — build.zig'in ÜÇÜNCÜ zincirinin — YENİ KÖKÜ)
  taşındı — `builtin.cpu.arch` TEK BAŞINA "hangi zincir" sorusunu
  AYIRT EDEMESE de, "hangi KÖK dosyadan derlendiği" HER ZAMAN AYIRT
  eder. (`_ = importedModule;` şeklinde bir dosyanın TAMAMINI discard
  İLE force-ref etmenin, o dosyanın KENDİ üst-düzey `comptime`
  bloklarını GERÇEKTEN tetiklediği — Zig'in tembel-analiz modelinin
  BEKLENEN AMA bu turda GERÇEK bir `zig build-obj`+`nm` deneyiyle
  DOĞRULANAN bir davranışı — BU çözümün TEMELİDİR.)

## [1.92.1]

### Düzeltildi (GERÇEK CI koşusuyla bulunan bir Linux/Windows regresyonu)
- `build.zig`nin `noxc_mod`ına `.link_libc = true` eklendi — v1.92.0'ın
  `NOX_FREESTANDING_KERNEL_ARCH` dâhilî kancası (`buildOne`) `std.c.getenv`
  KULLANIYOR, bu macOS'ta libSystem'in HER ZAMAN örtük olarak linklenmesi
  yüzünden SESSİZCE çalışıyordu — AMA Linux/Windows'ta (Zig'in VARSAYILANI
  libc-siz bir derleme) "dependency on libc must be explicitly specified"
  İLE `noxc`nin KENDİSİNİN DERLENEMEMESİNE yol AÇIYORDU. Bu, `noxc`
  binary'sinin (freestanding RUNTIME'la KARIŞTIRILMAMALI — SIRADAN bir
  host CLI aracı) TÜM platformlarda derlenmesini engelleyen, GERÇEK bir
  CI koşusuyla (Linux aarch64/x86-64 + Windows, ÜÇÜ de) bulunan bir
  regresyon.

## [1.92.0]

### Eklendi (Faz F.4 — Gerçek bare-metal boot zinciri, x86_64)
- `runtime/freestanding/x86_64/kernel.ld` (YENİ) — Multiboot1-yüklenebilir,
  1MiB'e (0x100000) yüklenen bir x86_64 kernel imajı İçİn linker script.
- `runtime/freestanding/x86_64/boot.S` (YENİ) — Multiboot1 başlığı, 32-bit
  `_start` (identity-map sayfa tabloları KURAR — 0..32MiB, 2MiB huge
  page'lerle — CR3/CR4.PAE/EFER.LME/CR0.PG SIRAYLA açılır, 32-bit `lgdt`
  + uzun-mod GDT'sine `ljmp`), 64-bit `long_mode_start` (`nox_freestanding_
  early_init()` → `main()` → `nox_freestanding_halt()`), 0-31 arası TÜM
  vektörler İçİn ISR trambolinleri (hata-kodu İTEN vektörler AYRI ele
  alınır) + `nox_isr_table`.
- `runtime/freestanding/x86_64/kernel.zig` (YENİ) — `outb`/`inb`, 16550
  UART (COM1) + `serialDiagSink` (diag_sink'e KAYITLI), 256-girdili IDT
  (`idtInstall`), 8259 PIC maskeleme, `nox_isr_dispatch` (`#BP`/vektör 3
  GERİ DÖNER — diğer TÜM vektörler `KERNEL_FAULT` raporlayıp `haltForever()`),
  `nox_freestanding_early_init`/`nox_freestanding_halt` (QEMU
  `isa-debug-exit`) + Nox-çağrılabilir `nox_kernel_phys_base/_limit/_
  trigger_breakpoint`.
- `runtime/freestanding/x86_64/kernel_demo.nox` (YENİ) — F.3'ün `lowlevel:`+
  `ptr_*` yerleşikleriyle SAF Nox'ta yazılmış, serbest-liste tabanlı bir
  fiziksel sayfa allocator'ı + tam bir doğrulama zinciri (seri port →
  `int3` breakpoint dönüşü → sayfa ayırma/serbest bırakma → `list.append`
  İLE ARC/heap → 6 checkpoint string'i).
- `compiler/codegen_qbe/codegen.zig`/`registration.zig` — `Codegen`e
  `profile: Profile` alanı (`generateModule`nin YENİ parametresi);
  `registration.zig`ye `runtimeInitSymbol` — freestanding profilinde
  `$nox_runtime_init` YERİNE `$nox_runtime_init_freestanding` çağrılır
  (hosted'ta SIFIR davranış değişikliği).
- `runtime/lib_freestanding.zig`ye `nox_runtime_init_freestanding`
  (4MiB `.bss`-destekli `FixedBufferAllocator`, `asap.nox_runtime_init_
  with_allocator`e bağlanır) — ARC/list/dict/class ARTIK freestanding'de
  GERÇEK bir heap'e (kernel'in KENDİ `.bss`i) akar.
- `runtime/lib_freestanding.zig`nin `printf`i GERÇEK bir implementasyona
  yükseltildi — `@cVaStart`/`@cVaArg`/`@cVaEnd` (Zig 0.16) İLE `%lld`/
  `%g`/`%s` biçimlerini destekler; TÜM gövde `if (comptime !printf_real)
  return 0;` İLE x86_64-ÖZEL comptime-gate'lenir (aarch64'te HİÇ analiz
  EDİLMEZ, `std.builtin.VaList`'in aarch64+freestanding+LLVM-backend
  kısıtına ASLA GİRMEZ).
- `compiler/qbe_target.zig`ye `nameForArch(arch_name: []const u8) ?[]const
  u8` (ÇALIŞMA-ZAMANI mimari-isim dispatch'i, MEVCUT comptime `name()`e
  DOKUNMADAN) + `compiler/main.zig`ye `NOX_FREESTANDING_KERNEL_ARCH`
  dâhilî ortam-değişkeni kancası — `noxc build --profile freestanding`
  bu KOŞULDA linklemeyi ATLAYIP HAM QBE assembly'sini (`.s`) döner.
- `build.zig`ye ÜÇÜNCÜ, SABİT x86_64 hedefli bir derleme zinciri —
  `zig-out/lib/noxrt-freestanding-x86_64.o` (`use_llvm = true` —
  `kernel.zig`nin `lidt` inline-asm'i Zig'in self-hosted x86_64 backend'i
  TARAFINDAN reddediliyordu) HER `zig build`de üretilir.
- YENİ `tests/golden/kernel_boot_x86_64_test.zig` — `kernel_demo.nox`'u
  GERÇEKTEN derleyip linkleyip (bkz. aşağıdaki "Düzeltildi" — link zinciri
  BEKLENENDEN farklı çıktı) GERÇEK bir `qemu-system-x86_64` çalıştırmasıyla
  doğrular: 6 checkpoint string'i SIRAYLA + `isa-debug-exit`in KESİN `33`
  çıkış kodu. `qbe`/`qemu-system-x86_64`/bir GNU `ld`/`objcopy` PATH'te
  YOKSA SESSİZCE atlanır (CI'de qemu HENÜZ kurulmuyor — F.5'in işi).

### Düzeltildi (GERÇEK QEMU çalıştırmalarıyla ÖLÇÜLEREK bulunan, planın ÖNGÖRMEDİĞİ 4 gerçek bug)
Bu faz, ÖNCEKİ fazların HİÇBİRİNİN karşılaşmadığı — çünkü HİÇBİRİ GERÇEKTEN
bir CPU'da/emülatörde ÇALIŞTIRILMADI — yeni bir sınıf hata ORTAYA
ÇIKARDI. HEPSİ GERÇEK QEMU çalıştırmaları + `-d int`/`-d in_asm` TALEP
İZLERİYLE (register/exception dump + tam disassembly) teşhis edildi:

1. **`.multiboot` bölümü `SHF_ALLOC` bayrağı TAŞIMIYORDU** — `boot.S`nin
   `.section .multiboot` yönergesi bayraksızdı, bu YÜZDEN linker BUNU
   HİÇBİR `PT_LOAD` segmentine DAHİL ETMİYORDU (Multiboot1 başlığı
   çalışma-zamanı imajının TAMAMEN DIŞINDA kalıyordu). Düzeltme: `.section
   .multiboot, "a", @progbits`.
2. **QEMU'nun dahili Multiboot1 yükleyicisi ELF64 kabul ETMİYOR**
   ("Cannot load x86-64 image, give a 32bit one" — GERÇEK bir QEMU
   hatası). `zig cc`nin gömülü LLD'si (`ld.lld`) klasik "elf32-i386
   konteyner + x86_64 kod" hilesini (`OUTPUT_FORMAT(elf32-i386)`) 64-bit
   girdilerle KOŞULSUZ reddediyor ("incompatible with elf32-i386"). GNU
   `ld` bunu KABUL EDİYOR AMA `R_X86_64_REX_GOTPCRELX` relokasyonlarının
   linker-taraflı "relax" (GOT-indirect `mov`u DOĞRUDAN `lea`ya ÇEVİRME)
   adımını elf32-i386 ÇIKTISI İçİn YARIM bırakıyor (extern veri
   referansları — `kernel.zig`nin `nox_isr_table[i]`si — ÇALIŞMA
   ZAMANINDA GARBAGE bir işaretçi okuyup #GP/#PF/#DF zincirine yol
   AÇIYORDU). Çözüm: kernel NORMAL (elf64-x86-64, `zig cc`nin LLD'si
   relax'ı DOĞRU yapıyor) linklenir, SONRA `objcopy -O elf32-i386 -S`
   İLE (TÜM relokasyonlar ZATEN çözüldüğünden GÜVENLİ) ELF32/EM_386
   konteynerine dönüştürülür.
3. **CR4.OSFXSR (bit 9) AYARLANMIYORDU** — Zig'in ürettiği HERHANGİ bir
   SSE talimatı (`movups` GİBİ, struct-kopyalama İçİn SERBESTÇE üretilir)
   `#UD` (Invalid Opcode) İLE ÇÖKÜYORDU. Düzeltme: `boot.S`nin CR4 kurulumu
   ARTIK `CR4.PAE | CR4.OSFXSR | CR4.OSXMMEXCPT` (0x620) AÇAR.
4. Test dosyasının KENDİ ELF-header doğrulaması (`e_machine`/`e_entry`
   alan-genişliği) ELF64 varsayıyordu — madde 2'nin ELF32-konteyner
   SONUCUNA göre GÜNCELLENDİ (`e_machine == EM_386`, `e_entry` 4 bayt).

### Kapsam Dışı (BİLİNÇLİ, plan dosyasının KENDİ notu)
Multiboot bellek-haritası ayrıştırma, Nox-yazılı allocator'ın ARC'ın
LİTERAL backing store'u olması, kesme-güdümlü/yeniden-girişli G/Ç,
Faz F.5'in CI entegrasyonu, genel-amaçlı `--target` bayrağı,
kullanıcı-alanı/SMP/gerçek donanım doğrulaması.

## [1.91.0]

### Eklendi (Faz R.3 + F.1'in tamamlanması — GERÇEK `noxc build --profile freestanding` cross-link akışı)
- `noxc build --profile freestanding <dosya.nox>` ARTIK GERÇEKTEN
  çalışıyor — DAHA ÖNCE `--profile freestanding` SADECE checker'ın
  capability allowlist'ini (Faz F.2) etkiliyordu, `buildOne`'ın linker
  akışı hâlâ hosted `cc`ye/host-OS ABI'sine bağlıydı (Faz R.3'ün "aynı
  mimaride bile Mach-O→ELF linklenemez" bulgusu ÇÖZÜLMEMİŞTİ).
- `build.zig`ye HER `zig build`/`zig build test` çağrısında (top-level
  `-Dtarget`den TAMAMEN BAĞIMSIZ, host mimarisi + freestanding OS İçİn)
  ÇALIŞAN, KALICI bir ikinci derleme zinciri EKLENDİ — `b.resolveTargetQuery`
  İLE bağımsız bir hedef İNŞA EDİP `runtime/lib_freestanding.zig`yi
  `zig-out/lib/noxrt-freestanding.o`ya derler; F.0.7'nin SADECE ELLE
  `zig build-obj` İLE doğrulanan çalışmasını ARTIK KALICI bir regresyon
  KORUMASINA çevirir (`test_step`e bağlı).
- `compile_swap_asm` (fiber bağlam-değişimi assembly'si) `is_freestanding`
  İKEN HOST `cc` YERİNE `zig cc -target <arch>-freestanding-none` KULLANIR
  (macOS'un native `ld`si ELF nesnelerini işleyemediğinden, `tests/golden/
  freestanding_link_test.zig`nin — Faz F.1 — ZATEN kanıtladığı YOL).
- `compiler/qbe_target.zig`nin `name()`i ARTIK `is_freestanding: bool`
  parametresi alır — freestanding İKEN HOST OS'tan (macOS/Windows'un
  ÖZEL ABI'leri) BAĞIMSIZ olarak HER ZAMAN arch-sadece (bare-ABI) hedef
  adını seçer.
- `noxc build --release --profile freestanding` AÇIK bir hatayla
  reddedilir — LLVM backend'inin paylaşılan `WorkerPool`u GERÇEK OS iş
  parçacıkları GEREKTİRİR, freestanding'de HENÜZ ÇÖZÜLMEMİŞ bir etkileşim.
- `compiler/project.zig`nin `ResourceDirs`ına YENİ `noxrt_freestanding_path`
  alanı — `buildOne`nin freestanding linker akışı BUNU (`zig cc -target
  ... -ffreestanding -nostdlib -static`) KULLANIR.
- YENİ `tests/cli/freestanding_build_test.zig` — `spawn`/`await`/`Task[int]`
  KULLANAN GERÇEK bir Nox programının `noxc build --profile freestanding`
  İLE derlenip GERÇEK bir ELF'e (magic + `e_type == ET_EXEC`) linklendiğini
  kanıtlar — F.0.7'nin scheduler-DAHİL kapsamının GERÇEK `noxc` CLI'siyle
  İLK KEZ uçtan-uca doğrulanması.

### Düzeltildi (GERÇEK bir uçtan-uca link denemesiyle ÖLÇÜLEREK bulunan, ÖNCEDEN bilinmeyen boşluklar)
- `runtime/lib_freestanding.zig`ye YENİ, minimal `nox_os_init` — codegen'in
  `genMain`/`genMainAsync`i HER programda KOŞULSUZ çağırıyor, F.0.7 bunu
  hariç tutmuştu.
- YENİ `strcmp` (GERÇEK/doğru bir implementasyon — SAF bellek karşılaştırması,
  HİÇBİR OS ilkeli GEREKTİRMEZ) — `core.nox`nin `Exception`/`ValueError`/
  `IndexError`/`KeyError` sınıfları HER programa OTOMATİK birleştiğinden VE
  Nox üst-düzey fonksiyonlar İçİn ölü-kod eleme YAPMADIĞINDAN, bu sınıfların
  otomatik-üretilen `_eq` metodu HER ZAMAN `$strcmp`i çağırır.
- YENİ `nox_stdin_read_line_raw`/`printf` placeholder'ları — `core.nox`nin
  `input()`u VE `print()` builtin'i AYNI nedenle HER programda koşulsuz
  derleniyor; GERÇEK bir konsol/UART HENÜZ olmadığından (Faz F.4'ün işi)
  bunlar SADECE LİNKLEMEYİ sağlar, ÜRETİLEN ikili bu turda HİÇBİR YERDE
  ÇALIŞTIRILMAZ.
- `build.zig`nin YENİ `noxrt-freestanding.o` hedefine `bundle_compiler_rt
  = true` — `b.addObject`in (yürütülebilir/dinamik kütüphanelerin AKSİNE)
  Zig'in KENDİ `memcpy`/`memset`/`memmove`/`__udivti3`/`__umodti3` GİBİ
  derleyici-runtime sembollerini VARSAYILAN olarak GÖMMEMESİ YÜZÜNDEN
  gerekti (`-nostdlib` bağlamında bunlar BAŞKA hiçbir yerden gelmez).

## [1.90.0]

### Eklendi (Faz F.0.7 — "Kritik düzeltme #3"ün çözümü: `runtime/lib_freestanding.zig`, scheduler/fiber/Task/Channel DAHİL, GERÇEKTEN derlenen bir freestanding runtime kökü)
- F.1'in bulduğu "OS-fallback kodu comptime-gate'lenmemiş" açığı (fiber.
  zig/self_pipe.zig'in mmap/libc çağrıları freestanding'de derlenemiyordu)
  ÇÖZÜLDÜ — kullanıcının "scheduler'ı da kapsama al" kararıyla, `spawn`/
  `await`/`Task[T]`/`Channel[T]` freestanding profilinde TAM olarak
  derlenebilir hale geldi (F.2'nin capability sistemi ZATEN `nox.thread.
  pool_run`/gerçek G/Ç'yi reddettiğinden, bu ÇEKİRDEK dil özelliğinin
  ötesine geçmeye GEREK YOK).
- YENİ `runtime/lib_freestanding.zig` — `noxrt_mod`nin freestanding
  hedeflerdeki KÖK modülü (`build.zig` bunu koşullu seçer): SADECE ARC/
  scheduler/dict/handle çekirdeği (`alloc/{asap,arc,dispatch_registry,
  lowlevel,cycle_detector,defer_stack}`, `errors/{handle,diag_sink}`,
  `async_rt/bridge` [+ transitif olarak fiber/self_pipe/scheduler/channel/
  io_reactor/spinlock/task_local/chase_lev_deque], `collections/{dict,
  list_sort}`, `str`) — `foreign_bridge`/`stdlib_shims/*`/`pool_bridge`/
  `thread_bridge`/`thread_channel` HİÇ import edilmez (lazy analiz
  SAYESİNDE sessizce dışlanır). Hosted derlemeler `runtime/lib.zig`yi
  DEĞİŞMEDEN kullanmaya devam eder.
- `runtime/async_rt/io_reactor.zig`ye YENİ `NullReactor` (kqueue/epoll/
  WSAPoll'ün 4. kardeşi, freestanding'de `IoReactor` OLARAK seçilir —
  `init` başarılı döner, diğer metodlar `error.Unsupported`).
- F.0.1-F.0.5'in AYNI "program-genelinde, atomik `.monotonic` enjeksiyon"
  deseniyle İKİ YENİ sağlayıcı: `dict.zig`'e `EntropyProvider`
  (`nox_register_entropy_provider`, `secureRandomBuf`'ın koşulsuz `arc4random_
  buf`/`SystemFunction036` bağımlılığını değiştirir — kayıt yoksa
  freestanding'de `hashSeed` sabit bir tohuma düşer, v0.1 sınırı) ve
  `errors/handle.zig`'e `HaltProvider` (`nox_register_halt_provider`,
  `std.process.exit(1)`'in yerine geçer — kayıt yoksa freestanding'de
  `while (true) {}`).

### Düzeltildi (self-discovered — F.1'in tahmininin ÇOK ÖTESİNDE bir kapsam, GERÇEK `zig build-obj -target aarch64-freestanding-none` denemeleriyle bulundu)
- `fiber.zig`/`self_pipe.zig`nin OS-fallback gövdeleri (mmap+mprotect/
  VirtualAlloc, POSIX pipe) `allocGuardedStack`/`freeGuardedStack`/
  `makeSelfPipe`/`closeSelfPipeFd`/`signalWakeFd`/`drainWakeFd`nin dispatch
  zincirine comptime-gate'lendi.
- `spinlock.zig`nin `std.Thread.yield()`ı, `scheduler.zig`nin `Scheduler.
  init`indeki `std.Thread.getCurrentId()`ı VE `markReady`nin `is_foreign`
  hesabındaki AYNI çağrısı, `sleepMs`in `std.c.timespec`/`nanosleep`ı
  comptime-gate'lendi (HEPSİ freestanding'de OS iş parçacığı/libc KAVRAMI
  olmadığından çağrılamaz — GERÇEK derleme hatalarıyla KANITLANDI).
- `bridge.zig`nin `nox_async_init`indeki havuz-bağlama bloğu (`worker_pool_
  mod.WorkerPool`ı KOŞULSUZ referans alıyordu — fiber.zig'in ORİJİNAL
  hatasıyla AYNI kök neden, çalışma-zamanı `if`in HER İKİ dalının da
  semantik analiz edilmesi) VE `nox_async_deadlock_abort`ın `std.process.
  exit(1)`i comptime-gate'lendi.
- `cycle_detector.zig`nin `nox_cycle_possible_root`ının havuz-uyandırma
  dalı (`posix.fd_t`, freestanding'de `void`, `@intCast` ile koşulsuz
  analiz ediliyordu) comptime-gate'lendi.
- `diag_sink.zig`nin `defaultStderrSink`i (`std.debug.print`, `std.Io.
  Threaded` üzerinden freestanding'de derlenemeyen bir I/O katmanına
  dayanıyordu) comptime-gate'lendi.
- **En büyük self-discovered bulgu**: `std.heap.page_allocator`/
  `smp_allocator`, bir struct alanının SADECE VARSAYILAN DEĞERİ olarak
  bile kullanılamaz — Zig, `Allocator.VTable`nin fonksiyon-işaretçisi
  alanlarını doldururken her birinin TAM GÖVDESİNİ (sadece imzasını
  DEĞİL) semantik olarak analiz eder, bu da `PageAllocator`ın `pageSize()`
  →`page_size_max` bağımlılığını (freestanding'de `@compileError`) ZORLAR
  — `asap.zig`nin `RuntimeState.bootstrap_allocator`/`injected_allocator`
  varsayılanları, `nox_runtime_init()`in gövdesi, `arc.zig`nin `enqueueAndMaybePump`
  worklist'i, VE (Debug modunda BİLE) `std.heap.DebugAllocator`/
  `arcOwnerThreadOk`ın `std.Thread.getCurrentId()`ı BUNA göre gate'lendi.
- **Break→red→fix (GERÇEK bir düzeltme SIRASINDA bulunan GERÇEK bir
  regresyon)**: `arc.zig`nin `enqueueAndMaybePump`ı İLK denemede `rt`
  mevcut OLDUĞUNDA HER ZAMAN `state.allocator()`e (hosted Debug'da GERÇEK,
  sızıntı-tespit eden `debug_gpa`) geçmişti — `rs.worklist` BİLEREK ÇAĞRILAR
  ARASI YENİDEN KULLANILAN, HİÇ tek-tek serbest bırakılmayan bir havuzlanmış
  tampon OLDUĞUNDAN, bu `nox_runtime_deinit`de GERÇEK bir "sızıntı"
  raporuna yol AÇTI (`codegen_golden_test`in 4 GG.24 fixture'ı İLE
  YAKALANDI). Düzeltildi: hosted tarafı `std.heap.page_allocator`ı (İZLENMEYEN,
  ÖNCEKİ davranış) BİREBİR KORUR, SADECE freestanding (page_allocator'ın
  HİÇ derlenemediği, `rt`nin HER ZAMAN mevcut olduğu tek yol) `state.
  allocator()`e geçer.
- `runtime/lib.zig` (hosted) HİÇ DEĞİŞMEDİ, TÜM gate'ler `is_freestanding`e
  (hosted derlemede HER ZAMAN `false`) bağlı olduğundan hosted davranış
  SIFIR etkilendi.

### Doğrulama
- GERÇEK `zig build-obj -target aarch64-freestanding-none` (host mimarisiyle
  eşleşen, `compile_swap_asm`in host-`cc` sınırlaması nedeniyle — Faz R.3'e
  bırakıldı) — `runtime/lib_freestanding.zig`, Debug/ReleaseSafe/ReleaseFast/
  ReleaseSmall'ın DÖRDÜNDE de SIFIR hatayla derlendi (F.1'in bulduğu 79
  hatadan 0'a).
- `zig build -Dtarget=aarch64-freestanding-none` (TAM build.zig akışı)
  `build.zig`nin YENİ root-file seçimini DOĞRU uyguladığını doğruladı —
  KALAN TEK hata `compile_swap_asm`in hardcoded host `cc`sinin (macOS'ta
  Mach-O üretir) bir ELF hedefine linklenememesi — ÖNCEDEN belgelenmiş,
  BU FAZIN kapsamı DIŞINDA bırakılan bir R.3 sınırlaması (bkz. spec).
- `zig build test` (TAM paket, Debug + ReleaseFast) — SIFIR regresyon.

## [1.89.1]

### Düzeltildi (§3.170 — `external-fixtures.yml`'in v1.81.0'dan beri HER push'ta başarısız olması: zincirli yeniden-vihraç çözümleme hatası)
- `.github/workflows/external-fixtures.yml` (Nyx v0.17.0 + Aether v0.6.5'in
  KENDİ GERÇEK test paketlerini kaynaktan derlenen `noxc`ye karşı
  çalıştırır) tanıtıldığı v1.81.0'dan bu yana 10/10 çalışmada
  BAŞARISIZDI — `ci.yml` HER ZAMAN yeşil kaldığından hiç fark edilmemişti.
- **Kök neden**: `checker.zig`nin `from_imports` mangling'i `from X
  import Y`nin `Y`sinin `X`TE DOĞRUDAN tanımlı olduğunu varsayıyordu —
  `nox.sqlite`nin `Statement`i `nox.db`den PAYLAŞMASI (Faz STD.6) GİBİ
  bir zincirli yeniden-vihraçta (Nyx'in `db.nox`su `from nox.sqlite
  import Statement` yaptığında) yanlış, hiç var olmayan bir sembole
  ("nox_sqlite_Statement") işaret ediyor, TEK derleme biriminin
  PAYLAŞILAN `from_imports` haritası yüzünden `stdlib/nox/sqlite.nox`nin
  KENDİ (doğru) çözümlemesini bile eziyordu.
- YENİ `resolveReExportChains` geçişi (+ `from_imports_orig_name`)
  eklendi — geçerli bir doğrudan-tanım çözümlemesini BULUP zincirdeki
  geçersiz tahminleri düzeltir, sıfır davranış değişikliği riskiyle.
- Nyx'in 45 + Aether'in 20 test dosyasının TAMAMI (gerçek pinned tag'lere
  karşı yerel repro ile) doğrulandı — 0/65 başarısız. YENİ bir regresyon
  testi eklendi (`tests/cli/local_import_test.zig`).
- Ayrıntılar için bkz. `nox-teknik-spesifikasyon.md` §3.170.

## [1.89.0]

### Eklendi (Faz F.3 — Dil uzantısı: `lowlevel:`'in "manuel katman"a genişletilmesi)
- `lowlevel:` bloğunun BUGÜNKÜ "SADECE tahsis stratejisini gevşetir"
  rolü, GERÇEK bir manuel bellek katmanına genişletildi — SIFIR YENİ
  sözdizimi/gramer/lexer/parser değişikliği: TÜM yeni yetenek, `print`/
  `len`/`str` İLE AYNI, ZATEN kanıtlanmış "checker/codegen'in `.identifier`
  dispatch'inde isme göre özel-işlenen yerleşik fonksiyon" kalıbıyla
  sunuldu.
- YENİ 9 `ptr` aritmetiği/okuma-yazma yerleşiği (`ptr_from_int(addr:
  int) -> ptr`, `ptr_to_int(p: ptr) -> int`, `ptr_add(p: ptr, n: int) ->
  ptr`, `ptr_read_int`/`ptr_read_float`/`ptr_read_bool(p: ptr) -> T`,
  `ptr_write_int`/`ptr_write_float`/`ptr_write_bool(p: ptr, v: T) ->
  None`) — `compiler/codegen_qbe/codegen.zig`nin backend-SOYUTLANMIŞ
  `qbeOp2`/`qbeOp2Imm`/`qbeLoad`/`qbeStore` emitter'larını KULLANIR,
  SIFIR EK kod İLE HEM QBE HEM LLVM backend'inde çalışır (bkz. YENİ
  `backend_conformance_test.zig` fixture'ı).
- YENİ `detach(x) -> ptr` — çıplak bir yerel değişkeni (list/dict/class/
  str) ARC yönetiminden KALICI olarak çıkarır (`VarInfo`'ya YENİ `manual`
  bayrağı — `arena`/`borrowed_field` İLE AYNI release-atlama gerekçesi).
  Bir parametre `detach` edilemez.
- YENİ `adopt(p: ptr) -> T` — bir HAM işaretçiyi BEKLENEN tipe göre ARC
  yönetimine geri alır — `T`, `checkExprExpected`/`genExprForTarget`nin
  ZATEN VAR OLAN "hedefin beklenen tipini kullan" mekanizmasıyla (boş `[]`/
  `{}` literallerinin AYNI deseni) çözülür, YENİ bir tipler-birinci-sınıf-
  değer sözdizimi GEREKMEDEN.
- 10 yeni yerleşiğin TÜMÜ SADECE `lowlevel:` İçİnde geçerlidir — bu kısıt
  checker'da DEĞİL (checker TÜR olarak koşulsuz kabul eder — `nox.
  thread.pool_run`'ın QBE'de `error.Unsupported`e düşen, ZATEN kanıtlanmış
  "checker tip-doğruluğunu kabul eder, codegen bağlam kısıtlaması uygular"
  deseniyle TUTARLI), SADECE codegen'de (`in_lowlevel_depth` sayacı
  üzerinden, `main.zig`nin ZATEN karşıladığı genel `error.Unsupported`
  mesajıyla) uygulanır.

### Düzeltildi (F.3'ün KENDİ implementasyonu SIRASINDA bulunan gerçek bir hata)
- `compiler/codegen_qbe/registration.zig`nin `collectLocals`'ı, bir
  `lowlevel:` bloğu İÇİNDEKİ HER `var_decl`'i (nasıl inşa edildiğinden
  BAĞIMSIZ) koşulsuz olarak `.arena = true` (bireysel ARC release'i
  ATLA) İşaretliyordu — `y: T = adopt(p)` İçİn bu YANLIŞTI: `p`'nin
  işaret ettiği bellek GERÇEK bir `nox_rc_alloc` başlığı taşıyabilir
  (`detach`'in KENDİ ürettiği KESİN durum) VE `y`'nin normal ARC release
  ALMASI GEREKİR, aksi halde nesne KALICI olarak sızar. `adopt(...)`
  değerli bir `var_decl` artık `in_lowlevel` blanket kuralından İSTİSNA
  tutulur (kırmızı-takım kanıtı: `lowlevel_detach_adopt_roundtrip.nox`
  fixture'ı BU düzeltme OLMADAN GERÇEK bir bellek sızıntısıyla BAŞARISIZ
  oluyordu, `zig build test`in `expectGolden`'ının "stderr boş olmalı"
  kontrolü TARAFINDAN yakalandı).

### Doğrulama
- YENİ typecheck golden fixture'ları (3): 9 builtin + `detach`'in HEPSİ
  TÜR olarak kabul edilir; `detach`nin çıplak-olmayan bir argümana
  uygulanması reddedilir; `adopt`'un beklenen-tipsiz bir bağlamda
  kullanımı reddedilir.
- YENİ, GERÇEKTEN derlenip ÇALIŞTIRILAN codegen golden fixture'ları (3):
  `ptr_from_int`/`ptr_to_int` round-trip; `detach`+`ptr_add`+`ptr_read_
  int`/`ptr_write_int` İLE bir listenin elemanlarına bireysel erişim;
  `detach`/`adopt` round-trip (bir sınıf örneği).
  Kırmızı-takım (`tests/cli/lowlevel_manual_test.zig`, YENİ, GERÇEK
  `noxc` alt süreciyle): `ptr_read_int`/`detach`/`adopt`'un `lowlevel:`
  DIŞINDA kullanımı `exit(1)` + genel "desteklenmeyen bir yapı" mesajıyla
  reddedilir.
- YENİ backend-conformance fixture'ı (`conformance_lowlevel_ptr_ops.nox`):
  `detach`/`ptr_add`/`ptr_read_int`/`ptr_write_int`'in HEM QBE HEM LLVM
  backend'inde BİREBİR AYNI çıktıyı ürettiğinin somut kanıtı.

## [1.88.0]

### Eklendi (Faz F.2 — Dil seviyesi: capability sistemi, `--profile freestanding`)
- YENİ `Profile` enum'u (`compiler/typecheck/types.zig`, `Backend`den
  TAMAMEN BAĞIMSIZ bir EKSEN) + `Checker.profile` alanı (varsayılan
  `.hosted`, SIFIR davranış değişikliği) — `compiler/codegen_qbe/codegen.zig`
  `Backend`iyle AYNI şekilde yeniden İHRAÇ eder.
- `compiler/typecheck/checker.zig`nin `collectImports`ı, `.freestanding`
  profilinde HANGİ `nox.*` stdlib modüllerinin `import` EDİLEBİLECEĞİNİ
  KISITLAYAN bir allowlist (`FREESTANDING_ALLOWED_MODULES`, 14 modül:
  strings/collections/json/regex/csv/toml/yaml/url/validate/template/
  path/db/orm/gzip) uygular — YENİ `TypeError.FreestandingModuleForbidden`.
  **Transitif bağımlılıklar OTOMATİK yakalanır**: `module_loader.zig`nin
  `loadImportsRecursive`ı BİR stdlib modülünün KENDİ İç `import`larını da
  merged AST'ye KOPYALADIĞINDAN, `nox.router`/`nox.test`/`nox.reflect`
  GİBİ allowlist'te OLMAYAN modüller (`nox.http`/`nox.fs`'e transitif
  bağımlı OLDUKLARI İçİn) allowlist'e AÇIKÇA EKLENMEDEN de doğru şekilde
  reddedilir (bkz. `tests/cli/profile_test.zig`nin `nox.router` testi —
  hata mesajı `'nox.http'`yi gösterir, `'nox.router'`ü DEĞİL).
- `noxc build`/`noxc check`e YENİ `--profile <hosted|freestanding>`
  bayrağı (`compiler/main.zig`nin `BuildOpts`/`parseBuildOpts`/`buildOne`/
  `cmdCheck`i) — bilinmeyen bir profil adı AÇIK bir hatayla `exit(1)`
  yapar. **`--profile freestanding` BU turda HÂLÂ HOST hedefine karşı
  derlenip ÇALIŞTIRILABİLİR** — "capability KISITLAMASI" (dil-seviyesi,
  HANGİ stdlib modüllerinin KULLANILABİLECEĞİ) İLE "hedef mimari/OS"
  (Faz F.1'in `is_freestanding` build.zig dalı) BİLİNÇLİ olarak AYRI,
  BAĞIMSIZ eksenlerdir.
- `tests/golden/typecheck_cases/`e 8 YENİ fixture (14-modüllük pozitif
  allowlist testi + 6 doğrudan-negatif [http/thread/fs/time/random/math]
  + varsayılan `.hosted` profilinin `nox.http`yi HÂLÂ serbestçe kabul
  ettiği regresyon-yok testi), `tests/cli/profile_test.zig` (YENİ, GERÇEK
  `noxc` alt süreciyle — pozitif+doğrudan-negatif+**transitif-negatif**+
  varsayılan-profil-regresyonu+`check --profile`+bilinmeyen-profil-hatası,
  6 uçtan-uca senaryo).

## [1.87.0]

### Eklendi (Faz F.1 — Build sistemi: cross-compile İSKELETİ + QBE-freestanding-link deneyi)
- `build.zig`ye Windows'un KENDİ, ZATEN kanıtlanmış `target.result.os.tag
  == .windows` deseniyle PARALEL bir `is_freestanding` bayrağı
  (`.freestanding`/`.other` hedef etiketleri) — `noxrt_mod`/`hpy_bridge_mod`/
  `wasm_bridge_mod`nin `link_libc`ı freestanding'de `false` olur, `hpy_bridge`/
  `wasm_bridge` importları `noxrt_mod`dan HARİÇ TUTULUR (F.0.1'in KENDİ
  "HPy/WASM köprüsü freestanding'e HİÇ TAŞINMAYACAK" gerekçesiyle TUTARLI).
  `noxrt_mod`nin KÖK dosyası BU turda HÂLÂ `runtime/lib.zig`DİR — SADECE
  İSKELET, GERÇEK bir `noxrt_freestanding` HEDEFİ OLUŞTURULMADI (aşağıdaki
  bulgu YÜZÜNDEN bugün DERLENEMEZ).
- YENİ `tests/golden/freestanding_link_test.zig` — F.1'in KENDİ, ÖNCEDEN
  tanımlanmış falsifiable deneyini (QBE'nin x86_64 SysV çıktısı hiç OS
  OLMADAN linklenebiliyor mu) KALICI bir teste ÇEVİRİR: `qbe -t amd64_sysv`
  İLE (bir veri bölümü + DOĞRUDAN bir fonksiyon çağrısı İçeren) küçük bir
  `.ssa`yı derler, `zig cc -target x86_64-freestanding-none -ffreestanding
  -nostdlib -static` İLE (DÜZ `cc`/`clang` İLE DEĞİL — bkz. aşağıdaki
  bulgu) linkler, sonucun GERÇEKTEN statik/çalıştırılabilir bir ELF (`ET_EXEC`,
  dinamik bölüm YOK) OLDUĞUNU ELF header'ı ELLE OKUYARAK doğrular. `qbe`
  PATH'te YOKSA SESSİZCE `SkipZigTest` (harici araç eksikse ana takımı
  KIRMAMA ilkesi).

### Bulundu (doğrudan deneysel araştırma — İKİ KRİTİK bulgu)
- **Bulgu #1 (OLUMLU CEVAP)**: QBE'nin x86_64 SysV çıktısı — fonksiyon
  çağrıları VE veri bölümleri DAHİL — GERÇEKTEN, SIFIR dinamik/libc/PLT
  bağımlılığıyla freestanding bir ELF olarak linklenebiliyor — AMA SADECE
  linker sürücüsü OLARAK `zig cc` (Zig'in KENDİ, evrensel LLD'si) KULLANILIRSA.
  Düz sistem `cc`si (macOS'ta Apple clang) `ld: unknown file type` İLE
  BAŞARISIZ olur — macOS'un NATİF `ld`si ELF nesne dosyalarını HİÇ İŞLEYEMİYOR.
- **Bulgu #2 (YENİ, "Kritik düzeltme #3")**: F.0.1-F.0.5'in "provider KAYDET,
  OS-fallback kodu KORU" tasarımı, freestanding COMPILE-ZAMANI İçİn YETERSİZ
  — `fiber.zig`nin `allocGuardedStackPosix`ı (`std.posix.mmap`/`PROT`) VE
  `self_pipe.zig`nin `makeSelfPipe`ı (`std.c.pipe`, libc) freestanding/"other"
  hedefte Zig std'sinde HİÇ TANIMLI/ÇÖZÜMLENEBİLİR DEĞİL — provider'ın
  runtime'da KAYITLI OLACAĞI GARANTİSİ, derleyicinin bu fallback dallarını
  (RUNTIME `if`, comptime DEĞİL) SEMANTİK olarak analiz ETMESİNİ ÖNLEMEZ.
  Bu, GERÇEK bir COMPILE hatasıdır (link-zamanı DEĞİL) — comptime-gate'leme
  (`if (builtin.os.tag != .freestanding)`) GEREKTİRİR, AYRI/gelecekteki bir
  faz olarak `nox-teknik-spesifikasyon.md`ye belgelendi.

## [1.86.1]

### Düzeltildi (F.0.5'in `self_pipe.zig` testinde GERÇEK bir Windows derleme hatası)
- v1.85.0'ın GERÇEK Windows CI koşusu (`gh run view` İLE kontrol edilerek
  YAKALANDI — standing instruction) `self_pipe.zig:114`/`:148`de "expected
  type '*anyopaque', found 'comptime_int'" İLE BAŞARISIZ oldu: `posix.
  fd_t` Windows'ta `windows.HANDLE` (`*anyopaque`), POSIX'te `c_int` —
  F.0.5'in sahte-sağlayıcı testindeki `.{100, 101}` tamsayı literalleri
  VE `@as(posix.fd_t, 100)` karşılaştırmaları SADECE POSIX'te GEÇERLİYDİ.
- YENİ `testSentinelFd(comptime n) posix.fd_t` yardımcısı — Windows'ta
  `@ptrFromInt(n)`, AKSİ HALDE düz tamsayı (`completion_pipe.zig`nin
  KENDİ `@ptrFromInt(a)`/`@ptrFromInt(b)` Windows-soket-handle deseniyle
  AYNI) — HER İKİ self_pipe.zig testindeki sentinel değerler VE
  karşılaştırmalar BUNU KULLANACAK şekilde güncellendi, macOS/Linux'ta
  davranış SIFIR değişti (yerelde YENİDEN doğrulandı).

## [1.86.0]

### Eklendi/Değiştirildi (Faz F.0.6 — gizli http_client.zig bağımlılığının kesilmesi, F.0'ın SON alt-fazı)
- Freestanding Nox çerçevesinin F.0.1-F.0.5'ten SONRAKİ VE F.0'ın SON alt-
  fazı: ÇEKİRDEK `runtime/async_rt/thread_channel.zig`/`thread_bridge.
  zig`/`pool_bridge.zig` (`scheduler.zig`nin KENDİ "İlke #6"sıyla — async_
  rt'nin stdlib_shims'ten bağımsız kalması — TUTARSIZ bir şekilde)
  `runtime/stdlib_shims/http_client.zig`yi İTHAL EDİYORDU — HTTP İçİn
  DEĞİL, SADECE genel self-pipe/string-kopyalama yardımcıları İçİn.
- YENİ `runtime/async_rt/completion_pipe.zig` — `http_client.zig`nin
  `makeSelfPipe`/`closeFd`/`signalSelfPipe`/`readSelfPipe`si (Windows UDP-
  loopback implementasyonu DAHİL, `self_pipe.zig`den — F.0.5, POSIX-only,
  farklı amaç — KASITLI olarak AYRI) BİREBİR TAŞINDI.
- `http_client.zig` bu 4 fonksiyonu ARTIK `completion_pipe.zig`den re-
  export eder (`thread_channel.zig`nin KENDİ, ZATEN kanıtlanmış
  `dupeToNoxStr` alias deseninin AYNISı, TERS yönde) — `process.zig`
  (GERÇEK/AYRI bir nedenle — `sharedClientIo()` — http_client.zig'e bağlı
  kalmaya DEVAM eden, kapsam DIŞI tutulan tek dış tüketici) DAHİL TÜM
  mevcut çağıranlar SIFIR değişiklikle çalışmaya devam eder.
- `thread_channel.zig`/`thread_bridge.zig`, `dupeToNoxStr` yerine (ZATEN
  import edilmiş) `str_mod.nox_str_from_bytes`yi DOĞRUDAN çağırır
  (`dupeToNoxStr`nin KENDİ gövdesiyle BİREBİR AYNI) — `pool_bridge.zig`
  bunu HİÇ kullanmıyordu, DOKUNULMADI.
- Sonuç: `thread_channel.zig`/`thread_bridge.zig`/`pool_bridge.zig` ARTIK
  `runtime/stdlib_shims/`e HİÇBİR import zinciri TAŞIMIYOR —
  `scheduler.zig`/`fiber.zig`/`channel.zig`/`io.zig`/`self_pipe.zig` İLE
  AYNI "stdlib_shims'ten bağımsız" ilkesine BU ÜÇ dosya da artık UYUYOR.
- YENİ, `completion_pipe.zig`nin İLK testi (dosya taşınmadan ÖNCE HİÇ
  dedicated unit-testi YOKTU, sadece http_client'in ucuçtan-uca HTTP
  testleri ÜZERİNDEN DOLAYLI egzersiz ediliyordu): `makeSelfPipe`→
  `signalSelfPipe`→`readSelfPipe`→`closeFd` TAM bir turu GERÇEKTEN
  doğrular.
- `zig build test` (Debug+ReleaseFast, `-j2` İLE) + `NOX_STRESS_ROUNDS=800
  zig build stress-test -Doptimize=ReleaseFast` TEMİZ (SAF kod-taşıma —
  davranış SIFIR değişti, bu turda HİÇBİR flake GÖZLENMEDİ).

## [1.85.0]

### Eklendi/Değiştirildi (Faz F.0.5 — Uyandırma mekanizması soyutlaması)
- Freestanding Nox çerçevesinin F.0.1-F.0.4'ten SONRAKİ beşinci alt-fazı:
  `runtime/async_rt/self_pipe.zig`nin `makeSelfPipe`/`closeSelfPipeFd`/
  `signalWakeFd`/`drainWakeFd`si KOŞULSUZ olarak POSIX `pipe()`/`close()`/
  `write()`/`read()` syscall'larını çağırıyordu — bir freestanding hedefte
  NE `pipe()` NE herhangi bir dosya-tanımlayıcısı KAVRAMI VAR.
- YENİ `WakeProviderVTable`/`WakeProvider` — F.0.4'ün `StackProviderVTable`
  sıyla AYNI ptr+vtable şekli — `create(ctx) -> ?[2]posix.fd_t` (read/
  write fd çifti) + `close`/`signal`/`drain(ctx, fd)` (MEVCUT dört
  fonksiyonun İMZALARIYLA BİREBİR AYNI).
- YENİ `nox_register_wake_provider(provider)` — F.0.1/F.0.4'ün AYNI
  "program-genelinde, TEK, atomik, `.monotonic`" deseni (`pub fn`, HENÜZ
  codegen'den ÇAĞRILMIYOR).
- `makeSelfPipe`/`closeSelfPipeFd`/`signalWakeFd`/`drainWakeFd` ARTIK ÖNCE
  kayıtlı sağlayıcıyı kontrol eder — DOLUYSA delege eder, AKSİ HALDE
  (VARSAYILAN, kayıt YAPILMAMIŞ HER program) BUGÜNKÜ POSIX davranışına
  (Windows'ta `error.Unsupported` DAHİL) BİREBİR AYNI şekilde düşer —
  `scheduler.zig`nin 5 çağrı sitesi (`deinit`/`attachToPool`/`markReady`)
  VE `cycle_detector.zig`nin 1 çağrı sitesi (`nox_cycle_possible_root`,
  STW round wake) HİÇBİRİNE DOKUNULMADI.
- YENİ, `self_pipe.zig`nin İLK testleri (dosya ÖNCEDEN sıfır test
  İçERİYORDU): sahte bir sağlayıcı (GERÇEK bir OS pipe'ı KULLANMADAN,
  sentinel fd değerleri + çağrı sayaçlarıyla) kaydedilip DÖRT fonksiyonun
  DA sağlayıcıya GERÇEKTEN ULAŞTIĞI doğrulandı; kırmızı-takım (kayıt
  YAPILMADAN GERÇEK bir OS pipe'ının kullanıldığı, sahte sağlayıcının HİÇ
  ÇAĞRILMADIĞI) AYRICA test edildi VE break→red→fix İLE (kayıt çağrısı
  GEÇİCİ kaldırılıp `expected 100, found 3` İLE testin GERÇEKTEN kırmızıya
  düştüğü görülüp GERİ eklendi) kaydın GERÇEKTEN load-bearing olduğu
  kanıtlandı.
- `zig build test` (Debug+ReleaseFast, TAM paket, `-j1` İLE de) + `NOX_
  STRESS_ROUNDS=800 zig build stress-test -Doptimize=ReleaseFast` TEMİZ
  (bilinen, pre-existing `-j` paralel-yük HTTP/pool test flake'leri —
  `http_serve_golden_test.zig`, `http_serve_tls_golden_test.zig`,
  `http_serve_multicore_pool_golden_test.zig` (N=2 havuzlu, self-pipe
  yolunu EGZERSİZ EDEN test DAHİL), `router_module_state_golden_test.zig`
  — İZOLE çalıştırmayla regresyon OLMADIĞI YENİDEN doğrulandı).

## [1.84.0]

### Eklendi/Değiştirildi (Faz F.0.4 — Fiber yığın kaynağı enjeksiyonu)
- Freestanding Nox çerçevesinin F.0.1/F.0.2/F.0.3'ten SONRAKİ dördüncü
  alt-fazı: `runtime/async_rt/fiber.zig`nin `allocGuardedStack`/
  `freeGuardedStack`si HER fiber yığınını KOŞULSUZ olarak `mmap`+
  `mprotect` (POSIX) / `VirtualAlloc`+`VirtualProtect` (Windows) İLE,
  GERÇEK bir işletim-sistemi sanal-bellek yöneticisi ÜZERİNDEN tahsis
  ediyordu — bir freestanding hedefte NE `mmap` NE `VirtualAlloc` VAR.
- YENİ `StackProviderVTable`/`StackProvider` — `std.mem.Allocator`nin
  AYNI ptr+vtable şekli (repo'daki TEK kanıtlanmış enjekte-edilebilir-
  arayüz emsali, YENİ bir desen İCAT EDİLMEDİ) — `alloc(ctx) -> ?[]align
  (STACK_ALIGN) u8` (TAM `STACK_SIZE` bayt döndürmelidir) + `free(ctx,
  stack)`.
- YENİ `nox_register_stack_provider(provider)` — F.0.1'in `dispatch_
  registry.zig`sıyla AYNI "program-genelinde, TEK, atomik, `.monotonic`"
  deseni (`pub fn`, HENÜZ codegen'den ÇAĞRILMIYOR — F.0.2/F.0.3'ün AYNI
  gerekçesi). `Scheduler`in KENDİSİ (dolayısıyla `Fiber`) `RuntimeState`ten
  BİLİNÇLİ olarak BAĞIMSIZ OLDUĞUNDAN (bkz. `bridge.zig`nin "İlke #6"ı),
  kayıt RuntimeState-scoped DEĞİL, F.0.1 İLE AYNI program-genelinde bir
  global.
- `allocGuardedStack`/`freeGuardedStack` ARTIK ÖNCE `g_stack_provider`i
  kontrol eder — DOLUYSA sağlayıcıya delege eder, AKSİ HALDE (VARSAYILAN,
  kayıt YAPILMAMIŞ HER program) BUGÜNKÜ mmap+mprotect/VirtualAlloc+
  VirtualProtect davranışına BİREBİR AYNI şekilde düşer — `Scheduler.
  acquireStack`/`releaseStack`, `Fiber.create`/`destroy`, `http_server.
  zig`nin bağlantı-fiber'ları HİÇBİRİNE DOKUNULMADI (araştırmanın
  kanıtladığı TEK dispatch noktası SAYESİNDE, TÜM tüketiciler OTOMATİK/
  ŞEFFAF olarak kapsandı).
- YENİ iki Zig testi (`fiber.zig`): sahte bir sağlayıcı (`std.testing.
  allocator.alignedAlloc`/`.free` sarmalayıcısı, sayaçlarla) kaydedilip
  GERÇEK bir `Fiber.create`/`resume_`/`destroy` çevriminin sağlayıcıyı
  TAM OLARAK 1/1 (alloc/free) çağırdığı VE fiber'ın entry fonksiyonunun
  yan etkisinin GERÇEKTEN gözlemlendiği doğrulandı; kırmızı-takım
  (kayıt YAPILMADAN `allocGuardedStack`/`freeGuardedStack` çağrılırsa
  sahte sağlayıcının HİÇ ÇAĞRILMADIĞI, VARSAYILAN mmap yolunun
  kullanıldığı) AYRICA test edildi VE break→red→fix İLE (kayıt çağrısı
  GEÇİCİ kaldırılıp testin GERÇEKTEN kırmızıya düştüğü görülüp GERİ
  eklendi) kaydın GERÇEKTEN load-bearing olduğu kanıtlandı.
- MEVCUT guard-page çökme testi (`fiber.zig`, "Faz MN.8, Bulgu C") —
  kayıt YAPILMADAN (varsayılan mmap+mprotect yolu) DEĞİŞMEDEN, HÂLÂ
  GERÇEK bir SIGSEGV/erişim-ihlaliyle çöktüğünü kanıtlamaya DEVAM eder;
  diğer İKİ mevcut fiber testi (x19 kaçağı/interleaved resume) DEĞİŞMEDEN
  geçti.
- `zig build test` (Debug+ReleaseFast, TAM paket) + `NOX_STRESS_ROUNDS=800
  zig build stress-test -Doptimize=ReleaseFast` TEMİZ (bilinen, pre-
  existing `-j` paralel-yük HTTP test flake'i izole çalıştırmayla
  regresyon OLMADIĞI YENİDEN doğrulandı).
- v1.83.0'ın (Faz F.0.3) GERÇEK CI koşusu (run 35008860150) İNCELENDİ:
  Windows yeşil; Linux (x86-64)'in bilinen `pool_bridge`/`nox_pool_serve`
  cross-worker race flake'i (task_66e267b4) İLE, macOS (aarch64) Debug'ın
  bilinen `-j` paralel-yük HTTP zamanlama flake'i İLE, Linux (aarch64)
  ReleaseFast'in `binary_size_test`nin (subprocess-tabanlı, paralel yük
  altında) YENİ AMA AYNI sınıftan bir flake'i İLE BAŞARISIZ oldu —
  ÜÇÜ de `diag_sink`/F.0.3'ün değiştirdiği HİÇBİR koda DOKUNMUYOR, GERÇEK
  bir regresyon BULUNMADI.

## [1.83.0]

### Eklendi/Değiştirildi (Faz F.0.3 — Panik/tanı çıktısı enjeksiyonu)
- Freestanding Nox çerçevesinin F.0.1/F.0.2'den SONRAKİ üçüncü alt-fazı:
  runtime'ın TÜM tanı/hata çıktısı (yakalanmamış istisna mesajı, bellek-
  sızıntısı raporu, deadlock tanısı, beklenmeyen errno uyarıları)
  `std.debug.print` İLE KOŞULSUZ stderr'e yazıyordu — bir freestanding
  hedefte stderr/OS dosya tanımlayıcıları HİÇ YOK.
- YENİ `runtime/errors/diag_sink.zig`: `dispatch_registry.zig`nin (F.0.1)
  AYNI "program-genelinde, atomik, `.monotonic`" deseni — `nox_register_
  diag_sink(sink)` (Zig-seviyesi, `pub fn`, HENÜZ codegen'den ÇAĞRILMIYOR)
  + paylaşılan `report(rt, fmt, args)` yardımcısı (512 baytlık yığın
  arabelleği). VARSAYILAN (kayıt yapılmazsa) BUGÜNKÜ stderr davranışıyla
  BİREBİR AYNI, SIFIR davranış değişikliği.
- `errors/handle.zig`nin `nox_unhandled_exception`i, `alloc/asap.zig`nin
  sızıntı-raporu, `async_rt/bridge.zig`nin `nox_async_deadlock_abort`ı
  (ARTIK `pub` — `async_rt/pool_bridge.zig`nin KENDİ, tekrarlanan
  deadlock mesajı KALDIRILIP DOĞRUDAN bu fonksiyona YÖNLENDİRİLDİ, GERÇEK
  bir küçük temizlik), `pool_bridge.zig`nin 3 OOM/doğrulama sitesi,
  `async_rt/io.zig`nin `fiberSafeUnexpectedErrno`sı (imzasına `scheduler`
  eklendi) ve `async_rt/io_reactor.zig`nin YENİ, dosya-yerel
  `unexpectedErrnoSafe` yardımcısı (7 çağrı sitesi) hepsi `diag_sink.
  report`e geçirildi — mesaj metinleri BİREBİR AYNI kaldı.
- `async_rt/fiber.zig`nin `printStackHwmMaxForResearch`ı (GG.23'ün
  `NOX_STACK_PAINT` aracı) da `rt` parametresi alıp `diag_sink.report`
  kullanacak şekilde güncellendi.
- **Doğrulama SIRASINDA bulunan, DÜZELTİLEN bir build-sistemi boşluğu**:
  `runtime/async_rt/fiber.zig`/`io.zig`/`io_reactor.zig`, `noxrt_mod`
  (kökü `runtime/lib.zig`) DIŞINDA, KENDİ BAŞLARINA AYRI, DAR test
  modülleri (`fiber_test_mod`/`scheduler_test_mod`/`channel_test_mod`/
  `io_test_mod`, `build.zig`) OLARAK da derleniyordu — bu dosyaların
  `diag_sink.zig`ye YENİ, relative-path importu bu modüllerin kökünü
  (`runtime/async_rt/`) YUKARI aşıp "import of file outside module path"
  hatası veriyordu. `shared/abi_layout.zig`nin ZATEN kanıtlanmış "named-
  module" desenini İZLEYEN YENİ bir `diag_sink` modülü (`build.zig`)
  eklenip TÜM tüketiciler (`noxrt_mod`, 4 standalone test modülü, VE
  `worker_pool_test_root.zig`) BUNU named-import OLARAK ALDI —
  `fiber.zig`nin KENDİ guard-page repro testinin `zig build-exe` çağrısı
  da AYNI `-M`/`--dep` deseniyle güncellendi.
- **Doğrulama SIRASINDA bulunan, DÜZELTİLEN bir test-tasarımı hatası**:
  `nox_runtime_deinit`in sızıntı-raporu sitesini GERÇEK bir kasıtlı
  sızıntıyla (nox_alloc + free-etmeme) tetiklemek, Zig'in KENDİ
  `DebugAllocator`ının BAĞIMSIZ leak-log mekanizmasını (`std.log.err`)
  da tetikleyip test-runner'ın "N errors were logged" sayacını
  BAŞARISIZ ediyordu (test'in KENDİ iddiaları GEÇSE BİLE) — YENİ
  testler `diag_sink.report`i DOĞRUDAN (gerçek bir sızıntı ÜRETMEDEN)
  çağıracak şekilde tasarlandı, `asap.zig`ye eklendi (kayıtlı sahte
  sink'in GERÇEKTEN hedef olduğu + kayıt YOKSA sahte sink'in BOŞ
  kaldığı/kırmızı-takım kanıtı).
- `zig build test` (Debug+ReleaseFast) + `NOX_STRESS_ROUNDS=800 zig
  build stress-test -Doptimize=ReleaseFast` TEMİZ (bilinen, pre-existing
  `-j` paralel-yük HTTP test flake'leri HARİÇ, izole çalıştırmayla
  regresyon OLMADIĞI doğrulandı).

## [1.82.0]

### Eklendi/Değiştirildi (Faz F.0.2 — Allocator enjeksiyonu)
- Freestanding Nox çerçevesinin F.0.1'den (dispatch tablosu statikleştirmesi)
  SONRAKİ ikinci alt-fazı: `RuntimeState`in çalışma-zamanı allocator'ı
  GERÇEKTEN enjekte edilebilir hale getirildi — `nox_runtime_init`
  `RuntimeState`in KENDİSİNİ HERHANGİ bir Nox kodu ÇALIŞMADAN ÖNCE
  `std.heap.page_allocator.create` İLE tahsis ediyordu; bir freestanding
  hedefin "heap zorunlu olmasın" hedefi BU tahsisin de enjekte edilebilir
  olmasını GEREKTİRİYOR.
- YENİ `RuntimeState.bootstrap_allocator`/`injected_allocator` alanları +
  YENİ `nox_runtime_init_with_allocator(backing)` (Zig-seviyesi, `pub fn`
  — HENÜZ codegen'den ÇAĞRILMIYOR). `nox_runtime_init()`nin argümansız
  çağrısı davranışı BİREBİR KORUR (bootstrap HER ZAMAN `page_allocator`,
  `.allocator()` Debug'da `debug_gpa`/Release'de `smp_allocator`).
- `runtime/alloc/lowlevel.zig`nin arena mekanizması (`nox_arena_create`)
  `state.allocator()` ÜZERİNDEN backing tahsis ettiğinden enjeksiyonu
  SIFIR kod değişikliğiyle DEVRALIR.
- **Doğrulama SIRASINDA bulunan VE düzeltilen İKİ GERÇEK, pre-existing
  hata**: (1) `nox_runtime_init_with_allocator`'ın bootstrap/injected
  allocator'ı TEK bir alanda BİRLEŞTİRME İLK tasarımı, argümansız
  `nox_runtime_init()`nin Release modunda bootstrap'ı `smp_allocator`a
  KAYDIRARAK `cycle_detector.zig`/`async_rt/bridge.zig`nin `nox_runtime_
  deinit`i ATLAYIP `state`i ELLE `std.heap.page_allocator.destroy` İLE
  yok eden İç testlerini GERÇEK bir allocator-uyumsuzluğuyla (SEGV)
  KIRDI — `bootstrap_allocator`/`injected_allocator` AYRI alanlara
  BÖLÜNEREK düzeltildi (break→red→fix İLE doğrulandı). (2) Release
  modunun arena-havuzu (`lowlevel.zig`nin `nox_arena_create`/`destroy`ı)
  `nox_runtime_deinit`de HİÇ DRAIN EDİLMİYORDU — `smp_allocator`
  (sızıntı-tespiti OLMAYAN) VARSAYILAN backing İKEN BU SESSİZCE
  zararsızdı, AMA enjekte edilebilir bir backing İLE (BU fazın KENDİ
  yeni testi, `std.testing.allocator`ı backing OLARAK KULLANARAK)
  GERÇEK bir sızıntı OLARAK ORTAYA ÇIKTI — YENİ `nox_arena_pool_drain`
  İLE düzeltildi.
- YENİ Zig testi (`asap.zig`): `nox_runtime_init_with_allocator(std.
  testing.allocator)` İLE bootstrap+`nox_alloc`/`free`+arena YAŞAM
  DÖNGÜSÜNÜN TAMAMININ SIFIR sızıntıyla `backing`e GERİ DÖNDÜĞÜNÜ
  kanıtlar (leak-tespit eden bir allocator'ı backing OLARAK KULLANMANIN
  KENDİSİ, yukarıdaki İKİ hatayı BULAN mekanizma).

## [1.81.0]

### Eklendi/Değiştirildi (Faz F.0.1 — dlopen/dlsym-tabanlı dispatch'i statik, "push" modeli bir kayıt mekanizmasına çevirme)
- Freestanding Nox çerçevesinin (bkz. proje planı) İLK alt-fazı: 5 çağrı
  sitesi (`runtime/alloc/arc.zig`, `runtime/alloc/cycle_detector.zig`
  (İKİ dispatch — trace + gc-free), `runtime/collections/dict.zig`,
  `runtime/errors/handle.zig`, `runtime/stdlib_shims/json.zig`) codegen'in
  ürettiği `nox_class_release_dispatch`/`nox_trace_dispatch`/`nox_gc_free_
  dispatch`/`nox_class_name_dispatch`/`nox_json_make_json_value`
  sembollerini `dlopen(null,...)+dlsym` (POSIX) / `GetModuleHandleA+
  GetProcAddress` (Windows) İLE ÇALIŞMA ZAMANINDA ARIYORDU — freestanding'de
  (dinamik yükleyici YOK) BU KAVRAMSAL olarak İMKANSIZ.
- Derin araştırma (2 paralel Explore ajanı + doğrudan kod okuması) BUNUN
  GERÇEK nedeninin "sembol bazen yok" OLMADIĞINI (core.nox'un koşulsuz
  merge'i YÜZÜNDEN sembol HER ZAMAN üretiliyor) ORTAYA ÇIKARDI — GERÇEK
  neden `noxrt_test`in (runtime'ın KENDİ Zig birim testlerini, HİÇBİR Nox
  programı OLMADAN derleyip çalıştıran hedef) bu sembolleri HİÇ ÜRETMEMESİ,
  bu YÜZDEN sabit bir `extern fn`nin O bağlamda LİNK adımını ÇÖKERTECEK
  olmasıydı.
- Çözüm: "pull" (isimle ara) modelinden "push" (codegen'in KENDİSİ, program
  BAŞLARKEN, sembol ADRESLERİNİ TEK SEFER kaydeder) modeline geçildi — YENİ
  `runtime/alloc/dispatch_registry.zig` (5 `std.atomic.Value(?fn_ptr)`
  global + `nox_register_dispatch_table` export'u), `compiler/codegen_qbe/
  registration.zig`'in `genMain`/`genMainAsync`'ına `$nox_runtime_init`
  ÇAĞRISININ HEMEN ARDINDAN, KOŞULSUZ, TEK satırlık bir kayıt çağrısı
  EKLENDİ (`nox_rc_release_enqueue_fixed`nin ZATEN kanıtlanmış "sembol
  adı = `l`-tipi değer" mekanizmasıyla). `noxrt_test` BAĞLAMINDA kayıt
  çağrısı HİÇ YAPILMADIĞINDAN TÜM alanlar `null` KALIR — dlsym'in
  "bulunamadı" durumuyla BİREBİR AYNI, GÜVENLİ varsayılan davranış.
- Bonus, düşük-riskli sadeleştirme: `compiler/main.zig`'in `NOX_DLSYM_
  SYMBOLS`/`computeLinkerVisibilityArgs`ı (5 sembolü ÖZEL olarak dinamik
  sembol tablosuna KOYAN, `-rdynamic`nin dead-stripping'i devre dışı
  bırakma sorununu ÇÖZEN FFI.3 mekanizması) TAMAMEN KALDIRILDI — dlsym
  ARTIK HİÇBİR YERDE ÇALIŞTIRILMEDİĞİNDEN bu semboller GENEL dead-
  stripping'den (`--gc-sections`/`-dead_strip`) MUAF TUTULMAYA GEREK
  DUYMUYOR (zaten KULLANILAN bir sembolü hiçbir linker STRIP ETMEZ).
  macOS/Linux'ta SADECE genel dead-stripping bayrağı KALDI; Windows dalı
  (`--export-all-symbols`) gerçek CI doğrulaması OLMADAN BİLİNÇLİ olarak
  DOKUNULMADI.
- Doğrulama: `zig ast-check`; `zig build noxrt-test` (Debug+ReleaseFast,
  172/172 — `noxrt_test`in HÂLÂ LİNKLENEBİLDİĞİNİN KANITI); kırmızı-takım
  (registration çağrısı GEÇİCİ kaldırılıp, sınıf-tipli bir uncaught-exception
  testinde sınıf adının "bilinmeyen sinif"e DÜŞTÜĞÜ, GERİ eklenince DOĞRU
  ADI ("MyError") gösterdiği doğrulandı); TAM paket `zig build test`
  (Debug+ReleaseFast — TÜM 281 IR-diff anlık görüntüsü YENİDEN oluşturuldu,
  `$main`nin YENİ TEK satırlık kaydı YÜZÜNDEN BEKLENEN bir kayma; ARADAN
  ÇIKAN HTTP golden test başarısızlıkları BU makinenin KENDİ, ÖNCEDEN
  belgelenmiş `-j10` kaynak-çekişmesi flake'i OLDUĞU, HER BİRİ İZOLE
  çalıştırılarak TEYİT edildi); `NOX_STRESS_ROUNDS=800 zig build
  stress-test -Doptimize=ReleaseFast` (44/44); `binary_size_test.zig`
  (dead-stripping + fonksiyonel JSON/sınıf/cycle-collector kanıtı HÂLÂ
  GEÇERLİ).
- Kapsam DIŞI (Faz F.0'ın KALAN 5 alt-maddesi, HER biri KENDİ AYRI Plan
  Mode turunda): allocator enjeksiyonu, panik/tanı çıktısı enjeksiyonu,
  fiber stack kaynağı enjeksiyonu, uyandırma mekanizması soyutlaması,
  `thread_channel`/`thread_bridge`/`pool_bridge`'in `http_client.zig`
  bağımlılığının kesilmesi.

## [1.80.10]

### Değiştirildi (Faz TEST.5 — `http_server.zig`nin KENDİ iç testlerindeki fiber-tabanlı + senkron askı risklerini kapatma)
- v1.80.9 (Faz TEST.4) push edildikten SONRA GERÇEK CI'de doğrulama
  yapıldığında (`gh run view 34964587230`), Linux (aarch64) job'u BU
  SEFER **4m5s'de TAMAMLANDI** (TEST.3+TEST.4'ün GERÇEKTEN işe yaradığının
  KANITI) — AMA AYNI koşuda Linux (x86-64) (önceki İKİ push'ta bilinen
  `pool_bridge` flake'iyle HIZLICA başarısız oluyordu) BU SEFER **30
  dakikalık zaman aşımına TAKILDI** (loglarda SON test-ilerleme satırından
  SONRA ~20 dakika TAMAMEN SESSİZ, cleanup logu `zig`/`test` süreçlerinin
  HÂLÂ ÇALIŞTIĞINI gösterdi) — GERÇEK, YENİ bir askı.
- Kök neden: `runtime/stdlib_shims/http_server.zig`nin KENDİ ~15 iç Zig
  testi (`tests/compat/http_serve_*_golden_test.zig`nin — Faz TEST.3'ün
  ZATEN `ChildWatchdog`la koruduğu — HARİCİ bir alt-süreç BAŞLATAN
  testlerinden TAMAMEN AYRI, denetlenmemiş bir yüzey: `serveImpl`i
  DOĞRUDAN, AYNI süreç İçİNDE çağırıyorlar) İKİ AYRI zaman-aşımsız
  mekanizma kullanıyordu: (A) senkron/scheduler'sız yolda ham,
  zaman-aşımsız `blockingAccept` (Faz TEST.1'in DÜZELTTİĞİ AYNI hata
  sınıfı, burada denetlenmemiş); (B) fiber/reaktör yolunda zaman-aşımsız
  `io_mod.nonBlockingAccept` — Linux'ta `close()`, ZATEN bloke olmuş bir
  `epoll_wait()`i UYANDIRMAZ (Linux'un KENDİ, belgelenmiş davranışı),
  bu YÜZDEN dışarıdan "fd'yi kapat" tarzı BASİT bir watchdog Mekanizma
  B'de GÜVENİLİR ÇALIŞMAZ.
- Düzeltme, İKİ PARÇA (BİRLİKTE ZORUNLU): (1) `serveImpl`nin accept
  döngüsü, ZATEN VAR VE ÜRETİMDE KANITLANMIŞ `io_mod.
  nonBlockingAcceptWithTimeout` mekanizmasını (ÖNCEDEN SADECE
  `serve_multicore`nin paylaşılan-bütçe yolunda, 25ms periyotla
  kullanılıyordu) `shared_budget == null` İKEN de (YENİ
  `DEFAULT_ACCEPT_POLL_MS = 2000`, GERÇEK sunucular İçİn SIFIR davranış
  değişikliği — bağlantı hazırsa `accept()` HER ZAMAN OLDUĞU GİBİ ANINDA
  döner) kullanacak şekilde genelleştirdi — `listen_fd` dışarıdan
  kapatılırsa BİR SONRAKİ periyodik yeniden-denemenin TAZE `accept()`
  çağrısı ANINDA `EBADF` alıp GERÇEK bir hata döner; (2) `http_server.
  zig`nin KENDİ İç testlerine, `tests/compat/child_watchdog.zig`nin
  `ChildWatchdog`ıyla AYNI ilkeli (arm/disarm, zaman aşımında zorla
  müdahale) YENİ bir `FdWatchdog` eklendi — HAM bir POSIX `listen_fd`
  üzerinde çalışır, zaman aşımında `closeSocket` İLE kapatır (senkron
  `blockingAccept`i DOĞRUDAN keser, fiber yolunda İSE Parça 1'in
  periyodik yeniden-denemesi TARAFINDAN yakalanır) — 9 iç teste
  (`nox_http_serve_raw`/`Performans`/fiber-eşzamanlılık/`Faz DD.1`
  (paylaşılan fd)/`Faz Q.5` (gövde boyutu + eşzamanlı bağlantı sınırı)/
  `Faz HH.7` (okuma zaman aşımı, İKİ test)/`Faz MN.12` (çapraz-worker
  çalma)) uygulandı.
- Kırmızı-takım SIRASINDA, `runtime/async_rt/io.zig`nin `setNonBlocking`ı
  (bir ÖNCEKİ oturumun "gereksiz `fcntl` tekrarını gider" optimizasyonu
  SIRASINDA eklenen, HER periyodik yeniden-denemede TEKRARLANAN
  `setNonBlocking(listen_fd)` çağrısı) GERÇEK, BAĞIMSIZ bir hata AÇIĞA
  ÇIKARDI: `fd` dışarıdan (watchdog TARAFINDAN) ZATEN kapatılmışken
  `fcntl(fd, F_GETFL)` NEGATİF (`EBADF`) döner — KOŞULSUZ `@intCast`
  (imzasız u32'ye SIĞMADIĞINDAN) bunu bir PANİKLE sonlandırıyordu. `current
  < 0` İSE sessizce ATLAYIP çağıranın HEMEN SONRAKİ `accept()` çağrısına
  GERÇEK/catch'lenebilir bir hata bırakacak şekilde düzeltildi (BÖYLECE
  dışarıdan kapatılan bir fd panik YERİNE HER ZAMAN NORMAL bir hata
  yolundan geçer — hem TEST.5'in KENDİ mekanizması hem GELECEKTEKİ
  HERHANGİ bir "dışarıdan fd kapatma" senaryosu İçİn genel bir
  sertleştirme).
- Doğrulama: `zig ast-check`; İKİ AYRI kırmızı-takım turu (Mekanizma B —
  istemci thread'leri GEÇİCİ kaldırılıp `bridge.nox_async_run_to_completion`ın
  HIZLI/hata İLE döndüğü; Mekanizma A — AYNI teknik senkron bir testte,
  `blockingAccept`in GERÇEKTEN kesildiği) — HER İKİSİ de düzeltmeden
  ÖNCE (watchdog + Parça 1 devre DIŞI bırakıldığında) TIMEOUT'a (60s)
  UĞRADI, düzeltmeyle HIZLI (~3-5s) başarısız OLDU; `zig build noxrt-test`
  (Debug + ReleaseFast, 172/172); TAM `zig build test` (Debug + ReleaseFast,
  855/857 — `http_serve_tls_golden_test.zig`nin İKİ testi `-j10`
  kaynak-çekişmesi ALTINDA BAŞARISIZ oldu, İZOLE (`zig test` DOĞRUDAN)
  çalıştırılıp Debug+ReleaseFast İKİSİNDE de TEMİZ geçtiği doğrulanıp
  Faz TEST.3/4'ün AYNI, ÖNCEDEN belgelenmiş `-j10` flake'i OLDUĞU
  TEYİT edildi, GERÇEK bir regresyon DEĞİL); `NOX_STRESS_ROUNDS=800 zig
  build stress-test -Doptimize=ReleaseFast` (44/44); `zig build
  http-soak-test -Doptimize=ReleaseFast -Dsoak-seconds=15` (2/2 — Parça
  1'in periyodik-poll değişikliğinin sürdürülebilir yük altında
  throughput'u ETKİLEMEDİĞİNİN kanıtı).
- Kapsam DIŞI: `async_rt.pool_bridge`/`worker_pool`nin KENDİ İÇ çapraz-worker
  çalma yarışı (task_66e267b4, AYRI/ÖNCEDEN işaretlenmiş bir flake, `Faz
  MN.12` testi BU AYNI ailenin bir PARÇASI olabilir — watchdog EKLENDİ
  AMA `pool.joinAll()` İçİnde bir askı OLURSA `FdWatchdog` BUNU
  ÇÖZMEYEBİLİR); kabul edilmiş bir bağlantı SONRASI okuma/yazma
  ortasında askı; Windows kod yolu.

## [1.80.9]

### Değiştirildi (Faz TEST.4 — `http_client.zig`nin KENDİ iç testlerindeki AYNI zaman-aşımsız `accept()` boşluğunu kapatma)
- v1.80.8 (Faz TEST.3) push edildikten SONRA GERÇEK CI'de doğrulama
  yapıldığında, Linux (aarch64) job'unun HÂLÂ 30 dakikalık zaman aşımına
  TAKILDIĞI görüldü — `http_serve_multicore_golden_test.zig`nin (Faz
  TEST.3'ün KENDİ watchdog'unun ZATEN korduğu) bir testi HIZLI şekilde
  başarısız oldu (watchdog ÇALIŞTI), AMA `zig build`nin KENDİ ana süreci
  30 dakika SONRA hâlâ orphan `zig`/`build`/`test` süreçleriyle askıda
  kalmaya DEVAM ETTİ — TEST.3'ün kapsamı DIŞINDA bırakılan, ÖNCEDEN
  belgelenen bir boşluk GERÇEKTEN tetiklenmişti.
- Kök neden: `runtime/stdlib_shims/http_client.zig`nin İKİ İÇ testi
  (`nox_http_get_raw: gerçek yerel HTTP sunucusuna GET isteği...` /
  `...bir fiber İÇİNDEN çağrıldığında...`), `testServeOnceDelayed`i
  `std.Thread.spawn` İLE arka planda başlatıp `defer server_thread.
  join()` İLE (zaman aşımsız) bekliyordu — `testServeOnceDelayed`nin
  KENDİSİ İSE (POSIX dalında) zaman-aşımsız, HAM `std.c.accept(listen_fd,
  null, null)` çağırıyordu. Bu, Faz TEST.1'in (v1.80.6) `tests/cli/
  search_test.zig`/`publish_test.zig`/`upgrade_test.zig`/`tests/compat/
  http_stdlib_golden_test.zig`de DÜZELTTİĞİ AYNI hata sınıfının, o
  turda GÖZDEN KAÇAN BEŞİNCİ bir örneğiydi — istemci (`nox_http_get_raw`)
  bağlanamazsa sunucu iş parçacığı `accept()`te SONSUZA KADAR bekler,
  `join()` de test sürecini SONSUZA KADAR askıda bırakır.
- Düzeltme: TEST.1'in KENDİ, ZATEN kanıtlanmış `acceptWithTimeout(listen_
  fd, timeout_ms)` yardımcısının (bir `poll()` çağrısıyla `accept()`e bir
  15 saniyelik zaman aşımı ekleyen) BİREBİR bir kopyası `http_client.zig`ye
  eklendi, `testServeOnceDelayed`nin POSIX dalındaki ham `std.c.accept`
  çağrısı BUNUNLA DEĞİŞTİRİLDİ (Windows dalına DOKUNULMADI — bu iç
  testler Windows CI'de HİÇ ÇALIŞMIYOR).
- Doğrulama: `zig ast-check`; kırmızı-takım (GEÇİCİ bir test, hiçbir
  istemci BAĞLANMADAN `testServeOnce`i çağırıp `acceptWithTimeout`in
  GERÇEKTEN 15 saniye SONRA döndüğünü, SONSUZA KADAR beklemediğini
  kanıtladı, SONRA KALDIRILDI); `zig build noxrt-test` (Debug: 172/172,
  ReleaseFast: 172/172) TEMİZ geçti; TAM paket `zig build test` (Debug)
  çalıştırıldığında `-j10`nin AĞIR paralel yükü ALTINDA (bu MAKİNENİN
  KENDİ, BU turun değişikliğinden BAĞIMSIZ kaynak-çekişmesi) BİRDEN FAZLA
  HTTP golden testi `term == .exited` beklentisiyle başarısız oldu —
  BUNLARIN HEPSİ Faz TEST.3'ün watchdog'unun TAM OLARAK TASARLANDIĞI GİBİ
  çalışıp (istemci bağlanamayınca 20 saniye SONRA süreci ÖLDÜRÜP) HIZLI/
  AÇIK bir şekilde başarısız OLMASIYDI (öncesinde SESSİZCE sonsuza kadar
  askıda kalırlardı) — HER BİRİ İZOLE (`zig test` DOĞRUDAN, paralel yük
  OLMADAN) çalıştırıldığında TEMİZ geçti, GERÇEK bir regresyon OLMADIĞI
  doğrulandı; `NOX_STRESS_ROUNDS=800 zig build stress-test -Doptimize=
  ReleaseFast` temiz.

## [1.80.8]

### Değiştirildi (Faz TEST.3 — HTTP golden testlerindeki `child.wait()`/`allocRemaining()` askı riskini bir watchdog ile kapatma)
- v1.80.7'nin (Faz TEST.2) doğrulaması SIRASINDA kullanıcının daha önce
  istediği CI kontrolü yapıldığında (`gh run list --workflow=ci.yml`),
  v1.80.3'ten (Faz MN.11, "CI hang'ini düzelttiği" iddia edilen commit)
  v1.80.6'ya (Faz TEST.1) KADAR SON DÖRT push'un DA Linux (aarch64) job'unda
  TAM OLARAK 30 dakikada (MN.11'in eklediği `timeout-minutes: 30`) zaman
  aşımına uğrayıp BAŞARISIZ OLDUĞU görüldü — YANİ TEST.1'in düzeltmesi
  ASIL hang'i ÇÖZMEMİŞTİ, sadece 6 saatlik sessiz bir askıyı 30 dakikalık
  açık bir başarısızlığa ÇEVİRMİŞTİ.
- Kök neden: TEST.1 (v1.80.6) SADECE 4 dosyadaki mock-sunucu test
  yardımcılarının (`std.c.accept()`'i DOĞRUDAN çağıran) çağrı sitelerini
  düzeltmişti — AMA `tests/compat/` altındaki `nox.http.serve*`/`Router`
  golden testlerinin BÜYÜK ÇOĞUNLUĞU (GERÇEK, derlenmiş bir Nox HTTP-
  sunucusu ikilisini `std.process.spawn` İLE arka planda başlatıp,
  istemci bağlantıları AYRI iş parçacıklarında test eden) TAMAMEN AYRI
  bir yüzey taşıyordu: istemci bağlantılarından HERHANGİ biri (`zig build
  test -j10`nin ağır kaynak çekişmesi ALTINDA) bağlanamazsa, sunucu ASLA
  `max_connections`e ulaşmaz, `accept()`te SONSUZA KADAR bekler — test
  süreci `allocRemaining()`/`child.wait()`te (İKİSİ de zaman aşımsız)
  SONSUZA KADAR bloke olur. Bu, bu oturumun KENDİSİNİN Faz TEST.2
  doğrulaması SIRASINDA yerel olarak GÖZLEMLEDİĞİ, "takılmış gibi"
  görünen askıyla BİREBİR aynı semptomdu.
- Doğrulama: İKİ izole `zig run` smoke testiyle (bir `sleep 30` alt-
  süreci `std.process.spawn` İLE başlatılıp, AYRI bir "watchdog" iş
  parçacığının 500ms sonra `std.posix.kill(pid, .KILL)` (HAM PID
  üzerinden, `Child` struct'ına HİÇ dokunmadan) ÇAĞIRMASIYLA) hem
  `allocRemaining` hem `child.wait()`in NEREDEYSE ANINDA (~500ms İçİnde)
  döndüğü KANITLANDI.
- `tests/compat/child_watchdog.zig` (YENİ, HİÇBİR `test` bloğu İçERMEYEN
  paylaşılan yardımcı dosya): `ChildWatchdog` struct'ı, `arm(child,
  timeout_ms)` (bir izleyici iş parçacığı BAŞLATIR) + `disarm()` (izleyiciyi
  DURDURUP joinler). Watchdog, `timeout_ms` içinde `disarm()` çağrılmazsa
  `std.posix.kill(pid, .KILL)` GÖNDERİR — HAM PID üzerinden, `std.process.
  Child` struct'ının KENDİSİNE HİÇ dokunmadan (İKİ farklı iş parçacığının
  AYNI `Child` struct'ını eş zamanlı DEĞİŞTİRMESİNİ önleyen BİLİNÇLİ bir
  tasarım kararı — `Child.kill(io)` YERİNE ham `std.posix.kill` kullanılması
  BUNDAN dolayı).
- 6 dosyadaki 16 çağrı sitesine (`tests/compat/http_serve_golden_test.zig`
  — 6, `http_serve_multicore_golden_test.zig` — 3, `http_serve_tls_golden_
  test.zig` — 2, `http_serve_ws_golden_test.zig` — 2, `router_module_state_
  golden_test.zig` — 2, `http_serve_multicore_pool_golden_test.zig` —
  SADECE İLK test, 1) `std.process.spawn` SONRASI 3 satırlık bir `arm`/
  `defer disarm()` bloğu EKLENDİ (20 saniyelik bir zaman aşımıyla —
  mutlu-yol testleri <1-2 saniyede bittiğinden bol bir pay). `http_serve_
  multicore_pool_golden_test.zig`nin İKİNCİ testi (zaten `child.kill(io)`
  İLE biten, `child.wait()` HİÇ çağırmayan) VE `http_soak_test.zig` (AYNI
  şekilde ZATEN güvenli) BİLİNÇLİ olarak DOKUNULMADI.
- Kırmızı-takım doğrulaması: bir testte `max_connections`i istemcilerin
  ASLA ulaşamayacağı bir sayıya GEÇİCİ olarak çekilip, sunucunun artık
  SONSUZA KADAR asılı KALMADIĞI, watchdog'un ~3 saniye (test amaçlı
  kısaltılmış zaman aşımıyla) SONRA süreci ÖLDÜRÜP testin `term ==
  .exited` iddiasında HIZLI/AÇIK bir hatayla BAŞARISIZ OLDUĞU doğrulanıp
  GERİ ALINDI.
- Doğrulama: `zig ast-check` (6 dosya + yeni dosya), TAM paket `zig build
  test` (Debug: 854/857 geçti, 2 BİLİNEN/ilişkisiz `-j10` çekişme flake'i
  — `http_serve_ws`/`router_module_state` — İZOLE çalıştırıldığında TEMİZ
  geçtiği doğrulandı; ReleaseFast: BENZER şekilde İZOLE doğrulandı, artı
  ZATEN ayrı izlenen `pool_bridge` flake'i), `NOX_STRESS_ROUNDS=800 zig
  build stress-test -Doptimize=ReleaseFast` temiz.



### Değiştirildi (Faz TEST.2 — `codegen_golden_test.zig`nin 300 sıralı testini gerçek iş-parçacığı paralelliğiyle hızlandırma)
- Kullanıcının "zig build test aşırı uzun sürüyor, Rust'taki gibi paralel
  çalışamıyor mu?" sorusu ÜZERİNE yapılan araştırma, TOPLAM `zig build
  test`in (temiz `.zig-cache`, 10 çekirdek, `-j10`) 5:20 sürdüğünü AMA
  ortalama CPU kullanımının SADECE %137 (10 çekirdekten ~1.4'ü) olduğunu
  buldu — `tests/golden/codegen_golden_test.zig`nin TEK BAŞINA 5 dakika
  sürdüğü (300 `test` bloğu, HER BİRİ Zig'in KENDİ, tek-iş-parçacıklı
  test-runner'ı YÜZÜNDEN SIRAYLA çalışıyordu) tespit edildi.
- 300 testten 265'i (256 `expectGolden`, 8 `expectUncaughtException`, 1
  `expectUncaughtExceptionWithStderr`) TEK bir `fixtures` VERİ dizisine
  dönüştürüldü; `expectGolden`/`expectUncaughtException`/
  `expectUncaughtExceptionWithStderr`nin parametrelerinden `comptime`
  KALDIRILDI (SAF bir imza gevşetmesi, davranış DEĞİŞMEDİ). YENİ, TEK bir
  toplu test — `std.Thread.spawn` + atomik bir iş-çalma sayacıyla (`n_workers
  = min(fixtures.len, cpu_count * 2)`) TÜM 265 fixture'ı GERÇEK iş-parçacığı
  paralelliğiyle çalıştırıyor, HANGİ fixture'ın başarısız olduğunu isim +
  hata adıyla özetliyor. Kalan 35 heterojen test (çoğu "codegen: ..." —
  üretilen `.ssa` IR metnini doğrudan inceleyen, TEK bir veri şemasına
  GENELLENEMEYECEK kadar ÇEŞİTLİ — + regex-eşleşmeyen 1 yorum-öncesi test)
  DOKUNULMADAN, olduğu gibi kaldı.
- **Ölçülen sonuç**: bu TEK dosyanın kendi test adımı 5 dakikadan **~2
  dakikaya** düştü (izole `zig test -OReleaseFast` çalıştırması: 265
  fixture'lık toplu test TEK BAŞINA 2:47, dosyanın TAMAMI 2:58 — HEM Debug
  HEM ReleaseFast'te DOĞRULANDI). Beklenen ideal (300/n_worker ≈ 15-20
  saniye) GERÇEKLEŞMEDİ — ÖLÇÜLEREK bulundu ki asıl darboğaz Zig-seviyesi
  hesaplama DEĞİL, HER fixture'ın kendi `qbe`+`cc`+çalıştırılan-binary alt-
  süreç zincirinin işletim-sistemi seviyesindeki (fork/exec/kod-imzalama)
  sabit maliyeti — bu maliyet iş-parçacığı SAYISIYLA orantılı KÜÇÜLMÜYOR.
  YİNE DE ~2.5x'lik GERÇEK, doğrulanmış bir kazanç (proje disiplini: ölç,
  varsayma — idealize edilmiş bir tahmin YERİNE GERÇEK sayı raporlanır).
- Doğrulama: TÜM 300 `.nox`/`.expected` fixture çifti (265 toplu + 35
  bireysel) `@embedFile` sayısının migrasyon ÖNCESİ/SONRASI BİREBİR AYNI
  (565) kaldığı doğrulanıp
  BİREBİR AYNI çıktıları ÜRETTİĞİ (Debug + ReleaseFast, 36/36 test) TEYİT
  edildi; kırmızı-takım (`fibonacci.expected`e geçici bir satır EKLENİP)
  GERÇEK diff'in stderr'e YAZILDIĞI, "BAŞARISIZ: <isim>" özet satırının
  GÖRÜNDÜĞÜ VE SADECE O TEK fixture'ın başarısız SAYILDIĞI doğrulanıp GERİ
  ALINDI; TAM paket `zig build test` (Debug, warm cache) 36/36 dahil TÜM
  adımlarla TEMİZ geçti.

## [1.80.6]

### Düzeltildi (v1.80.3'ün Linux (aarch64) CI hang'inin GERÇEK kök nedeni bulundu)
- **Faz TEST.1**: v1.80.3/v1.80.4'ün push'ları SONRASI Linux (aarch64) job'u
  İKİ KEZ ART ARDA (aynı commit'e karşı rerun DAHİL) TAM 30-dakikalık CI
  zaman-aşımına takıldı — v1.80.3'ün CHANGELOG girdisinde önerilen
  "muhtemelen runner-kaynaklı yavaşlık" hipotezi, İKİNCİ hang İLE
  ÇÜRÜTÜLDÜ. Native (emülasyonsuz) bir aarch64 Linux/Docker konteynerinde
  (bu makine Apple Silicon olduğundan qemu gerekmedi), `docker run --init`
  (tini'yi PID 1 yaparak GERÇEKÇİ bir zombi-reaping ortamı kurarak) VE
  GERÇEK bir clang/LLVM kurulumuyla GERÇEKTEN reprodüklendi, VE `gdb -p`
  İLE stuck süreçlerin CANLI yığın izleri ALINDI. **Kök neden, ÖNCEKİ
  M:N zamanlayıcı/STW-bariyeri teorisiyle HİÇ İLGİLİ DEĞİL**: `tests/
  cli/search_test.zig`/`publish_test.zig`/`upgrade_test.zig` VE `tests/
  compat/http_stdlib_golden_test.zig`'in KENDİ, ham-soket sahte-sunucu
  test yardımcıları (`std.c.accept(listen_fd, null, null)`) ZAMAN-AŞIMSIZ
  BLOKLAYICI bir çağrıydı — GERÇEK `noxc` alt-süreci (istemci) HERHANGİ
  bir nedenle (`zig build test`nin TAM paralel paketi ALTINDA ağır kaynak-
  çekişmesi, KESİN tetikleyici İZOLE EDİLEMEDİ AMA semptom GDB İLE KANITLANDI)
  bağlanmadan/erken çıkarsa, sunucu iş parçacığı `accept()` İçİNDE SONSUZA
  KADAR bekliyor, `defer server_thread.join()` de dolayısıyla TÜM test
  SÜRECİNİ SONSUZA KADAR askıda bırakıyordu.
- **Düzeltme**: 4 dosyanın HER BİRİNE (`search_test.zig`/`publish_test.
  zig`/`upgrade_test.zig`/`http_stdlib_golden_test.zig`), MN.11'in CI
  `timeout-minutes`iyle AYNI savunma-derinliği ilkesiyle, `poll()` tabanlı
  bir `acceptWithTimeout(listen_fd, 15_000)` yardımcısı EKLENDİ — kök
  neden TAM olarak izole edilemese de, `accept()`i 15 saniyede GERİ
  dönmeye ZORLAYARAK sessiz bir sonsuz askıyı HIZLI/AÇIK bir test
  BAŞARISIZLIĞINA çevirir.
- **Doğrulama**: Native aarch64 Docker'da (ÖNCEDEN 18-30 dakikada zaman-
  aşımına TAKILAN AYNI senaryo) düzeltme SONRASI test süreci **2 dakikada**
  temiz tamamlandı — hang TAMAMEN ORTADAN KALKTI. `zig build test`
  (yerel, Debug) 1120/1121 (1 atlandı — v1.80.5'in dead-stripping testi)
  TEMİZ.

## [1.80.5]

### Düzeltildi (GERÇEK bir Linux (x86-64) CI koşusuyla bulunan, KESİN/tekrarlanabilir bir dead-stripping test hatası)
- **Faz FFI.3.1**: v1.80.3'ün push'u SONRASI GERÇEK CI'de `binary_size_
  test.zig`'in "smtp/postgres kullanmayan basit bir program dead-stripping
  ile küçük kalır" testi Linux (x86-64) job'unda `nox_smtp_connect_raw`
  sembolünü ikilide BULUP başarısız oldu. Bir Docker/Ubuntu 24.04 (x86-64)
  konteynerinde GERÇEKTEN reprodüklenip KANITLANDI: bu bir flake DEĞİL,
  KESİN/tekrarlanabilir bir hatadır — Zig'in ELF hedeflerinde `link_
  function_sections`i (Faz FFI.3/v1.79.2'nin `--gc-sections`/`--export-
  dynamic-symbol` mekanizmasının GEREKTİRDİĞİ bölüm-seviyesi granülerlik)
  SADECE LLVM backend'i (Release* modları) ONURLANDIRIYOR — `-Doptimize`
  BAYRAKSIZ (Debug, `ci.yml`'nin İLK, öntanımlı `zig build test` çağrısı)
  derlenen `noxrt.o` (native/self-hosted backend KULLANIR) SIFIR `.text.*`
  bölümü ÜRETİYOR (`readelf -SW` İLE doğrulandı), bu YÜZDEN dead-stripping
  HİÇBİR şeyi elemiyor — `nox.smtp`/`nox.postgres` GİBİ HİÇ kullanılmayan
  TÜM stdlib shim kodu HER Debug-derlenen `noxc build` çıktısında KALIR.
  `ci.yml`'nin test job'u `zig build test` (Debug) İLE `zig build test
  -Doptimize=ReleaseFast`yi SIRAYLA çalıştırdığından VE İLK adım başarısız
  olduğunda İKİNCİ adım HİÇ ÇALIŞMADIĞINDAN, BU test CI'de HER ZAMAN,
  KOŞULSUZ olarak (kaynak-kısıtlılığından/şanstan BAĞIMSIZ) başarısız
  oluyordu — v1.79.2'den beri.
- **Düzeltme**: `binary_size_test.zig`, `build.zig`'in TÜM harici test
  modülleriyle AYNI paylaşılan `optimize` değerini KULLANDIĞINDAN, testin
  KENDİ `builtin.mode`i ambient `noxrt.o`nun MODUNU GÜVENİLİR biçimde
  YANSITIYOR — `builtin.mode == .Debug` İKEN dead-stripping'e ÖZGÜ
  iddialar `error.SkipZigTest` İLE ATLANIR (Windows'un KENDİ, ZATEN VAR
  olan skip-deseniyle TUTARLI) — `ci.yml`'nin `-Doptimize=ReleaseFast`
  geçişi AYNI test'i GERÇEKTEN doğrulamaya DEVAM ETTİĞİNDEN kapsam KAYBI
  YOK.
- **Doğrulama**: Debug'da `zig build test` → 1120/1121 (1 ATLANDI, DOĞRU
  test); `-Doptimize=ReleaseFast` → 1121/1121 (test GERÇEKTEN çalışıp
  GEÇTİ) — dead-stripping'in KENDİSİ (v1.79.2'nin düzeltmesi) hâlâ DOĞRU
  çalışıyor, SADECE testin Debug-modunda ÇALIŞTIRILMASI YANLIŞTI.

## [1.80.4]

### Düzeltildi (v1.80.3'ün GERÇEK CI koşusunda bulunan bir test-flake'i)
- **Faz MN.12**: v1.80.3 push edildikten SONRA GERÇEK CI'de (`gh run view`
  ile doğrulandı) `pool_bridge.zig`'in "Faz MN.8 Bulgu A - sibling
  worker'lar globals_init_fn ile KENDİ slotu İçİn ilklendirilir, ÇALINAN
  bir görev doğru bloğu okur" testi HEM macOS (aarch64) HEM Linux
  (x86-64) koşularında `stolen_count > 0` iddiasında BAŞARISIZ oldu —
  test GERÇEKTEN ÇÖKMEDİ/ASILI KALMADI, sadece kanıtlamak İSTEDİĞİ
  "en az bir görev BAŞKA bir worker'a çalındı" olgusunu KANITLAYAMADI.
  Kök neden: bu test, `realEntry`'nin 30 görevi spawn ETTİKTEN HEMEN
  SONRA, kardeş worker'ların OS iş parçacıklarının GERÇEKTEN
  ZAMANLANMASINI beklemeden, İLK görevi `await` ETMEYE (dolayısıyla
  driver'ın KENDİ deque'ini TÜKETMEYE) BAŞLIYORDU — `worker_pool.zig`'in
  KENDİ, ZATEN kanıtlanmış `stealTestWorkerEntry`si (Faz MN.4/5.8) TAM
  OLARAK BU riski (`std.Thread.yield()`'i 8 tur ÇAĞIRIP OS'a kardeşleri
  ÇALIŞTIRMASI İçİn adil bir şans VERMEK) ZATEN çözmüştü, AMA bu ÇÖZÜM
  `pool_bridge.zig`'in TESTİNE HİÇ UYGULANMAMIŞTI. Düzeltme: AYNI
  yield-döngüsü `realEntry`'nin spawn-SONRASI/await-ÖNCESİ noktasına
  EKLENDİ — 10/10 yerel koşuda (`zig build noxrt-test`) VE TAM paket
  (`zig build test`, 1121/1121) TEMİZ.
- **Ayrıca analiz edildi, DÜZELTME GEREKTİRMEDİĞİ DÜŞÜNÜLÜYOR (SONUÇ AYRI
  bir sürümde doğrulanacak)**: v1.80.3'ün push'u SONRASI GERÇEK CI'de
  Linux (aarch64) job'u yeniden 30-dakikalık zaman-aşımına (MN.11'in
  KENDİ savunma-derinliği önlemi) TAKILDI — DERİN bir bellek-modeli
  analizi (release-sequence kuralı, `plc`'nin TÜM RMW mutasyonlarının
  TEK bir zincir oluşturduğu) `plc==0` çıkış yolunun (MN.11'in düzelttiği)
  GERÇEKTEN sağlam OLDUĞUNU, VE `poolWideDeadlockCheck`'in GERÇEKTEN
  tetiklenirse SESSİZCE ASILI KALMAK YERİNE `std.process.exit(1)` İLE
  GÜRÜLTÜLÜ bir şekilde ÇÖKECEĞİNİ (CI'de GÖZLENEN "sıfır çıktı, 30
  dakika sessizlik" deseniyle UYUŞMADIĞINI) gösterdi — bu YÜZDEN
  gözlenen hang'in bir zamanlayıcı MANTIK hatası OLMAYIP `ubuntu-24.04-arm`
  runner FİLOSUNUN (x86-64'ten DAHA YENİ/muhtemelen DAHA fazla paylaşımlı)
  kaynak-kısıtlılığından kaynaklanan GENEL bir YAVAŞLIK OLABİLECEĞİ
  HİPOTEZİ ile job YENİDEN tetiklendi — SONUÇ (geçti/tekrar hang) BU
  CHANGELOG YAZILDIĞI ANDA HENÜZ BİLİNMİYORDU, AYRI bir sürümde/notta
  raporlanacak.

## [1.80.3]

### Düzeltildi (GERÇEK bir CI koşusuyla bulunan concurrency deadlock'u — Linux CI'de 6 saatlik askıda kalmalara yol açıyordu)
- **Faz MN.11**: Faz CI.1'in doğrulaması SIRASINDA `gh run list` İLE
  `ci.yml`nin v1.71.0'dan BERİ NEREDEYSE HİÇ yeşil OLMADIĞI, VE bazı
  koşuların Linux (x86-64)'te TAM 6 SAAT (GitHub'ın job-zaman-aşımı
  tavanı) ASILI KALDIĞI keşfedildi. Kök neden: `runtime/async_rt/
  scheduler.zig`nin `Scheduler.run()`ı, pool'lu YOLDA `poolWideDeadlockCheck()`
  `true` döndüğünde worker'ı `stw_requested`e HİÇ BAKMADAN KALICI olarak
  `run()`dan `return error.Deadlock` İLE ÇIKARIYORDU — Faz MN.8'in
  ZATEN düzelttiği (`plc==0` yolu İçİn, 37+ dakikalık GERÇEK bir hang
  İLE bulunan) AYNI hata sınıfının, AYNI fonksiyonun İKİNCİ bir çıkış
  noktasındaki DÜZELTİLMEMİŞ bir varyantıydı: worker bu YOLDAN KALICI
  ÇIKARKEN TAM O ANDA BAŞKA bir worker BİR STW round'u TALEP ETTİYSE
  (ör. cycle-collector eşiği), BU worker O round'a ASLA KATILMAZ —
  bariyerin gerektirdiği katılımcı SAYISI KALICI EKSİK KALIR, KALAN
  worker'lar SONSUZA KADAR bekler (`nox_pool_serve`/`nox_pool_run`nin
  `readSelfPipe`i de dolayısıyla SONSUZA KADAR bloklar). Düzeltme:
  `plc==0` yolunun AYNI koruması (`stw_requested`e bak, TALEP VARSA
  ÖNCE KATIL, SONRA yeniden değerlendir) BU İKİNCİ çıkış noktasına da
  UYGULANDI. AYRICA, `.github/workflows/ci.yml`ye `timeout-minutes: 30`
  EKLENDİ (savunma-derinliği — GELECEKTEKİ FARKLI bir hang de ARTIK
  6 saat DEĞİL, EN FAZLA 30 dakikada AÇIKÇA kırmızı olur).

## [1.80.2]

### CI/altyapı (release'ler artık CI durumuna GÖRE kapanıyor)
- **Faz CI.1**: `v1.76.0`'dan `v1.79.0`'a KADAR (4 sürüm, 3 gün) `ci.yml`
  HER TEK pushta `runtime/vendor/tls_client.zig: FileNotFound` İLE
  KIRMIZIYDI — AMA `release.yml`, etiketlenen commit'in CI durumuna
  HİÇ BAKMADAN GERÇEK GitHub Release'ler yayımlıyordu (`main`de HİÇBİR
  branch protection/required status check OLMADIĞI `gh api .../branches/
  main/protection` İLE DOĞRULANDI — `404 Branch not protected`).
  `release.yml`ye YENİ `ci-gate` job'u EKLENDİ: `build`/`windows-x64`
  ÇALIŞMADAN ÖNCE, etiketlenen commit İçİn `ci.yml`nin GERÇEKTEN
  `success` İLE tamamlandığını `gh api` İLE doğrular — DEĞİLSE release'i
  DURDURUR. `ci.yml`ye AYRICA YENİ, HIZLI (Zig GEREKTİRMEZ) bir
  `tracked-files-check` job'u EKLENDİ — `build.zig`nin `b.path(...)` İLE
  referans verdiği HER yolun git'te GERÇEKTEN İZLENDİĞİNİ doğrular
  (v1.79.1'in AYNI hata sınıfının BİR DAHA SESSİZCE OLUŞMASINI ÖNLER).
  `main`e DOĞRUDAN push YETKİSİNE/GitHub repo ayarlarına (GERÇEK branch
  protection) BİLİNÇLİ olarak DOKUNULMADI — DAR, SAF kod-seviyesi kapsam.

## [1.80.1]

### Test altyapısı (QBE↔LLVM conformance suite'i güncel özellik yüzeyine genişletildi)
- **Faz HH.1.2**: `tests/golden/backend_conformance_test.zig` (Faz HH.1,
  v1.50.0) v1.50.0'dan v1.80.0'a KADAR eklenen 6 büyük özellik İçİn
  YENİDEN değerlendirildi. 3'ü — Task istisna yayılımı (SC.1, v1.70.0),
  Task iptali (SC.2, v1.71.0), `and`/`or`nun GERÇEK kısa-devresi (FF.5,
  v1.76.0) — TAMAMEN backend-agnostik (TEK, PAYLAŞILAN codegen yolu,
  `self.backend` dallanması YOK) OLDUĞU doğrudan kod okumasıyla
  DOĞRULANIP YENİ `expectConformant` fixture'ları OLARAK EKLENDİ — ÜÇÜ
  de HEM QBE HEM LLVM'de BİREBİR AYNI stdout'u ÜRETTİ (BEKLENDİĞİ GİBİ,
  YENİ bir sapma BULUNMADI). KALAN 3'ü (HPy çağrı yüzeyi — harici
  `.hpy-venv`/`.so` bağımlılığı; extern geçici sahiplik/`retains(...)`
  — `codegen_ir_diff_test.zig`de ZATEN IR-seviyesinde doğrulanıyor; ORM/
  generic çıkarım — SAF derleme-zamanı, generic'ler codegen'e ULAŞMADAN
  monomorfize edilir) BİLİNÇLİ olarak KAPSAM DIŞI bırakıldı, GEREKÇESİ
  test dosyasının KENDİ belge notuna eklendi.

## [1.80.0]

### Eklendi (dil özelliği — `extern def`in escape sözleşmesi artık KONTROL EDİLEBİLİR)
- **Faz FFI.4**: v1.77.0'ın (FFI.1) escape-analysis carve-out'u, HER
  `extern def` çağrısının argümanını KOŞULSUZ "çağrı-sonrası HİÇ saklanmaz"
  SAYIYORDU — bu, 82 MEVCUT extern def'in ELLE denetlenmesiyle
  DOĞRULANMIŞ AMA HİÇBİR ŞEKİLDE ZORLANMAYAN bir varsayımdı: gelecekte
  (VEYA bir hatayla) argümanını GERÇEKTEN saklayan bir extern def
  yazılırsa, escape-analysis BUNU HİÇ ÖĞRENEMEZ, derleyici SESSİZCE
  YANLIŞ (stack/arena'ya promote edip) bir kullanım-sonrası-serbest-
  bırakma hatası ÜRETİRDİ. `extern def`e YENİ, OPSİYONEL bir `retains(
  param1, param2, ...)` yan tümcesi eklendi (`with_rt`İLE AYNI konumda/
  desende) — İSİMLENDİRİLEN parametrelerin ham işaretçisinin ÇAĞRI
  SONRASI SAKLANDIĞINI AÇIKÇA bildirir. Checker BU isimlerin GERÇEK
  parametre adlarıyla eşleştiğini DOĞRULAR (YENİ `UnknownRetainedParam`
  tanı kodu — typo/yanlış isim ARTIK derleme-zamanında YAKALANIR, bu
  kontratın "checked" tarafıdır). Escape-analysis'in 3 call-site'ı
  (`compiler/codegen_qbe/local_escape.zig`/`inlining.zig`) `retains(...)`
  İLE işaretlenen argümanları ARTIK "kaçıyor" SAYAR (normal ARC'a düşer,
  stack/arena promotion'a UYGUN SAYILMAZ). VARSAYILAN (yan tümce YOKSA):
  HİÇBİRİ saklanmaz — MEVCUT 196 extern def'in TAMAMI SIFIR değişiklikle
  ÇALIŞMAYA devam eder (SIFIR migrasyon). YENİ bir IR-diff fixture
  (`extern_arg_retains_forces_arc.nox`) `retains(xs)`in GERÇEKTEN
  `alloc8`i `nox_rc_alloc`e ÇEVİRDİĞİNİ (davranışı DEĞİŞTİRDİĞİNİN somut
  kanıtı) doğruluyor.

## [1.79.4]

### Düzeltildi (checker soundness — HH.10'un KENDİ v1 sınırı, transitif return-alias zinciri artık çözülüyor)
- **Faz HH.11**: v1.59.0'ın (HH.10) return-alias etkileri analizi
  (`compiler/typecheck/checker.zig`nin `computeReturnAliasEffects`/
  `scanReturnsForAliasEffect`i) BİLİNÇLİ olarak "BAŞKA bir fonksiyonu
  çağıran bir `return` HER ZAMAN `unknown`" diyordu — `wrapper(xs):
  return helper(xs)` GİBİ TEK bir dolaylı katman BİLE `ys = wrapper(xs)`nin
  `xs`in TRANSİTİF bir takma adı OLDUĞUNU YAKALAYAMIYORDU (`spawn
  worker(xs)` SONRASI `ys[0] = 42` SESSİZCE derleniyordu — GERÇEK bir
  veri-yarışı senaryosu). Harici bir (GPT-5.6) inceleme BU açığı YENİDEN
  gündeme getirdi VE bu turda GERÇEK bir repro İLE (doğrudan `noxc`ye
  karşı derlenip) DOĞRULANDI. **Düzeltme**: `computeReturnAliasEffects`
  TEK-geçişten Gauss-Seidel bir fixpoint döngüsüne (`MAX_RETURN_ALIAS_
  FIXPOINT_ITERATIONS=64`, `returnAliasEffectEql`) DÖNÜŞTÜRÜLDÜ —
  `scanReturnsForAliasEffect`nin `.call` dalı ARTIK callee'nin KENDİ
  (bu turda ZATEN hesaplanmış) `return_alias_effects` girdisine bakıp
  TRANSİTİF olarak `.alias_params`a TERFİ EDEBİLİYOR. `unknown`un
  tüketici tarafta (`updatePointsToForTarget`) `.fresh`/"haritada YOK"
  İLE BİREBİR AYNI (HİÇBİR `points_to` girdisi EKLEMEYEN) davranışı
  TAŞIMASI, fixpoint'in ERKEN kesilmesinin (cap'e ulaşılması) BİLE YENİ
  bir false-negative ÜRETEMEYECEĞİNİN (SADECE bazı fonksiyonların DAHA
  GEÇ terfi edeceğinin) matematiksel garantisidir — SIFIR regresyon
  riski. `tests/golden/typecheck_cases/ok_spawn_shared_return_alias_
  transitive_unknown.nox` (BU açığı "bilinçli sınır" OLARAK belgeleyip
  `OK` bekleyen ESKİ fixture) `err_spawn_shared_return_alias_transitive_
  two_level.nox` OLARAK TERSİNE ÇEVRİLDİ; YENİ 4 fixture EKLENDİ:
  3-seviyeli İLERİ-sıra zincir, 3-seviyeli TERS-sıra zincir (fixpoint'in
  metinsel sıradan BAĞIMSIZ olduğunun kanıtı), karşılıklı özyineleme VE
  öz-özyineleme (İKİSİ de `unknown`da GÜVENLE KİLİTLENİP sonsuz döngüye
  GİRMEDİĞİNİN/YENİ false-positive ÜRETMEDİĞİNİN regresyon-yok kanıtı).

## [1.79.3]

### Düzeltildi (Windows derleme hatası — GERÇEK bir CI koşusuyla bulundu)
- **`runtime/async_rt/pool_bridge.zig`nin `sleepOneMs`ı Windows'ta HİÇ
  DERLENMİYORDU**: `std.c.timespec`nin `.sec` alanının tipi `std.c.time_t`ye
  bağlı, VE Zig 0.16.0'nın KENDİ `std/c.zig`si `time_t`nin switch'inde
  `.windows`i HİÇ LİSTELEMİYOR (`else => void`e düşüyor) — `.sec = 0`
  ataması BU YÜZDEN `"expected type 'void', found 'comptime_int'"` derleme
  hatasıyla BAŞARISIZ oluyordu, `nox.http.serve_multicore`/`nox.thread.
  pool_run` GİBİ `--release` yollarına GİREN HER Windows `zig build` bunu
  HİÇ GEÇEMİYORDU. `runtime/async_rt/scheduler.zig`nin `sleepMs`ının
  ZATEN kanıtlanmış `kernel32.Sleep` guard'ı (`if (builtin.os.tag ==
  .windows) { ...; return; }`) BURAYA da AYNEN uygulandı. Kapsamlı bir
  tarama (`std.c.timespec`/`posix.timespec` KULLANAN TÜM DİĞER siteler:
  `thread_channel.zig`/`thread_bridge.zig`/`http_server.zig`nin 4
  örneği) BUNLARIN HEPSİNİN ya ZATEN doğru guard'landığını (`time.zig`/
  `random.zig`/`http_client.zig`/`io_reactor.zig`) ya da SADECE `test`
  bloklarının İÇİNDE (Windows CI'nin ŞU AN çalıştırmadığı bir yol)
  OLDUĞUNU doğruladı — TEK genuine, ungarded, PRODUCTION-yolu boşluğu
  `pool_bridge.zig`ydi.

## [1.79.2]

### Düzeltildi (KRİTİK — Linux'ta dead-code-stripping HİÇ ÇALIŞMIYORDU)
- **Faz FFI.3'ün `--gc-sections`i, Zig'in `Compile.link_function_sections`i
  VARSAYILAN OLARAK `false` OLDUĞUNDAN Linux/ELF hedeflerinde HİÇBİR ŞEYİ
  SİLEMİYORDU**: v1.79.1'in vendor-dosyası düzeltmesinden SONRA, GERÇEK bir
  GitHub Actions CI koşusu (`ubuntu-latest`/`ubuntu-24.04-arm`) `tests/cli/
  binary_size_test.zig`'in KENDİ negatif-sembol kontrolünü BAŞARISIZ VERDİ
  (`nox_smtp_connect_raw` HÂLÂ ikilide BULUNUYORDU) — macOS'ta AYNI test
  GEÇERKEN. Bir Docker/aarch64 konteynerinde (`readelf -SW`) DOĞRUDAN
  doğrulandı: `noxrt.o` (ELF) TEK, MONOLİTİK bir `.text` bölümü OLARAK
  üretiliyordu (Mach-O'da Zig ZATEN per-fonksiyon bölüm ürettiğinden macOS
  hiç ETKİLENMEMİŞTİ) — `Compile.link_function_sections`in (Zig 0.16'nın
  KENDİ derleme-zamanı seçeneği, "her fonksiyonu KENDİ bölümüne koy ki
  linker güvenle GC edebilsin") VARSAYILANI `false` OLDUĞUNDAN, `-Wl,--gc-
  sections`in silecek HİÇBİR bölüm-granülerliği YOKTU. `build.zig`'in
  `noxrt` (`b.addObject`) adımına `link_function_sections = true` +
  `link_data_sections = true` EKLENDİ — AYNI konteynerde YENİDEN doğrulandı:
  `noxrt.o` ARTIK 11.092 `.text.*` bölümü İçeriyor, `nox_smtp_connect_raw`
  ARTIK ikilide HİÇ BULUNMUYOR, `nox.json.decode`+sınıf+cycle-collector
  fonksiyonel testi DOĞRU çalışıyor. `tests/cli/binary_size_test.zig`'in
  boyut eşiği (3 MB → 10 MB) platformlar-arası GERÇEK bir varyansı (Linux/
  ELF Debug derleme bilgisi macOS/Mach-O'nunkinden ~4 kat BÜYÜK ölçüldü)
  tolere edecek şekilde GEVŞETİLDİ — asıl/KESİN kanıt negatif-sembol
  kontrolüdür, boyut eşiği SADECE bir savunma-derinliği regresyon bekçisi.

## [1.79.1]

### Düzeltildi (KRİTİK — fresh checkout/CI/release build hatası)
- **`runtime/vendor/tls_client.zig` git'e HİÇ eklenmemiş olarak kalmıştı**:
  bu dosya (`std.crypto.tls.Client`'ın gmail/office365 SMTP TLS el
  sıkışması İçİn yamalı forku — `nox.tls`/`nox.smtp`/`nox.websocket`'in
  ORTAK kaynağı, RFC 8446 §4.3.2 `certificate_request` mesajı İçİn İKİ
  GERÇEK yama İçEREN, tekrar-üretimle DOĞRULANMIŞ bir düzeltme) v1.76.0'dan
  (bu dosyayı İLK KEZ import eden commit) BERİ SADECE yerel diskte VARDI —
  git'e HİÇ eklenmemişti, `git status`ta "pre-existing untracked stray
  dosya" OLARAK YANLIŞLIKLA HER commit'te dışlanıyordu. **Sonuç**: HER
  FRESH checkout (GitHub Actions'ın `actions/checkout@v4`'ü DAHİL) `zig
  build` `runtime/vendor/tls_client.zig: FileNotFound` İLE BAŞARISIZ
  oluyordu — bu, v1.76.0'dan BU YANA (v1.76.0/v1.77.0/v1.78.0/v1.79.0)
  HİÇBİR GitHub Release'in oluşturulamamasının KÖK NEDENİYDİ (`.github/
  workflows/release.yml`, `v*` tag push'unda TÜM 4 platformda AYNI hatayla
  başarısız oluyordu — `gh run list` İLE doğrulandı). Dosya artık git'e
  EKLENDİ; GERÇEK bir FRESH `git clone` + `zig build -Doptimize=ReleaseFast`
  İLE (bu turda) doğrulandı. AYRICA `v1.75.1` (commit `4147fc0`, "Liste
  literalinde sondaki virgül düzeltmesi") git tag'i HİÇ oluşturulmamıştı —
  eklendi (BU commit `v1.76.0`'dan ÖNCE olduğundan `vendor/tls_client.zig`ye
  bağımlı DEĞİL, etkilenmez).

## [1.79.0]

### Düzeltildi (binary şişmesi) — Faz FFI.3
- **`-rdynamic`/`--export-all-symbols`in dead-code-stripping'i engellemesi
  düzeltildi**: "FFI maliyetlerini azaltma" listesinin 3. maddesi (`Faz
  FFI.1`/`FFI.2`den sonra). Araştırma, sorunun İLK varsayılandan (SADECE
  HPy/WASM köprüsü) ÇOK DAHA GENİŞ olduğunu ORTAYA ÇIKARDI: `runtime/
  lib.zig`nin `comptime { _ = X; }` deseni ~25 stdlib shim'inin HEPSİNİ
  koşulsuz zorla-analiz ediyor, bu YÜZDEN `noxrt.o` HER ZAMAN TÜM stdlib
  runtime kodunu İçeriyordu. **Ölçülen etki**: `print("hi")` GİBİ HİÇBİR
  stdlib modülü kullanmayan bir program BİLE 7.68 MB üretiyordu — kök
  neden `-rdynamic`nin (POSIX'te `nox.json`nin `dlopen(null,...)+dlsym`
  desenini desteklemek İçİn ZORUNLU, bkz. §3.71/Faz LL.6/R.3) TÜM global
  sembolleri dinamik tabloya koyup linker'ın dead-code-stripping mantığını
  FİİLEN devre dışı bırakması (macOS'ta `-rdynamic` OLMADAN + `-dead_strip`
  İLE AYNI program 1.52 MB'a İNİYOR, ama `-rdynamic`+`-dead_strip` BİRLİKTE
  7.44 MB'ta KALIYOR — sorun `-rdynamic`nin KENDİSİ, `-dead_strip`in
  eksikliği DEĞİL). **Çözüm**: taranıp, dlsym İLE GERÇEKTEN erişilen TAM
  5 sembolün (`nox_json_make_json_value`/`nox_class_release_dispatch`/
  `nox_trace_dispatch`/`nox_gc_free_dispatch`/`nox_class_name_dispatch` —
  HEPSİ `stdlib/nox/core.nox`nin HER programa otomatik birleştirilen
  sınıfları YÜZÜNDEN HER ZAMAN üretiliyor) SABİT bir listesi çıkarıldı;
  `compiler/main.zig`ye YENİ `computeLinkerVisibilityArgs`/`NOX_DLSYM_
  SYMBOLS` — macOS `-Wl,-exported_symbol,_<isim>` ×5 + `-Wl,-dead_strip`,
  Linux `-Wl,--export-dynamic-symbol=<isim>` ×5 (binutils ≥2.35, GERÇEK
  bir Docker/Ubuntu 24.04 konteynerinde bağımsız doğrulandı) + `-Wl,
  --gc-sections`, Windows BİLİNÇLİ olarak DEĞİŞTİRİLMEDİ (blanket
  `--export-all-symbols`, PE'nin narrow-export mekanizması AYRI bir tur
  gerektiriyor, gerçek Windows CI erişimi YOK). **Ölçülen sonuç**:
  `print("hi")` ARTIK 1.51 MB (~%80 küçülme). Fonksiyonel doğruluk
  `nox.json.decode` + sınıf örnekleri + cycle-collector'ı tetikleyen 800
  örneklik bir programla kanıtlandı; break→red→fix (`nox_trace_dispatch`
  GEÇİCİ olarak listeden çıkarılıp cycle-collector'ın GERÇEKTEN sızıntı
  verdiği, GERİ eklenince temiz kaldığı) İLE 5-sembol listesinin GERÇEKTEN
  GEREKLİ/EKSİKSİZ olduğu doğrulandı. YENİ `tests/cli/binary_size_test.zig`
  (negatif-sembol-yokluğu + boyut-üst-sınırı + fonksiyonel kanıt). Bkz.
  `nox-teknik-spesifikasyon.md` §3.148.

## [1.78.0]

### Eklendi (performans) + Düzeltildi (5 GERÇEK, öncesi var olan sızıntı)
- **Faz FFI.2 — HPy `Obj` havuzlama + marshal-yolu tahsis azaltması**:
  `runtime/hpy_bridge/context.zig`nin `Obj` struct'ı (456 bayt — `Obj`
  gerçek bir union DEĞİL, TÜM tag'lerin alanları YAN YANA) artık `--release`de
  (`std.heap.MemoryPool(Obj)`, `runtime/alloc/arc.zig`/`lowlevel.zig`nin
  AYNI, ZATEN kanıtlanmış `use_pool = builtin.mode != .Debug` deseni)
  context-başına bir free-list ÜZERİNDEN TEKRAR KULLANILIYOR — Debug'da
  (`zig build test`nin VARSAYILANI) `DebugAllocator`nin TAM güvenlik ağı
  DEĞİŞMEDEN KORUNUYOR. `runtime/foreign_bridge.zig`nin `MarshalCtx`
  zincirindeki 3 tekrarlanan `packed_args` tahsisi (`invokeHpyMethod`/
  `nox_hpy_new_finish`/`nox_hpy_call_attr_int_finish`) TEK, paylaşılan bir
  `packArgs` yardımcısına ÇIKARILDI — tipik (≤8 argümanlı) HER `hpy_call_on`
  çağrısı ARTIK bu adımda SIFIR heap tahsisi yapıyor (ÖNCEDEN HER ZAMAN 1
  tahsis). Gerçek A/B ölçümü (`git worktree`, YENİ `zig build bench-hpy`,
  `sum_two_ints` İLE 2M tekrarlı kalıcı-tutamaç çağrısı, 6 kesişimli koşu):
  çağrı başına ortalama ~314ns → ~297ns (~%5.6 daha hızlı).
- **BULUNAN, ÖNCEDEN VAR OLAN 5 GERÇEK sızıntı** (havuzlamanın YENİ
  `checkAllAllocationFailures` OOM-fuzz testi YAZILIRKEN yakalandı,
  havuzlamanın KENDİSİYLE İLGİSİZ, DAHA ÖNCE hiç test edilmemiş yollar):
  1. `createContext`nin ~28 tekil (None/True/False/istisna tipleri/yerleşik
     tipler/`h_SliceType`) inşası HİÇBİR rollback YAPMIYORDU — aralarından
     HERHANGİ biri (OOM) başarısız olsaydı ÖNCEKİLER SONSUZA KADAR sızardı;
     artık HER biri kendi `errdefer allocator.destroy(...)`ını alıyor.
  2. `ctxSetItem`/`ctxSetAttr`nin dict-ekleme dalları, `ctxDup`ı `append`in
     argüman ifadesinin İÇİNDE DOĞRUDAN çağırıyordu — `append` SONRADAN
     BAŞARISIZ olursa BU retain'ler asla geri alınmıyordu; `ctxListAppend`in
     ZATEN doğru olan "ÖNCE dup'la, SONRA dene, başarısızsa kapat" desenine
     getirildi.
  3. `ctxDictKeys`/`ctxDictCopy`/`ctxListGetSlice` (slice-GetItem) de AYNI
     kategoriden bir eksiklik taşıyordu (önceki iterasyonların dup'larını
     rollback'te kapatıyorlardı AMA BAŞARISIZ olan İTERASYONUN KENDİ dup'ını
     DEĞİL) — aynı şekilde düzeltildi.
  Bkz. `nox-teknik-spesifikasyon.md` §3.147.

## [1.77.0]

### Düzeltildi (KRİTİK ARC sızıntısı) + Eklendi (performans)
- **Faz FFI.1 — `extern def` çağrı yolunun ARC sızıntısı düzeltildi**:
  `compiler/codegen_qbe/calls.zig`nin `extern def` çağrı yolu (`genCall`nin
  `self.extern_functions.get(name)` dalı), sıradan Nox fonksiyon çağrılarının
  AKSİNE, `releaseTemporaryArgs`ı HİÇ ÇAĞIRMIYORDU — GEÇİCİ (taze) bir
  `str`/`list`/`dict`/`class` argümanı (ör. bir string birleştirmesinin
  SONUCU) bir `extern def`e geçirildiğinde refcount'u ASLA düşürülmüyordu,
  yani `extern_def(bir_birlestirme())` GİBİ HER çağrı bir tahsisi
  SONSUZA KADAR sızdırıyordu. Sıradan çağrı yolunun AYNI, ZATEN
  kanıtlanmış `releaseTemporaryArgs` çağrısı EKLENEREK düzeltildi.
- **Escape-analysis genişletmesi (asıl performans kazanımı)**: `local_
  escape.zig`/`inlining.zig`'in ASAP (GG.16-21) escape-analysis'i,
  `extern def`lere argüman GEÇEN yerel değişkenleri/parametreleri HER
  ZAMAN KOŞULSUZ "kaçıyor" sayıyordu — çünkü `extern def`ler AYRI bir
  tabloda (`self.extern_functions`) kayıtlı olduğundan, serbest fonksiyon
  çağrıları İçİn ZATEN var olan "kanıtlanmış güvenli yönlendirme"
  carve-out'una HİÇ girmiyorlardı. TÜM `extern def`ler (isim-listesi
  OLMADAN, `computeMustNotRaise`nin AYNI KOŞULSUZ-güven emsaliyle
  TUTARLI) escape-analysis İçİn KOŞULSUZ güvenli sayılacak şekilde
  genişletildi — bu, `nox.sqlite`/`nox.postgres`/`nox.mysql`/`nox.tls`/
  `nox.smtp`/`nox.websocket`/`nox.http` GİBİ TÜM stdlib sürücülerinin
  extern def'e geçen argümanlarının ARTIK stack/arena'ya promote
  edilebilmesini sağlıyor (ÖNCEDEN HER ZAMAN tam ARC'a düşüyordu).
  Bağımsız bir güvenlik denetimi, `str`/`list` argüman alan TÜM 82
  `extern def`in HİÇBİRİNİN çağrı-sonrası ham işaretçiyi SAKLAMADIĞINI
  doğruladı. Bkz. `nox-teknik-spesifikasyon.md` §3.146.

## [1.76.0]

### Düzeltildi (KRİTİK compiler hatası)
- **`and`/`or` artık GERÇEKTEN kısa devre yapıyor**: ÖNCEDEN `and`/`or`
  KOŞULSUZ QBE bit-işlemlerine (HER İKİ operandı da HER ZAMAN
  değerlendiren) derleniyordu — `pos < n and text[pos] == "X"` gibi bir
  koruma deseni `pos >= n` İKEN BİLE `text[pos]`i değerlendirip bir
  IndexError'a/SIGSEGV'e yol açabiliyordu (Faz STD.3/STD.5'in `nox.toml`/
  `nox.yaml`sinde nested-`if` İLE ELLE atlatılmıştı). ARTIK gerçek jnz+phi
  kontrol akışıyla derleniyor. Bu düzeltme SIRASINDA, phi düğümünün
  öncüllerini SABİT VARSAYAN (sağ operandın KENDİSİ BAŞKA bir dallanma
  İçEREBİLECEĞİNİ HESABA KATMAYAN) İKİNCİ, AYRI bir codegen hatası da
  bulunup düzeltildi — `Codegen`e YENİ bir `current_label` alanı eklendi.
  Bkz. `nox-teknik-spesifikasyon.md` §3.143.
- **`return s[i]` (str char-at) fonksiyondan dönerken ARC sızdırıyordu**:
  `returnNeedsRetain`nin `.index` dalı TABANI SIZDIRAN (list/dict) İLE
  TABANDAN BAĞIMSIZ TAZE bir değer üreten (str char-at) durumu AYIRT
  EDEMİYORDU — `Value.always_fresh` bayrağına güvenilerek düzeltildi.
- **Checker: `dict[K,V]`, protokol-tipli bir parametreye SAHİP OLDUĞU
  İçİn örtük generic sayılan fonksiyonlarda TANINMIYORDU** (`unifyTypeExpr`
  SADECE `list[T]`yi destekliyordu) — `conn: DbConnection` GİBİ bir
  parametre taşıyan HERHANGİ bir fonksiyonun `dict[K,V]` tipli BAŞKA bir
  parametresi "bilinmeyen generic tip: dict" hatasıyla REDDEDİLİYORDU.
- **AYNI yolda, boş `[]`/`{}` literalinin argüman olarak geçmesi tip
  çıkarımını BAŞARISIZ kılıyordu** (`where_params: list[Value] = []`
  gibi) — parametrenin bildirilen (tip-parametresi İçERMEYEN) tipi
  doğrudan kullanılacak şekilde düzeltildi.

### Eklendi
- **Faz STD.5 — `nox.yaml`**: kullanıcının 5 maddelik yol haritasının 3.
  maddesinin ("stdlib eksikleri") 5. (SONUNCU stdlib-gap) alt-parçası.
  `nox.toml`nin AYNI "saf Nox, kendi elle-yazılmış ayrıştırıcı" felsefesi,
  YAML'ın girinti-duyarlı/satır-tabanlı yapısına uyarlanmış, BİLİNÇLİ
  olarak DAR bir v1: blok/akış-stili eşleme+dizi, üç skaler tırnak biçimi,
  yorumlar, TEK bir opsiyonel baştaki `---` (İKİNCİ bir belge işareti
  `YamlError` İLE reddedilir). Bkz. `nox-teknik-spesifikasyon.md` §3.144.
- **Faz STD.6 — `nox.orm`**: roadmap'in 3. maddesinin SON alt-parçası.
  `nox.db`nin `DbConnection` protokolü ÜZERİNE İnşa edilen, `Table`/
  `Column` şeması + GERÇEK parametre bağlamasıyla (`Statement.bind_*`,
  SQL metnine ham DEĞER GÖMÜLMEZ) `create_table`/`insert`/`update`/
  `delete`/`select` CRUD yardımcıları sağlayan bir mikro-ORM. `Statement`
  (Row GİBİ) sqlite/postgres/mysql'in ÜÇÜNÜN de PAYLAŞTIĞI TEK, SOMUT bir
  sınıf oldu (protokol tipleri Nox'ta dönüş-tipi OLAMADIĞINDAN) — HER
  sürücünün KENDİ bind/execute/query mantığı fonksiyon-DEĞERİ alanları
  OLARAK enjekte edilir. Bkz. `nox-teknik-spesifikasyon.md` §3.145.
- Kullanıcının 5 maddelik yol haritasının 3. maddesi ("stdlib eksikleri" —
  csv/gzip/toml/smtp/yaml/orm) BU sürümle TAMAMEN BİTTİ.

### Doğrulandı
- `tests/cli/orm_test.zig`: GERÇEK bir SQLite'a karşı uçtan-uca CRUD akışı.
- ELLE, GERÇEK Docker Postgres 16 + MySQL 8 konteynerlerine karşı
  `nox.orm`nin KENDİSİ DAHİL tam CRUD doğrulandı — üçü de (sqlite dahil)
  AYNI sonuçları üretti; konteynerler doğrulama sonrası kaldırıldı.
- Tam `zig build test` (Debug+ReleaseFast) — TÜM MEVCUT testler (`nox.csv`/
  `nox.toml`/`nox.random`/decorator router testleri DAHİL) DEĞİŞMEDEN geçti.

## [1.75.1]

### Düzeltildi
- **Liste literalinde sondaki virgül `UnexpectedToken`la reddediliyordu**:
  `cols: list[int] = [1,\n2,\n]` gibi sondaki virgüllü bir liste literali
  (çok satırlı ya da tek satırlık — `[1, 2,]`) `noxc build`i çökertiyordu.
  Kök neden: `parser.zig`nin liste-literali döngüsü virgülü yuttuktan
  SONRA `]`yi kontrol etmeden HER ZAMAN yeni bir eleman bekliyordu. Bkz.
  `nox-teknik-spesifikasyon.md` §3.142.

## [1.75.0]

### Eklendi
- **Faz STD.4 — `nox.smtp`**: kullanıcının 5 maddelik yol haritasının 3.
  maddesinin ("stdlib eksikleri") 4. alt-parçası. Roadmap'in KENDİ
  ÖNCEDEN yazılmış notu "YENİ bir ham TCP soket ilkeli GEREKTİRİYOR"
  diyordu — bu VARSAYIM YANLIŞTI: `nox.tls`/`nox.websocket` (Faz NN.5,
  ZATEN VAR) plain-TCP connect + satır-tamponlu CRLF okuma + koşullu TLS
  katmanlamayı ZATEN İçEREN bir şablon sağlıyordu — `nox.smtp` SIFIR
  yeni soket ilkeli VE SIFIR checker/codegen değişikliği İLE yazıldı.
- `nox.smtp.connect(host, port, use_tls) -> SmtpClient` — `use_tls=True`
  ANINDAN TLS (SMTPS), `use_tls=False` düz-metin (SONRADAN `.starttls()`
  İLE yükseltilebilir). Bağlandıktan HEMEN SONRA "220" karşılama
  banner'ini OKUR/DOĞRULAR.
- `SmtpClient.ehlo`/`.starttls`/`.auth_login`/`.auth_plain`/`.send`
  (BİRDEN FAZLA alıcı + RFC 5321 §4.5.2 dot-stuffing DAHİL)/`.quit`/
  `.close` — TÜM EHLO/AUTH/MAIL FROM/RCPT TO/DATA protokol mantığı SAF
  Nox'ta (`stdlib/nox/smtp.nox`), Zig kabuğu (`runtime/stdlib_shims/
  smtp.zig`) SADECE ham bağlantı/satır-okuma/yazma/TLS-yükseltme sağlar.
- `nox.smtp.send_mail(...)` — TEK bir e-postayı connect→ehlo→(starttls)→
  (auth)→send→quit→close İLE baştan sona gönderen kolaylık fonksiyonu.
- `SmtpError` — bağlantı/yazma/okuma/protokol hatalarında fırlatılır.
- **AUTH PLAIN'in NUL-güvenlik çözümü**: ham payload'u (`\0kullanıcı\0şifre`)
  İKİ GÖMÜLÜ NUL bayt İçerdiğinden Nox'un NUL-sonlandırmalı `str`inde HİÇ
  İNŞA EDİLEMEZ (`sharedmem.nox`/`gzip.zig`'in AYNI kısıtı) — Zig kabuğu
  `username`/`password`yi AYRI argüman olarak alıp payload'u KENDİ `[]u8`
  dilimi İçİNDE inşa edip SADECE base64-KODLANMIŞ (NUL-SUZ) sonucu döner.

### Doğrulandı, ELLE (harici İnternet erişimine bağımlı olmaması İçin
### CI'da OTOMATİK DEĞİL — `nox.tls`/`nox.websocket`nin AYNI konvansiyonu)
- TAM protokol durum makinesi (EHLO, AUTH LOGIN, BİRDEN FAZLA alıcı İLE
  MAIL FROM/RCPT TO, DATA — dot-stuffing DAHİL, doğru şekilde ".."ye
  çevrilen bir "." satırıyla — QUIT) YEREL bir sahte SMTP sunucusuna
  (kendi yazdığım bir Python soket script'i) karşı byte-byte doğrulandı.
  AUTH PLAIN'in NUL-ayraçlı payload'u da AYRICA doğrulandı (`decoded:
  b'\x00dave\x00p@ss'`).
- **STARTTLS'in KENDİ mekanizması** (mevcut bir düz-metin bağlantıyı
  SONRADAN TLS'e yükseltme — bu fazın EN YENİ/EN RİSKLİ kısmı) YEREL,
  kendinden-imzalı sertifikalı bir test sunucusuna karşı doğrulandı:
  hata `TlsCertificateNotVerified` (bir SERTİFİKA-GÜVEN hatası, protokol
  karışıklığı DEĞİL) İLE sonuçlandı — bu, el sıkışmanın DOĞRU sırayla
  başlayıp sertifika-doğrulama aşamasına KADAR ULAŞTIĞININ kanıtıdır.

### Bulundu (BU turda keşfedilen, `nox.tls`ye AİT, ÖNCEDEN VAR OLAN
### bir sınırlama — `nox.smtp`nin KENDİ hatası DEĞİL)
- **`nox.tls` (VE dolayısıyla `nox.smtp`nin STARTTLS'i), BAZI GERÇEK
  mail-sunucusu TLS uç noktalarıyla `TlsUnexpectedMessage` İLE
  BAŞARISIZ oluyor** — `smtp.gmail.com:465` (ANINDAN TLS) VE
  `smtp.gmail.com:587`/`smtp.office365.com:587` (STARTTLS) İKİSİ de BU
  hatayla BAŞARISIZ OLDU, AMA `www.google.com:443`/`example.com:443`
  (SIRADAN HTTPS) `nox.tls` İLE SORUNSUZ ÇALIŞIYOR — bu YÜZDEN SORUN
  `nox.smtp`nin STARTTLS-ERTELEME mantığında DEĞİL, `nox.tls`nin ZATEN
  paylaştığı `std.crypto.tls.Client`in KENDİSİNDE (muhtemelen mail
  sunucularının GÖNDERDİĞİ, isteğe bağlı bir `CertificateRequest`
  mesajını Zig'in TLS 1.3 durum makinesinin TANIMAMASI — `Handshake
  State` enum'unda BÖYLE bir durum YOK) — AYRI bir araştırma/düzeltme
  görevi olarak flaglendi (bu turun kapsamı DIŞINDA).

## [1.74.0]

### Eklendi
- **Faz STD.3 — `nox.toml`**: kullanıcının 5 maddelik yol haritasının 3.
  maddesinin ("stdlib eksikleri") 3. alt-parçası. Saf Nox'ta yazıldı
  (`nox.csv`nin AYNI "tek-geçişli, karakter-karakter durum makinesi"
  deseni) — YENİ bir runtime ilkeli GEREKMEDİ.
- `nox.toml.parse(text: str) -> TomlValue` — yorumlar (`#...`), `[tablo]`
  başlıkları (noktalı İç İçe: `[a.b.c]`), çıplak/tırnaklı anahtarlı
  `key = value` çiftleri, değer tipleri: temel string (kaçış dizileriyle),
  integer (alt çizgi ayraçlı, `1_000` DAHİL), float (üstel gösterim
  DAHİL), bool, dizi (`[1, 2, 3]` — TEK-satırlık VE ÇOK-satırlık, köşeli
  parantez İçİnde boşluk/satır-sonu/yorum ÖNEMSİZ).
- `nox.toml.TomlValue` — SAF (core.nox'a BAĞIMLI OLMAYAN, `json.nox`nin
  reverse-FFI zorunluluğu BURADA GEREKMEDİĞİNDEN) bir kullanıcı sınıfı,
  tablolar İçİn GERÇEK bir `dict[str, TomlValue]` kullanır. `is_string`/
  `is_int`/`is_float`/`is_bool`/`is_array`/`is_table` tip-sorgu yardımcıları.
- `nox.toml.get(root: TomlValue, dotted_path: str) -> TomlValue` — `"a.b.c"`
  GİBİ noktalı bir yolu KÖKTEN itibaren çözer.
- `nox.toml.TomlError` — array-of-tables (`[[...]]`, v1'de desteklenmiyor),
  sonlandırılmamış string/dizi, GEÇERSİZ sayı/anahtar İçİn fırlatılır.
- **Kapsam DIŞI (BİLİNÇLİ v1)**: array-of-tables, inline table (`{k=v}`),
  çok-satırlı/literal string, tarih/saat, hex/octal/binary sayılar,
  `key=value` satırlarında noktalı anahtar.

### Bulundu (dil-seviyesi, BU turda KEŞFEDİLEN, DÜZELTİLMEDEN belgelenen)
- **Nox'ta `and`/`or` KISA-DEVRE YAPMAZ** — `compiler/codegen_qbe/expr.zig`
  HER İKİ operandı da KOŞULSUZ QBE `and`/`or` bit-işlemine ÇEVİRİR
  (dallanma/erken-çıkış YOK). Bu YÜZDEN `pos < n and text[pos] == "X"`
  GİBİ bir desen, `pos >= n` OLSA BİLE `text[pos]`i DENER — Python/JS/
  C'nin AKSİNE, YAYGIN bir varsayım İHLAL EDİLİYOR. `toml.nox` TÜM
  bounds-guard+index desenlerini `_char_at_or_empty`/`_safe_substr`
  yardımcılarıyla (bounds kontrolünü İçİNE ALAN AYRI fonksiyonlar)
  YENİDEN yazarak BUNU atlatıyor — dilin KENDİSİ BU turda DEĞİŞTİRİLMEDİ
  (blast radius'u ÇOK BÜYÜK bir semantik değişiklik olurdu, AYRI bir
  karar/tur gerektirir).
- **Bir fonksiyondan DOĞRUDAN `return s[i]` (çıplak string-indeksleme
  dönüşü) bir ARC sızıntısına yol açıyor** — tek-karakter sonucu fonksiyon
  SINIRINI GEÇERKEN retain edilmiyor (`nox_str_char_at` sonrası). `return
  "" + s[i]` (bir birleştirme operasyonu ÜZERİNDEN geçirmek) sızıntıyı
  ORTADAN KALDIRIYOR — `toml.nox`nin `_char_at_or_empty`si BU ELLE-
  ÖNLENMİŞ deseni kullanıyor. Kök neden (codegen'in fonksiyon-dönüşü
  release/retain zinciri) BU turda İNCELENMEDİ/DÜZELTİLMEDİ.

## [1.73.0]

### Eklendi
- **Faz STD.2 — `nox.gzip`**: kullanıcının 5 maddelik yol haritasının 3.
  maddesinin ("stdlib eksikleri") 2. alt-parçası. Zig'in `std.compress.
  flate`si (`compiler/pkg/upgrade.zig`nin `.tar.gz` paket indirmede
  İçSEL kullandığı, KANITLANMIŞ API) Nox programlarına dışa açıldı.
- `nox.gzip.compress(text: str) -> list[int]` / `decompress(data:
  list[int]) -> str` — bir metni gzip formatında sıkıştırır/açar.
- `nox.gzip.compress_bytes`/`decompress_bytes(data: list[int]) ->
  list[int]` — keyfi ikili veri İçİn genel ilkel.
- `nox.gzip.GzipError` — geçersiz gzip verisi/geçersiz bayt listesi
  (0-255 dışı) İçİn fırlatılır; `decompress` AYRICA açılan verinin
  gömülü NUL bayt İÇERMEDİĞİNİ (Nox'un NUL-sonlandırmalı `str`
  temsili İçİn GÜVENLİ olduğunu) doğrular.
- **KRİTİK tasarım kararı**: sıkıştırılmış veri ASLA `str` OLARAK
  taşınmaz — Nox'un `str`i NUL-sonlandırmalı OLDUĞUNDAN VE gzip çıktısı
  neredeyse HER ZAMAN gömülü `0x00` bayt İÇERDİĞİNDEN, `list[int]`
  (HER eleman 0-255) kullanılır (`stdlib/nox/sharedmem.nox`nin AYNI,
  önceden belgelenmiş kısıtı).
- `compiler/typecheck/checker.zig`nin `isFfiSafeListType`ına `list[int]`
  eklendi — `extern def`in C ABI sınırında artık `list[str]`e EK olarak
  `list[int]` de parametre/dönüş tipi olarak geçirilebiliyor (`list[str]`in
  AYNI, ZATEN kanıtlanmış ARC-list temsili gerekçesiyle).

### Sıradaki alt-parçalar (AYRI Plan Mode turlarında)
- `nox.zip` (arşiv okuma — Zig'in `std.zip`si BU sürümde SADECE okuma
  destekliyor, yazma/oluşturma YOK), `nox.toml`, `nox.smtp`, `nox.yaml`,
  ORM.

## [1.72.0]

### Eklendi
- **Faz STD.1 — `nox.csv`**: kullanıcının 5 maddelik yol haritasının 3.
  maddesinin ("stdlib eksikleri — csv/yaml/toml/eposta/sıkıştırma/orm")
  İLK alt-parçası. RFC 4180 uyumlu CSV ayrıştırma/yazma, SAF Nox'ta
  yazıldı (`stdlib/nox/csv.nox`) — YENİ bir runtime ilkeli/Zig değişikliği
  GEREKMEDİ.
- `nox.csv.parse(text: str) -> list[list[str]]` — virgülle ayrılmış,
  çift-tırnak İLE alıntılanabilen alanlar (alıntılı bir alan virgül/
  tırnak/satır-sonu İÇEREBİLİR, kaçış İçİn `""`). HEM `\n` HEM `\r\n`
  satır sonu KABUL edilir; sondaki temiz bir satır-sonu SAHTE bir ek
  satır ÜRETMEZ.
- `nox.csv.parse_dicts(text: str) -> list[dict[str, str]]` — İLK satırı
  başlık olarak kullanıp isimle erişim SAĞLAR.
- `nox.csv.write_row`/`write` — özel karakter İçEREN alanları OTOMATİK
  tırnaklar/kaçırır.
- `nox.csv.CsvError` — SADECE sonlandırılmamış tırnak İçİn fırlatılır.

### Sıradaki alt-parçalar (AYRI Plan Mode turlarında)
- Sıkıştırma (`nox.gzip`/`nox.zip` — Zig'in `std.compress.flate`/`std.zip`sini
  dışa açmak), `nox.toml`, `nox.smtp` (YENİ bir ham TCP soket ilkeli
  GEREKTİRİYOR), `nox.yaml`, ORM (`stdlib/nox/db.nox`nin `DbConnection`
  protokolü üzerine İNŞA edilecek).

## [1.71.0]

### Eklendi
- **Faz SC.2 — `Task[T].cancel()` + `CancelledError` (kooperatif görev
  iptali)**: kullanıcının 5 maddelik yol haritasının 2. maddesi
  ("structured concurrency")nin İKİNCİ turu — Faz SC.1'in (v1.70.0)
  onardığı `spawn`/`await` istisna-yayılım kanalını KULLANARAK GERÇEK
  bir Task iptal mekanizması eklendi.
- YENİ `stdlib/nox/core.nox`: `CancelledError(Exception)` — `ValueError`/
  `IndexError`/`KeyError`/`HPyError`YLA AYNI desen.
- `t.cancel()` — bir `Task[T]` değeri üzerinde ÇAĞRILABİLEN, senkron
  bir "iptal İSTE" bayrağı (`runtime/async_rt/scheduler.zig`nin `Task(T)`sine
  YENİ `cancel_requested` atomiği, `runtime/async_rt/bridge.zig`nin
  YENİ `nox_task_cancel`ı). `t.fiber`e HİÇ DOKUNMAZ — Task'ın KENDİ ömrü
  BOYUNCA (COMPLETED/DETACHED FARK ETMEKSİZİN) HER ZAMAN GÜVENLİ.
- **Kooperatif iptalin KENDİSİ**: cancel edilen task'ın KENDİ kodu bir
  SONRAKİ `await <Task>` yaptığında (Faz SC.1'in AYNI genel yolu)
  `CancelledError` fırlatılır — kendi `try`/`except`i yakalayabilir;
  yakalamazsa Faz SC.1'in kanalıyla dış `await` edene ulaşır. `runtime/
  async_rt/fiber.zig`ye YENİ `cancel_flag` (fiber'ın KENDİ Task'ının
  bayrağına işaretçi), `bridge.zig`ye YENİ `nox_task_check_cancelled`,
  `compiler/codegen_qbe/async_thread.zig`nin `genAwaitExpr`ına iptal-
  kontrolü (`genConstructFromValues`+`nox_raise`+`emitExceptionCheck`in
  AYNI, ZATEN kanıtlanmış zinciri).
- `t.cancel()`in checker/codegen tanınması: `compiler/typecheck/checker.zig`nin
  `.attribute` koluna YENİ `.task` bloğu, `compiler/codegen_qbe/calls.zig`nin
  `genMethodCall`ına YENİ dispatch, YENİ `genTaskCancel`.

### v1 bilinçli sınırlar
- Task hiç `await` YAPMIYORSA (SAF CPU-bağımlı kod) iptal HİÇ etkili
  OLMAZ — kooperatif modelin doğal sınırı (Python'un `asyncio`suyla AYNI).
- `Channel[T]`/`ThreadChannel[T]`/`ThreadHandle[T]` İçİn AYNI iptal-
  kontrolü BU turun kapsamı DIŞINDA (SADECE genel `Task[T]` `await`i).
- `t.cancel()` `None` döner (Python'un `bool` dönüşü GİBİ "iptal EDİLEBİLİR
  miydi" bilgisi YOK, BASİTLİK İçİn).

## [1.70.0]

### Düzeltildi
- **Faz SC.1 — `spawn`/`await` sınırında istisna yayılımı düzeltmesi**:
  bir `spawn` edilen `async def`nin gövdesinde YAKALANMAMIŞ bir istisna
  oluştuğunda, BUGÜNE KADAR bu istisna SESSİZCE KAYBOLUYORDU — `await`
  eden taraf istisnayı ASLA görmüyordu, `try`/`except` HİÇBİR ZAMAN
  tetiklenmiyordu, `await` SADECE (çöp/varsayılan) bir değer
  döndürüyordu. Bu, `nox-teknik-spesifikasyon.md`nin ("`async def`
  gövdesinde oluşan bir istisnanın... TAM entegrasyonu yok") AÇIKÇA
  belgelenmiş, BİLİNEN bir eksiklikti — GERÇEK, test edilebilir bir
  sessiz-yutma hatası olduğu bu turda netleşti VE düzeltildi.
- `runtime/async_rt/scheduler.zig`nin `Task(T)`sine YENİ `exc_obj`/
  `exc_line` alanları — `entryTrampoline`, sarmalanan gövde bir istisna
  BIRAKTIYSA (`Fiber.pending_exception`) bunu BURAYA (move semantiğiyle)
  taşır. `runtime/async_rt/bridge.zig`nin `nox_async_await`ı ARTIK bunu
  await eden tarafın bağlamına `nox_raise` İLE YENİDEN fırlatır.
  `compiler/codegen_qbe/async_thread.zig`nin `genAwaitExpr`ına, sıradan
  fonksiyon/metod/kurucu çağrılarıyla AYNI, ZATEN kanıtlanmış
  `emitExceptionCheck()` zincirine bağlanan TEK bir çağrı eklendi —
  YENİ bir dispatch/label mantığı İCAT EDİLMEDİ.
- Aynı, tamamlanmış bir `Task`ı İKİNCİ kez `await` etmek istisnayı BİR
  DAHA fırlatmaz (v1 BİLİNÇLİ sınırı — ARC'ın tek-sahiplikli referans
  modeliyle TUTARLI).

### Kapsam DIŞI (Round 2'nin/gelecekteki turların konusu)
- `Task[T].cancel()` + `CancelledError`nin KENDİSİ (kullanıcının ASIL
  istediği özellik — BU FAZ onun ÖNKOŞULU olan istisna-yayılım kanalını
  onardı).
- `Channel[T]`/`ThreadChannel[T]`nin `.send`/`.recv`i VE
  `ThreadHandle[T].join()` İçİn AYNI istisna-yayılım boşluğu.

## [1.69.0]

### Eklendi
- **Faz ÜH.1 — gerçek, kurulabilir bir VS Code Nox eklentisi + `noxlsp`ye
  `textDocument/formatting`**: `noxlsp` (bkz. `compiler/lsp_main.zig`)
  sunucu tarafında ZATEN `completion`/`definition`/`hover`/tanılama
  destekliyordu (P1.3/P1.4), AMA `editors/vscode-nox/` bugüne kadar
  YALNIZCA debugger (DAP) yapılandırma örnekleri İçEREN bir klasördü —
  GERÇEK, kurulabilir bir VS Code UZANTISI (package.json/sözdizimi
  grameri/LSP istemcisi) HİÇ YOKTU. `editors/tree-sitter-nox`nin KENDİ
  grameri de VS Code'un DOĞRUDAN KULLANAMAYACAĞI bir format (VS Code
  sözdizimi vurgulama İçİn TextMate grameri BEKLER). Sonuç: `noxlsp`
  binary'si TAM çalışır durumda olsa BİLE HİÇBİR kullanıcı VS Code'da
  bir `.nox` dosyası açıp TEK BİR LSP özelliğini (VEYA sözdizimi
  vurgulamayı) GÖREMİYORDU — eksik olan SUNUCU DEĞİL, PAKETLEME idi.
- YENİ `editors/vscode-nox/package.json` (uzantı manifestosu — `contributes.
  languages`/`contributes.grammars`/`nox.languageServerPath` ayarı),
  `language-configuration.json` (yorum/parantez/girinti kuralları),
  `syntaxes/nox.tmLanguage.json` (elle yazılmış TextMate grameri,
  `editors/tree-sitter-nox/queries/highlights.scm`nin token kategori
  isimlendirmesiyle TUTARLI), `src/extension.ts` (`vscode-languageclient`
  ile `noxlsp`yi stdio üzerinden başlatan istemci — `noxlsp` ZATEN gerçek
  JSON-RPC konuştuğundan sunucu-tarafında SIFIR değişiklik gerekmedi),
  `tsconfig.json`/`.vscodeignore` (`.vsix` üretim ayarları — Marketplace'e
  YAYIMLAMAK bu kapsamda DEĞİL). Mevcut `.vscode/launch.json.example`/
  `tasks.json.example` (DAP örnekleri) DEĞİŞMEDEN KORUNDU.
- YENİ `noxlsp` yeteneği: `textDocument/formatting` — `compiler/lsp_main.
  zig`nin `handleFormatting`ı, `compiler/main.zig`nin `cmdFmt`ıyla AYNI
  `lexer.tokenizeWithTrivia`→`parser.parseModule`→`formatter.formatModule`
  zincirini yeniden kullanarak (SIFIR yeni biçimlendirme mantığı) tek bir
  tam-belge `TextEdit` döner; `respondInitialize`nin `Capabilities`sine
  `documentFormattingProvider: true` eklendi. Kaynak GEÇERSİZ sözdizimine
  sahipse (kullanıcı O AN yazıyor olabilir) BOŞ bir edit dizisi döner —
  arabelleği ASLA bozmaz.
- `tests/cli/lsp_test.zig`ye YENİ, uçtan uca test: kötü biçimli AMA
  geçerli bir kaynağın `textDocument/formatting` İLE doğru şekilde
  yeniden biçimlendirildiğini VE geçersiz sözdizimli bir kaynakta BOŞ
  bir edit dizisi döndüğünü doğrular (gerçek `noxlsp` alt-süreci +
  gerçek JSON-RPC teli üzerinden, mevcut 3 testin AYNI deseni).

### Kapsam DIŞI (gelecekteki LSP turlarına bırakıldı)
- Çapraz-dosya/import-tabanlı goto-definition/hover, `textDocument/rename`,
  semantic tokens, VS Code Marketplace'e gerçekten yayımlamak.

## [1.68.0]

### Eklendi
- **Faz 24 — bellek-içi "file-like" writer/reader nesneleri**: `hpy-ujson`nin
  `dump()`/`load()`si (VE genel olarak çağrılabilir bir `.write(str)`/
  `.read()` attribute'una sahip bir "file-like" nesne BEKLEYEN HERHANGİ
  bir HPy fonksiyonu) artık Nox'tan çağrılabiliyor. Nox'un KENDİ, dahili
  (TAMAMEN Zig'de implemente edilmiş) BASİT bir bellek-İçİ (string) writer/
  reader nesnesi İNŞA EDİLDİ — GERÇEK bir Nox closure'ını KEYFİ bir HPy-
  çağrılabilir NESNEYE dönüştüren GENEL bir reverse-FFI mekanizması
  İCAT ETMEK YERİNE (orantısız büyük bir iş), `dump`/`load`ın İhtiyaç
  duyduğu TAM protokolü (`.write(str) -> int`, `.read() -> str`) karşılayan
  DAR/GERÇEKÇİ bir v1.
- YENİ `ObjTag` varyantları `.io_writer_`/`.io_reader_` (`runtime/hpy_bridge/
  context.zig`) — `attrLookup`nin PAYLAŞILAN `wrapBoundMethod` yardımcısı
  (Faz 21'in `type_methods` bulma dalından ÇIKARILDI) İLE `write`/`read`
  attribute'larını TAZE bir `.bound_method_` nesnesine SARAR.
- YENİ builtinler: `hpy_new_string_writer_on(handle: ptr) -> ptr`,
  `hpy_writer_get_str_on(handle: ptr, writer: ptr) -> str` (writer'ın
  BİRİKMİŞ TÜM `.write()` çağrılarının birleşimini okur), `hpy_new_string_
  reader_on(handle: ptr, content: str) -> ptr` (`.read()` İLK çağrıda
  TÜM içeriği, SONRAKİ çağrılarda boş — GERÇEK dosya nesnelerinin "EOF'tan
  SONRA boş döner" davranışıyla TUTARLI). `hpy_close_obj` (Faz 19) AYNEN
  yeniden KULLANILIR — YENİ bir "close" builtin'İNE GEREK YOK.
- Faz 19'un `.ptr` argüman marshalanabilirliği (`isHpyMarshalableArgType`)
  SAYESİNDE writer/reader nesneleri, HİÇBİR YENİ codegen/checker değişikliği
  GEREKMEDEN `hpy_call_on`/`hpy_call_obj_on` GİBİ MEVCUT çağrı yerleşiklerine
  argüman OLARAK geçirilebiliyor.

### Düzeltildi
- **`nox_hpy_call_int_finish`/`_float_finish`/`_str_finish`nin unmarshal
  SONRASI `ctx_Err_Occurred`i HİÇ kontrol etmemesi (GERÇEK `hpy-ujson`nin
  `dump()`u ELLE test EDİLİRKEN bulundu, writer/reader özelliğiyle
  İLİŞKİSİZ AYRI bir hata)**: bir C fonksiyonu `None` (VEYA beklenenden
  FARKLI bir tip) DÖNDÜĞÜNDE VE `hpy_call_on` (int BEKLER) GİBİ YANLIŞ
  bir tipli çağrı yerleşiğiyle çağrıldığında, unmarshal (`ctx_Long_
  AsInt64_t`/vb.) `ctx`nin KENDİ İÇ hata durumuna (Nox'un AYRI `g_hpy_
  last_error` kanalından TAMAMEN BAĞIMSIZ) bir `TypeError` YAZIYOR AMA
  BUNU HİÇ KONTROL/TEMİZLEMİYORDU — bu SESSİZCE "başarılı" (garbage `0`/
  `0.0`/`""`) dönüyor VE `ctx`nin İÇ hata durumu KİRLİ KALIYORDU. AYNI
  `h` üzerindeki BAŞKA, TAMAMEN İLİŞKİSİZ bir SONRAKİ çağrı (`HPyArg_
  ParseKeywords`nin KENDİSİ BİLE bir PENDING hatayla karşılaştığında
  BAŞARISIZ olabiliyordu) BU YÜZDEN GİZEMLİ şekilde BOZULUYORDU. Düzeltme:
  YENİ paylaşılan `checkUnmarshalErr` yardımcısı unmarshal SONRASI da
  `ctx_Err_Occurred`i kontrol EDER — VARSA temizleyip GERÇEK bir `HPyError`
  OLARAK yüzeye ÇIKARIR.

### Doğrulandı
- GERÇEK `hpy-ujson`nin `dump()`/`load()`si (`hpy_new_string_writer_on`+
  `hpy_call_obj_on(h, "dump", ..., w)`+`hpy_writer_get_str_on`;
  `hpy_new_string_reader_on`+`hpy_call_obj_on(h, "load", r)`+`hpy_getitem_
  int_on`) uçtan uca DOĞRU çalışıyor — int/list argümanları İçİn `dump()`
  DOĞRU JSON metni üretiyor, `load()` DOĞRU liste elemanlarını DÖNÜYOR,
  BİRDEN FAZLA ardışık çağrı SIZINTISIZ/BOZULMADAN çalışıyor.
- 5 YENİ golden test (`tests/compat/hpy_call_golden_test.zig`): writer
  round-trip (yazılan bayt sayısı + biriken içerik), BİRDEN FAZLA `.write()`
  çağrısının birikmesi, reader round-trip + "EOF'tan sonra boş" davranışı,
  `write()`e str-DIŞI argüman İçİn `HPyError`, VE unmarshal-tipi-uyuşmazlığı
  düzeltmesinin (`ctx`nin İÇ durumunun KİRLENMEDİĞİNİN) kanıtı.
- `zig build test` (Debug+ReleaseFast, TAM paket) + `NOX_STRESS_ROUNDS=800
  zig build stress-test -Doptimize=ReleaseFast` TEMİZ geçti.

## [1.67.0]

### Düzeltildi
- **Faz 23 — `HPy_TypeCheck`nin yerleşik tipler İçİn HER ZAMAN yanlış
  dönmesi (GERÇEK `hpy-ujson` — UltraJSON'ın HPy portu — İLE bulundu)**:
  kullanıcının kendi, önceden entegre ettiği `hpy-ujson` projesi (Faz 16-22
  SONRASI çok daha yetenekli hâle gelen HPy köprüsüne karşı) kapsamlı
  şekilde YENİDEN test edilirken, `dumps()`nin `int`/`list[int]`/
  `dict[str,int]` argümanları İçİn HER ZAMAN başarısız olduğu (`float`/
  `bool`/`str` İSE BAŞARILI olduğu) bulundu. Kök neden: `ctxTypeCheck`
  (`ctx_TypeCheck`, `HPy_TypeCheck`nin karşılığı) SADECE `.instance_`
  etiketli (kullanıcı-tanımlı `HPyType_FromSpec` örnekleri) nesneleri
  tanıyordu — `ujson_hpy`nin encoder'ı int TESPİTİ İçİn TAM OLARAK
  `HPy_TypeCheck(ctx, value, ctx->h_LongType)` KULLANDIĞINDAN (`§3.77`nin
  `ctxType`/`HPy_Type` İçİn ZATEN düzelttiği AMA `ctxTypeCheck`e HİÇ
  UYGULANMAMIŞ AYNI yerleşik-tip eşlemesi), bir `.long`-etiketli GERÇEK
  int HİÇBİR ZAMAN eşleşmiyordu — encoder "JSON serializable değil"
  İSTİSNASINA düşüyordu (list/dict İçİn de AYNI kök neden: HER ikisinin
  elemanları GEZİLİRKEN İçlerindeki int'ler AYNI bug'a çarpıyordu — konteynerlerin
  KENDİ tip-tespiti — `HPyList_Check`/`HPyDict_Check` — ZATEN doğruydu).
  Düzeltme: `ctxTypeCheck`, `ctxType`nin AYNI switch'ini (uzun/float/bool/
  str/tuple/list/bytes → KENDİ pinned tekiliyle KİMLİK karşılaştırması)
  PAYLAŞIR.
- **`ctx_Global_Store` (`HPyGlobal`) sızıntısı**: bir C eklentisinin KENDİ
  statik `HPyGlobal` değişkeninde (`static HPyGlobal g_x = {0};` GİBİ,
  Nox'un HİÇBİR ZAMAN görmediği bir bellek konumu) sakladığı DEĞER
  (`ujson_hpy`nin `module_exec`inin oluşturduğu `JSONDecodeError` istisna
  tekili GİBİ) `destroyContext`de HİÇ İZLENMİYOR/kapatılmıyordu — GERÇEK
  `hpy-ujson`ye karşı `hpy_open`+`hpy_close` çalıştırılırken `DebugAllocator`
  BUNU GERÇEK bir sızıntı OLARAK yakaladı. Düzeltme: `ctxGlobalStore`
  ARTIK dup'ladığı DEĞERİ `PrivateState`in YENİ `tracked_globals` haritasına
  da (adres → SON değer) KAYDEDER; `destroyContext` BUNU TÜKETİP kalan
  TÜM globalleri kapatır.

### Doğrulandı
- GERÇEK, kullanıcının `/Users/melihburakmemis/Documents/ujson-hpy`sindeki
  (önceden derlenmiş `ujson_hpy.hpy0.so`, Universal ABI) `dumps`/`loads`
  fonksiyonlarına karşı ELLE yazılmış bir Nox betiği: `dumps()` ARTIK
  int/float/bool/str/list[int]/dict[str,int] argümanlarının HEPSİ İçİn
  DOĞRU JSON metni ÜRETİYOR (`42`, `3.14`, `true`, `"hello"`, `[1,2,3]`,
  `{"a":1,"b":2}`), `loads()` HER dönüş tipi İçİn (int/float/bool/str/
  list, `hpy_getitem_int_on` İLE eleman-eleman DOĞRULANARAK) DOĞRU çalışıyor
  — VE `hpy_close(h)` SONRASI HİÇBİR sızıntı raporlanmıyor (`DebugAllocator`
  temiz).
- 2 YENİ internal Zig testi (`runtime/hpy_bridge/context.zig`): `ctxTypeCheck`nin
  yerleşik-tip tekilleriyle DOĞRU eşleştiğini (VE yanlış-tiplerle
  eşleşMEDİĞİNİ) kanıtlayan bir test; `ctxGlobalStore`nin İKİ ARDIŞIK
  yazımdan (üzerine-yazma) SONRA `destroyContext`in TEK, SON değeri
  double-free OLMADAN kapattığını kanıtlayan bir test.

## [1.66.0]

### Eklendi
- **Faz 22 — bare attribute-nesnesi + gerçek `slice` tipi + numpy-tarzı
  skaler-broadcast slice ataması (aHPy `external_nogil_targets` ile
  GERÇEK dünya doğrulaması)**: Faz 20'de "hibrit attribute+subscript
  nesnesi gerektiriyor, orantısız" diye ERTELENEN `external_nogil_targets`
  yeniden ele alındı — aHPy'nin GERÇEK Python kaynağı (`ahpy_setuptools_
  example.pyx:85-98`) okunarak ÖNCEKİ teşhisin YANLIŞ olduğu bulundu:
  `obj` SADECE attribute'lu (`amount`/`value`) basit bir nesne, `mapping`
  İSE SADECE sıralı (int-indeks + slice) bir nesne — hibrit bir şey HİÇ
  GEREKMİYOR. TEK gerçek engel: `mapping[1:2] = 4` (GERÇEK Python
  `list`inde GEÇERSİZ, ValueError verir) — kullanıcı BUNU numpy-tarzı bir
  SKALER-broadcast (aralıktaki HER elemana AYNI değeri yazma) OLARAK
  Nox'un `list[T]`ine GENELLEŞTİRİLMİŞ, bilinçli bir v1 uzantısı OLARAK
  istedi.
- **`h_SliceType` artık GERÇEKTEN çağrılabilir**: `Obj`de `h_SliceType:
  HPy = HPy_NULL` alanı VARDI ama `createContext` HİÇ ATAMIYORDU — GERÇEK
  aHPy kodunun `HPy_Call(ctx, ctx->h_SliceType, [a,b,c], 3, ...)` çağrısı
  HER ZAMAN "çağrılabilir değil" TypeError verirdi. Nox'un v1'i "slice"ı
  ZATEN 3 elemanlı bir `.tuple_` (start,stop,step) olarak temsil ettiğinden
  (`ctxSliceUnpack`nin ÖNCEDEN belgelenmiş tasarımı), YENİ `ctxSliceTypeNew`
  (`h_SliceType`nin `type_tp_new`i) SADECE 3 argümanı bu temsile paketler
  — YENİ bir `Obj` etiketi GEREKMEDİ.
- **`.list_`nin GetItem/SetItem'i artık slice-anahtarlı erişimi de
  destekliyor**: slice GET bir alt-liste KOPYASI döner; slice SET İKİ dal
  — sıralı bir değer (`list`/`tuple`) İSE GERÇEK Python semantiği (`step==1`
  aralığı büyütüp/küçültebilir, `step!=1` uzunluklar TAM eşit olmalı,
  aksi halde `ValueError`); SKALER bir değer İSE **YENİ, numpy-tarzı bir
  genelleme**: aralıktaki HER indekse AYNI değer yazılır (`arr[1:2]=4`nin
  numpy'daki broadcast davranışı).
- **YENİ Nox builtinleri**: `hpy_new_object_on(handle) -> ptr` (Faz 20'nin
  `createModuleObject`ini YENİDEN KULLANAN, boş/tipsiz bir attribute-nesnesi
  inşa eder), `hpy_getitem_int_on(handle, container, index) -> int`
  (`ctx_GetItem_i`i DOĞRUDAN çağırır — opak bir `.list_`/`.tuple_`
  tutamacının elemanlarını okur, ör. `hpy_call_obj_on`dan alınan bir
  dönüş tuple'ını doğrulamak İçİn).
- GERÇEK aHPy `external_nogil_targets`ına karşı ELLE doğrulandı:
  `hpy_new_object_on`+`hpy_setattr_int_on(amount=7)` + `mapping=[10,20]`
  İLE çağrılıp dönen 5 elemanlı tuple'ın İLK 4 elemanı (`nogil_stored_result`,
  `obj.value`, `mapping[0]`, `probe_calls`) `7`/`17`/`20`/`24` OLARAK
  (GERÇEK C-tarafı sayaç mantığıyla BİREBİR eşleşerek) doğrulandı —
  ÖNCEDEN TAMAMEN çağrılamayan bu fonksiyon ARTIK uçtan uca ÇALIŞIYOR.
- **YENİ, self-contained C test fonksiyonu** (`tests/compat/hpy_ext/
  noxtest.c`): `attr_and_seq_roundtrip` (aHPy'nin GERÇEK desenin KÜÇÜLTÜLMÜŞ
  bir kopyası — `HPyFunc_VARARGS`, attribute get/set + int-indeks get/set
  + slice get/set skaler-broadcast HEPSİNİ egzersiz eder, TEK bir int
  toplamı döner). YENİ golden test (`tests/compat/hpy_call_golden_test.
  zig`) + 6 YENİ dahili Zig testi (`runtime/hpy_bridge/context.zig`:
  `h_SliceType` çağrılabilirliği, slice GET, skaler-broadcast SET, sıralı-
  değer SET (büyüme/küçülme), step!=1 uzunluk-uyuşmazlığı ValueError'ı,
  bare-nesne attribute round-trip).

## [1.65.0]

### Eklendi
- **Faz 21 — modül-seviyesi tip inşası + GETSET + NOARGS tip metodları
  (aHPy `Box` ile GERÇEK dünya doğrulaması)**: Faz 20 sonrası kullanıcı
  aHPy'nin `ahpy_setuptools_example.hpy0.so`sunu 17 fonksiyonla DAHA GENİŞ
  test etti (hepsi doğru çalıştı) — sıradaki hedef, aHPy'nin `Box`
  (`HPyType_FromSpec` İLE tanımlı bir Cython `cdef class`ı) sınıfını
  Nox'tan İNŞA EDİP KULLANMAKTI. Araştırma ÜÇ GERÇEK boşluk buldu: (1)
  `constructInstance` `tp_new` KAYITLI OLMAYAN tipleri (Box'ın KENDİSİ
  GİBİ — Cython, GERÇEK HPy/CPython'ın "object.__new__" VARSAYILANINA
  GÜVENİR) TypeError İLE reddediyordu — YENİ `genericNew` (`ctxNew`in AYNI
  zeroed-buffer mantığı) `tp_new` EKSİKKEN düşülen bir varsayılan olarak
  eklendi. (2) `HPyDef_Kind_GetSet` (Box'ın `value` özelliği) TAMAMEN
  desteklenmiyordu — GERÇEK `cc`/`offsetof` İLE (`sizeof(HPyDef)=64`,
  `offsetof(HPyDef,getset)=8`, `sizeof(HPyGetSet)=56`) doğrulanan bir
  bayt-yeniden-yorumlama tekniğiyle (`slotOfLocal`nin AYNI ilkesi) YENİ
  `Obj.type_getsets`/`TypeGetSet` eklendi, `attrLookup`/`ctxSetAttr`
  GETSET getter/setter'larını (VARSA) ÖNCELİKLE ÇAĞIRIR hale getirildi
  (`instance_dict`e SESSİZCE genel bir girdi EKLEMEK YERİNE). (3)
  `TypeMethod`/`type_methods` SADECE `HPyFunc_O` metodları kaydediyordu —
  Box'ın `identity()`si (`HPyFunc_NOARGS`) HİÇ bulunamıyordu — `TypeMethod`
  HER İKİ imzayı da destekleyecek şekilde genelleştirildi (`bound_method_`
  VE `callDispatch` de AYNI şekilde).
- **YENİ Nox builtinleri**: `hpy_new_on(handle, class_name, args...) ->
  ptr` (bir MODÜL attribute'u OLAN tipi `ctx_GetAttr_s`+`ctx_Call` İLE
  İNŞA eder — `hpy_call_on`nin AYNI marshal zincirini paylaşır, YENİ,
  PAYLAŞILAN `genHpyMarshalTrailingArgs`e ÇIKARILDI), `hpy_getattr_int_on`/
  `hpy_setattr_int_on(handle, obj, attr_adı, [value]) -> int/None` (SABİT
  arity, GETSET/instance_dict'i şeffafça kullanır), `hpy_call_attr_on(handle,
  obj, attr_adı, args...) -> int` (bir opak örneğin BAĞLI METODUNU çağırır
  — `nox_hpy_args_begin_for_obj`in YENİ `target_obj` alanı İLE).
- GERÇEK aHPy `Box`ına karşı ELLE doğrulandı: `hpy_new_on(h, "Box", 5)` →
  `hpy_getattr_int_on(..., "value")` → `5`, `hpy_setattr_int_on(..., "value",
  42)` SONRASI `hpy_call_attr_on(..., "identity")` → `42` (GETSET setter'ın
  YAZDIĞI AYNI alanı `identity()`nin `HPyField_Load` İLE OKUDUĞUNU — İKİ
  AYRI mekanizmanın TUTARLI çalıştığını — KANITLAR).
- **YENİ, self-contained C test fixture'ı** (`tests/compat/hpy_ext/
  noxtest.c`): `Boxed` (aHPy'nin `Box`ının KÜÇÜLTÜLMÜŞ bir kopyası — `tp_new`
  YOK, `HPyDef_GETSET` (`"n"`), `HPyFunc_NOARGS` bir tip metodu (`double_n`),
  `tp_destroy`). YENİ golden testler (`tests/compat/hpy_call_golden_test.
  zig`, 4 yeni) — jenerik `tp_new` düşüşü, GETSET getter/setter round-trip,
  NOARGS bound-method çağrısı, `tp_destroy` tetiklemesi. `hpy_tier0_test.
  zig`nin `ctx_Call — tp_new'i olmayan bir tipte TypeError` testi, YENİ
  (doğru) davranışı (BAŞARILI jenerik inşa) yansıtacak şekilde güncellendi.

## [1.64.0]

### Eklendi
- **Faz 20 — HPy modül nesnesi + `HPy_mod_exec` desteği (aHPy
  entegrasyonu, GERÇEK dünya doğrulaması)**: kullanıcının KENDİ, GERÇEK
  aHPy toolchain'iyle derlenmiş `ahpy_setuptools_example.hpy0.so`sunu
  Nox'tan çağırmaya ÇALIŞMAK İKİ GERÇEK boşluk BULDU. **Boşluk 1** (bu
  sürümde de düzeltildi): `runtime/hpy_bridge/loader.zig` sadece
  `HPyFunc_O`/`HPyFunc_KEYWORDS` imzalarını taşıyordu — GERÇEK Cython-
  üretimi kod `HPyFunc_NOARGS`/`HPyFunc_VARARGS`i de kullanıyor. YENİ
  `findMethodNoArgs`/`findMethodVarargs` eklendi, `foreign_bridge.zig`nin
  `invokeHpyMethod`i (VE `nox_hpy_call`nin KENDİSİ) ARTIK KEYWORDS→
  VARARGS→O(n=1)→NOARGS(n=0) zincirini dener. **Boşluk 2 (BU sürümün ASIL
  konusu)**: `answer()` GİBİ argümansız bir fonksiyon BULUNUYOR AMA
  ÇAĞRILDIĞINDA istisna fırlatıyordu — GERÇEK Cython-üretimi kod, derleme-
  zamanı sabitlerini (`return 42` GİBİ) `HPy_mod_exec` slot'unda `self`
  (modülün KENDİ nesnesi) üzerinde `HPy_SetAttr_s` İLE YAZIYOR, `self`i
  SONRAKİ her fonksiyon çağrısında `HPy_GetAttr_s` İLE OKUYOR — Nox'un
  köprüsü İSE `ctx_Module_Create`/`HPy_mod_exec`i HİÇ ÇALIŞTIRMADIĞINDAN
  `self` HER ZAMAN `HPy_NULL` geçiyordu. YENİ `context.createModuleObject`
  (basit bir `.instance_` etiketli Obj — `ctxGetAttr`/`ctxSetAttr`nin
  ZATEN HERHANGİ bir `.instance_` nesnesi ÜZERİNDE çalışması SAYESİNDE
  YENİ bir attribute-depolama mekanizması İCAT ETMEYE GEREK KALMADI), YENİ
  `loader.findModExecSlot` (`HPySlot` bayt-yorumlama TEKNİĞİ, `ctxTypeFromSpec`nin
  İÇ `HPySlotLocal`ıyla AYNI ilke — bu SEFER `pub` OLARAK loader.zig'de).
  YENİ, PAYLAŞILAN `foreign_bridge.setupModuleObject`: modül nesnesini
  yaratır, `HPy_mod_exec` slot'u VARSA ÇALIŞTIRIR — `nox_hpy_open` (kalıcı
  tutamaç), `nox_hpy_call`/`nox_hpy_call_str` (Faz 14/15'in ESKİ tek-
  seferlik fonksiyonları), VE `invokeHpyMethod` (Faz 16-19'un persistent-
  handle çağrı ailesinin TAMAMI) ARTIK HEPSİ `self`i GERÇEK modül nesnesi
  OLARAK geçirir (`HPy_NULL` YERİNE). GERÇEK aHPy `.hpy0.so`sına karşı
  ELLE doğrulandı: `hpy_call_on(h, "answer")` → `42`, `hpy_call_on(h,
  "external_add", 20, 22)` → `42`. **Yan-bulgu (aynı doğrulama SIRASINDA
  bulunan, AYRI bir GERÇEK boşluk)**: `HPy_mod_exec`in KENDİSİ BİR `HPyType_
  FromSpec` tipini (Cython'ın bir `cdef class`ı) inşa edip O TİP nesnesinin
  KENDİSİNE (`.instance_` DEĞİL, `.type_`) `HPy_SetAttr_s` İLE attribute
  yazdığında `ctxSetAttr` BUNU reddediyordu (SADECE `.instance_` DESTEKLİYORDU)
  — bu, HER Cython-derlenmiş sınıfın `mod_exec` İçİnde tetiklediği, GERÇEK
  bir sınırdı (Box GİBİ HERHANGİ bir sınıf İÇEREN bir modülün TÜM `mod_exec`i
  BAŞARISIZ oluyordu). YENİ `Obj.type_dict` (`instance_dict`in AYNI `DictEntry`
  deseni, `.type_` etiketli nesneler İçİn) — `ctxSetAttr`/`attrLookup`
  ARTIK `.type_` nesnelerini de destekler.
- **YENİ, self-contained C test fixture'ı** (`tests/compat/hpy_ext/
  noxtest.c`): `HPyDef_SLOT(module_exec_marker, HPy_mod_exec)` (modülün
  KENDİSİNE `"faz20_marker"` = `99` YAZAN, GERÇEK aHPy'nin KENDİ desenini
  taklit eden bir `HPyFunc_INQUIRY`) + `HPyDef_METH(get_faz20_marker,
  ..., HPyFunc_NOARGS)` (`self` üzerinden OKUYAN). YENİ golden testler
  (`tests/compat/hpy_call_golden_test.zig`): `hpy_call_on(h, "get_faz20_marker")`
  → `99` (kalıcı-tutamaç yolu) VE `hpy_call(..., "get_faz20_marker", 0)`
  → `99` (ESKİ tek-seferlik yol) — Faz 14-19'un TÜM MEVCUT hpy golden
  testleri DEĞİŞMEDEN geçmeye DEVAM EDİYOR.

## [1.63.0]

### Eklendi
- **Faz 19 — opak HPy nesne tutamaçları: `HPyType_FromSpec` ile
  tanımlanan özel tiplerin GEÇİŞİ (aHPy entegrasyonu, 4/5)**: aHPy
  entegrasyonu listesinin SON KALAN maddesi — `runtime/hpy_bridge/
  loader.zig`nin bir C eklentisinin KENDİ `HPyType_FromSpec` İLE
  tanımladığı özel tipleri (`tests/compat/hpy_ext/noxtest.c`nin `Counter`
  örneği GİBİ) HİÇ desteklememesi. Araştırma, `runtime/hpy_bridge/
  context.zig`nin (Nox'un KENDİ, GERÇEK HPyContext implementasyonu)
  `ctx_Type_FromSpec`/`ctx_New`/`tp_destroy` GİBİ mekanizmaları ZATEN TAM
  desteklediğini, GERÇEK boşluğun SADECE loader/foreign_bridge'in BUNU
  bir Nox programına BAĞLAYAMAMASINDA olduğunu buldu — bir C eklentisi
  bir özel-tip örneğini DÖNDÜRDÜĞÜNDE, ÇAĞIRAN taraf (Nox) bu tutamacı
  TAMAMEN OPAK bir değer olarak taşıyabiliyor (tip-spesifik davranışın
  TAMAMI C eklentisinin KENDİ kodunda yaşıyor). YENİ builtinler: `hpy_call_
  obj_on(handle: ptr, func_name: str, args...) -> ptr` (bir opak nesne
  tutamacı döner — Faz 17'nin AYNI çoklu-argüman marshalling'ini
  paylaşır), `hpy_close_obj(handle: ptr, obj: ptr) -> None` (tutamacı
  serbest bırakır, C eklentisinin KENDİ `tp_destroy`sunu tetikleyebilir).
  `isHpyMarshalableArgType`ye `ptr` eklendi — TÜM 5 çağrı varyantı ARTIK
  DAHA ÖNCE `hpy_call_obj_on`dan alınmış bir tutamacı argüman olarak
  KABUL EDER (`make_counter`+`get_counter_x` deseninin TAM round-trip'i).
  **Tasarım — codegen sınırlamasını AST-rewrite İLE çözme**: `ptr`
  codegen'de `int` İLE BİREBİR AYNI temsile sahip olduğundan (ayırt
  edici bir `HeapKind` YOK, YENİ bir tane EKLEMEK düzinelerce switch'i
  etkilerdi), checker bir argümanın STATİK tipi `.ptr` İSE O argümanı
  (doğrulama TAMAMLANDIKTAN SONRA) gizli bir `__nox_hpy_obj_arg` işaretleyici
  çağrıya SARAR (`__nox_reflect_*`nin AYNI deseni) — codegen'in per-
  argüman döngüsü bu AST ŞEKLİNİ (yapısal olarak) tanıyıp `nox_hpy_args_
  add_handle`e yönlendirir, int/float/bool/str/list/dict/class'ın normal
  dispatch'ine HİÇ girmeden. Runtime tarafında `MarshalCtx.args`nin eleman
  tipi `ArgEntry{h, owned}`e genişledi — bir opak tutamaç argümanı
  (`owned=false`) çağrı SONRASI OTOMATİK kapatılmaz (Nox'un ZATEN sahip
  olduğu, ödünç verilen bir referanstır), skaler/list/dict/class-dict
  argümanları (`owned=true`) DEĞİŞMEDEN otomatik kapatılmaya devam eder.
  2 yeni golden test (`tests/compat/hpy_call_golden_test.zig`, MEVCUT
  `Counter` C tipini kullanır) — round-trip VE `tp_destroy`nin GERÇEKTEN
  tetiklendiği kanıtlandı. `HPyType_FromSpec`in kendisinin (context.zig)
  tip nesnesini KASITLI olarak KALICI/hiç-kapatılmayan bırakması (`Counter_
  type`in C eklentisinin KENDİ `static` global'inde sonsuza dek önbelleğe
  alınması) bilinen, `tests/compat/hpy_tier0_test.zig`nin ZATEN kabul
  ettiği bir v1 ödünleşimi — bu 2 yeni test BUNU (page_allocator YERİNE
  GERÇEK bir derlenmiş ikili+RuntimeState allocator'ı kullandıklarından)
  `expectGoldenAllowTypeLeak` (YENİ, stderr'i kontrol etmeyen bir
  `expectGolden` varyantı) İLE doğru şekilde karşılıyor.

## [1.62.0]

### Eklendi
- **Faz 18 — HPy köprüsünü Nox'un istisna mekanizmasına entegre etme
  (aHPy entegrasyonu, 3/5)**: `hpy_call`/`hpy_call_str`/`hpy_open`/
  `hpy_call_on`/`hpy_call_str_on`/`hpy_call_float_on`/`hpy_call_bool_on`nin
  TÜM hata durumları (dosya/sembol/metod bulunamadı, VEYA çağrılan HPy C
  fonksiyonunun KENDİSİ bir istisna fırlattı — `ctx_Err_Occurred`)
  SESSİZCE `0`/boş `str` DÖNME YERİNE ARTIK GERÇEK bir `HPyError`
  (YENİ, `stdlib/nox/core.nox`ye eklenen bir `Exception` alt sınıfı)
  `raise` eder — `try`/`except HPyError as e: print(e.message)` İLE
  GERÇEKTEN yakalanabilir. Tasarım: `runtime/foreign_bridge.zig`ye YENİ,
  threadlocal bir "son HPy hatası" yuvası (`g_hpy_last_error`/`setHpyError`) —
  HER `hpy_*` fonksiyonunun HER hata dalı (yükleme/context-oluşturma/
  metod-bulunamadı/HPy istisnası) BU yuvaya bir hata METNİ YAZAR (dönüş
  DEĞERİ DEĞİŞMEZ — `0`/boş/null DEVAM eder); YENİ `nox_hpy_take_error`
  BU yuvayı GERÇEK bir Nox `str`ine çevirip TÜKETİR. Codegen (`compiler/
  codegen_qbe/calls.zig`nin YENİ `emitHpyErrorCheckOrRaise`i, `genParseOrRaise`in
  AYNI err/ok-etiket şablonu) HER `hpy_*` çağrısından HEMEN SONRA BU
  yuvayı kontrol edip (VARSA) bir `HPyError` inşa edip `$nox_raise` +
  `emitExceptionCheck` çağırır. `compiler/codegen_qbe/exceptions.zig`nin
  `computeMustNotRaise`sinin "asla raise etmez" whitelist'İNDEN `hpy_call`/
  `hpy_call_str` ÇIKARILDI (ARTIK GERÇEKTEN raise EDEBİLİYORLAR —
  `wasm_call` BU FAZIN kapsamı DIŞINDA, DEĞİŞMEDİ). `HPyError`nin
  `stdlib/nox/core.nox`ye EKLENMESİ TÜM programların class_id
  numaralandırmasını KAYDIRDIĞINDAN (whole-program AST birleştirmesi,
  §3.99'un BİLİNÇLİ tasarımı), `tests/golden/ir_snapshots/`nin TÜMÜ
  (237 fixture) BEKLENDİĞİ GİBİ yeniden ÜRETİLDİ — DAVRANIŞ SIFIR
  değişmedi, SADECE sabit class-id DEĞERLERİ kaydı. 3 yeni golden test
  (`tests/compat/hpy_call_golden_test.zig`) — kötü yol, bulunamayan
  fonksiyon adı, VE `raise_value_error` (MEVCUT, `HPyErr_SetString`
  çağıran C test fonksiyonu) ÜZERİNDEN `ctx_Err_Occurred` yolunun
  GERÇEKTEN egzersiz edildiğini kanıtlıyor — HEPSİ `try`/`except HPyError:`
  İLE yakalanıyor. `hpy_call_golden_test.zig`nin KENDİ `compileAndRun`ı
  (ÖNCEDEN `resolveImports` çağırmıyordu — 9 MEVCUT testin HİÇBİRİ
  core.nox'un bir sınıfına İHTİYAÇ DUYMADIĞINDAN) `resolveImports`
  çağıracak şekilde GÜNCELLENDİ (`codegen_golden_test.zig`nin
  `IndexError` İçİn ZATEN kullandığı AYNI desen).

## [1.61.0]

### Eklendi
- **Faz 17 — kalıcı tutamaçlı HPy çağrılarına çoklu-argüman + list/dict/
  class marshalling (aHPy entegrasyonu, 2/5)**: Faz 16'nın `hpy_call_on`/
  `hpy_call_str_on`sının SADECE TEK bir `int`/`str` argüman kabul etmesi
  VE list/dict/class değer marshalling'inin hiç olmaması — orijinal 5
  maddelik listenin 2. VE 3. maddesi — BİRLİKTE çözüldü. `hpy_call_on`/
  `hpy_call_str_on` ARTIK `handle`/`func_name`den SONRA SIFIR VEYA DAHA
  FAZLA, HETEROJEN tipli (int/float/bool/str/list[T]/dict[K,V]/class —
  HEPSİ skaler eleman/alan tipleriyle) trailing argüman kabul eder; YENİ
  `hpy_call_float_on`/`hpy_call_bool_on` (float/bool dönüşlü kardeşler)
  eklendi. Tasarım: `runtime/foreign_bridge.zig`ye YENİ bir "builder"
  API'si — `nox_hpy_args_begin` bir `MarshalCtx` yaratır, codegen HER
  argümanın STATİK tipine göre tip-başına bir `nox_hpy_args_add_*`
  (int/float/bool/str/list[T]/dict[K,V]) VEYA (class İçİn) `nox_hpy_
  class_arg_begin/set_*/end` üçlüsünü çağırır, SONUNDA dönüş-tipine özel
  bir `nox_hpy_call_{int,float,bool,str}_finish` GERÇEK çağrıyı yapıp
  `MarshalCtx`i serbest bırakır. Bir `class` örneği yalnızca TÜM alanları
  skalerse marshalling'e KATILIR VE yalnızca alan-adı→değer bir HPy
  `dict`i OLARAK ("surrogate" temsil — `HPyType_FromSpec` HENÜZ yok, Faz
  19'un işi) geçirilebilir; BU SADECE GİDEN yönde çalışır (HPy'den GERİ
  bir `class`a dönüştürme bu fazın kapsamı DIŞINDA — kullanıcıya SORULUP
  onaylandı). Dönüş tipi bu fazda yalnızca int/float/bool/str KALIR
  (geriye-dönük tip çıkarımı olmadığından list/dict/class dönüş tipi
  AYRI/gelecekteki bir iş). GERİYE DÖNÜK uyumluluk: `invokeHpyMethod`
  ÖNCE `HPyFunc_KEYWORDS` (N-argümanlı YENİ yol) dener, BULUNAMAZSA VE
  TAM 1 argüman VARSA `HPyFunc_O` (Faz 14-16'nın ESKİ tek-argümanlı test
  fonksiyonları — `get_call_count`/`add_one` — İçİn) imzasına düşer; BU
  düzeltme olmadan Faz 16'nın KENDİ persistence testi (`get_call_count`,
  `HPyFunc_O` imzalı) SESSİZCE `0` dönmeye başlıyordu — geliştirme
  sırasında YAKALANIP DÜZELTİLDİ. `tests/compat/hpy_ext/noxtest.c`ye 5
  yeni `HPyFunc_KEYWORDS` test fonksiyonu (`sum_two_ints`, `concat_three_
  strs`, `sum_list_of_ints`, `dict_value_sum`, `class_field_sum`) VE
  `tests/compat/hpy_call_golden_test.zig`ye 5 yeni golden test eklendi —
  hepsi GERÇEKTEN derlenip çalıştırılan `.nox` programlarıyla, list[int]/
  dict[str,int]/class-as-dict marshalling'inin HER BİRİNİN GERÇEK bir HPy
  eklentisine karşı doğru çalıştığını kanıtlıyor. 2 yeni negatif codegen
  fixture'ı (`hpy_call_on_nested_list_arg_rejected.nox`, `hpy_call_on_
  class_with_nested_field_rejected.nox`) İÇ İÇE konteynerlerin (`list[
  list[int]]`, nested-alanlı bir sınıf) `TypeMismatch` İLE reddedildiğini
  doğruluyor.

## [1.60.0]

### Eklendi
- **Faz 16 — `hpy_open`/`hpy_call_on`/`hpy_call_str_on`/`hpy_close`:
  kalıcı HPy modül+context tutamacı (aHPy entegrasyonu, 1/5)**: kullanıcının
  kendi `aHPy` projesini (Cython'dan CPython-bağımsız HPy Universal ABI
  C'ye derleyen bir backend) Nox'a entegre etme planının İLK maddesi.
  Araştırma sırasında, `runtime/hpy_bridge/`nin (180/180 `ctx_*` alanı
  dolu) GERÇEK `.nox` programlarına HİÇ bağlanmadığı ÖNCÜLÜ YANLIŞ
  bulundu — `hpy_call`/`hpy_call_str` (Faz 14/15) ZATEN çalışıyordu.
  GERÇEK kalan boşluk, `runtime/foreign_bridge.zig`nin KENDİ belgelediği
  "v0.1, bilinçli olarak dar" sınırlarından BİRİYDİ: her `hpy_call` HER
  ÇAĞRIDA modülü baştan `dlopen` edip yeni bir `HPyContext` yaratıp HEMEN
  kapatıyordu — kalıcılık yoktu. Bu sürüm 4 yeni yerleşik ekliyor
  (mevcut `hpy_call`/`hpy_call_str` DEĞİŞMEDEN, geriye dönük uyumlu
  kalıyor): `hpy_open(path: str, ext_name: str) -> ptr` modülü/context'i
  BİR KEZ açıp ikisini de heap'te bir `PersistentHpyHandle` struct'ında
  saklayıp opak bir `ptr` (mevcut, `extern def`in de kullandığı tip)
  döner; `hpy_call_on(handle, func_name, arg: int) -> int` VE
  `hpy_call_str_on(handle, func_name, arg: str) -> str` AYNI, ZATEN AÇIK
  modül/context'i (SIFIR yeniden-yükleme) yeniden kullanır; `hpy_close(handle)`
  context'i yok edip kütüphaneyi kapatıp handle'ı serbest bırakır.
  Kalıcılığın GERÇEKTEN çalıştığı (silinen bir false-positive DEĞİL),
  `tests/compat/hpy_ext/noxtest.c`ye eklenen YENİ, stateful bir test
  fonksiyonuyla (`get_call_count` — her çağrıda artan bir `static long`
  C globali döndürür) KANITLANDI: aynı handle'la 3 ardışık `hpy_call_on`
  çağrısı `1`/`2`/`3` bastı (silent reload olsaydı `1`/`1`/`1` olurdu,
  çünkü dlopen paylaşımlı kütüphaneyi yeniden eşleyip `static` globali
  sıfırlardı). `hpy_open`/`hpy_call_on`nin `path`/`func_name` argümanları
  `hpy_call`İLE AYNI Güvenlik bulgusu H-1 kısıtına tabi (sadece string
  LİTERALİ — çalışma-zamanı hesaplı bir yoldan/adından keyfi native kod
  yüklenmesini/çağrılmasını önlemek İçİn), 2 yeni negatif codegen
  fixture'ıyla doğrulandı.



### Eklendi
- **HH.10 — post-spawn checker'ına dönüş-alias etkileri (return-alias
  effects)**: harici bir inceleme HH.8/HH.9'un KENDİ, bilinçli olarak
  ertelenmiş "Kapsam DIŞI" maddesini (fonksiyon-çağrısı dönüşü üzerinden
  aliasing) önerdi. `def identity(xs: list[int]) -> list[int]: return xs`
  gibi bir fonksiyonun dönüş değeri, kendi parametresiyle GERÇEKTEN alias'tır
  — `ys = identity(xs); t = spawn worker(xs); ys[0] = 42` v1.58.0'da
  sessizce derleniyordu. Düzeltme (`compiler/typecheck/checker.zig`):
  YENİ bir whole-program pre-pass (`computeReturnAliasEffects`,
  `computeMutatesGraph`ile AYNI aşamada) her üst-düzey, generic-olmayan
  fonksiyon için tek-geçişli bir `ReturnAliasEffect` (`fresh` / bir SET
  parametre indeksiyle `alias_params` / `unknown`) hesaplıyor — fonksiyonun
  KENDİ `return` ifadelerini (if/while/for'a özyineleyerek, ama BAŞKA bir
  fonksiyona transitif ÇÖZÜMLEME yapmadan — bu SINIRLAMA özyineleme/karşılıklı
  özyineleme risk sınıfını tamamen ortadan kaldırıyor) tarayıp: bir parametreyi
  DOĞRUDAN döndüren yollar o parametrenin indeksini `alias_params` kümesine
  ekliyor (`if flag: return a else: return b` gibi İKİ farklı parametre
  union'lanabiliyor — `choose(a,b,flag)` örneği), literal/sınıf-kurucusu
  dönüşleri katkı SAĞLAMIYOR (kesin fresh), `try`/`with` içeren VEYA başka
  bir fonksiyon çağıran dönüşler `unknown`a düşüyor (konservatif, transitif
  zincirler v1'de KAPSAM DIŞI). `updatePointsToForTarget`'ın `.call` dalı
  bu etkiyi tüketiyor: `.fresh`/bulunamayan-callee MEVCUT "taze kaynak-
  kimliği" davranışını KORUYOR (sınıf kurucuları/extern/generic/metodlar
  değişmedi), `.alias_params` ilgili argümanları points_to üzerinden çözüp
  hedefe UNION'LUYOR, `.unknown` HİÇBİR points_to girdisi eklemiyor (HH.9-
  öncesi davranışla BİREBİR AYNI — SIFIR yeni false-positive riski). 4 yeni
  golden fixture eklendi (identity repro'su + choose union + fresh
  regresyon-yok + transitif-unknown regresyon-yok); MEVCUT TÜM HH.2-HH.9
  fixture'ları DEĞİŞMEDEN geçiyor. İncelemenin AYRICA öne sürdüğü "döngü-
  içi tekrar-tahsis hassasiyeti" (allocation-site vs allocation-instance)
  EL İLE incelendi — HH.7'nin ZATEN belgelenmiş "recurrent lock" ödünleşiminin
  farklı bir ifadesi olduğu, kilidin SADECE AYNI statik deyime sızdığı
  (bağımsız deyimlere SIZMADIĞI) doğrulandı — AYRI bir düzeltme GEREKMEDİ.

## [1.58.0]

### Düzeltildi
- **HH.9 — v1.57.0'ın (HH.8) alias-takibindeki İKİ boşluk düzeltildi**:
  harici bir inceleme, HH.8'in ANA yön değişikliğini (isim yerine soyut
  kaynak kimliği) DOĞRU BULDU AMA UYGULAMADA İKİ AYRI, GERÇEK boşluk
  TESPİT ETTİ — HER İKİSİ de GERÇEK repro'larla DOĞRULANDI. **Boşluk 1
  (YENİ false-negative)**: `points_to` güncellemesi SADECE `.var_decl`de
  yapılıyordu, DÜZ bir yeniden-atama (`ys = xs`, `.assign`) HİÇ
  İŞLENMİYORDU — `ys: list[int] = [7,8,9]; ys = xs; t = spawn worker(xs);
  ys[0] = 42; await t` v1.57.0'da SESSİZCE derleniyordu. **Boşluk 2
  (BENİM KENDİ hatam — YENİ false-positive)**: `.list_lit`/`.dict_lit`
  İçİn kaynak-kimliği `elems.ptr`/`pairs.ptr`den türetiliyordu — Zig'in
  allocator'ı sıfır-uzunluklu dilimler İçİn (boş `[]`/`{}` literalleri)
  AYNI sentinel adresi döndürebiliyor, bu YÜZDEN İKİ TAMAMEN BAĞIMSIZ boş
  liste ÇAKIŞABİLİYORDU (`a: list[int] = []; b: list[int] = []; spawn
  worker(a); b.append(1)` YANLIŞLIKLA reddediliyordu). Düzeltme
  (`compiler/typecheck/checker.zig`): kaynak-kimliği ARTIK RHS ifadesinin
  İÇİNE BAKMAK YERİNE DEYİMİN (`var_decl`/`assign`) KENDİ, stabil AST-
  adresinden (`@intFromPtr(&stmts[i])`, GG.15/HH.5-8'in AYNI "AST-düğüm
  pointer'ı = benzersiz kimlik" deseni) türetiliyor — HER deyim, İÇERİĞİ
  BOŞ olsa BİLE KENDİ benzersiz konumuna sahip olduğundan Boşluk 2 YAPISAL
  olarak KAPANIYOR; VE points_to güncelleme mantığı YENİ, PAYLAŞILAN bir
  `updatePointsToForTarget` yardımcısına ÇIKARILIP HEM `.var_decl` HEM
  (YENİ) `.assign`(identifier-hedefli) TARAFINDAN çağrılabildiğinden
  Boşluk 1 de KAPANIYOR — TEK bir tasarım değişikliği İKİ boşluğu da
  kapattı. 4 yeni golden fixture eklendi (yeniden-atama repro'su +
  bağımsız-boş-liste + bağımsız-boş-dict + alias-sonrası-yeniden-atama
  regresyon-yok); MEVCUT TÜM HH.2/HH.5/HH.6/HH.7/HH.8 fixture'ları
  DEĞİŞMEDEN geçiyor. Kırmızı-takım kanıtı: HER İKİ düzeltme AYRI AYRI
  GEÇİCİ olarak geri alınıp İLGİLİ repro'nun TEKRAR YANLIŞ davrandığı,
  SONRA GERİ eklenip TEKRAR DOĞRU davrandığı doğrulandı. İncelemenin
  ÜÇÜNCÜ notu (fonksiyon-çağrısı dönüşü üzerinden aliasing, `ys =
  identity(xs)`) HH.8'in KENDİ, önceden yazılmış "Kapsam DIŞI" bölümünde
  ZATEN belgeliydi — YENİ bir sürpriz değil, BİLİNÇLİ bir v1 sınırı
  olarak KALIYOR. `v1.57.0`nin KENDİ CHANGELOG/spec girişi TARİHSEL bir
  kayıt olarak DEĞİŞTİRİLMEDİ.

## [1.57.0]

### Düzeltildi
- **HH.8 — v1.56.0'ın (HH.7) post-spawn checker'ında GERÇEK bir dördüncü
  false-negative düzeltildi**: harici bir inceleme, checker'ın paylaşılan
  kaynağı DEĞİŞKEN İSMİYLE takip ettiğini, `ys: list[int] = xs` Nox'ta
  GERÇEK bir referans/alias oluşturuyorsa `ys` ÜZERİNDEN yapılan bir
  mutasyonun `xs`i spawn'a paylaşan checker'ı atlatabileceğini GÖSTERDİ.
  İncelemenin KENDİ örneği (`.append()`in bir realloc'ta aliasing'i
  kırdığını GÖSTEREN bir senaryo) yanlış çıktı, ama SAF indeks-ataması
  (realloc gerektirmeyen mutasyon) İLE aliasing GERÇEKTEN doğrulandı
  (`xs[0]=100` sonrası `ys[0]` de 100 okuyor) — VE bu DAR AMA GERÇEK
  aliasing'le BİRLEŞTİRİLEN bir repro (`ys = xs; t = spawn worker(xs);
  ys[0] = 42; await t`) v1.56.0'da SESSİZCE derleniyordu. Düzeltme
  (`compiler/typecheck/checker.zig`): `SpawnFlowState`ye YENİ bir
  `points_to: StringHashMapUnmanaged([]const usize)` alanı eklendi —
  isim → o ismin referans verdiği soyut kaynak-kimlik(ler)i (list/dict/class
  literalleri/sınıf-kurucuları İçİn AST-düğüm pointer'ı, `ys = xs` GİBİ
  ÇIPLAK isim-den-isme atamalar İçİn KAYNAK ismin AYNI kimlik-kümesini
  KOPYALAYAN bir alias). `resource_owners`/`locked_resources` ARTIK İSİMLE
  DEĞİL bu soyut kaynak-kimliğiyle keyleniyor — spawn-tespiti/mutasyon-
  kontrolü/`await`/döngü-kilidi mekanizmalarının HEPSİ artık HANGİ İSİM
  kullanılırsa kullanılsın AYNI kaynağa çözülüyor. `points_to`,
  `resource_owners`/`task_spawn_ids`İLE AYNI şekle sahip olduğundan MEVCUT
  `mergeUsizeListMap` branch/loop birleştirmesini HİÇBİR DEĞİŞİKLİK
  GEREKMEDEN kapsıyor. Fonksiyon-çağrısı dönüşü/attribute-erişimi ÜZERİNDEN
  aliasing (`ys = f(xs)`) BİLİNÇLİ olarak kapsam dışı bırakıldı (SADECE
  ÇIPLAK isim-den-isme atama kapsanıyor — dilde `&`/pointer sözdizimi
  olmadığından bu aliasing'in TEK gerçek kaynağı). 4 yeni golden fixture
  eklendi (ana repro + ters yön + sınıf-attribute-alias + bağımsız-listeler
  regresyon-yok kontrolü); MEVCUT TÜM HH.2/HH.5/HH.6/HH.7 fixture'ları
  DEĞİŞMEDEN geçiyor. Kırmızı-takım kanıtı: `isResourceOwned`i GEÇİCİ
  olarak devre dışı bırakıp repro'nun TEKRAR sessizce derlendiği, SONRA
  geri eklenip TEKRAR yakalandığı doğrulandı. `v1.56.0`nin KENDİ
  CHANGELOG/spec girişi TARİHSEL bir kayıt olarak DEĞİŞTİRİLMEDİ.

## [1.56.0]

### Düzeltildi
- **HH.7 — v1.55.0'ın (HH.6) post-spawn checker'ında GERÇEK bir üçüncü
  false-negative düzeltildi**: harici bir inceleme, bir `spawn` çağrısının
  spawn-ID'sinin (HER `spawn` çağrısının KENDİ AST-düğüm pointer'ı) döngü
  fixpoint'inin HER iterasyonunda AYNI KALDIĞINI, bu YÜZDEN bir döngünün
  gerçekte BİRDEN FAZLA AYRI runtime Task ürettiği HALLERDE bunun TEK bir
  owner olarak dedup edildiğini GÖSTERDİ. Somut, GERÇEKTEN DERLENEN repro
  (v1.55.0'a karşı doğrulandı, EL İLE fixpoint mekaniği de İZLENEREK):
  ```nox
  while i < 2:
      t: Task[None] = spawn worker(xs)
      i = i + 1
  await t          # SADECE SON iterasyonun task'ını joinler
  xs.append(42)    # v1.55.0: SESSİZCE derleniyordu
  ```
  Döngü SONRASI TEK bir `await t` (`t` SADECE SON iterasyonun task'ını
  TUTAR) DAHA ÖNCEKİ iterasyonların (HİÇBİR ZAMAN await edilmemiş)
  task'larını joinlemiyordu. KONTROL testi (HER iterasyon KENDİ task'ını
  döngü İÇİNDE join ediyor) HÂLÂ DOĞRU çalışıyordu — mekanizma GENEL
  olarak SAĞLAMDI, SADECE "döngü sonrası tek bir await, HER iterasyonu
  joinler" varsayımı YANLIŞTI. Düzeltme (`compiler/typecheck/checker.zig`):
  incelemenin ÖNERDİĞİ TAM zero/one/many cardinality lattice'i YERİNE
  (incelemenin KENDİSİ de "İLK implementasyon İçİn DAHA GÜVENLİ" olarak
  BASİT modeli işaret etti), DAHA BASİT VE AYNI DERECEDE SAĞLAM bir kural:
  bir döngünün fixpoint'i YAKINSADIKTAN SONRA, döngüye GİRİŞTEKİ duruma
  GÖRE YENİ olan (döngünün KENDİ gövdesinde ÜRETİLEN) VE hâlâ `resource_owners`de
  KALAN (yani her iterasyonda KENDİ içinde joinlenmediği KANITLANAN) HER
  isim, `SpawnFlowState`nin YENİ `locked_resources` kümesine eklenerek
  KALICI olarak kilitleniyor — bu isimler ARTIK HİÇBİR SONRAKİ `await` İLE
  temizlenemiyor (fire-and-forget'in AYNI "sonsuza kadar uçuşta" disipliniyle
  tutarlı). Güvenli desen (spawn+await AYNI iterasyon İçİnde eşleşiyor)
  İçİn fixpoint yakınsadığında `resource_owners` ZATEN boş olduğundan,
  hiçbir şey yanlışlıkla kilitlenmiyor. 4 yeni golden fixture eklendi (ana
  repro + aynı-iterasyon-join negatifi + döngü-içi-koşullu-await + `for`
  döngüsü varyantı); MEVCUT TÜM HH.2/HH.5/HH.6 fixture'ları DEĞİŞMEDEN
  geçiyor. `v1.55.0`nin KENDİ CHANGELOG/spec girişi TARİHSEL bir kayıt
  olarak DEĞİŞTİRİLMEDİ — düzeltme dürüstçe burada belgeleniyor.

## [1.55.0]

### Düzeltildi
- **HH.6 — v1.54.0'ın (HH.5) post-spawn checker'ında GERÇEK bir ikinci
  false-negative düzeltildi**: harici bir inceleme, `SpawnFlowState`nin
  HER kaynağı SADECE bir BOOLEAN ("uçuşta mı DEĞİL Mİ") olarak takip
  ettiğini, KAÇ AYRI task'ın O kaynağı paylaştığını (multiplicity) HİÇ
  BİLMEDİĞİNİ GÖSTERDİ. Somut, GERÇEKTEN DERLENEN repro (v1.54.0'a karşı
  doğrulandı):
  ```nox
  t1: Task[None] = spawn worker(xs)
  t2: Task[None] = spawn worker(xs)
  await t1
  xs.append(42)   # v1.54.0: SESSİZCE derleniyordu — t2 HÂLÂ xs'i OKUYOR OLABİLİR
  await t2
  ```
  `await t1`, `xs`i TAMAMEN "temiz" sayıyordu — `t2` HÂLÂ ÇALIŞIYOR olsa
  BİLE. Düzeltme (`compiler/typecheck/checker.zig`): `SpawnFlowState`nin
  HER İKİ alanı da ARTIK "isim → BOOLEAN" YERİNE "isim → HÂLÂ O kaynağı
  paylaşan spawn-site KİMLİK KÜMESİ" taşıyor (`resource_owners`/`task_spawn_ids`,
  İKİSİ de `StringHashMapUnmanaged([]const usize)`, TEK PAYLAŞILAN
  `mergeUsizeListMap` yardımcısıyla klonlanıp birleştiriliyor). HER `spawn`
  çağrısı KENDİ AST-düğüm pointer'ını (`@intFromPtr(...)`, GG.15-18/HH.3'ün
  ZATEN kullandığı "AST-pointer = benzersiz kimlik" deseni) spawn-ID olarak
  taşıyor — `await t1` ARTIK SADECE `t1`in KENDİ spawn-ID'sini `resource_owners["xs"]`
  listesinden ÇIKARIYOR, `t2`nin spawn-ID'si KALIYOR, `resource_owners["xs"]`
  HÂLÂ NON-EMPTY olduğundan `xs.append(42)` DOĞRU şekilde REDDEDİLİYOR.
  Fixpoint cap'i (`MAX_LOOP_FIXPOINT_ITERATIONS=64`) İçİn de savunma-derinliği
  eklendi: cap GERÇEKTEN aşılırsa (GERÇEKÇİ HİÇBİR fonksiyon YAKLAŞMAZ)
  `forceConservativeState` TÜM bilinen paylaşılabilir isimleri SENTİNEL
  bir spawn-ID İLE "sonsuza kadar uçuşta" işaretleyerek GÜVENLİ tarafta
  kalıyor (incelemenin önerisi). 3 yeni golden fixture eklendi (çoklu-
  owner repro + her-ikisi-de-await negatifi + fire-and-forget+isimli-karışık);
  MEVCUT TÜM HH.2/HH.5 fixture'ları (branch-leak DAHİL) DEĞİŞMEDEN geçiyor.
  `v1.54.0`nin KENDİ CHANGELOG/spec girişi TARİHSEL bir kayıt olarak
  DEĞİŞTİRİLMEDİ — düzeltme dürüstçe burada belgeleniyor.

## [1.54.0]

### Düzeltildi
- **HH.5 — v1.51.0'ın (HH.2) post-spawn checker'ında GERÇEK bir false-
  negative düzeltildi**: harici bir inceleme, `checkNoPostSpawnCallerMutation`nin
  `if`/`elif`/`else` dallarına AYNI (TEK, paylaşılan) `shared_in_flight`/
  `task_to_shared` durumunu SIRAYLA (`then`→`elif`→`else`) geçirdiğini,
  bu YÜZDEN bir daldaki `await`in KARDEŞ (karşılıklı-dışlayan) bir dalın
  mutasyon kontrolünü YANLIŞLIKLA "temizleyebildiğini" GÖSTERDİ. Somut,
  GERÇEKTEN DERLENEN repro (v1.53.0'a karşı doğrulandı):
  ```nox
  t: Task[None] = spawn worker(xs)
  if condition:
      await t
  else:
      xs.append(42)   # v1.51.0-v1.53.0: SESSİZCE derleniyordu
  ```
  `condition == false` olduğunda `worker(xs)` HÂLÂ ÇALIŞIRKEN `xs.append(42)`
  senkronizasyonsuz bir mutasyondur — v1.51.0'ın CHANGELOG/spec metninin
  "sıfır yanlış-negatif" iddiası **YANLIŞTI**. Düzeltme (`compiler/typecheck/
  checker.zig`): `if`/`elif`/`else` dallarının HER BİRİ artık GİRİŞ durumunun
  KENDİ, BAĞIMSIZ bir KOPYASINDAN (`SpawnFlowState.clone`) başlar, ÇIKIŞTA
  "may" (union) anlamıyla birleştirilir (`SpawnFlowState.mergeFrom` —
  eksik bir `else`, GİRİŞ durumunu DEĞİŞTİRMEDEN birleşime katan zımni bir
  no-op dal gibi ele alınır, HH.2'nin KASITLI aşırı-muhafazakâr "spawn bir
  dalda ise if kapandıktan sonra da uçuşta say" davranışı KORUNUR). `while`/
  `for` döngüleri de artık HH.2'nin "iki-geçiş" yaklaşımı YERİNE GERÇEK bir
  fixpoint (`iterateLoopToFixpoint`, `state` monoton büyüdüğünden sonlu
  iterasyonda YAKINSAR, `MAX_LOOP_FIXPOINT_ITERATIONS=64` savunma sınırı)
  kullanıyor. Bellek yönetimi basitleştirildi: `checkNoPostSpawnCallerMutation`
  artık fonksiyon-ömürlü BİR `ArenaAllocator` kullanıyor (branch-başına
  klonlamanın ürettiği çok sayıda küçük tahsisi TEK bir `deinit()`le
  serbest bırakır — ÖNCEKİ kırılgan elle-serbest-bırakma döngüsü KALDIRILDI).
  3 yeni golden fixture eklendi (harici incelemenin TAM repro'su + ters
  yön + güvenli-dallanma regresyon-yok kontrolü); MEVCUT TÜM HH.2 fixture'ları
  (dahil `err_spawn_shared_mutation_after_if_conservative`, İÇTEN-DIŞA
  aşırı-muhafazakâr davranışın YENİ modelde de KORUNDUĞUNUN kanıtı)
  değişmeden geçiyor. `v1.51.0`nin KENDİ CHANGELOG/spec girişi TARİHSEL
  bir kayıt olarak DEĞİŞTİRİLMEDİ — düzeltme dürüstçe burada belgeleniyor.

## [1.53.0]

### Eklendi
- **HH.4 — build artifact izolasyonu**: `zig-out/bin/noxc`/`zig-out/lib/
  noxrt.o`/`zig-out/lib/nox/stdlib` PAYLAŞILAN, TEK yollardı — `zig build`
  (Debug, varsayılan) VE `zig build -Doptimize=ReleaseFast` İKİSİ de AYNI
  yola YAZIYORDU, HANGİSİ EN SON çalıştıysa O KAZANIYORDU. Bu OTURUMDA
  İKİ KEZ yaşanan GERÇEK bir kontaminasyon hatasının (elle yapılan bir
  ReleaseFast ölçümünün, SONRADAN İLGİSİZ bir `zig build test` [Debug]
  çağrısıyla SESSİZCE bozulması — v1.48.0 döneminde BİRKAÇ sayının 3-8×
  ŞİŞMİŞ olarak yanlışlıkla raporlanmasına yol açmıştı) KALICI çözümü.
  HER `zig build`/`zig build test` çağrısı ARTIK KENDİ `-Doptimize`
  moduna göre adlandırılmış, PAYLAŞILAN yola HİÇ DOKUNMAYAN EK bir kopya
  bırakır: `zig-out/<mod>/{bin/noxc, lib/noxrt.o, lib/nox/stdlib/}`
  (`<mod>` ∈ `debug`/`release-safe`/`release-fast`/`release-small`,
  Windows'ta AYRICA `lib/swap_asm.o`). `compiler/project.zig`nin ZATEN
  VAR OLAN `NOX_RESOURCE_DIR` ortam değişkeni (bkz. `resolveResourceDirs`)
  bu dizini DOĞRUDAN bir kaynak-kökü olarak kabul eder — ör.
  `NOX_RESOURCE_DIR=$PWD/zig-out/release-fast zig-out/release-fast/bin/
  noxc build --release foo.nox -o /tmp/foo` HER ZAMAN o ANDA derlenmiş
  ReleaseFast noxc/noxrt.o çiftini kullanır, SONRAKİ hiçbir Debug/farklı-
  modlu `zig build`/`zig build test` çağrısı bunu bozamaz. Tasarım
  TAMAMEN EK (additive) — PAYLAŞILAN yollara/`noxc`nin KENDİSİNE/
  `main.zig`e/`project.zig`ye HİÇBİR DOKUNUŞ yok, SIFIR mevcut-tüketici
  riski. Uçtan-uca doğrulandı: `zig build -Doptimize=ReleaseFast` SONRASI
  `zig build test` (Debug) çalıştırılıp PAYLAŞILAN yolun Debug'a
  DÖNDÜĞÜ, AMA `NOX_RESOURCE_DIR` İLE etiketli release-fast kökünün
  DEĞİŞMEDEN doğru çalıştığı GERÇEKTEN derlenip çalıştırılarak kanıtlandı.

## [1.52.0]

### Eklendi
- **HH.3 — `noxc explain <dosya.nox>`**: derleyicinin HER yerel değişken
  İçİn ZATEN verdiği "stack mi/arena mı/ARC mı" tahsis kararını (`compiler/
  codegen_qbe/local_escape.zig`nin `classifyVarDecl`i) İNSAN-OKUNUR bir
  raporla YÜZEYE ÇIKARIR — ÖNCEDEN bu bilgi SADECE `.ssa` metnini
  okuyarak çıkarılabiliyordu (bu OTURUM boyunca GG.16'dan GG.25'e KADAR
  TEKRAR TEKRAR yapılan İŞ). Örnek çıktı:
  ```
  app.nox:12  xs: list[int]
    tahsis: stack (40 bayt)
    gerekce:
      - sabit-boyutlu literal liste (40 bayt)
      - kaçmıyor, boyut/bütçe İçinde -> stack
    çerçeve bütçesi: 40 / 24576 bayt (önce: 0)
  ```
  Tasarım: `classifyVarDecl`nin (SAFETY-KRİTİK, ARC doğruluğunu kontrol
  eden kod) KENDİSİNE HİÇBİR DEĞİŞİKLİK YAPILMADI — YENİ `explainVarDecl`
  bu fonksiyonu ÇAĞIRIR (OTORİTER/GERÇEK karar, SIFIR sapma riski), SONRA
  SADECE "neden" METNİ İçİn AYNI dosyadaki SAF sub-predicate'leri (salt-
  okunur, yan-etkisiz) TEKRAR çağırır. `noxc explain` `--release` bayrağını
  da destekler (`list`/`class`/`dict` spawn-parametreli programların TİP-
  KONTROLÜNDEN geçebilmesi İçİn — tahsis kararının KENDİSİ backend'DEN
  BAĞIMSIZDIR). **GERÇEK bir hata bulunup düzeltildi** (geliştirme
  sırasında): `module_loader.resolveImports`nin `core.nox`/import edilen
  stdlib dosyalarını kullanıcının KENDİ `module.body`sinin ÖNÜNE EKLEMESİ
  YÜZÜNDEN, İLK sürüm stdlib'in KENDİ değişkenlerini kullanıcının dosyasına
  AİTMİŞ GİBİ (YANLIŞ satır numarasıyla) raporluyordu — `codegen.
  ExplainOptions`nin `user_stmt_start` alanıyla düzeltildi.

### Değişti
- `codegen.generateModule`e YENİ, SONDAKİ opsiyonel `explain_opts`
  parametresi eklendi (VARSAYILAN `null` — TÜM MEVCUT çağrı siteleri
  DAVRANIŞ SIFIR değişecek şekilde güncellendi; `codegen_ir_diff_test.zig`nin
  237 fixture'ı BİREBİR AYNI kaldığı doğrulanarak KANITLANDI).

## [1.51.0]

### Düzeltildi
- **HH.2 — post-spawn çağıran-tarafı mutasyon denetleyicisi artık CFG-
  farkındalı**: GG.22.B'nin (v1.46.0) `checkNoPostSpawnCallerMutation`i
  BİLİNÇLİ olarak SADECE üst-düzey deyimleri tarıyordu — bir harici
  incelemenin işaret ettiği somut boşluk:
  ```nox
  xs: list[int] = [1, 2, 3]
  t: Task[int] = spawn worker(xs)
  if condition:
      xs.append(42)   # ÖNCEDEN yakalanmıyordu
  await t
  ```
  `condition` runtime'da `True` olursa `xs`, `worker`nin (`--release`
  altında BAŞKA bir OS iş parçacığında ÇALIŞABİLEN) HÂLÂ İŞLEDİĞİ SIRADA
  senkronizasyonsuz mutasyona uğrardı. `checkNoPostSpawnCallerMutation`
  ARTIK `if`/`elif`/`else` VE `while`/`for` gövdelerine ÖZYİNELER —
  FORK/MERGE gerektiren tam bir dataflow-lattice modeli YERİNE, TEK bir
  threading edilen durumla (dallara AYRI kopyalar yerine AYNI pointer'lar
  geçirilir) AYNI güvenlik garantisini (SIFIR yanlış-negatif) daha az
  mühendislik riskiyle sağlayan bir tasarım. Döngüler İçİn "iki-geçiş"
  yaklaşımı (gövde İKİ KEZ İşlenir) bir döngünün KENDİ "geri-kenarını"
  (gövde SONUNDA spawn edilip gövde BAŞINDA mutasyona uğrayan bir
  paylaşım) da yakalar. `try`/`except`/`finally`/`with`/`lowlevel`/
  İÇ İÇE `func_def`/`class_def` HÂLÂ kapsam DIŞI (AYRI, gelecekteki bir
  tur). Kırmızı-takım kanıtı: HEM if/while/for özyinelemesi HEM iki-
  geçiş mekanizması AYRI AYRI GEÇİCİ olarak KALDIRILIP YENİ testlerin
  DOĞRU şekilde başarısız olduğu doğrulandı.

## [1.50.0]

### Eklendi
- **HH.1 — QBE↔LLVM backend conformance suite**: kullanıcının paylaştığı
  bir harici incelemenin önerisi — GG.24'ün araştırması SIRASINDA
  (v1.48.0) TAMAMEN İLGİSİZ bir stack-size ölçümü YAPARKEN `await`
  edilen HERHANGİ bir `bool` sonucunun `--release` altında HİÇ
  DERLENEMEDİĞİ (LLVM emisyon hatası, QBE yolu HİÇBİR ZAMAN göstermedi)
  bulunmuştu — sistematik bir karşılaştırma OLMADAN bu tür hatalar
  AYLARCA gizli kalabilirdi. YENİ `tests/golden/backend_conformance_test.zig`,
  AYNI Nox kaynağını HEM QBE HEM LLVM İLE derleyip çalıştırır, stdout'ların
  BİREBİR eşleştiğini doğrular — 6 "uyum" testi (fonksiyon dönüşü/
  istisna-yükü/closure-yakalaması/sınıf-alanı/liste-elemanı/tek spawn+await,
  int/bool/float/str/class tiplerini KAPSAR) + 5 "belgelenmiş sapma"
  testi (`checker.zig`nin `isSpawnParamSafeType`/`isThreadTransferSafeType`si
  — `list`/`class` spawn/`nox.thread.start` parametresi SADECE `--release`de
  geçerli; `nox.thread.pool_run` SADECE `--release`de derlenir; decorator'lar
  İSE TERSİNE SADECE `.qbe`de çalışır, `--release`de reddedilir — HER
  İKİ backend'in de KENDİ KABUL/RED sınırını AÇIKÇA doğrular). Kırmızı-
  takım kanıtı: `llvm_emit.zig`nin `trunc` düzeltmesi GEÇİCİ olarak GERİ
  ALINIP conformance paketinin GERÇEKTEN bunu YAKALADIĞI doğrulandı.

### Değişti
- `tests/golden/codegen_golden_test.zig`nin `compileAndRun`ı VE
  `tests/golden/llvm_golden_test.zig`nin `compileAndRunLlvm`ı YENİ,
  paylaşılan `tests/golden/compile_helpers.zig`ye TAŞINDI (DAVRANIŞ
  SIFIR değişti — AYNI fonksiyon gövdesi, SADECE YERİ değişti) — ÜÇÜNCÜ
  bir bağımsız kopya (YENİ conformance testi İçİn) çıkarılmadı, TAM
  OLARAK bu paketin ÖNLEMEYE ÇALIŞTIĞI "iki implementasyon SESSİZCE
  birbirinden SAPAR" hata SINIFININ KENDİSİNE düşülmemesi İçİn.

### Notlar
- Bu turda `zig build test`in (Debug/ReleaseFast) TAM koşularında YENİ,
  4. bir "zararsız ama TANIDIK" harness artefaktı GÖZLEMLENDİ: YENİ
  conformance testi (11 test, HER biri HEM QBE HEM LLVM İçİn AYRI
  alt-süreçler — TOPLAM ~44 harici süreç çağrısı) `zig build test`in
  `--listen=-` IPC protokolüyle ARADA SIRADA `EndOfStream` panikleriyle
  "başarısız" GÖRÜNÜYOR — AYNI test ikilisi `--listen` OLMADAN DOĞRUDAN
  çalıştırıldığında (VE standalone `zig test` İLE tekrarlanan koşularda)
  HER ZAMAN 11/11 TEMİZ geçiyor. Bu, projenin ÖNCEDEN belgelediği 3
  bilinen flake'le (paralel test yükü altında OS-seviyesi kaynak baskısı)
  AYNI KÖKTEN — GERÇEK bir mantık hatası DEĞİL.

## [1.49.0]

### Düzeltildi
- **GG.25.1 — `STACK_SIZE`'ın (v1.48.0) gözden kaçan riski: sıradan
  KULLANICI özyinelemesi**: bir harici incelemenin işaret ettiği,
  GG.24/GG.25'in (v1.48.0) ölçtüğü DÖRT senaryonun (regex/JSON/sınıf-
  zinciri release'i/Aether-Nyx) HEPSİNİN çalışma-zamanının KENDİ İÇ
  özyinelemesi olduğu, HİÇBİRİNİN SIRADAN bir Nox kullanıcı fonksiyonunun
  GERÇEK özyinelemesini (`def f(n): return f(n-1)` gibi) ÖLÇMEDİĞİ
  bulgusu doğrulandı. Ölçüm: KUYRUK-özyinelemeli desenler LLVM
  TARAFINDAN SESSİZCE döngüye çevrildiğinden (yığın büyümesi SIFIR
  görünür, YANILTICI test), AMA GERÇEK (kuyruk-OLMAYAN, her seviyede
  heap tahsisi yapan — LLVM'in döngüye ÇEVİREMEYECEĞİ) bir özyineleme
  seviye-başına ~48-80 bayt (fonksiyon karmaşıklığına göre) GERÇEK
  yığın tüketiyor — 128 KiB'de bu SADECE ~1.600-2.700 seviye (Python'un
  varsayılan 1.000 özyineleme sınırının ~1.6-2.7 katı, AMA DAR bir pay)
  güvenli demekti (256 KiB'DEKİ ~3.200-5.400 seviyenin YARISI).
  `STACK_SIZE` (`runtime/async_rt/fiber.zig`) 128 KiB'DEN **192 KiB**'e
  yükseltildi — orta-karmaşıklıkta bir fonksiyon İçİn ~2.400 seviye
  (Python'un ~%140 FAZLASI, DAHA RAHAT bir pay) sağlarken, ORİJİNAL
  256 KiB'e göre YİNE DE adres-alanında ~%25 kazanım BIRAKIR.
  `MAX_STACK_ALLOC_SIZE`(2048→3072)/`MAX_PROMOTED_FRAME_SIZE`(16384→24576)
  AYNI oranda ölçeklendi. GG.24/GG.25'in DÖRT senaryosu 192 KiB'İN de
  ÇOK RAHAT altında kalmaya DEVAM ediyor (EN YÜKSEK/JSON: hedefin
  SADECE ~%9'u).

### Eklendi
- **YENİ, kalıcı regresyon testi** (`gg25_user_recursion_depth_1000.nox`):
  Python'un varsayılan özyineleme sınırıyla (1000) AYNI derinlikte,
  KUYRUK-OLMAYAN bir kullanıcı özyinelemesi, `spawn`/`await` İLE fiber'ın
  KENDİ (sınırlı) yığınında çalıştırılır — `STACK_SIZE` GELECEKTE tekrar
  küçültülürse BU testin ÇÖKMESİ (SIGBUS), o değişikliğin sıradan
  kullanıcı özyinelemesi İçİn GÜVENLİ OLMADIĞININ KANITI olur.

### Notlar
- Bu düzeltme, `v1.48.0`nin YAYIMLANMASINDAN HEMEN SONRA, bir harici
  incelemenin ("kullanıcı-kodu özyineleme için ayrı bir stack-overflow
  regresyon paketi eksik") doğrudan doğrulanmasıyla bulundu — dürüstçe
  AYRI bir sürüm OLARAK kaydedilir (`v1.48.0`nin KENDİSİ geri ALINMADI/
  amend EDİLMEDİ, SADECE bu YENİ bulgu SONRASINDA düzeltildi).

## [1.48.0]

### Düzeltildi
- **GG.24 — `genClassRelease`'in özyineleme derinliği sertleştirmesi**:
  GG.23'ün ERTELEDİĞİ 4. risk (bkz. `[1.47.0]`nin "Notlar"ı) çözüldü —
  `compiler/codegen_qbe/ownership.zig`nin `releaseValueIfSet`i/
  `genListElemRelease`i VE `exceptions.zig`nin bare-`except:` dispatch'i,
  bir sınıf-tipli alanı (`Node.next: Node | None` gibi) serbest bırakırken
  ÖNCEDEN DOĞRUDAN `call $ClassName_release`/`$nox_class_release_dispatch`
  üretiyordu — bir bağlı-liste/ağaç ZİNCİRİNİ serbest bırakırken HER
  halka İçİn GERÇEK bir yığın çerçevesi tüketiyordu. YENİ, derinlik-eşiği
  KARMA mekanizma (`runtime/alloc/arc.zig`nin `nox_rc_release_enqueue_
  fixed`/`_dynamic`i): İLK `MAX_DIRECT_RELEASE_DEPTH` (50) seviye BUGÜNKÜ
  GİBİ doğrudan çağrı (ölçülemeyecek KADAR küçük ek yük), SADECE bunu
  aşan patolojik zincirlerde `cycle_detector.zig`nin `markGray`/
  `scanBlack`İYLE AYNI iteratif, heap-tabanlı worklist'e düşülür — TOPLAM
  en-kötü-durum yığın derinliği ARTIK zincir uzunluğundan TAMAMEN
  BAĞIMSIZ (`NOX_STACK_PAINT`İLE ÖLÇÜLDÜ: 2.000/7.000/50.000 düğümlük
  zincirlerin ÜÇÜ de AYNI 5.936 baytlık sabit tavanda).
- **`--release` (LLVM) — `await` edilen bir `bool` sonucu HİÇ derlenemiyordu
  (GG.24'ün araştırması SIRASINDA bulundu, TAMAMEN AYRI bir hata)**:
  `compiler/codegen_qbe/llvm_emit.zig`nin `qbeOp1`si, `w`-hedefli bir
  `copy`yi HER ZAMAN `add i32 <kaynak>, 0` olarak üretiyordu — AMA bu kod
  tabanında `w`-hedefli `copy`nin TEK kullanımı (`expr.zig`nin
  `fromPayload`si, `await`in `i64` payload'ını bir `bool`e DARALTIRKEN)
  kaynağı HER ZAMAN `l` (i64) tipindeydi, bu YÜZDEN LLVM operand-tipi
  uyuşmazlığı YÜZÜNDEN GEÇERSİZ IR üretiliyordu. Sonuç: `--release`
  altında `Task[bool]`/`Channel[bool]` await eden HERHANGİ bir program
  (`nox.regex.is_match`in KENDİSİ DAHİL, `bool` döndürdüğünden) `clang
  basarisiz` İLE derlenemiyordu. Düzeltme: `qbeOp1`e AÇIK bir `trunc i64
  ... to i32` dalı eklendi.

### Değişti
- **`STACK_SIZE` 256 KiB'den 128 KiB'e küçültüldü** (`runtime/async_rt/
  fiber.zig`) — GG.24'ün düzeltmesi SONRASI GG.23'ün DÖRT sentetik en-
  kötü-durum senaryosu + GERÇEK-dünya (Aether v0.6.5/Nyx v0.17.0)
  `NOX_STACK_PAINT`İLE YENİDEN ölçüldü: regex 1.312 B, JSON (30 seviye)
  17.760 B (EN YÜKSEK sentetik senaryo, hedefin SADECE ~%13.6'sı), sınıf-
  zinciri release'i (HERHANGİ bir uzunlukta) 5.936 B, Aether 4.928 B, Nyx
  13.952 B — HEPSİ 128 KiB'in ÇOK RAHAT altında. `compiler/codegen_qbe/
  inlining.zig`nin `MAX_STACK_ALLOC_SIZE`(4096→2048)/`MAX_PROMOTED_
  FRAME_SIZE`(32768→16384) sabitleri AYNI oranda (YARIYA) küçültüldü.
  `MAX_DIRECT_RELEASE_DEPTH` (yukarıdaki GG.24 düzeltmesi) 200'DEN 50'YE
  düşürüldü — 200'ün KENDİSİ ZATEN güvenliydi (gerçek tavan ~17.936 B),
  AMA 50 EK bir güvenlik payı sağlıyor VE GERÇEK-dünya zincirleri
  PRATİKTE asla 50 seviyeye BİLE yaklaşmadığından davranış/performans
  SIFIR etkilenir.

### Notlar
- **Ölçüm metodolojisi dersi**: bu turun ARA bir aşamasında, `zig build
  test`in (Debug modu, `-Doptimize` VERİLMEDEN) `zig-out/lib/noxrt.o`yu
  SESSİZCE Debug-modu bir sürümle EZDİĞİ fark edilmeden birkaç `--release`
  ölçümü (chain-release/Aether/Nyx) alındı — Debug modu ARC havuzlamasını
  DEVRE DIŞI bıraktığından (`use_pool = builtin.mode != .Debug`) bu
  ölçümler GERÇEK sayılardan ~3-8× ŞİŞİRİLMİŞTİ (ör. chain-release tavanı
  YANLIŞLIKLA 137.904 B GİBİ görünmüştü, GERÇEĞİ 5.936 B). Hata, `git
  stash` İLE TEMİZ `v1.47.0` HEAD'e karşı AYNI ölçümün TEKRARLANMASIYLA
  yakalanıp (AYNI şişirilmiş sayılar YENİDEN üretildi) düzeltildi — TÜM
  yukarıdaki sayılar `zig build -Doptimize=ReleaseFast`in HEMEN SONRASINDA,
  ARADA HİÇBİR Debug derlemesi OLMADAN alınmış TEMİZ ölçümlerdir.
- Gerçek-dünya doğrulaması: Aether (20 test) + Nyx (45 test) TAM test
  paketleri YENİ noxc İLE (128 KiB `STACK_SIZE`İLE) 65/65 yeşil.

## [1.47.0]

### Düzeltildi
- **GG.23 — fiber-stack sertleştirmesi (cycle-collector/JSON/regex
  özyinelemesi)**: fiber'ın sabit 256 KiB yığınını AŞABİLECEK üç ayrı
  özyineleme riski sertleştirildi. (1) `runtime/alloc/cycle_detector.zig`nin
  Bacon-Rajan `markGray`/`scan`/`scanBlack`/`collectWhite`si (kullanıcı
  hiçbir şey yapmadan `possible_roots_since_collect` 700'ü aştığında
  OTOMATİK tetiklenen döngü-çöpçüsü) Zig-çağrı-yığını YERİNE yığın
  (heap) tabanlı bir worklist kullanacak şekilde ITERATİF hale getirildi
  — artık binlerce/milyonlarca nesnelik meşru veri yapıları (bağlı-liste/
  ağaç/önbellek) BU tarama YÜZÜNDEN çökmez. Dönüşüm SIRASINDA GERÇEK, ince
  bir doğruluk noktası bulunup düzeltildi: iteratif `scanBlack`nin LIFO
  sırası, paylaşılan/"elmas" bir çocuğun (iki ayrı ebeveynden erişilen)
  İKİ KEZ işlenmesine (çift refcount artışına) yol açabiliyordu — YENİ
  bir POP-anı "zaten siyah mı" kontrolüyle (VE bunu kanıtlayan YENİ bir
  "elmas" kırmızı-takım testiyle) düzeltildi. (2) `nox.json.decode`ye
  YENİ bir iç-içe-geçme derinlik sınırı (32 seviye) — hem `std.json.
  parseFromSlice`nin KENDİ sınırsız iç özyinelemesini HEM `buildNode`/
  `buildNodeFast`nin ayrı geçişini korur; sınırı aşan girdi MEVCUT
  "geçersiz JSON" (`JsonError`) hata yoluyla temiz reddedilir. (3)
  `nox.regex`in `matchHere`si — düz-literal/karakter-sınıfı eşleşme dalı
  (nicelik işaretçisi GEREKMEDEN) HER KARAKTER İçİn bir yığın çerçevesi
  üreten bir kuyruk-çağrısıydı (ölçüldü: ~688 B/karakter, ~378 karakterlik
  SIRADAN bir metinde ZATEN 256 KiB'i aşıyordu) — bir döngüye çevrildi
  (SIFIR yığın büyümesi); kalan risk (bir PATERNİN kendisinin adversarial
  olarak çok sayıda nicelik işaretçisi taşıması) İçİn 500 derinlikli bir
  savunma sınırı eklendi (aşılırsa sessizce "eşleşme yok" döner, `is_match`/
  `find`in TOTAL fonksiyon sözleşmesi korunur).

### Eklendi
- **Kalıcı `NOX_STACK_PAINT` fiber-stack ölçüm aracı**: bir "stack-painting"
  tekniğiyle (fiber yığınını imzalı bir desenle boyayıp, kullanım
  sonunda ne kadarının bozulduğunu tarayarak) GERÇEK yüksek-su-işaretini
  ölçen, `NOX_STACK_PAINT` ortam değişkeniyle KAPILI (varsayılan: SIFIR
  maliyet) kalıcı bir araç — `NOX_STRESS_ROUNDS`/`NOX_SOAK_SECONDS`nin
  AYNI deseni. `nox_runtime_deinit` süreç-çapında ölçülen maksimumu
  `NOX_STACK_HWM_BYTES=<n>` olarak stderr'e yazar.

### Notlar
- Derin bir araştırma (stack-painting İLE GERÇEK ölçüm) `STACK_SIZE`i
  (256 KiB) küçültmenin GÜVENLİ olup OLMADIĞINI da araştırdı — bu turun
  3 düzeltmesi SONRASI regex/JSON senaryoları ÇOK güvenli hale geldi
  (400 karakterlik regex: 1.312 B; 30 seviye JSON: 17.696 B) AMA GERÇEK
  bir 4. risk bulundu: uzun bir bağlı-liste zincirinin release'i,
  BAMBAŞKA bir mekanizmadan (codegen'in KENDİ ürettiği `genClassRelease`/
  `releaseValueIfSet` özyinelemeli release zinciri, `compiler/codegen_qbe/
  layout.zig`/`ownership.zig` — bu turun kapsamı DIŞINDA) kaynaklanıyor
  VE hâlâ ~32 B/düğüm maliyetli (256 KiB'de ~7.300 düğümde sınırda).
  Bu YÜZDEN **`STACK_SIZE` bu turda 256 KiB'DE KALDI** — küçültme, bu
  4. riskin (`genClassRelease`nin KENDİ özyinelemesinin iteratif hale
  getirilmesi) çözülmesini bekleyen AYRI, gelecekteki bir tura bırakıldı.
  Gerçek-dünya doğrulaması: Aether (v0.6.5, 20 test) + Nyx (v0.17.0, 45
  test) TAM test paketleri YENİ noxc İLE 65/65 yeşil.

## [1.46.0]

### Düzeltildi
- **GG.22.A — `checkCall`nin `.identifier` dalındaki gölgeleme-çözümleme
  sırası hatası**: `checkCall`nin çözümleme sırası ÖNCEDEN `generic_functions`/
  `self.functions`/`self.classes`'ı `ctx.scope.lookup`dan (yerel değişken/
  parametre) ÖNCE kontrol ediyordu — codegen'in `genCall`ı İSE HER ZAMAN
  yereli ÖNCE kontrol eder. Bir yerel func-tipli değişken GERÇEK bir
  global fonksiyonla AYNI adı AMA FARKLI bir imza TAŞIDIĞINDA (`mutate:
  (int) -> int = other`, global `mutate` 2 parametreli), checker
  YANLIŞLIKLA global'in imzasına göre doğrulayıp GEÇERLİ bir programı
  `ArgumentCountMismatch` İLE reddediyordu — checker/codegen ANLAŞMAZLIĞI.
  `ctx.scope.lookup` ARTIK generic/global/sınıf kontrollerinin HEMEN
  ÖNÜNE taşındı (codegen'İN önceliklendirmesiyle TAM eşleşiyor,
  `from_imports` YİNE EN SONDA). YENİ bir codegen golden fixture'ı
  (`local_func_value_shadows_global_diff_arity`) düzeltmeden ÖNCE
  reddedilen, SONRA doğru derlenip çalışan programı kanıtlar.

### Eklendi
- **GG.22.B — spawn-sonrası çağıran-tarafı mutasyon koruması**:
  `checkNoSpawnSharedMutation` SADECE spawn-HEDEFİ fonksiyonun KENDİ
  gövdesini kontrol ediyordu — bir `spawn` çağrısına paylaşılan bir
  `list`/`dict`/`class` yerel GEÇTİKTEN SONRA, çağıranın KENDİSİNİN bu
  değişkeni `await` edilmeden ÖNCE mutasyona uğratmasını HİÇBİR ŞEY
  KISITLAMIYORDU (`--release`/LLVM'de yapısal olarak İFADE edilebilen
  GERÇEK bir veri-yarışı boşluğu). YENİ `checkNoPostSpawnCallerMutation`
  (checker.zig) — ÜST-DÜZEY deyimleri (if/while/for/try/with gövdelerine
  İNMEDEN, v1 BİLİNÇLİ sınırı) forward tek-geçişle tarayıp bir `spawn`a
  paylaşılan argüman olarak geçen isimleri "uçuşta" işaretler, karşılık
  gelen `await`te temizler; `await` edilmeden (VEYA fire-and-forget —
  isimsiz spawn — HİÇBİR ZAMAN) önce bu isimlerin mutasyona uğratılması
  ARTIK `SpawnSharedMutation` İLE reddedilir. `checkFunctionBody` VE
  `checkModule`nin üst-düzey taramasına kanca eklendi. 3 YENİ LLVM golden
  fixture'ı (`llvm_golden_test.zig`): hata — await'ten ÖNCE mutasyon;
  regresyon-yok — await'TEN SONRA mutasyon SERBEST; hata — fire-and-forget
  spawn SONRASI mutasyon HÂLÂ REDDEDİLİR.

## [1.45.0]

### Eklendi
- **GG.21 — metod çağrıları için interprocedural escape/mutasyon
  genişletmesi (ASAP güçlendirmesi, Tur 5)**: v1.44.0'ın (GG.20) SADECE
  serbest fonksiyon çağrılarını kapsayan interprocedural kanıtı ARTIK
  METOD çağrılarını (`obj.method(...)`) da kapsıyor — AMA SADECE metod
  PROVABLY "final" (receiver'ın statik tipinin HİÇBİR bilinen alt sınıfı
  O metodu override ETMİYORSA) İSE VE receiver İZLENEN fonksiyonun KENDİ
  (sibling) bir parametresiyse (checker tarafında `resolveExprSharedType`
  SAYESİNDE alan-zincirleri de DAHİL). `checker.zig`ye YENİ `ClassInfo.
  method_owners` + `methodIsFinal`; `codegen_qbe`ye YENİ `methodIsFinal`
  (`ClassInfo.descendant_class_ids`/`ClassMethodInfo.owner` — ZATEN VAR
  OLAN exception-hiyerarşisi bilgisini YENİDEN KULLANIR) + `ClassParam`/
  `collectClassParams`. Override EDİLEN bir metot (polimorfik olabilir)
  HÂLÂ koşulsuz kaçış/mutasyon SAYILIR — `inheritance_polymorphism.nox`nin
  AYNI deseniyle kanıtlanan KIRMIZI-TAKIM testleri BUNU doğrular.
  Geliştirme SIRASINDA break→red→fix İLE GERÇEK bir hata bulundu VE
  düzeltildi: `msig.owner` (SADECE sınıf adı) `NodeKey.func` OLARAK
  YANLIŞLIKLA KULLANILMIŞTI (doğrusu `"{sınıf}_{metod}"` sembolü) — bu,
  final bir metodun GERÇEKTEN mutasyona uğrattığı bir argümanın
  YANLIŞLIKLA "güvenli" sayılıp stack'e taşınmasına, GERÇEK bir
  kullanım-sonrası-serbest-bırakma çökmesine (SIGSEGV, red-team fixture'ı
  İLE ÜRETİLEN) yol açıyordu — kırmızı-takım testleri TAM OLARAK BUNU
  yakaladı. `point_sum`-benzeri bir metod-yönlendirme deseni İçİn `git
  worktree` İLE ~2.8x ölçülen kazanç (bkz. `benchmarks/RESULTS.md`).
  3 YENİ checker fixture'ı + 3 YENİ codegen fixture'ı (pozitif + negatif-
  mutasyon + kırmızı-takım-polimorfizm, HER İKİ tarafta da), tam
  regresyon paketi + stress-test tamamen yeşil.

## [1.44.0]

### Eklendi
- **GG.20 — interprocedural escape/mutasyon analizi (ASAP güçlendirmesi,
  Tur 4)**: harici bir (GPT-5.6) incelemenin işaret ettiği ORTAK kök
  neden (`checker.zig`nin `SpawnSharedMutation`ı bir yardımcı fonksiyon
  ÜZERİNDEN mutasyonu yakalayamıyordu; ASAP'in KENDİ "argüman-olarak-
  geçiş HER ZAMAN kaçış" katı kuralı AYNI nedenden geliyordu) İçİn TEK,
  PAYLAŞILAN bir "fonksiyon etkisi" motoru: YENİ `compiler/effect_graph.zig`
  (`computeMustNotRaise`in ters-çağrı-grafiği/worklist algoritmasının
  GENELLEŞTİRİLMİŞ, checker/codegen ARASINDA bağımlılık KURMAYAN, NÖTR
  hali). `checker.zig`nin `SpawnSharedMutation`ı ARTIK bir yardımcı
  fonksiyon ÜZERİNDEN (arbitrer derinlikte, transitif olarak) mutasyonu
  YAKALAR. `codegen_qbe`nin ASAP'i (GG.17/19) ARTIK salt-okunur bir
  SERBEST fonksiyona argüman olarak geçen bir yereli stack'e dönüştürebilir
  (ÖNCEDEN HER argüman-geçişi koşulsuz kaçış SAYILIYORDU) — GG.18'in
  arena-yolu VE `spawn`a geçen değerler BU gevşetmenin BİLİNÇLİ olarak
  DIŞINDA bırakıldı (İKİSİ de break→red→fix İLE doğrulanan GERÇEK
  güvenlik sınırları: arena değerleri çağrı sınırını AŞAMAZ, spawn
  ASENKRON/çapraz-fiber olduğundan callee'nin KENDİ kaçış-kanıtı
  GEÇERSİZDİR). `point_sum`-benzeri bir desen İçİn `git worktree` İLE
  ~2.9x ölçülen bir kazanç (bkz. `benchmarks/RESULTS.md`). 6 YENİ golden
  fixture (3 checker + 3 codegen) + 2 LLVM kırmızı-takım testi, tam
  regresyon paketi + `NOX_STRESS_ROUNDS=800 zig build stress-test`
  tamamen yeşil.

## [1.43.0]

### Eklendi
- **GG.19 — aggregate stack-promotion bütçesi + inline/ASAP'in birlikte
  çalışması**: harici bir (GPT-5.6) incelemenin bulduğu İKİ maddenin
  düzeltmesi. (1) `MAX_STACK_ALLOC_SIZE` (4096 bayt) ARTIK SADECE nesne-
  başına DEĞİL — YENİ `MAX_PROMOTED_FRAME_SIZE` (32 KiB) bir fonksiyonun
  TÜM stack-promotable yerellerinin TOPLAMINI da sınırlıyor (aşan bir
  aday arenaya DÜŞÜYOR — sınıflar İçİn de artık bir arena-fallback VAR,
  ÖNCEDEN tek seçenek tam ARC'tı). (2) v1.42.0'ın "GG.17/18 adayı
  İçEREN HER fonksiyonu GG.2 inline-edilebilirliğinden TAMAMEN dışla"
  KABA hotfix'i KALDIRILDI — `registerInlineSite` ARTIK callee gövdesindeki
  HER adayı, GG.2'nin KENDİ `self.vars` gölgeleme desenini TEKRARLAYAN
  bir mekanizmayla (`InlineConstructSite`), BU SPESİFİK splice sitesine
  ÖZGÜ TAZE bir tutamakla YENİDEN kaydediyor — inline + ASAP ARTIK
  GÜVENLE BİRLİKTE çalışıyor. İncelemenin KENDİ önerdiği `point_sum(x)`
  deseni İçİn `git worktree` İLE v1.42.0 (stack-SADECE) karşısında EK
  bir kazanç ölçüldü (bkz. `benchmarks/RESULTS.md`). 4 YENİ golden
  fixture (aynı-helper-birden-fazla-çağrı-sitesi, aynı-helper-iki-farklı-
  caller, inline+stack birlikte, aggregate bütçe aşımı) + tam regresyon
  paketi, `zig build test` 106/106 adım 882/882 test tamamen yeşil.

## [1.42.0]

### Düzeltildi
- **GG.17'nin `stack_construct_sites` kaydı, inline edilince ÇAPRAZ-
  FONKSİYON temp adı çakışmasına yol açıyordu (GERÇEK, canlı bir hata —
  v1.41.0/v1.41.1'de)**: bir GG.17-kalifiye yerel İÇEREN VE AYRICA GG.2
  inline-edilebilirlik şartlarını da KARŞILAYAN bir fonksiyon (`helper()`),
  başka bir fonksiyona (`caller()`) inline edildiğinde, `stack_construct_
  sites`in AST-düğüm-anahtarlı, hiç temizlenmeyen kaydı `helper`'ın KENDİ
  temp-numaralandırmasına ÖZGÜ bir dizeyi TAŞIYIP splice SIRASINDA
  YENİDEN kullanıyordu — `caller`'ın AYNI dizeyi taşıyan TAMAMEN FARKLI
  bir yerelinin (ör. bir parametre) ÜZERİNE liste payload'ı TAŞARAK
  yazılıyordu (sessiz bir stack bozulması, farklı slot düzenlerinde GERÇEK
  bir çökme/yanlış sonuç üretebilirdi). Doğrudan derlenip ÇALIŞTIRILARAK
  bulundu. Düzeltme: bir fonksiyonun gövdesi GG.17/18 TARAFINDAN EN AZ bir
  düğüm kaydedecekse, o fonksiyon ARTIK GG.2 inline-edilebilirliğinden
  TAMAMEN DIŞLANIYOR (`lowlevel_stmt` İÇEREn bir gövdenin ZATEN AYNI
  gerekçeyle dışlanmasıyla TUTARLI).

### Eklendi
- **GG.18 — değişken-boyutlu (`.append()` ile büyüyen) listeler İçİn
  fonksiyon-kapsamlı arena**: GG.17'nin sabit-boyutlu kapsamının DIŞINDA
  kalan bir `list[T]` (`T` SKALER: int/float/bool) yereli — boş `[]`
  literalinden `.append()` İLE büyüyen, gerisinde HİÇ kaçmadığı KANITLANAN
  — ARTIK `nox_rc_alloc`+refcount başlığı YERİNE fonksiyon-kapsamlı, ÖZEL
  bir arena (`nox_arena_create`/`nox_arena_alloc`/YENİ `nox_arena_list_
  grow`/`nox_arena_destroy`) kullanıyor — `.append()` içeren ARC yolunda
  daha önce ölçülemeyen bir kazanç (sık çağrılan bir fonksiyon İçİnde
  büyüyen bir liste deseni İçİn `git worktree` İLE ölçüldü, bkz.
  `benchmarks/RESULTS.md`). v1'de BİLİNÇLİ olarak SADECE `.append()`
  desteklenir (`.pop()`/`.sort()`/argüman-olarak-geçiş/`return` HÂLÂ kaçış
  sayılır), heap-yönetimli eleman tipleri (`list[str]` GİBİ) ARENA'YA
  dönüştürülmez (arenanın per-object free desteklememesi, elemanların
  release edilmemesi anlamına gelirdi — GG.17'nin class-alan-release
  hatasının AYNISı BAŞTAN elendi). Kullanıcının "ASAP'i (Katman 1)
  güçlendirebilir miyiz" hipotezinin Tur 2'si — bkz. nox-teknik-
  spesifikasyon.md §3.108.

## [1.41.0]

### Eklendi
- **GG.17 — sıradan yerel değişkenler İçİn genel kaçış analizi (ASAP
  güçlendirmesi, Tur 1)**: bir fonksiyon gövdesinin ÜST DÜZEYİNDEKİ bir
  `var_decl` (`p: Point = Point(1,2)` YA DA `xs: list[int] = [1,2,3]`,
  ne `lowlevel:` İçİnde ne bir çağrı-argümanı) derleme-zamanında boyutu
  bilindiği VE geri kalan gövdede HİÇ kaçmadığı (`return`/argüman/alan-
  ataması/takma-ad/metod-çağrısı OLARAK kullanılmadığı) KANITLANDIĞINDA
  ARTIK `nox_rc_alloc` YERİNE gerçek bir QBE stack `alloc8`'i kullanıyor
  — retain/release/refcount başlığı TAMAMEN ORTADAN KALKIYOR (C'nin
  KENDİ stack-allocation maliyetiyle eşdeğer). Mevcut GG.15 (`lowlevel:`
  blokları)/GG.16 (çağrı-argümanları) üreticileriyle AYNI, paylaşılan
  tüketim mekanizmasını (`Codegen.stack_construct_sites`) kullanır —
  tüketim tarafına SIFIR değişiklik gerekti. YENİ, ORTAK bir boyut tavanı
  (`MAX_STACK_ALLOC_SIZE = 4096` bayt, bir fiber'ın 256 KiB stack'ini
  korumak İçİn) GG.15/16'ya da RETROAKTİF uygulandı (öncesinde İKİSİ de
  SINIRSIZDI). Kullanıcının "ASAP'i (Katman 1) güçlendirebilir miyiz"
  hipotezinin doğrudan sonucu — bkz. nox-teknik-spesifikasyon.md §3.107
  (İKİ GERÇEK, break→red→fix İLE bulunan hatanın — sıralama hatası VE
  sınıf-alan-release atlaması — TAM hikayesi).

## [1.40.0]

### Düzeltildi
- **`setNonBlocking`'in HER `nonBlockingRead`/`Write`/`Accept` çağrısında
  gereksiz tekrarı giderildi — bu oturumdaki EN BÜYÜK, GERÇEK performans
  bulgusu.** Kullanıcının "dilimiz, IO, HTTP için detaylı bir bottleneck
  analizi yapalım" isteği ÜZERİNE `benchmarks/http_compare/` TAZEden
  ölçüldü — v1.38.0/v1.39.0'ın threadlocal/RuntimeState düzeltmelerinin
  GERÇEK HTTP verimini ÖLÇÜLEBİLİR şekilde DEĞİŞTİRMEDİĞİ (interleaved
  A/B, v1.37.0 vs v1.39.0, HEM GET-echo HEM JSON-POST senaryosunda
  istatistiksel olarak AYIRT EDİLEMEZ) DÜRÜSTÇE kaydedildi. AMA bu SIRADA
  `run_json_worker_sweep.sh`nin (Faz MN.10 regresyon kapısı) 4-worker
  durumunda 1-worker'DAN YAVAŞ ölçüldüğü GÖRÜLDÜ — `sample` (macOS
  profillerici) İLE profillenip `otool -tV` İLE ADRES ARİTMETİĞİYLE
  çapraz-doğrulandı: profilcinin fiber stack-switching'in kafasını
  karıştırdığı "releaseStack/trampoline" sembolizasyonu ASLINDA `io.
  nonBlockingWrite`nin İÇİYDİ. Kök neden: `setNonBlocking(fd)` (2 gerçek
  `fcntl` syscall'ı) HER `nonBlockingRead`/`nonBlockingReadWithTimeout`/
  `nonBlockingWrite` çağrısının BAŞINDA KOŞULSUZ çalışıyordu — fd'nin
  non-blocking DURUMU bir KEZ ayarlandıktan SONRA ASLA değişmediği HALDE.
  Kalıcı/keep-alive bir bağlantı BİRÇOK isteği hizmet ettiğinden HER
  istek EN AZ 4 GEREKSİZ syscall ÖDÜYORDU. Geçici olarak kaldırılıp
  ölçülünce (SONRA geri alındı) 4-worker JSON senaryosu **~%41 daha
  HIZLI** çıktı. Düzeltme: `setNonBlocking` artık `pub`, HTTP/TLS
  bağlantı fd'si `accept()` ANINDA (`setTcpNodelay`nin YANINDA) TEK
  SEFER ayarlanıyor, `nonBlockingRead`/`Write`den ÇIKARILDI; YENİ
  `nonBlockingReadOnce` yardımcısı 6 tek-seferlik self-pipe sitesini
  (http_client/thread_bridge/pool_bridge×3/process) telafi ediyor;
  `ThreadChannel`e (çoklu-kez okunabilen uyandırma fd'leri İçİn) 2 yeni
  fd-başına "zaten ayarlandı" bayrağı eklendi. **Bulunan VE düzeltilen
  bir GERÇEK regresyon (İlk denemede)**: `bindAndListen()`de dinleme
  fd'sini KOŞULSUZ non-blocking yapmak `http_server.zig`nin `blockingAccept`
  (fiber-siz senkron) yolunu KIRDI (4 test GERÇEKTEN askıya düştü, `zig
  build noxrt-test --test-timeout` İLE YAKALANIP `blockingAccept`nin
  `EAGAIN`i HİÇ ele ALMADIĞI BULUNDU) — bu parça GERİ ALINIP `listen_fd`
  SADECE `nonBlockingAccept`/`nonBlockingAcceptWithTimeout`da (accept-
  döngüsü BAŞINA, istek BAŞINA DEĞİL — asıl kazancın kaynağı DEĞİLDİ)
  ayarlanmaya DEVAM EDİYOR. **Ölçülen sonuç**: `run_json_worker_sweep.sh`
  1/2/4-worker'ı ~150-160K'dan **~208K req/s**'e ÇIKARDI (8-worker'ın
  ZATEN olduğu, muhtemelen çekirdek-oversubscription kaynaklı ~201K
  tavanına YAKLAŞARAK) — script'in KENDİ PASS/FAIL eşiği bu YENİ, BENİGN
  "hepsi aynı donanım tavanına yakın" durumunu (eski %88 katastrofik
  inversiyondan FARKLI, ~%96.5 oranı) yanlış-pozitif İŞARETLEMESİN diye
  gevşetildi (bkz. script'in KENDİ güncellenmiş belge notu).

## [1.39.0]

### Düzeltildi
- **`RuntimeState`nin 9600 bayta (v1.26.6'da 120 bayt, ~80x) büyümesi
  düzeltildi — havuz-özgü durum lazy bir uzantıya taşındı.** v1.38.0'ın
  bulduğu, kapsam dışı bıraktığı mimari bulgunun takibi. `@sizeOf`/
  `std.atomic.cache_line` doğrudan ölçülerek kök neden kesinleştirildi:
  `pool_free_lists: [MAX_POOL_WORKERS]PoolFreeListRow` TEK BAŞINA
  büyümenin ~%85'iydi (`align(std.atomic.cache_line)` — 128 bayt macOS
  aarch64'te — her satırı, gerçek veri 80 bayt olmasına rağmen, 128 bayta
  yuvarlıyordu → 64×128=8192 bayt, havuzsuz bir programda BİLE gömülü).
  `runtime/alloc/asap.zig`ye YENİ, lazy tahsis edilen bir `PoolExtension`
  eklendi (`arena_pool`/`cycle_gc` İLE AYNI "opak tutamaç" deseni) —
  havuz-özgü TÜM durum (`pool_free_lists`/`globals_blocks`nin slot 1-63'ü
  + `pool_wake_fds`/`pool_scheduler_ptrs`/`pool_live_count`/vb.) BURAYA
  taşındı; `RuntimeState` SADECE slot 0 İçİn inline alanlar + `WorkerPool.
  create()` GERÇEKTEN çağrıldığında tahsis edilen bir `pool_ext` işaretçisi
  taşır. YENİ bulunan üçüncü bir TLV sıcak-yol sorunu (`nox_globals_get`/
  `nox_globals_set`, v1.38.0'ın `pool_ever_active` kısayolunun hiç
  uygulanmadığı bir yer) de AYNI turda düzeltildi. **Sonuç**: `@sizeOf
  (RuntimeState)` 9600 → 256 bayt (~%97 azalma), `zig build test`
  (Debug+ReleaseFast)/`stress-test`/`http-soak-test` HEPSİ temiz. **DÜRÜST
  bir olumsuz sonuç**: `list_release_overhead`/`oop_arc_churn`/`dict_
  bench`/`json_bench`nin interleaved ölçümü HİÇBİR ölçülebilir performans
  farkı GÖSTERMEDİ — v1.38.0'ın "büyüme önbellek-yerelliğini bozuyor gibi
  görünüyor" hipotezi bu benchmark'larda YANLIŞ çıktı (tek bir ~9.6KB
  tahsis modern CPU önbelleğiyle rekabet etmiyor). `list_release_overhead`nin
  kalan farkının GERÇEK kaynağı HÂLÂ bilinmiyor — YİNE DE `RuntimeState`nin
  küçülmesi GERÇEK, doğrulanmış bir mimari/bellek-ayak-izi kazancı
  olduğundan (özellikle çok sayıda `RuntimeState` örneği yaratan
  senaryolarda) kullanıcı KARARIYLA tutuldu.

## [1.38.0]

### Düzeltildi
- **`nox_exception_pending`/`nox_rc_alloc`/`nox_rc_free_payload`'ın
  gereksiz `threadlocal` (TLV) erişimi düzeltildi — iki GERÇEK, hiç
  fark edilmemiş performans regresyonu kapatıldı.** Derin bir bottleneck
  incelemesi (kullanıcının isteğiyle) `benchmarks/RESULTS.md`nin EN SON
  taban çizgisi (`noxc 1.26.6`) İLE ŞU ANKİ arasında `zig build bench`i
  YENİDEN çalıştırıp KARŞILAŞTIRDI VE M:N zamanlayıcı işinin (Faz MN.1-
  MN.10, v1.27.0-v1.29.0) SADECE "stdout doğru mu" diye doğrulanmış,
  ZAMANLAMA HİÇ yeniden ölçülmemiş olduğunu bulup İKİ regresyonu `git
  worktree` İLE KESİN bisect etti: `exception_check_overhead` (450.9ms
  → ~617ms, +37%) VE `list_release_overhead` (158.8ms → ~230ms, +29%).
  Kök neden HER İKİSİNDE de AYNI: `bridge.currentFiber()`/`asap.
  currentWorkerSlot()` (macOS'ta TLV thunk'ına GERÇEK bir `blr` ÜRETEN
  threadlocal'lar) HER TEK çağrıda YENİDEN hesaplanıyordu — HÂLBUKİ
  `async`/`spawn`/`Task`/`Channel`/`pool_run` HİÇ KULLANMAYAN (EZİCİ
  ÇOĞUNLUKTAKİ) programlarda bu HER ZAMAN `null`/`0`e çözülüyordu. `asap.
  RuntimeState`ya İKİ yeni bayrak (`fiber_ever_active`, `pool_ever_active`
  — HER İKİSİ de doğru, TEK bir NOKTADA işaretlenip program-sırası
  garantisiyle thread-güvenli) eklenip `pendingException()`/`nox_rc_
  alloc`/`nox_rc_free_payload` BU bayrakları kontrol ederek pahalı
  threadlocal erişimini ATLIYOR. **Break→red→fix ritüeli**: `pool_ever_
  active` GEÇİCİ olarak devre dışı bırakılınca `worker_pool.zig`nin
  4-worker eş zamanlı testi GERÇEK bir SIGBUS İLE ÇÖKTÜ (kontrolün
  load-bearing olduğu kanıtlandı); geri eklenince TAMAMEN yeşil.
  **Bulunan bir optimizasyon tuzağı**: `nox_rc_alloc`/`free_payload`de
  BASİT bir üçlü ifade (`if (cond) call() else 0`) YAZILDIĞINDA, `otool
  -tV` İLE derlenmiş binary OKUNDUĞUNDA LLVM'in çağrıyı dallanmadan ÖNCE
  KOŞULSUZ yürütüp SONUCU bir `csel` İLE seçtiği (if-dönüştürme) GÖZLEMLENDİ
  — düzeltmeyi TAMAMEN etkisiz kılıyordu; `@branchHint(.unlikely)` İLE
  GERÇEK bir dallanma zorlanıp `otool -tV` İLE TEKRAR doğrulandı.
  **Sonuçlar** (aynı makinede arka arkaya ölçüldü): `exception_check_
  overhead` ~617ms → ~549-580ms (GERÇEK, yapısal bir kazanım); `async_
  task_churn` ~59ms → ~44-46ms (MN.1/2'nin payı GERİ alındı, v1.29.12'nin
  GEREKLİ Task/Channel atomik-refcount maliyeti KORUNDU — bu KASITLI
  bir regresyon, düzeltilmedi); `list_release_overhead` ~230ms → ~211-
  216ms (TLV maliyeti YAPISAL olarak KANITLANDI/kaldırıldı — `nm`/`sample`
  İLE alloc/free'nin KENDİ payının %59'dan %13'e DÜŞTÜĞÜ doğrulandı —
  AMA toplam süre BEKLENDİĞİ kadar toparlanmadı: AYRI bir araştırma
  `RuntimeState`in `v1.26.6`den bugüne **120 bayttan 9600 bayta (80x)**
  büyüdüğünü buldu — M:N havuzunun 64-worker'a kadar sabit-boyutlu
  durumunu (deque'ler/free-list'ler/STW bariyerleri) HER `RuntimeState`e
  gömmesi, TEK-worker'lı bir programda bile `pool_free_lists`e erişimin
  önbellek-yerelliğini bozuyor — bu YAPISAL, DAHA BÜYÜK bir mimari
  bulgu, AYRI bir görev olarak KAPSAM DIŞI bırakıldı.

## [1.37.0]

### Eklendi
- **Aether + Nyx'i GERÇEK harici entegrasyon fixture'ı olarak compiler
  CI'ye ekleme.** Harici bir kod incelemesinin listesinin 4. maddesi.
  O ANA kadar noxc'nin dil/stdlib regresyonları SADECE `tests/golden/`nin
  sentetik fixture'larıyla yakalanıyordu — GERÇEK, büyük, üretim-benzeri
  bir Nox programının noxc'nin YENİ bir sürümüyle hâlâ doğru çalıştığını
  kanıtlayan hiçbir mekanizma yoktu. Kullanıcının KENDİ yazdığı iki GERÇEK
  Nox web-framework'ü (`github.com/mburakmmm/aether`, 20 test dosyası;
  `github.com/mburakmmm/nyx`, 45 test dosyası) KENDİ CI'lerinde ZATEN
  kullandığı "yerel checkout'a işaret ettirme" hilesini (`compiler/pkg/
  fetch.zig`nin ZATEN desteklediği mutlak-yerel-yol `repo` alanı) temel
  alarak, YENİ, AYRI `.github/workflows/external-fixtures.yml` HER push/
  PR'da kaynaktan derlenen GÜNCEL noxc'yi framework'lerin KENDİ PINNED
  sürümüne (Aether v0.6.5, Nyx v0.17.0) karşı `noxc fetch` + `tests/*.nox`
  döngüsüyle çalıştırıyor. CI'ye eklemeden önce yerel olarak doğrulandı:
  65/65 test (20+45) sıfır regresyonla geçti — v1.29.8/v1.29.11'den
  v1.36.0'a kadarki tüm ara sürümlerin geriye-dönük uyumlu kaldığının
  olumlu bir kanıtı.

## [1.36.0]

### Eklendi
- **`nox.http.serve_multicore`/`serve_tls` İçİn gecelik soak (sürdürülebilir
  yük) testi.** Harici bir kod incelemesinin işaret ettiği, v1.31.0'ın
  KENDİ CHANGELOG'unun da "kapsam dışı, ayrı ve daha büyük bir görev" diye
  bıraktığı boşluk: mevcut TEK "çoklu istemci" testi (`http_serve_
  multicore_pool_golden_test.zig`) yalnızca 2 eşzamanlı istemci (tek
  istek) VEYA 20 ardışık (eşzamanlı DEĞİL) istek yapıyordu — gerçek bir
  sürdürülebilir yük testi yoktu. YENİ `tests/compat/http_soak_test.zig`,
  `benchmarks/http_bench.zig`nin (gerçek `zig-out/bin/noxc`yi bir alt
  süreç olarak çağıran, checker/codegen iç API'lerine bağımlı OLMAYAN)
  desenini temel alarak, 8 sürekli istemci iş parçacığının hem düz HTTP
  (`serve_multicore`) hem TLS (`serve_tls`, gerçek `std.crypto.tls.Client`
  el sıkışmasıyla) üzerinden `NOX_SOAK_SECONDS` ortam değişkeniyle
  yapılandırılabilir bir süre boyunca kesintisiz istek attığı YENİ, opt-in
  bir `zig build http-soak-test` adımı ekliyor (v1.31.0'ın `stress-test`iyle
  AYNI "test adımının parçası DEĞİL" ilkesi). **Geliştirme SIRASINDA İKİ
  GERÇEK bug bulunup düzeltildi**: (1) `std.Io.Clock.Timestamp.now(io,
  .awake)`, manuel `std.Thread.spawn` İLE başlatılan bir iş parçacığından
  çağrıldığında GÜVENİLİR DEĞİL — süre-sınırı döngüsü HİÇ SONLANMADI (canlı
  test SIRASINDA 17+ dakika boyunca GERÇEK, başarılı istekler atarak
  sonsuza dek çalıştığı GÖZLEMLENDİ) — düzeltme: worker iş parçacıkları
  İçİndeki süre ölçümü `Io`dan bağımsız, ham `clock_gettime(CLOCK.
  MONOTONIC)` İLE yapılıyor. (2) `std.Io.net.IpAddress.connect`, TEK-
  seferlik kullanımda güvenilir olsa da SÜRDÜRÜLEBİLİR/yoğun tekrarlı
  kullanım altında (8 iş parçacığı, saniyede yüzlerce bağlantı) ARALIKLI
  `error.Unexpected` (EINVAL) üretti — düzeltme: TLS soak'ın bağlantısı ham
  `std.c.connect` İLE kurulup `std.Io.File`e sarılıyor (`std.crypto.tls.
  Client`ın ihtiyaç duyduğu Reader/Writer arayüzü, sorunlu `Io.net`
  bağlantı-kurma yolundan tamamen kaçınarak elde ediliyor) — standalone bir
  reprodüksiyonla 2000+ başarılı istekte sıfır hata doğrulandı. `.github/
  workflows/stress.yml`ye (worker-pool stresinin AKSİNE GERÇEKTEN `qbe`+`cc`
  gerektiren) AYRI bir `http-soak` işi eklendi (300 saniye/platform).

## [1.35.0]

### Düzeltildi
- **Bilinen iki test flake'i kalıcı olarak düzeltildi.** Harici bir kod
  incelemesinin "fuzzing'deki bilinen flake/crash kalıntılarını sıfırla"
  önerisinin karşılığı. **Flake 1** (`fiber.zig`nin guard-page testi,
  "Faz MN.8, Bulgu C"): SABİT bir `/tmp` yolu (`/tmp/nox_guard_overflow_
  repro_bin`) kullanıyordu — AMA bu test (`fiber.zig`nin transitively
  import edilmesi yüzünden) `scheduler_test`/`channel_test`/`io_test`/
  `noxrt_test`de de AYRI AYRI çalışıyor VE `zig build test` bu ikilileri
  PARALEL çalıştırıyor — BİRDEN FAZLA sürecin AYNI ANDA AYNI dosyaya
  derleme ÇIKTISI yazıp AYNI dosyayı çalıştırmaya çalışması GERÇEK bir
  TOCTOU yarışı yaratıp aralıklı `processSpawnPosix` başarısızlıklarına
  yol açıyordu. `tests/cli/install_test.zig`/`tests/compat/http_serve_
  golden_test.zig`nin ZATEN kurulu `std.testing.tmpDir` konvansiyonuna
  geçildi — çakışma YAPISAL olarak imkansız hale geldi. **Flake 2**
  (`worker_pool.zig`nin 20-turlu Task-await stres testi): `stolen_
  waiter_count > 0` iddiası HER turdan BAĞIMSIZ olarak (20 KEZ) kontrol
  ediliyordu — zorlama mekanizması (sabit 8 `yield()`) iyi niyetli ama
  garantisiz olduğundan, küçük bir tur-başına başarısızlık olasılığı 20
  kez bileşip aralıklı GERÇEK test başarısızlıklarına yol açıyordu.
  Sayaç artık 20 tur BOYUNCA birikiyor, iddia döngü bittikten SONRA TEK
  sefer kontrol ediliyor (kardeş `ChanStressCtx` testinin hiç çalma
  iddia etmemesiyle AYNI ilke — testin KENDİ amacı, HER turun kendi
  başına yeniden kanıtlamasını değil, tüm çalışma boyunca EN AZ bir
  kanıtı gerektiriyor). Doğrulama: `async-rt-test` 5+ ardışık temiz
  koşu, `worker-pool-test` 10 ardışık temiz koşu, VE `NOX_STRESS_
  ROUNDS=500 zig build stress-test` (v1.31.0'ın stres altyapısı
  yeniden kullanılarak) temiz geçti. Tam `zig build test`: birden çok
  ardışık koşuda SIFIR flake.

## [1.34.0]

### Eklendi
- **`SpawnSharedMutation` kontrolü ARTIK arbitrer derinlikte iç içe alan
  erişimlerini de yakalıyor.** Harici bir kod incelemesinin ("hangi
  gerçek problem henüz açık?" sorusuna verdiği yanıt) işaret ettiği
  gerçek bir sınır: v1.30.0'ın kontrolü BİLİNÇLİ olarak SADECE doğrudan
  parametre mutasyonunu yakalıyordu — `b: Box` (paylaşılan, `Box.xs:
  list[int]`) İçİn `b.xs[0] = 99` daha ÖNCE DERLENİYORDU (hata YOK).
  Kök neden basitti: checker'ın ZATEN sahip olduğu bilgi (`ClassInfo.
  fields`, her sınıf alanının ÇÖZÜLMÜŞ tipini TUTAR) tek seviye ötesinde
  KULLANILMIYORDU. YENİ `resolveExprSharedType`, `b`/`b.xs`/`b.inner.xs`
  GİBİ HERHANGİ derinlikteki bir attribute zincirini ÖZYİNELEMELİ olarak
  çözüp hangi paylaşılan parametreden türediğini VE son tipini bulur —
  YENİ bir çağrı-grafiği/whole-program analizi DEĞİL, SADECE mevcut
  alan-tipi haritasının arbitrer derinlikte kullanılması. 2 yeni golden
  test (tek seviye — ARTIK yakalanıyor — ve iki seviyeli sınıf zinciri)
  eklendi; MEVCUT `ok_spawn_shared_transitive_field_not_caught` fixture'ı
  `err_spawn_shared_nested_field_mutation` olarak yeniden adlandırılıp
  davranışı (BİLİNÇLİ olarak) tersine çevrildi. **Kapsam DIŞI KALMAYA
  DEVAM EDİYOR** (AYRI, DAHA BÜYÜK bir görev): bir helper fonksiyonun
  ÇAĞRILMASI YOLUYLA transitif mutasyon (`worker(xs)` → `helper(xs)` →
  `xs.append()`) — bunu KANITLAYAN YENİ bir "hâlâ yakalanmıyor" testi de
  eklendi (çağrı-grafiği analizi checker.zig'de HİÇ YOK). Tam `zig build
  test`: TÜM MEVCUT fixture'lar (bir tanesi HARİÇ — KASITLI davranış
  değişikliği) DEĞİŞMEDEN geçti.

## [1.33.0]

### Eklendi
- **`noxc refresh [paket]` — GLOBAL kurulu paketleri güncelleme komutu.**
  Kullanıcı gerçek bir eksikliği fark etti: `noxc upgrade` sadece `noxc`nin
  KENDİ derleyici ikilisini günceller, `noxc install <paket>` İLE GLOBAL
  kurulmuş bir Nox paketini (ör. "nyx") güncellemek İçİn AYRI, keşfedilebilir
  bir komut YOKTU. Araştırma `noxc install <paket>`in ZATEN HER
  çalıştırıldığında uzak repoyu YENİDEN klonlayıp (`fetchToCache` HER ZAMAN
  gerçek bir `git clone` yapar, önbellek SADECE çözümlenen SHA ZATEN
  yerelse devreye girer), YENİDEN derleyip, `installed.json`daki kaydı
  `upsert` İLE güncellediğini gösterdi — GERÇEK eksik SADECE bunun İçİn
  AYRI bir komut VE TÜM kurulu paketleri TEK seferde güncelleyen bir yol
  olmamasıydı. `update`/`upgrade` isimleri ZATEN BAŞKA, İLİŞKİSİZ
  özellikler tarafından kullanıldığından (`update`: proje-seviyesi
  `nox.json`/`nox.lock` bağımlılık kilidi; `upgrade`: `noxc`nin KENDİ
  ikilisi) YENİ bir fiil, `refresh`, seçildi. `cmdInstall`nin fetch+derle+
  yerleştir+kayıt gövdesi paylaşılan bir `installOrUpdatePackage`
  fonksiyonuna çıkarıldı; `noxc refresh <paket>` SADECE onu, `noxc refresh`
  (argümansız) `installed.json`daki TÜM paketleri günceller — toplu modda
  TEK bir paketin başarısızlığı DİĞERLERİNİ ENGELLEMEZ (pip/cargo/apt'nin
  konvansiyonuyla TUTARLI), sadece SONUNDA (en az bir başarısızlık VARSA)
  `exit(1)` yapılır. 4 yeni uçtan uca test (`tests/cli/install_test.zig`):
  tekli güncelleme (yeni bir commit'in GERÇEKTEN çekildiğini kanıtlar),
  toplu güncelleme, kurulu-olmayan bir ad İçİn temiz hata, VE toplu modda
  kısmi başarısızlığın diğer paketi ENGELLEMEDİĞİ. Mevcut `install`/
  `uninstall`/`list` testleri DEĞİŞMEDEN geçti.

## [1.32.1]

### Dokümantasyon
- **"FF.8 — modül sistemi mimarisi" değerlendirildi ve KOD DEĞİŞİKLİĞİ
  OLMADAN ertelendi.** Kullanıcının 4 maddelik stabilite turunun son
  maddesi — eski bir bellek notu whole-program AST birleştirmesi + isim
  mangling YERİNE bir "ModuleIR"/ayrı sembol tabloları öneriyordu.
  Derinlemesine araştırma "ModuleIR"nin bu depoda HİÇ VAR OLMAYAN,
  tamamen dışarıdan gelen bir hedef OLDUĞUNU gösterdi. Mevcut mekanizmanın
  İKİ GERÇEK, kayıtlı çakışma tuzağı (`nox_path_join` isim çakışması —
  Faz EE.1; 3.-taraf paket adı çakışması — Faz P.7) HER İKİSİ de ZATEN
  ÇÖZÜLMÜŞ (biri sert `DuplicateDefinition` hatası + isimlendirme
  kuralıyla, diğeri ZATEN var olan bir alias-benzersizliği değişmeziyle).
  GERÇEKTEN açık kalan TEK sınırlama, birden çok dosyadan derlenen bir
  programda DWARF hata-ayıklama bilgisinin yanlış dosyayı göstermesi
  (satır DOĞRU, dosya YANLIŞ) — çökme/veri-bozulması ÜRETMEYEN, saf bir
  geliştirici-deneyimi kozmetiği. Tam bir ModuleIR yeniden yazımı
  `checker.zig`de 56, `codegen_qbe/*`de 85 çağrı sitesini AYNI ANDA
  değiştirmeyi gerektirir — hiçbir somut hatayı çözmeden, projenin
  KENDİ istikrar hedefiyle DOĞRUDAN çelişen bir blast radius. Kullanıcıya
  sunulup "tam yeniden yazımı ATLA" kararı ONAYLANDI — bulgular
  `nox-teknik-spesifikasyon.md` §3.99'a kalıcı olarak belgelendi. Kod
  DEĞİŞİKLİĞİ YOK.

## [1.32.0]

### Değiştirildi
- **Checker-taraflı intrinsics registry konsolidasyonu + GERÇEK bir alias-
  uyuşmazlığı bug'ının düzeltilmesi.** Eski bir yol haritası notu ("FF.7 —
  intrinsics registry") `checker.zig`/`codegen_qbe`ye dağılmış `nox.http.
  serve`/`nox.thread.start` gibi stdlib "intrinsic" çağrılarının özel-durum
  dispatch'ini merkezi bir tabloya toplamayı öneriyordu. Araştırma bunun
  codegen tarafının ZATEN Faz P1.6'da yapıldığını gösterdi (`async_thread.
  zig`nin `IntrinsicKind`/`intrinsic_table`/`matchIntrinsicKind`ü) — SADECE
  checker tarafı (9 fonksiyon, `matchesNoxHttpCall` + `tryResolveThreadSpawnCall`/
  `tryResolvePoolRunCall`nin İÇİNE AYRI AYRI inline edilmiş İKİ KOPYA eşleştirme
  algoritması, `checkCall`nin `.attribute` kolunda 14 sıralı if-çağrısı) hiç
  bu geçişi yapmamıştı. **Ayrıca araştırma SIRASINDA GERÇEK, ayrı bir bug
  bulundu**: checker'ın eşleştirmesi (`substituteAlias` üzerinden) modül
  takma adlarını (`import nox.http as h; h.serve(...)`) kabul ediyordu, AMA
  codegen'in KENDİ eşleştiricisi (`matchesNoxAttr`) SAF yapısal — callee'nin
  kelimesi kelimesine `nox.<modül>.<ad>` olmasını şart koşuyor, takma ad
  farkındalığı YOK. Sonuç: takma-adlı bir `serve` çağrısı checker'dan
  GEÇERdi ama codegen'de sıradan bir metod çağrısı sanılıp yanlış/çökme ile
  sonuçlanırdı. Düzeltme: checker'a codegen'in ZATEN kanıtlanmış `IntrinsicKind`/
  `intrinsic_table`/`matchIntrinsicKind` şeklinin KENDİ, bağımsız bir kopyası
  eklendi (checker→codegen import'u `decorators.zig`nin checker'ı ZATEN
  import etmesi yüzünden gerçek bir döngüsel bağımlılık olurdu — paylaşılamaz,
  yapısal bir benzerlik olarak taşındı); 3 kopya eşleştirme algoritması TEK
  bir `matchesNoxAttrCall`e birleşti; `checkCall`nin 14 sıralı dispatch'i TEK
  bir sınıflandırma + switch'e indirgendi; VE eşleşen bir çağrının callee'si
  (takma ad ne olursa olsun) codegen'in HER ZAMAN tanıyacağı kanonik
  `nox.<modül>.<ad>` şekline YENİDEN YAZILIYOR (`tryResolveQualifiedCall`in
  ZATEN kullandığı AST-yeniden-yazma desenini izleyerek). Yeni bir uçtan uca
  golden test (`http_serve_golden_test.zig`) `import nox.http as h; h.serve(...)`
  desenini GERÇEKTEN derleyip çalıştırıp doğru yanıt aldığını kanıtlıyor. Tam
  `zig build test`: TÜM MEVCUT http/thread intrinsic testleri DEĞİŞMEDEN
  geçti (SAF bir iç-yeniden-düzenleme + bir davranış düzeltmesi, codegen'in
  KENDİSİNE dokunulmadı).

## [1.31.0]

### Eklendi
- **Eşzamanlılık stres-test altyapısı: opt-in `zig build stress-test` +
  gecelik CI cron işi.** Bu oturumun (ve önceki oturumların) M:N
  zamanlayıcı/async runtime'ında bulduğu HER GERÇEK veri yarışı
  (`Task.detached` yarışı, `Channel`/`Task`ın sarkan-işaretçi SIGSEGV'i,
  work-stealing livelock'ları, ECONNRESET çökmesi, fiber-bağlamlı
  segfault-döngüsü riski) AD-HOC bir yöntemle bulunmuştu (kullanıcının
  KENDİ `wrk` yük testi, harici bir ChatGPT incelemesi, ya da manuel
  `lldb` reprodüksiyonları) — HİÇBİRİ `zig build test`in KENDİ, HER
  push'ta çalışan hızlı test paketinden yakalanmamıştı VE olamazdı da:
  `runtime/async_rt/worker_pool.zig`nin KENDİ, kanıtlanmış "çapraz-worker
  çalma"yı zorlayan İKİ 20-tekrarlı stres testi (Channel/Task `await_()`)
  ZATEN VAR VE doğru race'i tetikleme mekanizmasını (TÜM görevleri worker
  0'ın deque'ine PUSH edip kardeşlerin ÇALMASINI beklemek) kanıtlamış
  durumdaydı — ama SABİT 20 tur, HER push'ta Debug+ReleaseFast İKİ KEZ
  çalıştığından, MAKUL bir CI süresi İçİn tur sayısı DÜŞÜK tutulmak
  ZORUNDAYDI. Düzeltme: bu İKİ testin tur sayısı artık `NOX_STRESS_ROUNDS`
  ortam değişkeninden okunuyor (YENİ `stressRoundsFromEnv` yardımcısı —
  AYARLANMAMIŞSA ÖNCEKİ GİBİ TAM 20 tur, SIFIR davranış değişikliği).
  `build.zig`ye YENİ, GERÇEKTEN opt-in bir `stress-test` adımı eklendi
  (`-Dstress-rounds`, varsayılan 2000) — bu depodaki İLK "varsayılan
  `test` adımının PARÇASI OLMAYAN" test hedefi (`worker_pool_test`
  ikilisini YENİDEN kullanır, `test_step`e EKLENMEZ). YENİ `.github/
  workflows/stress.yml` bunu gecelik (cron `0 3 * * *`) + `workflow_
  dispatch` İLE, `ci.yml`nin AYNI 3-platform matrisinde (macOS/aarch64,
  Linux/x86-64, Linux/aarch64) 3000 tur İLE çalıştırıyor — `ci.yml`nin
  KENDİSİNE DOKUNULMADI (paylaşılan, ZATEN çalışan bir yapılandırmaya
  dokunmamak İçİn). Doğrulandı: varsayılan `zig build test`/`worker-pool-
  test` (20 tur) ~2.2s'de değişmeden geçiyor; `zig build stress-test
  -Dstress-rounds=500` ~5.0s'de (aynı ölçek, doğrudan ikili üzerinde de
  DOĞRULANDI) 43/43 test geçiyor — mekanizma uçtan uca çalışıyor.
  **Kapsam DIŞI (BİLİNÇLİ)**: diğer İKİ stres testi (ARC/globals
  izolasyonu, STW bariyeri) BÜYÜTÜLMEDİ — tur sayıları BİLİNÇLİ,
  belgelenmiş bir eşik-güvenliği sınırına (`nox_cycle_possible_root`un
  paylaşılan sayacı 700) bağlı, ayrı bir yeniden tasarım gerektirir.
  `nox.http.serve`/`serve_multicore`e özgü bir HTTP-seviyesi soak testi
  de AYRI bir görev olarak bırakıldı.

## [1.30.1]

### Düzeltildi
- **`checker.zig`nin `checkExpr`/`checkBinary` özyinelemesi artık derinlik
  sınırlı — GERÇEK, pre-existing bir yığın-taşması SIGABRT'ı düzeltildi.**
  `tests/fuzz/lexer_parser_checker_fuzz.zig`nin "cok uzun tek satirlik
  ifade" regresyon testi (2000 kez `+ 1` eklenen TEK satırlık bir ifade,
  `x: int = 1 + 1 + 1 + ... + 1`) Debug modda GERÇEK bir SIGABRT'la
  çöküyordu — TEMİZ `main` dalında da (bu düzeltmeden BAĞIMSIZ) aynen
  üretildiği doğrulandı. Kök neden: `parser.zig`nin GÜVENLİK bulgusu
  H-3 düzeltmesi (`enterRecursion`/`exitRecursion`/`MAX_EXPR_DEPTH=500`)
  YALNIZCA parantez İÇ İÇE geçmesini VE önek-operatör zincirlerini (`not
  not ...`, `- - ...`, `await await ...`, `spawn spawn ...`) kapsıyor —
  bunlar parser'da GERÇEKTEN özyineliyor. AMA ikili-operatör zincirleri
  (`parseOr`/`parseAnd`/.../`parseMulDiv`) YİNELEMELİ (`while`) döngülerle
  işleniyor — özyineleme derinliğini ARTIRMIYORLAR, ama YİNE DE N-derin
  (`1+1+1+...` İçİn 2000-derin) SOL-çarpık bir AST üretiyorlar. Parser'ın
  guard'ı bu YÜZDEN bu girdiyi HİÇ YAKALAMIYORDU — `checker.zig`nin
  `checkExpr` (HER `.binary` düğümünde İKİ KEZ özyineleyen `checkBinary`
  İLE) bu AST'yi GERÇEKTEN özyinelemeli geziyordu VE HİÇBİR derinlik
  sınırı YOKTU. Düzeltme: parser'ın KENDİ, ZATEN kanıtlanmış desenini
  (`enterRecursion`/`exitRecursion`/sabit `MAX_EXPR_DEPTH`/`defer`-tabanlı
  KENDİLİĞİNDEN sıfırlanma) `checker.zig`ye AYNEN taşıdım — AMA checker'ın
  ÖZYİNELEME şekli farklı OLDUĞUNDAN (HER AST düğümü GERÇEKTEN
  `checkExpr`den geçiyor), guard'ı TEK bir noktaya, `checkExpr`in
  KENDİSİNE koymak YETERLİ oldu (yeni `expr_depth` alanı + `MAX_EXPR_
  DEPTH=500` + `enterExprRecursion`/`exitExprRecursion` + YENİ bir
  `TooDeeplyNested` tanı kodu). Bu, switch'in HERHANGİ bir KOLUNA yerel
  değişken EKLEMEDİĞİNDEN, checker.zig'in KENDİ belgelediği "switch
  kolları AYNI çerçeveyi paylaşır" tuzağına da GİRMİYOR. `codegen_qbe/
  expr.zig`nin `genExpr`/`genBinary`si de AYNI şekle sahip VE guard'sız,
  AMA `main.zig`nin `cmdBuild`ı `checkModule` BAŞARISIZ olan bir AST'yi
  codegen'e HİÇ GEÇİRMEDİĞİNDEN, checker-taraflı guard PRATİKTE codegen'i
  de dolaylı olarak KORUYOR. 2 yeni typecheck golden test fixture'ı: biri
  `MAX_EXPR_DEPTH`i aşan bir ifadenin `TooDeeplyNested` İLE TEMİZ
  reddedildiğini, diğeri sınırın ÇOK ALTINDA (100 seviye) GERÇEKÇİ bir
  ifadenin ETKİLENMEDEN derlendiğini kanıtlıyor. Önceden ÇÖKEN fuzz testi
  ARTIK temiz geçiyor (`zig test ... --test-filter "cok uzun"`). Tam
  `zig build test`: TEK bilinen İLİŞKİSİZ `fiber.zig` "Bulgu C" flake'i
  HARİÇ temiz (`git stash` İLE clean `main`de de AYNEN üretildiği ayrıca
  doğrulandı — bu değişiklikten BAĞIMSIZ, önceden var olan bir kaynak-
  çekişmesi flake'i).

## [1.30.0]

### Eklendi
- **`list[T]`/`dict[K,V]`/`class`ın `spawn`-paylaşımlı, senkronizasyonsuz
  cross-worker MUTASYON riski artık DERLEME ZAMANINDA reddediliyor** —
  v1.29.12'nin CHANGELOG girdisinin BİLİNÇLİ olarak kapsam dışı bıraktığı
  problem. `list`/`dict`/`class` örnekleri `--release` (LLVM backend)
  altında bir `spawn` çağrısına argüman olarak GEÇİLEBİLİYORDU (`checker.
  zig`nin `isSpawnParamSafeType`i buna izin verir) AMA bu tiplerin
  `.append()`/`.pop()`/`.sort()`/`xs[i]=`/`d[k]=`/`obj.alan=` mutasyon
  operasyonlarının HİÇBİRİ senkronizasyon TAŞIMIYOR (ne kilit ne
  atomiklik) — İKİ ayrı fiber (M:N zamanlayıcının work-stealing'i
  yüzünden potansiyel olarak İKİ ayrı OS iş parçacığında) AYNI listeye/
  sözlüğe/nesneye EŞZAMANLI yazarsa bu GERÇEK bir veri yarışıydı (`list.
  append`in realloc'u SIRASINDA başka bir fiber'ın AYNI ANDA eski
  işaretçi üzerinden okuma/yazma yapması DAHİL bellek bozulması riski).
  Kullanıcıya çalışma-zamanı kilidi (dict+class İçİn ucuz, `list[T]`
  İçİn ABI göçü gerektirdiğinden AYRI bir tura ertelenecekti) VE derleme-
  zamanı reddi (sıfır çalışma-zamanı maliyeti, list/dict/class'ta TEK
  TİP, ABI DEĞİŞİKLİĞİ YOK) seçenekleri sunuldu — **derleme-zamanı
  reddi** seçildi (Nox'un KENDİ "Katman 1: Görünmez Borrow Checker"
  felsefesiyle TUTARLI). Yeni bir `checker.zig` pre-pass'ı
  (`collectSpawnTargets`) modülün TAMAMINI (TÜM iç içe kontrol-akışı
  gövdeleri, iç içe `def`ler, sınıf metodları DAHİL, METİNSEL sıradan
  BAĞIMSIZ) tarayıp HER `spawn f(...)` çağrısının hedef fonksiyon adını
  toplar; `checkFunctionBody` artık bir spawn-hedefi fonksiyonun
  `list`/`dict`/`class` tipli HER parametresi İçİn kendi gövdesini
  (`checkNoSpawnSharedMutation`) tarayıp DOĞRUDAN mutasyonu (transitif/
  iç içe erişim VE başka fonksiyonlara transitif çağrı-takibi BİLİNÇLİ
  olarak v1 kapsamı DIŞINDA — call-graph analizi YOK) yeni bir
  `SpawnSharedMutation` tanı koduyla reddediyor. 7 yeni typecheck golden
  test fixture'ı: 4 pozitif (list `.append()`, list `xs[i]=`, dict
  `d[k]=`, class `obj.alan=`), 1 metinsel-sıra-bağımsızlığı kanıtı (spawn
  çağrısı hedef fonksiyonun KENDİ tanımından ÖNCE yazılsa BİLE yakalanır),
  1 negatif kontrol (spawn-hedefi OLMAYAN sıradan fonksiyonların KENDİ
  list/dict/class parametrelerini mutasyona uğratması — ÇOK yaygın, GÜVENLİ
  mevcut davranış — ETKİLENMEDİĞİNİ kanıtlar), 1 kapsam-sınırı kanıtı
  (`b.xs[0]=` gibi transitif/iç-içe bir alan üzerinden mutasyon BİLİNÇLİ
  olarak yakalanmaz, derlenir). Bu tipler `isSpawnParamSafeType`nin
  `.qbe` dalında ZATEN spawn-parametresi olarak reddedildiğinden, yeni
  fixture'lar `Checker.backend = .llvm` ayarlayan YENİ bir `expectGoldenLlvm`
  test yardımcısı (`llvm_golden_test.zig`nin KENDİ `checker_state.backend
  = .llvm` deseniyle AYNI, ama SAF tip denetimi — kodgen/`clang` YOK)
  kullanır. `zig build test`: TÜM MEVCUT fixture'lar (spawn İçEREN
  HERHANGİ bir `codegen_cases`/`typecheck_cases` fixture'ı DAHİL)
  DEĞİŞMEDEN geçti — SAF bir EKLEME, hiçbir mevcut davranış değişmedi.

## [1.29.12]

### Düzeltildi
- **`Task[T]`/`Channel[T]`ye GERÇEK atomik referans sayımı eklendi —
  ChatGPT'nin M:N incelemesindeki İKİNCİ (v1.29.11'in kapsam dışı
  bıraktığı) bulgunun canlı bir SIGSEGV REPRODÜKSİYONUYLA doğrulanıp
  düzeltilmesi.** `Task[T]`/`Channel[T]` (`isHeapManaged`in DIŞINDA,
  ARC/refcount başlığı YOK) bir `spawn`e argüman olarak GEÇİLDİĞİNDE
  (checker HER İKİ backend'de de İZİN VERİR) SESSİZCE HİÇBİR retain
  OLMUYORDU — sahip kapsamı bittiğinde spawn edilen çocuk HENÜZ
  BAŞLAMAMIŞ/BİTMEMİŞ olsa BİLE `nox_channel_destroy`/`nox_async_destroy_
  task` KOŞULSUZ (Task İçİn v1.29.11'in `state`-protokolü ÜZERİNDEN)
  serbest bırakıyordu. **`Channel[T]` İçİn GERÇEK bir SIGSEGV canlı olarak
  üretilip `lldb` İLE DOĞRULANDI**: bir sahip, `Channel`i BAŞKA bir spawn
  edilen fonksiyona geçirip HENÜZ o fonksiyon HİÇ ÇALIŞMADAN kendi kapsamı
  bitince, çocuk fiber DAHA SONRA `.recv()` çağırdığında `self.mutex.
  lock()` SERBEST BIRAKILMIŞ belleğe erişip ÇÖKÜYORDU. **`Task[T]` İçİn
  DAHA SİNSİ, farklı bir sonuç bulundu**: v1.29.11'in `state`-protokolü
  ÇÖKMEYİ önlese BİLE, sahip erken `destroy()` çağırdığında `state`
  KOŞULSUZ `DETACHED`ye geçtiğinden, DAHA SONRA GERÇEKTEN `await_()`
  çağıran meşru bir tüketici `state`i `PENDING` BULAMAYIP
  `suspendCurrent()` HİÇ ÇAĞRILMADAN HENÜZ YAZILMAMIŞ (TANIMSIZ) `self.
  result`ı SESSİZCE döndürüyordu — ÇÖKME YOK ama SESSİZCE YANLIŞ VERİ.
  Düzeltme: `ThreadHandle`nin (`thread_bridge.zig`) ZATEN KANITLANMIŞ
  atomik-referans-sayacı desenini (AMA SABİT "2'den başlar" DEĞİL, `1`den
  başlayıp HER kopyada artan GERÇEK bir sayaç) `Task(T)`/`Channel(T)`ye
  ekledim; derleyicinin TEK retain-enjeksiyon noktasını (`ownership.zig`
  nin `retainIfAliasing`ı) VE `spawn`ın KENDİ kapanış-paketleme/açma
  kodunu (`async_thread.zig`nin `genSpawnExpr`/`genSpawnWrapper`ı) BACKEND-
  BAĞIMSIZ (list/class/dict'in `--release`e ÖZGÜ retain'inin AKSİNE)
  genişlettim. `nox_task_retain`/`nox_channel_retain` (YENİ) HER kopyada
  artırır; `nox_async_destroy_task`/`nox_channel_destroy` HER `destroy()`
  de azaltır — SADECE SON sahip (refcount SIFIRA İNDİĞİNDE) GERÇEK
  temizliği (v1.29.11'in `state`-protokolü/`Channel.deinit`) tetikler. Bir
  fiber'ın KENDİ payı YALNIZCA `.send()`/`.recv()`i TAMAMEN BİTİRDİKTEN
  SONRA azaltıldığından EK bir kilit GEREKMEZ (refcount 0'a inerken BAŞKA
  birinin AKTİF kullanımda olması YAPISAL olarak İMKANSIZ). Reprodüksiyon
  KENDİSİ YENİ bir golden teste dönüştürüldü (`channel_spawn_outlives_
  owner.nox`) VE `Task`in "sessiz çöp veri" senaryosunu doğrulayan YENİ
  bir birim testi eklendi (`scheduler.zig`). Tam `zig build test`: TEK
  bilinen İLİŞKİSİZ fuzz çökmesi HARİÇ temiz (848/849), IR-diff'in 3
  fixture'ı (`async_channel.nox`, `async_deadlock.nox`, `task_local_basic.
  nox` — HEPSİ Channel'ı spawn'a GEÇİRİYOR) BEKLENEN, İNCELENEN (yalnızca
  YENİ `nox_channel_retain`/`nox_channel_destroy` çağrıları EKLENMİŞ)
  şekilde DEĞİŞTİ, snapshot'ları YENİLENDİ. **Kapsam DIŞI (BİLİNÇLİ)**:
  `list`/`class`/`dict`nin `--release`e özgü, senkronizasyonsuz cross-
  worker MUTATION riski (bu Task/Channel HANDLE'ININ ömrüyle DEĞİL,
  İÇERİĞİN eşzamanlı DEĞİŞTİRİLMESİYLE İLGİLİ, tamamen AYRI bir problem)
  — AYRI bir görev.



### Düzeltildi
- **`Task[T].detached` veri yarışı, atomik `state` protokolüne taşındı —
  ChatGPT'nin M:N incelemesinde işaret ettiği bir bulgunun doğrulanıp
  düzeltilmesi.** `runtime/async_rt/scheduler.zig`nin `Task(T)` struct'ı
  tamamlanma durumu İçİn ZATEN doğru bir atomik `state` protokolü
  kullanıyordu (Faz MN.8, Bulgu B — `PENDING`/`COMPLETED`/bir `*Waiter`
  işaretçisi, CAS tabanlı) AMA `detached: bool` BU protokolün DIŞINDA,
  DÜZ, senkronize-OLMAYAN AYRI bir alandı — `nox_async_destroy_task`
  (`WorkerPool` GERÇEK `std.Thread.spawn` OS iş parçacıkları kullanır)
  onu BAŞKA bir OS iş parçacığında YAZARKEN, `entryTrampoline` BAŞKA bir
  OS iş parçacığında OKUYORDU. **Doğrulama SIRASINDA bulunan, incelemenin
  KENDİSİNİN GÖRMEDİĞİ daha ciddi bir ikinci sonuç**: `entryTrampoline`nin
  ESKİ `detached` dalı `self`i `state`e/waiter'a HİÇ BAKMADAN serbest
  bırakıyordu — `Task[T]` bir `spawn`e argüman olarak GEÇİLİP (`checker.
  zig`nin `isSpawnParamSafeType`i BUNU HER İKİ backend'de de İZİN VERİYOR)
  BAŞKA bir fiber ZATEN `await_()` İLE kendini waiter olarak KAYDETMİŞKEN
  sahip `destroy()` çağırırsa, waiter'ı UYANDIRMADAN `self`i serbest
  BIRAKIYORDU — waiter'ın fiber'ı SONSUZA KADAR askıda kalıyordu (Faz
  MN.8'in ÇÖZDÜĞÜ sınıftan bir kayıp-uyandırma, GERİ GELMİŞ). Düzeltme:
  `detached` AYRI bir alan OLARAK DEĞİL, `state`in ÜÇÜNCÜ bir değeri
  (`DETACHED`) olarak kodlandı — `nox_async_destroy_task`, `state`i
  `PENDING`den `DETACHED`ye TEK bir atomik CAS İLE geçirmeyi DENER; CAS
  SADECE HİÇBİR GERÇEK waiter HENÜZ KAYITLI DEĞİLKEN başarılı olur, bu
  YÜZDEN ZATEN KAYITLI bir waiter ARTIK ASLA çiğnenemez/sallandırılamaz.
  `thread_bridge.zig`deki BAYAT/YANLIŞ bir yorum ("Task.detached TEK bir
  OS iş parçacığında kooperatif ÇALIŞTIĞI İçİn güvenlidir") de düzeltildi
  — bu iddia v1.29.1'in `Waiter` düzeltmesi TARAFINDAN ZATEN yanlışlanmıştı.
  YENİ bir regresyon testiyle (`runtime/async_rt/scheduler.zig`) hem
  ZATEN KAYITLI bir waiter'ın CAS TARAFINDAN çiğnenmediği hem
  `entryTrampoline`nin görev tamamlandığında onu GERÇEKTEN uyandırdığı
  (ESKİ davranışta ASLA olmazdı) doğrulandı. Tam `zig build test`: TEK
  bilinen İLİŞKİSİZ fuzz çökmesi HARİÇ temiz (842/843), IR-diff DEĞİŞMEDİ.
  **Kapsam DIŞI (BİLİNÇLİ, AYRI bir tur gerektirir)**: `Channel[T]`nin
  `nox_channel_destroy`sı `detached`-BENZERİ BİR erteleme mekanizması BİLE
  TAŞIMIYOR (HER ZAMAN KOŞULSUZ serbest bırakıyor) — Task/Channel'ın TAM
  ARC-yönetimli OLMAMASININ (incelemenin "Task/Channel borrow lifetime"
  bulgusu) DAHA BÜYÜK, YAPISAL bir problemi, BU turun kapsamı DIŞINDA.



### Düzeltildi
- **v1.29.9'un ECONNRESET düzeltmesi SIRASINDA bulunan GENEL riskin
  KENDİSİ kapatıldı: `runtime/async_rt/io.zig`nin fiber-bağlamlı
  `nonBlocking*` fonksiyonlarında, ECONNRESET/EPIPE/ECONNABORTED AİLESİ
  DIŞINDA kalan HERHANGİ bir "beklenmeyen" errno'nun (Debug modunda,
  `zig build test`nin VARSAYILAN modu) HÂLÂ `posix.unexpectedErrno`nin
  segfault-döngüsü YOLUNA düşme riski VARDI.** v1.29.9'un doğrulama
  turunda bulunan kök nedenin (fiber'ın ÖZEL yığınında `std.debug.
  dumpCurrentStackTrace()`nin GERÇEK bir SEGFAULT + segfault-handler'ın
  KENDİSİ AYNI bozuk yolu TEKRAR çağırması) GENEL bir çözümü: yeni bir
  `fiberSafeUnexpectedErrno` yardımcı fonksiyonu, `io.zig`nin `.AGAIN`
  DIŞINDAKİ TÜM `else` dallarına (`nonBlockingAccept`/`WithTimeout`/
  `nonBlockingRead`/`WithTimeout`/`nonBlockingWrite` — TOPLAM 5 site)
  eklendi: AYNI hata numarasını (geliştirici tanısı İçİn hâlâ değerli)
  YAZDIRIR AMA `dumpCurrentStackTrace()`i ASLA çağırmaz. `http_server.
  zig`/`tls_server.zig`deki AYNI-görünümlü `posix.unexpectedErrno`
  çağrıları İNCELENİP GÜVENLİ olduğu doğrulandı — HEPSİ `scheduler ==
  null` (fiber-DIŞI, senkron/bloklayan yedek) DALINDA yaşıyor, normal OS
  iş parçacığı yığınında ÇALIŞIYORLAR (`io_reactor.zig`nin 7 çağrısı da
  AYNI gerekçeyle güvenli — `Scheduler.run()`nin KENDİ ana döngüsünden,
  fiber İÇİNDEN DEĞİL). Kapsam BİLİNÇLİ olarak SADECE GERÇEKTEN fiber-
  bağlamlı çağrı siteleriyle SINIRLI tutuldu. GERÇEK bir `EBADF` (kapalı
  fd'ye okuma) errno'sunu fiber bağlamında tetikleyen YENİ bir regresyon
  testiyle (`runtime/async_rt/io.zig`) askıya-düşme/panik OLMADAN `error.
  Unexpected`in GRACEFUL döndüğü doğrulandı. Tam `zig build test`: TEK
  bilinen İLİŞKİSİZ fuzz çökmesi HARİÇ temiz (837/838), IR-diff
  DEĞİŞMEDİ. (Not: `zig build`nin konsol çıktısında YENİ testin `stderr`e
  yazdığı tanı mesajı YÜZÜNDEN "failed command" GÖRÜNEBİLİR — bu, Zig'in
  `--listen=-` yapılandırılmış test protokolünün, GERÇEKTEN GEÇEN bir
  testin `stderr`e HERHANGİ bir metin yazmasına verdiği KOZMETİK bir
  tepkidir; GERÇEK süreç çıkış kodu VE `Build Summary`nin KENDİSİ 0/
  DEĞİŞMEMİŞ olarak DOĞRULANDI.)



### Düzeltildi
- **`nox.http.serve()` sunucuları, bir istemcinin TCP bağlantısını ANİDEN
  sıfırlamasıyla (`ECONNRESET` — `wrk` GİBİ yük-test araçlarının zaman
  aşımında/koşum sonunda RUTİN olarak yaptığı bir şey) ÇÖKEBİLİYORDU/
  ASKIYA DÜŞEBİLİYORDU.** `runtime/async_rt/io.zig`nin `nonBlockingRead`/
  `nonBlockingReadWithTimeout`/`nonBlockingWrite`/`nonBlockingAccept`(WithTimeout)
  fonksiyonlarının `errno` `switch`i `.AGAIN` DIŞINDAKİ HER ŞEYİ (ECONNRESET
  DAHİL — TAMAMEN NORMAL, BEKLENEN bir istemci davranışı) `posix.
  unexpectedErrno`nin "beklenmeyen hata" yoluna düşürüyordu. **Doğrulama
  SIRASINDA BULUNAN, ÇOK DAHA CİDDİ bir GERÇEK hata**: `posix.
  unexpectedErrno`nin çağırdığı `std.debug.dumpCurrentStackTrace()`, bir
  Nox FİBER'ının (ÖZEL, OS iş parçacığı yığınından FARKLI bir yığın
  üzerinde çalışan) bağlamından ÇAĞRILDIĞINDA Zig'in yerel unwind'ının
  fiber yığın düzenini ANLAMAMASI YÜZÜNDEN GERÇEK bir SEGFAULT'a yol
  açıyor, ARDINDAN o segfault'un KENDİ handler'ı AYNI bozuk unwind yolunu
  TEKRAR ÇAĞIRARAK süreci KALICI olarak ASKIYA düşürüyordu (doğrudan
  gözlemlendi: düzeltme geçici olarak GERİ ALINIP YENİ regresyon testi
  çalıştırıldığında). Yani BU, yalnızca gürültülü `stderr` çıktısı DEĞİL,
  `nox.http.serve()` KULLANAN HER programı ANİ bir istemci bağlantı
  sıfırlamasıyla ÇÖKERTEBİLECEK GERÇEK bir güvenilirlik açığıydı. Düzeltme:
  okuma tarafında `ECONNRESET`, EOF (`0`) İLE AYNI şekilde ele alınır
  (`FiberReader.stream`in MEVCUT `error.EndOfStream` yolu, `http_server.
  zig`de HİÇBİR değişiklik GEREKMEDEN devreye girer); yazma tarafında
  `ECONNRESET`/`EPIPE` Zig'in KENDİ idiomatik isimleriyle (`error.
  ConnectionResetByPeer`/`error.BrokenPipe`, `std.posix.read`/`std.Io.
  zig`İLE AYNI adlandırma) döner; `accept()`te olası `ECONNABORTED`
  (istemci, kuyruğa alınmış bir bağlantıyı işlenmeden İPTAL edebilir)
  dinleme soketini BOZMADAN sessizce TEKRAR denenir. GERÇEK bir TCP
  bağlantısını `SO_LINGER{onoff=1,linger=0}` İLE (RST üreten) kapatan YENİ
  bir regresyon testiyle (`runtime/async_rt/io.zig`) hem düzeltmenin
  çalıştığı hem zamanlayıcının/reaktörün RESET SONRASI da BAŞKA
  bağlantılara doğru hizmet vermeye devam ettiği kanıtlandı. Gerçek `wrk`
  yükü altında (5 ardışık koşum, koşum başına ~750 gerçek okuma hatası)
  sunucunun HİÇBİR çökme/askıya düşme/`stderr` çıktısı OLMADAN hayatta
  kaldığı doğrulandı.



### Düzeltildi
- **`nox.json.decode()`nin ASIL darboğazı bulunup düzeltildi: HER çağrıda
  taze `mmap`/`munmap` syscall çifti.** v1.29.7'nin "dürüst negatif sonuç"
  bulgusu üzerine `sample` (macOS) ile profil çıkarıldı — `nox_json_decode_
  raw`nin (`runtime/stdlib_shims/json.zig`) HER çağrıda `std.heap.
  ArenaAllocator.init(std.heap.page_allocator)` yapıp fonksiyon dönmeden
  `arena.deinit()` ile tamamen kapatması, TOPLAM maliyetin **~%62**sini
  (mmap ~%21 + munmap ~%41) oluşturuyordu — `std.heap.page_allocator`
  HİÇBİR önbellekleme yapmadığından, ayrıştırılan JSON'un boyutundan
  TAMAMEN BAĞIMSIZ olarak HER `decode()` çağrısı bir mmap+munmap syscall
  çifti ödüyordu (`runtime/alloc/lowlevel.zig`nin `nox_arena_create`/
  `nox_arena_destroy`sının Faz M.7'de ZATEN çözdüğü AYNI sorun — farklı
  bir arena için). Düzeltme: arena artık `threadlocal` olarak BİR KEZ
  oluşturulup Zig'in KENDİ `ArenaAllocator.reset(.retain_with_limit(64
  KB))`ı İLE YENİDEN kullanılıyor (mmap/munmap YOK, `nox_rc_alloc`/ARC'a
  HİÇ dokunmadığından `lowlevel.zig`nin Debug-modu kısıtlamasına GEREK
  YOK). **Ölçülen sonuç** (ReleaseFast): sıkı-döngü 300k `decode()` çağrısı
  84ms (ÖNCEDEN 522ms, **6.2x**); `wrk` echo-decode-only 225 670 req/s
  (ÖNCEDEN 137 589, **1.64x**) — `echo raw passthrough`a (239 513 req/s)
  olan yakınlık %57'den **%94**e çıktı. Tüm golden/IR-diff testleri
  değişmeden geçti (833/834, tek bilinen ilişkisiz fuzz çökmesi hariç).



### Değiştirildi
- **`nox.json.decode()`nin düğüm-başına derlenmiş Nox koduna geri dönmesi
  (dlsym + retain/predecrement dengeleme dansı) kaldırıldı — `JsonValue`
  örnekleri artık `class_id` çalışma-zamanında BİR KEZ (sabit kodlanmadan,
  ilk gerçek örneğin tag baytından) keşfedilip `buildPtrList`nin ZATEN
  kullandığı ilkeyle DOĞRUDAN Zig'de inşa ediliyor.** Kullanıcının Aether
  ping/echo tablosundaki ~2.3x farkın ("GET /ping ~207k, POST /echo ~91k
  req/s") araştırılması sırasında bulundu — saf `nox.http`+`nox.json` ile
  izole ölçüm, farkın body-okuma/`encode()`den DEĞİL `decode()`nin
  KENDİSİNDEN geldiğini gösterdi. **Dürüst sonuç:** hipotez ("düğüm-başına-
  Nox-çağrısı domine ediyor") `--release`de (ReleaseFast) ÖLÇÜLDÜĞÜNDE
  YANLIŞ ÇIKTI — kaldırılan çağrı+ARC-dengeleme zaten ucuzmuş (300k
  `decode()` çağrısı sıkı döngüde 534ms→522ms, ~%2; `wrk` echo-decode-only
  135 731→137 589 req/s, ~%1.4). `decode()`nin asıl maliyeti BAŞKA yerde
  (muhtemelen `std.json.parseFromSlice`nin KENDİSİ veya `dupeToNoxStr`nin
  string kopyalama maliyeti) — İKİSİ de BU değişiklikle DOKUNULMADI, AYRI
  bir araştırma/görev olarak devam ediyor. Bu değişiklik KENDİ BAŞINA
  zararsız bir sadeleştirme (daha az tahsis, daha az ARC işlemi, `nox.
  json`nin PUBLİK API'si/semantiği DEĞİŞMEDİ) — TÜM golden/IR-diff testleri
  değişmeden geçti (833/834, tek bilinen ilişkisiz fuzz çökmesi HARİÇ),
  YENİ bir tekrarlı-decode testiyle (`json_decode_repeated_calls.nox`)
  hem yavaş/keşif yolu hem hızlı yol sızıntısız doğrulandı.



### Düzeltildi
- **`nox.http.serve_tls`de GERÇEK, ÖNCEDEN VAR OLAN bir eşzamanlılık
  tehlikesi düzeltildi: `tls_server.zig`nin `threadlocal var tl_read_
  target`/`tl_write_source`u AYNI OS iş parçacığında İÇ İçe geçen İKİ
  FARKLI TLS bağlantı fiber'ı arasında karışabiliyordu.** Bu buffer
  işaretçileri, bir OpenSSL BIO callback İmzası (`SSL_read`/`SSL_write`
  DIŞARIDAN yalnızca `ssl`i alır, bir Zig closure'ı GEÇİREMEZ) İLE bir
  Zig arabelleği ARASINDAKİ farkı kapatmak İçİn `drive()`nin çağırdığı
  `op(conn.ssl)` fonksiyonlarına aktarılıyordu — VE modülün KENDİ belge
  notu bunu "her OS iş parçacığı kendi threadlocal kopyasına sahip
  olduğundan çapraz-iş-parçacığı veri yarışı OLUŞMAZ" diyerek
  GÜVENLİ ilan ediyordu. Bu iddia YALNIZCA çapraz-İŞ-PARÇACIĞI yarışını
  kapsıyordu — `drive()`nin `fillRbioOnce` → `rawSockRead` →
  `suspendForIoOrTimeout` çağrısı GERÇEK bir kooperatif yield noktasıdır;
  bir bağlantının fiber'ı ORADA askıdayken AYNI OS iş parçacığında
  zamanlanan BAŞKA bir TLS bağlantısı `tlsRead`/`tlsWrite` çağırırsa,
  PAYLAŞILAN threadlocal'ı EZERdi — ilk fiber uyandığında `op(conn.ssl)`
  KENDİ arabelleği YERİNE ikinci bağlantının (ÇOKTAN dönmüş, potansiyel
  olarak yığından serbest bırakılmış) arabelleğine okur/yazardı. Bu,
  `serve_multicore`nin M:N havuzuyla İLGİSİZ, TEK-worker `serve_tls()`
  DAHİL, BUGÜNE kadar var olan temel M:1 kooperatif fiber modelinde HER
  ZAMAN mevcut olan bir hataydı. Düzeltme: `tl_read_target`/`tl_write_
  source` threadlocal DEĞİŞKENLERİ kaldırıldı, YERİNE `TlsConn`nin
  KENDİSİNE `read_target`/`write_source` alanları eklendi (HER TLS
  bağlantısının ZATEN KENDİ `TlsConn`u vardır — `acceptHandshake`de
  tahsis edilir, `tlsShutdown`da serbest bırakılır — bu YÜZDEN paylaşım
  İMKANSIZDIR); `drive()`nin callback İmzası `*const fn (?*anyopaque)`
  (yalnızca `ssl`) yerine `*const fn (*TlsConn)` oldu. GERÇEK bir
  reprodüksiyon testiyle (`tests/compat/http_serve_tls_golden_test.zig`,
  "yavaş" istemcinin isteğini İKİ parçaya bölüp ARADA sunucunun `tlsRead`
  askıya alınmasını ZORLARKEN "hızlı" bir istemcinin AYRI bir bağlantı
  üzerinden TAM bir el sıkışma+istek/yanıt döngüsünü ARADA tamamladığı)
  DOĞRULANDI: eski koda GERİ ALINDIĞINDA test 3 denemeden BİRİNDE "yavaş"
  istemcinin yanıtının BOZULDUĞUNU (`resp:/slow` yerine BAŞKA bir içerik)
  YAKALADI; düzeltmeyle 20 ardışık çalıştırmada (12 + 8) TEMİZ.



### Düzeltildi
- **`nox.http.serve_multicore`nin `--release` (LLVM M:N havuzu) yolunda
  bağlantı fiber'ları ARTIK çapraz-worker ÇALINABİLİR** — v1.29.4'ün
  `SO_REUSEPORT` düzeltmesinin (her worker KENDİ bağımsız soketini açar)
  KENDİSİNİN yol açtığı, kullanıcının GERÇEK Aether çerçevesinde (routing+
  JSON dispatch maliyeti olan bir handler'da) DOĞRULANAN yeni bir
  darboğaz: `SO_REUSEPORT`nin kernel bağlantı-dağılım hash'i worker'lar
  ARASINDA dengesiz olabiliyordu, VE (ÖNCEDEN Faz MN.7b'de belgelenmiş)
  kabul edilen HER bağlantı fiber'ı `Scheduler.markReady()` İLE DOĞRUDAN
  kabul eden worker'ın KENDİ `ready` listesine ekleniyordu — Chase-Lev
  work-stealing deque'ine DEĞİL. Yani bir worker'a fazla bağlantı düşerse,
  O worker TÜM bu bağlantıları TEK BAŞINA işliyordu, hiçbir boşta kardeş
  YARDIM EDEMİYORDU. Saf/ucuz handler'larda (bare ping) görünmezdi;
  Aether'in GERÇEK dispatch maliyetinde 8-worker'ı 1-worker'DAN DAHA
  YAVAŞ yapan (~209k→~56k req/s, -%73) bir darboğaza dönüşüyordu — Aether
  bunu KENDİ tarafında `--release`de `serve_multicore`u hiç KULLANMAYARAK
  atlatmıştı. Düzeltme: bağlantı fiber'ları `Scheduler.spawn()`nin Task[T]
  fiber'ları İçİN ZATEN kullandığı AYNI "deque'e it, İLK-çalıştırmadan
  SONRA sabitlen" desenine taşındı — `Scheduler.ownDeque()` havuzsuz
  durumda (QBE'nin bağımsız worker'ları, tek-worker `nox.http.serve()`)
  `null` döndüğünden SIFIR davranış değişikliğiyle. Tek gerçek yan-etki:
  `ConnCtx.active_connections` (eşzamanlı-bağlantı sayacı) ARTIK atomik
  (`std.atomic.Value(usize)`) — ÖNCEDEN "aynı OS iş parçacığında çalışır"
  varsayımına dayanıyordu, bu bağlantı fiber'ları çalınabilir olunca
  ARTIK GEÇERSİZDİ. Kullanıcının GERÇEK Aether handler'ıyla, `serve_
  multicore`u DOĞRUDAN çağıran bir test harness'ıyla (Aether'in KENDİ
  atlatması BYPASS edilerek) 2 bağımsız ölçümde 8-worker'ın ARTIK HİÇBİR
  ZAMAN 1-worker'ın ALTINA düşmediği (+%6 İLA +%25 arası kazanç)
  DOĞRULANDI.

## [1.29.4]

### Düzeltildi
- **`nox.http.serve_multicore`nin PAYLAŞILAN TEK `accept()` fd'si (N
  worker'ın AYNI fd üzerinde thundering-herd `accept()`i), `SO_REUSEPORT`
  İLE worker-başına BAĞIMSIZ soketlere çevrildi** — kullanıcının "ping
  8 worker'da 1 worker'dan hâlâ yavaş" raporunun KÖK NEDENİ (`pool_free_
  lists` kilidi [v1.29.3] BUNU DÜZELTMEMİŞTİ, TAMAMEN AYRI bir OS-seviyesi
  darboğaz). Standalone bir C deneyiyle (bare kqueue + N pthread, SIFIR
  Nox kodu) KANITLANDI: paylaşılan fd 8 iş parçacığında 1'e göre %12
  YAVAŞ, `SO_REUSEPORT` İLE düz/hafif İYİLEŞME. HER worker ARTIK `nox_
  http_server_listen_multicore_worker(_tls)` İLE KENDİ BAĞIMSIZ soketini
  TAZE açıyor; `nox_http_listen_fd`nin KENDİSİ (`nox.http.listen()`nin
  KAMUYA AÇIK "birleştirilebilir ilkeller" API'si) DOKUNULMADAN kaldı.
- **YUKARIDAKİ değişikliğin doğrulanması SIRASINDA bulunan GERÇEK bir
  SO_REUSEPORT sınırlaması düzeltildi**: kernel'in bağlantı-dağılım
  hash'i, KÜÇÜK/SABİT `max_connections` (`serve_multicore`nin worker-
  başına eski sözleşmesi) İLE eşzamanlı bağlantıları TEK bir worker'ın
  soketine yönlendirebiliyordu — o worker KENDİ kotasını doldurup
  ÇIKARKEN, HİÇ bağlantı ALAMAYAN DİĞER worker `accept()`te SONSUZA
  KADAR bekliyordu (`http_serve_multicore_pool_golden_test.zig`
  GERÇEKTEN takılıyordu, standalone bir tekrar-üretimle DOĞRULANDI).
  Düzeltme: worker'lar arasında PAYLAŞILAN bir atomic bağlantı bütçesi
  (`SharedServeBudget`, TOPLAM = `max_connections × num_workers` —
  ESKİ "her worker KENDİ payını alır" semantiğini KORUR) + zaman
  aşımlı `accept()` (25ms) İLE periyodik yeniden-kontrol — kotayı hiç
  ALAMAYAN bir worker artık SONSUZA KADAR DEĞİL, EN FAZLA bir poll
  aralığı KADAR bekleyip TEMİZ çıkıyor. `max_connections<=0` (SINIRSIZ,
  GERÇEK üretim yolu) BU mekanizmayı HİÇ DEVREYE SOKMUYOR — SIFIR ek
  maliyet.
- **Doğrulama SIRASINDA bulunan, YUKARIDAKİLERDEN TAMAMEN BAĞIMSIZ 2
  GERÇEK regresyon**: (1) `genHttpServe`nin (düz `nox.http.serve(port,
  handle[, max_connections])`, `serve_multicore` DEĞİL) `nox_http_
  serve_raw` çağrısı YENİ 7-argümanlı imzaya GÜNCELLENMEMİŞTİ — 6
  argümanla çağrıldığından ABI KAYMASI oluşuyor, TÜM `nox.http.serve()`
  çağrıları (SINIRLI/SINIRSIZ FARK ETMEKSİZİN) ÇALIŞMA ANINDA SESSİZCE,
  HİÇBİR hata/çıktı VERMEDEN ANINDA dönüyordu (`http_serve_golden_test.
  zig`nin TÜM testleri GERÇEKTEN başarısız oldu, doğrudan bir tekrar-
  üretimle DOĞRULANDI: sunucu 0.1sn İçİNDE, hiçbir bağlantı kabul
  etmeden çıkış kodu 0 İLE dönüyordu). (2) `SharedServeBudget`/
  `MulticoreBoundedPayload`nin `state.allocator()` İLE tahsis edilip
  HİÇ serbest BIRAKILMAMASI, golden testlerin KENDİ DebugAllocator
  sızıntı-denetimini (stderr'e HİÇBİR ŞEY yazılmaması = sızıntı YOK)
  İHLAL EDİYORDU — "tek seferlik, küçük, kabul edilebilir sızıntı"
  varsayımı BU test disipliniyle ÇELİŞTİ; TÜM worker'lar (QBE: `nox_
  thread_join` döngüsü SONRASI; `--release`: `nox_pool_serve` SENKRON
  DÖNDÜKTEN SONRA) bitince BUNLARI GERÇEKTEN serbest bırakan `nox_http_
  free_shared_budget`/`nox_http_free_bounded_payload` eklendi.

## [1.29.3]

### Düzeltildi
- **Paylaşılan M:N havuzunda ARC küçük-nesne havuzunun (`pool_free_lists`)
  TEK GLOBAL kilidi, worker-slotlu, KİLİTSİZ bir tasarıma çevrildi** —
  Aether geliştirilirken gözlemlenip Nox'ta doğrulanan gerçek bir yük-
  altı darboğaz: `nox.json.decode`/`encode` gibi tahsis-yoğun bir HTTP
  handler'ı `--release` altında `wrk` İLE ölçüldüğünde, `8 worker`
  paylaşımlı havuzda `1 worker`DAN DAHA YAVAŞ çalışıyordu (~89k req/s vs
  ~101k req/s) — klasik bir global-kilit çekişmesi imzası. Kök neden:
  `RuntimeState.pool_free_lists`in (ARC'ın serbest-liste havuzu, 10 boyut
  sınıfı) TÜM worker'lar TARAFINDAN paylaşılan TEK bir `SpinLock` İLE
  korunması. Düzeltme: `RuntimeState.globals_blocks`nin (Faz MN.3b'de
  ZATEN kanıtlanmış) worker-slotlu, kilitsiz deseni AYNEN tekrar
  kullanıldı — HER worker `asap.currentWorkerSlot()` İLE KENDİ satırına
  erişir, kilit GEREKMEZ (`nox_rc_free_payload` HER ZAMAN referansı
  BIRAKAN fiber'ı ÇALIŞTIRAN OS iş parçacığında çalıştığından GÜVENLİDİR).
  Cache-line ping-pong'u ÖNLEMEK İçİn HER worker'ın satırı 64 bayta
  hizalandı (`PoolFreeListRow`). Ölçülen sonuç (AYNI makinede, düzeltme
  ÖNCESİ/SONRASI): 8-worker throughput'u ~%64 arttı (89k→147k req/s) VE
  8 worker artık 1 worker'ı ~%43 GEÇİYOR (tersine-dönüş TAMAMEN düzeldi).
  HTTP handler'ları senkron olduğundan (`async def` OLAMAZLAR) bu
  değişikliğin motive edici İş yükü İçİn (HTTP/JSON) hiçbir dengesiz-
  dağılım riski YOK; genel `spawn`/work-stealing İçİn kabul edilen,
  bilinçli bir v1 sınırlaması var (bkz. `asap.zig`nin `pool_free_lists`
  belge notu). SADECE `--release` (LLVM backend) dalını etkiler — QBE
  yolu (bayraksız `noxc build`) HİÇ paylaşılan `RuntimeState` KULLANMADIĞI
  İçİN gözlemsel olarak DEĞİŞMEDİ (IR-diff 204/0/3-atlandı KORUNDU).

## [1.29.2]

### İyileştirildi
- **Nox'un HTTP/M:N tavan hızını artıran 3 madde** — Aether çerçevesinin
  `PERF_GAPS.md` raporu analiz edilirken, Aether'e ÖZGÜ OLMAYAN, Nox'un
  KENDİ derleyici/runtime'ındaki gerçek darboğazlar tespit edilip
  düzeltildi:
  1. **`TCP_NODELAY`** — kabul edilen HER bağlantı soketine (`runtime/
     async_rt/io.zig`, `runtime/stdlib_shims/http_server.zig`) uygulanır
     hale getirildi (Nagle algoritması küçük JSON yanıtlarında gereksiz
     gecikme EKLİYORDU). Ölçüldü: `benchmarks/http_compare` c=30'da
     +%4.0, c=100'de +%15.1.
  2. **Header kopyalama döngüsünün atlanması** — `genHttpServeWrapper`nin
     DERLEME-ZAMANINDA ZATEN hesapladığı "handler `req.headers`e
     dokunuyor mu" bilgisi (`used_fields.headers`) ARTIK `nox_http_
     serve_raw`/`_ws_raw`e kadar taşınıyor — handler headers'a HİÇ
     dokunmuyorsa `connectionEntry`nin HER istekte ÇALIŞTIRDIĞI
     `iterateHeaders`+`dupeToNoxStr` (header başına 2 ARC tahsisi)
     döngüsü TAMAMEN atlanır.
  3. **`--release` altında `$main`in otomatik havuzu artık KÜÇÜK bir
     varsayılana (2 worker) düşer** — modül `nox.http.serve_multicore*`/
     `nox.thread.pool_run` HİÇ ÇAĞIRMIYORSA (YENİ, ayrı bir derleme-
     zamanı AST yürüyüşü, `moduleUsesMulticorePool`, İLE tespit edilir).
     `serve_multicore`/`pool_run` KULLANAN programlar HÂLÂ CPU çekirdek
     sayısı kadar worker ALIR (DEĞİŞMEDİ); `NOX_POOL_WORKERS` HER İKİ
     durumda da KOŞULSUZ ÖNCELİKLİDİR. Bilinçli ödünleşim: GERÇEK ağır
     paralel İş İçİn çıplak `spawn`/`nox.thread.start` KULLANAN AMA
     `serve_multicore`/`pool_run` ÇAĞIRMAYAN programlar artık SESSİZCE
     2 worker'a düşer — İSTENEN paralellik `NOX_POOL_WORKERS`İLE AÇIKÇA
     belirtilmelidir.

  Her 3 madde de `self.backend == .llvm` (`--release`) dalına SINIRLI —
  QBE yolu (bayraksız `noxc build`) BAYT-BİREBİR DEĞİŞMEDİ (IR-diff
  204/0/3-atlandı KORUNDU).

## [1.29.1]

### Düzeltildi
- **`Task[T]` çapraz-worker `await_()` yarışı** — harici bir teknik
  değerlendirmenin (ChatGPT) İŞARET ETTİĞİ, DOĞRUDAN kaynak okumasıyla
  BAĞIMSIZ olarak DOĞRULANMIŞ GERÇEK bir hata: `checker.zig` `Task[T]`yi
  bir `spawn`e argüman OLARAK ZATEN İZİN VERİYORDU (MN.9'dan ÖNCE de) —
  bir fiber KENDİ oluşturduğu bir `Task`ı BAŞKA bir spawn edilmiş
  fonksiyona geçirebilir, O fonksiyonun fiber'ı `--release` altında
  BAŞKA bir worker'a ÇALINABİLİR, VE `Task.await_()`/`entryTrampoline`
  ESKİDEN `self.scheduler`i (görev OLUŞTURULDUĞUNDA sabitlenen worker)
  kullanıyordu — `Channel[T]`nin MN.9.1'de düzeltilen AYNI hatası,
  `Task[T]` İçİN HİÇ düzeltilmemişti. Düzeltme: `entryTrampoline`/
  `await_`, Channel'ın `RecvSlot`/`SendSlot` deseninin AYNISı — YENİ bir
  `Waiter{fiber,scheduler}` çifti (askıya alma ANINDA `currentScheduler()`
  İLE KAYDEDİLİR) ÜZERİNDEN uyandırma yapar. Düzeltme geçici olarak
  GERİ ALINIP YENİ regresyon testinin GERÇEKTEN SEGV İLE çöktüğü
  (`self.scheduler.current.?`de null-unwrap) KANITLANDI, SONRA
  düzeltmeyle 15+ ard arda ReleaseFast koşumu TEMİZ doğrulandı.

## [1.29.0]

### Eklendi
- **`--release` altında M:N zamanlayıcının HER YERDE şeffaf aktivasyonu**
  (Faz MN.9): MN.1-8'in inşa ettiği iş-çalan (work-stealing) M:N
  zamanlayıcı, ARTIK SADECE `pool_run`/`serve_multicore` açıkça
  çağrıldığında DEĞİL, `--release` altında `async def`/`spawn`/`await`/
  `Channel[T]` KULLANAN HER programda `$main` TARAFINDAN OTOMATİK
  kurulur (`NOX_POOL_WORKERS` ortam değişkeni İLE ayarlanabilir/devre
  dışı bırakılabilir işçi sayısı, VARSAYILAN CPU çekirdek sayısı).
  `nox_pool_run`/`nox_pool_serve` ARTIK YENİ bir havuz İNŞA ETMEK
  YERİNE bu OTOMATİK havuza DÜZLEŞTİRİLİR (`spawnToForeignScheduler`
  İLE çapraz-worker YAYIN). `nox.thread.start`/`ThreadChannel[T]`
  (ÖNCEDEN TAMAMEN AYRI, paylaşımsız-OS-iş-parçacığı modeli) `--release`
  altında AYNI paylaşılan havuza BİRLEŞTİRİLDİ — argüman/dönüş tip
  sınırı `--release`de `list`/`class`/`dict`/`Task[T]`/`Channel[T]`/
  `TaskLocal[T]`yi de KAPSAYACAK şekilde genişledi (Nox-KAYNAK
  sözdizimi/API'si HİÇ DEĞİŞMEDİ, `.qbe` altında ESKİ, DAR tip sınırı
  AYNEN korunur). `Channel[T]`ye koşulsuz `SpinLock` eklenerek (Faz
  MN.9.1) ebeveyn-çalınan-çocuk arası eş zamanlı erişim GÜVENLİ hale
  getirildi — Bölüm 4/5'in ÖN KOŞULUYDU.

### Düzeltildi
- Uygulama SIRASINDA MN.1-8'den kalma **3 GERÇEK eşzamanlılık hatası**
  bulunup düzeltildi (bkz. plan dosyasının detaylı analizi):
  `Channel[T]`nin çapraz-worker `markReady` hedefinin YANLIŞ scheduler'a
  gitmesi (worker'ın KENDİ scheduler'ı YERİNE uyandırılan fiber'ın
  PİNLİ olduğu scheduler kullanılmalıydı); DebugAllocator'ın fiber-
  yığını İç tahsislerde çerçeve-yürüme İz yakalamasıyla ÇAKIŞMASI (test
  `page_allocator`a geçirilerek düzeltildi); `poolServeFlattened`nin
  yayın hedefi sayısının `num_workers` YERİNE TAM havuz boyutunu
  kullanması (fazladan worker'ların SONSUZA KADAR bloke kalmasına yol
  açıyordu — `lldb` İLE teşhis edildi).

## [1.28.1]

### Düzeltildi
- Harici bir teknik değerlendirmenin (bkz. MN.8 plan notu) İŞARET
  ETTİĞİ 2 GERÇEK sorun + 1 sertleştirme (Faz MN.8): (A) `nox.thread.
  pool_run`ın saf-çalma sibling worker'larının modül-global durumu HİÇ
  ilklendirmemesi (VE driver'ın KENDİ globals'ının, `entry_task`ın
  ÇALINABİLİRLİĞİ YÜZÜNDEN konuma bağımlı kalması — iki AYRI düzeltme
  gerekti); (B) `poolWideDeadlockCheck`nin YAKLAŞIK algoritmasının
  GERÇEK kök nedeni — `Task(T)`nin PLAIN `completed`/`waiter` alanları
  YÜZÜNDEN GERÇEK bir kayıp-uyandırma (lost wakeup) yarışı, CAS tabanlı
  "single-shot future" protokolüyle düzeltildi (paylaşılan bir
  "aktivite epoch"u İLE YANLIŞ-pozitif tespiti de AYRICA sertleştirildi);
  (C) fiber yığınlarına mmap+koruma sayfası (guard page) eklendi
  (POSIX `mprotect`/Windows `VirtualProtect`) — taşma ARTIK sessizce
  bitişik belleği bozmak YERİNE belirli bir SIGSEGV'e dönüşür.

## [1.28.0]

### Eklendi
- **`nox.thread.pool_run(num_workers, entry)`** (Faz MN.7a): Faz MN.1-6'da
  inşa edilen M:N iş-çalan zamanlayıcı altyapısını (o zamana kadar SADECE
  Zig-seviyesi, hiçbir Nox programından erişilemeyen) İLK KEZ gerçek,
  derlenmiş bir Nox programından çağrılabilir kılan genel-amaçlı ilkel —
  SADECE `noxc build --release` (LLVM backend) İLE derlenebilir (QBE'nin
  atomic instruction'ı olmadığından). `entry` İçİNDEKİ `spawn`/`await`
  ARTIK ŞEFFAF olarak çapraz-worker çalmadan yararlanır.
- **`nox.http.serve_multicore`nin `--release` altında havuz-tabanlı
  lowering'i** (Faz MN.7b): YENİ `nox_pool_serve` — `nox_thread_spawn`nin
  ESKİ, worker-başına BAĞIMSIZ `RuntimeState` modeli YERİNE TÜM worker'lar
  TEK bir paylaşılan `WorkerPool`/ARC havuzu/döngü-çözücüyü PAYLAŞIR.
  QBE yolu (bayraksız `noxc build`) bayt-birebir değişmedi.

### Düzeltildi
- MN.7a/7b'nin GERÇEK, çok-worker kullanım desenlerini İLK KEZ
  egzersiz etmesi SIRASINDA, MN.4/5/6'dan kalma **4 GERÇEK eşzamanlılık
  hatası** bulunup düzeltildi: (1-2) `Scheduler.run()`ün `pool_live_
  count==0` erken-çıkış yolu, KENDİSİ ÇIKARKEN TAM O ANDA istenen bir
  STW/döngü-çözücü turuna katılmayı KAÇIRABİLİYORDU (İKİ AYRI varyant —
  biri sibling-başlangıç sırasıyla, biri release/acquire sıralama
  eksikliğiyle ilgili; İKİNCİSİ `worker_pool.zig`nin KENDİ MN.6 stres
  testinde 37+ dakikalık GERÇEK bir asılı-kalma OLARAK gözlemlenip
  `sample` İLE teşhis edildi); (3) `poolWideDeadlockCheck`, BAŞKA bir
  worker'ın ÇAPRAZ-worker `markReady` İLE eklediği yerel hazır-işleri HİÇ
  KONTROL ETMİYORDU (YANLIŞ pozitif deadlock); (4) `http_server.zig`nin
  `serveImpl`i bağlantı-fiber'larını spawn ederken (havuzlu modda
  SADECE `pool_live_count`ın kullanıldığı yerde) koşulsuz `self.live_
  count`e dokunuyordu — `usize` alta-taşması İLE GERÇEK HTTP trafiği
  altında YANLIŞ pozitif "kilitlenme tespit edildi" hatasına yol açtığı
  DOĞRUDAN gözlemlendi.

## [1.27.0]

### Eklendi
- **Deneysel `noxc build --release` LLVM backend'i** (Faz LLVM.1-8):
  QBE yolu (varsayılan, bayraksız `noxc build`) TAMAMEN değişmeden,
  `--release` bayrağıyla `.ll`/`clang -O2` üzerinden derleyen İKİNCİ
  bir backend. Ön koşul olarak `compiler/codegen_qbe/`nin TÜM QBE metin-
  emisyonu TEK bir seam'e (`qbe_emit.zig`) çekildi (Faz IR.0-14, 16
  dosyadaki 960 çağrı sitesi, HER dilim IR-diff aracıyla bayt-birebir
  doğrulandı — davranış SIFIR değişti). LLVM yolu 30/30 benchmark'ta
  QBE'yle stdout eşleşiyor; `qbeAlloc`nin mem2reg'i engelleyen bir
  `ptrtoint` deseni bulunup düzeltildi (`json_bench`: 51s→~28s).
- **M:N iş-çalan (work-stealing) fiber zamanlayıcı altyapısı** (Faz
  MN.1-6, `runtime/async_rt/`+`runtime/alloc/`): LLVM yoluna sınırlı
  atomic ARC (QBE'nin atomic instruction'ı olmadığından), fiber-affine
  çalışma-zamanı global'leri, standalone Chase-Lev work-stealing deque,
  paylaşılan `RuntimeState`li worker havuzu, gerçek çapraz-worker
  fiber çalma + havuz-çapında yaklaşık deadlock tespiti, VE döngü
  çözücü İçİn kooperatif "dünyayı-durdur" bariyeri. Şu an SADECE Zig-
  seviyesi altyapı — `nox.thread`/`nox.http.serve_multicore`e BAĞLANMASI
  (gerçek bir Nox programının bunu KULLANABİLMESİ) AYRI, henüz
  başlanmamış bir sonraki faz. Uygulama sırasında 4 GERÇEK eşzamanlılık
  hatası bulunup düzeltildi (worker-havuzu senkronizasyon hataları +
  `Scheduler`ın standalone Windows-CI test hedefini kırması + STW
  bariyerinin İKİ AYRI livelock'u — biri `zig build test`in TAM
  takımında 30+ dakikalık GERÇEK bir CPU-yüklü livelock OLARAK
  gözlemlenip `sample` İLE teşhis edildi).

### Düzeltildi
- **`Task[T]`/`Channel[T]`/`ThreadHandle[T]`/`ThreadChannel[T]`/
  `TaskLocal[T]` tipli bir yerel değişken bir döngü İçİNDE yeniden
  bildirildiğinde (`t: Task[int] = spawn ...`) yineleme başına BİR
  `Task` struct'ı sızması**: kök neden codegen'deydi (`stmt.zig`nin
  `.var_decl` dalı, runtime DEĞİL) — bu 5 tür `isHeapManaged`in DIŞINDA
  olduğundan "üzerine yazmadan önce eskiyi yok et" çağrısı eksikti.
  Düzeltme İKİ parçalıydı: eksik çağrı eklendi VE bu 5 türün slotu artık
  (ARC-yönetimli türlerle AYNI şekilde) girişte sıfırlanıyor +
  `nox_async_destroy_task`/`nox_channel_destroy` artık null-güvenli
  (500k yinelemelik `benchmarks/async_task_churn.nox` sızıntısız).

## [1.26.6]

### Değişti
- **GG.16**: `sum_list(make_data())` gibi bir çağrı sınırı ötesinde --
  `make_data()`nin GG.2 ile inline edilmiş sabit-boyutlu liste literali,
  `sum_list`in kendi `xs` parametresinin gövdesi içinde hiç kaçmadığı
  (yeni `paramNeverEscapes` analizi -- yalnızca for-iterable/`.index`
  tabanı/tek `len()` argümanı güvenli sayılır, varsayılan "kaçtığını
  varsay") kanıtlandığında `nox_rc_alloc` yerine çağıranın giriş bloğunda
  önceden ayrılmış bir yığın slotu kullanılıyor. Uygulama sırasında GERÇEK
  bir çağrı-sitesi-karışması hatası bulunup düzeltildi: ilk sürüm yığın
  slotunu paylaşılan liste-literali AST düğümüyle (`elems.ptr`)
  anahtalıyordu -- aynı `make_pair()` gövdesi güvenli BİR çağrı sitesinde
  (`total(make_pair())`) VE güvensiz BAŞKA bir sitede (`stored: list[int]
  = make_pair()`, kalıcı bir isme bağlanıyor) kullanıldığında, ikincisi de
  yanlışlıkla aynı slotu aldı (SIGBUS çökmesi). Düzeltme: slot artık
  argüman ÇAĞRI SİTESİNİN kendi kimliğiyle anahtarlanıyor, `genInlinedCall`
  sadece kayıtlı o özel siteyi splice ederken geçici olarak devreye
  sokuyor. 4 yeni golden test (2 pozitif + 2 IR-metni kanıtı) + öncekinin
  kendisi regresyon koruması olarak eklendi. `list_traversal`: 59.3ms ->
  ~49-50ms (~%15-16 iyileşme; GG.15'ten daha küçük ama gerçek kazanç, bkz.
  nox-teknik-spesifikasyon.md §3.66 GG.16).

## [1.26.5]

### Değişti
- **GG.15**: `lowlevel:` bloğu içindeki sabit-boyutlu inşalar (sınıf
  kurucuları + basit-literal `list_lit`'ler) artık `nox_arena_alloc`
  yerine fonksiyon-girişinde önceden ayrılmış yığın slotlarını kullanıyor
  -- `checkNoLowlevelEscape` bu değerlerin hiçbir zaman kaçmadığını zaten
  kanıtladığından, tahsis stratejisini bump-pointer arenadan gerçek QBE
  yığın slotuna çevirmek güvenli. Bir `lowlevel:` örneğindeki TÜM inşalar
  dönüştürülebiliyorsa `nox_arena_create`/`destroy` çifti de tamamen
  eleniyor; karışık durumda (identifier elemanlı liste gibi tanınmayan
  bir şekil varsa) "ya hepsi ya hiçbiri" ilkesiyle mevcut arena davranışı
  korunuyor. 4 yeni golden test (2 pozitif + 2 IR-metni kanıtı) ile
  doğrulandı. Bu fazın kazancı projenin şimdiye kadarki en büyüğü:
  63.8ms->~28.3ms (~%56 iyileşme), C karşılaştırması 26.54x->~10-15x
  yavaş (C tarafı ms-altı gürültü nedeniyle oran dalgalanıyor ama nox'un
  kendi mutlak süresindeki iyileşme kesin, bkz.
  nox-teknik-spesifikasyon.md §3.66 GG.15).

## [1.26.4]

### Değişti
- **GG.14**: string literali döndüren fonksiyonlardan (ör. `pick`) geçen
  bir değeri (ör. `pass_through(s): return s`) inline-splice edilmiş bir
  parametre üzerinden ARTIK gereksiz retain/release almıyor -- string
  literalleri `PINNED_REFCOUNT` (asla sıfıra inmez) taşıdığından bu
  aritmetik mantıksal olarak güvenli ama tamamen israftı. Bilinçli olarak
  dar: yalnızca TÜM return'leri doğrudan string literali olan fonksiyonlar
  tanınır -- `pass_through` gibi parametresini olduğu gibi döndüren
  fonksiyonlar hiçbir zaman tanınmaz. Yeni bir pozitif+negatif fixture
  (pinned/dinamik string'i aynı `forward()` üzerinden geçiren) + bir
  IR-metni testi ile doğrulandı. Bu fazın kazancı gürültüden ayırt
  edilebilir büyüklükte: stres tablosu 48.3ms->44.4ms, C karşılaştırması
  4.36x->4.12x yavaş (bkz. nox-teknik-spesifikasyon.md §3.66 GG.14).

## [1.26.3]

### Değişti
- **GG.13**: küçük (≤8 alan), döngüsüz sınıflar için `a == b`/`a != b`
  ARTIK paylaşılan `$ClassName_eq`e bir `call`+dönüş yerine, karşılaştırıcı
  DOĞRUDAN kullanım sitesine spliced ediliyor -- `list == list` (her zaman
  döngü gerektirir) bu optimizasyonun kapsamı dışında kalıyor. Yeni bir
  IR-metni testi + taze `.ssa` incelemesiyle `call $Point_eq`in gerçekten
  üretilmediği doğrulandı; mevcut 2.000.000 yinelemelik yığın-taşması
  regresyon testi davranış/bellek güvenliğini teyit etti. Bu fazın kazancı
  (GG.12'nin aksine) gürültüden ayırt edilebilir büyüklükte: stres tablosu
  12.4ms->11.3ms, C karşılaştırması 1.97x->1.61x yavaş (bkz.
  nox-teknik-spesifikasyon.md §3.66 GG.13).

## [1.26.2]

### Değişti
- **GG.11 (belge-only)**: `generics_protocols.nox`nin `identity()` inlining
  "bulgusu" TAZE bir derlemeyle YENİDEN DOĞRULANAMADI — `identity__int`
  zaten TAMAMEN inline ediliyor (checked-in `.ssa` byte-byte identik çıktı,
  "stale artefakt" hipotezi de yanlıştı). Kod değişikliği yok.
- **GG.12**: `Box.sum()` gibi `local_items: list[int] = self.items` +
  `for x in local_items:` desenlerinde `self`in bir alanının salt-okunur,
  tek-kullanım kopyası ARTIK retain/release GEREKTİRMİYOR — `self` metodun
  tüm aktivasyonu boyunca canlı, alan hiç yeniden atanmıyor, kopya hiçbir
  yere aktarılmıyor. Yeni bir IR-metni testi + taze `.ssa` incelemesiyle
  retain/predecrement'in GERÇEKTEN elendiği doğrulandı — wall-clock etkisi
  bu benchmark'ın ms-ölçeğinde gürültüden ayırt edilemediğinden README
  rakamları güncellenmedi (bkz. nox-teknik-spesifikasyon.md §3.66 GG.12).

## [1.26.1]

### Düzeltildi
- **`nox.path.join` regresyonu (~18x yavaşlama)**: `str` ABI değişikliği
  (uzunluk alanı + ASCII bayrağı) SONRASI `nox_path_join_raw` yanlış bir
  gerekçeyle `std.heap.page_allocator` üzerinden bir ara tampona GERİ
  DÖNDÜRÜLMÜŞTÜ — Faz II'nin (v1.8.x civarı) ZATEN düzelttiği AYNI sayfa-
  tahsisi darboğazı sessizce geri gelmişti (`path_bench`: ~8ms → ~145ms).
  Benchmark tazeleme sırasında bulunup `nox_str_concat`in AYNI tek-tahsis
  desenine dönülerek düzeltildi — sonuç eski taban çizgisinden bile
  HIZLI (~0-1ms).

### Değişti
- Tüm benchmark takımı (`zig build bench -Doptimize=ReleaseFast`) yeniden
  çalıştırıldı; `README.md`/`README.en.md`/`benchmarks/RESULTS.md`deki
  sayılar güncel/doğrulanmış sonuçları yansıtacak şekilde güncellendi.

## [1.26.0]

### Eklendi
- **`dict[K, class]` — sınıf DEĞERLİ dict'ler**: nyx'te farkedilen bir
  Nox eksikliği — checker `dict[K, V]`nin DEĞER tipini `int`/`float`/
  `bool`/`str`e KISITLIYORDU, nyx "preload list API" GİBİ bir geçici
  çözüme MAHKUMDU. Artık `dict[int, Record]` GİBİ bir kullanım
  MÜMKÜN (ANAHTAR kısıtlaması AYNEN KALDI — sınıf anahtarlar HÂLÂ
  REDDEDİLİR). `TaskLocal[T]`in AYNI tasarımını (Tasarım B: `nox_class_
  release_dispatch`in tag-tabanlı dağıtımı) YENİDEN kullanır —
  `dict.zig` hangi SOMUT sınıf olduğunu HİÇ bilmek zorunda DEĞİLDİR.

## [1.25.0]

### Eklendi
- **Yakalanmamış istisna raporlaması: sınıf adı + satır numarası**: nyx'te
  farkedilen bir Nox eksikliği — `raise` edilen bir istisna HİÇBİR konum
  (satır) veya tip adı bilgisi TAŞIMIYORDU, yakalanmamış bir istisna
  `nox_unhandled_exception`ın SABİT, jenerik tek satırlık mesajıyla
  SONLANIYORDU. Artık `nox_raise` `raise` deyiminin KAYNAK satırını da
  taşır; yeni `$nox_class_name_dispatch` (derleyicinin ÜRETTİĞİ, `$nox_
  class_release_dispatch`in AYNI tag-tabanlı if-zinciri kalıbı) istisnanın
  GERÇEK çalışma-zamanı sınıf adını çözer. Örnek: `nox: yakalanmamış
  istisna: ShoppingCartError (satır 6) — program sonlandırılıyor`.
- **`Exception` taban sınıfı**: `stdlib/nox/core.nox`'a TÜM `raise`
  edilebilir sınıfların ORTAK atası olarak eklendi; stdlib'in TÜM 18
  `*Error` sınıfı (`ValueError`/`IndexError`/`KeyError`/`HttpError`/
  `JsonError`/`FsError`/`OsError`/`PathError`/`ProcessError`/
  `SharedMemError`/`PostgresError`/`MysqlError`/`SqliteError`/
  `AssertionError`/`TlsError`/`TemplateError`/`WebSocketError`/
  `UrlError`) ARTIK `Exception`den TÜRER — `except Exception:` İLE
  programdaki HANGİ modülden gelirse gelsin HERHANGİ bir istisnayı TEK
  bir kolla yakalamak MÜMKÜN (Faz 7 tekli kalıtım + hiyerarşik `except`
  mekanizması ZATEN bunu destekliyordu, YENİ bir dil özelliği GEREKMEDİ).
- **Parser: sınıf gövdesinde `pass`**: `class X(Base): pass` (HİÇBİR
  KENDİ alan/metod EKLEMEYEN bir alt sınıf — `Exception` migrasyonunun
  KENDİSİ bunu GEREKTİRDİ) ÖNCEDEN `UnexpectedToken` İLE ÇÖKÜYORDU (sınıf
  gövdesi dispatch'i `pass`i SADECE fonksiyon gövdelerinde tanıyordu) —
  GERÇEK bir dil boşluğuydu, düzeltildi.

## [1.24.0]

### Eklendi
- **`TaskLocal[T]` — task/fiber-local bağlam**: nyx'te farkedilen bir
  Nox eksikliği — async çalışma zamanında HERHANGİ bir task/fiber-local
  depolama ilkeli YOKTU, nyx her İSTEK İçİn bir OS-thread-local
  "worker-local" durum torbasıyla İDARE EDİYORDU (AYNI worker thread'te
  ZAMANLANAN İKİ fiber'ın BİRBİRİNİN bağlamını GÖRME riski taşıyordu).
  `TaskLocal[T]`, `Channel[T]`nin BİREBİR paraleli (yerleşik generic,
  `get()/set(value)/clear()` — `await` GEREKTİRMEZ, senkron): GERÇEK
  değer `Fiber`nin KENDİ per-fiber haritasında saklanır, `TaskLocal`
  örneğinin KENDİSİ (TİPİK KULLANIM: modül-seviyesi bir global) TÜM
  fiber'lar arasında PAYLAŞILABİLİR. Bilinçli v1 kısıtlaması: `T` bir
  sınıf/`str`/`list`/`dict` OLMALIDIR (çıplak `int`/`float`/`bool`
  `Optional`-kutulama komplikasyonu YÜZÜNDEN REDDEDİLİR). Yeni golden
  test (`task_local_basic.nox`) İKİ fiber'ın GERÇEK eşzamanlı-çakışma
  senaryosunda BİRBİRİNİN değerini GÖRMEDİĞİNİ kanıtlar.

## [1.23.0]

### Eklendi
- **`nox.db.Row` — ortak, PAYLAŞILAN satır sınıfı**: `nox.sqlite`/`nox.
  postgres`/`nox.mysql`nin ÜÇÜ de YAPISAL OLARAK BİREBİR AYNI ama
  BAĞIMSIZ birer `Row` sınıfı tanımlıyordu — bu YÜZDEN `DbConnection`
  protokolüne `query(sql) -> list[Row]` EKLENEMİYORDU (checker'ın
  protokol dönüş-tipi eşleştirmesi TAM/invaryant: `list[sqlite.Row]`
  bir `list[RowProtocol]` İMZASINI KARŞILAMIYORDU). Kovaryant protokol
  eşleştirmesi GİBİ büyük bir compiler özelliği EKLEMEK YERİNE, ÜÇ
  sürücünün `Row`u `stdlib/nox/db.nox`ta TEK, PAYLAŞILAN bir concrete
  sınıfa BİRLEŞTİRİLDİ — `sqlite.nox`/`postgres.nox`/`mysql.nox` ARTIK
  KENDİ `Row`larını TANIMLAMIYOR, `from nox.db import Row` KULLANIYOR.
  `DbConnection` protokolü ARTIK `query`yi de KAPSIYOR.
- **DAVRANIŞ DEĞİŞİKLİĞİ (kasıtlı)**: `from nox.sqlite import Row` (VEYA
  `nox.postgres`/`nox.mysql`) ARTIK ÇALIŞMAZ — `Row` ARTIK `nox.db`den
  İTHAL EDİLMELİDİR (`from nox.db import Row`). Nox'un `from X import
  Y`si TRANSİTİF/yeniden-ihraç EDİCİ DEĞİLDİR (Y'nin GERÇEKTEN X'te
  TANIMLI olmasını VARSAYAR) — bu YÜZDEN `Row`un `nox.db`ye taşınması
  ONU İTHAL EDEN HER YERİN güncellenmesini GEREKTİRİYOR.

## [1.22.9]

### Düzeltildi
- **`hpy_bridge`/`wasm_bridge` (Linux)**: `hpy_bridge_mod`/`wasm_bridge_mod`nin
  KENDİ bağımsız test hedefleri (`hpy_bridge_test`/`wasm_bridge_test`),
  `noxrt_mod`nin (onları İTHAL EDEN) `.link_libc = true`SUNU MİRAS
  ALMIYORDU — bu modüllerin kendi kök test derlemesinde `std.c.arc4random_
  buf` (bkz. `context.zig`, Faz LL.4 deseni) Linux'ta "dependency on libc
  must be explicitly specified" hatasıyla BAŞARISIZ oluyordu. Ayrıca AYNI
  sınıftan bir ÜÇÜNCÜ site bulundu: `tests/cli/shared_mem_test.zig`nin
  KENDİ `std.c.getpid()` çağrısı, `external_test_files` döngüsündeki HİÇBİR
  test modülünün `link_libc` TANIMLAMAMASI yüzünden AYNI hatayı veriyordu.
  Düzeltme: her ikisine de `.link_libc = true` eklendi.
- **`nox.process` cwd testi (Linux)**: `Command("pwd").set_cwd("/tmp")`nin
  çıktısı PLATFORM'a göre değişir (macOS'ta `/tmp` sembolik bağdır →
  `/private/tmp` yazdırır; Linux'ta genelde DEĞİLDİR → düz `/tmp` yazdırır)
  — ÖNCEDEN sabit bir `.expected` metin dosyası `/private/tmp`i
  SABİTLİYORDU, bu YÜZDEN Linux'ta HER ZAMAN başarısız oluyordu. Düzeltme:
  bu SATIR ayrı doğrulanıyor (iki bilinen GERÇEK çözünürlükten biriyle
  eşleşmeli), geri kalan çıktı TAM eşleştiriliyor.

## [1.22.8]

### Düzeltildi
- **CI'nin Windows TLS duman testi, TLS+HTTP GERÇEKTEN BAŞARILI OLDUĞU
  HALDE yanlış-pozitif olarak BAŞARISIZ görünüyordu**: `v1.22.7`nin kök-neden
  düzeltmesi SONRASI TLS handshake+HTTP yanıtının KENDİSİ ARTIK GERÇEKTEN
  BAŞARILI oluyordu (`tls_smoke.exe` stderr'i BOŞTU) — AMA CI betiği yine
  "beklenmeyen govde: '111 107 45 119 105 110 100 111 119 115 45 116 108
  115'" diyerek başarısız oluyordu. Bu, PowerShell'in `Invoke-WebRequest
  -UseBasicParsing`inin, yanıtta bir `Content-Type` başlığı OLMADIĞINDA
  `$resp.Content`yi bir STRING DEĞİL HAM `byte[]` olarak DÖNDÜRMESİNDEN
  kaynaklanıyordu — string interpolasyonu bu byte dizisini ASCII kodlarının
  ONDALIK karşılıklarının boşlukla ayrılmış hali OLARAK yazdırıyordu (`111
  107 45 ...` = "ok-windows-tls"nin ASCII kodları). Düzeltme: duman testinin
  yanıtına bir `Content-Type: text/plain` başlığı EKLENDİ.

## [1.22.7]

### Düzeltildi
- **GERÇEK KÖK NEDEN bulundu ve düzeltildi — `nox.http.serve_tls` Windows'ta
  HİÇ dinlemeye BAŞLAMIYORDU**: `v1.22.6`nin sembol-seviyesi tanısı
  KESİN olarak gösterdi: `nox_tls_server: sembol bulunamadi: BIO_new`.
  `BIO_new`/`BIO_s_mem`/`BIO_read`/`BIO_write`/`BIO_ctrl` OpenSSL'in
  `libcrypto`SUNDA tanımlıdır, `libssl`DE DEĞİL. POSIX'te (`dlsym`) bu
  SORUN OLMAZ — bir handle üzerinde arama YAPARKEN o modülün bağımlılık
  grafiğini (libssl'in KENDİ `libcrypto` bağımlılığı DAHİL) transitif
  olarak TARAR (macOS/Linux CI ZATEN bunu doğruladı). AMA Windows'ta
  `GetProcAddress` YALNIZCA verilen HMODULE'ün KENDİ exports tablosuna
  BAKAR, bağımlılıklarına ASLA İNMEZ — bu YÜZDEN `GetProcAddress(libssl_
  handle, "BIO_new")` HER ZAMAN başarısız OLUYORDU (`libssl-3-x64.dll`/
  `libcrypto-3-x64.dll` HER İKİSİ de DİSKTE doğrulanmış OLSA BİLE).
  Düzeltme: Windows'ta BIO_* sembolleri ARTIK AYRI bir `libcrypto` handle'ından
  aranıyor — bu handle'ı elde etmek İçİn AYRI bir arama/PATH GEREKMİYOR,
  çünkü `libcrypto` `libssl` yüklendiğinde ZATEN işlem belleğine
  yüklenmiş oluyor (bare-isimli bir `LoadLibraryA` çağrısı SADECE
  refcount'u artırıp AYNI, ZATEN-yüklü handle'ı DÖNÜYOR).

## [1.22.6]

### Düzeltildi
- **`libssl` yükleme başarısızlığı ("lib_load_failed") HALA kör bir kutuydu**:
  `v1.22.5`nin `CtxError` ayrımı `newServerCtx` seviyesinde HANGİ adımın
  başarısız olduğunu (kütüphane yükleme mi, cert mi, key mi) gösterse de,
  "kütüphane yükleme" adının KENDİSİ HÂLÂ tek bir kara kutuydu: `openLib()`
  (`LoadLibraryA`/`dlopen`) mi başarısız oldu, yoksa kütüphane BULUNUP
  `loadAll()`daki ~20 `GetProcAddress`/`lookup` çağrısından BİRİ mi başarısız
  oldu — bilinmiyordu. GERÇEK bir Windows CI çalıştırmasında `libssl-3-x64.
  dll`/`libcrypto-3-x64.dll` HER İKİSİ de doğrulanmış (bulunmuş) OLDUĞU
  HALDE `nox.http.serve_tls` yine "libssl yuklenemedi" diyordu — HANGİ
  adımın gerçekte başarısız olduğu teşhis EDİLEMİYORDU. Düzeltme: `openLib`
  ARTIK her başarısız `LoadLibraryA`/`dlopen` denemesinde (Windows'ta
  `GetLastError()` KODU DAHİL) stderr'e satır basıyor; `lookupSym` ARTIK
  HANGİ sembol adının bulunamadığını basıyor.

## [1.22.5]

### Düzeltildi
- **`nox.http.serve_tls`nin TLS bağlamı hatası TEK bir belirsiz stderr
  mesajına DÜŞÜYORDU**: `newServerCtx`nin dört FARKLI başarısızlık nedeni
  (libssl yüklenemedi, sertifika dosyası kullanılamadı, anahtar dosyası
  kullanılamadı, anahtar sertifikayla eşleşmiyor) HEPSİ AYNI belirsiz
  mesaja ("libssl kurulu degil olabilir, ya da cert/key yolu/eslesmesi
  yanlis") düşüyordu — bu, GERÇEK bir Windows CI çalıştırmasında `libssl`/
  `libcrypto` HER İKİSİ de doğrulanmış OLDUĞU HALDE sunucunun yine de
  dinlemeye BAŞLAMADIĞI bir durumu teşhis etmeyi ZORLAŞTIRIYORDU.
  Düzeltme: `tls_server.CtxError` (4 üyeli enum) EKLENDİ, `newServerCtx`
  ARTIK bir `err_out` parametresi ALIYOR, `logTlsCtxFailure` HANGİ adımın
  başarısız olduğunu AYRI AYRI mesajlarla bildiriyor.

## [1.22.4]

### Düzeltildi
- **CI'nin Windows TLS duman testi, GERÇEK hata sebebini HİÇBİR ZAMAN
  göstermiyordu**: doğru `libssl-3-x64.dll` ARTIK bulunduğu (bkz. `v1.22.3`)
  HALDE HTTPS bağlantısı yine kurulamıyordu, ama betik bağlantı hatasında
  DOĞRUDAN `throw` attığından `tls_smoke.exe`nin stderr çıktısını dump'layan
  KOD SATIRINA HİÇ ULAŞILMIYORDU (hata HER ZAMAN körlemesine "50 deneme"
  mesajıyla SINIRLI kalıyordu). Düzeltme: hata artık bir DEĞİŞKENDE
  biriktirilip stderr/süreç-durumu HER ZAMAN yazdırıldıktan SONRA
  fırlatılıyor.
- **OpenSSL kurulum dizini PATH'e EKLENMİYORDU (muhtemel kök neden)**:
  `LoadLibraryA` mutlak bir yolla çağrıldığında SADECE o TEK DLL'i o
  yoldan yükler — `libssl-3-x64.dll`nin KENDİ `libcrypto-3-x64.dll`
  bağımlılığı YİNE standart Windows DLL arama sırasıyla (PATH DAHİL,
  ama libssl'in BULUNDUĞU dizin DAHİL DEĞİL) çözülür. Bu YÜZDEN
  `C:\Program Files\OpenSSL` PATH'te DEĞİLKEN `libcrypto` bulunamayıp
  `LoadLibraryA` SESSİZCE başarısız olabiliyordu — `newServerCtx` bu
  YÜZDEN `ensureLoaded()` adımında başarısız olup TLS sunucusu HİÇ
  dinlemeye BAŞLAMIYOR olabilirdi. Düzeltme: OpenSSL kurulum dizini ARTIK
  `GITHUB_PATH`e eklenip job'ın KALAN adımları İçin PATH'e DAHİL ediliyor;
  `libcrypto-*.dll`nin varlığı da AYRICA tanı olarak loglanıyor.

## [1.22.3]

### Düzeltildi
- **CI'nin Windows `libssl` kurulumu YANLIŞ bir kütüphaneyi buluyordu**:
  `v1.22.2`nin geniş "`C:\Program Files` altında HERHANGİ bir `libssl-
  *.dll`" son çare taraması, GERÇEK bir CI çalıştırmasında `windows-
  latest` çalıştırıcısında ÖNCEDEN kurulu AWS CLI'nin KENDİ BAĞIMSIZ
  `libssl-3.dll`sini (`C:\Program Files\Amazon\AWSCLIV2\`, alfabetik
  sırada "OpenSSL"DEN ÖNCE geldiğinden İLK eşleşen) BULUYORDU — bu YABANCI
  kütüphane `TLS_server_method`/`SSL_CTX_new` gibi sembolleri EKSİK/uyumsuz
  OLDUĞUNDAN `nox.http.serve_tls` SESSİZCE hiç dinlemeye BAŞLAMIYORDU
  (`Invoke-WebRequest`in 50 denemesi de zaman AŞIMINA UĞRADI). Ayrıca
  `choco install openssl.light`in (v3.1.4) GERÇEK kurulum yolu `C:\
  Program Files\OpenSSL`ydi (`OpenSSL-Win64` DEĞİL). Düzeltme: KESİN
  kurulum yolu ARTIK İLK sırada denenir, YANLIŞ-POZİTİF riski taşıyan
  GENİŞ `C:\` taraması TAMAMEN KALDIRILDI.

## [1.22.2]

### Düzeltildi
- **CI'nin Windows `libssl` kurulum adımı yanlış yolda arıyordu**:
  `v1.22.1`in düzeltmesi SONRASI `windows-frontend` işi GERÇEKTEN
  `nox.http.serve_tls` duman testi adımına ULAŞTI (bu, o job'ın Windows
  CI TARİHİNDE İLK KEZ bu kadar İLERİ gittiği anlamına gelir) AMA
  Chocolatey'nin `openssl.light` paketinin GERÇEK kurulum yolu, sabit
  varsayılan `C:\Program Files\OpenSSL-Win64\bin`den FARKLI çıktı —
  `libssl DLL bulunamadi` İLE BAŞARISIZ oldu. Düzeltme: ARTIK BİRDEN
  FAZLA olası kök (Program Files/(x86)/OpenSSL-Win32/chocolatey'nin
  KENDİ paket kütüphanesi) DENENİR, HİÇBİRİ bulamazsa `C:\Program
  Files`/`C:\ProgramData\chocolatey` altında sınırlı-derinlikli bir SON
  ÇARE taraması yapılır; `choco`nun KENDİ çıktısı da ARTIK GİZLENMEZ
  (gelecekteki bir başarısızlıkta tanı KOLAYLAŞSIN diye).

## [1.22.1]

### Düzeltildi
- **`compiler/pkg/install.zig`nin `exeFileName` testi, GitHub Actions'ın
  native `windows-latest` çalıştırıcısında GERÇEKTEN başarısız oluyordu**
  (bu değişiklikle İLİŞKİSİZ, ÖNCEDEN VAR OLAN bir Windows CI kırılması —
  `v1.21.3` dahil ÖNCEKİ birkaç sürümün CI koşularında da AYNI ŞEKİLDE
  başarısız olduğu doğrulandı, bu YÜZDEN `v1.22.0`nun Windows doğrulama
  adımları HİÇ ÇALIŞAMADAN `windows-frontend` işi bu testte DURUYORDU).
  `std.heap.FixedBufferAllocator` (64 baytlık sabit bir tampon) ile
  `std.fmt.allocPrint`in (`Writer.Allocating.initCapacity`, YALNIZCA
  6 bayt İLE başlayıp 7 bayta büyümesi GEREKEN) etkileşimi Windows'ta
  `error.OutOfMemory` İLE BAŞARISIZ oluyordu — macOS/Linux'ta AYNI kod
  SORUNSUZDU. Düzeltme: teste ÖZGÜ, gereksiz `FixedBufferAllocator`
  yerine `std.testing.allocator` (sızıntı TESPİTLİ GERÇEK heap) kullanıldı.

## [1.22.0]

### Eklendi
- **`nox.http` sunucusuna GERÇEK TLS terminasyonu (OpenSSL/BoringSSL FFI) +
  sunucu-tarafı WebSocket Upgrade** — kullanıcının `nyx` framework'ünde
  farkedilen SON Nox eksikliği (bkz. proje belleği "server TLS +
  WebSocket Upgrade" fazı). Zig'in KENDİ `std.crypto.tls`i (0.16.0)
  YALNIZCA istemci tarafını (`Client.zig`) uyguladığından — `Server.zig`
  YOK — kullanıcı BİLEREK sıfırdan bir TLS handshake yazmak yerine
  `sqlite.zig`/`postgres.zig`/`mysql.zig` İLE AYNI çalışma-zamanı dlopen-
  FFI desenini seçti (`runtime/stdlib_shims/tls_server.zig`, YENİ):
  `libssl`e (macOS: Homebrew MUTLAK yolları; Windows: `Kernel32.
  LoadLibraryA`; Linux: `libssl.so.3`/`.so.1.1`; hepsinde `NOX_OPENSSL_LIB`
  ortam değişkeni kaçış kapısı) TEMBEL bağlanır, TLS'i bellek-BIO'lar
  (`BIO_s_mem`) üzerinden sürer — OpenSSL GERÇEK fd'ye HİÇ dokunmaz,
  TÜM soket G/Ç'si mevcut fiber-farkında `rawRead`/`rawWriteAll`
  altyapısından geçer, böylece TLS/düz-metin bağlantılar AYNI eşzamanlı
  zamanlayıcıyı PAYLAŞIR.
- Sunucu-tarafı WebSocket Upgrade (`runtime/stdlib_shims/websocket_server.zig`,
  YENİ): RFC 6455 el sıkışması (`Sec-WebSocket-Accept` hesaplaması istemci
  kabuğuyla — `websocket.zig`nin YENİ `computeAcceptValue`i — PAYLAŞILIR),
  maskesiz gelen istemci frame'lerini REDDEDER (Close 1002), sunucu→istemci
  frame'lerini HİÇBİR ZAMAN maskelemez. `stdlib/nox/websocket.nox`ye YENİ
  `WebSocketServerConn` sınıfı (`WebSocketClient` İLE AYNI API: `send_text`/
  `recv`/`is_open`/`close`) eklendi.
- **TAM 12'lik Nox-yüzü fonksiyon matrisi**: `serve`/`serve_fd`/
  `serve_multicore`nin ÜÇÜ de artık `_tls`/`_ws`/`_ws_tls` uzantılarına
  sahip (`serve_tls`, `serve_ws`, `serve_ws_tls`, `serve_fd_tls`,
  `serve_fd_ws`, `serve_fd_ws_tls`, `serve_multicore_tls`,
  `serve_multicore_ws`, `serve_multicore_ws_tls` — 9 YENİ isim).
  Codegen (`compiler/codegen_qbe/http_intrinsics.zig`) bunların HEPSİNİ
  3 PARAMETRİK "generic" çekirdek fonksiyona (`genHttpServeGeneric`/
  `genHttpServeFdGeneric`/`genHttpServeMulticoreGeneric`, `want_tls`/
  `want_ws` bayraklarıyla) indirger — kombinatoryal patlama runtime
  SEVİYESİNDE tamamen "bedava" (`ConnCtx`ye `tls_ctx`/`ws_handler` alanı
  eklemek TÜM ÜÇ transport biçimine YETTİ), yalnızca codegen/checker'da
  mekanik bir isimlendirme işiydi.
- `tests/fixtures/tls/test_cert.pem`/`test_key.pem` — sabit, tek-seferlik
  üretilmiş test-only self-signed sertifika+anahtar çifti (100 yıl geçerli,
  `CN=localhost`). `tests/compat/http_serve_tls_golden_test.zig` (Zig'in
  KENDİ `std.crypto.tls.Client`ıyla GERÇEK bir el sıkışma+istek/yanıt
  interop kanıtı) + `tests/compat/http_serve_ws_golden_test.zig` (ham bir
  RFC 6455 istemcisiyle el sıkışma+maskeli frame yankısı VE maskesiz bir
  frame'in REDDEDİLDİĞİNİN kanıtı) eklendi.
- CI (`ci.yml`nin `windows-frontend` işi): kullanıcının AÇIKÇA seçtiği
  "Windows'u da TAM doğrula" kararı — Chocolatey İLE GERÇEK bir `libssl`
  kurulup (`NOX_OPENSSL_LIB` İLE %100 güvenilir biçimde BULUNARAK)
  `nox.http.serve_tls`in GERÇEK bir HTTPS isteğine yanıt verdiği native
  bir Windows runner'da doğrulanıyor, ARDINDAN TAM 12'lik isim matrisinin
  HEPSİNİN Windows qbe.exe+MinGW cc İLE derlenip BAĞLANDIĞI ayrıca
  kontrol ediliyor.

### Düzeltildi (bu fazın KENDİ araştırması sırasında bulunan GERÇEK hatalar)
- **macOS'ta bare `dlopen("libssl.dylib")` Apple'ın dyld PAYLAŞILAN
  önbelleğindeki bir "sahte" kütüphaneyle eşleşip `abort()` çağırıyordu**
  ("... is loading libcrypto in an unsafe way" — Apple, sistemden OpenSSL'i
  KALDIRDIĞINDAN bu isimlerle dlopen eden uygulamaları BİLEREK kırmak İçin
  tutuyor). `lldb` backtrace'iyle YAKALANDI. Düzeltme: macOS'ta ARTIK
  YALNIZCA Homebrew/MacPorts'un MUTLAK yolları denenir, bare isimler HİÇ
  denenmez.
- **GERÇEK bir use-after-free yarışı**: `serve_multicore_tls`/tekli
  `serve_tls` bağlantı-başına bir fiber olarak SPAWN edilirken, `max_
  connections`e ulaşılınca ÇAĞIRANIN payı BİTER BİTMEZ (yeni spawn edilen
  fiber HENÜZ HİÇ ÇALIŞMAMIŞKEN) `nox_http_server_close` `SSL_CTX_free`
  çağırıyordu — `lldb` İLE (`x8+0x10` → serbest bırakılmış belleğin
  içeriği) KANITLANDI. Düzeltme: `SSL_CTX_up_ref` İLE bağlantı fiber'ı
  SPAWN EDİLMEDEN ÖNCE (hâlâ GÜVENLİ orijinal fiber'dayken) EK bir
  referans alınır, `acceptHandshake` `SSL_new`DAN SONRA bırakır.
- `connectionEntry`, TLS-farkında `reader_ptr`/`writer_ptr` yerine HER
  ZAMAN düz-metin `fiber_reader`/`fiber_writer`i `std.http.Server.init`e
  veriyordu — el sıkışma BAŞARILI olsa BİLE HTTP katmanı şifreli baytları
  OKUYUP YAZARDI (bkz. yukarıdaki GERÇEK yarış hatasının düzeltilmesi
  SIRASINDA fark edildi).
- `SSL_shutdown`in ürettiği `close_notify` alert'i `flushWbio` İLE GERÇEK
  soketE AKTARILMIYORDU — istemciler (Zig'in `std.crypto.tls.Client`ı
  DAHİL, `allow_truncation_attacks=false` VARSAYILANIYLA) bağlantıyı
  `error.TlsConnectionTruncated` İLE REDDEDİYORDU (`http_serve_tls_
  golden_test.zig`nin İLK çalıştırmasıyla YAKALANDI).

## [1.21.3]

### Düzeltildi
- **`nox.sqlite`nin `execute`i ARTIK `nox.postgres`/`nox.mysql` İLE
  TUTARLI olarak etkilenen satır sayısını (`int`) döner** (ÖNCEDEN
  `None`): `Statement.execute()`/`Connection.execute()` — geriye dönük
  UYUMLU (mevcut, dönüş değerini yok sayan HİÇBİR çağrı sitesi
  etkilenmez, bkz. `tests/cli/sqlite_test.zig`). Bu tutarsızlık,
  `nox.db.DbConnection` protokolüne `execute`in EKLENEMEMESİNİN kök
  nedeniydi (protokol eşleştirmesi dönüş tipini TAM eşleştirir) — ARTIK
  protokole EKLENDİ. Kullanıcının `nyx` framework'ünde farkedilen "ortak
  DB Connection tipi" eksikliğinin BİR PARÇASI olarak bulunup düzeltildi
  (kalan kısım — `query`/`prepare`/`Row`nin protokole DAHİL EDİLEMEMESİ,
  generic konteynerler İçin kovaryant protokol eşleştirmesi GEREKTİRDİĞİNDEN
  — BİLİNÇLİ olarak AYRI, daha büyük bir compiler-tasarım işi olarak
  bırakıldı).

## [1.21.2]

### Düzeltildi
- **`nox.sharedmem`nin Linux build'lerini v1.18.0'dan beri KIRAN bir
  `std.c.fstat` uyumsuzluğu**: `runtime/stdlib_shims/shared_mem.zig`,
  `openPosix`da mevcut segment boyutunu kontrol etmek İçin `std.c.fstat`
  KULLANIYORDU — bu Zig sürümünde (0.16.0) `std.c.fstat` Linux'ta `void`
  olarak tanımlı (GERÇEK bir libc sembolüne BAĞLANMIYOR, bkz. `fs.zig`nin
  ÖNCEDEN AYNI kısıt İçin bulduğu `fstatCompat` deseni, nox-teknik-
  spesifikasyon.md §3.71) — `nox.sharedmem` (Faz 6, v1.13.0 civarı)
  eklendiğinde bu ÇÖZÜM oraya UYGULANMAMIŞTI. `release.yml`nin GitHub
  Actions'ta linux-x64 hedefini derlerken v1.18.0'dan İTİBAREN sürekli
  BAŞARISIZ olmasının kök nedeniydi (`gh run list` İLE DOĞRULANDI).
  `fs.zig`nin KANITLANMIŞ `fstatCompat` desenini (Linux'ta `std.c.statx`
  + `AT.EMPTY_PATH`, diğer platformlarda ESKİ `std.c.fstat`) minimal bir
  `fstatSize` yardımcısıyla `shared_mem.zig`ye UYGULAYARAK düzeltildi.
  macOS native build + tam regresyon YEŞİL; `zig build -Dtarget=x86_64-
  linux` çapraz derlemesiyle DOĞRULANDI (asıl hata KAYBOLDU — kalan tek
  hata macOS'un KENDİ `cc`sinin bir Linux `.S` dosyasını assemble
  EDEMEMESİ, saf host-only çapraz-araç zinciri kısıtı, GERÇEK Linux CI
  runner'ında OLUŞMAZ). Kullanıcının "GitHub Actions release workflow'u
  sürekli başarısız oluyor" gözlemine yanıt olarak bulunup düzeltildi.

## [1.21.1]

### Düzeltildi
- **Kapanış-tipi (closure) yakalama eksik `func_sig` alanı**: `closures.zig`nin
  `buildClosureValue`ı, bir yakalanan (capture) DEĞERİN `func_sig`ini
  (`heap == .closure` olan yakalamalar İçİn ÇAĞRI imzası) KOPYALAMIYORDU —
  bu YÜZDEN bir iç içe `def`, ÇEVRELEYEN fonksiyonun FONKSİYON-TİPLİ (ör.
  `(int) -> int`) bir parametresini/yerel değişkenini YAKALAYIP
  ÇAĞIRMAYA çalıştığında (`handler(x)`) codegen "desteklenmeyen bir yapı"
  hatasıyla BAŞARISIZ oluyordu (list/dict/str/sınıf gibi VERİ tipi
  yakalamalar ETKİLENMİYORDU — yalnızca FONKSİYON tipi). Kullanıcının
  `nyx` framework'ünde (`routes.nox`, `post_with_override`-tarzı sarmalayıcı
  desenler) BULUNUP BAĞIMSIZ olarak GERÇEK nox-lang koduyla doğrulandı.
  Tek satırlık eksik alan atamasıyla (`.func_sig = src.func_sig`)
  düzeltildi; iç içe SARMALAMA (bir closure'ın BAŞKA bir closure'ı
  yakalayıp SARMASI) DAHİL 2000+ yinelemede sızıntısız doğrulandı. Ayrı
  bir bulgu: kullanıcının `nyx.app`de `on_shutdown` hook registry'sini
  DEVRE DIŞI bırakan (`Nox package codegen limit` diye not düşülmüş)
  eski bir workaround, GERÇEKTEN aynı desende (paket-modül sınıfı + list-
  of-closure alan + Router ile birlikte) test EDİLDİ ve v1.18.1'in
  P1c/C2 düzeltmeleriyle ZATEN çözüldüğü doğrulandı — bu, nox-lang
  tarafında YAPILACAK bir şey GEREKTİRMİYOR (nyx tarafında kaldırılabilir
  bir eski not).

## [1.21.0]

### Eklendi
- **Decorator sözdizimi + metadata-tabanlı metaprogramming (Faz 1: üst-düzey
  fonksiyonlar)**: `@isim` / `@isim("arg1", "arg2")` — bir veya daha fazla
  satır, HEMEN bir üst-düzey `def`den ÖNCE. Rust proc-macro/Lisp makro
  tarzı bir kod-dönüşüm sistemi DEĞİL — derleyici decorator'ın ANLAMINI
  yorumlamaz, YALNIZCA (isim, string-literal argümanlar, hedef fonksiyon)
  üçlüsünü derleme-zamanı bir metadata tablosuna KAYDEDER; framework'ler
  (ör. bir ExpressJS/NestJS-tarzı web katmanı) bu ham veriyi ÇALIŞMA
  ZAMANINDA `nox.reflect` üzerinden sorgular.
  - Yeni `@` token'ı (lexer), `ast.Decorator` + `FuncDef.decorators`/
    `ClassDef.decorators` alanları (parser). v1: yalnızca üst-düzey
    fonksiyonları hedefler — sınıf decorator'ları PARSE EDİLİR ama checker
    AÇIKÇA reddeder (`self`e bağlı, çağrılabilir bir metod-değeri
    mekanizması HENÜZ olmadığından, BİLİNÇLİ kapsam daraltması).
  - Checker: argümanlar YALNIZCA string LİTERALİ olabilir (`hpy_call`nin
    AYNI güvenlik deseni); decorator'lı fonksiyon OTOMATİK olarak
    `functions_used_as_value`e eklenir (MEVCUT trampoline mekanizması
    yeniden kullanılır, YENİ codegen İCAT EDİLMEDİ).
  - Codegen: `layout.zig`nin `genClassVtable`ıyla AYNI desende statik bir
    `$__nox_decorators` `.data` tablosu (`compiler/codegen_qbe/
    decorators.zig`, yeni dosya) + 7 SABİT-imzalı derleyici yerleşiği
    (`__nox_reflect_decorator_count/target_name/name/arg_count/arg/
    is_handler/handler`).
  - `stdlib/nox/reflect.nox` (yeni): bu yerleşikleri saran ince bir API +
    `router_from_decorators()` — `@get`/`@post`/`@put`/`@delete` İLE
    decore edilmiş, `(ctx: Context) -> HttpResponse` imzalı TÜM
    fonksiyonlardan MEVCUT `nox.router.Router`ı (hiçbir değişiklik
    gerekmeden) inşa eden, ÖRNEK bir tüketici.
  - `noxc expand <dosya.nox>` (yeni CLI alt-komutu): derleyicinin
    decorator'lardan çıkardığı metadata'yı insan-okunur biçimde yazdırır
    (şeffaflık — GERÇEK bir kod dönüşümü OLMADIĞINDAN "üretilen kod"
    GÖSTERİLMEZ).
  - GERÇEK bir tasarım tuzağı bulunup düzeltildi: Nox'un `T | None`
    sözdizimi bir `(P) -> R` func_type'ını SARAYAMAZ (`| None` HER ZAMAN
    en yakın DÖNÜŞ tipine bağlanır, `parseBaseTypeExpr`nin func_type
    dalının KENDİ İÇİNDE `parseTypeExpr`i özyinelemeli çağırması nedeniyle
    — `list[(Context) -> HttpResponse | None]` middleware imzasının VAR
    OLAN, ÇALIŞAN semantiğini BOZMAMAK İçin BİLEREK dokunulmadı) — bu
    yüzden "Optional handler" YERİNE AYRI bir `__nox_reflect_decorator_
    is_handler(i) -> bool` erişimcisi eklendi (`decorator_handler(i)`
    NON-optional kalır, çağıran ÖNCE `is_handler`ı kontrol eder).
  - 10 yeni test: 4 parser (sözdizimi), 3 checker golden (literal-olmayan
    argüman reddi, sınıf-decorator reddi, temel kabul), 1 codegen golden
    (uçtan uca GET+POST router dispatch'i), 1 CLI test (`noxc expand`).

## [1.20.0]

### Eklendi
- **`hpy_call_str` yerleşiği**: `hpy_call`in (yalnızca `int` argüman/dönüş,
  `HPyFunc_O` imzalı metodlar) YALNIZCA `str` argüman/dönüşlü kardeşi —
  `HPyFunc_KEYWORDS` imzalı metodları (JSON encoder'ların YAYGIN kullandığı
  kayıt biçimi, ör. `ujson_hpy.dumps`/`loads`) POZİSYONEL-TEK-ARGÜMAN
  (anahtar kelime OLMADAN) çağırır. `hpy_call`in AYNI güvenlik kısıtları
  geçerlidir (yol/uzantı-adı/fonksiyon-adı yalnızca string LİTERALİ
  olabilir). `runtime/hpy_bridge/loader.zig`ye `findMethodKeywords`
  eklendi. Kullanıcının kendi `hpy-ujson` portu (upstream UltraJSON'un
  HPy Universal ABI'ye taşınmış hali) İLE GERÇEKTEN doğrulandı:
  `ujson_hpy.dumps("hello world")` → `"hello world"`, `ujson_hpy.
  loads("\"decoded value\"")` → `decoded value` — 500 yinelemede sıfır
  sızıntı. `tests/compat/hpy_ext/noxtest.c`ye YENİ bir `HPyFunc_KEYWORDS`
  test metodu (`upper_str_via_c`) + yeni bir golden test eklendi.

## [1.19.0]

### Eklendi
- **HPy köprüsünde yerleşik tip tekilleri**: `h_LongType`/`h_FloatType`/
  `h_BoolType`/`h_UnicodeType`/`h_TupleType`/`h_ListType`/`h_BytesType`
  (`HPyContext`) ÖNCEDEN HİÇ doldurulmuyordu — `HPy_Type` bu tiplerde
  `HPy_NULL` döndürüyordu. Bu, `HPyType_IsSubtype(ctx, HPy_Type(ctx,
  deger), ctx->h_FloatType)` GİBİ bir tip-dispatch deseni kullanan (JSON
  encoder'ların YAYGIN kullandığı) HPy eklentilerinin (kullanıcının kendi
  `hpy-ujson` portu ARAŞTIRMASI SIRASINDA bulundu) HER ZAMAN yanlış
  sonuç üretmesine yol açıyordu. Artık bu 7 tekil GERÇEK yerleşik-tip
  handle'larıyla dolduruluyor, `HPy_Type` yerleşik tipler İçin doğru
  tekili döner — `ctx_Type_IsSubtype`nin KİMLİK karşılaştırması bu
  dispatch deseni İçin ARTIK doğru çalışır. Yeni birim testi eklendi.

## [1.18.1]

### Düzeltildi
- **`noxc install`/`add` sabit `"main"` dal varsayımı**: `--ref` AÇIKÇA
  verilmediğinde repo'nun GERÇEK varsayılan dalına (`git ls-remote
  --symref`) bakmadan sabit `"main"` varsayıyordu — varsayılan dalı
  `master` (ya da başka bir isim) olan repolar İçin (GERÇEKTEN gözlemlendi:
  `github.com/mburakmmm/nyx`) `noxc install <alias>` HER ZAMAN
  `GitCommandFailed` İLE başarısız oluyordu. Artık GERÇEK varsayılan dal
  otomatik tespit edilir; tespit başarısız olursa sessizce eski `"main"`
  varsayımına düşülür (geriye dönük DAVRANIŞ DEĞİŞMEZ).
- **P1c — modül-global + terfi ETMEMİŞ üst-düzey değişken → derleyici
  paniği**: `genNoxInitGlobals`, `module.body`deki HER `var_decl`nin
  `module_globals`e TERFİ ETTİĞİNİ VARSAYIYORDU — GERÇEKTE terfi yalnızca
  adı bir fonksiyon/metod gövdesinden (iç içe `def`ler DAHİL) REFERANS
  alınan `var_decl`lere UYGULANIR. Programda (paket İÇİ DAHİL) HERHANGİ
  bir global terfi ETTİĞİ anda, terfi ETMEMİŞ SAF bir üst-düzey betik
  değişkeni (ör. hiçbir fonksiyondan erişilmeyen bir `y: int = 5`)
  `.get(v.name).?`de panige/segfault'a yol açıyordu — kullanıcı repro'suyla
  (paket modülü global + nested closure middleware) doğrulandı.
- **C2 — `(T) -> dict[K,V]` fonksiyon-tipli parametre üzerinden dolaylı
  çağrı, sonucu inline argüman olarak geçtiğinde çöküyordu**:
  `genIndirectCallThroughClosurePtr`, döndürdüğü `Value`de `dict_info`yi
  KOPYALAMAYI unutuyordu — dönüş değeri (`heap == .dict`) BAŞKA bir çağrıya
  DOĞRUDAN argüman olarak geçirildiğinde (ör. `use_ctx(to_context_fn(rows[i]))`),
  `releaseTemporaryArgs` bu TAZE `dict` değerini serbest bırakmaya
  çalışırken `dict_info.?`nin null olmasıyla çöküyordu (derleme-zamanı
  panik Debug'da, SIGSEGV ReleaseFast'te). Bir yerel değişkene atayıp SONRA
  geçirmek geçici çözümdü — artık gerek YOK.
- Her iki codegen hatası İçin (`module_global_plus_unpromoted_local`,
  `inline_closure_call_returns_dict`) yeni golden test eklendi.

## [1.18.0]

### Değiştirildi
- **`str` ABI değişikliği — uzunluk alanı + ASCII bayrağı** (kök-seviyeli
  bir runtime değişikliği, davranış AYNI kalıyor): `str`in temsili
  `[8 bayt refcount][8 bayt paketlenmiş uzunluk+ascii][baytlar...NUL]`
  oldu (ÖNCEDEN uzunluk alanı YOKTU). `len()`/`s[i]` artık ASCII
  string'lerde (pratikte ÇOĞU) O(1) — codepoint taraması TAMAMEN
  atlanıyor; ASCII-OLMAYAN string'ler İçin tek bir tarama tembel (lazy)
  yapılıp SONUÇ önbelleklenir. NUL-sonlandırma KORUNDU — `extern def`/HPy
  geçişi ETKİLENMEDİ. Ölçüm (bkz. `benchmarks/str_len_many_strings.nox`,
  Apple M4, ReleaseFast): bir `list[str]`in FARKLI elemanları üzerinde
  tekrarlanan `len()` çağrıları İçin **~11x hızlanma** (~110ms → ~10ms).
  Kabul edilen ödünleşim: kısa string ağırlıklı iş yüklerinde tepe bellek
  ayak izinde ~%24 artış (8 bayt/string başlık maliyeti — bkz.
  nox-teknik-spesifikasyon.md §3.76).

## [1.17.1]

### Düzeltildi
- **`nox.json.decode()` yaprak-başına gereksiz tahsis israfı**: her yaprak
  düğüm (null/bool/number/string) — VE dizi/obje düğümlerinin kullanılmayan
  `keys`/`vals`/`arr` alanları — ÖNCEDEN kendi ayrı boş `list`lerini (+ boş
  `str`ini) tahsis ediyordu (yaprak başına EN AZ 4 heap tahsisi). Artık TEK
  bir paylaşılan boş `list` + paylaşılan boş `str` (`nox_json_decode_raw`
  çağrısı başına BİR KEZ inşa edilir) `nox_rc_retain`le TÜM düğümler
  arasında paylaşılıyor — tahsis sayısı belge boyutundan BAĞIMSIZ sabit
  kalıyor. Ölçüm (200 nesnelik bir dizinin 100 kez decode edilmesi,
  Apple M4, ReleaseFast): **~16.0s → ~7.0s (~2.3x)**. DebugAllocator'lı
  200.000 yinelemelik bir sızıntı testiyle doğrulandı (sabit ~1.8MB tepe
  bellek ayak izi).
- Bu düzeltme sırasında GERÇEK bir regresyon bulunup AYNI oturumda
  düzeltildi: paylaşılan-boş-nesne kurulumunun `parseFromSlice`DEN ÖNCE
  yapılması, `rt=null` İLE çağrılan İZOLE test bağlamlarında (`nox_rc_alloc`nin
  havuz hızlı-yolu gerçek bir `RuntimeState` gerektirdiğinden) GEÇERLİ
  JSON'u BİLE `nox_json_last_op_ok()=false` olarak işaretliyordu — kurulum
  artık parse BAŞARISINDAN SONRAYA taşındı, `g_last_op_ok` yalnızca JSON
  sözdizimi geçerliliğini yansıtır.

## [1.17.0]

### Eklendi
- **GLOBAL paket kurulumu**: `noxc install <paket|repo> [--ref <ref>]` —
  bir paketin `nox.json`sinde bildirilen `bin` girdi noktasını (YENİ
  opsiyonel `Manifest.bin: {name, path}` alanı) derleyip `{nox_home}/bin/`
  (varsayılan `~/.nox/bin/`) altına GLOBAL bir ikili olarak kurar — `pip`/
  `cargo install`/`pipx` tarzı, `noxc`nin KENDİ araç-zinciri kurulumundan
  (`~/.nox-lang/bin/`) bilinçli olarak AYRI bir dizin/kayıt (`{nox_home}/
  pkg/installed.json`). `noxc uninstall <komut-adi>` kurulu ikiliyi kaldırır
  (paylaşılan paket önbelleğine dokunmadan); `noxc list` global kurulu tüm
  komutları listeler. PATH'te değilse tek satırlık bir `export PATH=...`
  ipucu bir kez yazdırılır (shell rc dosyaları OTOMATİK düzenlenmez).

### Düzeltildi
- `noxc add`/`noxc delete`, manifest'i yeniden yazarken YENİ `bin` alanını
  SESSİZCE siliyordu (kod incelemesiyle bulundu, test hatası DEĞİL).
- `noxc list` çıktısını stderr'e yazıyordu — `noxc search`le TUTARLI
  olacak şekilde stdout'a taşındı (uçtan-uca testle yakalanan gerçek hata).

## [1.16.1]

### Değiştirildi
- README.md/README.en.md'nin özellik listesine tek-kalıtım (`class
  Derived(Base):`) eklendi (v1.16.0'ın dokümantasyon takibi).

## [1.16.0]

### Eklendi
- **Basit tek-kalıtım**: `class Derived(Base):` — tek bir taban sınıf,
  metod override (taban ile TAM imza eşleşmesi gerektirir), `super().
  __init__(...)` ile AÇIK kurucu zincirleme, `super().metod(...)` (HER
  ZAMAN doğrudan, asla vtable üzerinden — sonsuz özyinelemeyi önler).
  Taban-tipli bir değişken/liste/fonksiyon parametresi bir alt sınıf
  örneğini tutabilir ve `obj.metod()` ÇALIŞMA ZAMANINDA doğru override'a
  gider (yeni bir vtable mekanizması — closure'ların `fn_ptr` başlığıyla
  aynı ruh). `except Base:` bir `Derived` örneğini de yakalar (hiyerarşik
  `class_id` eşleşmesi). `xs: list[Animal] = [Dog(...), Cat(...)]` gibi
  polimorfik liste literalleri artık kabul ediliyor. **Bilinçli v1
  kapsamı**: çoklu kalıtım yok; generic sınıf + kalıtım etkileşimi yok
  (açıkça reddedilir); kovaryant dönüş/kontravaryant parametre yok;
  kalıtıma katılan bir sınıfın TÜM metod çağrıları (override edilsin
  edilmesin) vtable üzerinden dolaylı yapılır — devirtualization
  (orijinal tasarımda planlanan bir optimizasyon) "hangi metod herhangi
  bir yerde override ediliyor" bilgisinin taban sınıf kaydedilirken
  bilinemeyeceği gerçeğiyle çatıştığından v1'de basitleştirildi; kalıtıma
  HİÇ katılmayan sınıflar (Nox kodunun büyük çoğunluğu) için nesne
  düzeni/performans birebir öncekiyle aynı kalır (tam regresyon suitiyle
  doğrulandı — mevcut tüm sınıf golden testleri byte-bir-byte aynı çıktı
  üretmeye devam etti); `$ClassName_eq` (yapısal `==`) hâlâ statik/alıcı-
  tipi tabanlı (bir alt sınıfın ek alanlarını görmez — bellek-güvenli ama
  semantik bir sürpriz, düşük öncelik olarak kaydedildi).

### Düzeltildi
- **Kalıtıma katılan bir sınıfın taban-tipli release'i alt sınıfın ek
  alanlarını sessizce atlıyordu** (bellek bozulmaz, ama alt sınıfın ek
  alanlarının kendi iç referansları hiç serbest bırakılmazdı — gerçek bir
  sızıntı) — `releaseValueIfSet`/`genListElemRelease` artık bare
  `except:`in zaten kullandığı çalışma-zamanı etiket dağıtımına
  (`nox_class_release_dispatch`) yönlendiriliyor.
- **Sıfır sanal metotlu (yalnızca `__init__`) kalıtımsal bir sınıf
  bağlantı hatasına yol açıyordu** — `genConstructFromValues` var
  olmayan bir `$ClassName_vtable` sembolüne koşulsuz referans veriyordu.

## [1.15.0]

### Eklendi
- **`nox.sharedmem`**: GERÇEK, isimli bir paylaşımlı bellek (shared-memory)
  IPC ilkeli — `shm_open`+`mmap(MAP_SHARED)` (macOS/Linux) ile BAĞIMSIZ
  (fork EDİLMEMİŞ) `noxc run` çalıştırmalarının AYNI bellek bölgesini
  GÖRMESİNİ sağlar (limitasyon #6: "process'ler arası paylaşılan state
  yok, sadece per-process modül globals" — bkz. proje belleği "nyx v2
  limitasyon listesi doğrulaması"). `SharedBuffer` sınıfı: `lock()`/
  `unlock()` (basit bir spinlock, Go-tarzı `defer` ile eşleştirilmesi
  ÖNERİLİR), `read_int`/`write_int` (ham 8 bayt, `str` ARA KATMANI
  ATLANARAK — bkz. aşağıdaki düzeltme notu), `read_str`/`write_str`.
  `close()` sadece bu process'in eşlemesini kapatır (segment DİĞER
  process'ler için YAŞAMAYA devam eder), `unlink(name)` segmenti KALICI
  olarak SİLER (`nox.sqlite`nin dosya-silme deseniyle TUTARLI). Windows
  için `CreateFileMappingA`/`MapViewOfFile` ile GERÇEK bir implementasyon
  hedeflendi (derleme zamanında doğrulandı, çalışma zamanı Windows testi
  bu ortamda YAPILAMADI). GERÇEK iki AYRI `noxc run` process'iyle
  (`tests/cli/shared_mem_test.zig`) uçtan uca doğrulandı.

### Düzeltildi
- **`nox.sharedmem`: macOS'ta ikinci process'in `shm_open`ı HER ZAMAN
  başarısız oluyordu** — `openPosix` KOŞULSUZ olarak `ftruncate`
  çağırıyordu, ama macOS ZATEN boyutlandırılmış bir POSIX shm nesnesine
  TEKRAR `ftruncate` çağrılmasını `EINVAL` ile REDDEDİYOR (Linux'un
  AKSİNE) — bu YÜZDEN paylaşımlı belleği İLK AÇAN process ÇALIŞIYORDU
  ama İKİNCİ/SONRAKİ HER process (yani ÇAPRAZ-PROCESS paylaşımın TAMAMI)
  BOZUKTU. GERÇEK iki-process testiyle YAKALANDI. Düzeltme: `ftruncate`
  ÖNCESİ `fstat` ile MEVCUT boyut kontrol edilir, ZATEN yeterince
  büyükse `ftruncate` hiç ÇAĞRILMAZ.
- **`nox.sharedmem`: int'lerin `str` üzerinden ham bayt olarak
  kodlanması ARC çift-serbest-bırakmaya yol açıyordu** — ilk tasarım
  `read_int`/`write_int`i `char_from_byte`/`byte_at` ile 8 baytlık bir
  `str`e kodluyordu, ama Nox'un TÜM `str` temsili sıfırla-sonlanan
  (`strlen`-tabanlı) OLDUĞUNDAN (bkz. `runtime/str.zig`) GÖMÜLÜ bir NUL
  bayt (küçük int'lerin YÜKSEK baytları İçin YAYGIN) ARC boyut hesabını
  BOZUYORDU (GERÇEK bir "Allocation size N does not match free size N-1"
  çökmesiyle KANITLANDI). Düzeltme: int'ler İçin `nox_shm_read_i64_raw`/
  `nox_shm_write_i64_raw` (Zig şiminde YENİ) ile `str` ARA KATMANI
  TAMAMEN ATLANDI — bu, Nox'un DAHA GENİŞ "string'ler gömülü NUL
  taşıyamaz" kısıtının bilinen bir sonucu, YENİ bir dil hatası DEĞİL.

## [1.14.0]

### Eklendi
- **`nox.tls`**: ham bir TLS akışı ilkeli (`connect`/`write`/`read`/
  `close`) — Zig'in KENDİ `std.crypto.tls.Client`ini ham bir soket
  üzerinde DOĞRUDAN sürer (sqlite/postgres/mysql'in dlopen desenlerinin
  AKSİNE SAF Zig kodudur, HİÇBİR harici bağımlılık YOK). Sistemin CA
  sertifika deposuna (`std.crypto.Certificate.Bundle.rescan`, platform
  bağımsız) karşı sunucu sertifikasını doğrular. GERÇEK bir uzak sunucuya
  (`example.com`) karşı uçtan uca doğrulandı. **Bilinçli v1 kapsamı**:
  SADECE İSTEMCİ (Zig std kütüphanesinde bir TLS SUNUCUSU HENÜZ YOK).
- **`nox.websocket`**: RFC 6455 WebSocket istemcisi (`connect`/`send_text`/
  `recv`/`close`) — `ws://`/`wss://` el sıkışması (SHA1/base64 doğrulaması
  DAHİL) + frame kodlama/çözme/maskeleme. GERÇEK bir uzak sunucuya
  (`wss://ws.postman-echo.com/raw`) karşı TAM round-trip doğrulandı.
  **Bilinçli v1 kapsamı**: SADECE İSTEMCİ (`nox.http.serve`nin karmaşık
  async sunucu mimarisine bir Upgrade-hijack yolu eklemek bu fazın kapsamı
  DIŞINDA bırakıldı).

## [1.13.0]

### Eklendi
- **`nox.postgres`: parametreli sorgu desteği** — `Connection.prepare(sql)`
  bir `Statement` döner (`bind_int`/`bind_float`/`bind_str`/`bind_null`
  sonra `execute()`/`query()`) — libpq'nun `PQexecParams`i (TEK çağrıda
  TÜM parametreleri kabul eder, sqlite'ın GERÇEK artımlı bind'inden FARKLI
  "biriktir-sonra-ateşle" felsefesiyle) kullanılır. `bind_null` GERÇEK SQL
  `NULL` üretir (libpq'ya `NULL` C işaretçisi geçirilerek).
- **`nox.mysql`: parametreli sorgu desteği + `last_insert_rowid()`** —
  `Connection.prepare(sql)` AYNI `Statement` API'sini sunar, ama İÇ
  MEKANİZMA `mysql_real_escape_string` İLE İSTEMCİ-TARAFLI GÜVENLİ kaçışlama
  KULLANIR (GERÇEK `mysql_stmt_*` sunucu-taraflı hazır deyimleri DEĞİL —
  `MYSQL_BIND` struct'ının ÇOK-TİPLİ, ABI-KIRILGAN TAM Zig karşılığına
  girmeden, AYNI GÜVENLİK garantisini SQL-enjeksiyona karşı sağlayan
  BİLİNÇLİ bir tasarım kararı, bkz. `runtime/stdlib_shims/mysql.zig`nin
  belge notu). `Connection.last_insert_rowid()` EKLENDİ (`mysql_insert_id`
  — Postgres'in AKSİNE MySQL bunu DOĞRUDAN destekler).
- **`nox.db.DbConnection`**: `nox.sqlite`/`nox.postgres`/`nox.mysql`nin
  ÜÇÜNÜN de `Connection` sınıfının PAYLAŞTIĞI `close(self) -> None`
  metodu İçin yapısal (duck-typed) bir `protocol` — kullanıcı kodu tek
  bir sürücüye BAĞLI KALMADAN yazılabilir. **Bilinçli kapsam sınırlaması**:
  `execute`in dönüş tipi (sqlite: `None`, postgres/mysql: `int` — ÖNCEDEN
  VAR OLAN bir tasarım ayrışması, geriye dönük uyumluluk İçin DEĞİŞTİRİLMEDİ)
  VE `query`nin dönüş tipi (`Row` üç sürücüde AYRI concrete sınıflar)
  protokole DAHİL EDİLEMEDİ (bkz. `stdlib/nox/db.nox`nin belge notu).

## [1.12.1]

### Düzeltildi
- **Paket alias zorunluluğu kaldırıldı**: bir paketin KENDİ İÇ `import X.Y`
  deyimleri ÖNCEDEN TÜKETİCİNİN `nox.json`ındaki `requires[].alias`ına
  karşı çözülüyordu — yani paket YALNIZCA tüketici TESADÜFEN aynı alias'ı
  seçerse doğru çalışıyordu (nyx İçin bu, `alias: "nyx"` ZORUNLULUĞU
  anlamına geliyordu, doğrulanan bir nyx v2 limitasyonuydu). Artık her
  paketin KENDİ `nox.json`ındaki `name` alanı okunuyor — bir paketin
  kendi-içi import'ları KENDİ adıyla çözülür, tüketicinin seçtiği alias NE
  OLURSA olsun. `nox.json`ı olmayan (veya `name` alanı boş) eski/basit
  paketler İçin davranış DEĞİŞMEDİ (geriye dönük UYUMLU).

## [1.12.0]

### Eklendi
- **Nitelikli (`pkg.module.ClassName`) tip adları artık tip-açıklaması
  konumunda kullanılabiliyor** (`var_decl`/fonksiyon parametresi/dönüş
  tipi) — ÖNCEDEN `import pkg.module` (nitelikli import, `from pkg.module
  import ClassName` DEĞİL) sonrası bu, parser'da `UnexpectedToken` hatasına
  yol açıyordu (tip adı İçin TEK bir `identifier` token'ı bekleniyordu,
  noktalı yol DEĞİL); nitelikli isimler SADECE İFADE konumunda (`pkg.
  module.ClassName(...)` bir kurucu çağrısı) ÇALIŞIYORDU. `import ... as`
  İLE gelen modül takma adları da ÇÖZÜLÜYOR. Bu, bir nyx v2 limitasyon
  iddiasının ("fonksiyon-tipi parametre SIGSEGV veriyor") araştırılması
  sırasında bulunan GERÇEK, önceden bilinmeyen bir kısıttı — asıl semptom
  SIGSEGV DEĞİLDİ ama kökeni AYNIYDI.

## [1.11.2]

### Düzeltildi
- **GERÇEK, doğrulanmış ARC çift-serbest-bırakma kök nedeni bulunup
  düzeltildi** (v1.11.1'de bulunan "list[T] döndüren fonksiyon + `while`
  döngüsü" çökmesinin kök nedeni): `ownership.zig`nin
  `releaseNamedLocalsExcept`i, bir callee `return <isim>` (çıplak
  identifier) İLE bir değeri ARAYANA "taşıdığında", o yerelin SLOT'unu
  SIFIRLAMIYORDU — inline edilmiş bir çağrı sitesinin slotu bir `while`
  döngüsü İÇİNDE YENİDEN KULLANILDIĞINDA, bir SONRAKİ yinelemenin KENDİ
  `var_decl`i BU STALE (artık arayana ait) işaretçiyi HÂLÂ "canlı" SANIP
  TEKRAR serbest bırakıyordu (çift serbest bırakma). `.ssa` çıktısı
  dump edilerek KANITLANDI (Faz JJ'nin `releaseSlotIfSet`de düzelttiği
  AYNI kök nedenin "identifier ile taşınan" varyantı).
- Bu kök-neden düzeltmesinden SONRA, v1.11.1'de GÜVENSİZ bulunup GERİ
  ALINAN 4 sızıntı düzeltmesi (`genIndex`/`genStrIndex`/`genListAssign`/
  `genDictGet`nin sınır-kontrolü/eksik-anahtar hata dalları) GÜVENLE
  yeniden eklendi — HER BİRİ 50 iterasyonluk gerçek döngü testiyle
  doğrulandı.
- **YENİ, önceden bilinmeyen bir sızıntı bulunup düzeltildi**: `d[key]`
  (`genIndex`nin `dict` dispatch dalı) taban sözlük TEMPORARY İSE (ör.
  `make_dict()[key]`) hiçbir zaman serbest bırakılmıyordu (ne başarı ne
  hata dalında) — `str`-değerli sözlükler İçin retain-önce-serbest-bırak
  korumasıyla birlikte düzeltildi (aksi halde kullanım-sonrası-serbest-
  bırakma riski vardı).

## [1.11.1]

### Düzeltildi
- **GERÇEK 4 bellek sızıntısı düzeltildi** (v1.11.0'ın "genMethodCall/
  genListPop" düzeltmesinin AYNI sınıfı — istisna kontrolünden ÖNCE
  serbest bırakma sırası): `genIndirectCallThroughClosurePtr` (dolaylı
  closure çağrıları), `genCall`nin serbest fonksiyon dağıtımı (derleyicideki
  EN SIK çalışan yol), VE `genConstructFromValues` (`__init__` istisna
  fırlatırsa HEM argümanların HEM TAM İNŞA EDİLMEMİŞ `self`in KENDİSİNİN
  sızması — ikincisi YENİ bulunan, AYRI bir alt-hataydı).

### Bilinç notu (düzeltilmedi, bilinçli olarak)
- `genIndex`/`genStrIndex`/`genListAssign`nin sınır-dışı-erişim hata
  dallarındaki (list/str `[i]`) BENZER bir sızıntı İçin "AÇIK" düzeltme
  (`genListPop`nin AYNI deseni) DENENDİ ama bir `while` döngüsü İÇİNDE
  (3+ yineleme) `incorrect alignment` PANİĞİYLE ÇÖKMEYE yol açtığı
  bulundu — sızıntıdan DAHA KÖTÜ bir regresyon olduğundan GERİ ALINDI.
  Bu araştırma sırasında AYRI, DAHA CİDDİ bir hata da bulundu: `list[T]`
  DÖNEN bir fonksiyonun bir `while` döngüsü İÇİNDE bir yerele TEKRAR
  TEKRAR atanması (İSTİSNA/hata OLMADAN, TAMAMEN normal kod) AYNI
  çökmeye yol açıyor — `v1.11.0`de ZATEN VAR OLAN, bu oturumdan BAĞIMSIZ
  bir hata. HER İKİSİ de AYRI bir görev olarak kaydedildi (bkz. proje
  belleği "ARC sızıntı düzeltmeleri follow-up").

## [1.11.0]

### Eklendi
- **`nox.collections`**: `Stack[T]`/`Queue[T]`/`Deque[T]`/`Set[T]`/
  `Counter[T]`/`OrderedDict[K,V]`/`LRUCache[K,V]`/`Heap[T]`/
  `PriorityQueue[T]` — tamamen saf Nox, arite-genel `class Foo[T, ...]:`
  generic sınıfları üzerine (`Pair[K,V]` tarzı çok-parametreli generic
  sınıfların İLK gerçek kullanımı — bu SIRADA `checker.zig`/`codegen_qbe/
  registration.zig`nin `.generic` tip ifadesi çözümlemesinde `from X
  import Y` İLE getirilen generic sınıflar İçin eksik bir `from_imports`
  geri düşüşü bulunup İKİSİ de düzeltildi).
- **Yeni derleyici ilkeli: `list[T].pop()`** — son elemanı kaldırıp döner
  (boş listede `IndexError`). `.append`in AKSİNE alıcı keyfi bir ifade
  olabilir (`self.items.pop()` doğrudan geçerli).
- **`nox.url`**: `URL.parse`/`percent_encode`/`percent_decode`/
  `query_encode`/`query_decode`/`join` — `nox.strings`e İKİ küçük yeni
  ilkel eklendi (`char_from_byte`, `byte_len`) percent-decode'un çok-
  baytlı UTF-8'i doğru işlemesi İçin.
- **`nox.process`**: `Command`/`Output` — fiber-uyumlu (zamanlayıcıyı
  KİLİTLEMEYEN) alt-süreç çalıştırma (`std.process.run` üzerine,
  `nox.http`nin İSTEMCİSİYLE AYNI arka-plan-iş-parçacığı+self-pipe
  köprüleme deseni).
- **`nox.postgres`/`nox.mysql`**: `libpq`/`libmysqlclient`e çalışma
  zamanında tembel bağlanan (statik bağımlılık KATMAYAN, `nox.sqlite`nin
  AYNI deseni) veritabanı sürücüleri — Docker'daki gerçek postgres:16/
  mysql:8 sunucularına karşı TAM CRUD (INSERT/SELECT/tip-NULL/hatalı-
  sorgu/hatalı-bağlantı) doğrulandı.

### Düzeltildi
- **GERÇEK bir bellek sızıntısı**: geçici (isimsiz, bir değişkene
  bağlanmamış) bir sınıf örneği/liste üzerinde ÇAĞRILAN bir metod/işlem
  İSTİSNA fırlatırsa (ör. `Command("yok").run()`), alıcı/argümanların
  serbest bırakılması `emitExceptionCheck`nin kaçış dalında HİÇ
  ÇALIŞMIYORDU (kontrol HER ZAMAN serbest-bırakma kodundan ÖNCE
  atlıyordu) — `genMethodCall`/`genListPop` düzeltildi; YAPISAL OLARAK
  AYNI hata (`genCall`nin serbest fonksiyon/dolaylı-closure çağrı
  yolları, `genConstruct`, `genIndex`/`genStrIndex`, İKİ `stmt.zig`
  sitesi) HENÜZ giderilmedi, AYRI bir görev olarak kaydedildi.

## [1.10.0]

### Eklendi
- **Modül-seviyesi global durum**: üst-düzey (script top-level) bir
  `var_decl`, ARTIK herhangi bir fonksiyon/metod gövdesinden (HEM okuma
  HEM yazma, iç içe `def`ler DAHİL) görülebiliyor — `docs/NOX_LIMITATIONS.
  md`nin (`nyx` framework) VE `services/noxpkg/`nin BAĞIMSIZ olarak
  çarptığı AYNI kısıt artık YOK. YENİ bir `global` anahtar kelimesi
  EKLENMEDİ (bilinçli tasarım kararı) — Nox'ta çıplak bir atama zaten
  ÖNCEDEN VAR OLAN bir ismi gerektirdiğinden (Python'daki "yeni yerel mi
  global güncelleme mi" belirsizliği hiç yok), yerel/parametre/yakalama
  kapsamında BULUNAMAYAN çıplak bir isim OTOMATİK olarak modül-global'e
  düşer; mevcut yerel gölgeleme her zaman ÖNCELİKLİDİR. Depolama: her
  OS iş parçacığının (`nox.http.serve_multicore`nin HER worker'ı,
  `nox.thread.start`nin HER worker'ı DAHİL) KENDİ bağımsız, taze
  ilklendirilmiş global bloğu vardır — worker'lar ARASI PAYLAŞILMAZ
  (ARC refcount'larının atomik OLMAMASIYLA tutarlı, bilinçli v1 kararı).
  `stdlib/nox/router.nox`nin `Router`u ARTIK script top-level'da BİR KEZ
  inşa edilip `handle`den REFERANS alınabiliyor (`services/noxpkg/main.
  nox` bu deseni KULLANACAK şekilde basitleştirildi — ÖNCEDEN her istekte
  `build_router()` çağırmak ZORUNDAYDI).

### Düzeltildi
- `list_build_index_iterate.nox` benzeri, HİÇBİR fonksiyonu OLMAYAN
  programları DAHİL 22 golden testi kıran bir REGRESYON (bu özelliğin
  geliştirilmesi SIRASINDA bulunup düzeltildi, YAYIMLANMADAN önce):
  otomatik-enjekte edilen builtin sarmalayıcıların (ör. `sum(xs: list
  [int])`) KENDİ parametre isimleri, kullanıcının İLGİSİZ üst-düzey
  değişkenleriyle SADECE isim çakışması yüzünden "modül-global kullanımı"
  sayılıyordu — düzeltme, bir fonksiyon ağacının KENDİ bağladığı
  (parametre/yerel/for-döngüsü/except-as/with-as) isimleri artık
  ÇIKARIYOR, yalnızca GERÇEKTEN serbest isimler global sayılıyor.

## [1.9.0]

### Eklendi
- **Çıplak `except:`** (tipsiz, HERHANGİ bir bekleyen istisnayla eşleşen
  bir yakalama yan tümcesi) — Python'un kendi kısıtıyla tutarlı, yalnızca
  SON `except` yan tümcesi olabilir (aksi halde net bir ayrıştırma
  hatası). `finally` zaten çalışıyordu (`nyx` framework'ün gözlemlediği
  ~1.6.x'ten beri) — `docs/NOX_LIMITATIONS.md` (P5) İLE raporlanan eksik
  yalnızca ÇIPLAK `except:`ydi.

### Düzeltildi
- **GERÇEK bir bellek sızıntısı**: `as e:` bağlaması OLMAYAN bir `except`
  (hem tipli hem YENİ çıplak biçim) yakaladığı istisna nesnesini HİÇBİR
  ZAMAN serbest bırakmıyordu (`nox_exception_take`in döndürdüğü nesne
  hiçbir yerelde saklanmadığından normal kapsam-sonu temizliği devreye
  girmiyordu) — bu, ÇIPLAK `except:` eklenmeden ÖNCE de var olan bir
  hataydı (`except SomeType:` — bağlamasız — İLE de tetiklenebilirdi).
  Çözüm: yeni bir çalışma-zamanı dağıtım fonksiyonu (`nox_class_release_
  dispatch`, `nox_trace_dispatch`/`nox_gc_free_dispatch` İLE AYNI
  "sınıf-id'ye göre doğru fonksiyona dal aç" deseninde) — istisnanın
  ÇALIŞMA-ZAMANI sınıfı derleme zamanında bilinmese bile (Nox'ta kalıtım/
  RTTI olmadığından HERHANGİ bir sınıf raise edilebilir) doğru `_release`
  fonksiyonuna dal açar.

## [1.8.2]

### Düzeltildi
- `nyx` framework geliştirilirken bulunan, `docs/NOX_LIMITATIONS.md` İLE
  raporlanan 2 GERÇEK derleyici hatası düzeltildi:
  - **`\r` kaçışı** — İKİ AYRI yerde eksikti: `parser.zig`nin `decodeEscapes`i
    (düz VE f-string literalleri) VE `codegen_qbe/abi.zig`nin
    `escapeForQbeString`i (parser DOĞRU çözse BİLE, ham CR baytı `.ssa`
    metin dosyasına gömülünce QBE/`as` tarafından `\n`e bozuluyordu).
  - **`list[dict[K,V]]`** (bir dict listesi) codegen'de "desteklenmeyen
    bir yapı" hatasıyla çöküyordu — checker ZATEN kabul ediyordu, eksik
    olan codegen'in KENDİ `ElemHeapInfo`sunun `dict`in şeklini (`key_is_str`/
    `value_is_str`) taşıyacak bir alanının OLMAMASIYDI. İnşa (boş liste +
    append), listeler arası eleman okuma (`rows[i]["ad"]`), indeksle atama
    ve kapsam-sonu temizliği artık DOĞRU çalışıyor.
- `docs/NOX_LIMITATIONS.md`daki DİĞER maddelerin çoğu (C2/C3/C4/C6,
  `finally`) BU depoya karşı yeniden doğrulandı ve zaten ÇALIŞIYOR (nyx
  ~1.6.x'e karşı gözlemlenmişti, bu oturumdaki önceki düzeltmelerle ZATEN
  çözülmüştü).

## [1.8.1]

### Düzeltildi
- `services/noxpkg/` admin giriş sayfası artık ağ hatalarını (fetch
  reddi) sessizce yutmuyor (`.catch` ile görünür bir hata mesajı),
  gönderim sırasında butonu devre dışı bırakıp "giris yapiliyor..."
  gösteriyor (çift-gönderim/karışıklığı önler), ve şifre alanına
  `autocomplete="current-password"` eklendi (bazı tarayıcıların "güçlü
  şifre öner" davranışının giriş akışına karışmasını önler).

## [1.8.0]

### Eklendi
- **`noxc search <sorgu>`** (TEK argüman) artık `NOX_INDEX_URL`den
  (varsayılan: `noxpkg.2mtechnology.org` merkezi kaydı) sorgular —
  `noxc add`nin `repo` atlandığında AYNI varsayılana düşmesiyle TUTARLI.
  Açık indeksli iki argümanlı form (`noxc search <indeks> <sorgu>`)
  DEĞİŞMEDEN kalır.
- `services/noxpkg/`e herkese açık bir anasayfa (`GET /`) eklendi —
  yayındaki paketleri listeler, istemci-taraflı (sunucu sorgu-string
  ayrıştırması GEREKMEDEN) bir arama kutusuyla.

## [1.7.1]

### Düzeltildi
- `nox.http.serve`/`serve_multicore` artık `0.0.0.0`e (TÜM arayüzler)
  bağlanıyor — ÖNCEDEN sabit `127.0.0.1` idi, bu YÜZDEN Docker'ın NORMAL
  port-yönlendirmesi (`ports: "host:container"`) sessizce ulaşamıyordu
  (`services/noxpkg/` inşa edilirken bulundu, `network_mode: host`
  workaround'u artık gereksiz — geri alındı).
- Birinci-sınıf fonksiyon-değer mekanizması artık `from other_module
  import f` İLE alınan bir fonksiyonu ÇAĞRI DIŞINDA bir DEĞER olarak
  (ör. bir `list[(T)->U]`e KONULDUĞUNDA) da çözer — ÖNCEDEN yalnızca
  AYNI dosyada tanımlı fonksiyonlar İçin çalışıyordu, cross-module
  kullanım `UndefinedVariable` verirdi.
- `stdlib/nox/router.nox`nin belge notu, `Router`nin modül-üstünde bir
  KEZ inşa edilip `handle`den kullanılamayacağını (Nox'ta üst-düzey
  `var_decl` durumu HİÇBİR fonksiyon içinden görülemez) VE doğru
  deseni (HER istekte yeniden inşa) AÇIKÇA belgeler; bu regresyonu
  yakalayan yeni bir uçtan-uca test eklendi.

## [1.7.0]

### Eklendi
- **`noxc add <alias> [repo] [--ref <ref>]`** — bir bağımlılığı `nox.json`a
  ekler (zaten VARSA upsert — `repo`/`ref`i günceller). `repo`
  VERİLMEZSE, `NOX_INDEX_URL`den (varsayılan: `noxpkg.2mtechnology.org`
  merkezi indeksi, henüz yayında OLMASA bile env override'ıyla test
  EDİLEBİLİR) alias'ı ARAYIP çözer.
- **`noxc delete <alias>`** — bağımlılığı `nox.json`dan (VE `nox.lock`taki
  eşleşen girdiden) çıkarır.
- **`noxc publish <repo> [--ref <ref>] [--description <metin>] [--tags a,b,c]`**
  — paketin METADATASINI (kod/tarball YOK — mevcut GitHub-tabanlı
  mimariyle uyumlu) `NOX_PUBLISH_API_BASE`e (varsayılan: `noxpkg.
  2mtechnology.org`) gönderir; onay merkezi sitenin admin panelinden
  manuel yapılır, bu komut poll ETMEZ.
- `compiler/project.zig`ye `saveManifest` (`nox.json`i geri yazan İLK
  kod yolu — `saveLockfile` İLE AYNI desen) VE `compiler/pkg/registry.zig`
  (indeks-alias çözümü + yayınlama İSTEMCİSİ) eklendi.

## [1.6.1]

### Düzeltildi
- README.md/README.en.md'nin "HTTP verimi" tablosu Faz HH'nin keep-alive
  eklemesinden ÖNCEki, güncelliğini yitirmiş Nox sayılarını (~12-17K
  İstek/sn) gösteriyordu — `benchmarks/RESULTS.md`nin KENDİ, DAHA GÜNCEL
  sayısıyla (~165K-182K) bile TUTARSIZDI. Dört sunucu (Nox/Zig/Go/
  FastAPI) sıfırdan, 3'er koşumun ortancası olarak yeniden ölçüldü;
  `benchmarks/RESULTS.md`ye tarihli bir metodoloji notu eklendi.

## [1.6.0]

### Eklendi
- **`nox.template`** — saf Nox'ta yazılmış BASİT bir string-değiştirme
  HTML şablon motoru (bilinçli olarak dar kapsam: yalnızca `{{ isim }}`
  değişken yer-tutucuları, koşul/döngü YOK — "gerçek" bir Jinja-benzeri
  motor AYRI, daha büyük bir iş). Varsayılan olarak HTML-güvenli: `render`
  HER değişkenin değerini HTML özel karakterlerine göre kaçırır (XSS'e
  karşı temel savunma); zaten güvenli/istenerek HAM HTML İÇEREN bir değer
  İçin `render_unescaped` kullanılır. Kapatılmamış bir `{{`/tanımsız bir
  değişken çökmek YERİNE açık bir `TemplateError` fırlatır.

## [1.5.0]

### Eklendi
- **`nox.validate`** — `nox.json` üzerine saf Nox'ta yazılmış basit bir
  şema doğrulayıcı: bir `Schema`ya alan ADI/beklenen TİP ("string"/
  "number"/"bool"/"array"/"object"/"null")/zorunlu-mu kuralları eklenir
  (`require`/`optional`), SONRA bir `JsonValue`ya (`validate`) ya da
  doğrudan bir HTTP istek gövdesi gibi HAM JSON metnine (`validate_json_str`
  — geçersiz JSON'u da AYRI bir `try`/`except` GEREKMEDEN tek bir hata
  mesajına çevirir) karşı çalıştırılır; insan-okunur bir hata mesajı
  listesi döner (boşsa geçerli). Kapsam BİLİNÇLİ olarak DAR: tam bir
  JSON-Schema motoru DEĞİL, yalnızca DÜZ (iç içe OLMAYAN) alanlar İçin
  varlık + tip kontrolü — iç içe doğrulama kullanıcının `validate`i
  KENDİSİ özyinelemeli ÇAĞIRMASIYLA elde edilir.

## [1.4.0]

### Eklendi
- **Üst-düzey (non-generic) `def` fonksiyonları artık BİRİNCİ-SINIF bir
  DEĞER olarak kullanılabilir** — `f: (int) -> int = benim_fonksiyonum`
  gibi bir atama, bir `list[(T) -> U]`e eklenip `xs[i](v)` ile dolaylı
  çağrılabilme, VE bir sınıf ALANINA konulup `obj.alan(v)` ile
  çağrılabilme artık ÇALIŞIYOR (önceden yalnızca `f(v)` DOĞRUDAN çağrısı
  desteklenirdi). Checker, üst-düzey her fonksiyon İçin (`(l rt, ...params)`
  imzalı) sıfır-yakalamalı bir "trampoline" sarmalayıcı (`<isim>__fnval`,
  `(l rt, l %env, ...params)` imzalı, `%env`i yok sayıp gerçek fonksiyonu
  çağırır) üretilmesi GEREKENLERİ işaretler; codegen bunları OLAĞAN bir
  closure değeri gibi (ARC/retain/release DAHİL) üretir. Generic
  fonksiyonlar bilinçli olarak v1 kapsamı DIŞINDA bırakıldı (açık bir
  tip hatasıyla reddedilir).
- **`nox.uuid`** — saf Nox'ta, `nox.crypto`/`nox.random` üzerine yazılmış
  UUID v4 üretimi (`uuid4()`) ve doğrulaması (`is_valid(s)`).
- **`nox.router`** — `nox.http.serve`in ham TEK `handle` geri çağrısı
  üzerine saf Nox'ta yazılmış path-parametreli (`/users/:id`) yol
  yönlendirme + before/after ara katman (middleware) katmanı. Yukarıdaki
  birinci-sınıf fonksiyon değerleri OLMADAN (rota işleyicilerini/ara
  katmanları bir `list`te saklayabilmek GEREKTİĞİNDEN) mümkün değildi.

### Düzeltildi
- **GERÇEK bir erken-serbest-bırakma/bellek-bozulması hatası** (`nox.router`
  geliştirilirken bulundu): bir sınıf ALANI OLAN `list[T]`i büyütmenin
  TEK yolu olan "yerel değişkene oku → `.append()` et → geri yaz" deseninde
  (`.append`in alıcısı ÇIPLAK bir yerel OLMAK ZORUNDA — bkz. ilgili v1
  kısıtı), büyüme (`nox_list_grow`) ESKİ bloktaki eleman işaretçilerini
  YENİ bloğa retain'SİZ kopyalıyordu; `self.attr` HÂLÂ ESKİ bloğu
  görürken (writeback HENÜZ olmadan) bu ESKİ blok DAHA SONRA TAM
  özyinelemeli bir release İLE serbest bırakılınca, İÇİNDEKİ elemanlar
  HÂLÂ YENİ blok tarafından kullanılıyorken erken serbest bırakılıyordu.
  Artık büyüme sırasında kopyalanan HER heap-yönetimli eleman retain
  edilir, ESKİ blok BU ÇAĞRIDA gerçekten öldüğünde bu ek pay bir düz
  decrement İLE dengelenir.
- HER sınıf İçin otomatik üretilen `$ClassName_eq` (`Optional` daraltması
  `if x != None:` İçin GEREKİR — kullanıcı `==`/`!=` HİÇ kullanmasa BİLE),
  `list[(T) -> U]` gibi closure-elemanlı bir liste ALANINA rastladığında
  `unreachable`e düşüp ÇÖKÜYORDU; artık `dict`/`Task`/`Channel` İLE AYNI
  tutamaç-kimliği (pointer) karşılaştırmasına düşüyor.

## [1.3.0]

### Eklendi
- **`noxc upgrade [--check] [<sürüm>]`** — kurulu bir Nox araç zincirini
  (binary + `noxrt.o` + `nox.*` stdlib) KENDİ KENDİNE en son (ya da
  belirtilen — düşürme DAHİL) GitHub Release'e günceller, `install.sh`/
  `install.ps1`yi yeniden çalıştırmaya GEREK KALMADAN. Plan Mode ile
  tasarlandı (2 Explore + 1 Plan ajanı) VE GERÇEK GitHub altyapısına
  karşı (bir `/tmp` kopyasında, GERÇEK kurulu sistem HİÇ dokunulmadan)
  uçtan uca doğrulandı: `v1.0.0`e düşürüldü, SONRA açık bir sürüm PIN'iyle
  `v1.2.0`a geri yükseltildi, HER İKİ durumda da sonuç ikilinin KENDİ
  `--version`i doğrulandı. `--check`, kurulum/indirmeyi ATLAYIP yalnızca
  mevcut/en-son sürümü karşılaştırıp raporlar (script'ler İçin: güncelse
  çıkış 0, YENİ bir sürüm VARSA çıkış 1).
  **Güvenli değiştirme modeli:** indirme+çıkarma TAMAMEN bir `.upgrade-
  scratch` geçici dizininde yapılır (HERHANGİ bir aşama BAŞARISIZ olursa
  MEVCUT kurulum HİÇ dokunulmadan kalır — `install.sh`/`ps1`nin YIKICI
  "önce SİL" modelinden DAHA GÜVENLİ); yalnızca `bin/{noxc,noxlsp,qbe}`
  Windows'ta ÖNCE yeniden adlandırılıp (ÇALIŞAN bir `.exe` SİLİNEMEZ/
  ÜZERİNE YAZILAMAZ ama YENİDEN ADLANDIRILABİLİR) SONRA değiştirilir;
  geri kalan HER ŞEY doğrudan üzerine yazılır (Unix'te `Dir.copyFile`
  ZATEN rename-tabanlı atomik bir değiştirme yapar). İndirilen arşivin
  SHA-256'sı (`release.yml`nin HER varlığın YANINA koyduğu `.sha256`
  dosyasıyla) doğrulanır.
- **Yeni sürüm otomasyonu politikası (`VERSIONING.md` §4)**:
  `scripts/bump_version.sh {patch|minor|major}` + `main`e giden HER
  commit'in KENDİ git tag'i + GERÇEK GitHub Release'i olarak yayımlanması
  (`.github/workflows/release.yml` ZATEN vardı, YALNIZCA sık sık
  tag'lenme disiplini YENİ). Eski `X.Y.0-dev` son eki bu YÜZDEN
  KALDIRILDI. **İlk release (v1.1.0) GERÇEK bir regresyon YAKALADI:**
  Zig 0.16'nın `std.DynLib`i Windows İçin HİÇBİR implementasyon
  TAŞIMIYOR (`dynamic_library.zig`nin `switch`i yalnızca Linux/macOS/
  BSD'yi kapsıyor, `else` dalı BİLİNÇLİ bir `@compileError`dır) —
  `nox.sqlite`nin Zig kabuğu bu YÜZDEN Windows'ta `noxrt.o`nun (sqlite
  KULLANMAYAN programlar DAHİL) DERLENMESİNİ bozuyordu; `v1.1.1`de
  `crypto.zig`nin `advapi32` özel-durumuyla AYNI desende (Windows'ta
  `std.DynLib` YERİNE `kernel32.LoadLibraryA`/`GetProcAddress`)
  düzeltildi.
- **Modern bir CLI yardım ekranı** (`noxc --help`/`-h`/`help`, VE artık
  çıplak `noxc` da) — kullanıcı geri bildirimi: önceden bare `noxc`
  yalnızca tek satırlık bir "kullanim" mesajı veriyordu, cargo/go/npm
  gibi araçların KENDİ `--help` çıktılarıyla KIYASLANABİLİR bir ekran
  YOKTU. Yeni ekran TÜM alt komutları (build/run/test/check/fmt/init/
  fetch/update/search/version) kısa açıklamalarla + ortak bayraklarla +
  örneklerle listeler. **Sistem diline göre otomatik yerelleştirilir**
  (Türkçe/İngilizce): `LC_ALL`/`LC_MESSAGES`/`LANG` (bu ÖNCELİK SIRASIYLA,
  `gettext`in KENDİ standart çözümleme kuralı) `tr` İLE BAŞLIYORSA Türkçe;
  Windows'ta bu değişkenler genelde AYARLANMADIĞINDAN, hiçbiri
  BULUNAMAZSA `GetUserDefaultUILanguage` (kernel32) YEDEK olarak
  kullanılır.
- **Bilinmeyen bir alt komut artık ham bir `error: FileNotFound` Zig
  panik izi YERİNE anlaşılır bir ipucu verir.** `noxc upgrade` gibi
  mistyped/mevcut olmayan bir alt komut, tanınan hiçbir anahtar
  kelimeyle eşleşmediğinden eski "tekil-dosya" (`.legacy`) yoluna
  düşüyor VE o ismi bir DOSYA sanıp açmaya çalışıyordu — `.nox` İLE
  BİTMEYEN bir yol İçin artık "bilinmeyen komut ya da dosya: '...' —
  komutlar icin: noxc --help" mesajı (yerelleştirilmiş) verilir; GERÇEK
  bir eksik `.nox` dosyası İçin de (ham panik izi yerine) sade bir
  "dosya bulunamadi: ..." mesajı eklendi.

## [1.1.1]

### Düzeltildi
- **`nox.sqlite`nin Zig kabuğu (`runtime/stdlib_shims/sqlite.zig`) Windows'ta
  HİÇ DERLENEMİYORDU** — `v1.1.0`nun `windows-x64` release CI işi bunu
  YAKALADI (bkz. `gh run view`, `zig build (ReleaseFast)` adımı 11 hatayla
  başarısız oldu). Kök sebep: Zig 0.16'nın `std.DynLib`i Windows İçin
  HİÇBİR implementasyon TAŞIMIYOR (`dynamic_library.zig`nin `switch
  (native_os)`ı yalnızca Linux/macOS/BSD'yi kapsıyor, `else` dalı BİLİNÇLİ
  bir `@compileError`dır — geçici bir eksiklik DEĞİL). `noxrt.o` HER Nox
  programına koşulsuz bağlandığından, bu Windows'ta noxc'nin KENDİSİNİN
  derlenmesini (sqlite KULLANMAYAN programlar DAHİL) BOZUYORDU. Düzeltme:
  `crypto.zig`nin `SystemFunction036`/`advapi32` özel-durumuyla AYNI desen
  — Windows'ta `std.DynLib` YERİNE `kernel32.dll`nin KENDİ `LoadLibraryA`/
  `GetProcAddress`si DOĞRUDAN kullanılır. `-Dtarget=x86_64-windows` İLE
  çapraz-derleme yapılarak DOĞRULANDI (bu makinede gerçek bir Windows
  ortamı olmadığından, çalışma-zamanı testi CI'nin bir SONRAKİ `windows-x64`
  işine bırakılıyor). **v1.1.0'ın GitHub Release'i bu YÜZDEN `windows-x64`
  varlığından YOKSUNDU** — `VERSIONING.md`nin KENDİ politikası gereği o
  etiket/release SİLİNMEDİ, düzeltme bu YENİ PATCH sürümüyle gelir.

## [1.1.0]

### Değerlendirildi
- Gerçek M:N (çok çekirdekli) fiber zamanlayıcısı (Faz AA.1) — yalnızca
  araştırma, KOD DEĞİŞİKLİĞİ YOK. `nox-teknik-spesifikasyon.md` §3.46:
  mevcut M:1 modelden M:N'e geçişin somut mimari engelleri (zamanlayıcının
  süreç-geneli tekil oluşu, ARC refcount'unun bilinçli olarak atomik
  olmaması + QBE'ye inline edilmiş olması, havuzlanmış ayırıcının/döngü
  çözücünün senkronize olmayışı, birkaç stdlib globalinin M:1 garantisine
  açıkça dayanması) kod okunarak tespit edildi. Karar ERTELENDİ —
  kullanıcıyla bir kapsam-netleştirme görüşmesi olmadan hiçbir tasarım/
  implementasyon turuna girişilmeyecek.

### Eklendi
- `nox.thread` (Faz BB.1 — çalışma zamanı hazırlığı, henüz dil yüzeyi
  yok) — kullanıcının 1.0 için zorunlu kıldığı gerçek M:N (çok
  çekirdekli) fiber/yeşil iş parçacığı desteğinin ilk adımı. Beş
  "tehlikeli" global (`bridge.zig`nin `g_scheduler`, `random.zig`nin
  `g_prng`/`g_seeded`, `fs.zig`nin `g_last_ok`, `json.zig`nin
  `g_last_op_ok`/`g_make_json_value_fn`, `cycle_detector.zig`nin
  `g_trace_dispatch_fn`/`g_gc_free_dispatch_fn`) `threadlocal` yapıldı —
  `nox-teknik-spesifikasyon.md` §3.47. Gerçek `std.Thread.spawn`
  kullanan izolasyon testleri eklendi; `random.zig`nin testi, kasıtlı
  boz→kırmızı ritüelinde bir paylaşılan-PRNG veri yarışını gerçekten
  yakaladı.
- `nox.thread` Katman 1'in saf-Zig çekirdeği (Faz BB.2, henüz dil yüzeyi
  yok) — YENİ `runtime/async_rt/thread_bridge.zig`: `nox_thread_spawn`/
  `nox_thread_join`/`nox_thread_destroy`. Gerçek bir YENİ OS iş
  parçacığı başlatır, o iş parçacığında TAMAMEN BAĞIMSIZ bir
  `RuntimeState`/`Scheduler` kurar (`$main`in kendi önyükleme dizisinin
  bir kopyası) — çocuk KENDİ `spawn`/`await`/`Channel[T]`ini
  kullanabilir. `str` argüman/sonuçlar `http_client.zig`nin audit
  edilmiş "düz baytlarla kopyala, ARC'a hiç dokunma" protokolüyle
  taşınır. `nox-teknik-spesifikasyon.md` §3.48. Kasıtlı boz→kırmızı
  ritüelinde, str-hazırlık kopyalama adımının atlanması test sürecinin
  askıda kalmasına yol açtı — çapraz-iş-parçacığı bellek bozulmasının
  somut kanıtı.
- `nox.thread.start`/`ThreadHandle[T]`/`.join()` — checker desteği (Faz
  BB.3, henüz codegen yok). **İsim düzeltmesi:** plan `nox.thread.spawn`
  öngörüyordu, ama `spawn` zaten dilin kendi fiber-spawn anahtar kelimesi
  olduğundan (`kw_spawn`) bu parse hatasına yol açtı — gerçekten derlenip
  keşfedildi, isim `start`a değiştirildi. `entry`in (nox.http.serve'in
  tersine) `async def` olması zorunlu kılındı; argüman/dönüş tipi
  `isThreadTransferSafeType`den geçmeli (int/float/bool/str/None/ptr —
  Task/Channel/class/list/dict hariç, çünkü bunlar kendi zamanlayıcısına
  bağlıdır). `nox-teknik-spesifikasyon.md` §3.49. 7 yeni checker golden
  testi + kasıtlı boz→kırmızı ritüeli.
- `nox.thread.start`/`ThreadHandle[T]`/`.join()` — codegen + `stdlib/
  nox/thread.nox` (Faz BB.4). Gerçek `nox.thread.start(entry, arg)` artık
  yeni bir OS iş parçacığında GERÇEKTEN çalışır, `ThreadHandle.join()`
  fiber-farkında askıya alır (ebeveynin diğer fiber'ları çocuk çalışırken
  ilerlemeye devam eder), `int`/`str` payload'lar (arg VE dönüş) sızıntısız
  taşınır, join edilmeden scope'tan çıkan bir `ThreadHandle` sızmadan
  temizlenir (atomik referans sayımı). `nox-teknik-spesifikasyon.md`
  §3.50 — codegen'in checker'dan ayrı `resolveType`inin `ThreadHandle`i
  tanımaması (Unsupported hatası) ve `genThreadStartWrapper`nin `str`
  argümanı hedef fonksiyon çağrısından sonra serbest bırakmaması (gerçek
  bir sızıntı — uçtan uca golden testle yakalandı) dahil, gerçekten
  derlenip çalıştırılarak bulunan hatalar ve düzeltmeleri belgeler. 4 yeni
  uçtan uca codegen golden testi (int/str spawn+join, fiber-farkındalık
  sıralama kanıtı, detached/fire-and-forget sızıntı testi) + kasıtlı
  boz→kırmızı ritüeli.
- `ThreadChannel[T]` Katman 2'nin saf-Zig çekirdeği (Faz BB.5, henüz dil
  yüzeyi yok) — YENİ `runtime/async_rt/thread_channel.zig`:
  `nox_threadchannel_new`/`_send_val`/`_send_str`/`_recv_val`/`_recv_str`/
  `_destroy`. İş parçacıkları arasında gerçek, sürekli, çift-yönlü
  iletişim — simetrik çift-pipe geri basınç modeli (kullanıcının
  AskUserQuestion yanıtıyla seçilen tasarım), `nox_thread_join`ın aynı
  `Scheduler.suspendForIo`/`nonBlockingRead` ikilisini yeniden kullanır.
  `str` transferi `ThreadHandle` ile aynı "düz baytlarla kopyala"
  protokolünü izler. `nox-teknik-spesifikasyon.md` §3.51 — bu Zig
  sürümünde `std.Thread.Mutex`in artık olmadığının keşfini (CAS-tabanlı
  spin-kilide geçiş) belgeler. Kasıtlı boz→kırmızı ritüelinde, kilidin
  kaldırılması küçük hacimde gözlenmedi; hacim 2 milyon öğeye
  çıkarılınca kesin bir veri bozulması (`expected 44602, found 44601`)
  yakalandı.
- `ThreadChannel[T]` — checker + codegen (Faz BB.6), `nox.thread` faz
  serisinin (BB.1-BB.6) tamamlanışı. `ThreadChannel[T](capacity)` artık
  uçtan uca çalışıyor: iki gerçek OS iş parçacığı arasında sürekli,
  çift-yönlü iletişim, `int`/`str` payload'lar sızıntısız, kapasite
  geri basıncı (dual-pipe) tam boru hattından doğrulandı. `ThreadChannel`
  (Task/Channel/ThreadHandle'ın aksine) `*Scheduler` alanı taşımadığından
  `nox.thread.start`ın `arg`ı olarak geçirilebilir — bu, `isThreadTransferSafeType`e
  bilinçli bir istisna olarak eklendi. `nox-teknik-spesifikasyon.md`
  §3.52 — gerçekten çalıştırılıp bulunan iki hata belgelenir: (1)
  `registerFunc`in `isSpawnParamSafeType`i `ThreadChannel` parametreli
  `async def`leri reddediyordu (`isThreadTransferSafeType`den bağımsız,
  ayrı bir kapı); (2) `ThreadChannel` kurucu mantığının `checkExpr`in
  kendi switch'ine doğrudan eklenmesi, önceden var olan "çok uzun ifade
  çökmeden işlenir" fuzz regresyon testinde gerçek bir stack overflow'a
  yol açtı (Debug modunda bir fonksiyonun yığın çerçevesi tüm switch
  dallarının birleşimine göre boyutlanır) — ayrı bir `checkGenericConstruct`
  fonksiyonuna çıkarılarak düzeltildi. 3 yeni uçtan uca codegen golden
  testi + kasıtlı boz→kırmızı ritüeli (yanlış runtime fonksiyonuna
  yönlendirme, gerçek bir tip-karışıklığı çökmesi olarak yakalandı).
- Profesyonel kurulum: GitHub Releases + `install.sh` + `noxc --version`
  (Faz CC.1) — `curl -fsSL .../install.sh | sh` artık macOS (Apple
  Silicon) ve Linux (x86-64/aarch64) için önceden derlenmiş bir paket
  kurar (`noxc`/`noxlsp` + çalışma zamanı + stdlib + gömülü `qbe` —
  yalnızca sistem `cc`si dışarıda bırakılır, çünkü `noxc` gerçek bir
  tek statik ikili değildir). YENİ `.github/workflows/release.yml`,
  `v*` etiketlerinde 3 platform için (`ci.yml` ile aynı matris) tarball
  üretip yayımlar. YENİ `noxc --version`/`version`/`-V` — sürüm metni
  `build.zig.zon`den tek doğruluk kaynağı olarak türetilir. `nox-teknik-
  spesifikasyon.md` §3.53. Kullanıcı onayıyla (AskUserQuestion) kapsam
  netleştirildi: Homebrew tap yerine Releases+install.sh, ve qbe
  tarball'a gömülür. 1 yeni CLI golden testi + kasıtlı boz→kırmızı
  ritüeli.

### Düzeltildi
- CI/Release: `mlugg/setup-zig@v1` eylemi, `v1.0.0` etiketinin İLK
  denemesinde `ci.yml`/`release.yml`nin İKİSİNDE de Zig kurulum adımını
  ~1 dakikada çökertti. Kök neden ağ kesintisi DEĞİLDİ — o eylemin
  "official" yedek URL'si etiketli sürümler İÇİN yanlış bir yol
  (`ziglang.org/builds/...`, SADECE dev-snapshot'lar İÇİN doğru)
  KULLANIYORDU. Düzeltme: her iki workflow'da da Zig, `qbe`nin ZATEN
  kullandığı AYNI "doğrudan `curl`+`tar`" deseniyle DOĞRU
  (`ziglang.org/download/<sürüm>/...`) URL'den kuruluyor artık.
  `nox-teknik-spesifikasyon.md` §3.53 (addendum).
- `install.sh`: `resolve_version`in `curl | grep | sed` zinciri, `set -e`/
  `pipefail` aktifken `grep` hiçbir şey bulamadığında (henüz Release
  yokken ya da API'ye erişilemediğinde) betiği yardımcı `die` mesajına
  hiç ulaşmadan sessizce sonlandırıyordu (kullanıcı raporu: "otomatik
  kurulum scripti de çalışmıyor"). Düzeltme: yanıt önce ayrı bir
  değişkene (`|| true` ile) alınıp sonra ayrıştırılıyor, böylece boş
  sonuç her zaman açık hata mesajına ulaşıyor. Gerçek bir uçtan uca
  doğrulamayla (yayımlanan v1.0.0 varlığı indirilip açılıp `noxc
  --version` + gerçek bir .nox derlemesi çalıştırılarak) paketin tam
  işlevsel olduğu kanıtlandı.
- CI: gerçek, %100 yerel olarak tekrarlanabilir bir soğuk-önbellek yarış
  durumu (`rm -rf .zig-cache zig-out && zig build test` tek komutu,
  `noxc`/`noxlsp`yi alt süreç olarak çağıran test dosyalarını —
  `lsp_test.zig` dahil, `fetch`/`update`e özgü değil — `processSpawnPosix`
  ile çökertiyordu; kullanıcının gerçek CI çalıştırmasında gözlemlediği
  "test buildler takılıyor" raporuyla keşfedildi). Düzeltme: `ci.yml`de
  her mod için önce salt `zig build` (tüm install_* adımlarını bitirir),
  sonra ayrı bir komut olarak `zig build test`. `nox-teknik-spesifikasyon.md`
  §3.55.

### Eklendi
- `noxc fetch`/`noxc update` — gerçek implementasyon (Faz CC.2.1, Faz
  O §P.5'ten beri rezerve bırakılmıştı). `fetch`, proje kökündeki
  `nox.json`'daki `requires[]`i (bir .nox dosyası derlemeden) önbelleğe
  doldurur; `update`, her bağımlılığı ref'ten koşulsuz yeniden çözüp
  `nox.lock`taki kilitli SHA'ları günceller. `nox-teknik-spesifikasyon.md`
  §3.54 — gerçekten test edilip bulunan iki hata (kendi yazdığım yeni
  testlerde, ürün kodunda değil) belgelenir: `std.Io.Dir.openAbsolute`
  bu Zig sürümünde yok; `.cwd` kullanan bir alt süreç çağrısına göreli
  bir argv[0] geçmek, çalıştırılabilir dosyanın YENİ çalışma dizinine
  göre yanlış çözülmesine yol açar (genel bir kural olarak belgelendi).
  2 yeni uçtan uca CLI testi + kasıtlı boz→kırmızı ritüeli.
- `noxc init [proje-adi]`/`noxc check <dosya.nox>` (Faz CC.2.2). `init`,
  Cargo/Go tarzı proje iskeleti oluşturur (`nox.json`+`main.nox`+
  `.gitignore`; argümansız CWD'de, isimli yeni bir alt dizinde — var olan
  bir projenin üzerine asla yazmaz). `check`, codegen/`qbe`/`cc`
  tetiklemeden sadece lex→parse→import çözümü→tip denetimi çalıştırır —
  editör entegrasyonu/hızlı geri bildirim için. `nox-teknik-
  spesifikasyon.md` §3.56. 3 yeni uçtan uca CLI testi (üretilen projenin
  gerçekten derlenip çalıştığı dahil) + kasıtlı boz→kırmızı ritüeli.

### Düzeltildi
- Linux/x86-64 CI'de gerçekten gözlemlenen, önceden var olan üç hata
  (`noxc fetch`/`update`/`init`/`check` ile ilgisiz — soğuk-önbellek
  yarış düzeltmesi CI'yi bu kadar ileri götürene kadar hiç görünür
  değillerdi): (1) `runtime/stdlib_shims/http_client.zig`'in
  `workerThreadFn`'i, tamamlanma sinyalini yazdıktan SONRA `ctx.write_fd`yi
  `defer` bloğunda okumaya devam ediyordu — sinyal yazılır yazılmaz
  çağıran `ctx`yi serbest bırakabildiğinden gerçek bir kullanım-sonrası-
  serbest yarışıydı (bir bağlantı testinde segfault, iki `nox.http.get`
  altın testinde `ProgramFailed` olarak gözlemlendi — aynı kök neden).
  `write_fd` artık fonksiyon girişinde yerel bir değişkene kopyalanıyor.
  (2) `tests/compat/zig_ext/util.o`, `zig build-obj` ile `-fPIC` olmadan
  derleniyordu — dağıtımın PIE-varsayılan `cc`sine bağlanırken link
  hatası veriyordu; `-fPIC` eklendi. `nox-teknik-spesifikasyon.md` §3.57
  — bu yarış yerel olarak (macOS/aarch64'te) hiç tekrarlanamadığından
  doğrulama kod incelemesi + gerçek Linux/x86-64 CI'de yeniden
  çalıştırmaya dayanıyor. (3) Yukarıdaki iki düzeltme sonrası GERÇEK
  CI'de ortaya çıkan dördüncü, ayrı bir zamanlama hatası: fiber-sırası
  kanıtlayan bir `nox.http.get` testi, yerel test sunucusu yanıtı
  gecikmesiz yazdığından bazen Linux/x86-64'te hiç askıya alınmadan tek
  seferde tamamlanıyordu. `http_server.zig`'in "yavaş istemci" testinin
  (150ms gecikme) aynı deseni sunucu tarafına da uygulandı
  (`testServeOnceDelayed`).

### Eklendi
- Renkli/daha okunabilir `noxc` çıktısı (Faz CC.2.3). Checker tip
  hataları, `qbe`/`cc` başarısızlıkları ve tüm "bulunamadı"/"okunamadi"
  hata yolları artık kırmızı; `derlendi`/`olusturuldu`/"tip hatasi yok"
  yeşil. Gerçek bir terminale bağlı değilken (dosyaya/pipe'a
  yönlendirilmiş) veya `NO_COLOR` ayarlıyken otomatik devre dışı kalır
  — script/CI tüketicileri her zaman ham metin görür. `nox-teknik-
  spesifikasyon.md` §3.58. `script(1)` ile gerçek bir sanal TTY üzerinde
  manuel doğrulama + boru hattında (TTY olmayan) hiç ANSI kaçış dizisi
  sızmadığını doğrulayan yeni bir otomatik test + kasıtlı boz→kırmızı
  ritüeli.

### Değiştirildi
- Metod çağrıları için istisna-kontrolü eleme (Faz M.8, yeniden ele
  alındı — kullanıcının "sonraki aşama geliştirmeler" listesinin #2
  maddesi, "Dil Performans artışı"). Daha önce (dil stabilizasyonu fazı)
  "ölçülmeden kanıtlanmadı" gerekçesiyle ertelenmişti; izole bir mikro-
  benchmarkla ~%41'lik gerçek bir kazanç ölçülünce yeniden ele alındı.
  `computeMustNotRaise` artık TÜM sınıf metodlarını (yalnızca `__init__`
  değil) analiz ediyor; basit `obj.method()` çağrıları (alıcının sınıfı
  `self.`/bir yerel değişken üzerinden statik olarak bilinen durumlarda)
  artık `nox_exception_pending` kontrolünü, o metodun transitif olarak
  ASLA raise etmediği kanıtlanabildiğinde atlayabiliyor — belirsiz her
  durumda (zincirleme çağrı, yeniden bildirilmiş/"zehirlenmiş" bir
  değişken, vb.) kontrol MUHAFAZAKÂR olarak korunuyor, istisna hiçbir
  zaman sessizce yutulmuyor. `nox-teknik-spesifikasyon.md` §3.59. Aynı
  turda, araştırma sırasında bulunan önceden var olan gerçek bir hata da
  düzeltildi: `collectRaiseInfoExpr`, bilinmeyen bir çağrı hedefini (ör.
  iç içe bir closure) sessizce "güvenli" sayıyordu — artık koşulsuz
  güvensiz sayılıyor. 6 yeni golden test (3 katmanlı metod-zinciri raise
  yayılımı hem `self.` hem yerel değişken üzerinden, yeniden bildirme/
  zehirlenme güvenlik testi, pozitif eleme testi + IR-metni doğrulaması)
  + `benchmarks/method_call_elision.nox` (300M çağrı, ~480ms → ~270ms,
  ~%44 hızlanma) + kasıtlı boz→kırmızı ritüeli.

### Eklendi
- Çok çekirdekli `nox.http.serve` (Faz DD.1 — kullanıcının "sonraki
  aşama geliştirmeler" listesinin #3 maddesi, "HTTP kütüphane async m:n
  entegrasyonu ve performans artışı"). Gerçek bir *paylaşılan* M:N
  zamanlayıcı YERİNE (Faz AA.1'de somut mimari engeller nedeniyle
  ERTELENMİŞ, ERTELENMİŞ kalıyor), `nox.thread`in (Faz BB.1-BB.6) ZATEN
  sağladığı "N bağımsız M:1 dünyası" modeli üzerine inşa edildi: bir
  dinleme soketinin ham `fd`si (`nox.thread`in ZATEN desteklediği bir
  aktarım tipi olan düz bir `int`) N bağımsız iş parçacığına dağıtılıp
  her biri KENDİ kqueue/epoll'ıyla AYNI soketi izleyebiliyor — hiçbir
  yeni senkronizasyon ilkeli gerekmedi. Üç yeni parça: `nox.http.
  listen(port) -> int` (birleştirilebilir ilkel, mevcut FFI mekanizmasıyla
  sıfır yeni derleyici kodu), `nox.http.serve_fd(fd, handle[,
  max_connections])` (`nox.http.serve`nin kardeşi, `nox.thread.start`ile
  birleştirilebilir), `nox.http.serve_multicore(port, handle,
  num_threads[, max_connections])` (tek satırlık kolaylık sarmalayıcısı —
  thread-spawn döngüsünü derleyici üretir). `nox-teknik-spesifikasyon.md`
  §3.60. 5 yeni test (2 Zig birim testi — paylaşılan fd'de gerçek çift
  iş parçacığı kabulü + `owns_fd`in deterministik doğrulaması — + 3 uçtan
  uca golden test) + kasıtlı boz→kırmızı ritüeli (`owns_fd`i geçici
  olarak bozmak yalnızca bir birim testini KIRMIZI yapmakla kalmadı,
  gerçek bir çalışma-zamanı tıkanmasına — paylaşılan fd'nin erken
  kapanıp diğer iş parçacığının `accept()`ini sonsuza dek askıda
  bırakması — da yol açtı, düzeltmenin gerekliliğinin somut kanıtı).
- Stdlib geliştirme ve performans (Faz EE.1 — kullanıcının "sonraki aşama
  geliştirmeler" listesinin #4 maddesi). Beş kalem: (1) `nox.strings.
  byte_at(s, idx) -> int` — `s[i]`nin (her çağrıda tahsis eden) alloc-sız
  eşdeğeri; `starts_with`/`ends_with`/`index_of`/`contains` artık bunu
  kullanıyor, ÖNCEDEN hiç bayraklanmamış bir O(n·m) heap-tahsis darboğazını
  giderdi. (2) `nox.strings.join` artık Zig'de tek-geçiş O(n) (ÖNCEDEN saf
  Nox'ta `+`-birleştirme döngüsüyle O(n²)idi — `split`/`trim`/vb.'nin
  ZATEN izlediği "Zig'e sar" örüntüsüne UYMUYORDU). (3) YENİ `list[T].
  sort()` — `int`/`float`/`str` elemanlar, `.append`den FARKLI olarak
  alıcı çıplak bir isimle SINIRLI DEĞİL. (4) YENİ `nox.path` modülü —
  `join`/`basename`/`dirname`/`extension`/`is_absolute`, saf string
  manipülasyonu, I/O yok. (5) `nox.fs.exists`/`is_file`/`is_dir` — var
  OLMAMA durumunda `read_to_string`in AKSİNE ASLA `raise` etmez.
  `nox-teknik-spesifikasyon.md` §3.61. `strings_perf_bench.nox`
  ölçümü: 6040ms → 200ms (**~30x hızlanma**, çıktı değerleri birebir
  aynı). Yeni Zig birim testleri + 3 yeni uçtan uca golden test + 2
  kalem için kasıtlı boz→kırmızı ritüeli.

### Düzeltildi
- Sürüm tutarsızlığı (Faz FF.1 — harici bir teknik incelemede bulunan
  gerçek bir bulgu). `build.zig.zon` (dolayısıyla `noxc --version`)
  `1.0.0` DÖNDÜRÜYORDU, ama main dalı ZATEN `v1.0.0`dan SONRAKİ (Faz
  M.8/DD.1/EE.1) özellikleri İÇERİYORDU — kullanıcı `noxc --version`a
  GÜVENİP yanlış bir imaj edinebilirdi. `1.1.0-dev`e (Zig'in KENDİ
  `-dev` ön-sürüm sözleşmesiyle AYNI) güncellendi. `nox-teknik-
  spesifikasyon.md`nin başlığı da ("Versiyon: 0.1 (Taslak)", "Durum:
  Mimari tasarım aşaması" — GERÇEKTEN `v1.0.0` yayımlandıktan SONRA bile
  DEĞİŞTİRİLMEMİŞTİ) VE `README.md`nin sürüm rozeti güncellendi.
  Derleyici kaynak dosyalarının modül-üstü yorumlarındaki ("Nox v0.1
  lexer" gibi) ARTIK ANLAMSIZ kalmış `v0.1` etiketleri (9 dosya)
  KALDIRILDI.
- "Gerçek M:N" terminolojisi (Faz FF.2 — harici incelemenin AYNI turda
  bulduğu bir bulgu). `README.md`/`stdlib/nox/thread.nox`/`nox-teknik-
  spesifikasyon.md`nin `nox.thread`in (Faz BB.1-BB.6) TESLİM EDİLEN
  mimarisini tarif eden yerlerinde "gerçek M:N (çok çekirdekli)" ifadesi
  YANILTICIYDI — GERÇEKTE teslim edilen, işlerin OS iş parçacıkları
  ARASINDA çalıntı/göçle (work-stealing) dağıtıldığı TEK bir PAYLAŞILAN
  zamanlayıcı DEĞİL, "paylaşımsız (shared-nothing), N BAĞIMSIZ M:1 fiber
  çalışma zamanının OS iş parçacıkları üzerinde paralel çalışması"dır
  (Faz AA.1'in, §3.46, somut mimari engeller nedeniyle ERTELEDİĞİ MODEL
  BUDUR — ERTELENMİŞ KALIYOR). Yalnızca dokümantasyon/yorum düzeltmesi,
  KOD DAVRANIŞI DEĞİŞMEDİ. AA.1'in KENDİ değerlendirme metnindeki
  (§3.46, kullanıcının ORİJİNAL isteğinin/araştırmanın tarihsel kaydı)
  "gerçek M:N" ifadeleri BİLEREK DEĞİŞTİRİLMEDİ — onlar geçmişte
  DEĞERLENDİRİLEN (VE ERTELENEN) kavramı doğru tarif ediyor.
- **`dict[K,V]` sallanan-işaretçi/çift-serbest-bırakma güvenlik açığı**
  (Faz FF.3, bkz. nox-teknik-spesifikasyon.md §3.62 — harici incelemenin
  TEK "kritik" bulgusu, GERÇEK bir SIGSEGV İLE doğrulandı). `dict[K,V]`
  ÖNCEDEN ARC-yönetimli DEĞİLDİ (`Task`/`Channel` İLE AYNI "tek sahiplilik,
  kapsam sonunda KOŞULSUZ yıkım" modeli) — bir dict adlandırılmış bir
  yerele bağlanıp SONRA bir sınıf alanına GEÇİRİLİRSE, yerelin kapsam-sonu
  temizliği dict'i KOŞULSUZ yok ediyor, sınıf alanı SALLANAN bir işaretçi
  kalıyordu. `dict` ARTIK `str`/`list`/`class` İLE AYNI TAM ARC modelinde
  (`nox_dict_new` `nox_rc_alloc` İLE tahsis eder, `nox_dict_release`
  — ESKİ `nox_dict_destroy` — predecrement'e göre KOŞULLUDUR). Düzeltme
  sırasında İKİ BAĞIMSIZ, İLGİLİ eksiklik daha bulundu ve giderildi: (1)
  `extern def` dönüş tiplerinin `dict_info`yi KOPYALAMAMASI (SIGABRT İLE
  yakalandı), (2) `isTemporaryExpr`in `.dict_lit`i TANIMAMASI (`HttpResponse(
  200, "ok", {"x": "x"})` gibi adlandırılmamış dict literallerinin GERÇEK
  bir sızıntıya yol açması, `zig build test`in DebugAllocator'ı İLE
  yakalandı). `stdlib/nox/http.nox`nin ARTIK GEÇERSİZ "headers'ı ASLA bir
  yerele bağlama" uyarı yorumu güncellendi (davranış DEĞİŞMEDİ). YENİ
  pozitif golden test (iki sınıf örneğine + kaynak yerele PAYLAŞILAN dict)
  + YENİ Zig birim testi (retain + iki release) + kasıtlı boz→kırmızı→
  düzelt ritüeli üç kez uygulandı (pre-existing hata, `retainIfAliasing`
  break'i, `nox_dict_release` predecrement break'i).
- `nox-teknik-spesifikasyon.md`de Faz FF.3'ün §3.62 eklenmesi sırasında
  kazayla SİLİNMİŞ olan `## 4. Bellek Yönetimi — "Sahiplik Piramidi"`
  başlık satırı YENİDEN EKLENDİ (yalnızca dokümantasyon, `git show
  HEAD~1:nox-teknik-spesifikasyon.md` İLE KANITLANDI — Katman 1-4'ün
  İÇERİĞİ ETKİLENMEMİŞTİ, yalnızca üst-düzey başlık eksikti).

### Eklendi
- **`self` parametresi İçin tip çıkarımı** (Faz FF.4, bkz. nox-teknik-
  spesifikasyon.md §3.63). Bir sınıf/protokol metodunun `def m(self: Foo,
  ...)` şeklinde `self`i AÇIKÇA tiplemesi ARTIK ZORUNLU DEĞİL — `def m(self,
  ...)` de GEÇERLİ, tipi kapsayan sınıf/protokol adına OTOMATİK çözülür;
  `self: Foo` açıkça yazmak da HÂLÂ geçerli, `nox fmt` kullanıcının
  YAZDIĞINI SADIK biçimde KORUR (normalize ETMEZ). **AGENTS.md §5**in "tüm
  parametre tipleri zorunlu, istisnasız" ilkesine, bu KENDİSİ AGENTS.md
  §16'nın "mimariyi etkileyen kararlar İçin önce sor" prosedürüyle
  kullanıcıya AÇIKÇA sunulup ONAYLANDIKTAN SONRA, `self` İçin belgelenmiş
  bir istisna eklendi (spec §3.1 bunu ÖNCEDEN bilerek REDDETMİŞ VE ileride
  gündeme gelirse §16 prosedürünün UYGULANMASI gerektiğini NOT ETMİŞTİ).
  Uygulama, `checker.zig`/`codegen.zig`/`ownership/analysis.zig`e SIFIR
  değişiklik gerektirdi (parser, self'in tipini HER ZAMAN dolu bırakır,
  yalnızca `formatter.zig`nin okuduğu YENİ bir `self_inferred` bayrağı
  eklendi) — bu, YENİ ownership/codegen golden testleriyle regresyon-
  korumalı biçimde DOĞRULANDI. Ayrıca, bu alana dokunulurken, AÇIKÇA
  YANLIŞ bir `self: WrongClass` tipinin reddedildiğini test eden HİÇBİR
  mevcut fixture OLMADIĞI fark edildi — YENİ `err_class_self_wrong_type`/
  `err_protocol_self_wrong_type` golden testleriyle KAPATILDI (kasıtlı
  boz→kırmızı→düzelt ritüeliyle doğrulandı).
- **Açık sınıf alan bildirimleri** (Faz FF.5, bkz. nox-teknik-
  spesifikasyon.md §3.64). Bir sınıfın alan tipleri ARTIK `__init__`den
  ÇIKARILMANIN YANI SIRA sınıf gövdesinde çıplak `<ad>: <tip>` (PEP 526
  tarzı, gerçek Python'da ZATEN var olan bir yapı) İLE de AÇIKÇA
  bildirilebilir — İKİ mekanizma AYNI sınıfta BİRLİKTE kullanılabilir.
  FF.4'ün AKSİNE bu, checker'IN YANI SIRA codegen'e de DOKUNMAYI
  GEREKTİRDİ — codegen'in KENDİ, DAHA ZAYIF `inferFieldType`si (yalnızca
  `__init__` parametresi/literal/üst-düzey atama tanır) açıkça bildirilen
  alanlar İçin TAMAMEN ATLANIR, tip `resolveType` İLE DOĞRUDAN çözülür —
  bu, `inferFieldType`nin BUGÜNE KADAR ele ALAMADIĞI alan örüntülerini
  (ör. bir `if` İÇİNDE atanan bir alan) da MÜMKÜN kılar. Güvenlik
  gereksinimi: AÇIKÇA bildirilen bir alanın `__init__`de HİÇ atanmaması
  YENİ bir checker hatasıdır (`UnassignedField`) — codegen TÜM alanları
  `__init__`den ÖNCE sıfırladığından, atanmayan bir alan (heap-tipli İSE)
  SALLANAN/null bir işaretçi OLARAK kalırdı (Faz FF.3'ün kapattığı açıkla
  AYNI RUHTA, ÖNLENEN bir tehlike). Düzeltme sırasında İKİ BLOCKING hijyen
  açığı bulundu ve giderildi: `nox fmt`in bildirilen alanları SESSİZCE
  SİLMESİ (formatlayıcının `.class_def` dalı GÜNCELLENMEMİŞTİ) ve `import
  nox.X` üzerinden gelen sınıfların alan bildirimlerinin `module_loader.zig`de
  SESSİZCE düşmesi. Ayrıca alan bildirimlerinin (`ast.Stmt`ten BAĞIMSIZ
  olmaları nedeniyle) `nox fmt`in trivia (boş satır/yorum) akışını
  GERÇEKTEN BOZDUĞU GÖZLEMLENDİ (bir sonraki deyimin gövdesine SIZAN
  sahte bir boş satır) — `FieldDecl`e satır numarası eklenerek düzeltildi.
  YENİ golden testler (bildirilen+çıkarılan alanların BİRLİKTE çalıştığı,
  atanmayan/çakışan/yinelenen bildirim hata durumları, `inferFieldType`nin
  ele ALAMADIĞI bir örüntüde codegen bypass'ının çalıştığını KANITLAYAN
  uçtan uca bir test, `nox fmt` round-trip testi) + üç BAĞIMSIZ
  mekanizma (parser/checker/codegen) İçin AYRI AYRI boz→kırmızı→düzelt
  ritüeli.
- **`T | None` (Optional) tip desteği** (Faz FF.6, bkz. nox-teknik-
  spesifikasyon.md §3.65 — Faz FF listesinin EN BÜYÜK maddesi). YENİ `|`
  token'ı + `T | None` sözdizimi (yalnızca soldan-sağa, tek seviye — `None
  | T`/zincirleme REDDEDİLİR). Kapsam TAM: hem HEAP tipler (class/str/
  list/dict — çalışma zamanı temsili taban tiple AYNI, null=None, NEREDEYSE
  ücretsiz) HEM DE İLKEL tipler (int/float/bool — TEK, GENEL bir ARC-
  yönetimli kutuya, `HeapKind.boxed_scalar`, sarılır). Daraltma (narrowing)
  DAR ve örüntü-tabanlı: yalnızca `if`/`while`'ın KOŞULUNUN TAM OLARAK
  `<isim> != None`/`<isim> == None` olması durumunda GEÇERLİDİR (genel
  akış-duyarlı analiz DEĞİLDİR) — bir bağlı liste/ağaç traversal'ının
  (`next: Node | None`, spec'in ÖNCEDEN engellediği ÖZ-REFERANSLI alan
  örneği) ARTIK GERÇEKTEN YAZILABİLDİĞİ uçtan uca bir golden testle
  KANITLANDI. Daraltılmamış bir Optional'a alan/metod/index erişimi YENİ
  bir checker hatasıdır (`OptionalNotNarrowed`). Kutulanmış İLKEL
  Optional'lar İçin codegen'in KENDİSİ de checker'ın narrowing mantığını
  (`genIf`/`genWhile`'ın `narrowed_unbox` örtüsü) YANSITMAK ZORUNDA kaldı
  — HEAP tiplerin AKSİNE (temsil AYNI, codegen değişikliği GEREKMEDİ)
  kutulanmış bir skalerin temsili `T`den TAMAMEN FARKLI olduğundan bu
  KAÇINILMAZDI. Uygulama sırasında İKİ GERÇEK, segfault'a yol açan hata
  bulunup break→red→fix ritüeliyle DÜZELTİLDİ: (1) `emitInlineRetain`
  (ARC retain'in KENDİSİ) null-KONTROLSÜZDÜ — Optional'dan ÖNCE heap-
  yönetimli bir slot ASLA null bir DEĞER TUTAMAYACAĞINDAN bu hiç GEREKLİ
  OLMAMIŞTI; (2) kutulanmış skaler release'i YANLIŞLIKLA refcount-farkında
  OLMAYAN `nox_rc_free_payload`i (`nox_rc_release` YERİNE) kullanıyordu,
  bu da PAYLAŞILAN bir kutunun (ör. `w: int | None = y`) ERKEN serbest
  bırakılıp SONRA ÇİFTE-SERBEST-BIRAKMAYA yol açmasına neden oluyordu.
  Bilinçli, dar v1 sınırlamaları: "erken dönüş" narrowing'i (`if x ==
  None: return ...` SONRASI takip eden kodun otomatik daraltılması)
  desteklenmiyor; `Task`/`Channel`/`ThreadHandle`/`ThreadChannel | None`
  desteklenmiyor (ARC-dışı, null-güvenlikleri ayrıca doğrulanmadı).
- **`str` release'inin inline edilmesi** (Faz GG.1, bkz. nox-teknik-
  spesifikasyon.md §3.66 — performans fazının ilk adımı, kullanıcının
  "Go/Rust arası konumlandırma" hedefiyle açıldı). `releaseValueIfSet`in
  `.str` dalı ARTIK `nox_str_release`i HER release'de TAM bir fonksiyon
  ÇAĞRISI olarak çağırmıyor — `class`/`list`in KENDİ `_release`larının
  ZATEN kullandığı `emitInlinePredecrement` deseniyle predecrement
  DOĞRUDAN QBE IR'ına inline edilir, YALNIZCA refcount GERÇEKTEN sıfıra
  düştüğünde (pinned/literal dizeler İçin ASLA) YENİ, hafif bir
  `nox_str_free_now`ya (predecrement'siz) düşülür. Bu, GERÇEK Nox/Go/Rust/
  C/Python ölçümlerinde bulunan EN BÜYÜK açığı (`string_passing`de Nox
  Go/Rust/C'nin 7-11 katı yavaştı) hedef aldı — ölçüm: `string_passing`
  (n=15M, ReleaseFast) ~65ms → ~50ms, diğer 18 benchmark'ta regresyon YOK.
  Break→red→fix: `should_free` geçici olarak koşulsuz `"1"`e sabitlenince
  DebugAllocator'ın "Invalid free" panik'i (pinned string'in statik
  belleğini geçerli heap işaretçisi sanma) ANINDA tetiklendi, kontrolün
  load-bearing olduğu kanıtlandı.
- **Seçici serbest-fonksiyon inlining'i** (Faz GG.2, bkz. nox-teknik-
  spesifikasyon.md §3.67). `list_traversal` benchmark'ının Go'ya karşı
  %85 kaybının kök nedeni araştırılınca, QBE'nin fonksiyonlar-arası
  inlining HİÇ yapmadığı (Go'nun aksine) bulundu — kullanıcı üç seçenekten
  (seçici inlining / ABI-seviyesi opsiyonel arena parametresi / erteleme)
  **seçici inlining'i** seçti. Küçük (≤8 üst-düzey/≤20 toplam deyim),
  döngüsüz, `try`/`with`/`raise`/`lowlevel` İÇERMEYEN, özyinelemesiz VE
  transitif olarak ASLA istisna fırlatamayacağı KANITLANMIŞ (`must_not_raise`)
  serbest fonksiyonlar ARTIK çağrı sitesine QBE-metni olarak SPLICE
  edilebiliyor — GERÇEK bir `call` YERİNE. Standalone fonksiyon HER ZAMAN
  AYRICA üretilir (saf EKLEMELİ bir optimizasyon, davranış DEĞİŞMEZ).
  Uygulama sırasında İKİ GERÇEK hata bulunup düzeltildi: (1) `genInlinedCall`in
  İLK sürümü TAZE argümanları (ör. `show(safe_div(...))`) splice SONRASI
  serbest BIRAKMIYORDU (10 test KIRMIZIYDI, `releaseTemporaryArgs`in AYNI
  dengelemesi eklendi); (2) "iç içe inlining yok" kuralı YANLIŞ
  uygulanmıştı — `quadruple(x) -> double(double(x))` gibi bir fonksiyon
  KENDİSİ BAŞKA bir sitede inline edilince, İÇİNDEKİ `double` çağrılarının
  ÖNCEDEN KAYDEDİLMİŞ slotları ARTIK GEÇERSİZ bir QBE fonksiyonuna AİTTİ
  (segfault) — `self.inline_sites` ARTIK HER üst-düzey gövde-üretiminde
  TEMİZLENİYOR. Break→red→fix: `must_not_raise` şartı GEÇİCİ olarak
  kaldırılınca 3 BAĞIMSIZ mevcut test (2 M.8 istisna-yutma testi + BİR
  gerçek sızıntı) KIRMIZI oldu, kontrolün load-bearing olduğu kanıtlandı.
  Ölçüm: `list_traversal` ~62.5ms → ~60.3ms (dürüstçe tahmin edildiği gibi
  KISMİ bir kazanım — `nox_rc_alloc`ın KENDİSİ hâlâ çalışıyor), YAN kazanım
  olarak `string_passing` GG.1'in ~50ms'sinden ~44.8ms'ye düştü. 4 YENİ
  golden test + boz-kırmızı-düzelt ritüeli.
- **for-loop metod çağrısı istisna-kontrolü elemesi boşluğu** (Faz GG.3,
  bkz. nox-teknik-spesifikasyon.md §3.66). `for item in items:
  item.method()` deseni, `computeMustNotRaise`in (Faz M.8) `.for_stmt`
  dalının döngü değişkeninin sınıfını HER ZAMAN `null` bildirmesi YÜZÜNDEN
  `item.method()` çağrısını ÇÖZÜMLENEMEZ sayıp İÇİNDE bulunduğu TÜM
  fonksiyonu KOŞULSUZ zehirliyordu — çok YAYGIN bir OOP idiomunda M.8'in
  kazanımını sıfırlayan GERÇEK bir boşluktu. YENİ bir `list_elem_types`
  haritası (hangi yerel/parametrenin `list[SomeClass]` tipinde olduğunu
  izler) `collectRaiseInfoStmts` akışına eklendi; `.for_stmt` ARTIK döngü
  değişkeninin sınıfını bu haritadan ÇÖZÜMLÜYOR (`genForList`nin GERÇEK
  codegen'inin ZATEN yaptığı AYNI çözümleme). IR-metni doğrulaması: aynı
  fixture'ın ürettiği IR'da `nox_exception_pending`e TEK çağrı bile YOK.
  Break→red→fix: `elem_cn` çözümlemesi GEÇİCİ olarak yok sayılınca TAM
  OLARAK beklenen tek test (IR doğrulaması) kırmızı oldu, davranış testi
  yeşil kaldı — elemenin YALNIZCA bir kontrol-optimizasyonu olduğunun
  kanıtı. Ölçüm: `for_loop_method_elision` (240M metod çağrısı) 273.0ms →
  259.6ms, **~%5 hızlanma** (M.8'in doğrudan çağrılardaki ~%44'ünden
  küçük — yalnızca istisna kontrolü elenir, metod çağrısının KENDİSİ
  GG.2'nin kapsamı DIŞINDA kalır).
- **`benchmarks/exception_check_overhead.nox`** (Faz GG.4 — bkz.
  nox-teknik-spesifikasyon.md §3.66'nın "DEĞERLENDİRİLDİ, REDDEDİLDİ"
  notu). `nox_exception_pending`i (GG.1/GG.2'nin `emitInlinePredecrement`/
  seçici inlining'iyle AYNI desenle) inline etme fikri TAM olarak
  uygulanıp (yeni `runtime/alloc/runtime_state.zig` + `build.zig`'in
  `rt_layout` modülü İLE `@offsetOf` tabanlı doğrudan `loadl`) doğrulandı
  (467/468 yeşil, 20 testi kırmızıya çeviren break→red→fix), AMA
  ölçüldüğünde BEKLENENİN TERSİ, TEKRARLANABİLİR bir sonuç çıktı: 453.5ms
  → 532.5ms (**~%17 YAVAŞLAMA**, muhtemelen QBE'nin linear-scan register
  ayırıcısının `call` sınırının doğal canlı-aralık kesimini kaybetmesi).
  **Kod TAMAMEN geri alındı** (`git checkout` + `runtime_state.zig`
  silindi) — yalnızca bu benchmark KALICI bir regresyon-koruma olarak
  eklendi.
- **Döngü içindeki `s[i]`nin tekrar eden `strlen`i (manuel LICM)** (Faz
  GG.5, bkz. nox-teknik-spesifikasyon.md §3.66). `genStrIndex`in sınır
  kontrolü İçin gereken `strlen(s)` HER TEK `s[i]` erişiminde YENİDEN
  hesaplanıyordu — bir döngü İçinde tekrar eden erişim (dizeyi karakter
  karakter tarayan bir ayrıştırıcı GİBİ ÇOK YAYGIN bir idiom) bu yüzden
  O(dizi uzunluğu × erişim sayısı) GERÇEK bir O(n²) hazırdı (GG.1'in
  araştırma notunda ERTELENEN bulgu). YENİ `str_len_cache` haritası,
  `genWhile`/`genForRange`/`genForList`in ÜÇÜNÜN de döngüye GİRMEDEN
  ÖNCE çağırdığı `enterStrLenCacheScope` İLE doldurulur: `str`-tipli,
  gövde İÇİNDE (iç içe döngüler DAHİL) HİÇ yeniden atanmayan İsimler
  İçin `strlen` TEK SEFERLİK önceden hesaplanıp önbelleklenir (`genStrIndex`
  bu önbelleği KONTROL EDİP varsa GERÇEK bir `$strlen` çağrısı ÜRETMEZ);
  gövdede bir iç içe closure VARSA TÜM önbellekleme BİLİNÇLİ olarak
  atlanır. Break→red→fix: yeniden-atama KORUMASI GEÇİCİ olarak devre
  dışı bırakılınca `str_index_loop_reassign_stale_len.nox` TAM OLARAK
  beklendiği gibi YANLIŞ sonuç (200 yerine 101) verdi — bayat-uzunluk
  korumasının load-bearing olduğu KANITLANDI. Ölçüm: `str_index_loop_licm`
  (20M erişim) 1919.3ms → 82.3ms, **~%96 hızlanma (~23,3×)** — GG serisinin
  EN BÜYÜK ölçülmüş kazanımı. **Yan bulgu (AYRI bir takip görevine
  bırakıldı):** bir `str` yerelinin bir döngü İçinde yeniden atanmasının,
  AYNI döngüdeki bir `try/except` bloğuyla BİRLEŞTİĞİNDE ÖNCEDEN VAR OLAN
  (GG.5'TEN TAMAMEN BAĞIMSIZ, `git stash` İLE pre-GG.5 codegen'de de AYNEN
  yeniden üretilen) bir bellek sızıntısı VE yakalanmamış bir istisnanın
  bir `while` İÇİNDEN GEÇERKEN process'i doğru sonlandırmadığı KEŞFEDİLDİ.
- **Değerlendirildi, REDDEDİLDİ: 2'nin kuvveti sabit çarpımlarını shift'e
  çevirme** (Faz GG.6 — bkz. nox-teknik-spesifikasyon.md §3.66'nın
  "DEĞERLENDİRİLDİ, REDDEDİLDİ" notu). Kod YAZILMADAN ÖNCE ölçüldü (GG.4'ün
  dersi UYGULANARAK): `i * 8` İçeren 500M yinelemelik bir döngünün ÜRETTİĞİ
  `.ssa` ELLE `shl`e YAMANIP AYRI derlendi — `mul` VE `shl` arasında
  ÖLÇÜLEBİLİR fark BULUNAMADI (140-143ms, HER İKİSİ de). Apple Silicon'ın
  tamsayı çarpma birimi KÜÇÜK sabitlerle çarpmada `shl` İLE PRATİKTE AYNI
  hızda — **hiçbir kod yazılmadı**.
- **En küçük/en sık ARC yardımcılarını çağrı yerine inline etme** (Faz
  GG.7, bkz. nox-teknik-spesifikasyon.md §3.66). GG.1'in `.str` dalına
  uyguladığı `emitInlinePredecrement` deseni, `releaseValueIfSet`in KALAN
  İKİ dalına — ilkel-elemanlı `list[T]` (ÇOK SIK, HER liste release'i) VE
  `boxed_scalar` (Optional-kutulanmış ilkel) — HÂLÂ UYGULANMAMIŞTI; İKİSİ
  de GERÇEK bir `call $nox_rc_release` üretiyordu. `nox_rc_release`in
  KENDİSİ ZATEN TAM OLARAK `nox_rc_predecrement(ptr) != 0 ?
  nox_rc_free_payload(...) : ()` OLDUĞUNDAN, davranış BİREBİR KORUNARAK
  İKİ dal da AYNI splice desenine geçirildi. Break→red→fix: HER İKİ
  dalın `jnz`i GEÇİCİ olarak KOŞULSUZ `jmp` (HER ZAMAN serbest bırak)
  İLE değiştirilince TAM OLARAK 4 test KIRMIZI oldu (paylaşılan liste/
  kutu referanslarının erken serbest bırakılması) — kontrolün load-bearing
  olduğu kanıtlandı. Ölçüm: `list_release_overhead` (50M döngü) 171.2ms
  → 157.9ms, **~%8 hızlanma** (GG.1'in ~%23'ünden küçük — `nox_rc_alloc`ın
  KENDİSİ hâlâ dominant maliyet).
- **Değerlendirildi, REDDEDİLDİ: runtime'a dokunmayan saf fonksiyonlar
  için RT_PARAM'ı elemek** (Faz GG.8 — bkz. nox-teknik-spesifikasyon.md
  §3.66'nın "DEĞERLENDİRİLDİ, REDDEDİLDİ" notu). Kod YAZILMADAN ÖNCE
  ölçüldü (GG.4/GG.6'nın dersi UYGULANARAK): `numeric_recursion`
  (`fib(35)`, ~30M özyinelemeli çağrı, `rt`ye HİÇ dokunmaz) fonksiyonunun
  ÜRETTİĞİ `.ssa` ELLE `rt` parametresi ÇIKARILARAK yamanıp AYRI derlendi
  — `rt`li VE `rt`siz arasında ÖLÇÜLEBİLİR fark BULUNAMADI (5 ölçümün
  TÜMÜ, ~0.02-0.03s). ARM64 çağrı kuralı İLK 8 tamsayı argümanı KAYITLARDA
  geçirdiğinden BİR argüman EKLEMEK/ÇIKARMAK (sınırın ÇOK altındayken)
  Apple Silicon'da ÖLÇÜLEBİLİR bir maliyet DEĞİŞTİRMEZ — GG.6 İLE AYNI
  kategoride bir sonuç. **Hiçbir kod yazılmadı** (GERÇEK uygulama, YENİ
  bir whole-program "saflık" analizi + HER çağrı sitesinin GG.2'nin
  inlining'iyle ETKİLEŞİMİ DAHİL güncellenmesini GEREKTİRİRDİ — SIFIR
  ölçülmüş kazanım İçin orantısız bir mimari karmaşıklık).
- **Kanıtlanabilir sınır-içi erişimlerde bounds-check elemesi** (Faz
  GG.9, bkz. nox-teknik-spesifikasyon.md §3.66). `for i in range(len(xs)):
  ... xs[i] ...` deseninde `i`nin `[0, len(xs))` ARALIĞINDA olduğu
  döngünün KENDİ sınırından ZATEN KANITLANMIŞTIR, ama `genIndex`/
  `genStrIndex` HER erişimde AYRICA bir sınır kontrolü üretiyordu. Kod
  YAZILMADAN ÖNCE ölçüldü (GG.4/GG.6/GG.8'in dersi UYGULANARAK): bu KEZ
  (GG.4/GG.6/GG.8'in AKSİNE) GERÇEK bir fark BULUNDU (~76-77ms →
  ~46-47ms, elle .ssa yaması) — İKİ karşılaştırma + OR + koşullu dal
  zinciri, TEK bir `mul`/argüman farkının AKSİNE, Apple Silicon'da BİLE
  ölçülebilir bir maliyet taşıyor. YENİ `bounds_elide_ctx`, `genForRange`nin
  TESPİT ETTİĞİ desende (GG.5'in `str_len_cache`iyle AYNI `collectReassignedNames`/
  `bodyHasNestedFuncDef` güvenlik disiplini) doldurulur; `genIndex`/
  `genStrIndex` sınır kontrolünü (VE `genStrIndex`de `strlen`in KENDİSİNİ)
  TAMAMEN atlar. Break→red→fix: yeniden-atama koruması GEÇİCİ kaldırılınca
  TAM OLARAK beklenen tek test kırmızı oldu, kontrolün load-bearing olduğu
  kanıtlandı. Ölçüm: `bounds_check_elision` (100M erişim) 67.6ms → 38.7ms,
  **~%43 hızlanma (~1,75×)** — GG.5'ten (~23,3×) SONRA GG serisinin EN
  BÜYÜK ikinci kazanımı. **Yan bulgu:** `list` yerelinin bir `for`-range
  döngüsünde yeniden atanmasının `try/except` İLE BİRLEŞTİĞİNDE ÖNCEDEN
  VAR OLAN (GG.5'in `str` bulgusunun `list` KARŞILIĞI) bir bellek sızıntısı
  KEŞFEDİLDİ — güvenlik testi bu YÜZDEN yalnızca STATİK (IR-metni) olarak
  doğrulandı, ÇALIŞTIRILMADI.
- **Değerlendirildi, KAPATILDI: fiber'ların iş parçacıkları arası
  taşınamaması** (Faz GG.10 — bkz. nox-teknik-spesifikasyon.md §3.66'nın
  "DEĞERLENDİRİLDİ, KAPATILDI" notu; GG serisinin SON maddesi). Bu soru
  ZATEN §3.46 (Faz AA.1, gerçek M:N zamanlayıcı araştırması, 7 mimari
  engel buldu) VE §3.47 (Faz BB.1, kullanıcının shared-nothing modeli
  SEÇTİĞİ karar) İLE soruldu VE cevaplandı — BUGÜN ÇALIŞAN mimari BUDUR.
  `nox.http.serve_multicore` İçin (bu sınırlamanın önemli OLABİLECEĞİ TEK
  senaryo) gerçek bir yük dengesizliği HİÇ ölçülmedi. YENİ bulgu: QBE'nin
  atomic instruction'ı OLMADIĞI DOĞRULANDI (`qbe -h`) — atomic refcount
  `emitInlineRetain`/`emitInlinePredecrement`in (GG.1/GG.7'nin ÖLÇÜLMÜŞ
  ~%23/~%8 kazançlarına sahip inline aritmetiği) YERİNE HER TEK retain/
  release İçin GERÇEK bir fonksiyon çağrısı GEREKTİRİRDİ — GG serisinin
  kazandığı performansın ÖNEMLİ bir kısmını SIFIRLARDI, ÖLÇÜLMÜŞ HİÇBİR
  fayda OLMADAN. **Hiçbir kod yazılmadı.** Faz GG (GG.1-GG.10) BURADA
  TAMAMEN KAPANIR.
- **Accept backlog artırımı (128→1024)** (Faz HH.1, bkz. nox-teknik-
  spesifikasyon.md §3.68). `nox.http.serve`/`serve_multicore`nin
  `bindAndListen`i, `benchmarks/http_compare/zig_server.zig`nin
  karşılaştırma sunucusunun ZATEN kullandığı `1024`e YÜKSELTİLDİ — Nox
  KENDİSİ dezavantajlı bir backlog İLE ölçülüyordu. **Değerlendirildi,
  GERİ ALINDI: `ConnCtx` havuzu.** `Scheduler.stack_pool` desenini
  `ConnCtx`e de uygulama girişimi, ELLE yazılan bir reprodüksiyonla GERÇEK
  bir kullanım-sonrası-serbest-bırakma tuzağı ORTAYA ÇIKARDI: `serveImpl`
  (fiber yolunda) `max_connections` bağlantıyı kabul EDER etmez döner —
  henüz tamamlanmamış bağlantı fiber'ları zamanlayıcı tarafından bu YIĞIN
  ÇERÇEVESİ geri döndükten ÇOK SONRA çalıştırılabilir; havuz `serveImpl`nin
  yerel değişkeni OLARAK tasarlanmıştı, bu da geç biten bir fiber'ın
  temizlik `defer`inin SALLANAN bir işaretçiye yazmasına yol AÇARDI
  (`zig build test`nin İKİ eşzamanlı bağlantılı golden testinde Debug
  modunda TUTARLI şekilde YAKALANDI). `ConnCtx` küçük bir struct olduğundan
  havuzu `Scheduler`e taşımaya (yeni modüller arası bağımlılık) DEĞMEDİ —
  **kod deposundan geri alındı**, `gpa.create`/`gpa.destroy` korundu.
- **İstek alanlarının çift kopyalanmasını gider: kopyala → retain** (Faz
  HH.2, bkz. nox-teknik-spesifikasyon.md §3.68). `connectionEntry`
  `method`/`target`/header isim-değerlerini ÖNCE `gpa.dupe` İLE düz bir
  kopya çıkarıyordu, SONRA Nox tarafı `nox_http_request_method/target/
  body/headers`i çağırdığında `dupeToNoxStr` AYNI veriyi İKİNCİ KEZ
  ARC-sahipli olarak kopyalıyordu. ARTIK `connectionEntry` bu alanları
  DOĞRUDAN ARC-sahipli inşa ediyor (TEK kopya), `nox_http_request_*`
  erişimcileri ARTIK kopyalamaz — YALNIZCA `nox_rc_retain` yapıp AYNI
  işaretçiyi döner. Break→red→fix: `nox_http_request_method`in `retain`i
  GEÇİCİ kaldırılınca `req`in TÜM alanlarını okuyan bir handler'a karşı
  GERÇEK bir istek **SIGSEGV (çıkış kodu 139) İLE ÇÖKTÜ** (çifte serbest
  bırakma) — `retain` GERİ eklenince temiz çalıştı, kontrolün load-bearing
  olduğu KANITLANDI. Yeni bir uçtan uca golden test, `HttpRequest`nin
  DÖRT alanının (method/target/body/headers) TAMAMININ doğru geldiğini VE
  sızıntı/UAF OLMADIĞINI doğrular. **Yan not (AYRI bir takip görevine
  bırakıldı):** `tests/compat/http_serve_multicore_golden_test.zig`nin
  `-Doptimize=ReleaseFast`ta ÖNCEDEN VAR OLAN (`git stash` İLE HH
  serisinden BAĞIMSIZ olduğu doğrulanan) zamanlama-hassasiyetli bir
  "flaky" davranışı GÖZLEMLENDİ.
- **Yanıt tarafındaki çift kopyalamayı gider: kopyala → retain** (Faz
  HH.3, bkz. nox-teknik-spesifikasyon.md §3.68). `nox_http_response_new`,
  `HttpResponse.body`/`.headers` ZATEN Nox'un ARC-sahipli `str`/`dict`i
  OLDUĞU HALDE `gpa.dupe`/`http_client.copyHeaders` İLE YENİDEN
  kopyalıyordu. ARTIK `body` `nox_rc_retain` edilir, `headers` YENİ bir
  `retainHeaders` fonksiyonuyla (HER isim/değeri retain eder) işlenir —
  `http_client.copyHeaders`in KENDİSİ DEĞİŞTİRİLMEDİ (o, İSTEMCİ
  kabuğunun arka plan iş parçacığına GEÇİŞ İÇİN KASITLI olarak bağımsız
  bir kopya çıkarır; `retainHeaders` İSE YALNIZCA ARC sahibi İLE AYNI iş
  parçacığında çalışan sunucu yolunda kullanılır). Break→red→fix: `body`
  retain'i GEÇİCİ kaldırılınca DebugAllocator **"Double free detected"**i
  TAM bir yığın izİYLE yakaladı (`$HttpResponse_release`in `nox_str_free_
  now`ı + `destroyResponse`nin `nox_str_release`i — TAM OLARAK öngörülen
  çifte serbest bırakma); retain GERİ eklenince temiz çalıştı. Bu dosyanın
  KENDİ birim testleri (düz C literal'leriyle çağıranlar) `dupeToNoxStr`
  İLE ÖNCE gerçek bir ARC dizesi inşa edecek şekilde güncellendi. Yeni bir
  uçtan uca golden test, DİNAMİK inşa edilmiş bir yanıt gövdesi VE BİRDEN
  FAZLA yanıt başlığının doğru geldiğini doğrular.
- **`HttpRequest` alanlarının TEMBEL (yalnızca kullanılıyorsa) inşası**
  (Faz HH.4, bkz. nox-teknik-spesifikasyon.md §3.68). `genHttpServeWrapper`
  ARTIK `handle`in `req` gövdesini KONSERVATİF bir AST taramasıyla
  (`computeUsedRequestFields` — TÜM 17 `ast.Expr` VE TÜM `ast.Stmt`
  varyantı İçin TAM, Zig'in kapsamlı switch zorunluluğu SAYESİNDE
  `else` KULLANILMADAN) tarayıp HANGİ `method`/`target`/`body`/`headers`
  alanlarının GERÇEKTEN okunduğunu tespit ediyor — KULLANILMAYAN str
  alanlar İçin pahalı `nox_http_request_*` çağrısı YERİNE `""` (pinned,
  bedava) literal'i, `headers` KULLANILMIYORSA `nox_http_request_headers`
  (O(header sayısı)) YERİNE DOĞRUDAN boş `nox_dict_new` (O(1)) üretiliyor.
  `req`in KENDİSİ (çıplak tanımlayıcı olarak) BAŞKA bir fonksiyona/iç-içe
  bir closure'a KAÇARSA TÜM alanlar KONSERVATİF olarak kullanılmış SAYILIR
  (GG.2/GG.5/GG.9'un AYNI disiplini). Break→red→fix: alan işaretleme
  GEÇİCİ devre dışı bırakılınca, YALNIZCA `req.method`i okuyan bir
  handler **YANLIŞ (boş) bir `method` değeri döndü** — analiz GERİ
  eklenince doğru geldi. Üç senaryo (hiç kullanmayan/yalnızca `method`
  kullanan/başka bir fonksiyona geçiren) ELLE, ayrıca `req`i HİÇ
  referans almayan bir handler YENİ bir golden testle doğrulandı.
- **`dict[K,V]` küçük-harita optimizasyonu** (Faz HH.5, bkz. nox-teknik-
  spesifikasyon.md §3.68 — HTTP'ye ÖZGÜ DEĞİL, TÜM `dict` kullanımına
  fayda sağlar). `runtime/collections/dict.zig`nin `Dict`i ARTIK
  `entries.items.len` `SMALL_MAP_THRESHOLD` (8) ALTINDAYKEN `index`
  hashmap'ini HİÇ İNŞA ETMİYOR — DOĞRUSAL tarama (küçük N İçin
  hash'lemekten DAHA HIZLI) kullanılıyor, `nox_dict_set`in `index.
  putContext` çağrısı TAMAMEN ATLANIYOR. Eşik AŞILDIĞINDA `buildIndex`
  TEK SEFERLİK ÇAĞRILIP MEVCUT TÜM `entries`i `index`e aktarıyor,
  BUNDAN SONRA O(1) hash yoluna GEÇİLİYOR. Break→red→fix: `findIndexLinear`
  GEÇİCİ olarak KOŞULSUZ `null` DÖNDÜRECEK şekilde bozulunca, YALNIZCA
  hedef test DEĞİL, `http_client.zig`nin GET testi VE HH.2'nin dört-alan
  golden testi de KIRMIZI oldu — küçük `dict[str,str]`lerin (HTTP
  header'ları) runtime GENELİNDE ne kadar YAYGIN olduğunun somut kanıtı.
  Eşik-geçişini (8→9 eleman, `index_built`in DOĞRU anda `true`ya geçtiği,
  HER İKİ modda da get/üzerine-yazmanın DOĞRU çalıştığı) doğrulayan yeni
  bir birim testi eklendi; mevcut FF.3 ARC-güvenlik testleri DEĞİŞMEDEN
  yeşil kaldı.
- **HTTP keep-alive desteği** (Faz HH.6, bkz. nox-teknik-spesifikasyon.md
  §3.68). `connectionEntry` ARTIK TEK bir `receiveHead()`den SONRA
  bağlantıyı KOŞULSUZ kapatmıyor — `std.http.Server`nin ZATEN desteklediği
  "aynı bağlantıda birden çok istek" yeteneği KULLANILARAK bir `while`
  döngüsüne alındı; `respond()`e HER ZAMAN `.keep_alive = true` geçilip
  EFEKTİF karar Zig'in KENDİSİNE (istemcinin BEYAN ettiği tercih + HTTP
  sürüm varsayılanı) bırakılıyor. Yeni bir DoS sınırı: `MAX_REQUESTS_PER_
  CONNECTION` (1000) — okuma zaman aşımı (HH.7'ye kadar) OLMADIĞINDAN, tek
  bir bağlantının SONSUZA dek bir fiber'ı MONOPOLİZE etmesini önler.
  **GERÇEK bir hata bulunup düzeltildi (dürüstçe belgeleniyor):** İLK
  tasarım "kapanıyor mu" kararını `server.reader.state != .ready` İLE
  veriyordu — `zig build test`de GERÇEK bir SONSUZ askıda kalmayla
  (`sample`in TAM yığın izleriyle TEŞHİS edildi: sunucu `kevent()`de,
  istemci `read()`te BLOKE) YAKALANDI: `connectionEntry` gövdeyi
  `respond()`DAN ÖNCE ELLE tükettiğinden reader'ın İÇ durumu ZATEN
  `.received_head`in ÖTESİNE geçmiş oluyordu, Zig std'sinin "kapanıyor
  OLARAK işaretle" mantığı YALNIZCA O durumdan geçiş yaptığından GÖVDELİ
  (POST/PUT) istekler İçin HİÇ tetiklenmiyordu. Düzeltme: `server.reader.
  state` YERİNE İSTEMCİNİN KENDİ beyanı (`request.head.keep_alive`)
  DOĞRUDAN kullanıldı. Break→red→fix: `.keep_alive` GEÇİCİ `false`e
  döndürülünce yeni golden test BEKLENDİĞİ gibi kırmızı oldu; geri
  eklenince temiz geçti. Yeni bir uçtan uca golden test, `max_
  connections=1` OLMASINA RAĞMEN `Connection: close` göndermeden İKİ
  ardışık isteğin AYNI bağlantı üzerinden sunulduğunu doğrular.
- **Okuma zaman aşımı / slowloris koruması** (Faz HH.7, bkz. nox-teknik-
  spesifikasyon.md §3.68 — Faz HH bu maddeyle TAMAMEN kapanır).
  `io_reactor.zig`ye `registerWithTimeout`/`cancel` eklendi — bir fd'nin
  KENDİSİ İLE bir zamanlayıcı AYNI ANDA register edilir, HANGİSİ ÖNCE
  ateşlerse fiber'ı uyandırır, DİĞERİ iptal edilir (kqueue'da native
  `EVFILT_TIMER`, epoll'da YENİ `timerfd_create`/`timerfd_settime` + bir
  ETİKETLİ-işaretçi şeması — `epoll_event`in filtre TÜRÜ TAŞIMAMASI
  yüzünden). `Scheduler.suspendForIoOrTimeout` VE `io.
  nonBlockingReadWithTimeout` eklendi; `http_server.zig`nin
  `FiberReader.stream`i (HEM başlık HEM gövde okumasının TEK geçtiği
  nokta) 30 saniyelik bir `READ_TIMEOUT_MS` KULLANIR — aşılırsa bağlantı
  HİÇBİR yanıt yazılmadan sessizce kapatılır. **Bilinçli basitleştirme:**
  eşik TOPLAM süre DEĞİL, HER `EAGAIN` SONRASI YENİDEN başlayan bir
  penceredir — GERÇEK slowloris'in (veri hiç/çok seyrek göndermek)
  tanımına ZATEN aykırı bir çaba gerektirdiğinden v1 İçin kabul edilebilir
  bulundu. Break→red→fix: zaman aşımı kontrolü GEÇİCİ devre dışı
  bırakılınca YENİ eklenen "hiçbir şey göndermeyen bağlantı" testi
  `zig build test`i (25s dış sınırla) SONSUZA dek ASILI bıraktı (`ps` İLE
  doğrulandı); geri eklenince temiz geçti. **Çift platform doğrulama**
  (R.1 disiplini): `scheduler.zig`/`io.zig` `aarch64-linux-musl`e ÇAPRAZ
  derlenip NATIVE (emülasyonsuz, OrbStack) bir aarch64 Docker
  konteynerinde çalıştırıldı — TÜM testler (İKİ YENİ `registerWithTimeout`
  testi DAHİL) yeşil; macOS'ta değişmeden yeşil.

### Düzeltildi
- **`nox.http.serve_multicore`: `max_connections` SONLU olduğunda spawn
  edilen worker OS iş parçacıkları HENÜZ bitirmeden süreç çıkabiliyordu**
  (Faz HH.8, bkz. nox-teknik-spesifikasyon.md §3.66 — kullanıcı tarafından
  bildirilen, `zig build test -Doptimize=ReleaseFast`da %30-70 "failed
  without output" flake'i olarak gözlemlenen GERÇEK bir süreç-çıkış
  yarışı). `genHttpServeMulticore`nin "fire-and-forget" (`ThreadHandle`lar
  ASLA join edilmez) tasarımı `max_connections=0` (sınırsız, ÜRETİM
  varsayılanı) İÇİN doğruydu ama SONLU değerler İÇİN (testlerde ZATEN
  geçerli bir kullanım) yanlıştı: çağıranın kendi payı biter bitmez
  `$main` tamamlanıp süreç çıkabiliyordu — worker'lar KENDİ bağlantılarını
  henüz kabul/sunmamışken bile. Çözüm: spawn edilen `ThreadHandle`lar
  çalışma-zamanı boyutlu bir dizide tutulup çağıranın kendi payı bittikten
  SONRA (sınırsız modda bu satıra hiç ulaşılmaz, davranış değişmez)
  `nox_thread_join`+`nox_thread_destroy` ile join edilir. Break→red→fix:
  join döngüsü geçici geri alınınca aynı test binary'si 25 ardışık
  koşumda %32 (8/25) başarısızlık verdi (bildirilen oranla tutarlı); geri
  eklenince 40 ardışık koşumda 0 başarısızlık.
  **Açık bulgu, ÇOK SAATLİK araştırmayla İZOLE edildi (Faz HH.9, bkz.
  nox-teknik-spesifikasyon.md §3.66):** hem BU testte HEM `serve_multicore`
  KULLANMAYAN, çıplak `nox.thread.start`+`serve_fd`+`await t.join()`
  desenini kullanan İKİNCİ testte, `zig build test`in (Debug modu) altında
  `SIGABRT`/stack-smashing gözlemlendi — AMA AYNI derlenmiş ikili
  `-Doptimize=ReleaseFast` VE `-Doptimize=ReleaseSafe` (GÜVENLİK kontrolleri
  HÂLÂ aktif, ama `smp_allocator`) İLE TAMAMEN temiz. Fiber bağlam-değişimi,
  destroy/join sıralaması, ThreadHandle çift-serbest-bırakma, çocuk iş
  parçacığı temizliği, paylaşılan dize literallerinin ATOMİK OLMAYAN ARC
  refcount'u (HEM runtime fonksiyonlarında HEM QBE'nin GÖMÜLÜ IR'ında,
  İKİSİ de atomik yapılıp test edildi) VE QBE'nin çağrılar-arası uzun
  ömürlü değerleri (yığın yuvası + gerçek yığın-dışı hücre, İKİSİ de
  denendi) yanlış koruması hipotezlerinin HEPSİ deneysel A/B testleriyle
  KESİN olarak ELENDİ. Sorun `std.heap.DebugAllocator`ın KENDİSİNE ÖZGÜ
  bir davranışla main_body'nin QBE çıktısı arasındaki bir etkileşime
  izole edildi ama TAM mekanizma bulunamadı (Zig'in KENDİ, üçüncü taraf
  kaynağına inmek gerekirdi). **Karar:** `ReleaseSafe`, Debug'un AYNI
  güvenlik ağını taşıyan ama bu sorunu SERGİLEMEYEN yeterli bir doğrulama
  vekili olarak kabul edildi — `zig build test -Doptimize=ReleaseSafe`
  TAMAMEN yeşil. HH serisinden BAĞIMSIZ, ÖNCEDEN VAR OLAN, dar bir
  `DebugAllocator`-özgü istisna olarak KAYITLI, kapsam dışı bırakıldı.
- **HTTP benchmark karşılaştırmasının (bkz. `benchmarks/RESULTS.md`
  "Bölüm 3") YAYIMLANAN İLK sonuçları YANLIŞTI, DÜZELTİLDİ.** İlk sürüm,
  `nox.http.serve_multicore`nin yüksek eşzamanlılıkta (c=100) çıplak Zig
  soket tabanına göre 30x+ GERİLEDİĞİNİ raporlamıştı — bu, İKİ AYRI
  benchmark-metodolojisi HATASINDAN kaynaklanıyordu, Nox'un KENDİSİNDE
  böyle bir sorun YOK: (1) `noxc build`, o an `zig-out/lib/noxrt.o`da NE
  VARSA ONU KOŞULSUZ kullanır — en son çalıştırılan `zig build` (ReleaseFast
  BAYRAĞI OLMADAN) runtime'ı YANLIŞLIKLA Debug modunda kurmuştu (TEK/
  kilitli `DebugAllocator` — ReleaseFast'ın kilitsiz `smp_allocator`ı
  YERİNE), bu da çok iş parçacıklı yükte ORANTISIZ kilit çekişmesine yol
  açtı; (2) benchmark sunucusunun `max_connections` parametresi YANLIŞLIKLA
  `4096`ya (SINIRSIZ yerine) AYARLANMIŞTI, bu da GERÇEK bir yük testinin
  ORTASINDA sunucunun SESSİZCE durup çıkmasına yol açıyordu. Düzeltmeler
  UYGULANIP (ReleaseFast runtime + `max_connections=0`) benchmark YENİDEN
  çalıştırıldığında Nox, HER İKİ eşzamanlılık seviyesinde de çıplak Zig
  tabanını GEÇTİ — kayda değer bir gerileme/kararsızlık YOK.
- **`runtime/async_rt/scheduler.zig`nin `run()`unda GERÇEK, BAĞIMSIZ bir
  O(n)→O(n²) verimsizlik bulundu ve düzeltildi** (yukarıdaki araştırma
  sırasında — dominant neden DEĞİLDİ, ama gerçek bir iyileştirme):
  hazır kuyruğun `orderedRemove(0)`ı HER kaldırmada TÜM kalan elemanları
  kaydırıyordu (O(n)) — `reactor.poll` TEK çağrıda 64'e kadar fiber'ı
  BİRDEN hazır kuyruğa ekleyebildiğinden, yoğun G/Ç altında bu PARTİYİ
  boşaltmak O(n²) olurdu. Zamanlayıcının hazır kuyruğu SIRALAMA (FIFO)
  DEĞİL yalnızca ADALET gerektirdiğinden `swapRemove(0)` (O(1)) GÜVENLE
  kullanılabilir — mevcut TÜM testler DEĞİŞMEDEN yeşil kaldı.

### Eklendi
- **`nox.*` stdlib / Rust `std` karşılaştırması (Faz II, bkz. nox-teknik-
  spesifikasyon.md §3.67 — kullanıcı isteği).** Var olan 6 `nox.*` stdlib
  benchmark'ının (`strings_bench`/`math_bench`/`os_fs_bench`/`time_bench`/
  `dict_bench`/`strings_perf_bench`) BİREBİR AYNI algoritmalı Rust `std`
  eşdeğerleri (`benchmarks/*_bench.rs`, `rustc -O`, Cargo YOK) yazılıp
  `benchmarks/run.zig`ye KALICI bir "Bölüm 4" harness'ı olarak eklendi.
  `nox.json`/`nox.random`/`nox.regex`/`nox.crypto` BİLİNÇLİ OLARAK
  zamanlanmadı — Rust'ın `std`inde bunların HİÇBİRİ YOK. **Bulgu:** 5/6
  benchmark'ın farkı ölçüm gürültüsünün İÇİNDE (2-6ms mutlak süre); ama
  `strings_perf_bench` İKİ AYRI koşuda TEKRARLANABİLİR biçimde **~16x
  YAVAŞ** ölçüldü — kök neden, `nox.strings.contains`/`index_of`nin SAF
  Nox'ta bayt-bayt bir fonksiyon-çağrısı döngüsüyle O(n×m) arama yapması
  (Rust'ın SIMD-destekli `str::contains`inin AKSİNE). TÜM `nox.*` modülleri
  İçin (zamanlanmayanlar dahil) bir eksik-fonksiyon/yetenek analizi
  RESULTS.md Bölüm 4'e eklendi.
- **`index_of`/`starts_with`/`ends_with` Zig kabuğuna taşındı (AYNI faz
  İçinde, kullanıcının "devam edelim" talimatıyla).** Yukarıdaki bulgu
  ÜZERİNE, EE.1'in `join`e uyguladığı AYNI tedavi (`stdlib/nox/strings.nox`
  → `runtime/stdlib_shims/strings.zig`, `std.mem.indexOf`/`startsWith`/
  `endsWith`i SARAN 3 yeni `extern def`) uygulandı; `contains` HÂLÂ saf
  Nox'ta kalır (`index_of`e devreder, hızı OTOMATİK devralır). Break→red→
  fix: `nox_strings_index_of_raw` geçici bozulunca `zig build test` 4 test
  BAŞARISIZ verdi, geri eklenince Debug/ReleaseSafe/ReleaseFast ÜÇÜ de
  yeşil. **Sonuç: `strings_perf_bench`nin yavaşlaması 16.2x'ten 3.6x'e
  DÜŞTÜ** (208.7ms → 47.2ms, Rust'ın 12.9ms'i sabit kaldı).
- **`index_of`nin arama algoritması değiştirildi (AYNI faz, kullanıcının
  "onu da yapalım" talimatıyla — başta bir `String`/`StringBuilder`
  istendi, ama izole ölçüm bunun YANLIŞ hedef olduğunu gösterdi).**
  `strings_perf_bench`nin İKİ yarısı (contains-tarama VE join) ayrı ayrı
  ölçülünce kalan farkın `join`de DEĞİL, HÂLÂ `contains`/`index_of`de
  olduğu görüldü; SAF bir Zig testiyle (Nox'un çağrı/ARC makinesi HİÇ
  karışmadan) izole edilince sorunun Nox'ta DEĞİL, `std.mem.indexOf`nin
  KENDİSİNDE (Boyer-Moore-Horspool, HER çağrıda 256 baytlık skip-tablosu
  YENİDEN kurup SIMD kullanmıyor) olduğu doğrulandı.
  `nox_strings_index_of_raw`, Zig'in SIMD-vektörleştirilmiş
  `std.mem.indexOfScalarPos`sini KULLANAN bir "ilk baytı bul + doğrula"
  yardımcısına (`fastIndexOf`) geçirildi — bilinçli v1 ödünleşimi: en
  kötü durumda (needle'ın ilk baytı haystack'ta çok sık tekrarlıyorsa)
  O(n×m)ye geri döner, gerçek metinde NADİR kabul edildi. Break→red→fix
  YİNE 4 test BAŞARISIZ/yeşil döngüsüyle doğrulandı. **Sonuç:
  `strings_perf_bench`nin yavaşlaması 3.6x'ten 1.1x'e DÜŞTÜ** (47.2ms →
  13.8ms, Rust'ın 12.9ms'ine pratikte eşdeğer).
- **`nox.path` Rust karşılaştırmasına eklendi + `join`deki gerçek
  darboğaz düzeltildi (AYNI faz, kullanıcının "diğer stdlib alanları da
  benchmarklandı mı" sorusuyla).** `nox.path` (Rust'ın `std::path::Path`
  iyle ADİL karşılaştırılabilir olduğu HALDE) Faz II'nin İLK turunda
  atlanmıştı — sıfırdan `benchmarks/path_bench.{nox,rs}` yazılıp harness'a
  eklendi. **İLK ölçüm 9.4x-9.9x YAVAŞ çıktı** (147ms'e karşı Rust'ın
  ~15-16ms'i). Kök neden: `nox_path_join_raw`nin eski uygulaması
  `std.fs.path.join`i `std.heap.page_allocator` (YAVAŞ, sayfa-granülerlikli)
  İLE çağırıp SONRA İKİNCİ bir ARC kopyası çıkarıyordu — çağrı başına 2
  tahsis. `nox_strings_join_raw`nin (EE.1) AYNI stratejisiyle (2-yol İçin
  basitleşmiş ayraç-mantığı EL İLE, `arc.nox_rc_alloc`a TEK tahsis)
  düzeltildi. Break→red→fix (GERÇEK bir "Invalid free" çökmesi bile
  YAKALANDI) İLE doğrulandı, Debug/ReleaseSafe/ReleaseFast ÜÇÜ de yeşil.
  **Sonuç: `path_bench` 147ms'ten ~8ms'e düştü, yavaşlama 9.4x-9.9x'ten
  0.5x-0.6x'e (Nox ARTIK Rust'tan HIZLI) döndü.**

### Eklendi
- **`json`/`random`/`regex`/`crypto` GERÇEK Rust crate'lerine karşı
  benchmarklandı + test kapsamı genişletildi (Faz II devamı, kullanıcı
  isteği).** `benchmarks/rust_crates/` (GERÇEK Cargo projesi, `serde_json`/
  `rand`/`regex`/`sha2`, `Cargo.lock` commit edilir) eklenip `run.zig`nin
  "Bölüm 5" harness'ına bağlandı. **Sonuçlar:** `json_bench` ~2.7x YAVAŞ
  (kök neden MİMARİ — HER JSON düğümü İçin bir Zig→Nox çapraz-dil çağrısı,
  DÜZELTİLMEDİ, ayrı bir yeniden-tasarım gerektirir); `random`/`regex`/
  `crypto` İSE Nox'ta Rust'tan HIZLI ölçüldü (crypto'da ~4x). `crypto.zig`
  (DAHA ÖNCE SIFIR unit testi) + `random.zig` + `regex.zig` test kapsamı
  genişletildi.

### Düzeltildi
- **`nox.json.encode`, `\t`/CR İÇEREN dizelerde GEÇERSİZ JSON üretiyordu
  (round-trip decode YAKALANMAMIŞ istisnayla ÇÖKÜYORDU) — DÜZELTİLDİ**
  (test kapsamı genişletmesi sırasında bulundu). `encode_string`e `\t`/CR
  escape'i eklendi (3 yeni golden testle DOĞRULANDI). **Beklenmedik bulgu:
  Nox'un lexer'ı `\r`yi escape olarak TANIMAZ** (sessizce `\` düşürülüp düz
  `r` harfi alınır) — CR bu yüzden `nox.strings.byte_at` İLE bayt-değeri
  (13) karşılaştırılarak yakalandı, string literaliyle DEĞİL.

### Değerlendirildi (kapsam dışı bırakıldı, GERÇEK bir derleyici hatası)
- **Kalan C0 kontrol karakterleri İçin genel `\u00XX` JSON escape'i
  eklenmeye ÇALIŞILIRKEN GERÇEK, CİDDİ bir derleyici hatası bulundu.**
  `list[str]` DÖNEN bir yardımcı fonksiyon (hex-basamak arama tablosu)
  bir DÖNGÜ İÇİNDEKİ AYNI ifadede İKİ KEZ çağrıldığında ARC muhasebesi
  BOZULUYOR — Debug modunda `nox_rc_predecrement`da "incorrect alignment"
  panikı, ReleaseFast'ta SESSİZ bir SIGSEGV. Bir `str`-tabanlı alternatif
  ÇÖKMÜYOR ama HER çağrıda GERÇEK bir bellek sızıntısına yol AÇIYOR. Genel
  escape yolu bu YÜZDEN UYGULANMADI; kullanıcıya AYRI, ÖZEL bir derleyici-
  hatası araştırma görevi olarak bildirildi (GG serisinin serbest-
  fonksiyon inlining'iyle İLGİLİ OLABİLECEĞİ düşünülüyor, kesin kök neden
  bulunmadı — HH.9'un araştırma disiplinini gerektiren AYRI bir görev).
- **YUKARIDAKİ derleyici hatası, kullanıcının İKİ AYRI "yapabilirsin"
  onayıyla HH.9'un AYNI disipliniyle DAHA DA DERİN araştırıldı (bkz.
  nox-teknik-spesifikasyon.md §3.68).** İLK turun "QBE register çakışması"
  hipotezi, Nox'u HİÇ karıştırmayan EL YAZIMI bir `.ssa` dosyasıyla test
  edilip 100+ koşuda DOĞRULANAMADI. İKİNCİ turda `churn`nin `main` HARİÇ
  TÜMÜ gerçek `noxrt.o`ya karşı DOĞRUDAN, tek bir süreç İçinde tekrar
  tekrar ÇAĞRILARAK ÇOK daha net bir desen bulundu: **~%20'lik ASLR'ye
  bağlı Heisenbug İZLENİMİ YANLIŞTI/YANILTICIYDI** — asıl tetikleyici,
  BİR TEK çağrı İÇİNDEKİ döngünün KAÇINCI yinelemesi. 10 satırlık YENİ bir
  tekrarlama (`loopcall(n)`: `hexd(1) + hexd(2)`yi `n` kez döngüleyen)
  **`n=1`de 20/20 TEMİZ, `n=2`de ~20/20 ÇÖKÜYOR** — yani BİRİNCİ yineleme
  HER ZAMAN güvenli, İKİNCİDEN İTİBAREN döngü SONUNDAKİ liste serbest-
  bırakma çağrısı GEÇERSİZ bir işaretçiyle çöküyor. İki kontrol testi
  (döngüsüz tekrar çağrı TEMİZ; döngüsüz aynı-ifadede-iki-çağrı TEMİZ)
  tetikleyicinin TAM OLARAK "list[str] döndüren fonksiyonun aynı
  ifadede iki kez çağrılması + 2 yinelemeli bir döngü" BİRLİKTELİĞİ
  olduğunu KESİN olarak izole etti. Kök mekanizma YİNE kanıtlanamadı
  (QBE'nin register tahsisi mi, `codegen.zig`nin döngü-gövdesi/GG.2
  inlining etkileşimi mi belirsiz) ama tekrarlanabilirlik %20'den ~%100'e
  çıkarıldı ve gelecekteki araştırma İçin çok daha küçük/net bir başlangıç
  noktası bırakıldı; kapsam yine bu fazın DIŞINDA.

### Eklendi
- **Faz III.1 — `nox.math`ye trigonometri/logaritma/sabitler eklendi**
  (bkz. nox-teknik-spesifikasyon.md §3.69). `sin`/`cos`/`tan`/`log`/`exp`/
  `atan2` — mevcut `sqrt`/`pow`/`floor`/`ceil` İLE AYNI çıplak-çağrılan
  `extern def ... from "m"` deseni. `ln` (libm'de BÖYLE bir sembol
  OLMADIĞINDAN `log`u SARAN nitelikli bir `func_def`) VE `pi()`/`e()`
  (Nox'ta top-level `const` OLMADIĞINDAN nitelikli çağrılan sabit-
  fonksiyonlar) eklendi. Yeni golden test. SAF Nox, runtime/codegen
  değişikliği YOK.
- **Faz III.2 — `nox.strings`ye eksik yardımcılar eklendi** (bkz.
  nox-teknik-spesifikasyon.md §3.69). `trim_start`/`trim_end`,
  `splitn(s,sep,n)` (EN FAZLA `n` parça, SONUNCUSU KALANIN TAMAMI),
  `rsplit(s,sep)` (AYNI parçalar, TERS sıra), `repeat(s,n)` (EE.1'in
  `join`iyle AYNI TEK-tahsis stratejisi), `eq_ignore_case(a,b)`. 7 yeni
  unit test (break→red→fix İLE doğrulandı) + 1 yeni golden test.
- **Faz III.3 — `nox.fs`ye `append_string`/`metadata`/`read_dir`/`copy`/
  `rename`/`remove_file`/`create_dir` eklendi + `read_to_string`nin
  `page_allocator` çift-tahsis deseni düzeltildi** (bkz. nox-teknik-
  spesifikasyon.md §3.69). `metadata()` `DateTime`nin AYNI Nox-tarafı
  sınıf inşa deseniyle (`std.c.fstat`, FD-tabanlı — YOL-tabanlı `std.c.
  stat`in aksine BU Zig sürümünde GERÇEKTEN ÇALIŞTIĞI doğrulandı);
  `read_dir()` HAM libc `opendir`/`readdir`/`closedir` İLE (`.`/`..`
  atlanır); `copy` TAŞINABİLİR (macOS'a-özgü `copyfile()` KULLANILMAZ).
  **Fırsatçı düzeltme:** `read_to_string_raw`, `path.zig`nin EE.1-SONRASI
  düzeltmesinden ÖNCEKİ `page_allocator` desenini kullanıyordu — `fstat`
  İLE dosya boyutu ÖNCEDEN alınıp TEK bir `arc.nox_rc_alloc`a geçirildi.
  Yeni `fs_bench` İLE ÖNCE/SONRA ÖLÇÜLDÜ: **~170-180ms → ~130-138ms
  (~1.25-1.3x)** — `path_bench`nin ~9.9x'inden MÜTEVAZİ (disk G/Ç süresi
  BASKIN) ama GERÇEK. 14 yeni unit test (break→red→fix İLE doğrulandı) +
  1 yeni golden test (idempotent, tekrar tekrar koşulabilir).
- **Faz III.4 — `nox.path`ye `canonicalize`/`strip_prefix`/`components`
  eklendi** (bkz. nox-teknik-spesifikasyon.md §3.69). `canonicalize`
  (`std.c.realpath` — modülün "hiç I/O yok" ilkesine BİLİNÇLİ istisna,
  YENİ `PathError`; GERÇEK bir test macOS'ta `/tmp`nin KENDİSİNİN
  `/private/tmp`ye sembolik link OLDUĞUNU ORTAYA ÇIKARDI); `strip_prefix`
  (eşleşmezse DEĞİŞMEDEN döner); `components()` (`std.fs.path.
  componentIterator`, SAF string ayrıştırma). 4 yeni unit test
  (break→red→fix İLE doğrulandı) + 1 yeni golden test.
- **Faz III.5 — `nox.os`ye `set_var`/`current_dir` eklendi** (bkz.
  nox-teknik-spesifikasyon.md §3.69). `set_var` (`std.c`de OLMAYAN
  `setenv`, `foreign_bridge.zig`nin desenine UYGUN ham `extern "c" fn`
  bildirimiyle bağlandı); `current_dir` (`std.c.getcwd`). `nox.os`nin
  İLK yazma yan-etkili fonksiyonları. 2 yeni unit test (break→red→fix
  İLE doğrulandı) + 1 yeni golden test.
- **Faz III.6 — `dict[K,V]`ye `keys()`/`values()` eklendi** (bkz.
  nox-teknik-spesifikasyon.md §3.69). `contains`/`len` İLE AYNI yerleşik-
  metod deseni; `runtime/collections/dict.zig`ye YENİ `nox_dict_keys`/
  `nox_dict_values` (+ ortak `buildEntryList`). `DictInfo`ye YENİ bir
  simetrik `key_qtype` alanı eklendi (`bool` anahtar/değerlerin doğru
  4 baytlık `list[bool]` eleman boyutuyla round-trip yapması İÇİN). `str`
  anahtar/değerler `nox_rc_retain` İLE PAYLAŞILIR (dict VE dönen liste
  BAĞIMSIZ sahip olur). 4 yeni unit test (break→red→fix İLE doğrulandı,
  retain kaldırılınca GERÇEK bir kullanım-sonrası-serbest-bırakma/sızıntı
  yakalandı) + 1 yeni golden test.
- **Faz III.7 — `nox.time`ye `DateTime.to_str()` + `Instant`/`Duration`
  eklendi** (bkz. nox-teknik-spesifikasyon.md §3.69). `to_str()` SAF Nox
  (YENİ `pad2` yardımcısıyla elle sıfır-doldurma); `Instant`/`Duration`
  YENİ `nox_time_monotonic_ms_raw` (`.MONOTONIC`, `now_ms`nin duvar-saati
  `.REALTIME`sinden FARKLI — Rust'ın `Instant::now()`si İLE AYNI ilke)
  üzerine kurulu. 1 yeni unit test (break→red→fix İLE doğrulandı) + 1
  yeni golden test.
- **Faz III.8 — `nox.random`a `normal()`/`exponential(rate)` + `shuffle[T]`
  eklendi** (bkz. nox-teknik-spesifikasyon.md §3.69). Dağılımlar SAF Nox
  (Box-Muller/ters-CDF); `shuffle` Fisher-Yates, `list[T]`nin MEVCUT
  indeksleme/atamasıyla YERİNDE çalışır. **Yan ürün düzeltme:**
  `checker.zig`nin `resolveMangledCall`ine `self.generic_functions`
  kontrolü eklendi — nitelikli çağrılar (`nox.random.shuffle(xs)`) DAHA
  ÖNCE generic fonksiyonları HİÇ bulamıyordu (yalnızca aynı-modül ÇIPLAK
  çağrılar çalışıyordu). break→red→fix İLE doğrulandı + 1 yeni golden test.
- **Faz III.9 — `nox.crypto`ye `sha1`/`sha512` eklendi** (bkz.
  nox-teknik-spesifikasyon.md §3.69). `sha256` İLE BİREBİR AYNI desen —
  Zig'in KENDİ `std.crypto.hash.Sha1`/`sha2.Sha512`si. Bilinen test
  vektörleriyle (`""`/`"abc"`) doğrulandı. 4 yeni unit test (break→red→fix
  İLE doğrulandı) + 1 yeni golden test.
- **Faz III.10 — `nox.json`ye `encode_pretty(v, indent)` eklendi** (bkz.
  nox-teknik-spesifikasyon.md §3.69). SAF Nox, `nox.strings.repeat`
  (Faz III.2) İLE girinti üretir — Python'un `json.dumps(v, indent=N)`si
  İLE AYNI biçim/anlam. Zig-tarafı DEĞİŞİKLİK GEREKMEDİ, break→red→fix
  golden test İLE yapıldı + 1 yeni golden test.
- **Faz III TAMAMLANDI** — stdlib eksik-fonksiyon tablosunun 10 alt-fazının
  (III.1-III.10) TÜMÜ uygulandı. 5 madde (+ UTF-8) BİLİNÇLİ olarak AYRI,
  kendi planlama turlarını gerektiren görevler olarak kapsam DIŞI bırakıldı
  (bkz. nox-teknik-spesifikasyon.md §3.69'un giriş notu).

### Düzeltildi
- **Faz JJ — §3.68'de belgelenen, daha önce ÇÖZÜLEMEYEN `list[str]` +
  döngü ARC bozulması hatası ÇÖZÜLDÜ** (bkz. nox-teknik-spesifikasyon.md
  §3.68'in "Bulgu 3" altbölümü). `lldb` İLE kök neden bulundu: bir
  `list[str]` yerel değişkeni İÇEREN küçük bir fonksiyon 2+ yinelemeli bir
  döngü İçinde AYNI ifadede İKİ KEZ inline çağrıldığında, `releaseSlotIfSet`
  (bir yerel değişkeni serbest bırakan çekirdek fonksiyon) slotu serbest
  bıraktıktan SONRA sıfırlamıyordu — inline edilmiş bir çağrı sitesinin
  slotu (GERÇEK bir fonksiyonun aksine) döngü yinelemeleri ARASI YENİDEN
  KULLANILDIĞINDAN, bir SONRAKİ yinelemenin "üzerine yazmadan önce eskiyi
  serbest bırak" mantığı ZATEN serbest bırakılmış (VE genellikle YENİDEN
  KULLANILMIŞ) bir POINTER'I "canlı" sanıp TEKRAR serbest bırakıyordu —
  gerçek bir çift-serbest-bırakma/kullanım-sonrası-serbest-bırakma
  (`"incorrect alignment"` paniği/SIGSEGV). Düzeltme: `releaseSlotIfSet`
  VE `destroyNonArcSlotIfSet`ye (`Task`/`Channel`/`ThreadHandle`/
  `ThreadChannel` karşılığı) serbest bırakma/yıkımdan HEMEN SONRA slotu
  sıfırlayan birer satır eklendi. Break→red→fix İLE doğrulandı (düzeltme
  geri alınınca AYNI panik/yığın izi GERİ GELDİ) + 1 yeni golden test.
- **Faz KK.1 — Güvenlik bulgusu H-2: `dict[K,V]` eksik anahtar erişimi
  artık `KeyError` raise ediyor** (bkz. nox-teknik-spesifikasyon.md
  §3.70). ÖNCEDEN eksik anahtarda sessizce null dönen `d[key]`, sonraki
  HER kullanımda (`len()` gibi) GERÇEK bir null-pointer çökmesine
  (SIGSEGV, doğrudan doğrulandı) yol açıyordu — AYRICA `dict[str,int]`
  gibi sayısal değer tiplerinde saklı GERÇEK bir `0` DEĞERİYLE "anahtar
  YOK" durumu AYIRT EDİLEMİYORDU (bağımsız bir doğruluk hatası).
  `genDictGet` artık `nox_dict_contains` İLE ÖNCE varlığı kontrol edip
  yoksa YENİ `KeyError` sınıfını (`IndexError`/`ValueError` İLE AYNI
  statüde) raise ediyor. Break→red→fix İLE doğrulandı + 1 yeni golden
  test.
- **Faz KK.2 — Güvenlik bulgusu H-1: `hpy_call`ın yol/uzantı/fonksiyon
  adı artık derleme-zamanı string literali olmak ZORUNDA** (bkz.
  nox-teknik-spesifikasyon.md §3.70). ÖNCEDEN bu üç argüman yalnızca
  TİPÇE `str` olmak zorundaydı — DEĞER olarak çalışma-zamanı hesaplı
  keyfi bir ifade OLABİLİYORDU, `hpy_bridge`nin doğrulamasız `dlopen`ı
  İLE birleşince SIRADAN Nox kodundan ulaşılabilen bir "keyfi native
  kütüphane yükle" ilkeli oluşturuyordu. Checker artık üçünü de `.string_
  lit` (derleme-zamanı sabiti) OLMAYA zorluyor. Break→red→fix İLE
  doğrulandı + 1 yeni unit test.
- **Faz KK.3 — Güvenlik bulgusu H-3: ayrıştırıcıya özyineleme-derinliği
  sınırı eklendi** (bkz. nox-teknik-spesifikasyon.md §3.70). Özyinelemeli-
  iniş ayrıştırıcının HİÇBİR derinlik sınırı YOKTU — 50.000 iç içe
  parantez İÇEREN bir `.nox` dosyası `noxc`nin KENDİSİNİ yığın taşmasıyla
  ÇÖKERTİYORDU (doğrudan doğrulandı). `Parser`e paylaşılan bir `depth`
  sayacı + `enterRecursion`/`exitRecursion` eklendi, ÜÇ AYRI özyineleme
  giriş noktasında (`parseExpr`, kendi-kendine-özyineleyen `parseNot`/
  `parseUnary`) çağrılır — `MAX_EXPR_DEPTH=500` aşılırsa YENİ `ParseError.
  RecursionLimitExceeded` döner. Break→red→fix İLE doğrulandı (dört
  alt-durumlu 1 yeni unit test — makul derinlik SORUNSUZ, parantez/`not`/
  eksi zincirlerinin ÜÇÜ de yakalanıyor).
- **Faz KK (H-1/H-2/H-3) TAMAMLANDI** — güvenlik raporunun ÜÇ yüksek
  öncelikli bulgusunun TÜMÜ düzeltildi.
- **Faz KK.4 — Güvenlik bulgusu M-1: HTTP başlık CR/LF doğrulaması artık
  HER build modunda çalışıyor** (bkz. nox-teknik-spesifikasyon.md
  §3.70). `std.http`nin KENDİ doğrulaması yalnızca `assert`le
  yapıldığından `ReleaseFast`te TAMAMEN devre dışıydı — kullanıcı
  verisini bir başlığa yansıtan bir Nox programı ÜRETİMDE SESSİZCE CRLF
  enjekte edebiliyordu (başlık/yanıt bölme), Debug/ReleaseSafe'de İSE
  AYNI girdi panikle ÇÖKMEYE yol açıyordu. `http_client.copyHeaders`/
  `http_server.retainHeaders`e HER modda ÇALIŞAN GERÇEK birer `if`
  kontrolü eklendi — bozuk başlık SESSİZCE ATLANMAZ, İSTEĞİN/YANITIN
  TAMAMI reddedilir. Break→red→fix İLE doğrulandı (`ReleaseFast` DAHİL)
  + 6 yeni unit test.
- **Faz KK.5 — Güvenlik bulgusu M-3: `dict[K,V]`nin hash tohumu artık
  rastgeleleştirilmiş (hash-flooding'e karşı)** (bkz. nox-teknik-
  spesifikasyon.md §3.70). `dict.zig`nin `str`-anahtar hash'i (`Wyhash`)
  HER ZAMAN SABİT `seed=0` İLE çalışıyordu — `nox.http`nin `HttpRequest.
  headers`ı TAM OLARAK `dict[str,str]` OLDUĞUNDAN, 8'den fazla başlık
  gönderen bir saldırgan ÖNCEDEN bilinen sabit tohumla çakışan anahtarlar
  üretip bir Nox HTTP sunucusunu O(1) ortalamadan O(n) en-kötü-duruma
  düşürebiliyordu (klasik hash-flooding DoS'u). YENİ `hashSeed()`, HER
  iş parçacığının kendi `threadlocal` (bir `Dict` HER ZAMAN TEK bir iş
  parçacığına aittir) rastgele tohumunu `std.c.arc4random_buf` İLE BİR
  KEZ üretip yeniden kullanır. Break→red→fix İLE doğrulandı + 2 yeni
  unit test.
- **Faz KK.6 — Güvenlik bulguları M-4/M-5/M-6: `nox.crypto`ya HMAC +
  zaman-sabit karşılaştırma + güvenli rastgelelik eklendi, `sha1`e
  uyarı düşüldü** (bkz. nox-teknik-spesifikasyon.md §3.70). Stdlib'de
  mesaj bütünlüğü İçin HMAC, belirteç karşılaştırması İçin zaman-sabit
  bir alternatif, GÜVENLİ rastgelelik İçin bir CSPRNG YOKTU. Eklenenler:
  `hmac_sha256(key, data)` (`std.crypto.auth.hmac.sha2.HmacSha256`),
  `constant_time_eq(a, b)` (`==`in zamanlama yan-kanalına AÇIK `strcmp`
  tabanlı karşılaştırmasının GÜVENLİ alternatifi), `secure_random_hex(n)`
  (`std.c.arc4random_buf`, `nox.random`nin BİLİNÇLİ OLARAK kriptografik
  olmayan PRNG'sinin YERİNE). `sha1`in belge notuna SHAttered çakışma
  zayıflığı uyarısı eklendi. Break→red→fix İLE doğrulandı + 5 yeni unit
  test + 1 yeni golden test.
- **Faz KK.7 — Güvenlik bulgusu M-8: paket yöneticisinin repo URL şema
  doğrulaması artık AÇIK bir izin listesi kullanıyor** (bkz. nox-teknik-
  spesifikasyon.md §3.70). `resolveCloneUrl`, `"://"` İÇEREN HERHANGİ bir
  `repo` değerini (dizenin HERHANGİ bir YERİNDE, yalnızca ÖNEK olarak
  DEĞİL) "zaten şemalı" sayıp `git clone`a OLDUĞU GİBİ geçiriyordu —
  saldırgan etkisindeki bir manifest, gizlenmiş bir `ext::` transportuyla
  KEYFİ komut yürütmeyi DENEYEBİLİRDİ (git'in KENDİ varsayılan reddi
  DIŞINDA hiçbir Nox-tarafı korumadan). Artık yalnızca `https`/`http`/
  `git`/`ssh`/`file` ÖNEKLERİ (`startsWith`) kabul ediliyor, aksi halde
  `error.UnsupportedRepoScheme`. **Faz KK'nin TÜM yüksek+orta öncelikli
  bulguları (H-1/H-2/H-3/M-1/M-3/M-4/M-5/M-6/M-8) TAMAMLANDI** — yalnızca
  M-2 (gerçek bir `bytes` tipi) VE M-7 (parola KDF'i) BİLİNÇLİ olarak
  UZUN VADEYE bırakıldı. Break→red→fix İLE doğrulandı + 2 yeni unit test.
- **Faz LL.1 — Windows desteği: derleyici ön-ucu + Windows CI iskeleti**
  (bkz. nox-teknik-spesifikasyon.md §3.71). Araştırma, `runtime/
  async_rt/io_reactor.zig`nin dosya-seviyesi bir `comptime`
  `@compileError`sinin Windows'ta HEM `noxrt.o`yu HEM `nox.thread`/
  `spawn`/`await`/`nox.http`i ENGELLEDİĞİNİ, AMA `noxc`/`noxlsp`nin
  (derleyicinin KENDİSİ) HİÇBİR POSIX-özgü çağrı İÇERMEDİĞİNİ ortaya
  çıkardı — TÜM Windows engeli `runtime/` İÇİNDE, derleyici ön-ucunda
  DEĞİL. `build.zig`ye `noxrt`den TAMAMEN BAĞIMSIZ iki YENİ adım eklendi:
  `zig build noxc` (yalnızca `noxc`/`noxlsp`/`stdlib`) VE `zig build
  frontend-test` (yalnızca `compiler/lib.zig`nin lexer/parser/checker
  testleri). `.github/workflows/ci.yml`ye mevcut 3-platform matrisinin
  YANINA AYRI bir `windows-frontend` işi eklendi — GERÇEK bir
  `windows-latest` çalıştırıcısında Zig kurup bu iki adımı VE bir
  `noxc.exe check` duman testini çalıştırır. Mevcut `install`/`test`/
  `run`/`bench` adımları VE 3-platform matrisi DEĞİŞMEDİ (sıfır
  regresyon, TAM test paketi Debug/ReleaseSafe/ReleaseFast'te
  doğrulandı). **Bu, GENEL Windows desteği DEĞİL** — yalnızca derleyici
  ön-ucunun native Windows'ta çalıştığını kanıtlar; `noxc build`/`run`
  VE HER Nox PROGRAMI HÂLÂ Windows'ta çalışmıyor (runtime portu LL.2-
  LL.7'nin kapsamı, henüz yapılmadı — README'nin "Windows henüz
  desteklenmiyor" notu BU YÜZDEN DEĞİŞTİRİLMEDİ). GERÇEK
  `windows-latest` CI çalıştırmalarıyla 3 gerçek hata bulunup düzeltildi:
  `main.zig`nin argüman ayrıştırması (`iterate()` → `iterateAllocator`,
  macOS/Linux'ta davranış AYNI kaldı), eksik bir `.gitattributes`
  (`core.autocrlf=true` VARSAYILANI `.nox`/`.zig` dosyalarını checkout'ta
  SESSİZCE CRLF'ye çeviriyordu, lexer `\r`yi TANIMADIĞINDAN `core.nox`
  DAHİL her dosya patlıyordu — `* text=auto eol=lf` eklendi), VE CI'nin
  KENDİ PowerShell duman testindeki bir kaçış-dizisi belirsizliği.
  **Bilinçli AÇIK bırakıldı:** lexer'ın KENDİSİNİN `\r\n`ye tolerans
  göstermesi (gerçek Windows kullanıcılarının KENDİ editörleriyle
  yazdığı dosyalar İçin) — bu, checkout-seviyesi düzeltmenin ÇÖZMEDİĞİ,
  ayrı bir takip sorusu. **Ayrıca, Windows'la İLGİSİZ, ÖNCEDEN VAR OLAN
  bir Linux CI regresyonu keşfedildi** (iki ayrı çalıştırmada BİREBİR
  aynı hatayla doğrulandı): bu Zig 0.16.0 derlemesinde `std.c.fstat`
  Linux'ta `void` olarak tanımlı, `runtime/stdlib_shims/fs.zig`nin
  (Faz III.3) kullanımı `noxrt.o`nun Linux'ta (x86-64 VE aarch64) HİÇ
  derlenememesine yol açıyor — kullanıcıya raporlanıp ayrı bir takip
  adımında DÜZELTİLDİ.
- **Linux CI regresyonu düzeltmesi: `fs.zig`ye `fstatCompat`** (bkz.
  nox-teknik-spesifikasyon.md §3.71). İLK deneme `std.c.fstatat`e
  geçmekti, AMA GERÇEK CI'de bu DA `.linux => {}` çıktı (`fstat` İLE
  AYNI "boş" desen) — canlı bir CI çalıştırmasıyla yakalandı. Kalıcı
  düzeltme: `std.c.statx` (switch'e HİÇ girmeyen, KOŞULSUZ bir extern
  bildirimi, bu YÜZDEN GERÇEK bir glibc sembolüne HER ZAMAN bağlı).
  YENİ `fstatCompat`, Linux'ta `statx(fd, "", AT.EMPTY_PATH,
  {SIZE,MTIME}, &buf)` çağırıp platform-nötr bir `FileInfo`ye çevirir;
  diğer platformlarda `std.c.fstat`i (zaten ÇALIŞTIĞINDAN) dokunulmadan
  çağırıp AYNI `FileInfo`ye çevirir. Yerel olarak (macOS, etkilenmeyen
  dal) Debug/ReleaseSafe/ReleaseFast'te doğrulandı; Linux'taki GERÇEK
  doğrulama iki CI denemesinde yapıldı.
- **İki pre-existing Linux test hatası daha düzeltildi** (`fstatCompat`
  sonrası GERÇEK CI'de ortaya çıktı, Windows/`fstatCompat`la İLGİSİZ):
  `path.zig`nin Faz III.4 testi VE `path_new_operations` golden testi,
  `canonicalize("/tmp/../tmp")`nin macOS'a ÖZGÜ `/tmp → /private/tmp`
  sembolik-link çözümünü SABİT beklenti sayıyordu — Linux'ta `/tmp`
  sembolik link OLMADIĞINDAN başarısız oluyordu. Birim testi platform-
  koşullu beklenen değere geçirildi (sembolik-link kanıtı KORUNDU);
  golden test HİÇBİR platformda sembolik link olmayan `/usr/../usr`ya
  geçirildi.
- **`compiler/lexer/lexer.zig` artık `\r\n` (Windows) satır sonlarına
  tolerans gösteriyor** (bkz. nox-teknik-spesifikasyon.md §3.71 —
  LL.1'in "bilinçli açık bırakılan" takip sorusunun kapatılması).
  `.gitattributes` düzeltmesi yalnızca BU REPO'nun checkout'unu
  kapsıyordu — gerçek bir Windows kullanıcısının KENDİ editörüyle
  yazdığı `.nox` dosyası HÂLÂ `UnexpectedCharacter`a çarpardı, çünkü
  lexer HİÇBİR `\r` işleme İÇERMİYORDU. Üç noktada düzeltildi: boş-satır
  tespiti, ana döngüde `\r`nin (tek başına ya da `\n`den önce) sessizce
  atlanması, ters-eğik-çizgi satır-devamının `\r\n` varyantı. 3 yeni
  birim testi (if/indent, yorum/boş-satır, satır-devamı — üçü de AÇIKÇA
  `\r\n` baytlı) + kasıtlı boz→kırmızı ritüeliyle doğrulandı.
- **Faz LL.2/LL.3 — `io_reactor.zig`nin Windows backend'i + Windows x64
  fiber assembly'si (BİRLİKTE yapıldı)** (bkz. nox-teknik-spesifikasyon.md
  §3.71). Zig'in test toplama modeli io_reactor.zig'i test ederken
  fiber.zig'i (dolayısıyla `nox_swap_context` linkini) TRANSİTİF olarak
  çektiğinden ikisi AYRI doğrulanamıyordu — TEK pasoda yazılıp TEK CI
  turunda doğrulandı. **Bilinçli tasarım kararı:** plan "IOCP backend'i"
  diyordu, ama IOCP tamamlama-tabanlıdır, kqueue/epoll'un (ve `io.zig`nin)
  VARSAYDIĞI hazır-olma-bildirimi modeliyle YAPISAL olarak uyuşmaz —
  bunun yerine `WSAPoll` kullanıldı (aynı hazır-olma sözleşmesi, `http_
  server.zig`/`http_client.zig`nin OVERLAPPED işlemlere yeniden yazılması
  gerekmedi). `WindowsReactor`, kqueue/epoll'un aksine bir interest listesi
  tutmayan `WSAPoll`ın gerektirdiği şekilde bekleyen `WaitCtx`leri kendisi
  bir listede tutar, her `poll()`da taze bir `WSAPOLLFD` dizisi kurup en
  yakın zaman aşımını (yeni `WaitCtx.deadline_ms`, `QueryPerformanceCounter`
  tabanlı) hesaplar. `WSAStartup`/`WSAPoll`/`QueryPerformanceCounter`
  elle (`extern "ws2_32"`/`"kernel32"`) bildirildi — Zig'in bu sürümünün
  ws2_32 bağlaması bunları içermiyor. Fiber assembly'si Win64'ün SysV'den
  farklı callee-saved GPR kümesini VE (SysV'nin aksine) callee-saved
  XMM6-15'i (160 bayt) `swap_x86_64.S`ye `#if defined(_WIN32)` ile eklenen
  ayrı bir dalda kaydediyor; `fiber.zig`nin `createWithStack`ı Windows
  için 232 baytlık sahte ilk çerçeveyi elle yazan ayrı bir dal kazandı.
  Doğrulama için `fiber_test`/`scheduler_test`/`channel_test`/`io_test`
  (runtime/stdlib_shims'e hiç bağımlı olmayan mevcut standalone hedefler)
  yeni bir `zig build async-rt-test` adımında toplanıp `windows-frontend`
  CI işine eklendi — `noxrt`in tamamının Windows'a taşınmasını beklemeden
  yalnızca fiber/reaktör katmanını doğrular. Test yardımcıları da
  platform-nötr hale getirildi (Windows'ta `socketpair(AF_UNIX,...)` yok
  — UDP-loopback çift + `send`/`recv`/`closesocket`). Yerel olarak
  (macOS, etkilenmeyen dal) Debug/ReleaseSafe/ReleaseFast'te doğrulandı.
  **GERÇEK Windows CI'de İLK denemede 2 hata bulundu:** sahte çerçeve
  boyutu (232→240 bayt — SysV dalının KENDİSİ de 8 bayt fazla ayırıyor,
  `ret` sonrası hizalamanın 8-mod-16 olması için; 232 kullanınca fiber/
  scheduler/channel testleri segfault veriyordu) ve `io.zig`nin (LL.5'in
  kapsamındaki soket katmanını egzersiz eden, ayrı) kendi testinin
  atlanmamış olması. İKİNCİ CI çalıştırmasında tamamen yeşil.
- **Faz LL.4 — `stdlib_shims`nin POSIX çağrılarının Windows karşılıklarına
  portu** (bkz. nox-teknik-spesifikasyon.md §3.71). `dict.zig`/`crypto.
  zig`nin `arc4random_buf`ı (Windows'ta void) `RtlGenRandom`e
  (`SystemFunction036`) geçirildi; `os.zig`nin `setenv`i `_putenv_s`e.
  **En büyük parça `fs.zig`:** bu Zig sürümünde `std.c.O`/`Stat` İKİSİ DE
  Windows'ta `void`, `readdir` DE `.windows => {}` — dosya G/Ç'si TAMAMEN
  AYRI, ham Win32/MinGW-CRT ilkelleriyle (`_open`/`_read`/`_write`/
  `_close` + `_O_BINARY`, `_filelengthi64`, `_get_osfhandle`+
  `GetFileTime`, `FindFirstFileA`/`FindNextFileA`/`FindClose`,
  `GetFileAttributesA`) yeniden yazıldı. `access`/`rename`/`unlink`/
  `mkdir`/`rmdir`/`getcwd`/`realpath`/`clock_gettime`/`timespec` İSE
  (Zig'in KENDİ switch'lerinde GERÇEK windows-case'leri/koşulsuz
  externleri OLDUĞU doğrulandığından) DOKUNULMADAN bırakıldı. Testlerin
  sabit `/tmp` varsayımı `%TEMP%` okuyan bir yardımcıya geçirildi. Yerel
  olarak (macOS) doğrulandı; Windows'un kendisi gerçek CI'de doğrulanacak.
- **Faz LL.4 SONRASI keşif + LL.5 (devam ediyor) — Winsock katmanı**
  (bkz. nox-teknik-spesifikasyon.md §3.71). Tam bir `zig build`in (LL.4'ü
  LL.5'ten izole edemediği İçin eklenen keşif adımı) ortaya çıkardığı 15
  hatadan 3 dosyası çözüldü: `time.zig` (`clockid_t`nin void olması
  yüzünden `GetSystemTimePreciseAsFileTime`/`QueryPerformanceCounter`/
  `Sleep`e geçirildi), `io.zig` (paylaşılan `pub const WinSock` — `fcntl`
  yerine `ioctlsocket`, `errno` yerine `WSAGetLastError`), `http_server.
  zig` (`fdToI64`/`i64ToFd` köprüsüyle `posix.fd_t`(HANDLE)↔SOCKET
  tutarsızlığı çözüldü) ve `http_client.zig` (`std.c.pipe`nin Windows'ta
  KARŞILIĞI OLMADIĞINDAN self-pipe'ı bağlanmış bir UDP-loopback çiftine
  çevrildi). `std.DynLib`/`std.c.dlopen`in Windows desteksizliği
  çözüldü: `hpy_bridge/loader.zig`ye `LoadLibraryA`/`GetProcAddress`/
  `FreeLibrary` tabanlı bir `NoxDynLib` sarmalayıcısı, `json.zig`/
  `cycle_detector.zig`nin `dlopen(null, ...)` self-lookup desenine
  `GetModuleHandleA`+`GetProcAddress`. `random.zig`nin PRNG tohumlaması
  da (AYNI `clockid_t`-void sorunu, keşifte gözden kaçmıştı)
  `QueryPerformanceCounter`e geçirildi. **Tam `zig build`in Windows
  keşif adımı GERÇEK CI'de SIFIR hatayla doğrulandı.**
- **Faz LL.5 tamamlandı — `nox.thread`/`ThreadChannel`nin self-pipe
  portu.** `thread_bridge.zig`/`thread_channel.zig` de (CI'nin henüz
  ulaşamadığı, proaktif taramayla bulunan) AYNI `std.c.pipe` desenini
  kullanıyordu — `http_client.zig`nin `makeSelfPipe`/`closeFd`/
  `signalSelfPipe`/`readSelfPipe`ı `pub` yapılıp yeniden kullanıldı
  (kopya YOK). Bununla runtime'ın TAMAMI (HPy köprüsü + tüm
  `stdlib_shims`) GERÇEK Windows CI'de sıfır hatayla derleniyor —
  Faz LL'nin en büyük riski aşıldı. Kalan: gerçek bağlama/çalıştırma
  (LL.6), release/install betiği (LL.7), dokümantasyon (LL.8).
- **Faz LL.6 tamamlandı — GERÇEK Windows CI'de doğrulandı: `noxc.exe
  run` bir Nox programını uçtan uca (lex→parse→check→codegen→qbe→cc→
  bağlama→ÇALIŞTIRMA) derleyip çalıştırdı, exit code 0, doğru çıktı.**
  `compiler/
  main.zig`de bulunan iki potansiyel Windows engeli düzeltildi:
  MinGW'in `cc`sinin çıktı dosyasına her zaman `.exe` eklemesi (`noxc
  run`ın çalıştırmaya çalıştığı yolla diskteki gerçek dosya arasında
  uyuşmazlık yaratıyordu — `buildOne` artık ayrı bir `.exe`'li
  `bin_path` hesaplıyor). `ci.yml`ye `qbe`yi kaynaktan (doğrudan `cc
  *.c` ile, Makefile/`sh` PowerShell'de güvenilir değil) derleyip
  gerçek bir `noxc run` duman testi (`print(21+21)`) eklendi. Sonraki
  3 CI turunda sırayla bulunup düzeltilen hatalar: `qbe`nin config.h/
  alt-dizin derleme sorunları, MinGW'in `-rdynamic`yi tanımaması
  (`-Wl,--export-all-symbols`a geçirildi) ve **QBE 1.3'ün KENDİSİNDE
  gerçek bir upstream hatası** (`amd64/winabi.c`nin `amd64_win`
  backend'i, yığından geçirilen bir `f64` parametreyi yanlışlıkla
  tamsayı sınıfıyla yüklüyordu — `JsonValue.__init__`in `n` alanı
  yüzünden HER Nox programında tetikleniyordu; `ci.yml`nin `qbe kur`
  adımına tek satırlık bir metin-yaması eklendi, upstream değişirse
  adım sessizce atlamak yerine açıkça hata verir). Son olarak
  **`zig build-obj`nin KENDİSİNDE gerçek bir Zig derleyici hatası**
  bulundu: COFF (Windows) hedefinde, `addObjectFile` ile eklenen ham
  bir nesne dosyası (fiber bağlam değişimi assembly'si) varken Zig
  kendi derlediği tüm modül içeriğini sessizce atıp yalnızca o ham
  dosyayı çıktı olarak veriyordu (`noxrt.o` bu yüzden 515 bayta —
  runtime'ın TAMAMI kayıp — düşüyordu; `use_llvm`/`link_gc_sections`
  denemeleri BU YÜZDEN etkisizdi, gerçek neden ne backend ne de
  gc-sections'dı). macOS'ta `zig build-obj -target x86_64-windows-gnu`
  doğrudan çağrılıp yalıtılarak doğrulandı. Çözüm: `build.zig` artık
  Windows'ta fiber assembly'sini `noxrt.o`nun içine gömmek yerine ayrı
  kurup (`swap_asm.o`), `compiler/main.zig`nin nihai `cc` bağlamasına
  ayrı bir girdi olarak ekliyor — macOS/Linux'un mevcut, doğrulanmış
  davranışı değişmedi. Son iki düzeltme: eksik sistem kütüphaneleri
  (`-lntdll -lws2_32 -lcrypt32` — Zig'in KENDİ std'sinin Windows
  ilkelleri + `std.http.Client`in TLS sertifika mağazası erişimi İçin)
  ve `std.c.realpath`in MinGW'de HİÇ MEVCUT OLMAMASI (`path.zig`nin
  `nox_path_canonicalize_raw`ı Windows'ta `GetFullPathNameA`ya
  geçirildi — sembolik linkleri ÇÖZMEZ, yalnızca normalize eder).
  Toplamda 7 gerçek hata sırayla bulunup düzeltildi (2'si bu projenin
  kendi kodunda, 1'i upstream QBE'de, 4'ü Zig/MinGW'in kendisinde).
- **Faz LL.7 — `release.yml`ye `windows-x64` hedefi + `install.ps1`.**
  `release.yml`ye Faz LL.1-LL.6'da doğrulanan aynı adımları
  (`-Doptimize=ReleaseFast` ile) tekrarlayan, `.zip` paketleyen ayrı bir
  Windows işi eklendi (`lib/swap_asm.o` dahil — bkz. LL.6). `install.ps1`
  (repo kökü), `install.sh`nin birebir PowerShell karşılığı: aynı
  `NOX_INSTALL_DIR`/`NOX_VERSION` ortam değişkenleri, GitHub Releases
  API'sinden sürüm çözümü, `cc`/`gcc` (MinGW-w64) eksikse uyarı, PATH'e
  kalıcı ekleme. Gerçek bir Windows makinesinde uçtan uca (yalnızca elle
  gözden geçirilip YAML/PowerShell sözdizimi doğrulandı) henüz
  çalıştırılmadı — kullanıcı hazır olduğunda `workflow_dispatch` ile
  (bir git tag'i gerektirmeden) test edilebilir.
- **Faz LL.8 — README/README.en'in Windows bölümleri güncellendi.**
  "Windows henüz desteklenmiyor, WSL kullanın" notu, mevcut gerçek
  desteği (fiber/WSAPoll/Winsock/`nox.http` dahil tüm çalışma zamanı
  çalışıyor) ve tek bilinen sınırlamayı (`nox.path.canonicalize`
  Windows'ta sembolik link çözmüyor) yansıtacak şekilde yeniden yazıldı.
- **Faz MM — HPy köprüsü: çağrılabilir nesne protokolü** (`ctx_Callable_
  Check`/`ctx_Call`/`ctx_CallTupleDict`/`ctx_SetCallFunction`/`ctx_Call
  RealFunctionFromTrampoline`). En önemli katkı: `HPyType_FromSpec` ile
  oluşturulan bir tipin `SomeType(args)` şeklinde GERÇEKTEN inşa
  edilebilmesi — CPython'ın `type.__call__`ının (`tp_new`+`tp_init`,
  sırasıyla) birebir karşılığı; `ctx_New` (Faz 19) bunu yapmıyordu.
  `tests/compat/hpy_ext/noxtest.c`ye yeni bir `Widget` tipi (tp_new/
  tp_init/tp_call slotlarıyla) + `hpy_tier0_test.zig`ye 4 yeni uçtan uca
  test eklendi. Bilinçli v1 sınırlamaları: anahtar kelime argümanları
  reddedilir (TypeError), `ctx_CallMethod` ertelendi (henüz olmayan
  `ctx_GetAttr` ailesine bağımlı). Kapsam: 180 `ctx_*` fonksiyonundan
  50→**55**'i implemente.
- **Faz NN — HPy köprüsü: attribute erişimi** (`ctx_GetAttr`/`ctx_GetAttr_
  s`/`ctx_HasAttr`/`ctx_HasAttr_s`/`ctx_SetAttr`/`ctx_SetAttr_s`). Her
  `.instance_`e Nox'un EKLEDİĞİ attribute'ları tutan bir `instance_dict`
  yedek deposu (Python'ın per-instance `__dict__`ine karşılık) + YENİ
  `ObjTag.bound_method_` (`type_methods`teki bir örnek metodunu bir
  örnek üzerinden erişildiğinde `self`i BAĞLI tutan gerçek bir "bağlı
  metod" nesnesine saran mekanizma — Faz MM'nin `callDispatch`/`ctx_
  Callable_Check`i bunu ÇAĞIRABİLECEK/tanıyabilecek şekilde genişletildi).
  `tests/compat/hpy_ext/noxtest.c`ye `get_attr_via_c` modül metodu +
  `Widget`in KENDİ `_defines[]`ine gerçek bir `add_value` örnek metodu
  eklendi; `hpy_tier0_test.zig`ye 4 yeni uçtan uca test (round-trip,
  eklenti-tarafı görünürlük, bağlı-metod çağrısı, var olmayan attribute
  negatif testleri). Bilinçli v1 sınırlaması: `.type_` üzerinden sınıf-
  seviyesi/unbound attribute erişimi yok; `ctx_CallMethod` hâlâ ayrı bir
  sonraki dilim (ön koşulu artık hazır). Kapsam: 180 `ctx_*`
  fonksiyonundan 55→**61**'i implemente.
- **Faz OO — HPy köprüsü: ctx_CallMethod.** Gerçek HPy sözleşmesiyle
  (`args[0]` = alıcı/self, `args[1..nargs)` = gerçek çağrı argümanları,
  `nargs` alıcıyı da sayar) birebir uyumlu: `name`, Faz NN'nin
  `ctxGetAttr`i ile alıcı üzerinde aranır, bulunan (tipik olarak
  `.bound_method_`) Faz MM'nin `callDispatch`ine delege edilir.
  `noxtest.c`ye eklentinin kendi C kodunun gerçek `HPy_CallMethod`
  makrosunu çağırdığı `call_add_value_via_c` eklendi; `hpy_tier0_test.
  zig`ye 4 yeni uçtan uca test (doğrudan çağrı, eklenti-tarafı
  trampoline, kwargs reddi, var olmayan metod → AttributeError). Kapsam:
  180 `ctx_*` fonksiyonundan 61→**62**'si implemente.
- **Faz PP — HPy köprüsü: Long sayısal dönüşüm ailesi** (`ctx_Long_
  FromInt32_t`/`FromUInt32_t`/`FromUInt64_t`/`FromSize_t`/`FromSsize_t`/
  `AsInt32_t`/`AsUInt32_t`/`AsUInt32_tMask`/`AsUInt64_t`/`AsUInt64_tMask`/
  `AsSize_t`/`AsSsize_t`/`AsVoidPtr`/`AsDouble`, 14 fonksiyon) — mevcut
  `.long` (`i64`) etiketinin mekanik uzantıları; dar tipler İçin gerçek
  `OverflowError` davranışı, "Mask" varyantları hatasız bit-düzeni
  korur. `noxtest.c`ye zincirleme dönüşüm + `AsDouble`/`AsVoidPtr`
  çağıran 3 yeni metod, `hpy_tier0_test.zig`ye 4 yeni test. Kapsam: 180
  `ctx_*` fonksiyonundan 62→**76**'sı implemente.
- **Faz QQ — HPy köprüsü: sayı protokolünün geri kalanı** (`ctx_Number_
  Check`/`ctx_MatrixMultiply`/`ctx_Divmod`/`ctx_Power`/`ctx_Positive`/
  `ctx_Invert`/`ctx_Lshift`/`ctx_Rshift`/`ctx_And`/`ctx_Xor`/`ctx_Or`/
  `ctx_Index`/`ctx_Long`/`ctx_Float` + 13 `InPlace*` varyantı, 28
  fonksiyon). Tüm `InPlace*` varyantları normal karşılıklarına delege
  eder (Nox'ta kullanıcı-tanımlı `__iadd__` yok — CPython'ın değişmez
  int/float için yaptığıyla aynı); `MatrixMultiply` her zaman
  `TypeError` (Nox'ta `__matmul__` yok). `noxtest.c`ye 4 yeni modül
  metodu, `hpy_tier0_test.zig`ye 4 yeni test — 26/26 yeşil. Kapsam: 180
  `ctx_*` fonksiyonundan implemente edilen sayı **101**'e çıktı (bundan
  SONRAKİ sayılar `context.zig`nin doğrulama komutuyla teyit edilmiştir).
- **Faz RR — HPy köprüsü: hata yönetiminin geri kalanı** (`ctx_FatalError`/
  `ctx_Err_SetObject`/`ctx_Err_SetFromErrnoWithFilename`/`ctx_Err_
  SetFromErrnoWithFilenameObjects`/`ctx_Err_NewException`/`ctx_Err_
  NewExceptionWithDoc`/`ctx_Err_WarnEx`/`ctx_Err_WriteUnraisable`, 8
  fonksiyon). `PendingError`e bir `value: HPy` alanı eklendi (`Err_
  SetObject` için); `Err_NewException` yeni, pin'siz bir `.exc_type`
  kimliği üretir; `Err_SetFromErrnoWithFilename(Objects)` gerçek `errno`yu
  `strerror`e çevirir; `Err_WarnEx`/`WriteUnraisable` stderr'e yazar.
  `FatalError` gerçek `Py_FatalError` gibi süreci sonlandırır — bu yüzden
  otomatik testten çağrılamaz, yalnızca wiring doğrulanır. `noxtest.c`ye
  6 yeni modül metodu, `hpy_tier0_test.zig`ye 7 yeni test — 33/33 yeşil.
  Kapsam: 180 `ctx_*` fonksiyonundan 101→**109**'u implemente.
- **Faz SS/TT — HPy köprüsü: temel nesne protokolünün geri kalanı +
  Bytes tipi** (16 fonksiyon: `Repr`/`Str`/`ASCII`/`Bytes`(çevirme)/
  `RichCompare`/`RichCompareBool`/`Hash`/`Type_GenericNew`/`AsStruct_
  Legacy` + YENİ `ObjTag.bytes_` ile `Bytes_Check`/`Size`/`GET_SIZE`/
  `AsString`/`AS_STRING`/`FromString`/`FromStringAndSize`). `.instance_`
  nesneleri kayıtlı `tp_repr`/`tp_str`/`tp_hash`/`tp_richcompare`
  slotlarını (varsa) kullanır, yoksa jenerik Python-benzeri biçimlendirme
  (None/True/False/int/float `3.0`/str repr+str/list/tuple/dict/type/
  instance). `Hash`, süreç başına rastgele tohumlu `Wyhash` kullanır
  (hash-flooding DoS'a karşı, M-3'ün aynı ilkesi). `Widget`e test amaçlı
  özel `tp_repr`/`tp_hash` slotları eklendi; `noxtest.c`ye 9 yeni modül
  metodu, `hpy_tier0_test.zig`ye 8 yeni test — 41/41 yeşil. Kapsam: 180
  `ctx_*` fonksiyonundan 109→**124**'ü implemente.
- **Faz UU — HPy köprüsü: Unicode ailesinin geri kalanı** (12 fonksiyon:
  `AsASCIIString`/`AsLatin1String`/`AsUTF8String`/`FromWideChar`/`Decode
  FSDefault(AndSize)`/`EncodeFSDefault`/`ReadChar`/`DecodeASCII`/`Decode
  Latin1`/`FromEncodedObject`/`Substring`). `FromWideChar`, `wchar_t`nin
  platforma göre değişen genişliğini (Windows UTF-16/macOS-Linux UTF-32)
  koşullu bir tip takma adıyla ele alır; `ReadChar`/`Substring` kod
  noktası (bayt değil) indeksleriyle çalışır. `errors` parametresi yok
  sayılır (her zaman "strict"). `noxtest.c`ye 9 yeni modül metodu,
  `hpy_tier0_test.zig`ye 7 yeni test — 48/48 yeşil. Kapsam: 180 `ctx_*`
  fonksiyonundan 124→**136**'sı implemente.
- **Faz VV — HPy köprüsü: List/Tuple Builder'ları** (8 fonksiyon:
  `ListBuilder_New/Set/Build/Cancel` + `TupleBuilder_New/Set/Build/
  Cancel`). `HPyListBuilder`/`HPyTupleBuilder` (`HPy`nin kendisiyle aynı
  biçimde tek bir `isize` taşıyan opak tutamaçlar) `.list_`in zaten
  dinamik büyüyebilen yapısını doğrudan kullanır; `TupleBuilder` aynı
  mekanizmayı geçici bir sahneleme listesi olarak kullanıp `Build`ta
  gerçek (değişmez) bir `.tuple_`ye dönüştürür. `noxtest.c`ye 4 yeni
  modül metodu, `hpy_tier0_test.zig`ye 2 yeni test — 50/50 yeşil.
  Kapsam: 180 `ctx_*` fonksiyonundan 136→**144**'ü implemente.
- **Faz WW — HPy köprüsü: Tracker + Field/Global saklama-yükleme**
  (8 fonksiyon: `Tracker_New/Add/ForgetAll/Close` + `Field_Store/Load` +
  `Global_Store/Load`). `HPyTracker`/`HPyField`/`HPyGlobal` (`HPy`nin
  kendisiyle aynı biçimde tek bir `isize` taşıyan opak tutamaçlar).
  `Tracker`, `.list_`in deposunu `ctxDup` çağırmadan yeniden kullanır
  (gerçek "Add yeni referans oluşturmaz" sözleşmesini korumak için);
  `Field`/`Global`, Nox'un basit refcounting'inde "eski değeri kapat,
  yeniyi dup'la, sakla" desenine indirgenir (GC write-barrier/alt-
  yorumlayıcı ayrımı Nox'ta geçerli değil). `noxtest.c`ye 6 yeni modül
  metodu, `hpy_tier0_test.zig`ye 3 yeni test — 53/53 yeşil. Kapsam: 180
  `ctx_*` fonksiyonundan 144→**152**'si implemente (DÜZELTME: doğrulama
  komutundaki gevşek `grep` deseni bazı zaten-implemente fonksiyonları
  yanlışlıkla sayıyordu — gerçek sayı **155**'ti; bkz. Faz XX).
- **Faz XX — HPy köprüsü: tip içgözlemi + çeşitli** (11 fonksiyon:
  `Type_GetName/IsSubtype/GetBuiltinShape` + `AsStruct_Type/Long/Float/
  Unicode/Tuple/List` + `Dump` + `Slice_Unpack`). `Obj`e `type_name`/
  `type_builtin_shape` alanları eklendi. `Type_IsSubtype` yalnızca kimlik
  döner (Nox'ta kalıtım yok); `AsStruct_*` yalnızca doğrudan o etiketli
  nesneler için çalışır (builtin-shape türetmesi desteklenmiyor);
  `Slice_Unpack`, Nox'ta henüz olmayan bir `slice` tipi yerine 3 elemanlı
  bir `(start, stop, step)` tuple kabul eder, CPython'ın aynı varsayılan
  kurallarıyla. `noxtest.c`ye 6 yeni modül metodu, `hpy_tier0_test.zig`ye
  4 yeni test — 57/57 yeşil. Kapsam: 180 `ctx_*` fonksiyonundan
  155→**166**'sı implemente (düzeltilmiş, kesin sayım yöntemiyle).
- **Faz YY — HPy köprüsü: Capsule + ContextVar** (7 fonksiyon:
  `Capsule_New/Get/IsValid/Set` + `ContextVar_New/Get/Set`). `Capsule`
  (YENİ `ObjTag.capsule_`), gerçek `PyCapsule`in CPython'a bağımlı
  OLMAYAN bir kavram olması sayesinde tam sadakatle implemente edildi —
  yıkıcı, `Obj` yok edilirken gerçek `PyCapsule_Destructor` zamanlamasıyla
  çağrılır. `ContextVar` (YENİ `ObjTag.contextvar_`), Nox'ta gerçek
  bağlam yayılımı olmadığından tek bir global yuva olarak implemente
  edildi; bu ABI diliminde `Reset`/token fonksiyonu olmadığından `Set`
  dürüstçe önceki değeri döner.
  **Yan-etki düzeltmesi:** `h_LookupError`/`h_UnicodeEncodeError`/
  `h_UnicodeDecodeError` (Faz UU/SS'ten beri kullanılan) şimdiye kadar
  gerçek bir pinned tekile bağlanmamıştı (`HPy_NULL`'da kalmışlardı) —
  bu, ilgili `ctx_Err_ExceptionMatches` testlerinin her iki taraf da
  `._i == 0` olduğundan yanlışlıkla "eşleşiyor" görünmesine yol açıyordu.
  Üçü de artık diğer 15 yerleşik istisna gibi doğru bağlandı.
  `noxtest.c`ye 7 yeni modül metodu, `hpy_tier0_test.zig`ye 3 yeni test
  — 60/60 yeşil. Kapsam: 180 `ctx_*` fonksiyonundan 166→**173**'ü
  implemente.
- **Faz ZZ — HPy köprüsü: kapanış, 180/180'e tamamlayan dilim** (7
  fonksiyon: `ReenterPythonExecution/LeavePythonExecution` + `Compile_s/
  EvalCode/Import_ImportModule` + `FromPyObject/AsPyObject`). Üç
  dürüstlük kategorisi: (1) `ReenterPythonExecution`/`LeavePython
  Execution` — gerçek no-op'lar (Nox'ta GIL yok, bırakılacak kilit yok);
  (2) `Compile_s`/`EvalCode`/`Import_ImportModule` — ulaşılabilir ama
  kapsam dışı, gerçek bir Python-tarzı istisnayla (`NotImplementedError`/
  `ImportError`) reddedilir (Nox ayrı bir dildir, gömülü Python
  derleyicisi/VM/import sistemi yok — bir uzantının bunları çağırması
  tüm uygulamayı çökertmemeli); (3) `FromPyObject`/`AsPyObject` — gerçek
  bir `cpy_PyObject*`in Nox'un yalnızca desteklediği `HPY_ABI_UNIVERSAL`
  modunda hiçbir zaman var olamayacağından (`FORBIDDEN_cpy_PyObject`),
  `ctx_CallRealFunctionFromTrampoline` (Faz MM) ile aynı gerekçeyle
  dokümante edilmiş bir `@panic` ile bırakıldı. `noxtest.c`ye 4 yeni
  modül metodu, `hpy_tier0_test.zig`ye 2 yeni test — 62/62 yeşil.
  **Kapsam: 180 `ctx_*` fonksiyonunun TAMAMI (180/180) artık gerçek,
  tipli fonksiyon işaretçileriyle bağlı** — kullanıcının "gerçekten
  180/180 ctx_*" hedefi karşılandı (üçü yapısal olarak imkansız oldukları
  için dokümante `@panic` ile — sahte implemente edilmedi). Faz MM'den
  (50/180) Faz ZZ'ye (180/180) kadar tek bir oturumda (2026-07-22) 130
  fonksiyon eklendi, her biri gerçek bir HPy 0.9.0 C uzantısıyla uçtan
  uca doğrulandı.
- **Python builtin genişletmesi: `input`/`abs`/`min`/`max`/`round`/`sum`.**
  `input()` YENİ `runtime/stdlib_shims/io.zig` ile stdin'den satır okur
  (v1: argümansız, gerçek EOF'ta `EOFError` fırlatmaz). `abs`/`min`/`max`/
  `round`/`sum`/`sum_float` `stdlib/nox/core.nox`e saf Nox generic
  fonksiyonları olarak eklendi — hiçbir checker.zig/codegen.zig
  değişikliği gerekmedi. Yan-keşif: `round()`nin `int(x + 0.5)` ihtiyacı,
  `int()` builtin'inin önceden yalnızca `str` kabul ettiğini ortaya
  çıkardı — `float` argümanı da (QBE'nin `dtosi`si üzerinden, Python'ın
  `int(3.9) == 3`iyle aynı sıfıra-doğru kırpma) kabul edecek şekilde
  genişletildi. `nox-teknik-spesifikasyon.md` §3.72.
- **Go-tarzı `defer` anahtar kelimesi — tam Go semantiği (bir döngü
  içindeki `defer` dahil).** `defer CALL`, `CALL`i fonksiyonun dönüş
  anında (normal düşme/`return`/yakalanmamış bir istisna dahil) LIFO
  sırasıyla çalıştırır. YENİ `runtime/alloc/defer_stack.zig`: bekleyen
  çağrı sayısı çalışma zamanında değişebildiğinden (bir döngü içindeki
  `defer`), derleyicinin kendi statik `finally_stack`i yerine gerçekten
  çalışma zamanında büyüyen bir yığın kullanır. Checker, her `defer`i
  sentetik bir iç içe `def` gibi ele alıp mevcut closure yakalama-analizini
  aynen yeniden kullanır — yeni bir capture mekanizması yazılmadı.
  `nox-teknik-spesifikasyon.md` §3.72.
  **Yan-bulgu: bağımsız bir bellek-sızıntısı hatası bulundu ve
  düzeltildi.** `defer`i doğrulayan ilk testler, `defer` içermeyen
  (`input()`i iki kez çağıran) bir fonksiyonun bile tutarlı şekilde
  sızdırdığını ortaya çıkardı — kök sebep, fonksiyon-inlining
  optimizasyonunun (Faz GG.2), gövdesi hiç `return` içermeyen (örtük
  `None` dönüşü) inline edilen bir callee'nin kendi heap-yönetimli
  yerellerini hiç serbest bırakmamasıydı. `nox.os.current_dir()` gibi
  mevcut bir zero-arg wrapper'ı iki kez çağırmak da aynı şekilde
  sızıyordu — `defer`e özgü değil, ondan önce fark edilmemiş bir hataydı.
  5 yeni uçtan-uca golden test (tek `defer`, LIFO sıra, bir döngü
  içinde `defer`, `try`/`finally` etkileşimi, istisna yayılımı) +
  1 tip-hatası testi (modül seviyesinde `defer` reddi).
- **Darboğaz analizi (2026-07-22): C'ye karşı en yavaş kalan 5
  benchmark'ın ürettiği makine kodu okunarak 4 codegen bulgusu tespit
  edildi, sırayla düzeltildi** (bkz. `benchmarks/RESULTS.md`, ayrıntılı
  ölçümler için). (1) Bounds-check elision (Faz GG.9), yalnızca `for i
  in range(len(xs))`u tanıyordu — `detectWhileBoundsElideCtx`, elle
  yazılmış `while j < len(xs)`/`while j < SABİT` eşdeğerlerini de
  kapsayacak şekilde genişletildi (`lowlevel_arena`de ~%13.5 iyileşme).
  (2) Sabit liste literallerinin QBE `blit`le toplu kopyalanması
  DENENDİ ama bu ARM64 hedefinde QBE'nin KENDİ `blit` lowering'inin
  kaynak adresini her parça İçin yeniden hesaplaması nedeniyle GERÇEK
  bir regresyon (~%19) olduğu ÖLÇÜLEREK bulundu — GERİ ALINDI, kod
  değiştirilmeden bırakıldı (bulgu `genListLit`de belgeli). (3)
  `i % 3` gibi tekrarlanan saf alt-ifadeler İçin dominance-farkında bir
  CSE önbelleği (`Codegen.mod_cache`) eklendi — `if`/`elif`/`else`
  dallarının her biri anlık-görüntü/geri-yükleme İLE korunur, döngüler
  gövde İçinde yeniden atanan isimleri döngüye GİRERKEN geçersiz kılar,
  satır-içi (inline) çağrı sınırları SLOT-tabanlı anahtarlama VE bir
  "argüman takma adı" mekanizmasıyla GÜVENLE aşılabilir hale getirilir.
  Geliştirme sırasında, `if`/döngü gövdesi bir ismi yeniden ATADIĞINDA
  ÖNCEKİ (bayat) bir önbellek girdisinin YANLIŞLIKLA geri getirildiği
  GERÇEK bir SSA-uygunluk (dominance) hatası BULUNDU ve düzeltildi
  (hedeflenmiş güvenlik testleriyle YAKALANDI — bkz. AGENTS.md İlke #7).
  (4) `genListEq`nin döngü sayacı İçin gereksiz bir `alloc8`+ölü
  `str` yerine QBE'nin KENDİ `phi` talimatı kullanıldı — bu SIRADA
  `genEqCompareOrJump`ye eklenen `success_label` parametresi, GERÇEK
  bir `qbe` derleme hatasıyla ("predecessors not matched in phi")
  KEŞFEDİLEN bir öncül-blok belirsizliğini de düzeltti. 11 yeni golden
  test (davranışsal + IR-metni düzeyinde doğrulama, bkz.
  `tests/golden/codegen_golden_test.zig`).

### Eklendi (harici inceleme P0-P2 düzeltme listesi, 16 madde — TAMAMLANDI)
- **P0.1-P0.5**: paket önbelleği path-traversal düzeltmesi, gerçek span
  sistemi (`compiler/span.zig`), yapılandırılmış parser tanılamaları,
  README HPy durum düzeltmesi, CI'da fuzzing.
- **P1.1**: tek-parça `compiler/codegen_qbe/codegen.zig` (8573 satır) 15
  alt modüle bölündü (`abi`/`layout`/`ownership`/`closures`/`exceptions`/
  `stmt`/`expr`/`optimizations`/`inlining`/`calls`/`async_thread`/
  `http_intrinsics`/`registration`/`types`/`codegen`) — sıfır genel API
  değişikliği, performans regresyonu yok.
- **P1.2**: derleyici/çalışma-zamanı ABI yerleşim sabitleri İçin tek
  gerçek kaynak — YENİ `shared/abi_layout.zig`, üç bağımsız Zig modül
  grafiği (`nox_mod`/`noxc_mod`/`noxrt_mod`) tarafından paylaşılıyor.
- **P1.3**: `noxc-lsp` artık proje/bağımlılık-farkında (`nox.json` +
  `nox.lock` çözümlemesi) ama KASITLI olarak salt-okunur — hiçbir zaman
  ağ çağrısı/`nox.lock` yazımı tetiklemez.
- **P1.4**: `noxc-lsp`ye `textDocument/completion`/`definition`/`hover`
  eklendi — YENİ `compiler/lsp_nav.zig`, yalnızca AYNI dosya İçinde statik
  navigasyon (checker'ın tip-çıkarım motorunu paylaşmaz).
- **P1.6**: 4 neredeyse-yinelenen `isXCallee` yapısal-eşleştirme
  fonksiyonu tek parametrik `matchesNoxAttr` + statik `intrinsic_table`
  kaydına birleştirildi — yeni bir intrinsic eklemek artık tek bir tablo
  satırı.
- **P2.1**: gerçek kullanıcı-tanımlı generic sınıflar (derleme-zamanı
  monomorfizasyon, tip-silme DEĞİL) — `[T](args)` sözdizimi HERHANGİ bir
  isme genelleştirildi. 3 gerçek hata implementasyon sırasında bulundu ve
  düzeltildi (modüller-arası kopyada `type_params` düşmesi, from-imports
  generic sınıf çözümlemesi, `Box[int](9).get()` gibi geçici generic
  construct'ların bellek sızıntısı).
- **P2.2**: boş `[]` liste literalleri artık bağlamdan (var_decl/atama/
  çağrı-argümanı/return) eleman tipini çıkarıyor — önceden yalnızca boş
  liste HATA veriyordu.
- **P2.3**: dokümantasyon netleştirmesi — kimlik ASCII-yalnız, sayı
  literalleri yalnızca 10-tabanlı, string literalleri KAÇIŞSIZ gerçek
  satır sonu içerebiliyor (gerçek, şaşırtıcı, önceden var olan davranış,
  şimdi yazıya döküldü).
- **P2.4**: `nox.lock` SHA-sapma hatası düzeltildi (önbellek silinip
  yukarı akış dalı ilerlediğinde `noxc build`/`fetch` artık kilitli SHA'yı
  kullanıyor, dal referansını DEĞİL); güvensiz taşıma (`http`/`git`)
  artık `NOX_ALLOW_INSECURE_TRANSPORT` olmadan reddediliyor; opsiyonel
  `require_signed_commit` (`git verify-commit` üzerinden).
- **P2.5**: benchmark koşucusu artık yalnızca min değil min/max/ortalama
  gösteriyor + ortam bilgisi (OS/mimari/CPU/çekirdek sayısı/Zig sürümü/
  gerçek `noxc --version`) yazdırıyor.
- P1.5 (modül arayüzü + artımlı derleme) kullanıcı kararıyla ATLANDI —
  Nox'un tek-derleme-birimi tasarımıyla çelişen bir mimari çatallanma.

### Eklendi (nox.http gzip düzeltmesi sonrası dil/stdlib eksik-özellik turu)
- **`f"..."` biçimlendirilmiş dize literalleri.** Lexer bir `f`/`F`
  önekini + brace-derinliği ve iç içe tırnak takibiyle TÜM f-string'i
  tarar (`{{`/`}}` kaçışları, Python-klasik iç içe tırnak kuralı — iç
  string'in tırnağı dış tırnakla AYNIYSA hata). Parser `{expr}`
  segmentlerini yeniden tokenize edip ayrıştırır, `str(expr)` çağrılarıyla
  sarar, tüm segmentleri sol-sağ `+` zinciriyle katlar — YENİ bir AST
  düğümü GEREKMEDİ, saf bir sözdizimsel şeker.
- **7 birleşik atama operatörü**: `+=`/`-=`/`*=`/`/=`/`//=`/`%=`/`**=`,
  yalnızca `.identifier` hedefleri İçin desugar edilir (`x += 1` →
  `x = x + 1`), `.attribute`/`.index` hedefleri reddedilir.
  `str()` builtin'i artık `str`/`bool` argümanlarını da kabul ediyor
  (f-string interpolasyonunun İÇ ÇAĞRISI İçin gerekliydi).
- **UTF-8 karakter-farkındalıklı `len()`/`s[i]`**: önceden ikisi de HAM
  bayt tabanlıydı, çok baytlı karakterleri (`café`, `日本語`) BOZUYORDU.
  YENİ `nox_str_char_count`/yeniden yazılmış `nox_str_char_at`
  (`std.unicode` üzerinden codepoint yürüyüşü). ASCII hızlı-yol
  (`str_ascii_cache` + QBE `jnz`/`phi`) eklendi çünkü naif düzeltme
  ASCII sıralı erişimi O(n²)'ye düşürüyordu (80.4ms → 30sn+) — hızlı
  yolla nihai maliyet yalnızca ~1.65x (132.9ms, gerçek ReleaseFast
  ölçümüyle doğrulandı). Çok-baytlı sıralı erişim BİLİNÇLİ olarak hâlâ
  O(n²) — dokümante edilmiş, ertelenmiş bir sınır.
- **`noxc search` artık uzak bir paket indeksi URL'sinden çekebiliyor**
  (`compiler/pkg/index.zig`nin YENİ `loadIndexFromUrl`) — `https` her
  zaman İZİNLİ, `http` yalnızca `NOX_ALLOW_INSECURE_TRANSPORT=1` İLE;
  gzip/deflate doğru şekilde `readerDecompressing` İLE çözülüyor (nox.http
  düzeltmesiyle AYNI ders).
- **`nox.sqlite` — gerçek bir SQLite sürücüsü.** `libsqlite3`e ASLA
  statik bağlanmaz — YENİ `runtime/stdlib_shims/sqlite.zig`, `std.DynLib`
  İLE İLK KULLANIMDA (dlopen/dlsym) çalışma zamanında yükler, bu YÜZDEN
  sqlite KULLANMAYAN hiçbir Nox programı yeni bir bağımlılık KAZANMAZ.
  `stdlib/nox/sqlite.nox`: `Connection`/`Statement`/`Row`/`SqliteError`
  sınıfları + `open()` — parametreli sorgular, tipli sütun erişimi
  (`get_str`/`get_int`/`get_float`/`is_null`), `last_insert_rowid`/
  `changes`, `SqliteError` İLE hata yönetimi. İlk tasarım `sqlite3_*`
  sembollerini DOĞRUDAN `extern def ... from "sqlite3"` İLE bağlıyordu
  ama bu, `noxrt.o`da (HER Nox programına statik bağlı) çözülmemiş
  sembol bırakıp sqlite KULLANMAYAN programların bağlanmasını
  BOZUYORDU (gerçek regresyon, testte yakalandı) — tamamen `std.DynLib`
  tabanlı tembel yüklemeye geçilerek düzeltildi.

### Düzeltildi (nox.http gzip/deflate ve ilgili küçük hatalar)
- **`nox.http`nin gzip/deflate gövdeleri hiç ÇÖZMEDİĞİ** GERÇEK bir heap
  bozulması hatası bulundu ve düzeltildi — ham gzip baytları (gömülü NUL
  DAHİL) doğrudan NUL-sonlandırılmış bir Nox `str`ine akıyor, sonraki
  `strlen()` tabanlı serbest-bırakma boyutu hesaplamasını bozuyordu.
  `response.reader()` yerine `response.readerDecompressing()` kullanılarak
  düzeltildi; gövdede gömülü NUL bulunursa artık çökme yerine temiz bir
  `HttpError` fırlatılıyor (savunma katmanı).
- Başlıkların ayrıştırılmasından SONRAKİ bir başarısızlık yolunda
  `ctx.response_headers`in SIZDIĞI bulundu — `headers_committed` bayrağı
  + `defer` İLE düzeltildi.
- Boş `{}` dict literali (önceden imkansızdı, boş `[]` liste İLE
  simetrik olarak) parser/checker/codegen'e eklendi.
- `main` isimli bir kullanıcı fonksiyonu, sentezlenen C giriş sembolüyle
  ÇAKIŞIYORDU — artık `registerFunc` bunu AÇIKÇA reddediyor (önceden bu
  hatadan habersizce yararlanan ~10 test fixture'ı `entry` olarak
  yeniden adlandırıldı).
- **`except X as e:` sınıf-adı çözümlemesindeki from-imports hatasının 3
  BAĞIMSIZ örneği** (`checker.zig`nin `checkTry`i, `codegen_qbe/
  exceptions.zig`nin `genTry`i, VE gerçek arızalı nokta olan
  `codegen_qbe/registration.zig`nin `collectLocals`i) — üçü de
  `self.from_imports.get(name)` yedek çözümlemesiyle düzeltildi. Bu,
  "AST alanı bir kez çözülüp yerinde YENİDEN YAZILMIYOR, HER tüketici
  kendi başına çözmeli" kalıbının kod tabanında en az 4. tekrarı.

### Eklendi (gerçek backend/app kütüphaneleri turu — nox.sqlite'tan sonra)
- **Parola hash'leme: `nox.crypto.argon2_hash`/`bcrypt_hash`/`scrypt_hash`
  + karşılık gelen `*_verify`.** Zig'in KENDİ, savaş-test edilmiş
  `std.crypto.pwhash.{argon2,bcrypt,scrypt}`si — sıfırdan bir algoritma
  YAZILMADI, harici bağımlılık EKLENMEDİ. Üçü de OWASP'ın ÖNERDİĞİ tek bir
  maliyet parametresi ön-ayarını kullanır, HİÇBİR tuning seçeneği v1'de
  SUNULMAZ. Dönen dize (`$argon2id$v=19$...`/`$2b$10$...`/`$scrypt$...`)
  tuzu (salt) + tüm parametreleri KENDİ İÇİNDE taşır, doğrudan bir DB
  sütununa yazılabilir. `*_verify`, yanlış parola İLE bozuk/başka-
  algoritmadan bir hash dizesini AYNI şekilde `False` DÖNEREK ayırt
  etmez (yan-kanal/oracle sızıntısını ÖNLEMEK İçin bilinçli bir karar).
  `argon2`/`scrypt`in `strHash`ı bir `std.Io` gerektirdiğinden,
  `http_client.zig`nin TÜM istekler ARASINDA paylaşılan `sharedClientIo`si
  (`pub` yapılarak) burada da yeniden kullanıldı — YENİ bir `std.Io.
  Threaded` örneği süreç-geneli bir sinyal-işleyici çakışması riski
  taşırdı (bkz. o fonksiyonun KENDİ belge notu).

## [1.0.0]

### Eklendi
- İlk git commit'i — proje artık gerçek sürüm kontrolü altında (Faz Q.1).
- `CHANGELOG.md` (bu dosya).
- GitHub Actions CI (Faz Q.2) — her push/PR'da `zig build test` (Debug +
  ReleaseFast).
- Linux epoll I/O reaktör backend'i (Faz R.1) — `runtime/async_rt`in
  async G/Ç'si artık macOS (kqueue) yanında Linux'u (epoll) da destekliyor.
  Gerçek (emülasyonsuz) bir Docker aarch64 Linux konteynerinde doğrulandı.
- x86-64 fiber bağlam değişimi desteği (Faz R.2) — `runtime/async_rt`
  artık aarch64 yanında x86-64'ü (SysV ABI) de destekliyor. Docker'daki bir
  x86-64 Linux konteynerinde (Rosetta ikili çevirisi üzerinden — gerçek
  donanım kadar kesin DEĞİL, dürüstçe belirtilir) doğrulandı.
- CI matrisi genişletildi (Faz R.3): macOS/aarch64 + Linux/x86-64
  (`ubuntu-latest`, R.2'nin x86-64 kodunu GERÇEK donanımda doğrular) +
  Linux/aarch64 (`ubuntu-24.04-arm`) — Linux'ta `qbe` kaynaktan derlenir.
- `build.zig`e Zig araç zinciri sürüm denetimi eklendi (Faz R.4) — çalışan
  derleyici sürümü CI'nin pinlediği sürümden (`0.16.0`) farklıysa net bir
  uyarı basılır (sert bir hata değil — yama sürümleri genelde uyumludur).
- **Katman 3 (döngü çözücü) uygulandı (Faz S.3)** — `runtime/alloc/
  cycle_detector.zig`, Bacon & Rajan'ın senkron trial-deletion algoritmasıyla
  (Nim'in ORC modelinin/CPython'ın döngü GC'sinin akrabası). Bunun İÇİN
  ÖNCE sınıfların KENDİ KENDİSİNE (`self.next = self`) atanabilmesi
  gerekiyordu (`codegen.zig`nin `inferFieldType`i genişletildi) — bu, GERÇEK
  bir A↔B referans döngüsü kurmanın (sonradan `a.next = b; b.next = a;`
  ile) tek bootstrap yoludur (`None`/opsiyonel tip HENÜZ yok). v1 kapsamı
  yalnızca SINIF örnekleri (`list[T]`/`dict[K,V]` elemanları dahil değil).
  Tetikleme: tahsis-baskısı eşiği (varsayılan 700) + program çıkışında son
  bir tarama.
- Tip denetleyici hataları artık kaynak SATIR numarası taşıyor (Faz T.1) —
  `HATA <kod>: satır N: <mesaj>` biçimi. Kapsam bilinçli olarak DEYİM
  (statement) granülerliğinde (ifade/`Expr` düzeyinde değil — bu, `checker.
  zig`/`codegen.zig` genelinde `ast.Expr`i eşleştiren düzinelerce yere HİÇ
  dokunmadan, yalnızca `ast.Stmt`i saran bir `{ kind, line }` yapısıyla
  güvenle uygulanabildi). 22 mevcut typecheck golden testinin `.expected`
  dosyası bu yeni önekle güncellendi.
- Tip denetleyici artık TEK çalıştırmada BİRDEN ÇOK hata raporlayabiliyor
  (Faz T.2) — kurtarma `checkModule`nin üst-düzey (fonksiyon/sınıf/gevşek
  deyim) döngüsünde VE `checkClassBody`nin metod döngüsünde, HER bağımsız
  birimin sınırında yapılır (AYNI birim İÇİNDEKİ İKİNCİ bir hata HÂLÂ
  raporlanmaz — bilinçli bir sınırlama). `CheckOutcome.err`e yeni bir `all:
  []const Diagnostic` alanı eklendi; `main.zig` VE doğrudan `Checker`
  kullanan 5 test dosyası TÜM kurtarılmış tanılamaları kontrol edip
  yazdıracak şekilde güncellendi (aksi halde bir hata sessizce codegen'e
  sızardı).
- `noxc build/run/test`e `-g` bayrağı eklendi (Faz T.3) — QBE IL'in
  belgelenmemiş `dbgfile`/`dbgloc` yönergeleri (assembler'ın `.file`/`.loc`
  sözde-yönergelerine BİREBİR eşlenir) üzerinden GERÇEK DWARF satır tablosu
  üretir. Linux'ta (GERÇEK bir Docker aarch64 konteynerinde `noxc build -g`
  ile uçtan uca doğrulandı) `gdb`de dosya:satır kesme noktaları/adımlama
  TAM ÇALIŞIYOR. Bilinen v1 sınırlamaları (dürüstçe belgelendi, bkz. spec
  §3.17): yalnızca SATIR bilgisi (değişken inceleme YOK — QBE'nin KENDİ
  sınırı), stdlib'e (import edilen modüllere) adım atıldığında dosya
  yanlış atfedilebilir (satır numarası doğru, dosya yanlış), macOS'ta
  BAĞLI (linked) ikili DWARF taşımaz (Apple'ın STABS/debug-map mekanizması
  ayrı bir mühendislik sorunu — ara `.o` GERÇEK DWARF taşır, doğrulandı).
- Lexer'a yorum/boş-satır konumu yakalama eklendi (Faz T.4a) — YENİ, opsiyonel
  `lexer.tokenizeWithTrivia` (mevcut `tokenize` DEĞİŞMEDEN, ~50+ çağrı sitesi
  ETKİLENMEDEN) `Trivia` (yorum METNİ + satır + trailing/standalone bayrağı,
  ya da boş-satır işareti) akışı üretir — GELECEKTEKİ gerçek `noxc fmt`
  formatlayıcısının (T.4b) yorumları SESSİZCE SİLMEDEN yeniden yerleştirebilmesi
  İÇİN ön koşul (kullanıcıyla netleşti: yorum-koruma OLMADAN bir formatlayıcı
  gerçek kullanıcı kodunda veri kaybına yol açardı).
- `noxc fmt` gerçek bir formatlayıcıya kavuştu (Faz T.4b) — YENİ `compiler/
  fmt/formatter.zig`, AST'yi 4-boşluk girinti + precedence-farkındalıklı
  (yalnızca GEREKLİ) parens ile kanonik Nox söz dizimine yeniden yazar,
  T.4a'nın yakaladığı yorumları/boş satırları en yakın deyime göre yeniden
  yerleştirir. Dosyayı YERİNDE (in-place) yeniden yazar, İDEMPOTENTTİR
  (ikinci formatlama dosyayı değiştirmez), tip denetimi ÇALIŞTIRMAZ
  (`gofmt`ın davranışıyla tutarlı — sözdizimsel olarak geçerli ama tipçe
  hatalı kod da formatlanabilir).
- `list[T]`e `.append()` (dinamik büyüme) VE indeksli atama (`xs[i] = v`)
  eklendi (Faz U.1) — kullanıcıyla netleşen karar: GERÇEK paylaşım semantiği
  (kapasite YETERLİYSE `.append()` YERİNDE yazar, TÜM alias'lar GÖRÜR;
  kapasite DOLUNCA YENİ, 2× büyüklükte bir blok ayrılır — Python listeleri
  gibi). Liste başlığı `{len, elemanlar...}`den `{len, cap, elemanlar...}`e
  genişletildi (`nox.json`/`nox.strings.split`in Zig-taraflı el-yapımı liste
  inşası DAHİL, TÜM liste kod yolları güncellendi). Bilinen v1 sınırlamaları:
  büyüme ANINDA var olan bir alias yeni elemanı görmez (TEMİZ bir
  `IndexError`e yol açar, bellek bozulması DEĞİL); alıcı bir parametre
  OLAMAZ; arena listeleri büyütülemez; boş liste literali (`[]`) hâlâ
  desteklenmiyor.
- Proje-içi çoklu-dosya birinci-taraf import desteği eklendi (Faz U.2) —
  `nox.json` içeren bir projede artık `import helpers` (doğrudan) ve
  `import utils.mathy` (iç içe yol, `<proje_kökü>/utils/mathy.nox`e
  çözümlenir) gibi hiçbir `requires[]` kaydı gerektirmeyen proje-yerel
  importlar çalışıyor. Çözümleme önceliği: `nox.*` (stdlib) → `requires[]`
  alias'ı (üçüncü-taraf) → proje-köküne göreli dosya (YENİ) → bilinmeyen
  alias hatası. `nox.json` OLMADAN (manifestsiz) tek-dosya kullanım eski
  ("yalnızca stdlib") davranışını aynen koruyor — birinci-taraf importlar
  bilinçli olarak bir manifest gerektiriyor (Go'nun `go.mod`u/Cargo'nun
  `Cargo.toml`ı ile tutarlı).
- `import X as Y` ve `from X import Y [as Z]` sözdizimi eklendi (Faz U.3) —
  `import nox.http as h` ile `h.get(...)` `nox.http.get(...)`e eşdeğer olur;
  `from nox.http import get` ile `get(...)` modül niteliği olmadan doğrudan
  çağrılabilir (`from nox.http import get as g` ile yerel takma ad da
  verilebilir). Bir `from`la içe aktarılan isim kullanıcının kendi yerel bir
  tanımıyla çakışırsa yerel tanım her zaman önceliklidir. Bilinen v1
  sınırlaması: `nox.http.serve` özel yerleşiği `import ... as`la tam
  desteklenir ama `from nox.http import serve` ile çıplak çağrı henüz özel
  olarak tanınmıyor (güvenli bir "tanımsız değişken" hatasına düşer, sessiz
  yanlış davranış değil).
- Birinci-sınıf fonksiyon değerleri (closure) için tip sistemi temeli
  eklendi (Faz U.4.1) — yeni `(int, int) -> int` tip ifadesi sözdizimi ve
  `Type.func` semantik tipi. Bu ilk alt-faz yalnızca tip sistemini kapsıyor;
  çalışma zamanı temsili/dolaylı çağrı desteği sonraki alt-fazlarda (U.4.2-
  U.4.4) geliyor. Kullanıcıyla netleşen karar: tam closure semantiği (dış
  kapsam değişkenlerini yakalama), yalnızca çıplak fonksiyon referansları
  değil.
- İç içe `def` + serbest değişken (capture) analizi eklendi (Faz U.4.2) —
  bir fonksiyon gövdesi içinde artık (generic/async olmayan) başka bir
  `def` tanımlanabilir; dış kapsamdaki değişkenlere yapılan referanslar
  otomatik olarak "yakalanır" (capture), iç fonksiyonun adı dış kapsamda
  `.func` tipinde bir yerel değişkene bağlanır. Yakalama yalnızca okunabilir
  (dış değişkene sonradan atama, closure'dan görünmez) — dış bir değişkene
  ATANMAYA çalışmak açık bir hatayla reddedilir. Çalışma zamanı temsili/
  dolaylı çağrı henüz yok (U.4.3/U.4.4'te geliyor) — şimdilik `noxc build`
  bu tür bir programı derlerken checker aşamasını geçer ama codegen
  aşamasında güvenli bir "henüz desteklenmiyor" hatasıyla durur.
- Closure çalışma zamanı temsili + QBE codegen eklendi (Faz U.4.3) — iç içe
  `def`ler artık gerçekten çalışıyor: yeni `HeapKind.closure` (sınıf
  örnekleriyle aynı ARC havuzu, `{fn_ptr, yakalanan değerler...}` bellek
  düzeni), `genNestedFuncDef`/`genClosureFunc`/`genClosureRelease`. Bir
  closure oluşturulduğunda yakalanan heap-yönetimli değerler retain edilir,
  closure serbest bırakıldığında (refcount sıfıra inince) release edilir —
  döngü içinde tekrar tekrar oluşturma/serbest bırakma sızıntısız. Bilinçli
  v1 kesintileri: Katman 3 döngü çözücüsüyle entegrasyon yok, closure'lar
  için `==`/`!=` yok, closure'ı DEĞER olarak dolaylı çağırma/parametre-dönüş
  olarak geçirme henüz yok (U.4.4'e ertelendi — bir closure'ı çıplak bir
  func-tipli değişkene atamak/döndürmek şimdilik güvenli bir "henüz
  desteklenmiyor" hatasına düşer, çökme değil).
- Closure değerleri üzerinden dolaylı çağrı + parametre/dönüş olarak
  geçirme eklendi (Faz U.4.4) — **Faz U.4 (birinci-sınıf fonksiyon
  değerleri/closure) TAMAMEN BİTTİ.** Bir closure artık func-tipli bir
  değişkene/parametreye atanabilir ve o değişken/parametre üzerinden
  dolaylı olarak çağrılabilir (`f(x)`) — hangi somut closure çağrıldığı
  derleme zamanında bilinmese de argüman/dönüş tipleri statik imzadan
  (`(int) -> int` gibi) doğru şekilde çözülür. Closure bellek düzenine
  ikinci bir işaretçi (`release_fn_ptr`, offset 8) eklendi — release artık
  tamamen dolaylı/polimorfik, U.4.3'ün `class_name` bilinmediğinde
  "henüz desteklenmiyor" hatasına düşen geçici kısıtlaması tamamen
  kaldırıldı. Bilinçli v1 sınırı: yalnızca bir iç içe `def`den inşa edilen
  closure'lar func-tipli olabilir — üst-düzey bir `def`e çıplak referans
  (`f: (int) -> int = add`) henüz desteklenmiyor.
- `with EXPR as NAME:` / `with EXPR:` (bağlam yöneticisi / context manager)
  eklendi (Faz U.5) — `EXPR`, bir `__enter__(self) -> T` / `__exit__(self)
  -> None` metod çiftine sahip bir sınıf örneği olmalıdır; `__exit__` HER
  ZAMAN çalışır (normal tamamlanma, `return`, yakalanmamış istisna DAHİL).
  Bilinçli v1 sınırları: `__enter__`/`__exit__` argüman almaz, `__exit__`
  bir istisnayı bastıramaz, birden çok bağlam yöneticisi tek bir `with`de
  virgülle birleştirilemez (her biri ayrı bir `with` olarak iç içe
  yazılmalıdır).
- `nox.log` modülü eklendi (Faz V.1) — basit, seviyeli konsol günlükleme
  (`debug`/`info`/`warn`/`error` + `format`). Tamamen saf Nox
  (`nox.time.now_ms` + `str()` + `print()` üzerine), hiç Zig/`extern def`
  gerekmedi. Bilinçli v1 sınırı: çalışma zamanında yapılandırılabilir bir
  minimum-seviye filtresi yok (Nox'ta paylaşılan mutable modül-düzeyi
  durum yok), çıktı her zaman stdout'a gider.
- `nox.random` modülü eklendi (Faz V.2) — basit PRNG (`seed`/`randint`/
  `random`, Xoshiro256 — kriptografik güvenlik iddiası yok). Diğer stdlib
  modüllerinden farklı olarak gerçek bir Zig kabuğu gerektirdi
  (`runtime/stdlib_shims/random.zig`); PRNG durumu, `nox.os`nin argc/argv'si
  ile aynı "süreç ömrü boyunca yaşayan statik değişken" deseninde tutulur.
  `seed` hiç çağrılmadıysa ilk kullanımda otomatik tohumlanır.
- `nox.crypto` modülü eklendi (Faz V.3) — `sha256(data: str) -> str` (64
  karakterlik küçük harf hex özet). Zig'in kendi `std.crypto.hash.sha2.
  Sha256`si sarılır (sıfırdan bir hash algoritması yazılmadı). FIPS 180-4
  test vektörleriyle doğrulandı.
- `nox.time` genişletildi (Faz V.4) — `DateTime` sınıfı (yıl/ay/gün/saat/
  dakika/saniye) + `from_epoch_ms(ms) -> DateTime` / `now() -> DateTime`.
  Zig'in kendi `std.time.epoch`u sarılır (sıfırdan takvim aritmetiği
  yazılmadı). Bilinçli v1 sınırı: yalnızca ayrıştırma (epoch-ms →
  DateTime), ters yön yok; yalnızca 1970 ve sonrası.
- `nox.test` genişletildi (Faz V.5) — yeni `TestSuite` sınıfı
  (`check_eq_int`/`check_eq_str`/`check_eq_float`/`check_true`, mevcut
  `raise`-tabanlı `assert_*`in aksine hiçbir zaman raise etmez, sonucu
  biriktirir) + `write_junit_xml`. `check_*`in raise etmemesi, kullanıcının
  kendi `setup()`/`teardown()`unu her kontrolün etrafına koyabilmesini
  sağlar — tek bir başarısız kontrol artık teardown'ı engellemez.
- `nox.regex` modülü eklendi (Faz V.6) — `is_match(pattern, text) -> bool`
  / `find(pattern, text) -> int`. Zig'de std'de regex bulunmadığından,
  Brian Kernighan'ın kamuya mal olmuş klasik minimal backtracking regex
  algoritmasının genişletilmiş bir versiyonu yazıldı. Desteklenenler:
  literal karakterler, `.`, `*`/`+`/`?`, `^`/`$`, `[abc]`/`[a-z]`/`[^abc]`.
  Bilinçli v1 kapsam dışı: gruplama, alternasyon, geri-referanslar,
  `{m,n}`, escape dizileri (`\d` vb.).
- Tree-sitter grameri eklendi (Faz W.1, `editors/tree-sitter-nox/`) — dilin
  neredeyse tamamını (girinti-duyarlı bloklar, tüm kontrol akışı, `with`/
  `lowlevel`, generics, fonksiyon tipleri, `async`/`await`/`spawn`,
  `extern def ... with_rt`, `import`/`from...import`, `list`/`dict`
  literalleri) kapsar. Girinti (NEWLINE/INDENT/DEDENT) üretimi, tree-sitter-
  python'ın kanıtlanmış algoritmasından uyarlanmış bir harici C tarayıcısıyla
  (`src/scanner.c`) yapılır. `queries/highlights.scm` ile sözdizimi
  vurgulama sorgusu dahil. Repodaki 201 gerçek `.nox` dosyasının TAMAMI
  (stdlib + benchmarks + tests/golden) sıfır ayrıştırma hatasıyla doğrulandı
  — derleyicinin kendi golden-test süitinden bağımsız bir ikinci doğrulama
  katmanı. Bu, ana derleyici/runtime'a hiçbir değişiklik getirmez (ayrı bir
  JS/C alt-projedir, `zig build test`i etkilemez).
- `noxlsp` eklendi (Faz W.2, `compiler/lsp_main.zig`, yeni `zig build`
  hedefi) — Nox için minimal bir Language Server Protocol sunucusu.
  `textDocument/didOpen`/`didChange`/`didClose` üzerinde derleyicinin
  gerçek lexer→parser→checker boru hattını doğrudan kütüphane olarak
  çağırıp sonucu `textDocument/publishDiagnostics`e çevirir (`hover`/
  `completion`/`definition` gibi diğer yetenekler bilinçli olarak v1
  kapsamı dışı). `tests/cli/lsp_test.zig` ile uçtan uca (spawn edilen
  gerçek `noxlsp` alt sürecine stdio üzerinden LSP çerçeveleriyle
  konuşularak) doğrulandı.
- DAP/debugger entegrasyonu eklendi (Faz W.3, `editors/vscode-nox/`) —
  yeni bir DAP sunucusu yazılmadı: `noxc build -g`nin (Faz T.3) ürettiği
  gerçek DWARF hat tablosu, var olan `lldb-dap`/CodeLLDB gibi standart
  debug adaptörleriyle doğrudan uyumlu. VS Code için `launch.json`/
  `tasks.json` şablonları + kurulum ve bilinen sınırlamaları (yalnızca
  satır-düzeyi, macOS'ta bağlı ikili DWARF taşımıyor) belgeleyen bir
  README eklendi. Bu makinede kurulu `lldb-dap`e ham DAP protokolüyle
  doğrudan konuşularak (initialize/launch/setBreakpoints/
  configurationDone) doğrulandı — macOS sınırlaması artık DAP protokolü
  seviyesinde de teyit edildi.
- `tests/fuzz/` dolduruldu (Faz X.2) — Zig'in kendi yerleşik, kapsam-güdümlü
  fuzzer'ı (`std.testing.fuzz`/`Smith`, `zig build test --fuzz`) kullanan
  iki hedef: lexer→parser→checker zinciri ve WASM ikili ayrıştırıcısı.
  Ayrıca, bu pinlenmiş Zig 0.16.0 araç zincirinde `--fuzz`in kendisinin
  (Zig'in kendi `compiler/test_runner.zig`sindeki bağımsız bir tip
  uyuşmazlığı yüzünden) derlenemediği keşfedildi — bu yüzden her iki
  dosyaya da `std.testing.fuzz`e bağımlı olmayan, her `zig build test`te
  koşulsuz çalışan elle yazılmış regresyon testleri eklendi.
- ARC atomikliği/cross-thread invariant'ı resmileştirildi (Faz X.3) —
  `runtime/alloc/arc.zig`nin refcount'u kasıtlı olarak atomik değil (ölçülen
  performans fazı gerekçesiyle) ve Nox'un eşzamanlılık modeli tek-OS-iş-
  parçacıklı fiber zamanlaması; bu invariant araştırıldı, `nox.http`
  istemcisinin tek istisnası (arka plan iş parçacığı) doğrulandı ve artık
  Debug modunda `asap.RuntimeState.arc_owner_tid` ile aktif olarak
  denetleniyor (Release'de sıfır maliyet). Gerçek bir `std.Thread.spawn`
  ile başlatılan ayrı iş parçacığından yapılan ihlalin doğru yakalandığı
  yeni bir birim testiyle doğrulandı.
- Hafif paket dizini eklendi (Faz Y.1) — `compiler/pkg/index.zig`, üçüncü-
  taraf Nox paketlerini keşfetmek için statik bir JSON indeksini
  ayrıştırıp arayan salt-okunur bir katalog (gerçek bir sunucu/registry
  DEĞİL, `docs/uretim-hazirlik-analizi.md`nin talimatına uygun). Yeni,
  tam işlevsel `noxc search <indeks-dosyasi.json> [sorgu]` alt komutu
  (hâlâ iskelet olan `fetch`/`update`den farklı olarak).
- Beş gerçek üçüncü-taraf Nox paketi yayımlandı (Faz Y.2) —
  `github.com/mburakmmm/nox-pkg-{greet,mathx,stack,strfmt,collections}`,
  hepsi MIT lisanslı ve `v1.0.0` etiketli genel GitHub repoları — Nox'un
  merkeziyetsiz (Git tabanlı) paket ekosisteminin GERÇEKTEN çalıştığını
  kanıtlamak için. `examples/thirdparty_demo/`, bu beş paketi GERÇEK ağ
  üzerinden getirip tüketen uçtan uca bir örnek + `noxc search` için
  örnek bir paket dizini içerir.
- 1.0 için somut bir "hazır" tanımı belgelendi (Faz Z.1) —
  `nox-teknik-spesifikasyon.md` §3.43: Faz Q–Y'nin (temel sağlamlaştırma,
  platform genişletme, bellek güvenliği, derleyici DX, dil
  tamamlanmışlığı, stdlib, araç ekosistemi, güvenlik sertleştirme, paket
  ekosistemi) TAMAMININ TAMAMLANDIĞINI doğrulayan bir kontrol listesi;
  gerçek M:N fiber zamanlayıcı değerlendirmesinin (AA.1) 1.0'ın kapsamı
  DIŞINDA, 1.0-sonrası açık bir araştırma öğesi olarak kaldığı AÇIKÇA
  belirtildi.
- `VERSIONING.md` eklendi (Faz Z.2) — `v1.0.0`dan itibaren geçerli
  olacak semver politikası (MAJOR/MINOR/PATCH tanımları, kaynak
  uyumluluğu garantisi, kullanımdan kaldırma kuralı) ve dil/ABI
  stabilite garantisinin bilinçli kapsam dışı bıraktığı dört alan
  (ikili/ABI uyumluluğu, hata mesajı metni, `--dump`/`-v` çıktısı,
  üçüncü-taraf paket API'leri) yazılı hale getirildi. `README.md`ye
  bağlantı eklendi.
- `v0.1 (taslak)` etiketi kaldırıldı, gerçek sürüm numaralandırmasına
  geçildi (Faz Z.3) — `build.zig.zon`nin `.version`i `1.0.0`e
  güncellendi, `README.md`nin durum banner'ı buna göre yeniden yazıldı,
  bu dosyanın Faz Q'dan beri biriken tüm girdileri tek bir `[1.0.0]`
  başlığı altında toplandı.

### Düzeltildi
- **Bellek sızıntısı (Faz X.2, `tests/fuzz/wasm_parser_fuzz.zig`nin yeni
  regresyon testi tarafından bulundu):** `runtime/wasm_bridge/module.zig`nin
  `parse` fonksiyonu, onlarca hata yolunun hiçbirinde o ana kadar
  biriktirilmiş `types`/`func_type_indices`/`bodies`/`exports`
  listelerini (ve içlerindeki `params`/`results`/`name`/`locals`
  alt-dilimlerini) serbest bırakmıyordu — bozuk/kısaltılmış bir `.wasm`
  girdisi her zaman bir sızıntıya yol açardı (Faz 13'ten beri var olan,
  sistemik bir tasarım boşluğu). Her ara listeye/alt-tahsise kendi
  `errdefer`i eklenerek düzeltildi.
- **Güvenlik (Faz X.1, `docs/uretim-hazirlik-analizi.md` P1 bulgusu #12):**
  WASM köprüsünün DÖRT LEB128 varint okuyucusu (`runtime/wasm_bridge/
  module.zig`nin `readVarU32`/`readVarI32`si + `runtime/wasm_bridge/
  interp.zig`nin `readVarU32At`/`readVarI32At`si), bozuk/kötü niyetli bir
  `.wasm` dosyası 6+ ardışık devam baytı (`0x80`) sağladığında `shift: u5`
  taşmasına (28+7=35 > 31) yol açıyordu — güvenli derlemelerde panik
  (DoS), güvensiz derlemelerde tanımsız davranış. Bayt sayısı 5 ile
  sınırlandı, birikim `u64`/`i64`e taşındı, sonuç hedef genişliğe (u32/
  i32) sığma açısından doğrulandı (kanonik olmayan kodlamalar artık
  sessizce kırpılmıyor, reddediliyor). Kasıtlı boz→kırmızı→düzelt
  ritüeli sırasında test vektörünün kendisinde de gerçek bir hata
  bulundu (bkz. nox-teknik-spesifikasyon.md §3.38) ve düzeltildi.
- `noxlsp`nin LSP çerçeveleme okuyucusunda (`readMessage`), `std.Io.Reader.
  takeDelimiterExclusive`in delimiter'ı (`\n`) TÜKETMEDİĞİ (yalnızca ONA
  KADAR ilerlediği) fark edilmeden `takeDelimiterExclusive` kullanılmıştı —
  bu, her başlık satırından sonra `\n`nin buferde kalıp bir sonraki okumanın
  yanlış konumdan başlamasına, dolayısıyla mesaj gövdesinin kaydırılmasına
  yol açıyordu. `zig build test`in tamamının askıda kalmasıyla (SIGKILL ile
  sonlandırma gerekti) keşfedildi; `takeDelimiterInclusive`e geçilerek
  düzeltildi.
- **Önemli test-altyapısı düzeltmesi:** `compiler/*.zig` dosyalarına gömülü
  onlarca birim testi (`compiler/lexer/lexer.zig`, `compiler/parser/
  parser.zig`, `compiler/typecheck/types.zig` vb.) `zig build test`
  tarafından SESSİZCE hiç çalıştırılmıyordu — `lib.zig`nin (`nox` modülünün
  kökü) hiçbir `refAllDecls` çağrısı içermemesi nedeniyle Zig'in tembel
  analiz modeli bu dosyaların içindeki `test` bloklarını hiç keşfetmiyordu.
  `lib.zig`ye özyinelemeli bir `refAllDeclsRecursive` yardımcısı eklendi;
  bu, `compiler/parser/parser.zig`deki DÖRT testin Faz T.1'den (AST'ye
  `{kind, line}` sarmalayıcısı eklenmesi) beri sessizce DERLENEMEZ durumda
  olduğunu ortaya çıkardı (düzeltildi). Test sayısı 300'den 318'e çıktı.
- `noxc` artık proje kökü DIŞINDAN (ör. sistem geneli bir kurulumdan)
  çalıştırılabiliyor — `main.zig`, kendi stdlib/runtime kaynak dizinlerini
  artık CWD-göreli sabit `"stdlib"`/`"zig-out/lib/noxrt.o"` yolları yerine
  `project.resolveResourceDirs`in (kendi çalıştırılabilir dosya konumuna
  göre) çözdüğü yolları kullanıyor (Faz Q.3). Yeni, isteğe bağlı
  `NOX_RESOURCE_DIR` ortam değişkeni eklendi (paket önbelleği kökü olan
  `NOX_HOME`den AYRI bir kavram).
- `swap_aarch64.s` → `swap_aarch64.S`: Mach-O'ya özgü `_` sembol öneki
  KALDIRILDI, macOS/Linux'ta AYNI kaynaktan doğru derlenen taşınabilir bir
  `SYM(...)` makrosu eklendi (önceden Linux'ta linklenmezdi).
- `build.zig`ye Linux hedefleri İÇİN `link_libc = true` eklendi (`runtime/`
  genelinde kullanılan `std.c.*` çağrıları Linux'ta AÇIK libc bağlama
  gerektirir — macOS'ta bu her zaman örtüktü).
- `qbe`nin `-t <target>`i artık AÇIKÇA geçiliyor (Faz R.3) — önceden
  `qbe`nin KENDİ build-time varsayılanına güveniliyordu, bu da AYNI
  derleyicinin platform/derleme-ortamına göre SESSİZCE farklı bir ABI
  üretmesine yol açabiliyordu (Linux'ta GERÇEKTEN yakalanan bir hata).
- `build.zig`deki `install_stdlib`, `test_step`e HİÇ bağlı DEĞİLDİ —
  `zig build test`, `zig-out/lib/nox/stdlib/`nin ÖNCEKİ bir `zig build`
  çalışmasından KALMA olmasına sessizce güveniyordu (temiz bir `zig-out`
  üzerinde GERÇEKTEN başarısız olduğu doğrulandı, şimdi düzeltildi).
- `cc`nin link satırına `-rdynamic` eklendi (Faz R.3, EN DERİN bulgu) —
  `nox.json`nin `dlsym(dlopen(null,...), ...)` deseni ana programın KENDİ
  (QBE'nin ürettiği) sembollerini bulmak İÇİN bunu Linux'ta ZORUNLU kılıyor
  (macOS'ta örtük). Eksikliği Linux'ta GERÇEK bir çökmeye (geçerli JSON'da)
  VE bellek sızıntısına (bozuk JSON'un hata yolunda) yol açıyordu. `qbe -t`
  seçim mantığı da tekrarı önlemek İÇİN yeni `compiler/qbe_target.zig`ye
  taşındı.
- `Task[T]`/`Channel[T]`/`dict[K,V]` tipli bir değişken/sınıf alanı YENİDEN
  atandığında eski değer artık sızmıyor (Faz S.1) — `genAssign` artık bu üç
  türü de `destroyNonArcValue` ile yok ediyor. `Task` İÇİN AYRICA bir bellek
  güvenliği düzeltmesi: henüz TAMAMLANMAMIŞ bir görev "yok edilirse" (ör.
  hiç `await` edilmeden yeniden atanırsa) artık struct'ı HEMEN serbest
  BIRAKMIYOR (bu, fiber SONRADAN tamamlanınca serbest bırakılmış belleğe
  yazan bir use-after-free olurdu) — yeni `Task.detached` bayrağı gerçek
  serbest bırakmayı görev KENDİ KENDİNE tamamlanana kadar erteliyor.
- `list[T]` indekslemesi (`xs[i]`) artık sınır kontrolü yapıyor (Faz S.2) —
  önceden `xs[999]` gibi bir erişim sınır kontrolü OLMADAN doğrudan geçersiz
  belleğe erişirdi (tanımsız davranış). `s[i]`nin ZATEN kullandığı AYNI
  desenle artık aralık dışı bir erişimde `IndexError` `raise` ediliyor.
  Yan bulgu: `tests/compat/extern_ffi_test.zig` `core.nox`u (dolayısıyla
  `IndexError`/`ValueError`i) hiç birleştirmiyordu — düzeltildi.
- Codegen'in `releaseValueIfSet`i, func-tipli bir değişkene atanan/
  döndürülen bir closure değerinin somut kökeni bilinmediğinde (`class_name
  == null`) "attempt to use null value" ile ÇÖKÜYORDU (Faz U.4.3 sırasında
  manuel uçtan-uca testte bulundu). `class_name.?` → `class_name orelse
  return error.Unsupported` — artık main.zig'in zaten yakaladığı güvenli
  "henüz desteklenmiyor" hatasına düşüyor, panik yok.
- **Kritik, Faz 7'den beri var olan bir `try/finally` hatası düzeltildi**
  (Faz U.5'in `with` doğrulaması sırasında bulundu): bir `finally` bloğu
  İÇİNDE bir METOD ÇAĞRISI varsa (metod çağrıları her zaman bir istisna
  kontrolü üretir) VE bu finally normal-tamamlanma/eşleşen-`except`
  yolunda çalıştırılıyorsa, noxc'nin KENDİSİ derleme sırasında sonsuz
  özyinelemeyle (yığın taşması) çöküyordu — `finally_body`, KENDİSİ
  çalışırken hâlâ `finally_stack`de olduğundan, içindeki çağrının istisna
  kontrolü `drainFinally`yi tetikleyip aynı `finally`yi tekrar tekrar
  çalıştırıyordu. Yeni `runDetachedFinally` yardımcısı bunu düzeltiyor
  (finally'yi çalıştırmadan önce geçici olarak yığından çıkarıp sonra
  geri ekliyor). Önceden hiçbir test bir metod çağrısı içeren `finally`
  yazmadığından fark edilmemişti — `with`in `__exit__`i her zaman bir
  metod çağrısı olduğundan bunu ilk kez ortaya çıkardı.

### Güvenlik
- `nox.http.serve`e iki DoS sertleştirmesi eklendi (Faz Q.5): bir isteğin
  gövdesi artık 10 MiB ile sınırlı (aşılırsa `413 Payload Too Large`,
  handler hiç çağrılmaz) ve eşzamanlı bağlantı sayısı artık 4096 ile
  sınırlı (aşan bağlantılar `receiveHead`e ulaşmadan sessizce kapatılır).
  Bilinen kalan sınırlama: okuma zaman aşımı (slowloris koruması) henüz
  yok — reaktöre zamanlayıcı desteği eklenene kadar ertelendi.
