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

## Bölüm 3 — HTTP verim (throughput) karşılaştırması: Nox / Go / Zig / FastAPI

**Kaynak/tekrarlanabilirlik:** `benchmarks/http_compare/run_compare.sh` —
DÖRT sunucu (`nox_server.nox`, `go_server.go`, `zig_server.zig`,
`fastapi_server.py`), HEPSİ AYNI yanıtı üretir (durum 200, `x: x`
başlığı, `"ok"` gövdesi — 2 bayt), `wrk` İLE ölçülür. Makine: Apple M4
(10 çekirdek), macOS, `go1.26.4`/`zig 0.16.0`/`Python 3.14.6`
(`fastapi 0.136.3`/`uvicorn 0.49.0`)/`wrk 4.2.0`. TÜM sunucular 10
iş parçacığı/işlem KULLANACAK şekilde YAPILANDIRILDI (Nox:
`serve_multicore(port, handle, 10, 4096)`; Zig: 10 `accept()` iş
parçacığı AYNI dinleme soketini PAYLAŞIR; Go: `net/http`nin
VARSAYILANI, GOMAXPROCS ÜZERİNDEN TÜM çekirdekleri otomatik kullanır;
FastAPI: `uvicorn --workers 10`).

**Metodolojik BİLİNÇLİ bir asimetri (SONUÇLARI okurken KRİTİK):**
`nox.http.serve`/`serve_multicore` BUGÜN yalnızca bağlantı-başına-TEK-
istek modelindedir (istek işlenip yanıt yazıldıktan SONRA bağlantı HER
ZAMAN kapatılır, HTTP keep-alive YOK — bkz. `runtime/stdlib_shims/
http_server.zig`nin `connectionEntry`si). `zig_server.zig` (bu
karşılaştırmanın "çıplak Zig tabanı") BİLEREK AYNI modele UYDURULDU
(`Connection: close`, DOĞRUDAN `std.c` soketleri) — bu SAYEDE Nox'a-
karşı-Zig YARISI, BAĞLANTI YENİDEN KULLANIM POLİTİKASI DEĞİL, Nox'un
ARC/fiber/QBE-codegen soyutlamasının ÇIPLAK soketler ÜZERİNE kattığı
GERÇEK EK YÜKÜ izole eder. Go (`net/http`) VE FastAPI/uvicorn İSE
VARSAYILAN (keep-alive AÇIK) modlarında bırakıldı — KENDİ doğal/
gerçek-dünya YAPILANDIRMALARINDA test edilmeleri, Nox'a-karşı-Go/
FastAPI YARISINI daha ANLAMLI/dürüst kılar, ama bu YARININ BÜYÜK
KISMININ "keep-alive VAR mı YOK mu" farkını YANSITTIĞI (SALT istek-
işleme hızını DEĞİL) AÇIKÇA belirtilmelidir.

### Orta eşzamanlılık (`wrk -t4 -c30 -d10s`) — TÜM DÖRT sunucu AYNI ayarlarla

Bu seviyede (30 bağlantı, yerel makine/loopback) HİÇBİR sunucu GERÇEKTEN
DOYURULMUYOR — sayılar birbirine YAKIN, farkı büyük ölçüde İSTEMCİ/
loopback maliyeti BELİRLİYOR:

| Sunucu | İstek/sn | p50 gecikme | p99 gecikme | Soket hatası |
|---|---|---|---|---|
| Nox (`serve_multicore`, N=10) | **24,325** | 1.39ms | 3.05ms | yok |
| Zig (çıplak `std.c` soket, N=10 iş parçacığı) | 21,580 | 1.21ms | 4.08ms | yok |
| Go (`net/http`, varsayılan keep-alive) | 20,882 | 1.39ms | 3.05ms | yok |
| FastAPI (`uvicorn --workers 10`, varsayılan keep-alive) | 19,374 | 1.24ms | 4.75ms | yok |

Bu seviyede Nox, ÇIPLAK Zig soket tabanını (VE Go/FastAPI'yi) bile
GEÇİYOR — makul eşzamanlılıkta `nox.http.serve_multicore`nin GERÇEK
ek yükü ÖLÇÜLEMEYECEK kadar KÜÇÜK.

### Yüksek eşzamanlılık (`wrk -t8 -c100 -d15s`) — keep-alive farkı DOMİNANT hale gelir

| Sunucu | İstek/sn | p50 gecikme | p99 gecikme | Soket hatası (connect/read/write) |
|---|---|---|---|---|
| Nox (`serve_multicore`, N=10) | 2,687 | 1.16ms | 2.49ms | **96 / 69488 / 47928** |
| Zig (çıplak `std.c` soket, N=10 iş parçacığı) | 4,757 | 0.95ms | 2.30ms | 96 / 0 / 0 |
| Go (`net/http`, varsayılan keep-alive) | **197,178** | 0.28ms | 3.52ms | yok |
| FastAPI (`uvicorn --workers 10`, varsayılan keep-alive) | 23,302 | 2.18ms | 32.38ms | yok |

**İKİ AYRI, DÜRÜSTÇE ayrıştırılması GEREKEN bulgu:**
1. **Go/FastAPI'nin BÜYÜK sıçraması** (Nox/Zig'e göre 8x-70x) BÜYÜK
   ÖLÇÜDE keep-alive'ın TCP el sıkışma/bağlantı KURMA maliyetini
   ORTADAN KALDIRMASINDANDIR — `wrk`nin 100 bağlantısı BİNLERCE isteği
   AYNI soket ÜZERİNDEN tekrar KULLANIR; Nox/Zig İSE HER istek İçin
   YENİDEN el sıkışır. Bu, SALT istek-işleme HIZI farkı DEĞİLDİR —
   `nox.http.serve`nin BUGÜN keep-alive DESTEKLEMEMESİNİN GERÇEK,
   ölçülebilir maliyetidir (gelecekteki bir faz İçin AÇIK bir aday).
2. **Nox'un ÇIPLAK Zig tabanına GÖRE de GERİDE kalması VE YÜKSEK soket
   hata SAYISI** (`read 69488`/`write 47928` — BAŞARILI 40388 isteğin
   KENDİSİNDEN bile FAZLA) BAĞIMSIZ, GERÇEK bir bulgudur: 100 eşzamanlı
   bağlantıda `nox.http.serve_multicore`, AYNI "10 iş parçacığı TEK
   dinleme soketini PAYLAŞIR" mimarisine sahip ÇIPLAK Zig tabanından
   BELİRGİN ŞEKİLDE DAHA FAZLA hata VERİYOR VE DAHA YAVAŞ — bu, Orta
   eşzamanlılık testinde GÖRÜLMEYEN, YÜKSEK eşzamanlı bağlantı ÇÖKÜŞÜ
   ALTINDA (fiber zamanlayıcı/`accept()` geri-basınç mantığında olası
   bir darboğaz) ortaya çıkan, KAYDA GEÇMEYE DEĞER bir gelecek-fazı
   ADAYI/bilinen sınırlamadır — bu belgenin KENDİSİ bunu ÇÖZMEYİ
   hedeflemez, yalnızca DÜRÜSTÇE raporlar.

### Özet

- **Orta eşzamanlılıkta** (gerçekçi bir küçük-orta ölçekli servis yükü)
  Nox, Go/Zig/FastAPI İLE **AYNI SINIFTA/rekabetçi**.
- **Yüksek eşzamanlılıkta** Go/FastAPI'nin keep-alive AVANTAJI VE Nox'un
  bağlantı-başına-yeniden-el-sıkışma mimarisi, farkı BÜYÜTÜYOR; AYRICA
  `nox.http.serve_multicore`nin YÜKSEK eşzamanlı bağlantı SAYISI ALTINDA
  ÇIPLAK Zig tabanına göre de GERİLEDİĞİ GÖZLEMLENDİ — bu, keep-alive
  desteğiyle BİRLİKTE gelecekteki bir performans/sağlamlaştırma fazının
  DOĞAL adayıdır.
