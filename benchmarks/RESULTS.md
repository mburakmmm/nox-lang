# Nox Benchmark Sonuçları

`zig build bench -Doptimize=ReleaseFast` çalıştırmasının en güncel çıktısı. Tekrarlanabilir doğrulama için `benchmarks/run.zig`'e bakın.

## Bölüm 1 — Stres testleri (yalnızca Nox, büyük N)

Bu testler yalnızca Nox'un büyük ölçekte çökmediğini/sızdırmadığını ve zamanla regresyona uğramadığını doğrular; başka bir dille kıyaslanmaz.

| Benchmark | Süre (min) |
|---|---|
| numeric_recursion | 23.3ms |
| tight_loop_arithmetic | 504.0ms |
| list_traversal | 2.7ms |
| oop_arc_churn | 2.4ms |
| generics_protocols | 80.8ms |
| exceptions_control_flow | 3.0ms |
| lowlevel_arena | 2.9ms |
| string_passing | 95.2ms |
| deep_equality | 12.9ms |
| list_class_field | 7.5ms |
| async_task_churn | 30.4ms |
| dict_bench | 2.8ms |
| json_bench | 17.8ms |
| strings_bench | 5.6ms |
| math_bench | 4.0ms |
| os_fs_bench | 2.9ms |
| time_bench | 5.9ms |
| method_call_elision | 270.0ms |
| strings_perf_bench | 200.0ms |

**19/19 geçti.**

#### Faz M.8 (yeniden ele alındı) — metod çağrısı istisna-kontrolü eleme

`method_call_elision.nox`, `Counter.increment`i (provably-safe — hiç
`raise` etmez, başka bir metod/serbest fonksiyon çağırmaz) 300M kez
çağırır. Aynı ikili, `genMethodCall`in `emitExceptionCheck`i KOŞULSUZ
ürettiği ESKİ davranışa GEÇİCİ olarak geri alınıp (kod deposunda kalıcı
bir değişiklik YAPILMADI — yalnızca ölçüm için) yeniden ölçüldü:

| Durum | Süre (min, 300M çağrı) | Çağrı başına |
|---|---|---|
| ÖNCESİ (kontrol HER ZAMAN üretilir) | 480ms | ~1.60ns |
| SONRASI (provably-safe metodlarda kontrol elenir) | 270ms | ~0.90ns |

**~%44 hızlanma** — bu fazı tetikleyen izole mikro-benchmarkın (bkz. bu
dosyanın ilerisindeki değil, `nox-teknik-spesifikasyon.md` §3.59'daki
~%41'lik ölçümle TUTARLI, aynı büyüklük mertebesinde). IR-metni düzeyinde
GERÇEKTEN elenmenin gerçekleştiği ayrıca doğrudan doğrulandı (bkz.
`tests/golden/codegen_golden_test.zig`deki "IR'da nox_exception_pending
GERÇEKTEN YOK" testi).

#### Faz EE.1 — `nox.strings` performans (`byte_at` + O(n) `join`)

`strings_perf_bench.nox`, İKİ AYRI EE.1 optimizasyonunu BİRLİKTE ölçer:
2006 baytlık bir dizede 50000 `contains` taraması (`starts_with`/`ends_with`/
`index_of`nin de kullandığı, artık alloc-sız `byte_at` tabanlı karşılaştırma)
+ 3000 elemanlı bir `list[str]` üzerinde 500 `join` çağrısı (artık Zig'de
tek-geçiş O(n)). Aynı ikili, İKİ optimizasyon da GEÇİCİ olarak ESKİ
davranışa geri alınıp (`s[i]` tabanlı karşılaştırma + saf-Nox `+`-
birleştirme döngüsü — kod deposunda kalıcı bir değişiklik YAPILMADI,
yalnızca ölçüm için) yeniden ölçüldü:

| Durum | Süre (min) |
|---|---|
| ÖNCESİ (`s[i]` alloc'lu karşılaştırma + O(n²) `join`) | 6040ms |
| SONRASI (`byte_at` alloc-sız + O(n) `join`) | 200ms |

**~30x hızlanma** — çıktı DEĞERLERİ (`50000`/`7499500`) İKİ durumda da
BİREBİR AYNI, DAVRANIŞIN DEĞİŞMEDİĞİNİ (yalnızca performansın) doğrular.

## Bölüm 2 — Python + C karşılaştırması (aynı algoritma, küçültülmüş N)

Her satır üç dilde **aynı algoritmayı** çalıştırır (Python/C, o dilin kendi doğal deyimiyle yazıldı — ör. C'de `oop_arc_churn` için `malloc`/`free`, `exceptions_control_flow` için idiomatic dönüş-kodu). C, `cc -O2` ile derlendi.

| Benchmark | Nox | Python | C | Nox / Python | Nox / C |
|---|---|---|---|---|---|
| numeric_recursion | 15.3ms | 377.2ms | 14.0ms | **24.7x hızlı** | 1.10x yavaş |
| tight_loop_arithmetic | 14.4ms | 1759.6ms | 4.8ms | **122.4x hızlı** | 2.97x yavaş |
| list_traversal | 63.3ms | 1289.4ms | 3.1ms | **20.4x hızlı** | 20.09x yavaş |
| oop_arc_churn | 36.0ms | 475.4ms | 44.8ms | **13.2x hızlı** | 0.80x (Nox C'den hızlı) |
| generics_protocols | 61.2ms | 1573.8ms | 26.0ms | **25.7x hızlı** | 2.35x yavaş |
| exceptions_control_flow | 21.0ms | 673.0ms | 5.9ms | **32.0x hızlı** | 3.57x yavaş |
| lowlevel_arena | 63.3ms | 1323.1ms | 5.0ms | **20.9x hızlı** | 12.65x yavaş |
| string_passing | 72.9ms | 1241.2ms | 8.9ms | **17.0x hızlı** | 8.17x yavaş |
| deep_equality | 7.1ms | 51.7ms | 3.3ms | **7.3x hızlı** | 2.19x yavaş |
| list_class_field | 6.1ms | 49.5ms | 4.3ms | **8.2x hızlı** | 1.43x yavaş |

**10/10 geçti.**

### Özet

- **Python'a karşı:** Nox her senaryoda **7x–122x daha hızlı**.
- **C'ye karşı:** Nox genelde **1x–4x** arasında yavaş (aritmetik/OOP ağırlıklı kodda C'ye çok yakın, `oop_arc_churn`'de C'den bile hızlı); liste/dizi gezme ve `lowlevel` arena gibi bellek-erişim-ağırlıklı senaryolarda fark daha büyük (12x–20x) — codegen'deki gelecekteki optimizasyon fırsatlarını işaret ediyor.
