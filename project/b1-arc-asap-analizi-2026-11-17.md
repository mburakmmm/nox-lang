# B1 — "ARC'ye düşen payı azaltıp ASAP'e gelen yüzdeyi artırmak" (Gemini önerisi) — analiz ve plan

> **GÜNCELLEME (aynı gün, gerçek-dünya ölçümüyle): aşağıdaki §1-§5 ilk okumadır ve ARC maliyeti konusunda fazla iyimserdi. §6'daki ölçümler kullanıcının endişesini doğruluyor: sınıf ağırlıklı (ağaç/AST) iş yükünde çalışma süresinin ~%70'i bellek yönetimi işlevlerinde, ~%40'ı ARC/döngü-toplayıcı mekanizmasında geçiyor. Karar/öncelik §6-§7'ye göre okunmalı.**

Tarih: 2026-11-17. Kaynak: kullanıcının masaüstündeki `asap.md` (Gemini'nin önerisi). Bu belge öneriyi **koda karşı** doğrular; ölçümler Apple M4, bu repodaki `noxc` ile.

## 1. Önermenin dayandığı "%92 ARC" rakamı neyi ölçüyor?

Rakamı doğrudan yeniden üretemedim (kaynağı bu oturumda yok), ama iki olası kaynağın ikisi de **çalışma zamanı ARC maliyetini ölçmüyor**:

1. `noxc build --dump` içindeki *sahiplik raporu* (`compiler/ownership/analysis.zig`) **tanılama amaçlıdır**; kodun kendisi söyler: "codegen KENDİ sahiplik kararlarını AYRICA/dahili olarak üretir". Rapor **her parametreyi** (`self` dahil) ve stdlib ön ekinin (`core.nox`) tüm parametrelerini koşulsuz "ARC" yazar. Yani yüksek bir ARC yüzdesi büyük ölçüde parametre sayısıdır.
2. `noxc explain` çıktısı skaler yerelleri (`int`, `float`, `bool`) de "ARC (heap, reference-counted)" diye listeler. Bu bir **hata/yanıltıcı etikettir** (skaler hiçbir zaman heap'e girmez). Kendi ölçümümde 1.600'ü aşkın girdinin 936'sı skalerdi.

Düzeltme önerisi (B1-0, küçük): `explain` skaler yerelleri listelemesin, `--dump` raporu parametreleri "ödünç/çağıran sahiplenir" olarak etiketlesin. Böylece bu metrik bir daha yanlış okunmaz.

## 2. Gemini'nin dört önerisi — kodla karşılaştırma

| Öneri | Durum | Kanıt |
|---|---|---|
| **1. Otomatik `borrow` çıkarımı** (çağrılarda retain/release çiftini sil) | **Zaten böyle çalışıyor.** | Çağrı sözleşmesi ödünç: IR'da `call $depth(l %rt, l %t28, l 3)` çevresinde retain/release YOK (kendi örneğimde doğrulandı); callee yalnızca saklayacaksa (alana atama, kapsayıcıya koyma, return) sayacı artırır. Sahiplik analizi ayrıca "gövdesi bilinen çağrıda argüman kaçmıyorsa yerel kaçmış sayılmaz" kuralını uygular (`ownership/analysis.zig` başlık notu). |
| **2. Yığın terfisi** (`alloca`) | **Var, ama kapsamı dar.** | `local_escape.zig`: kaçmayan, boyutu bilinen liste literali ve alanları heap-yönetimli olmayan sınıf kurucusu yığına (ya da büyüyebilir arenaya) gider. Gerçek koddaki oran **%0,6** (aşağıda §3). Asıl boşluk burada. |
| **3. Thread-local (atomik olmayan) ARC** | **Ölçüldü, kazanç küçük.** | Deneysel anahtarla (kaldırıldı) aynı benchmark'ı atomik ve düz `load/add/store` sayaçla derledim: `oop_arc_churn` 15=15 ms, `list_class_field` 16/17, `string_passing` 39/37, `deep_equality` 20=20, `generics_protocols` 47=47, `list_release_overhead` 241/229 ms (≤%5). M4'te çekişmesiz `ldaddal` ucuz; asıl maliyet tahsis/serbest bırakma. Çok iş parçacığında düz sayaç güvenlik riski (Faz 9.0 SHARED biti ile uyumlu bir tasarım gerekir) → **kazanç/risk oranı düşük, önceliklendirilmez.** (WASM tek iş parçacıklı hedefte zaten düz sayaç kullanılıyor.) |
| **4. `@acyclic` tip işaretlemesi** (Bacon-Rajan tamponuna girme) | **Zaten var ve önerilenden kesin.** | `layout.zig`: sınıf grafında (alt sınıflar, `list[...]`/`dict[...]` elemanları, iç içe kapsayıcılar dahil) kendine dönebilen yol aranır; yalnızca döngüsel olabilen sınıflar `cyclic_classes` içine girer ve mor tampona kaydolur. Döngüsüz tipler 3. katmana hiç uğramaz. |

Sonuç: önerilerin 1, 3 (kısmen: WASM'da), 4. maddeleri zaten uygulanmış ya da ölçüldüğünde değersiz; gerçek fırsat 2. maddenin kapsamını genişletmek ve ölçümü doğru yapmak.

## 3. Gerçek durum: heap-tipli yerellerde yığın/arena oranı

`scripts`'siz ölçüm (geçici betik; `explain` çıktısı + kaynaktaki tip bildirimi): `stdlib/nox/*.nox`, `benchmarks/**`, `services/noxpkg/*.nox` = 1.033 heap-tipli yerel.

| kategori | yığın | arena | ARC (heap, sayaçlı) |
|---|---|---|---|
| sınıf/diğer | 0 | 0 | 334 |
| liste | 3 | 3 | 287 |
| dict | 0 | 0 | 47 |
| str | 0 | 0 | 359 |
| **toplam** | **3** | **3** | **1.027 (%99,4)** |

ARC'de kalma nedenleri (ilk neden, sayılar): çağrıdan dönen değer (`unknown call target`/`call target is not a plain name`: ~470), `str` (yığına aday değil: 209+138), literal olmayan/karışık liste (142), alanları heap-yönetimli sınıf (60).

Yorum: yerellerin büyük çoğunluğu **bir çağrının döndürdüğü** değerlerdir (`s: str = f(x)`, `x: Node = make()`). Bu değerler callee'de tahsis edildiği için yığına alınamaz; modelin (sahip = çağıran) doğal sonucu. "ARC'de" olmaları sayacın pahalı olduğu anlamına gelmez: yerel, tek sahipli bir değerde retain/release çifti oluşmaz, kapsam sonunda tek release (= ASAP yıkıcısı) çalışır.

## 4. Gerçek fırsatlar (sıralı) ve plan

Her adım önce ÖLÇER, sonra değiştirir (AGENTS §8: muhafazakâr, yanlış-pozitif yok; bellek modeli etkisi olan adımlar `[K]`):

- **B1-0 (S)** Ölçüm düzeltmesi: `explain` skalerleri atlasın; `--dump` parametre etiketi "borrowed (caller owns)". Çıktıya heap-tipli yerel özeti (yığın/arena/ARC/neden) eklensin. Bu, "yüzde" hedefini ölçülebilir kılar.
- **B1-1 (M)** Çalışma zamanı sayaçları: `noxc build --rc-stats` ile derlenen programda `retain`, `release`, `alloc`, `free` sayıları (satır içi sayaç artırımları; yalnızca bu bayrakta). Böylece "gerçek ARC trafiği" gerçek programlarda (nyx, aether, noxpkg, benchmarks) ölçülür. Karar bu rakamlara göre.
- **B1-2 (M)** Küçük/sabit-uzunluklu `str` yerelleri için kaçmayan-yığın: `"a" + "b"` / `f"..."` / `str(i)` gibi geçici dizelerde tahsis+serbest bırakmayı atlayan yol (yerel `str` değişkeni kapsamdan çıkmadan başka yere gitmiyorsa arenaya). `str` en büyük kategori (359) ve hiç terfi etmiyor. `[K]` (ABI/bellek modeli etkisi).
- **B1-3 (M)** Kaçmayan, `append` ile büyüyen listelerin ve `dict`lerin arena kapsamı (liste için büyüyebilir arena zaten var; dict/str-liste kapsamını genişlet, `GG.18` temelinde).
- **B1-4 (L)** Callee tarafı "sahipliği devret" imzası: `return`/alana atamada gereksiz retain→release çiftlerini ortadan kaldıran `move` çıkarımı (callee dönüş değerini yerelinden devralır). Heap-tipli dönüş değerleri (≈470 yerel) için ARC trafiğinin asıl kaynağı burası olabilir; B1-1 ölçümü doğrular.
- **Yapılmayacak / düşük öncelik:** atomik olmayan ARC (kazanç ≤%5, güvenlik riski), `@acyclic` (zaten var).

## 5. Karar noktaları (kullanıcı)

1. B1-0 ve B1-1'i hemen yapayım mı (yalnızca tanılama/ölçüm, dil/bellek modeli değişmez)? — **Öneri: evet.**
2. B1-2/B1-4 (bellek modeli etkili) için B1-1 sonuçlarını görmeden tasarım yapmayayım mı? — **Öneri: evet, ölçüm önce.**

## 6. Gerçek-dünya ölçümü (2026-11-17, `NOX_RC_STATS=1` + örnekleme profili)

Araç (B1-1, yapıldı): `NOX_RC_STATS=1 noxc build x.nox` ile derlenen ve `NOX_RC_STATS=1 ./x` ile çalıştırılan program çıkışta stderr'e heap türüne göre satır içi retain/release sayısını ve tahsis/serbest bırakma toplamlarını yazar (`NOXRC ...`). Kapalıyken sıfır maliyet. Zamanlar için `sample <pid> 3` (macOS) ve `-Dkeep-symbols` çalışma zamanı kullanıldı.

**Aether (gerçek HTTP sunucusu, 1 işçi, `wrk -c32`, GET /ping + POST /echo ≈ 506k istek):**

| ölçü | değer |
|---|---|
| istek başına retain / release / tahsis | ~66 / ~182 / ~266 |
| isteklerin ürettiği tahsis | 5,7 KB/istek |
| örneklerin dağılımı | %60 sistem çağrısı (`write` ≈ istek günlüğü, `read`, `kevent`), %13 tahsis/serbest bırakma/ARC çalışma zamanı işlevleri |

Sonuç (sunucu): ARC burada darboğaz değil; sistem çağrısı + günlük yazımı baskın. Asıl bellek maliyeti istek başına ~266 tahsis (HTTP için kabul edilebilir).

**Genel amaçlı iş yükleri (yazdığım üç temsilci program, `scratchpad/work/`):**

| iş yükü | tahsis | retain | release | sonuç |
|---|---|---|---|---|
| AST kur + değerlendir + katla (sınıf ağacı, `class Node{left,right}`) | 1,47 M | 1,47 M | 2,95 M | **aşağıda** |
| metin işleme (tokenize + `dict[str,int]` + liste) | 434 k | 320 k | 320 k | örneklerin %29'u bellek işlevlerinde (`dict.findIndexSlow` %26, `nox_str_append` %14 dahil değil) |
| parçacık simülasyonu (uzun ömürlü nesneler, alan güncelleme) | 2 k | 0 | 2 k | ARC trafiği yok |

**AST iş yükü profili (sınıf-ağırlıklı, derleyici/yorumlayıcı tarzı):**

| işlev | pay |
|---|---|
| `nox_rc_release_enqueue_fixed` (sınıf release yolu) | 18,0 % |
| `nox_cycle_possible_root` (Bacon-Rajan olası-kök kaydı) | 14,5 % |
| `nox_rc_free_payload` | 11,7 % |
| `nox_rc_alloc` | 10,7 % |
| `nox_cycle_forget` | 7,5 % |
| `Node_release` | 5,0 % |
| `alloc.arc.poolSlotFor` | 4,5 % |
| gerçek iş (`eval_node` + `fold` + `build`) | 28,2 % |

Yani bu iş yükünde **~%72 bellek yönetimi**, bunun **~%40'ı ARC/döngü-toplayıcı mekanizması** (release yolu + olası-kök kaydı + forget + sınıf release) ve ~%27'si tahsis/serbest bırakma.

Neden: `Node` kendine referans verdiğinden tip-tabanlı `@acyclic` analizi onu "döngüsel olabilir" sayar (`layout.zig`, doğru ve gerekli). Ağaç gerçekte döngüsüz, ama `l: Node | None = n.left` gibi her alan okuması bir retain/release çifti üretir; release sayaç >0 kalınca nesne **mor kök olarak kaydedilir** (1,47 M kayıt ≈ düğüm başına bir) ve sonra `forget` ile silinir. Gemini'nin "`@acyclic` zaten var" cevabı burada yetmiyor: özyinelemeli (ağaç/bağlı liste/graf) tipler için tip bilgisi döngüsüzlüğü kanıtlayamaz.

**Düzeltmeler:**
- İlk analizdeki "atomik/düz sayaç ≤%5" ölçümü doğrudur ama **yanlış soruyu yanıtlıyordu**: maliyet sayaç komutunun atomikliğinde değil, sayaç işlemlerinin sayısında ve onların tetiklediği olası-kök/enqueue yolunda.
- "Sızdırarak tavan" deneyi (retain/release/serbest bırakma kapalı) geçerli bir tavan vermedi: sızdırınca `ast_eval` 3× YAVAŞLADI (27 → 88 ms; serbest bırakma sıcak belleği yeniden kullandırıyor), `text_proc` çıktısı bozuldu (çalışma zamanı dizeleri kendi sayaçlarını yönetir). Tavan, mekanizmayı ortadan kaldırarak değil, aşağıdaki elemelerle ölçülmeli.

## 7. Gerçek fırsatlar — hesap ve plan (güncel sıra)

AST iş yükü üzerinden hesaplanmış üst sınırlar (örnekleme payı → en çok kazanç; gerçek kazanç ölçülecek):

| # | fikir | AST payı | beklenen | not |
|---|---|---|---|---|
| **I1** | **Alan okumasından gelen yerelde retain/release çiftini sil** (`l = n.left`, yerel kaçmıyor ve çağrı bölgesinde alanı değiştirebilecek yazma yok). Etki-özeti (hangi işlev hangi sınıf alanına yazar) gerekir. | olası-kök 14,5 + forget 7,5 + enqueue'nun büyük kısmı ≈ **%30-40** | **1,5-1,7×** | Aynı anda ARC trafiğini ve mor kök kaydını sıfırlar; Gemini'nin "borrow" önerisinin gerçek karşılığı (çağrı argümanları zaten ödünç; alan okumaları değil). Bellek modeli etkisi `[K]`. |
| **I2** | **Sınıf release'in satır içi hızlı yolu**: sayaç >1 ise yalnızca azalt (çağrı yok); sıfıra düşünce çağır. | enqueue 18 → ~5 | +%10-13 | Güvenli, yalnızca codegen. |
| **I3** | **Olası-kök kaydının ucuzlaması**: tek iş parçacıklı programda (havuz yok) kilitsiz kayıt/forget; alan-okuması aliası olan nesneleri hiç mor yapma. | root+forget 22 → ~8 | +%10-14 | I1 yapılırsa gereksizleşir; I1 uygulanamayan yerler için. |
| **I4** | **Tahsiste sınıf başına satır içi serbest-liste**: sabit boyutlu sınıfta `poolSlotFor` + `nox_rc_alloc` çağrısı yerine IR'da liste başı pop; serbest bırakırken push. | rc_alloc 10,7 + poolSlotFor 4,5 + free_payload 11,7 → yarıya | +%10-13 | Çok iş parçacıklı yuva (`poolSlotFor`) dikkate alınmalı. |
| **I5** | **`str` kapsam-yerel geçici dizeler** (arena/yığın): metin işlemede `str` birinci kategori (359 yerel, hiç terfi etmiyor). | `nox_str_append`/alloc payı | ölçülecek | `[K]` |
| **I6** | **Dönüş değeri / son-kullanım taşıma (move)**: son kullanımı olan yerelin başka bir alana/dönüşe verilmesinde retain+release çiftini sil. | retain 1,47 M'nin kalanı | küçük-orta | I1 ile birlikte etki-özeti kullanır. |
| — | atomik olmayan sayaç | — | ≤%5 | yapma |

Kümülatif tavan (AST): I1+I2+I4 ≈ 28 % (gerçek iş) / (28 + kalan ~25) ≈ **~1,9-2,2× daha hızlı**; hepsi uygulanırsa tahmini ASAP/ARC oranı: heap-tipli yerellerin **~%60-70'inde sayaç trafiği sıfır** (şu an alan okuması yerelleri ve geçici yerellerin çoğu sayaçlı). Bunlar tahmindir; her adımdan önce/sonra `NOX_RC_STATS` + örnekleme ile doğrulanacak, AGENTS §8'e göre muhafazakâr (yanlış-pozitif yok).

**Önerilen sıra:** I2 (S, güvenli) → I4 (M) → I3 → I1 (L, etki-özeti, bellek modeli `[K]`) → I6/I5. Her biri kendi golden + ölçüm + iki backend doğrulamasıyla.

## 8. Yapılanlar bu turda

- B1-1 `NOX_RC_STATS` tanılaması (runtime `nox_rcstat`, `RuntimeState.rcstat*`, codegen `emitRcStat`, `wasm_abi_table`); üç iş yükü + Aether ölçüldü.
- Yan bulgu: Aether sunucusu `NOX_POOL_WORKERS` ayarlanmadan ~%40-60 oranında açılışta çöküyor (v2.2.7'de de var; `nox_os_OsError_release` içinde bozuk işaretçi) → ayrı görev açıldı.
- B1-0 (`explain`/`--dump` etiket düzeltmesi) henüz yapılmadı.
