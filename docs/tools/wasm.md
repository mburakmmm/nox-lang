# WebAssembly (wasm32-wasi)

Nox programları WebAssembly'ye derlenebilir:

```bash
noxc build --target wasm32-wasi hello.nox -o hello.wasm
node --no-warnings tests/golden/wasm_run.mjs hello.wasm   # ya da wasmtime, wasmer, ...
```

Çıktı bir WASI komutudur (`_start`). Derleme yolu LLVM'dir: `.ll` dosyası `zig cc -target wasm32-wasi` ile wasi-libc ve `noxrt-wasm32-wasi.o` çalışma zamanına bağlanır. `zig` PATH'te olmalıdır; `--backend qbe`, `--emit-asm` ve `-g` bu hedefte hatadır. Çalışma zamanı nesnesi `zig build wasm-rt` ile üretilir (sürüm paketlerinde hazır gelir).

## Nelerin çalıştığı

Dilin tamamı: sınıflar, kalıtım (çoklu dahil), jeneratörler, `async`/`await`/`Channel`, istisnalar, `with`, `__del__`, comprehension'lar, f-string, `lowlevel`. Standart kütüphaneden: `nox.strings`, `math`, `mathx`, `os`, `path`, `time`, `random`, `json`, `yaml`, `toml`, `csv`, `unicode`, `bytes`, `buffer`, `base64`, `bits`, `atomic`, `collections`, `url`, `uuid`, `validate`, `template`, `log`, `test`, `io`, **`fs`** (WASI ön-açılan dizinler), **`regex`**, **`gzip`**, **`crypto`** (hash/HMAC/parola özetleri, WASI `random_get`).

## Sınırlar

- **Tek iş parçacığı.** `nox.thread` aynı yığında çalışır; gerçek paralellik yoktur. Varsayılan olarak `spawn`/`await` iç içe çalıştırma benzetimiyle çalışır: bir görev, onu bekleyen görevin yığınında sonuna kadar çalışır; altındaki bir görevin sonucunu bekleyen görev "deadlock" olarak bildirilir. Bu sınır `--asyncify` ile kalkar (aşağıya bakın).
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

## `--asyncify`: gerçek fiber

```bash
noxc build --target wasm32-wasi --asyncify prog.nox -o prog.wasm     # wasm-opt (binaryen) gerekir
noxc run   --target wasm32-freestanding --asyncify prog.nox
```

`--asyncify` göreve bekleyen görevleri gerçekten askıya alır (yığın değiştirme): karşılıklı kanal beklemeleri, `nox.thread`/`sleep` sırası ve `async` kalıpları native zamanlayıcıyla aynı sırada çalışır, deadlock sınırı kalkar. Çıktı modül host'tan ek import istemez; her WASM motorunda çalışır. Maliyet: yaklaşık %30–50 yavaşlık/boyut ve `wasm-opt` bağımlılığı ([ADR-014](../internals/adr/014-wasm-asyncify.md)). Paralel çalışma değildir (tek iş parçacığı).
