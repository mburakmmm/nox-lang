//! v2.0.144 (spec §3.346): `--deny-capability <liste>` / `--deny-capability=<liste>` / `NOX_DENY_CAPABILITY` — herhangi bir hedefte, profilin sağladığı bir yeteneği
//! ELLE geri alır. Güvenilmeyen kodu derleyen ortamlar (playground) için: yetenek isteyen modül import'u ve `@capability.requires` çağrıları derleme
//! zamanında reddedilir. GERÇEK `noxc` alt süreciyle (`profile_test.zig`nin AYNI deseni).

const std = @import("std");

fn noxcPath() []const u8 {
    return "zig-out/bin/noxc";
}

fn writeTempSource(gpa: std.mem.Allocator, io: std.Io, source: []const u8, tmp: *std.testing.TmpDir) ![]const u8 {
    try tmp.dir.writeFile(io, .{ .sub_path = "prog.nox", .data = source });
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &path_buf);
    return std.fmt.allocPrint(gpa, "{s}/prog.nox", .{path_buf[0..len]});
}

const Run = struct { code: u8, stderr: []u8 };

fn runNoxc(gpa: std.mem.Allocator, io: std.Io, env_deny: ?[]const u8, argv_tail: []const []const u8) !Run {
    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.append(gpa, noxcPath());
    try argv.appendSlice(gpa, argv_tail);
    var env = try std.testing.environ.createMap(gpa);
    defer env.deinit();
    if (env_deny) |v| try env.put("NOX_DENY_CAPABILITY", v);
    const result = try std.process.run(gpa, io, .{ .argv = argv.items, .environ_map = &env });
    gpa.free(result.stdout);
    const code: u8 = if (result.term == .exited) result.term.exited else 255;
    return .{ .code = code, .stderr = result.stderr };
}

const net_program =
    \\import nox.http
    \\print(1)
    \\
;

test "noxc check --deny-capability net: ağ isteyen modül (nox.http) reddedilir, mesaj yeteneği ve bayrağı söyler" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try writeTempSource(gpa, io, net_program, &tmp);
    defer gpa.free(path);

    const denied = try runNoxc(gpa, io, null, &.{ "check", "--deny-capability", "net", path });
    defer gpa.free(denied.stderr);
    try std.testing.expectEqual(@as(u8, 1), denied.code);
    try std.testing.expect(std.mem.indexOf(u8, denied.stderr, "module 'nox.http' cannot be used") != null);
    try std.testing.expect(std.mem.indexOf(u8, denied.stderr, "'network' is denied (--deny-capability)") != null);

    // Yasak yokken aynı program geçer.
    const allowed = try runNoxc(gpa, io, null, &.{ "check", path });
    defer gpa.free(allowed.stderr);
    try std.testing.expectEqual(@as(u8, 0), allowed.code);
}

test "--deny-capability her yerde ve her biçimde çalışır: '=' biçimi, alt komuttan önce, NOX_DENY_CAPABILITY, takma adlar" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try writeTempSource(gpa, io, net_program, &tmp);
    defer gpa.free(path);

    const cases = [_]struct { env: ?[]const u8, argv: []const []const u8 }{
        .{ .env = null, .argv = &.{ "check", "--deny-capability=fs,net", path } },
        .{ .env = null, .argv = &.{ "--deny-capability", "network", "check", path } },
        .{ .env = "net", .argv = &.{ "check", path } },
        .{ .env = "filesystem, network", .argv = &.{ "check", path } },
    };
    for (cases) |c| {
        const r = try runNoxc(gpa, io, c.env, c.argv);
        defer gpa.free(r.stderr);
        if (r.code != 1 or std.mem.indexOf(u8, r.stderr, "is denied (--deny-capability)") == null) {
            std.debug.print("beklenen ret yok (env={?s}): {s}\n", .{ c.env, r.stderr });
            return error.DenyNotApplied;
        }
    }
}

test "--deny-capability: ilgisiz bir yasak programı etkilemez; bilinmeyen yetenek adı sessizce yok sayılmaz" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try writeTempSource(gpa, io, net_program, &tmp);
    defer gpa.free(path);

    // `fs` yasağı ağ modülünü engellemez.
    const unrelated = try runNoxc(gpa, io, null, &.{ "check", "--deny-capability", "fs", path });
    defer gpa.free(unrelated.stderr);
    try std.testing.expectEqual(@as(u8, 0), unrelated.code);

    // Yanlış yazılmış bir yasak güvenlik beklentisini boşa çıkarırdı: açık hata.
    const bogus = try runNoxc(gpa, io, null, &.{ "check", "--deny-capability", "netwrok", path });
    defer gpa.free(bogus.stderr);
    try std.testing.expectEqual(@as(u8, 1), bogus.code);
    try std.testing.expect(std.mem.indexOf(u8, bogus.stderr, "unknown capability") != null);
    try std.testing.expect(std.mem.indexOf(u8, bogus.stderr, "netwrok") != null);

    // Değer verilmemiş bayrak.
    const missing = try runNoxc(gpa, io, null, &.{ "check", path, "--deny-capability" });
    defer gpa.free(missing.stderr);
    try std.testing.expectEqual(@as(u8, 1), missing.code);
    try std.testing.expect(std.mem.indexOf(u8, missing.stderr, "expects") != null);
}

test "--deny-capability entropy: sembol düzeyinde @capability.requires çağrısı da reddedilir" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try writeTempSource(gpa, io,
        \\import nox.crypto
        \\print(nox.crypto.secure_random_hex(4))
        \\
    , &tmp);
    defer gpa.free(path);

    const denied = try runNoxc(gpa, io, null, &.{ "check", "--deny-capability", "entropy", path });
    defer gpa.free(denied.stderr);
    try std.testing.expectEqual(@as(u8, 1), denied.code);
    try std.testing.expect(std.mem.indexOf(u8, denied.stderr, "'entropy' is denied (--deny-capability)") != null);

    const allowed = try runNoxc(gpa, io, null, &.{ "check", path });
    defer gpa.free(allowed.stderr);
    try std.testing.expectEqual(@as(u8, 0), allowed.code);
}
