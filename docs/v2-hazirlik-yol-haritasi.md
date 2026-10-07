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

- [ ] **2.1 Kullanımdan kaldırılmış takma adlar** (`nox.csv`, `nox.json` içinde "KULLANIMDAN KALDIRILMIŞ" bölümleri) —
  2.0'da kaldır mı? Liste çıkar, kullanıcıya sor.
- [ ] **2.2 Stdlib sınıf kurucu imzalarını dondur** — `HttpRequest`'e 1.127'de eklenen 5. argüman (`peer_addr`)
  Aether'i kırdı. Fabrika fonksiyonu / kurucu dondurma politikası.
- [ ] **2.3 2.0'a hangi diğer kırıcı temizlikler girecek?** (kullanıcıyla birlikte karar).
- [ ] **2.4 Semantik dondurma (§10) gözden geçirme:** v1.143.0 varsayılan backend LLVM oldu → sabit-genişlikli
  tamsayı taşması varsayılan olarak SARAR (QBE'de tuzaktı). Bu 2.0 notlarına açıkça girmeli.

## 3. Platform ve dağıtım

- [ ] **3.1 Windows:** LLVM yolunda MinGW bağlama argümanları yok → Windows'ta QBE'ye düşülüyor. CI'da Windows işi
  "yalnızca derleyici ön-ucu". LLVM'i Windows'ta çalıştır VEYA belgeli kısıt olarak bırak.
- [ ] **3.2 `clang` bağımlılığı:** release paketi `qbe` içeriyor, `clang` içermiyor; clang yoksa sessizce QBE'ye
  düşülüyor (not basılıyor). Kalıcı çözüm: `zig cc` ya da paketlenmiş clang değerlendir.
- [ ] **3.3 aarch64 stack-smash:** kök neden aarch64 için DOĞRULANMADI (x86-64 muadili v1.142.3'te bulundu).
  `allow_failure` v1.142.21'de kaldırıldı; v1.142.24 CI temiz. Birkaç koşu daha izle; çıkarsa kök nedeni araştır.
- [ ] **3.4 riscv64 hosted** desteği yok (yalnızca freestanding `--emit-asm`).

## 4. Dokümantasyon

- [ ] **4.1** `docs/LANGUAGE.md` (330 satır) genişlet: tüm sözdizimi, tip kuralları, hata modeli.
- [x] **4.2** Stdlib API başvurusu — v1.158.0 (`docs/STDLIB.md`, üretici betik `scripts/gen_stdlib_docs.py`). Öğretici ayrı.
- [ ] **4.3** README benchmark tablosunu güncel sayılarla yenile (v1.142.x/1.143 ölçümleri, `benchmarks/cross_lang`).
- [ ] **4.4** İngilizce spec/AGENTS özeti (şu an yalnızca Türkçe).

## 5. Güvenlik ve kalite

- [ ] **5.1** `extern def` / bağımlılık güven sınırı belgeli (AGENTS.md §9.5) ama sandbox/imzalama YOK — 2.0
  duyurusunda açık uyarı; paket imzalama değerlendir.
- [x] **5.2** HTTP sunucusu güvenlik incelemesi — v1.158.0: eksik yazma zaman aşımı (yavaş-okuyucu DoS) bulundu ve düzeltildi.
- [x] **5.3** Doğrulandı: stres/torture `--release` LLVM kullanır, diferansiyel korpus iki backend'i çalıştırır, fuzz ön-uç düzeyindedir.

## 6. Teknik borç

- [ ] **6.1** ASAP closure-effect genişletmesi (araştırıldı, uygulanmadı).
- [ ] **6.2** `genClassRelease` özyinelemesi 256 KiB fiber yığınında sınırda (STACK_SIZE küçültülmedi).
- [ ] **6.3** `nox.binary` hâlâ somut `Buffer` alıyor (generic sınıf çapraz-modül hatası sonrası kapsam dışı kaldı).
- [ ] **6.4** Aether `is_stopping()` + `HttpRequest` uyumu (Aether deposunda yapılacak).
- [x] **6.5** Eski async-istisna notları düzeltildi — v1.158.0.

## 7. Performans (engelleyici değil)

- [ ] matmul ~2x C (sınır kontrolleri + `b[k][j]` satır yüklemeleri), `loop` ~1.5x C (QBE'de sabit bölenli `%`).
- [ ] dict kıyaslaması C'nin ~2.8x'i (Go'dan hızlı).

## Bitenler (bu yol haritasının öncesi, bağlam için)

- v1.143.0/1: varsayılan backend LLVM (`--backend qbe|llvm`), taşma davranışı belgelendi.
- v1.142.26: `nox.strings` join/replace/upper/lower/repeat doğrudan yazım (split+join 0.90→0.10 s).
- v1.142.25: `IndexError` yutulma hatası + `f()["k"]` derleyici çökmesi düzeltildi.
