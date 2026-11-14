//! `noxc sbom` (TODO 7.4 S1, tasarım: `project/registry-guvenlik-tasarimi-2026-11.md`): CycloneDX 1.5 JSON SBOM.
//! Kaynak: `nox.json` (proje) + `nox.lock` (kilitli bağımlılıklar: depo, ref, çözülmüş commit) + her kaynak ağacında statik tarama (`extern def`, `lowlevel`, `bin`).
//! Çıktı DETERMİNİSTİKTİR (zaman damgası/yol/kullanıcı adı yok, bileşenler sıralı) — böylece imzalanabilir ve golden test edilebilir. Hiçbir kod ÇALIŞTIRILMAZ.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const project = @import("../project.zig");
const fetch = @import("fetch.zig");
const run_cache = @import("run_cache.zig");

/// Bir kaynak ağacının statik tarama sonucu.
pub const NativeInfo = struct {
    /// `extern def ... from "<lib>"` kitaplık adları (tekil, sıralı).
    extern_libs: []const []const u8 = &.{},
    lowlevel: bool = false,
    has_extern: bool = false,
    bin: bool = false,

    pub fn isNative(self: NativeInfo) bool {
        return self.has_extern or self.lowlevel or self.bin;
    }
};

/// Tek bir `.nox` kaynağını tarar: `extern def` satırları (`from "x"` adı), `lowlevel:` blokları.
fn scanSource(a: Allocator, text: []const u8, libs: *std.StringArrayHashMapUnmanaged(void), info: *NativeInfo) !void {
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (std.mem.startsWith(u8, line, "extern def ")) {
            info.has_extern = true;
            if (std.mem.lastIndexOf(u8, line, " from \"")) |at| {
                const rest = line[at + " from \"".len ..];
                if (std.mem.indexOfScalar(u8, rest, '"')) |end| {
                    const name = rest[0..end];
                    if (name.len > 0 and !libs.contains(name)) try libs.put(a, try a.dupe(u8, name), {});
                }
            }
        } else if (std.mem.startsWith(u8, line, "lowlevel:") or std.mem.eql(u8, line, "lowlevel")) {
            info.lowlevel = true;
        }
    }
}

/// `dir` altındaki tüm `.nox` dosyalarını (önbellek/inşa dizinleri hariç) tarar ve `nox.json`un `bin` alanına bakar.
pub fn scanTree(a: Allocator, io: Io, dir: []const u8) !NativeInfo {
    var info: NativeInfo = .{};
    var libs: std.StringArrayHashMapUnmanaged(void) = .empty;
    var d = Io.Dir.openDirAbsolute(io, dir, .{ .iterate = true }) catch return info;
    defer d.close(io);
    var walker = try d.walk(a);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".nox")) continue;
        var skipped = false;
        var parts = std.mem.splitAny(u8, entry.path, "/\\");
        while (parts.next()) |p| {
            if (run_cache.shouldSkipDir(p)) skipped = true;
        }
        if (skipped) continue;
        const bytes = d.readFileAlloc(io, entry.path, a, .limited(8 * 1024 * 1024)) catch continue;
        try scanSource(a, bytes, &libs, &info);
    }
    if (project.loadManifest(a, io, dir)) |m| {
        if (m.bin != null) info.bin = true;
    } else |_| {}
    const names = try a.dupe([]const u8, libs.keys());
    std.mem.sort([]const u8, names, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);
    info.extern_libs = names;
    return info;
}

/// `github.com/owner/repo` -> `pkg:github/owner/repo@<version>`; diğer ana makineler `pkg:generic/<repo>@<version>`.
pub fn purl(a: Allocator, repo: []const u8, version: []const u8) ![]const u8 {
    const prefix = "github.com/";
    if (std.mem.startsWith(u8, repo, prefix)) {
        return std.fmt.allocPrint(a, "pkg:github/{s}@{s}", .{ repo[prefix.len..], version });
    }
    return std.fmt.allocPrint(a, "pkg:generic/{s}@{s}", .{ repo, version });
}

const Prop = struct { name: []const u8, value: []const u8 };

fn writeProps(w: *std.Io.Writer, props: []const Prop) !void {
    try w.writeAll("\"properties\": [");
    for (props, 0..) |p, i| {
        if (i > 0) try w.writeAll(", ");
        try w.print("{{\"name\": {f}, \"value\": {f}}}", .{ std.json.fmt(p.name, .{}), std.json.fmt(p.value, .{}) });
    }
    try w.writeAll("]");
}

fn nativeProps(a: Allocator, info: NativeInfo, list: *std.ArrayListUnmanaged(Prop)) !void {
    try list.append(a, .{ .name = "nox:native", .value = if (info.isNative()) "true" else "false" });
    if (info.has_extern) try list.append(a, .{ .name = "nox:extern-def", .value = "true" });
    if (info.lowlevel) try list.append(a, .{ .name = "nox:lowlevel", .value = "true" });
    if (info.bin) try list.append(a, .{ .name = "nox:bin", .value = "true" });
    if (info.extern_libs.len > 0) {
        var joined: std.ArrayListUnmanaged(u8) = .empty;
        for (info.extern_libs, 0..) |l, i| {
            if (i > 0) try joined.append(a, ',');
            try joined.appendSlice(a, l);
        }
        try list.append(a, .{ .name = "nox:extern-libs", .value = joined.items });
    }
}

/// SBOM JSON metnini üretir. `nox_home`: bağımlılık kaynaklarının önbelleği (`pkg/mod/...`); önbellekte yoksa bileşen "taranmadı" olarak işaretlenir (`nox:scanned=false`).
pub fn generate(a: Allocator, io: Io, nox_home: []const u8, project_dir: []const u8, tool_version: []const u8) ![]u8 {
    const manifest = project.loadManifest(a, io, project_dir) catch project.Manifest{};
    const lock = project.loadLockfile(a, io, project_dir) catch project.Lockfile{};

    var out: std.Io.Writer.Allocating = .init(a);
    const w = &out.writer;

    const root_name = if (manifest.name.len > 0) manifest.name else "app";
    const root_info = try scanTree(a, io, project_dir);
    var root_props: std.ArrayListUnmanaged(Prop) = .empty;
    try nativeProps(a, root_info, &root_props);

    // Bileşenleri (alias sırasına göre) hazırla.
    const idx = try a.alloc(usize, lock.packages.len);
    for (idx, 0..) |*v, i| v.* = i;
    std.mem.sort(usize, idx, lock.packages, struct {
        fn lt(pk: []const project.LockedPackage, x: usize, y: usize) bool {
            return std.mem.lessThan(u8, pk[x].alias, pk[y].alias);
        }
    }.lt);

    try w.writeAll("{\n  \"bomFormat\": \"CycloneDX\",\n  \"specVersion\": \"1.5\",\n  \"version\": 1,\n");
    try w.print("  \"metadata\": {{\n    \"tools\": {{\"components\": [{{\"type\": \"application\", \"name\": \"noxc\", \"version\": {f}}}]}},\n", .{std.json.fmt(tool_version, .{})});
    try w.print("    \"component\": {{\"type\": \"application\", \"bom-ref\": {f}, \"name\": {f}, ", .{ std.json.fmt(root_name, .{}), std.json.fmt(root_name, .{}) });
    try writeProps(w, root_props.items);
    try w.writeAll("}\n  },\n  \"components\": [");

    for (idx, 0..) |pi, n| {
        const p = lock.packages[pi];
        var info: NativeInfo = .{};
        var scanned = false;
        if (fetch.cachedDirFor(a, nox_home, p.repo, p.resolved)) |cdir| {
            if (Io.Dir.openDirAbsolute(io, cdir, .{})) |dd| {
                var d2 = dd;
                d2.close(io);
                info = try scanTree(a, io, cdir);
                scanned = true;
            } else |_| {}
        } else |_| {}
        const ref_purl = try purl(a, p.repo, p.resolved);
        var props: std.ArrayListUnmanaged(Prop) = .empty;
        try props.append(a, .{ .name = "nox:repo", .value = p.repo });
        try props.append(a, .{ .name = "nox:ref", .value = p.ref });
        try props.append(a, .{ .name = "nox:resolved-commit", .value = p.resolved });
        try props.append(a, .{ .name = "nox:scanned", .value = if (scanned) "true" else "false" });
        if (scanned) try nativeProps(a, info, &props);
        if (p.hpy_sha256.len > 0) try props.append(a, .{ .name = "nox:hpy-sha256", .value = p.hpy_sha256 });
        try w.writeAll(if (n == 0) "\n    " else ",\n    ");
        try w.print("{{\"type\": \"library\", \"bom-ref\": {f}, \"name\": {f}, \"version\": {f}, \"purl\": {f}, ", .{ std.json.fmt(ref_purl, .{}), std.json.fmt(p.alias, .{}), std.json.fmt(p.ref, .{}), std.json.fmt(ref_purl, .{}) });
        try writeProps(w, props.items);
        try w.writeAll("}");
    }
    try w.writeAll(if (idx.len == 0) "],\n" else "\n  ],\n");

    try w.print("  \"dependencies\": [\n    {{\"ref\": {f}, \"dependsOn\": [", .{std.json.fmt(root_name, .{})});
    for (idx, 0..) |pi, n| {
        const p = lock.packages[pi];
        if (n > 0) try w.writeAll(", ");
        try w.print("{f}", .{std.json.fmt(try purl(a, p.repo, p.resolved), .{})});
    }
    try w.writeAll("]}\n  ]\n}\n");
    return out.written();
}

test "purl: github ve genel depo" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("pkg:github/o/r@abc", try purl(a, "github.com/o/r", "abc"));
    try std.testing.expectEqualStrings("pkg:generic/git.example.com/x/y@v1", try purl(a, "git.example.com/x/y", "v1"));
}

test "scanSource: extern def kitaplıkları, lowlevel, yorumlar yok sayılır" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var libs: std.StringArrayHashMapUnmanaged(void) = .empty;
    var info: NativeInfo = .{};
    try scanSource(a,
        \\# extern def fake() -> int from "ignored"
        \\extern def f(x: int) -> int from "libm"
        \\extern def g() -> None from "libm"
        \\extern def h() -> None from "zlib"
        \\def ok() -> None:
        \\    lowlevel:
        \\        pass
    , &libs, &info);
    try std.testing.expect(info.has_extern and info.lowlevel);
    try std.testing.expectEqual(@as(usize, 2), libs.count());
    try std.testing.expect(libs.contains("libm") and libs.contains("zlib") and !libs.contains("ignored"));
}
