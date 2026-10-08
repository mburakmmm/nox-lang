# Nox — Üretim Hazırlık Analizi ve MVP Sonrası Yol Haritası

**Tarih:** 13 Temmuz 2026
**Kapsam:** Derleyici (`compiler/`), çalışma zamanı (`runtime/`), standart kütüphane (`stdlib/`), CLI+paket sistemi (Faz O), araç zinciri ve süreç olgunluğu.
**Yöntem:** Üç paralel, bağımsız kod incelemesi (dil/derleyici tamamlanmışlığı; çalışma zamanı+güvenlik+altyapı; araç ekosistemi+dokümantasyon), bulgular çapraz kontrol edilip tek bir önceliklendirilmiş envanterde birleştirildi.

---

## 0. Yönetici Özeti

Nox, ~125 tamamlanmış geliştirme fazı sonucunda **mimari olarak son derece derin ve iç tutarlı** bir dil: gerçek bir sahiplik/ARC modeli, monomorphization tabanlı generics, yapısal protokoller, fiber tabanlı async/await, gerçek bir `nox.http` istemci+sunucusu, git tabanlı merkeziyetsiz bir paket yöneticisi ve dikkatle ölçülmüş bir performans profili (C'nin ~1-4 katı yavaş, Python'dan 7-122 kat hızlı) var. Bu, "oyuncak dil" seviyesinin çok ötesinde bir mühendislik olgunluğu.

Ama **"üretime çıkarma" sorusu farklı bir eksen** — ve oradan bakıldığında proje hâlâ net bir şekilde **v0.1/mimari-tasarım-aşaması**:

- **Sıfır CI, sıfır git commit'i, sıfır dağıtım paketi.** Bugün `noxc`'ye ulaşmanın tek yolu depoyu klonlayıp `zig build` çalıştırmak.
- **Eşzamansızlık/HTTP çalışma zamanı yalnızca aarch64 macOS'ta ÇALIŞIYOR** — `fiber.zig`'deki `comptime` kapısı x86-64/Linux hedeflerinde **derlemeyi doğrudan reddediyor**. Bu "test edilmedi" değil, "yapısal olarak imkânsız."
- **Sistem geneli kurulum bugün ÇALIŞMIYOR** — doğru çözüm zaten yazılmış (`project.resolveResourceDirs`) ama `main.zig`'e hiç BAĞLANMAMIŞ; linkleme hâlâ CWD'ye göre sabit `zig-out/lib/noxrt.o` yolunu kullanıyor.
- **HTTP sunucusunun sıfır DoS koruması var** (zaman aşımı yok, boyut sınırı yok, bağlantı sınırı yok) — bir slowloris saldırısıyla trivially devre dışı bırakılabilir.
- **Kullanıcıya dönük SIFIR dokümantasyon** — README yok, LICENSE yok, örnek program yok, İngilizce (ya da herhangi bir) kullanıcı rehberi yok. Var olan iki belge (AGENTS.md, spec) tamamen Türkçe ve derleyici katkıcıları/AI ajanları için yazılmış.
- **Bellek güvenliği tamamlanmadı** — döngü çözücü (Katman 3) hiç yazılmadı; şu an döngüler yalnızca *tesadüfen* (sınıf alanlarının ileri-referans edememesi yüzünden) imkânsız, kalıcı bir garanti değil.

**Sonuç:** Nox bir "dili nasıl inşa edersin" alıştırması olarak zaten bitmiş sayılır; "gerçek kullanıcılara güvenle verilebilir bir ürün" olarak ise **platform desteği, güvenlik sertleştirmesi, dağıtım/CI ve dokümantasyon** dört ayrı, ciddi yatırım gerektiren cephe var. Aşağıdaki yol haritası bunları önceliklendirir.

---

## 1. Kritik Boşluklar (Bulgu Envanteri)

Aşağıdaki tablo üç araştırmanın TÜM bulgularını, etki/aciliyet sırasına göre gruplar.

### 1.1 🔴 P0 — Gerçek kullanımı ENGELLEYEN (herhangi bir "üretim" iddiasından ÖNCE çözülmeli)

| # | Boşluk | Kanıt | Neden P0 |
|---|---|---|---|
| 1 | **Sıfır CI/CD, sıfır git commit'i** | `git log` → "henüz bir işleme yok"; `.github/workflows/` yok | Hiçbir değişiklik otomatik doğrulanmıyor; katkıcı/ekip büyüdüğünde regresyon riski YÖNETİLEMEZ |
| 2 | **Sistem geneli kurulum ÇALIŞMIYOR** | `main.zig`, `resolveResourceDirs`'i HİÇ çağırmıyor; linkleme hâlâ CWD-göreli `"zig-out/lib/noxrt.o"` sabit dizgesi kullanıyor (main.zig:439,476) | `noxc`'yi `/opt/homebrew/bin`'e kurup HERHANGİ bir yerden çalıştırmak BUGÜN mümkün değil — dağıtımın ÖN KOŞULU |
| 3 | **Async/HTTP çalışma zamanı yalnızca aarch64** | `fiber.zig:15-18`: `@compileError` niyetle x86-64/diğer mimarilerde DERLEMEYİ REDDEDİYOR; I/O reaktörü yalnızca kqueue (macOS) | Linux sunucularında (bulut/CI'nin ezici çoğunluğu) `nox.http`/`spawn`/`Channel` KULLANILAMAZ |
| 4 | **HTTP sunucusunda SIFIR DoS koruması** | `http_server.zig`: zaman aşımı yok, `max_connections` sınırsız, body/header boyut sınırı yok | Herhangi bir `nox.http.serve` uygulaması trivially slowloris/bellek-tükenmesi saldırısına AÇIK |
| 5 | **Kullanıcıya dönük dokümantasyon SIFIR** | README/LICENSE/CONTRIBUTING yok; `docs/` boş; tek prosa (AGENTS.md+spec) tamamen Türkçe VE derleyici-içi bir günlük gibi yazılmış | Yeni bir geliştirici bugün dili ÖĞRENEMEZ, hatta kullanma HAKKINI bile bilemez (lisans yok) |
| 6 | **Dağıtım paketi yok** | Homebrew formula/Docker/`.deb` yok; TEK yol depo klonlayıp `zig build` | Kullanıcı adayı derleyiciyi ELDE EDEMEZ |

### 1.2 🟠 P1 — Ciddi teknik borç / güvenlik riski (üretime ÇOK yakın ama görmezden gelinemez)

| # | Boşluk | Kanıt | Risk |
|---|---|---|---|
| 7 | **Döngü çözücü (Katman 3) hiç yazılmadı** | `runtime/alloc/cycle_detector.zig` YOK; döngüler bugün yalnızca sınıf-alanı ileri-referans kısıtı YÜZÜNDEN imkânsız (kalıcı garanti değil) | `list[T]` sınıf alanı desteği/ileri-referans genişletildiği AN self-referential yapılar sessizce SIZMAYA başlar |
| 8 | **Bilinen, düzeltilmemiş ARC sızıntı sınıfları** | `Task`/`Channel`/`dict` yeniden ATANIRSA (`t = spawn ...` ikinci kez) eski değer SIZAR — yalnızca kapsam-çıkışı ele alınmış | Uzun süre çalışan (özellikle sunucu) programlar YAVAŞÇA bellek tüketir |
| 9 | **ARC refcount'ları atomik DEĞİL** | `arc.zig`: `rc.* += 1`/`-= 1` düz tamsayı — şu an güvenli çünkü arka plan iş parçacıkları (http_client) ARC nesnelerine HİÇ dokunmuyor, ama bu KIRILGAN/belgelenmemiş bir DAVRANIŞ, invariant DEĞİL | Gelecekteki bir stdlib genişlemesi (ör. arka plan iş parçacığından ARC nesnesi üretmek) SESSİZ veri yarışı/heap bozulması yaratabilir |
| 10 | **`extern def`/`lowlevel`in güven sınırı HİÇBİR yerde belgelenmemiş** | AGENTS.md/spec yalnızca tip disiplinini tartışıyor, "bu ÇIPLAK native kod yürütme yetkisi" uyarısı YOK | Kullanıcı, bir `extern def`in TAM native güven ile çalıştığını FARK ETMEDEN bir bağımlılık ekleyebilir |
| 11 | **`nox.fs`/`nox.os` path/girdi doğrulaması SIFIR** | `fs.zig`: yol doğrudan `std.c.open`'a geçiyor, `..`/kanonikleştirme/jail YOK | Kullanıcı girdisinden gelen bir yol path-traversal'a AÇIK (belgelenmemiş bir risk olarak) |
| 12 | **WASM ayrıştırıcısında varint taşması** | `module.zig`/`interp.zig`'in LEB128 okuyucuları taşma (overflow) SINIRI KONTROL ETMİYOR | Bozuk/kötü niyetli bir `.wasm` dosyası panik/UB tetikleyebilir; `tests/fuzz/` BOŞ, hiç fuzzing yapılmadı |
| 13 | **Kaynak konumu (satır/sütun) izleme SIFIR** | `ast.zig` düğümleri hiçbir pozisyon bilgisi TAŞIMIYOR — spec'te TEK bir yerde "bilinçli v0.1 sınırlaması" olarak not edilmiş, 50+ sonraki fazda HİÇ ele alınmamış | Her tip/derleme hatası konumsuz düz metin — GERÇEK kullanıcı deneyimi için KABUL EDİLEMEZ |
| 14 | **Hata kurtarma YOK** | Checker İLK tip hatasında DURUYOR (çoklu tanılama yok) | Bir dosyada 5 hata varsa kullanıcı TEK TEK, derleme-düzelt-derleme döngüsüyle bulmak ZORUNDA |
| 15 | **Zig araç zinciri sürümü kilitli DEĞİL** | `build.zig.zon`'da yalnızca bir ALT sınır (`minimum_zig_version`) var, TAM pin/lockfile YOK | Zig'in KENDİSİ (`std.http`/`std.Io`) sürüm güncellemesinde SESSİZCE davranış değiştirebilir |

### 1.3 🟡 P2 — Dil tamamlanmışlığı (gerçek uygulamalar İÇİN gerekli ama acil ENGEL değil)

| Kategori | Eksik | Not |
|---|---|---|
| OOP | Kalıtım/metaclass **hiç YOK** (Faz 1'den beri kasıtlı) | `except Base` bir `Derived`'i YAKALAYAMAZ |
| Fonksiyonel | Closure/lambda/birinci-sınıf fonksiyon **YOK** | Yalnızca derleyici-içi (spawn wrapper) closure var |
| Sözdizimi | f-string, augmented assignment (`+=`), comprehension, `match`, dekoratör **YOK** | Faz 1'den beri hiç ele alınmadı |
| Kontrol akışı | `with`/context manager, iterator/generator protokolü **YOK** | `for` yalnızca `range()`/`list[T]` |
| Koleksiyonlar | `list[T]` **büyüyemiyor** (`.append()` yok), **indeksli atama yok**, **sınır kontrolü yok** | `dict[K,V]` bunların hepsini destekliyor, `list[T]` desteklemiyor — TUTARSIZLIK |
| Fonksiyon imzası | Varsayılan parametre değeri, `*args`/`**kwargs`, anahtar-kelime argümanı **YOK** | |
| Modüller | `from X import Y`/`as` aliasing **kalıcı olarak kapsam dışı**; proje-İÇİ çoklu-dosya birinci-taraf import **YOK** (yalnızca stdlib+paket importu var) | Bugün bir Nox "projesi" TEK dosyaya sıkışmış (paket bağımlılıkları hariç) |
| Generics | Yalnızca serbest fonksiyonlar generic olabilir (metod/sınıf OLAMAZ); dönüş-tipinden çıkarım YOK; heterojen `list[Shape]` YOK | |

### 1.4 🟢 P3 — Ekosistem/araç olgunluğu (dil "tamam" olsa BİLE eksik kalacak)

- **LSP yok** (autocomplete/go-to-def/hover — hiçbiri yok)
- **Syntax highlighting grameri yok** (TextMate/tree-sitter/Vim/Emacs — hiçbiri yok)
- **Debugger/DAP yok, derlenen ikili SIFIR debug bilgisi taşıyor** (`-g`/DWARF hiç geçilmiyor)
- **`noxc fmt` sadece bir stub** ("henüz uygulanmadı" + exit 1)
- **Stdlib ince**: logging, random, crypto/hash, regex, CSV/YAML/TOML, gerçek bir Date/DateTime tipi, zengin bir test çerçevesi (setup/teardown, mock, JUnit XML çıktısı) — HİÇBİRİ yok
- **Paket keşfi yok**: merkezi bir indeks/registry YOK (kasıtlı, ama şu an "hangi paketler var" sorusuna YANIT VERİLEMİYOR — hiçbir üçüncü-taraf Nox paketi muhtemelen HENÜZ VAR OLMUYOR)
- **Sürüm/stabilite politikası yok**: CHANGELOG yok, semver taahhüdü yok, "v0.1/taslak" öz-tanımı KORUNUYOR

---

## 2. MVP Sonrası Yol Haritası (Fazlandırılmış)

Yol haritası, projenin KENDİ "Faz X.Y" disipliniyle (her alt-faz kendi doğrulamasıyla biter) TUTARLI ama bu kez STRATEJİK seviyede — her Faz bir SONRAKİ üretim-hazırlık eşiğini temsil ediyor. Sıralama, P0→P3 önceliğini YANSITIR; bir sonraki faza geçmeden önceki fazın TAMAMLANMASI şart değildir (bazıları paralel yürütülebilir), ama Q ve R fazları diğer HER ŞEYİN önünde gelmelidir (aksi halde üstüne inşa edilen çalışma "üretim" iddiasını asla KARŞILAMAZ).

### Faz Q — Temel Sağlamlaştırma (EN YÜKSEK ÖNCELİK, diğer her şeyin ön koşulu)

| Alt-faz | İş | Neden ÖNCE |
|---|---|---|
| Q.1 | `git init` + ilk commit + `CHANGELOG.md` başlat | Sürüm geçmişi OLMADAN hiçbir şey izlenebilir/geri alınabilir değil |
| Q.2 | CI kur (GitHub Actions: her push'ta `zig build test` Debug+ReleaseFast, macOS runner) | Regresyonları YAKALAMANIN tek yolu |
| Q.3 | `main.zig`'i `project.resolveResourceDirs`e BAĞLA (zaten yazılmış, sadece KULLANILMIYOR) — sistem geneli kurulumu GERÇEKTEN çalışır hale getir | Dağıtımın MUTLAK ön koşulu |
| Q.4 | `README.md` (İngilizce + Türkçe) + `LICENSE` (MIT/Apache-2.0 öner) + `CONTRIBUTING.md` yaz | Yasal/legal netlik + ilk izlenim |
| Q.5 | `nox.http.serve`e temel DoS sertleştirmesi: bağlantı başına okuma zaman aşımı, `max_connections` varsayılanı (sınırsız DEĞİL), header/body boyut üst sınırı | Bugünkü hâliyle GERÇEK dünyaya AÇILAMAZ |
| Q.6 | AGENTS.md'ye `extern def`/`lowlevel` İÇİN açık bir "GÜVEN SINIRI" bölümü + `nox.fs` İÇİN path-traversal UYARISI ekle | Sıfır maliyetli, KRİTİK bir dokümantasyon boşluğu |

### Faz R — Platform Genişletme

| Alt-faz | İş |
|---|---|
| R.1 | Linux `epoll` tabanlı ikinci bir I/O reaktör backend'i (`io_reactor.zig`'i backend-agnostik hale getir) |
| R.2 | x86-64 İÇİN fiber context-switch (elle yazılmış assembly YA DA `ucontext`/`makecontext` tabanlı taşınabilir bir yaklaşım) |
| R.3 | CI matrisine Linux runner ekle, cross-compilation'ı GERÇEKTEN doğrula (`zig build -Dtarget=x86_64-linux-gnu`) |
| R.4 | Zig araç zinciri sürümünü TAM pinle (CI'de `zig version` kontrolü + kurulum talimatlarında kesin sürüm) |

### Faz S — Bellek Güvenliği Tamamlama

| Alt-faz | İş |
|---|---|
| S.1 | `Task`/`Channel`/`dict` yeniden atamasının ESKİ değeri release ETMESİNİ sağla (bilinen sızıntı sınıfı) |
| S.2 | `list[T]` indekslemeye sınır kontrolü ekle (`IndexError` raise) |
| S.3 | Katman 3 (döngü çözücü) TASARIMI + ilk implementasyonu — EN AZINDAN `list[T]` sınıf alanları/ileri-referans AÇILMADAN önce |

### Faz T — Derleyici DX

| Alt-faz | İş |
|---|---|
| T.1 | AST düğümlerine kaynak pozisyonu (satır/sütun) EKLE — lexer/parser/checker/codegen ZİNCİRİ boyunca taşı |
| T.2 | Checker'a çoklu-tanılama/hata kurtarma EKLE (ilk hatada durma yerine) |
| T.3 | QBE→cc boru hattına DWARF/`-g` debug bilgisi emisyonu ekle |
| T.4 | `noxc fmt`ı GERÇEKTEN implemente et (AST'yi yorum/boşluk KORUYARAK yeniden yazan bir printer) |

### Faz U — Dil Tamamlanmışlığı (Kullanıcı Talebi Öncelikli)

| Alt-faz | İş |
|---|---|
| U.1 | `list[T]`e `.append()`/dinamik büyüme + indeksli ATAMA ekle (dict zaten destekliyor — TUTARLILIK) |
| U.2 | Proje-içi çoklu-dosya birinci-taraf import (yerel modül sistemi — Faz O'nun bilinçli ERTELEDİĞİ parça) |
| U.3 | `import X as Y` / `from X import Y` (basitleştirilmiş bir alt küme olarak bile) |
| U.4 | Birinci-sınıf fonksiyon değerleri / closure (EN AZINDAN salt-okunur yakalama) |
| U.5 | `with`/context manager |

### Faz V — Standart Kütüphane Genişletme

| Alt-faz | İş |
|---|---|
| V.1 | `nox.log` (seviyeli logging) |
| V.2 | `nox.random` |
| V.3 | `nox.crypto` (SHA-256 asgari) |
| V.4 | `nox.time` genişletme: gerçek `Date`/`DateTime`, biçimlendirme/ayrıştırma |
| V.5 | `nox.test` genişletme: setup/teardown, JUnit XML çıktısı (CI entegrasyonu İÇİN) |
| V.6 | Basit bir regex/pattern-matching modülü |

### Faz W — Araç Ekosistemi

| Alt-faz | İş |
|---|---|
| W.1 | Tree-sitter grameri (VS Code + Neovim + GitHub syntax highlighting İÇİN TEK kaynak) |
| W.2 | Minimal LSP (yalnızca tanılama + go-to-definition ile BAŞLA, autocomplete SONRA) |
| W.3 | DAP/debugger entegrasyonu (T.3'ün debug bilgisi ÜZERİNE inşa edilir) |

### Faz X — Güvenlik Sertleştirme + Fuzzing

| Alt-faz | İş |
|---|---|
| X.1 | WASM ayrıştırıcısının varint okuyucularına taşma SINIRI ekle | 
| X.2 | `tests/fuzz/`i DOLDUR: lexer/parser/checker + WASM ayrıştırıcısı İÇİN libFuzzer/AFL tabanlı fuzz hedefleri |
| X.3 | ARC atomikliği/cross-thread invariant'ını YA gerçek atomiklerle YA DA derleme-zamanı bir assertion'la RESMİLEŞTİR |

### Faz Y — Paket Ekosistemi Olgunlaşması

| Alt-faz | İş |
|---|---|
| Y.1 | Hafif bir "paket dizini" (yalnızca statik bir JSON indeksi — gerçek bir sunucu/registry DEĞİL) — plan dosyasının kendi "gelecekte eklenebilir" tasarımını KULLAN |
| Y.2 | En az 3-5 gerçek örnek üçüncü-taraf paket YAYIMLA (ekosistemin GERÇEKTEN çalıştığını KANITLAMAK için) |

### Faz Z — Sürüm/Stabilite Politikası

| Alt-faz | İş |
|---|---|
| Z.1 | 1.0 için somut bir "hazır" tanımı (hangi Faz'lar TAMAMLANMALI) belirle |
| Z.2 | Semver politikası + dil/ABI stabilite garantisi YAZILI hale getir |
| Z.3 | `v0.1/taslak` etiketini KALDIR, gerçek bir sürüm numaralandırmasına GEÇ |

---

## 3. Önceliklendirme Tavsiyesi

Eğer kaynak/zaman sınırlıysa, önerilen sıra:

1. **Faz Q (tamamı)** — bunlar olmadan "üretim" kelimesi anlamsız.
2. **Faz U.1 (list[T] büyüme/indeksli atama) + S.1 (bilinen sızıntılar)** — küçük, yüksek etkili, mevcut kullanıcıların İLK çarpacağı sorunlar.
3. **Faz T.1-T.2 (pozisyon izleme + hata kurtarma)** — derleyici DX'inin GERÇEK kullanıcı memnuniyetine EN DOĞRUDAN etkisi.
4. **Faz R (Linux desteği)** — eğer hedef kitle sunucu/bulut kullanım İSE bu Faz Q kadar ACİL sayılmalı, aksi halde ertelenebilir.
5. **Faz V/W (stdlib+araçlar)** — kullanıcı tabanı büyüdükçe organik olarak ÖNCELİKLENDİRİLEBİLİR (hangi modülün EKSİK OLDUĞU gerçek kullanım geri bildirimiyle netleşir).
6. **Faz X/Y/Z** — proje OLGUNLAŞTIKÇA doğal bir SONRAKİ adım, ama bugün ACİL DEĞİL.

---

*Bu belge, `/Users/melihburakmemis/Documents/nox-lang` deposunun 13 Temmuz 2026 tarihli hâli üzerinden, üç bağımsız kod incelemesi ile hazırlanmıştır. Yeni fazlar tamamlandıkça bu belgenin güncellenmesi ÖNERİLİR.*
