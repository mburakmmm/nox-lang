//! Paket köküne göre HPy artefaktını doğrular ve çalıştırılabilirin yanına
//! kopyalar. Çalışma dizini seçim için kullanılmaz. `hpy_open` bu dosyayı
//! çağırmaz.

const std = @import("std");
const contract = @import("hpy_contract");
const project = @import("../project.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;

pub fn annotateLock(allocator: Allocator, io: Io, cache_dir: []const u8, entry: *project.LockedPackage) !void {
    const text = readManifest(allocator, io, cache_dir) catch |e| switch (e) {
        error.FileNotFound => return,
        else => |err| return err,
    };
    defer allocator.free(text);
    const decision = contract.validateText(allocator, text, contract.hostTarget());
    var accepted = switch (decision) {
        .reject => return error.HpyRejected,
        .ok => |acc| acc,
    };
    defer accepted.deinit();
    try verifyArtifact(allocator, cache_dir, accepted.artifact());
    const m = accepted.manifest();
    entry.hpy_schema = m.schema_version;
    entry.hpy_ahpy_version = try allocator.dupe(u8, m.producer.ahpy_version);
    entry.hpy_source_commit = try allocator.dupe(u8, m.producer.cython_base);
    entry.hpy_abi = try allocator.dupe(u8, m.host.hpy_abi);
    entry.hpy_target = try allocator.dupe(u8, accepted.artifact().target);
    entry.hpy_sha256 = try allocator.dupe(u8, accepted.artifact().sha256);
    entry.hpy_module = try allocator.dupe(u8, m.module.name);
}

pub fn requireComplete(entry: project.LockedPackage, is_hpy: bool) bool {
    if (!is_hpy) return true;
    return entry.hpy_schema == 1 and entry.hpy_sha256.len == 64 and entry.hpy_module.len != 0 and entry.hpy_target.len != 0;
}

pub fn findConflict(packages: []const project.LockedPackage) bool {
    for (packages, 0..) |a, i| {
        for (packages[i + 1 ..]) |b| {
            if (contract.moduleConflict(a.hpy_module, a.hpy_sha256, b.hpy_module, b.hpy_sha256)) return true;
        }
    }
    return false;
}

pub fn stageBesideBinary(allocator: Allocator, io: Io, cache_dir: []const u8, bin_path: []const u8, entry: project.LockedPackage) !void {
    if (entry.hpy_module.len == 0) return;
    if (!requireComplete(entry, true)) return error.HpyRejected;
    const text = try readManifest(allocator, io, cache_dir);
    defer allocator.free(text);
    const decision = contract.validateText(allocator, text, entry.hpy_target);
    var accepted = switch (decision) {
        .reject => return error.HpyRejected,
        .ok => |acc| acc,
    };
    defer accepted.deinit();
    if (!std.mem.eql(u8, accepted.artifact().sha256, entry.hpy_sha256)) return error.HpyRejected;
    const bytes = try readArtifact(allocator, cache_dir, accepted.artifact());
    defer allocator.free(bytes);
    const bin_dir = std.fs.path.dirname(bin_path) orelse ".";
    const dest_dir = try std.fmt.allocPrint(allocator, "{s}/hpy/{s}", .{ bin_dir, entry.hpy_module });
    defer allocator.free(dest_dir);
    try Io.Dir.cwd().createDirPath(io, dest_dir);
    const manifest_path = try std.fmt.allocPrint(allocator, "{s}/nox-hpy.json", .{dest_dir});
    defer allocator.free(manifest_path);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = manifest_path, .data = text });
    var suffix_bytes: [8]u8 = undefined;
    io.random(&suffix_bytes);
    const partial = try std.fmt.allocPrint(allocator, "{s}/{s}.{x}.partial", .{ dest_dir, accepted.artifact().path, std.mem.readInt(u64, &suffix_bytes, .little) });
    defer allocator.free(partial);
    const final_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dest_dir, accepted.artifact().path });
    defer allocator.free(final_path);
    if (std.fs.path.dirname(final_path)) |parent| try Io.Dir.cwd().createDirPath(io, parent);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = partial, .data = bytes });
    if (!contract.digestMatches(bytes, entry.hpy_sha256, accepted.artifact().size)) {
        Io.Dir.cwd().deleteFile(io, partial) catch {};
        return error.HpyRejected;
    }
    try Io.Dir.renameAbsolute(partial, final_path, io);
    const provenance = try std.fmt.allocPrint(allocator, "{s}\n{s}\n{s}\n{s}\n", .{ entry.hpy_sha256, entry.hpy_source_commit, contract.noxc_version, contract.profile });
    defer allocator.free(provenance);
    const provenance_path = try std.fmt.allocPrint(allocator, "{s}.provenance", .{final_path});
    defer allocator.free(provenance_path);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = provenance_path, .data = provenance });
    try copyIfPresent(allocator, io, cache_dir, dest_dir, "LICENSE");
    try copyIfPresent(allocator, io, cache_dir, dest_dir, "NOTICE");
    try copyIfPresent(allocator, io, cache_dir, dest_dir, "SBOM.json");
}

fn copyIfPresent(allocator: Allocator, io: Io, from_dir: []const u8, to_dir: []const u8, name: []const u8) !void {
    const src = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ from_dir, name });
    defer allocator.free(src);
    const data = Io.Dir.cwd().readFileAlloc(io, src, allocator, .limited(8 * 1024 * 1024)) catch |e| switch (e) {
        error.FileNotFound => return,
        else => |err| return err,
    };
    defer allocator.free(data);
    const dest = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ to_dir, name });
    defer allocator.free(dest);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = dest, .data = data });
}

fn readManifest(allocator: Allocator, io: Io, cache_dir: []const u8) ![]u8 {
    const path = try std.fmt.allocPrint(allocator, "{s}/nox-hpy.json", .{cache_dir});
    defer allocator.free(path);
    return Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024));
}

fn verifyArtifact(allocator: Allocator, cache_dir: []const u8, art: contract.Artifact) !void {
    const bytes = try readArtifact(allocator, cache_dir, art);
    defer allocator.free(bytes);
    if (!contract.digestMatches(bytes, art.sha256, art.size)) return error.HpyRejected;
}

fn readArtifact(allocator: Allocator, cache_dir: []const u8, art: contract.Artifact) ![]u8 {
    const root = try allocator.dupeZ(u8, cache_dir);
    defer allocator.free(root);
    return contract.readPackageFile(allocator, root, art.path, 64 * 1024 * 1024);
}

fn dirReal(io: Io, dir: Io.Dir, buf: []u8) ![]const u8 {
    const len = try dir.realPath(io, buf);
    return buf[0..len];
}

test "kesilen kurulum son artefaktı seçmez, tamamlanan kurulum seçer" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var entry: project.LockedPackage = .{ .alias = "sampleext", .repo = "local", .ref = "main", .resolved = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" };
    try annotateLock(a, io, "tests/compat/hpy_host", &entry);

    var parent = std.testing.tmpDir(.{});
    defer parent.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const parent_path = try dirReal(io, parent.dir, &buf);
    const bin_path = try std.fmt.allocPrint(a, "{s}/app", .{parent_path});
    const staged = try std.fmt.allocPrint(a, "{s}/hpy/sampleext/artifacts/sample.hpy0", .{parent_path});
    const leftover = try std.fmt.allocPrint(a, "{s}/hpy/sampleext/artifacts/sample.hpy0.deadbeef.partial", .{parent_path});

    try Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(leftover).?);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = leftover, .data = "kesildi" });
    if (std.Io.Dir.accessAbsolute(io, staged, .{})) |_| return error.StaleArtifactSelected else |_| {}

    try stageBesideBinary(a, io, "tests/compat/hpy_host", bin_path, entry);
    const final_bytes = try Io.Dir.cwd().readFileAlloc(io, staged, a, .limited(8 * 1024 * 1024));
    try std.testing.expect(contract.digestMatches(final_bytes, entry.hpy_sha256, @intCast(final_bytes.len)));
    try std.testing.expect(!std.mem.eql(u8, final_bytes, "kesildi"));
    forgetStaged(a, io, parent_path, "sampleext");
    if (std.Io.Dir.accessAbsolute(io, staged, .{})) |_| return error.StaleArtifactSelected else |_| {}
    try stageBesideBinary(a, io, "tests/compat/hpy_host", bin_path, entry);
    try std.Io.Dir.cwd().access(io, staged, .{});
}

test "aynı modül adı farklı özette çakışır" {
    const left: project.LockedPackage = .{ .alias = "a", .repo = "r", .ref = "main", .resolved = "aa", .hpy_module = "sampleext", .hpy_sha256 = "aaa" };
    const same: project.LockedPackage = .{ .alias = "b", .repo = "r", .ref = "main", .resolved = "bb", .hpy_module = "sampleext", .hpy_sha256 = "aaa" };
    const other: project.LockedPackage = .{ .alias = "c", .repo = "r", .ref = "main", .resolved = "cc", .hpy_module = "sampleext", .hpy_sha256 = "bbb" };
    const plain: project.LockedPackage = .{ .alias = "d", .repo = "r", .ref = "main", .resolved = "dd" };
    try std.testing.expect(!findConflict(&.{ left, same, plain }));
    try std.testing.expect(findConflict(&.{ left, other }));
    try std.testing.expect(requireComplete(plain, false));
    try std.testing.expect(!requireComplete(plain, true));
}

pub fn forgetStaged(allocator: Allocator, io: Io, bin_dir: []const u8, module_name: []const u8) void {
    if (module_name.len == 0) return;
    const dest = std.fmt.allocPrint(allocator, "{s}/hpy/{s}", .{ bin_dir, module_name }) catch return;
    defer allocator.free(dest);
    Io.Dir.cwd().deleteTree(io, dest) catch {};
}
