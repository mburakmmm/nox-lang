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
const scratch_util = @import("shim_util.zig");
const builtin = @import("builtin");
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
    const out = scratch_util.scratchAllocator().alloc(u8, len) catch return null;
    for (0..len) |i| {
        const slot = base + LIST_HEADER_SIZE + FIELD_SLOT_SIZE * i;
        const v = @as(*align(1) i64, @ptrCast(slot)).*;
        if (v < 0 or v > 255) {
            scratch_util.scratchAllocator().free(out);
            return null;
        }
        out[i] = @intCast(v);
    }
    return out;
}

/// Yığın üstü sıkıştırıcı durumu (`flate.Compress` ~224 KB + 64 KB pencere) fiber yığınından (192 KiB) BÜYÜKTÜR: bir `nox.http`/`nox.grpc_server` işleyicisi (fiber)
/// içinde çağrılınca yığın korumasına çarpıp SIGBUS veriyordu (v2.1.44). Bu yüzden iş, büyük yığınlı geçici bir OS iş parçacığında yürütülür (iş parçacığı
/// olmayan hedeflerde — WASM — doğrudan, oradaki yığın ayrıdır).
const compress_thread_stack: usize = 2 * 1024 * 1024;

const CompressJob = struct {
    allocator: std.mem.Allocator,
    data: []const u8,
    result: ?([]u8) = null,
};

fn compressJobMain(job: *CompressJob) void {
    job.result = gzipCompressInline(job.allocator, job.data) catch null;
}

pub fn gzipCompress(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    if (comptime builtin.single_threaded or builtin.os.tag == .freestanding or builtin.os.tag == .wasi) {
        return gzipCompressInline(allocator, data);
    }
    var job = CompressJob{ .allocator = allocator, .data = data };
    const t = std.Thread.spawn(.{ .stack_size = compress_thread_stack }, compressJobMain, .{&job}) catch return error.OutOfMemory;
    t.join();
    return job.result orelse error.OutOfMemory;
}

fn gzipCompressInline(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
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

pub fn gzipDecompress(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    var in_reader = std.Io.Reader.fixed(data);
    const window_buf = try allocator.alloc(u8, std.compress.flate.max_window_len);
    defer allocator.free(window_buf);
    const decompress = try allocator.create(std.compress.flate.Decompress);
    defer allocator.destroy(decompress);
    decompress.* = std.compress.flate.Decompress.init(&in_reader, .gzip, window_buf);
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
    defer scratch_util.scratchAllocator().free(bytes);
    const compressed = gzipCompress(scratch_util.scratchAllocator(), bytes) catch {
        g_last_op_ok = false;
        return buildIntList(rt, &.{});
    };
    defer scratch_util.scratchAllocator().free(compressed);
    g_last_op_ok = true;
    return buildIntList(rt, compressed);
}

pub export fn nox_gzip_decompress_bytes_raw(rt: ?*anyopaque, list_ptr: ?*anyopaque) ?*anyopaque {
    const bytes = readIntListAsBytes(list_ptr) orelse {
        g_last_op_ok = false;
        return buildIntList(rt, &.{});
    };
    defer scratch_util.scratchAllocator().free(bytes);
    const decompressed = gzipDecompress(scratch_util.scratchAllocator(), bytes) catch {
        g_last_op_ok = false;
        return buildIntList(rt, &.{});
    };
    defer scratch_util.scratchAllocator().free(decompressed);
    g_last_op_ok = true;
    return buildIntList(rt, decompressed);
}

pub export fn nox_gzip_compress_str_raw(rt: ?*anyopaque, s: ?[*:0]const u8) ?*anyopaque {
    const text = std.mem.span(s orelse {
        g_last_op_ok = false;
        return buildIntList(rt, &.{});
    });
    const compressed = gzipCompress(scratch_util.scratchAllocator(), text) catch {
        g_last_op_ok = false;
        return buildIntList(rt, &.{});
    };
    defer scratch_util.scratchAllocator().free(compressed);
    g_last_op_ok = true;
    return buildIntList(rt, compressed);
}

pub export fn nox_gzip_decompress_to_str_raw(rt: ?*anyopaque, list_ptr: ?*anyopaque) ?[*:0]u8 {
    const bytes = readIntListAsBytes(list_ptr) orelse {
        g_last_op_ok = false;
        return str_mod.nox_str_from_bytes(rt, "");
    };
    defer scratch_util.scratchAllocator().free(bytes);
    const decompressed = gzipDecompress(scratch_util.scratchAllocator(), bytes) catch {
        g_last_op_ok = false;
        return str_mod.nox_str_from_bytes(rt, "");
    };
    defer scratch_util.scratchAllocator().free(decompressed);
    if (std.mem.indexOfScalar(u8, decompressed, 0) != null) {
        g_last_op_ok = false;
        return str_mod.nox_str_from_bytes(rt, "");
    }
    g_last_op_ok = true;
    return str_mod.nox_str_from_bytes(rt, decompressed);
}

/// Pulse NOX-CAP-BYTES-001: bayt listesini (`list[int]`, her eleman 0-255) BAYT-TAM bir `str`e çevirir (gömülü NUL ve geçersiz UTF-8 aynen korunur; ikili HTTP
/// gövdesi / protobuf yükü için). 0-255 dışı bir eleman varsa `g_last_op_ok` düşer ve boş dize döner. Ters yön `nox.strings.byte_at` döngüsüdür.
/// Son `nox_bytes_str_from_list_raw` çağrısı başarılı mıydı? (`nox_gzip_last_op_ok` ile aynı iş parçacığı-yerel bayrak; `nox.bytes` ayrı bir adla çağırır, böylece
/// `nox.gzip` ile birlikte içe aktarıldığında extern adları çakışmaz.)
pub export fn nox_bytes_last_ok_raw() callconv(.c) i64 {
    return if (g_last_op_ok) 1 else 0;
}

pub export fn nox_bytes_str_from_list_raw(rt: ?*anyopaque, list_ptr: ?*anyopaque) callconv(.c) ?[*:0]u8 {
    const bytes = readIntListAsBytes(list_ptr) orelse {
        g_last_op_ok = false;
        return str_mod.nox_str_from_bytes(rt, "");
    };
    defer scratch_util.scratchAllocator().free(bytes);
    g_last_op_ok = true;
    return str_mod.nox_str_from_bytes(rt, bytes);
}

const fiber_mod = @import("../async_rt/fiber.zig");

const FiberHarness = struct {
    var ok: bool = false;
    var main_ctx: fiber_mod.Context = .{};

    fn entry(arg: *anyopaque) void {
        _ = arg;
        const data = "gzip on a fiber stack " ** 40;
        const z = gzipCompress(scratch_util.scratchAllocator(), data) catch return;
        defer scratch_util.scratchAllocator().free(z);
        const back = gzipDecompress(scratch_util.scratchAllocator(), z) catch return;
        defer scratch_util.scratchAllocator().free(back);
        ok = std.mem.eql(u8, back, data);
    }
};

// v2.1.44: sıkıştırma GERÇEK bir fiber yığınında (192 KiB, koruma sayfalı) çalışır: iş büyük yığınlı bir iş parçacığına taşınır; öncesinde yığın korumasına çarpıp SIGBUS veriyordu.
// (Önceki sürümdeki 192 KiB'lık `std.Thread` yığını Linux'ta `pthread_create` EINVAL verdiğinden — thread-local alanı sığmıyor — test gerçek fiber ile yazıldı.)
test "gzipCompress/gzipDecompress work from a real fiber stack" {
    if (builtin.single_threaded) return error.SkipZigTest;
    FiberHarness.ok = false;
    const fiber = try fiber_mod.Fiber.create(scratch_util.scratchAllocator(), FiberHarness.entry, undefined);
    defer fiber.destroy();
    fiber.resume_(&FiberHarness.main_ctx);
    try std.testing.expect(fiber.finished);
    try std.testing.expect(FiberHarness.ok);
}
