# Nox 2.0 öncesi yol haritası

Bu dosya, 2.0 yayınlanmadan ÖNCE yapılması gereken işlerin KALICI kaydıdır (2026-10-07, v1.143.1 itibarıyla,
kullanıcıyla birlikte çıkarıldı). Bir ajan yeni bir göreve başlamadan önce bu dosyaya bakmalı; bir madde
bittiğinde ya da yeni bir eksik bulunduğunda BURASI güncellenmelidir. Sıra = öncelik. Durum: `[ ]` açık,
`[~]` sürüyor, `[x]` bitti (sürüm numarasıyla).

**Kural (AGENTS.md §16):** yeni dil özelliği = mimariyi etkileyen karar. Her madde için önce kısa tasarım özeti
kullanıcıya sunulur; onaydan sonra uygulanır. Her özellik: parser → checker → ownership etkisi → codegen
(HER İKİ backend: QBE + LLVM) → golden test → spec bölümü → CHANGELOG → sürüm → commit + tag.

## 1. Dil özellikleri (Python-benzeri yüzeydeki boşluklar)

2026-10-07'de ~50 özellik `noxc check` ile denendi; aşağıdakiler REDDEDİLİYOR. Sıra, öneri sırasıdır.

- [x] **1.1 `break` / `continue`** — v1.144.0 (spec §3.261). Tasarım notları aşağıda.
- [x] **1.2 `in` / `not in`** — v1.145.0 (spec §3.262). Kullanıcı sınıfları için `__contains__` yok (ayrı karar).
- [x] **1.3 Üçlü ifade** `a if cond else b` — v1.146.0 (spec §3.263). Dallar aynı tipte olmalı (int/float karışımı → 1.8 `float(int)` sonrası gevşetilebilir).
- [x] **1.4 Varsayılan argümanlar + keyword argümanlar** — v1.147.0 (spec §3.264). Yalnızca sabit literal varsayılanlar; argümanlar parametre sırasıyla değerlendirilir.
- [x] **1.5 `for` genişletmeleri** — v1.148.0 (spec §3.265): `range(a,b,adım)`, `for c in str`, `for k in dict`, her liste ifadesi. Ayrıca eski bir
  doğruluk açığı kapandı (aynı kapsamda farklı tiple yeniden bildirim).
- [x] **1.6a dict tam API** — v1.149.0 (spec §3.266): get/pop/setdefault/update/copy/clear/len/`del d[k]`. Silme O(n).
- [x] **1.6b dict değer/anahtar tipleri** — v1.152.0 (spec §3.269): değer `list[T]`/`dict`, anahtar `float`; ayrıca `xs[i].append`/`d[k].append` eleman alıcısı büyütme.
- [x] **1.7 list tam API** — v1.150.0 (spec §3.267): `extend`, `insert`, `pop(i)`, `remove`, `index`, `count`, `clear`, `reverse`, `copy`, `del xs[i]`, `list + list`, `list * n`, `sorted`/`reversed` (yeni liste döner). Dilimleme 1.9'da.
- [x] **1.8 `float(int)` / açık int→float dönüşümü** — v1.151.0 (spec §3.268): `float(int/float/bool/u8…u64/str)`.
- [x] **1.9 str karşılaştırma `<`/`>`/`<=`/`>=`, `"ab" * 3`, dilimleme** — v1.153.0 (spec §3.270): `xs[a:b:adım]`, `s[a:b:adım]`, tree-sitter dahil.
- [x] **1.10 list/dict comprehension + lambda** — v1.154.0 (spec §3.271) / v1.155.0 (spec §3.272).
- [x] **1.11 `is None`, `print` çoklu argüman (+sep/end), str metot sözdizimi** — v1.156.0 (spec §3.273).
- [x] **1.12 Koruma (guard) tarzı Optional daraltma** (v1.156.0, spec §3.273) — eski tanım: ** `if x == None: return/break/continue` sonrası `x` daraltılsın
  (şu an yalnızca `if x != None:` bloğu içinde; bağlı liste gezintisi için gerekli).
- [x] **1.13 tuple** — v1.157.0 (spec §3.274). Eski tanım:  `tuple[T1, T2]` tipi, `(a, b)` literal, `t[0]`, açma (`a, b = f()`), çoklu dönüş,
  `for k, v in d.items()`, `enumerate`/`zip`. Kullanıcı kararı (2026-10-07): 2.0 için özelliklerden kaçınma, eksiksiz olsun.
- Bilinçli ertelenmiş (LANGUAGE.md): `*args`/`**kwargs`, çoklu kalıtım — 2.0 için yeniden değerlendirilecek mi, kullanıcıya sorulacak.

### 1.1 `break` / `continue` — tasarım

- **Anlam (Python ile aynı):** `break` en içteki `while`/`for`'dan çıkar; `continue` en içteki döngünün sonraki
  yinelemesine geçer (`while`'da koşula, `for range`'de artırmaya, `for list`'te sonraki elemana). Döngü
  dışında kullanım derleme hatası. `try/finally`, `with`, `defer`, `lowlevel` arena kapsamlarından çıkarken
  temizlik KURALLARI `return` ile AYNI mekanizmayı paylaşır (AGENTS.md §9: ayrı kod yolu yazılmaz).
- **Riskli noktalar:** (a) ASAP/ARC kapsam-çıkışı temizliği (döngü gövdesindeki yerellerin break/continue'da
  serbest bırakılması); (b) "Nox'ta break/continue olmadığından gövde baştan sona çalışır" varsayan analizler:
  `detectWhileBoundsElideCtx` (artırma gövdenin SON deyimi olmalı), `enterModCacheLoopScope`, `str_len_cache`
  LICM, `markAliasStmts`/escape analizleri, `collectReassignedNames`; (c) `try/finally` ve `with` içinden
  `break`; (d) iç içe döngüler; (e) fiber/async (`await` döngü içinde); (f) hem QBE hem LLVM etiket üretimi.

## 2. Kırıcı değişiklik penceresi (yalnızca MAJOR'da yapılabilir)

- [x] **2.1 Kullanımdan kaldırılmış takma adlar** (v1.171.0: KALDIRILDI, bkz. `docs/MIGRATING-2.0.md`) (`nox.csv`, `nox.json` içinde "KULLANIMDAN KALDIRILMIŞ" bölümleri) —
  2.0'da kaldır mı? Liste çıkar, kullanıcıya sor.
- [x] **2.2 Stdlib sınıf kurucu imzalarını dondur** (v1.171.0: `VERSIONING.md` §5 — yeni parametre yalnızca varsayılanla; `HttpRequest.peer_addr = ""`) — `HttpRequest`'e 1.127'de eklenen 5. argüman (`peer_addr`)
  Aether'i kırdı. Fabrika fonksiyonu / kurucu dondurma politikası.
- [x] **2.3 Diğer kırıcı temizlikler** — kullanıcı kararı (2026-10-08): yeni sözdizimi eklenmez; `*args/**kwargs`/çoklu kalıtım 2.x; liste `docs/MIGRATING-2.0.md`'de.
- [x] **2.4 Backend'ler arası semantik eşitliği** — v1.169.0: sabit-genişlikli taşma HER İKİ backend'de tuzağa düşer (önceden LLVM sarıyordu); 64 vakalık fark matrisi (8 genişlik × 8 durum) iki backend'de birebir aynı. Düz `int` her ikisinde de sarar. Keyword değerlendirme sırası: yan etkili argümanlar KAYNAK sırasıyla değerlendirilir, parametre sırasıyla bağlanır (spawn'da yan etkili kwarg'lar parametre sırasıyla yazılmalı).

## 3. Platform ve dağıtım

> v1.166.0: durum ve kısıtlar `docs/PLATFORMS.md`te BELGELENDİ ([~] = belgelendi, kalıcı çözüm açık). Windows LLVM / paketlenmiş clang ve aarch64 kök neden hâlâ yapılacak.

- [x] **3.1 Windows (v1.171.1/2: LLVM `zig cc` ile CI'da uçtan uca doğrulandı, `zig` varsa varsayılan):** LLVM yolunda MinGW bağlama argümanları yok → Windows'ta QBE'ye düşülüyor. CI'da Windows işi
  "yalnızca derleyici ön-ucu". LLVM'i Windows'ta çalıştır VEYA belgeli kısıt olarak bırak.
- [x] **3.2 `clang` bağımlılığı (v1.171.1: clang → `zig cc` → QBE; `tests/cli/zig_cc_fallback_test.zig`; paketlenmiş toolchain 2.x):** release paketi `qbe` içeriyor, `clang` içermiyor; clang yoksa sessizce QBE'ye
  düşülüyor (not basılıyor). Kalıcı çözüm: `zig cc` ya da paketlenmiş clang değerlendir.
- [x] **3.3 aarch64 stack-smash (son 40 CI koşusunda test hatası YOK; kök neden x86-64 ile aynı, v1.142.3/21):** kök neden aarch64 için DOĞRULANMADI (x86-64 muadili v1.142.3'te bulundu).
  `allow_failure` v1.142.21'de kaldırıldı; v1.142.24 CI temiz. Birkaç koşu daha izle; çıkarsa kök nedeni araştır.
- [x] **3.4 riscv64 hosted (v2.0.4, duman CI v2.0.8):** `swap_riscv64.S`, `--target linux-riscv64` (musl, statik). CI `riscv64-smoke` `class_list_spawn` çıktısını `70` diye kilitler. Freestanding riscv64 hâlâ yalnızca `--emit-asm`. Tam korpus paritesi yok.

## 4. Dokümantasyon

- [x] **4.1** `docs/LANGUAGE.md` genişletildi — v1.159.0 (sayısal kurallar, Optional, modüller, hata modeli, backend'ler). Yazarken 2 gerçek hata bulundu/düzeltildi (sıfıra bölme, print(Optional)).
- [x] **4.2** Stdlib API başvurusu — v1.158.0 (`docs/STDLIB.md`, üretici betik `scripts/gen_stdlib_docs.py`). Öğretici ayrı.
- [x] **4.3** Çapraz-dil benchmark yenilendi (v1.158.0 ölçümü; `benchmarks/` .gitignore'da olduğundan README özeti ana README'de).
- [x] **4.4** İngilizce mimari/katkı özeti — v1.166.0 (`docs/ARCHITECTURE.en.md`; platform durumu `docs/PLATFORMS.md`).

## 5. Güvenlik ve kalite

- [x] **5.1 (v1.171.2: `docs/SECURITY.md`; imzalama/sandbox 2.x tasarımı)** `extern def` / bağımlılık güven sınırı belgeli (AGENTS.md §9.5) ama sandbox/imzalama YOK — 2.0
  duyurusunda açık uyarı; paket imzalama değerlendir.
- [x] **5.2** HTTP sunucusu güvenlik incelemesi — v1.158.0: eksik yazma zaman aşımı (yavaş-okuyucu DoS) bulundu ve düzeltildi.
- [x] **5.3** Doğrulandı: stres/torture `--release` LLVM kullanır, diferansiyel korpus iki backend'i çalıştırır, fuzz ön-uç düzeyindedir.

## 6. Teknik borç

- [x] **6.1 (v2.0.2, matris v2.0.8)** ASAP closure-effect: func tipli bir yerel tam olarak bir kez, gövdesi bilinen bir fonksiyona veya iç içe `def`e bağlıysa o gövdenin parametre kaçışı çağrı yerine taşınır. Birden fazla yazım, parametre olarak gelen func, takma ad zinciri veya taranmamış gövde ARC kalır. Aynı nesnenin özyinelemeli geçişi ARC, `spawn` her zaman ARC. `try` codegen'de kanıtı düşürür.
- [x] **6.2 (GG.24/25 worklist zaten kapatmıştı; v1.171.1 fiber içi golden testi)** `genClassRelease` özyinelemesi 256 KiB fiber yığınında sınırda (STACK_SIZE küçültülmedi).
- [x] **6.3** `nox.binary` artık `Span` üzerinde de çalışır — v1.166.0 (`span_reader`/`span_writer`; tam generic sınıf yerine geriye uyumlu yardımcı).
- [x] **6.4 (sınır, v2.0.8)** Aether/Nyx bu depoda `external-fixtures.yml` ile pinli (Aether v0.7.2, Nyx v0.22.0). `is_stopping` + `HttpRequest` Aether deposunda kalır; burada sahte test yok.
- [x] **6.5** Eski async-istisna notları düzeltildi — v1.158.0.

## 7. Performans (engelleyici değil)

- [x] **matmul (v2.0.3)** QBE 0.064→0.049 s (LLVM 0.041, C 0.020; M4, ReleaseFast). `shl` ölçek, sayılan indeksde negatif düzeltme yok, değişmeyen `list[list[T]]` satırı ilk girişte bir kez. Kalan ~2.1–2.5x sınır kontrolü + liste dolaylaması.
- [x] **loop (v2.0.3, kod yok)** QBE 0.82 s, LLVM 0.67 s, C 0.53 s. QBE'de `mulh` yok; yazılım yüksek çarpım `rem`den yavaş (0.72 s karşı 0.64 s).
- [x] **dict (v2.0.3, kod yok)** ~2.5x C (0.055 / 0.022 s). `entries` + `HashMap`, `d[k]` iki arama. Sıra ve tohum bozulmadan kapanmaz.

## Bitenler (bu yol haritasının öncesi, bağlam için)

- v1.143.0/1: varsayılan backend LLVM (`--backend qbe|llvm`), taşma davranışı belgelendi.
- v1.142.26: `nox.strings` join/replace/upper/lower/repeat doğrudan yazım (split+join 0.90→0.10 s).
- v1.142.25: `IndexError` yutulma hatası + `f()["k"]` derleyici çökmesi düzeltildi.
