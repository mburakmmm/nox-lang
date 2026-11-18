# E — Eşzamanlı (concurrent) Bacon-Rajan: kanıtlı zorluk/risk değerlendirmesi ve aşamalı plan (2026-11-18)

Durum: **plan; kod yazılmadı.** AGENTS §16: bellek modeli + ABI etkisi → kullanıcı kararı gerekir (Bölüm 7).
Girdi: `project/bacon-rajan-analizi-2026-11-18.md` (K2/K3 ölçümleri), `runtime/alloc/cycle_detector.zig` (1176 satır), `compiler/codegen_qbe/ownership.zig`.

## 1. Neyi çözmek istiyoruz (fayda tarafı, ölçülmüş)

- Toplama duraklaması ≈ **adayların eriştiği alt-graf × ~17 ns/düğüm** (500 bin canlı düğümde ≈ 9–10 ms). Öbek boyutuyla değil, aday köklerden erişilen graf ile orantılı.
- Eşik düzeltmesi (v2.2.15) **sıklığı** düşürdü (yineleme başına 13,9 µs → 165 ns); tek duraklamanın **uzunluğu** değişmedi.
- Gerçek HTTP yükünde (Aether) ARC darboğaz değil; `@acyclic` analizi sayesinde döngü toplayıcı çoğu istekte hiç çalışmıyor.
- Sonuç: eşzamanlı toplayıcı **verim (throughput) kazandırmaz**; yalnızca büyük canlı **döngüsel** graflı programlarda **kuyruk gecikmesini** (p99.9) düşürür. Bunun gerçekten gerekli olup olmadığı **E0'da ölçülmeden** yatırım yapılmamalı.

## 2. Kod okumasından çıkan engeller (kanıt)

| # | Bulgu (dosya) | Sonuç |
|---|---|---|
| H1 | `markGray` çocukların **başlık sayacını yerinde azaltır** (`hdrWord(child).* -%= 1`, atomik değil), `scanBlack` geri artırır (`cycle_detector.zig` ~548, ~607) | Yaşayan mutator varken başlıktaki sayaç **yalan** olur: bir `release` 0'a çarpıp erken serbest bırakabilir. Eşzamanlı sürüm **yan tablo CRC** (deneme sayacı) gerektirir; başlıkta boş 32 bit yok (rc düşük 32 + idx 26 + SHARED/LOCK/renk/buffered; yalnız bit 63 boş) |
| H2 | `traceChildren` → codegen'in ürettiği `$Class_trace` alanları **atomik olmadan** okur; sonuç arabelleği `nox_trace_buf_alloc(rt)` ile **çağıranın rt'sinden** tahsis edilir | Toplayıcı iş parçacığının **kendi rt/allocator'ı** olmalı (arena-pool yuvaları iş parçacığı-güvenli değil). Alan okumaları 64-bit hizalı; yine de `atomic(.monotonic)` okumaya çevrilmeli (UB'yi önlemek için) |
| H3 | Serbest bırakılan blok havuz bağlı-listesine hemen döner (`emitClassFreePayload` satır içi), `readTag(p)` serbest belleği okuyabilir | **Karantina** şart: toplama sürerken serbest bırakmalar "limbo" listesine alınır. Mevcut `fast_alloc_on` bayrağı (fail-closed, `rt-24`) satır içi havuz yolunu zaten kapatıp yavaş yola yönlendirebiliyor → **kanca hazır** |
| H4 | `cycle_gc_lock` yalnızca `pool_ever_active` iken tutuluyor (`gcLockIfShared`, v2.2.x) | Toplayıcı iş parçacığı varken bu **kilit atlaması kaldırılmalı** (tek iş parçacıklı programda kilit maliyeti geri gelir; ölçülmeli) |
| H5 | `nox_cycle_possible_root` yalnız `release` sonrası `rc>0` iken çağrılır; renk/buffered bitleri başlıkta | Mutator tarafı zaten başlık bitlerini okuyor → bariyer için **ek bellek erişimi yok** |
| H6 | B1 "son kullanımda taşıma" (move) bir kenarı **rc değişmeden** yaratır | Recycler'ın "her kenar değişimi bir sayaca dokunur" argümanı bu kenar için **geçerli değil**. Muhafazakâr yönde güvenli olduğu **tahmin** (toplayıcı yeni kenarı saymaz → düğüm "canlı" görünür); ters yönde (toplayıcının saydığı kenarı rc'siz kaldıran bir taşıma) var mı **kanıtlanmalı** — E1'in ilk işi |
| H7 | WASM / iOS / freestanding'de iş parçacığı yok | STW yolu **kalmalı**: iki toplayıcı kipi, her codegen değişikliği iki backend × iki kip |

Mutasyon noktası sayısı ilk bakışta büyük ama **merkezileşmiş**: codegen'de 25 `emitInlineRetain` + 9 `emitInlinePredecrement` **çağrı yeri** yalnızca **2 yardımcı fonksiyon**dan geçer (`ownership.zig:803` ve komşusu); runtime'daki ~98 rc çağrısı `nox_rc_retain` / `nox_rc_predecrement` / `nox_rc_release` ailesine iner (`nox_rc_retain` zaten atomik `fetchAdd(.acq_rel)`; **eski değer dönüşü bedava**). Bariyer yalnız **döngüsel olabilen sınıflara** (`cyclic_classes`) ve onları tutan kaplara gerekir; `@acyclic`/skaler/`str` hiç etkilenmez.

## 3. Hazır olan altyapı (riski düşüren kanıtlar)

- `cycle_detector.zig` sahte nesne düzeneği (`newFakeObject`, `wireField`, `fakeTraceDispatch*`, `simulateRelease`) → toplayıcı algoritmasını **derleyici/runtime olmadan** rastgele graf + rastgele mutasyonla **diferansiyel fuzz** edebiliriz (STW toplayıcı = oracle).
- Renk/buffered/idx başlıkta, `compactRoots`, `nox_cycle_forget` kilit altında zaten çalışıyor.
- STW bariyeri (`scheduler.stwParticipate`) fallback olarak kalır.
- `NOX_RC_STATS` + `-Dkeep-symbols` + `sample` ile bariyer maliyeti anında ölçülebilir.

## 4. Gerçekçi zorluk hükmü

- **Araştırma-düzeyi imkânsız değil:** Recycler (Bacon vd. 2001, Java), Σ/Δ doğrulamalı eşzamanlı döngü toplama literatürde çözülmüş; bizim koşullarımız (atomik RMW zaten var, çalışma zamanı sahibi, sınıf başına `trace`) uygun.
- **Ama "orta iş" da değil.** En tehlikeli sınıf: **sessiz bellek bozulması** (erken serbest bırakma) — yalnızca nadir iç içe geçmelerde çıkar, CI'da haftalar sonra kırmızı olur. Bu yüzden maliyetin büyük kısmı **test altyapısı**dır, algoritma değil.
- Kaba iş tahmini (AI destekli, tek geliştirici): E0 3 gün · E1 ~2 hafta · E2 2–3 hafta · sertleştirme 2 hafta. Risk: **yüksek**, ancak her aşama kapıyla durdurulabilir ve STW her zaman geri dönüş yolu.

## 5. Aşamalı plan ve kapılar (kill criteria)

**E0 — Ölçüm (kod riski ≈ 0, ~3 gün)**
1. Aether/Nyx yükü altında toplayıcı çağrı sayısı + duraklama histogramı (yeni `NOX_RC_STATS` satırı). **Kapı G0:** gerçek sunucu/araç iş yüklerinde p99.9 duraklama **< 2 ms** ise E **durdurulur** (fayda yok); yalnızca sentetik büyük-graf programlarda sorun varsa E yerine F (aşağıda) seçilir.
2. Bariyer maliyeti prototipi: `emitInlineRetain/Predecrement` + `nox_rc_retain/predecrement` içinde "eski değerin renk bitleri ≠ siyah → yavaş yol" kontrolü, yalnızca `cyclic_classes` için, bayrak arkasında. **Kapı G1:** AST/trees/collections kıyaslarında ≤ %2 yavaşlama; döngüsüz programlarda sıfır (IR farkı yok).

**E1 — Algoritma doğruluğu (aynı iş parçacığı, ~2 hafta)**
- Yan tablo CRC'li, **artımlı** (dilimli) toplayıcı; mutator kancaları + limbo listesi; henüz yeni iş parçacığı yok (dilimler sahibi iş parçacığında ara ara çalışır).
- H6 (taşıma kenarı) için yazılı kanıt + fuzz karşı-örnek taraması.
- **Kapı G2:** sahte-nesne fuzz'unda (≥ 10⁹ rastgele işlem, birden çok tohum) **erken serbest bırakma = 0**, kaçak = STW oracle ile aynı; tüm `zig build test` + fixture korpusu iki backend'de yeşil; Aether/Nyx test paketleri yeşil.

**E2 — Gerçek eşzamanlılık (~2–3 hafta)**
- Toplayıcı iş parçacığı (kendi rt/allocator, atomik alan okumaları), `cycle_gc_lock` atlamasının kaldırılması, kapanış sırası, `nox.thread` çocuk rt'leri, M:N havuzu.
- **Kapı G3:** TSan benzeri stres (mümkünse `-fsanitize-thread`), 24 saat Aether yük testi, kaçak/çökme yok; duraklama histogramında p99.9 hedefi (öneri: < 500 µs) sağlanıyor; verim kaybı ≤ %3.

**E3 — Yayın:** önce opt-in (`NOX_GC=concurrent`), 2 sürüm sonra varsayılan; WASM/iOS/freestanding STW kalır. AGENTS §2 değişmez ilkeleri: etkilenmiyor (unwind yok, ownership sözdizimi yok); §6 global durum: yeni toplayıcı durumu `RuntimeState` içinde kalır.

## 6. Daha ucuz alternatifler (E yerine ya da E'den önce)

- **F — Paralel STW işaretleme:** `markGray/scan/collectRoots` işçiler arasında bölünür (çalışma çalma; havuz zaten var). Mutator durduğundan H1/H3 yok; beklenen duraklama ≈ /N (4–8 işçide 3–5×). Risk **düşük-orta**, ~1–2 hafta. Tek iş parçacıklı programlara faydası yok.
- **G — Artımlı aday sınırlama:** her toplamada yalnızca ilk K aday kök işlenir (dilimlenmiş STW). **Kanıt gerekli:** aday kökler çoğunlukla aynı büyük grafı paylaşıyorsa kazanç sıfır; E0 histogramı bunu gösterir.

## 7. Karar (kullanıcıdan istenen)

1. E0'ı başlatalım mı (yalnızca ölçüm + bariyer prototipi, kapı G0/G1'de dururuz)? **Öneri: evet.**
2. G0 sonucuna göre: gerçek duraklama sorunu çıkarsa E1'e, yalnızca sentetik sorunsa F'e geçilsin mi?
3. Yan tablo CRC (başlık ABI'si **değişmez**) tercih edildi; başlığı 16 bayta çıkarmak (ABI + bellek maliyeti) **önerilmez**.

## 8. E0 sonuçları (2026-11-18, ölçüldü)

Araç: `NOX_RC_STATS=1` artık çıkışta `NOXGC collections=… total_us=… max_us=… visited=… freed=…` + log2 µs kovaları da yazar (yalnız çalışma zamanı env'i; derleme bayrağı gerekmez; hosted/Windows-dışı). ReleaseFast.

| İş yükü | Toplama sayısı | En uzun duraklama |
|---|---|---|
| **Aether** `/ping` + `/echo`, wrk 50 bağlantı, ~200 bin istek/sn, 1 işçi (123 M tahsis) | **1** (kapanıştaki son toplama) | 5 µs |
| Aether, 4 işçi (108 M tahsis) | **1** | 9 µs |
| Nyx test paketi (72 test, 3 süreç) | 1'er (kapanış) | 0 µs |
| `cycle_gc_pause` sentetik, 500 bin canlı döngüsel düğüm | 903 | 12,4 ms (kova 8–16 ms: 5; 1–2 ms: 18) |

**G0 hükmü:** gerçek sunucu/araç iş yüklerinde döngü toplayıcı **hiç duraklama üretmiyor** (`@acyclic` + kapsam analizi döngüsüz nesneleri toplayıcıya sokmuyor). Plandaki durdurma ölçütü (p99.9 < 2 ms) fazlasıyla sağlandı → **E1/E2'nin fayda gerekçesi şu an ölçülebilir bir iş yükünde yok.** Yalnızca büyük canlı döngüsel graf tutan (simülasyon, oyun, büyük çift bağlı yapılar) programlar etkilenir; bunun için gerçek bir örnek program henüz yok.

## 9. Karar ve F uygulaması (2026-11-18, v2.2.18)

Kullanıcı kararı: **E kapatıldı**, süreyi kısaltmak için **F (paralel STW işaretleme)** yapıldı.

- Uygulama: `runtime/alloc/cycle_detector.zig` (`ParShared`/`ParWorker`, aşamalar mark/scan/collect), `runtime/alloc/asap.zig` (`createAuxState`/`destroyAuxState`). İşçi başına hafif `RuntimeState` (üretilen `$Sınıf_trace` yalnız `rt`yi `nox_trace_buf_alloc`a iletir → her işçinin kendi tek arabelleği), atomik başlık işlemleri, renk CAS ile düğüm talebi, paylaşılan kuyrukta kaba taneli iş bağışı + boşta-sayacıyla sonlandırma.
- Doğruluk argümanı: `scan`de beyaza boyama bayat `rc==0` okumasıyla yapılabilir; siyah bir ebeveynin sayaç artışı çocuğu (CAS: siyah dışı → siyah) yeniden işler, bu yüzden sonuç sıralı algoritmayla aynı sabit noktadır. Sayaç yalnızca `scan`de artar, `rc>0` okuması yanlış pozitif vermez.
- Ölçüm (500 bin canlı düğümlü parent'lı ikili ağaç, ReleaseFast, M-serisi, makine yüklü): en uzun duraklama 23–24 → 13,4 ms (4 iş parçacığı, 1,75×); toplam toplama süresi 150 → 102 ms. 2 iş parçacığında 15,9 ms, 8'de 12,3 ms. Ölçeklenme sınırı: bellek gecikmesine bağlı işaretçi izleme, her düğümde birden çok ebeveynden gelen atomik sayaç çekişmesi, serbest bırakmanın lider iş parçacığında sıralı kalması. Zincir/halka graflarda kazanç yok (tek sıralı bağımlılık zinciri).
- Doğrulama: rastgele graf farksal testi (sıralı = paralel serbest bırakılan küme, sızıntı yok; 3000 tohum ReleaseSafe), fixture korpusu zorunlu paralel kipte 625/625, Nyx 72/72 ve Aether 35/35 testleri zorunlu paralel kipte yeşil.
