//! Mobil gömme ABI'si (`include/nox_embed.h`). NNI'den ayrıdır.
//! Host bir `NoxEmbedSlot` sahiplenir. İkinci `create` aynı slotta
//! `ERR_EXISTS` döner. Süreç genelinde gizli bir uygulama yok.

const std = @import("std");
const builtin = @import("builtin");
const asap = @import("alloc/asap.zig");

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

pub const ABI: i32 = 1;
const EVENT_CAP: u32 = 64;
const EVENT_BYTES: usize = 256;

pub const Slot = extern struct {
    abi_version: i32,
    app: ?*anyopaque,
};

pub const HostConfig = extern struct {
    size: u32,
    abi_version: u32,
    slot: ?*Slot,
    documents: ?[*:0]const u8,
    support: ?[*:0]const u8,
    cache: ?[*:0]const u8,
    temp_dir: ?[*:0]const u8,
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
    count: u32,
    head: u32,
    events: [EVENT_CAP]Event,
};

/// Sandbox kararı, çağıranın taşıdığı `rt`nin politikasına bakar (gizli/thread-local seçim YOK, AGENTS §2.6):
/// aynı süreçteki iki uygulama ve `nox.thread` çocukları birbirinin köklerini göremez. `rt == null`
/// yalnızca runtime'sız birim testleri içindir; derlenmiş programlar `with_rt` ile daima geçerli `rt` verir.
pub fn allowsPath(rt: ?*anyopaque, path: ?[*:0]const u8) bool {
    const state: *asap.RuntimeState = @ptrCast(@alignCast(rt orelse return true));
    if (!state.embed_active) return true;
    const raw = path orelse return false;
    return underRoots(state.embed_roots, std.mem.span(raw));
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
    if (cfg.size != @sizeOf(HostConfig) or cfg.abi_version != ABI) return ERR_VERSION;
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
        .count = 0,
        .head = 0,
        .events = undefined,
    };
    slot.app = app;
    out.?.* = app;
    return OK;
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
    const rt = asap.nox_runtime_init() orelse {
        return ERR_NOMEM;
    };
    app.rt = rt;
    app.state = .started;
    installRoots(app);
    if (app.entry) |entry| {
        app.in_user = true;
        entry(rt);
        app.in_user = false;
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
    if (app.count == EVENT_CAP) return ERR_STATE;
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
    };
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
