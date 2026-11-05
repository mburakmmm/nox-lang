//! v2.0.179 (Faz 11.4): `nox.path.safe_join` sembolik bağlarla da kökü aşmayı reddeder. Fixture korpusu sembolik bağ kuramadığı için bu senaryo gerçek bir `noxc run` alt süreciyle,
//! Zig'in kurduğu bir dizin ağacında doğrulanır: `data/link -> ../dataevil` (kökten kaçan bağ), `rootlink -> data` (kökün KENDİSİ sembolik bağ).
//! Windows'ta sembolik bağ oluşturmak ayrıcalık ister; test orada atlanır.

const std = @import("std");
const builtin = @import("builtin");

fn absPath(io: std.Io, dir: std.Io.Dir, buf: []u8) ![]const u8 {
    const len = try dir.realPath(io, buf);
    return buf[0..len];
}

const script =
    "import nox.path\n" ++
    "\n" ++
    "def attempt(label: str, root: str, req: str) -> None:\n" ++
    "    try:\n" ++
    "        r: str = nox.path.safe_join(root, req)\n" ++
    "        print(label, \"ok\", nox.path.basename(r))\n" ++
    "    except nox_path_PathError:\n" ++
    "        print(label, \"reddedildi\")\n" ++
    "\n" ++
    "attempt(\"dosya\", \"data\", \"a.txt\")\n" ++
    "attempt(\"kacan baglanti\", \"data\", \"link/secret\")\n" ++
    "attempt(\"kacan baglanti kendisi\", \"data\", \"link\")\n" ++
    "attempt(\"baglantili kok, ic dosya\", \"rootlink\", \"a.txt\")\n" ++
    "attempt(\"baglantili kok, nokta nokta\", \"rootlink\", \"../dataevil/secret\")\n" ++
    "attempt(\"baglantili kok, kardes\", \"rootlink\", \"../dataevil\")\n";

test "nox.path.safe_join: sembolik baglar ve baglantili kok" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "data");
    try tmp.dir.createDirPath(io, "dataevil");
    try tmp.dir.writeFile(io, .{ .sub_path = "data/a.txt", .data = "a" });
    try tmp.dir.writeFile(io, .{ .sub_path = "dataevil/secret", .data = "s" });
    try tmp.dir.symLink(io, "../dataevil", "data/link", .{ .is_directory = true });
    try tmp.dir.symLink(io, "data", "rootlink", .{ .is_directory = true });
    try tmp.dir.writeFile(io, .{ .sub_path = "t.nox", .data = script });

    var home = std.testing.tmpDir(.{});
    defer home.cleanup();
    var home_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var env = try std.testing.environ.createMap(a);
    try env.put("NOX_HOME", try a.dupe(u8, try absPath(io, home.dir, &home_buf)));

    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir = try a.dupe(u8, try absPath(io, tmp.dir, &buf));
    const cwd = try std.process.currentPathAlloc(io, a);
    const noxc = try std.fmt.allocPrint(a, "{s}/zig-out/bin/noxc", .{cwd});
    const r = try std.process.run(a, io, .{ .argv = &.{ noxc, "run", "t.nox" }, .cwd = .{ .path = dir }, .environ_map = &env });
    if (r.term != .exited or r.term.exited != 0) std.debug.print("noxc run basarisiz: {s}\n", .{r.stderr});
    try std.testing.expectEqualStrings(
        "dosya ok a.txt\n" ++
            "kacan baglanti reddedildi\n" ++
            "kacan baglanti kendisi reddedildi\n" ++
            "baglantili kok, ic dosya ok a.txt\n" ++
            "baglantili kok, nokta nokta reddedildi\n" ++
            "baglantili kok, kardes reddedildi\n",
        r.stdout,
    );
}
