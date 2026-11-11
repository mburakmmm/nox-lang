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

const LastOkSlot = scratch_util.TlsSlot(bool, true);

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

// v2.1.57: çıplak çekirdek (freestanding, wasm DEĞİL): iş parçacığı yok ve fiber yığınları (192 KiB) sıkıştırıcı durumuna (~290 KB) yetmez. İş, statik büyük yığınlı bir mini-fiber üzerinde
// çalışır (tek çekirdek/tek iş parçacığı; yeniden giriş desteklenmez: iç içe çağrı `OutOfMemory` döner).
const fiber_mod = @import("../async_rt/fiber.zig");
const BARE_STACK_BYTES = 768 * 1024;
const BareStack = if (scratch_util.bare_kernel) struct {
    var mem: [BARE_STACK_BYTES]u8 align(fiber_mod.STACK_ALIGN) = undefined;
    var busy: bool = false;
} else struct {};

const BareJob = struct {
    allocator: std.mem.Allocator,
    data: []const u8,
    compress: bool,
    result: ?[]u8 = null,
};

fn bareEntry(arg: *anyopaque) void {
    const job: *BareJob = @ptrCast(@alignCast(arg));
    job.result = (if (job.compress) gzipCompressInline(job.allocator, job.data) else gzipDecompressInline(job.allocator, job.data)) catch null;
}

fn bareRun(allocator: std.mem.Allocator, data: []const u8, compress: bool) ![]u8 {
    if (BareStack.busy) return error.OutOfMemory;
    BareStack.busy = true;
    defer BareStack.busy = false;
    var job = BareJob{ .allocator = allocator, .data = data, .compress = compress };
    var ctx: fiber_mod.Context = .{};
    const f = try fiber_mod.Fiber.createWithStack(allocator, bareEntry, &job, &BareStack.mem);
    f.resume_(&ctx);
    _ = f.destroyKeepStack();
    return job.result orelse error.OutOfMemory;
}

// v2.1.63: macOS ve Linux'ta sıkıştırma/açma libdeflate ile (`third_party/libdeflate`, MIT; build.zig `addLibdeflate`). Durum yığında DEĞİL libdeflate'in kendi öbek tahsisindedir, yani fiber
// yığını sorunu (aşağıdaki iş parçacığı/mini-fiber yolları) bu yolda yoktur. Diğer hedefler (Windows, WASM, mobil, çıplak çekirdek) Zig `std.compress.flate` yolunu kullanır.
const use_libdeflate = (builtin.os.tag == .macos or builtin.os.tag == .linux) and !builtin.abi.isAndroid() and !builtin.cpu.arch.isWasm();
const ld = if (use_libdeflate) struct {
    const Compressor = opaque {};
    const Decompressor = opaque {};
    extern fn libdeflate_alloc_compressor(level: c_int) ?*Compressor;
    extern fn libdeflate_free_compressor(c: *Compressor) void;
    extern fn libdeflate_gzip_compress_bound(c: *Compressor, in_nbytes: usize) usize;
    extern fn libdeflate_gzip_compress(c: *Compressor, in: [*]const u8, in_nbytes: usize, out: [*]u8, out_nbytes_avail: usize) usize;
    extern fn libdeflate_alloc_decompressor() ?*Decompressor;
    extern fn libdeflate_free_decompressor(d: *Decompressor) void;
    extern fn libdeflate_gzip_decompress_ex(d: *Decompressor, in: [*]const u8, in_nbytes: usize, out: [*]u8, out_nbytes_avail: usize, actual_in_nbytes_ret: ?*usize, actual_out_nbytes_ret: ?*usize) c_int;
    const SUCCESS: c_int = 0;
    const BAD_DATA: c_int = 1;
    const INSUFFICIENT_SPACE: c_int = 3;
} else struct {};

/// Bellek bombasına karşı üst sınır: açılmış çıktı 2 GiB'i geçerse hata (eski Zig yolunda sınır yoktu).
const MAX_DECOMPRESSED: usize = 2 * 1024 * 1024 * 1024;

fn ldCompress(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    const c = ld.libdeflate_alloc_compressor(6) orelse return error.OutOfMemory; // 6 = eski `.default` ile aynı düzey
    defer ld.libdeflate_free_compressor(c);
    const bound = ld.libdeflate_gzip_compress_bound(c, data.len);
    const out = try allocator.alloc(u8, bound);
    errdefer allocator.free(out);
    const n = ld.libdeflate_gzip_compress(c, data.ptr, data.len, out.ptr, out.len);
    if (n == 0) return error.OutOfMemory;
    return allocator.realloc(out, n) catch out[0..n];
}

fn ldDecompress(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    const d = ld.libdeflate_alloc_decompressor() orelse return error.OutOfMemory;
    defer ld.libdeflate_free_decompressor(d);
    // İlk tahmin: gzip alt bilgisindeki ISIZE (son 4 bayt, mod 2^32), en fazla deflate'in teorik oranı (1032:1) kadar; yetmezse iki katına çıkarılır.
    var guess: usize = 64 * 1024;
    if (data.len >= 18) {
        const isize_hint: usize = std.mem.readInt(u32, data[data.len - 4 ..][0..4], .little);
        guess = @max(@min(isize_hint, data.len * 1032), 64);
    }
    var cap: usize = @min(guess + 1, MAX_DECOMPRESSED);
    while (true) {
        const out = try allocator.alloc(u8, cap);
        var actual_out: usize = 0;
        const rc = ld.libdeflate_gzip_decompress_ex(d, data.ptr, data.len, out.ptr, out.len, null, &actual_out);
        if (rc == ld.SUCCESS) return allocator.realloc(out, actual_out) catch out[0..actual_out];
        allocator.free(out);
        if (rc != ld.INSUFFICIENT_SPACE) return error.BadGzipData;
        if (cap >= MAX_DECOMPRESSED) return error.OutOfMemory;
        cap = @min(cap *| 2, MAX_DECOMPRESSED);
    }
}

pub fn gzipCompress(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    if (comptime use_libdeflate) return ldCompress(allocator, data);
    if (comptime scratch_util.bare_kernel) return bareRun(allocator, data, true);
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
    if (comptime use_libdeflate) return ldDecompress(allocator, data);
    if (comptime scratch_util.bare_kernel) return bareRun(allocator, data, false);
    return gzipDecompressInline(allocator, data);
}

fn gzipDecompressInline(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
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
    return if (LastOkSlot.value) 1 else 0;
}

pub export fn nox_gzip_compress_bytes_raw(rt: ?*anyopaque, list_ptr: ?*anyopaque) ?*anyopaque {
    const bytes = readIntListAsBytes(list_ptr) orelse {
        LastOkSlot.value = false;
        return buildIntList(rt, &.{});
    };
    defer scratch_util.scratchAllocator().free(bytes);
    const compressed = gzipCompress(scratch_util.scratchAllocator(), bytes) catch {
        LastOkSlot.value = false;
        return buildIntList(rt, &.{});
    };
    defer scratch_util.scratchAllocator().free(compressed);
    LastOkSlot.value = true;
    return buildIntList(rt, compressed);
}

pub export fn nox_gzip_decompress_bytes_raw(rt: ?*anyopaque, list_ptr: ?*anyopaque) ?*anyopaque {
    const bytes = readIntListAsBytes(list_ptr) orelse {
        LastOkSlot.value = false;
        return buildIntList(rt, &.{});
    };
    defer scratch_util.scratchAllocator().free(bytes);
    const decompressed = gzipDecompress(scratch_util.scratchAllocator(), bytes) catch {
        LastOkSlot.value = false;
        return buildIntList(rt, &.{});
    };
    defer scratch_util.scratchAllocator().free(decompressed);
    LastOkSlot.value = true;
    return buildIntList(rt, decompressed);
}

pub export fn nox_gzip_compress_str_raw(rt: ?*anyopaque, s: ?[*:0]const u8) ?*anyopaque {
    const text = std.mem.span(s orelse {
        LastOkSlot.value = false;
        return buildIntList(rt, &.{});
    });
    const compressed = gzipCompress(scratch_util.scratchAllocator(), text) catch {
        LastOkSlot.value = false;
        return buildIntList(rt, &.{});
    };
    defer scratch_util.scratchAllocator().free(compressed);
    LastOkSlot.value = true;
    return buildIntList(rt, compressed);
}

pub export fn nox_gzip_decompress_to_str_raw(rt: ?*anyopaque, list_ptr: ?*anyopaque) ?[*:0]u8 {
    const bytes = readIntListAsBytes(list_ptr) orelse {
        LastOkSlot.value = false;
        return str_mod.nox_str_from_bytes(rt, "");
    };
    defer scratch_util.scratchAllocator().free(bytes);
    const decompressed = gzipDecompress(scratch_util.scratchAllocator(), bytes) catch {
        LastOkSlot.value = false;
        return str_mod.nox_str_from_bytes(rt, "");
    };
    defer scratch_util.scratchAllocator().free(decompressed);
    if (std.mem.indexOfScalar(u8, decompressed, 0) != null) {
        LastOkSlot.value = false;
        return str_mod.nox_str_from_bytes(rt, "");
    }
    LastOkSlot.value = true;
    return str_mod.nox_str_from_bytes(rt, decompressed);
}

/// Pulse NOX-CAP-BYTES-001: bayt listesini (`list[int]`, her eleman 0-255) BAYT-TAM bir `str`e çevirir (gömülü NUL ve geçersiz UTF-8 aynen korunur; ikili HTTP
/// gövdesi / protobuf yükü için). 0-255 dışı bir eleman varsa `g_last_op_ok` düşer ve boş dize döner. Ters yön `nox.strings.byte_at` döngüsüdür.
/// Son `nox_bytes_str_from_list_raw` çağrısı başarılı mıydı? (`nox_gzip_last_op_ok` ile aynı iş parçacığı-yerel bayrak; `nox.bytes` ayrı bir adla çağırır, böylece
/// `nox.gzip` ile birlikte içe aktarıldığında extern adları çakışmaz.)
pub export fn nox_bytes_last_ok_raw() callconv(.c) i64 {
    return if (LastOkSlot.value) 1 else 0;
}

pub export fn nox_bytes_str_from_list_raw(rt: ?*anyopaque, list_ptr: ?*anyopaque) callconv(.c) ?[*:0]u8 {
    const bytes = readIntListAsBytes(list_ptr) orelse {
        LastOkSlot.value = false;
        return str_mod.nox_str_from_bytes(rt, "");
    };
    defer scratch_util.scratchAllocator().free(bytes);
    LastOkSlot.value = true;
    return str_mod.nox_str_from_bytes(rt, bytes);
}

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

test "v2.1.63: libdeflate ile sıkıştırılan, Zig std.compress.flate ile açılır ve tersi (çapraz uyumluluk)" {
    if (!use_libdeflate) return error.SkipZigTest;
    const a = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x6A17);
    const rand = prng.random();
    const sizes = [_]usize{ 0, 1, 2, 17, 255, 4096, 65536, 300_000, 2_000_000 };
    for (sizes) |n| {
        const data = try a.alloc(u8, n);
        defer a.free(data);
        // yarı tekrarlı, yarı rastgele
        for (data, 0..) |*b, i| b.* = if ((i / 97) % 2 == 0) @truncate(i *% 31) else rand.int(u8);
        // libdeflate -> std flate
        const z = try ldCompress(a, data);
        defer a.free(z);
        const back = try gzipDecompressInline(a, z);
        defer a.free(back);
        try std.testing.expectEqualSlices(u8, data, back);
        // std flate -> libdeflate
        const z2 = try gzipCompressInline(a, data);
        defer a.free(z2);
        const back2 = try ldDecompress(a, z2);
        defer a.free(back2);
        try std.testing.expectEqualSlices(u8, data, back2);
    }
}

test "v2.1.63: libdeflate açma — bozuk veri hata verir, ISIZE yalanı (büyük/küçük) doğru sonuç ya da hata verir, çıktı sınırı" {
    if (!use_libdeflate) return error.SkipZigTest;
    const a = std.testing.allocator;
    const text = "gzip " ** 50_000;
    const z = try ldCompress(a, text);
    defer a.free(z);
    // bozuk CRC / kesik girdi
    var bad = try a.dupe(u8, z);
    defer a.free(bad);
    bad[bad.len - 6] ^= 0xFF;
    try std.testing.expectError(error.BadGzipData, ldDecompress(a, bad));
    try std.testing.expectError(error.BadGzipData, ldDecompress(a, z[0 .. z.len / 2]));
    try std.testing.expectError(error.BadGzipData, ldDecompress(a, "not gzip at all, not gzip at all"));
    // ISIZE alanını küçük/büyük yalanla değiştir: sonuç yine doğru ya da hata (asla taşma/çökme)
    for ([_]u32{ 0, 1, 10, 0xFFFFFFFF }) |fake| {
        var lie = try a.dupe(u8, z);
        defer a.free(lie);
        std.mem.writeInt(u32, lie[lie.len - 4 ..][0..4], fake, .little);
        if (ldDecompress(a, lie)) |out| {
            defer a.free(out);
            try std.testing.expectEqualStrings(text, out);
        } else |_| {}
    }
}
