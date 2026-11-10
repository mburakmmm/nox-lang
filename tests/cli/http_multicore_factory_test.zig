//! v2.1.20: `nox.http.serve_multicore(port, make_handler, n)` — işleyici FABRİKASI. Her worker fabrikayı kendi `RuntimeState`inde bir kez çağırır (worker başına durum; ana
//! çalışma zamanından closure geçirilemez). `scripts/http_factory_probe.py` iki arka uçta gerçek bir sunucu çalıştırır. python3 yoksa atlanır.

const std = @import("std");
const builtin = @import("builtin");

test "serve_multicore: fabrika her worker'da bir kez cagrilir, durum worker'a ozeldir" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    const r = std.process.run(std.testing.allocator, io, .{
        .argv = &.{ "python3", "scripts/http_factory_probe.py", "zig-out/bin/noxc" },
    }) catch return error.SkipZigTest; // python3 yok
    defer std.testing.allocator.free(r.stdout);
    defer std.testing.allocator.free(r.stderr);
    if (r.term != .exited or r.term.exited != 0) std.debug.print("fabrika probu basarisiz: {s}{s}\n", .{ r.stdout, r.stderr });
    try std.testing.expect(r.term == .exited and r.term.exited == 0);
}

// v2.1.32: `nox.http.configure(ip_family=...)` ile çok çekirdekli IPv6 dinleme (dual-stack ve yalnızca-IPv6, iki arka uç). IPv6 loopback ya da python3 yoksa atlanır.
test "serve_multicore: configure(ip_family) IPv6 dual-stack ve yalnizca-IPv6" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    const r = std.process.run(std.testing.allocator, io, .{
        .argv = &.{ "python3", "scripts/http_ipv6_probe.py", "zig-out/bin/noxc" },
    }) catch return error.SkipZigTest; // python3 yok
    defer std.testing.allocator.free(r.stdout);
    defer std.testing.allocator.free(r.stderr);
    if (r.term != .exited or r.term.exited != 0) std.debug.print("ipv6 probu basarisiz: {s}{s}\n", .{ r.stdout, r.stderr });
    try std.testing.expect(r.term == .exited and r.term.exited == 0);
}
