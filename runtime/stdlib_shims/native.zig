//! `nox.native` Zig kabuğu — **Nox Native Interface (NNI) v1**, ana makine (host) tarafı. Bkz. `docs/NATIVE-API.md` ve `include/nox_nni.h`.
//!
//! Bir C/Zig/Rust/C++ eklentisi (`.so`/`.dylib`/`.dll`) `nox_plugin_init_v1(api, rt)` sembolünü dışa aktarır; host eklentiyi `dlopen` ile yükler,
//! SÜRÜMLÜ bir işlev tablosu (`NoxApiV1`) ile çağırır ve eklenti `register_function` ile adlandırılmış yerel işlevlerini kaydeder.
//!
//! **Opak:** eklenti Nox'un ARC başlığını, `RuntimeState`i, `str`/`list` bellek düzenini ASLA görmez — string/bayt değerleri yalnızca opak
//! `NoxHandle` (üreteç sayacı + indeks) ile dolaşır; her `NoxRuntime*` bu dosyadaki `Host` bağlamının opak işaretçisidir. İç runtime (ARC, vb.)
//! serbestçe değişebilir, bu ABI değişmez.
//!
//! **Gizli global durum YOK:** her yüklenen eklenti kendi `Host` bağlamına sahiptir (runtime allocator'ı ile tahsis edilir).
//!
//! **İş parçacığı sözleşmesi:** eklenti işlevleri, Nox'un çağıran iş parçacığında SENKRON çalışır. `api.post_event` HERHANGİ bir iş parçacığından
//! çağrılabilir (kilitli kuyruğa ekler); Nox kodu olayları `poll_event` ile kendi zamanlayıcısında tüketir — yerel iş parçacığı Nox nesne
//! grafiğine ASLA girmez. Diğer API işlevleri yalnızca bir eklenti işlevi çalışırken (çağıran iş parçacığında) ya da init sırasında çağrılabilir;
//! `retain`/`release`/`string_new`/`string_view` kilitlidir ve herhangi bir iş parçacığından güvenlidir.

const std = @import("std");
const builtin = @import("builtin");
const asap = @import("../alloc/asap.zig");
const str_mod = @import("../str.zig");
const SpinLock = @import("../async_rt/spinlock.zig").SpinLock;

// ---- C ABI türleri (include/nox_nni.h ile bire bir) ----

pub const NoxHandle = u64;
pub const NoxStatus = i32;
pub const NOX_OK: NoxStatus = 0;
pub const NOX_ERROR: NoxStatus = 1;
pub const NOX_PANIC: NoxStatus = 2;
pub const NOX_ABI_UNSUPPORTED: NoxStatus = 3;
pub const NOX_BAD_HANDLE: NoxStatus = 4;
pub const NOX_OUT_OF_MEMORY: NoxStatus = 5;
pub const NOX_NOT_FOUND: NoxStatus = 6;

pub const V_NONE: i32 = 0;
pub const V_INT: i32 = 1;
pub const V_FLOAT: i32 = 2;
pub const V_BOOL: i32 = 3;
pub const V_STRING: i32 = 4;
pub const V_BYTES: i32 = 5;

pub const NoxValue = extern struct {
    kind: i32 = V_NONE,
    reserved: i32 = 0,
    u: extern union { i: i64, f: f64, h: NoxHandle } = .{ .i = 0 },
};

const NoxRuntime = anyopaque;
const NoxNativeFn = *const fn (api: *const NoxApiV1, rt: *NoxRuntime, args: [*]const NoxValue, argc: usize, out: *NoxValue) callconv(.c) NoxStatus;

pub const NoxApiV1 = extern struct {
    abi_version: u32,
    struct_size: u32,
    retain: *const fn (rt: *NoxRuntime, h: NoxHandle) callconv(.c) void,
    release: *const fn (rt: *NoxRuntime, h: NoxHandle) callconv(.c) void,
    string_new: *const fn (rt: *NoxRuntime, p: [*]const u8, len: usize) callconv(.c) NoxHandle,
    string_view: *const fn (rt: *NoxRuntime, h: NoxHandle, p: *[*]const u8, len: *usize) callconv(.c) NoxStatus,
    bytes_new: *const fn (rt: *NoxRuntime, p: [*]const u8, len: usize) callconv(.c) NoxHandle,
    bytes_view: *const fn (rt: *NoxRuntime, h: NoxHandle, p: *[*]const u8, len: *usize) callconv(.c) NoxStatus,
    alloc: *const fn (rt: *NoxRuntime, size: usize, alignment: usize) callconv(.c) ?*anyopaque,
    free: *const fn (rt: *NoxRuntime, p: ?*anyopaque, size: usize, alignment: usize) callconv(.c) void,
    error_set: *const fn (rt: *NoxRuntime, code: i32, msg: [*]const u8, len: usize) callconv(.c) NoxStatus,
    register_function: *const fn (rt: *NoxRuntime, name: [*:0]const u8, f: NoxNativeFn) callconv(.c) NoxStatus,
    post_event: *const fn (rt: *NoxRuntime, kind: i64, payload: ?*const NoxValue) callconv(.c) NoxStatus,
};

const PluginInitFn = *const fn (api: *const NoxApiV1, rt: *NoxRuntime) callconv(.c) NoxStatus;
/// Plugin API v1: isteğe bağlı yaşam döngüsü kancası. Eklenti `nox_plugin_shutdown_v1` dışa aktarırsa host, kitaplığı kapatmadan önce BİR KEZ çağırır.
const PluginShutdownFn = *const fn (api: *const NoxApiV1, rt: *NoxRuntime) callconv(.c) void;

// ---- Host bağlamı ----

const Entry = struct {
    in_use: bool = false,
    gen: u32 = 1,
    refs: u32 = 0,
    kind: i32 = V_STRING,
    data: []u8 = &.{},
};

const Func = struct { name: []u8, f: NoxNativeFn };

const Event = struct { kind: i64, value: NoxValue, bytes: []u8 = &.{} };

const LibHandle = if (builtin.os.tag == .windows) ?*anyopaque else std.DynLib;
const Kernel32 = if (builtin.os.tag == .windows) struct {
    extern "kernel32" fn LoadLibraryA(name: [*:0]const u8) callconv(.c) ?*anyopaque;
    extern "kernel32" fn GetProcAddress(module: ?*anyopaque, name: [*:0]const u8) callconv(.c) ?*anyopaque;
} else struct {};

const Host = struct {
    allocator: std.mem.Allocator,
    lib: LibHandle,
    lock: SpinLock = .{},
    entries: std.ArrayListUnmanaged(Entry) = .empty,
    funcs: std.ArrayListUnmanaged(Func) = .empty,
    events: std.ArrayListUnmanaged(Event) = .empty,
    // Çağrı durumu (çağıran iş parçacığına ait; kilit gerektirmez)
    args: std.ArrayListUnmanaged(NoxValue) = .empty,
    arg_bytes: std.ArrayListUnmanaged([]u8) = .empty,
    result: NoxValue = .{},
    result_bytes: []u8 = &.{},
    err_msg: []u8 = &.{},
    cur_event: Event = .{ .kind = -1, .value = .{} },
    lib_open: bool = false,
    ready: bool = false,
};

fn hostFrom(rt: *NoxRuntime) *Host {
    return @ptrCast(@alignCast(rt));
}

fn handleIndex(h: NoxHandle) ?struct { idx: usize, gen: u32 } {
    if (h == 0) return null;
    const lo: u32 = @truncate(h);
    if (lo == 0) return null;
    return .{ .idx = lo - 1, .gen = @intCast(h >> 32) };
}

fn lookupEntry(host: *Host, h: NoxHandle) ?*Entry {
    const hi = handleIndex(h) orelse return null;
    if (hi.idx >= host.entries.items.len) return null;
    const e = &host.entries.items[hi.idx];
    if (!e.in_use or e.gen != hi.gen) return null;
    return e;
}

fn newEntry(host: *Host, kind: i32, p: [*]const u8, len: usize) NoxHandle {
    const copy = host.allocator.alloc(u8, len) catch return 0;
    @memcpy(copy, p[0..len]);
    host.lock.lock();
    defer host.lock.unlock();
    var idx: usize = host.entries.items.len;
    for (host.entries.items, 0..) |*e, i| {
        if (!e.in_use) {
            idx = i;
            break;
        }
    }
    if (idx == host.entries.items.len) {
        host.entries.append(host.allocator, .{}) catch {
            host.allocator.free(copy);
            return 0;
        };
    }
    const e = &host.entries.items[idx];
    e.in_use = true;
    e.refs = 1;
    e.kind = kind;
    e.data = copy;
    return (@as(u64, e.gen) << 32) | @as(u64, @intCast(idx + 1));
}

// ---- API işlevleri ----

fn apiRetain(rt: *NoxRuntime, h: NoxHandle) callconv(.c) void {
    const host = hostFrom(rt);
    host.lock.lock();
    defer host.lock.unlock();
    if (lookupEntry(host, h)) |e| e.refs += 1;
}

fn apiRelease(rt: *NoxRuntime, h: NoxHandle) callconv(.c) void {
    const host = hostFrom(rt);
    host.lock.lock();
    defer host.lock.unlock();
    const e = lookupEntry(host, h) orelse return;
    if (e.refs > 1) {
        e.refs -= 1;
        return;
    }
    host.allocator.free(e.data);
    e.data = &.{};
    e.in_use = false;
    e.refs = 0;
    e.gen +%= 1;
    if (e.gen == 0) e.gen = 1;
}

fn apiStringNew(rt: *NoxRuntime, p: [*]const u8, len: usize) callconv(.c) NoxHandle {
    if (!std.unicode.utf8ValidateSlice(p[0..len])) return 0;
    return newEntry(hostFrom(rt), V_STRING, p, len);
}

fn apiBytesNew(rt: *NoxRuntime, p: [*]const u8, len: usize) callconv(.c) NoxHandle {
    return newEntry(hostFrom(rt), V_BYTES, p, len);
}

fn view(rt: *NoxRuntime, h: NoxHandle, want: i32, p: *[*]const u8, len: *usize) NoxStatus {
    const host = hostFrom(rt);
    host.lock.lock();
    defer host.lock.unlock();
    const e = lookupEntry(host, h) orelse return NOX_BAD_HANDLE;
    if (e.kind != want) return NOX_BAD_HANDLE;
    p.* = e.data.ptr;
    len.* = e.data.len;
    return NOX_OK;
}

fn apiStringView(rt: *NoxRuntime, h: NoxHandle, p: *[*]const u8, len: *usize) callconv(.c) NoxStatus {
    return view(rt, h, V_STRING, p, len);
}

fn apiBytesView(rt: *NoxRuntime, h: NoxHandle, p: *[*]const u8, len: *usize) callconv(.c) NoxStatus {
    return view(rt, h, V_BYTES, p, len);
}

fn apiAlloc(rt: *NoxRuntime, size: usize, alignment: usize) callconv(.c) ?*anyopaque {
    const host = hostFrom(rt);
    const al: std.mem.Alignment = std.mem.Alignment.fromByteUnits(if (alignment == 0 or !std.math.isPowerOfTwo(alignment)) 16 else alignment);
    const p = host.allocator.rawAlloc(size, al, @returnAddress()) orelse return null;
    return p;
}

fn apiFree(rt: *NoxRuntime, p: ?*anyopaque, size: usize, alignment: usize) callconv(.c) void {
    const host = hostFrom(rt);
    const ptr = p orelse return;
    const al: std.mem.Alignment = std.mem.Alignment.fromByteUnits(if (alignment == 0 or !std.math.isPowerOfTwo(alignment)) 16 else alignment);
    host.allocator.rawFree(@as([*]u8, @ptrCast(ptr))[0..size], al, @returnAddress());
}

fn apiErrorSet(rt: *NoxRuntime, code: i32, msg: [*]const u8, len: usize) callconv(.c) NoxStatus {
    _ = code;
    const host = hostFrom(rt);
    const copy = host.allocator.alloc(u8, len) catch return NOX_OUT_OF_MEMORY;
    @memcpy(copy, msg[0..len]);
    if (host.err_msg.len > 0) host.allocator.free(host.err_msg);
    host.err_msg = copy;
    return NOX_ERROR;
}

fn apiRegister(rt: *NoxRuntime, name: [*:0]const u8, f: NoxNativeFn) callconv(.c) NoxStatus {
    const host = hostFrom(rt);
    const dup = host.allocator.dupe(u8, std.mem.span(name)) catch return NOX_OUT_OF_MEMORY;
    host.funcs.append(host.allocator, .{ .name = dup, .f = f }) catch {
        host.allocator.free(dup);
        return NOX_OUT_OF_MEMORY;
    };
    return NOX_OK;
}

fn apiPostEvent(rt: *NoxRuntime, kind: i64, payload: ?*const NoxValue) callconv(.c) NoxStatus {
    const host = hostFrom(rt);
    var ev: Event = .{ .kind = kind, .value = .{} };
    if (payload) |pv| {
        ev.value = pv.*;
        // Dize/bayt yükü: kuyruğa girerken içeriği KOPYALA (tutamaç ömrü olay tüketilene kadar eklentiye bağlı kalmasın).
        if (pv.kind == V_STRING or pv.kind == V_BYTES) {
            host.lock.lock();
            const e = lookupEntry(host, pv.u.h);
            const ok = e != null and e.?.kind == pv.kind;
            if (ok) ev.bytes = host.allocator.dupe(u8, e.?.data) catch {
                host.lock.unlock();
                return NOX_OUT_OF_MEMORY;
            };
            host.lock.unlock();
            if (!ok) return NOX_BAD_HANDLE;
            ev.value.u = .{ .h = 0 };
        }
    }
    host.lock.lock();
    defer host.lock.unlock();
    host.events.append(host.allocator, ev) catch {
        if (ev.bytes.len > 0) host.allocator.free(ev.bytes);
        return NOX_OUT_OF_MEMORY;
    };
    return NOX_OK;
}

const api_v1: NoxApiV1 = .{
    .abi_version = 1,
    .struct_size = @sizeOf(NoxApiV1),
    .retain = apiRetain,
    .release = apiRelease,
    .string_new = apiStringNew,
    .string_view = apiStringView,
    .bytes_new = apiBytesNew,
    .bytes_view = apiBytesView,
    .alloc = apiAlloc,
    .free = apiFree,
    .error_set = apiErrorSet,
    .register_function = apiRegister,
    .post_event = apiPostEvent,
};

// ---- Nox tarafı (extern def) kabuğu ----

fn setErr(host: *Host, msg: []const u8) void {
    if (host.err_msg.len > 0) host.allocator.free(host.err_msg);
    host.err_msg = host.allocator.dupe(u8, msg) catch &.{};
}

fn hostFromInt(h: i64) ?*Host {
    if (h == 0) return null;
    return @ptrFromInt(@as(usize, @intCast(h)));
}

fn openLib(path: [*:0]const u8) ?LibHandle {
    if (builtin.os.tag == .windows) return Kernel32.LoadLibraryA(path);
    return std.DynLib.open(std.mem.span(path)) catch null;
}

fn lookupSym(comptime T: type, lib: *LibHandle, comptime name: [:0]const u8) ?T {
    if (builtin.os.tag == .windows) {
        const handle = lib.* orelse return null;
        const addr = Kernel32.GetProcAddress(handle, name.ptr) orelse return null;
        return @ptrCast(addr);
    }
    return lib.lookup(T, name);
}

fn lookupInit(lib: *LibHandle) ?PluginInitFn {
    return lookupSym(PluginInitFn, lib, "nox_plugin_init_v1");
}

/// Eklentiyi yükler ve başlatır. Hata iletisi okunabilsin diye başarısız yüklemede de bir host döner (`nox_native_is_ready_raw` == 0);
/// `0` yalnızca bellek/argüman hatasıdır.
export fn nox_native_open_raw(rt: ?*anyopaque, path: ?[*:0]const u8) callconv(.c) i64 {
    const state: *asap.RuntimeState = @ptrCast(@alignCast(rt orelse return 0));
    const gpa = state.allocator();
    const p = path orelse return 0;
    const host = gpa.create(Host) catch return 0;
    host.* = .{ .allocator = gpa, .lib = undefined };
    host.lib = openLib(p) orelse {
        setErr(host, "could not load the plugin (dlopen/LoadLibrary failed)");
        return @intCast(@intFromPtr(host));
    };
    host.lib_open = true;
    const init = lookupInit(&host.lib) orelse {
        setErr(host, "symbol nox_plugin_init_v1 not found");
        return @intCast(@intFromPtr(host));
    };
    const st = init(&api_v1, @ptrCast(host));
    if (st != NOX_OK) {
        if (host.err_msg.len == 0) setErr(host, "nox_plugin_init_v1 failed");
        return @intCast(@intFromPtr(host));
    }
    host.ready = true;
    return @intCast(@intFromPtr(host));
}

/// Yükleme başarılı mı (1) yoksa host yalnızca hata taşıyor mu (0)?
export fn nox_native_is_ready_raw(h: i64) callconv(.c) i64 {
    const host = hostFromInt(h) orelse return 0;
    return if (host.ready) 1 else 0;
}

/// Plugin API v1: kayıtlı yerel işlev sayısı / i. işlevin adı (manifest ile çapraz doğrulama için).
export fn nox_native_func_count_raw(h: i64) callconv(.c) i64 {
    const host = hostFromInt(h) orelse return 0;
    return @intCast(host.funcs.items.len);
}

export fn nox_native_func_name_raw(rt: ?*anyopaque, h: i64, i: i64) callconv(.c) ?[*:0]u8 {
    const host = hostFromInt(h) orelse return str_mod.allocStr(rt, "", str_mod.ASCII_TRUE);
    if (i < 0 or i >= host.funcs.items.len) return str_mod.allocStr(rt, "", str_mod.ASCII_TRUE);
    return str_mod.allocStr(rt, host.funcs.items[@intCast(i)].name, str_mod.ASCII_UNKNOWN);
}

/// Plugin API v1: ana makine anahtarı ("macos-arm64", "linux-x64", ...). Manifestin `library` tablosunu seçmek için.
export fn nox_native_platform_raw(rt: ?*anyopaque) callconv(.c) ?[*:0]u8 {
    const os_name = switch (builtin.os.tag) {
        .macos => "macos",
        .linux => "linux",
        .windows => "windows",
        else => "other",
    };
    const arch_name = switch (builtin.cpu.arch) {
        .aarch64 => "arm64",
        .x86_64 => "x64",
        else => "other",
    };
    var buf: [32]u8 = undefined;
    const key = std.fmt.bufPrint(&buf, "{s}-{s}", .{ os_name, arch_name }) catch "other";
    return str_mod.allocStr(rt, key, str_mod.ASCII_TRUE);
}

export fn nox_native_error_raw(rt: ?*anyopaque, h: i64) callconv(.c) ?[*:0]u8 {
    const host = hostFromInt(h) orelse return str_mod.allocStr(rt, "invalid plugin handle", str_mod.ASCII_TRUE);
    return str_mod.allocStr(rt, host.err_msg, str_mod.ASCII_UNKNOWN);
}

export fn nox_native_close_raw(h: i64) callconv(.c) void {
    const host = hostFromInt(h) orelse return;
    const gpa = host.allocator;
    if (host.ready) {
        if (lookupSym(PluginShutdownFn, &host.lib, "nox_plugin_shutdown_v1")) |shutdown| shutdown(&api_v1, @ptrCast(host));
    }
    nox_native_args_clear_raw(h);
    for (host.entries.items) |*e| if (e.in_use) gpa.free(e.data);
    host.entries.deinit(gpa);
    for (host.funcs.items) |f| gpa.free(f.name);
    host.funcs.deinit(gpa);
    for (host.events.items) |ev| if (ev.bytes.len > 0) gpa.free(ev.bytes);
    host.events.deinit(gpa);
    host.args.deinit(gpa);
    host.arg_bytes.deinit(gpa);
    if (host.result_bytes.len > 0) gpa.free(host.result_bytes);
    if (host.err_msg.len > 0) gpa.free(host.err_msg);
    if (host.cur_event.bytes.len > 0) gpa.free(host.cur_event.bytes);
    if (host.lib_open and builtin.os.tag != .windows) host.lib.close();
    gpa.destroy(host);
}

export fn nox_native_args_clear_raw(h: i64) callconv(.c) void {
    const host = hostFromInt(h) orelse return;
    for (host.arg_bytes.items) |b| host.allocator.free(b);
    host.arg_bytes.clearRetainingCapacity();
    host.args.clearRetainingCapacity();
}

export fn nox_native_arg_int_raw(h: i64, v: i64) callconv(.c) void {
    const host = hostFromInt(h) orelse return;
    host.args.append(host.allocator, .{ .kind = V_INT, .u = .{ .i = v } }) catch {};
}

export fn nox_native_arg_float_raw(h: i64, v: f64) callconv(.c) void {
    const host = hostFromInt(h) orelse return;
    host.args.append(host.allocator, .{ .kind = V_FLOAT, .u = .{ .f = v } }) catch {};
}

export fn nox_native_arg_bool_raw(h: i64, v: i64) callconv(.c) void {
    const host = hostFromInt(h) orelse return;
    host.args.append(host.allocator, .{ .kind = V_BOOL, .u = .{ .i = if (v != 0) 1 else 0 } }) catch {};
}

export fn nox_native_arg_str_raw(h: i64, s: ?[*:0]const u8) callconv(.c) void {
    const host = hostFromInt(h) orelse return;
    const text = std.mem.span(s orelse return);
    const copy = host.allocator.dupe(u8, text) catch return;
    host.arg_bytes.append(host.allocator, copy) catch {
        host.allocator.free(copy);
        return;
    };
    // Tutamaç çağrı anında oluşturulur; şimdilik yalnızca indeksi saklarız (kind=STRING, h = arg_bytes indeksi+1).
    host.args.append(host.allocator, .{ .kind = V_STRING, .u = .{ .h = host.arg_bytes.items.len } }) catch {};
}

/// Kayıtlı yerel işlevi çağırır. `0` = başarılı; aksi halde `NoxStatus` (ayrıntı `nox_native_error_raw`).
export fn nox_native_call_raw(h: i64, name: ?[*:0]const u8) callconv(.c) i64 {
    const host = hostFromInt(h) orelse return NOX_BAD_HANDLE;
    const fname = std.mem.span(name orelse return NOX_NOT_FOUND);
    var f: ?NoxNativeFn = null;
    for (host.funcs.items) |fe| if (std.mem.eql(u8, fe.name, fname)) {
        f = fe.f;
    };
    const fun = f orelse {
        setErr(host, "no registered native function with that name");
        return NOX_NOT_FOUND;
    };
    if (host.err_msg.len > 0) {
        host.allocator.free(host.err_msg);
        host.err_msg = &.{};
    }
    // Dize argümanları için çağrı süresince yaşayan tutamaçlar oluştur.
    var tmp: std.ArrayListUnmanaged(NoxValue) = .empty;
    defer tmp.deinit(host.allocator);
    var made: std.ArrayListUnmanaged(NoxHandle) = .empty;
    defer made.deinit(host.allocator);
    for (host.args.items) |a| {
        var v = a;
        if (a.kind == V_STRING) {
            const bytes = host.arg_bytes.items[@intCast(a.u.h - 1)];
            const hh = newEntry(host, V_STRING, bytes.ptr, bytes.len);
            made.append(host.allocator, hh) catch {};
            v.u = .{ .h = hh };
        }
        tmp.append(host.allocator, v) catch return NOX_OUT_OF_MEMORY;
    }
    if (host.result_bytes.len > 0) {
        host.allocator.free(host.result_bytes);
        host.result_bytes = &.{};
    }
    var out: NoxValue = .{};
    const st = fun(&api_v1, @ptrCast(host), tmp.items.ptr, tmp.items.len, &out);
    for (made.items) |hh| apiRelease(@ptrCast(host), hh);
    nox_native_args_clear_raw(h);
    if (st == NOX_OK and (out.kind == V_STRING or out.kind == V_BYTES)) {
        host.lock.lock();
        const e = lookupEntry(host, out.u.h);
        if (e) |ent| host.result_bytes = host.allocator.dupe(u8, ent.data) catch &.{};
        host.lock.unlock();
        apiRelease(@ptrCast(host), out.u.h);
        out.u = .{ .i = 0 };
    }
    host.result = out;
    return st;
}

export fn nox_native_result_kind_raw(h: i64) callconv(.c) i64 {
    const host = hostFromInt(h) orelse return 0;
    return host.result.kind;
}

export fn nox_native_result_int_raw(h: i64) callconv(.c) i64 {
    const host = hostFromInt(h) orelse return 0;
    return host.result.u.i;
}

export fn nox_native_result_float_raw(h: i64) callconv(.c) f64 {
    const host = hostFromInt(h) orelse return 0;
    return host.result.u.f;
}

export fn nox_native_result_str_raw(rt: ?*anyopaque, h: i64) callconv(.c) ?[*:0]u8 {
    const host = hostFromInt(h) orelse return str_mod.allocStr(rt, "", str_mod.ASCII_TRUE);
    return str_mod.allocStr(rt, host.result_bytes, str_mod.ASCII_UNKNOWN);
}

/// Kuyruktaki bir sonraki olayı alır: olay türünü döner, kuyruk boşsa `-1` (negatif türler eklenti tarafından kullanılamaz).
export fn nox_native_event_poll_raw(h: i64) callconv(.c) i64 {
    const host = hostFromInt(h) orelse return -1;
    host.lock.lock();
    defer host.lock.unlock();
    if (host.events.items.len == 0) return -1;
    if (host.cur_event.bytes.len > 0) host.allocator.free(host.cur_event.bytes);
    host.cur_event = host.events.orderedRemove(0);
    return host.cur_event.kind;
}

export fn nox_native_event_value_kind_raw(h: i64) callconv(.c) i64 {
    const host = hostFromInt(h) orelse return 0;
    return host.cur_event.value.kind;
}

export fn nox_native_event_int_raw(h: i64) callconv(.c) i64 {
    const host = hostFromInt(h) orelse return 0;
    return host.cur_event.value.u.i;
}

export fn nox_native_event_float_raw(h: i64) callconv(.c) f64 {
    const host = hostFromInt(h) orelse return 0;
    return host.cur_event.value.u.f;
}

export fn nox_native_event_str_raw(rt: ?*anyopaque, h: i64) callconv(.c) ?[*:0]u8 {
    const host = hostFromInt(h) orelse return str_mod.allocStr(rt, "", str_mod.ASCII_TRUE);
    return str_mod.allocStr(rt, host.cur_event.bytes, str_mod.ASCII_UNKNOWN);
}

test "NNI tutamac tablosu: uretec sayaci eski tutamaci gecersiz kilar" {
    var host: Host = .{ .allocator = std.testing.allocator, .lib = undefined };
    defer {
        for (host.entries.items) |*e| if (e.in_use) std.testing.allocator.free(e.data);
        host.entries.deinit(std.testing.allocator);
    }
    const rt: *NoxRuntime = @ptrCast(&host);
    const h1 = apiStringNew(rt, "merhaba", 7);
    try std.testing.expect(h1 != 0);
    var p: [*]const u8 = undefined;
    var len: usize = 0;
    try std.testing.expectEqual(NOX_OK, apiStringView(rt, h1, &p, &len));
    try std.testing.expectEqualStrings("merhaba", p[0..len]);
    apiRelease(rt, h1);
    try std.testing.expectEqual(NOX_BAD_HANDLE, apiStringView(rt, h1, &p, &len));
    const h2 = apiStringNew(rt, "x", 1);
    try std.testing.expect(h2 != h1);
    apiRelease(rt, h2);
    try std.testing.expectEqual(@as(NoxHandle, 0), apiStringNew(rt, "\xff\xfe", 2));
}
