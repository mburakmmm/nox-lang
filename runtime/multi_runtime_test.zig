//! Çoklu runtime izolasyon korpusu (TODO 1.5, AGENTS §2.6): aynı süreçte birden çok `RuntimeState` — farklı iş
//! parçacıklarında eşzamanlı dahil — birbirinin durumunu görmemelidir. Her runtime `std.testing.allocator` üzerinden
//! kurulur; bu yüzden sızıntı ve çift-serbest bırakma da denetlenir.
//!
//! Kapsam: allocator, bekleyen istisna, sözlük hash tohumu (entropi), gömme sandbox politikası, zamanlayıcı (fiber) durumu.
//! Bilinen sınır (global-state-audit.md, `tl-errno`): fiber DIŞINDAKİ kodda `last_op_ok()` ve stdin artığı iş parçacığı-
//! yereldir; aynı iş parçacığındaki iki runtime bunu paylaşır. Bu dosya o davranışı DOĞRULAMAZ, yalnızca belgelenir.

const std = @import("std");
const asap = @import("alloc/asap.zig");
const str_mod = @import("str.zig");
const dict_mod = @import("collections/dict.zig");
const errors = @import("errors/handle.zig");
const bridge = @import("async_rt/bridge.zig");
const embed = @import("embed.zig");

fn newRt() !*anyopaque {
    return asap.nox_runtime_init_with_allocator(std.testing.allocator) orelse error.InitFailed;
}

test "iki runtime: bir tanesindeki bekleyen istisna diğerini etkilemez" {
    const a = try newRt();
    defer asap.nox_runtime_deinit(a);
    const b = try newRt();
    defer asap.nox_runtime_deinit(b);

    errors.nox_raise(a, @ptrFromInt(0x10), 3);
    try std.testing.expectEqual(@as(i32, 1), errors.nox_exception_pending(a));
    try std.testing.expectEqual(@as(i32, 0), errors.nox_exception_pending(b));
    errors.nox_raise(b, @ptrFromInt(0x20), 4);
    try std.testing.expect(errors.nox_exception_take(a) == @as(?*anyopaque, @ptrFromInt(0x10)));
    try std.testing.expectEqual(@as(i32, 1), errors.nox_exception_pending(b));
    try std.testing.expect(errors.nox_exception_take(b) == @as(?*anyopaque, @ptrFromInt(0x20)));
}

test "iki runtime: sözlük hash tohumu runtime başınadır ve bağımsızdır" {
    const a = try newRt();
    defer asap.nox_runtime_deinit(a);
    const b = try newRt();
    defer asap.nox_runtime_deinit(b);

    inline for (.{ a, b }) |rt| {
        const d = dict_mod.nox_dict_new(rt, 1) orelse return error.NewFailed;
        // Küçük sözlükler karma indeks kurmaz; tohum, indeks kurulunca çekilir: yeterince çok anahtar ekle.
        var i: usize = 0;
        while (i < 64) : (i += 1) {
            var kb: [16]u8 = undefined;
            const kt = std.fmt.bufPrint(&kb, "k{d}", .{i}) catch unreachable;
            const key = str_mod.nox_str_from_bytes(rt, kt) orelse return error.AllocFailed;
            const value = str_mod.nox_str_from_bytes(rt, "v") orelse return error.AllocFailed;
            dict_mod.nox_dict_set(rt, d, 1, 1, 0, @bitCast(@intFromPtr(key)), @bitCast(@intFromPtr(value)));
        }
        dict_mod.nox_dict_release(rt, d, 1, 1, 0);
    }
    const sa: *asap.RuntimeState = @ptrCast(@alignCast(a));
    const sb: *asap.RuntimeState = @ptrCast(@alignCast(b));
    try std.testing.expect(sa.dict_hash_seed_init and sb.dict_hash_seed_init);
    // 2^-64 olasılıkla eşit: farklı tohum, aynı süreçte bile ayrı entropi çekimi demektir.
    try std.testing.expect(sa.dict_hash_seed != sb.dict_hash_seed);
}

test "iki runtime: sandbox politikası runtime başınadır" {
    const a = try newRt();
    defer asap.nox_runtime_deinit(a);
    const b = try newRt();
    defer asap.nox_runtime_deinit(b);
    const sa: *asap.RuntimeState = @ptrCast(@alignCast(a));
    sa.embed_active = true;
    sa.embed_roots[0] = "/app-a";

    try std.testing.expect(embed.allowsPath(a, "/app-a/x"));
    try std.testing.expect(!embed.allowsPath(a, "/app-b/x"));
    try std.testing.expect(embed.allowsPath(b, "/herhangi/yer")); // b gömme dışı: kısıtsız
    sa.embed_active = false;
}

const Worker = struct {
    id: usize,
    rounds: usize,
    failed: std.atomic.Value(bool) = .init(false),

    fn run(self: *Worker) void {
        const rt = asap.nox_runtime_init_with_allocator(std.testing.allocator) orelse {
            self.failed.store(true, .release);
            return;
        };
        defer asap.nox_runtime_deinit(rt);
        const state: *asap.RuntimeState = @ptrCast(@alignCast(rt));
        // Bu iş parçacığına özgü bir politika kökü: başka iş parçacığının kökünü görürsek izolasyon bozulmuştur.
        var root_buf: [32:0]u8 = undefined;
        const root = std.fmt.bufPrintZ(&root_buf, "/worker-{d}", .{self.id}) catch unreachable;
        state.embed_active = true;
        state.embed_roots[0] = root.ptr;
        defer state.embed_active = false;

        var i: usize = 0;
        while (i < self.rounds) : (i += 1) {
            var text_buf: [48]u8 = undefined;
            const text = std.fmt.bufPrint(&text_buf, "w{d}-r{d}", .{ self.id, i }) catch unreachable;
            const s = str_mod.nox_str_from_bytes(rt, text) orelse {
                self.failed.store(true, .release);
                return;
            };
            if (!std.mem.eql(u8, std.mem.span(s), text)) self.failed.store(true, .release);
            str_mod.nox_str_release(rt, s);

            errors.nox_raise(rt, @ptrFromInt(0x1000 + self.id), @intCast(i));
            if (errors.nox_exception_pending(rt) != 1) self.failed.store(true, .release);
            if (errors.nox_exception_take(rt) != @as(?*anyopaque, @ptrFromInt(0x1000 + self.id))) self.failed.store(true, .release);

            var path_buf: [64:0]u8 = undefined;
            const own = std.fmt.bufPrintZ(&path_buf, "{s}/f", .{root}) catch unreachable;
            if (!embed.allowsPath(rt, own.ptr)) self.failed.store(true, .release);
            var other_buf: [64:0]u8 = undefined;
            const other = std.fmt.bufPrintZ(&other_buf, "/worker-{d}/f", .{self.id + 1}) catch unreachable;
            if (embed.allowsPath(rt, other.ptr)) self.failed.store(true, .release);
        }
    }
};

test "çok iş parçacığı: her biri kendi runtime'ında str/istisna/sandbox döngüsü, çapraz bulaşma yok" {
    var workers: [4]Worker = undefined;
    var threads: [4]std.Thread = undefined;
    for (&workers, 0..) |*w, i| w.* = .{ .id = i, .rounds = 300 };
    for (&threads, 0..) |*t, i| t.* = try std.Thread.spawn(.{}, Worker.run, .{&workers[i]});
    for (threads) |t| t.join();
    for (&workers) |*w| try std.testing.expect(!w.failed.load(.acquire));
}

fn doubleEntry(arg: *anyopaque) callconv(.c) i64 {
    const v: *i64 = @ptrCast(@alignCast(arg));
    return v.* * 2;
}

const SchedWorker = struct {
    input: i64,
    result: i64 = -1,

    fn run(self: *SchedWorker) void {
        const rt = asap.nox_runtime_init_with_allocator(std.testing.allocator) orelse return;
        defer asap.nox_runtime_deinit(rt);
        bridge.nox_async_init(rt);
        defer bridge.nox_async_deinit(rt);
        var value = self.input;
        const task = bridge.nox_async_spawn(rt, doubleEntry, &value) orelse return;
        _ = bridge.nox_async_run_to_completion(rt);
        self.result = bridge.nox_async_await(rt, task);
        bridge.nox_async_destroy_task(rt, task);
    }
};

test "çok iş parçacığı: her runtime'ın zamanlayıcısı bağımsız çalışır (fiber durumu karışmaz)" {
    var workers: [3]SchedWorker = .{ .{ .input = 10 }, .{ .input = 20 }, .{ .input = 30 } };
    var threads: [3]std.Thread = undefined;
    for (&threads, 0..) |*t, i| t.* = try std.Thread.spawn(.{}, SchedWorker.run, .{&workers[i]});
    for (threads) |t| t.join();
    try std.testing.expectEqual(@as(i64, 20), workers[0].result);
    try std.testing.expectEqual(@as(i64, 40), workers[1].result);
    try std.testing.expectEqual(@as(i64, 60), workers[2].result);
}
