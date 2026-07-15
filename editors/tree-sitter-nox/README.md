# tree-sitter-nox

[Nox](https://github.com/nox-lang/nox) programlama dili için bir
[Tree-sitter](https://tree-sitter.github.io/tree-sitter/) grameri. Editör
sözdizimi vurgulama (syntax highlighting), kod katlama, yapısal seçim ve
gelecekteki LSP/DAP entegrasyonları (bkz. `nox-teknik-spesifikasyon.md`
Faz W) için artımlı bir ayrıştırıcı sağlar.

Bu, Nox'un **kendi derleyicisinin** (bkz. `compiler/`) yerini TUTMAZ —
`noxc`nin lexer/parser'ı hâlâ TEK doğruluk kaynağıdır. Bu gramer, editör
araçları İÇİN AYRI, bağımsız bir ayrıştırıcıdır ve `compiler/lexer/`+
`compiler/parser/`deki GERÇEK gramerin bilinçli olarak SADELEŞTİRİLMİŞ bir
YANSIMASIdır (bkz. aşağıdaki "Kapsam" bölümü).

## Kurulum

```sh
npm install
npm run generate   # grammar.js -> src/parser.c
npm test           # test/corpus/*.txt regresyon testleri
```

## Kapsam

Nox'un GERÇEK sözdizimi (bkz. `compiler/lexer/token.zig` + `compiler/parser/
parser.zig`) NEREDEYSE TAMAMEN kapsanır: girinti-duyarlı bloklar, `def`/
`class`/`protocol`/`extern def`/`lowlevel`, `if/elif/else`, `while`/`for`,
`try/except/finally`, `with`, `raise`, `import`/`from...import`, generic
tip parametreleri (`def f[T](...)`), fonksiyon tip ifadeleri
(`(int) -> int`), `async`/`await`/`spawn`.

**Bilinçli sadeleştirmeler** (v1 kapsamı dışı — vurgulayıcı/editör aracı
için gereksiz ayrıntı, GERÇEK derleyicinin doğruluğunu etkilemez):

- `Channel[T](capacity)` — dilde YALNIZCA `Channel` için ayrılmış, açık tip
  argümanlı kurucu çağrısı sözdizimi — AYRI bir düğüm türü olarak
  modellenmez; sıradan iç içe `index`+`call` olarak ayrıştırılır (bkz.
  `grammar.js`'in `index` kuralının belge notu).
- String literalleri tek satırla sınırlıdır (gerçek lexer teknik olarak
  çok satırlı bir string'i REDDETMEZ, ama pratikte hiç kullanılmaz — bkz.
  `grammar.js`'in `string` kuralının belge notu).
- TAB girinti karakterleri 8 sütunluk bir boşluk GİBİ SAYILIR (gerçek
  derleyici TAB'ı TAMAMEN REDDEDER — `TabsNotAllowed` — bu gramer yalnızca
  vurgulama İÇİN daha TOLERANSLI davranır).

## Mimari notu — harici tarayıcı (`src/scanner.c`)

Nox, Python'un girinti modelini (bkz. `compiler/lexer/lexer.zig`) birebir
takip eder — NEWLINE/INDENT/DEDENT üretimi bağlamsız bir gramerle İFADE
EDİLEMEZ, bu yüzden bir C harici tarayıcısı gerekir. `src/scanner.c`,
[tree-sitter-python](https://github.com/tree-sitter/tree-sitter-python)nun
(MIT lisanslı) KANITLANMIŞ algoritmasından UYARLANMIŞTIR — üçlü-tırnak/
f-string/ham-string karmaşıklığı OLMADAN (Nox'ta yok), yalnızca NEWLINE/
INDENT/DEDENT + parantez-içi-satır-sonu-bastırma mantığı korunmuştur.

## Doğrulama

- `npm run generate` + `npm test`: `test/corpus/basics.txt` (deyimlerin/
  ifadelerin/tiplerin TAMAMINI kapsayan tek bir kaynak dosyası).
- Grameri repodaki HER GERÇEK `.nox` dosyasına (`stdlib/`, `benchmarks/`,
  `tests/golden/`, TOPLAM 200+ dosya) karşı sıfır-hata ile ayrıştırma
  (bkz. `nox-teknik-spesifikasyon.md`nin W.1 bölümü — bu, derleyicinin
  KENDİSİYLE aynı golden-test disiplini DEĞİL, ama bu gramer İÇİN eşdeğer
  bir regresyon GÜVENCESİdir).
