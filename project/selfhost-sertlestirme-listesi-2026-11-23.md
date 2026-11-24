# Selfhost sağlamlaştırma + mühendislik/performans listesi (GPT-6 raporları nox-1 / nox-2, 2026-11-23)

Kaynak: `~/Desktop/nox-1.md` (Aşama 1/2: sağlamlaştırma, ref. v2.2.44) ve `~/Desktop/nox-2.md` (Aşama 2/2: mühendislik/performans). Sıra ve karar: kullanıcı, 2026-11-23 — önce Rapor 1 (P0 → P1), sonra Rapor 2 N.1–N.2; N.3/N.4 ölçümlere göre ayrı karar. Durum işaretleri: `[x]` bitti (sürüm) · `[ ]` açık · `[~]` kısmen · `[K]` kullanıcı kararı bekliyor · `[-]` yanlış pozitif/geçersiz (kanıtla).

**Çalışma kuralları (ikisi için):** her bulgu önce güncel kaynakta/reproducer ile doğrulanır; kök neden düzeltilir; kalıcı regresyon testi (LLVM + QBE); davranış değişikliği kullanıcı onayı; perf'e dokunan düzeltme ölçülür (ReleaseFast, C sütunu). **Token tasarrufu:** kod analizinde önce `graphify query/path/explain` (AGENTS.md "Kod grafı" kuralı), kod değişince `sh scripts/graphify_refresh.sh --wait`; rtk hook'u (Claude Code yeniden başlatılınca) komut çıktısını sıkıştırır.

## Rapor 1 — Sağlamlaştırma (Aşama 3 öncesi, ZORUNLU)

### P0
- [x] **R1-P0.1** Modüller arası aynı adlı global çakışması — v2.2.45 (modül öneki + `from M import VAR` takma değişkeni; farklı tipli varyant doğrulandı: `42 3`). Kalan: [ ] selfhost'taki geçici benzersiz adları (`G_FOUT`/`G_FMEM`) geri al (kozmetik); [ ] worker-local/paylaşılan global + closure + selfhost-obj yolunda ek test; [ ] type-alias modül izolasyonunun gerilemediğini doğrula.
- [x] **R1-P0.2** Liste büyütme OOM'da sınır dışı yazma: `nox_list_grow`/`nox_arena_list_grow` null döner (başlığa dokunmaz) ama `genListAppend` dönüşü atıp yazıyor (`compiler/codegen_qbe/calls.zig` ~2769). *Kaynakta doğrulandı, çalıştırarak değil.* Çözüm: fail-stop (kanıtla tüm yollarda tutarlı) ya da dönüş kontrolü; extend/insert/arena/shared yolları; fault-injection testi; heap elemanlı retain hata yolu. **v2.2.46:** `genListAppend` büyütme dönüşünü denetler; null ise `nox_out_of_memory` (fail-stop, diğer tahsis yollarıyla aynı politika), hem normal hem arena listesi; IR anlık görüntüleri yenilendi. Kalan: [ ] fault-injection ile çalıştırılan test (OOM'u zorlayan düzenek yok), [ ] `nox_list_push/reserve/concat/copy/slice` null dönüşlerinin tüketicileri (null → deref çökmesi, bozulma değil) ve `extend/insert` denetimi.
- [x] **R1-P0.3** Alias ile Optional alan daraltması (`alias.left = None` sonrası `n.left.value`) — **reproducer çalıştı: checker kabul, program sessiz `rc=1` çöküyor.** Muhafazakâr invalidation (alan adı bazlı: `X.f = ...` aynı alan adına sahip tüm daraltmaları düşürür); iç içe yollar, koleksiyon alias'ı, closure/global/method/generic testleri; kanıtlı güvenli daraltmaları gereksiz kaldırma. **v2.2.46:** `X.f = ...` ataması `f` alan adını kök-olmayan adım olarak taşıyan TÜM yol daraltmalarını düşürür (takma ad + yolu çözülemeyen hedefler); `tests/cli/optional_narrowing_safety_test.zig`. Kalan: koleksiyon içi alias varyantları, closure `nonlocal` (Optional nonlocal şu an `__nl_x` tip uyuşmazlığı veriyor → ulaşılamıyor), global/generic varyantları.
- [x] **R1-P0.4** Yan etkili bileşik koşul (`n.left != None and clear(n)`) — **reproducer çalıştı: kabul + çökme.** `collectNarrows` sağ operand yan etkisinden sonra eski kanıtı yeniden üretiyor; and/or/not, if/elif/while/erken dönüş guard'ları. **v2.2.46:** `A and B`/`A or B` için sağ operand kullanıcı kodu çalıştırabiliyorsa (`mayRunUserCode`) sol operandın yol daraltmaları atılır; if/while/or-else testleri. Kalan: ternary/`not` birleşimleri için ek test.
- [~] **R1-P0.5** Yerleşik çağrılar (`str/repr/print/len`) üzerinden daraltma (`callKeepsNarrows`): raporun `print(str(b))` örneği doğru reddedildi; çıplak `print(n)`/`len(x)`/protocol/vtable/FFI/await varyantları denenecek. **v2.2.46 (kısmen):** `hasDunder` bayrağı + `checkExpr` sarmalayıcısı: kullanıcı dunder'ı (`__str__/__len__/__add__`…) çağrılabilen her ifade sonrası yol daraltmaları düşer (sıralı ifadeler); `str(n)` ile test. Kalan: aynı koşul İÇİNDEKİ dunder (`and print(n)` biçimi; sözdizimsel yardımcı tipi bilmiyor), `@property`, çıplak `print(n)`/`len(x)` varyantları, protocol/vtable/FFI/await.
- [x] **R1-P0.6** (v2.2.47; kullanıcı onayı 2026-11-23: Python semantiği) Yan etkili indeks atamasında sınır kontrolü sağ taraftan ÖNCE (`xs[2] = clear_and_return(xs)` → Python `IndexError`; Nox sessizce geçiyor, `len=0`). Varyantlar: append/clear/pop, negatif indeks, indeks ifadesi yan etkisi, heap elemanlı, iç içe, paylaşılan, bileşik atama. **[K] Python semantiğine dönüş (RHS → indeks → sınır kontrolü): onay iste.**

### P1
- [~] **R1-P1.1** (v2.2.49: denetim tablosu `project/liste-basligi-denetimi-2026-11-24.md`; eksik testler adlandırıldı) Kararlı liste başlığı: tüm sahiplik/runtime yolları denetimi (ARC, cycle collector, ayrı tampon, stash, arena, stack liste, escape analizi, SharedList, M:N, sabit genişlikli, heap elemanlı, iç içe, dict/alan, exception cleanup, stdlib listeleri) + DebugAllocator doğrulaması.
- [~] **R1-P1.2** (v2.2.49: `detach/adopt` adlı çalışma zamanı API'si BULUNAMADI; sözleşme belgelenecek — denetim belgesi) `detach/adopt` + FFI sözleşmesi (`data - 16` ≠ gerçek ARC başlığı); NNI/NAPI/HPy köprüleri; desteklenmeyen ham ABI kullanımını açıkça belgele.
- [~] **R1-P1.3** (v2.2.49: kilitsiz büyüme tasarım sınırı doğrulandı (atomik olmayan data/cap + serbest bırakılan eski tampon); M:N yarış testi açık) Ortak sahiplik/eşzamanlı erişim: worker büyütürken diğerinin eski `data`sını okuması; len/cap/data tutarlılığı; TBAA/LICM `data` yükünü döngü dışına taşıması; global liste yeniden atamaları. (Genel kilit EKLEME.)
- [x] **R1-P1.4** GC büyük-tahsis sayacı resize muhasebesi (`noteLargeResize` → eşik kontrollü `noteLargeAlloc/Free`; `accounted(size)` farkı ile düzelt; birim testi: büyüt/küçült/aynı sınıf/realloc başarısız/serbest). *Eşik davranışı henüz doğrulanmadı.* **v2.2.46:** `noteLargeResize` artık eski/yeni boyutun muhasebe katkıları arasındaki farkı kullanır (eşik altı fark sayılmama + serbest bırakmada tam boyut düşme → işaretsiz taşma yok); `runtime/alloc/asap.zig` birim testi. Not: yol yalnızca libc-large (≥256 KiB) bloklar için erişilebilir (`nox_list_reserve` küçük büyümeleri).
- [ ] **R1-P1.5** Paralel cycle collector OOM: white nesne keşfi/birleştirme tahsis hatalarının yutulması; fault-injection (mark/scan düzeltmesini yeniden tasarlama).
- [x] **R1-P1.6** `Runtime.start`: `nox_runtime_init` null kontrolü yok (`compiler/selfhost_glue.zig:48`) — **kaynakta doğrulandı.** Kontrollü hata; kısmi init temizliği; çift start/stop. **v2.2.46:** `Runtime.start` `error.RuntimeInitFailed` döner, `runOnBigStack` hatayı iletir (bellek yetersizliği enjekte edilemediği için çalıştırılan test yok). Kalan: çift start/stop incelemesi.
- [x] **R1-P1.7** (v2.2.48: selfhost-contract + sembol testi) Zig–Nox ABI sınırı sözleşmesi: bekleyen istisna, hata kodları, OOM/IndexError, global durum temizliği, tampon sahipliği, ardışık çağrılar, fini sırasında bekleyen istisna. Hiçbir Nox hatası Zig'de başarı sayılmamalı.
- [x] **R1-P1.8** (v2.2.48: init/fini, iki çalışma zamanı, sembol sözleşmesi testi) Birleşik selfhost nesnesi: init/fini sırası, modüller arası bağımlılık, tekrar import, çift bağlama; gelecekte ayrı nesne dosyaları için sembol sözleşmesi.
- [x] **R1-P1.9** `scripts/frontend_diff.py`: sonuç kategorileri (SUCCESS / EXPECTED_LANGUAGE_ERROR / COMPILER_CRASH / TIMEOUT / OOM / INFRASTRUCTURE_ERROR / UNEXPECTED_EXIT); ortak çökme/timeout ASLA başarı değil; Windows kodları; reducer kategoriyi korur; selftest'e ortak crash/timeout. *Doğrulandı: şu an ortak çökme eşit sayılıyor.* **v2.2.46:** `frontend_diff.py` sonuçları sınıflandırır (SUCCESS/EXPECTED_LANGUAGE_ERROR/COMPILER_CRASH/TIMEOUT/OOM/INFRASTRUCTURE_ERROR/UNEXPECTED_EXIT); yalnızca ilk ikisi eşdeğerlik kanıtı; selftest'e ortak çökme/timeout/OOM/sinyal eklendi. Kalan: Windows özel durum kodları gerçek ortamda, reducer kategoriyi açıkça korusun (şu an `same()` üzerinden dolaylı).
- [x] **R1-P1.10** (v2.2.49: fixture_oracle.py + expected_errors.txt; oracle `f"{a b}"` parser hatasını buldu/düzeltti; bilinen bulgu: CRLF + üç tırnaklı string içeriği `\r\n` korunuyor — `ok_strings.nox` CRLF_KNOWN, karar gerekir) Bağımsız oracle fixture'ları (spec tabanlı), pozitif fixture'ın gerçekten ayrıştığını zorunlu doğrula (ok_* tekrarını otomatik engelle), negatif için hata türü+konum; geçerli kaynaklar mutasyondan ayrı raporlanır; CRLF testi korunur.
- [x] **R1-P1.11** (v2.2.48: başarısız fmt kaynak değiştirmez testi) Formatter hata eşdeğerliği: `build.zig` fmt diff adımına `--stderr` (yol normalizasyonu ile); başarısız fmt kaynağı değiştirmez testi. *Doğrulandı: şu an stderr karşılaştırılmıyor.* **v2.2.46 (kısmen):** build.zig fmt farksal adımına `--stderr` eklendi. Kalan: başarısız fmt kaynak dosyayı değiştirmez testi.
- [~] **R1-P1.12** (v2.2.50: 73→4 ihlal; kalan yalnız 4 CRLF; Zig+Nox birlikte düzeltildi; v2.2.49: fmt_properties.py idempotence+semantik+CRLF; 73 bilinen ihlal tabanda (`scripts/fmt_properties_baseline.txt`): 64 idempotence (boş satır büyümesi, ör. `class` sonrası `protocol`), 5 semantik, 4 CRLF. KALAN: ihlallerin düzeltilmesi (Zig + Nox formatter birlikte) ve tabandan silinmesi; float bit deseni/kapsam listesi) Formatter: parity + **idempotence** (`fmt(fmt(x)) == fmt(x)`) + **semantik koruma** (AST eşitliği, span/trivia normalize); float bit deseni; f-string/escape/Unicode/CRLF/Optional/generic/unpack/match/else/multi-with/dekoratör/öncelik/yorum kapsamı; Zig formatter hatalarının Nox'a taşınmaması.
- [~] **R1-P1.13** (v2.2.48: ayrı süreç tepe-RSS `scripts/selfhost_bench.sh` + eşdeğer-değil etiketi; KALAN: Nox tarafı toplam-tahsis/tepe-canlı-heap sayaçları, ReleaseFast ile bütçe yeniden değerlendirmesi) Bellek ölçümü eşdeğerliği: parser/formatter 0,31×/0,20× (Nox mantıksal bayt ↔ Zig `queryCapacity`) **eşdeğer değil**; 6 metrik (mantıksal, ayrılmış heap, tepe canlı heap, toplam tahsis, tepe RSS, bitişte kalan) iki tarafta ayrı süreçte; plan §10 bellek bütçesi bu metrikle yeniden değerlendirilir.
- [~] **R1-P1.14** (v2.2.48: Debug reddi, anlamsız sonuç reddi, kip/commit başlığı; KALAN: soğuk başlangıç ayrı ölçüm) Debug/ReleaseFast runtime karışması: benchmark başında kip doğrulama (Debug ile perf reddedilir), çıktı yolları ayrımı, soğuk başlangıç ayrı, rapora backend/flags/runtime/commit, boş/anlamsız sonuç kapıdan geçmez.

### P2
- [ ] **R1-P2.1** `put_span_suffix` O(n²) → üretici (`scripts/gen_selfhost_ast.py`) düzeltilir; bayt eşdeğerliği; benchmark.
- [ ] **R1-P2.2** Nightly platform/dağıtım: Windows kapsamı, runtime/stdlib/backend dağıtım sözleşmesi belgesi, desteklenmeyeni "doğrulandı" raporlama.

### Regresyon denetimi (H) ve ekosistem (I) ve matris (J)
- [ ] **R1-H** Önceden düzeltilmiş konuların yeni liste mimarisi + selfhost sonrası gerilemediğini kontrol et (Aether worker istisnası v2.2.25, SafeHTTP, GC mark/scan OOM, GC seri/paralel eşdeğerlik, yıldızlı unpack uzunluk kontrolü, type alias izolasyonu, lexer span/CRLF, sızıntı testleri, liste alias semantiği, QBE=LLVM).
- [ ] **R1-I** Gerçek ekosistem uyumluluğu: Nyx, Aether, Aura, Nova, Noxen, Rune, Feather, Atlas, Quartz, Vault (+ Nox 1.2 dönemi Nyx web uygulaması: değişiklik gerektirmeden derleme, HTTP davranışı, çok worker, sızıntı, perf). Erişilemeyeni açıkça raporla. (CI'da Aether+Nyx fixture'ları zaten var.)
- [ ] **R1-J** Her düzeltme için test matrisi: LLVM+QBE, Debug (bellek) + ReleaseFast (davranış), Linux/macOS/Windows, WASM/freestanding/mobil (etkileniyorsa), NNI/HPy, M:N. Perf: güncel baseline (benchmark seti+sürüm kesinleştir), düzeltme sonrası aynı set; güvenlik kontrolleri perf için kaldırılmaz.
- [ ] **R1-L** Aşama 1 tamamlanma ölçütleri (rapor Bölüm L) karşılandı, açık P1/P2 maddeleri gerekçeli kayıtlı. Sonuç raporu: bulgu başına Bölüm K formatı.

## Rapor 2 — Mühendislik/performans (Phase 2.5; R1 bittikten sonra)

### N.1 Ölçüm altyapısı (önce)
- [x] **R2-N1.a** (v2.2.49: ReleaseFast taban ölçümü aşağıda; BULGU: art arda çağrılarda Nox belleği geri vermiyor → R1-P1.7b) R1-P1.13/P1.14 ölçüm düzeltmeleri doğrulanır; güncel Nox/C baseline (hangi set+sürüm+koşul).
- [ ] **R2-A.1** Lexer/parser/formatter uçtan uca CPU+ARC profili (kategori tablosu: ARC, allocation, list, string, algoritma, ABI; inclusive/exclusive ayrı; instrumentation'lı ölçüm normalden ayrı).
- [ ] **R2-A.2** Saf Nox vs hibrit (Zig'e statik bağlı) 10 senaryo; fark açıklanır (ABI köprüsü, codegen, link, kopyalama).
- [ ] **R2-A.3** Adil benchmark protokolü (ReleaseFast, warm-up, medyan/min/dağılım, RSS, tahsis sayısı/baytı, sürüm kaydı; sabit katlama engeli).

### N.2 Düşük riskli iyileştirmeler
- [ ] **R2-D.1** Lexer token başına 5 `append` → toplu yazım (9 alternatif ölç; yeni public API ekleme; genel optimizasyon, selfhost'a özgü kural yok).
- [ ] **R2-D.2** `at()/peek()/emit()` inlining analizi (LLVM IR + asm; bayt başına çağrı kalıyor mu; zorla inline yok).
- [ ] **R2-D.3** Lexer veri yerleşimi: gerçek uygulama vs eşdeğer (aynı düz tampon) karşılaştırması.
- [ ] **R2-D.4** Lexer köprüsü maliyetini doğrudan ölç (kopya, Token dönüşümü allocation).
- [ ] **R2-E.2** `mk_*` oluşturucularında toplu yazım (üretici `gen_selfhost_ast.py`).
- [ ] **R2-E.3** Span araması (R1-P2.1 ile aynı iş; performans+bellek etkisi ölç).
- [ ] **R2-E.5** AST sentezlenmiş bayt/çıktı tamponu `list[int]` (8 B/bayt) → `list[u8]`/Buffer.
- [ ] **R2-F.1/F.2/F.3** Formatter `w()` bayt başına `append`+`ord(s[i])`; küçük geçici tahsisler (`wint` digit listesi, `float_from_bits` tek elemanlı liste); aşama aşama süre (lex/parse/traversal/format/çıktı/aktarım/cleanup).
- [ ] **R2-E.4** (yalnızca köprü yeniden kullanılacaksa) eleman başına ABI çağrısı yerine toplu aktarım; tiplenmiş AST köprüsü eleman başına ABI ile KURULMAZ.

### N.3 Derleyici optimizasyonları
- [ ] **R2-H.1/H.2/H.3** Inlining, bounds check, redundant load/store, TBAA/alias, cold path; LLVM vs QBE farkı (gerçek parser/formatter dispatch'i ölç); `--selfhost-obj` makine kodu kalitesi (visibility, init/fini, runtime parametresi, link/DCE).
- [ ] **R2-B.2/B.5** ASAP gerçek kullanım oranı (stack/arena/ARC sınıflandırma + neden); borrowed parametre/gereksiz retain-release; `_c` consuming clone etkisi.
- [ ] **R2-G.3** Kararlı liste başlığı perf doğrulaması (append yerel/alan/parametre/iç içe, sabit genişlikli, heap elemanlı, traversal, sieve, matmul, sort, copy; lexer/parser/formatter); alias doğruluğundan geri dönülmez.

### N.4 Araştırma — her biri ölçümlü tasarım raporu + KULLANICI KARARI (otomatik uygulanmaz)
- [K] **R2-B.3** Nesne grafiği escape analizi / region inference / arena kümeleri.
- [K] **R2-B.4** AST için arena/ARC/ASAP/düz dizi karşılaştırması (düz dizi korunur).
- [K] **R2-B.6** Atomik olmayan RC hızlı yolları (varsa mevcut thread-local/publish mekanizmasını önce incele).
- [K] **R2-C.1/C.2** Enum: immortal nesne, tahsissiz skaler tag, escape ile eliminasyon, statik varyant (D1.3'te yalnızca paylaşılan singleton reddedildi; diğerleri açık); küçük değer tipleri tahsissiz (yeni keyword YOK).
- [K] **R2-G.1/G.2** Sembol tablosu 2,87× kök neden; string interning/SymbolId (sınırsız büyüyen global havuz yok; LSP yaşam süresi).

### N.5 Typechecker hazırlığı (Aşama 3 öncesi)
- [ ] **R2-J.1–J.4** Tip temsili (sınıf/düz tablo/TypeId/interning/arena), scope+sembol tablosu senaryoları, allocation stratejisi, alt aşama başına erken perf ölçümü (işlevsel eşdeğerlik, allocation, bellek, CPU, Zig karşılaştırması, açık dogfood).
- [ ] **R2-I.1–I.3** Tasarım kararı sınıflandırması (OPTIMAL_DESIGN/ARC_AVOIDANCE/TEMPORARY_WORKAROUND/…); gereksiz `lowlevel` azaltma; kodun Nox'a özgü hale getirilmesi (ölçümle). **R2-E.1** düz dizi AST güvenliği (ofset doğrulama, tipli yardımcılar, debug invariant'ları).
- [ ] **R2-K** Dogfood defteri ek alanları (sınıflandırma, mikro+uçtan uca sonuç, reddedilenler+kanıt, workaround kaldırma koşulu, kalıcı perf kapısı).
- [ ] **R2-L** Kalıcı perf kapıları: kararlı uygulama (Nox/C, Aether/Nyx, alloc, koleksiyon/string), selfhost bileşenleri, bellek (RSS/canlı heap/allocation/GC pause), üretilen kod perf'i.
- [ ] **R2-N6** Son doğrulama + Bölüm P kabul ölçütleri; sonuç raporu Bölüm O formatı.

## İlerleme günlüğü
- 2026-11-23: liste açıldı; R1-P0.1 zaten v2.2.45'te kapalı. Doğrulama özeti: P0.3, P0.4 reproducer ile; P0.6 sessiz yanlış sonuç; P0.2 kaynakta; P1.6/P1.9/P1.11/P1.13 kaynakta.

- 2026-11-23: R1-P0.6 v2.2.47'de kapandı (genListAssign/genListSet/genDictAssign: RHS → indeks → sınır; golden list_index_assign_rhs_first). Bilinen fark: alıcı ifadesi RHS'ten önce (Python'da sonra), yalnızca yan etkili alıcıda görünür.

- 2026-11-23: v2.2.48 toplu tur: P1.7/P1.8/P1.11 kapandı, P1.13/P1.14 kısmen ([~], kalanlar maddelerde).

- 2026-11-24: v2.2.50: P1.7b kapandı (kök neden macOS realloc), P1.12 ihlaller 73→4. YENİ açık: **R1-P1.7c** ReleaseFast nightly parse-nox hata iletisi çöp bayt (eski ikili de), küçük tekrar bulunamadı.

## R2-N1.a taban ölçümü (2026-11-24, v2.2.48 kaynak, aarch64-macos, ReleaseFast derleyici + çalışma zamanı, `zig build nightly -Doptimize=ReleaseFast --prefix`)
Korpus: `stdlib/nox/*.nox + selfhost/{lexer,parser,formatter}.nox` birleşimi, 990 487 B; 20 tekrar, en iyi süre. Komut: `noxc-nightly parse-bench|fmt-bench` ve `scripts/selfhost_bench.sh` (ayrı süreç tepe RSS).
| | Zig | Nox | oran |
|---|---|---|---|
| parse süre | 14,1 ms | 22,8 ms | **1,62×** |
| fmt süre | 18,8 ms | 38,9 ms | **2,07×** |
| parse tepe RSS, 1 tekrar | 45,7 MiB | 20,3 MiB | **0,45×** |
| fmt tepe RSS, 1 tekrar | 60,8 MiB | 29,8 MiB | **0,49×** |
| parse tepe RSS, 5 tekrar | 45,7 MiB | 79,1 MiB | 1,73× |
| fmt tepe RSS, 5 tekrar | 60,8 MiB | 118,3 MiB | 1,95× |
| parse tepe RSS, 20 tekrar | 45,7 MiB | 292,4 MiB | **6,40×** |
| fmt tepe RSS, 20 tekrar | 60,8 MiB | 444,8 MiB | **7,32×** |
Küçük girdide (0,32 MiB tek dosya) süre oranı 5,5–5,9× (sabit maliyet baskın); plan bütçesi (≤3×) büyük korpusta sağlanıyor. "Mantıksal bayt 0,31×/0,20×" iddiası eşdeğer metrik DEĞİLDİR; tek tekrarda gerçek tepe RSS oranı 0,45–0,49× (iyi).
**BULGU (açık, yeni): R1-P1.7b** — aynı Nox çalışma zamanında art arda `parse`/`fmt` çağrıları her tekrarda ≈15 (parse) / ≈22 (fmt) MiB tutuyor (Zig tarafı sabit: `--side=zig` 45,7 MiB). Modül-global sınıf yeniden atamasının tek başına sızdırmadığı küçük bir tekrar üretimiyle doğrulandı; kaynak selfhost hattında (ör. `G_AST`/`lx.out`/arena çöp listeleri) aranmalı. `noxc` süreç-içi tek çağrıda sorun değil; LSP/izleme gibi uzun yaşayan kullanım için kritik. `selfhost-contract`a bellek-büyümesi sınırı eklenmeli.
- [x] **R1-P1.7b** (v2.2.50: kök neden macOS libmalloc realloc tutulması; `nox_list_realloc` macOS düzeltmesi; RSS-büyüme kapısı henüz YOK) Art arda selfhost çağrılarında bellek tutulması (yukarıdaki sayılar): kök neden, düzeltme, `selfhost-contract` + bench'te RSS-büyüme kapısı.
- [~] **R1-P0.5/P0.3 kalan:** v2.2.49: closure, çıplak `print(n)`, f-string, birleştirme, aynı koşuldaki `str(n)`, dolaylı `print(n)` yapan işlev kapandı; KALAN: `@property`, protocol/vtable/FFI/await varyantları.
- [x] **R1-P0.1 kalan** (v2.2.49: tür takma adı + closure izolasyon testi; `G_FOUT/G_FMEM` kozmetik geri alma YAPILMADI; worker-local/paylaşılan global testi yok).
