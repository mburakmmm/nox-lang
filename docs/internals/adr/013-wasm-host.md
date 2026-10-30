# ADR-013 `wasm32-freestanding` ve `nox_host`

Durum: kabul (kullanıcı kararı: Nox'a özel import ad alanı). `--target wasm32-freestanding`, WASI'ye ve libc'ye bağlı olmayan bir WebAssembly modülü üretir; dış dünya yalnızca `nox_host` ad alanındaki import'lardır.

## Karar

- Aynı LLVM yolu (ADR-012): `.ll` → `zig cc -target wasm32-freestanding` + `noxrt-wasm32-freestanding.o` (`runtime/lib_wasm_freestanding.zig`). Giriş `_start` (`runtime/wasm_libc.zig`); `main(1, ["nox"])` çağırır ve çıkış kodunu `nox_host.exit` ile verir. Tek dışa aktarım ayrıca `nox_host_abi_version`dır.
- **Host sözleşmesi** (`runtime/wasm_host.zig`, sürüm 1):

  | import | imza | anlam |
  |---|---|---|
  | `write` | `(fd, ptr, len) -> i32` | 1 stdout, 2 stderr; yazılan bayt ya da `-1` |
  | `read` | `(fd, ptr, len) -> i32` | yalnız fd 0; `0` dosya sonu, `-1` hata |
  | `clock_ms` | `(kind) -> i64` | 0 duvar saati (epoch ms), 1 monoton |
  | `random_fill` | `(ptr, len)` | kriptografik rastgele bayt |
  | `sleep_ms` | `(ms)` | tek iş parçacıklı kipte host anında dönebilir |
  | `exit` | `(code)` | dönmez |

  İş parçacıklı modüller (`wasm32-freestanding-threads`, ADR-015) ek olarak `thread_spawn(arg) -> i32` içe aktarır ve `nox_host_thread_start(tid, arg)` dışa aktarır; paylaşımlı `env.memory` kullanırlar.

Host, `nox_host_abi_version()`ı okuyup desteklemediği bir sürümü reddeder. Sürüm artışı kırıcı değişikliktir (yeni import eklemek değildir: bilinmeyen import host'ta tanımlı değilse modül yüklenmez, bu da açık bir hatadır).
- **Çekirdek ayırıcı**: freestanding çıplak donanım değildir; `std.heap.wasm_allocator` (`memory.grow`) ile `nox_runtime_init_with_allocator` yolu kullanılır (`asap.zig`).
- **libc yerine**: `printf` (yer tutucular `%lld %llu %d %u %s %c %g %f %%`), `strcmp`, ve eksik libm (`atan2`, `tan`) `wasm_libc.zig`dedir; kalan matematik Zig compiler-rt'den gelir. `from "m"` bildirimleri için `-lm` verilmez.
- **Ortam**: işletim sistemi yoktur. `nox.os.getenv`/`set_var` modüle özel, başlangıçta boş bir tabloyla çalışır; `arg(0)` `"nox"`, `current_dir()` `"/"`. Dosya sistemi yoktur: `nox.fs` derleme zamanında reddedilir (ve ağ/süreç modülleri ADR-012'deki gibi).
- **Çalıştırıcı**: `compiler/wasm_host.mjs` tek dosyalık, bağımlılıksız ES modülüdür (Node CLI + tarayıcı için `createHost`/`runNox`). `noxc` bunu gömer; `noxc run --target wasm32-freestanding` onu `node` ile çalıştırır. Nexus Engine gibi başka bir host aynı tabloyu uygular.

## Reddedilen

- WASI preview1'i aynen kullanmak: "freestanding" ayrımı anlamsızlaşır, host izin/limit denetimi WASI'nin kaba izinlerine bağlanır.
- WASI Component Model / wasi-http: araç zinciri büyük, ayrı bir faz.

Geri alma: `qbe_target.hostedTargetInfo`daki kaydı, `build.zig`deki ikinci `addWasmRuntimeChain` çağrısını ve `runtime/wasm_*.zig` dosyalarını silmek.
