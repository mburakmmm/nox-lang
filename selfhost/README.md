# selfhost/: noxc-nightly'nin Nox ile yazılmış bileşenleri

Plan ve takip listesi: `project/noxc-nightly-selfhost-plani-2026-11.md`. Bu dizin yalnızca **nightly** ikilisine girer (`zig build nightly`); normal `noxc` bu dizinden habersizdir.

## Nasıl çalışır

1. `zig build nightly`: kurulu `noxc` (stage0) `selfhost/lexer.nox` dosyasını `noxc build --selfhost-obj` ile **`main`siz** bir nesneye (`zig-out/nightly/selfhost.o`) derler. Bu bayrak gizlidir ve kullanıcıya açık değildir (kararı: plan §3.1, seçenek B).
2. Nesne, `noxrt.o` ve `compiler/main.zig` (nightly seçeneği açık) tek ikilide birleşir: `zig-out/bin/noxc-nightly`.
3. Zig tarafı: `compiler/selfhost_glue.zig`. `nox_runtime_init()` → `nox_lib_init(rt)` (dispatch tablosu + modül global'leri) → Nox işlevleri → `nox_lib_fini(rt)` → `nox_runtime_deinit(rt)`.

## Stil ve sözleşme

- Her üst düzey `def` dış bağlantılı bir C simgesidir; Nox işlevleri gizli ilk parametre olarak `rt` alır (`i64`). Simge çakışmasını önlemek için bu dizindeki dışa açık işlevler `sh_` önekiyle başlar (Aşama 1'de lexer girişi `nox_lex`).
- **Liste takma adı kuralı (D1.2):** büyüyen bir listeye (`append`) yerel bir takma adla değil her zaman sahibi olan alan/değişken üzerinden ekle (`st.out.append(x)`); `a = st.out; a.append(x)` büyümede bayatlar. Bayt okuma `lowlevel` içinde ayrı işlevde yapılır (sınıf kurma/`list[Sınıf]` orada yok). Bulgu defteri: `project/selfhost-dogfood-defteri-2026-11.md`.
- `ad := ifade` yalnızca sağ taraf tipi açıksa; aksi halde tam tip yazılır. Bu dizinde async/`spawn` yok (`--selfhost-obj` bunları reddeder).
- Veri sınırı düz sayı arabelleği (`ptr[u8]`, `lowlevel` içinde) ya da bayt tamponudur; Nox nesneleri Zig'e sızdırılmaz.
- Yeni dil özellikleri önce Zig derleyicisinde, farksal testle sonra buraya.

## Dosyalar

- `lexer.nox.in`: elle düzenlenen **kaynak** (Aşama 1, Nox lexer'ı). `lexer.nox`: `scripts/gen_selfhost_lexer.py` ile ÜRETİLEN dosya (token türü sayıları, anahtar sözcük işlevi, Unicode tabloları); elle düzenlenmez, `--check` ile güncelliği denetlenir (precheck + `zig build test`).
- `nox.json`: proje bildirimi. `tests/`: Aşama testleri için ayrılmış dizin (farksal testler `scripts/frontend_diff.py`de).

## Denemeler

`selfhost/spike/` Aşama 0'ın kanıt deneylerini içerir (0.1: Zig→Nox çağrısı).

## Aşama 2 (parser)

`parser.nox` ÜRETİLMİŞTİR: kaynak `parser.nox.in`, üretici `scripts/gen_selfhost_parser.py` (`--check` güncelliği doğrular). `ast_schema.nox` da üretilmiştir (`scripts/gen_selfhost_ast.py`). Doğrulama: `noxc-nightly parse-nox <dosya>` (Nox parser + Nox yazıcısı) ↔ `noxc ast --full`; `scripts/frontend_diff.py --component parser --stderr [--fuzz N]`; bütçe: `noxc-nightly parse-bench <dosya> [tekrar] --max-ratio=3 --max-mem=2` (ReleaseFast çalışma zamanıyla).

## Aşama 2.13 (biçimlendirici)

`formatter.nox` ÜRETİLMİŞTİR (`formatter.nox.in` + `scripts/gen_selfhost_parser.py`). `noxc-nightly fmt <dosya>` Nox hattını kullanır; doğrulama: `scripts/frontend_diff.py --component fmt` (`noxc fmt --stdout` ↔ `noxc-nightly fmt --stdout`); bütçe: `noxc-nightly fmt-bench <dosya> [tekrar] --max-ratio=3 --max-mem=2`. Modül-düzeyi global adları modüller arasında benzersiz olmalıdır (bkz. dogfood D2.3).

## Aşama 3 (tip denetleyici)

`types.nox` (3.1, ELLE yazılmış; üretilmiş değil): tip tablosu `TT` (düz sütunlar + hash-consing → `TypeId`), `SymbolId` intern havuzu, sınıf hiyerarşisi, `assignable`/`format`/`mangle`/`ty_validate`. Tasarım: `project/asama3-tasarim-kararlari-2026-11-24.md`. Doğrulama: `noxc-nightly types-diff [adet] [tohum]` (Zig `typecheck/types.zig` ↔ Nox; `zig build frontend-diff-test` ve `tests/cli/selfhost_contract_test.zig` içinde) ve bütçe: `noxc-nightly types-bench [k] [m] [tekrar] --max-ratio=1.3` (ReleaseFast nightly gerekir). Kurallar: tip = `TypeId` (tamsayı), asla Nox nesnesi/ağacı değil; sembol = `SymbolId`; `func` tipinden önce çocuklar kurulur; hash adımı 40 bit maskeli (taşmaya bağımlı değil).

`typecheck.nox` ÜRETİLMİŞTİR (3.2+; kaynak `typecheck.nox.in`, üretici `scripts/gen_selfhost_parser.py`, `--check` güncelliği doğrular): kapsam/sembol tabloları (`Scope`, `declare_var`, modül global tabloları), `stmts_assign_name`. Doğrulama: `noxc-nightly ck-diff scope [ops] [tohum]`, `ck-diff assign <dosya...>`, bütçe `ck-diff bench [kapsam] [ad] [işlem] [tekrar] --max-ratio=1.3` (ReleaseFast).

3.3 (kapsam-kapılı): `typecheck.nox` kapsam dışı yapıda `CkUnsupported` fırlatır (durum 2); kapsam-içi programlarda `noxc-nightly ck-diff check <dosya...>` GERÇEK `checker.check` ile sonuç/kod/ileti/satır/span/tüm tanılamaları karşılaştırır. Tohumlu program üreteci: `scripts/ck_gen.py --out DIR --count N --seed S` (kasıtlı hatalı programlar dahil).

