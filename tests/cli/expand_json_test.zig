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

const CanonSource =
    \\@export
    \\def swap_pair(p: tuple[int, str]) -> tuple[str, int]:
    \\    return (p[1], p[0])
    \\
    \\@export
    \\def nest(xs: list[tuple[int, str]], d: dict[str, tuple[int, float]], o: int | None) -> list[int | None]:
    \\    return [o]
    \\
    \\@export
    \\def defaults(a: int = -3, b: float = 1.5, c: bool = True, s: str = "hi", n: int | None = None) -> None:
    \\    pass
    \\
;

test "expand --json uses canonical surface spelling for tuple/containers and emits constant defaults (UR-008)" {
    if (builtin.os.tag == .windows) return;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "canon.nox", .data = CanonSource });
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &buf);
    const src = try std.fmt.allocPrint(gpa, "{s}/canon.nox", .{buf[0..len]});
    defer gpa.free(src);
    const r = try run(gpa, io, &.{ "zig-out/bin/noxc", "expand", "--json", "--module", "canon", src });
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);
    try std.testing.expectEqual(@as(u8, 0), exitCode(r));
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "tuple__") == null);

    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, r.stdout, .{});
    defer parsed.deinit();
    const ex = parsed.value.object.get("exports").?.array.items;
    const swap = ex[0].object;
    try std.testing.expectEqualStrings("tuple[int, str]", swap.get("params").?.array.items[0].object.get("type").?.string);
    try std.testing.expectEqualStrings("tuple[str, int]", swap.get("return_type").?.string);
    try std.testing.expectEqualStrings("value", swap.get("params").?.array.items[0].object.get("marshal").?.string);
    try std.testing.expectEqualStrings("value", swap.get("return_marshal").?.string);
    const nest = ex[1].object;
    const np = nest.get("params").?.array.items;
    try std.testing.expectEqualStrings("list[tuple[int, str]]", np[0].object.get("type").?.string);
    try std.testing.expectEqualStrings("dict[str, tuple[int, float]]", np[1].object.get("type").?.string);
    try std.testing.expectEqualStrings("int | None", np[2].object.get("type").?.string);
    try std.testing.expectEqualStrings("list[int | None]", nest.get("return_type").?.string);
    try std.testing.expect(np[0].object.get("default").? == .null);
    const dp = ex[2].object.get("params").?.array.items;
    try std.testing.expectEqual(@as(i64, -3), dp[0].object.get("default").?.object.get("value").?.integer);
    try std.testing.expectEqualStrings("float", dp[1].object.get("default").?.object.get("type").?.string);
    try std.testing.expectEqual(@as(f64, 1.5), dp[1].object.get("default").?.object.get("value").?.float);
    try std.testing.expect(dp[2].object.get("default").?.object.get("value").?.bool);
    try std.testing.expectEqualStrings("hi", dp[3].object.get("default").?.object.get("value").?.string);
    const nd = dp[4].object.get("default").?.object;
    try std.testing.expectEqualStrings("None", nd.get("type").?.string);
    try std.testing.expect(nd.get("value").? == .null);
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
