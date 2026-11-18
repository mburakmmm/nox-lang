# Selfhost dogfood defteri (Nox'un kendi derleyicisini yazarken bulunan Nox/çalışma zamanı bulguları)

Süreç kuralı (kullanıcı önerisi, 2026-11-18): her aşama boyunca bulunan bulgular bu deftere yazılır; **aşama bitince "dogfood kapanışı"** yapılır: her bulgu *düzelt / ertele (kanıtla) / karar iste* olarak ele alınır. Aşama ortasında düzeltme yapılmaz (hareketli hedef farksal kanıtı bozar). Sınıflandırma: **Z** = Zig derleyici/çalışma zamanı hatası (önce Zig'de düzelt, Nox portu sonra), **P** = saf performans/bellek iyileştirmesi (dil değişmez; ölçüyle), **L** = dil davranışı/yüzeyi değişikliği (dil yüzeyi dondu: kullanıcı onayı gerekir, AGENTS §16), **D** = tasarım gereği (belgele, selfhost stil rehberine yaz).

Durum: `[x]` kapandı (sürüm) · `[ ]` açık · `[K]` kullanıcı kararı bekliyor · `[-]` tasarım gereği/belgelendi.

## Aşama 1 (lexer) bulguları — kapanış v2.2.36

| # | Tür | Bulgu | Kanıt | Durum |
|---|---|---|---|---|
| D1.1 | Z | Zig lexer trivia kipi CRLF'te yorum metnine `\r` taşıyor ve CRLF boş satırı iki kez sayıyor → `noxc fmt` CRLF dosyada karışık satır sonu (`\r\n` + `\n`) üretiyor | `printf 'x = 1\r\n\r\n# c1\r\n' \| noxc fmt` | [x] v2.2.36 (Zig + Nox portu; `tests/cli/tokens_ast_test.zig` CRLF testi) |
| D1.2 | D | Liste büyürken yeniden tahsis edilir; `ys = xs; xs.append(v)` büyümede `ys` eski bloğu görür (spesifikasyon "bilinçli v1 sınırlaması" 1; öğretici "aynı listeye bakar" diyor) | `ys=[]; zs=ys; zs.append(..)` → `len(ys)=0` (Python: 50) | [K] düzeltme çift dolaylı "handle" yeniden tasarımı (mimari); şimdilik selfhost stil kuralı: token arabelleğine yalnızca alan üzerinden ekle (`selfhost/README.md`) |
| D1.3 | P | Enum varyantları öbek nesnesi (retain/release, atomik): 68 kollu `match` ~20 ns/dağıtım | plan 0.11 | [ ] aday: yüklü olmayan varyantları sabit/ölümsüz tekil nesne yap (dil değişmez); Aşama 2 kapanışında ölç |
| D1.4 | P | Yoğun `if k == C1 / elif k == C2 …` zincirleri doğrusal (68 kol ~20 ns) | plan 0.11 | [ ] aday: LLVM `switch`e indirgeme (codegen, dil değişmez); Aşama 2 kapanışında parser dağıtım ölçümüyle |
| D1.5 | L | `match` üst düzey tamsayı sabit deseni kabul etmiyor (`case 0:`; yalnız enum/iç desenlerde) | `m2.nox` sözdizimi hatası | [K] dil kararı |
| D1.6 | L | Özellik üzerinde Optional daraltma yok (`if n.l is None` sonrası `n.l` daralmaz) | compiler_bench bulgusu | [K] dil kararı (checker kuralı) |
| D1.7 | D | `lowlevel` içinde sınıf kurma/`list[Sınıf].append` yok | compiler_bench | [-] bayt okuma ayrı işlevde (selfhost stil kuralı) |
| D1.8 | P | Lexer: bayt başına `at()` çağrısı + token başına 5 `append` + Token dönüşümü (2,2×/2,35×) | `lex-bench` | [ ] bütçe içinde; uçtan uca profilde ele alınır |

## Aşama 2 (parser/AST) — bulgular buraya eklenecek
