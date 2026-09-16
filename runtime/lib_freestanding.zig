//! Faz F.0.7 (bkz. plan dosyası "Kritik düzeltme #3"in çözümü): `noxrt_mod`nin
//! freestanding hedeflerdeki KÖK modülü — `runtime/lib.zig`nin AYNI "her
//! dosyayı isim üzerinden yeniden dışa-aktar + comptime force-ref" deseni,
//! AMA SADECE ARC/scheduler/dict/handle ÇEKİRDEĞİNİ kapsayan, DAHA DAR bir
//! liste. `foreign_bridge.zig`/`stdlib_shims/*`/`pool_bridge.zig`/
//! `thread_bridge.zig`/`thread_channel.zig` (VE `stdlib_shims/io.zig`) BU
//! DOSYAYA HİÇ İMPORT EDİLMEZ — Zig'in tembel analiz modelinde ("hiçbir şey
//! onları başvurmadıkça analiz edilmez", bkz. `lib.zig`nin AYNI notu) bu,
//! bunların freestanding derlemesinden TAMAMEN SESSİZCE dışlandığı anlamına
//! gelir (YENİ bir derleme hatası RİSKİ YOK — sadece hiç analiz edilmiyorlar).
//!
//! **Kapsam kararı (kullanıcının "Scheduler'ı da kapsama al" seçimiyle):**
//! `spawn`/`await`/`Task[T]`/`Channel[T]` (ÇEKİRDEK dil özelliği) freestanding
//! profilinde ÇALIŞIR — AMA `nox.thread.pool_run`/`nox.http.serve_multicore`
//! (GERÇEK OS iş parçacığı havuzu) VE gerçek soket/dosya G/Ç'si F.2'nin
//! capability allowlist'i TARAFINDAN ZATEN reddedilir, bu YÜZDEN onların
//! runtime karşılıkları (`worker_pool.zig`/`pool_bridge.zig`/`thread_bridge.
//! zig`/`thread_channel.zig`/`stdlib_shims/*`) BU KÖKTEN HİÇ erişilemez —
//! `bridge.zig`nin `nox_async_init`indeki `if (comptime !is_freestanding)`
//! guard'ı (bkz. onun belge notu) bunu GARANTİ eder.

pub const asap = @import("alloc/asap.zig");
pub const arc = @import("alloc/arc.zig");
pub const dispatch_registry = @import("alloc/dispatch_registry.zig");
pub const diag_sink = @import("diag_sink");
pub const lowlevel = @import("alloc/lowlevel.zig");
pub const cycle_detector = @import("alloc/cycle_detector.zig");
pub const defer_stack = @import("alloc/defer_stack.zig");
pub const errors = @import("errors/handle.zig");
pub const async_bridge = @import("async_rt/bridge.zig");
pub const task_local = @import("async_rt/task_local.zig");
/// `lib.zig`nin AYNI "bağımsız, sadece test-keşfi İçİn KAYITLI" deseni —
/// `scheduler.zig` ZATEN `chase_lev_deque.zig`yi DOĞRUDAN import ETTİĞİNDEN
/// bu satır davranışı DEĞİŞTİRMEZ, sadece isim-üzerinden ERİŞİLEBİLİR kılar.
pub const chase_lev_deque = @import("async_rt/chase_lev_deque.zig");
pub const str = @import("str.zig");
pub const dict = @import("collections/dict.zig");
pub const list_sort = @import("collections/list_sort.zig");

// `lib.zig`nin AYNI zorunlu force-ref bloğu — bu modüllerin `export fn`
// bildirimlerinin freestanding `noxrt.o`nun nesne çıktısına DAHİL olması
// İçİn (hiçbir şey onları başvurmadıkça analiz edilmez).
comptime {
    _ = asap;
    _ = arc;
    _ = dispatch_registry;
    _ = diag_sink;
    _ = lowlevel;
    _ = cycle_detector;
    _ = defer_stack;
    _ = errors;
    _ = async_bridge;
    _ = task_local;
    _ = chase_lev_deque;
    _ = str;
    _ = dict;
    _ = list_sort;
}
