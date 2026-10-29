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

- **Tek iş parçacığı.** `nox.thread` aynı yığında çalışır; gerçek paralellik yoktur. `spawn`/`await` iç içe çalıştırma benzetimiyle çalışır: bir görev, onu bekleyen görevin yığınında sonuna kadar çalışır. Altındaki bir görevin sonucunu bekleyen bir görev "deadlock" olarak bildirilir.
- **Ağ ve süreç yok.** `nox.http`, `transfer`, `reflect`, `router`, `tls`, `websocket`, `smtp`, `sqlite`, `postgres`, `mysql`, `process`, `sharedmem`, `native`, `plugin`, `hpy` ve `hpy_*` / `wasm_call` yerleşikleri derleme sırasında şu iletiyle reddedilir: `module 'nox.http' cannot be used on the wasm32-wasi target (it needs sockets)`.
- **Yerel kütüphane yok.** `extern def ... from "lib"` ile bir `.wasm`a native kütüphane bağlanamaz.
- **Dosya sistemi** çalıştırıcının WASI ön-açımlarına bağlıdır (`wasm_run.mjs` `.` ve `/tmp` açar).
- **Matematik** işlevleri (`exp`, `sin`, ...) wasi-libc'den gelir; son basamakta platform libm'den ayrılabilir (ör. `exp(1.0)`).

Ayrıntı ve gerekçe: [ADR-012](../internals/adr/012-wasm-target.md). Bir WASM modülünü Nox'a *içe aktarmak* (`wasm_call`) ayrı bir mekanizmadır: [HPy ve WebAssembly](../internals/hpy-wasm.md).
