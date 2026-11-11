# FFI performans analizi (2026-11-11)

Soru: `extern def` ile C kütüphanesi çağırmanın maliyeti nedir, dar boğaz nerede? (Amaç: C kütüphanelerini Nox'a getirmek, bkz. otomatik binding aracı fikri.)

**Araç:** `benchmarks/ffi_perf/` (`ffi_bench.c` ayrı çeviri birimi → satır içi olamaz; `harness.c` C tabanı; `ffi_perf.nox`; `run.py` Python `ctypes` karşılığıyla birlikte; sağlama toplamı Nox ile C arasında eşleşmek zorunda). **Ortam:** Apple M4, ReleaseFast, 3 koşu medyanı, ns/çağrı.

## Sonuç

| Senaryo | C | Nox LLVM | Nox QBE | Python ctypes | Nox LLVM / C |
|---|---:|---:|---:|---:|---:|
| `int` argümanlı skaler çağrı | 0.71 | 0.72 | 0.76 | 214 | **1.01** |
| `float` argümanlı skaler çağrı | 0.71 | 0.71 | 0.80 | 215 | **1.00** |
| `str` argümanı (1 KB, NUL'lu) | 0.70 | 0.69 | 0.73 | 109 | **0.98** |
| toplu iş: 1M `int` toplamı (C içinde), çağrı başı ns | 72 090 | 72 560 | 74 140 | - | 1.01 |
| aynı toplam Nox'ta `lowlevel` `ptr_read` döngüsüyle | - | 137 540 | 332 060 | - | (C'nin 1.9x / 4.6x'i) |
| **callback** (C → Nox işlevi, çağrı başı) | 0.71 | **4.99** | 5.36 | - | **7.05** |
| `list[int]` → C tamponu kopyası (eleman başı) | 0.22 | 0.40 | 0.87 | - | 1.85 |

## Bulgular

1. **Çağrı maliyeti sıfır.** `extern def` skaler, `float` ve `str` argümanlı çağrılarda çıplak C çağrısıyla aynı (≈0.7 ns); `ctypes`ten 150-300x hızlı. Önceki "FFI maliyeti" kaygısı çağrı yolu için **geçerli değil**. İki backend arasında fark yok (QBE biraz geride).
2. **Callback 7x pahalı** (≈5 ns): C'nin Nox işlevini çağırması bir trampoline'dan geçiyor. Büyük olasılıkla `ptr` bağlam çözümlemesi ve istisna koruması; **nedeni profilenmedi**. Sıcak döngüde milyonlarca callback (örn. `qsort_r` karşılaştırıcı) çağıran kütüphanelerde fark eder; dönüşümü ayrı ölçülebilir.
3. **Asıl maliyet veri aktarımı.** Çağrı sınırından yalnızca `int/float/bool/str/ptr/sabit genişlikli tamsayı` geçebilir. `list[T]`, `Buffer`, `bytes` için **sıfır-kopya bir ham işaretçi yolu yok** (`mem.copy` yalnızca `ptr` alır). Bir `list[int]` C'ye verilecekse `lowlevel` döngüsüyle ayrı bir tampona kopyalanır: LLVM'de 0.40 ns/eleman, **QBE'de 0.87** (QBE bu döngüyü yeterince optimize etmiyor). 1M elemanlı bir veri için ≈0.4-0.9 ms; çağrının kendisi bunun yanında yok sayılır.
4. **Sayısal ağır iş C'de kalmalı.** Nox'un `lowlevel` döngüsü C'nin 1.9x'i (LLVM) / 4.6x'i (QBE); C tarafı vektörleştiriyor.

## Çıkarım (kullanıcı hedefi: C kütüphanesi getirmek)

Maliyet bir engel değil; engel **ergonomi ve kapsam**: (a) struct'ı değerle geçirme/döndürme yok (yalnızca skaler + `ptr`; `@repr("C")` sınıflar ancak `ptr` ile), (b) `list`/`bytes` için zero-copy görünüm yok, (c) `str` dönüşü yalnızca runtime kabukları için, (d) hata sözleşmesi (errno / dönüş kodu) elle sarmalanıyor, (e) callback yalnızca sondaki-`userdata` kalıbı, kaydedilip sonra çağrılan callback yok. Bunlar C başlığından **otomatik binding üretimi** (madde 4) için tasarım girdileridir.

## Öneri

1. (Küçük) `Buffer`/`list[u8]`/`list[int]` için `lowlevel` içinde veri işaretçisi alma (`buffer_ptr`-benzeri) — sıfır-kopya geçiş. **Dil/ABI kararı**, kullanıcıya sorulacak (İlke 1/2 ile uyumlu: ownership gizli kalır, yalnızca `lowlevel`).
2. (Küçük) QBE'de `lowlevel` ptr_write/read döngüsü optimizasyonu veya LLVM-only notu.
3. (Orta) Callback trampoline'ı profile et; sıcak yolda ARC/istisna kontrolünü kaldırma fırsatı.
4. Struct-by-value ve kayıtlı (saklanan) callback için tasarım, binding üreticisiyle birlikte (madde 4).

## Yeniden ölçüm

```sh
zig build -Doptimize=ReleaseFast && python3 benchmarks/ffi_perf/run.py --repeat 3
```
