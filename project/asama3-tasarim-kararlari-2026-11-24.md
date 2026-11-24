# Aşama 3 (typechecker) hazırlığı — tasarım kararları (2026-11-24)

Kaynak: `project/rapor2-sonuc-2026-11-24.md` ölçümleri; kararlar kullanıcıdan (AskUserQuestion, 2026-11-24).

| Madde | Karar | Gerekçe |
|---|---|---|
| R2-B.6 atomik olmayan RC | **YAPILMAYACAK** | Koşulsuz atomik ARC M:N güvenliğini sağlar; selfhost'ta ARC işlemi azdır (≈68 bin blok/MB), blok sayısı −%46 iken süre −%3: kazanç küçük, doğruluk riski büyük. Yeniden açma koşulu: thread-affinity kanıtı için ayrı tasarım turu. |
| R2-G.1/G.2 sembol tablosu | **`SymbolId` + derleme-ömürlü intern havuzu** | Dize anahtarlı sözlük tamsayı anahtarlıya göre ≈6× pahalı (dict_str vs dict_int). Havuz her derleme/LSP oturumunda yaratılır ve bırakılır; sınırsız büyüyen global havuz YOK. Typechecker yazımıyla (Aşama 3) birlikte uygulanır. |
| R2-J.1 tip temsili | **düz tablo + `TypeId` + hash-consing** (öneri, K kararıyla uyumlu) | AST ile aynı desen; tahsissiz, invariant denetimli (`nox_parse_validate` benzeri `nox_types_validate`); yapısal eşitlik = `TypeId` eşitliği. |
| R2-C.1/C.2 enum | **Tahsissiz skaler etiket** (karar: uygula; ayrı özellik fazı) | Aşağıdaki plan. |
| R2-L kalıcı kapılar | **`lang_perf` Nox/C kapısı** | `benchmarks/lang_perf/run.py --check` (tolerans 1,25×, yalnızca macOS nightly; taban çizgisi oran ölçütleri). Aether/Nyx ve GC duraklama kapıları AYRI iş. |

## Enum: tahsissiz skaler etiket — tasarım ve aşamalar
Durum: enum parser'da sıradan sınıflara indirgenir (`enum_variants` + sentezlenmiş kurucular); her varyant inşası bir ARC nesnesidir (≈7,3 ns, düz tamsayıya göre ~10×; `enum_bench`: 3 M inşa+match = 22 ms).
Hedef: **hiçbir varyantı alan taşımayan** ("düz") enumlar `int` etiketine derlenir; yük taşıyan enumlar nesne olarak kalır (davranış değişmez).
Aşamalar (her biri kendi golden testi, iki backend, ayrı sürüm):
1. **Checker**: düz enum bilgisi (`flat_enum`); `==`/`!=`, `match` (tüm varyantlar kapsanma denetimi), `str()`/`repr()`, sözlük/küme anahtarı, `isinstance`, varsayılan parametre, alan tipi olarak kullanım doğrulanır; kapsam dışı kullanımlar (örn. `ptr_of`) açık hata verir.
2. **Codegen**: inşa = sabit `int`; `match` = `switch`/karşılaştırma; ARC: heap-yönetimli DEĞİL (`retain/release` yok); `Value.heap = .none`, `qtype .w/.l`.
3. **Runtime/FFI**: `nox.reflect`, JSON/`str` kabukları ve `extern def` sınırı (enum → `int` olarak geçer).
4. **Selfhost + stdlib kayıt**: Nox parser/formatter enum yüzeyi (`printEnum`) aynı kalır (kaynak biçimi değişmez).
Doğrulama kapısı: `enum_bench` ≥ 5× hızlanma, tüm golden/IR anlık görüntüleri, Zig↔Nox farksal parite, bellek sızıntı testleri. Başlatmadan önce son onay: **kullanıcı** (dil anlambilimi + ABI etkisi).
