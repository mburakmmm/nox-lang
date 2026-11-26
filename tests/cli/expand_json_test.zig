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

const ClassSource =
    \\@export
    \\class CounterError(ValueError):
    \\    pass
    \\
    \\@export("instance_locked")
    \\class Counter:
    \\    """A counter."""
    \\    n: int
    \\
    \\    def __init__(self, start: int, label: str = "c") -> None:
    \\        self.n = start
    \\
    \\    def inc(self, by: int) -> int:
    \\        """Add."""
    \\        self.n = self.n + by
    \\        return self.n
    \\
    \\    @property
    \\    def value(self) -> int:
    \\        return self.n
    \\
    \\    @value.setter
    \\    def value(self, v: int) -> None:
    \\        self.n = v
    \\
    \\    @staticmethod
    \\    def zero() -> int:
    \\        return 0
    \\
    \\    @classmethod
    \\    def make(cls, start: int) -> Counter:
    \\        return Counter(start)
    \\
    \\    def twin(self) -> Counter | None:
    \\        return None
    \\
    \\    def __repr__(self) -> str:
    \\        return "c"
    \\
    \\    def _private(self) -> int:
    \\        return 1
    \\
    \\class NotExported:
    \\    x: int
    \\
    \\    def __init__(self) -> None:
    \\        self.x = 1
    \\
;

test "expand --json (UR-009) emits class, method kinds, properties and exception records" {
    if (builtin.os.tag == .windows) return;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "cl.nox", .data = ClassSource });
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &buf);
    const src = try std.fmt.allocPrint(gpa, "{s}/cl.nox", .{buf[0..len]});
    defer gpa.free(src);
    const r = try run(gpa, io, &.{ "zig-out/bin/noxc", "expand", "--json", "--module", "fastmath", src });
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);
    if (exitCode(r) != 0) std.debug.print("{s}\n", .{r.stderr});
    try std.testing.expectEqual(@as(u8, 0), exitCode(r));

    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, r.stdout, .{});
    defer parsed.deinit();
    const exports = parsed.value.object.get("exports").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), exports.len); // NotExported @export taşımaz
    const exc = exports[0].object;
    try std.testing.expectEqualStrings("exception", exc.get("kind").?.string);
    try std.testing.expectEqualStrings("fastmath::CounterError", exc.get("id").?.string);
    try std.testing.expectEqualStrings("ValueError", exc.get("base").?.string);

    const cls = exports[1].object;
    try std.testing.expectEqualStrings("class", cls.get("kind").?.string);
    try std.testing.expectEqualStrings("fastmath::Counter", cls.get("id").?.string);
    try std.testing.expectEqualStrings("instance_locked", cls.get("thread_policy").?.string);
    const ctor = cls.get("constructor").?.object;
    try std.testing.expectEqualStrings("nox_host_export_fastmath_Counter___new__", ctor.get("c_symbol").?.string);
    const cparams = ctor.get("params").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), cparams.len);
    try std.testing.expectEqualStrings("start", cparams[0].object.get("name").?.string);
    try std.testing.expectEqualStrings("span", cparams[1].object.get("marshal").?.string);
    try std.testing.expect(cparams[1].object.get("has_default").?.bool);

    const methods = cls.get("methods").?.array.items;
    // inc, value(get), value(set), zero, make, twin, __repr__ (`_private` dışa açılmaz)
    try std.testing.expectEqual(@as(usize, 7), methods.len);
    const want = [_]struct { name: []const u8, kind: []const u8, sym: []const u8, has_self: bool }{
        .{ .name = "inc", .kind = "instance", .sym = "nox_host_export_fastmath_Counter_inc", .has_self = true },
        .{ .name = "value", .kind = "property_get", .sym = "nox_host_export_fastmath_Counter_get_value", .has_self = true },
        .{ .name = "value", .kind = "property_set", .sym = "nox_host_export_fastmath_Counter_set_value", .has_self = true },
        .{ .name = "zero", .kind = "staticmethod", .sym = "nox_host_export_fastmath_Counter_zero", .has_self = false },
        .{ .name = "make", .kind = "classmethod", .sym = "nox_host_export_fastmath_Counter_make", .has_self = false },
        .{ .name = "twin", .kind = "instance", .sym = "nox_host_export_fastmath_Counter_twin", .has_self = true },
        .{ .name = "__repr__", .kind = "dunder", .sym = "nox_host_export_fastmath_Counter___repr__", .has_self = true },
    };
    for (want, 0..) |wm, i| {
        const m = methods[i].object;
        try std.testing.expectEqualStrings(wm.name, m.get("name").?.string);
        try std.testing.expectEqualStrings(wm.kind, m.get("method_kind").?.string);
        try std.testing.expectEqualStrings(wm.sym, m.get("c_symbol").?.string);
        try std.testing.expectEqual(wm.has_self, m.get("has_self").?.bool);
        try std.testing.expect(!m.get("is_async").?.bool);
        try std.testing.expectEqualStrings("instance_locked", m.get("thread_policy").?.string);
    }
    try std.testing.expectEqualStrings("Add.", methods[0].object.get("doc").?.string);
    try std.testing.expectEqual(@as(usize, 1), methods[0].object.get("params").?.array.items.len); // `self` parametre listesinde YOK
    try std.testing.expectEqualStrings("None", methods[2].object.get("return_type").?.string);
    try std.testing.expectEqualStrings("Counter", methods[4].object.get("return_type").?.string);
    try std.testing.expectEqualStrings("handle", methods[4].object.get("return_marshal").?.string);
    try std.testing.expectEqualStrings("Counter | None", methods[5].object.get("return_type").?.string);
    try std.testing.expectEqualStrings("value", methods[5].object.get("return_marshal").?.string);
}

test "expand --json (UR-010) reports HostObject as external_ref" {
    if (builtin.os.tag == .windows) return;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const r = try run(gpa, io, &.{ "zig-out/bin/noxc", "expand", "--json", "--module", "cb", "tests/compat/host_abi/callbacks.nox" });
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);
    try std.testing.expectEqual(@as(u8, 0), exitCode(r));
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, r.stdout, .{});
    defer parsed.deinit();
    const exports = parsed.value.object.get("exports").?.array.items;
    var found_pass = false;
    var found_all = false;
    for (exports) |e| {
        const o = e.object;
        const name = o.get("name").?.string;
        if (std.mem.eql(u8, name, "passthrough")) {
            found_pass = true;
            try std.testing.expectEqualStrings("external_ref", o.get("return_marshal").?.string);
            try std.testing.expectEqualStrings("HostObject", o.get("return_type").?.string);
            try std.testing.expectEqualStrings("external_ref", o.get("params").?.array.items[0].object.get("marshal").?.string);
        } else if (std.mem.eql(u8, name, "call_all")) {
            found_all = true;
            try std.testing.expectEqualStrings("list[HostObject]", o.get("params").?.array.items[0].object.get("type").?.string);
            try std.testing.expectEqualStrings("value", o.get("params").?.array.items[0].object.get("marshal").?.string);
        }
    }
    try std.testing.expect(found_pass and found_all);
}
