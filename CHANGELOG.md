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
