# Dil yüzeyi: bırakılmış / ertelenmiş kalemler denetimi ve "dondurma öncesi" iş listesi (2026-11-18)

Amaç (kullanıcı, 2026-11-18): bootstrap (lexer/parser'ı Nox'ta yeniden yazma) başlamadan önce **sözdizimini/AST'yi etkileyen** eksikleri kapatmak; böylece Nox tarafı tekrar tekrar değiştirilmesin. Bootstrap planı (`project/noxc-nightly-selfhost-plani-2026-11.md`) bu liste bitene kadar **bekletilir**.

Yöntem: (1) `nox-teknik-spesifikasyon.md` (30 115 satır) içinde 295 "ertelendi / henüz yok / desteklenmiyor / kapsam dışı / TODO" işaretli satır tarandı; (2) izleme dosyaları (`yapilacaklar`, `acik-isler`, `nox-ana-todo`, `v2-3-yapilacaklar`, `limitasyon-ajan-rehberi`) açık kutular için tarandı; (3) `docs/language/python-differences.md` iddiaları **bugünkü noxc ile 49 küçük programla yeniden üretildi** (rehber kuralı 3: kayıtlar bayat olabilir).

Bulgu özeti: spesifikasyonun ertelenmiş işaretlerinin çoğu **tarihsel** (sonraki fazlarda kapanmış: `__init__`'siz sınıf, `list[T]` alanı, `with`, closure, boş liste vb.). Bugün gerçekten açık olanlar iki gruptur: (a) sözdizimi/AST'yi etkileyen **dil yüzeyi boşlukları** (bu belgenin konusu), (b) çalışma zamanı/araç işleri (REPL, C FFI sandbox, mobil, preemption, WASM kotaları, Snap) — bunlar lexer/parser taşımasını etkilemez, ayrı izlenir (`project/v2-3-yapilacaklar-2026-11.md` 6.x, kullanıcı kararıyla kapsam dışı).

Durum: `[ ]` açık · `[x]` bitti (sürümle) · `[K]` karar gerekir · `[-]` tasarım gereği, yapılmaz.

## A. Belge sapması (kod yok; hemen düzeltilir)

`docs/language/python-differences.md` bugünkü davranışla çelişiyor (probe ile doğrulandı):

- [x] A1 "no `global`/`nonlocal`" → `nonlocal` **var** (p41 OK).
- [x] A2 "`match`, `@property`, `@staticmethod`, `@classmethod` yok" → hepsi **var** (p40, p17, p18, p42 OK).
- [x] A3 "no `yield` inside `try`/`with`" → `try/finally` içinde `yield` **çalışıyor** (p24 OK); `with` içinde `yield` ayrıca doğrulanacak (probe `open` yerleşik olmadığından sonuçsuz kaldı).
- [x] A4 "no `async with`" → ayrıştırılıyor (p23 yalnızca tanımsız ad hatası); `async for` var (q3 OK). Gerçek durum belgelenecek.
- [x] A5 "no `__all__`" → opt-in `__all__` v2.2.5'ten beri var.
- [x] A6 "no walrus `:=`" → deyim düzeyinde `x := v` bildirimi **var** (v2.2.20); Python'un ifade-içi walrus'ı (`(n := 5)`) yok — cümle düzeltilecek.
- [x] A7 "chained comparison" belgelenmemiş ama çalışıyor (p15 OK): belgeye eklenecek.

## B. Dil yüzeyi boşlukları (lexer/parser/AST'yi etkiler → dondurmadan önce karar)

Her satırın başındaki "p.." probe numarasıdır (bugün `noxc check` sonucu). Boyut: S küçük, M orta, L büyük.

### B1. Küçük, kesin faydalı, çözümü belirgin (öneri: hepsini yap)
- [x] B1.1 (S) `;` deyim ayırıcı (p02) — lexer belirteci + parser; `a: int = 1; b: int = 2`.
- [x] B1.2 (M) Tek satırlık bileşik deyim gövdesi (p01): `if x > 1: print(x)`, `else: ...`, `while`/`for`/`try`/`except`/`finally`/`with`/`def f(): return 1`. Parser; AST/formatter gövdeyi aynı biçime indirger (fmt çok satıra açar mı yoksa korur mu: karar B1.2a).
- [x] B1.3 (S) `try … else:` (p04) — parser + `IfStmt`/bayrak desugarı.
- [x] B1.4 (S-M) `for … else` ve `while … else` (p05, p06) — `break` olmadan biterse; bayrak değişkeni desugarı (checker/codegen değişmez).
- [x] B1.5 (S) Çok-öğeli `with a as x, b as y:` (p09) — iç içe `with`'e desugar.
- [x] B1.6 (S) Ham dize `r"…"`/`r'…'` (p11) — lexer.
- [x] B1.7 (S) Bitişik dize birleştirme `"a" "b"` (p12) — lexer/parser (derleme zamanı birleştirme; f-string ile karışımı kuralı: yalnızca aynı tür).
- [x] B1.8 (S) `...` (Ellipsis) gövde olarak (p39) — `pass` eşdeğeri; protokol/`def` gövdeleri için.
- [x] B1.9 (S) f-string `!r` / `!s` / `!a` dönüşümleri (p14) — şu an özel hata veriyor; `repr()` ve `str()` mevcut (doğrulandı), `ascii()` yok: `!r`→`repr(x)`, `!s`→`str(x)` yapılır, `!a` açık hata olarak kalır.

### B2. Anlamsal karar gerektirenler (AGENTS §16: önce sor)
- [x] B2.1 `[K]` (M) Çıplak `raise` (p07): `except` gövdesinde mevcut istisnayı yeniden fırlat. Mevcut istisna tutamacı codegen'de var; checker kuralı ("yalnızca except içinde"). Python'da çok yaygın → önerilir.
- [x] B2.2 `[K]` (M) `raise X from Y` (p08): neden zinciri. Seçenekler: (a) `Y`yi değerlendirip `__cause__` alanına yaz (istisna sınıflarına alan), (b) kabul et ama yok say (sözdizimi uyumu, davranış kaybı). Öneri: (a) küçük sürümle, `e.cause` salt-okunur.
- [x] B2.3 `[K]` (M) Yıldızlı açma `a, *b = xs` (p03) ve iç içe açma `(a, b), c = ...` (p44).
- [x] B2.4 `[K]` (M) Literal yayılımı `[*a, 2]` (p49), `{**a, "k": v}` (p48).
- [x] B2.5 `[K]` (M) `type IntList = list[int]` tip takma adı (p16): ad çözümleme, monomorphization etkileşimi, generic takma ad (v1: yalnızca tam tip takma adı).
- [x] B2.6 `[K]` (S) `global x` (p32): şu an sözdizimi hatası. Modül düzeyi değişken işlevden doğrudan atanabildiği için `global` anlamsal olarak gereksiz; seçenek: kabul et (no-op + doğrulama) ya da açık hata mesajı ("gerek yok, doğrudan atayın"). Öneri: açık yönlendirici mesaj.
- [-] B2.7 `[K]` (kullanıcı kararında seçilmedi → yapılmadı) (S) Varsayılan parametre değerinde sabit katlanmış ifade (p27: `b: int = 1 + 1`) — checker; düşük değer, öneri: yalnız tamsayı/float/dize sabit katlama.
- [-] B2.8 `[K]` (kullanıcı kararında seçilmedi → yapılmadı) (M) `bytes` literali `b"ab"` (p25): `bytes` tipi yok; `nox.binary.Buffer` var. Öneri: şimdilik yapılmaz, yalnız net hata mesajı.

### B3. Tasarım gereği, yapılmaz (`[-]`) — yalnızca belgede açık dursun
- [-] `%` biçimlendirme (p13), `import *` (p19), göreli içe aktarma (p20), dilim ataması/silme (p21), `del name` (p10), işlev içi `import` (p33), `g(*xs)` için `*args` parametresi şartı (p36), ifade-içi walrus (p22), `isinstance`/`weakref`, `list[Task[T]]`, çıplak `Callable[...]` yazımı (Nox'un fonksiyon tipi sözdizimi farklıdır).

## Kullanıcı kararları (2026-11-18)

- B1: **hepsi yapılacak** (dil yüzeyi 1).
- B2: çıplak `raise` + `raise X from Y`, yıldızlı + iç içe açma, literal yayılımı, `type` takma adı **yapılacak** (dil yüzeyi 2); `global x` **kabul edilecek (no-op, doğrulamalı)**; `bytes` literali ve varsayılan değer sabit katlama sorulmadı → yapılmaz (bytes için net hata iletisi).

## C. Anlamsal (checker) tarafında bırakılmış ama AST'yi değiştirmeyen kalemler

Bunlar lexer/parser taşımasını etkilemez; **dondurma şartı değildir**, bilgi olarak:
- E5 sınıf/metot dekoratör işleyicileri (kapsam dışı, kullanıcı kararı), E8 `match` kenarları (koruma ifadesinde lambda/comprehension/dict yok; `match` üreteçte yok), C5/7.3 `list[Task[T]]`, 9.15 WASM kotaları, F2 freestanding liste bozulması (`project/freestanding-kapsam-analizi-2026-11.md`), 6.1–6.4.
- Parser içi desugarlar (tuple açma `__nox_tup_*`, `match`→`IfStmt` zinciri, jeneratör/async dönüşümleri, dekoratör metadata): Nox portunda **aynı davranışla** çoğaltılacak; yeni bir `StmtKind` eklemek ≈25 dosya/90+ yürüyücü (rehber E8) olduğundan bu liste yeni `StmtKind` önermez; B1/B2 maddeleri mevcut AST düğümlerine indirgenir.

## D. Önerilen yürütme sırası

1. A1–A7 belge düzeltmesi (hemen).
2. B1.1–B1.9 tek toplu sürüm ("dil yüzeyi 1"): lexer (`;`, `r""`, bitişik dize), parser (tek satır gövde, `else`'ler, çoklu `with`, `...`), f-string dönüşümü; her biri golden + fmt + tree-sitter + iki backend.
3. B2 kararları (aşağıdaki sorular) → onaylananlar "dil yüzeyi 2" sürümü.
4. Dondurma: `AGENTS.md`/spesifikasyona "dil yüzeyi donduruldu (v2.2.x)" notu; bundan sonra yüzey değişikliği = Nox portuna da yansıtılacak iş.
5. `project/noxc-nightly-selfhost-plani-2026-11.md` yeniden başlatılır (Aşama 0).

## E. İlerleme özeti

| Grup | Madde | Bitti |
|---|---|---|
| A belge | 7 | 7 |
| B1 küçük/kesin | 9 | 9 |
| B2 karar gerekir | 8 (6 yapıldı, 2 yapılmaz) | 6 |
