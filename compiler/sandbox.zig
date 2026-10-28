//! `noxc run --sandbox` (TODO 7.2/7.3, ADR-010): güvenilmeyen Nox kaynağını işletim sistemi düzeyinde kısıtlanmış bir süreçte çalıştırır.
//!
//! Derleme güvenilirdir (kullanıcı kodu çalıştırmaz); kısıtlama ÜRETİLEN ikilinin ÇALIŞMASINA uygulanır. Varsayılan: ağ YOK, yazma
//! yalnızca geçici dizinde, okuma sistem kitaplıkları + çalışma dizini + ikilinin dizini. `extern def` ve `lowlevel` dahil tüm yerel kod
//! aynı kısıtın içindedir; sandbox Nox'un tip/sahiplik garantilerini DEĞİL, işletim sistemi yetkisini sınırlar. macOS: `sandbox-exec`
//! (SBPL profili). Linux: `bwrap` (bubblewrap) varsa. Windows: desteklenmez.

const std = @import("std");
const builtin = @import("builtin");

pub const Policy = struct {
    allow_net: bool = false,
    allow_write: []const []const u8 = &.{},
    allow_read: []const []const u8 = &.{},
};

pub const Error = error{ Unsupported, MissingTool, OutOfMemory, InvalidPath };

/// SBPL/komut satırına gömülecek yolda tırnak ve ters bölü olmamalı (profil enjeksiyonu).
fn checkPath(p: []const u8) Error!void {
    if (p.len == 0 or p[0] != '/') return error.InvalidPath;
    for (p) |c| if (c == '"' or c == '\\' or c == 0 or c == '\n' or c == ')' or c == '(') return error.InvalidPath;
}

pub fn macosProfile(a: std.mem.Allocator, bin_dir: []const u8, cwd: []const u8, tmp: []const u8, policy: Policy) Error![]const u8 {
    try checkPath(bin_dir);
    try checkPath(cwd);
    try checkPath(tmp);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    try out.appendSlice(a, "(version 1)\n(deny default)\n");
    try out.appendSlice(a, "(allow process-exec)\n(allow process-fork)\n(allow sysctl-read)\n(allow signal (target self))\n(allow mach-lookup)\n(allow ipc-posix-shm)\n");
    // Okuma: sistem kitaplıkları, çalışma dizini, ikilinin dizini, geçici dizin ve izinli yollar. Kullanıcı dosyaları (ev dizini) varsayılan kapalıdır.
    try out.appendSlice(a, "(allow file-read* (literal \"/\") (subpath \"/usr\") (subpath \"/bin\") (subpath \"/sbin\") (subpath \"/System\") (subpath \"/Library\") (subpath \"/dev\") (subpath \"/private/var/db\") (subpath \"/private/etc/localtime\") (subpath \"/var/db\"))\n");
    try out.appendSlice(a, try std.fmt.allocPrint(a, "(allow file-read* (subpath \"{s}\") (subpath \"{s}\") (subpath \"{s}\"))\n", .{ bin_dir, cwd, tmp }));
    for (policy.allow_read) |p| {
        try checkPath(p);
        try out.appendSlice(a, try std.fmt.allocPrint(a, "(allow file-read* (subpath \"{s}\"))\n", .{p}));
    }
    // Yazma: yalnızca geçici dizin ve izinli yollar; /dev/null ve tty için sınırlı.
    try out.appendSlice(a, "(allow file-write* (literal \"/dev/null\") (literal \"/dev/dtracehelper\") (regex #\"^/dev/tty\"))\n");
    try out.appendSlice(a, try std.fmt.allocPrint(a, "(allow file-write* (subpath \"{s}\"))\n", .{tmp}));
    for (policy.allow_write) |p| {
        try checkPath(p);
        try out.appendSlice(a, try std.fmt.allocPrint(a, "(allow file-read* file-write* (subpath \"{s}\"))\n", .{p}));
    }
    if (policy.allow_net) try out.appendSlice(a, "(allow network*)\n(allow system-socket)\n");
    return out.toOwnedSlice(a);
}

/// Sandbox içinde çalışacak komutun argv'sini kurar (saf fonksiyon: test edilebilir).
pub fn buildArgv(a: std.mem.Allocator, os: std.Target.Os.Tag, bin_path: []const u8, argv_tail: []const []const u8, cwd: []const u8, tmp: []const u8, policy: Policy) Error![]const []const u8 {
    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    switch (os) {
        .macos => {
            const bin_dir = std.fs.path.dirname(bin_path) orelse return error.InvalidPath;
            const profile = try macosProfile(a, bin_dir, cwd, tmp, policy);
            try argv.appendSlice(a, &.{ "sandbox-exec", "-p", profile });
            // Ağ kapalıyken çalışma zamanına bildir (temiz hata için; bkz. `http_client.networkDenied`).
            if (!policy.allow_net) try argv.appendSlice(a, &.{ "/usr/bin/env", "NOX_SANDBOX_NO_NET=1" });
            try argv.append(a, bin_path);
        },
        .linux => {
            try argv.appendSlice(a, &.{ "bwrap", "--ro-bind", "/", "/", "--dev", "/dev", "--proc", "/proc", "--tmpfs", "/tmp", "--die-with-parent", "--new-session" });
            if (!policy.allow_net) try argv.appendSlice(a, &.{ "--unshare-net", "--setenv", "NOX_SANDBOX_NO_NET", "1" });
            for (policy.allow_write) |p| {
                try checkPath(p);
                try argv.appendSlice(a, &.{ "--bind", p, p });
            }
            try argv.appendSlice(a, &.{ "--", bin_path });
        },
        else => return error.Unsupported,
    }
    try argv.appendSlice(a, argv_tail);
    return argv.toOwnedSlice(a);
}

test "macOS profili ağı varsayılan kapatır, --allow-net açar, yazmayı geçici dizinle sınırlar" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const closed = try macosProfile(a, "/cache/bin", "/work", "/private/tmp", .{});
    try std.testing.expect(std.mem.indexOf(u8, closed, "(deny default)") != null);
    try std.testing.expect(std.mem.indexOf(u8, closed, "network") == null);
    try std.testing.expect(std.mem.indexOf(u8, closed, "(allow file-write* (subpath \"/private/tmp\"))") != null);
    try std.testing.expect(std.mem.indexOf(u8, closed, "/Users") == null);
    const open = try macosProfile(a, "/cache/bin", "/work", "/private/tmp", .{ .allow_net = true, .allow_write = &.{"/data/out"} });
    try std.testing.expect(std.mem.indexOf(u8, open, "(allow network*)") != null);
    try std.testing.expect(std.mem.indexOf(u8, open, "file-write* (subpath \"/data/out\")") != null);
}

test "yol enjeksiyonu reddedilir" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectError(error.InvalidPath, macosProfile(a, "/ok", "/w\"x", "/t", .{}));
    try std.testing.expectError(error.InvalidPath, macosProfile(a, "/ok", "/w", "/t", .{ .allow_write = &.{"rel/path"} }));
    try std.testing.expectError(error.InvalidPath, macosProfile(a, "/ok", "/w", "/t", .{ .allow_read = &.{"/a)(allow default"} }));
}

test "linux argv: ağ varsayılan ayrılır, --allow-net paylaşır, yazma bağlanır; windows desteklenmez" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const closed = try buildArgv(a, .linux, "/b/prog", &.{"x"}, "/w", "/tmp", .{});
    try std.testing.expectEqualStrings("bwrap", closed[0]);
    var has_unshare = false;
    for (closed) |s| if (std.mem.eql(u8, s, "--unshare-net")) {
        has_unshare = true;
    };
    try std.testing.expect(has_unshare);
    try std.testing.expectEqualStrings("x", closed[closed.len - 1]);
    const open = try buildArgv(a, .linux, "/b/prog", &.{}, "/w", "/tmp", .{ .allow_net = true, .allow_write = &.{"/out"} });
    for (open) |s| try std.testing.expect(!std.mem.eql(u8, s, "--unshare-net"));
    try std.testing.expectError(error.Unsupported, buildArgv(a, .windows, "/b/prog", &.{}, "/w", "/tmp", .{}));
}
