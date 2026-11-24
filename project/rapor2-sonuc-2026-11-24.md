# Rapor 2 — sonuç raporu (v2.2.59, 2026-11-24)

Kaynak: `project/selfhost-sertlestirme-listesi-2026-11-23.md` (R2 maddeleri). Ölçüm ortamı: aarch64-macos, ReleaseFast derleyici + runtime, 992 KB korpus (stdlib + selfhost), `scripts/selfhost_perf_report.py` (10 senaryo, medyan/min/yayılım). Ayrıntılı tablo: `project/selfhost-perf-raporu-2026-11-24.md`.

## Sonuç özeti (Nox/Zig süre oranı, 1 MB korpus)
| aşama | başlangıç (v2.2.48) | şimdi | Zig |
|---|---|---|---|
| lexer | ~1,9× | **0,53×** | 5,3 ms |
| parse (lexer dahil) | 1,62× | **0,69×** | 12,2 ms |
| fmt hattı | 2,07× | **0,70×** | 16,2 ms |
| fmt tepe RSS (ayrı süreç) | — | 30 MiB (Zig 61 MiB) | 0,49× |

## Uygulanan / ölçülen maddeler
| Madde | Durum | Bulgu / kanıt |
|---|---|---|
| A.1 profil | [x] | `sample` + `NOX_FRAME_POINTERS=1`; kategori: lexer taraması ≈%27, parser ≈%35, biçimleme ≈%20, `Ast_release` ≈%6, ARC tahsis/serbest ≈%5 (arena çifti elendikten sonra). Çağıran zincirleri Zig runtime'ında çerçeve işaretçisi olmadığı için yaklaşık. |
| A.2 saf Nox vs hibrit | [x] kapsamlı | 10 senaryo raporu. "Saf Nox" bağımsız yürütülebilir kurulmadı: Nox bileşenleri Zig'e `selfhost.o` olarak statik bağlıdır; köprü maliyeti doğrudan ölçüldü (Token dönüşümü ≈ %24 lexer süresi). Tüm hat oranları 10 senaryonun 9'unda ≤ 1,0× (tek istisna: dize ağırlıklı lexer 1,36× — uzun dizelerde bayt başına tarama). "fmt−parse" farkı (1,2–2,4×) GERÇEK biçimleme süresi değildir: fmt hattı trivia'lı sözcükleme, çıktı kopyası ve AST serbest bırakmayı içerir; profilde biçimleme işlevleri görünmüyor — rapor betiğinde "YAKLAŞIK" etiketlendi. |
| A.3 adil protokol | [x] | `selfhost_perf_report.py`: ısınma + N ölçüm medyanı/min/yayılım, ayrı süreç RSS, ARC blok/bayt, Debug reddi, sürüm/commit başlığı, girdiler senaryo başına farklı (sabit katlama yok; sonuç `doNotOptimizeAway`). |
| D.1 token başına 5 append | [x] | Liste büyütmesi ≈%12; toplu yazım için tek `nox_list_append5` (v2.2.58) lexer −%16. |
| D.2 inlining | [x] | IR/asm: `emit/peek/at` sonrası istisna kontrolü yok; `-O3` ve `-inline-threshold=600` ±%1 (etkisiz) → derleyici bayrağıyla kazanç yok. |
| D.3 lexer veri yerleşimi | [x] | Baskın maliyet düzenden değil `lowlevel` arena çiftindendi (v2.2.55). |
| D.4 köprü maliyeti | [x] | 0,77 ms ≈ %24; iyileştirme gerekmez. |
| E.1 düz dizi AST güvenliği | [x] | `nox_parse_validate` (span kimliği/değer sınırı, gövde dilimi, kimlik aralığı); `parse-bench` her tekrarda doğrular (üretim yolunda çağrılmaz). Tipli yardımcılar zaten üretici tarafından (`mk_*`, `O:`/`T:`/`E:` makroları) sağlanıyor. |
| E.2 `mk_*` toplu yazım | [x] gerekçeli | Parse profilinde `mk_*` ilk 25'te yok; uygulanmadı. Lexer `emit` için yapıldı. |
| E.3 span araması | [x] | v2.2.52: yoğun dizin, 0,09→0,04 s. |
| E.4 eleman başına ABI | [x] n/a | Köprü eleman başına çağrı kullanmıyor (ham arabellek adresi). |
| E.5 çıktı tamponu `list[u8]` | [x] | Biçimlendirici çıktı tamponu `list[u8]`: fmt tepe RSS 44→30 MiB (−%32), süre −%1…−%4; extern `with_rt` kabuklarına `list[u8]` parametre izni (kullanıcı kodu kuralı değişmedi). AST dökümü tamponu (`a.o`) yalnız hata ayıklama komutlarında kullanıldığından dokunulmadı. |
| F.1–F.3 formatter | [x] | `w`/`ws`/yorum toplu kopya (−%17), `ord` ASCII hızlı yolu, `is_generic_enum_ctor` O(n²) süzgeci (−%13), aşama aşama süre raporda. |
| H.1 inlining/bayraklar | [x] | `-O3`/inline eşiği etkisiz. |
| H.2 bounds check | [x] | Güvenlik kontrolleri perf için kaldırılmaz (AGENTS/liste kuralı); `at()` zaten kontrolsüz `ptr_read` (lowlevel). |
| H.3 LLVM vs QBE, `--selfhost-obj` | [x] | Nightly yalnızca LLVM (`--selfhost-obj`); QBE yolu nightly için kullanılmaz (CI notu). Visibility/DCE: tüm `def` simgeleri dışa açık (`T`); LLVM yine de satır içi yaptı (`-O3` etkisiz). |
| B.2/B.5 ASAP oranı | [x] | selfhost IR statik: `rc_alloc` 1663 nokta (çoğu istisna/nesne), `arena_create` 9, `arena_alloc` 18, yığın `alloca` 7194; 1 MB ayrıştırmada ≈ 68 bin ARC blok. Düz `lowlevel` arenası elemesi (v2.2.55) bayt başına arena çiftini kaldırdı. Borrowed parametre/`_c` klon analizi: tahsis sayısı süreyi belirlemiyor (blok −%46 ⇒ süre −%3). |
| G.3 liste başlığı perf | [x] | `lang_perf` (ReleaseFast): gerileme yok; Nox/C: `list_append_sum_pop` 4,24→1,85, `str_index_loop` 3,29→1,33, `sieve` 1,63→1,15, `dict_int` 6,87→4,26, `sort` 0,99→0,96. |
| L kalıcı kapılar | [~] | selfhost lexer ≤1,2×, parse/fmt ≤1,3× + RSS-büyüme (nightly.yml). Kalan: Nox/C, Aether/Nyx, allocation/GC duraklama kapıları (karar: aşağıda). |

## [K] araştırma raporları (karar bekleyen)
- **B.3 escape analizi / region**: tahsis maliyeti süreyi belirlemiyor (blok −%46 ⇒ süre −%3). Selfhost için kazanç beklentisi düşük; genel dil için büyük değişiklik. **Öneri: yapma.**
- **B.4 AST depolama**: düz dizi (15,5 MB mantıksal vs Zig arena 51 MB). Düz dizi korunur. **Öneri: yapma.**
- **B.6 atomik olmayan RC**: `nox_rc_retain/release` koşulsuz atomik (`fetchAdd acq_rel`) ve codegen satır içi yolu `atomicrmw`; selfhost'ta ARC işlemi azdır (≈68 bin blok/MB). Tek iş parçacıklı kanıtlanamayan programda doğruluk riski (M:N). **Öneri: yapma; ancak thread-affinity kanıtı tasarlanacaksa ayrı bir tasarım turu.**
- **C.1/C.2 enum**: 3 M enum inşa+`match` 22 ms ≈ 7,3 ns/işlem (düz tamsayı ≈ 0,7 ns; ~10×). Tip temsili enum nesneleriyle yazılırsa (Aşama 3) her düğüm 7 ns. Seçenekler: (a) olduğu gibi; (b) yük taşımayan varyantlar için ölümsüz tekil nesne (D1.3'te "paylaşılan tekil" reddedilmişti); (c) tahsissiz skaler etiket (yeni değer tipi — dil anlambilimi değişir). **Karar gerekir.**
- **G.1/G.2 sembol tablosu / interning**: `dict_str_500k` 27,9 ms (Nox), `dict_int_1.5M` 14,4 ms; dize anahtarlı sözlük tamsayı anahtarlıya göre ~6× pahalı (500 bin vs 1,5 M anahtar normalize edilirse ≈ 17×/anahtar). Aşama 3 sembol tablosu `SymbolId` ile (tamsayı) tutulursa bu maliyet kalkar. **Karar gerekir (SymbolId + genel havuz).**

## Aşama 3 (typechecker) hazırlığı — J / I / K
- **J.1 tip temsili**: seçenekler (a) sınıf ağacı (okunaklı, tahsis başına ≈7 ns + ARC), (b) düz dizi + `TypeId` (AST ile aynı desen, tahsissiz, invariant denetimli), (c) interning (kimlik karşılaştırması O(1)). Öneri: **(b)+(c)**: düz tablo, yapısal karşılık tek `TypeId` (hash-consing).
- **J.2 scope/sembol tablosu**: `SymbolId` (interned) + düz kapsam yığını; `dict[str, ...]` yalnızca ilk girişte.
- **J.3 allocation stratejisi**: tüm tip/sembol verisi tek `TypeTable` nesnesinde düz listeler; arena yok, ARC yok (düz dizi korunur).
- **J.4 erken perf ölçümü**: her alt aşama (kapsam çözümü, ifade tipleme, çağrı çözümü) için `selfhost_perf_report.py` benzeri bench + Zig karşılaştırması; kapı eşiği ≤1,3×.
- **I.1–I.3 sınıflandırma**: tasarım kararları OPTIMAL_DESIGN (düz dizi, bayt toplu yazım, arena elemesi), ARC_AVOIDANCE (`P.sw/okl`, `P.cur`, kaldırılan yerel listeler), TEMPORARY_WORKAROUND (`NOX_FRAME_POINTERS`/`NOX_CLANG_EXTRA` ölçüm bayrakları, `list_u8` extern izni yalnız `with_rt`), REJECTED_WITH_EVIDENCE (`-O3`, `mk_*` toplu yazım, `indent_stack` alan taşıma, `append` yerine önceden boyutlandırma). Gereksiz `lowlevel`: `at()` tarzı işlevler artık maliyetsiz; ek azaltma gerekmiyor.
- **K dogfood defteri**: bu belge + liste "R2 profil bulguları" bölümleri defterin yeni alanlarını (sınıflandırma, mikro+uçtan uca sonuç, reddedilenler+kanıt, workaround kaldırma koşulu, kalıcı kapı) taşır; workaround kaldırma koşulları: `NOX_FRAME_POINTERS` Zig runtime çerçeve işaretçisi eklenince; `NOX_CLANG_EXTRA` deney bitince.

## N6 kabul
- Doğruluk: test-fast 875/875 (2336+ test), Zig↔Nox lexer/parser/astdump/fmt farksal paritesi farksız, `fmt_properties` 0 ihlal, precheck yeşil.
- Performans: lexer 0,53×, parse 0,69×, fmt 0,70× Zig; fmt RSS 0,49×; `lang_perf` gerileme yok.
- Açık: R2-L kalan kapılar, [K] kararları.
