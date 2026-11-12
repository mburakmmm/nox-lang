# Dil çekirdeği performans analizi (TODO 3.5; başlangıç 2026-11-12)

Amaç: Nox'un **dil çekirdeği** performansını ölçmek, C ile arasındaki farkın nerede olduğunu bulmak ve dilin anlamını/yüzeyini değiştirmeyen optimizasyonlarla kapatmak. İlke: gözlemlenebilir davranış aynı kalır (hata sırası, taşma, NaN, sıralama), her değişiklik iki backend'de (LLVM varsayılan + QBE) ve önce/sonra çıktı eşitliğiyle doğrulanır; ölçülmeyen kazanç geri alınır.

## 3.5.1 Ölçüm düzeneği (v2.1.73)

`benchmarks/lang_perf/`: 19 çekirdek (sayısal döngü, özyineleme, collatz, elek, matris çarpımı, float döngüsü, `dict[int,int]`, `dict[str,int]`, `list` ekleme/toplama/çıkarma, dize kurma/indeksleme, metot çağrısı, sanal gönderim, işlev-değer çağrısı, jeneratör, istisna, nesne ağacı tahsisi, `sort`, ekleme sıralaması). Aynı iş üç dilde yazılı: `lang_perf.nox`, `lang_perf.py` (CPython 3.15, JIT'li), `lang_perf.c` (`cc -O2`; sözlük-str/jeneratör/istisna kümeleri C'de doğal karşılığı olmadığı için yok). `run.py`: önce ölçek 1'de **sağlama toplamlarının üç dilde aynı** olduğunu doğrular, sonra `--scale` (varsayılan 10) ile zamanlar; ms/ölçek ve oranları yazar (`zig build -Doptimize=ReleaseFast` gerekir).

```sh
zig build -Doptimize=ReleaseFast
python3 benchmarks/lang_perf/run.py --scale 10 --repeat 5          # tablo
python3 benchmarks/lang_perf/run.py --no-python --json out.json    # yalnızca Nox vs C
```

### Tur 1 ölçümü (Apple M-serisi, ReleaseFast, ortanca; ms / ölçek)

```text
kernel                          llvm       qbe     c -O2    python  llvm/c  qbe/c  llvm/py   (ms / ölçek)
loop_arith_5M                   2.93      3.73      1.94    323.74    1.51   1.92    0.009
fib_rec_30_32                   2.48      2.98      2.58     46.46    0.96   1.16    0.053
collatz_300k                   32.98     53.53     33.13   1419.50    1.00   1.62    0.023
sieve_4M                       16.93     20.20     10.14    204.21    1.67   1.99    0.083
matmul_100                      1.09      1.23      0.45     23.89    2.45   2.74    0.046
float_loop_3M                   7.72      8.40      8.88     87.98    0.87   0.95    0.088
dict_int_1.5M                  22.60     23.71      3.38     95.30    6.69   7.01    0.237
dict_str_500k                  28.48     29.06       nan     52.31     nan    nan    0.544
list_append_sum_pop_2M          7.41      5.51      1.65     90.29    4.51   3.35    0.082
str_build_join_300k             7.34      7.37      8.17     11.31    0.90   0.90    0.649
method_calls_3M                11.26     14.85      9.10    178.95    1.24   1.63    0.063
virtual_dispatch_2M             3.00      3.01      1.51    101.83    1.99   2.00    0.030
func_value_calls_2M            13.66     16.56      1.49     97.45    9.14  11.08    0.140
generator_1.5M                 13.92     18.74       nan     44.78     nan    nan    0.311
exceptions_200k                 1.05      1.29       nan     16.11     nan    nan    0.065
alloc_tree_17x4                10.92     11.43     15.05    265.64    0.73   0.76    0.041
sort_500k                      39.57     39.21     40.87    127.58    0.97   0.96    0.310
insertion_sort_3k               1.16      2.65      0.72     52.88    1.61   3.68    0.022
str_index_loop_1M               2.76      3.11      0.43     15.00    6.44   7.25    0.184

geometrik ortalama: llvm/c = 1.87   qbe/c = 2.19   llvm/python = 0.087   (1.0 = eşit; < 1 Nox daha hızlı)
```

### İlk okuma

- CPython 3.15 (JIT'li) karşısında Nox her çekirdekte hızlı (geometrik ortalama ~0.09x = ~11x). Hedef Python değil **C**: LLVM backend C -O2'nin ortalama ~1.9 katında, QBE ~2.2 katında.
- C'ye en uzak çekirdekler (llvm/c): `func_value_calls` ~9x, `dict_int` ~7x, `str_index_loop` ~6.5x, `list_append_sum_pop` ~4.4x, `matmul_100` ~2.4x, `virtual_dispatch` ~2x, `sieve`/`insertion_sort`/`loop_arith` 1.5-1.6x. Bunlar 3.5.2'nin profil hedefleri.
- Nox C'ye eşit ya da önde: `fib`, `collatz`, `float_loop`, `str_build_join`, `alloc_tree`, `sort`.
- QBE çoğu çekirdekte LLVM'den yavaş (özellikle `insertion_sort` 3.7x, `func_value_calls` 11x); backend eşitliği hedefi (madde 5.3) için not.
- `method_calls` ilk sürümde LLVM/C tarafından kapalı biçimde katlanıp 0 ms çıktı; çekirdek `(toplam*31 + x) % p` ile katlanamaz hale getirildi. Yeni çekirdek yazarken bu tuzak göz önünde tutulmalı.

## Sıradaki adımlar

- **3.5.2** profil ve darboğaz analizi: yukarıdaki en uzak çekirdekler için üretilen IR/assembly ve örneklemeli profil; fırsat listesi (kazanç × risk).
- **3.5.3** uygulama turu, **3.5.4** gerileme koruması (bu paketin eşik denetimi).
