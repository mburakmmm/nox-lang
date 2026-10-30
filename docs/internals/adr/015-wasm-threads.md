# ADR-015 WASM'da gerçek paralellik: `--threads`

Durum: kabul (kullanıcı kararı: "wasi-threads tarzı gerçek M:N; host tarafını kendi API'mizle yazalım"). `noxc build --target wasm32-wasi --threads`, yerel M:N çalışma zamanını (iş çalan havuz + fiber'lar) WASM'a taşır.

## Karar

- Hedef adı `wasm32-wasi-threads` (`--threads`, `--asyncify`i içerir): çalışma zamanı `noxrt-wasm32-wasi-threads.o` (`+atomics +bulk_memory`, `-fno-single-threaded`), bağlama `-mcpu=generic+atomics+bulk_memory -Wl,--shared-memory,--import-memory,--max-memory=1 GiB,--export=wasi_thread_start` + `wasm-opt --asyncify`. Yalnızca `wasm32-wasi`: freestanding için iş parçacığı başlatma sözleşmesi (`nox_host.thread_spawn`) henüz yok.
- **Host sözleşmesi** (WASI-threads ABI'si; wasmtime 50 `-Sthreads`ı kaldırdığından host'u Nox sağlar): modül paylaşımlı `env.memory` içe aktarır ve `wasi::thread-spawn(arg) -> tid` ister; host her çağrıda yeni bir iş parçacığında aynı belleğe bağlı yeni bir örnek kurar ve `wasi_thread_start(tid, arg)`ı çağırır. `compiler/wasm_host.mjs` bunu Node Worker'larıyla uygular (gözetmen iş parçacığı + `BroadcastChannel` ile `proc_exit`; ana wasm iş parçacığı da bir Worker'dır, böylece atomik beklemedeki bir iş parçacığı çıkışı engellemez). Başka bir host (Nexus Engine) aynı iki parçayı sağlar.
- **Kendi iş parçacığı uygulamamız** (`async_rt/thread_spawn.zig`): Zig 0.16'nın `WasiThreadImpl`i kullanılmaz. Gölge yığın işaretçisini ayrılan yığın bölgesinin ALT ucuna kurar (yığın aşağı büyüdüğünden yalnızca 64 KiB kullanılabilir, ötesi komşu bloğu ezer) ve `std.Io.Threaded` futex'ine dayanır (Zig tip hatası). Burada blok (TLS + 1 MiB yığın) sıfırlanır (`__wasm_init_tls` yalnızca `.tdata`yı kopyalar), giriş `callconv(.naked)` yazılır — YENİ örneğin `__stack_pointer`ı tüm iş parçacıkları için aynı statik tepedir, sıradan bir Debug önsözü bu ortak bölgede çerçeve açıp `arg`ı eş zamanlı başlayan iş parçacıklarının birbirinin üstüne yazmasına yol açıyordu — ve iş parçacığı kendi Asyncify sürücüsü altında çalışır.
- **64-bit atomikler**: Zig 0.16 wasm32'de `@atomicRmw(u64, ...)`i derlemez; ARC başlığı (64-bit) ve zamanlayıcı sayaçları `async_rt/atomic64.zig` aracılığıyla satır içi `i64.atomic.*` ile erişilir (tek iş parçacıklı wasm'de düz erişim). Üretilen Nox kodunda ARC `atomicrmw` olarak kalır (LLVM `+atomics` ile `i64.atomic.rmw.*` üretir).
- **Ayırıcı**: `wasm_mt_alloc.zig` — `memory.grow` üstünde boyut sınıflı serbest listeler + `memory.atomic.wait32/notify` tabanlı tek kilit (Zig'in `WasmAllocator`ı çok iş parçacıklıda derlenmez); kök dosyadaki `os.heap.page_allocator` geçersiz kılmasıyla tüm çalışma zamanına yönlendirilir. Panic işleyicisi minimal (`wasm_panic.zig`; varsayılan `Io.Threaded`e dayanır).
- Asyncify durumu iş parçacığı başınadır (`threadlocal`); bir fiber work-stealing ile başka bir işçide sarılabilir (arabellek + gölge yığın paylaşımlı bellektedir). `printf` kilit altında tek `fd_write` ile yazar (`wasm_threads_libc.zig`; wasi-libc stdio'su iş parçacığı güvenli değildir). İşçi sayısı `NOX_POOL_WORKERS` (varsayılan: `$main` havuzu için küçük sabit, `serve_multicore`/`pool_run` için 4; wasm'de CPU sayısı sorgulanamaz).
- Tanılama: `NOX_WASM_NAMES=1` işlev adlarını çıktıda tutar (wasm yığın izleri adlı olur).

## Sonuç

Korpus (`wasm-corpus-test`) yerel `--release` M:N denylist'iyle (zamanlayıcıya bağlı 4 fixture + libm farkı) 0 FARK. 4 eşit görevle (4 işçi) tek iş parçacıklı Asyncify'a göre ~2.3× hızlanma ölçüldü.

## Sınırlar

- Tarayıcıda `SharedArrayBuffer` için COOP/COEP başlıkları gerekir; kendi host'unuz `thread-spawn` ve paylaşımlı belleği sağlamalıdır.
- `detach` edilen iş parçacıklarının bellek bloğu geri verilmez (az sayıda sürücü iş parçacığı).
- Dosya tanıtıcıları WASI örneği başınadır (Node'da): bir iş parçacığında açılan dosya diğerinde görünmez.
- `wasm32-freestanding` iş parçacıkları henüz yok.

Geri alma: `wasm32-wasi-threads` kaydını ve `wasm-rt`teki beşinci çalışma zamanı nesnesini silmek.
