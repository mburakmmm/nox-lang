# ADR-014 WASM'da gerçek fiber: Asyncify

Durum: kabul (kullanıcı kararı: "thread kipi olmayanlar için Asyncify"). `--asyncify`, wasm32 hedeflerinde (`wasm32-wasi`, `wasm32-freestanding`) yerel M:1 fiber zamanlayıcısını gerçek yığın değiştirmeyle çalıştırır.

## Sorun

WebAssembly'de yığın değiştirme (fiber) yoktur. ADR-012'nin "iç içe çalıştırma" benzetimi (varsayılan) görevleri çağıranın yığınında sonuna kadar çalıştırır; yığında kendi altındaki bir görevi bekleyen görev (karşılıklı kanal beklemeleri, `nox.thread` sleep sırası) ilerleyemez ve zamanlama native'den ayrışabilir.

## Karar

- `noxc build --target wasm32-wasi --asyncify` (ya da `wasm32-freestanding`): çalışma zamanı varyantı `noxrt-<hedef>-asyncify.o` seçilir ve bağlamadan sonra `wasm-opt --strip-dwarf --asyncify --pass-arg=asyncify-removelist@*nox_asyncify_run_main* --pass-arg=asyncify-ignore-imports -O2` çalışır. İç adlar `<hedef>-asyncify` (`qbe_target.hostedTargetInfo`); `wasm-opt` (Binaryen) PATH'te yoksa derleme açık bir iletiyle durur.
- **Binaryen'in `asyncify.*` import'ları modülün içinde tanımlanır**; çıktı host'tan hiçbir ek import istemez. Her WASM motoru (Node, wasmtime, wasmer, tarayıcı, Nexus Engine) modülü olduğu gibi çalıştırır.
- `runtime/async_rt/asyncify.zig`: `swap(old, new)` çağıran akışı kaydeder (`__stack_pointer`, Asyncify arabelleği, kök) ve yığını açar; en dış sürücü `nox_asyncify_run_main` (Asyncify dönüşümünden muaf) sıradaki akışın kökünü yeni gölge yığında başlatır ya da `start_rewind` ile sarar. Her fiber kendi gölge yığınına (`fiber.zig` `STACK_SIZE`) sahiptir; arabellek (256 KiB) yalnızca askıdayken tutulur ve havuza döner.
- `fiber.zig` wasm32'de `nox_swap_context` yerine `asyncify.swap`, fiber kökü olarak `WasmRoot` kullanır. `scheduler.zig`/`channel.zig`/`bridge_native.zig` değişmeden çalışır (M:1 kipi); iç içe benzetim (`bridge_wasm.zig`) yalnızca `--asyncify`siz varyantta kullanılır (`wasm_options.asyncify`).
- Görev girişlerinin işaretçi argümanı wasm32'de Nox'un 64-bit sözcüğüdür (`abi_ptr.TaskArg`); 64-bit atomikler `atomics` özelliği olmayan wasm'de düz yükle/sakla ile sağlanır (`atomic_compat.zig`).
- Giriş: `__main_argc_argv` (wasi) ve `_start` (freestanding) artık çalışma zamanındadır (`wasm_entry.zig`); IR sarmalayıcısı kaldırıldı.

## Sonuç

Tüm korpus (`wasm-corpus-test`) her dört wasm varyantında native `.expected` ile aynı çıktıyı verir; asyncify varyantlarında yalnızca libm (`mathx_trig_log_constants`, musl `exp`) ayrışır — `thread_spawn_ordering` ve `task_local_basic` artık native ile aynı sıradadır.

## Maliyet

Asyncify, modülün çağrı zincirini bütünüyle dönüştürür; her akış değişimi, akışın çağrı derinliği ile orantılı çözme/sarma yapar. Ölçüm (`benchmarks/wasm/RESULTS.md`, Apple M4, Node 26): CPU-bağımlı kernellerde (`fib`, `loop`, `mandel`, `collatz`) varsayılan wasm'a göre +0-4% süre ve boyut farkı yok (`wasm-opt -O2` modülü küçültür); askıya alma sıklığı yüksek yüklerde maliyet belirgindir: `async_task_churn` (500 bin spawn/await) varsayılan iç içe çalıştırma benzetimine göre 2,6x yavaş. İlk tahmindeki "%30-50" CPU-bağımlı kodda gerçekleşmedi. Yine de varsayılan değildir (`wasm-opt` bağımlılığı, askıya alma maliyeti). Paralellik (birden çok iş parçacığı) için ayrı bir kip gerekir (`--threads`, ADR-015).

**Hata dersi (v2.0.84):** `swap` her askıya almada kendi gölge yığın çerçevesini sızdırıyordu (sürücü yığın işaretçisini `swap`in İÇİNDE okunan değere kuruyor, yeniden girişte önsöz/epilog simetrik çalışıyordu); ReleaseFast'te 32 bayt/askıya alma, 8 MiB gölge yığın 2^18 görev sonra taşıp `memory access out of bounds` veriyordu. Debug çalışma zamanında görünmüyordu. İşaretçi artık çağıranın içinde (satır içi) okunur ve `wasm-rt` Debug derlemede de optimize (ReleaseSafe) üretilir; `async_task_churn_long` fixture'ı (300 bin görev) hem asyncify hem threads hedeflerinde koşar.

## Reddedilen

- Yığın değiştirme önerisi (WasmFX / stack-switching): motor desteği henüz yaygın değil.
- Asyncify'ı varsayılan yapmak: `wasm-opt` bağımlılığı ve çalışma zamanı maliyeti.

Geri alma: `wasm_options.asyncify` ve `*-asyncify` hedef kayıtlarını silmek; `asyncify.zig` yalnızca bu varyantta derlenir.
