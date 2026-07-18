# Nox Benchmark Sonuçları

`zig build bench -Doptimize=ReleaseFast` çalıştırmasının en güncel çıktısı. Tekrarlanabilir doğrulama için `benchmarks/run.zig`'e bakın.

## Bölüm 1 — Stres testleri (yalnızca Nox, büyük N)

Bu testler yalnızca Nox'un büyük ölçekte çökmediğini/sızdırmadığını ve zamanla regresyona uğramadığını doğrular; başka bir dille kıyaslanmaz.

| Benchmark | Süre (min) |
|---|---|
| numeric_recursion | 19.9ms |
| tight_loop_arithmetic | 460.7ms |
| list_traversal | 3.3ms |
| oop_arc_churn | 3.0ms |
| generics_protocols | 44.9ms |
| exceptions_control_flow | 3.2ms |
| lowlevel_arena | 3.4ms |
| string_passing | 57.9ms |
| deep_equality | 12.1ms |
| list_class_field | 7.3ms |
| async_task_churn | 29.3ms |
| dict_bench | 3.7ms |
| json_bench | 14.7ms |
| strings_bench | 4.8ms |
| math_bench | 3.7ms |
| os_fs_bench | 2.8ms |
| time_bench | 6.2ms |
| method_call_elision | 262.3ms |
| for_loop_method_elision | 245.3ms |
| exception_check_overhead | 442.5ms |
| str_index_loop_licm | 80.4ms |
| list_release_overhead | 155.7ms |
| bounds_check_elision | 38.1ms |
| strings_perf_bench | 201.5ms |

**24/24 geçti.**

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

#### Faz GG.3 — for-loop metod çağrısı istisna-kontrolü elemesi

`for_loop_method_elision.nox`, `for b in boxes: total + b.get()` desenini
(GG.3'ün elediği boşluk — `boxes: list[Box]` parametresinin sınıfının
ARTIK for-loop değişkenine YAYILMASI) 240M metod çağrısı (30M dış
yineleme × 8 elemanlı liste) ile ölçer. Aynı ikili, `.for_stmt`in döngü
değişkeninin sınıfını HER ZAMAN `null` bıraktığı ESKİ davranışa GEÇİCİ
olarak geri alınıp (kod deposunda kalıcı bir değişiklik YAPILMADI —
yalnızca ölçüm için) yeniden ölçüldü:

| Durum | Süre (min, 240M çağrı) |
|---|---|
| ÖNCESİ (döngü değişkeninin sınıfı hiç çözümlenmez, fonksiyon zehirlenir) | 273.0ms |
| SONRASI (`list[Box]` parametresinden çözümlenip kontrol elenir) | 259.6ms |

**~%5 hızlanma** — M.8'in doğrudan `self.`/yerel-değişken metod
çağrılarındaki (~%44) kazanımından KÜÇÜK ama GERÇEK: burada elenen tek
şey `nox_exception_pending` kontrolüdür (metod gövdesinin KENDİSİ hâlâ
GERÇEK bir çağrı olarak üretilir, GG.2'nin inlining'i yalnızca SERBEST
fonksiyonları kapsar, metodları DEĞİL). Asıl kazanım DAR (bu TEK darboğaz
değil) ama YAYGIN bir OOP idiomunu (`for item in items: item.method()`)
M.8'in kapsamına GERİ katıyor — GG.3 ÖNCESİ bu desen TÜM enclosing
fonksiyonu KOŞULSUZ zehirliyordu. IR-metni düzeyinde GERÇEKTEN elenmenin
gerçekleştiği ayrıca doğrudan doğrulandı (bkz.
`tests/golden/codegen_golden_test.zig`deki "for-loop içindeki
provably-safe metod çağrısının ÜRETTİĞİ IR'da nox_exception_pending
GERÇEKTEN YOK" testi).

#### Faz GG.4 — Değerlendirildi, REDDEDİLDİ: `nox_exception_pending`i inline etme (ÖLÇÜLMÜŞ regresyon)

`exception_check_overhead.nox` — `maybe_raise` GÖVDESİNDE bir `raise`
OLDUĞUNDAN `must_not_raise`e ASLA giremeyen, bu yüzden HER çağrı sitesinde
istisna kontrolünün HER ZAMAN üretildiği (M.8/GG.2/GG.3'ün ELEMESİNİN
YAPISAL olarak İMKANSIZ olduğu) TEK kalan durum — 300M çağrı, GERÇEKTEN
raise EDEN hiçbiri yok. GG.1/GG.2'nin `emitInlinePredecrement`/seçici
inlining'iyle AYNI desen (`RuntimeState.pending_exception`in bayt
offset'ini `@offsetOf` İLE build.zig'e YENİ bir `rt_layout` modülü
ekleyip DOĞRUDAN `%rt`den `loadl`+`cnel` İLE OKUMAK, `nox_exception_pending`
ÇAĞRISI YERİNE) UYGULANDI, TAM olarak doğrulandı (467/468 yeşil, break→
red→fix RİTÜELİ 20 testi GERÇEKTEN kırmızıya çevirdi — istisna yayılımının
KENDİSİ doğrulandı), AMA ölçüm BEKLENENİN TERSİNİ gösterdi:

| Durum | Süre (min, 300M çağrı) |
|---|---|
| ÖNCESİ (`call $nox_exception_pending`) | 453.5ms |
| SONRASI (inline `loadl`+`cnel`) | 532.5ms |

**~%17 YAVAŞLAMA** — 3'er tekrarla İKİ YÖNDE de DOĞRULANDI (gürültü
DEĞİL, TEKRARLANABİLİR). Kök neden, kesin olarak PROFİLLENMEDİ (bu turun
kapsamı DIŞINDA), ama en olası açıklama QBE'nin KENDİ (araştırmayla ÖNCEDEN
doğrulanmış — bkz. §3.66'nın giriş notu) linear-scan register
ayırıcısıdır: `call` sınırı doğal bir "canlı aralık" kesim noktası
sağlarken, `loadl`/`cnel`i AYNI temel bloğa gömmek KAYIT baskısını
ARTIRIP `maybe_raise`in KENDİ gövdesindeki DEĞİŞKENLER İçin DAHA KÖTÜ
spill kararlarına yol AÇMIŞ olabilir — M.5/M.8'in "ölçülmeden mimari
EKLEME" reddiyle AYNI kategoride bir sonuç, ama BURADA tersine: mimari
ÖLÇÜLDÜ VE reddedildi. **Kod deposundan TAMAMEN GERİ ALINDI** (`git checkout`
İLE codegen.zig/build.zig/runtime/alloc/asap.zig, `runtime_state.zig`
SİLİNDİ) — `nox_exception_pending` HÂLÂ gerçek bir `call`dır.
`exception_check_overhead.nox` KALICI bir regresyon-koruma benchmark'ı
olarak TUTULDU (gelecekte AYNI "inline et" fikri yeniden denenirse AYNI
ölçümle karşılaşacaktır).

#### Faz GG.5 — Döngü içindeki `s[i]`nin tekrar eden `strlen`i (manuel LICM)

`str_index_loop_licm.nox` — 5000 baytlık bir dizeyi 4000 kez baştan sona
TARAR (20M `s[i]` erişimi). GG.5 ÖNCESİ `genStrIndex`in sınır kontrolü
İÇİN gereken `strlen(s)` HER TEK erişimde YENİDEN hesaplanırdı — dizi
UZUNLUĞUYLA orantılı bir maliyet, döngü BAŞINA TEKRARLANDIĞINDAN GERÇEK
bir O(dizi uzunluğu × erişim sayısı) hazır. Aynı ikili, önbellekleme
mekanizması (`enterStrLenCacheScope`/`str_len_cache`) GEÇİCİ olarak
DEVRE DIŞI bırakılıp (kod deposunda kalıcı bir değişiklik YAPILMADI —
yalnızca ölçüm için) yeniden ölçüldü:

| Durum | Süre (min, 20M erişim) |
|---|---|
| ÖNCESİ (`strlen` HER `s[i]`de yeniden hesaplanır) | 1919.3ms |
| SONRASI (döngüye girmeden ÖNCE BİR KEZ hesaplanıp önbelleklenir) | 82.3ms |

**~%96 hızlanma (~23,3×)** — GG.1-GG.4'ün EN BÜYÜK ölçülmüş kazanımı;
GG.1'in araştırma notunda ÖNGÖRÜLEN "QBE'nin LICM yapmaması" kök neden
sınıfının EN NET somutlaşmasıdır. Uygunluk KATI muhafazakâr: bir isim
YALNIZCA (1) `str`-tipli VE (2) BU döngü gövdesinde (iç içe döngüler
DAHİL) HİÇ yeniden atanmıyorsa VE (3) gövdede HİÇBİR iç içe closure
(`func_def`) YOKSA önbelleğe ALINABİLİR (bkz. `bodyHasNestedFuncDef`/
`collectReassignedNames`in belge notları) — aksi TAKDİRDE (GG.1/GG.2/
GG.4'ün AYNI disipliniyle) GÜVENLİ, ESKİ davranışa (her erişimde GERÇEK
`strlen`) SESSİZCE geri düşülür. Break→red→fix ritüeli İKİ AYRI güvenlik
boyutunu doğruladı: (1) `if (true or !reassigned.contains(...))` İLE
yeniden-atama KORUMASI GEÇİCİ olarak devre dışı bırakılınca `s`nin
BAYAT (döngüye girmeden ÖNCEKİ) uzunluğu KULLANILIP GEÇERLİ bir erişim
YANLIŞLIKLA `IndexError` fırlattı (101 yerine 200 — bkz. `tests/golden/
codegen_cases/str_index_loop_reassign_stale_len.nox`); (2) `pending`in
KENDİSİ `=w copy 0`e sabitlenmesi GEREKMEDİ (GG.5 istisna kontrolüne
DOKUNMUYOR) — bunun YERİNE `enterStrLenCacheScope`in KENDİSİ 467/468
yeşil testle (tek istisna, önceden belgelenmiş İLGİSİZ bir HTTP zamanlama
flake'i) doğrulandı. **Yan bulgu (GG.5'TEN BAĞIMSIZ, AYRI bir takip
görevine bırakıldı):** bir `str` yerelinin bir döngü İçinde yeniden
atanması, AYNI döngüdeki bir `try/except` bloğuyla BİRLEŞTİĞİNDE
ÖNCEDEN VAR OLAN (pre-GG.5 codegen'de de `git stash` İLE doğrulanan) bir
bellek sızıntısı KEŞFEDİLDİ — bu turun kapsamı DIŞINDA bırakıldı.

#### Faz GG.7 — En küçük/en sık ARC yardımcılarını çağrı yerine inline etme

`list_release_overhead.nox` — `make_list` (GG.2'nin seçici inlining'iyle
`run`nin İÇİNE spliced) HER yinelemede TAZE bir `list[int]` inşa edip
HEMEN tüketir (50M yineleme). `releaseValueIfSet`in ilkel-elemanlı
`list[T]` VE `boxed_scalar` (Optional-kutulanmış ilkel) dalları HÂLÂ
GG.1/GG.2'de `.str` İçin ZATEN kurulan `emitInlinePredecrement` desenine
GEÇMEMİŞTİ — GERÇEK bir `call $nox_rc_release` üretiyorlardı. Aynı ikili,
bu İKİ dal GEÇİCİ olarak ESKİ (gerçek çağrı) davranışına döndürülüp
yeniden ölçüldü:

| Durum | Süre (min, 50M döngü) |
|---|---|
| ÖNCESİ (`call $nox_rc_release`) | 171.2ms |
| SONRASI (inline `emitInlinePredecrement` + koşullu `nox_rc_free_payload`) | 157.9ms |

**~%8 hızlanma** — GG.1'in `.str` kazanımından (~%23) KÜÇÜK (`nox_rc_alloc`
İLE GG.2'nin ZATEN eleyemediği KENDİSİ hâlâ dominant maliyet, bkz. GG.2'nin
`list_traversal` notu) ama GERÇEK. Break→red→fix: `should_free`in `jnz`i
`jmp {free_label}` İLE (KOŞULSUZ serbest bırakma) DEĞİŞTİRİLİNCE 4 GERÇEK
test (paylaşılan liste/kutu referanslarının ERKEN serbest bırakılması —
GG.4'ün `.boxed_scalar` belge notunun UYARDIĞI TAM O senaryo) KIRMIZI
oldu — kontrolün GERÇEKTEN load-bearing olduğu KANITLANDI.

#### Faz GG.9 — Kanıtlanabilir sınır-içi erişimlerde bounds-check elemesi

`bounds_check_elision.nox` — `for i in range(len(xs)): ... xs[i] ...`
deseninde `i`nin `[0, len(xs))` ARALIĞINDA olduğu döngünün KENDİ
`range(len(xs))` sınırından ZATEN KANITLANMIŞTIR, ama `xs[i]`nin AYRICA
ürettiği sınır kontrolü (karşılaştırma + `IndexError` dalı) BU ÖNCEDEN
GG.4/GG.6/GG.8'de "ölçülemez" bulunan mul/rt-param DEĞİŞİKLİKLERİNİN
AKSİNE burada GERÇEK bir maliyet TAŞIR (20 elemanlı bir listeyi 5M kez,
100M erişim, tarar). Aynı ikili, `boundsElideApplies`in KENDİSİ GEÇİCİ
olarak KOŞULSUZ `false` DÖNECEK şekilde DEĞİŞTİRİLİP (kod deposunda
kalıcı bir değişiklik YAPILMADI — yalnızca ölçüm için) yeniden ölçüldü:

| Durum | Süre (min, 100M erişim) |
|---|---|
| ÖNCESİ (HER `xs[i]`de GERÇEK sınır kontrolü) | 67.6ms |
| SONRASI (kanıtlanabilir sınır-içi erişimlerde TAMAMEN elenir) | 38.7ms |

**~%43 hızlanma (~1,75×)** — GG serisinin GG.5'ten (~23,3×) SONRA EN
BÜYÜK ikinci ölçülmüş kazanımı; GG.4/GG.6/GG.8'in AKSİNE, İKİ karşılaştırma
+ bir OR + bir koşullu dal ZİNCİRİNİN (TEK bir `mul`/argüman FARKLI OLARAK)
GERÇEKTEN ölçülebilir bir maliyet OLDUĞUNU KANITLAR — muhtemelen HER
erişimde bir VERİ-BAĞIMLI karşılaştırma zincirinin (elemanın KENDİSİ
YÜKLENMEDEN ÖNCE TAMAMLANMASI GEREKEN) yarattığı GERÇEK bir gecikme
zinciri (latency chain). Hem `list[T]` (`genIndex`) hem `str`
(`genStrIndex`) indekslemesi KAPSANIR — TEK bir `bounds_elide_ctx`
(`genForRange`nin TESPİT ETTİĞİ, GG.5'in `str_len_cache`iyle AYNI
`collectReassignedNames`/`bodyHasNestedFuncDef` güvenlik disiplinini
KULLANAN) YETERLİDİR. Break→red→fix: `detectBoundsElideCtx`in yeniden-
atama KORUMASI GEÇİCİ olarak YOK SAYILINCA TAM OLARAK beklenen tek test
(reassignment-safety IR kontrolü) kırmızı oldu — kontrolün GERÇEKTEN
load-bearing olduğu KANITLANDI. **Yan bulgu (GG.9'DAN BAĞIMSIZ, AYRI bir
takip görevine bırakıldı):** `list` yerelinin bir `for`-range döngüsü
İçinde yeniden atanmasının, AYNI döngüdeki bir `try/except` bloğuyla
BİRLEŞTİĞİNDE ÖNCEDEN VAR OLAN (GG.5'in `str` İçin bulduğu AYNI hatanın
`list` KARŞILIĞI, `git stash` İLE pre-GG.9 codegen'de de AYNEN yeniden
üretilen) bir bellek sızıntısı KEŞFEDİLDİ.

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
| numeric_recursion | 15.7ms | 377.4ms | 11.0ms | **24.0x hızlı** | 1.42x yavaş |
| tight_loop_arithmetic | 13.7ms | 1742.8ms | 5.0ms | **127.5x hızlı** | 2.72x yavaş |
| list_traversal | 58.5ms | 1290.0ms | 4.7ms | **22.0x hızlı** | 12.44x yavaş |
| oop_arc_churn | 35.9ms | 469.0ms | 42.8ms | **13.0x hızlı** | 0.84x (Nox C'den hızlı) |
| generics_protocols | 35.6ms | 1590.5ms | 24.3ms | **44.7x hızlı** | 1.46x yavaş |
| exceptions_control_flow | 21.3ms | 677.3ms | 6.1ms | **31.8x hızlı** | 3.49x yavaş |
| lowlevel_arena | 72.7ms | 1321.7ms | 4.1ms | **18.2x hızlı** | 17.72x yavaş |
| string_passing | 44.3ms | 1212.1ms | 8.7ms | **27.4x hızlı** | 5.11x yavaş |
| deep_equality | 7.2ms | 51.5ms | 3.6ms | **7.2x hızlı** | 1.98x yavaş |
| list_class_field | 5.3ms | 49.1ms | 2.8ms | **9.3x hızlı** | 1.89x yavaş |

**10/10 geçti.**

### Özet

- **Python'a karşı:** Nox her senaryoda **7x–127x daha hızlı**.
- **C'ye karşı:** Nox genelde **1x–5x** arasında yavaş (aritmetik/OOP ağırlıklı kodda C'ye çok yakın, `oop_arc_churn`'de C'den bile hızlı); liste/dizi gezme ve `lowlevel` arena gibi bellek-erişim-ağırlıklı senaryolarda fark daha büyük (12x–18x) — codegen'deki gelecekteki optimizasyon fırsatlarını işaret ediyor.
- `generics_protocols` (61.2ms → 35.6ms) ve `string_passing` (72.9ms → 44.3ms)
  Faz GG (serbest-fonksiyon inlining + string performansı) SONRASI belirgin
  biçimde hızlandı — bu iki senaryo, GG.2'nin seçici serbest-fonksiyon
  inlining'inin VE GG.1'in string optimizasyonlarının YOĞUN kullandığı
  kod yollarını temsil eder.

## Bölüm 3 — HTTP verim (throughput) karşılaştırması: Nox / Go / Zig / FastAPI

**Kaynak/tekrarlanabilirlik:** `benchmarks/http_compare/run_compare.sh` —
DÖRT sunucu (`nox_server.nox`, `go_server.go`, `zig_server.zig`,
`fastapi_server.py`), HEPSİ AYNI yanıtı üretir (durum 200, `x: x`
başlığı, `"ok"` gövdesi — 2 bayt), `wrk` İLE ölçülür. Makine: Apple M4
(10 çekirdek), macOS, `go1.26.4`/`zig 0.16.0`/`Python 3.14.6`
(`fastapi 0.136.3`/`uvicorn 0.49.0`)/`wrk 4.2.0`. TÜM sunucular 10
iş parçacığı/işlem KULLANACAK şekilde YAPILANDIRILDI (Nox:
`serve_multicore(port, handle, 10, 0)` — `0` = SINIRSIZ bağlantı, bkz.
aşağıdaki DÜZELTME notu; Zig: 10 `accept()` iş parçacığı AYNI dinleme
soketini PAYLAŞIR; Go: `net/http`nin VARSAYILANI, GOMAXPROCS ÜZERİNDEN
TÜM çekirdekleri otomatik kullanır; FastAPI: `uvicorn --workers 10`).

**⚠️ DÜZELTME (bu bölümün İLK sürümü YANLIŞTI — bkz. aşağıda GEREKÇESİ):**
Bu bölümün YAYIMLANAN İLK sürümü, Nox'un yüksek eşzamanlılıkta (c=100)
çıplak Zig soket tabanına göre 30x+ GERİLEDİĞİNİ VE çok sayıda soket
hatası VERDİĞİNİ raporlamıştı. Bu SONRADAN AYRINTILI bir araştırmayla
(bkz. proje geçmişi) **TAMAMEN yanlış olduğu, İKİ AYRI benchmark-
metodolojisi HATASINDAN kaynaklandığı** kanıtlandı — Nox'un KENDİSİNDE
BÖYLE bir gerileme/kararsızlık YOKTUR:

1. **`noxrt.o` YANLIŞLIKLA Debug modunda linklenmişti.** `nox_server.nox`,
   o an `zig-out/lib/noxrt.o`da NE VARSA ONU kullanılarak derlenmişti —
   VE en son çalıştırılan `zig build` komutu (ReleaseFast BAYRAĞI
   OLMADAN) runtime'ı Debug modunda YENİDEN kurmuştu. Debug modunda
   `runtime/alloc/asap.zig`nin `RuntimeState.allocator()`ı `std.heap.
   DebugAllocator`a (TEK, KİLİTLİ/senkronize bir ayırıcı) gider —
   ReleaseFast'ta İSE `std.heap.smp_allocator`a (kilitsiz, iş parçacığı-
   duyarlı). 10 iş parçacığının HEPSİ AYNI kilitli DebugAllocator'ı
   PAYLAŞTIĞINDA, eşzamanlı istek sayısı arttıkça KİLİT ÇEKİŞMESİ
   ORANTISIZ büyür — TAM DA "orta eşzamanlılıkta İYİ, yüksek
   eşzamanlılıkta ÇÖKÜYOR" deseni bu şekilde üretilir. `zig build
   -Doptimize=ReleaseFast` İLE runtime YENİDEN kurulup `nox_server.nox`
   YENİDEN derlenince, c=100'de verim TEK BAŞINA **~10x-30x arttı** VE
   soket hataları KAYBOLDU.
2. **`nox_server.nox`nin `max_connections` parametresi (4. argüman)
   `4096` olarak AYARLANMIŞTI** — bu parametrenin AslIn'da "TOPLAM bu
   kadar bağlantı kabul edip SONRA sunucuyu KENDİLİĞİNDEN durdur"
   anlamına geldiği (deterministik golden testler İÇİN tasarlanmış bir
   özellik, bkz. `runtime/stdlib_shims/http_server.zig`nin `serveImpl`si)
   FARK EDİLMEMİŞTİ — GERÇEK bir verim benchmark'ı KOLAYCA on binlerce
   istek gönderir, bu da sunucunun (ya da 10 iş parçacığından BİRİNİN)
   testin ORTASINDA SESSİZCE durup ÇIKMASINA yol açtı ("connection
   refused" hataları VE görünüşte AÇIKLANAMAYAN çökmeler OLARAK
   gözlemlendi). `0` (sınırsız) OLARAK düzeltildi.

Bu İKİ düzeltmeden SONRA (aşağıdaki DOĞRU sonuçlar) Nox, çıplak Zig
soket tabanını HER İKİ eşzamanlılık seviyesinde de GEÇİYOR — kayda değer
bir kararsızlık/gerileme YOK. **Ayrıca bu araştırma sırasında, zamanlayıcının
hazır kuyruğunda BAĞIMSIZ, GERÇEK bir O(n)→O(n²) verimsizlik BULUNUP
düzeltildi** (bkz. `runtime/async_rt/scheduler.zig`nin `run()`u,
`orderedRemove(0)` → `swapRemove(0)`) — YÜKSEK eşzamanlılıkta BİR
`reactor.poll()` çağrısı TEK seferde 64'e kadar fiber'ı hazır kuyruğa
ekleyebildiğinden (`io_reactor.zig`nin `events: [64]` arabelleği),
`orderedRemove(0)`nin HER kaldırmada kuyruğun TÜMÜNÜ kaydırması bu
PARTİYİ boşaltmayı O(n²) yapardı; sıralama (FIFO) zamanlayıcı İçin
davranışsal olarak GEREKMEDİĞİNDEN (yalnızca ADALET gerekir)
`swapRemove` GÜVENLE O(1) yapar. Bu, DOMİNANT neden DEĞİLDİ (yukarıdaki
İKİ metodoloji hatası dominanttı) ama GERÇEK, bağımsız bir iyileştirmedir.

**Ayrı, BENİGN bir gözlem (araştırma sırasında BULUNDU, KAYDA DEĞER ama
ÇÖZÜLMESİ GEREKMEYEN):** `wrk`, Nox'un sunucusuna karşı (Zig/Go/FastAPI'ye
KARŞI DEĞİL) her zaman bir miktar "read"/"write" "soket hatası" raporlar
— ama bu GERÇEK istek KAYBINI YANSITMAZ: hem `ab` (Apache Bench, 5000/5000
istek BAŞARILI, %0 hata) HEM sıralı `curl` döngüsü (50/50 BAŞARILI) AYNI
sunucuya karşı SIFIR hata gösterdi. Bu, `wrk`nin KENDİ bağlantı-yeniden-
kullanım mantığının Nox'un TAM OLARAK `keep_alive=false` İLE kapattığı
bir bağlantıyı ÇOK KISA bir pencerede YENİDEN kullanmaya ÇALIŞMASINDAN
kaynaklanan, ZARARSIZ bir `wrk`-özgü tuhaflık gibi GÖRÜNÜYOR — GERÇEK
bir Nox hatası DEĞİL, ayrıca araştırılmadı (kapsam dışı bırakıldı).

### Orta eşzamanlılık (`wrk -t4 -c30 -d10s`) — TÜM DÖRT sunucu AYNI ayarlarla

Bu seviyede (30 bağlantı, yerel makine/loopback) HİÇBİR sunucu GERÇEKTEN
DOYURULMUYOR:

| Sunucu | İstek/sn |
|---|---|
| Nox (`serve_multicore`, N=10) | **17,073** |
| Zig (çıplak `std.c` soket, N=10 iş parçacığı) | 14,970 |
| Go (`net/http`, varsayılan keep-alive) | 190,275 |
| FastAPI (`uvicorn --workers 10`, varsayılan keep-alive) | 21,792 |

### Yüksek eşzamanlılık (`wrk -t8 -c100 -d15s`)

| Sunucu | İstek/sn |
|---|---|
| Nox (`serve_multicore`, N=10) | **12,506** |
| Zig (çıplak `std.c` soket, N=10 iş parçacığı) | 7,038 |
| Go (`net/http`, varsayılan keep-alive) | **196,759** |
| FastAPI (`uvicorn --workers 10`, varsayılan keep-alive) | 24,337 |

**⚠️ İKİNCİ bir metodoloji notu (bu turda BULUNDU, DÜZELTİLDİ — Nox'un
KENDİSİYLE İLGİSİZ):** `run_compare.sh`'ın `pkill -f "uvicorn
fastapi_server:app"` temizlik deseni, uvicorn'un SPAWN ettiği worker
işlemlerini (bare `Python -c "from multiprocessing.spawn import
spawn_main..."` komut satırıyla çalışırlar, `pkill` deseniyle EŞLEŞMEZ)
YAKALAMIYOR — bu YÜZDEN bir `fastapi_c30` koşumundan SONRA 10 worker
port 8801'de ÇALIŞIR durumda KALIYOR, bir SONRAKİ testin (`nox_c100`/
`zig_c100`/`go_c100`) o porta BAĞLANMAYA çalışan istemcinin GERÇEKTE
hâlâ ÇALIŞAN uvicorn worker'larına isabet etmesine yol AÇIYOR (yanıt
başlığında `server: uvicorn` GÖRÜLEREK doğrulandı). Bu turun sonuçları
HER test öncesi `lsof -ti :8801 | xargs kill -9` İLE porta bağlı TÜM
işlemler (isim eşleşmesi ARANMADAN) temizlenerek yeniden ölçüldü.
Ayrıca, Zig'in c=100 sonucu run-to-run GÖZLE GÖRÜLÜR bir varyans
gösterdi (gözlemlenen aralık ~5,200–10,800 İstek/sn, birkaç koşumda
İLK 100 bağlantının HEPSİ reddedilip test SÜRESİNİN NEREDEYSE TAMAMI
boyunca toparlanamadı) — muhtemelen çıplak `accept()`-döngüsü
mimarisinin 10 iş parçacığının HEPSİNİN `accept()` içinde BLOKE
olması İçin gereken kısa ısınma süresi YETERSİZ kalınca 100 eşzamanlı
bağlantının bir kısmının SYN kuyruğunda düşmesi VE `wrk`nin bu KAYIP
bağlantılar İçin UZUN TCP yeniden-gönderim zaman aşımlarına takılması;
yukarıdaki tablo BİRDEN FAZLA (5) koşumun ORTANCA'sını temsil eder.
Bu, Nox'un KENDİSİNDE bir sorun DEĞİLDİR (Nox aynı koşullarda İSTİKRARLI
kaldı) — yalnızca ham `accept()`-döngüsü mimarisinin, olgun bir HTTP
sunucusunun aksine, bağlantı fırtınalarına karşı DAHA KIRILGAN olduğunu
gösterir.

### Özet

- Nox, HER İKİ eşzamanlılık seviyesinde de çıplak Zig soket tabanını
  (aynı "N iş parçacığı, tek dinleme soketi, bağlantı başına tek istek"
  mimarisiyle) GEÇİYOR — c=100'de fark ÖNCEKİ ölçümden DAHA BÜYÜK (bkz.
  yukarıdaki Zig varyansı notu) — `nox.http.serve_multicore`nin
  ARC/fiber/QBE-codegen soyutlamasının GERÇEK ek yükü, doğru
  (ReleaseFast) bir runtime İLE ÖLÇÜLEMEYECEK kadar KÜÇÜK.
- Go, keep-alive'ın (Nox/Zig'in `Connection: close` mimarisinin AKSİNE,
  TCP el sıkışma maliyetini ORTADAN KALDIRAN) DOĞAL avantajıyla AÇIK ARA
  önde — bu, `nox.http.serve`nin keep-alive DESTEKLEMEMESİNİN GERÇEK,
  ölçülebilir maliyetidir (gelecekteki bir faz İçin AÇIK bir aday),
  Nox'un ham istek-işleme HIZIYLA İLGİLİ bir sınırlama DEĞİLDİR.
- FastAPI/uvicorn, keep-alive AÇIK olmasına RAĞMEN Nox İLE AYNI
  MERTEBEDE — Python/ASGI katmanının KENDİ ek yükü, keep-alive
  avantajını BÜYÜK ÖLÇÜDE dengeliyor.
- **Ders (gelecekteki benchmark çalışmaları İçin):** `noxc build`/`run`,
  o an `zig-out/lib/noxrt.o`da NE VARSA ONU (Debug YA DA ReleaseFast)
  KOŞULSUZ kullanır — hangisinin kurulu olduğuna dair HİÇBİR uyarı
  YOKTUR. Manuel performans ölçümünden ÖNCE HER ZAMAN `zig build
  -Doptimize=ReleaseFast` çalıştırıldığından EMİN OLUNMALIDIR (bkz.
  CONTRIBUTING.md).
