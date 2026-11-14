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
const crypto_shim = @import("crypto.zig");

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
    /// W3 (v2.1.93): host işlevleri. `.nox` tarafı HER çağrıda (ve açılışta) tek bir gönderici geçirir; yalnızca o çağrı süresince saklanır (kayıtlı/saklanan geri çağrı yok).
    cb: ?HostCallback = null,
    ud: ?*anyopaque = null,
    host_failed: bool = false,
    hctx: []HostCtx = &.{},
    hbind: []interp.HostBinding = &.{},
    /// W3b (WASI preview1 alt kümesi, varsayılan KAPALI): yakalanan çıktılar, argümanlar, izinler, çıkış kodu.
    wasi: bool = false,
    wasi_clock: bool = false,
    wasi_random: bool = false,
    wasi_inherit: bool = false,
    wasi_args: [][]u8 = &.{},
    out: std.ArrayListUnmanaged(u8) = .empty,
    errout: std.ArrayListUnmanaged(u8) = .empty,
    exit_code: i64 = -1,
    rng_state: u64 = 0x9E3779B97F4A7C15,
};

const WASI_OUT_LIMIT: usize = 16 * 1024 * 1024;

/// Nox gönderici işlevinin C ABI imzası (`@ffi.callback` hedefi): (host_indeks, a0, a1, a2, a3, userdata=rt) -> sonuç.
const HostCallback = *const fn (i64, i64, i64, i64, i64, ?*anyopaque) callconv(.c) i64;

const HostCtx = struct { h: *Handle, idx: i64, nparams: usize, nresults: usize, ptypes: []const module_mod.ValType, rtypes: []const module_mod.ValType };

fn hostThunk(ctx: ?*anyopaque, inst: *interp.Instance, args: []const u64, results: []u64) interp.Trap!void {
    _ = inst;
    const c: *HostCtx = @ptrCast(@alignCast(ctx.?));
    const h = c.h;
    const cb = h.cb orelse {
        setErr(h, "host function called outside a nox.wasm call", .{});
        return error.HostFailure;
    };
    var a: [4]i64 = .{ 0, 0, 0, 0 };
    for (args, 0..) |v, i| {
        a[i] = switch (c.ptypes[i]) {
            .i32 => @as(i64, @as(i32, @bitCast(@as(u32, @truncate(v))))),
            .f32 => @as(i64, @intCast(@as(u32, @truncate(v)))),
            else => @bitCast(v),
        };
    }
    const r = cb(c.idx, a[0], a[1], a[2], a[3], h.ud);
    if (h.host_failed) {
        h.host_failed = false;
        setErr(h, "a host function raised an exception", .{});
        return error.HostFailure;
    }
    if (c.nresults > 0) {
        results[0] = switch (c.rtypes[0]) {
            .i32 => @as(u64, @as(u32, @truncate(@as(u64, @bitCast(r))))),
            .f32 => @as(u64, @as(u32, @truncate(@as(u64, @bitCast(r))))),
            else => @bitCast(r),
        };
    }
}

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

// ----------------------------------------------------------------------------------------- WASI preview1 alt kümesi (yetenek tabanlı, varsayılan kapalı)

const WasiFn = struct { name: []const u8, p: []const module_mod.ValType, r: []const module_mod.ValType, f: interp.HostFn };
const I32 = module_mod.ValType.i32;
const I64 = module_mod.ValType.i64;

fn wasiH(ctx: ?*anyopaque) *Handle {
    return @ptrCast(@alignCast(ctx.?));
}

fn wmem(inst: *interp.Instance, off: u64, len: u64) ?[]u8 {
    const m = inst.memory();
    const o: usize = @intCast(@as(u32, @truncate(off)));
    const l: usize = @intCast(@as(u32, @truncate(len)));
    if (o > m.len or l > m.len - o) return null;
    return m[o .. o + l];
}

fn wr32(inst: *interp.Instance, off: u64, v: u32) bool {
    const sl = wmem(inst, off, 4) orelse return false;
    std.mem.writeInt(u32, sl[0..4], v, .little);
    return true;
}

fn wasiFdWrite(ctx: ?*anyopaque, inst: *interp.Instance, args: []const u64, results: []u64) interp.Trap!void {
    const h = wasiH(ctx);
    const fd = @as(u32, @truncate(args[0]));
    if (fd != 1 and fd != 2) {
        results[0] = 8; // EBADF
        return;
    }
    const iovs_ptr: usize = @intCast(@as(u32, @truncate(args[1])));
    const iovs_len: usize = @intCast(@as(u32, @truncate(args[2])));
    var total: u32 = 0;
    for (0..iovs_len) |i| {
        const iov = wmem(inst, iovs_ptr + i * 8, 8) orelse {
            results[0] = 21; // EFAULT
            return;
        };
        const buf_ptr = std.mem.readInt(u32, iov[0..4], .little);
        const buf_len = std.mem.readInt(u32, iov[4..8], .little);
        const data = wmem(inst, buf_ptr, buf_len) orelse {
            results[0] = 21;
            return;
        };
        const dst = if (fd == 1) &h.out else &h.errout;
        if (dst.items.len + data.len > WASI_OUT_LIMIT) {
            results[0] = 28; // ENOSPC
            return;
        }
        dst.appendSlice(h.allocator, data) catch {
            results[0] = 48; // ENOMEM
            return;
        };
        if (comptime @import("builtin").os.tag != .windows) {
            if (h.wasi_inherit) _ = std.c.write(@intCast(fd), data.ptr, data.len);
        }
        total +%= buf_len;
    }
    results[0] = if (wr32(inst, args[3], total)) 0 else 21;
}

fn wasiFdOther(ctx: ?*anyopaque, inst: *interp.Instance, args: []const u64, results: []u64) interp.Trap!void {
    _ = ctx;
    _ = inst;
    _ = args;
    results[0] = 8; // EBADF: dosya sistemi/stdin yok
}

fn wasiFdClose(ctx: ?*anyopaque, inst: *interp.Instance, args: []const u64, results: []u64) interp.Trap!void {
    _ = ctx;
    _ = inst;
    _ = args;
    results[0] = 0;
}

fn wasiFdFdstatGet(ctx: ?*anyopaque, inst: *interp.Instance, args: []const u64, results: []u64) interp.Trap!void {
    _ = ctx;
    const fd = @as(u32, @truncate(args[0]));
    if (fd > 2) {
        results[0] = 8;
        return;
    }
    const sl = wmem(inst, args[1], 24) orelse {
        results[0] = 21;
        return;
    };
    @memset(sl, 0);
    sl[0] = 2; // filetype = karakter aygıtı
    std.mem.writeInt(u64, sl[8..16], if (fd == 0) 2 else 64, .little); // yalnızca fd_read (stdin) ya da fd_write haklarından biri
    results[0] = 0;
}

fn wasiArgsSizes(ctx: ?*anyopaque, inst: *interp.Instance, args: []const u64, results: []u64) interp.Trap!void {
    const h = wasiH(ctx);
    var total: u32 = 0;
    for (h.wasi_args) |a| total += @intCast(a.len + 1);
    results[0] = if (wr32(inst, args[0], @intCast(h.wasi_args.len)) and wr32(inst, args[1], total)) 0 else 21;
}

fn wasiArgsGet(ctx: ?*anyopaque, inst: *interp.Instance, args: []const u64, results: []u64) interp.Trap!void {
    const h = wasiH(ctx);
    var buf_off: u32 = @truncate(args[1]);
    for (h.wasi_args, 0..) |a, i| {
        if (!wr32(inst, args[0] + i * 4, buf_off)) {
            results[0] = 21;
            return;
        }
        const sl = wmem(inst, buf_off, a.len + 1) orelse {
            results[0] = 21;
            return;
        };
        @memcpy(sl[0..a.len], a);
        sl[a.len] = 0;
        buf_off += @intCast(a.len + 1);
    }
    results[0] = 0;
}

fn wasiEnvSizes(ctx: ?*anyopaque, inst: *interp.Instance, args: []const u64, results: []u64) interp.Trap!void {
    _ = ctx;
    results[0] = if (wr32(inst, args[0], 0) and wr32(inst, args[1], 0)) 0 else 21;
}

fn wasiEnvGet(ctx: ?*anyopaque, inst: *interp.Instance, args: []const u64, results: []u64) interp.Trap!void {
    _ = ctx;
    _ = inst;
    _ = args;
    results[0] = 0;
}

fn wasiClockTime(ctx: ?*anyopaque, inst: *interp.Instance, args: []const u64, results: []u64) interp.Trap!void {
    const h = wasiH(ctx);
    if (!h.wasi_clock) {
        results[0] = 63; // EPERM: saat yeteneği verilmedi
        return;
    }
    if (comptime @import("builtin").os.tag == .windows) {
        results[0] = 52; // ENOSYS: bu sürümde Windows'ta saat yok
        return;
    }
    var ts: std.c.timespec = undefined;
    const clk: std.c.clockid_t = if (@as(u32, @truncate(args[0])) == 0) .REALTIME else .MONOTONIC;
    _ = std.c.clock_gettime(clk, &ts);
    const ns: u64 = @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
    const sl = wmem(inst, args[2], 8) orelse {
        results[0] = 21;
        return;
    };
    std.mem.writeInt(u64, sl[0..8], ns, .little);
    results[0] = 0;
}

fn wasiRandomGet(ctx: ?*anyopaque, inst: *interp.Instance, args: []const u64, results: []u64) interp.Trap!void {
    const h = wasiH(ctx);
    if (!h.wasi_random) {
        results[0] = 63;
        return;
    }
    const sl = wmem(inst, args[0], args[1]) orelse {
        results[0] = 21;
        return;
    };
    crypto_shim.secureRandomBuf(sl);
    results[0] = 0;
}

fn wasiProcExit(ctx: ?*anyopaque, inst: *interp.Instance, args: []const u64, results: []u64) interp.Trap!void {
    _ = inst;
    _ = results;
    const h = wasiH(ctx);
    h.exit_code = @as(i64, @intCast(@as(u32, @truncate(args[0]))));
    return error.HostFailure;
}

fn wasiYield(ctx: ?*anyopaque, inst: *interp.Instance, args: []const u64, results: []u64) interp.Trap!void {
    _ = ctx;
    _ = inst;
    _ = args;
    results[0] = 0;
}

const wasi_table = [_]WasiFn{
    .{ .name = "fd_write", .p = &.{ I32, I32, I32, I32 }, .r = &.{I32}, .f = wasiFdWrite },
    .{ .name = "fd_read", .p = &.{ I32, I32, I32, I32 }, .r = &.{I32}, .f = wasiFdOther },
    .{ .name = "fd_close", .p = &.{I32}, .r = &.{I32}, .f = wasiFdClose },
    .{ .name = "fd_seek", .p = &.{ I32, I64, I32, I32 }, .r = &.{I32}, .f = wasiFdOther },
    .{ .name = "fd_fdstat_get", .p = &.{ I32, I32 }, .r = &.{I32}, .f = wasiFdFdstatGet },
    .{ .name = "fd_prestat_get", .p = &.{ I32, I32 }, .r = &.{I32}, .f = wasiFdOther },
    .{ .name = "fd_prestat_dir_name", .p = &.{ I32, I32, I32 }, .r = &.{I32}, .f = wasiFdOther },
    .{ .name = "args_sizes_get", .p = &.{ I32, I32 }, .r = &.{I32}, .f = wasiArgsSizes },
    .{ .name = "args_get", .p = &.{ I32, I32 }, .r = &.{I32}, .f = wasiArgsGet },
    .{ .name = "environ_sizes_get", .p = &.{ I32, I32 }, .r = &.{I32}, .f = wasiEnvSizes },
    .{ .name = "environ_get", .p = &.{ I32, I32 }, .r = &.{I32}, .f = wasiEnvGet },
    .{ .name = "clock_time_get", .p = &.{ I32, I64, I32 }, .r = &.{I32}, .f = wasiClockTime },
    .{ .name = "random_get", .p = &.{ I32, I32 }, .r = &.{I32}, .f = wasiRandomGet },
    .{ .name = "proc_exit", .p = &.{I32}, .r = &.{}, .f = wasiProcExit },
    .{ .name = "sched_yield", .p = &.{}, .r = &.{I32}, .f = wasiYield },
};

fn findWasi(name: []const u8) ?*const WasiFn {
    for (&wasi_table) |*w| {
        if (std.mem.eql(u8, w.name, name)) return w;
    }
    return null;
}

const WasiOpts = struct { enabled: bool = false, clock: bool = false, random: bool = false, inherit: bool = false, args: []const []const u8 = &.{}, max_threads: u32 = 0 };

fn openBytes(rt: ?*anyopaque, bytes: []u8, fuel: i64, max_pages: i64) ?*anyopaque {
    return openBytesHost(rt, bytes, fuel, max_pages, &.{}, null, null, .{});
}

fn openBytesHost(rt: ?*anyopaque, bytes: []u8, fuel: i64, max_pages: i64, names: []const []const u8, cb: ?HostCallback, ud: ?*anyopaque, wopts: WasiOpts) ?*anyopaque {
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
    if (wopts.max_threads > 0) {
        // wasi-threads (opt-in): iOS/Android'de kapalı (kullanıcı kararı 2026-11-14).
        if (!interp.threads_supported) {
            setErr(h, "wasi-threads are not available on this platform (iOS/Android/WebAssembly hosts)", .{});
            return @ptrCast(h);
        }
        cfg.max_threads = @min(wopts.max_threads, 256);
    }
    // Host işlevi içe aktarmalarını bağla: "modül.ad" anahtarı `names` içindeki konumu (= Nox tarafı `hosts` indeksi) verir.
    var nfuncs: usize = 0;
    for (h.module.imports) |imp| {
        if (imp.desc == .func) nfuncs += 1;
    }
    var nbind: usize = 0;
    if (nfuncs > 0) {
        h.hctx = a.alloc(HostCtx, nfuncs) catch return @ptrCast(h);
        h.hbind = a.alloc(interp.HostBinding, nfuncs) catch return @ptrCast(h);
        var k: usize = 0;
        for (h.module.imports) |imp| {
            const type_idx = switch (imp.desc) {
                .func => |t| t,
                else => continue,
            };
            const ft = h.module.types[type_idx];
            if (wopts.enabled and std.mem.eql(u8, imp.module, "wasi_snapshot_preview1")) {
                if (findWasi(imp.name)) |wf| {
                    if (!std.mem.eql(module_mod.ValType, wf.p, ft.params) or !std.mem.eql(module_mod.ValType, wf.r, ft.results)) {
                        setErr(h, "WASI function '{s}' has an unexpected signature", .{imp.name});
                        return @ptrCast(h);
                    }
                    h.hbind[k] = .{ .module = imp.module, .name = imp.name, .item = .{ .func = .{ .params = wf.p, .results = wf.r, .f = wf.f, .ctx = h } } };
                    k += 1;
                    continue;
                }
                setErr(h, "WASI function '{s}' is not supported by nox.wasm (supported: fd_write, args_*, environ_*, clock_time_get, random_get, proc_exit, ...)", .{imp.name});
                return @ptrCast(h);
            }
            // Yerleşik wasi-threads içe aktarması motorda çözülür (bkz. `interp.threadSpawnHost`).
            if (wopts.max_threads > 0 and std.mem.eql(u8, imp.module, "wasi") and std.mem.eql(u8, imp.name, "thread-spawn")) continue;
            var found: ?usize = null;
            for (names, 0..) |nm, i| {
                if (nm.len == imp.module.len + 1 + imp.name.len and std.mem.startsWith(u8, nm, imp.module) and nm[imp.module.len] == '.' and std.mem.eql(u8, nm[imp.module.len + 1 ..], imp.name)) {
                    found = i;
                    break;
                }
            }
            const idx = found orelse {
                setErr(h, "missing host function '{s}.{s}' (register it with Host.func before opening)", .{ imp.module, imp.name });
                return @ptrCast(h);
            };
            if (ft.params.len > 4 or ft.results.len > 1) {
                setErr(h, "host function '{s}.{s}': at most 4 parameters and 1 result are supported", .{ imp.module, imp.name });
                return @ptrCast(h);
            }
            for (ft.params) |p| {
                if (p.isRef()) {
                    setErr(h, "host function '{s}.{s}': reference-typed parameters are not supported", .{ imp.module, imp.name });
                    return @ptrCast(h);
                }
            }
            h.hctx[k] = .{ .h = h, .idx = @intCast(idx), .nparams = ft.params.len, .nresults = ft.results.len, .ptypes = ft.params, .rtypes = ft.results };
            h.hbind[k] = .{ .module = imp.module, .name = imp.name, .item = .{ .func = .{ .params = ft.params, .results = ft.results, .f = hostThunk, .ctx = &h.hctx[k] } } };
            k += 1;
        }
        nbind = k; // yerleşik (thread-spawn) içe aktarmaları atlandıysa kullanılmayan kuyruk bağlanmaz (hbind'in KENDİSİ kısaltılmaz: serbest bırakma boyutu bozulurdu)
    }
    h.wasi = wopts.enabled;
    h.wasi_clock = wopts.clock;
    h.wasi_random = wopts.random;
    h.wasi_inherit = wopts.inherit;
    if (wopts.args.len > 0) {
        h.wasi_args = a.alloc([]u8, wopts.args.len) catch return @ptrCast(h);
        for (wopts.args, 0..) |arg, i| h.wasi_args[i] = a.dupe(u8, arg) catch return @ptrCast(h);
    }
    h.cb = cb;
    h.ud = ud;
    defer {
        h.cb = null;
        h.ud = null;
    }
    h.inst = interp.Instance.init(a, &h.module, h.hbind[0..nbind], cfg) catch |e| {
        if (e == error.ImportNotFound) {
            setErr(h, "the module imports host memory/tables/globals (not supported by nox.wasm)", .{});
        } else {
            setErr(h, "could not instantiate the module: {s}", .{trapName(e)});
        }
        return @ptrCast(h);
    };
    return @ptrCast(h);
}

fn readStrList(a: std.mem.Allocator, list: ?*anyopaque) ?[][]const u8 {
    const lp: [*]const u8 = @ptrCast(list orelse return &.{});
    const n: usize = @intCast(@as(*align(1) const i64, @ptrCast(lp)).*);
    const out = a.alloc([]const u8, n) catch return null;
    for (0..n) |i| {
        const addr: usize = @intCast(@as(u64, @bitCast(@as(*align(1) const i64, @ptrCast(lp + LIST_HEADER_SIZE + FIELD_SLOT_SIZE * i)).*)));
        out[i] = if (addr == 0) "" else str_mod.nox_str_slice(@ptrFromInt(addr));
    }
    return out;
}

/// Host işlevli (ve isteğe bağlı WASI) açılış: `names[i]` = "modül.ad"; Nox tarafındaki `hosts[i]` bu içe aktarmanın gövdesidir. `flags`: bit0 saat, bit1 rastgelelik, bit2 çıktıyı süreç
/// stdout/stderr'ine de yaz, bit3 WASI etkin. `cb`/`ud` (userdata = rt) yalnızca açılış (start işlevi) süresince geçerlidir.
pub export fn nox_wasm_open_host_raw(rt: ?*anyopaque, path: ?[*:0]const u8, names: ?*anyopaque, wasi_args: ?*anyopaque, flags: i64, fuel: i64, max_pages: i64, cb: ?HostCallback, ud: ?*anyopaque) callconv(.c) ?*anyopaque {
    const state: *asap.RuntimeState = @ptrCast(@alignCast(rt orelse return null));
    const a = state.allocator();
    const p = str_mod.nox_str_slice(path orelse return failedHandle(rt, "path is null", .{}));
    const pz = a.dupeZ(u8, p) catch return null;
    defer a.free(pz);
    const bytes = readFileAll(a, pz) catch |e| return failedHandle(rt, "cannot read '{s}': {s}", .{ p, trapName(e) });
    const nm = readStrList(a, names) orelse return null;
    defer a.free(nm);
    const wa = readStrList(a, wasi_args) orelse return null;
    defer a.free(wa);
    return openBytesHost(rt, bytes, fuel, max_pages, nm, cb, ud, .{ .enabled = flags & 8 != 0, .clock = flags & 1 != 0, .random = flags & 2 != 0, .inherit = flags & 4 != 0, .args = wa, .max_threads = @intCast(@max(0, flags >> 16) & 0xffff) });
}

pub export fn nox_wasm_open_bytes_host_raw(rt: ?*anyopaque, data: ?*anyopaque, names: ?*anyopaque, wasi_args: ?*anyopaque, flags: i64, fuel: i64, max_pages: i64, cb: ?HostCallback, ud: ?*anyopaque) callconv(.c) ?*anyopaque {
    const state: *asap.RuntimeState = @ptrCast(@alignCast(rt orelse return null));
    const a = state.allocator();
    const lp: [*]const u8 = @ptrCast(data orelse return failedHandle(rt, "no data", .{}));
    const n: usize = @intCast(@as(*align(1) const i64, @ptrCast(lp)).*);
    const buf = a.alloc(u8, n) catch return null;
    for (0..n) |i| {
        const v = @as(*align(1) const i64, @ptrCast(lp + LIST_HEADER_SIZE + FIELD_SLOT_SIZE * i)).*;
        buf[i] = @truncate(@as(u64, @bitCast(v)));
    }
    const nm = readStrList(a, names) orelse return null;
    defer a.free(nm);
    const wa = readStrList(a, wasi_args) orelse return null;
    defer a.free(wa);
    return openBytesHost(rt, buf, fuel, max_pages, nm, cb, ud, .{ .enabled = flags & 8 != 0, .clock = flags & 1 != 0, .random = flags & 2 != 0, .inherit = flags & 4 != 0, .args = wa, .max_threads = @intCast(@max(0, flags >> 16) & 0xffff) });
}

/// WASI: biriken stdout/stderr'i döner ve boşaltır.
pub export fn nox_wasm_take_stdout_raw(rt: ?*anyopaque, hp: ?*anyopaque) callconv(.c) ?[*:0]u8 {
    const h = asHandle(hp) orelse return str_mod.nox_str_from_bytes(rt, "");
    const out = str_mod.nox_str_from_bytes(rt, h.out.items);
    h.out.clearRetainingCapacity();
    return out;
}

pub export fn nox_wasm_take_stderr_raw(rt: ?*anyopaque, hp: ?*anyopaque) callconv(.c) ?[*:0]u8 {
    const h = asHandle(hp) orelse return str_mod.nox_str_from_bytes(rt, "");
    const out = str_mod.nox_str_from_bytes(rt, h.errout.items);
    h.errout.clearRetainingCapacity();
    return out;
}

/// `proc_exit` ile çıkış kodu (yoksa -1).
pub export fn nox_wasm_exit_code_raw(hp: ?*anyopaque) callconv(.c) i64 {
    const h = asHandle(hp) orelse return -1;
    return h.exit_code;
}

/// Host işlevi bir Nox istisnası fırlattığında gönderici çağırır: sonraki geri dönüşte yürütme `HostFailure` ile kesilir.
pub export fn nox_wasm_host_fail_raw(hp: ?*anyopaque) callconv(.c) void {
    const h = asHandle(hp) orelse return;
    h.host_failed = true;
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

pub export fn nox_wasm_null_raw() callconv(.c) ?*anyopaque {
    return null;
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
    for (h.wasi_args) |arg| a.free(arg);
    if (h.wasi_args.len > 0) a.free(h.wasi_args);
    h.out.deinit(a);
    h.errout.deinit(a);
    if (h.hctx.len > 0) a.free(h.hctx);
    if (h.hbind.len > 0) a.free(h.hbind);
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
    h.exit_code = -1;
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
    for (ft.params) |t| if (t == .v128) {
        setErr(h, "'{s}' takes a v128 parameter, which cannot cross the Nox boundary (wrap it in an i64-pair export)", .{name});
        return false;
    };
    for (ft.results) |t| if (t == .v128) {
        setErr(h, "'{s}' returns a v128 value, which cannot cross the Nox boundary (wrap it in an i64-pair export)", .{name});
        return false;
    };
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

/// `nox_wasm_call_raw` + host gönderici (bu çağrı süresince geçerli; iç içe çağrılarda önceki değer geri yüklenir).
pub export fn nox_wasm_call_host_raw(hp: ?*anyopaque, name: ?[*:0]const u8, args: ?*anyopaque, cb: ?HostCallback, ud: ?*anyopaque) callconv(.c) i64 {
    const h = asHandle(hp) orelse return 0;
    const saved_cb = h.cb;
    const saved_ud = h.ud;
    h.cb = cb;
    h.ud = ud;
    defer {
        h.cb = saved_cb;
        h.ud = saved_ud;
    }
    return nox_wasm_call_raw(ud, hp, name, args);
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

pub export fn nox_wasm_call_f_host_raw(hp: ?*anyopaque, name: ?[*:0]const u8, args: ?*anyopaque, cb: ?HostCallback, ud: ?*anyopaque) callconv(.c) f64 {
    const h = asHandle(hp) orelse return 0;
    const saved_cb = h.cb;
    const saved_ud = h.ud;
    h.cb = cb;
    h.ud = ud;
    defer {
        h.cb = saved_cb;
        h.ud = saved_ud;
    }
    return nox_wasm_call_f_raw(ud, hp, name, args);
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

test "nox.wasm kabuğu: modül aç, çağır, belleği sınırla, kapat" {
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);
    // (module (memory 1) (func (export "add_one") (param i32) (result i32) local.get 0 i32.const 1 i32.add)) — kendi kendine yeten bayt listesi:
    // test dosya sistemindeki üretilmiş bir ikiliye (CI'da sıralama bağımlı) DAYANMAZ.
    const code = [_]u8{ 0, 97, 115, 109, 1, 0, 0, 0, 1, 6, 1, 96, 1, 127, 1, 127, 3, 2, 1, 0, 5, 3, 1, 0, 1, 7, 11, 1, 7, 97, 100, 100, 95, 111, 110, 101, 0, 0, 10, 9, 1, 7, 0, 32, 0, 65, 1, 106, 11 };
    const lraw = arc.nox_rc_alloc(rt, LIST_HEADER_SIZE + FIELD_SLOT_SIZE * code.len) orelse return error.AllocFailed;
    defer arc.nox_rc_free_payload(rt, lraw, LIST_HEADER_SIZE + FIELD_SLOT_SIZE * code.len);
    const lb: [*]u8 = @ptrCast(lraw);
    @as(*align(1) i64, @ptrCast(lb)).* = code.len;
    @as(*align(1) i64, @ptrCast(lb + 8)).* = code.len;
    for (code, 0..) |c, i| @as(*align(1) i64, @ptrCast(lb + LIST_HEADER_SIZE + FIELD_SLOT_SIZE * i)).* = c;
    const hp = nox_wasm_open_bytes_raw(rt, lraw, 0, 0) orelse return error.OpenFailed;
    defer nox_wasm_close_raw(hp);
    const err0 = nox_wasm_error_raw(rt, hp) orelse return error.AllocFailed;
    defer str_mod.nox_str_release(rt, err0);
    try std.testing.expectEqual(@as(usize, 0), str_mod.nox_str_slice(err0).len);
    const name = str_mod.nox_str_from_bytes(rt, "add_one") orelse return error.AllocFailed;
    defer str_mod.nox_str_release(rt, name);
    const raw = arc.nox_rc_alloc(rt, LIST_HEADER_SIZE + FIELD_SLOT_SIZE) orelse return error.AllocFailed;
    const ab: [*]u8 = @ptrCast(raw);
    @as(*align(1) i64, @ptrCast(ab)).* = 1;
    @as(*align(1) i64, @ptrCast(ab + 8)).* = 1;
    @as(*align(1) i64, @ptrCast(ab + LIST_HEADER_SIZE)).* = 41;
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
