//! Faz 10 (WASM, ADR-015): iş parçacıklı wasm32'de `std.debug.defaultPanic` derlenmez (Zig 0.16 `Io.Threaded` tip hatası + `WasmAllocator`); bu minimal işleyici
//! iletiyi stderr'e (WASI `fd_write`) yazıp `unreachable` ile durur.

const std = @import("std");
const builtin = @import("builtin");

pub fn handler(msg: []const u8, _: ?usize) noreturn {
    @branchHint(.cold);
    if (comptime builtin.os.tag == .freestanding) {
        const host = struct {
            extern "nox_host" fn write(fd: i32, ptr: [*]const u8, len: usize) i32;
        };
        _ = host.write(2, "panic: ", 7);
        _ = host.write(2, msg.ptr, msg.len);
        _ = host.write(2, "\n", 1);
    } else if (comptime builtin.os.tag == .wasi) {
        const w = std.os.wasi;
        var pre = [_]w.ciovec_t{
            .{ .base = "panic: ", .len = 7 },
            .{ .base = msg.ptr, .len = msg.len },
            .{ .base = "\n", .len = 1 },
        };
        var n: usize = 0;
        _ = w.fd_write(2, &pre, pre.len, &n);
    }
    @trap();
}

pub const panic = std.debug.FullPanic(handler);
