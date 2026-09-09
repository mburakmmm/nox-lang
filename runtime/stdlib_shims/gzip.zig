//! `nox.gzip` Zig kabuğu — Zig'in `std.compress.flate`si (streaming
//! Compress/Decompress) ZATEN VAR (bkz. `compiler/pkg/upgrade.zig`nin
//! `.tar.gz` paket indirmede İçSEL kullanımı) — burada Nox'a DIŞA AÇILIYOR.
//!
//! Nox'un `str`i NUL-sonlandırmalı (C-tarzı, bkz. `runtime/str.zig`)
//! OLDUĞUNDAN VE gzip çıktısı KEYFİ ikili veri OLDUĞUNDAN (neredeyse HER
//! ZAMAN gömülü `0x00` bayt İÇerir), sıkıştırılmış veri ASLA doğrudan
//! `str` OLARAK taşınmaz — `list[int]` (HER eleman 0-255 aralığında TEK
//! bir bayt) kullanılır (bkz. `sharedmem.nox`nin AYNI, belgelenmiş
//! kısıtı: "ham ikili veri İçİn read_int/write_int kullanın").
//!
//! Hata sinyali `nox.json`nin AYNI "last_op_ok" deseni — Zig fonksiyonu
//! HER ZAMAN GEÇERLİ (boş/varsayılan) bir değer döner, `nox_gzip_last_op_ok`
//! AYRI olarak kontrol edilir (Nox'un dönüş tipleri HER ZAMAN non-nullable
//! olduğundan).

const std = @import("std");
const arc = @import("../alloc/arc.zig");
const str_mod = @import("../str.zig");
const abi_layout = @import("abi_layout");

const LIST_HEADER_SIZE = abi_layout.LIST_HEADER_SIZE;
const FIELD_SLOT_SIZE = abi_layout.FIELD_SLOT_SIZE;

threadlocal var g_last_op_ok: bool = true;

fn buildIntList(rt: ?*anyopaque, bytes: []const u8) ?*anyopaque {
    const raw = arc.nox_rc_alloc(rt, LIST_HEADER_SIZE + FIELD_SLOT_SIZE * bytes.len) orelse return null;
    const base: [*]u8 = @ptrCast(raw);
    @as(*align(1) i64, @ptrCast(base)).* = @intCast(bytes.len);
    @as(*align(1) i64, @ptrCast(base + 8)).* = @intCast(bytes.len);
    for (bytes, 0..) |b, i| {
        const slot = base + LIST_HEADER_SIZE + FIELD_SLOT_SIZE * i;
        @as(*align(1) i64, @ptrCast(slot)).* = @intCast(b);
    }
    return @ptrCast(base);
}

/// `list_ptr`teki HER slotu okuyup bir bayt dilimine çevirir — 0-255
/// dışı bir değer VARSA (kullanıcı GEÇERSİZ bir liste verdiyse) `null`
/// döner (çağıran taraf `g_last_op_ok`i düşürür).
fn readIntListAsBytes(list_ptr: ?*anyopaque) ?[]u8 {
    const p = list_ptr orelse return null;
    const base: [*]u8 = @ptrCast(p);
    const len: usize = @intCast(@as(*align(1) i64, @ptrCast(base)).*);
    const out = std.heap.page_allocator.alloc(u8, len) catch return null;
    for (0..len) |i| {
        const slot = base + LIST_HEADER_SIZE + FIELD_SLOT_SIZE * i;
        const v = @as(*align(1) i64, @ptrCast(slot)).*;
        if (v < 0 or v > 255) {
            std.heap.page_allocator.free(out);
            return null;
        }
        out[i] = @intCast(v);
    }
    return out;
}

fn gzipCompress(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    // `Compress.init`nin KENDİ ön-koşulu: `assert(output.buffer.len > 8);`
    // — `Writer.Allocating.init` BOŞ (`&.{}`) bir buffer İLE başlar,
    // BU YÜZDEN `initCapacity` (N > 8) KULLANILMALI.
    var out: std.Io.Writer.Allocating = try .initCapacity(allocator, 4096);
    errdefer out.deinit();
    var window_buf: [std.compress.flate.max_window_len]u8 = undefined;
    var compress = try std.compress.flate.Compress.init(&out.writer, &window_buf, .gzip, .default);
    try compress.writer.writeAll(data);
    try compress.finish();
    return out.toOwnedSlice();
}

fn gzipDecompress(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    var in_reader = std.Io.Reader.fixed(data);
    var window_buf: [std.compress.flate.max_window_len]u8 = undefined;
    var decompress = std.compress.flate.Decompress.init(&in_reader, .gzip, &window_buf);
    var out: std.Io.Writer.Allocating = try .initCapacity(allocator, 4096);
    errdefer out.deinit();
    _ = try decompress.reader.streamRemaining(&out.writer);
    return out.toOwnedSlice();
}

pub export fn nox_gzip_last_op_ok() i32 {
    return if (g_last_op_ok) 1 else 0;
}

pub export fn nox_gzip_compress_bytes_raw(rt: ?*anyopaque, list_ptr: ?*anyopaque) ?*anyopaque {
    const bytes = readIntListAsBytes(list_ptr) orelse {
        g_last_op_ok = false;
        return buildIntList(rt, &.{});
    };
    defer std.heap.page_allocator.free(bytes);
    const compressed = gzipCompress(std.heap.page_allocator, bytes) catch {
        g_last_op_ok = false;
        return buildIntList(rt, &.{});
    };
    defer std.heap.page_allocator.free(compressed);
    g_last_op_ok = true;
    return buildIntList(rt, compressed);
}

pub export fn nox_gzip_decompress_bytes_raw(rt: ?*anyopaque, list_ptr: ?*anyopaque) ?*anyopaque {
    const bytes = readIntListAsBytes(list_ptr) orelse {
        g_last_op_ok = false;
        return buildIntList(rt, &.{});
    };
    defer std.heap.page_allocator.free(bytes);
    const decompressed = gzipDecompress(std.heap.page_allocator, bytes) catch {
        g_last_op_ok = false;
        return buildIntList(rt, &.{});
    };
    defer std.heap.page_allocator.free(decompressed);
    g_last_op_ok = true;
    return buildIntList(rt, decompressed);
}

pub export fn nox_gzip_compress_str_raw(rt: ?*anyopaque, s: ?[*:0]const u8) ?*anyopaque {
    const text = std.mem.span(s orelse {
        g_last_op_ok = false;
        return buildIntList(rt, &.{});
    });
    const compressed = gzipCompress(std.heap.page_allocator, text) catch {
        g_last_op_ok = false;
        return buildIntList(rt, &.{});
    };
    defer std.heap.page_allocator.free(compressed);
    g_last_op_ok = true;
    return buildIntList(rt, compressed);
}

pub export fn nox_gzip_decompress_to_str_raw(rt: ?*anyopaque, list_ptr: ?*anyopaque) ?[*:0]u8 {
    const bytes = readIntListAsBytes(list_ptr) orelse {
        g_last_op_ok = false;
        return str_mod.nox_str_from_bytes(rt, "");
    };
    defer std.heap.page_allocator.free(bytes);
    const decompressed = gzipDecompress(std.heap.page_allocator, bytes) catch {
        g_last_op_ok = false;
        return str_mod.nox_str_from_bytes(rt, "");
    };
    defer std.heap.page_allocator.free(decompressed);
    if (std.mem.indexOfScalar(u8, decompressed, 0) != null) {
        g_last_op_ok = false;
        return str_mod.nox_str_from_bytes(rt, "");
    }
    g_last_op_ok = true;
    return str_mod.nox_str_from_bytes(rt, decompressed);
}
