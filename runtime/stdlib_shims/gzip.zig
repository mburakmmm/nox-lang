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

const FIELD_SLOT_SIZE = abi_layout.FIELD_SLOT_SIZE;

const LastOkSlot = scratch_util.TlsSlot(bool, true);

pub fn buildIntList(rt: ?*anyopaque, bytes: []const u8) ?*anyopaque {
    const raw = arc.nox_list_new(rt, bytes.len, FIELD_SLOT_SIZE) orelse return null;
    const base: [*]u8 = @ptrCast(raw);
    @as(*align(1) i64, @ptrCast(base)).* = @intCast(bytes.len);
    @as(*align(1) i64, @ptrCast(base + 8)).* = @intCast(bytes.len);
    for (bytes, 0..) |b, i| {
        const slot = abi_layout.listData(base) + FIELD_SLOT_SIZE * i;
        @as(*align(1) i64, @ptrCast(slot)).* = @intCast(b);
    }
    return @ptrCast(base);
}

/// `list_ptr`teki HER slotu okuyup bir bayt dilimine çevirir — 0-255
/// dışı bir değer VARSA (kullanıcı GEÇERSİZ bir liste verdiyse) `null`
/// döner (çağıran taraf `g_last_op_ok`i düşürür).
pub fn readIntListAsBytes(list_ptr: ?*anyopaque) ?[]u8 {
    const p = list_ptr orelse return null;
    const base: [*]u8 = @ptrCast(p);
    const len: usize = @intCast(@as(*align(1) i64, @ptrCast(base)).*);
    const out = scratch_util.scratchAllocator().alloc(u8, len) catch return null;
    for (0..len) |i| {
        const slot = abi_layout.listData(base) + FIELD_SLOT_SIZE * i;
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

/// v2.2.63: `nox.zlib` (RFC 1950 zlib ve RFC 1951 ham deflate) aynı sıkıştırıcı/açıcı yığın düzenini paylaşır; kap biçimi (`container`) işe taşınır.
pub const Container = std.compress.flate.Container;

const CompressJob = struct {
    allocator: std.mem.Allocator,
    data: []const u8,
    container: Container = .gzip,
    result: ?([]u8) = null,
};

fn compressJobMain(job: *CompressJob) void {
    job.result = compressInline(job.allocator, job.data, job.container) catch null;
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
    container: Container = .gzip,
    result: ?[]u8 = null,
};

fn bareEntry(arg: *anyopaque) void {
    const job: *BareJob = @ptrCast(@alignCast(arg));
    job.result = (if (job.compress) compressInline(job.allocator, job.data, job.container) else decompressInline(job.allocator, job.data, job.container)) catch null;
}

fn bareRun(allocator: std.mem.Allocator, data: []const u8, compress: bool, container: Container) ![]u8 {
    if (BareStack.busy) return error.OutOfMemory;
    BareStack.busy = true;
    defer BareStack.busy = false;
    var job = BareJob{ .allocator = allocator, .data = data, .compress = compress, .container = container };
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
    extern fn libdeflate_deflate_compress_bound(c: *Compressor, in_nbytes: usize) usize;
    extern fn libdeflate_deflate_compress(c: *Compressor, in: [*]const u8, in_nbytes: usize, out: [*]u8, out_nbytes_avail: usize) usize;
    extern fn libdeflate_deflate_decompress_ex(d: *Decompressor, in: [*]const u8, in_nbytes: usize, out: [*]u8, out_nbytes_avail: usize, actual_in_nbytes_ret: ?*usize, actual_out_nbytes_ret: ?*usize) c_int;
    extern fn libdeflate_adler32(adler: u32, buf: ?*const anyopaque, len: usize) u32;
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

const ZLIB_HEADER = [2]u8{ 0x78, 0x9C }; // deflate, 32 KiB pencere, varsayılan düzey (6)

/// gzip dışı kaplar libdeflate'in ham deflate'i üzerine kurulur (zlib kabı: 2 bayt başlık + deflate + Adler-32 BE; `zlib_*.c` vendor edilmedi).
fn ldCompressContainer(allocator: std.mem.Allocator, data: []const u8, container: Container) ![]u8 {
    if (container == .gzip) return ldCompress(allocator, data);
    const c = ld.libdeflate_alloc_compressor(6) orelse return error.OutOfMemory;
    defer ld.libdeflate_free_compressor(c);
    const extra: usize = if (container == .zlib) 6 else 0;
    const bound = ld.libdeflate_deflate_compress_bound(c, data.len);
    const out = try allocator.alloc(u8, bound + extra);
    errdefer allocator.free(out);
    const body = out[if (container == .zlib) 2 else 0..];
    const n = ld.libdeflate_deflate_compress(c, data.ptr, data.len, body.ptr, bound);
    if (n == 0) return error.OutOfMemory;
    if (container == .zlib) {
        out[0] = ZLIB_HEADER[0];
        out[1] = ZLIB_HEADER[1];
        std.mem.writeInt(u32, out[2 + n ..][0..4], ld.libdeflate_adler32(1, data.ptr, data.len), .big);
        return allocator.realloc(out, n + 6) catch out[0 .. n + 6];
    }
    return allocator.realloc(out, n) catch out[0..n];
}

fn ldDecompressContainer(allocator: std.mem.Allocator, data: []const u8, container: Container) ![]u8 {
    if (container == .gzip) return ldDecompress(allocator, data);
    var body: []const u8 = data;
    if (container == .zlib) {
        // RFC 1950: CMF (CM=8, CINFO<=7), FLG ((CMF*256+FLG) % 31 == 0, FDICT=0), deflate, Adler-32 (BE).
        if (data.len < 6) return error.BadZlibData;
        if (data[0] & 0x0F != 8 or (data[0] >> 4) > 7) return error.BadZlibData;
        if ((@as(u32, data[0]) * 256 + data[1]) % 31 != 0 or data[1] & 0x20 != 0) return error.BadZlibData;
        body = data[2..];
    }
    const d = ld.libdeflate_alloc_decompressor() orelse return error.OutOfMemory;
    defer ld.libdeflate_free_decompressor(d);
    var cap: usize = @min(@max(body.len *| 4, 4096), MAX_DECOMPRESSED);
    while (true) {
        const out = try allocator.alloc(u8, cap);
        var actual_in: usize = 0;
        var actual_out: usize = 0;
        const rc = ld.libdeflate_deflate_decompress_ex(d, body.ptr, body.len, out.ptr, out.len, &actual_in, &actual_out);
        if (rc == ld.SUCCESS) {
            if (container == .zlib) {
                const trailer_at = actual_in;
                if (body.len < trailer_at + 4 or std.mem.readInt(u32, body[trailer_at..][0..4], .big) != ld.libdeflate_adler32(1, out.ptr, actual_out)) {
                    allocator.free(out);
                    return error.BadZlibData;
                }
            }
            return allocator.realloc(out, actual_out) catch out[0..actual_out];
        }
        allocator.free(out);
        if (rc != ld.INSUFFICIENT_SPACE) return error.BadDeflateData;
        if (cap >= MAX_DECOMPRESSED) return error.OutOfMemory;
        cap = @min(cap *| 2, MAX_DECOMPRESSED);
    }
}

pub fn gzipCompress(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    if (comptime use_libdeflate) return ldCompress(allocator, data);
    return compressWith(allocator, data, .gzip);
}

/// Kap biçimli (gzip/zlib/ham deflate) sıkıştırma: macOS/Linux'ta libdeflate, diğer hedeflerde `std.compress.flate` (gerektiğinde büyük yığınlı iş parçacığı / çıplak çekirdek mini-fiber'ı üzerinde).
pub fn compressWith(allocator: std.mem.Allocator, data: []const u8, container: Container) ![]u8 {
    if (comptime use_libdeflate) return ldCompressContainer(allocator, data, container);
    if (comptime scratch_util.bare_kernel) return bareRun(allocator, data, true, container);
    if (comptime builtin.single_threaded or builtin.os.tag == .freestanding or builtin.os.tag == .wasi) {
        return compressInline(allocator, data, container);
    }
    var job = CompressJob{ .allocator = allocator, .data = data, .container = container };
    const t = std.Thread.spawn(.{ .stack_size = compress_thread_stack }, compressJobMain, .{&job}) catch return error.OutOfMemory;
    t.join();
    return job.result orelse error.OutOfMemory;
}

fn compressInline(allocator: std.mem.Allocator, data: []const u8, container: Container) ![]u8 {
    // `Compress.init`nin KENDİ ön-koşulu: `assert(output.buffer.len > 8);`
    // — `Writer.Allocating.init` BOŞ (`&.{}`) bir buffer İLE başlar,
    // BU YÜZDEN `initCapacity` (N > 8) KULLANILMALI.
    var out: std.Io.Writer.Allocating = try .initCapacity(allocator, 4096);
    errdefer out.deinit();
    var window_buf: [std.compress.flate.max_window_len]u8 = undefined;
    var compress = try std.compress.flate.Compress.init(&out.writer, &window_buf, container, .default);
    try compress.writer.writeAll(data);
    try compress.finish();
    return out.toOwnedSlice();
}

pub fn gzipDecompress(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    if (comptime use_libdeflate) return ldDecompress(allocator, data);
    return decompressWith(allocator, data, .gzip);
}

/// `compressWith`in tersi. Hata ya da bozuk/kesik girdi her hedefte hata döner (asla çökmez); std yolunda zlib Adler-32 ve gzip CRC-32/uzunluk altbilgisi de doğrulanır.
pub fn decompressWith(allocator: std.mem.Allocator, data: []const u8, container: Container) ![]u8 {
    if (comptime use_libdeflate) return ldDecompressContainer(allocator, data, container);
    if (comptime scratch_util.bare_kernel) return bareRun(allocator, data, false, container);
    return decompressInline(allocator, data, container);
}

/// Zig 0.16 `std.compress.flate.Decompress`, girdi bir sembolün ORTASINDA bittiğinde (kesik akış) `assert(r.seek <= r.end)` ile çöker (ReleaseFast'ta tanımsız davranış). Girdinin sonuna 16 sıfır
/// bayt (en uzun Huffman kodu + ek bitler < 5 bayt) eklenir: kesik akış güvenli biçimde hata olarak biter; altbilgi (CRC/Adler) doğrulaması gerçek baytlardan yapılır.
const INPUT_PAD = 16;

fn decompressInline(allocator: std.mem.Allocator, data: []const u8, container: Container) ![]u8 {
    const padded = try allocator.alloc(u8, data.len + INPUT_PAD);
    defer allocator.free(padded);
    @memcpy(padded[0..data.len], data);
    @memset(padded[data.len..], 0);
    var in_reader = std.Io.Reader.fixed(padded);
    const window_buf = try allocator.alloc(u8, std.compress.flate.max_window_len);
    defer allocator.free(window_buf);
    const decompress = try allocator.create(std.compress.flate.Decompress);
    defer allocator.destroy(decompress);
    decompress.* = std.compress.flate.Decompress.init(&in_reader, container, window_buf);
    var out: std.Io.Writer.Allocating = try .initCapacity(allocator, 4096);
    errdefer out.deinit();
    _ = try decompress.reader.streamRemaining(&out.writer);
    // std altbilgiyi (zlib Adler-32 / gzip CRC-32 + uzunluk) okur ama DOĞRULAMAZ: burada doğrulanır (libdeflate yolu zaten doğrular).
    const written = out.written();
    switch (container) {
        .zlib => if (decompress.container_metadata.zlib.adler != std.hash.Adler32.hash(written)) return error.BadChecksum,
        .gzip => {
            const m = decompress.container_metadata.gzip;
            if (m.crc != std.hash.Crc32.hash(written) or m.count != @as(u32, @truncate(written.len))) return error.BadChecksum;
        },
        .raw => {},
    }
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
        const back = try decompressInline(a, z, .gzip);
        defer a.free(back);
        try std.testing.expectEqualSlices(u8, data, back);
        // std flate -> libdeflate
        const z2 = try compressInline(a, data, .gzip);
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

// v2.2.63: std yolu (Windows/WASM/mobil/çıplak çekirdek) kesik akışta çökmemeli ve altbilgi bozukluğunu yakalamalı.
test "v2.2.63: std flate yolu — kesik girdi her kesme noktasında hata verir, bozuk Adler-32/CRC-32 reddedilir, tam akış gidiş-dönüş yapar" {
    const a = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x2263);
    const rand = prng.random();
    const data = try a.alloc(u8, 5000);
    defer a.free(data);
    for (data, 0..) |*b, i| b.* = if ((i / 61) % 2 == 0) @truncate(i *% 7) else rand.int(u8);
    for ([_]Container{ .raw, .zlib, .gzip }) |c| {
        const z = try compressInline(a, data, c);
        defer a.free(z);
        const back = try decompressInline(a, z, c);
        defer a.free(back);
        try std.testing.expectEqualSlices(u8, data, back);
        var cut: usize = 0;
        while (cut < z.len) : (cut += 1) {
            // Sıfır dolgu, akışın eksik SON baytı zaten sıfırsa (EOB kodunun kuyruğu) onu birebir tamamlayabilir: bu durumda çıktı TAM veri olmalı; asla kısmi/yanlış veri değil.
            if (decompressInline(a, z[0..cut], c)) |o| {
                defer a.free(o);
                try std.testing.expectEqualSlices(u8, data, o);
            } else |_| {}
        }
        if (c != .raw) {
            const bad = try a.dupe(u8, z);
            defer a.free(bad);
            bad[bad.len - 6] ^= 0xFF; // altbilgi: Adler-32 / CRC-32
            if (decompressInline(a, bad, c)) |o| {
                a.free(o);
                return error.CorruptChecksumAccepted;
            } else |_| {}
        }
    }
}
