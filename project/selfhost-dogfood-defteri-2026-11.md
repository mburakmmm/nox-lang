# Selfhost dogfood defteri (Nox'un kendi derleyicisini yazarken bulunan Nox/çalışma zamanı bulguları)

Süreç kuralı (kullanıcı önerisi, 2026-11-18): her aşama boyunca bulunan bulgular bu deftere yazılır; **aşama bitince "dogfood kapanışı"** yapılır: her bulgu *düzelt / ertele (kanıtla) / karar iste* olarak ele alınır. Aşama ortasında düzeltme yapılmaz (hareketli hedef farksal kanıtı bozar). Sınıflandırma: **Z** = Zig derleyici/çalışma zamanı hatası (önce Zig'de düzelt, Nox portu sonra), **P** = saf performans/bellek iyileştirmesi (dil değişmez; ölçüyle), **L** = dil davranışı/yüzeyi değişikliği (dil yüzeyi dondu: kullanıcı onayı gerekir, AGENTS §16), **D** = tasarım gereği (belgele, selfhost stil rehberine yaz).

Durum: `[x]` kapandı (sürüm) · `[ ]` açık · `[K]` kullanıcı kararı bekliyor · `[-]` tasarım gereği/belgelendi.

## Aşama 1 (lexer) bulguları — kapanış tamamlandı v2.2.39 (D1.1–D1.8; D1.8 lexer perf ucu açık izleme: lex-bench ≤3× kapısı)

| # | Tür | Bulgu | Kanıt | Durum |
|---|---|---|---|---|
| D1.1 | Z | Zig lexer trivia kipi CRLF'te yorum metnine `\r` taşıyor ve CRLF boş satırı iki kez sayıyor → `noxc fmt` CRLF dosyada karışık satır sonu (`\r\n` + `\n`) üretiyor | `printf 'x = 1\r\n\r\n# c1\r\n' \| noxc fmt` | [x] v2.2.36 (Zig + Nox portu; `tests/cli/tokens_ast_test.zig` CRLF testi) |
| D1.2 | D | Liste büyürken yeniden tahsis edilir; `ys = xs; xs.append(v)` büyümede `ys` eski bloğu görür (spesifikasyon "bilinçli v1 sınırlaması" 1) | `ys=[]; zs=ys; zs.append(..)` → `len(ys)=0` (Python: 50) | [x] v2.2.39: **kalıcı, belgelenmiş sınırlama** — öğretici ve python-differences artık gerçeği söylüyor (eskiden "aynı listeye bakar" diyordu); selfhost stil kuralı (tek sahip, alan üzerinden ekle). Gerçek düzeltme = liste için handle (başlık + ayrı tampon) yeniden tasarımı: her liste işlemi + FFI/HPy/JSON/stdlib yerleşimi + tahsis sayısı ×2 etkilenir; **ayrı proje olarak yalnızca kullanıcı isterse** başlatılır |
| D1.3 | P | Enum varyantları öbek nesnesidir; yüklü olmayan varyant oluşturma = tahsis+serbest bırakma | ReleaseFast süreç-içi: oluştur+`match`+bırak 3,2 ns vs `int` 0,4 ns (8×; tahsis satır içi havuz yolunda) | [x] v2.2.39: **tasarım ölçülüp REDDEDİLDİ.** Önerilen statik/ölümsüz paylaşılan tekil nesne için retain/release çekişmesi ölçüldü: 1 iş parçacığı 5 ns, 2 → 16 ns, 4 → 51 ns, 8 → **285 ns/çift** (bugünkü iş parçacığı-yerel havuz ~3 ns): çok işçili M:N çalışmada büyük geriye gidiş. Yönerge: sıcak yollarda enum yerine `int` sabit + `kind` alanı (selfhost böyle yapar); enum dağıtımı (2–4 ns) sorun değil |
| D1.4 | P | Yoğun `if k == C1 / elif …` zincirleri | gerçekçi (aritmetik gövdeli) 64 kollu zincir 9–10 ns/iter (kollar baskın); **derlenmiş assembly'de LLVM `-O2` zinciri sıçrama tablosuna çevirmiş** (`lJTI…` + `br x11`) | [x] uygulanıp doğrulandı: ek codegen işi gerekmiyor (LLVM yapıyor); QBE yolu doğrusal ama yalnız freestanding/yedek |
| D1.5 | L | `match` üst düzey tamsayı sabit deseni yoktu | `case 0:` sözdizimi hatası | [x] v2.2.37 (kullanıcı onayı 2026-11-18): skaler `match` (int/float/str/bool literal, `\|` alternatifleri, yakalama, koruma, `case _`; kapsamlılık zorunlu değil; enum ile karışmaz). Parser indirgemesi + formatter; fixture `match_scalar`, `tests/cli/match_scalar_test.zig`, docs/language/enums.md |
| D1.6 | L | Özellik üzerinde Optional daraltma yoktu | compiler_bench bulgusu | [x] v2.2.37 (kullanıcı onayı): `a.b`/`a.b.c` yolları (yalnızca sınıf/list/dict/str; if/while/and/or/not + koruma biçimi); atamada, kullanıcı koduna giden çağrıda ve `await`te düşer (sağlamlık); fixture `optional_attr_narrowing`, 3 typecheck hata golden'ı, docs/language/types.md |
| D1.7 | D | `lowlevel` içinde sınıf kurma/`list[Sınıf].append` yok | compiler_bench | [-] bayt okuma ayrı işlevde (selfhost stil kuralı) |
| D1.8 | P | Lexer: bayt başına `at()` çağrısı + token başına 5 `append` + Token dönüşümü (2,2×/2,35×) | `lex-bench` | [ ] bütçe içinde; uçtan uca profilde ele alınır |

## Aşama 2 (parser/AST) bulguları

| # | Tür | Bulgu | Kanıt | Durum |
|---|---|---|---|---|
| D2.1 | D (hata) | **İndeksli atamada kapsayıcı, sağ taraftan ÖNCE değerlendiriliyor** (`a.n[i] = f()`; `f` aynı alanı `append` ile büyütürse yazma serbest bırakılmış eski tampona gider → bellek bozulması/SIGSEGV). Python: sağ taraf önce. D1.2 ile (kararlı başlık) bu risk ortadan kalkar; o zamana dek geçici değişken zorunlu | `selfhost/parser.nox.in` `substitute_binds`: `a.n[nb + O] = substitute_binds(...)` 4+ düğümlü `match` gövdesinde çöktü (`match_scalar.nox`); geçici değişkenle düzeltildi | [ ] kapanışta: D1.2 sonrası regresyon fixture'ı + (D1.2 gecikirse) değerlendirme sırasını düzeltme kararı |
| D2.2 | D | Çağrı sırasında alıcı parametre listesine `append` (`conds.append` kalleesinde) yine eski-tampon tuzağı (D1.2 ailesi) — parser tasarımında liste biriktiren yardımcılar `P` alanı üzerinden (`p.lp_conds`) yazıldı | `lower_pattern`, `p.cov` | [-] D1.2'ye bağlı |

## Süreç kuralı: performans maddeleri "kazancı küçük" diye KAPATILMAZ (kullanıcı, 2026-11-18)

Mikro ölçümde küçük görünen bir maliyet, tam derleme hattı çalışınca darboğaz çıkabilir. Bu yüzden her performans adayı (a) gerçekçi bir iş yüküyle (yan etkili gövdeler, tam hat) ölçülür, (b) zararsızsa (davranış aynı, bütçe kötüleşmiyor) **uygulanır ve kalıcı bırakılır**, (c) uygulanmadıysa **açık madde olarak kalır** ve bir CI kapısıyla (`lex-bench --max-ratio`, `compiler_bench`) izlenir. "İş yok" sonucu yalnızca madde fiilen uygulanıp ölçüldükten sonra yazılır.

## Ölçüm uyarısı (v2.2.37, genişletildi v2.2.38)

Üç ölçüm tuzağı bu turda yanlış sonuç üretti: (1) yeni derlenmiş ikilinin ilk koşusu ~0,2 s soğuk-başlangıç taşır; (2) **`zig build test` çalışma zamanını (`zig-out/lib/noxrt.o`) Debug bırakır** (DebugAllocator, ~100× yavaş): her perf ölçümünden önce `zig build -Doptimize=ReleaseFast` ve sonuçta `DebugAllocator` görünmemeli; (3) sabit dönüşlü mikro-kodu LLVM katlar: kollar gerçekçi (yan etkili/aritmetik) olmalı. Ölçüm şablonu: süreç içinden `nox.time.monotonic_ns`, iki koşu, ReleaseFast.

## Önceki not (v2.2.37)

Yeni derlenmiş bir ikili macOS'ta ilk çalıştırmada ~0,2 s soğuk-başlangıç yükü taşır. Mikro ölçümler **süreç içinden** (`nox.time.monotonic_ns`) ve en az iki koşuyla alınmalıdır; dışarıdan `time` ile ölçülen ilk koşu kullanılmaz. (D1.3/D1.4'ün yanlış bulguları buradan çıktı; `compiler_bench`/`lex-bench` zaten süreç içi ve en-iyi-N ölçer, etkilenmedi.)
