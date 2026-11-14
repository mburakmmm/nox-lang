//! 2.2 aşama 6: paketin KAYNAK DİLİ etiketi (`nox` = saf Nox, `c`, `cpp`, `rust`, `go`, `zig`, `mixed`).
//!
//! Etiket yayıncı beyanıdır (`nox.json` `"source"` ya da `noxc publish --source`); `noxc publish` yerelde proje ağacını tarar ve beyanla çelişen
//! durumda yayını reddeder (sunucu kaynağı klonlayıp taramaz — güvenlik gerekçesiyle, bkz. `project/acik-isler-2026-11-14.md` B4/S3). Beyan yoksa
//! tarama sonucu kullanılır. Sayfada "yayıncı beyanı" ibaresiyle gösterilir.

const std = @import("std");

pub const Kind = enum {
    nox,
    c,
    cpp,
    rust,
    go,
    zig,
    mixed,

    pub fn label(self: Kind) []const u8 {
        return @tagName(self);
    }
};

/// Kullanıcı yazımları: `nox`/`pure-nox`, `c`, `cpp`/`c++`, `rust`, `go`, `zig`, `mixed` (büyük/küçük harf fark etmez).
pub fn parse(text: []const u8) ?Kind {
    var buf: [16]u8 = undefined;
    if (text.len == 0 or text.len > buf.len) return null;
    const lower = std.ascii.lowerString(&buf, text);
    if (std.mem.eql(u8, lower, "nox") or std.mem.eql(u8, lower, "pure-nox") or std.mem.eql(u8, lower, "pure nox")) return .nox;
    if (std.mem.eql(u8, lower, "c")) return .c;
    if (std.mem.eql(u8, lower, "cpp") or std.mem.eql(u8, lower, "c++")) return .cpp;
    if (std.mem.eql(u8, lower, "rust")) return .rust;
    if (std.mem.eql(u8, lower, "go")) return .go;
    if (std.mem.eql(u8, lower, "zig")) return .zig;
    if (std.mem.eql(u8, lower, "mixed")) return .mixed;
    return null;
}

/// Ağaçta bulunan yerel (Nox dışı) kaynak dilleri.
pub const Detected = struct {
    c: bool = false,
    cpp: bool = false,
    rust: bool = false,
    go: bool = false,
    zig: bool = false,
    /// Her dil için görülen ilk dosya (hata iletisinde örnek göstermek için); bellek `a`dan.
    example: ?[]const u8 = null,

    pub fn count(self: Detected) u8 {
        return @as(u8, @intFromBool(self.c)) + @intFromBool(self.cpp) + @intFromBool(self.rust) + @intFromBool(self.go) + @intFromBool(self.zig);
    }

    pub fn kind(self: Detected) Kind {
        const n = self.count();
        if (n == 0) return .nox;
        if (n > 1) return .mixed;
        if (self.c) return .c;
        if (self.cpp) return .cpp;
        if (self.rust) return .rust;
        if (self.go) return .go;
        return .zig;
    }
};

/// Taramada atlanan dizinler: sürüm denetimi, önbellekler/derleme çıktıları ve paketin KENDİ testleri/örnekleri/belgeleri/kıyasları (yayın kaynağı sayılmaz).
fn skipDir(name: []const u8) bool {
    const skip = [_][]const u8{ ".git", ".nox", "node_modules", "target", "zig-out", ".zig-cache", "tests", "test", "examples", "example", "docs", "benchmarks", "bench", ".github" };
    for (skip) |s| if (std.mem.eql(u8, name, s)) return true;
    return false;
}

fn classify(name: []const u8) ?enum { c, cpp, rust, go, zig } {
    const ext = std.fs.path.extension(name);
    if (std.mem.eql(u8, ext, ".c")) return .c;
    if (std.mem.eql(u8, ext, ".cc") or std.mem.eql(u8, ext, ".cpp") or std.mem.eql(u8, ext, ".cxx") or std.mem.eql(u8, ext, ".hpp") or std.mem.eql(u8, ext, ".hh")) return .cpp;
    if (std.mem.eql(u8, ext, ".rs")) return .rust;
    if (std.mem.eql(u8, ext, ".go")) return .go;
    if (std.mem.eql(u8, ext, ".zig")) return .zig;
    return null;
}

/// `root` altında (en çok 6 düzey) yerel kaynak dillerini arar.
pub fn detect(io: std.Io, a: std.mem.Allocator, root: []const u8) !Detected {
    var d: Detected = .{};
    try walk(io, a, root, "", 0, &d);
    return d;
}

fn walk(io: std.Io, a: std.mem.Allocator, root: []const u8, rel: []const u8, depth: usize, d: *Detected) !void {
    if (depth > 6) return;
    const path = if (rel.len == 0) try a.dupe(u8, root) else try std.fmt.allocPrint(a, "{s}/{s}", .{ root, rel });
    var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |e| {
        const child_rel = if (rel.len == 0) try a.dupe(u8, e.name) else try std.fmt.allocPrint(a, "{s}/{s}", .{ rel, e.name });
        switch (e.kind) {
            .directory => if (!skipDir(e.name)) try walk(io, a, root, child_rel, depth + 1, d),
            .file => if (classify(e.name)) |k| {
                switch (k) {
                    .c => d.c = true,
                    .cpp => d.cpp = true,
                    .rust => d.rust = true,
                    .go => d.go = true,
                    .zig => d.zig = true,
                }
                if (d.example == null) d.example = child_rel;
            },
            else => {},
        }
    }
}

pub const Verdict = union(enum) {
    ok: Kind,
    /// Beyan ile tarama çelişiyor; iletide gösterilecek açıklama.
    mismatch: []const u8,
};

/// `declared` null ise taramanın sonucu kullanılır. Çelişki: beyan `nox` ama yerel kaynak var; ya da beyan yerel bir dil ama tarama onu bulmadı; `mixed` beyanı
/// için en az iki dil gerekir; tek dil beyanı başka bir dil bulunmasıyla çelişir.
pub fn verify(a: std.mem.Allocator, declared: ?Kind, d: Detected) !Verdict {
    const found = d.kind();
    const decl = declared orelse return .{ .ok = found };
    if (decl == found) return .{ .ok = decl };
    const ex = d.example orelse "";
    if (decl == .nox) return .{ .mismatch = try std.fmt.allocPrint(a, "declares a pure Nox package but found {s} sources (e.g. {s}); set \"source\" to \"{s}\" in nox.json", .{ found.label(), ex, found.label() }) };
    if (found == .nox) return .{ .mismatch = try std.fmt.allocPrint(a, "declares \"{s}\" but no {s} source files were found (outside tests/examples/docs)", .{ decl.label(), decl.label() }) };
    return .{ .mismatch = try std.fmt.allocPrint(a, "declares \"{s}\" but the source tree contains {s} sources (e.g. {s})", .{ decl.label(), found.label(), ex }) };
}

const testing = std.testing;

test "source_kind.parse: yazımlar ve büyük/küçük harf" {
    try testing.expectEqual(Kind.nox, parse("nox").?);
    try testing.expectEqual(Kind.nox, parse("Pure-Nox").?);
    try testing.expectEqual(Kind.cpp, parse("C++").?);
    try testing.expectEqual(Kind.cpp, parse("CPP").?);
    try testing.expectEqual(Kind.rust, parse("rust").?);
    try testing.expect(parse("") == null);
    try testing.expect(parse("java") == null);
    try testing.expect(parse("averyveryverylongname") == null);
}

test "source_kind: tarama ve karar (geçici dizin)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try tmp.dir.writeFile(io, .{ .sub_path = "main.nox", .data = "print(1)\n" });
    var d0 = try detect(io, a, root);
    try testing.expectEqual(Kind.nox, d0.kind());
    // tests/ ve examples/ altındaki yerel dosyalar sayılmaz
    try tmp.dir.createDir(io, "tests", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "tests/helper.c", .data = "int x;\n" });
    d0 = try detect(io, a, root);
    try testing.expectEqual(Kind.nox, d0.kind());
    // kök dizindeki C kaynağı
    try tmp.dir.createDir(io, "native", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "native/shim.c", .data = "int y;\n" });
    var d1 = try detect(io, a, root);
    try testing.expectEqual(Kind.c, d1.kind());
    try testing.expect(d1.example != null);
    // beyan yok -> tarama sonucu
    var v = try verify(a, null, d1);
    try testing.expectEqual(Kind.c, v.ok);
    // saf Nox beyanı ama C var -> çelişki
    v = try verify(a, .nox, d1);
    try testing.expect(v == .mismatch);
    try testing.expect(std.mem.indexOf(u8, v.mismatch, "shim.c") != null);
    // C beyanı, tarama C -> tamam
    v = try verify(a, .c, d1);
    try testing.expectEqual(Kind.c, v.ok);
    // Rust eklenince karışık
    try tmp.dir.writeFile(io, .{ .sub_path = "native/lib.rs", .data = "fn main() {}\n" });
    d1 = try detect(io, a, root);
    try testing.expectEqual(Kind.mixed, d1.kind());
    v = try verify(a, .c, d1);
    try testing.expect(v == .mismatch);
    v = try verify(a, .mixed, d1);
    try testing.expectEqual(Kind.mixed, v.ok);
    // beyan yerel dil ama ağaç saf Nox
    const empty = Detected{};
    v = try verify(a, .go, empty);
    try testing.expect(v == .mismatch);
    v = try verify(a, .nox, empty);
    try testing.expectEqual(Kind.nox, v.ok);
}
