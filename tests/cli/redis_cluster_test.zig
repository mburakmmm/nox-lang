//! `nox.redis_cluster` gerçek 3 düğümlü Redis Cluster'a karşı (`scripts/redis_cluster_probe.py`): CRC16 yuva hesabı (`CLUSTER KEYSLOT` ile çapraz), yuvalar arası okuma/yazma, `-MOVED` ile bayat yuva tablosunun
//! düzelmesi, göç sürerken `-ASK`. İki arka uç. `redis-server`/`redis-cli`/python3 yoksa ya da küme kurulamazsa atlanır.

const std = @import("std");
const builtin = @import("builtin");

test "redis_cluster: yuva hesabi, MOVED ve ASK gercek kumede" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    const r = std.process.run(std.testing.allocator, io, .{
        .argv = &.{ "python3", "scripts/redis_cluster_probe.py", "zig-out/bin/noxc" },
    }) catch return error.SkipZigTest; // python3 yok
    defer std.testing.allocator.free(r.stdout);
    defer std.testing.allocator.free(r.stderr);
    if (r.term == .exited and r.term.exited == 77) return error.SkipZigTest; // redis-server/redis-cli yok ya da küme kurulamadı
    if (r.term != .exited or r.term.exited != 0) std.debug.print("redis cluster probu basarisiz: {s}{s}\n", .{ r.stdout, r.stderr });
    try std.testing.expect(r.term == .exited and r.term.exited == 0);
}
