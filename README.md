# Nox

Nox, Python'un sözdizimsel tanıdıklığını sistem programlama dillerinin
performansı ve determinizmiyle birleştiren, tamamen **AOT (Ahead-of-Time)
derlenen** bir dildir. Yorumlayıcı yok, GC duraklaması yok — [QBE](https://c9x.me/compile/)
tabanlı bir derleyici arka ucu ve Zig ile yazılmış hafif bir çalışma zamanı
kullanılır.

> **Sürüm: v1.0.0.** `docs/uretim-hazirlik-analizi.md`nin üretim-hazırlığı
> yol haritasındaki TÜM fazlar (Q–Z) tamamlandı — bkz.
> [`nox-teknik-spesifikasyon.md` §3.43](nox-teknik-spesifikasyon.md)
> (somut "hazır" tanımı) ve [`VERSIONING.md`](VERSIONING.md) (semver
> politikası + stabilite garantisi). Katkı için bkz.
> [Katkıda Bulunma](CONTRIBUTING.md).

```nox
class Counter:
    def __init__(self: Counter, start: int) -> None:
        self.value = start

    def increment(self: Counter) -> None:
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
- **Gerçek M:N (çok çekirdekli) iş parçacığı desteği** (`nox.thread`) —
  paylaşımsız (shared-nothing) bağımsız OS iş parçacıkları
  (`ThreadHandle[T]`/`.join()`) ve aralarında sürekli, çift-yönlü
  iletişim (`ThreadChannel[T]`), tek bir OS çekirdeğiyle sınırlı
  KALMADAN gerçek paralellik sağlar.
- Büyüyen bir standart kütüphane (`nox.http`, `nox.json`, `nox.strings`,
  `nox.math`, `nox.os`/`nox.fs`, `nox.time`, `nox.test`) ve Go tarzı
  merkeziyetsiz (GitHub URL'si üzerinden) bir paket sistemi.

Mimari/tasarım kararlarının tam dökümü için
[`nox-teknik-spesifikasyon.md`](nox-teknik-spesifikasyon.md)'ye bakın.

## Kurulum

Gereksinimler: [Zig 0.16](https://ziglang.org/download/) ve [QBE](https://c9x.me/compile/)
(`brew install qbe` / kaynaktan derleme).

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
noxc build main.nox         # main.nox'u derler, "main" ikilisini üretir
noxc run main.nox -- a b c  # derler + çalıştırır, argv'yi iletir
noxc test                   # CWD altındaki tüm *_test.nox dosyalarını keşfedip çalıştırır
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

`zig build bench -Doptimize=ReleaseFast` — güncel sonuçlar İÇİN
[`benchmarks/RESULTS.md`](benchmarks/RESULTS.md)'ye bakın (Python'a karşı
7x-122x hızlı; C'ye karşı genelde 1x-4x yavaş, bazı senaryolarda C İLE
BAŞA BAŞ ya da daha hızlı).

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
| `benchmarks/` | Nox/Python/C karşılaştırmalı benchmark paketi |
| `docs/` | Üretim-hazırlığı analizi ve yol haritası |

## Katkıda Bulunma

Bkz. [CONTRIBUTING.md](CONTRIBUTING.md).

## Sürümleme

`v1.0.0`dan itibaren geçerli olacak semver politikası + dil/ABI
stabilite garantisi İÇİN bkz. [VERSIONING.md](VERSIONING.md).

## Lisans

[MIT](LICENSE).
