# Nox

*Türkçe | [English](README.en.md)*

Nox, Python'un sözdizimsel tanıdıklığını sistem programlama dillerinin
performansı ve determinizmiyle birleştiren, tamamen **AOT (Ahead-of-Time)
derlenen** bir dildir. Yorumlayıcı yok, GC duraklaması yok — [QBE](https://c9x.me/compile/)
tabanlı bir derleyici arka ucu ve Zig ile yazılmış hafif bir çalışma zamanı
kullanılır.

> **`v1.0.0` yayımlandı ve etiketlendi** — `docs/uretim-hazirlik-analizi.md`nin
> üretim-hazırlığı yol haritasındaki TÜM fazlar (Q–Z) tamamlandı, bkz.
> [`nox-teknik-spesifikasyon.md` §3.43](nox-teknik-spesifikasyon.md)
> (somut "hazır" tanımı) ve [`VERSIONING.md`](VERSIONING.md) (semver
> politikası + stabilite garantisi). **`main` dalı ŞU AN `v1.1.0`a doğru
> aktif geliştiriliyor** (`noxc --version` bunu doğru raporlar) — henüz
> yayımlanmamış değişiklikler için bkz. [`CHANGELOG.md`](CHANGELOG.md)nin
> `[Yayımlanmamış]` bölümü. Katkı için bkz.
> [Katkıda Bulunma](CONTRIBUTING.md).

```nox
class Counter:
    def __init__(self, start: int) -> None:
        self.value = start

    def increment(self) -> None:
        self.value = self.value + 1

c: Counter = Counter(0)
i: int = 0
while i < 5:
    c.increment()
    i = i + 1
print(c.value)
```

## Neden Nox?

- **Zorunlu statik tip**, Python'a yakın sözdizimi (Mojo'nun kademeli
  tipleme yaklaşımından farklı olarak).
- **QBE üzerinden doğrudan native koda AOT derleme** — LLVM/MLIR bağımlılığı
  yok.
- **Katmanlı, çoğunlukla görünmez bir bellek modeli** ("Sahiplik Piramidi"):
  derleyici mümkün olduğunda sıfır maliyetli ASAP destructor'lar üretir,
  belirsiz durumlarda ARC'ye (referans sayımı) düşer — kullanıcıya hiçbir
  açık ownership sözdizimi hissettirilmez.
- **HPy esinli bir C eklenti modeli** ve gömülü bir WASM çalışma zamanı
  (kütüphane olarak import etmek için).
- **Go tarzı fiber/kooperatif async çalışma zamanı** (`spawn`/`await`,
  `Task`/`Channel`) + gerçek eşzamanlı G/Ç (kqueue tabanlı reaktör).
- **Paylaşımsız (shared-nothing), çok çekirdekli iş parçacığı desteği**
  (`nox.thread`) — her biri KENDİ bağımsız fiber çalışma zamanına sahip
  gerçek OS iş parçacıkları (`ThreadHandle[T]`/`.join()`) ve aralarında
  sürekli, çift-yönlü iletişim (`ThreadChannel[T]`), tek bir OS
  çekirdeğiyle sınırlı KALMADAN gerçek paralellik sağlar.
- Büyüyen bir standart kütüphane (`nox.http`, `nox.json`, `nox.strings`,
  `nox.math`, `nox.os`/`nox.fs`, `nox.time`, `nox.test`) ve Go tarzı
  merkeziyetsiz (GitHub URL'si üzerinden) bir paket sistemi.

Mimari/tasarım kararlarının tam dökümü için
[`nox-teknik-spesifikasyon.md`](nox-teknik-spesifikasyon.md)'ye bakın.

## Kurulum

### Önceden derlenmiş (önerilen)

macOS (Apple Silicon) ve Linux (x86-64/aarch64) için tek satırlık kurulum
— `noxc`/`noxlsp` + çalışma zamanı + `nox.*` stdlib + gömülü `qbe` içerir
(yalnızca bir C derleyicisi — `cc` — sistemde bulunmalıdır, linkleme
için):

```sh
curl -fsSL https://raw.githubusercontent.com/mburakmmm/nox-lang/main/install.sh | sh
```

Belirli bir sürümü kurmak/kurulum kökünü değiştirmek için `NOX_VERSION`/
`NOX_INSTALL_DIR` ortam değişkenlerine bakın (bkz. [`install.sh`](install.sh)).
Doğrulama: `noxc --version`.

### Kaynaktan derleme

Katkıda bulunanlar ya da desteklenmeyen bir platformdaki (ör. Intel Mac)
kullanıcılar için. Gereksinimler: [Zig 0.16](https://ziglang.org/download/)
ve [QBE](https://c9x.me/compile/) (`brew install qbe` / kaynaktan derleme).

```sh
git clone https://github.com/mburakmmm/nox-lang.git
cd nox-lang
zig build            # zig-out/bin/noxc + zig-out/lib/{noxrt.o,nox/stdlib/} kurulur
zig build test        # tüm test paketini çalıştırır (unit + golden + uçtan uca)
```

`noxc`, kendi çalıştırılabilir dosyasının konumuna göre stdlib/runtime
dosyalarını bulur (`<exe_dir>/../lib/...`) — `zig-out/bin/noxc`'yi `PATH`'e
ekleyip proje kökü dışından da çalıştırabilirsiniz. Farklı bir kurulum
düzeni kullanıyorsanız `NOX_RESOURCE_DIR` ortam değişkeniyle bu kökü
override edebilirsiniz (üçüncü-taraf paket önbelleğinin kökü olan
`NOX_HOME`'dan **ayrı** bir ayardır).

## Kullanım

```sh
noxc init myproject         # yeni bir proje iskeleti oluşturur (nox.json + main.nox)
noxc check main.nox         # sadece tip denetimi — codegen/qbe/cc yok, hızlı geri bildirim
noxc build main.nox         # main.nox'u derler, "main" ikilisini üretir
noxc run main.nox -- a b c  # derler + çalıştırır, argv'yi iletir
noxc test                   # CWD altındaki tüm *_test.nox dosyalarını keşfedip çalıştırır
noxc fetch                  # nox.json'daki bağımlılıkları önbelleğe doldurur
noxc update                 # bağımlılıkları en son ref'lerine yeniden çözer, nox.lock'u günceller
```

Bir proje birden fazla üçüncü-taraf bağımlılık gerektiriyorsa proje
kökünde bir `nox.json` tanımlayın:

```json
{
  "name": "myproject",
  "entry": "main.nox",
  "requires": [
    { "alias": "somepkg", "repo": "github.com/someuser/somepkg", "ref": "v1.2.3" }
  ]
}
```

```nox
import somepkg.util
import nox.http

print(somepkg.util.parse("..."))
```

`noxc build`/`run`/`test`, `requires[]`i çözüp `nox.lock`a (VCS'e commit
edilir) kilitler — tekrarlanabilir derlemeler İÇİN ilk çözümlemeden SONRA
tamamen offline çalışır.

## Benchmark'lar

`zig build bench -Doptimize=ReleaseFast` — TAM, ham çıktı İÇİN
[`benchmarks/RESULTS.md`](benchmarks/RESULTS.md)'ye bakın. Üç kategori
(aşağıdaki katlanır bölümlerde özetlenir): **dil temelleri**
(Python/C'ye karşı), **stdlib** (JSON/strings/math/fs/time/dict), ve
**HTTP verimi** (Nox/Go/Zig/FastAPI).

<details>
<summary><strong>Dil temelleri — Python/C'ye karşı (10 senaryo, aynı algoritma)</strong></summary>

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

**Özet:** Python'a karşı her senaryoda **7x–122x daha hızlı**; C'ye karşı
genelde **1x–4x yavaş** (aritmetik/OOP'de C'ye çok yakın, `oop_arc_churn`'de
C'den bile hızlı — liste/dizi gezme gibi bellek-erişim-ağırlıklı
senaryolarda fark daha büyük, 12x-20x). Metodoloji + `C`/Python kaynak
dosyaları İçin [`benchmarks/compare/`](benchmarks/compare/)ye bakın.
</details>

<details>
<summary><strong>Stdlib — JSON/strings/math/fs/time/dict (yalnızca Nox, büyük N — regresyon/stres testi)</strong></summary>

| Benchmark | Süre (min) |
|---|---|
| json_bench | 17.8ms |
| strings_bench | 5.6ms |
| math_bench | 4.0ms |
| os_fs_bench | 2.9ms |
| time_bench | 5.9ms |
| dict_bench | 2.8ms |
| strings_perf_bench (`byte_at` + O(n) `join`, Faz EE.1) | 200.0ms |

`strings_perf_bench`, Faz EE.1'in İKİ optimizasyonunu (alloc-sız `byte_at`
tabanlı karşılaştırma + Zig'de tek-geçiş O(n) `join`) BİRLİKTE ölçer —
optimizasyonlar GEÇİCİ olarak ESKİ davranışa (`s[i]` alloc'lu karşılaştırma
+ saf-Nox O(n²) `join`) geri alınıp yeniden ölçüldüğünde: **6040ms →
200ms, ~30x hızlanma** (çıktı değerleri İKİ durumda da BİREBİR AYNI).
Ayrıca Faz M.8 (provably-safe metod çağrılarında istisna-kontrolü
eleme): **480ms → 270ms, ~%44 hızlanma** (300M metod çağrısı). Tam
metodoloji İçin [`benchmarks/RESULTS.md`](benchmarks/RESULTS.md)'ye
bakın.
</details>

<details>
<summary><strong>HTTP verimi — Nox / Go / Zig / FastAPI (<code>wrk</code> ile)</strong></summary>

Dört sunucu (`benchmarks/http_compare/`), AYNI yanıtı üretir (durum 200,
`x: x` başlığı, `"ok"` gövdesi), 10 iş parçacığı/işlem kullanır, `wrk`
İLE ölçülür (Apple M4, 10 çekirdek — tekrarlanabilirlik İçin
`benchmarks/http_compare/run_compare.sh`'a bakın).

| Sunucu | Orta eşzamanlılık (c=30) | Yüksek eşzamanlılık (c=100) |
|---|---|---|
| Nox (`serve_multicore`, N=10) | **20,562** İstek/sn | 12,859 İstek/sn |
| Zig (çıplak `std.c` soket, N=10 iş parçacığı) | 14,743 İstek/sn | 10,866 İstek/sn |
| Go (`net/http`, varsayılan keep-alive) | 191,244 İstek/sn | **195,110** İstek/sn |
| FastAPI (`uvicorn --workers 10`, varsayılan keep-alive) | 22,142 İstek/sn | 23,994 İstek/sn |

Nox, HER İKİ seviyede de çıplak Zig soket tabanını GEÇİYOR. Go'nun AÇIK
ARA önde olması, keep-alive'ın (Nox/Zig'in `Connection: close`
mimarisinin AKSİNE) TCP el sıkışma maliyetini ORTADAN KALDIRMASINDANDIR
— `nox.http.serve`nin keep-alive desteklememesinin GERÇEK maliyeti,
ham istek-işleme HIZI farkı DEĞİL. Tam metodoloji + bu bölümün İLK
(YANLIŞ — Debug-modu runtime linklenmesi VE hatalı bir `max_connections`
ayarı yüzünden) sürümünün NASIL düzeltildiğinin ayrıntısı İçin
[`benchmarks/RESULTS.md`](benchmarks/RESULTS.md)'nin "Bölüm 3"üne bakın.
</details>

## Güvenlik

`extern def`/`lowlevel`, çıplak native kod yürütme yetkisidir — Nox'un
tip/sahiplik garantilerinin dışında, hiçbir sandbox/doğrulama olmadan
çalışır. Bir `nox.json` bağımlılığı eklemek, o paketin (ve geçişli
bağımlılıklarının) `extern def` ile bildirdiği native koda güvenmek
demektir. `nox.fs`/`nox.os` gibi stdlib modülleri de path/girdi
doğrulaması yapmaz (ör. `nox.fs` path-traversal'a karşı korumasızdır).
Ayrıntılar için [AGENTS.md §9.5](AGENTS.md#95-güven-sınırı-trust-boundary--extern-def--lowlevel).

## Proje Yapısı

| Dizin | İçerik |
|---|---|
| `compiler/` | Lexer → parser → checker → sahiplik analizi → QBE codegen |
| `runtime/` | Zig ile yazılmış çalışma zamanı (ARC, async fiber, HPy/WASM köprüleri, stdlib shim'leri) |
| `stdlib/` | Nox'un KENDİSİYLE yazılmış standart kütüphane (`nox.*`) |
| `tests/` | Unit + golden + uçtan uca (CLI alt süreç) testleri |
| `benchmarks/` | Nox/Python/C/Go/Zig/FastAPI karşılaştırmalı benchmark paketi |
| `docs/` | Üretim-hazırlığı analizi, yol haritası ve İngilizce dil referansı |

## Katkıda Bulunma

Bkz. [CONTRIBUTING.md](CONTRIBUTING.md).

## Sürümleme

`v1.0.0`dan itibaren geçerli olacak semver politikası + dil/ABI
stabilite garantisi İÇİN bkz. [VERSIONING.md](VERSIONING.md).

## Lisans

[MIT](LICENSE).
