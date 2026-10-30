# WebAssembly (wasm32-wasi)

Nox programları WebAssembly'ye derlenebilir:

```bash
noxc build --target wasm32-wasi hello.nox -o hello.wasm
node --no-warnings tests/golden/wasm_run.mjs hello.wasm   # ya da wasmtime, wasmer, ...
```

Çıktı bir WASI komutudur (`_start`). Derleme yolu LLVM'dir: `.ll` dosyası `zig cc -target wasm32-wasi` ile wasi-libc ve `noxrt-wasm32-wasi.o` çalışma zamanına bağlanır. `zig` PATH'te olmalıdır; `--backend qbe`, `--emit-asm` ve `-g` bu hedefte hatadır. Çalışma zamanı nesnesi `zig build wasm-rt` ile üretilir (sürüm paketlerinde hazır gelir).

## Nelerin çalıştığı

Dilin tamamı: sınıflar, kalıtım (çoklu dahil), jeneratörler, `async`/`await`/`Channel`, istisnalar, `with`, `__del__`, comprehension'lar, f-string, `lowlevel`. Standart kütüphaneden: `nox.strings`, `math`, `mathx`, `os`, `path`, `time`, `random`, `json`, `yaml`, `toml`, `csv`, `unicode`, `bytes`, `buffer`, `base64`, `bits`, `atomic`, `collections`, `url`, `uuid`, `validate`, `template`, `log`, `test`, `io`, **`fs`** (WASI ön-açılan dizinler), **`regex`**, **`gzip`**, **`crypto`** (hash/HMAC/parola özetleri, WASI `random_get`).

## Destek matrisi

| Kip | Bayrak | `spawn`/`await`/`Channel` | Gerçek fiber | Gerçek paralellik (`nox.thread`, M:N) | Bilinen sınır |
|---|---|---|---|---|---|
| Varsayılan | (yok) | iç içe çalıştırma benzetimi | hayır | hayır | altındaki bir görevi bekleyen görev deadlock sayılır |
| Asyncify | `--asyncify` | fiber (M:1) | evet | hayır | Asyncify'ın boyut ve hız maliyeti ([ADR-014](../internals/adr/014-wasm-asyncify.md)) |
| Threads | `--threads` | fiber + iş çalan havuz (M:N) | evet (Asyncify ile) | evet | paylaşımlı bellek gerekir; dosya tanıtıcıları iş parçacığı başınadır ([ADR-015](../internals/adr/015-wasm-threads.md)) |

Her kip `wasm32-wasi` ve `wasm32-freestanding` için vardır. Dil ve standart kütüphane davranışı kipler arasında aynıdır; fark yalnızca eşzamanlılık modelidir. Bu eşdeğerlik `zig build wasm-corpus-test` ile sekiz hedefte de fixture korpusuyla doğrulanır; bilinen farklar (libm'in son basamağı, kipe özgü zamanlama sırası) korpus listelerinde belgelidir.

## Sınırlar

- **Eşzamanlılık kipe bağlıdır** (yukarıdaki tabloya bakın). Varsayılan kipte iş parçacığı yoktur ve `spawn`/`await` iç içe çalıştırma benzetimiyle çalışır: bir görev, onu bekleyen görevin yığınında sonuna kadar çalışır; altındaki bir görevin sonucunu bekleyen görev "deadlock" olarak bildirilir. `--asyncify` gerçek fiber verir (tek iş parçacığı, M:1); `--threads` gerçek paralellik verir (M:N).
- **Ağ ve süreç yok.** `nox.http`, `transfer`, `reflect`, `router`, `tls`, `websocket`, `smtp`, `sqlite`, `postgres`, `mysql`, `process`, `sharedmem`, `native`, `plugin`, `hpy` ve `hpy_*` / `wasm_call` yerleşikleri derleme sırasında şu iletiyle reddedilir: `module 'nox.http' cannot be used on the wasm32-wasi target (it needs sockets)`.
- **Yerel kütüphane yok.** `extern def ... from "lib"` ile bir `.wasm`a native kütüphane bağlanamaz.
- **Dosya sistemi** çalıştırıcının WASI ön-açımlarına bağlıdır (`wasm_run.mjs` `.` ve `/tmp` açar).
- **Matematik** işlevleri (`exp`, `sin`, ...) wasi-libc'den gelir; son basamakta platform libm'den ayrılabilir (ör. `exp(1.0)`).

Ayrıntı ve gerekçe: [ADR-012](../internals/adr/012-wasm-target.md). Bir WASM modülünü Nox'a *içe aktarmak* (`wasm_call`) ayrı bir mekanizmadır: [HPy ve WebAssembly](../internals/hpy-wasm.md).

## `wasm32-freestanding` ve `nox_host`

```bash
noxc build --target wasm32-freestanding prog.nox -o prog.wasm
noxc run   --target wasm32-freestanding prog.nox          # node ile (compiler/wasm_host.mjs)
```

WASI ve libc olmadan, tarayıcıya ya da gömülü bir host'a uygun bir modül üretir. Modül dış dünyayı yalnızca `nox_host` import'larıyla görür: `write`, `read`, `clock_ms`, `random_fill`, `sleep_ms`, `exit` ([ADR-013](../internals/adr/013-wasm-host.md)). Dil ve stdlib `wasm32-wasi` ile aynıdır; farklar: `nox.fs` yok (dosya sistemi yok), ortam değişkenleri boş başlar (`set_var` modüle özel), `arg(0)` `"nox"`.

Tarayıcıda ya da kendi host'unda çalıştırmak için `compiler/wasm_host.mjs` içindeki `createHost` kullanılır:

```js
import { runNox } from './wasm_host.mjs';
const code = await runNox(await (await fetch('prog.wasm')).arrayBuffer(), {
  write: (fd, bytes) => { (fd === 2 ? console.error : console.log)(new TextDecoder().decode(bytes)); return bytes.length; },
  read: () => 0,
  clockMs: (kind) => (kind === 0 ? Date.now() : performance.now()),
  randomFill: (bytes) => crypto.getRandomValues(bytes),
  sleepMs: () => {},
});
```

### Doğrulama araçları

`scripts/wasm_corpus.py` fixture korpusunu paralel ve motor seçilebilir koşar (`--target`, `--engine node|wasmtime`); `scripts/wasm_stress.py` karma yükü (kanal fan-in, döngüsel çöp, terk edilen jeneratörler, `nox.thread`) dört hedefte süre boyunca tekrar koşup native çıktıyla birebir karşılaştırır.

### Maliyet

Ölçümler `benchmarks/wasm/RESULTS.md` içindedir (`benchmarks/wasm_bench.py` ile yeniden üretilir). Özet (Apple M4, Node 26): wasm, native LLVM'e göre CPU-bağımlı kodda 1,4x, bellek-yoğun kodda 3-5x yavaştır; `--asyncify` CPU-bağımlı kodda varsayılan kipe göre +0-4% ekler ama çok sık askıya alan yüklerde (500 bin `spawn`/`await`) 2,6x yavaşlatır; `--threads` dört eşit görevde Asyncify'a göre 2,7x hızlıdır ama tek işçide atomik ARC maliyeti taşır. Modüller 60-125 KB'dır.

### Tarayıcıda

`createHost`/`runNox` tarayıcıda olduğu gibi çalışır; `--asyncify` modülleri de (saf wasm). İş parçacıklı `wasm32-freestanding-threads` modülleri için `runNoxThreads(bytes, io)` kullanılır: ana wasm iş parçacığı bir Worker olarak çalışır (sayfa `Atomics.wait` yapamaz), tüm Worker'ları sayfa oluşturur ve çıktı/çıkış kodu sayfaya iletilir. Sayfa `crossOriginIsolated` olmalıdır (`Cross-Origin-Opener-Policy: same-origin` ve `Cross-Origin-Embedder-Policy: require-corp`). `examples/wasm-browser/` bir örnek sayfa ve bu başlıkları ekleyen küçük bir sunucu içerir:

```bash
noxc build --target wasm32-freestanding-threads prog.nox -o examples/wasm-browser/prog.wasm
node examples/wasm-browser/serve.mjs      # http://127.0.0.1:8123/examples/wasm-browser/index.html?wasm=prog.wasm
```

Chromium'da doğrulandı: varsayılan, `--asyncify` ve `--threads` kipleri (200 iş parçacıklı `thread_spawn_stress` ve paylaşımlı atomik sayaç dahil) native ile aynı çıktıyı verir. Firefox ve Safari denenmedi. `wasm32-wasi` modülleri tarayıcıda bir WASI dolgusu gerektirir (`nox_host` yerine WASI import'ları); `wasm_host.mjs` WASI'yi yalnızca Node'da sağlar.

### Başka motorlar

`wasm32-wasi` ve `wasm32-wasi-asyncify` modülleri `wasmtime` ile de çalışır (`noxc run` zaten onu tercih eder): tüm fixture korpusu `scripts/wasm_corpus.py --target wasm32-wasi --engine wasmtime` ile sıfır farkla geçer. İş parçacıklı modüller wasmtime/wasmer'da çalışmaz (wasi-threads kaldırıldı); onlar için `wasm_host.mjs` ya da `thread_spawn` sözleşmesini uygulayan bir host gerekir.

## `--asyncify`: gerçek fiber

```bash
noxc build --target wasm32-wasi --asyncify prog.nox -o prog.wasm     # wasm-opt (binaryen) gerekir
noxc run   --target wasm32-freestanding --asyncify prog.nox
```

`--asyncify` göreve bekleyen görevleri gerçekten askıya alır (yığın değiştirme): karşılıklı kanal beklemeleri, `nox.thread`/`sleep` sırası ve `async` kalıpları native zamanlayıcıyla aynı sırada çalışır, deadlock sınırı kalkar. Çıktı modül host'tan ek import istemez; her WASM motorunda çalışır. Maliyet: yaklaşık %30–50 yavaşlık/boyut ve `wasm-opt` bağımlılığı ([ADR-014](../internals/adr/014-wasm-asyncify.md)). Paralel çalışma değildir (tek iş parçacığı).

## `--threads`: gerçek paralel M:N

```bash
noxc build --target wasm32-wasi --threads prog.nox -o prog.wasm       # wasm-opt (binaryen) ve node gerekir
NOX_POOL_WORKERS=4 noxc run --target wasm32-wasi --threads prog.nox
```

`--threads`, yerel `--release` çalışma zamanının iş çalan M:N havuzunu WASM'a taşır: `spawn`/`await`, `Channel`, `nox.thread` birden çok iş parçacığında GERÇEKTEN paralel çalışır (paylaşımlı bellek + atomikler). Modül `env.memory` (paylaşımlı) ve `wasi::thread-spawn` içe aktarır; `compiler/wasm_host.mjs` bunları Node Worker'larıyla sağlar (wasmtime 50 `-Sthreads`ı kaldırdığından `noxc run` bu hedefte yalnızca Node kullanır). Başka bir host aynı iki içe aktarımı sağlayarak modülü çalıştırabilir. İşçi sayısı `NOX_POOL_WORKERS` ile ayarlanır. Sınırlar ve gerekçe: [ADR-015](../internals/adr/015-wasm-threads.md); `wasm32-freestanding` için de `--threads` vardır: host `nox_host.thread_spawn(arg) -> tid` sağlar ve her yeni iş parçacığında `nox_host_thread_start(tid, arg)`ı çağırır (paylaşımlı `env.memory` ile).
