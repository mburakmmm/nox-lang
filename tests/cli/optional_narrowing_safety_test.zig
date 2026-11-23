//! R1-P0.3/P0.4/P0.5 (GPT-6 sağlamlaştırma raporu): Optional özellik-yolu daraltması takma ad, yan etkili bileşik koşul ve kullanıcı dunder'ı karşısında güvenli olmalı
//! (önceden `alias.left = None` / `n.left != None and clear(n)` sonrası `n.left.value` KABUL edilip program None üzerinden çöküyordu). Geçerli kalıplar reddedilmemeli.
const std = @import("std");

const prelude =
    \\class Node:
    \\    left: Node | None
    \\    value: int
    \\    items: list[int]
    \\
    \\    def __init__(self, v: int) -> None:
    \\        self.left = None
    \\        self.value = v
    \\        self.items = [v]
    \\
    \\    def __str__(self) -> str:
    \\        self.left = None
    \\        return "node"
    \\
    \\def clear(n: Node) -> bool:
    \\    n.left = None
    \\    return True
    \\
    \\
;

fn check(a: std.mem.Allocator, io: std.Io, body: []const u8) !struct { ok: bool, stderr: []u8 } {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const src = try std.mem.concat(a, u8, &.{ prelude, body });
    defer a.free(src);
    try tmp.dir.writeFile(io, .{ .sub_path = "m.nox", .data = src });
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir = buf[0..try tmp.dir.realPath(io, &buf)];
    const path = try std.fmt.allocPrint(a, "{s}/m.nox", .{dir});
    defer a.free(path);
    const r = try std.process.run(a, io, .{ .argv = &.{ "zig-out/bin/noxc", "check", path } });
    a.free(r.stdout);
    return .{ .ok = r.term == .exited and r.term.exited == 0, .stderr = r.stderr };
}

fn expectRejected(body: []const u8) !void {
    const a = std.testing.allocator;
    const r = try check(a, std.testing.io, body);
    defer a.free(r.stderr);
    try std.testing.expect(!r.ok);
    try std.testing.expect(std.mem.indexOf(u8, r.stderr, "OptionalNotNarrowed") != null or std.mem.indexOf(u8, r.stderr, "narrow it first") != null);
}

fn expectAccepted(body: []const u8) !void {
    const a = std.testing.allocator;
    const r = try check(a, std.testing.io, body);
    defer a.free(r.stderr);
    if (!r.ok) std.debug.print("beklenmeyen ret:\n{s}\n", .{r.stderr});
    try std.testing.expect(r.ok);
}

test "P0.3: takma ad üzerinden alan ataması n.left daraltmasını düşürür" {
    try expectRejected(
        \\def f(n: Node) -> int:
        \\    alias: Node = n
        \\    if n.left != None:
        \\        alias.left = None
        \\        return n.left.value
        \\    return 0
        \\
    );
}

test "P0.3: yolu çözülemeyen hedef (xs[0].left = None) da aynı alan adına sahip daraltmaları düşürür" {
    try expectRejected(
        \\def f(n: Node, xs: list[Node]) -> int:
        \\    if n.left != None:
        \\        xs[0].left = None
        \\        return n.left.value
        \\    return 0
        \\
    );
}

test "P0.3: iç içe yol (n.left.left) başka bir adla `.left` atamasında düşer" {
    try expectRejected(
        \\def f(n: Node, m: Node) -> int:
        \\    if n.left != None and n.left.left != None:
        \\        m.left = None
        \\        return n.left.left.value
        \\    return 0
        \\
    );
}

test "P0.4: sağ operandı kullanıcı kodu çalıştıran `and` koşulu sol yol daraltmasını geri getirmez" {
    try expectRejected(
        \\def f(n: Node) -> int:
        \\    if n.left != None and clear(n):
        \\        return n.left.value
        \\    return 0
        \\
    );
}

test "P0.4: `or`/`not` biçimi (else dalı) ve while koşulu" {
    try expectRejected(
        \\def f(n: Node) -> int:
        \\    if n.left == None or clear(n):
        \\        return 0
        \\    return n.left.value
        \\
    );
    try expectRejected(
        \\def f(n: Node) -> int:
        \\    while n.left != None and clear(n):
        \\        return n.left.value
        \\    return 0
        \\
    );
}

test "P0.5: kullanıcı __str__'ü çağıran str()/print() yol daraltmasını düşürür" {
    try expectRejected(
        \\def f(n: Node) -> int:
        \\    if n.left != None:
        \\        print(str(n))
        \\        return n.left.value
        \\    return 0
        \\
    );
}

test "geçerli kalıplar reddedilmez" {
    try expectAccepted(
        \\def a(n: Node) -> int:
        \\    if n.left != None:
        \\        return n.left.value
        \\    return 0
        \\
        \\def b(n: Node) -> int:
        \\    if n.left != None and len(n.left.items) > 0:
        \\        return n.left.value + n.left.items[0]
        \\    return 0
        \\
        \\def c(n: Node) -> int:
        \\    if n.left != None and n.left.value > 1 and n.value > 0:
        \\        return n.left.value
        \\    return 0
        \\
        \\def d(n: Node) -> int:
        \\    total: int = 0
        \\    cur: Node | None = n
        \\    while cur != None:
        \\        total = total + cur.value
        \\        cur = cur.left
        \\    return total
        \\
        \\def e(n: Node) -> int:
        \\    n.left = Node(5)
        \\    if n.left != None:
        \\        n.value = 3
        \\        return n.left.value
        \\    return 0
        \\
        \\def f(n: Node) -> int:
        \\    if n.left != None:
        \\        print(n.left.value)
        \\        return n.left.value
        \\    return 0
        \\
    );
}

test "P0.4: alan yazmayan metot çağrısı daraltmayı korur, alan yazan (dolaylı dahil) düşürür" {
    try expectAccepted(
        \\class Tree:
        \\    l: Tree | None
        \\    v: int
        \\
        \\    def __init__(self, v: int) -> None:
        \\        self.l = None
        \\        self.v = v
        \\
        \\    def depth(self) -> int:
        \\        d: int = 0
        \\        if self.l != None:
        \\            d = self.l.depth() + 1
        \\        return d
        \\
        \\def ok(t: Tree) -> int:
        \\    if t.l != None and t.l.depth() > 0:
        \\        return t.l.v
        \\    return 0
        \\
    );
    try expectRejected(
        \\class Tree:
        \\    l: Tree | None
        \\    v: int
        \\
        \\    def __init__(self, v: int) -> None:
        \\        self.l = None
        \\        self.v = v
        \\
        \\    def sever(self) -> int:
        \\        self.l = None
        \\        return 1
        \\
        \\    def indirect(self) -> int:
        \\        return self.sever()
        \\
        \\def bad(t: Tree) -> int:
        \\    if t.l != None and t.indirect() > 0:
        \\        return t.l.v
        \\    return 0
        \\
    );
}
