# NOX MOBILE --- Android ve iOS Üretim Hazırlığı Yol Haritası

> **Belge türü:** Nox derleyicisi + runtime için bağlayıcı uygulama
> planı\
> **Hedef:** Aura'nın tek Nox uygulama kodundan gerçek Android APK/AAB
> ve iOS IPA üretebilmesini sağlayacak, üretim kalitesinde Nox mobil
> desteği\
> **Hazırlanma tarihi:** 20 Ekim 2026\
> **Başlangıç durumu:** Nox 2.0.x; Aura 1.0 masaüstü tamamlanmış, mobil
> 1.1--1.5 planlanmış\
> **Durum:** v2.0.19'da Nox tarafının önemli bir deneysel alt kümesi
> uygulandı; hedeflerin hiçbiri `supported` değildir. Güncel açık iş ve
> bağımlılık sırası `project/nox-ana-todo.md`, Aura'ya devredilen işler ise
> `project/aura-mobil-eksiklikleri.md` dosyasındadır. Aşağıdaki boş kutular
> tek başına güncel uygulama durumunu göstermez.\
> **Kapsam:** Öncelikle Nox deposu; Aura'ya ait sınırlar ayrıca
> işaretlenmiştir.

## 0. Yürütme sözleşmesi

Bu belge bir özellik listesi değil, her fazı testle kapanan uygulama
sözleşmesidir.

1.  Önce Nox'un mevcut kodu, `AGENTS.md`, derleyici ve runtime
    sözleşmeleri incelenir. Dosya ve sembol isimleri değişmişse güncel
    kaynak esas alınır.
2.  Mevcut masaüstü davranışı ve 2.x kaynak uyumluluğu korunur. Kırıcı
    ABI/API değişikliği için ayrı ADR ve sürüm politikası gerekir.
3.  **Nox derleyicisi Nox deposunda geliştirilir. Aura deposu
    derleyiciyi yamalamaz.** Aura yalnızca kararlı ve belgelenmiş Nox
    mobil API'lerini kullanır.
4.  Her faz için önce başarısız test / yeniden üretilebilir kanıt, sonra
    düzeltme, ardından temiz CI gerekir.
5.  "ARM64 assembly çıktı" mobil destek sayılmaz. Hedef OS ABI'si,
    runtime, yükleme, lifecycle, paket ve cihaz testi birlikte
    doğrulanır.
6.  iOS cihaz, iOS simülatör ve macOS ARM64 **farklı hedeflerdir**;
    Android ve GNU/Linux ARM64 de farklıdır.
7.  Her hedef için açık destek matrisi tutulur: `experimental`,
    `preview`, `supported`. CI'siz hedef `supported` olamaz.
8.  Masaüstü için QBE/LLVM eşdeğerliği bozulmaz. Mobilde ilk aşamada tek
    **doğrulanmış** backend seçilebilir; iki backend zorunluluğu ayrı
    bir kapıdır.
9.  iOS'ta çalışma zamanında indirilen kodu derleyip yürütme/JIT temel
    mimari olmayacak. Uygulama kodu AOT derlenip imzalı pakete
    gömülecek.
10. Her platform bağımlılığı capability/profile ile modellenir.
    Desteklenmeyen import sessizce derlenip çalışma anında çökmez.
11. "Tam mobil destek" yalnız sayaç ekranı değildir: uygulama yaşam
    döngüsü, giriş, metin, erişilebilirlik, ağ, depolama, hata raporlama
    ve mağaza dağıtımı test edilir.
12. Her sürüm sonunda Nox kaynak kodu, Aura mobil örnekleri ve gerçek
    cihaz/simülatör testlerinin sonuçları birlikte raporlanır.

### 0.1 Güncel uygulama özeti (25 Ekim 2026)

Bu tablo, aşağıdaki 190 maddelik kabul sözleşmesini değiştirmez; hangi kısmın
Nox'ta uygulandığını ve kalan işin hangi aktif listede yürütüldüğünü gösterir.
`Kısmi`, ilgili fazın bazı kaynak/testleri bulunduğu fakat kendi kabul kapısının
tamamı geçmediği anlamına gelir.

| Faz | Nox durumu | Kalan işin sahibi / kanıt |
|---|---|---|
| M0 — ADR/envanter | Büyük ölçüde tamam | ADR-MOB-001..008 ve toolchain/matrix mevcut; temiz/tagli baseline ve ayrıntılı durum takibi `project/nox-ana-todo.md` Faz 0 |
| M1 — target/AOT | Kısmi | Dört LLVM target ve library output var; iOS device run ve Android x64 run yok. Nox TODO Faz 3–4 |
| M2 — embed runtime | Kısmi | Versioned lifecycle/event ABI ve 10.000 döngü testi var; açık runtime/allocator state, exception/OOM ve cihaz sanitizer kapıları açık. Nox TODO Faz 1 ve 3 |
| M3 — mobil stdlib | Kısmi | Capability mask, FS/SQLite kökleri, TLS/HTTP/crypto/thread smoke var; sandbox ve ağ hata matrisi tamam değil. Nox TODO Faz 3 |
| M4 — iOS preview | Kısmi | Simulator çalıştırıldı; fiziksel cihaz, signed IPA ve TestFlight yok. Nox target işi ana TODO'da, host işi Aura devir belgesinde |
| M5 — Android preview | Kısmi | ARM64 emulator çalıştırıldı; x64 run, fiziksel cihaz, release APK/AAB ve Play yok. Sorumluluk bölünümü M4 ile aynı |
| M6 — Aura parity | Aura'ya devredildi | `project/aura-mobil-eksiklikleri.md` A3–A4 |
| M7 — DX/paketleme | Kısmi | Nox target/output CLI var; Aura doctor/create/run/build ve signed packaging Aura A5'te |
| M8 — üretim kalitesi | Açık | Nox runtime/security kapıları ana TODO Faz 3/7; UI/store/performance Aura A4/A6 |
| M9 — CI/lab | Kısmi | iOS simulator ve Android library CI var; emulator/device/nightly/release kanıtları açık |
| M10 — stable | Kapalı | `mobile-evidence/dod.txt` signed IPA/APK/AAB ve device lab için `no`; bütün target'lar `experimental` |

Nox'un yürütme sırası [`project/nox-ana-todo.md`](project/nox-ana-todo.md),
Aura teslimleri [`project/aura-mobil-eksiklikleri.md`](project/aura-mobil-eksiklikleri.md)
dosyasındadır. Tarihli ham kanıt `mobile-evidence/` altında tutulur.

## 1. Kaynak denetimi: bugün doğrulanmış olanlar

-   `compiler/qbe_target.zig` içindeki `hostedTargetInfo` şu hedefleri
    içeriyor: `macos-arm64`, `macos-x64`, `linux-x64`, `linux-arm64`,
    `linux-riscv64`, `windows-x64`. **Android ve iOS hedefleri henüz
    yok.**
-   `noxc build --target` hosted hedefleri mevcut;
    `--profile freestanding --target aarch64` işletim sistemi olmadan
    çalışan kod içindir, mobil uygulama hedefi değildir.
-   Nox'un `nox.*` standart kütüphanesi `filesystem`, `network`,
    `process`, `threads`, `clock`, `shared_memory`, `entropy` gibi
    capability sınıfları kullanıyor. Mobil izin/sandbox politikası için
    temel mevcut ama yeniden ayrıntılandırılması gerekiyor.
-   NNI v1 (`include/nox_nni.h`) opak handle ve C ABI üzerinden native
    genişletme sağlıyor. **Mobil uygulama tarafından Nox'u başlatmak
    için gereken gömme/host API'si ile NNI plugin API'si aynı şey
    değildir.**
-   Aura 1.0 masaüstünde macOS/Windows/Linux kabukları ve ortak
    widget/render sözleşmesi mevcut. `roadmap.md` mobil 1.1 iOS, 1.2
    klavye, 1.3 lifecycle, 1.4 Android, 1.5 GPU/erişilebilirlik/paket
    adımlarını tanımlıyor.
-   Aura'nın `AGENTS.md` mimari invariant'ları korunmalı: Widget ≠
    Element ≠ RenderObject; platform kabuğu widget import etmez;
    platform olayları kuyruktan akar; Nox derleyicisi Aura deposunda
    değiştirilmez.

**Önemli ayrım:** Bu belge güncel kaynakların statik incelemesine ve
resmi platform gereksinimlerine dayanır. Burada Nox'un mobil derlemesi
veya cihaz testi çalıştırılmış değildir.

### 1.1 Teslim edilecek hedefler

  -------------------------------------------------------------------------------------
  Kimlik         Platform       Önerilen Nox hedef adı  Çıktı            İlk kanıt
  -------------- -------------- ----------------------- ---------------- --------------
  T1             iPhone/iPad    `ios-arm64`             `.o`/`.a`,       Fiziksel
                 cihaz                                  XCFramework      cihazda Nox
                                                        device slice     fonksiyonu

  T2             iOS Simulator  `ios-simulator-arm64`   `.o`/`.a`,       iOS
                 (Apple                                 simulator slice  Simulator'da
                 Silicon)                                                çağrı

  T3             iOS Simulator  `ios-simulator-x64`     `.o`/`.a`        Intel
                 (Intel,                                                 simülatör CI
                 ikincil)                                                veya açıkça
                                                                         ertelenmiş

  T4             Android ARM64  `android-arm64`         `libnoxapp.so`   ARM64
                                                                         emülatör +
                                                                         cihaz

  T5             Android x86_64 `android-x64`           `libnoxapp.so`   x86_64
                 emülatör                                                emülatör

  T6             Android 32-bit **ilk sürüm kapsam      ---              Destek iddiası
                                dışı**                                   yok
  -------------------------------------------------------------------------------------

Hedef isimleri **öneridir**; önce ADR ile kesinleştirilecek. `ios-arm64`
ile `ios-simulator-arm64` tek ad altında birleştirilmeyecek. Android
minimum SDK, iOS deployment target, NDK/Xcode/Zig sürümleri ayrı bir
**kilitli toolchain manifesti** ile belirlenecek.

## 2. Hedef mimari

``` text
                       noxc (macOS / Linux / Windows host)
                                 |
                       Nox source + Aura source
                                 |
                   typecheck -> IR -> AOT backend
                                 |
             +-------------------+-------------------+
             |                                       |
       iOS arm64 / simulator                   Android arm64 / x64
             |                                       |
     Nox runtime static library               Nox runtime shared library
       libnoxapp.a / XCFramework                   libnoxapp.so
             |                                       |
        Swift/Obj-C++ host                       Kotlin/Java host
        UIKit + Skia renderer                  Activity + JNI + Skia
             |                                       |
     signed .app -> .xcarchive -> IPA          Gradle -> APK / signed AAB
             |                                       |
        TestFlight / App Store                  Google Play / sideload
```

**Önerilen uygulama sınırı:** Nox programı uygulamanın tek mantıksal
örneğidir; platform host yalnız lifecycle, olay, pencere/yüzey, OS
servisleri ve paketlemeyi sağlar. Platform host widget ağacını
oluşturmaz. Nox'a olaylar sürümlemeli, C ABI uyumlu bir köprüyle
iletilir.

### 2.1 Nox'a ait işler ve Aura'ya ait işler

  ------------------------------------------------------------------------------
  Alan                    Nox sorumluluğu         Aura sorumluluğu
  ----------------------- ----------------------- ------------------------------
  Derleyici hedefleri     Target triple, object   Yok
                          üretimi, link kontratı  

  Runtime                 Bellek, exceptions,     Nox API'lerini kullanmak
                          threads, fibers, TLS,   
                          init/shutdown           

  Host/embed ABI          Nox giriş noktası,      Köprüye uyumlu kabuk
                          olay/geri çağrı, handle 
                          yaşam döngüsü           

  Platform servisleri     Capability, güvenli     UI seviyesinde servis API'si
                          temel adaptörler, hata  
                          modeli                  

  Çizim                   Platform bağımsız       Skia raster/GPU backend, frame
                          native çağrıyı mümkün   pipeline
                          kılmak                  

  UI                      Widget bilgisi yok      Widget/Element/RenderObject,
                                                  input, semantics

  APK/AAB/IPA             Hedefe uygun            Gradle/Xcode proje üretimi,
                          linklenebilir native    signing, dağıtım
                          artifact ve metadata    

  CI                      Derleyici ve runtime    Gerçek uygulama smoke/E2E ve
                          uyumluluğu              paketleme
  ------------------------------------------------------------------------------

## 3. Faz M0 --- Envanter, ADR ve kabul testleri (bloklayıcı)

-   [ ] `compiler/main.zig`, `compiler/qbe_target.zig`, LLVM ve QBE
    target seçimi, `build.zig`, runtime object link zinciri, host
    linking yardımcıları incelensin.
-   [ ] `runtime/async_rt/{fiber,scheduler,io,...}`, `runtime/alloc`,
    TLS, thread, `stdlib_shims` ve freestanding yolları OS çağrısı ve
    assembly açısından taransın.
-   [ ] Hangi native `extern def` sembollerinin uygulama statik
    kütüphanesine gireceği çıkarılsın; her sembol için ABI/ownership
    tablosu hazırlansın.
-   [ ] Mevcut Aura host'unun `main` beklentisi, event polling ve Skia
    native link zinciri incelensin.
-   [ ] ADR-MOB-001: `Nox embedded library` modeli ve giriş noktası.
-   [ ] ADR-MOB-002: mobil target adları, triple, SDK, minimum OS ve
    backend seçimi.
-   [ ] ADR-MOB-003: Nox runtime'ın thread/fiber/TLS ve lifecycle
    politikası.
-   [ ] ADR-MOB-004: platform servisleri ve capability/izin sınırı.
-   [ ] ADR-MOB-005: statik/dinamik linkleme, Skia ve lisans/dağıtım.
-   [ ] ADR-MOB-006: callback reentrancy, event queue ve UI thread
    sözleşmesi.
-   [ ] ADR-MOB-007: debug symbols, crash reporting ve test
    gözlemlenebilirliği.
-   [ ] ADR-MOB-008: mobil backend politikası; QBE iOS/Android ABI
    doğrulaması veya LLVM-first kararı.
-   [ ] Her ADR'de reddedilen alternatifler ve geri alma planı bulunsun.
-   [ ] Nox/Aura CI başlangıç ölçümleri arşivlensin; mevcut masaüstü
    testleri referans olsun.

**Kabul:** Mimari kararlar yazılmış; platform hedefleri ve kabul
testleri sahipleri belirlenmiş; masaüstü baseline yeşil.

## 4. Faz M1 --- Gerçek mobil target ve AOT nesne üretimi

### 4.1 Derleyici ve hedef tanımları

-   [ ] `hostedTargetInfo` veya yerine geçen tekil target registry
    Android/iOS device/simulator ayrımını desteklesin.
-   [ ] Target tanımı `arch`, `os`, `abi`, `sdk`, `deployment target`,
    `object format`, `linker`, `runtime artifact`, `features` içersin.
-   [ ] Target doğrulaması frontend, LLVM, QBE, `zig cc`, runtime ve
    paketleme boyunca **tek kaynaktan** beslensin.
-   [ ] `--target` ile mobil hedef seçildiğinde host işletim sistemi
    varsayımına sessizce düşülmesin.
-   [ ] Hedefe uygun Mach-O (iOS) ve ELF (Android) nesneleri üretilsin;
    simülatör slice'ı yanlışlıkla cihaz slice'ı diye paketlenmesin.
-   [ ] Apple SDK `sysroot`, deployment target, `-isysroot`, target
    triple ve uygun clang/ld araçları açıkça çözülsün.
-   [ ] Android NDK sysroot, Bionic libc, Android API seviyesi ve
    LLVM/Clang triple açıkça çözülsün.
-   [ ] `zig cc` sürümünde Android/iOS desteği ve Apple SDK ile
    uyumluluk gerçek build ile doğrulansın; yalnız target string
    eklenmesi yeterli sayılmasın.
-   [ ] `--emit-obj` veya eşdeğer belgeli nesne çıktı modu tanımlansın.
-   [ ] `--emit-static-lib`/`--emit-shared-lib` semantiği belirlenip
    desteklenen platformlarda uygulanmalı; uygulama entry point'i
    library modunda `main` üretmemeli.
-   [ ] Linklenebilir runtime object/archive hedefe özel üretilsin;
    masaüstü `noxrt.o` yanlış hedefte kullanılmasın.
-   [ ] Target'a özel `libc`, `libm`, C++ runtime, atomic ve sistem
    kütüphaneleri link planında açıkça listelensin.
-   [ ] Harici `extern def` sembollerinin çözümü static archive ve
    shared library senaryolarında test edilsin.
-   [ ] `-fPIC`/PIE, symbol visibility, dead stripping ve LTO uyumluluğu
    test edilsin.
-   [ ] ARM64 calling convention, 16-byte stack alignment, struct
    return, float/vector argümanları, varargs, TLS ve exception
    sınırları için ABI fixture yazılsın.
-   [ ] iOS için device ve simulator `.a` dilimleri üretip
    `xcodebuild -create-xcframework` ile birleştirme kanıtlansın.
-   [ ] Android `libnoxapp.so` `arm64-v8a` ve `x86_64` klasörlerinde
    yüklenebilsin.
-   [ ] Android 16 KiB page size uyumluluğu, ELF segment hizası ve
    `getpagesize()` ile dinamik sayfa boyutu kullanımı doğrulansın.
-   [ ] Cross-compile işlemi imzalama gerektirmeden mümkün olsun; iOS
    IPA export/sign için macOS/Xcode şartı açıkça belgelensin.

### 4.2 Backend stratejisi

**Öneri:** Mobilde başlangıç için LLVM AOT tercih edilsin; ancak Nox'un
mevcut `--target` yolunun QBE'ye yönelmesi nedeniyle bu yeni bir build
yolu ve test gerektirir. QBE'nin `arm64_apple` çıktısının iOS
cihaz/simülatör hedefini otomatik olarak kapsadığı **varsayılmayacak**.
Android için genel `arm64` ABI'si de Bionic link zincirinin doğrulandığı
anlamına gelmez.

-   [ ] LLVM IR → doğru target triple/data layout → native `.o` yolu
    kanıtlansın.
-   [ ] QBE desteği vaat edilecekse aynı ABI fixture'ları geçsin; aksi
    hâlde mobilde QBE açık hata ile `unsupported` olsun.
-   [ ] QBE/LLVM arasında `int`, `float`, string, class, exception,
    generic ve async davranışları için diferansiyel test hazırlansın.
-   [ ] Cross-compile ile host'ta çalıştırma birbirine karıştırılmasın.

**Kabul:** Dört birincil hedefte (`ios-arm64`, `ios-simulator-arm64`,
`android-arm64`, `android-x64`) en az bir gerçek Nox modülü platform
host tarafından çağrılıyor; doğru ABI ve sonuç CI'de kanıtlanıyor.

## 5. Faz M2 --- Embeddable Nox runtime ve C ABI

Bu faz **kritik yol**dur. NNI v1 native plugin'lerin Nox'a bağlanması
içindir; iOS/Android host'un Nox uygulamasını başlatıp yönetmesi için
ayrı, küçük, sürümlemeli **Nox Embed ABI** tanımlanır.

### 5.1 Önerilen host ABI (taslak, mevcut API değil)

``` c
typedef struct NoxApp NoxApp;
typedef struct NoxHostConfig NoxHostConfig;
typedef struct NoxEvent NoxEvent;

int32_t nox_embed_abi_version(void);
int32_t nox_app_create(const NoxHostConfig* config, NoxApp** out);
int32_t nox_app_start(NoxApp* app);
int32_t nox_app_post_event(NoxApp* app, const NoxEvent* event);
int32_t nox_app_pump(NoxApp* app, uint64_t monotonic_time_ns);
int32_t nox_app_request_stop(NoxApp* app);
int32_t nox_app_destroy(NoxApp* app);
```

Bu yalnızca tasarım taslağıdır; kesin imzalar, hata türleri,
thread-safety, callback ve ownership ADR'de netleşmeden kamuya açılmaz.

-   [ ] `main()` varsayımından bağımsız `create/start/pump/stop/destroy`
    yaşam döngüsü sağlansın.
-   [ ] Nox uygulamasının global değişkenleri, modül init'i ve teardown
    sırası tanımlansın.
-   [ ] Birden çok `create` desteklenmeyecekse açıkça reddedilsin;
    desteklenecekse global runtime state ayrıştırılsın.
-   [ ] Init hatası, kısmi init ve tekrarlı destroy güvenli olsun.
-   [ ] C ABI'de yalnız sabit genişlikli türler, opaque handle ve
    versioned struct kullanılsın.
-   [ ] Struct size/ABI version kontrolü yapılsın; yanlış sürüm açık
    hata versin.
-   [ ] Nox string ve byte buffer'ları için UTF-8, uzunluk, NUL ve
    kopyalama/borrow sözleşmesi yazılsın.
-   [ ] Host callback'leri sırasında Nox exception'ları C sınırını
    aşmasın; hata kodu ve okunabilir hata nesnesine dönüştürülsün.
-   [ ] Native callback'in tekrar Nox'a girmesi (`reentrancy`)
    tanımlansın; yasaksa testli hata versin.
-   [ ] Handle retain/release ve finalizer sırası tanımlansın.
-   [ ] UI thread, runtime worker thread ve callback thread için tek bir
    sözleşme oluşturulsun.
-   [ ] `post_event` çoklu thread'den çağrılacaksa queue ownership ve
    ordering garanti edilsin.
-   [ ] Host olaylarının işlenmesi uygulama kapanışından sonra
    use-after-free oluşturmasın.
-   [ ] Uygulama askıya alındığında aktif frame/timer/işlerin ne olacağı
    tanımlansın.
-   [ ] Native host crash olduğunda veya Nox hata verdiğinde kaynak
    temizliği güvenli olsun.
-   [ ] Örnek C/Swift/Kotlin host fixture'ları sağlansın.

### 5.2 Bellek ve eşzamanlılık

-   [ ] ARC/ASAP ve cycle collector mobil runtime'da adres hizalama ve
    pointer boyutuyla doğrulansın.
-   [ ] iOS/Android allocator, bellek baskısı ve OOM hata modeli
    tanımlansın.
-   [ ] Thread-local runtime state ve TLS destructor davranışı
    doğrulansın.
-   [ ] ARM64 fiber context-switch assembly'si Apple/Android ABI'lerine
    karşı denetlensin; desteklenmiyorsa güvenli fallback seçilsin.
-   [ ] Stack guard, stack overflow, signal/exception handler ve
    sanitizer uyumluluğu test edilsin.
-   [ ] Async scheduler UI thread'i bloklamasın; frame pump'ın zaman
    bütçesi olsun.
-   [ ] Uygulama background olduğunda worker/fiber/timer davranışı
    işletim sistemi kurallarına uysun.
-   [ ] iOS arka planında sınırsız çalışan scheduler varsayılmasın;
    yalnız OS'nin izin verdiği background task modları kullanılsın.
-   [ ] JNI local/global reference yaşam döngüsü, Swift/Obj-C ARC ↔ Nox
    ARC ownership sınırları için stres testleri yazılsın.
-   [ ] Uygulama tekrar ön plana alındığında yarım kalmış işler ve event
    queue deterministik davransın.

**Kabul:** 10.000 tekrar create/start/stop/destroy, yoğun callback,
exception ve bellek baskısı testleri sanitizer/cihaz ortamlarında çökme,
double-free ve büyüyen kalıcı sızıntı göstermiyor.

## 6. Faz M3 --- Mobil standart kütüphane ve capability profili

`hosted` profilini mobilde koşulsuz açmak yerine `mobile-ios` ve
`mobile-android` platform özellikleriyle bir capability matrisi
oluşturulmalı. Bunlar ayrı profile adları olabilir veya mevcut hosted
profile içinde platform kısıtları olarak modellenebilir; seçim ADR'ye
bağlıdır.

  -------------------------------------------------------------------------------
  Modül / alan        iOS                Android           Gereken çalışma
  ------------------- ------------------ ----------------- ----------------------
  Saf hesaplama,      Temel taşınabilir  Temel taşınabilir ABI + golden test
  JSON, regex,                                             
  collections                                              

  `nox.time` /        Destek             Destek            Suspend/resume,
  monotonic clock                                          monotonic farklar

  `nox.crypto` /      Destek             Destek            OS güvenli RNG, key
  entropy                                                  storage ayrı

  `nox.fs`,           Sandbox içinde     App-private       Documents/cache/tmp,
  `nox.path`                             storage içinde    scoped erişim

  `nox.http`,         İzin/policy        Manifest/policy   TLS trust, DNS, IPv6,
  `nox.tls`,          koşullu            koşullu           proxy
  websocket                                                

  `nox.thread`,       Sınırlandırılmış   Destek            Lifecycle, worker
  `nox.atomic`                                             teardown

  `nox.process`       Genel subprocess   Android sandbox'a Unsupported API açık
                      desteği vaat       bağlı, varsayılan hata
                      edilmez            kısıtlı           

  `nox.sharedmem`     Ayrı değerlendirme Ayrı              OS izinleri ve IPC
                                         değerlendirme     

  `nox.native`,       Dinamik yükleme    Paketlenmiş       Static registry veya
  `nox.plugin`, HPy   varsayılan kapalı  native kod        açık unsupported
                                         politikası        

  SQLite              App sandbox        App sandbox       Uygun platform
                                                           SQLite/bağımlılık

  stdout/stderr/log   Xcode/OSLog        Logcat köprüsü    Debug/release log
                      köprüsü                              politikası
  -------------------------------------------------------------------------------

### 6.1 Dosya sistemi

-   [ ] `app_documents`, `app_support`, `app_cache`, `app_temp` gibi
    sandbox dizinleri için host-backed API sağlansın.
-   [ ] CWD'nin masaüstü gibi davranacağı varsayılmasın; göreli path
    semantiği açık olsun.
-   [ ] iOS Files/document picker ve Android Storage Access Framework,
    dosya yolu yerine URI/izin token'ı döndürebilir; bunları ham POSIX
    path'e zorla çevirmeyin.
-   [ ] Atomic write, dosya koruma, quota/disk-full, silinmiş URI izni
    ve uygulama güncellemesi test edilsin.
-   [ ] Backup/restore ve hassas veri depolama kuralları belgelensin.

### 6.2 Ağ ve güvenlik

-   [ ] Android `INTERNET` izni, iOS ATS ve TLS trust davranışları
    host/paket seviyesinde belgelensin.
-   [ ] DNS IPv4/IPv6, ağ değişimi, captive portal, offline, TLS
    sertifika reddi test edilsin.
-   [ ] HTTPS varsayılanı; sertifika doğrulaması debug kolaylığı için
    sessizce kapatılmasın.
-   [ ] Arka planda ağ işlemi yapma koşulları platforma özel
    belgelensin.
-   [ ] `nox.crypto` üzerinden rastgelelik, anahtar saklama için
    Keychain/Android Keystore adaptörü ayrı platform servisi olarak
    tanımlansın.
-   [ ] Kullanıcı izinleri (kamera, konum, mikrofon, bildirim vb.) Nox
    runtime'da zorunlu genel API değil; Aura/host servisleri üzerinden
    capability ile sağlansın.

### 6.3 Native extension ve aHPy

-   [ ] iOS'ta runtime `dlopen` ile dışarıdan indirilen native
    plugin'leri yükleme varsayımı kaldırılmalı; izin verilen native
    modüller derleme/link aşamasında pakete gömülmeli.
-   [ ] Android'de `.so` yalnız paketlenmiş, ABI uyumlu ve doğrulanmış
    kütüphanelerden yüklenmeli; keyfî dış kod yüklemeye dayanılmamalı.
-   [ ] NNI/HPy için mobil destek **ayrı capability** olarak izlenmeli;
    masaüstü uyumluluğu mobil destek iddiası değildir.
-   [ ] aHPy ilk mobil sürümün bloklayıcısı yapılmasın; daha sonra
    static/packaged Universal ABI stratejisi ADR ile değerlendirilsin.

**Kabul:** Saf stdlib testleri + desteklenen OS API testleri gerçek
hedeflerde çalışıyor; desteklenmeyen API'ler açık ve belgeli hata
veriyor.

## 7. Faz M4 --- iOS host: cihaz ve simülatör

**Nox teslimleri**

-   [ ] iOS device ve simulator için Nox AOT static archive üret.
-   [ ] `nox_embed.h` ve doğru mimari slice'ları içeren XCFramework
    üret.
-   [ ] Nox ABI, Objective-C++/Swift tarafından çağrılabilsin; C sembol
    adları kararlı olsun.
-   [ ] iOS'a özgü thread, TLS, clock, entropy, allocator, signal ve
    crash yollarını doğrula.
-   [ ] iOS SDK minimum sürümü ve deployment target kilitlensin.
-   [ ] ARM64 pointer authentication/modern cihaz uyumluluğu,
    gerekiyorsa platform testleriyle değerlendirilsin.

**Aura/host teslimleri (Nox deposunda uygulanmaz)**

-   [ ] UIKit tabanlı `UIApplication` / scene lifecycle kabuğu.
-   [ ] Tek full-screen `UIView`/surface, retina ölçeği, safe area ve
    orientation.
-   [ ] `CADisplayLink` veya eşdeğer frame scheduling; Nox `pump` UI
    thread üzerinde kontrollü.
-   [ ] `UITouch` olaylarını mevcut Aura pointer olaylarına normalize
    etme.
-   [ ] Yazılım klavyesi, `UITextInput`/IME, selection, composition,
    clipboard.
-   [ ] VoiceOver semantics ve erişilebilirlik eylemleri.
-   [ ] App lifecycle: inactive, background, foreground, terminate,
    memory warning.
-   [ ] App icon, launch screen, bundle ID, entitlements, privacy usage
    strings.
-   [ ] `xcodebuild archive`, signing/provisioning, `.xcarchive` ve
    export `.ipa`.
-   [ ] TestFlight upload, crash symbol (`dSYM`) ve App Store
    validation.

**Kabul:** iOS Simulator + en az bir fiziksel iPhone'da Aura counter,
Notes, Chat, Settings ve dosya/HTTP örnekleri çalışır; imzalı IPA
TestFlight'a yüklenebilir.

## 8. Faz M5 --- Android host: APK/AAB

**Nox teslimleri**

-   [ ] NDK `aarch64-linux-android<API>` ve `x86_64-linux-android<API>`
    için doğru native link zinciri.
-   [ ] `libnoxapp.so` ELF, PIC, exported embed ABI ve C++/libc
    bağımlılıkları doğrulansın.
-   [ ] JNI için thread attach/detach, local/global refs, exception
    propagation ve UTF-8 sınırı test edilsin.
-   [ ] Android log, clock, entropy, TLS ve app-private filesystem
    adaptörleri.
-   [ ] 16 KiB page-size uyumluluğu ve bağımlı tüm `.so` dosyalarının
    ELF hizası.
-   [ ] Native crash stack symbolication için unstripped symbols
    saklansın.

**Aura/host teslimleri**

-   [ ] Kotlin `Activity` veya `GameActivity` seçimi ADR ile
    kararlaştırılsın.
-   [ ] Surface lifecycle: create/change/destroy, pause/resume, ekran
    döndürme, process recreation.
-   [ ] `Choreographer` frame pacing; JNI üzerinden Nox pump.
-   [ ] Multi-touch, pointer ID, gesture, density, insets, cutout,
    navigation bar.
-   [ ] IME composition, soft keyboard, selection, clipboard,
    accessibility.
-   [ ] Android permission ve activity result API'leri.
-   [ ] Android manifest, min/target SDK, adaptive icon, splash, deep
    link (gerekirse).
-   [ ] Gradle/AGP, NDK, CMake veya dışarıdan gelen `.so` bağlama
    zinciri.
-   [ ] Debug APK, release signed APK ve Play Store için signed **AAB**.
-   [ ] Android vitals/crash, ProGuard/R8 yalnız Kotlin/Java katmanında,
    native symbols upload.

**Kabul:** Android ARM64 cihaz + x86_64 emülatörde aynı Aura örnekleri;
imzalı APK kuruluyor, AAB Play Console doğrulamasından geçiyor; 16 KiB
uyumluluk testi başarılı.

## 9. Faz M6 --- Aura köprü sözleşmesi (iki depoda ortak)

Aura'nın mevcut `roadmap.md` ve `AGENTS.md` mimarisi değiştirilmez:

``` text
Native OS event
      ↓
Host event queue (timestamp + device + lifecycle)
      ↓
Nox Embed ABI
      ↓
Aura platform poll_events
      ↓
Gesture / focus / state
      ↓
Widget → Element → RenderObject
      ↓
Scene → Skia raster / GPU
      ↓
Native surface
```

-   [ ] Mevcut Aura C sembol kümesi korunacak; mobilde yeni semboller
    eklenirse sürümlemeli ve geriye uyumlu.
-   [ ] Widget kodunda `UIKit`, `JNI`, `Activity`, `UIView` veya
    `extern def` kullanılmayacak.
-   [ ] Input queue ordering, coalescing, timestamp ve frame boundary
    tanımlanacak.
-   [ ] Dokunma/mouse/keyboard farklılıkları host'ta normalize edilecek.
-   [ ] Layout fiziksel piksel yerine mantıksal birimle yapılacak;
    density/scale host'tan gelecek.
-   [ ] Safe area, keyboard inset, orientation, font scale, text
    direction ve accessibility metrikleri sürümlemeli platform event
    olacak.
-   [ ] Skia raster yüzeyi 1.1--1.4 için mevcut Aura planına uygun
    kullanılacak.
-   [ ] GPU renderer 1.5'te ADR ile seçilecek; iOS Metal, Android
    Vulkan/OpenGL ES olasılıkları platform desteği, Skia sürümü ve
    performans kanıtıyla değerlendirilecek.
-   [ ] Frame başına yeniden çizim, görüntü belleği, büyük görsel, font
    atlası ve GPU resource cleanup ölçülecek.
-   [ ] Mobil text shaping, emoji ve RTL mevcut Aura 1.0 kapsamı
    dışında; **tam iki ekosistem desteği** hedefleniyorsa bunlar için
    ayrıca açık teslim kapısı oluşturulacak.
-   [ ] VoiceOver/TalkBack semantik ağacı, eylem, odak, dynamic type ve
    screen reader sırası test edilecek.
-   [ ] Native view embedding (`PlatformView`) varsa z-order, touch hit
    testing, clip ve lifecycle mobilde ayrıca doğrulanacak.

**Kabul:** Tek `.nox` uygulama kodu, platforma özel widget dalı olmadan
iOS ve Android'de aynı işlevsel testleri geçer.

## 10. Faz M7 --- Uygulama üretimi ve geliştirici deneyimi

Nox'un işi native artefact üretmektir; Aura CLI/packager bunu tam mobil
uygulamaya dönüştürür. Aşağıdaki komutlar **hedef taslaktır**, mevcut
komut olarak sunulmaz.

``` bash
# Nox katmanı — önerilen arayüz
noxc build --target ios-arm64 --emit-static-lib -o build/ios/libnoxapp.a app.nox
noxc build --target ios-simulator-arm64 --emit-static-lib -o build/ios-sim/libnoxapp.a app.nox
noxc build --target android-arm64 --emit-shared-lib -o build/android/arm64-v8a/libnoxapp.so app.nox

# Aura katmanı — önerilen arayüz
aura create --platforms ios,android my_app
aura run --device ios-simulator
aura run --device android-emulator
aura build ios --configuration release
aura build android --format apk --configuration release
aura build android --format aab --configuration release
```

-   [ ] Nox target/output CLI sözdizimi testle sabitlensin.
-   [ ] Aura proje manifesti: app ID, display name, version/build
    number, min OS, orientation, icon, permissions, entitlements,
    assets, signing config.
-   [ ] `aura doctor`: Xcode, SDK, NDK, JDK, Gradle, Zig, Clang, Skia,
    signing varlığını raporlasın.
-   [ ] `aura create`: reproducible iOS Xcode ve Android Gradle proje
    iskeleti.
-   [ ] `aura run`: simulator/emulator/device seçimi, build, install,
    launch, log.
-   [ ] `aura build`: native Nox library + Skia + host + assets +
    signing.
-   [ ] Apple cihaz/simülatör binary'leri doğru XCFramework slice'ından
    seçilsin.
-   [ ] Android APK debug, release APK ve AAB ayrı test edilsin.
-   [ ] Asset pipeline: fonts, PNG/JPEG, raster/Skia resource, locale,
    shader, boyut/ölçek.
-   [ ] Reproducible build: pinli toolchain, deterministic metadata
    mümkün olduğu ölçüde, artifact hash ve SBOM.
-   [ ] Signing secret'ları repoya yazılmasın; CI secret yönetimi ve
    yerel keychain/keystore kullanılsın.
-   [ ] iOS `dSYM`, Android unstripped symbols ve source map/line
    mapping saklansın.
-   [ ] Hata çıktıları geliştiriciye hangi katmanın başarısız olduğunu
    söylesin: Nox compiler / native link / Aura host / signing / store.
-   [ ] İlk aşamada hot reload vaat edilmesin; hızlı incremental native
    rebuild ve test döngüsü sağlansın.

## 11. Faz M8 --- Üretim kalitesi, güvenlik ve mağaza hazırlığı

### 11.1 Fonksiyonel kapsama

-   [ ] Startup, cold/warm launch, arka plandan dönüş, zorla kapatma,
    uygulama güncellemesi.
-   [ ] Offline/online geçiş, TLS başarısızlığı, izin reddi, düşük
    depolama, düşük bellek.
-   [ ] Karanlık/açık tema, font büyütme, farklı ekran boyutu, çentik,
    tablet, döndürme.
-   [ ] IME Türkçe/İngilizce, kompozisyon, emoji, RTL (hedefleniyorsa)
    ve selection.
-   [ ] Erişilebilirlik: VoiceOver/TalkBack, switch control, büyük yazı,
    kontrast.
-   [ ] 60/90/120 Hz frame pacing, ağır scroll, metin, animasyon,
    resize/rotation.
-   [ ] Background/resume sonrası network, timer ve worker davranışı.
-   [ ] Kamera/konum/bildirim gibi platform API'leri **opsiyonel
    eklenti** olarak test edilsin; çekirdek mobil desteğin koşulsuz
    gereği yapılmasın.
-   [ ] Deep link, push notification, in-app purchase, background fetch
    gibi servisler çekirdek 1.0 dışında ise açık destek tablosunda
    `not supported` yazsın; "tam" iddiasında belirsiz bırakılmasın.

### 11.2 Güvenlik

-   [ ] Tüm C/JNI/Swift sınırlarında length, null, ownership, ABI
    version, callback ömrü doğrulansın.
-   [ ] iOS code signing, entitlements ve ATS; Android signing, manifest
    izinleri, network security config.
-   [ ] Üçüncü taraf native paketler, Skia ve font lisansları; SBOM ve
    güvenlik güncelleme politikası.
-   [ ] Keychain/Keystore anahtarları Nox heap dump/log içine
    taşınmasın.
-   [ ] Release build'de debug endpoint, aşırı log, development
    certificate kalmasın.
-   [ ] App Store/Play politikaları ve SDK/target gereksinimleri **her
    release öncesi yeniden doğrulansın**.

### 11.3 Performans hedefleri

Aşağıdakiler **önerilen ilk bütçelerdir**; cihaz sınıfı seçilip baseline
ölçülmeden garanti sayılmaz.

  -----------------------------------------------------------------------
  Metrik                  İlk hedef               Ölçüm
  ----------------------- ----------------------- -----------------------
  UI frame                60 Hz'de 16,67 ms altı  P50/P95/P99
                          hedef                   

  120 Hz                  8,33 ms bütçe,          P50/P95/P99
                          desteklenen cihazda     

  Cold start              Referans cihaza göre    Gerçek cihaz
                          baseline + regresyon    
                          sınırı                  

  Peak RSS                Bellek baskısında OOM   Instruments / Android
                          olmadan                 profiler

  Native crash            Sıfır bilinen tekrar    E2E + crash telemetry
                          üretilebilir crash      

  Binary size             Versiyon başına ölçüm   IPA/APK/AAB boyutları
                          ve artış gerekçesi      

  Energy                  Boşta gereksiz sürekli  Energy profiler
                          frame üretmemek         
  -----------------------------------------------------------------------

## 12. Faz M9 --- CI, cihaz laboratuvarı ve yayın kapıları

### 12.1 Nox CI matrisi

  -----------------------------------------------------------------------
  Test              macOS host        Linux host        Gereken gerçek
                                                        ortam
  ----------------- ----------------- ----------------- -----------------
  iOS device        Evet              Opsiyonel, SDK    macOS/Xcode link
  cross-compile                       lisans koşullu    ve sign

  iOS simulator run Evet              Hayır             macOS runner +
                                                        Simulator

  iOS fiziksel      Özel runner/lab   Hayır             İmzalı fiziksel
  cihaz                                                 cihaz

  Android arm64     Evet              Evet              NDK
  build                                                 

  Android x86_64    Opsiyonel         Evet              Android Emulator
  emulator                                              

  Android ARM64     Lab               Lab               Fiziksel cihaz
  device                                                

  16 KiB page-size  Evet              Evet              Uyumlu
                                                        emulator/device

  Masaüstü          Evet              Evet + Windows    Var olan CI
  regresyon                                             
  -----------------------------------------------------------------------

-   [ ] Pull request: static analysis + cross-compile + host ABI +
    simulator/emulator smoke.
-   [ ] Nightly: full Nox stdlib, memory sanitizer, stress, lifecycle ve
    Aura E2E.
-   [ ] Release candidate: imzalı iOS IPA/TestFlight ve Android
    APK/AAB/Play internal testing.
-   [ ] Apple signing secret'ları fork PR'larında erişilebilir
    olmayacak.
-   [ ] Android emulator boot ve iOS simulator boot watchdog/cleanup ile
    yönetilecek.
-   [ ] CI job'ları kritik hatalarda `|| true` ile yeşile zorlanmayacak.
-   [ ] Test sonuçları target, backend, compiler commit, Aura commit,
    SDK/NDK, cihaz OS sürümüyle ilişkilendirilecek.
-   [ ] Nox sürüm değiştiğinde Aura karşılıklı uyumluluk testi otomatik
    tetiklenecek.
-   [ ] Sürüm için gereken kanıtlar ve artifact hash'leri
    `mobile-evidence/` veya eşdeğer yerde tutulacak.

### 12.2 Zorunlu golden / integration test korpusu

-   [ ] `mobile_abi_primitives`: int/float/bool/struct return/callback.
-   [ ] `mobile_string_utf8`: Türkçe, Unicode, NUL içeren buffer,
    invalid UTF-8 reddi.
-   [ ] `mobile_arc_lifecycle`: nesne/collection allocate-release ve
    cycle.
-   [ ] `mobile_exception_boundary`: exception C/JNI sınırını geçmeden
    hata olarak dönüyor.
-   [ ] `mobile_async_fibers`: scheduler ve UI thread bloklamama.
-   [ ] `mobile_fs_sandbox`: documents/cache/tmp + izin reddi.
-   [ ] `mobile_network_tls`: HTTPS, DNS, IPv6, offline, timeout.
-   [ ] `mobile_lifecycle`: cold/warm, background/foreground,
    orientation.
-   [ ] `mobile_memory_pressure`: cache temizleme, teardown.
-   [ ] `mobile_aura_counter`: dokunma → state → render.
-   [ ] `mobile_aura_notes`: IME → selection → clipboard.
-   [ ] `mobile_aura_chat`: virtual list + keyboard inset + 10.000
    satır.
-   [ ] `mobile_accessibility`: VoiceOver/TalkBack semantic
    labels/actions.
-   [ ] `mobile_packaging`: signed IPA ve signed APK/AAB doğrulaması.
-   [ ] `mobile_page16k`: Android ELF alignment ve runtime açılışı.

## 13. Faz M10 --- Sürümleme ve kabul kapıları

  -----------------------------------------------------------------------
  Milestone               Ad                      Çıkış koşulu
  ----------------------- ----------------------- -----------------------
  **M0**                  Tasarım dondurma        ADR + baseline + target
                                                  matrix

  **M1**                  AOT mobile object       iOS device/sim +
                                                  Android arm64/x64
                                                  gerçek ABI smoke

  **M2**                  Embedded runtime        Host C ABI +
                                                  lifecycle +
                                                  bellek/exception
                                                  testleri

  **M3**                  Mobile stdlib           Desteklenen capability
                                                  testleri yeşil

  **M4**                  iOS preview             Simulator + fiziksel
                                                  cihaz + Aura
                                                  counter/Notes

  **M5**                  Android preview         Emulator + fiziksel
                                                  cihaz + Aura
                                                  counter/Notes

  **M6**                  Aura parity             Aynı Nox UI koduyla iki
                                                  platformda
                                                  Chat/Settings/input

  **M7**                  Packaging               Signed IPA + APK + AAB,
                                                  test dağıtımı

  **M8**                  Release candidate       Security,
                                                  accessibility,
                                                  performance, lifecycle,
                                                  CI

  **M9**                  Stable mobile           Belgeli destek
                                                  matrisi + store
                                                  dağıtımı + regresyon
                                                  kapısı
  -----------------------------------------------------------------------

**Milestone kuralı:** Bir sonraki aşamaya geçmek için önceki aşamanın
zorunlu testleri geçmeli. Mobil destek Nox 2.1'e zorla sıkıştırılmamalı;
2.1'e ancak açıkça `experimental` olarak ve bağımsız CI ile alınabilir.

## 14. Önerilen geliştirme sırası ve bağımlılıklar

``` text
M0 ADR / envanter
   |
   v
M1 cross-target object + SDK/NDK link
   |
   v
M2 embed ABI + runtime lifecycle
   |
   +--------> M3 mobile stdlib/capability
   |                    |
   v                    |
M4 iOS host             |
   |                    |
   +----> M6 Aura parity <---- M5 Android host
                |
                v
        M7 packaging/signing
                |
                v
        M8 quality/store gates
                |
                v
          M9 stable mobile
```

**Kritik yol:** Target registry → platform runtime → embed ABI → iOS
cihaz + Android cihazda çalıştırma → Aura host → signed artifacts.

**İlk teknik spike (en düşük riskli başlangıç):** 1. iOS simulator için
Nox kaynak → `.o` → `.a` → Swift host'tan çağrı. 2. Android x86_64
emulator için Nox kaynak → `.o` → `.so` → JNI çağrısı. 3. Sonra iOS
device ve Android arm64. 4. Ardından `nox_app_create/start/pump/destroy`
ve Aura counter.

Bu sırada GUI olmadan native çağrı kanıtlanır; ilk engelin codegen, link
veya runtime olduğu netleşir.

## 15. Risk kayıt defteri

  -----------------------------------------------------------------------
  Risk                    Etki                    Azaltma / kapı
  ----------------------- ----------------------- -----------------------
  QBE Apple/Android ABI   Sessiz yanlış kod       LLVM-first, ABI
  farkları                                        fixture, QBE ayrı
                                                  sertifika

  iOS runtime dinamik     App Store reddi / crash AOT static link,
  plugin/JIT varsayımı                            packaged native modules

  Android Bionic ≠ glibc  Link/runtime hatası     NDK sysroot ve cihaz
                                                  testleri

  Android 16 KiB page     Yeni cihazda açılmama   ELF align + gerçek 16
                                                  KiB test

  Fiber assembly/TLS      Nadir bellek bozulması  Sanitizer, stress,
                                                  lifecycle test

  C ABI ownership         UAF/double free         Opaque handles,
                                                  retain/release
                                                  sözleşmesi

  UI thread bloklama      Takılma / ANR           Pump budget, async
                                                  worker ve frame ölçümü

  iOS background          Suspend sonrası hatalar OS lifecycle politikası
  sınırları                                       

  Skia ve native          Büyük APK/IPA           Artifact size bütçesi,
  bağımlılık boyutu                               sembol stripping

  IME/Unicode/RTL         Kullanılamaz metin      Gerçek cihaz ve dil
                          girişi                  matrisi

  Code signing / store    Yayın yapılamaması      Erken TestFlight/Play
  policy                                          internal denemesi

  Aura/Nox sürüm kayması  Sessiz ABI uyumsuzluğu  Karşılıklı pin ve
                                                  integration CI

  Masaüstü regresyon      Var olan ürün kırılması Üç masaüstü CI sürekli
                                                  zorunlu
  -----------------------------------------------------------------------

## 16. Definition of Done --- "Nox mobilde tam çalışıyor" demek için

Aşağıdaki maddelerin **tamamı** sağlanmadan `mobile stable` ilan
edilmez:

-   [ ] Nox aynı kaynak kodu hedefe uygun AOT native kütüphane olarak
    derliyor.
-   [ ] iOS cihaz, iOS simülatör, Android ARM64 cihaz ve Android x86_64
    emülatör destek matrisi testli.
-   [ ] Mobil runtime: memory, exception, thread, async, TLS, clock,
    entropy, temel stdlib testli.
-   [ ] Embed ABI sürümlü, belgeli, lifecycle ve ownership testleri
    yeşil.
-   [ ] iOS ve Android'de Aura aynı widget/render kodunu kullanıyor;
    platform-specific UI kodu widget katmanında yok.
-   [ ] Touch, IME, clipboard, safe area, orientation, lifecycle ve
    accessibility testli.
-   [ ] Sandbox filesystem, HTTPS/TLS, SQLite ve log/crash tanılaması
    çalışıyor.
-   [ ] Signed IPA TestFlight doğrulamasından, signed AAB Play internal
    test doğrulamasından geçmiş.
-   [ ] Debug APK, release APK, AAB ve IPA üretimi tekrar edilebilir;
    paketlerde doğru ABI/symbol/asset var.
-   [ ] Android 16 KiB uyumluluğu kanıtlanmış.
-   [ ] Nox + Aura sürüm pinleri ve otomatik entegrasyon CI mevcut.
-   [ ] macOS/Windows/Linux masaüstü testleri bozulmamış.
-   [ ] Belirlenmiş referans cihazlarda performans, enerji, bellek ve
    crash kabul sınırları geçmiş.
-   [ ] Desteklenmeyen mobil özellikler açıkça belgelenmiş; sessiz no-op
    veya yanlış "tam destek" iddiası yok.
-   [ ] Güvenlik, üçüncü taraf lisansları, mağaza izinleri ve güncel
    platform gereksinimleri denetlenmiş.

## 17. Kodlama ajanına uygulama talimatı

Bu belgeyi uygulayan Cursor/AI ajanı:

1.  Önce Nox `AGENTS.md`, Aura `AGENTS.md`, ilgili ADR'ler ve bu planı
    okusun.
2.  Yalnız sıradaki tamamlanmamış milestone üzerinde çalışsın;
    tamamlandı işareti ancak test kanıtıyla konulsun.
3.  Her değişiklikte **değişen dosyalar**, **neden**, **platform**,
    **test komutları**, **gerçek test sonucu**, **bilinen sınırlamalar**
    raporlansın.
4.  Hedef triple, toolchain, library path, ABI veya Nox syntax'ını
    uydurmasın; kaynak ve SDK ile doğrulasın.
5.  Aura deposuna Nox compiler workaround'ı eklemesin; compiler eksiğini
    Nox issue/ADR olarak kaydetsin.
6.  Masaüstü regresyonu görmezden gelmesin. Başarısız testi `skip`,
    `continue-on-error`, `|| true` ile örtmesin.
7.  Her hedef için build-only, simulator/emulator ve gerçek cihaz
    kanıtlarını birbirinden ayırsın.
8.  CI'da olmayan bir platformu `supported` ilan etmesin.
9.  Güvenlik ve ownership sınırları netleşmeden public API'yi
    dondurmasın.
10. Sonraki milestone'a geçmeden önce eksik maddeleri ve blokajları
    kullanıcıya raporlasın.

## 18. Resmî kaynaklar ve repo referansları

### Nox / Aura

-   [Nox compiler target
    registry](https://github.com/mburakmmm/nox-lang/blob/main/compiler/qbe_target.zig)
-   [Nox compiler
    CLI](https://github.com/mburakmmm/nox-lang/blob/main/docs/tools/noxc.md)
-   [Nox freestanding
    profile](https://github.com/mburakmmm/nox-lang/blob/main/docs/tools/freestanding.md)
-   [Nox stdlib capability
    matrix](https://github.com/mburakmmm/nox-lang/blob/main/docs/stdlib/index.md)
-   [Nox NNI
    v1](https://github.com/mburakmmm/nox-lang/blob/main/docs/apis/nni.md)
-   [Aura
    roadmap](https://github.com/mburakmmm/aura/blob/main/roadmap.md)
-   [Aura AGENTS](https://github.com/mburakmmm/aura/blob/main/AGENTS.md)
-   [Aura README](https://github.com/mburakmmm/aura/blob/main/README.md)

### Platform belgeleri

-   [Apple --- XCFramework
    creation](https://developer.apple.com/documentation/xcode/creating-a-multi-platform-binary-framework-bundle)
-   [Apple --- Preparing apps for
    distribution](https://developer.apple.com/documentation/xcode/preparing-your-app-for-distribution)
-   [Apple --- Distributing for beta and
    release](https://developer.apple.com/documentation/xcode/distributing-your-app-for-beta-testing-and-releases)
-   [Android NDK --- Build System Maintainers
    Guide](https://android.googlesource.com/platform/ndk/+/master/docs/BuildSystemMaintainers.md)

> **Güncellik notu:** Android target API ve 16 KiB politikası, Apple
> minimum SDK/Xcode gereksinimi, App Store/Google Play kuralları zamanla
> değişir. Her release öncesi resmî kaynaklar yeniden kontrol
> edilmelidir.

------------------------------------------------------------------------

**Planın nihai amacı:** Nox'un mobilde yalnızca native kod
çalıştırabilmesi değil; Aura'nın mevcut masaüstü mimarisini bozmadan,
aynı `.nox` uygulamasından cihazda çalışan, erişilebilir, güvenli,
performanslı ve mağazalara dağıtılabilir iOS/Android uygulamaları
üretebilmesidir.
