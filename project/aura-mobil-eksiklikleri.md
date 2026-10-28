# Aura mobil eksiklikleri — Nox'tan devir belgesi

> **Durum tarihi:** 25 Ekim 2026  
> **İncelenen Aura commit'i:** `ad1f9b5` (`v1.0.0`)  
> **Amaç:** Aura tarafında yapılması gereken mobil işleri Nox backlog'undan
> ayırmak. Bu belge Aura geliştiricisine verilmek içindir; Nox ajanı Aura
> uygulama kodunu sahiplenmez.

## Mevcut durum

Nox tarafında dört deneysel mobil kütüphane hedefi ve `nox_embed.h` vardır:

- `ios-arm64`
- `ios-simulator-arm64`
- `android-arm64`
- `android-x64`

Mevcut kanıta göre Aura `proof`, `notes` ve `chat` kaynakları iOS
simülatöründe ve Android ARM64 emülatöründe açılmıştır. VoiceOver/TalkBack
etiketleri, lifecycle dönüşü, Android memory-pressure olayı ve yatay yeniden
boyutlandırma için sınırlı kanıt vardır.

Ancak Aura mobil uygulaması henüz yayınlanmış/izlenen kaynak değildir. Şu
dosya ve dizinler yerel checkout'ta **untracked** durumdadır:

- `aura/platform/android.nox`
- `aura/platform/ios.nox`
- `examples/mobile/`
- `native/android/`
- `native/ios/`
- `native/mobile/`
- `scripts/build_android_app.sh`
- `scripts/build_ios_app.sh`
- `scripts/check_mobile_contract.sh`
- `scripts/fetch_skia_deps.sh`

Bu dosyalar kaybedilmemeli; fakat gözden geçirilmeden topluca commit
edilmemelidir.

## A0 — Repo ve mimari kapısı

- [x] Untracked mobil çalışmayı ayrı branch/worktree'de güvenceye al. (2026-10-28: Aura deposunda `mobile-sources` dalı, commit `2cb8177`; `main` ve çalışma ağacı dokunulmadı, itilmedi.)
- [x] Her dosyayı kaynak, üretilmiş artifact veya yerel ortam girdisi olarak
  sınıflandır; yalnız gerçek kaynakları izle. (18 dosya, ~130 KB, hepsi metin kaynağı: c/m/h/java/xml/md/sh/nox; ikili veya üretilmiş dosya yok. Yerel yol varsayılanı yalnız `scripts/build_*_app.sh` içinde: `NOX_ROOT` ve NDK sürümü — A0 5. maddesi açık.)
- [ ] Aura `AGENTS.md` invariant'larını mobil kod üzerinde denetle:
  Widget ≠ Element ≠ RenderObject; platform katmanı widget import etmez;
  olaylar kuyruktan akar.
- [ ] Mobil mimari ADR'lerini oluştur: iOS host, Android host, Skia raster,
  GPU seçimi, lifecycle/input, accessibility ve packaging/signing.
- [ ] Sabit yerel yolları (`NOX_ROOT`, SDK, NDK, Skia checkout) manifest veya
  `aura doctor` çözümüne taşı.
- [ ] `scripts/check_mobile_contract.sh` ve native event testlerini CI'a ekle.

**Çıkış:** Mobil kaynak izleniyor, mimari sınırlar testli, yerel makine yolu
source contract değil.

## A1 — iOS preview

- [ ] Simulator'da Counter, Notes, Chat ve Settings aynı Nox kaynaklarıyla
  otomatik smoke/self-check geçsin.
- [ ] Fiziksel iPhone'da `ios-arm64` Nox/Aura binary'si çalıştırılsın;
  build-only kanıt yeterli sayılmasın.
- [ ] UIKit scene lifecycle: inactive/background/foreground/terminate ve
  memory warning olay kuyruğundan geçsin.
- [ ] Touch, gesture yarışması, safe area, retina scale ve orientation gerçek
  cihazda doğrulansın.
- [ ] `UITextInput`: composition, commit, selection, delete, Türkçe/İngilizce
  ve emoji girişi test edilsin.
- [ ] Clipboard ve keyboard inset Notes/Chat testine bağlansın.
- [ ] VoiceOver semantics: rol, etiket, değer, selected, bounds, focus sırası
  ve activate action doğrulansın.
- [ ] App icon, launch screen, bundle ID, entitlements ve privacy strings
  manifestten üretilebilsin.
- [ ] Release archive, dSYM, signed IPA ve TestFlight validation tamamlanıp
  artifact hash'i kaydedilsin.

**Çıkış:** Simulator + fiziksel cihaz; signed IPA; TestFlight internal test.

## A2 — Android preview

- [ ] Android x86_64 çıktısı yalnız link edilmek yerine emülatörde çalışsın.
- [ ] Android ARM64 fiziksel cihaz testi eklensin.
- [ ] Surface create/change/destroy, pause/resume ve process recreation
  davranışı doğrulansın.
- [ ] Choreographer frame pacing Nox `pump` çağrısını UI thread bütçesi içinde
  tutsun.
- [ ] Multi-touch, pointer ID, gesture, density, insets, cutout ve navigation
  bar normalize edilsin.
- [ ] IME composition, selection, clipboard ve keyboard inset Notes/Chat
  testine bağlansın.
- [ ] TalkBack semantic ağacı ve eylemleri doğrulansın.
- [ ] JNI attach/detach, local/global refs, UTF-8, exception ve callback ömrü
  sanitizer/stres testi taşısın.
- [ ] Bütün native `.so` dosyaları 16 KiB uyumlu olsun ve uyumlu cihaz veya
  emülatörde açılış kanıtı bulunsun.
- [ ] Debug APK dışında release signed APK ve signed AAB üret.
- [ ] Native symbols, R8/ProGuard ayrımı ve crash symbolication sağla.
- [ ] AAB'yi Play internal testing doğrulamasından geçir.

**Çıkış:** x64 emulator + ARM64 fiziksel cihaz; signed APK/AAB; Play internal.

## A3 — Ortak Aura mobil sözleşmesi

- [ ] Counter, Notes, Chat ve Settings platform dalı olmadan aynı widget
  kaynaklarını kullansın.
- [ ] Widget/example `.nox` dosyalarında UIKit, JNI, Activity, UIView veya
  doğrudan `extern def` olmadığını CI denetlesin.
- [ ] Input queue ordering, timestamp, coalescing ve frame boundary yazılı ve
  testli olsun.
- [ ] Logical pixels, scale, safe area, orientation, font scale ve keyboard
  inset aynı sürümlü event sözleşmesini kullansın.
- [ ] Background/resume sırasında timer, network, animation ve pending input
  davranışı deterministik olsun.
- [ ] 10.000 satırlı Chat döndürme/keyboard/resume sonrası sanal kalmaya devam
  etsin.
- [ ] Memory pressure kaynakları/cache'leri bırakıp sonraki frame'de güvenli
  yeniden oluştursun.

## A4 — Çizim, metin ve erişilebilirlik

- [ ] Raster Skia yolunda resource cleanup, büyük görsel, font atlası ve frame
  başına yeniden çizim ölçülsün.
- [!] GPU backend için ADR yaz: iOS Metal ve Android Vulkan/OpenGL ES. Kanıt
  olmadan raster yol kaldırılmasın.
- [ ] 60/90/120 Hz frame pacing için P50/P95/P99 ölçümü ve referans cihaz
  bütçeleri oluştur.
- [ ] Text shaping, emoji ve RTL ya uygulanıp test edilsin ya da destek
  matrisinde açıkça `not supported` olarak kalsın.
- [ ] Dynamic type/font scale, kontrast, switch control ve screen-reader focus
  sırası test edilsin.
- [ ] PlatformView planlanıyorsa z-order, clipping, hit testing ve lifecycle
  için ayrı ADR/kapı oluştur.

## A5 — Aura CLI ve paketleme

- [ ] `aura doctor`: Nox, Xcode, SDK, NDK, JDK, Gradle, Zig, Clang, Skia,
  emulator/simulator ve signing durumunu raporlasın.
- [ ] `aura create --platforms ios,android`: reproducible Xcode/Gradle proje
  iskeleti üretsin.
- [ ] `aura run`: simulator/emulator/device seçimi, build, install, launch ve
  log akışını yönetsin.
- [ ] `aura build ios`: Nox static library + host + Skia + assets + signing.
- [ ] `aura build android --format apk|aab`: doğru ABI seti, assets ve signing.
- [ ] Uygulama manifesti app ID, display name, version/build, min OS/SDK,
  orientation, permissions, entitlements, icons ve assets taşısın.
- [ ] Font, PNG/JPEG, locale ve shader asset pipeline'ı deterministic olsun.
- [ ] Toolchain sürümleri pinlensin; artifact SHA-256 ve SBOM üretilebilsin.
- [ ] Signing secret'ları repoya veya build çıktısına yazılmasın.
- [ ] Hata mesajı arızayı Nox compiler/native link/Aura host/signing/store
  katmanlarından doğru olana bağlasın.

## A6 — CI, kalite ve yayın kapıları

- [ ] PR: contract test + native unit test + iOS simulator + Android x64
  emulator smoke.
- [ ] Nightly: Counter/Notes/Chat/Settings, lifecycle, memory pressure,
  accessibility ve performans.
- [ ] Release candidate: fiziksel iOS/Android cihaz, signed IPA/APK/AAB,
  TestFlight ve Play internal.
- [ ] Nox sürümü değiştiğinde pinli Aura uyumluluk işi otomatik tetiklensin.
- [ ] Her kanıt Nox commit'i, Aura commit'i, SDK/NDK, cihaz/OS, backend,
  artifact hash ve gerçek run/build ayrımını taşısın.
- [ ] Emulator/simulator watchdog ve cleanup başarısızlığı gizlemesin;
  `|| true` ile yeşile zorlanmasın.
- [ ] Cold/warm startup, offline/online, düşük depolama/bellek, rotation,
  tablet, dark/light theme ve uygulama güncellemesi test edilsin.
- [ ] App Store/Play gereksinimleri her release öncesinde güncel resmî
  belgelerden doğrulansın.

## Aura mobil temel Definition of Done

- [ ] Aynı Nox widget kodu iOS ve Android'de çalışıyor.
- [ ] iOS simulator + fiziksel iPhone testli.
- [ ] Android x64 emulator + ARM64 fiziksel cihaz testli.
- [ ] Touch, gesture, IME, clipboard, safe area/insets, orientation,
  lifecycle ve accessibility testli.
- [ ] Counter, Notes, Chat ve Settings iki platformda aynı kabul testlerini
  geçiyor.
- [ ] Signed IPA TestFlight'ta; signed AAB Play internal'da doğrulandı.
- [ ] Debug/release APK, AAB ve IPA tekrar üretilebilir.
- [ ] 16 KiB Android page-size çalışma anında kanıtlandı.
- [ ] Crash symbols, SBOM, lisanslar ve artifact hash'leri saklandı.
- [ ] Performans, bellek, enerji ve bilinen crash bütçeleri geçti.
- [ ] Desteklenmeyen özellikler açıkça belgeli; sessiz no-op yok.

## Nox ile koordinasyon sınırı

- Aura, Nox derleyicisini kendi deposunda yamalamaz.
- Nox eksiği bulunursa küçük reproducer ve beklenen davranışla Nox backlog'una
  taşınır.
- Aura yalnız public/sürümlü `nox_embed.h` ve belgelenmiş Nox mobil target
  sözleşmesini kullanır.
- Nox `supported` demeden Aura kendi paketini “Nox mobile stable” olarak
  sunmaz.

