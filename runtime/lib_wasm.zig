//! Faz 10 (WASM): `wasm32-wasi` hedefinin çalışma zamanı kökü. `lib.zig`in "her dosyayı yeniden dışa aktar + comptime force-ref" deseni, ama
//! OS iş parçacığı, soket, `dlopen` (sqlite/postgres/mysql/tls), HPy/WASM köprüsü, fiber yığın değiştirme ve M:N havuz İÇERMEYEN dar bir küme.
//! Asenkron (`spawn`/`await`/`Channel`) `async_rt/bridge_wasm.zig`deki aynı-yığında yuvalanmış benzetimle çalışır.

const std = @import("std");
const builtin = @import("builtin");

pub const std_options: std.Options = .{
    .unexpected_error_tracing = false,
};

pub const wasm_entry = @import("wasm_entry.zig");
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
pub const str = @import("str.zig");
pub const format = @import("format.zig");
pub const dict = @import("collections/dict.zig");
pub const list_sort = @import("collections/list_sort.zig");
pub const list_ops = @import("collections/list_ops.zig");
pub const strings_shim = @import("stdlib_shims/strings.zig");
pub const math_shim = @import("stdlib_shims/math.zig");
pub const os_shim = @import("stdlib_shims/os.zig");
pub const path_shim = @import("stdlib_shims/path.zig");
pub const time_shim = @import("stdlib_shims/time.zig");
pub const random_shim = @import("stdlib_shims/random.zig");
pub const json_shim = @import("stdlib_shims/json.zig");
pub const unicode_shim = @import("stdlib_shims/unicode.zig");
pub const atomic_shim = @import("stdlib_shims/atomic.zig");
pub const io_shim = @import("stdlib_shims/io.zig");
pub const gzip_shim = @import("stdlib_shims/gzip.zig");
pub const regex_shim = @import("stdlib_shims/regex.zig");
pub const crypto_shim = @import("stdlib_shims/crypto.zig");
pub const fs_shim = @import("stdlib_shims/fs.zig");

comptime {
    _ = wasm_entry;
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
    _ = str;
    _ = @import("unicode.zig");
    _ = @import("unicode_norm.zig");
    _ = format;
    _ = dict;
    _ = list_sort;
    _ = list_ops;
    _ = strings_shim;
    _ = math_shim;
    _ = os_shim;
    _ = path_shim;
    _ = time_shim;
    _ = random_shim;
    _ = json_shim;
    _ = unicode_shim;
    _ = atomic_shim;
    _ = io_shim;
    _ = gzip_shim;
    _ = regex_shim;
    _ = crypto_shim;
    _ = fs_shim;
}
