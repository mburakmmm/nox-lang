//! v2.0.136: `noxc login` jetonlarının yerel deposu — `<NOX_HOME>/credentials` (varsayılan `~/.nox/credentials`).
//!
//! Biçim: `{"servers": [{"server": "https://noxpkg.noxlang.com", "token": "nxp_...", "login": "kullanici"}]}`. Dosya POSIX'te `0600`
//! ile yazılır (yalnızca sahibi okur; Windows'ta kullanıcı profilinin ACL'si geçerlidir). Sunucu başına bir kayıt: `noxc login` aynı
//! sunucuya yeniden girince kaydın üzerine yazar. Jeton, noxpkg'in kendi API jetonudur (GitHub jetonu burada ASLA saklanmaz, bkz.
//! `services/noxpkg/github.nox`); sunucu yalnızca SHA-256 özetini tutar, bu dosyadaki jeton tek kopyadır.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const Entry = struct {
    server: []const u8,
    token: []const u8,
    login: []const u8 = "",
};

const FileShape = struct {
    servers: []const Entry = &.{},
};

pub fn path(a: Allocator, nox_home: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "{s}/credentials", .{nox_home});
}

/// Sunucu adresini karşılaştırma için normalleştirir: sondaki `/` atılır (`https://x/` ile `https://x` aynı sunucudur).
fn normalized(server: []const u8) []const u8 {
    return std.mem.trimEnd(u8, server, "/");
}

/// Kayıtları okur. Dosya yoksa boş liste; bozuksa `error.CredentialsCorrupt` (sessizce boş sayılmaz: kullanıcı kayıtlarını
/// kaybettiğini fark etmeli, `noxc login` dosyanın üzerine yazar).
pub fn load(a: Allocator, io: Io, nox_home: []const u8) ![]const Entry {
    const p = try path(a, nox_home);
    const text = std.Io.Dir.cwd().readFileAlloc(io, p, a, .limited(1024 * 1024)) catch |e| switch (e) {
        error.FileNotFound => return &.{},
        else => return e,
    };
    const parsed = std.json.parseFromSlice(FileShape, a, text, .{ .ignore_unknown_fields = true }) catch return error.CredentialsCorrupt;
    return parsed.value.servers;
}

pub fn find(entries: []const Entry, server: []const u8) ?Entry {
    for (entries) |e| {
        if (std.mem.eql(u8, normalized(e.server), normalized(server))) return e;
    }
    return null;
}

/// `entry`yi ekler; aynı sunucu için kayıt varsa değiştirir. Yeni bir dilim döner.
pub fn upsert(a: Allocator, entries: []const Entry, entry: Entry) ![]const Entry {
    var list: std.ArrayListUnmanaged(Entry) = .empty;
    for (entries) |e| {
        if (std.mem.eql(u8, normalized(e.server), normalized(entry.server))) continue;
        try list.append(a, e);
    }
    try list.append(a, .{ .server = normalized(entry.server), .token = entry.token, .login = entry.login });
    return list.items;
}

pub fn remove(a: Allocator, entries: []const Entry, server: []const u8) ![]const Entry {
    var list: std.ArrayListUnmanaged(Entry) = .empty;
    for (entries) |e| {
        if (std.mem.eql(u8, normalized(e.server), normalized(server))) continue;
        try list.append(a, e);
    }
    return list.items;
}

/// Dosyayı `0600` ile yazar. `writeFile` var olan bir dosyanın izinlerini DARALTMAZ (yalnızca oluştururken uygular); önceki bir
/// sürümün ya da elle oluşturulmuş geniş izinli bir dosya jetonu sızdırmasın diye önce silinir, sonra yeniden oluşturulur.
pub fn save(a: Allocator, io: Io, nox_home: []const u8, entries: []const Entry) !void {
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, nox_home);
    const p = try path(a, nox_home);
    const text = try std.json.Stringify.valueAlloc(a, FileShape{ .servers = entries }, .{ .whitespace = .indent_2 });
    cwd.deleteFile(io, p) catch {};
    try cwd.writeFile(io, .{
        .sub_path = p,
        .data = text,
        .flags = .{ .permissions = if (builtin.os.tag == .windows) .default_file else .fromMode(0o600) },
    });
}

fn tmpHome(io: Io, tmp: *std.testing.TmpDir, buf: []u8) ![]const u8 {
    const n = try tmp.dir.realPath(io, buf);
    return buf[0..n];
}

test "load: dosya yoksa bos liste" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const home = try tmpHome(io, &tmp, &buf);
    const entries = try load(arena.allocator(), io, home);
    try std.testing.expectEqual(@as(usize, 0), entries.len);
}

test "save/load gidis-donus, upsert ayni sunucuyu degistirir, remove siler" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const home = try tmpHome(io, &tmp, &buf);

    var entries: []const Entry = &.{};
    entries = try upsert(a, entries, .{ .server = "https://noxpkg.example/", .token = "nxp_old", .login = "alice" });
    entries = try upsert(a, entries, .{ .server = "https://other.example", .token = "nxp_other", .login = "bob" });
    entries = try upsert(a, entries, .{ .server = "https://noxpkg.example", .token = "nxp_new", .login = "alice" });
    try std.testing.expectEqual(@as(usize, 2), entries.len);
    try save(a, io, home, entries);

    const back = try load(a, io, home);
    try std.testing.expectEqual(@as(usize, 2), back.len);
    // Sondaki "/" fark etmez.
    const mine = find(back, "https://noxpkg.example/") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("nxp_new", mine.token);
    try std.testing.expectEqualStrings("alice", mine.login);
    try std.testing.expect(find(back, "https://yok.example") == null);

    const rest = try remove(a, back, "https://noxpkg.example");
    try std.testing.expectEqual(@as(usize, 1), rest.len);
    try std.testing.expectEqualStrings("https://other.example", rest[0].server);
}

test "load: bozuk JSON sessizce bos sayilmaz" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "credentials", .data = "{ bozuk" });
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const home = try tmpHome(io, &tmp, &buf);
    try std.testing.expectError(error.CredentialsCorrupt, load(arena.allocator(), io, home));
}

test "save: POSIX'te dosya 0600, onceden genis izinli dosya daraltilir" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // Elle oluşturulmuş, herkese açık bir önceki dosya.
    try tmp.dir.writeFile(io, .{ .sub_path = "credentials", .data = "{}", .flags = .{ .permissions = .fromMode(0o644) } });
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const home = try tmpHome(io, &tmp, &buf);
    try save(a, io, home, &.{.{ .server = "https://x.example", .token = "nxp_t", .login = "u" }});
    const st = try tmp.dir.statFile(io, "credentials", .{});
    try std.testing.expectEqual(@as(u32, 0o600), @as(u32, @intCast(st.permissions.toMode() & 0o777)));
}
