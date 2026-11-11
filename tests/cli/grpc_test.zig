//! v2.1.33: `nox.grpc` GERÇEK bir gRPC sunucusuna (grpcio) karşı (`scripts/grpc_probe.py`): unary, sunucu/istemci akışı, hata durumu, üst veri/trailer, akış denetimi (300 KB istek,
//! 2 MB yanıt), bilinmeyen metot; iki arka uç. `python3` ya da `grpcio` yoksa atlanır (CI'da `pip install grpcio` ile çalışır).

const std = @import("std");
const builtin = @import("builtin");

test "grpc: unary, akis, hata, ust veri ve akis denetimi gercek sunucuda" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    const r = std.process.run(std.testing.allocator, io, .{
        .argv = &.{ "python3", "scripts/grpc_probe.py", "zig-out/bin/noxc" },
    }) catch return error.SkipZigTest; // python3 yok
    defer std.testing.allocator.free(r.stdout);
    defer std.testing.allocator.free(r.stderr);
    if (r.term == .exited and r.term.exited == 77) return error.SkipZigTest; // grpcio yok
    if (r.term != .exited or r.term.exited != 0) std.debug.print("grpc probu basarisiz: {s}{s}\n", .{ r.stdout, r.stderr });
    try std.testing.expect(r.term == .exited and r.term.exited == 0);
}

// v2.1.41: `nox.grpc_server` (Nox ile yazılmış gRPC sunucusu, `nox.http` üzerinde) GERÇEK bir grpcio istemcisine karşı (`scripts/grpc_server_probe.py`).
test "grpc_server: unary, akislar, hata durumu ve buyuk mesajlar grpcio istemcisine karsi" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    const r = std.process.run(std.testing.allocator, io, .{
        .argv = &.{ "python3", "scripts/grpc_server_probe.py", "zig-out/bin/noxc" },
    }) catch return error.SkipZigTest; // python3 yok
    defer std.testing.allocator.free(r.stdout);
    defer std.testing.allocator.free(r.stderr);
    if (r.term == .exited and r.term.exited == 77) return error.SkipZigTest; // grpcio yok
    if (r.term != .exited or r.term.exited != 0) std.debug.print("grpc sunucu probu basarisiz: {s}{s}\n", .{ r.stdout, r.stderr });
    try std.testing.expect(r.term == .exited and r.term.exited == 0);
}
