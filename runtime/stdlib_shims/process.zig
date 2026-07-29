//! `nox.process` Zig kabuğu — bkz. proje belleği "4 yeni stdlib modülü"
//! planı. `std.process.run` (Zig 0.16'nın `std.Io`-parametreli API'si,
//! `compiler/main.zig`nin qbe/cc/`noxc run` İçin KULLANDIĞI AYNI API)
//! ÜZERİNE kurulu — spawn+argv/cwd/timeout+stdout/stderr yakalama+wait
//! TEK bir çağrıda.
//!
//! **Fiber-uyumlu bekleme** (`http_client.zig`nin `doRequest`ıYLA
//! BİREBİR AYNI desen, bkz. onun belge notu): `std.process.run` GERÇEK
//! bir arka plan OS iş parçacığında (`std.Thread.spawn`) çalıştırılır —
//! ÇAĞIRAN taraf bir "tamamlanma pipe'ı" (self-pipe) üzerinden bekler,
//! bir Nox FIBER İÇİNDEYSEK `bridge.currentFiberScheduler`/`nonBlockingRead`
//! İLE (zamanlayıcıyı KİLİTLEMEDEN, BAŞKA fiber'lar İLERLEYEBİLİR),
//! DEĞİLSEK sıradan bloklayan bir `read()` İLE. `sharedClientIo()`
//! (`http_client.zig`) YENİDEN KULLANILIR — AYRI bir `std.Io.Threaded`
//! havuzu GEREKMEZ.
//!
//! **v1 kapsamı (bilinçli)**: SADECE `Command.run()`in TEK, bloklayan
//! (fiber-uyumlu) çağrısı — canlı bir `Process` tutamacı/`kill()`/stdin
//! STREAMING YOK (zaman aşımı DIŞINDA). Ortam değişkenleri İçin AYRI bir
//! `.env()` API'si de YOK — çocuk süreç zaten (`std.process.run`nin
//! `environ_map = null` varsayılanıyla) ebeveynin ortamını MİRAS ALIR,
//! bu yüzden `nox.os.set_var(...)` `Command(...).run()`DAN ÖNCE
//! çağrılması YETERLİDİR (AYRI bir mekanizma İCAT ETMEYE gerek YOK).
//!
//! `containsNul` — `http_client.zig`nin AYNI savunması (bkz. onun belge
//! notu): bir alt sürecin stdout/stderr'i GÖMÜLÜ bir NUL bayt İçerirse
//! (Nox string'leri NUL-sonlandırmalı OLDUĞUNDAN temsil EDİLEMEZ) `Output`
//! "başarısız" sayılır (`ok=false`) — TAMAMEN ikili/rastgele çıktı üreten
//! süreçler v1 kapsamı DIŞI, metin-tabanlı CLI araçları (git/ls/echo/...)
//! İçin sorun DEĞİL.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const asap = @import("../alloc/asap.zig");
const arc = @import("../alloc/arc.zig");
const http_client = @import("http_client.zig");
const bridge = @import("../async_rt/bridge.zig");
const io_mod = @import("../async_rt/io.zig");
const abi_layout = @import("abi_layout");
const str_mod = @import("../str.zig");

const dupeToNoxStr = http_client.dupeToNoxStr;
const LIST_HEADER_SIZE = abi_layout.LIST_HEADER_SIZE;
const FIELD_SLOT_SIZE = abi_layout.FIELD_SLOT_SIZE;

fn containsNul(s: []const u8) bool {
    return std.mem.indexOfScalar(u8, s, 0) != null;
}

/// `list[str]` argümanının HAM payload'ını (bkz. `strings.zig`nin
/// `nox_strings_join_raw`ıYLA AYNI düzen: [8 bayt count][8 baytlık
/// işaretçi yuvası]*count) okuyup HER elemanın KENDİ (ebeveynden
/// BAĞIMSIZ) bir kopyasını üretir — arka plan iş parçacığı çalışırken
/// orijinal Nox listesi serbest bırakılsa/değişse BİLE GÜVENLİDİR
/// (`http_client.zig`nin `copyHeaders`iYLE AYNI gerekçe).
fn copyStrList(gpa: std.mem.Allocator, list_ptr: ?*anyopaque) ![][:0]u8 {
    const bytes: [*]u8 = @ptrCast(list_ptr orelse return &.{});
    const count: usize = @intCast(@as(*align(1) i64, @ptrCast(bytes)).*);
    if (count == 0) return &.{};
    var out = try gpa.alloc([:0]u8, count);
    errdefer gpa.free(out);
    var i: usize = 0;
    errdefer for (out[0..i]) |s| gpa.free(s);
    while (i < count) : (i += 1) {
        const addr: usize = @bitCast(@as(*align(1) i64, @ptrCast(bytes + LIST_HEADER_SIZE + FIELD_SLOT_SIZE * i)).*);
        const p: [*:0]const u8 = @ptrFromInt(addr);
        out[i] = try gpa.dupeZ(u8, str_mod.nox_str_slice(p));
    }
    return out;
}

const RunCtx = struct {
    allocator: std.mem.Allocator,
    argv: [][:0]u8,
    cwd: ?[]u8,
    timeout_ms: i64,
    write_fd: posix.fd_t,

    ok: bool = false,
    status: i64 = -1,
    stdout: []u8 = &.{},
    stderr: []u8 = &.{},

    fn destroyOwned(self: *RunCtx) void {
        for (self.argv) |a| self.allocator.free(a);
        if (self.argv.len > 0) self.allocator.free(self.argv);
        if (self.cwd) |c| self.allocator.free(c);
        if (self.stdout.len > 0) self.allocator.free(self.stdout);
        if (self.stderr.len > 0) self.allocator.free(self.stderr);
    }
};

fn workerThreadFn(ctx: *RunCtx) void {
    const write_fd = ctx.write_fd;
    defer {
        http_client.signalSelfPipe(write_fd);
        http_client.closeFd(write_fd);
    }

    const io = http_client.sharedClientIo();

    var argv_view = ctx.allocator.alloc([]const u8, ctx.argv.len) catch {
        ctx.ok = false;
        return;
    };
    defer ctx.allocator.free(argv_view);
    for (ctx.argv, 0..) |a, i| argv_view[i] = a;

    const cwd: std.process.Child.Cwd = if (ctx.cwd) |c| .{ .path = c } else .inherit;
    const timeout: std.Io.Timeout = if (ctx.timeout_ms > 0)
        .{ .duration = .{ .raw = .{ .nanoseconds = @as(i96, ctx.timeout_ms) * std.time.ns_per_ms }, .clock = .awake } }
    else
        .none;

    const result = std.process.run(ctx.allocator, io, .{
        .argv = argv_view,
        .cwd = cwd,
        .timeout = timeout,
    }) catch {
        ctx.ok = false;
        return;
    };

    if (containsNul(result.stdout) or containsNul(result.stderr)) {
        ctx.allocator.free(result.stdout);
        ctx.allocator.free(result.stderr);
        ctx.ok = false;
        return;
    }

    ctx.status = switch (result.term) {
        .exited => |code| code,
        .signal, .stopped, .unknown => -1,
    };
    ctx.stdout = result.stdout;
    ctx.stderr = result.stderr;
    ctx.ok = true;
}

export fn nox_process_run_raw(
    rt: ?*anyopaque,
    program: ?[*:0]const u8,
    args: ?*anyopaque,
    cwd: ?[*:0]const u8,
    timeout_ms: i64,
) callconv(.c) ?*anyopaque {
    const state: *asap.RuntimeState = @ptrCast(@alignCast(rt orelse return null));
    const gpa = state.allocator();
    const prog = program orelse return null;

    const ctx = gpa.create(RunCtx) catch return null;
    errdefer gpa.destroy(ctx);

    const fds = http_client.makeSelfPipe() orelse return null;

    const extra_args = copyStrList(gpa, args) catch {
        http_client.closeFd(fds[0]);
        http_client.closeFd(fds[1]);
        return null;
    };
    var argv = gpa.alloc([:0]u8, extra_args.len + 1) catch {
        http_client.closeFd(fds[0]);
        http_client.closeFd(fds[1]);
        return null;
    };
    argv[0] = gpa.dupeZ(u8, str_mod.nox_str_slice(prog)) catch {
        gpa.free(argv);
        http_client.closeFd(fds[0]);
        http_client.closeFd(fds[1]);
        return null;
    };
    for (extra_args, 0..) |a, i| argv[i + 1] = a;
    if (extra_args.len > 0) gpa.free(extra_args);

    const cwd_copy: ?[]u8 = if (cwd) |c| blk: {
        const s = str_mod.nox_str_slice(c);
        break :blk if (s.len == 0) null else (gpa.dupe(u8, s) catch null);
    } else null;

    ctx.* = .{
        .allocator = gpa,
        .argv = argv,
        .cwd = cwd_copy,
        .timeout_ms = timeout_ms,
        .write_fd = fds[1],
    };

    const thread = std.Thread.spawn(.{}, workerThreadFn, .{ctx}) catch {
        ctx.destroyOwned();
        gpa.destroy(ctx);
        http_client.closeFd(fds[0]);
        http_client.closeFd(fds[1]);
        return null;
    };
    thread.detach();

    if (bridge.currentFiberScheduler()) |scheduler| {
        var buf: [1]u8 = undefined;
        _ = io_mod.nonBlockingRead(scheduler, fds[0], &buf) catch {};
    } else {
        var buf: [1]u8 = undefined;
        http_client.readSelfPipe(fds[0], &buf);
    }
    http_client.closeFd(fds[0]);

    return ctx;
}

export fn nox_process_output_ok_raw(h: ?*anyopaque) callconv(.c) i64 {
    const ctx: *RunCtx = @ptrCast(@alignCast(h orelse return 0));
    return if (ctx.ok) 1 else 0;
}

export fn nox_process_output_status_raw(h: ?*anyopaque) callconv(.c) i64 {
    const ctx: *RunCtx = @ptrCast(@alignCast(h orelse return -1));
    return ctx.status;
}

export fn nox_process_output_stdout_raw(rt: ?*anyopaque, h: ?*anyopaque) callconv(.c) ?[*:0]u8 {
    const ctx: *RunCtx = @ptrCast(@alignCast(h orelse return dupeToNoxStr(rt, "")));
    return dupeToNoxStr(rt, ctx.stdout);
}

export fn nox_process_output_stderr_raw(rt: ?*anyopaque, h: ?*anyopaque) callconv(.c) ?[*:0]u8 {
    const ctx: *RunCtx = @ptrCast(@alignCast(h orelse return dupeToNoxStr(rt, "")));
    return dupeToNoxStr(rt, ctx.stderr);
}

export fn nox_process_output_free_raw(h: ?*anyopaque) callconv(.c) void {
    const ctx: *RunCtx = @ptrCast(@alignCast(h orelse return));
    const gpa = ctx.allocator;
    ctx.destroyOwned();
    gpa.destroy(ctx);
}
