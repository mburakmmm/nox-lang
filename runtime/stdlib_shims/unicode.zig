//! `nox.unicode` Zig kabuğu (TODO 8.7): Unicode normalizasyonu. Algoritma `../unicode_norm.zig`dedir.

const std = @import("std");
const str_mod = @import("../str.zig");
const norm = @import("../unicode_norm.zig");

/// `form`: 0=NFC, 1=NFD, 2=NFKC, 3=NFKD. Bellek yetersizse girdinin kopyasını döner.
export fn nox_unicode_normalize_raw(rt: ?*anyopaque, s: ?[*:0]const u8, form: i64) callconv(.c) ?[*:0]u8 {
    const slice = str_mod.nox_str_slice(s orelse return null);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.heap.page_allocator);
    const f: norm.Form = switch (form) {
        1 => .nfd,
        2 => .nfkc,
        3 => .nfkd,
        else => .nfc,
    };
    norm.normalize(std.heap.page_allocator, slice, f, &out) catch {
        out.clearRetainingCapacity();
        out.appendSlice(std.heap.page_allocator, slice) catch return null;
    };
    const buf = str_mod.nox_str_alloc_buf(rt, out.items.len) orelse return null;
    @memcpy(buf[0..out.items.len], out.items);
    return @ptrCast(buf);
}

test "nox_unicode_normalize_raw modülü derlenir" {
    _ = norm;
}
