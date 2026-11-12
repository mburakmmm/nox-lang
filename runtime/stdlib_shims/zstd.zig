//! `nox.zstd` Zig kabuğu (v2.1.71): Zstandard AÇMA (Zig `std.compress.zstd`; sıkıştırma Zig standart kütüphanesinde yoktur). Girdi/çıktı Nox `str` içinde ham bayttır.
//! Pencere `default_window_len` (8 MiB) ile sınırlıdır: daha büyük pencere isteyen akışlar hata verir. Çıktı en çok `max_output` bayttır (sıkıştırma bombası savunması).
//! Hata durumunda boş `str` döner ve `nox_zstd_last_ok` 0 olur (boş çıktı da geçerli olabilir). Çıplak çekirdekte (freestanding) desteklenmez (8 MiB pencere).

const std = @import("std");
const str_mod = @import("../str.zig");
const scratch_util = @import("shim_util.zig");

const LastOkSlot = scratch_util.TlsSlot(bool, true);
pub const max_output: usize = 1 << 30;

pub export fn nox_zstd_last_ok() callconv(.c) i64 {
    return @intFromBool(LastOkSlot.value);
}

pub fn decompress(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    var in_reader = std.Io.Reader.fixed(data);
    const zstd = std.compress.zstd;
    const window = try allocator.alloc(u8, zstd.default_window_len + zstd.block_size_max);
    defer allocator.free(window);
    const dec = try allocator.create(zstd.Decompress);
    defer allocator.destroy(dec);
    dec.* = zstd.Decompress.init(&in_reader, window, .{});
    var out: std.Io.Writer.Allocating = try .initCapacity(allocator, 4096);
    errdefer out.deinit();
    _ = try dec.reader.streamRemaining(&out.writer);
    if (out.written().len > max_output) return error.OutputTooLarge;
    return out.toOwnedSlice();
}

pub export fn nox_zstd_decompress_raw(rt: ?*anyopaque, data: ?[*:0]const u8) callconv(.c) ?[*:0]u8 {
    if (comptime scratch_util.bare_kernel) {
        LastOkSlot.value = false;
        return @constCast(str_mod.nox_empty_str());
    }
    const bytes = str_mod.nox_str_slice(data orelse return @constCast(str_mod.nox_empty_str()));
    const a = scratch_util.scratchAllocator();
    const out = decompress(a, bytes) catch {
        LastOkSlot.value = false;
        return @constCast(str_mod.nox_empty_str());
    };
    defer a.free(out);
    LastOkSlot.value = true;
    return str_mod.nox_str_from_bytes(rt, out);
}

test "zstd: bilinen çerçeve açılır, bozuk girdi hata verir" {
    const asap = @import("../alloc/asap.zig");
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);
    // "hello hello hello hello" -> zstd (Python compression.zstd, düzey 3)
    const frame = "\x28\xb5\x2f\xfd\x20\x17\x65\x00\x00\x30\x68\x65\x6c\x6c\x6f\x20\x01\x00\x99\x4b\x11";
    const inp = str_mod.nox_str_from_bytes(rt, frame) orelse return error.Failed;
    defer str_mod.nox_str_release(rt, inp);
    const out = nox_zstd_decompress_raw(rt, inp) orelse return error.Failed;
    defer str_mod.nox_str_release(rt, out);
    try std.testing.expectEqual(@as(i64, 1), nox_zstd_last_ok());
    try std.testing.expectEqualStrings("hello hello hello hello", str_mod.nox_str_slice(out));
    const junk = str_mod.nox_str_from_bytes(rt, "not zstd") orelse return error.Failed;
    defer str_mod.nox_str_release(rt, junk);
    _ = nox_zstd_decompress_raw(rt, junk);
    try std.testing.expectEqual(@as(i64, 0), nox_zstd_last_ok());
}
