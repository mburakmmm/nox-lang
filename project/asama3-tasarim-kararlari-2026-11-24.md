# Aşama 3 (typechecker) hazırlığı — tasarım kararları (2026-11-24)

Kaynak: `project/rapor2-sonuc-2026-11-24.md` ölçümleri; kararlar kullanıcıdan (AskUserQuestion, 2026-11-24).

| Madde | Karar | Gerekçe |
|---|---|---|
| R2-B.6 atomik olmayan RC | **YAPILMAYACAK** | Koşulsuz atomik ARC M:N güvenliğini sağlar; selfhost'ta ARC işlemi azdır (≈68 bin blok/MB), blok sayısı −%46 iken süre −%3: kazanç küçük, doğruluk riski büyük. Yeniden açma koşulu: thread-affinity kanıtı için ayrı tasarım turu. |
| R2-G.1/G.2 sembol tablosu | **`SymbolId` + derleme-ömürlü intern havuzu** | Dize anahtarlı sözlük tamsayı anahtarlıya göre ≈6× pahalı (dict_str vs dict_int). Havuz her derleme/LSP oturumunda yaratılır ve bırakılır; sınırsız büyüyen global havuz YOK. Typechecker yazımıyla (Aşama 3) birlikte uygulanır. |
| R2-J.1 tip temsili | **düz tablo + `TypeId` + hash-consing** (öneri, K kararıyla uyumlu) | AST ile aynı desen; tahsissiz, invariant denetimli (`nox_parse_validate` benzeri `nox_types_validate`); yapısal eşitlik = `TypeId` eşitliği. |
| R2-C.1/C.2 enum | **Tahsissiz skaler etiket** (karar: uygula; ayrı özellik fazı) | Aşağıdaki plan. |
| R2-L kalıcı kapılar | **`lang_perf` Nox/C kapısı** | `benchmarks/lang_perf/run.py --check` (tolerans 1,25×, yalnızca macOS nightly; taban çizgisi oran ölçütleri). Aether/Nyx ve GC duraklama kapıları AYRI iş. |

## Enum: kapsam ölçümü (v2.2.60) — ayrı, temiz bir oturumda yapılacak
Ölçüm (`enum_bench2`, 3 M işlem): ayırma 18 ms, **tekil örnek 15 ms (yalnız −%17)**, **skaler 1 ms (18×)** ⇒ tekil örnek denemeye değmez; kazanç yalnızca gerçek skaler temsilde. Kapsam: checker'da ≈135, codegen'de ≈45 `.class` dal noktası + `Type→TypeInfo` eşlemesi + `match` indirgemesi (`_tag`) + her iki backend + ARC (`heap = .none`) + FFI/reflect. Uzun bir oturum bağlamında yapılması token israfı/hata riski; bu bölümdeki aşamalı plan YENİ bir oturumda, sizin son onayınızla başlatılacak.

## Enum: tahsissiz skaler etiket — tasarım ve aşamalar
Durum: enum parser'da sıradan sınıflara indirgenir (`enum_variants` + sentezlenmiş kurucular); her varyant inşası bir ARC nesnesidir (≈7,3 ns, düz tamsayıya göre ~10×; `enum_bench`: 3 M inşa+match = 22 ms).
Hedef: **hiçbir varyantı alan taşımayan** ("düz") enumlar `int` etiketine derlenir; yük taşıyan enumlar nesne olarak kalır (davranış değişmez).
Aşamalar (her biri kendi golden testi, iki backend, ayrı sürüm):
1. **Checker**: düz enum bilgisi (`flat_enum`); `==`/`!=`, `match` (tüm varyantlar kapsanma denetimi), `str()`/`repr()`, sözlük/küme anahtarı, `isinstance`, varsayılan parametre, alan tipi olarak kullanım doğrulanır; kapsam dışı kullanımlar (örn. `ptr_of`) açık hata verir.
2. **Codegen**: inşa = sabit `int`; `match` = `switch`/karşılaştırma; ARC: heap-yönetimli DEĞİL (`retain/release` yok); `Value.heap = .none`, `qtype .w/.l`.
3. **Runtime/FFI**: `nox.reflect`, JSON/`str` kabukları ve `extern def` sınırı (enum → `int` olarak geçer).
4. **Selfhost + stdlib kayıt**: Nox parser/formatter enum yüzeyi (`printEnum`) aynı kalır (kaynak biçimi değişmez).
Doğrulama kapısı: `enum_bench` ≥ 5× hızlanma, tüm golden/IR anlık görüntüleri, Zig↔Nox farksal parite, bellek sızıntı testleri. Başlatmadan önce son onay: **kullanıcı** (dil anlambilimi + ABI etkisi).

## Enum: uygulama sonucu (v2.2.61)
**Uygulandı.** Plandan sapma (gerekçeli): aşama 1 (checker) "`flat_enum` bilgisi" yerine tek yüklem `ast.ClassDef.isFlatEnum()`; tip sistemi nominal kaldı, kapsam dışı kullanım hatası GEREKMEDİ — skaler `int` temsili konteyner/alan/closure/Optional/Task/Channel/FFI'ın tümünde doğrudan çalışır. Sınıf adı gereken yerler (örnek metod çağrısı, `_tag` okuması) için checker alıcıyı `__nox_flat("Sınıf", x)` ile sarar. Ayrıntı: spec §3.496. Gözlenebilir fark: `print/str/f-string/repr` etiketi (`1`) yazar (eskiden `Kind(_tag=1)`).
Ölçüm (ReleaseFast LLVM): `list[Kind]` 6,2×, kaçmayan inşa+match döngüsü 3,8× (eski temsil LLVM'de zaten ≈ 3 ns/işlem; skaler ≈ 0,8 ns ≈ düz tamsayı tabanı) — '≥5×' hedefi yalnızca kaçan (listede/alanda saklanan) biçimde sağlandı. Bağlı metod değeri (`f = c.name`) destekli; sözlük/küme anahtarı olarak enum zaten reddediliyordu (değişmedi).
