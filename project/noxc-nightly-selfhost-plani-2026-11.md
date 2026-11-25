# noxc-nightly / self-hosting: tam kapsamlı uygulama planı ve takip listesi

Kaynak karar: kullanıcı, 2026-11-18. Ayrıntılı gerekçe ve envanter: `project/bootstrap-plani-2026-11.md` (B3). Bu belge **uygulama planı + canlı takip listesidir**: bir iş bitince kutusu `[x]` olur ve sürümü yanına yazılır.

Durum işaretleri: `[ ]` açık · `[~]` sürüyor · `[x]` bitti (sürümle) · `[K]` kullanıcı kararı/eylemi gerekir · `[!]` engelli/risk.

> **DURUM: AKTİF (2026-11-18).** Dil yüzeyi donduruldu (v2.2.20–22, `project/dil-yuzeyi-acik-kalemler-2026-11-18.md`), GPT-6 sağlamlaştırma turu bitti (v2.2.25–27, `project/gpt6-sertlestirme-2026-11-18.md`). Aşama 0 sürüyor; yüzey değişikliği artık Nox portuna da yansıtılacak iş sayılır.

## 0. Verilen kararlar (yeniden tartışılmaz)

- **DEĞİŞMEZ KURAL (kullanıcı, 2026-11-18): TAM GEÇİŞ, KISMİ DEĞİL.** Her bileşen (lexer, parser/AST, checker, codegen, sürücü…) geçişe girdiğinde Zig karşılığının **tüm dil yüzeyini, tüm davranışını ve tüm çıktı alanlarını eksiksiz** karşılar; "şimdilik şu alt küme / şu hata yolu / şu alan sonra" yoktur. Geçiş parça parça (bileşen bileşen) ilerler, ama her parça kendi içinde tamdır. Her parça ayrıca: (1) **Nox dili kurallarına uygun** yazılır (zorunlu statik tipler, ownership sözdizimi yok, Nox'un kendi desenleri; Nox'ta olmayan bir şey için dil/runtime hilesi değil, açık bir dil kararı), (2) **performans bütçesi** içindedir (§10; aşıyorsa tamam sayılmaz), (3) **bellek uyumludur** (bütçe + sızıntı/çifte serbest bırakma testleri: Debug çalışma zamanında sızıntı denetimi yeşil), (4) farksal testle Zig ile aynı çıktıyı üretir (alan alan, hata konumu dahil). "Tamam" kutusu bunların hepsi sağlanmadan işaretlenmez; bilinen bir eksik varsa kutu `[~]` kalır ve eksik listelenir.
- **Performans maddeleri "kazancı küçük" diye kapatılmaz (kullanıcı, 2026-11-18):** gerçekçi yükle ölçülür, zararsızsa uygulanır ve kalıcı bırakılır, uygulanmadıysa açık kalır ve CI kapısıyla izlenir; "iş yok" ancak uygulanıp ölçüldükten sonra yazılır (bkz. dogfood defteri).
- **Dogfood kapanışı (kullanıcı önerisi, 2026-11-18):** her aşamanın sonunda `project/selfhost-dogfood-defteri-2026-11.md` ele alınır: aşama boyunca bulunan Nox/çalışma zamanı bulguları (Zig hatası → önce Zig'de düzelt; saf performans/bellek → ölçüyle düzelt; dil değişikliği → kullanıcıdan onay; tasarım gereği → belge/stil kuralı). Aşama ortasında düzeltme yapılmaz.
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
- [x] **0.9 CI hattı (v2.2.32; `noxc upgrade --nightly` ayrı karar bekliyor):** `nightly.yml` (günlük + `workflow_dispatch`): nightly derle, farksal test, kıyas, artifact `nightly-YYYY-MM-DD`; Release/`noxc upgrade` etkilenmez; `noxc upgrade --nightly` (isteğe bağlı, kararla).
  **SONUÇ:** `.github/workflows/nightly.yml` (günlük 02:17 UTC + elle): Linux x86-64 ve macOS arm64'te `zig build -Doptimize=ReleaseFast` → `zig build nightly` → `selfhost-info` → `frontend-diff-test` → `compiler_bench`; çıktı yalnızca artifact (`noxc-nightly-<OS>-<tarih>`, 14 gün). **`nightly-YYYY-MM-DD` GitHub pre-release'i varsayılan KAPALI**: yalnız elle tetiklemede `publish: true` ile (`--prerelease --latest=false`; `noxc upgrade` etkilenmez). Nox bileşenleri gelince farksal adım `--zig-only`den `--component`e geçer. `noxc upgrade --nightly` yapılmadı `[K]`.
- [x] **0.10 Belgeler (v2.2.32):** AGENTS.md §0 işaretçisi, spesifikasyon bölümü (§3.4xx "noxc-nightly"), `docs/` iç belge sayfası, bu listenin güncelleme kuralı.
  **SONUÇ:** AGENTS.md §0 işaretçisi, spesifikasyon §3.473–3.475, `docs/internals/architecture.md` (noxc-nightly) + `docs/internals/testing.md` (tanı komutları, farksal koşucu), `selfhost/README.md`. Güncelleme kuralı: bir iş bitince bu dosyada kutu `[x]` + sürüm; aşama kapanışında CHANGELOG girişi + spesifikasyon bölümü (AGENTS §7).
- [x] **0.11 Eksik dil/çalışma zamanı özellikleri (Aşama 0 değerlendirmesi, v2.2.32):** jenerik `enum`, büyük `match` performansı, `dict[str, X]` hızı, `list[T]` ayırma/`str` birleştirme; bulgu listesi bu dosyaya eklenir `[K]`.
  **BULGULAR (ölçümlü):**
  1. **Enum varyantları öbek nesnesidir** (retain/release): süreç-içi ölçümle 68 varyantlı `match` yalnızca **2–4 ns/dağıtım** (ilk ölçümdeki "~20 ns" soğuk-başlangıç yükünden kaynaklanan hataydı, v2.2.37'de düzeltildi); performans sorunu yok. Token/AST türleri yine de düz `int` sabitleri + `kind` alanı olarak tutulur (düz-dizi AST kararı). Jenerik enum zaten var (v2.1.24).
  2. **`match` yalnızca enum varyantı kabul ediyordu** → v2.2.37'de skaler `match` eklendi (dogfood D1.5). `if/elif k == C` zincirleri süreç-içi ~1 ns/68 kol: `switch` indirgemesine gerek yok (ilk "~20 ns" ölçümü hataydı).
  3. **`dict[str, X]`**: Zig `StringHashMap`e 2,9× (bütçe içinde, düzeltme gerekmez).
  4. **`list[T]`/`str` birleştirme**: 1,3× (bütçe içinde). `list[int]` üçlü append tabanlı lexer 2,7×: önceden ayrılmış arabellek Aşama 1'de denenecek.
  5. **Dil kuralları (değişiklik yok):** `lowlevel` içinde sınıf kurma/`list[Sınıf].append` yok → bayt okuma ayrı işlevde; özellik üzerinde Optional daraltma yok → yerel değişkene al.

### 3.1 Karar (kullanıcı, 2026-11-18): temiz kütüphane kipi = (B) dahili `--selfhost-obj`

Deney `.ll` metnini elle işledi (`@main` yeniden adlandırma). `zig build nightly` için kalıcı çözüm gerekir; `noxc`de bugün `--emit-obj/--emit-static-lib` yalnızca mobil hedeflerde var. Seçenekler: **(A)** hosted hedefte `--emit-obj` açılır ve yeni bir `--lib-prefix <ön ek>` / modülde `main` simgesi atlanır ("kütüphane modülü": üst düzey kod çalıştırılmaz, `def`ler dışa aktarılır); **(B)** yalnızca `build.zig` için dahili bir `noxc selfhost-obj` alt komutu (kullanıcıya açılmaz); **(C)** `@export` dekoratörü + açık dışa aktarma listesi. Öneri: **(B)** ile başla (kullanıcı yüzeyi/AGENTS §16 riski yok), kanıtlanınca (A)'ya genelleştir.

## 4. Aşama 1 — Lexer (Nox)

Girdi: `compiler/lexer/{lexer,token,unicode_ident}.zig` (~1 400 satır, 68 token türü, girinti/dedent, f-string, kaçışlar, unicode tanımlayıcı). Çıkış ölçütü: tüm depo `.nox` dosyalarında Nox lexer çıktısı Zig lexer ile token-token aynı; hata konumu/mesaj golden'ları aynı; lexer iş yükü ≤ 3× Zig.

- [x] 1.1 Token türü tablosu tek kaynaktan (`selfhost/token_kinds.nox` ↔ `token.zig`) üretilir; sıra/anlam uyumu testle kilitlenir.
  **SONUÇ (v2.2.33):** token türü tablosu tek kaynaktan: `scripts/gen_selfhost_lexer.py` `token.zig` sırasından üretir, `--check` precheck + `zig build test`te kilitler.
- [x] 1.2 Çekirdek tarama: boşluk, yorum, satır sonu, `;`, girinti yığını, `indent/dedent/newline` kuralları (parantez derinliği dahil).
  **SONUÇ (v2.2.33):** çekirdek tarama (boşluk, yorum, CR/CRLF, `\` devamı, `;`, girinti yığını, parantez derinliği).
- [x] 1.3 Tanımlayıcı + anahtar sözcükler (+ unicode, `unicode_ident` tabloları).
  **SONUÇ (v2.2.33):** tanımlayıcı + anahtar sözcükler (üretilmiş `kw_lookup`) + Unicode (`UNI_START/UNI_CONT` ikili arama, `std.unicode` doğrulamasıyla aynı).
- [x] 1.4 Sayılar: int/float, `_` ayırıcı, hex/oct/bin, üs, taşma hataları.
  **SONUÇ (v2.2.33):** sayılar.
- [x] 1.5 Dizeler: tek/üç tırnak, kaçışlar, ham, bayt dizeleri, hata (kapanmamış dize).
  **SONUÇ (v2.2.33):** dizeler (tek/üç tırnak, ham `r""`, kapanmamış dize hataları).
- [x] 1.6 f-string ham belirteci (parser içi bölme Aşama 2'de).
  **SONUÇ (v2.2.33):** f-string ham belirteci.
- [x] 1.7 İşleçler ve `:=` kuralı (parantez dışında tek belirteç), `->`, `**=` vb.
  **SONUÇ (v2.2.33):** işleçler ve `:=` kuralı.
- [x] 1.8 Trivia (yorum/boş satır) kanalı — formatter için.
  **SONUÇ (v2.2.33):** trivia kanalı (`want_trivia`; CRLF boş satır çifte sayım huyu dahil birebir).
- [x] 1.9 C ABI sarmalayıcı: `nox_lex(src_ptr, len, out_buf)` + Zig tarafı `Token` yeniden kurma (kopyasız dilimler).
  **SONUÇ (v2.2.33):** C ABI (`nox_lex_run/buffer/trivia_*`, `selfhost_glue.Runtime.lex`/`lexWithTrivia`); `noxc-nightly --frontend nox tokens`.
- [x] 1.10 Farksal test: tüm depo + fuzz korpusu (`tests/fuzz`); hata yolları (bad.nox serisi) aynı tanı.
  **SONUÇ (v2.2.33):** farksal: 1 258 dosya + 4 mutasyon tohumu × 4 000 girdi (düz), `--trivia` ve `--json --trivia` (3 000 + 3 000 girdi); 0 fark; dört hata sınıfı da kapsandı.
- [x] 1.11 Perf: 1 MB sentetik kaynak, ≥ Zig'in 1/3 hızı; bellek ≤ 2×.
  **SONUÇ (v2.2.33):** perf: 0,72 MiB stdlib metni Zig 3,6 ms, Nox 7,6 ms (**2,12×**), Token dizisine dönüşüm dahil 8,1 ms (**2,26×**); ham arabellek 40 B/token (Zig 56 B/Token).
- [x] 1.12 `--frontend nox` ile lexer'ın nightly'de varsayılan yapılması `[K]` (kapanış raporu: fark sayısı 0, perf, bellek).
  **KARAR (kullanıcı, 2026-11-18) ve SONUÇ (v2.2.34):** nightly'nin amacı self-hosting olduğundan Nox lexer'ı `noxc-nightly`de VARSAYILANDIR (`--frontend zig` Zig lexer'ına döner). `lexer.hook` (Zig `lexer.zig`) tokenize/tokenizeWithTrivia/tokenizeCapturingSpan çağrılarının arkasına Nox lexer'ını takar; `nightlyMain` tüm derleyiciyi 256 MiB yığınlı iş parçacığında ve tek Nox çalışma zamanıyla koşturur. Tüm hat kanıtı: 997 fixture için `check` çıktısı ve 60 örnekte `build` `.ll` metni kararlı `noxc` ile BAYT-BAYT aynı; `frontend_diff.py --component check` 1 258 dosyada 0 fark. CI: `lex-bench --max-ratio=3.0`.
- [x] 1.13 Belge + CHANGELOG + spesifikasyon bölümü.
  **SONUÇ (v2.2.33):** belge + CHANGELOG [2.2.33] + spesifikasyon §3.476.

### 4.1 Aşama 1 tam-geçiş denetimi (v2.2.35)

Değişmez kurala (§0) göre Aşama 1 yeniden denetlendi: (1) **yüzey/çıktı alanları:** tüm token alanları, trivia, TÜM hata kodları ve hata span'ı (bayt/satır/sütun/bitiş) Zig ile aynı (`tokens` çıktısına bayt aralığı eklendi, farksal test kapsıyor); açık eksik **yok**. (2) **Nox kuralları:** statik tipli, ownership sözdizimsiz; `lowlevel` yalnızca bayt okumada; token türü sayıları şablonla (modül global'i değil) — gerekçesi spesifikasyon §3.476. (3) **Performans:** 2,2×/2,35× ≤ 3× (CI kapısı). (4) **Bellek:** 60 tur düz/trivia/hata yolu + yıkım, Debug çalışma zamanında sızıntı raporu boş (`tests/cli/selfhost_obj_test.zig`; testin sızıntıyı gerçekten yakaladığı bilerek sızdıran harness ile doğrulandı). Denetimde bulunan iki eksik (hata span'ında bayt konumları; sızıntı testi yokluğu) bu sürümde kapatıldı.

## 5. Aşama 2 — Parser ve AST (Nox)

Girdi: `parser.zig` (~3 000 satır) + `ast.zig` (~640) + `ast_dump.zig`. Çıkış ölçütü: `--dump` çıktısı depodaki tüm dosyalarda Zig ile özdeş (`tests/golden/cases/*.ast.expected` dahil); sözdizimi hata konum/mesajları aynı; desugarlar (tuple açma, `match`, `defer`, dekoratör, dict/list comprehension, f-string bölme, lambda) birebir.

- [x] 2.1 (v2.2.40; tasarım: `project/selfhost-ast-tasarimi-2026-11.md` — düz-dizi temsil, ölçümlü karar) AST sınıf hiyerarşisi tasarımı (`selfhost/ast.nox`): ifade/deyim birleşim tipleri (sınıf hiyerarşisi + `kind` alanı; jenerik enum gerekirse dil işi `[K]`).
- [x] 2.2 (v2.2.42) Token akışı okuyucusu (Aşama 1 çıktısı ya da yerel lexer), `peek/advance/expect`, hata kurtarma kuralları (Zig ile aynı).
- [x] 2.3 (v2.2.42) İfade ayrıştırma: öncelik tırmanışı, üçlü, lambda, comprehension, `await/spawn`, çağrı/indeks/öznitelik, anahtar kelimeli argüman.
- [x] 2.4 (v2.2.42) Deyimler: atama/artırılmış/`:=`, `if/while/for/try/with/match`, `def/class/protocol/enum`, `import`, `defer`, `global/nonlocal`.
- [x] 2.5 (v2.2.42) Tip ifadeleri: basit, jenerik, `T | None`, fonksiyon tipleri.
- [x] 2.6 (v2.2.42) Parser içi desugarlar (tuple açma `__nox_tup_*`, `match` konu geçicisi, sınıf sabitleri, `__infer`).
- [x] 2.7 (v2.2.42) f-string bölme + iç ifade ayrıştırma.
- [x] 2.8 (v2.2.42) Span/konum sistemi (`Span`, deyim başlangıç/bitiş) birebir.
- [x] 2.9 (v2.2.42) AST dökümü (`ast_dump` eşdeğeri; Nox yazıcısı `selfhost/ast_schema.nox`) + `noxc-nightly parse-nox` aracı (`noxc ast --full` ile bayt-bayt aynı).
- [x] 2.10 (v2.2.42) Hata iletileri ve `syntax_report`: konum + işaretçi gösterimi aynı.
- [x] 2.11 C ABI: AST'nin Zig tarafına geçişi — **karar noktası `[K]`:** (a) Nox'un AST'yi bayt tamponuna serileştirmesi + Zig'in okuması (parser sınırı), ya da (b) Aşama 3'e kadar yalnızca doğrulama aracı olarak kalması (Zig checker Zig AST'siyle çalışır). Önerilen: (b) ile başla, checker Nox'a geçerken (a).
  **KARAR (2026-11-18, kullanıcı "gerçek selfhost için hangisi" diye sordu; öneri + uygulama):** **(b)**. Self-hosting'in bitiş durumunda AST Zig'e hiç geçmez (Nox parser → Nox checker); (a) iki dilde 100+ düğüm türü için geçici serileştirme olurdu. Parser doğruluğu `noxc ast` dökümü farksal eşitliğiyle kanıtlanır; tek köprü checker sonrası tiplenmiş AST sınırında (3.14) kurulur.
- [x] 2.12 (v2.2.44) Farksal test: AST dökümü eşitliği (tüm depo + mutasyonlu girdiler + `tests/fixtures/parser_edge`/`fmt_edge`), sözdizimi hata korpusu (hata iletisi bayt-bayt), `noxc fmt` çıktı eşitliği (depo 1 325 dosya + 3 825 mutasyonlu girdi; `frontend_diff.py --component fmt`).
- [x] 2.13 (v2.2.44; kullanıcı kararı 2026-11-19: "hepsini Nox'ta yazalım" — AST çözücüsü yok, biçimlendirici Nox AST'si üzerinde yazıldı) İlk "Nox ile üretilen araç": `noxc-nightly fmt` = Nox lexer + Nox parser + Nox biçimlendirici (`selfhost/formatter.nox`, `compiler/fmt/formatter.zig`in birebir portu; `--frontend zig` ile Zig yolu). Bütçe (`fmt-bench`): süre 2,1× (≤3×), bellek 0,20× (≤2×); sızıntı testi yeşil.
- [x] 2.14 (v2.2.42) Perf ≤ 3× Zig (ölçülen 1,6–1,7× — `noxc-nightly parse-bench`, 0,96 MiB stdlib+selfhost, ReleaseFast); bellek ≤ 2× (0,31×: 16,1 MB canlı vs Zig arena 51,5 MB); sızıntı/çifte serbest bırakma testi (Debug çalışma zamanı, 30 tur + hata yolları); derin ifade: 10 bin iç içe `(` Zig ile aynı hata iletisi, 300 iç içe blok / 3 000 zincirli öznitelik+çağrı / 6 000 terimli toplam sorunsuz.
- [x] 2.15 (v2.2.42) Belge + CHANGELOG + spesifikasyon §3.479.

### 5.1 Aşama 2 ilerleme notu (v2.2.41)

Tamamlanan altyapı (tasarım: `project/selfhost-ast-tasarimi-2026-11.md`): **2.0** oracle `noxc ast --full`; **2.A** `scripts/gen_selfhost_ast.py` → `selfhost/ast_schema.nox` (59 tür: düz-dizi şeması, oluşturucular `mk_*`, Zig'le BİREBİR `d_*` yazıcıları; `--check` precheck + `zig build test`te); **2.B** Zig `ast.Module` → düz diziler yansıma kodlayıcısı (`compiler/parser/ast_flat.zig`) + `noxc-nightly ast-roundtrip`: Nox yazıcısının çıktısı depodaki 1 258 dosya + mutasyonlu girdilerde `ast --full` ile **bayt-bayt aynı** (`frontend_diff.py --component astdump`, `zig build frontend-diff-test`). Birleşik giriş `selfhost/selfhost.nox` (lexer + AST şeması, tek nesne). **Sırada:** parser çekirdeğinin (2.2–2.8, 2.10) Nox'a işlev-işlev taşınması — hepsi tamamlanmadan 2.x `[x]` yapılmaz.

## 6. Aşama 3 — Tip denetleyici (Nox)

Girdi: `compiler/typecheck/` (12 dosya, ~16 600 satır; `checker.zig` 12 640 satır tek başına) — en büyük ve en riskli aşama. Çıkış ölçütü: ~330 typecheck golden'ında aynı tanı (konum + metin); tüm doğru programlarda aynı tiplenmiş AST, aynı monomorphization listesi, aynı `infer_types`/`expr_rewrites` sonuçları.

Alt aşamalar (her biri ayrı kapanır, bir önceki bitmeden sonrakine geçilmez):

- [x] 3.1 Tip temsili (`types.zig` eşdeğeri), tip eşitliği/atanabilirlik, `typeText` — **v2.2.66.** `selfhost/types.nox`: düz sütun tablosu `TT` + `TypeId` + hash-consing (yapısal eşitlik = TypeId eşitliği; `types.eql` ⇔ `id==id`) + derleme-ömürlü `SymbolId` intern havuzu (R2-G.1/G.2, R2-J.1/J.3 kararları); 18 `Type` varyantı, `FixedIntKind` (bitWidth/isSigned/fitsValue/ad), `format` (= `typeText`), `appendMangled` (Zig tarafı tek doğruluk kaynağı olarak `types.zig`e taşındı; checker çağırır), `isNumeric`/`isBitwiseEligible`, sınıf hiyerarşisi (`creg/cbase/cmix`) + `isSubclassOf`, `assignable` (eql, float←int, taban-sınıf kovaryansı, `T|None` otomatik sarma), `ty_validate` invariantları (DAG sırası, havuz aralıkları, hash tablosunda tam-bir-kez). Kanıt: `noxc-nightly types-diff <adet> <tohum>` (rastgele tip ağaçları; format/mangle/yüklemler/eql⇔TypeId/assignable (referans = `Checker.assignable`)/FixedIntKind/yeniden-kurmada kimlik kararlılığı/invariant; mutasyon testiyle fark yakaladığı doğrulandı) + `types-bench` (ReleaseFast: yapısal Zig iş yüküne göre **0,72×** süre, 148 KB canlı vs 1,2 MB arena; sağlama toplamları EŞİT). **Kapsam sınırı (başka alt aşamalara bilerek devredildi):** `assignableOrCoerce`/`classSatisfiesProtocol` (protokol kutulama yeniden yazımı: 3.4/3.6), `typeToTypeExpr` (AST üretir: 3.6), `Backend`/`Profile` seçenekleri (sürücü/checker seçenekleri: 3.12/Aşama 5). `func` tipi kurarken önce çocuklar kurulur (tek `tmp` alanı; iç içe `begin` yok).
- [x] 3.2 Kapsam/sembol tabloları, `declareVar`, modül düzeyi global terfi — **v2.2.67 (tablolar) + v2.2.68 (`collectModuleGlobals`).** `selfhost/typecheck.nox.in`→`typecheck.nox`: `Map2` (tamsayı anahtarlı, ekleme sıralı, ölü işaretli açık adresleme; `dict[str,..]` yok), `Scope` (declare/lookupLocal/lookup + yakalama kaydı/existsInChain; düz tablolar), `declare_var` (aynı kapsamda farklı tiple yeniden bildirim reddi, sınıf↔sınıf ARC-dışı serbestliği; `cnonarc` sınıf sütunu), `module_globals`/`module_int_consts` + `collect_module_globals` (bildirilen tip + değişmez tamsayı sabiti + yeniden atananları düşürme, `stmts_assign_name`). Kanıt: `ck-diff scope` (GERÇEK `checker.Scope` + declareVar referansı, mutasyon testiyle doğrulandı), `ck-diff assign` (552 dosya, 31 135 ad), `ck-diff bench` (derin zincir 1,03×, sığ 0,42× Zig). **Not:** `collect_module_globals` bildirilen tipi `type_expr_to_type` ile çözer; o işlevin tam yüzeyi (tuple/jenerik/protokol/qualified/func/optional/list/dict/`ptr[T]`) 3.3–3.12'de ilgili tablolarla birlikte büyür ve her biri orada izlenir (3.3 satırına bakın).
- [~] 3.3 Temel ifadeler/deyimler: literal, aritmetik, karşılaştırma, atama, kontrol akışı, fonksiyon çağrıları — **v2.2.68 (dilim A).** **Kapsam-kapılı yöntem:** Nox `check_module` kapsam dışı HER yapıda `CkUnsupported` fırlatır (durum 2, karşılaştırılmaz); kapsam-içi programlarda sonuç (kabul/ret), hata kodu, ileti, satır, span ve TÜM tanılamalar GERÇEK `checker.check` ile eşit olmalıdır (`noxc-nightly ck-diff check`). Atlanan sayısı 0'a inince 3.3 `[x]` olur. Dilim A (skaler tipler int/float/bool/str/None/ptr/fixed_int): literaller, identifier (kapsam→global→işlev değeri), unary, binary (aritmetik/karşılaştırma/mantık/bit/kaydırma/`in` str), `print` (sep/end), `len(str)`, kullanıcı işlevi çağrısı (positional, sayı/tip denetimi + argüman span'ı), var_decl, assign (identifier + `_ =`), if/elif/else, while, return, pass/break/continue, `check_function_body`, `always_returns`, `register_func` (varsayılan/variadik/dekoratör/jenerik/async hariç), `collect_module_globals`, tanılama toplama (`fail`/`recordDiagnostic`: "line N: ..." öneki, UTF-8). Kanıt: typecheck golden korpusunda 347 dosyadan 13, depoda 1212 dosyadan 63 kapsam-içi program eşit; `scripts/ck_gen.py` tohumlu üreteç (kasıtlı hatalı programlar) 6000+ program / 7000+ tanılama eşit; mutasyon testi (dönüş tipi denetimini kapatma) üreteçle yakalandı (gerçek korpus o dalı kapsamıyor). **Dilim B-1 (v2.2.70):** tip ifadeleri tam çekirdek (`list/dict/Task/Channel/ThreadHandle/ThreadChannel/TaskLocal[T]`, `ptr[T]`, `T | None`, `(A, B) -> R`; yalnız `tuple[...]`, `__nox_*` prelude jenerikleri ve nitelikli adlar kapsam dışı), liste/sözlük literalleri + beklenen-tip yolu (boş `[]`/`{}`, iç içe, Optional'a sarılı), `obj[i]` (list/dict/str), liste/sözlük `+`/`*`/`in`/`len`, `for` (range/list/str/dict), `constIntValue` + negatif sabit-genişlikli literal, eksik-argüman iletisi (`expandCallArgs`), kapsam-dışı neden histogramı (`ck-diff check --why`). Ölçüm: üreteç (artık liste/sözlük/Optional/for/index üretir) 3 tohum × 2500 program → **0 kapsam dışı**, 16 000+ tanılama eşit; mutasyon (dict index denetimi + `in list` sabit-genişlik denetimi kapatma) yakalandı; gerçek depoda kapsam-içi 63 → 125 dosya, hepsi eşit. Kalan gerçek-korpus kapsam dışı nedenleri (histogram): üst-düzey import/sınıf/protokol/extern (~750 dosya: 3.4/3.12), `async def` (~95: 3.8), kalan deyim türleri (`try/with/raise/del/defer/lowlevel`), `tuple[...]`, nitelikli/`__nox_*` tipler.
**Açık (sonraki dilimler):** sınıflar (3.4), Optional daraltma (3.5), jenerik/protokol (3.6), kapanış/lambda (3.7), async/jeneratör (3.8), enum/match/dekoratör (3.9), yerleşikler `str/int/float/...` ve metod çağrıları (3.10), `:=`/walrus, iç içe `def`, import/modül yükleme (3.12), `try/with/raise/del/defer/lowlevel`, `type_expr_to_type` kalan dalları (tuple/qualified/sınıf).
- **Ara faz NoxPy (v2.2.75-78) TAMAMLANDI** (UR-001..007, yerleşik `bytes`, Host ABI; bkz. `project/noxpy-upstream-gorev-belgesi-2026-11.md`). **Devam noktası:** `ck-diff check --why-deep` histogramının tepesi — str/Task/Channel metotları, yerleşik işlevler (`check_call#2`), `spawn`, kalıtım (3.4b), import (3.12).
- [~] 3.10 yerleşik metotlar: **v2.2.74 dilim A** (list/dict metotları, grow/extend deyim kapısı; spec §3.508); **v2.2.79 dilim B** (yerleşik dönüşüm/ölçü çağrıları: `str/int/float/repr`, cast'ler, `sizeof/alignof/offsetof`, `super()` hatası, yerel değer/UndefinedFunction; spec §3.513; depo kapsam-içi 161→194 kabul + 14 ret). **v2.2.80 dilim C** (str + Task/Channel/TaskLocal/ThreadHandle/ThreadChannel metotları, `await` bağlamı `Fx.awaited`; spec §3.514). Açık: prelude yönlendirmeli str metotları (`str#prelude`), prelude yönlendirmeli yerleşikler (`max/min/sorted/sum/list/set/bool/...`, `int(s, taban)`; `check_call#prelude`), ptr/lowlevel ailesi, `bytes(...)`, işlev-tipli yerel çağrısı (`check_call#fnvalue`).
- [~] 3.13 spawn: **v2.2.84 dilim A** (`spawn f(...)` → `Task[T]`, spec §3.518); açık: `spawn obj.metod()`, `list/dict/class` parametreli hedefler (Zig SpawnSharedMutation analizleri), kwarg argümanlar, iç içe `async def`.
- [~] 3.11 lowlevel/ptr/kurucular: **v2.2.82 dilim A** (`lowlevel:`, ptr ailesi, `Channel/ThreadChannel/TaskLocal/ptr[T]` kurucuları, `wasm_call`; spec §3.516); açık: `adopt` (beklenen tip), `defer`. **`extern def` v2.2.83 (spec §3.517):** kayıt + çağrı denetimi; açık: `@ffi.*`/`@capability.requires` dekoratörleri.
- [~] 3.9 hata yönetimi deyimleri: **v2.2.81 dilim A** (`raise`/`try`/`except`/`finally`/sync `with`/`del`, `always_returns`; spec §3.515); açık: noktalı `except`, `async with`, `defer`, `lowlevel`, `@classmethod`/enum/match/dekoratör.
- [~] 3.8 async: **v2.2.73 dilim A** (`async def` kaydı + param güvenliği, doğrudan çağrı hatası, `await` Task operandı; spec §3.507); açık: spawn + analizleri, Channel/ThreadHandle, async metot/iç içe.
- [~] 3.12-hazırlık (v2.2.72): `ck-diff checkm` birleşik-modül köprüsü (Zig yükleyici → düz-dizi AST → Nox check ↔ Zig check, bkz. spec §3.506); import işleme taşınana dek tüm dosyalar `toplevel#10` kapsam dışı.
- [~] 3.4 Sınıflar: alanlar, `__init__`, metodlar, tekli/çoklu kalıtım, vtable kararı, mixin (`mixin_flatten`) — **v2.2.71 (dilim A: kalıtımsız basit sınıflar).** `typecheck.nox.in`: sınıf tabloları (`cls_map/cls_fields/cls_meths/cls_init/cls_unas`; işlev/metod/`__init__` imzaları ortak `new_sig` havuzunda), `collect_class_names` (+ kapsam dışı özellik kapısı), `register_class_sigs` (bildirilen alanlar, metod imzaları, `self` kuralları, `__del__`, ayrılmış adlar), `check_class`/`check_method_body` (`__init__` önce, `UnassignedField`, `MissingReturn`), `check_attribute` (alan okuma), `check_assign_attr` (`self.x = v` / `self.x: T = v` / `obj.x = v`, `__init__` dışı yeni alan reddi, sınıf özniteliği hatası), `check_method_call` (örnek metodu, func-tipli alan çağrısı, `UndefinedMethod`), kurucu çağrısı, `has_dunder` (dunder yoksa sınıf değerleri yerleşiklerde/for/index'te normal akar; varsa kapsam dışı), `xs[i] = v`/`d[k] = v`. Kanıt: üreteç (artık sınıflar üretir) 3×2500 program → 2450+ kapsam-içi/tohum, 19 800 tanılama eşit; 3 mutasyon yakalandı; gerçek depoda kapsam-içi 125 → 197, hepsi eşit. **Bilinen sapma/kapı:** ≥2 atanmamış bildirilmiş alan (Zig HashMap yineleme sırası) kapsam dışı. **Açık:** kalıtım/`super()`/çoklu kalıtım+mixin, sınıf sabitleri/`class_attr_promote`, `@dataclass`/`@derive`/dekoratörler, `@property`/`@staticmethod`/`@classmethod`, enum, jenerik sınıf (3.6), dunder yeniden yazımları (operatör/`__getitem__`/`__len__`/`__str__`/`__iter__`), sınıf operandlı `binary`, `Sınıf.SABİT`, `isinstance`, vtable kararı (codegen girdisi).
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
5. [x] Aşama 1 (lexer) — v2.2.33–34; sıradaki: Aşama 2 (parser/AST).

## 13. İlerleme özeti (el ile güncellenir)

| Aşama | Madde | Bitti | Durum |
|---|---|---|---|
| 0 Altyapı | 11 | 11 | **bitti (v2.2.32)** — sıradaki Aşama 1 (lexer) |
| 1 Lexer | 13 | 13 | **bitti (v2.2.33–35; tam-geçiş kuralına göre denetlendi)** — sıradaki Aşama 2 (parser/AST) |
| 2 Parser/AST | 15 | 15 | **bitti (v2.2.42 parser, v2.2.44 biçimlendirici, v2.2.45 dogfood kapanışı)** — sıradaki Aşama 3 (tip denetleyici) |
| 3 Tip denetleyici | 17 | 2 | **sürüyor** — 3.1 (v2.2.66) ve 3.2 (v2.2.67–68) bitti; 3.3 `[~]` (v2.2.68 dilim A: skaler tipli ifade/deyim + kullanıcı işlevleri, kapsam-kapılı farksal); sıradaki 3.3 dilim B (for/range, liste/sözlük) |
| 4 Sahiplik + codegen | 13 | 0 | açık |
| 5 Sürücü | 5 | 0 | açık |
| 6 Sabit nokta | 5 | 0 | açık |
