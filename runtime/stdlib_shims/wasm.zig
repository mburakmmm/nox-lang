//! `nox.wasm` Zig kabuğu (v2.1.92, TODO 4.3 W2): gömülü WebAssembly yorumlayıcısına (`runtime/wasm_bridge`) kalıcı örnek tutamacı yüzeyi.
//!
//! Tutamaç opaktır (İlke 4: Nox'a ham bellek adresi verilmez; yorumlayıcının doğrusal belleği yalnızca `mem_*` sınır denetimli çağrılarla okunur/yazılır).
//! Hata sözleşmesi: işlevler asla fırlatmaz; son hata tutamaçta saklanır (`nox_wasm_error_raw` -> boş dize = hata yok). `.nox` sarmalayıcısı bunu
//! `WasmError`a çevirir. Açılış başarısız olsa bile tutamaç döner (içinde hata metni) — global durum yoktur.
//!
//! Değerler ham 64-bit yuvalardır: `i32` parametre alt 32 bit; sonuçta `i32` işaret genişletilir, `i64` olduğu gibi, `f32` ham 32 bit deseni, `f64` ham 64 bit deseni.

const std = @import("std");
const arc = @import("../alloc/arc.zig");
const asap = @import("../alloc/asap.zig");
const abi_layout = @import("abi_layout");
const str_mod = @import("../str.zig");
const wasm_bridge = @import("wasm_bridge");

const LIST_HEADER_SIZE = abi_layout.LIST_HEADER_SIZE;
const FIELD_SLOT_SIZE = abi_layout.FIELD_SLOT_SIZE;
const interp = wasm_bridge.interp;
const module_mod = wasm_bridge.module;

const libc = struct {
    extern "c" fn fopen(filename: [*:0]const u8, mode: [*:0]const u8) ?*anyopaque;
    extern "c" fn fclose(stream: *anyopaque) c_int;
    extern "c" fn fread(ptr: [*]u8, size: usize, count: usize, stream: *anyopaque) usize;
    extern "c" fn fseek(stream: *anyopaque, offset: c_long, whence: c_int) c_int;
    extern "c" fn ftell(stream: *anyopaque) c_long;
};

fn readFileAll(allocator: std.mem.Allocator, path: [*:0]const u8) ![]u8 {
    const f = libc.fopen(path, "rb") orelse return error.FileNotFound;
    defer _ = libc.fclose(f);
    if (libc.fseek(f, 0, 2) != 0) return error.SeekFailed;
    const size = libc.ftell(f);
    if (size < 0) return error.TellFailed;
    _ = libc.fseek(f, 0, 0);
    const buf = try allocator.alloc(u8, @intCast(size));
    errdefer allocator.free(buf);
    const n = libc.fread(buf.ptr, 1, buf.len, f);
    if (n != buf.len) return error.ShortRead;
    return buf;
}

const ERR_CAP = 192;

const Handle = struct {
    allocator: std.mem.Allocator,
    /// Modül baytları (ayrıştırıcı bunlara işaret edebilir) — örnek yok olana kadar tutulur.
    bytes: []u8,
    module: module_mod.Module,
    inst: ?*interp.Instance = null,
    module_ok: bool = false,
    err: [ERR_CAP]u8 = undefined,
    err_len: usize = 0,
    /// Son çağrının sonuç sayısı ve sonuçları (çok değerli dönüş).
    nresults: usize = 0,
    results: [16]u64 = undefined,
};

fn setErr(h: *Handle, comptime fmt: []const u8, args: anytype) void {
    const s = std.fmt.bufPrint(&h.err, fmt, args) catch h.err[0..0];
    h.err_len = s.len;
}

fn clearErr(h: *Handle) void {
    h.err_len = 0;
}

fn asHandle(p: ?*anyopaque) ?*Handle {
    const raw = p orelse return null;
    return @ptrCast(@alignCast(raw));
}

fn failedHandle(rt: ?*anyopaque, comptime fmt: []const u8, args: anytype) ?*anyopaque {
    const state: *asap.RuntimeState = @ptrCast(@alignCast(rt orelse return null));
    const a = state.allocator();
    const h = a.create(Handle) catch return null;
    h.* = .{ .allocator = a, .bytes = &.{}, .module = undefined };
    setErr(h, fmt, args);
    return @ptrCast(h);
}

fn trapName(e: anyerror) []const u8 {
    return @errorName(e);
}

fn openBytes(rt: ?*anyopaque, bytes: []u8, fuel: i64, max_pages: i64) ?*anyopaque {
    const state: *asap.RuntimeState = @ptrCast(@alignCast(rt orelse return null));
    const a = state.allocator();
    const h = a.create(Handle) catch return null;
    h.* = .{ .allocator = a, .bytes = bytes, .module = undefined };
    h.module = module_mod.parse(a, h.bytes) catch |e| {
        setErr(h, "invalid wasm module: {s}", .{trapName(e)});
        return @ptrCast(h);
    };
    h.module_ok = true;
    var cfg: interp.Config = .{};
    if (fuel > 0) cfg.fuel = @intCast(fuel);
    if (max_pages > 0) cfg.max_memory_pages = @intCast(@min(max_pages, 65536));
    h.inst = interp.Instance.init(a, &h.module, &.{}, cfg) catch |e| {
        if (e == error.ImportNotFound) {
            setErr(h, "the module imports host functions/memory (not supported by nox.wasm.open yet)", .{});
        } else {
            setErr(h, "could not instantiate the module: {s}", .{trapName(e)});
        }
        return @ptrCast(h);
    };
    return @ptrCast(h);
}

/// `path`teki modülü okuyup örnekler. `fuel`/`max_pages` <= 0 ise varsayılan sınırlar.
pub export fn nox_wasm_open_raw(rt: ?*anyopaque, path: ?[*:0]const u8, fuel: i64, max_pages: i64) callconv(.c) ?*anyopaque {
    const state: *asap.RuntimeState = @ptrCast(@alignCast(rt orelse return null));
    const a = state.allocator();
    const p = str_mod.nox_str_slice(path orelse return failedHandle(rt, "path is null", .{}));
    const pz = a.dupeZ(u8, p) catch return null;
    defer a.free(pz);
    const bytes = readFileAll(a, pz) catch |e| return failedHandle(rt, "cannot read '{s}': {s}", .{ p, trapName(e) });
    return openBytes(rt, bytes, fuel, max_pages);
}

/// Bellekteki bayt listesinden (`list[int]`, her eleman 0..255) modülü örnekler.
pub export fn nox_wasm_open_bytes_raw(rt: ?*anyopaque, data: ?*anyopaque, fuel: i64, max_pages: i64) callconv(.c) ?*anyopaque {
    const state: *asap.RuntimeState = @ptrCast(@alignCast(rt orelse return null));
    const a = state.allocator();
    const lp: [*]const u8 = @ptrCast(data orelse return failedHandle(rt, "no data", .{}));
    const n: usize = @intCast(@as(*align(1) const i64, @ptrCast(lp)).*);
    const buf = a.alloc(u8, n) catch return null;
    for (0..n) |i| {
        const v = @as(*align(1) const i64, @ptrCast(lp + LIST_HEADER_SIZE + FIELD_SLOT_SIZE * i)).*;
        buf[i] = @truncate(@as(u64, @bitCast(v)));
    }
    return openBytes(rt, buf, fuel, max_pages);
}

pub export fn nox_wasm_is_null_raw(hp: ?*anyopaque) callconv(.c) i64 {
    return @intFromBool(hp == null);
}

pub export fn nox_wasm_error_raw(rt: ?*anyopaque, hp: ?*anyopaque) callconv(.c) ?[*:0]u8 {
    const h = asHandle(hp) orelse return str_mod.nox_str_from_bytes(rt, "invalid wasm handle");
    return str_mod.nox_str_from_bytes(rt, h.err[0..h.err_len]);
}

pub export fn nox_wasm_close_raw(hp: ?*anyopaque) callconv(.c) void {
    const h = asHandle(hp) orelse return;
    const a = h.allocator;
    if (h.inst) |i| i.deinit();
    if (h.module_ok) h.module.deinit();
    if (h.bytes.len > 0) a.free(h.bytes);
    a.destroy(h);
}

fn readIntSlots(list: ?*anyopaque, out: []u64) ?usize {
    const lp: [*]const u8 = @ptrCast(list orelse return 0);
    const n: usize = @intCast(@as(*align(1) const i64, @ptrCast(lp)).*);
    if (n > out.len) return null;
    for (0..n) |i| out[i] = @bitCast(@as(*align(1) const i64, @ptrCast(lp + LIST_HEADER_SIZE + FIELD_SLOT_SIZE * i)).*);
    return n;
}

/// Sonuç yuvasını Nox `int` desenine çevirir (i32 işaret genişletilir; diğerleri ham).
fn normalizeResult(ty: module_mod.ValType, v: u64) i64 {
    return switch (ty) {
        .i32 => @as(i64, @as(i32, @bitCast(@as(u32, @truncate(v))))),
        .f32 => @as(i64, @intCast(@as(u32, @truncate(v)))),
        else => @bitCast(v),
    };
}

fn callCommon(h: *Handle, name: []const u8, args: []const u64) bool {
    clearErr(h);
    h.nresults = 0;
    const inst = h.inst orelse {
        if (h.err_len == 0) setErr(h, "module is not instantiated", .{});
        return false;
    };
    const idx = inst.findExport(name, .func) orelse {
        setErr(h, "no exported function named '{s}'", .{name});
        return false;
    };
    const ft = h.module.typeOf(idx);
    if (ft.params.len != args.len) {
        setErr(h, "'{s}' expects {d} argument(s), got {d}", .{ name, ft.params.len, args.len });
        return false;
    }
    if (ft.results.len > h.results.len) {
        setErr(h, "too many results", .{});
        return false;
    }
    var res: [16]u64 = undefined;
    inst.invoke(idx, args, res[0..ft.results.len]) catch |e| {
        setErr(h, "trap: {s}", .{trapName(e)});
        return false;
    };
    h.nresults = ft.results.len;
    for (ft.results, 0..) |ty, i| h.results[i] = @bitCast(normalizeResult(ty, res[i]));
    return true;
}

/// Dışa aktarılan işlevi tamsayı/ham-bit argümanlarıyla çağırır; ilk sonucu (yoksa 0) döner. Hata: `nox_wasm_error_raw`.
pub export fn nox_wasm_call_raw(rt: ?*anyopaque, hp: ?*anyopaque, name: ?[*:0]const u8, args: ?*anyopaque) callconv(.c) i64 {
    _ = rt;
    const h = asHandle(hp) orelse return 0;
    var slots: [16]u64 = undefined;
    const n = readIntSlots(args, &slots) orelse {
        setErr(h, "at most 16 arguments are supported", .{});
        return 0;
    };
    if (!callCommon(h, str_mod.nox_str_slice(name orelse return 0), slots[0..n])) return 0;
    return if (h.nresults > 0) @bitCast(h.results[0]) else 0;
}

/// Kayan noktalı argümanlarla çağırır (argümanlar `f64` ham bit desenleri olarak `list[int]`te taşınır; C ABI `list[float]` geçirmez): `f32`/`f64` parametreler
/// değeri alır, `i32`/`i64` parametreler değeri tamsayıya keser.
pub export fn nox_wasm_call_f_raw(rt: ?*anyopaque, hp: ?*anyopaque, name: ?[*:0]const u8, args: ?*anyopaque) callconv(.c) f64 {
    _ = rt;
    const h = asHandle(hp) orelse return 0;
    const nm = str_mod.nox_str_slice(name orelse return 0);
    const lp: [*]const u8 = @ptrCast(args orelse return 0);
    const n: usize = @intCast(@as(*align(1) const i64, @ptrCast(lp)).*);
    if (n > 16) {
        setErr(h, "at most 16 arguments are supported", .{});
        return 0;
    }
    const inst = h.inst orelse {
        clearErr(h);
        setErr(h, "module is not instantiated", .{});
        return 0;
    };
    const idx = inst.findExport(nm, .func) orelse {
        setErr(h, "no exported function named '{s}'", .{nm});
        return 0;
    };
    const ft = h.module.typeOf(idx);
    var slots: [16]u64 = undefined;
    for (0..@min(n, ft.params.len)) |i| {
        const d: f64 = @bitCast(@as(*align(1) const u64, @ptrCast(lp + LIST_HEADER_SIZE + FIELD_SLOT_SIZE * i)).*); // f64 ham biti
        slots[i] = switch (ft.params[i]) {
            .f64 => @bitCast(d),
            .f32 => @as(u64, @as(u32, @bitCast(@as(f32, @floatCast(d))))),
            .i32 => @as(u64, @as(u32, @bitCast(@as(i32, @intFromFloat(std.math.clamp(d, -2147483648.0, 2147483647.0)))))),
            else => @bitCast(@as(i64, @intFromFloat(std.math.clamp(d, -9.2e18, 9.2e18)))),
        };
    }
    if (!callCommon(h, nm, slots[0..n])) return 0;
    if (h.nresults == 0) return 0;
    const rty = ft.results[0];
    const raw = h.results[0];
    return switch (rty) {
        .f64 => @bitCast(raw),
        .f32 => @floatCast(@as(f32, @bitCast(@as(u32, @truncate(raw))))),
        else => @floatFromInt(@as(i64, @bitCast(raw))),
    };
}

/// Çok değerli dönüşte `i`. sonucun ham deseni (son çağrıdan).
pub export fn nox_wasm_result_raw(hp: ?*anyopaque, i: i64) callconv(.c) i64 {
    const h = asHandle(hp) orelse return 0;
    if (i < 0 or i >= h.nresults) return 0;
    return @bitCast(h.results[@intCast(i)]);
}

pub export fn nox_wasm_result_count_raw(hp: ?*anyopaque) callconv(.c) i64 {
    const h = asHandle(hp) orelse return 0;
    return @intCast(h.nresults);
}

/// Dışa aktarılan işlevlerin adları, ekleme sırasıyla (tek str, '\n' ayraçlı).
pub export fn nox_wasm_exports_raw(rt: ?*anyopaque, hp: ?*anyopaque) callconv(.c) ?[*:0]u8 {
    const h = asHandle(hp) orelse return str_mod.nox_str_from_bytes(rt, "");
    if (!h.module_ok) return str_mod.nox_str_from_bytes(rt, "");
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(h.allocator);
    for (h.module.exports) |e| {
        if (e.kind != .func) continue;
        if (buf.items.len > 0) buf.append(h.allocator, '\n') catch return null;
        buf.appendSlice(h.allocator, e.name) catch return null;
    }
    return str_mod.nox_str_from_bytes(rt, buf.items);
}

/// "i32,i32->i32" biçiminde işlev imzası ("" = yok).
pub export fn nox_wasm_signature_raw(rt: ?*anyopaque, hp: ?*anyopaque, name: ?[*:0]const u8) callconv(.c) ?[*:0]u8 {
    const h = asHandle(hp) orelse return str_mod.nox_str_from_bytes(rt, "");
    const inst = h.inst orelse return str_mod.nox_str_from_bytes(rt, "");
    const idx = inst.findExport(str_mod.nox_str_slice(name orelse return null), .func) orelse return str_mod.nox_str_from_bytes(rt, "");
    const ft = h.module.typeOf(idx);
    var buf: [128]u8 = undefined;
    var w: usize = 0;
    for (ft.params, 0..) |p, i| {
        if (i > 0) {
            buf[w] = ',';
            w += 1;
        }
        const s = @tagName(p);
        @memcpy(buf[w..][0..s.len], s);
        w += s.len;
    }
    buf[w] = '-';
    buf[w + 1] = '>';
    w += 2;
    for (ft.results, 0..) |p, i| {
        if (i > 0) {
            buf[w] = ',';
            w += 1;
        }
        const s = @tagName(p);
        @memcpy(buf[w..][0..s.len], s);
        w += s.len;
    }
    return str_mod.nox_str_from_bytes(rt, buf[0..w]);
}

// ----------------------------------------------------------------------------------------- doğrusal bellek (sınır denetimli)

pub export fn nox_wasm_mem_size_raw(hp: ?*anyopaque) callconv(.c) i64 {
    const h = asHandle(hp) orelse return 0;
    const inst = h.inst orelse return 0;
    return @intCast(inst.memory().len);
}

fn memSlice(h: *Handle, off: i64, len: i64) ?[]u8 {
    clearErr(h);
    const inst = h.inst orelse {
        setErr(h, "module is not instantiated", .{});
        return null;
    };
    const m = inst.memory();
    if (off < 0 or len < 0) {
        setErr(h, "negative memory offset/length", .{});
        return null;
    }
    const o: usize = @intCast(off);
    const l: usize = @intCast(len);
    if (o > m.len or l > m.len - o) {
        setErr(h, "memory access out of bounds (offset {d}, length {d}, memory size {d})", .{ o, l, m.len });
        return null;
    }
    return m[o .. o + l];
}

/// `len` baytı `list[int]` (0..255) olarak okur; sınır dışı = boş liste + hata.
pub export fn nox_wasm_mem_read_raw(rt: ?*anyopaque, hp: ?*anyopaque, off: i64, len: i64) callconv(.c) ?*anyopaque {
    const h = asHandle(hp);
    const sl: []const u8 = if (h) |hh| (memSlice(hh, off, len) orelse &.{}) else &.{};
    const raw = arc.nox_rc_alloc(rt, LIST_HEADER_SIZE + FIELD_SLOT_SIZE * sl.len) orelse return null;
    const base: [*]u8 = @ptrCast(raw);
    @as(*align(1) i64, @ptrCast(base)).* = @intCast(sl.len);
    @as(*align(1) i64, @ptrCast(base + 8)).* = @intCast(sl.len);
    for (sl, 0..) |b, i| @as(*align(1) i64, @ptrCast(base + LIST_HEADER_SIZE + FIELD_SLOT_SIZE * i)).* = b;
    return @ptrCast(base);
}

/// Bellekten `len` baytı `str` olarak okur (UTF-8 metin; ilk NUL'da kesilmez ama Nox `str` NUL içeremez: NUL görülürse orada biter).
pub export fn nox_wasm_mem_read_str_raw(rt: ?*anyopaque, hp: ?*anyopaque, off: i64, len: i64) callconv(.c) ?[*:0]u8 {
    const h = asHandle(hp) orelse return str_mod.nox_str_from_bytes(rt, "");
    const sl = memSlice(h, off, len) orelse return str_mod.nox_str_from_bytes(rt, "");
    const end = std.mem.indexOfScalar(u8, sl, 0) orelse sl.len;
    return str_mod.nox_str_from_bytes(rt, sl[0..end]);
}

/// `data` (`list[int]`, 0..255) baytlarını `off` konumuna yazar. Başarı: 0; hata: 1 (+ `nox_wasm_error_raw`).
pub export fn nox_wasm_mem_write_raw(hp: ?*anyopaque, off: i64, data: ?*anyopaque) callconv(.c) i64 {
    const h = asHandle(hp) orelse return 1;
    const lp: [*]const u8 = @ptrCast(data orelse return 1);
    const n: usize = @intCast(@as(*align(1) const i64, @ptrCast(lp)).*);
    const sl = memSlice(h, off, @intCast(n)) orelse return 1;
    for (0..n) |i| sl[i] = @truncate(@as(u64, @bitCast(@as(*align(1) const i64, @ptrCast(lp + LIST_HEADER_SIZE + FIELD_SLOT_SIZE * i)).*)));
    return 0;
}

/// `s`nin baytlarını (NUL'suz) `off` konumuna yazar. Başarı: 0.
pub export fn nox_wasm_mem_write_str_raw(hp: ?*anyopaque, off: i64, s: ?[*:0]const u8) callconv(.c) i64 {
    const h = asHandle(hp) orelse return 1;
    const bytes = str_mod.nox_str_slice(s orelse return 1);
    const sl = memSlice(h, off, @intCast(bytes.len)) orelse return 1;
    @memcpy(sl, bytes);
    return 0;
}

/// Küçük-endian işaretsiz okuma (`width` 1, 2, 4 veya 8 bayt); `i64` desenine sıfır genişletilir (8 baytta ham).
pub export fn nox_wasm_mem_load_raw(hp: ?*anyopaque, off: i64, width: i64) callconv(.c) i64 {
    const h = asHandle(hp) orelse return 0;
    if (width != 1 and width != 2 and width != 4 and width != 8) {
        setErr(h, "width must be 1, 2, 4 or 8", .{});
        return 0;
    }
    const sl = memSlice(h, off, width) orelse return 0;
    var v: u64 = 0;
    for (sl, 0..) |b, i| v |= @as(u64, b) << @intCast(8 * i);
    return @bitCast(v);
}

/// Küçük-endian yazma (alt `width` bayt). Başarı: 0.
pub export fn nox_wasm_mem_store_raw(hp: ?*anyopaque, off: i64, width: i64, value: i64) callconv(.c) i64 {
    const h = asHandle(hp) orelse return 1;
    if (width != 1 and width != 2 and width != 4 and width != 8) {
        setErr(h, "width must be 1, 2, 4 or 8", .{});
        return 1;
    }
    const sl = memSlice(h, off, width) orelse return 1;
    const v: u64 = @bitCast(value);
    for (sl, 0..) |*b, i| b.* = @truncate(v >> @intCast(8 * i));
    return 0;
}

pub export fn nox_wasm_f64_to_bits_raw(x: f64) callconv(.c) i64 {
    return @bitCast(x);
}

pub export fn nox_wasm_f64_from_bits_raw(b: i64) callconv(.c) f64 {
    return @bitCast(b);
}

pub export fn nox_wasm_f32_to_bits_raw(x: f64) callconv(.c) i64 {
    return @intCast(@as(u32, @bitCast(@as(f32, @floatCast(x)))));
}

pub export fn nox_wasm_f32_from_bits_raw(b: i64) callconv(.c) f64 {
    return @floatCast(@as(f32, @bitCast(@as(u32, @truncate(@as(u64, @bitCast(b)))))));
}

test "nox.wasm kabuğu: addone.wasm aç, çağır, belleği sınırla, kapat" {
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);
    const path = str_mod.nox_str_from_bytes(rt, "tests/compat/wasm_ext/addone.wasm") orelse return error.AllocFailed;
    defer str_mod.nox_str_release(rt, path);
    const hp = nox_wasm_open_raw(rt, path, 0, 0) orelse return error.OpenFailed;
    defer nox_wasm_close_raw(hp);
    const err0 = nox_wasm_error_raw(rt, hp) orelse return error.AllocFailed;
    defer str_mod.nox_str_release(rt, err0);
    try std.testing.expectEqual(@as(usize, 0), str_mod.nox_str_slice(err0).len);
    const name = str_mod.nox_str_from_bytes(rt, "add_one") orelse return error.AllocFailed;
    defer str_mod.nox_str_release(rt, name);
    const raw = arc.nox_rc_alloc(rt, LIST_HEADER_SIZE + FIELD_SLOT_SIZE) orelse return error.AllocFailed;
    const lb: [*]u8 = @ptrCast(raw);
    @as(*align(1) i64, @ptrCast(lb)).* = 1;
    @as(*align(1) i64, @ptrCast(lb + 8)).* = 1;
    @as(*align(1) i64, @ptrCast(lb + LIST_HEADER_SIZE)).* = 41;
    defer arc.nox_rc_free_payload(rt, raw, LIST_HEADER_SIZE + FIELD_SLOT_SIZE);
    try std.testing.expectEqual(@as(i64, 42), nox_wasm_call_raw(rt, hp, name, raw));
    // Bellek sınır denetimi: modül belleğinin SONUNDAKİ erişim hata verir, çökme/okuma yok; sınır içi okuma/yazma çalışır.
    const size = nox_wasm_mem_size_raw(hp);
    try std.testing.expect(size > 0);
    try std.testing.expectEqual(@as(i64, 0), nox_wasm_mem_store_raw(hp, 16, 4, 0x01020304));
    try std.testing.expectEqual(@as(i64, 0x01020304), nox_wasm_mem_load_raw(hp, 16, 4));
    try std.testing.expectEqual(@as(i64, 0x04), nox_wasm_mem_load_raw(hp, 16, 1));
    try std.testing.expectEqual(@as(i64, 0), nox_wasm_mem_load_raw(hp, size - 2, 4));
    const err1 = nox_wasm_error_raw(rt, hp) orelse return error.AllocFailed;
    defer str_mod.nox_str_release(rt, err1);
    try std.testing.expect(str_mod.nox_str_slice(err1).len > 0);
}
