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

## 3.5.2 Profil ve darboğaz analizi (v2.1.75)

Yöntem: en uzak çekirdeklerin (llvm/c oranı) tek başına küçük programlara ayrılması, üretilen LLVM IR'ının (`noxc build ... -o X` yanında `X.ll` bırakır) satır satır okunması ve gerekirse parça parça süre ölçümü. Bulgular, kazanç tahmini ve riske göre sıralanmıştır (hepsi anlamı korur).

### Bulgular

1. **Sabit (pinned) dizenin her `release`inde atomik çarpma (`str_index_loop` 6.5x, tüm `str` kullanan kod).** `text[i]` ASCII yolunda `nox_ascii_chars` tablosundaki **statik** tek-karakterlik dizeyi döndürür (tahsis yok), ama sonuçtaki `release` dizisi koşulsuz `atomicrmw sub ... acq_rel` yapar: pinned bir nesnenin sayacına her yinelemede atomik yazma (≈ 2 ns, iş parçacıkları arası önbellek hattı çekişmesi). Ayrıca `== "a"` için libc `strcmp` çağrısı. *Fırsat:* (a) release öncesi sayacı **atomiksiz yükleyip** pinned ise atla (dize literalleri, `ascii_chars`, her pinned değer için geçerli); (b) tek baytlık literalle karşılaştırmayı satır içi bayt karşılaştırmasına indir. *Risk:* düşük. *Tahmin:* `str_index_loop` ~3-4x, genel `str` ağır kodda %5-15.
2. **Yakalamasız üst-düzey işlev değerinin her kullanımda yığın nesnesi olarak tahsisi (`func_value_calls` 9x).** `apply(inc, q)` döngüsü her yinelemede `nox_rc_alloc(16)` ile 16 baytlık kapanış nesnesi yaratıp (kod işaretçisi + release işaretçisi) çağrıdan sonra dolaylı `release` çağırır. Yakalaması olmayan kapanış değişmezdir. *Fırsat:* bu nesneyi **statik, pinned** veri olarak bir kez bildirmek (dize literalleri gibi); tahsis ve release ortadan kalkar. *Risk:* düşük (kimlik karşılaştırması yok; pinned sayaç release'i zaten atlar). *Tahmin:* ~5x.
3. **Aynı anahtar için üç ayrı sözlük araması (`dict_int` 6.8x, `dict_str`).** `if k in d: d[k] = d[k] + 1` kalıbı `nox_dict_contains` + `nox_dict_get` + `nox_dict_set` olarak üç kez özetleyip dolaşır; C eşdeğeri tek arama. *Fırsat:* sözlük başına **son erişilen yuva önbelleği** (anahtar + indeks, doğrulamalı); aynı anahtara ardışık aramalar özetleme ve dolaşma yapmaz. Bir **tek geçişli** `d[k] += v`/`get-or-insert` ilkeli ayrı bir yol. *Risk:* orta (geçersizleştirme: silme/yeniden boyutlandırma). *Tahmin:* ~1.6-2x.
4. **Liste büyütmesi tahsis-kopyala-bırak (`list_append_sum_pop` 4.4x; 20M eleman: ekleme Nox 73 ms vs C 12.7 ms, toplama ve çıkarma eşit).** Ekleme hızlı yolu satır içi ve ucuz; fark `nox_list_grow`un her iki katlamada yeni blok alıp kopyalaması (büyük bloklarda taze sayfa hataları + 2×n bayt kopya); C `realloc` büyük bloklarda `mremap` ile kopyasız büyür. *Fırsat:* `nox_list_grow`u `allocator.remap/realloc` (yerinde büyütme; Linux'ta `mremap`) ile yapmak, büyük listelerde büyüme çarpanını ayarlamak. *Risk:* düşük (taşınan işaretçiler zaten yeniden yazılıyor). *Tahmin:* ~2-3x ekleme (macOS'ta `mremap` yok → daha az).
5. **Çağrı sonrası `nox_exception_pending` denetimi (her doğrudan/dolaylı çağrıda).** Yaprak ve "asla fırlatmaz" kanıtlanabilen işlevlerin çağrılarında denetim gereksiz (`compiler/effect_graph.zig` zaten etki bilgisi taşıyor). *Fırsat:* kanıtlanmış-fırlatmayan çağrılardan denetimi çıkarmak. *Risk:* orta (etki analizi muhafazakâr olmalı; fırlatma yolu `finally`/`defer` ile etkileşir). *Tahmin:* çağrı ağır kodda %3-10.
6. **`matmul_100` 2.4x ve `virtual_dispatch` 2x, `sieve`/`insertion_sort` 1.6x:** büyük olasılıkla liste indeksleme sınır denetimleri + `list[list[float]]` çift dolaylılığı + döngü değişmezi taşımanın yapılamaması (`alloca` yüklemeleri). Henüz IR düzeyinde doğrulanmadı: 3.5.3'te `bounds_check_elision` düzeneğiyle ayrıca ölçülecek.
7. **QBE farkı:** QBE çoğu çekirdekte LLVM'in 1.1-3.7x gerisinde (özellikle iç içe döngüler); QBE'nin optimizasyonsuz çıktısı ve satır içi açma yokluğu. Backend eşitliği hedefi (madde 5.3) ile birlikte ele alınır; bu turda yalnızca ortak (runtime/IR düzeyi) kazançlar hedeflenir.

### Sıralı fırsat listesi (kazanç × risk)

| # | Fırsat | Etkilenen çekirdekler | Risk |
|---|---|---|---|
| 1 | Pinned dize release'inde atomiksiz atlama + tek baytlık karşılaştırmayı satır içi | `str_index_loop`, tüm `str` kodu | düşük |
| 2 | Yakalamasız işlev değerlerini statik/pinned yapmak | `func_value_calls` ve tüm yüksek-dereceli kod | düşük |
| 3 | `nox_list_grow` için yerinde büyütme (realloc/mremap) | `list_append`, tüm büyük listeler | düşük |
| 4 | Sözlük son-yuva önbelleği / tek aramalı güncelleme | `dict_int`, `dict_str` | orta |
| 5 | Kanıtlanmış-fırlatmayan çağrılardan istisna denetimini kaldırmak | çağrı yoğun kod | orta |
| 6 | Sınır denetimi eleme / döngü değişmezi (3.5.3'te ölçülecek) | `matmul`, `sieve`, `insertion_sort` | orta |

## Sıradaki adımlar

## 3.5.3 Uygulama turu 1 (v2.1.76) ve düzeltilen bulgular

Uygulananlar (hepsi semantik korumalı, iki backend'de doğrulandı, ayrıntı spec §3.425):

| Fırsat | Sonuç |
|---|---|
| #1 pinned dize release'inde atomik yazma atlama + `s == "lit"` satır içi bayt karşılaştırması | `str_index_loop` 6.4x → 3.3x (profil: süre %76 `strcmp`'teydi; atomik atlama tek başına görünür fark vermedi, gerçek kazanç satır içi karşılaştırmadan) |
| #2 yakalamasız işlev değeri → statik/pinned kapanış | `func_value_calls` 9.1x → 3.0x |

Geometrik ortalama (llvm/c): 1.87x → **1.67x** (QBE 2.20x → 2.06x).

**Rapor düzeltmeleri (tur 1 sırasında bulundu):**

- *Bulgu 3 (sözlük):* dict'te zaten **son-yuva önbelleği var** (`Dict.last_idx`, v1.142.16); ikinci/üçüncü arama önbellekten döner. Kalan maliyet tek gerçek `findIndex` (tohumlu hash + açık adresleme + `entries` dolaylı karşılaştırma, ~10 ns). Kazanç tablo tasarımı (satır içi anahtar/özet, daha az dolaylılık) gerektirir; orta risk, ayrı tur.
- *Bulgu 4 (liste büyütme):* yerinde `realloc` mümkün değil — üretilen `append` kodu eski bloğu kendisi release ediyor ve eleman retain/release dengesine güveniyor; sözleşmeyi değiştirmek (büyütme + eski bloğun sahiplik devri tek runtime çağrısında) hem `genListAppend` hem `nox_list_grow` için kapsamlı bir codegen+runtime değişikliği ve ARC testleri gerektirir. 4.5 (ARC/ASAP) bölümüyle birlikte ele alınacak.
- *Bulgu 5 (istisna denetimi):* `computeMustNotRaise` (compiler/codegen_qbe/exceptions.zig) doğrudan çağrılar için denetimi **zaten kaldırıyor**; kalan denetimler dolaylı (işlev değeri) ve sanal çağrılarda, yani callee bilinmediğinde zorunlu. Kazanç yalnızca denetimin kendisini ucuzlatmaktan gelir (`nox_exception_pending` bir çağrı; fiber-farkındalığı nedeniyle satır içi yük için `RuntimeState` alan ofsetlerinin ABI'ye açılması gerekir).
- *Bulgu 6 (`matmul`, `sieve`, `insertion_sort`):* IR incelemesi: iç döngüde `a[i][k]`, `b[k][j]` için dört liste uzunluğu yükü + sınır denetimi; indeks döngü değişkenli olduğundan denetimler kalır, satır işaretçisi/uzunlukları LLVM tarafından döngü dışına çıkarılabilir durumda. `list[list[float]]` çift dolaylılığı (C'de bitişik 2B dizi) doğal bir maliyet; 2.4x kabul edilebilir, yapısal kazanç ancak sabit-boyutlu çok boyutlu dizi türüyle (dil özelliği, ayrı karar) mümkün.

Kalan adaylar (her biri tasarım gerektirir): dolaylı çağrı istisna denetimini ucuzlatmak (RuntimeState ABI), sözlük tablo mikro-yapısı, liste büyütme sahiplik sözleşmesi (→ 4.5), sınır denetimi eleme (LLVM `llvm.assume` ipuçları), QBE'ye satır içi açma.

## 3.5.4 Gerileme koruması (v2.1.77)

`python3 benchmarks/lang_perf/run.py --scale 10 --repeat 5 --no-python --check benchmarks/lang_perf/baseline.json [--tolerance 1.3]`: her çekirdeğin donanımdan bağımsız ölçütü (C karşılığı olanlar için **llvm/c oranı**, olmayanlar için llvm ms) `baseline.json` ile karşılaştırılır; tolerans aşılırsa çıkış kodu 1. Sağlama toplamı doğrulaması her çalıştırmada yapılır. Yeni baseline: `--save-baseline benchmarks/lang_perf/baseline.json` (ReleaseFast ile, yeterince boşta bir makinede). Bilinçli olarak CI'ya bağlanmadı (paylaşılan koşucuların gürültüsü); kod değişikliği öncesi/sonrası yerelde çalıştırılır.

## 3.5.3 Tur 2 ön değerlendirmesi (2026-11-12, henüz uygulanmadı)

Kalan "C'ye uzak" çekirdeklerin ne kadarının GERÇEK açık alan olduğu ölçüldü:

- `str_index_loop` (3.3x): çekirdeğin zamanı iki parçadır — `"abcab" * N` kurulumu (~0,6 ms/1M) + döngü (~1 ns/yineleme). Döngü zaten C'ye ~2x; kalan fark büyük ölçüde kıyas yapısı (C'de kurulum modülo ile satır içi). Küçük kazanç, düşük öncelik.
- `dict_int` (6.7x): C referansı elle yazılmış, **tek yoklamalı, eklenme sırasız** açık adresli tablodur; Nox sözlüğü eklenme sırasını korur (`entries` + indeks) ve `contains`+`get`+`set` üç çağrıdır (`last_idx` önbelleği ikinci/üçüncüyü karşılar). Gerçek yapısal fark; mikro-optimizasyon (tohum yüklemesi, karıştırıcı) ~%10-20 verebilir, 6x'in çoğu tasarım gereği.
- `func_value_calls` (3x): C referansı sabit işlev işaretçisini satır içine açıyor; Nox'ta kalan maliyet dolaylı çağrı + çağrı sonrası istisna denetimi. Gerçek açık alan: dolaylı çağrıdan önce hedefi sabit-işlev kanıtlanabiliyorsa doğrudan çağrıya çevirmek (yerel `f = inc` tek hedefli kanıtı zaten `local_escape`te var).
- GERÇEK açık alan (sırayla): (1) `list_append` büyütmesi (4,5x; yerinde `realloc` için sahiplik sözleşmesi, 4.5.4 madde 3), (2) `matmul`/`sieve`/`insertion_sort` sınır denetimi + satır işaretçisi taşıma (2,4x/1,7x/1,6x), (3) tek hedefli işlev değeri → doğrudan çağrı, (4) QBE'ye satır içi açma (QBE çıktısı LLVM'in ~1,1-3,7x gerisinde).

**Yan bulgu (4.5.4 madde 4):** `dict[int, Box]` + `d.pop(k, Box(0))` kalıbında RSS doğrusal büyüyor (~2 B/pop; 5M→40M işlemde 7,5→25,8 MB) ama Debug çalışma zamanı sızıntı denetimi **temiz** — gerçek sızıntı değil, ayırıcı/havuz düzeyinde bir birikim (yalnızca "sınıf varsayılanlı pop" kalıbında; yalnızca `set`/int değerli `pop` düz). Ayrı inceleme.

### Tur 2 sonuçları (v2.1.80)

- `s[i] == "c"` birleştirmesi uygulandı: `str_index_loop` döngüsü 1,0 → ~0,3 ns/yineleme (10M karakter: 10 → 3 ms).
- Sözlük (`dict_int`): profil `findIndex` = %74 (tek gerçek arama, ~11 ns ≈ iki bağımlı önbellek ıskası: slot → `entries`). **Deney:** `int` anahtarı slotta satır içi (16 bayt slot) — ıskayı bire indirmesi beklenirken tablo iki katına çıkınca ~%5 YAVAŞ; geri alındı. Sözlük bu kıyasta tasarım sınırında (ekleme sıralı + tek arama).
- `sieve` iç döngüsüne elle TBAA (liste uzunluğu ≠ eleman) eklenerek IR-düzeyi deney: fark yok (iç döngü bellek-bağımlı, adım atlamalı erişim) → uygulanmadı.
- `func_value_calls`: kalan maliyet `apply` çağrısı + dolaylı çağrı + İKİ `nox_exception_pending` çalışma zamanı çağrısı (satır içi olamıyor, `RuntimeState` düzeni derleyiciyle paylaşılmıyor). Çözüm: sıcak yol bayrağını (fiber yoksa `pending_exception`) derleyicinin bildiği sabit ofsette satır içi okumak → ABI kararı (AGENTS §16: kullanıcıya sorulur).

