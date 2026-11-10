//! Ember NL-006/007: `nox.postgres` yapılandırılmış hatalar (SQLSTATE → `kind`), `statement_timeout`, `Transaction` koruması ve `Pool`
//! gerçek bir PostgreSQL sunucusuna karşı (`scripts/postgres_native_probe.py`, geçici küme). PostgreSQL/libpq/python3 yoksa atlanır.

const std = @import("std");
const builtin = @import("builtin");

test "postgres: SQLSTATE kind, statement_timeout, Transaction ve Pool gercek sunucuda" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    const r = std.process.run(std.testing.allocator, io, .{
        .argv = &.{ "python3", "scripts/postgres_native_probe.py", "zig-out/bin/noxc" },
    }) catch return error.SkipZigTest; // python3 yok
    defer std.testing.allocator.free(r.stdout);
    defer std.testing.allocator.free(r.stderr);
    if (r.term == .exited and r.term.exited == 77) return error.SkipZigTest; // PostgreSQL/libpq yok
    if (r.term != .exited or r.term.exited != 0) std.debug.print("postgres probu basarisiz: {s}{s}\n", .{ r.stdout, r.stderr });
    try std.testing.expect(r.term == .exited and r.term.exited == 0);
}
