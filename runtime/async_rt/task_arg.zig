//! Görev girişlerinin (`spawn` ile verilen, derlenmiş Nox sarmalayıcısı) tek işaretçi argümanı: yerelde `*anyopaque`, wasm32'de Nox'un 64-bit sözcüğü (`u64`).
//! (`async_rt` dizininde: `scheduler.zig`nin test modülleri bu dizinin dışından içe aktaramaz.)

const builtin = @import("builtin");

pub const TaskArg = if (builtin.cpu.arch.isWasm()) u64 else *anyopaque;

pub inline fn taskArg(p: *anyopaque) TaskArg {
    if (comptime builtin.cpu.arch.isWasm()) return @as(u64, @intFromPtr(p));
    return p;
}
