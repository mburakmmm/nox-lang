//! `noxc cache prune` + `install`/`refresh`/`upgrade` sonrası otomatik
//! temizlik (bkz. nox-teknik-spesifikasyon.md §3.239).
//!
//! **Sorun:** paket önbelleği (`{nox_home}/pkg/mod/<repo>/<sha>`) içerik-
//! adresli ve HİÇBİR YERDE temizlenmiyordu — bir repo'nun her yeni commit'i
//! (global `install`/`refresh`, proje `nox.lock` güncellemesi, yerel-yol
//! bağımlılıkları) yeni bir tam kopya bırakıyordu; eski SHA'lar sonsuza
//! kadar kalıyordu (gerçek bir ~/.nox 2.1 GB'a ulaşmıştı).
//!
//! **Kural (muhafazakâr):** bir SHA dizini şu durumlarda KORUNUR:
//!   1. `installed.json`da (global kurulu paketler) kayıtlıysa;
//!   2. (`keep_newest_per_repo`, varsayılan) o repo'nun en yeni (mtime)
//!      girdisiyse — bir projenin `nox.lock`undaki güncel sürümü
//!      gereksiz yere yeniden indirtmemek için.
//! Geri kalanı silinir. Önbellek her zaman yeniden üretilebilir olduğundan
//! (bir `nox.lock`ta kilitli SHA yerelde yoksa resolver onu yeniden
//! getirir) en kötü durum bir sonraki derlemede ek bir `git clone`dur.
//! Ayrıca bir saatten eski `pkg/tmp/*` (yarım kalmış `stage-*`/
//! `install-scratch-*`) artıkları süpürülür.
//!
//! Hiçbir global/gizli durum yok: kök yol, korunacak kayıtlar ve seçenekler
//! AÇIK parametredir (AGENTS.md §2.6).

const std = @import("std");
const fetch = @import("fetch.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

/// `installed.json` kaydından, korumak için ihtiyaç duyulan KÜÇÜK görünüm
/// (bu modül `project.zig`ye bağımlı OLMASIN diye ayrı bir tip).
pub const KeepEntry = struct {
    repo: []const u8,
    resolved_sha: []const u8,
};

pub const PruneOptions = struct {
    /// Silme; yalnızca ne silineceğini raporla.
    dry_run: bool = false,
    /// `true` (varsayılan): her repo'nun en yeni girdisi de korunur.
    /// `false` (`--all`): yalnızca `keep` listesi korunur.
    keep_newest_per_repo: bool = true,
    /// Doluysa YALNIZCA bu repo'nun girdileri taranır (install sonrası
    /// otomatik temizlik); `pkg/tmp` süpürmesi de atlanır.
    only_repo: ?[]const u8 = null,
};

pub const PruneReport = struct {
    /// Silinen (dry-run'da silinecek) SHA dizinlerinin mutlak yolları.
    removed_paths: []const []const u8 = &.{},
    freed_bytes: u64 = 0,
    kept_entries: usize = 0,
    removed_tmp_entries: usize = 0,
};

/// Bir önbellek SHA dizin adı mı? (`git rev-parse HEAD`: 40 hex, SHA-256
/// depolarda 64 hex.)
fn isShaDirName(name: []const u8) bool {
    if (name.len != 40 and name.len != 64) return false;
    for (name) |c| switch (c) {
        '0'...'9', 'a'...'f' => {},
        else => return false,
    };
    return true;
}

const one_hour_ns: i96 = 3600 * std.time.ns_per_s;

const Group = struct {
    dir_path: []const u8,
    /// Bu repo'nun `pkg/mod` köküne göre göreli yolu (`github.com/u/r`).
    rel: []const u8,
    shas: std.ArrayListUnmanaged([]const u8) = .empty,
};

fn collectGroups(a: Allocator, io: Io, dir_path: []const u8, rel: []const u8, out: *std.ArrayListUnmanaged(Group)) !void {
    var dir = Io.Dir.openDirAbsolute(io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var group: Group = .{ .dir_path = dir_path, .rel = rel };
    var subdirs: std.ArrayListUnmanaged([]const u8) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |e| {
        if (e.kind != .directory) continue;
        if (isShaDirName(e.name)) {
            try group.shas.append(a, try a.dupe(u8, e.name));
        } else {
            try subdirs.append(a, try a.dupe(u8, e.name));
        }
    }
    if (group.shas.items.len > 0) try out.append(a, group);
    for (subdirs.items) |name| {
        const child_path = try std.fmt.allocPrint(a, "{s}/{s}", .{ dir_path, name });
        const child_rel = if (rel.len == 0) try a.dupe(u8, name) else try std.fmt.allocPrint(a, "{s}/{s}", .{ rel, name });
        try collectGroups(a, io, child_path, child_rel, out);
    }
}

fn dirSizeBytes(a: Allocator, io: Io, path: []const u8) u64 {
    var dir = Io.Dir.openDirAbsolute(io, path, .{ .iterate = true }) catch return 0;
    defer dir.close(io);
    var walker = dir.walk(a) catch return 0;
    defer walker.deinit();
    var total: u64 = 0;
    while (walker.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        const st = entry.dir.statFile(io, entry.basename, .{ .follow_symlinks = false }) catch continue;
        total += st.size;
    }
    return total;
}

fn mtimeNs(io: Io, dir_path: []const u8) i96 {
    const st = Io.Dir.cwd().statFile(io, dir_path, .{}) catch return 0;
    return st.mtime.nanoseconds;
}

/// Önbelleği temizler. `keep`, `installed.json`daki kayıtlardır.
pub fn prune(a: Allocator, io: Io, nox_home: []const u8, keep: []const KeepEntry, opts: PruneOptions) !PruneReport {
    var keep_paths: std.StringHashMapUnmanaged(void) = .empty;
    for (keep) |k| {
        const p = fetch.cachedDirFor(a, nox_home, k.repo, k.resolved_sha) catch continue;
        try keep_paths.put(a, p, {});
    }
    const only_rel: ?[]const u8 = if (opts.only_repo) |r| try fetch.sanitizeRepoForCachePath(a, r) else null;

    var report: PruneReport = .{};
    var removed: std.ArrayListUnmanaged([]const u8) = .empty;

    const mod_root = try std.fmt.allocPrint(a, "{s}/pkg/mod", .{nox_home});
    var groups: std.ArrayListUnmanaged(Group) = .empty;
    try collectGroups(a, io, mod_root, "", &groups);

    for (groups.items) |g| {
        if (only_rel) |want| {
            if (!std.mem.eql(u8, g.rel, want)) continue;
        }
        var newest_idx: ?usize = null;
        if (opts.keep_newest_per_repo) {
            var newest_ns: i96 = std.math.minInt(i96);
            for (g.shas.items, 0..) |sha, i| {
                const full = try std.fmt.allocPrint(a, "{s}/{s}", .{ g.dir_path, sha });
                const ns = mtimeNs(io, full);
                if (newest_idx == null or ns > newest_ns) {
                    newest_ns = ns;
                    newest_idx = i;
                }
            }
        }
        for (g.shas.items, 0..) |sha, i| {
            const full = try std.fmt.allocPrint(a, "{s}/{s}", .{ g.dir_path, sha });
            if (keep_paths.contains(full) or (newest_idx != null and newest_idx.? == i)) {
                report.kept_entries += 1;
                continue;
            }
            report.freed_bytes += dirSizeBytes(a, io, full);
            if (!opts.dry_run) {
                Io.Dir.cwd().deleteTree(io, full) catch continue;
            }
            try removed.append(a, full);
        }
    }

    if (opts.only_repo == null) {
        const tmp_root = try std.fmt.allocPrint(a, "{s}/pkg/tmp", .{nox_home});
        if (Io.Dir.openDirAbsolute(io, tmp_root, .{ .iterate = true })) |opened| {
            var tmp_dir = opened;
            defer tmp_dir.close(io);
            const now_ns = Io.Timestamp.now(io, .real).nanoseconds;
            var it = tmp_dir.iterate();
            while (try it.next(io)) |e| {
                const full = try std.fmt.allocPrint(a, "{s}/{s}", .{ tmp_root, e.name });
                if (now_ns - mtimeNs(io, full) < one_hour_ns) continue;
                report.freed_bytes += dirSizeBytes(a, io, full);
                if (!opts.dry_run) Io.Dir.cwd().deleteTree(io, full) catch continue;
                report.removed_tmp_entries += 1;
            }
        } else |_| {}
    }

    report.removed_paths = removed.items;
    return report;
}

/// İnsan-okunur boyut ("12.3 MB").
pub fn formatBytes(a: Allocator, bytes: u64) ![]const u8 {
    const kb: f64 = 1024.0;
    const b: f64 = @floatFromInt(bytes);
    if (b >= kb * kb * kb) return std.fmt.allocPrint(a, "{d:.1} GB", .{b / (kb * kb * kb)});
    if (b >= kb * kb) return std.fmt.allocPrint(a, "{d:.1} MB", .{b / (kb * kb)});
    if (b >= kb) return std.fmt.allocPrint(a, "{d:.1} KB", .{b / kb});
    return std.fmt.allocPrint(a, "{d} B", .{bytes});
}

test "isShaDirName: 40/64 küçük hex kabul, diğerleri red" {
    try std.testing.expect(isShaDirName("0123456789abcdef0123456789abcdef01234567"));
    try std.testing.expect(!isShaDirName("0123456789ABCDEF0123456789abcdef01234567"));
    try std.testing.expect(!isShaDirName("abc"));
    try std.testing.expect(!isShaDirName("github.com"));
}
