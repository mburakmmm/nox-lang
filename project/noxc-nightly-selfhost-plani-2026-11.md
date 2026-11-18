# noxc-nightly / self-hosting: tam kapsamlı uygulama planı ve takip listesi

Kaynak karar: kullanıcı, 2026-11-18. Ayrıntılı gerekçe ve envanter: `project/bootstrap-plani-2026-11.md` (B3). Bu belge **uygulama planı + canlı takip listesidir**: bir iş bitince kutusu `[x]` olur ve sürümü yanına yazılır.

Durum işaretleri: `[ ]` açık · `[~]` sürüyor · `[x]` bitti (sürümle) · `[K]` kullanıcı kararı/eylemi gerekir · `[!]` engelli/risk.

> **DURUM: AKTİF (2026-11-18).** Dil yüzeyi donduruldu (v2.2.20–22, `project/dil-yuzeyi-acik-kalemler-2026-11-18.md`), GPT-6 sağlamlaştırma turu bitti (v2.2.25–27, `project/gpt6-sertlestirme-2026-11-18.md`). Aşama 0 sürüyor; yüzey değişikliği artık Nox portuna da yansıtılacak iş sayılır.

## 0. Verilen kararlar (yeniden tartışılmaz)

- Aynı depo (`nox-lang`), ayrı repo YOK. Nox kaynakları `selfhost/` altında; `zig build nightly` → `noxc-nightly` ikilisi.
- `noxc-nightly` = normal `noxc` + Nox ile yazılmış bileşenler (tek ikili). Her Nox bileşeni `--frontend nox|zig` benzeri bayrakla seçilir; **Zig bileşeni her zaman yedekte kalır** (Zig tohumu süresiz).
- Geçiş sırası: lexer → parser/AST → tip denetleyici → sahiplik + codegen → sürücü. Henüz Nox'a geçmemiş her şey Zig'den akar.
- Yeni dil özellikleri **önce Zig'de**, farksal testle sonra Nox'a (özellik dondurma yok).
- Nightly bir sürüm hattı değildir: semver "Latest"i değiştirmez, `noxc upgrade` yalnızca kararlı sürümü seçmeye devam eder; nightly günlük `nightly-YYYY-MM-DD` pre-release olarak çıkar. "Her commit bir sürümdür" politikası nightly için uygulanmaz.

## 1. İlkeler ve sınır kuralları

- [ ] **Eşdeğerlik kanıtı olmadan varsayılan olmaz.** Bir Nox bileşeni, aynı girdide Zig bileşeniyle bayt-bayt (ya da tanı metni birebir) eşdeğer çıktı verene kadar yalnızca `--frontend nox` ile seçilir.
- [ ] AGENTS §2 değişmez ilkeleri geçerli: ownership sözdizimi yok, unwind tablosu yok, global durum izin listesi (`project/global-state-allowlist.tsv`), her yeni özellik golden testli, her codegen değişikliği iki backend'de doğrulanır.
- [ ] Nox derleyici kodu "statik tipli, çıkarım yalnızca `:=` v1" kuralına uyar (`selfhost/` için stil rehberi: sağ taraf tipi açıksa `:=`).
- [ ] Hata mesajları ve konumlar Zig derleyiciyle **birebir** aynı kalır (golden'lar bunu kilitler).
- [ ] Performans bütçesi her aşamada ölçülür (bkz. §6); bütçeyi aşan bileşen varsayılan olmaz.
- [ ] İlerleme bu dosyada işaretlenir; her aşama kapanışında `CHANGELOG`ta bir giriş ve spesifikasyonda bir bölüm (AGENTS §7).

## 2. Mimari özeti

```
Nox kaynak (.nox)
   │
   ▼  [Aşama 1]  lexer      Zig  ──veya──  Nox (selfhost/lexer)      → Token dizisi (düz sayı arabelleği)
   ▼  [Aşama 2]  parser/AST Zig  ──veya──  Nox (selfhost/parser)     → AST (metin dökümü eşdeğer)
   ▼  [Aşama 3]  checker    Zig  ──veya──  Nox (selfhost/typecheck)  → tiplenmiş AST + tanılar
   ▼  [Aşama 4]  ownership+codegen  Zig ──veya── Nox                 → QBE / LLVM metni
   ▼  [Aşama 5]  sürücü / paket / CLI
   ▼
   qbe | clang  →  noxrt.o (Zig runtime, Nox'a TAŞINMAZ)
```

Bağlama (hibrit): `build.zig`, önce Zig'li `noxc`'yi (stage0) derler; stage0, `selfhost/*.nox`'u nesne dosyasına derler; nesne nightly ikilisine C ABI ile bağlanır. Veri sınırı düz sayı arabelleği (token) ya da bayt tamponu (AST dökümü/IR metni): kopyasız, ARC'siz.

## 3. Aşama 0 — Altyapı ve ön koşullar

Çıkış ölçütü: `zig build nightly` çalışır; Zig→Nox çağrısı kanıtlanmış; farksal test koşucusu ve CI hazır; derleyici-türü bir Nox iş yükü Python'dan hızlı ve çökmeden çalışıyor.

- [x] **0.1 Zig→Nox çağrı deneyi (v2.2.28):** Nox'ta tek bir işlev (`def count_ident_tokens(buf: ptr[u8], n: int) -> int`) nesne dosyasına derlenir, Zig'den C ABI ile çağrılır. Sonuç: yol A (statik bağlama) çalışıyor mu? Çalışmazsa ek bir "kütüphane olarak derle" kipi (`noxc build --lib`/`--emit-obj`) tasarlanır. `[K]` kütüphane kipi gerekirse AGENTS §16 gereği önce sorulur.
  **SONUÇ:** yol A çalışıyor (`selfhost/spike/01-zig-calls-nox/`, `run.sh` yeniden üretir): `.ll` → `clang -c` → `noxrt.o` ile Zig harness'a bağlanır; Nox işlevi `define i64 @ad(i64 %rt, ...)` dış bağlantılı; 1,9 MB tarama döngüsü Nox 0,67–0,79× Zig süresi. Kalan engel `main` simgesi ve hosted `--emit-obj` yokluğu → **0.3 için `[K]` kütüphane kipi sorusu aşağıda (§3.1)**.
- [x] **0.2 `selfhost/` iskeleti (v2.2.29):** `selfhost/nox.json`, `selfhost/lexer.nox`, `selfhost/tests/`, stil rehberi (`selfhost/README.md`).
- [x] **0.3 `zig build nightly` (v2.2.29):** stage0 → Nox nesnesi → bağlama → `zig-out/bin/noxc-nightly`. `zig build test` bu adımı kırmaz (nightly isteğe bağlı adım).
  **SONUÇ:** karar (B) uygulandı: gizli `noxc build --selfhost-obj` (`main` yerine `nox_lib_init`/`nox_lib_fini`, `lib_split` kodgen bayrağı; `async` üst düzey kod reddedilir); `compiler/selfhost_glue.zig` köprüsü yalnızca nightly seçeneğiyle analiz edilir; `noxc-nightly selfhost-info [dosya]` gizli komutu bağlı Nox bileşenini çalıştırır. Testler: `tests/cli/selfhost_obj_test.zig` (sınıf + global + sözlük, Zig harness). IR anlık görüntüleri değişmedi.
- [x] **0.4 `--frontend zig|nox` bayrağı (v2.2.30; bileşen bazında açma Aşama 1+):** `build/run/check/fmt` komutlarında; nightly'de varsayılan `zig`, bileşen eşdeğer olunca bileşen bazında açılır. Normal `noxc`te bayrak yok (ya da yalnızca `zig`).
- [x] **0.5 Tanı araçları (v2.2.30):** `noxc tokens <dosya>` (token dökümü, Nox/Zig ortak biçim), `noxc ast <dosya>` (mevcut `--dump` ile eşit), JSON çıktı seçeneği.
- [x] **0.6 Farksal test koşucusu (v2.2.30):** `scripts/frontend_diff.py` (+ `zig build frontend-diff-test`): tüm depo `.nox` dosyaları (git'in bildiği 1 257 dosya; ~9 800 sayısı gömülü/üretilmiş kaynakları da sayıyordu — Zig↔Zig koşusu Debug `noxc` ile 5 sn) üzerinde Zig ve Nox bileşenini çalıştırıp çıktıları karşılaştırır; fark = kırmızı; ilk farkı gösteren küçültücü (delta) çıktısı.
- [x] **0.7 Derleyici-türü kıyas seti (v2.2.31):** `benchmarks/compiler_bench/` (lexer, ağaç dönüşümü, dict[str,X] yoğun, str birleştirme); Zig ve Nox sütunu, hedef ≤ 3–5× Zig (parser/lexer için ≤ 3×).
  **SONUÇ:** `benchmarks/compiler_bench/` (`run.sh`): lex 2,7–3,0×, dict[str,int] 2,9×, ağaç dönüşümü 0,97×, str 1,3×: hepsi bütçe içinde, lexer sınırda (ayrıntı + iki dil bulgusu README'de).
- [x] **0.8 Derin özyineleme (v2.2.31):** fiber yığını sabit 192 KiB; derleyici görevleri için ayarlanabilir büyük yığın ya da açık-yığınlı yineleme; `NOX_STACK_PAINT` ile ölçüm; derin AST testi (100 bin düğüm).
  **SONUÇ:** fiber yığını bu yolda sınır değil (bileşenler senkron, yerel iş parçacığı yığınında çalışır). 8 MiB ana yığın iki çocuklu özyinelemede ~300 bin derinliğe yetiyor, 1 milyonda SIGSEGV; 256 MiB iş parçacığı 1 milyonu taşıyor → `selfhost_glue.runOnBigStack` (256 MiB). Parser/checker'a ayrı derinlik sınırı Aşama 2/3'te. Ayrıntı: `selfhost/spike/02-deep-recursion/README.md`, test `tests/cli/selfhost_obj_test.zig`.
- [ ] **0.9 CI hattı:** `nightly.yml` (günlük + `workflow_dispatch`): nightly derle, farksal test, kıyas, artifact `nightly-YYYY-MM-DD`; Release/`noxc upgrade` etkilenmez; `noxc upgrade --nightly` (isteğe bağlı, kararla).
- [ ] **0.10 Belgeler:** AGENTS.md §0 işaretçisi, spesifikasyon bölümü (§3.4xx "noxc-nightly"), `docs/` iç belge sayfası, bu listenin güncelleme kuralı.
- [ ] **0.11 Eksik dil/çalışma zamanı özellikleri (Aşama 0 değerlendirmesi):** jenerik `enum`, büyük `match` performansı, `dict[str, X]` hızı, `list[T]` ayırma/`str` birleştirme; bulgu listesi bu dosyaya eklenir `[K]`.

### 3.1 Karar (kullanıcı, 2026-11-18): temiz kütüphane kipi = (B) dahili `--selfhost-obj`

Deney `.ll` metnini elle işledi (`@main` yeniden adlandırma). `zig build nightly` için kalıcı çözüm gerekir; `noxc`de bugün `--emit-obj/--emit-static-lib` yalnızca mobil hedeflerde var. Seçenekler: **(A)** hosted hedefte `--emit-obj` açılır ve yeni bir `--lib-prefix <ön ek>` / modülde `main` simgesi atlanır ("kütüphane modülü": üst düzey kod çalıştırılmaz, `def`ler dışa aktarılır); **(B)** yalnızca `build.zig` için dahili bir `noxc selfhost-obj` alt komutu (kullanıcıya açılmaz); **(C)** `@export` dekoratörü + açık dışa aktarma listesi. Öneri: **(B)** ile başla (kullanıcı yüzeyi/AGENTS §16 riski yok), kanıtlanınca (A)'ya genelleştir.

## 4. Aşama 1 — Lexer (Nox)

Girdi: `compiler/lexer/{lexer,token,unicode_ident}.zig` (~1 400 satır, 68 token türü, girinti/dedent, f-string, kaçışlar, unicode tanımlayıcı). Çıkış ölçütü: tüm depo `.nox` dosyalarında Nox lexer çıktısı Zig lexer ile token-token aynı; hata konumu/mesaj golden'ları aynı; lexer iş yükü ≤ 3× Zig.

- [ ] 1.1 Token türü tablosu tek kaynaktan (`selfhost/token_kinds.nox` ↔ `token.zig`) üretilir; sıra/anlam uyumu testle kilitlenir.
- [ ] 1.2 Çekirdek tarama: boşluk, yorum, satır sonu, `;`, girinti yığını, `indent/dedent/newline` kuralları (parantez derinliği dahil).
- [ ] 1.3 Tanımlayıcı + anahtar sözcükler (+ unicode, `unicode_ident` tabloları).
- [ ] 1.4 Sayılar: int/float, `_` ayırıcı, hex/oct/bin, üs, taşma hataları.
- [ ] 1.5 Dizeler: tek/üç tırnak, kaçışlar, ham, bayt dizeleri, hata (kapanmamış dize).
- [ ] 1.6 f-string ham belirteci (parser içi bölme Aşama 2'de).
- [ ] 1.7 İşleçler ve `:=` kuralı (parantez dışında tek belirteç), `->`, `**=` vb.
- [ ] 1.8 Trivia (yorum/boş satır) kanalı — formatter için.
- [ ] 1.9 C ABI sarmalayıcı: `nox_lex(src_ptr, len, out_buf)` + Zig tarafı `Token` yeniden kurma (kopyasız dilimler).
- [ ] 1.10 Farksal test: tüm depo + fuzz korpusu (`tests/fuzz`); hata yolları (bad.nox serisi) aynı tanı.
- [ ] 1.11 Perf: 1 MB sentetik kaynak, ≥ Zig'in 1/3 hızı; bellek ≤ 2×.
- [ ] 1.12 `--frontend nox` ile lexer'ın nightly'de varsayılan yapılması `[K]` (kapanış raporu: fark sayısı 0, perf, bellek).
- [ ] 1.13 Belge + CHANGELOG + spesifikasyon bölümü.

## 5. Aşama 2 — Parser ve AST (Nox)

Girdi: `parser.zig` (~3 000 satır) + `ast.zig` (~640) + `ast_dump.zig`. Çıkış ölçütü: `--dump` çıktısı depodaki tüm dosyalarda Zig ile özdeş (`tests/golden/cases/*.ast.expected` dahil); sözdizimi hata konum/mesajları aynı; desugarlar (tuple açma, `match`, `defer`, dekoratör, dict/list comprehension, f-string bölme, lambda) birebir.

- [ ] 2.1 AST sınıf hiyerarşisi tasarımı (`selfhost/ast.nox`): ifade/deyim birleşim tipleri (sınıf hiyerarşisi + `kind` alanı; jenerik enum gerekirse dil işi `[K]`).
- [ ] 2.2 Token akışı okuyucusu (Aşama 1 çıktısı ya da yerel lexer), `peek/advance/expect`, hata kurtarma kuralları (Zig ile aynı).
- [ ] 2.3 İfade ayrıştırma: öncelik tırmanışı, üçlü, lambda, comprehension, `await/spawn`, çağrı/indeks/öznitelik, anahtar kelimeli argüman.
- [ ] 2.4 Deyimler: atama/artırılmış/`:=`, `if/while/for/try/with/match`, `def/class/protocol/enum`, `import`, `defer`, `global/nonlocal`.
- [ ] 2.5 Tip ifadeleri: basit, jenerik, `T | None`, fonksiyon tipleri.
- [ ] 2.6 Parser içi desugarlar (tuple açma `__nox_tup_*`, `match` konu geçicisi, sınıf sabitleri, `__infer`).
- [ ] 2.7 f-string bölme + iç ifade ayrıştırma.
- [ ] 2.8 Span/konum sistemi (`Span`, deyim başlangıç/bitiş) birebir.
- [ ] 2.9 AST dökümü (`ast_dump` eşdeğeri) + `noxc ast` aracı.
- [ ] 2.10 Hata iletileri ve `syntax_report`: konum + işaretçi gösterimi aynı.
- [ ] 2.11 C ABI: AST'nin Zig tarafına geçişi — **karar noktası `[K]`:** (a) Nox'un AST'yi bayt tamponuna serileştirmesi + Zig'in okuması (parser sınırı), ya da (b) Aşama 3'e kadar yalnızca doğrulama aracı olarak kalması (Zig checker Zig AST'siyle çalışır). Önerilen: (b) ile başla, checker Nox'a geçerken (a).
- [ ] 2.12 Farksal test: AST dökümü eşitliği (tüm depo), sözdizimi hata korpusu, `noxc fmt` (formatter Nox AST'siyle) çıktı eşitliği.
- [ ] 2.13 İlk "Nox ile üretilen araç": `noxc fmt` Nox lexer+parser ile (düşük risk, görünür kazanım).
- [ ] 2.14 Perf ≤ 3× Zig; bellek; derin ifade (10 bin iç içe) testi.
- [ ] 2.15 Belge + CHANGELOG + spesifikasyon.

## 6. Aşama 3 — Tip denetleyici (Nox)

Girdi: `compiler/typecheck/` (12 dosya, ~16 600 satır; `checker.zig` 12 640 satır tek başına) — en büyük ve en riskli aşama. Çıkış ölçütü: ~330 typecheck golden'ında aynı tanı (konum + metin); tüm doğru programlarda aynı tiplenmiş AST, aynı monomorphization listesi, aynı `infer_types`/`expr_rewrites` sonuçları.

Alt aşamalar (her biri ayrı kapanır, bir önceki bitmeden sonrakine geçilmez):

- [ ] 3.1 Tip temsili (`types.zig` eşdeğeri), tip eşitliği/atanabilirlik, `typeText`.
- [ ] 3.2 Kapsam/sembol tabloları, `declareVar`, modül düzeyi global terfi.
- [ ] 3.3 Temel ifadeler/deyimler: literal, aritmetik, karşılaştırma, atama, kontrol akışı, fonksiyon çağrıları.
- [ ] 3.4 Sınıflar: alanlar, `__init__`, metodlar, tekli/çoklu kalıtım, vtable kararı, mixin (`mixin_flatten`).
- [ ] 3.5 Optional daraltma (`if x is not None`, `and/or/not`, döngü), `Optional` kuralları.
- [ ] 3.6 Jenerikler/protokoller: monomorphization, kısıtlar, `ast_clone`.
- [ ] 3.7 Kapanışlar, iç içe `def`, `nonlocal` (`nonlocal_desugar`), lambda, `call_expand_apply`.
- [ ] 3.8 Jeneratörler/async (`generator_desugar`, `hoistNestedAsync`, `spawn` kuralları).
- [ ] 3.9 Enum/`match`/`derive`/dekoratör işlemleri.
- [ ] 3.10 Standart kütüphane çağrı kuralları: yerleşikler, str/list/dict/set metodları, `nox.*` yerleşik sihirli işlevler.
- [ ] 3.11 `index_call_fixup`, `bound_method_fixup`, `guard_normalize`, `class_attr_promote` geçişleri.
- [ ] 3.12 Modül yükleme/çözümleme (`module_loader`, `__all__`, from-import, paket yolu).
- [ ] 3.13 Tanı biçimi: hata kodu + konum + "çıkarım notu" (`:=`), `noxc explain` ile uyum.
- [ ] 3.14 Tiplenmiş AST'nin Zig codegen'e verilmesi — **karar `[K]`:** Aşama 4'e kadar köprü (serileştirilmiş tiplenmiş AST) ya da checker Nox'a geçince codegen de birlikte. Önerilen: serileştirme köprüsü (nightly'de her iki bileşen de çalışabilir).
- [ ] 3.15 Farksal: ~330 typecheck golden + tüm depo; tanı sırası/sayısı eşit; `llvm`/`qbe` backend bayrağı farkları.
- [ ] 3.16 Perf ve bellek bütçesi; derleme süresi (tüm stdlib kontrol: ≤ 2× Zig).
- [ ] 3.17 Belge + CHANGELOG + spesifikasyon.

## 7. Aşama 4 — Sahiplik analizi ve kod üretimi (Nox)

Girdi: `compiler/ownership/` (~900) + `compiler/codegen_qbe/` (28 dosya, ~31 800 satır). Çıkış ölçütü: 645+ IR anlık görüntüsünün hepsi **bayt-bayt aynı** (QBE) ve LLVM çıktısı fixture korpusunda davranış-eşdeğer; ASAP/ARC kararları (`explain`) aynı; sızıntı/çift-serbest testleri yeşil.

- [ ] 4.1 QBE/LLVM metin yazıcıları (`qbe_emit`, `llvm_emit`): çıktı biçimlendirici, geçici/etiket üretimi.
- [ ] 4.2 Tip düzeni (`layout`, `types`, `abi`, `mi_layout`): sınıf/liste/dict/str düzeni, vtable.
- [ ] 4.3 İfade/deyim codegen (`expr`, `stmt`, `calls`): çağrı kuralları, kısa devre, indeks, dilim.
- [ ] 4.4 Sahiplik: retain/release, ASAP/ARC kararları, `local_escape`, arena/yığın terfisi, hareket analizleri (`optimizations`, `ownership`).
- [ ] 4.5 İstisnalar/`finally`/`with`/`defer` (`exceptions`).
- [ ] 4.6 Kapanışlar, jeneratörler, async/thread (`closures`, `async_thread`).
- [ ] 4.7 Satır içi açma (`inlining`), tüketen sözleşme klonları, `ref_params`.
- [ ] 4.8 HTTP/FFI/HPy/decorator ara kodları (`http_intrinsics`, `ffi_callback`, `hpy_sigs`, `decorators`).
- [ ] 4.9 Modül global durumu (`shared_globals`, `globals`), `dyn_share`.
- [ ] 4.10 Hedefler: wasm/freestanding/mobil farkları, `wasm_abi_table`.
- [ ] 4.11 Farksal: IR anlık görüntüleri bayt-bayt, fixture korpusu iki backend, `explain` çıktıları, sızıntı testleri.
- [ ] 4.12 Perf: derleme süresi ≤ 2× Zig, bellek ≤ 2×.
- [ ] 4.13 Belge + CHANGELOG + spesifikasyon.

## 8. Aşama 5 — Sürücü ve araçlar (Nox)

- [ ] 5.1 `noxc check/build/run/test/fmt/explain/expand` sürücüsü Nox'ta (clang/qbe/zig çağrıları `nox.process`).
- [ ] 5.2 Paket sistemi: `nox.json`, kilit dosyası, `fetch/update/add/delete/publish/search/login/install` (mevcut CLI testleri aynı).
- [ ] 5.3 `noxc upgrade`/imza/SBOM/doğrulama.
- [ ] 5.4 LSP/bindgen — **kapsam dışı bırakılabilir `[K]`** (Zig'de kalır; Aşama 6 sonrası ayrı karar).
- [ ] 5.5 CLI davranış testleri (yardım ekranı, hata mesajları, çıkış kodları) aynı.

## 9. Aşama 6 — Sabit nokta ve devralma

- [ ] 6.1 `scripts/bootstrap.sh`: stage0 (Zig'li noxc) → stage1 (stage0 ile derlenmiş Nox noxc) → stage2 (stage1 ile) → stage3; **stage2 ≡ stage3 bayt-bayt**.
- [ ] 6.2 CI'da zorunlu sabit-nokta testi; ikili boyut ve derleme süresi bütçesi (Nox-noxc ≤ 2× Zig-noxc süresi).
- [ ] 6.3 Nox-noxc'nin `zig build test` korpusunun tamamını geçmesi (iki backend).
- [ ] 6.4 Üretim varsayılanına geçiş kararı `[K]` (Zig tohumu bootstrap-only kalır).
- [ ] 6.5 Yeniden-bootstrap rehberi (tohum güncelleme prosedürü) + yedek tohum ikilisi arşivi.

## 10. Performans/bellek bütçeleri (kapı ölçütleri)

| Bileşen | Süre (Zig'e göre) | Bellek | Ölçüm |
|---|---|---|---|
| Lexer | ≤ 3× | ≤ 2× | 1 MB kaynak |
| Parser | ≤ 3× | ≤ 2× | tüm stdlib |
| Tip denetleyici | ≤ 3× | ≤ 2× | tüm stdlib + örnekler |
| Codegen | ≤ 3× | ≤ 2× | fixture korpusu |
| Toplam derleme | ≤ 2× | ≤ 2× | `noxc build` büyük proje |

Bütçe aşılırsa: önce `NOX_RC_STATS`/`sample` ile bellek yönetimi payına bak (B1 bulgusu: sınıf-ağırlıklı iş yüklerinde süre ~%70 bellek yönetimi), arena/tahsis desenleri, sonra algoritma.

## 11. Riskler ve karşı önlemler

- [!] **Çift bakım:** her özellik iki bileşende → "önce Zig, sonra farksal testle Nox" kuralı + CI kırmızısı.
- [!] **Zig→Nox çağrı yolu belirsiz (0.1):** başarısızsa kütüphane kipi tasarımı (AGENTS §16 sorusu); yedek: ayrı süreç + JSON (yavaş ama çalışır).
- [!] **Derin özyineleme/yığın (0.8):** erken ölçülür; çözülmeden Aşama 2'ye geçilmez.
- [!] **Performans:** sınıf-ağırlıklı iş yükü; B1 çalışmaları 28 → 16 ms; her aşamada kıyas.
- [!] **Jenerik enum açık:** AST için sınıf hiyerarşisiyle başlanır; dil işi gerekirse `[K]`.
- [!] **Zaman çizelgesi belirsiz:** tek geliştirici 6–8 ay, AI destekli paralel çalışmayla 3–4 ay tahmini (B3 belgesi); her aşama kapısı yeniden tahmin getirir.
- [!] **Hata mesajı sapması:** golden'lar + farksal testler kilitler.

## 12. Sıralı ilk adımlar (başlangıç)

1. [x] 0.1 Zig→Nox çağrı deneyi (tek işlev, C ABI) — v2.2.28.
2. [x] 0.2 + 0.3 `selfhost/` iskeleti ve `zig build nightly` — v2.2.29.
3. [x] 0.5 + 0.6 `noxc tokens` ve farksal test koşucusu (lexer için) — v2.2.30.
4. [x] 0.7 + 0.8 derleyici kıyas seti ve yığın çözümü — v2.2.31.
5. [ ] Aşama 1 (lexer) başlangıcı.

## 13. İlerleme özeti (el ile güncellenir)

| Aşama | Madde | Bitti | Durum |
|---|---|---|---|
| 0 Altyapı | 11 | 8 | sürüyor (0.1–0.8 bitti; sıradaki 0.9 CI, 0.10 belge, 0.11 değerlendirme) |
| 1 Lexer | 13 | 0 | açık |
| 2 Parser/AST | 15 | 0 | açık |
| 3 Tip denetleyici | 17 | 0 | açık |
| 4 Sahiplik + codegen | 13 | 0 | açık |
| 5 Sürücü | 5 | 0 | açık |
| 6 Sabit nokta | 5 | 0 | açık |
