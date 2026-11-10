//! Ember NL-001: `nox.redis` gerçek `redis-server`'lara karşı (`scripts/redis_probe.py`): komutlar, ikili yük, Streams/tüketici grupları, betik + NOSCRIPT kurtarma,
//! AUTH/ACL, kopan bağlantı + `reconnect`. `redis-server`/python3 yoksa atlanır.

const std = @import("std");
const builtin = @import("builtin");

test "redis: komutlar, Streams, betik, AUTH/ACL ve reconnect gercek sunucuda" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    const r = std.process.run(std.testing.allocator, io, .{
        .argv = &.{ "python3", "scripts/redis_probe.py", "zig-out/bin/noxc" },
    }) catch return error.SkipZigTest; // python3 yok
    defer std.testing.allocator.free(r.stdout);
    defer std.testing.allocator.free(r.stderr);
    if (r.term == .exited and r.term.exited == 77) return error.SkipZigTest; // redis-server yok
    if (r.term != .exited or r.term.exited != 0) std.debug.print("redis probu basarisiz: {s}{s}\n", .{ r.stdout, r.stderr });
    try std.testing.expect(r.term == .exited and r.term.exited == 0);
}
