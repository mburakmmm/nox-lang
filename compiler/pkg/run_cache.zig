//! `noxc run` / `noxc test` ikilisi proje klasörüne yazılmaz.
//! Anahtar, kaynak yolu + içerik + derleyici sürümü ve bayraklardır.
//! Dizin `$NOX_HOME/cache/run/` altındadır. Aynı kaynak değişince önceki
//! özet dizini silinir; her kaynak yolu tek canlı ikili tutar.
//!
//! **Sınırsız şişme düzeltmesi (v2.0.95):** "aynı yolun eski özeti silinir"
//! kuralı yalnızca AYNI kaynak yolu için işler; geçici dizinlerdeki, taşınmış
//! ya da silinmiş projelerin ikilileri sonsuza kadar kalıyordu (gerçek bir
//! `~/.nox/cache/run` 4 GB'a ulaştı). Üç önlem:
//!   1. Derleme biter bitmez ikili dışındaki ara dosyalar (`bin.ll`, `bin.ssa`,
//!      `bin.s` ...) silinir (`dropIntermediates`).
//!   2. Her kullanımda `used` işaretçisi güncellenir (`touch`).
//!   3. Her derlemeden sonra `prune`: kullanılmayan eski girdiler ve toplam
//!      boyut tavanı aşıldığında EN ESKİ kullanılanlar silinir. Son
//!      `grace_s` içinde kullanılan girdiye ASLA dokunulmaz (eşzamanlı
//!      `noxc run/test` süreçleri güvende).

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

/// Kullanım işaretçisi: `obj/<özet>/used` (içeriği boş; yalnızca mtime anlamlı).
/// `bin`in kendi mtime'ı kullanılmaz: Windows'ta çalışan bir `.exe`nin
/// zaman damgası güncellenemeyebilir.
pub const used_marker = "used";

pub const Limits = struct {
    /// Toplam boyut tavanı; `0` = tavan yok.
    max_bytes: u64 = 512 * 1024 * 1024,
    /// Bu süreden uzun kullanılmayan girdi silinir.
    max_age_s: i64 = 14 * 24 * 3600,
    /// Bu süre içinde kullanılan girdiye dokunulmaz.
    grace_s: i64 = 600,
};

pub const Report = struct {
    removed: usize = 0,
    freed_bytes: u64 = 0,
    kept: usize = 0,
    kept_bytes: u64 = 0,
};

/// `NOX_RUN_CACHE_MAX_MB` değerinden tavan; geçersiz/boş değer varsayılanı bırakır.
pub fn limitsFromEnv(max_mb: ?[]const u8) Limits {
    var l: Limits = .{};
    if (max_mb) |v| {
        if (std.fmt.parseInt(u64, std.mem.trim(u8, v, " \t"), 10)) |mb| l.max_bytes = mb *| (1024 * 1024) else |_| {}
    }
    return l;
}

/// Girdinin "son kullanıldı" işaretçisini şimdiye çeker (en iyi çaba).
pub fn touch(io: Io, obj_dir: []const u8) void {
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&buf, "{s}/{s}", .{ obj_dir, used_marker }) catch return;
    Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "" }) catch {};
}

/// Derleme sonrası `keep_name` (ikili) ve `used` dışındaki her şeyi siler.
pub fn dropIntermediates(a: Allocator, io: Io, obj_dir: []const u8, keep_name: []const u8) void {
    var dir = Io.Dir.openDirAbsolute(io, obj_dir, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    var it = dir.iterate();
    while (it.next(io) catch null) |e| {
        if (std.mem.eql(u8, e.name, keep_name) or std.mem.eql(u8, e.name, used_marker)) continue;
        const dup = a.dupe(u8, e.name) catch continue;
        names.append(a, dup) catch continue;
    }
    for (names.items) |n| dir.deleteTree(io, n) catch {};
}

const Entry = struct {
    name: []const u8,
    last_used_s: i64,
    bytes: u64,
    has_bin: bool,
};

fn isBinName(name: []const u8) bool {
    return std.mem.eql(u8, name, "bin") or std.mem.eql(u8, name, "bin.exe");
}

fn mtimeSeconds(st: Io.File.Stat) i64 {
    return @intCast(@divFloor(st.mtime.nanoseconds, std.time.ns_per_s));
}

/// `$NOX_HOME/cache/run/obj` içinden `limits`e göre eski/fazla girdileri siler,
/// ardından hedefi kalmayan `paths/*` dizin dosyalarını temizler.
/// `now_s` açıkça verilir (test edilebilirlik; gizli saat yok).
pub fn prune(a: Allocator, io: Io, nox_home: []const u8, limits: Limits, now_s: i64, dry_run: bool) !Report {
    var report: Report = .{};
    const obj_path = try std.fmt.allocPrint(a, "{s}/cache/run/obj", .{nox_home});
    var obj = Io.Dir.openDirAbsolute(io, obj_path, .{ .iterate = true }) catch return report;
    defer obj.close(io);

    var entries: std.ArrayListUnmanaged(Entry) = .empty;
    var it = obj.iterate();
    while (try it.next(io)) |e| {
        if (e.kind != .directory) continue;
        var sub = obj.openDir(io, e.name, .{ .iterate = true }) catch continue;
        defer sub.close(io);
        var entry: Entry = .{ .name = try a.dupe(u8, e.name), .last_used_s = 0, .bytes = 0, .has_bin = false };
        var newest: i64 = 0;
        var marker: ?i64 = null;
        var sit = sub.iterate();
        while (sit.next(io) catch null) |f| {
            const st = sub.statFile(io, f.name, .{ .follow_symlinks = false }) catch continue;
            entry.bytes += st.size;
            const m = mtimeSeconds(st);
            if (isBinName(f.name)) entry.has_bin = true;
            if (std.mem.eql(u8, f.name, used_marker)) marker = m else newest = @max(newest, m);
        }
        // İşaretçi yoksa (eski sürümde yazılmış girdi) dosya mtime'ına düş.
        entry.last_used_s = marker orelse newest;
        if (entry.last_used_s == 0) {
            const st = obj.statFile(io, e.name, .{}) catch continue;
            entry.last_used_s = mtimeSeconds(st);
        }
        try entries.append(a, entry);
    }

    var doomed = try a.alloc(bool, entries.items.len);
    @memset(doomed, false);
    var total: u64 = 0;
    for (entries.items, 0..) |e, i| {
        const age = now_s - e.last_used_s;
        if (age >= limits.grace_s and (!e.has_bin or age > limits.max_age_s)) {
            doomed[i] = true;
        } else total += e.bytes;
    }
    if (limits.max_bytes != 0 and total > limits.max_bytes) {
        const order = try a.alloc(usize, entries.items.len);
        for (order, 0..) |*o, i| o.* = i;
        std.mem.sort(usize, order, entries.items, struct {
            fn less(es: []const Entry, x: usize, y: usize) bool {
                return es[x].last_used_s < es[y].last_used_s;
            }
        }.less);
        for (order) |i| {
            if (total <= limits.max_bytes) break;
            if (doomed[i] or now_s - entries.items[i].last_used_s < limits.grace_s) continue;
            doomed[i] = true;
            total -= entries.items[i].bytes;
        }
    }

    for (entries.items, 0..) |e, i| {
        if (!doomed[i]) {
            report.kept += 1;
            report.kept_bytes += e.bytes;
            continue;
        }
        report.removed += 1;
        report.freed_bytes += e.bytes;
        if (!dry_run) obj.deleteTree(io, e.name) catch {};
    }
    if (!dry_run) pruneOrphanIndex(a, io, nox_home);
    return report;
}

/// `paths/<yol_özeti>` dosyaları bir `obj/<özet>` dizinine işaret eder; hedefi
/// silinmişse dosya da silinir.
fn pruneOrphanIndex(a: Allocator, io: Io, nox_home: []const u8) void {
    const paths_path = std.fmt.allocPrint(a, "{s}/cache/run/paths", .{nox_home}) catch return;
    var paths = Io.Dir.openDirAbsolute(io, paths_path, .{ .iterate = true }) catch return;
    defer paths.close(io);
    var obj = Io.Dir.openDirAbsolute(io, std.fmt.allocPrint(a, "{s}/cache/run/obj", .{nox_home}) catch return, .{}) catch return;
    defer obj.close(io);
    var orphans: std.ArrayListUnmanaged([]const u8) = .empty;
    var it = paths.iterate();
    while (it.next(io) catch null) |e| {
        if (e.kind != .file) continue;
        const target = paths.readFileAlloc(io, e.name, a, .limited(64)) catch continue;
        const hex = std.mem.trim(u8, target, " \t\r\n");
        const target_ok = if (hex.len == 0) false else if (obj.statFile(io, hex, .{})) |_| true else |_| false;
        if (!target_ok) orphans.append(a, a.dupe(u8, e.name) catch continue) catch continue;
    }
    for (orphans.items) |n| paths.deleteFile(io, n) catch {};
}

pub fn digest(parts: []const []const u8) [32]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    for (parts) |part| {
        var len_bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &len_bytes, part.len, .little);
        hasher.update(&len_bytes);
        hasher.update(part);
    }
    return hasher.finalResult();
}

pub fn hex16(sum: [32]u8) [16]u8 {
    const digits = "0123456789abcdef";
    var out: [16]u8 = undefined;
    for (sum[0..8], 0..) |byte, i| {
        out[i * 2] = digits[byte >> 4];
        out[i * 2 + 1] = digits[byte & 0xf];
    }
    return out;
}

/// Dosya adı (veya yol parçası) bu isimle eşleşirse test seçilir.
/// Sorgu `/` içeriyorsa yolun içinde aranır; aksi halde yalnızca
/// `*_test.nox` dosya adında. Kısa bir ev-dizini öneki bütün ağacı seçmesin.
pub fn matchesTestName(path: []const u8, query: []const u8) bool {
    if (query.len == 0) return false;
    const base = std.fs.path.basename(path);
    if (std.mem.indexOf(u8, base, query) != null) return true;
    if (std.mem.indexOfScalar(u8, query, '/') != null or std.mem.indexOfScalar(u8, query, '\\') != null) {
        return std.mem.indexOf(u8, path, query) != null;
    }
    return false;
}

pub fn shouldSkipDir(name: []const u8) bool {
    return std.mem.eql(u8, name, ".nox") or
        std.mem.eql(u8, name, ".git") or
        std.mem.eql(u8, name, "zig-out") or
        std.mem.eql(u8, name, "zig-cache") or
        std.mem.eql(u8, name, "node_modules") or
        std.mem.startsWith(u8, name, ".");
}

test "test ismi dosya adinda aranir, ev dizini oneki secilmez" {
    try std.testing.expect(matchesTestName("/tmp/proj/tests/v18_smtp_test.nox", "smtp"));
    try std.testing.expect(matchesTestName("/tmp/proj/tests/v18_smtp_test.nox", "v18_smtp_test.nox"));
    try std.testing.expect(!matchesTestName("/Users/melih/proj/tests/v18_smtp_test.nox", "Users"));
    try std.testing.expect(matchesTestName("/tmp/proj/tests/v18_smtp_test.nox", "tests/v18"));
    try std.testing.expect(!matchesTestName("/tmp/proj/tests/other_test.nox", "smtp"));
}

test "ozet parcalarin sirasina baglidir" {
    const a = digest(&.{ "a", "b" });
    const b = digest(&.{ "b", "a" });
    const c = digest(&.{ "a", "b" });
    try std.testing.expect(!std.mem.eql(u8, &a, &b));
    try std.testing.expect(std.mem.eql(u8, &a, &c));
    const hex = hex16(a);
    try std.testing.expectEqual(@as(usize, 16), hex.len);
}

fn writeEntry(io: Io, root: Io.Dir, hex: []const u8, bin_name: []const u8, bin_bytes: usize, used_age_s: ?i64, now_s: i64) !void {
    var buf: [128]u8 = undefined;
    try root.createDirPath(io, try std.fmt.bufPrint(&buf, "cache/run/obj/{s}", .{hex}));
    const data = try std.testing.allocator.alloc(u8, bin_bytes);
    defer std.testing.allocator.free(data);
    @memset(data, 'x');
    var pbuf: [160]u8 = undefined;
    if (bin_name.len > 0) try root.writeFile(io, .{ .sub_path = try std.fmt.bufPrint(&pbuf, "cache/run/obj/{s}/{s}", .{ hex, bin_name }), .data = data });
    if (used_age_s) |age| {
        const marker = try std.fmt.bufPrint(&pbuf, "cache/run/obj/{s}/{s}", .{ hex, used_marker });
        try root.writeFile(io, .{ .sub_path = marker, .data = "" });
        const ts = Io.Timestamp.fromNanoseconds((now_s - age) * std.time.ns_per_s);
        try root.setTimestamps(io, marker, .{ .access_timestamp = .{ .new = ts }, .modify_timestamp = .{ .new = ts } });
    }
}

fn exists(io: Io, root: Io.Dir, rel: []const u8) bool {
    return if (root.statFile(io, rel, .{})) |_| true else |_| false;
}

test "prune: eski, ikilisiz ve tavani asan girdiler silinir; taze olana dokunulmaz" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var rb: [Io.Dir.max_path_bytes]u8 = undefined;
    const home = rb[0..try tmp.dir.realPath(io, &rb)];

    const now: i64 = 2_000_000_000;
    const day: i64 = 24 * 3600;
    try writeEntry(io, tmp.dir, "fresh0000000000a", "bin", 1000, 60, now); // grace içinde
    try writeEntry(io, tmp.dir, "recent000000000b", "bin", 1000, 2 * day, now); // taze, tutulur
    try writeEntry(io, tmp.dir, "ancient00000000c", "bin", 1000, 30 * day, now); // yaşlı
    try writeEntry(io, tmp.dir, "failed000000000d", "", 0, 2 * day, now); // ikilisiz
    try writeEntry(io, tmp.dir, "inflight0000000e", "", 0, 5, now); // ikilisiz ama grace içinde
    try tmp.dir.createDirPath(io, "cache/run/paths");
    try tmp.dir.writeFile(io, .{ .sub_path = "cache/run/paths/live", .data = "recent000000000b" });
    try tmp.dir.writeFile(io, .{ .sub_path = "cache/run/paths/orphan", .data = "ancient00000000c" });

    const report = try prune(a, io, home, .{ .max_bytes = 0 }, now, false);
    try std.testing.expectEqual(@as(usize, 2), report.removed);
    try std.testing.expectEqual(@as(usize, 3), report.kept);
    try std.testing.expect(exists(io, tmp.dir, "cache/run/obj/fresh0000000000a/bin"));
    try std.testing.expect(exists(io, tmp.dir, "cache/run/obj/recent000000000b/bin"));
    try std.testing.expect(exists(io, tmp.dir, "cache/run/obj/inflight0000000e/used"));
    try std.testing.expect(!exists(io, tmp.dir, "cache/run/obj/ancient00000000c/bin"));
    try std.testing.expect(!exists(io, tmp.dir, "cache/run/obj/failed000000000d/used"));
    try std.testing.expect(exists(io, tmp.dir, "cache/run/paths/live"));
    try std.testing.expect(!exists(io, tmp.dir, "cache/run/paths/orphan"));
}

test "prune: boyut tavani asilirsa en eski kullanilanlar silinir, grace icindekiler korunur" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var rb: [Io.Dir.max_path_bytes]u8 = undefined;
    const home = rb[0..try tmp.dir.realPath(io, &rb)];

    const now: i64 = 2_000_000_000;
    const hour: i64 = 3600;
    try writeEntry(io, tmp.dir, "oldest0000000000", "bin", 1000, 5 * hour, now);
    try writeEntry(io, tmp.dir, "older00000000000", "bin", 1000, 3 * hour, now);
    try writeEntry(io, tmp.dir, "newer00000000000", "bin", 1000, 1 * hour, now);
    try writeEntry(io, tmp.dir, "justnow000000000", "bin", 1000, 30, now);

    // Tavan 2500 bayt: toplam 4000 -> iki en eski silinir, 2000 kalır.
    var report = try prune(a, io, home, .{ .max_bytes = 2500 }, now, true);
    try std.testing.expectEqual(@as(usize, 2), report.removed); // kuru çalıştırma: silmez
    try std.testing.expect(exists(io, tmp.dir, "cache/run/obj/oldest0000000000/bin"));
    report = try prune(a, io, home, .{ .max_bytes = 2500 }, now, false);
    try std.testing.expectEqual(@as(usize, 2), report.removed);
    try std.testing.expect(!exists(io, tmp.dir, "cache/run/obj/oldest0000000000/bin"));
    try std.testing.expect(!exists(io, tmp.dir, "cache/run/obj/older00000000000/bin"));
    try std.testing.expect(exists(io, tmp.dir, "cache/run/obj/newer00000000000/bin"));

    // Tavan 1 bayt olsa bile grace içindeki (30 sn önce kullanılan) girdi silinmez.
    _ = try prune(a, io, home, .{ .max_bytes = 1 }, now, false);
    try std.testing.expect(exists(io, tmp.dir, "cache/run/obj/justnow000000000/bin"));
}

test "dropIntermediates: yalnizca ikili ve used kalir" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var rb: [Io.Dir.max_path_bytes]u8 = undefined;
    const home = rb[0..try tmp.dir.realPath(io, &rb)];
    for ([_][]const u8{ "bin", "bin.ll", "bin.ssa", "bin.s", "used" }) |n| {
        var pb: [64]u8 = undefined;
        try tmp.dir.writeFile(io, .{ .sub_path = try std.fmt.bufPrint(&pb, "{s}", .{n}), .data = "z" });
    }
    dropIntermediates(a, io, home, "bin");
    try std.testing.expect(exists(io, tmp.dir, "bin"));
    try std.testing.expect(exists(io, tmp.dir, "used"));
    try std.testing.expect(!exists(io, tmp.dir, "bin.ll"));
    try std.testing.expect(!exists(io, tmp.dir, "bin.ssa"));
    try std.testing.expect(!exists(io, tmp.dir, "bin.s"));
}

test "limitsFromEnv: MB cinsinden tavan, gecersiz deger varsayilani korur" {
    try std.testing.expectEqual(@as(u64, 100 * 1024 * 1024), limitsFromEnv("100").max_bytes);
    try std.testing.expectEqual(@as(u64, 0), limitsFromEnv("0").max_bytes);
    try std.testing.expectEqual((Limits{}).max_bytes, limitsFromEnv("abc").max_bytes);
    try std.testing.expectEqual((Limits{}).max_bytes, limitsFromEnv(null).max_bytes);
}
