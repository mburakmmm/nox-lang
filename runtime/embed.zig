//! Mobil gömme ABI'si (`include/nox_embed.h`). NNI'den ayrıdır.
//! Host bir `NoxEmbedSlot` sahiplenir. İkinci `create` aynı slotta
//! `ERR_EXISTS` döner. Süreç genelinde gizli bir uygulama yok.

const std = @import("std");
const builtin = @import("builtin");
const asap = @import("alloc/asap.zig");
const errors_handle = @import("errors/handle.zig");
const abi_ptr = @import("abi_ptr.zig");
const dispatch_registry = @import("alloc/dispatch_registry.zig");

fn monoNs() u64 {
    if (comptime builtin.os.tag == .windows) {
        const k = struct {
            extern "kernel32" fn QueryPerformanceCounter(count: *i64) callconv(.c) i32;
            extern "kernel32" fn QueryPerformanceFrequency(freq: *i64) callconv(.c) i32;
        };
        var freq: i64 = 0;
        var counter: i64 = 0;
        if (k.QueryPerformanceFrequency(&freq) == 0 or freq <= 0) return 0;
        if (k.QueryPerformanceCounter(&counter) == 0 or counter < 0) return 0;
        return @as(u64, @intCast(@divTrunc(counter * 1_000_000_000, freq)));
    }
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    if (ts.sec < 0 or ts.nsec < 0) return 0;
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

pub const OK: i32 = 0;
pub const ERR_VERSION: i32 = -1;
pub const ERR_INVAL: i32 = -2;
pub const ERR_EXISTS: i32 = -3;
pub const ERR_STATE: i32 = -4;
pub const ERR_REENTRANT: i32 = -5;
pub const ERR_NOMEM: i32 = -6;
pub const ERR_UTF8: i32 = -7;
/// Olay kuyruğu dolu (`post_event`); olay KOPYALANMADI, host sonra yeniden deneyebilir. Önceden `ERR_STATE` dönüyordu.
pub const ERR_FULL: i32 = -8;
/// Kullanıcı kodu (giriş ya da olay işleyicisi) dönerken bekleyen bir Nox istisnası var. Nesne bekleyen durumda kalır:
/// host `nox_exception_take` ile alır. `pump`ta kuyrukta kalan olaylar yerinde durur.
pub const ERR_EXCEPTION: i32 = -9;

pub const ABI: i32 = 1;
const EVENT_CAP: u32 = 64;
const EVENT_BYTES: usize = 256;

pub const Slot = extern struct {
    abi_version: i32,
    app: ?*anyopaque,
};

/// Host'un çalışma zamanına verdiği bellek ayırıcısı (isteğe bağlı). `alloc` `alignment` hizalı, en az `len` baytlık bellek
/// döner (sıfırlanmış olması GEREKMEZ), yetersizse `NULL`; `free` aynı `len`/`alignment` ile bırakır. Çağrılar farklı iş
/// parçacıklarından gelebilir: host ayırıcısı iş parçacığı-güvenli olmalı ve uygulama yok edilene kadar yaşamalıdır.
pub const HostAllocator = extern struct {
    size: u32,
    ctx: ?*anyopaque,
    alloc: ?*const fn (?*anyopaque, usize, usize) callconv(.c) ?*anyopaque,
    free: ?*const fn (?*anyopaque, ?*anyopaque, usize, usize) callconv(.c) void,
};

/// `size` alanı sürüm ayrımını taşır: eski düzen (`allocator` alanı yok) ve genişletilmiş düzen kabul edilir (ABI numarası 1 kalır).
pub const HostConfigV1 = extern struct {
    size: u32,
    abi_version: u32,
    slot: ?*Slot,
    documents: ?[*:0]const u8,
    support: ?[*:0]const u8,
    cache: ?[*:0]const u8,
    temp_dir: ?[*:0]const u8,
};

pub const HostConfig = extern struct {
    size: u32,
    abi_version: u32,
    slot: ?*Slot,
    documents: ?[*:0]const u8,
    support: ?[*:0]const u8,
    cache: ?[*:0]const u8,
    temp_dir: ?[*:0]const u8,
    /// `null`: sistem ayırıcısı. Aksi halde çalışma zamanının yönetilen heap'i (liste/sözlük/ARC/RuntimeState) buradan beslenir.
    allocator: ?*const HostAllocator,
};

const State = enum(u8) { created, started, stopped, destroyed };

const Event = struct {
    kind: i32,
    len: u32,
    bytes: [EVENT_BYTES]u8,
};

const App = struct {
    allocator: std.mem.Allocator,
    state: State,
    in_user: bool,
    rt: ?*anyopaque,
    entry: ?*const fn (?*anyopaque) callconv(.c) void,
    event_fn: ?*const fn (?*anyopaque, i32, [*]const u8, u32) callconv(.c) void,
    slot: *Slot,
    roots: [4]?[*:0]const u8,
    /// Host ayırıcısının kopyası (`null`: sistem ayırıcısı). `hostAllocator()` bunu bir `std.mem.Allocator`a bağlar.
    host_alloc: ?HostAllocator,
    count: u32,
    head: u32,
    events: [EVENT_CAP]Event,
};

const host_alloc_vtable: std.mem.Allocator.VTable = .{
    .alloc = hostAlloc,
    .resize = hostResize,
    .remap = hostRemap,
    .free = hostFree,
};

fn hostAlloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
    _ = ret_addr;
    const app: *App = @ptrCast(@alignCast(ctx));
    const h = app.host_alloc orelse return null;
    const align_bytes = alignment.toByteUnits();
    const raw = h.alloc.?(h.ctx, len, align_bytes) orelse return null;
    // Sözleşme ihlali (hizasız bellek) çalışma zamanını bozmasın: reddet ve geri ver.
    if (@intFromPtr(raw) % align_bytes != 0) {
        h.free.?(h.ctx, raw, len, align_bytes);
        return null;
    }
    return @ptrCast(raw);
}

fn hostResize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
    _ = ctx;
    _ = memory;
    _ = alignment;
    _ = new_len;
    _ = ret_addr;
    return false;
}

fn hostRemap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
    _ = ctx;
    _ = memory;
    _ = alignment;
    _ = new_len;
    _ = ret_addr;
    return null;
}

fn hostFree(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
    _ = ret_addr;
    const app: *App = @ptrCast(@alignCast(ctx));
    const h = app.host_alloc orelse return;
    h.free.?(h.ctx, memory.ptr, memory.len, alignment.toByteUnits());
}

/// `app`in çalışma zamanı için ayırıcı: host verdiyse onu, yoksa sistem ayırıcısını.
fn runtimeAllocator(app: *App) ?std.mem.Allocator {
    if (app.host_alloc == null) return null;
    return .{ .ptr = app, .vtable = &host_alloc_vtable };
}

/// Sandbox kararı, çağıranın taşıdığı `rt`nin politikasına bakar (gizli/thread-local seçim YOK, AGENTS §2.6):
/// aynı süreçteki iki uygulama ve `nox.thread` çocukları birbirinin köklerini göremez. `rt == null`
/// yalnızca runtime'sız birim testleri içindir; derlenmiş programlar `with_rt` ile daima geçerli `rt` verir.
pub fn allowsPath(rt: ?*anyopaque, path: ?[*:0]const u8) bool {
    const state: *asap.RuntimeState = @ptrCast(@alignCast(rt orelse return true));
    if (!state.embed_active) return true;
    const raw = path orelse return false;
    const text = std.mem.span(raw);
    if (!underRoots(state.embed_roots, text)) return false;
    return canonicalUnderRoots(state.embed_roots, text);
}

/// Metinsel kök denetimini geçen yolun sembolik bağlar çözüldükten sonra da bir kökün altında kaldığını doğrular: kök içindeki
/// bir bağ dışarıyı gösterebilir. Var olan en uzun önek `realpath` ile çözülür, kalan (henüz olmayan) bileşenler eklenir; kökler de
/// kanonikleştirilir (`/tmp` -> `/private/tmp`). Kanonikleştirilemeyen yol reddedilir (fail-closed). Windows'ta gömme hedefi yoktur.
fn canonicalUnderRoots(roots: [4]?[*:0]const u8, path: []const u8) bool {
    if (comptime builtin.os.tag == .windows) return true;
    var resolved_buf: [std.posix.PATH_MAX]u8 = undefined;
    const resolved = canonicalize(path, &resolved_buf) orelse return false;
    for (roots) |root_z| {
        const root = std.mem.span(root_z orelse continue);
        if (root.len == 0) continue;
        var root_buf: [std.posix.PATH_MAX]u8 = undefined;
        const canon_root = canonicalize(root, &root_buf) orelse continue;
        if (std.mem.eql(u8, resolved, canon_root)) return true;
        if (std.mem.startsWith(u8, resolved, canon_root) and resolved.len > canon_root.len and resolved[canon_root.len] == '/') return true;
    }
    return false;
}

fn canonicalize(path: []const u8, out: *[std.posix.PATH_MAX]u8) ?[]const u8 {
    var z_buf: [std.posix.PATH_MAX]u8 = undefined;
    var end = path.len;
    if (end >= z_buf.len) return null;
    // Var olan en uzun öneki bul: sondan başlayıp `/` sınırlarında kısalt.
    while (true) {
        @memcpy(z_buf[0..end], path[0..end]);
        z_buf[end] = 0;
        const rp = std.c.realpath(@ptrCast(&z_buf), @ptrCast(out));
        if (rp != null) {
            const base = std.mem.sliceTo(out, 0);
            const rest = path[end..];
            if (base.len + rest.len >= out.len) return null;
            @memmove(out[base.len .. base.len + rest.len], rest);
            return out[0 .. base.len + rest.len];
        }
        // Önek bulunamadı: bir bileşen yukarı çık (kök `/` bile çözülemezse reddet).
        const slash = std.mem.lastIndexOfScalar(u8, path[0..end], '/') orelse return null;
        if (slash == 0) {
            if (end == 1) return null;
            end = 1;
        } else end = slash;
    }
}

fn underRoots(roots: [4]?[*:0]const u8, path: []const u8) bool {
    if (path.len == 0 or path[0] != '/') return false;
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |part| {
        if (std.mem.eql(u8, part, "..")) return false;
    }
    for (roots) |root_z| {
        const root = std.mem.span(root_z orelse continue);
        if (root.len == 0) continue;
        if (std.mem.eql(u8, path, root)) return true;
        if (std.mem.startsWith(u8, path, root) and path.len > root.len and path[root.len] == '/') return true;
    }
    return false;
}

fn appFrom(ptr: ?*anyopaque) ?*App {
    const raw = ptr orelse return null;
    const app: *App = @ptrCast(@alignCast(raw));
    if (app.state == .destroyed) return null;
    return app;
}

fn installRoots(app: *App) void {
    const state: *asap.RuntimeState = @ptrCast(@alignCast(app.rt orelse return));
    state.embed_active = true;
    state.embed_roots = app.roots;
}

fn clearRoots(app: *App) void {
    if (app.rt) |rt| {
        const state: *asap.RuntimeState = @ptrCast(@alignCast(rt));
        state.embed_active = false;
        state.embed_roots = .{ null, null, null, null };
    }
}

pub fn createWith(allocator: std.mem.Allocator, config: ?*const HostConfig, out: ?*?*anyopaque) i32 {
    const cfg = config orelse return ERR_INVAL;
    if (cfg.abi_version != ABI) return ERR_VERSION;
    // `size`: eski (allocator alanı yok) ya da genişletilmiş düzen; ikisi de ABI 1.
    const has_allocator_field = cfg.size == @sizeOf(HostConfig);
    if (cfg.size != @sizeOf(HostConfigV1) and !has_allocator_field) return ERR_VERSION;
    var host_alloc: ?HostAllocator = null;
    if (has_allocator_field) {
        if (cfg.allocator) |a| {
            if (a.size != @sizeOf(HostAllocator) or a.alloc == null or a.free == null) return ERR_INVAL;
            host_alloc = a.*;
        }
    }
    const slot = cfg.slot orelse return ERR_INVAL;
    if (slot.abi_version != ABI) return ERR_VERSION;
    if (out == null) return ERR_INVAL;
    if (slot.app != null) return ERR_EXISTS;
    const app = allocator.create(App) catch return ERR_NOMEM;
    app.* = .{
        .allocator = allocator,
        .state = .created,
        .in_user = false,
        .rt = null,
        .entry = null,
        .event_fn = null,
        .slot = slot,
        .roots = .{ cfg.documents, cfg.support, cfg.cache, cfg.temp_dir },
        .host_alloc = host_alloc,
        .count = 0,
        .head = 0,
        .events = undefined,
    };
    slot.app = app;
    out.?.* = app;
    return OK;
}

/// `nox_exception_take`in döndürdüğü istisna nesnesini bırakır (host nesnenin sahibidir). Sınıf etiketi nesnenin ilk sekiz baytıdır;
/// bırakma, programın kayıtlı sınıf-bırakma tablosuyla yapılır. `null` zararsızdır.
export fn nox_exception_release(rt: ?*anyopaque, exception: ?*anyopaque) callconv(.c) void {
    const obj = exception orelse return;
    const f = dispatch_registry.classReleaseFn() orelse return;
    const tag: *const i64 = @ptrCast(@alignCast(obj));
    f(abi_ptr.arg(rt), tag.*, abi_ptr.arg(obj));
}

export fn nox_embed_abi_version() callconv(.c) i32 {
    return ABI;
}

const hostLog = if (builtin.os.tag == .ios or builtin.abi.isAndroid()) mobileLog else desktopLog;

fn mobileLog(msg: [*:0]const u8) void {
    const c = struct {
        extern "c" fn nox_host_log_debug(text: [*:0]const u8) void;
    };
    c.nox_host_log_debug(msg);
}

fn desktopLog(msg: [*:0]const u8) void {
    _ = msg;
}

/// Debug derlemesi OSLog veya logcat'e yazar. Release bu çağrıyı yapmaz.
export fn nox_log_debug_raw(rt: ?*anyopaque, msg: ?[*:0]const u8) callconv(.c) void {
    _ = rt;
    if (builtin.mode != .Debug) return;
    const text = msg orelse return;
    hostLog(text);
}

export fn nox_app_create(config: ?*const HostConfig, out: ?*?*anyopaque) callconv(.c) i32 {
    return createWith(std.heap.page_allocator, config, out);
}

export fn nox_app_set_entry(app_ptr: ?*anyopaque, entry: ?*const fn (?*anyopaque) callconv(.c) void) callconv(.c) void {
    const app = appFrom(app_ptr) orelse return;
    if (app.in_user) return;
    app.entry = entry;
}

export fn nox_app_set_event_fn(app_ptr: ?*anyopaque, function: ?*const fn (?*anyopaque, i32, [*]const u8, u32) callconv(.c) void) callconv(.c) void {
    const app = appFrom(app_ptr) orelse return;
    if (app.in_user) return;
    app.event_fn = function;
}

export fn nox_app_start(app_ptr: ?*anyopaque) callconv(.c) i32 {
    const app = appFrom(app_ptr) orelse return ERR_STATE;
    if (app.in_user) return ERR_REENTRANT;
    if (app.state != .created) return ERR_STATE;
    const rt = (if (runtimeAllocator(app)) |a| asap.nox_runtime_init_with_allocator(a) else asap.nox_runtime_init()) orelse {
        return ERR_NOMEM;
    };
    app.rt = rt;
    app.state = .started;
    installRoots(app);
    if (app.entry) |entry| {
        app.in_user = true;
        entry(rt);
        app.in_user = false;
        if (errors_handle.nox_exception_pending(rt) != 0) return ERR_EXCEPTION;
    }
    return OK;
}

export fn nox_app_runtime(app_ptr: ?*anyopaque) callconv(.c) ?*anyopaque {
    const app = appFrom(app_ptr) orelse return null;
    return app.rt;
}

export fn nox_app_post_event(app_ptr: ?*anyopaque, kind: i32, bytes: ?[*]const u8, len: u32) callconv(.c) i32 {
    const app = appFrom(app_ptr) orelse return ERR_STATE;
    if (app.state != .started) return ERR_STATE;
    if (len > EVENT_BYTES) return ERR_INVAL;
    const slice = if (len == 0) "" else (bytes orelse return ERR_INVAL)[0..len];
    if (len > 0 and !std.unicode.utf8ValidateSlice(slice)) return ERR_UTF8;
    if (app.count == EVENT_CAP) return ERR_FULL;
    const index: usize = (app.head + app.count) % EVENT_CAP;
    app.events[index].kind = kind;
    app.events[index].len = len;
    if (len > 0) @memcpy(app.events[index].bytes[0..len], slice);
    app.count += 1;
    return OK;
}

export fn nox_app_pump(app_ptr: ?*anyopaque, monotonic_time_ns: u64) callconv(.c) i32 {
    const app = appFrom(app_ptr) orelse return ERR_STATE;
    if (app.in_user) return ERR_REENTRANT;
    if (app.state != .started) return ERR_STATE;
    var delivered: i32 = 0;
    while (app.count > 0) {
        if (monotonic_time_ns != 0 and monoNs() >= monotonic_time_ns) break;
        const event = app.events[app.head];
        app.head = (app.head + 1) % EVENT_CAP;
        app.count -= 1;
        delivered += 1;
        if (app.event_fn) |function| {
            app.in_user = true;
            function(app.rt, event.kind, &event.bytes, event.len);
            app.in_user = false;
            if (errors_handle.nox_exception_pending(app.rt) != 0) return ERR_EXCEPTION;
        }
    }
    return delivered;
}

export fn nox_app_request_stop(app_ptr: ?*anyopaque) callconv(.c) i32 {
    const app = appFrom(app_ptr) orelse return ERR_STATE;
    if (app.in_user) return ERR_REENTRANT;
    if (app.state != .started) return ERR_STATE;
    app.state = .stopped;
    app.count = 0;
    app.head = 0;
    return OK;
}

export fn nox_app_destroy(app_ptr: ?*anyopaque) callconv(.c) i32 {
    const raw = app_ptr orelse return OK;
    const app: *App = @ptrCast(@alignCast(raw));
    if (app.state == .destroyed) return OK;
    if (app.in_user) return ERR_REENTRANT;
    clearRoots(app);
    if (app.rt) |rt| asap.nox_runtime_deinit(rt);
    app.rt = null;
    app.state = .destroyed;
    if (app.slot.app == @as(*anyopaque, app)) app.slot.app = null;
    const allocator = app.allocator;
    allocator.destroy(app);
    return OK;
}

fn sampleConfig(slot: *Slot, documents: ?[*:0]const u8) HostConfig {
    return .{
        .size = @sizeOf(HostConfig),
        .abi_version = ABI,
        .slot = slot,
        .documents = documents,
        .support = null,
        .cache = null,
        .temp_dir = null,
        .allocator = null,
    };
}

/// Test host ayırıcısı: `std.testing.allocator` üzerinden ayırır, canlı/toplam sayısını tutar, istenince başarısız olur.
const TrackingHost = struct {
    live: usize = 0,
    total: usize = 0,
    fail: bool = false,

    fn alloc(ctx: ?*anyopaque, len: usize, alignment: usize) callconv(.c) ?*anyopaque {
        const self: *TrackingHost = @ptrCast(@alignCast(ctx.?));
        if (self.fail) return null;
        const a = std.mem.Alignment.fromByteUnits(alignment);
        const p = std.testing.allocator.rawAlloc(len, a, @returnAddress()) orelse return null;
        self.live += 1;
        self.total += 1;
        return p;
    }

    fn free(ctx: ?*anyopaque, ptr: ?*anyopaque, len: usize, alignment: usize) callconv(.c) void {
        const self: *TrackingHost = @ptrCast(@alignCast(ctx.?));
        const a = std.mem.Alignment.fromByteUnits(alignment);
        std.testing.allocator.rawFree(@as([*]u8, @ptrCast(ptr.?))[0..len], a, @returnAddress());
        self.live -= 1;
    }

    fn descriptor(self: *TrackingHost) HostAllocator {
        return .{ .size = @sizeOf(HostAllocator), .ctx = self, .alloc = alloc, .free = free };
    }
};

test "host ayırıcısı çalışma zamanının tüm yönetilen belleğini karşılar ve destroy hepsini geri verir" {
    var host: TrackingHost = .{};
    const descriptor = host.descriptor();
    var slot: Slot = .{ .abi_version = ABI, .app = null };
    var config = sampleConfig(&slot, "/app/documents");
    config.allocator = &descriptor;

    var out: ?*anyopaque = null;
    try std.testing.expectEqual(OK, createWith(std.testing.allocator, &config, &out));
    const app = out.?;
    try std.testing.expectEqual(@as(usize, 0), host.total); // henüz çalışma zamanı yok
    try std.testing.expectEqual(OK, nox_app_start(app));
    try std.testing.expect(host.total > 0);

    // Çalışma zamanı üzerinden bir str ayır: host sayacı artmalı.
    const rt = nox_app_runtime(app);
    const before = host.total;
    const text = @import("str.zig").nox_str_from_bytes(rt, "merhaba") orelse return error.AllocFailed;
    try std.testing.expect(host.total > before);
    @import("str.zig").nox_str_release(rt, text);

    try std.testing.expectEqual(OK, nox_app_destroy(app));
    try std.testing.expectEqual(@as(usize, 0), host.live); // sızıntı yok (testing.allocator da denetler)
}

test "host ayırıcısı bellek vermezse start ERR_NOMEM döner, uygulama created kalır ve sızıntısız yok edilir" {
    var host: TrackingHost = .{ .fail = true };
    const descriptor = host.descriptor();
    var slot: Slot = .{ .abi_version = ABI, .app = null };
    var config = sampleConfig(&slot, "/app/documents");
    config.allocator = &descriptor;

    var out: ?*anyopaque = null;
    try std.testing.expectEqual(OK, createWith(std.testing.allocator, &config, &out));
    try std.testing.expectEqual(ERR_NOMEM, nox_app_start(out));
    try std.testing.expect(nox_app_runtime(out) == null);
    try std.testing.expectEqual(OK, nox_app_destroy(out));
    try std.testing.expectEqual(@as(usize, 0), host.live);
}

test "geçersiz host ayırıcısı ERR_INVAL, eski (allocator alanı olmayan) düzen kabul edilir" {
    var slot: Slot = .{ .abi_version = ABI, .app = null };
    var out: ?*anyopaque = null;

    var bad_size: HostAllocator = .{ .size = 1, .ctx = null, .alloc = TrackingHost.alloc, .free = TrackingHost.free };
    var config = sampleConfig(&slot, "/app/documents");
    config.allocator = &bad_size;
    try std.testing.expectEqual(ERR_INVAL, createWith(std.testing.allocator, &config, &out));
    try std.testing.expect(slot.app == null);

    var no_alloc: HostAllocator = .{ .size = @sizeOf(HostAllocator), .ctx = null, .alloc = null, .free = TrackingHost.free };
    config.allocator = &no_alloc;
    try std.testing.expectEqual(ERR_INVAL, createWith(std.testing.allocator, &config, &out));

    // Eski host: HostConfigV1 boyutu, sistem ayırıcısı.
    const v1: HostConfigV1 = .{
        .size = @sizeOf(HostConfigV1),
        .abi_version = ABI,
        .slot = &slot,
        .documents = "/app/documents",
        .support = null,
        .cache = null,
        .temp_dir = null,
    };
    try std.testing.expectEqual(OK, createWith(std.testing.allocator, @ptrCast(&v1), &out));
    try std.testing.expectEqual(OK, nox_app_destroy(out));

    // Tanınmayan boyut hâlâ ERR_VERSION.
    var weird = sampleConfig(&slot, "/app/documents");
    weird.size = @sizeOf(HostConfig) + 8;
    try std.testing.expectEqual(ERR_VERSION, createWith(std.testing.allocator, &weird, &out));
}

test "embed path stays inside the host roots" {
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);
    const state: *asap.RuntimeState = @ptrCast(@alignCast(rt));
    state.embed_active = true;
    state.embed_roots[0] = "/app/documents";
    try std.testing.expect(allowsPath(rt, "/app/documents"));
    try std.testing.expect(allowsPath(rt, "/app/documents/notes.txt"));
    try std.testing.expect(!allowsPath(rt, "/app/documents/../secret"));
    try std.testing.expect(!allowsPath(rt, "/tmp/other"));
    try std.testing.expect(!allowsPath(rt, ":memory:"));
}

test "embed policy is per runtime: two apps never see each other's roots" {
    const a = asap.nox_runtime_init_with_allocator(std.testing.allocator) orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(a);
    const b = asap.nox_runtime_init_with_allocator(std.testing.allocator) orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(b);
    const sa: *asap.RuntimeState = @ptrCast(@alignCast(a));
    const sb: *asap.RuntimeState = @ptrCast(@alignCast(b));
    sa.embed_active = true;
    sa.embed_roots[0] = "/apps/a/documents";
    sb.embed_active = true;
    sb.embed_roots[0] = "/apps/b/documents";
    try std.testing.expect(allowsPath(a, "/apps/a/documents/x"));
    try std.testing.expect(!allowsPath(a, "/apps/b/documents/x"));
    try std.testing.expect(allowsPath(b, "/apps/b/documents/x"));
    try std.testing.expect(!allowsPath(b, "/apps/a/documents/x"));
}

test "embed policy does not depend on the calling OS thread" {
    const rt = asap.nox_runtime_init_with_allocator(std.testing.allocator) orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);
    const state: *asap.RuntimeState = @ptrCast(@alignCast(rt));
    state.embed_active = true;
    state.embed_roots[0] = "/app/documents";
    const Probe = struct {
        rt: ?*anyopaque,
        inside: bool = false,
        outside: bool = true,
        fn run(self: *@This()) void {
            self.inside = allowsPath(self.rt, "/app/documents/ok.txt");
            self.outside = allowsPath(self.rt, "/etc/passwd");
        }
    };
    var probe: Probe = .{ .rt = rt };
    const t = try std.Thread.spawn(.{}, Probe.run, .{&probe});
    t.join();
    try std.testing.expect(probe.inside);
    try std.testing.expect(!probe.outside);
}

test "child runtime inherits an independent, owned copy of the policy" {
    const parent = asap.nox_runtime_init_with_allocator(std.testing.allocator) orelse return error.InitFailed;
    const ps: *asap.RuntimeState = @ptrCast(@alignCast(parent));
    ps.embed_active = true;
    ps.embed_roots[0] = "/app/documents";
    ps.embed_roots[1] = "/app/cache";

    var policy = try asap.snapshotEmbedPolicy(parent, std.testing.allocator);
    const child = asap.nox_runtime_init_with_allocator(std.testing.allocator) orelse return error.InitFailed;
    asap.adoptEmbedPolicy(child, &policy);

    // Ebeveyn yok edildikten sonra bile çocuğun politikası geçerli kalır (kendi kopyası var).
    asap.nox_runtime_deinit(parent);
    try std.testing.expect(allowsPath(child, "/app/documents/a.txt"));
    try std.testing.expect(allowsPath(child, "/app/cache/b"));
    try std.testing.expect(!allowsPath(child, "/app/other"));
    asap.nox_runtime_deinit(child); // testing.allocator sızıntı yakalar: sahip olunan kökler serbest kalmalı
}

test "child of a non-embedded runtime stays unrestricted and allocates nothing" {
    const parent = asap.nox_runtime_init_with_allocator(std.testing.allocator) orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(parent);
    var policy = try asap.snapshotEmbedPolicy(parent, std.testing.allocator);
    try std.testing.expect(!policy.active);
    const child = asap.nox_runtime_init_with_allocator(std.testing.allocator) orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(child);
    asap.adoptEmbedPolicy(child, &policy);
    try std.testing.expect(allowsPath(child, "/anywhere/at/all"));
}

test "an unadopted policy snapshot can be released without leaking" {
    const parent = asap.nox_runtime_init_with_allocator(std.testing.allocator) orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(parent);
    const ps: *asap.RuntimeState = @ptrCast(@alignCast(parent));
    ps.embed_active = true;
    ps.embed_roots[2] = "/app/support";
    var policy = try asap.snapshotEmbedPolicy(parent, std.testing.allocator);
    asap.freeEmbedPolicy(&policy, std.testing.allocator);
    try std.testing.expect(!policy.active);
}

test "embed rejects a second create, reentry, and a double destroy" {
    const allocator = std.testing.allocator;
    var slot = Slot{ .abi_version = ABI, .app = null };
    const config = sampleConfig(&slot, "/app/documents");
    var out: ?*anyopaque = null;
    try std.testing.expectEqual(OK, createWith(allocator, &config, &out));
    var again: ?*anyopaque = null;
    try std.testing.expectEqual(ERR_EXISTS, createWith(allocator, &config, &again));
    const Nested = struct {
        var slot_holder: ?*anyopaque = null;
        var saw: i32 = 0;
        var reentered: i32 = 0;
        fn entry(rt: ?*anyopaque) callconv(.c) void {
            _ = rt;
            reentered = nox_app_start(slot_holder);
            reentered += nox_app_pump(slot_holder, 0);
        }
        fn onEvent(rt: ?*anyopaque, kind: i32, bytes: [*]const u8, len: u32) callconv(.c) void {
            _ = rt;
            _ = bytes;
            _ = len;
            if (saw == 0) saw = kind;
            reentered += nox_app_pump(slot_holder, 0);
        }
    };
    Nested.slot_holder = out;
    nox_app_set_entry(out, Nested.entry);
    nox_app_set_event_fn(out, Nested.onEvent);
    try std.testing.expectEqual(OK, nox_app_start(out));
    try std.testing.expect(Nested.reentered < 0);
    try std.testing.expectEqual(OK, nox_app_post_event(out, 7, "merhaba", 7));
    try std.testing.expectEqual(ERR_UTF8, nox_app_post_event(out, 1, "\xff", 1));
    const n = nox_app_pump(out, 0);
    try std.testing.expect(n >= 1);
    try std.testing.expectEqual(@as(i32, 7), Nested.saw);
    try std.testing.expectEqual(OK, nox_app_request_stop(out));
    try std.testing.expectEqual(ERR_STATE, nox_app_post_event(out, 1, "x", 1));
    try std.testing.expectEqual(OK, nox_app_destroy(slot.app));
    try std.testing.expectEqual(OK, nox_app_destroy(slot.app));
    try std.testing.expect(slot.app == null);
}

test "embed create start stop destroy ten thousand times" {
    const allocator = std.testing.allocator;
    var i: usize = 0;
    while (i < 10_000) : (i += 1) {
        var slot = Slot{ .abi_version = ABI, .app = null };
        const config = sampleConfig(&slot, "/app/documents");
        var out: ?*anyopaque = null;
        try std.testing.expectEqual(OK, createWith(allocator, &config, &out));
        try std.testing.expectEqual(OK, nox_app_start(out));
        try std.testing.expectEqual(OK, nox_app_request_stop(out));
        try std.testing.expectEqual(OK, nox_app_destroy(slot.app));
        try std.testing.expectEqual(OK, nox_app_destroy(slot.app));
    }
}

fn raisingEntry(rt: ?*anyopaque) callconv(.c) void {
    errors_handle.nox_raise(rt, @ptrFromInt(0x1000), 7);
}

var delivered_kinds: [8]i32 = undefined;
var delivered_count: usize = 0;

fn recordingEvent(rt: ?*anyopaque, kind: i32, bytes: [*]const u8, len: u32) callconv(.c) void {
    _ = bytes;
    _ = len;
    _ = rt;
    delivered_kinds[delivered_count] = kind;
    delivered_count += 1;
}

fn raiseOnSecondEvent(rt: ?*anyopaque, kind: i32, bytes: [*]const u8, len: u32) callconv(.c) void {
    recordingEvent(rt, kind, bytes, len);
    if (delivered_count == 2) errors_handle.nox_raise(rt, @ptrFromInt(0x2000), 9);
}

test "giriş noktasından kaçan Nox istisnası start'ta ERR_EXCEPTION olur; nesne bekleyen kalır ve alınabilir" {
    var slot: Slot = .{ .abi_version = ABI, .app = null };
    const config = sampleConfig(&slot, "/app/documents");
    var out: ?*anyopaque = null;
    try std.testing.expectEqual(OK, createWith(std.testing.allocator, &config, &out));
    nox_app_set_entry(out, raisingEntry);
    try std.testing.expectEqual(ERR_EXCEPTION, nox_app_start(out));
    const rt = nox_app_runtime(out);
    try std.testing.expectEqual(@as(i32, 1), errors_handle.nox_exception_pending(rt));
    try std.testing.expect(errors_handle.nox_exception_take(rt) == @as(?*anyopaque, @ptrFromInt(0x1000)));
    try std.testing.expectEqual(@as(i32, 0), errors_handle.nox_exception_pending(rt));
    // Uygulama başlamış sayılır: olay kabul eder.
    try std.testing.expectEqual(OK, nox_app_post_event(out, 1, null, 0));
    try std.testing.expectEqual(OK, nox_app_destroy(out));
}

test "olay işleyicisi istisna bırakırsa pump durur (ERR_EXCEPTION), kalan olaylar kuyrukta kalır" {
    var slot: Slot = .{ .abi_version = ABI, .app = null };
    const config = sampleConfig(&slot, "/app/documents");
    var out: ?*anyopaque = null;
    try std.testing.expectEqual(OK, createWith(std.testing.allocator, &config, &out));
    nox_app_set_event_fn(out, raiseOnSecondEvent);
    try std.testing.expectEqual(OK, nox_app_start(out));
    delivered_count = 0;
    for ([_]i32{ 10, 11, 12 }) |kind| try std.testing.expectEqual(OK, nox_app_post_event(out, kind, null, 0));

    try std.testing.expectEqual(ERR_EXCEPTION, nox_app_pump(out, 0));
    try std.testing.expectEqual(@as(usize, 2), delivered_count);
    try std.testing.expectEqual(@as(i32, 11), delivered_kinds[1]);
    const rt = nox_app_runtime(out);
    try std.testing.expect(errors_handle.nox_exception_take(rt) == @as(?*anyopaque, @ptrFromInt(0x2000)));

    // Host istisnayı aldıktan sonra kalan olay (12) teslim edilir.
    nox_app_set_event_fn(out, recordingEvent);
    try std.testing.expectEqual(@as(i32, 1), nox_app_pump(out, 0));
    try std.testing.expectEqual(@as(i32, 12), delivered_kinds[2]);
    try std.testing.expectEqual(OK, nox_app_destroy(out));
}

test "dolu kuyrukta post_event ERR_FULL döner ve durdurulmuş uygulamada ERR_STATE" {
    var slot: Slot = .{ .abi_version = ABI, .app = null };
    const config = sampleConfig(&slot, "/app/documents");
    var out: ?*anyopaque = null;
    try std.testing.expectEqual(OK, createWith(std.testing.allocator, &config, &out));
    try std.testing.expectEqual(OK, nox_app_start(out));
    var i: u32 = 0;
    while (i < EVENT_CAP) : (i += 1) try std.testing.expectEqual(OK, nox_app_post_event(out, 1, null, 0));
    try std.testing.expectEqual(ERR_FULL, nox_app_post_event(out, 1, null, 0));
    try std.testing.expectEqual(OK, nox_app_request_stop(out));
    try std.testing.expectEqual(ERR_STATE, nox_app_post_event(out, 1, null, 0)); // durdurulduktan sonra
    try std.testing.expectEqual(ERR_STATE, nox_app_pump(out, 0));
    try std.testing.expectEqual(OK, nox_app_destroy(out));
}

test "create bellek yetersizliğinde ERR_NOMEM döner ve slota dokunmaz; start başarısızlığı yeniden denenebilir" {
    var slot: Slot = .{ .abi_version = ABI, .app = null };
    const config = sampleConfig(&slot, "/app/documents");
    var out: ?*anyopaque = null;
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectEqual(ERR_NOMEM, createWith(failing.allocator(), &config, &out));
    try std.testing.expect(slot.app == null and out == null);

    // Kısmi başlatma: host ayırıcısı önce başarısız olur, sonra düzelir.
    var host: TrackingHost = .{ .fail = true };
    const descriptor = host.descriptor();
    var cfg2 = sampleConfig(&slot, "/app/documents");
    cfg2.allocator = &descriptor;
    try std.testing.expectEqual(OK, createWith(std.testing.allocator, &cfg2, &out));
    try std.testing.expectEqual(ERR_NOMEM, nox_app_start(out));
    host.fail = false;
    try std.testing.expectEqual(OK, nox_app_start(out)); // state hâlâ created
    try std.testing.expectEqual(OK, nox_app_destroy(out));
    try std.testing.expectEqual(@as(usize, 0), host.live);
}

test "sembolik bağ ile kökten kaçış reddedilir, kök içi ve henüz olmayan dosyalar kabul edilir" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.createDir(io, "root", .default_dir);
    try tmp.dir.createDir(io, "outside", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "outside/secret.txt", .data = "x" });
    try tmp.dir.writeFile(io, .{ .sub_path = "root/inside.txt", .data = "x" });
    try tmp.dir.symLink(io, "../outside", "root/escape", .{ .is_directory = true });
    var base_buf: [std.posix.PATH_MAX]u8 = undefined;
    const base_len = try tmp.dir.realPath(io, &base_buf);
    const base = base_buf[0..base_len];

    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);
    const state: *asap.RuntimeState = @ptrCast(@alignCast(rt));
    var root_z: [std.posix.PATH_MAX]u8 = undefined;
    const root = try std.fmt.bufPrintZ(&root_z, "{s}/root", .{base});
    state.embed_active = true;
    state.embed_roots[0] = root.ptr;
    defer state.embed_active = false;

    var p: [std.posix.PATH_MAX]u8 = undefined;
    const inside = try std.fmt.bufPrintZ(&p, "{s}/root/inside.txt", .{base});
    try std.testing.expect(allowsPath(rt, inside.ptr));
    const missing = try std.fmt.bufPrintZ(&p, "{s}/root/yeni/dosya.txt", .{base});
    try std.testing.expect(allowsPath(rt, missing.ptr)); // henüz olmayan hedef: önek kök altında
    const via_link = try std.fmt.bufPrintZ(&p, "{s}/root/escape/secret.txt", .{base});
    try std.testing.expect(!allowsPath(rt, via_link.ptr)); // bağ kökün dışına çıkıyor
    const link_dir = try std.fmt.bufPrintZ(&p, "{s}/root/escape", .{base});
    try std.testing.expect(!allowsPath(rt, link_dir.ptr));
    const via_missing_under_link = try std.fmt.bufPrintZ(&p, "{s}/root/escape/olmayan/x.txt", .{base});
    try std.testing.expect(!allowsPath(rt, via_missing_under_link.ptr));
}

test "fuzz: rastgele çağrı dizileri ve bozuk girdiler çökertmez, durum makinesi tutarlı kalır (TODO 7.5)" {
    var prng = std.Random.DefaultPrng.init(0x4e6f78);
    const rand = prng.random();
    var host: TrackingHost = .{};
    const descriptor = host.descriptor();
    var round: usize = 0;
    while (round < 300) : (round += 1) {
        var slot: Slot = .{ .abi_version = ABI, .app = null };
        var config = sampleConfig(&slot, "/app/documents");
        // Bazı turlarda bozuk yapılandırma: yanlış boyut/sürüm, null slot, bozuk ayırıcı tanımı.
        var bad_alloc: HostAllocator = .{ .size = rand.int(u32), .ctx = null, .alloc = null, .free = null };
        switch (rand.uintLessThan(u8, 8)) {
            0 => config.size = rand.int(u32),
            1 => config.abi_version = rand.int(u32),
            2 => config.slot = null,
            3 => config.allocator = &bad_alloc,
            4 => config.allocator = &descriptor,
            else => {},
        }
        var out: ?*anyopaque = null;
        const rc = createWith(std.testing.allocator, &config, &out);
        if (rc != OK) {
            try std.testing.expect(slot.app == null);
            try std.testing.expect(out == null);
            continue;
        }
        const app = out;
        var step: usize = 0;
        while (step < 40) : (step += 1) {
            switch (rand.uintLessThan(u8, 7)) {
                0 => _ = nox_app_start(app),
                1 => {
                    // Rastgele uzunluk ve içerik: sınır (256), bozuk UTF-8, null işaretçi ile sıfırdan farklı uzunluk.
                    var bytes: [300]u8 = undefined;
                    rand.bytes(&bytes);
                    const len: u32 = rand.uintLessThan(u32, 320);
                    const ptr: ?[*]const u8 = if (rand.boolean()) &bytes else null;
                    const r = nox_app_post_event(app, rand.int(i32), ptr, len);
                    try std.testing.expect(r == OK or r == ERR_STATE or r == ERR_INVAL or r == ERR_UTF8 or r == ERR_FULL);
                },
                2 => {
                    const r = nox_app_pump(app, if (rand.boolean()) 0 else rand.int(u64));
                    try std.testing.expect(r >= 0 or r == ERR_STATE or r == ERR_REENTRANT or r == ERR_EXCEPTION);
                },
                3 => _ = nox_app_request_stop(app),
                4 => _ = nox_app_runtime(app),
                5 => nox_app_set_event_fn(app, if (rand.boolean()) recordingEvent else null),
                else => {},
            }
        }
        // Her durumda destroy başarılı olmalı, ikinci destroy güvenli kalmalı, slot boşalmalı.
        try std.testing.expectEqual(OK, nox_app_destroy(app));
        try std.testing.expect(slot.app == null);
    }
    try std.testing.expectEqual(@as(usize, 0), host.live);
    // null uygulama işaretçisiyle hiçbir giriş noktası çökmez.
    try std.testing.expectEqual(ERR_STATE, nox_app_start(null));
    try std.testing.expectEqual(ERR_STATE, nox_app_pump(null, 0));
    try std.testing.expectEqual(ERR_STATE, nox_app_post_event(null, 0, null, 0));
    try std.testing.expectEqual(OK, nox_app_destroy(null));
    try std.testing.expect(nox_app_runtime(null) == null);
}
