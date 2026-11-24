//! `nox.zlib` Zig kabuğu (v2.2.63, Prism): zlib (RFC 1950) ve ham deflate (RFC 1951) kapları + `crc32` (IEEE 802.3) ve `adler32` (RFC 1950) sağlama toplamları.
//!
//! Sıkıştırma/açma `gzip.zig`nin kap biçimli yolunu (`compressWith`/`decompressWith`: Zig `std.compress.flate`, gerektiğinde büyük yığınlı iş parçacığı / çıplak çekirdek
//! mini-fiber'ı; WASM/Windows/mobil/çıplak çekirdek dahil TÜM hedefler) kullanır — libdeflate yolu yoktur (yalnızca gzip kabı için eklenmişti). Sağlama toplamları saf Zig'dir
//! (`std.hash`). İkili veri `nox.gzip` ile aynı biçimde `list[int]` (her eleman 0-255) taşınır.
//! Hata sinyali `nox.gzip` ile aynı "last_op_ok" desenidir (iş parçacığı-yerel bayrak).

const std = @import("std");
const scratch_util = @import("shim_util.zig");
const gzip = @import("gzip.zig");

const LastOkSlot = scratch_util.TlsSlot(bool, true);

pub export fn nox_zlib_last_op_ok() i64 {
    return if (LastOkSlot.value) 1 else 0;
}

fn containerOf(kind: i64) ?gzip.Container {
    return switch (kind) {
        0 => .raw,
        1 => .zlib,
        else => null,
    };
}

/// `kind`: 0 = ham deflate (RFC 1951), 1 = zlib (RFC 1950).
pub export fn nox_zlib_compress_raw(rt: ?*anyopaque, list_ptr: ?*anyopaque, kind: i64) ?*anyopaque {
    const container = containerOf(kind) orelse {
        LastOkSlot.value = false;
        return gzip.buildIntList(rt, &.{});
    };
    const bytes = gzip.readIntListAsBytes(list_ptr) orelse {
        LastOkSlot.value = false;
        return gzip.buildIntList(rt, &.{});
    };
    defer scratch_util.scratchAllocator().free(bytes);
    const out = gzip.compressWith(scratch_util.scratchAllocator(), bytes, container) catch {
        LastOkSlot.value = false;
        return gzip.buildIntList(rt, &.{});
    };
    defer scratch_util.scratchAllocator().free(out);
    LastOkSlot.value = true;
    return gzip.buildIntList(rt, out);
}

pub export fn nox_zlib_decompress_raw(rt: ?*anyopaque, list_ptr: ?*anyopaque, kind: i64) ?*anyopaque {
    const container = containerOf(kind) orelse {
        LastOkSlot.value = false;
        return gzip.buildIntList(rt, &.{});
    };
    const bytes = gzip.readIntListAsBytes(list_ptr) orelse {
        LastOkSlot.value = false;
        return gzip.buildIntList(rt, &.{});
    };
    defer scratch_util.scratchAllocator().free(bytes);
    const out = gzip.decompressWith(scratch_util.scratchAllocator(), bytes, container) catch {
        LastOkSlot.value = false;
        return gzip.buildIntList(rt, &.{});
    };
    defer scratch_util.scratchAllocator().free(out);
    LastOkSlot.value = true;
    return gzip.buildIntList(rt, out);
}

/// `prev` önceki (nihai) CRC-32'dir; `0` yeni bir toplam başlatır (zlib `crc32(prev, ...)` ile aynı sözleşme). Geçersiz bayt listesi → `last_op_ok` düşer, `prev` döner.
fn crc32Update(prev: i64, bytes: []const u8) i64 {
    var h = std.hash.Crc32.init();
    h.crc = ~@as(u32, @truncate(@as(u64, @bitCast(prev))));
    h.update(bytes);
    return @intCast(h.final());
}

/// `prev` önceki Adler-32'dir; `1` yeni bir toplam başlatır (zlib `adler32(prev, ...)`).
fn adler32Update(prev: i64, bytes: []const u8) i64 {
    var h = std.hash.Adler32{ .adler = @truncate(@as(u64, @bitCast(prev))) };
    h.update(bytes);
    return @intCast(h.adler);
}

pub export fn nox_zlib_crc32_raw(list_ptr: ?*anyopaque, prev: i64) i64 {
    const bytes = gzip.readIntListAsBytes(list_ptr) orelse {
        LastOkSlot.value = false;
        return prev;
    };
    defer scratch_util.scratchAllocator().free(bytes);
    LastOkSlot.value = true;
    return crc32Update(prev, bytes);
}

pub export fn nox_zlib_adler32_raw(list_ptr: ?*anyopaque, prev: i64) i64 {
    const bytes = gzip.readIntListAsBytes(list_ptr) orelse {
        LastOkSlot.value = false;
        return prev;
    };
    defer scratch_util.scratchAllocator().free(bytes);
    LastOkSlot.value = true;
    return adler32Update(prev, bytes);
}

pub export fn nox_zlib_crc32_str_raw(s: ?[*:0]const u8, prev: i64) i64 {
    const text = std.mem.span(s orelse return prev);
    LastOkSlot.value = true;
    return crc32Update(prev, text);
}

pub export fn nox_zlib_adler32_str_raw(s: ?[*:0]const u8, prev: i64) i64 {
    const text = std.mem.span(s orelse return prev);
    LastOkSlot.value = true;
    return adler32Update(prev, text);
}

test "crc32/adler32: bilinen degerler ve parcali hesaplama" {
    try std.testing.expectEqual(@as(i64, 0xCBF43926), crc32Update(0, "123456789"));
    try std.testing.expectEqual(@as(i64, 0), crc32Update(0, ""));
    const part1 = crc32Update(0, "1234");
    try std.testing.expectEqual(@as(i64, 0xCBF43926), crc32Update(part1, "56789"));
    try std.testing.expectEqual(@as(i64, 0x091E01DE), adler32Update(1, "123456789"));
    try std.testing.expectEqual(@as(i64, 1), adler32Update(1, ""));
    const a1 = adler32Update(1, "12345");
    try std.testing.expectEqual(@as(i64, 0x091E01DE), adler32Update(a1, "6789"));
}

test "zlib ve ham deflate kaplari gidis-donus yapar, zlib basligi dogru, bozuk veri reddedilir" {
    const a = std.testing.allocator;
    const data = "nox.zlib " ** 400;
    for ([_]gzip.Container{ .raw, .zlib }) |c| {
        const z = try gzip.compressWith(a, data, c);
        defer a.free(z);
        try std.testing.expect(z.len < data.len);
        if (c == .zlib) {
            // CMF=0x78 (deflate, 32K pencere); (CMF*256+FLG) % 31 == 0
            try std.testing.expectEqual(@as(u8, 0x78), z[0]);
            try std.testing.expectEqual(@as(u32, 0), (@as(u32, z[0]) * 256 + z[1]) % 31);
            // Adler-32 son 4 bayt (büyük bayt sıralı)
            try std.testing.expectEqual(std.hash.Adler32.hash(data), std.mem.readInt(u32, z[z.len - 4 ..][0..4], .big));
        }
        const back = try gzip.decompressWith(a, z, c);
        defer a.free(back);
        try std.testing.expectEqualSlices(u8, data, back);
        if (gzip.decompressWith(a, z[0 .. z.len / 2], c)) |bad| {
            a.free(bad);
            return error.TestExpectedError;
        } else |_| {}
    }
    const empty = try gzip.compressWith(a, "", .zlib);
    defer a.free(empty);
    const back0 = try gzip.decompressWith(a, empty, .zlib);
    defer a.free(back0);
    try std.testing.expectEqual(@as(usize, 0), back0.len);
}

test "zlib kabi: bozuk baslik, bozuk Adler-32 ve kesik akis her hedefte reddedilir (libdeflate yolu dahil)" {
    const a = std.testing.allocator;
    const data = "zlib container checks " ** 100;
    const z = try gzip.compressWith(a, data, .zlib);
    defer a.free(z);
    for ([_]usize{ 0, 1 }) |i| { // CMF/FLG bozulur
        const bad = try a.dupe(u8, z);
        defer a.free(bad);
        bad[i] ^= 0x55;
        if (gzip.decompressWith(a, bad, .zlib)) |o| {
            a.free(o);
            return error.BadHeaderAccepted;
        } else |_| {}
    }
    const bad_sum = try a.dupe(u8, z);
    defer a.free(bad_sum);
    bad_sum[bad_sum.len - 1] ^= 0xFF;
    if (gzip.decompressWith(a, bad_sum, .zlib)) |o| {
        a.free(o);
        return error.BadChecksumAccepted;
    } else |_| {}
    var cut: usize = 0;
    while (cut < z.len) : (cut += 1) {
        if (gzip.decompressWith(a, z[0..cut], .zlib)) |o| {
            a.free(o);
            return error.TruncatedAccepted;
        } else |_| {}
    }
}
