# Nox

*Türkçe | [English](README.en.md)*

Nox, Python'un sözdizimsel tanıdıklığını sistem programlama dillerinin
performansı ve determinizmiyle birleştiren, tamamen **AOT (Ahead-of-Time)
derlenen** bir dildir. Yorumlayıcı yok, GC duraklaması yok — [QBE](https://c9x.me/compile/)
tabanlı bir derleyici arka ucu ve Zig ile yazılmış hafif bir çalışma zamanı
kullanılır.

> **`v1.1.0` yayımlandı ve etiketlendi** — `docs/uretim-hazirlik-analizi.md`nin
> üretim-hazırlığı yol haritasındaki TÜM fazlar (Q–Z) tamamlandı, bkz.
> [`nox-teknik-spesifikasyon.md` §3.43](nox-teknik-spesifikasyon.md)
> (somut "hazır" tanımı) ve [`VERSIONING.md`](VERSIONING.md) (semver
> politikası + stabilite garantisi). **`main`e giden HER commit ARTIK
> KENDİ sürüm etiketiyle otomatik yayımlanır** (bkz. `VERSIONING.md` §4,
> "her commit bir sürümdür") — `noxc --version` HER ZAMAN çalıştığınız
> ikilinin GERÇEK sürümünü raporlar; tam geçmiş için bkz.
> [`CHANGELOG.md`](CHANGELOG.md). Katkı için bkz.
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
  tipleme yaklaşımından farklı olarak) — `f"..."` biçimlendirilmiş dize
  literalleri, 7 birleşik atama operatörü (`+=`/`-=`/`*=`/`/=`/`//=`/
  `%=`/`**=`), UTF-8 karakter-farkındalıklı `len()`/`s[i]` (ASCII hızlı
  yolu ile), derleme-zamanı monomorfizasyonlu kullanıcı-tanımlı generic
  sınıflar (`class Box[T]:`) ve basit tek-kalıtım (`class Derived(Base):`
  — metod override, `super()`, çalışma-zamanı polimorfik dispatch) DAHİL.
- **QBE üzerinden doğrudan native koda AOT derleme** — LLVM/MLIR bağımlılığı
  yok.
- **Katmanlı, çoğunlukla görünmez bir bellek modeli** ("Sahiplik Piramidi"):
  derleyici mümkün olduğunda sıfır maliyetli ASAP destructor'lar üretir,
  belirsiz durumlarda ARC'ye (referans sayımı) düşer — kullanıcıya hiçbir
  açık ownership sözdizimi hissettirilmez.
- **HPy esinli bir C eklenti modeli** ve gömülü bir WASM çalışma zamanı
  (kütüphane olarak import etmek için). HPy `ctx_*` API yüzeyinin 180/180
  fonksiyonu gerçek bir HPy 0.9.0 C uzantısıyla uçtan uca doğrulanmış
  durumda — üçü (`ctx_CallRealFunctionFromTrampoline`, `ctx_FromPyObject`,
  `ctx_AsPyObject`), Nox'un mimarisinde (yalnızca `HPY_ABI_UNIVERSAL`,
  gerçek bir CPython çağrı yolu yok) yapısal olarak karşılığı OLMADIĞI
  İçin sahte bir uygulama YERİNE bilinçli, dokümante edilmiş bir `@panic`
  ile bırakıldı (bkz. `runtime/hpy_bridge/context.zig`).
- **Go tarzı fiber/kooperatif async çalışma zamanı** (`spawn`/`await`,
  `Task`/`Channel`) + gerçek eşzamanlı G/Ç (kqueue tabanlı reaktör).
- **Paylaşımsız (shared-nothing), çok çekirdekli iş parçacığı desteği**
  (`nox.thread`) — her biri KENDİ bağımsız fiber çalışma zamanına sahip
  gerçek OS iş parçacıkları (`ThreadHandle[T]`/`.join()`) ve aralarında
  sürekli, çift-yönlü iletişim (`ThreadChannel[T]`), tek bir OS
  çekirdeğiyle sınırlı KALMADAN gerçek paralellik sağlar.
- Büyüyen bir standart kütüphane (`nox.http`, `nox.json`, `nox.strings`,
  `nox.math`, `nox.os`/`nox.fs`/`nox.path`, `nox.time`, `nox.random`,
  `nox.crypto` (SHA-256/1/512, HMAC, zaman-sabit karşılaştırma, güvenli
  rastgelelik, VE argon2id/bcrypt/scrypt parola hash'leme — hepsi Zig'in
  KENDİ `std.crypto`si, harici bağımlılık YOK), `nox.regex`, `nox.test`,
  `nox.thread`, `nox.sqlite`/`nox.postgres`/`nox.mysql` — `libsqlite3`/
  `libpq`/`libmysqlclient`e çalışma zamanında tembel bağlanan, statik
  bağımlılık KATMAYAN veritabanı sürücüleri — `nox.uuid` (UUID v4
  üretimi/doğrulaması), `nox.router` — `nox.http.serve`in ham `handle`
  geri çağrısı üzerine saf Nox'ta yazılmış path parametreli yol
  yönlendirme + before/after ara katman katmanı (üst-düzey `def`
  fonksiyonlarının artık BİRİNCİ-SINIF bir değer olarak `list`lerde/sınıf
  alanlarında saklanabilmesi SAYESİNDE mümkün oldu), `nox.validate` —
  bir HTTP istek gövdesi gibi ham JSON metnini basit bir alan-kuralları
  şemasına (isim/tip/zorunlu) karşı doğrulayan bir katman, `nox.template`
  — varsayılan olarak HTML-güvenli (XSS'e karşı otomatik kaçırma) basit
  bir `{{ isim }}` string-değiştirme şablon motoru, `nox.collections` —
  `Stack`/`Queue`/`Deque`/`Set`/`Counter`/`OrderedDict`/`LRUCache`/
  `Heap`/`PriorityQueue` (arite-genel `class Foo[T, ...]:` generic
  sınıfları üzerine), `nox.url` — URL ayrıştırma + percent-encoding +
  sorgu (query string) kodlama/çözme, VE `nox.process` — fiber-uyumlu
  (zamanlayıcıyı KİLİTLEMEYEN) alt-süreç (subprocess) çalıştırma) ve Go
  tarzı merkeziyetsiz (GitHub URL'si ya da doğrudan bir indeks URL'si
  üzerinden, `noxc search`) bir paket sistemi — bir paket kendi `nox.json`
  sinde bir `bin` girdi noktası tanımlıyorsa `noxc install` ile (`pip`/
  `cargo install` tarzı) GLOBAL olarak da kurulup PATH'ten çalıştırılabilir
  bir CLI komutuna dönüşebilir (`noxc uninstall`/`noxc list` ile yönetilir).
- **Decorator sözdizimi** (`@get("/users/:id")` gibi, üst-düzey `def`ler
  üzerinde) — derleyici decorator'ın anlamını yorumlamayan, YALNIZCA
  derleme-zamanı metadata (isim + literal argümanlar + hedef fonksiyon)
  kaydeden, framework-agnostik bir mekanizma. `nox.reflect` bu metadata'yı
  çalışma zamanında sorgulayan API'yi sunar; `router_from_decorators()`
  bunu `nox.router.Router`a çeviren örnek bir tüketicidir (ExpressJS/
  NestJS tarzı yönlendirme). `noxc expand <dosya.nox>` çıkarılan
  metadata'yı şeffaflık için insan-okunur biçimde yazdırır.

Mimari/tasarım kararlarının tam dökümü için
[`nox-teknik-spesifikasyon.md`](nox-teknik-spesifikasyon.md)'ye bakın.

## Kurulum

### Önceden derlenmiş (önerilen)

macOS (Apple Silicon), Linux (x86-64/aarch64) ve Windows (x86-64) için
tek satırlık kurulum — `noxc`/`noxlsp` + çalışma zamanı + `nox.*` stdlib +
gömülü `qbe` içerir (yalnızca bir C derleyicisi sistemde bulunmalıdır,
linkleme için — macOS/Linux'ta `cc`, Windows'ta MinGW-w64):

```sh
curl -fsSL https://raw.githubusercontent.com/mburakmmm/nox-lang/main/install.sh | sh
```

Windows'ta (PowerShell):

```powershell
irm https://raw.githubusercontent.com/mburakmmm/nox-lang/main/install.ps1 | iex
```

Belirli bir sürümü kurmak/kurulum kökünü değiştirmek için `NOX_VERSION`/
`NOX_INSTALL_DIR` ortam değişkenlerine bakın (bkz. [`install.sh`](install.sh)/
[`install.ps1`](install.ps1)). Doğrulama: `noxc --version`.

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

### Windows

Native Windows (x86-64) desteği VAR — `async` çalışma zamanı (fiber
bağlam değişimi + `WSAPoll` tabanlı G/Ç reaktörü), `nox.thread`/
`nox.channel`/`nox.http` (Winsock soket katmanı) DAHİL tüm çalışma zamanı
Windows'ta ÇALIŞIR (bkz. `nox-teknik-spesifikasyon.md` §3.71, Faz LL).
Yukarıdaki `install.ps1` İLE kurup `noxc`yi normal şekilde kullanın —
tek fark, linkleme İçin bir MinGW-w64 C derleyicisi ([MSYS2](https://www.msys2.org/)
üzerinden `pacman -S mingw-w64-x86_64-gcc` ya da
[w64devkit](https://github.com/skeeto/w64devkit)) gerekir. **Bilinçli v1
sınırlaması:** `nox.path.canonicalize`, Windows'ta sembolik linkleri
ÇÖZMEZ (yalnızca `.`/`..`yi normalize edip mutlak yola çevirir —
Windows'ta sembolik link kullanımı zaten nadir ve yönetici izni
gerektirir).

## Kullanım

```sh
noxc --help                 # tüm alt komutları listeleyen bir yardım ekranı (sistem diline göre TR/EN)
noxc init myproject         # yeni bir proje iskeleti oluşturur (nox.json + main.nox)
noxc check main.nox         # sadece tip denetimi — codegen/qbe/cc yok, hızlı geri bildirim
noxc build main.nox         # main.nox'u derler, "main" ikilisini üretir
noxc run main.nox -- a b c  # derler + çalıştırır, argv'yi iletir
noxc test                   # CWD altındaki tüm *_test.nox dosyalarını keşfedip çalıştırır
noxc fetch                  # nox.json'daki bağımlılıkları önbelleğe doldurur
noxc update                 # bağımlılıkları en son ref'lerine yeniden çözer, nox.lock'u günceller
noxc add nyx                # "nyx" paketini merkezi indeksten çözüp nox.json'a ekler
noxc add nyx --ref v1.2.0   # belirli bir sürüme/ref'e pinler
noxc add nyx github.com/x/y # indeks yerine repo'yu doğrudan belirtir (ör. private paketler)
noxc delete nyx             # bağımlılığı nox.json'dan (ve nox.lock'tan) çıkarır
noxc publish github.com/me/nyx --description "..."  # paket metadatasını merkezi indekse gönderir (admin onayı bekler)
noxc upgrade [--check]      # noxc'nin kendisini (binary+runtime+stdlib) en son sürüme günceller
noxc install nyx            # "nyx"nin bin girdi noktasını derleyip ~/.nox/bin'e GLOBAL kurar (PATH'ten çalıştırılabilir)
noxc install github.com/x/y --ref v1.2.0  # repo/ref doğrudan belirtilerek de kurulabilir
noxc uninstall nyx          # global kurulu komutu kaldırır
noxc list                   # global kurulu tüm komutları listeler
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
[`benchmarks/RESULTS.md`](benchmarks/RESULTS.md)'ye bakın. Dört kategori
(aşağıdaki katlanır bölümlerde özetlenir): **dil temelleri**
(Python/C'ye karşı), **stdlib** (JSON/strings/math/os/fs/time/dict/path,
Nox-içi stres testleri), **stdlib — Rust `std` karşılaştırması** (Faz II),
ve **HTTP verimi** (Nox/Go/Zig/FastAPI).

<details>
<summary><strong>Dil temelleri — Python/C'ye karşı (10 senaryo, aynı algoritma)</strong></summary>

| Benchmark | Nox | Python | C | Nox / Python | Nox / C |
|---|---|---|---|---|---|
| numeric_recursion | 14.4ms | 384.8ms | 13.1ms | **26.7x hızlı** | 1.10x yavaş |
| tight_loop_arithmetic | 13.2ms | 1715.0ms | 4.1ms | **129.7x hızlı** | 3.25x yavaş |
| list_traversal | 59.3ms | 1284.0ms | 3.2ms | **21.7x hızlı** | 18.30x yavaş |
| oop_arc_churn | 36.7ms | 471.9ms | 43.9ms | **12.9x hızlı** | 0.83x (Nox C'den hızlı) |
| generics_protocols | 38.1ms | 1576.9ms | 26.5ms | **41.4x hızlı** | 1.44x yavaş |
| exceptions_control_flow | 22.4ms | 678.6ms | 6.1ms | **30.3x hızlı** | 3.68x yavaş |
| lowlevel_arena | 63.8ms | 1327.9ms | 2.4ms | **20.8x hızlı** | 26.54x yavaş |
| string_passing | 33.7ms | 1208.8ms | 8.2ms | **35.9x hızlı** | 4.12x yavaş |
| deep_equality | 6.2ms | 51.1ms | 3.9ms | **8.2x hızlı** | 1.61x yavaş |
| list_class_field | 4.2ms | 50.5ms | 2.0ms | **12.0x hızlı** | 2.12x yavaş |

**Özet:** Python'a karşı her senaryoda **8x–130x daha hızlı**; C'ye karşı
genelde **1x–5x yavaş** (aritmetik/OOP'de C'ye çok yakın, `oop_arc_churn`'de
C'den bile hızlı — liste/dizi gezme gibi bellek-erişim-ağırlıklı
senaryolarda fark daha büyük, 18x-27x). `generics_protocols`/`string_passing`
Faz GG (serbest-fonksiyon inlining + string performansı) SONRASI belirgin
biçimde hızlandı. Metodoloji + `C`/Python kaynak dosyaları İçin
[`benchmarks/compare/`](benchmarks/compare/)ye bakın.
</details>

<details>
<summary><strong>Stdlib — JSON/strings/math/os/fs/time/dict/path (yalnızca Nox, büyük N — regresyon/stres testi)</strong></summary>

| Benchmark | Süre (min) |
|---|---|
| json_bench | 12.2ms |
| strings_bench | 14.8ms |
| math_bench | 3.6ms |
| os_fs_bench | 2.3ms |
| time_bench | 6.2ms |
| dict_bench | 2.7ms |
| path_bench | 8.7ms |
| strings_perf_bench (`contains`/`index_of` + `join`, Faz EE.1 + Faz II) | 13.6ms |

`strings_perf_bench`, Faz EE.1'in İKİ optimizasyonunu (alloc-sız `byte_at`
tabanlı karşılaştırma + Zig'de tek-geçiş O(n) `join`) BİRLİKTE ölçer —
optimizasyonlar GEÇİCİ olarak ESKİ davranışa (`s[i]` alloc'lu karşılaştırma
+ saf-Nox O(n²) `join`) geri alınıp yeniden ölçüldüğünde: **6040ms →
200ms, ~30x hızlanma** (çıktı değerleri İKİ durumda da BİREBİR AYNI). Faz
II'nin Rust karşılaştırması (aşağıya bkz.) BUNUN ÜZERİNE `contains`/
`index_of`i DAHA da hızlandırdı: 200ms → **13.8ms**. Ayrıca Faz M.8
(provably-safe metod çağrılarında istisna-kontrolü eleme): **480ms →
270ms, ~%44 hızlanma** (300M metod çağrısı). Tam metodoloji İçin
[`benchmarks/RESULTS.md`](benchmarks/RESULTS.md)'ye bakın.
</details>

<details>
<summary><strong>Stdlib — Rust <code>std</code> karşılaştırması (Faz II, aynı algoritma, 7 senaryo)</strong></summary>

| Benchmark | Nox | Rust | yavaşlama (nox/rust) |
|---|---|---|---|
| strings_bench | 16.5ms | 4.2ms | 4.0x |
| math_bench | 3.4ms | 3.5ms | **1.0x (Nox hızlı)** |
| os_fs_bench | 2.6ms | 4.2ms | **0.6x (Nox hızlı)** |
| time_bench | 5.9ms | 7.5ms | **0.8x (Nox hızlı)** |
| dict_bench | 2.9ms | 3.7ms | **0.8x (Nox hızlı)** |
| strings_perf_bench | 13.7ms | 13.3ms | 1.0x |
| path_bench | 9.0ms | 17.6ms | **0.5x (Nox hızlı)** |
| fs_bench | 191.4ms | 147.8ms | 1.3x |

Karşılaştırmada İKİ GERÇEK darboğaz bulunup düzeltildi: `nox.strings.
contains`/`index_of` (SAF Nox O(n×m) taraması → Zig'in SIMD-vektörleştirilmiş
`indexOfScalarPos`i, **16.2x → 1.1x**) ve `nox.path.join` (`std.heap.
page_allocator` üzerinden çift-tahsis → tek `arc.nox_rc_alloc`, **9.9x →
0.5x, Nox artık Rust'tan hızlı**). `str` ABI değişikliği (uzunluk alanı +
ASCII bayrağı, bkz. §3.76) SONRASI `nox.path.join` KISA BİR SÜRE İçin AYNI
`page_allocator` darboğazına GERİ DÖNMÜŞTÜ (~18x yavaşlama) — GERÇEK bir
tekrar-üretimle bulunup TEKRAR düzeltildi (bkz. nox-teknik-spesifikasyon.md
§3.86). Tam metodoloji İçin
[`benchmarks/RESULTS.md`](benchmarks/RESULTS.md) "Bölüm 4"e bakın.
</details>

<details>
<summary><strong>Stdlib — Rust CRATE karşılaştırması: json/random/regex/crypto (Faz II devamı)</strong></summary>

`nox.json`/`nox.random`/`nox.regex`/`nox.crypto` Rust `std`de HİÇ
karşılığı olmadığından (harici crate gerektirir), GERÇEK bir Cargo
projesi (`benchmarks/rust_crates/`) İLE fiili standart crate'lerine
(`serde_json`/`rand`/`regex`/`sha2`) karşı AYRICA ölçüldü:

| Benchmark | Nox | Rust (crate) | yavaşlama (nox/rust) |
|---|---|---|---|
| json_bench (`serde_json`) | 13.0ms | 5.8ms | **2.3x** |
| random_bench (`rand`) | 7.5ms | 9.2ms | 0.8x (Nox hızlı) |
| regex_bench (`regex`) | 6.1ms | 6.8ms | 0.9x (Nox hızlı) |
| crypto_bench (`sha2`) | 3.3ms | 14.4ms | **0.23x (Nox 4x hızlı)** |

`json_bench`nin ~2.7x farkı MİMARİ (HER JSON düğümü İçin bir Zig→Nox
çapraz-dil çağrısı) — düzeltilmedi, ayrı bir yeniden-tasarım gerektirir.
Test kapsamı genişletmesi sırasında `nox.json.encode`de GERÇEK bir
düzeltilen boşluk (`\t`/CR escape eksikliği, round-trip çökmesine yol
açıyordu) VE GERÇEK, CİDDİ bir derleyici hatası (`list[str]` dönen bir
fonksiyonun bir döngü içinde iki kez çağrılması ARC'ı bozuyor, SIGSEGV'e
yol açıyor — ayrı bir görev olarak bildirildi) bulundu. Tam metodoloji +
eksik-fonksiyon tablosu İçin
[`benchmarks/RESULTS.md`](benchmarks/RESULTS.md) "Bölüm 5"e bakın.
</details>

<details>
<summary><strong>HTTP verimi — Nox / Go / Zig / FastAPI (<code>wrk</code> ile)</strong></summary>

Dört sunucu (`benchmarks/http_compare/`), AYNI yanıtı üretir (durum 200,
`x: x` başlığı, `"ok"` gövdesi), 10 iş parçacığı/işlem kullanır, `wrk`
İLE ölçülür (Apple M4, 10 çekirdek — tekrarlanabilirlik İçin
`benchmarks/http_compare/run_compare.sh`'a bakın). Aşağıdaki tablo
2026-07-25'te (`ReleaseFast` runtime doğrulanarak) 3'er koşumun
ORTANCASI olarak YENİDEN ölçüldü — bkz. `benchmarks/RESULTS.md`nin
"Bölüm 3 — 2026-07-25 yeniden-koşumu" bölümü (bu makinede AYNI ANDA
çalışan diğer uygulamalardan gelen paylaşılan yükün TÜM sunucuların
mutlak sayılarını önceki (daha "sessiz") koşumlara göre AŞAĞI çektiği,
ama sunucular ARASI SIRALAMA/ORANIN korunduğu NOT edildi).

| Sunucu | Orta eşzamanlılık (c=30) | Yüksek eşzamanlılık (c=100) |
|---|---|---|
| Nox (`serve_multicore`, N=10) | **108,378** İstek/sn | **117,195** İstek/sn |
| Zig (çıplak `std.c` soket, N=10 iş parçacığı) | 21,479 İstek/sn | 15,930 İstek/sn |
| Go (`net/http`, varsayılan keep-alive) | 103,177 İstek/sn | 82,784 İstek/sn |
| FastAPI (`uvicorn --workers 10`, varsayılan keep-alive) | 8,936 İstek/sn | 9,702 İstek/sn |

Nox, HER İKİ eşzamanlılık seviyesinde de HEM çıplak Zig soket tabanını
HEM Go'nun `net/http`sini HEM FastAPI'yi GEÇİYOR — keep-alive desteği
(Faz HH) SAYESİNDE Nox artık Go'nun mimarisiyle AYNI rejimde (TCP el
sıkışma maliyeti istek başına DEĞİL, bağlantı başına ödeniyor) çalışıyor.
Tam metodoloji + bu bölümün İLK
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
| `benchmarks/` | Nox/Python/C/Rust/Go/Zig/FastAPI karşılaştırmalı benchmark paketi |
| `docs/` | Üretim-hazırlığı analizi, yol haritası ve İngilizce dil referansı |

## Katkıda Bulunma

Bkz. [CONTRIBUTING.md](CONTRIBUTING.md).

## Sürümleme

`v1.0.0`dan itibaren geçerli olacak semver politikası + dil/ABI
stabilite garantisi İÇİN bkz. [VERSIONING.md](VERSIONING.md).

## Lisans

[MIT](LICENSE).
