# Aşama 2 tasarımı: Nox parser'ı ve AST temsili (kullanıcı kuralı: tam geçiş, Nox kurallarına uygun, performanslı, bellek-uyumlu)

## 1. Kararlar ve gerekçeleri

1. **AST sınırı (2.11) = (b):** Nox parser doğrulama aracı olarak ilerler; tek köprü Nox checker sonrası tiplenmiş AST'de kurulur (bkz. plan 2.11).
2. **Temsil = düz diziler (struct-of-arrays).** Ölçüm (524 bin düğüm, ReleaseFast): sınıf-düğüm 86 MB (~164 B/düğüm) ve ~0,03 s; düz dizi 35 MB (~67 B/düğüm) ve ~0,04 s. Zig'in `Expr` birleşimi ~64 B ⇒ bellek bütçesi (≤2×) yalnızca düz diziyle sağlanır. Nox'ta `isinstance`/aşağı dönüşüm olmadığından sınıf hiyerarşisi zaten kullanışsız.
3. **Şema tek kaynaktan:** `compiler/parser/ast.zig` → `scripts/gen_selfhost_ast.py` → `selfhost/ast_schema.nox` (düğüm türü sayıları, alan konumları, oluşturucular, **`dump_full` yazıcısı**). `ast.zig`ye eklenen/silinen her alan üretilen dosyayı ve `--check`i bozar, böylece Nox tarafı sessizce geride kalamaz (lexer'ın `lexer.nox.in` deseniyle aynı).
4. **Oracle:** `noxc ast --full` (yansımayla, her alan, v2.2.40). Nox parser'ı aynı biçimi üretir; `scripts/frontend_diff.py --component ast --sub-args=--full` Zig ↔ Nox'u depodaki 1 258 dosya + mutasyonlu girdilerde, sözdizimi hata iletileri dahil karşılaştırır.

## 2. Temsil ayrıntısı

- `N: list[int]` düğüm tablosu: bir düğüm = `[tür, alan0, alan1, ...]` (tür başına sabit alan sayısı, şemadan). `Expr`/`Stmt`/`TypeExpr` birleşimleri ayrı tür sayıları taşır; yapı alanları (`Call`, `Binary`...) aynı düğümün alanlarıdır (yük satır içi).
- Alan türleri: `int`/`bool`/enum → doğrudan tamsayı; `f64` → bit deseni (iki `i64` değil, `float` bitleri `ptr`-bitcast ile tek tamsayı); düğüm başvurusu → `N` indeksi (`-1` = `null`); dilim → `(L içinde başlangıç, uzunluk)` iki tamsayı (`L: list[int]` ortak liste tablosu); dize → `(a, b)`: `a ≥ 0` kaynak metinde `[a, b)` aralığı (**sıfır tahsisli**; Zig'in kaynağa dilim tutmasıyla aynı), `a < 0` ise sentezlenmiş dizeler tablosunda (`S: list[str]`) `-a-1`. `?T` → değer ya da `-1`.
- Span: `Stmt.span` ve ifade span'leri yan tablo (`SP`) olarak; `expr_spans` yalnızca kaydedilen düğümler için.
- Bellek bütçesi: düğüm başına ≤ ~64 B (Zig `Expr` boyutu), `S` yalnızca parser'ın ürettiği adlar için (`__nox_tup_N_K`, `__match_N` vb.).

## 3. Parser'ın taşınması (tam yüzey)

`parser.zig` (3 608 satır) işlev-işlev, aynı sırayla Nox'a taşınır: ifade önceliği, deyimler, tip ifadeleri, dekoratörler, `class/protocol/enum` (parser-içi sentez), f-string bölme (iç ifadeler için lexer'ı yeniden çağırır), tüm desugarlar (tuple açma, yıldızlı/iç içe açma, `match` skaler+enum, `for/while/try else`, çok-öğeli `with`, `raise from`, çıplak `raise`, `type` takma adı, yayılım, `;` ve tek satır gövde, `global/nonlocal`, comprehension/lambda/jeneratör hazırlığı, dekoratör metadata), `normalizeStatementTokens` geçişi, `injectClassAttrStorage`, span sistemi, sözdizimi hata iletileri (`syntax_report`: konum + işaretçi gösterimi) ve `last_diagnostic` notları. Hata iletisi ve konum Zig ile **birebir** olmalıdır.

## 4. Aşama 2 alt adımları (plan §5 ile eşleşir)

| Adım | İçerik | Kapanış ölçütü |
|---|---|---|
| 2.0 | `noxc ast --full` oracle'ı (yansıma) | ✔ v2.2.40 |
| 2.A | `gen_selfhost_ast.py`: ast.zig'i okuyup `selfhost/ast_schema.nox` (tür sayıları, alan konumları, oluşturucular, `dump_full`) üretir; `--check` precheck/CI'da | tüm `ast.zig` türleri kapsanır; üretilen dosya `noxc check` + `--selfhost-obj` geçer |
| 2.B | `dump_full` Nox yazıcısının Zig dökümüyle doğrulanması (elle kurulmuş küçük ağaçlar + sonra parser ile) | sentetik ağaçlarda bayt-bayt eşit |
| 2.C | Parser çekirdeği: ifadeler, deyimler, tip ifadeleri | alt kümede değil, **tam** yüzeyle (aşağıdaki 2.D–2.G ile birlikte kapanır) |
| 2.D–2.G | sınıf/enum/protokol sentezi; f-string; desugarlar; dekoratör/metadata/`injectClassAttrStorage`; `normalizeStatementTokens` | hepsi tamamlanmadan 2.x `[x]` olmaz |
| 2.H | Hata iletileri + konumlar (`syntax_report`) | hata korpusu + mutasyon girdilerinde birebir |
| 2.I | Farksal: depo + mutasyon; perf ≤ 3×, bellek ≤ 2×, sızıntı testi | plan 2.12–2.14 |
| 2.J | Dogfood kapanışı (defter) | bulgular ele alınır |
