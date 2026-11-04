//! Derleyici tanılamalarının (sözdizimi hataları, codegen iletileri) yazıldığı yer. CLI'de stderr; gömülü kullanımda (tarayıcıda WASM'a derlenmiş ön yüz, spec §3.353)
//! çağıranın tamponu. `std.debug.print` wasm32-freestanding'de bulunmaz, bu yüzden tanılama yazan her kod buradan geçer.

const std = @import("std");
const builtin = @import("builtin");

pub const Sink = struct {
    ctx: ?*anyopaque = null,
    write: *const fn (ctx: ?*anyopaque, text: []const u8) void = stderrWrite,

    pub fn print(self: Sink, comptime fmt: []const u8, args: anytype) void {
        var buf: [2048]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, fmt, args) catch buf[0..];
        self.write(self.ctx, text);
    }
};

/// Varsayılan: stderr (freestanding'de çıktı atılır; orada çağıran kendi `Sink`ini verir).
pub const stderr: Sink = .{};

fn stderrWrite(_: ?*anyopaque, text: []const u8) void {
    if (comptime builtin.os.tag == .freestanding) return;
    std.debug.print("{s}", .{text});
}

/// Tanılamayı bir tamponda toplar: çağıran `Collector`ı yaşatır, `sink()` ile bir `Sink` alır.
pub const Collector = struct {
    list: std.ArrayListUnmanaged(u8) = .empty,
    allocator: std.mem.Allocator,

    fn write(ctx: ?*anyopaque, text: []const u8) void {
        const self: *Collector = @ptrCast(@alignCast(ctx.?));
        self.list.appendSlice(self.allocator, text) catch {};
    }

    pub fn sink(self: *Collector) Sink {
        return .{ .ctx = self, .write = write };
    }
};
