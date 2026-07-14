# Değişiklik Günlüğü (Changelog)

Bu proje henüz **v0.1 (taslak)** aşamasındadır — semver garantisi henüz YOK
(bkz. `docs/uretim-hazirlik-analizi.md`, Faz Z). Bu dosya, Faz Q'dan
(temel sağlamlaştırma) itibaren yapılan değişiklikleri özetler; öncesi
için `nox-teknik-spesifikasyon.md`'nin tam geliştirme geçmişine bakın.

## [Yayımlanmamış]

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

### Düzeltildi
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

### Güvenlik
- `nox.http.serve`e iki DoS sertleştirmesi eklendi (Faz Q.5): bir isteğin
  gövdesi artık 10 MiB ile sınırlı (aşılırsa `413 Payload Too Large`,
  handler hiç çağrılmaz) ve eşzamanlı bağlantı sayısı artık 4096 ile
  sınırlı (aşan bağlantılar `receiveHead`e ulaşmadan sessizce kapatılır).
  Bilinen kalan sınırlama: okuma zaman aşımı (slowloris koruması) henüz
  yok — reaktöre zamanlayıcı desteği eklenene kadar ertelendi.
