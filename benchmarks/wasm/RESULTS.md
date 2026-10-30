# WASM maliyet ölçümü (Faz 10.10)

`benchmarks/wasm_bench.py` ile üretilir (`--runs 3`). Her iş yükü beş kipte derlenir ve çalıştırılır; çıktı native ile birebir aynı olmak zorundadır. wasm kipleri
`compiler/wasm_host.mjs` (Node/V8) ile koşar, yani süre modül derleme + örnekleme + çalıştırmadır (`empty` satırı sabit başlangıç maliyetini gösterir: ~0,1 sn).
Çalışma zamanı ve `noxc` `zig build -Doptimize=ReleaseFast` ile derlenmiştir (Debug çalışma zamanı ~100x yavaştır, ölçüm için geçersizdir).

## Süre

Ortam: Darwin arm64, 10 mantıksal çekirdek, node v26.12.1; her hücre 3 çalıştırmanın en küçüğü (sn); parantez içi native'e oran.

| İş yükü | native (LLVM --release) | wasm | asyncify | threads x1 | threads x4 |
|---|---|---|---|---|---|
| empty | 0.00 | 0.09 | 0.09 | 0.10 | 0.10 |
| fib | 0.18 | 0.25 (1.4x) | 0.25 (1.4x) | 0.28 (1.6x) | 0.28 (1.6x) |
| loop | 0.68 | 0.93 (1.4x) | 0.96 (1.4x) | 1.01 (1.5x) | 1.00 (1.5x) |
| sieve | 0.04 | 0.16 | 0.21 | 0.23 | 0.24 |
| mandel | 0.10 | 0.32 (3.1x) | 0.32 (3.1x) | 0.33 (3.2x) | 0.33 (3.2x) |
| matmul | 0.04 | 0.17 | 0.16 | 0.17 | 0.17 |
| dict | 0.05 | 0.17 (3.3x) | 0.19 (3.7x) | 0.20 (3.9x) | 0.20 (4.0x) |
| strings | 0.07 | 0.25 (3.7x) | 0.27 (4.0x) | 0.23 (3.5x) | 0.23 (3.4x) |
| trees | 0.11 | 0.58 (5.4x) | 0.61 (5.6x) | 0.31 (2.9x) | 0.32 (2.9x) |
| sort | 0.07 | 0.26 (3.7x) | 0.26 (3.7x) | 0.27 (3.9x) | 0.27 (3.9x) |
| collatz | 0.33 | 0.89 (2.7x) | 0.93 (2.8x) | 1.39 (4.2x) | 1.38 (4.1x) |
| async_task_churn | 0.08 | 0.10 (1.3x) | 0.26 (3.3x) | 0.31 (4.0x) | 0.68 (8.7x) |
| channel_pingpong | 0.01 | — | 0.14 | 0.15 | 0.16 |
| parallel_compute | 1.39 | 3.26 (2.3x) | 3.01 (2.2x) | 3.04 (2.2x) | 1.10 (0.8x) |

## Modül boyutu

wasm modül boyutu (bayt, `--release`):

| İş yükü | wasm | asyncify | threads x1 | threads x4 |
|---|---|---|---|---|
| empty | 96722 | 90048 | 59669 | 59669 |
| fib | 96814 | 90118 | 59737 | 59737 |
| loop | 96809 | 90128 | 59757 | 59757 |
| sieve | 102639 | 101496 | 72233 | 72233 |
| mandel | 96987 | 90298 | 59932 | 59932 |
| matmul | 105449 | 106119 | 74375 | 74375 |
| dict | 106185 | 104905 | 73456 | 73456 |
| strings | 103857 | 101902 | 70883 | 70883 |
| trees | 97363 | 92311 | 61911 | 61911 |
| sort | 125238 | 121602 | 90269 | 90269 |
| collatz | 96844 | 90153 | 59778 | 59778 |
| async_task_churn | 102820 | 111610 | 96782 | 96782 |
| channel_pingpong | 104377 | 117900 | 102902 | 102902 |
| parallel_compute | 104329 | 113563 | 98675 | 98675 |

Boyutlar v2.0.84 sonrasıdır: varsayılan kip daha önce DWARF yüzünden ~3 MB idi (`--strip-debug` ile ~100 KB oldu).

## Okuma

- **CPU-bağımlı kodda Asyncify neredeyse bedava** (`fib`, `loop`, `mandel`, `collatz`: varsayılan wasm'a göre +0-4%); ADR-014'ün eski "%30-50" tahmini bu kernellerde geçerli değil. Maliyet çağrı derinliğine ve askıya alma sıklığına bağlı: `async_task_churn` (her görev bir fiber geçişi) varsayılan kipe göre 2,6x yavaş (0,26 sn'ye karşı 0,10 sn); varsayılan kip bu yükü iç içe çalıştırma benzetimiyle fiber olmadan yapar.
- **wasm, native LLVM'e göre 1,4x (fib, loop) ile 5,4x (trees) arasında yavaş.** Bellek-yoğun yükler (`trees`, `dict`, `strings`, `sort`) en çok kaybeder.
- **`--threads` tek işçide hız kaybettirir**: `collatz` 0,89 -> 1,39 sn (atomik ARC ve paylaşımlı bellek). Karşılığı: `parallel_compute` dört eşit görevle Asyncify'a göre 2,7x hızlı (3,01 -> 1,10 sn); `trees` ise ilginç biçimde daha hızlı (0,58 -> 0,31 sn): büyük olasılıkla threads kipinin boyut sınıflı ayırıcısı (`wasm_mt_alloc.zig`) varsayılan kipin `BrkAllocator`ından hızlıdır (ayırıcı ayrı ölçülmedi).
- **Küçük görevlerde fazla işçi zarar verir**: `async_task_churn` 1 işçide 0,31 sn, 4 işçide 0,68 sn (iş çalma ve kilit çekişmesi, görevin kendisi neredeyse boş).
- **`channel_pingpong`** (tamponsuz kanalda 200 bin mesaj): varsayılan wasm kipi bunu yapamaz (`—`: iç içe çalıştırma benzetimi karşılıklı beklemede kilitlenir, ADR-012); asyncify/threads ~0,15 sn. Bu iş yükü native çok-işçili havuzda hatayı ortaya çıkardı (v2.0.85): üretici/tüketici farklı işçilere oturunca boşta işçi 1 ms'lik uykuyla bekliyordu (program dakikalarca "takılıyordu") ve düzeltmeden sonra `Channel.recv`teki bir veri yarışı (göndericiyi uyandırdıktan sonra `slot.value` okuma) görünür oldu. İkisi de düzeltildi.

Sınırlar: tek makine (Apple M4), tek motor (Node 26 / V8), 3 tekrarın en küçüğü; küçük iş yüklerinde (<0,1 sn) oranlar yanıltıcıdır, bu yüzden yalnızca uzun çalışan kernellerde oran verilir.
