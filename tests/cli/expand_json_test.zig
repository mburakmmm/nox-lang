//! UR-007 (NoxPy): `noxc expand --json` — `@export` taşıyan üst-düzey işlevlerin tipli, şema-sürümlü metadata'sı.
//! Tipler checker'dan gelir (`int`, `str` ...), docstring ilk dize deyimidir, `thread_policy` `@export("...")` ilk argümanıdır.

const std = @import("std");
const builtin = @import("builtin");

const Source =
    \\@export
    \\def add(a: int, b: int) -> int:
    \\    """Add two integers."""
    \\    return a + b
    \\
    \\@export("instance_locked")
    \\def greet(name: str, loud: bool = False) -> str:
    \\    return name
    \\
    \\def helper(x: int) -> int:
    \\    return x
    \\
;

fn run(gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8) !std.process.RunResult {
    return std.process.run(gpa, io, .{ .argv = argv });
}

fn exitCode(r: std.process.RunResult) u8 {
    return if (r.term == .exited) r.term.exited else 255;
}

test "expand --json emits schema v1 metadata for @export functions only" {
    if (builtin.os.tag == .windows) return;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "fm.nox", .data = Source });
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &buf);
    const src = try std.fmt.allocPrint(gpa, "{s}/fm.nox", .{buf[0..len]});
    defer gpa.free(src);
    const r = try run(gpa, io, &.{ "zig-out/bin/noxc", "expand", "--json", "--module", "fastmath", src });
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);
    try std.testing.expectEqual(@as(u8, 0), exitCode(r));

    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, r.stdout, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expectEqual(@as(i64, 1), root.get("schema_version").?.integer);
    try std.testing.expectEqualStrings("noxc", root.get("compiler").?.object.get("name").?.string);
    try std.testing.expectEqualStrings("fastmath", root.get("module").?.object.get("name").?.string);
    const exports = root.get("exports").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), exports.len); // `helper` @export taşımaz
    const add = exports[0].object;
    try std.testing.expectEqualStrings("add", add.get("name").?.string);
    try std.testing.expectEqualStrings("fastmath::add", add.get("id").?.string);
    try std.testing.expectEqualStrings("nox_host_export_fastmath_add", add.get("c_symbol").?.string);
    try std.testing.expectEqualStrings("Add two integers.", add.get("doc").?.string);
    try std.testing.expectEqualStrings("parallel", add.get("thread_policy").?.string);
    try std.testing.expectEqualStrings("int", add.get("return_type").?.string);
    const aparams = add.get("params").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), aparams.len);
    try std.testing.expectEqualStrings("a", aparams[0].object.get("name").?.string);
    try std.testing.expectEqualStrings("int", aparams[0].object.get("type").?.string);
    try std.testing.expect(!aparams[0].object.get("has_default").?.bool);
    const greet = exports[1].object;
    try std.testing.expectEqualStrings("instance_locked", greet.get("thread_policy").?.string);
    try std.testing.expect(greet.get("doc").? == .null);
    try std.testing.expect(greet.get("params").?.array.items[1].object.get("has_default").?.bool);
}

test "expand --json fails on a type error without emitting JSON" {
    if (builtin.os.tag == .windows) return;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "bad.nox", .data = "x: int = \"a\"\n" });
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &buf);
    const src = try std.fmt.allocPrint(gpa, "{s}/bad.nox", .{buf[0..len]});
    defer gpa.free(src);
    const r = try run(gpa, io, &.{ "zig-out/bin/noxc", "expand", "--json", src });
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);
    try std.testing.expect(exitCode(r) != 0);
    try std.testing.expectEqual(@as(usize, 0), r.stdout.len);
}
