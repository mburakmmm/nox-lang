//! Zamanlayıcı köprüsünün seçici dosyası: yerel hedeflerde fiber tabanlı `bridge_native.zig`, wasm32'de (yığın değiştirme yok) aynı-yığında
//! yuvalanmış benzetim yapan `bridge_wasm.zig`. Çalışma zamanının geri kalanı bu dosyayı `@import("bridge.zig")` ile kullanır; dışa açılan
//! (`export fn`) semboller seçilen uygulamada tanımlıdır ve burada `comptime` ile zorla çözülür.

const builtin = @import("builtin");

/// wasm32: Asyncify kipinde (`wasm_options.asyncify`, ADR-014) yerel fiber zamanlayıcısı gerçek yığın değiştirmeyle çalışır; aksi halde iç içe benzetim.
const impl = if (builtin.cpu.arch.isWasm())
    (if (@import("wasm_options").asyncify) @import("bridge_native.zig") else @import("bridge_wasm.zig"))
else
    @import("bridge_native.zig");

pub const currentFiberScheduler = impl.currentFiberScheduler;
pub const currentFiber = impl.currentFiber;
pub const currentTaskLocals = impl.currentTaskLocals;
pub const spawnPinnedForCurrentThread = impl.spawnPinnedForCurrentThread;
pub const nox_async_init = impl.nox_async_init;
pub const nox_async_deinit = impl.nox_async_deinit;
pub const nox_async_spawn = impl.nox_async_spawn;
pub const nox_async_await = impl.nox_async_await;
pub const nox_task_retain = impl.nox_task_retain;
pub const nox_task_cancel = impl.nox_task_cancel;
pub const nox_task_check_cancelled = impl.nox_task_check_cancelled;
pub const nox_async_destroy_task = impl.nox_async_destroy_task;
pub const nox_async_run_to_completion = impl.nox_async_run_to_completion;
pub const nox_async_deadlock_abort = impl.nox_async_deadlock_abort;

comptime {
    _ = impl;
}
