//! v2.0.175 (Faz 11.2, betik modu) uçtan-uca testi: `noxc run <betik.nox> a b` betik yolundan SONRAKİ her argümanı programa iletir (`--` isteğe bağlı kalır) ve
//! `#!/usr/bin/env -S noxc run` shebang'li bir betik doğrudan çalıştırılabilir. Eskiden `--` olmadan verilen argümanlar sessizce düşüyordu (`arg_count` 1 kalıyordu).
//! `$NOX_HOME`, `local_import_test.zig` ile aynı izolasyon desenidir.

const std = @import("std");
const builtin = @import("builtin");

fn absPath(io: std.Io, dir: std.Io.Dir, buf: []u8) ![]const u8 {
    const len = try dir.realPath(io, buf);
    return buf[0..len];
}

const script_body =
    "import nox.os\n" ++
    "print(nox.os.arg_count())\n" ++
    "for i in range(1, nox.os.arg_count()):\n" ++
    "    print(nox.os.arg(i))\n";

fn runNoxc(a: std.mem.Allocator, io: std.Io, env_map: *std.process.Environ.Map, argv: []const []const u8) !std.process.RunResult {
    var full: std.ArrayListUnmanaged([]const u8) = .empty;
    try full.append(a, "zig-out/bin/noxc");
    try full.appendSlice(a, argv);
    return std.process.run(a, io, .{ .argv = full.items, .environ_map = env_map });
}

test "noxc run: betik yolundan sonraki argumanlar -- olmadan da programa iletilir" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var proj = std.testing.tmpDir(.{});
    defer proj.cleanup();
    var proj_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const proj_path = try absPath(io, proj.dir, &proj_buf);
    try proj.dir.writeFile(io, .{ .sub_path = "s.nox", .data = script_body });

    var home = std.testing.tmpDir(.{});
    defer home.cleanup();
    var home_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var env_map = try std.testing.environ.createMap(a);
    try env_map.put("NOX_HOME", try absPath(io, home.dir, &home_buf));

    const script = try std.fmt.allocPrint(a, "{s}/s.nox", .{proj_path});

    // 1) -- olmadan: iki argüman.
    const r1 = try runNoxc(a, io, &env_map, &.{ "run", script, "a", "b" });
    try std.testing.expectEqualStrings("3\na\nb\n", r1.stdout);

    // 2) Betik bayrakları (derleyici bayrağıyla çakışanlar dahil) programa gider.
    const r2 = try runNoxc(a, io, &env_map, &.{ "run", script, "--help", "-g", "--release" });
    try std.testing.expectEqualStrings("4\n--help\n-g\n--release\n", r2.stdout);

    // 3) Eski biçim (-- ile) hâlâ çalışır; ilk -- yutulur.
    const r3 = try runNoxc(a, io, &env_map, &.{ "run", script, "--", "a", "b" });
    try std.testing.expectEqualStrings("3\na\nb\n", r3.stdout);

    // 4) Derleyici bayrağı betik yolundan ÖNCE verilir ve programa sızmaz.
    const r4 = try runNoxc(a, io, &env_map, &.{ "run", "--backend", "qbe", script, "z" });
    try std.testing.expectEqualStrings("2\nz\n", r4.stdout);

    // 5) Argümansız çağrı.
    const r5 = try runNoxc(a, io, &env_map, &.{ "run", script });
    try std.testing.expectEqualStrings("1\n", r5.stdout);
}

test "shebang: #!/usr/bin/env -S noxc run betigi dogrudan calistirilabilir" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var proj = std.testing.tmpDir(.{});
    defer proj.cleanup();
    var proj_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const proj_path = try absPath(io, proj.dir, &proj_buf);
    try proj.dir.writeFile(io, .{ .sub_path = "tool.nox", .data = "#!/usr/bin/env -S noxc run\n" ++ script_body });
    const script = try std.fmt.allocPrint(a, "{s}/tool.nox", .{proj_path});
    const chmod = try std.process.run(a, io, .{ .argv = &.{ "chmod", "+x", script } });
    try std.testing.expect(chmod.term == .exited and chmod.term.exited == 0);

    var home = std.testing.tmpDir(.{});
    defer home.cleanup();
    var home_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var env_map = try std.testing.environ.createMap(a);
    try env_map.put("NOX_HOME", try absPath(io, home.dir, &home_buf));
    // `env -S noxc` için noxc PATH'te olmalı.
    const cwd = try std.process.currentPathAlloc(io, a);
    const old_path = env_map.get("PATH") orelse "/usr/bin:/bin";
    try env_map.put("PATH", try std.fmt.allocPrint(a, "{s}/zig-out/bin:{s}", .{ cwd, old_path }));

    const r = std.process.run(a, io, .{ .argv = &.{ script, "x", "y" }, .environ_map = &env_map }) catch return error.SkipZigTest;
    if (r.term != .exited or r.term.exited != 0) {
        std.debug.print("shebang betigi basarisiz: {s}\n", .{r.stderr});
        return error.ShebangRunFailed;
    }
    try std.testing.expectEqualStrings("3\nx\ny\n", r.stdout);
}
