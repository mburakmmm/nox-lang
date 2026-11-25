# `bytes` yerleşik tipi — görev belgesi (NoxPy ön koşulu)

Kaynak: NoxPy `UPSTREAM_REQUIREMENTS.md` UR-006 (`bytes` span) + `ir.py` `PHASE1_PARAM_TYPES`. Tespit (2026-11-25): Nox'ta yerleşik `bytes` yok (`str`, `list[u8]`, `nox.buffer.Buffer`, `nox.bytes` köprüsü var). Kullanıcı kararı (2026-11-25): **önce `bytes`, sonra tüm NoxPy UR işleri tek turda**; AGENTS.md §16.3 gereği yeni dil özelliği — aşağıdaki tasarım kullanıcıyla onaylandı.

## Onaylanan tasarım

- **Temsil:** yeni DEĞİŞMEZ statik tip `bytes` (≠ `str`, örtük dönüşüm YOK, hash'lenebilir → dict anahtarı). Çalışma zamanında `str` ile AYNI bellek düzeni (uzunluk başlığı + bayt verisi, ARC yönetimli): concat/eşitlik/hash/sıralama hazır `str` kodunu paylaşır; yeni ARC türü yok. `len`/indeks/dilim/yineleme BAYT tabanlıdır (str'nin codepoint semantiği KULLANILMAZ).
- **Literal:** `b"..."` (kaçışlar: `\n \t \r \\ \" \' \0 \xHH`; ASCII dışı karakter hata). **Bu turda**, Zig lexer/parser/biçimlendirici/AST dökümleri + selfhost Nox lexer/parser/formatter/ast_schema karşılığı + `frontend_diff.py` paritesi AYNI turda.
- **Eleman tipi:** `b[i]` ve `for x in b` → `int` (0..255); atama yok.
- **İşlemler (v1):** `len(b)`, `b[i]`, `b[i:j]` (dilim), `b1 + b2`, `==`/`!=`/`<`/`<=`/`>`/`>=` (bayt sözlük sırası), `x in b` (`bytes in bytes` alt dizi ve `int in bytes`), yineleme, dict anahtarı; dönüşümler `bytes(list[u8])`, `b.to_list() -> list[u8]`, `s.encode() -> bytes`, `b.decode() -> str` (geçersiz UTF-8'de `ValueError`), `b.hex() -> str`.
- Dışında (sonra): `bytearray`, `b"" % ...`, f-bytes, `bytes.join/split/find/startswith`, `nox.bytes`/`nox.buffer` yeniden düzenleme.

## Doğrulama ölçütü (DoD)

Golden test (iki backend) + IR anlık görüntüleri; selfhost lexer/parser/formatter paritesi (`frontend_diff`); `zig build test` yeşil; docs (language/types.md + spec); NoxPy `ir.py` `bytes` kabulü; `noxc expand --json` `bytes` yazar.

## İlerleme

- [x] 1 Tip sistemi (`types.zig` `.bytes`, checker kuralları)
- [x] 2 Lexer/parser/AST (`b"..."`), biçimlendirici, AST dökümleri
- [x] 3 Codegen (QBE+LLVM) + çalışma zamanı bayt-tabanlı girişler (+ str eşitlik/sözlük NUL düzeltmesi)
- [x] 4 Selfhost lexer/parser/formatter/ast_schema paritesi (frontend_diff FARK YOK)
- [~] 5 Testler (golden fixture Python ile doğrulandı), belgeler, sürüm — v2.2.77 test/precheck/yayın bekliyor; ReleaseFast ile str karşılaştırma hız ölçümü açık
