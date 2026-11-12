# ARC / ASAP analizi, eksikler ve stres testleri (TODO 4.5; 2026-11-12)

Kapsam: sahiplik piramidinin (ASAP/yığın-arena yükseltmesi → ARC → döngü çözücü → `lowlevel`) gerçek durumunu ölçmek, eksikleri bulmak ve doğruluğu stres testleriyle kanıtlamak. İlke 1 korunur: kullanıcı sözdiziminde ownership yok, belirsizlikte sessizce ARC.

## 4.5.1 Envanter (v2.1.78)

Araçlar: `scripts/arc_inventory.py` (`noxc explain --release` çıktısını bir dizindeki tüm programlarda toplar), `NOX_FORCE_ARC=1` (derleme ortamında yığın/arena yükseltmesini kapatan "gölge mod"), `scripts/arc_shadow_test.py`, `scripts/arc_stress.py` + `tests/stress/*.nox`.

### Tahsis kararları (541 program, 3473 yerel değişken kararı)

| Karar | Adet | Oran |
|---|---:|---:|
| ARC (yığın, referans sayımlı) | 3402 | **%98.0** |
| yığın (sabit boyutlu, kaçmayan liste/sınıf) | 42 | %1.2 |
| arena (büyüyebilir, skaler elemanlı liste / büyük sınıf) | 29 | %0.8 |

ARC'ye düşme nedenleri (ilk 7): 1240 — yalnızca liste literalleri ve sınıf kurucu çağrıları yığın/arena adayıdır (dize, sözlük, işlev sonucu, vb. doğrudan ARC); 753 — büyüyebilir arena yolunda da kaçıyor; 717 — çağrı hedefi sınıf kurucusu değil (işlev dönüşü); 326 — eleman tipi skaler değil; 160 — sınıfta yığın-yönetimli alan var; 142 — çağrı hedefi düz ad değil; 64 — yerel bildirimden sonra güvensiz kullanılıyor.

**Sonuç:** "Katman 1" bugün yalnızca *kaçmayan liste/sınıf yerellerini* yığına/arenaya taşıyan bir kaçış analizidir; geri kalan her şey (dize, sözlük, işlev sonuçları, kaçan her şey) ARC'dir ve her retain/release satır içi `atomicrmw` ile yapılır. AGENTS §8'in tarif ettiği "referans sayacı olmadan ASAP temizliği" büyük ölçüde henüz yok (yalnızca yığın/arena alt kümesinde).

### Ölçülen: atomik sayaç maliyeti

Geçici deney: `atomicrmw add/sub` yerine düz yükle-topla-sakla (wasm32 tek iş parçacıklı yolundaki gibi) tüm native çıktıda zorlanıp `benchmarks/lang_perf` koşuldu (Apple M-serisi): **fark yok** (geometrik ortalama 1.66 → 1.71, gürültü içinde; `alloc_tree` 10.4 → 10.5 ms). Çekişmesiz atomikler bu donanımda ucuz; "tek iş parçacıklı programda atomiksiz sayaç" optimizasyonu Apple Silicon'da kazanç vermiyor (x86'da `lock xadd` pahalıdır; orada ayrıca ölçülmeli, ölçülmeden uygulanmadı).

### Gölge mod fark testi

`NOX_FORCE_ARC=1` ile her program yığın/arena yükseltmesi olmadan derlenip çalıştırılır; stdout, stderr ve çıkış kodu normal derlemeyle **aynı** olmalı (deterministik olmayan, ağ/iş parçacığı/zaman kullananlar atlanır). Sonuç — ReleaseFast ve **Debug çalışma zamanı** (DebugAllocator sızıntı/çift serbest bırakma denetimi açık, stderr karşılaştırılıyor) ile: **437–438 program aynı, 0 fark** (103–104 atlandı). Yani yığın/arena yükseltmesi, "her şey ARC" referansıyla davranışsal olarak tutarlı ve ARC yolu sızıntısız.

## 4.5.2 Eksikler ve bulgular

1. **Kapsam darlığı (yukarıdaki tablo).** En büyük fırsat: (a) kaçmayan **dize** değerleri (birleştirme zincirleri, `f"..."` sonuçları) için arena/yığın; (b) **işlev dönüş değerleri** için "tek sahip, taşıma" analizi (çağrı sonucu hemen bir yerele atanıp kaçmıyorsa retain/release çifti gereksiz); (c) skaler olmayan elemanlı listeler için arena (elemanların bırakılması gerekir); (d) sözlük literalleri. Bu, retain/release çiftlerinin büyük kısmını ortadan kaldırabilir; risk orta (ASAP "yanlış pozitif güvenli" karar vermemeli), gölge mod ve stres düzeneği güvenlik ağı.
2. **Döngü çözücü: tepe bellek ve kalıcı kapasite.** Bulgu (stres testi `deep_structures`): kendine tipçe referans verebilen sınıflarda (zincir `Link.nxt: Link | None`) her `release` (sayaç sıfırlanmayan) nesneyi "olası kök" tamponuna ekler; tampon serbest bırakılan nesneler için yalnızca *tombstone* bırakır ve toplama tetikleyici (`possible_roots_since_collect`) kayıt sayısını sayar (silinenleri düşmez). Canlı grafikte toplama hiçbir şey serbest bırakamadığından uyarlanabilir eşik 700 → 16M'e katlanır; zincir her döngüde yaratılıp atıldığında RSS **ölçekle doğrusal büyür** (ölçek 1/10/40: 20 / 56 / 238 MB; yalnızca 300 bin düğümlü zincir tekrarı, canlı veri hep ≤ 10 MB). Sızıntı değil (Debug sızıntı denetimi temiz, program sonunda hepsi geri verilir) ama tepe bellek ve `roots` kapasitesi şişiyor. *Çözüm adayı:* serbest bırakmada `possible_roots_since_collect` ve canlı kök sayacını düşür; tombstone oranı yüksekse `roots` dizisini yerinde sıkıştır (indeksleri başlıklarda güncelle); toplama sonrası kapasiteyi küçült. Orta risk (kilit/atomik başlık biti ince), stres düzeneği şart.
3. **Sözlük (`dict_churn`): hafif büyüme** (ölçek 1/10/40: 3.5 / 6.9 / 13 MB; 5000 anahtarlı sözlüğe 16M işlem). Mezar taşı yoğunlaştırma ve dize anahtar tahsisleri incelenmeli; Debug sızıntı denetimi temiz.
4. **Liste büyütme sahiplik sözleşmesi** (bkz. dil performans raporu): `append` büyütmesinde eski blok çağıran tarafından release ediliyor; yerinde `realloc`/`mremap` bu sözleşmeyi değiştirmeyi gerektirir. ARC iyileştirme turunda ele alınmalı.
5. **Pinned dize retain'i:** `retain` hâlâ pinned dizelerde atomik artış yapıyor (release v2.1.76'da düzeltildi); sayaç 2^30'dan başladığı için pratikte güvenli, ama gereksiz yazma.
6. **Tasarım notu:** kaçmayan yerellerin yanında *parametre* ödünç alma (callee retain etmeden okur) yalnızca satır içi açılan işlevlerde (`paramNeverEscapes`) yapılıyor; çağrı sınırında genel bir "borrowed parameter" yok.

## 4.5.3 Stres/soak düzeneği (v2.1.78)

`tests/stress/` (altı program; ölçek argümanı `nox.os.arg(1)`): `alloc_storm` (milyonlarca kısa ömürlü liste/dize/sınıf, karışık yaşam süreleri), `cycles` (çift bağlı liste, graf, kendine referans), `deep_structures` (300 bin düğümlü zincir + derin ağaç), `exceptions_paths` (try/except/finally/with + canlı nesneler), `dict_churn` (ekleme/silme, dize anahtar, sınıf değerli), `closures_gen` (nesne yakalayan kapanışlar, terk edilen jeneratörler). `scripts/arc_stress.py`: iki ölçekte (S, 2S) çalıştırır; tepe RSS ve süreyi ölçer; **çıktıların LLVM / QBE / gölge mod** arasında aynı olduğunu, RSS'in `baseline.json` tavanını (×1.5) aşmadığını ve ölçekle sınırsız büyümediğini denetler (bilinen büyüme baseline'da işaretlidir: `deep_structures`).

| Program | Süre (S=10) | RSS | RSS (2S) | Durum |
|---|---:|---:|---:|---|
| alloc_storm | 0.30 s | 2.0 MB | 2.0 | düz, sızıntı yok |
| cycles | 0.18 s | 4.8 MB | 4.8 | döngü çözücü belleği geri veriyor |
| deep_structures | 0.28 s | 55.9 MB | 111.8 | **doğrusal büyüme** (bulgu 2) |
| exceptions_paths | 0.36 s | 1.8 MB | 1.8 | düz |
| dict_churn | 0.39 s | 6.9 MB | 11.0 | hafif büyüme (bulgu 3) |
| closures_gen | 0.43 s | 1.9 MB | 1.9 | düz |

Doğrulama: altı programın hepsi **Debug çalışma zamanı** altında (DebugAllocator sızıntı/çift serbest bırakma denetimi) ölçek 1'de temiz (boş stderr, çıkış 0); çıktılar ReleaseFast ile aynı. Çok iş parçacıklı ARC yarışları (M:N) için mevcut `concurrency_torture*` ve `http_soak` testleri korunuyor; bu düzeneğe eklenmedi.

## 4.5.4 İyileştirme adayları (sırayla, her biri 4.5.3'ten geçmeli)

1. (YAPILDI v2.1.79) Döngü çözücü: canlı-kök sayacı + tombstone sıkıştırması + toplama sonrası kapasite küçültme (bulgu 2) — hedef: `deep_structures` RSS'inin ölçekten bağımsız olması.
2. ASAP kapsamı: kaçmayan dize/dönüş-değeri sahipliği (bulgu 1a/1b) — önce `noxc explain` ile yeni kararların gerekçelendirilmesi, gölge modda fark yok koşulu.
3. Liste büyütme sahiplik sözleşmesi (bulgu 4: v2.1.82'de incelendi, macOS'ta `remap` yok → ertelendi) ve pinned retain (bulgu 5: YAPILDI v2.1.83).
4. Sözlük mezar taşı/dize anahtar tahsisleri (bulgu 3): YAPILDI v2.1.84 (kök neden: yoğunlaştırmada indeks dizisinin yeniden tahsisi + Zig SmpAllocator dilim davranışı).
