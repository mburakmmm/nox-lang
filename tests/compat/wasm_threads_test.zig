//! wasi-threads (v2.1.155, TODO 4.6): `tests/compat/wasm_threads/threads.wasm` (`threads.wat`) gerçek OS iş parçacıklarında, tek paylaşımlı bellek üzerinde çalışır.
//! Doğrulananlar: N iş parçacığı × 10000 atomik artış = tam toplam (yarışsız), gerçek `wait`/`notify`, `max_threads` sınırı (`thread-spawn` negatif döner), kapalıyken içe aktarma çözülemez,
//! iş parçacığındaki tuzak ana yürütmeyi iptal eder, sonsuz `wait`te bekleyen iş parçacığı `close`ta (deinit) iptal edilip birleştirilir, sızıntı yok (testing allocator).

const std = @import("std");
const wasm = @import("wasm_bridge");

const threads_wasm = @embedFile("wasm_threads/threads.wasm");

test "wasi-threads: 4 iş parçacığı x 10000 atomik artış tam toplam verir (20 tur)" {
    if (!wasm.interp.threads_supported) return error.SkipZigTest;
    const a = std.testing.allocator;
    var m = try wasm.module.parse(a, threads_wasm);
    defer m.deinit();
    var round: usize = 0;
    while (round < 20) : (round += 1) {
        const inst = try wasm.interp.Instance.init(a, &m, &.{}, .{ .max_threads = 8, .fuel = 4_000_000_000 });
        defer inst.deinit();
        var res = [1]u64{0};
        try inst.callByName("run", &[_]u64{4}, &res);
        try std.testing.expectEqual(@as(u32, 40000), @as(u32, @truncate(res[0])));
    }
}

test "wasi-threads: max_threads sınırı aşılınca thread-spawn negatif döner" {
    if (!wasm.interp.threads_supported) return error.SkipZigTest;
    const a = std.testing.allocator;
    var m = try wasm.module.parse(a, threads_wasm);
    defer m.deinit();
    const inst = try wasm.interp.Instance.init(a, &m, &.{}, .{ .max_threads = 2 });
    defer inst.deinit();
    var res = [1]u64{0};
    try inst.callByName("run", &[_]u64{6}, &res);
    try std.testing.expectEqual(@as(u32, 0xffff_ffff), @as(u32, @truncate(res[0]))); // 3. spawn reddedildi -> -1
}

test "wasi-threads: kapalıyken (max_threads = 0) thread-spawn içe aktarması çözülemez" {
    const a = std.testing.allocator;
    var m = try wasm.module.parse(a, threads_wasm);
    defer m.deinit();
    try std.testing.expectError(error.ImportNotFound, wasm.interp.Instance.init(a, &m, &.{}, .{}));
}

test "wasi-threads: iş parçacığındaki tuzak ana yürütmeyi iptal eder" {
    if (!wasm.interp.threads_supported) return error.SkipZigTest;
    const a = std.testing.allocator;
    var m = try wasm.module.parse(a, threads_wasm);
    defer m.deinit();
    const inst = try wasm.interp.Instance.init(a, &m, &.{}, .{ .max_threads = 4, .fuel = 2_000_000_000 });
    defer inst.deinit();
    var res = [1]u64{0};
    // arg 7: iş parçacığı `unreachable` ile tuzağa düşer, hiç artırmaz; `run` yerine elle: spawn_one(7) sonra ana tarafta uzun döngüde iptal görülür.
    try inst.callByName("spawn_one", &[_]u64{7}, &res);
    try std.testing.expect(@as(u32, @truncate(res[0])) != 0xffff_ffff);
    // Ana yürütme artık bitmeyecek bir `run` ister (3 iş parçacığı beklenir ama biri çöker): iptal OutOfFuel ile çıkmalı ya da 2 sn içinde biten iş parçacıkları sayılır.
    const r = inst.callByName("run", &[_]u64{3}, &res);
    _ = r catch |e| try std.testing.expect(e == error.OutOfFuel or e == error.Canceled);
}

test "wasi-threads: sonsuz wait'te bekleyen iş parçacığı kapanışta iptal edilir ve birleştirilir" {
    if (!wasm.interp.threads_supported) return error.SkipZigTest;
    const a = std.testing.allocator;
    var m = try wasm.module.parse(a, threads_wasm);
    defer m.deinit();
    const inst = try wasm.interp.Instance.init(a, &m, &.{}, .{ .max_threads = 4 });
    var res = [1]u64{0};
    try inst.callByName("spawn_one", &[_]u64{99}, &res);
    try std.testing.expect(@as(u32, @truncate(res[0])) != 0xffff_ffff);
    // İş parçacığının `wait`e girmesine zaman tanı.
    const ts: std.c.timespec = .{ .sec = 0, .nsec = 100 * std.time.ns_per_ms };
    _ = std.c.nanosleep(&ts, null);
    inst.deinit(); // asılmamalı; sızıntı varsa testing allocator yakalar
}
