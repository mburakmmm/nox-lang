# Bacon-Rajan döngü toplayıcısı: eşzamanlılık ve duraklama (K2 + K3, 2026-11-18)

## K2 — Eşzamanlı mı?
**Hayır.** `runtime/alloc/cycle_detector.zig` modül başlığı "Bacon & Rajan'ın **senkron** trial-deletion" algoritmasını söyler; eşzamanlı (concurrent) Bacon-Rajan değildir.
- **Tek iş parçacığı / havuzsuz:** olası-kök sayısı eşiği aşınca (`nox_cycle_possible_root`) toplama **aynı iş parçacığında, çağrının içinde** çalışır (MarkGray → Scan → CollectWhite). Duraklama = toplamanın süresi.
- **M:N havuz:** eşik aşılınca `pool_stw_requested` kurulur ve tüm işçiler kendi güvenli noktalarında bir bariyerde buluşur (`scheduler.stwParticipate`); son varan işçi (lider) toplamayı çalıştırır, öbürleri bariyerde `sleepMs(1)` döngüsüyle bekler. Yani **dünyayı durduran (STW)** ve eşzamanlı değil.
- Yalnızca sınıf örneklerini (döngüsel olabilen sınıfları: `cyclic_classes`) tarar; `str`/liste/dict sayaçlıdır, tarama grafına yalnızca sınıf alanları üzerinden girer.

## K3 — Ne kadar duraklıyor? (ölçüm)
`benchmarks/cycle_gc_pause.nox`, Apple M4, ReleaseFast. Canlı bir halka grafı (her düğüm `other`/`peer` ile komşularını tutar) + her yinelemede çöp A↔B döngüsü + halkadan bir düğümün geçici tutulup bırakılması (canlı grafa olası-kök kaydı). Yineleme süresi = mutatör gecikmesi.

| canlı düğüm | en kötü duraklama | >1 ms yineleme | yineleme başına ort. |
|---|---|---|---|
| 1 000 | 85 µs | 0 | 150 ns |
| 50 000 | 0,66 ms | 0 | 1,59 µs |
| 500 000 | 8,8 ms | 785 | **13,9 µs (~90× yavaş)** |

Duraklama ≈ **olası köklerden erişilen alt grafın boyutu × ~17 ns/düğüm**; öbek boyutuna değil canlı döngüsel grafa bağlı. Asıl sorun duraklamanın uzunluğundan çok **sıklığıydı**: eşik sabit 700 olası-kök kaydı olduğundan, 500 bin düğümlü canlı graf **her 700 kayıtta baştan sona** taranıyordu.

### Düzeltme (v2.2.15)
Verimli toplamadan sonra bir sonraki eşik `max(700, ziyaret_edilen / 4)` olur (üst sınır `MAX_COLLECT_THRESHOLD`): toplama maliyeti kayıt başına amortize O(1). Aynı ölçüm:

| canlı düğüm | en kötü duraklama | >1 ms yineleme | yineleme başına ort. |
|---|---|---|---|
| 1 000 | 81 µs | 0 | 149 ns |
| 50 000 | 1,18 ms | 35 | **161 ns** (10×) |
| 500 000 | 10,5 ms | 4 | **165 ns** (84×) |

Bedel: çöp döngüler bir sonraki toplamaya kadar birikir (en çok eşik kadar kök; örnekte ~125 bin çift ≈ 12 MB). Tek duraklamanın uzunluğu değişmedi (artımlı/eşzamanlı işaretleme gerektirir).

### M:N havuzu (kısmen ölçüldü)
`pool_run`, 4 işçi, biri uzun CPU döngüsüyle (yield yok, ~48 ms) güvenli noktaya geç ulaşan: diğer 3 işçinin en kötü yinelemesi ~330 µs kaldı; bu koşuda toplama isteği uzun döngü sırasına denk gelmedi, **en kötü durum (en yavaş işçinin güvenli noktaya varışı kadar herkesin beklemesi) ölçüyle gösterilemedi**; kod okumasından: bekleyen işçiler `sleepMs(1)` ile yoklar (≥1 ms uyanma granülü) ve bariyer, en uzun yield'siz CPU döngüsü kadar gecikir (kooperatif zamanlama tasarım gereği; bkz. `6.2` preempt incelemesi).

### Öneriler (yapılmadı, karar/ölçüm gerekir)
1. Bariyerde `sleepMs(1)` yerine park/futex (uyanma gecikmesini ~µs'ye indirir).
2. Duraklama uzunluğu için artımlı/eşzamanlı işaretleme (büyük mühendislik; döngüsel grafta duraklamayı dilimlere böler).
3. Yield'siz uzun CPU döngülerinde güvenli nokta yoklaması (derleyici: döngü geri kenarında sayaçlı kontrol) — `6.2` kapsamı.
