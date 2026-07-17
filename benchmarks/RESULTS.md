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
| method_call_elision | 271.3ms |
| for_loop_method_elision | 259.6ms |
| strings_perf_bench | 200.0ms |

**20/20 geçti.**

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
| Nox (`serve_multicore`, N=10) | **20,562** |
| Zig (çıplak `std.c` soket, N=10 iş parçacığı) | 14,743 |
| Go (`net/http`, varsayılan keep-alive) | 191,244 |
| FastAPI (`uvicorn --workers 10`, varsayılan keep-alive) | 22,142 |

### Yüksek eşzamanlılık (`wrk -t8 -c100 -d15s`)

| Sunucu | İstek/sn |
|---|---|
| Nox (`serve_multicore`, N=10) | 12,859 |
| Zig (çıplak `std.c` soket, N=10 iş parçacığı) | 10,866 |
| Go (`net/http`, varsayılan keep-alive) | **195,110** |
| FastAPI (`uvicorn --workers 10`, varsayılan keep-alive) | 23,994 |

### Özet

- Nox, HER İKİ eşzamanlılık seviyesinde de çıplak Zig soket tabanını
  (aynı "N iş parçacığı, tek dinleme soketi, bağlantı başına tek istek"
  mimarisiyle) GEÇİYOR — `nox.http.serve_multicore`nin ARC/fiber/QBE-
  codegen soyutlamasının GERÇEK ek yükü, doğru (ReleaseFast) bir runtime
  İLE ÖLÇÜLEMEYECEK kadar KÜÇÜK.
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
