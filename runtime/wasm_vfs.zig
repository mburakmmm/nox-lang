//! `wasm32-freestanding` için bellek içi sanal dosya sistemi (spec §3.349). Freestanding modülde işletim sistemi yoktur (ADR-013); `nox.fs` ve `nox.sqlite`
//! dosya tabanlı veritabanları bu VFS üzerinde çalışır. Ağaç çalışma zamanının doğrusal belleğinde yaşar: host'a (tarayıcı, Node, Nexus) hiçbir import eklemez, sunucuya
//! ya da gerçek diske hiçbir şey yazılmaz (playground için güvenli), `--threads` kipinde iş parçacıkları arasında paylaşılır (küçük bir döner kilit). Ömrü programın
//! ömrüdür: çıkışta içerik kaybolur. Kalıcılık ya da gerçek bir dizine eşleme, ileride `nox_host`a eklenecek isteğe bağlı import'larla yapılabilir (kırıcı değildir).
//!
//! Model: düz bir `yol -> girdi` tablosu (`std.StringHashMap`); yollar kurala göre normalleştirilir (`.`/`..`/çift `/` ayıklanır, göreli yollar kök `/` altında çözülür,
//! `nox.os.current_dir()` zaten `"/"` döner). Dizinler boş girdilerdir, dosyalar sayaçlı (`refs`) `File` nesneleridir: açık bir tanıtıcı varken `remove` edilen dosya,
//! tanıtıcı kapanana kadar yaşar (POSIX `unlink` semantiği). Sistem çağrısı benzeri hatalar `null`/`-1`/`false` döner; `nox.fs` bunu `FsError`a çevirir.

const std = @import("std");
const builtin = @import("builtin");
const host = @import("wasm_host.zig");

const gpa = std.heap.page_allocator;

pub const Mode = enum { read, write, append, read_write };

const File = struct {
    data: std.ArrayListUnmanaged(u8) = .empty,
    mtime_ms: i64 = 0,
    refs: u32 = 1,

    fn release(self: *File) void {
        self.refs -= 1;
        if (self.refs == 0) {
            self.data.deinit(gpa);
            gpa.destroy(self);
        }
    }
};

/// `file == null` bir dizindir.
const Entry = struct { file: ?*File };

const Handle = struct { file: *File, pos: usize, readable: bool, writable: bool, append: bool };

pub const Info = struct { size: i64, mtime_ms: i64, is_dir: bool };

var g_entries: std.StringHashMapUnmanaged(Entry) = .empty;
var g_handles: std.ArrayListUnmanaged(?Handle) = .empty;
var g_ready: bool = false;

/// Tanıtıcı numaraları 3'ten başlar (0/1/2 stdin/stdout/stderr gibi görünsün).
const first_fd: usize = 3;

const needs_lock = !builtin.single_threaded;
var g_lock: std.atomic.Value(u8) = .init(0);

fn lock() void {
    if (comptime needs_lock) {
        while (g_lock.cmpxchgWeak(0, 1, .acquire, .monotonic) != null) {}
    }
}

fn unlock() void {
    if (comptime needs_lock) g_lock.store(0, .release);
}

fn now() i64 {
    // Yerel birim testlerinde `nox_host` import'u yoktur; saat orada sabit 0'dır.
    return if (comptime host.is_freestanding_wasm) host.clock_ms(0) else 0;
}

fn putDir(path: []const u8) bool {
    const key = gpa.dupe(u8, path) catch return false;
    g_entries.put(gpa, key, .{ .file = null }) catch {
        gpa.free(key);
        return false;
    };
    return true;
}

/// Kök `/` ve `/tmp` (wasm32-wasi'nin ön-açımlarıyla aynı: `.` ve `/tmp`) ilk kullanımda oluşturulur.
fn ensureReady() bool {
    if (g_ready) return true;
    if (!putDir("/") or !putDir("/tmp")) return false;
    g_ready = true;
    return true;
}

/// `path`i mutlak, normalleştirilmiş bir yola çevirir (çağıran sahip olur). `..` kökün üstüne çıkmaz.
fn normalize(path: []const u8) ?[]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);
    var depth_starts: std.ArrayListUnmanaged(usize) = .empty;
    defer depth_starts.deinit(gpa);
    var it = std.mem.tokenizeScalar(u8, path, '/');
    while (it.next()) |part| {
        if (std.mem.eql(u8, part, ".")) continue;
        if (std.mem.eql(u8, part, "..")) {
            if (depth_starts.pop()) |start| out.shrinkRetainingCapacity(start);
            continue;
        }
        depth_starts.append(gpa, out.items.len) catch return null;
        out.append(gpa, '/') catch return null;
        out.appendSlice(gpa, part) catch return null;
    }
    if (out.items.len == 0) out.append(gpa, '/') catch return null;
    return out.toOwnedSlice(gpa) catch null;
}

fn parentOf(norm: []const u8) []const u8 {
    if (norm.len <= 1) return "/";
    const slash = std.mem.lastIndexOfScalar(u8, norm, '/') orelse return "/";
    return if (slash == 0) "/" else norm[0..slash];
}

fn parentIsDir(norm: []const u8) bool {
    const e = g_entries.get(parentOf(norm)) orelse return false;
    return e.file == null;
}

fn allocHandle(h: Handle) i32 {
    for (g_handles.items, 0..) |slot, i| {
        if (slot == null) {
            g_handles.items[i] = h;
            return @intCast(first_fd + i);
        }
    }
    g_handles.append(gpa, h) catch return -1;
    return @intCast(first_fd + g_handles.items.len - 1);
}

fn handleAt(fd: i32) ?*Handle {
    if (fd < first_fd) return null;
    const i: usize = @intCast(fd - @as(i32, @intCast(first_fd)));
    if (i >= g_handles.items.len) return null;
    if (g_handles.items[i]) |*h| return h;
    return null;
}

/// Dosyayı açar (gerekirse oluşturur). `write` içeriği keser, `append` sona ekler, `read_write` ne keser ne ekler (SQLite için). Başarısızlıkta `-1`.
pub fn open(path: []const u8, mode: Mode) i32 {
    lock();
    defer unlock();
    if (!ensureReady()) return -1;
    const norm = normalize(path) orelse return -1;
    var owned = true;
    defer if (owned) gpa.free(norm);
    var file: *File = undefined;
    if (g_entries.get(norm)) |e| {
        file = e.file orelse return -1; // bir dizin
        file.refs += 1;
        if (mode == .write) {
            file.data.clearRetainingCapacity();
            file.mtime_ms = now();
        }
    } else {
        if (mode == .read) return -1;
        if (!parentIsDir(norm)) return -1;
        file = gpa.create(File) catch return -1;
        file.* = .{ .mtime_ms = now(), .refs = 2 }; // 1 tablo girdisi + 1 tanıtıcı
        g_entries.put(gpa, norm, .{ .file = file }) catch {
            gpa.destroy(file);
            return -1;
        };
        owned = false; // anahtar tabloya geçti
    }
    const fd = allocHandle(.{
        .file = file,
        .pos = if (mode == .append) file.data.items.len else 0,
        .readable = mode == .read or mode == .read_write,
        .writable = mode != .read,
        .append = mode == .append,
    });
    if (fd < 0) file.release();
    return fd;
}

pub fn close(fd: i32) void {
    lock();
    defer unlock();
    const h = handleAt(fd) orelse return;
    h.file.release();
    g_handles.items[@intCast(fd - @as(i32, @intCast(first_fd)))] = null;
}

pub fn read(fd: i32, buf: []u8) isize {
    lock();
    defer unlock();
    const h = handleAt(fd) orelse return -1;
    if (!h.readable) return -1;
    const data = h.file.data.items;
    if (h.pos >= data.len) return 0;
    const n = @min(buf.len, data.len - h.pos);
    @memcpy(buf[0..n], data[h.pos .. h.pos + n]);
    h.pos += n;
    return @intCast(n);
}

fn writeAt(file: *File, pos: usize, bytes: []const u8) bool {
    const end = pos + bytes.len;
    if (end > file.data.items.len) {
        const old = file.data.items.len;
        file.data.resize(gpa, end) catch return false;
        if (pos > old) @memset(file.data.items[old..pos], 0); // `seek` ile aşılan boşluk sıfırlanır
    }
    @memcpy(file.data.items[pos..end], bytes);
    file.mtime_ms = now();
    return true;
}

pub fn write(fd: i32, bytes: []const u8) isize {
    lock();
    defer unlock();
    const h = handleAt(fd) orelse return -1;
    if (!h.writable) return -1;
    if (h.append) h.pos = h.file.data.items.len;
    if (!writeAt(h.file, h.pos, bytes)) return -1;
    h.pos += bytes.len;
    return @intCast(bytes.len);
}

/// Mutlak konuma gider; yeni konumu döner, hata `-1`.
pub fn seek(fd: i32, offset: i64) i64 {
    lock();
    defer unlock();
    const h = handleAt(fd) orelse return -1;
    if (offset < 0) return -1;
    h.pos = @intCast(offset);
    return offset;
}

pub fn fstat(fd: i32) ?Info {
    lock();
    defer unlock();
    const h = handleAt(fd) orelse return null;
    return .{ .size = @intCast(h.file.data.items.len), .mtime_ms = h.file.mtime_ms, .is_dir = false };
}

/// SQLite `xRead`: `pos`u hareket ettirmeden `off` konumundan okur; dosya sonunu aşan kısım okunmaz (dönen sayı `buf.len`den küçük olur).
pub fn pread(fd: i32, buf: []u8, off: u64) isize {
    lock();
    defer unlock();
    const h = handleAt(fd) orelse return -1;
    const data = h.file.data.items;
    if (off >= data.len) return 0;
    const start: usize = @intCast(off);
    const n = @min(buf.len, data.len - start);
    @memcpy(buf[0..n], data[start .. start + n]);
    return @intCast(n);
}

pub fn pwrite(fd: i32, bytes: []const u8, off: u64) isize {
    lock();
    defer unlock();
    const h = handleAt(fd) orelse return -1;
    if (!h.writable) return -1;
    if (!writeAt(h.file, @intCast(off), bytes)) return -1;
    return @intCast(bytes.len);
}

pub fn truncate(fd: i32, size: u64) bool {
    lock();
    defer unlock();
    const h = handleAt(fd) orelse return false;
    if (!h.writable) return false;
    const new_len: usize = @intCast(size);
    const old = h.file.data.items.len;
    h.file.data.resize(gpa, new_len) catch return false;
    if (new_len > old) @memset(h.file.data.items[old..new_len], 0);
    h.file.mtime_ms = now();
    return true;
}

pub fn stat(path: []const u8) ?Info {
    lock();
    defer unlock();
    if (!ensureReady()) return null;
    const norm = normalize(path) orelse return null;
    defer gpa.free(norm);
    const e = g_entries.get(norm) orelse return null;
    if (e.file) |f| return .{ .size = @intCast(f.data.items.len), .mtime_ms = f.mtime_ms, .is_dir = false };
    return .{ .size = 0, .mtime_ms = 0, .is_dir = true };
}

/// `realpath` karşılığı: yol VARSA mutlak, normalleştirilmiş hali (çağıran `gpa` ile serbest bırakır), yoksa `null`. Sembolik bağ olmadığından yalnızca `.`/`..` çözülür.
pub fn canonicalPath(path: []const u8) ?[]u8 {
    lock();
    defer unlock();
    if (!ensureReady()) return null;
    const norm = normalize(path) orelse return null;
    if (!g_entries.contains(norm)) {
        gpa.free(norm);
        return null;
    }
    return norm;
}

/// Bir dosyayı siler (dizin silmez). Açık tanıtıcılar kapanana kadar içerik yaşar.
pub fn remove(path: []const u8) bool {
    lock();
    defer unlock();
    if (!ensureReady()) return false;
    const norm = normalize(path) orelse return false;
    defer gpa.free(norm);
    const e = g_entries.get(norm) orelse return false;
    const f = e.file orelse return false;
    const kv = g_entries.fetchRemove(norm) orelse return false;
    gpa.free(kv.key);
    f.release();
    return true;
}

pub fn createDir(path: []const u8) bool {
    lock();
    defer unlock();
    if (!ensureReady()) return false;
    const norm = normalize(path) orelse return false;
    var owned = true;
    defer if (owned) gpa.free(norm);
    if (g_entries.contains(norm)) return false;
    if (!parentIsDir(norm)) return false;
    g_entries.put(gpa, norm, .{ .file = null }) catch return false;
    owned = false;
    return true;
}

fn isUnder(key: []const u8, dir: []const u8) bool {
    if (key.len <= dir.len) return false;
    if (!std.mem.startsWith(u8, key, dir)) return false;
    return dir.len == 1 or key[dir.len] == '/';
}

/// `path` dizinindeki doğrudan çocukların adlarını `names`e ekler (çağıran her adı `gpa` ile serbest bırakır). Dizin yoksa `false`.
pub fn readDir(path: []const u8, names: *std.ArrayListUnmanaged([]const u8)) bool {
    lock();
    defer unlock();
    if (!ensureReady()) return false;
    const norm = normalize(path) orelse return false;
    defer gpa.free(norm);
    const e = g_entries.get(norm) orelse return false;
    if (e.file != null) return false;
    var it = g_entries.iterator();
    while (it.next()) |kv| {
        const key = kv.key_ptr.*;
        if (!isUnder(key, norm)) continue;
        const rest = key[if (norm.len == 1) 1 else norm.len + 1 ..];
        if (std.mem.indexOfScalar(u8, rest, '/') != null) continue; // torun, doğrudan çocuk değil
        const owned = gpa.dupe(u8, rest) catch return false;
        names.append(gpa, owned) catch {
            gpa.free(owned);
            return false;
        };
    }
    return true;
}

/// Dosya ya da dizini yeniden adlandırır/taşır. Hedef bir dosyaysa değiştirilir (POSIX); hedef bir dizinse ya da hedefin ebeveyni yoksa başarısız olur.
pub fn rename(old_path: []const u8, new_path: []const u8) bool {
    lock();
    defer unlock();
    if (!ensureReady()) return false;
    const from = normalize(old_path) orelse return false;
    defer gpa.free(from);
    const to = normalize(new_path) orelse return false;
    var to_owned = true;
    defer if (to_owned) gpa.free(to);
    if (std.mem.eql(u8, from, "/")) return false;
    const src = g_entries.get(from) orelse return false;
    if (std.mem.eql(u8, from, to)) return true;
    if (!parentIsDir(to)) return false;
    if (src.file == null and isUnder(to, from)) return false; // dizini kendi altına taşıma
    if (g_entries.get(to)) |dst| {
        if (dst.file == null or src.file == null) return false; // dizin hedefi (ya da dizini dosyanın üstüne) desteklenmez
        const kv = g_entries.fetchRemove(to).?;
        gpa.free(kv.key);
        dst.file.?.release();
    }
    if (src.file != null) {
        const kv = g_entries.fetchRemove(from).?;
        gpa.free(kv.key);
        g_entries.put(gpa, to, src) catch return false;
        to_owned = false;
        return true;
    }
    // Dizin: kendisi ve altındaki tüm girdiler yeni önekle yeniden anahtarlanır.
    var moved: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (moved.items) |k| gpa.free(k);
        moved.deinit(gpa);
    }
    var it = g_entries.iterator();
    while (it.next()) |kv| {
        const key = kv.key_ptr.*;
        if (std.mem.eql(u8, key, from) or isUnder(key, from)) {
            const dup = gpa.dupe(u8, key) catch return false;
            moved.append(gpa, dup) catch {
                gpa.free(dup);
                return false;
            };
        }
    }
    for (moved.items) |old_key| {
        const entry = g_entries.get(old_key).?;
        const suffix = old_key[from.len..];
        const new_key = std.mem.concat(gpa, u8, &.{ to, suffix }) catch return false;
        const removed = g_entries.fetchRemove(old_key).?;
        gpa.free(removed.key);
        g_entries.put(gpa, new_key, entry) catch {
            gpa.free(new_key);
            return false;
        };
    }
    return true;
}

// ---- Host köprüsü: önyükleme (preload) ve anlık görüntü (snapshot) ---------------------------------------------------------------------------------------------
// Host sanal dosya sistemini kalıcı kılmak için (Node `--vfs-dir`, tarayıcıda IndexedDB/OPFS) modül başlamadan ağacı doldurur ve çıkışta anlık görüntüsünü alır.
// Hiçbir import gerektirmez: host dışa aktarımları (`runtime/wasm_vfs_host.zig`) çağırır, belleği doğrudan okur/yazar; kilit sayesinde `--threads`te de güvenlidir.

/// `path` ve üstündeki tüm dizinleri oluşturur (`mkdir -p`); var olan bir DOSYA yolu engellerse `false`. Çağıran kilidi tutar.
fn mkdirAllLocked(norm: []const u8) bool {
    if (g_entries.get(norm)) |e| return e.file == null;
    if (!mkdirAllLocked(parentOf(norm))) return false;
    return putDir(norm);
}

/// Dizin (ve gerekirse üstleri) oluşturur. Var olan dizin başarıdır.
pub fn hostMkdirAll(path: []const u8) bool {
    lock();
    defer unlock();
    if (!ensureReady()) return false;
    const norm = normalize(path) orelse return false;
    defer gpa.free(norm);
    return mkdirAllLocked(norm);
}

/// Dosyayı (üst dizinleriyle) oluşturur ya da içeriğini değiştirir.
pub fn hostPut(path: []const u8, data: []const u8) bool {
    lock();
    defer unlock();
    if (!ensureReady()) return false;
    const norm = normalize(path) orelse return false;
    defer gpa.free(norm);
    if (std.mem.eql(u8, norm, "/")) return false;
    if (!mkdirAllLocked(parentOf(norm))) return false;
    if (g_entries.get(norm)) |e| {
        const f = e.file orelse return false; // dizin dosyayla değiştirilmez
        f.data.clearRetainingCapacity();
        f.data.appendSlice(gpa, data) catch return false;
        f.mtime_ms = now();
        return true;
    }
    const f = gpa.create(File) catch return false;
    f.* = .{ .mtime_ms = now() };
    f.data.appendSlice(gpa, data) catch {
        gpa.destroy(f);
        return false;
    };
    const key = gpa.dupe(u8, norm) catch {
        f.data.deinit(gpa);
        gpa.destroy(f);
        return false;
    };
    g_entries.put(gpa, key, .{ .file = f }) catch {
        gpa.free(key);
        f.data.deinit(gpa);
        gpa.destroy(f);
        return false;
    };
    return true;
}

fn lessPath(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// Tüm ağacın (kök hariç) serileştirilmiş görüntüsü; çağıran `gpa` ile serbest bırakır. Kayıt: `u8 tür (0 dizin, 1 dosya)`, `u32 yol uzunluğu`, yol, `u32 veri uzunluğu`,
/// veri (hepsi küçük-endian). Kayıtlar yola göre sıralıdır, yani ebeveyn çocuktan önce gelir.
pub fn snapshot() ?[]u8 {
    lock();
    defer unlock();
    if (!ensureReady()) return null;
    var keys: std.ArrayListUnmanaged([]const u8) = .empty;
    defer keys.deinit(gpa);
    var it = g_entries.iterator();
    while (it.next()) |kv| {
        if (kv.key_ptr.*.len <= 1) continue;
        keys.append(gpa, kv.key_ptr.*) catch return null;
    }
    std.mem.sort([]const u8, keys.items, {}, lessPath);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);
    for (keys.items) |key| {
        const e = g_entries.get(key).?;
        const data: []const u8 = if (e.file) |f| f.data.items else &.{};
        out.append(gpa, if (e.file != null) 1 else 0) catch return null;
        out.appendSlice(gpa, &std.mem.toBytes(std.mem.nativeToLittle(u32, @intCast(key.len)))) catch return null;
        out.appendSlice(gpa, key) catch return null;
        out.appendSlice(gpa, &std.mem.toBytes(std.mem.nativeToLittle(u32, @intCast(data.len)))) catch return null;
        out.appendSlice(gpa, data) catch return null;
    }
    return out.toOwnedSlice(gpa) catch null;
}

// ---- Testler (yerel; global tablo kullanıldığından her test kendi yolunu kullanır) ------------------------------------------------------------------------------

fn expectNormalized(input: []const u8, want: []const u8) !void {
    const got = normalize(input) orelse return error.OutOfMemory;
    defer gpa.free(got);
    try std.testing.expectEqualStrings(want, got);
}

test "normalize: ., .., cift / ve goreli yollar" {
    try expectNormalized("", "/");
    try expectNormalized("/", "/");
    try expectNormalized("a/b", "/a/b");
    try expectNormalized("/a//b/./c/", "/a/b/c");
    try expectNormalized("/a/b/../c", "/a/c");
    try expectNormalized("/../..", "/");
    try expectNormalized("../x", "/x");
}

test "dosya: yaz, oku, seek, ekle, kes, pread/pwrite" {
    try std.testing.expect(createDir("/t_file"));
    const w = open("/t_file/a.txt", .write);
    try std.testing.expect(w >= 3);
    try std.testing.expectEqual(@as(isize, 5), write(w, "hello"));
    try std.testing.expectEqual(@as(isize, -1), read(w, &.{})); // yazma tanıtıcısı okunamaz
    close(w);

    const a = open("/t_file/a.txt", .append);
    try std.testing.expectEqual(@as(isize, 6), write(a, " world"));
    close(a);

    const r = open("t_file/../t_file/a.txt", .read); // goreli + ..
    var buf: [32]u8 = undefined;
    try std.testing.expectEqual(@as(isize, 11), read(r, &buf));
    try std.testing.expectEqualStrings("hello world", buf[0..11]);
    try std.testing.expectEqual(@as(isize, 0), read(r, &buf)); // dosya sonu
    try std.testing.expectEqual(@as(i64, 6), seek(r, 6));
    try std.testing.expectEqual(@as(isize, 5), read(r, &buf));
    try std.testing.expectEqualStrings("world", buf[0..5]);
    try std.testing.expectEqual(@as(isize, -1), write(r, "x")); // okuma tanıtıcısı yazılamaz
    try std.testing.expectEqual(@as(i64, 11), fstat(r).?.size);
    close(r);

    const rw = open("/t_file/a.txt", .read_write); // keser de eklemez de
    try std.testing.expectEqual(@as(isize, 3), pwrite(rw, "XYZ", 20)); // bosluk sifirlanir
    try std.testing.expectEqual(@as(i64, 23), fstat(rw).?.size);
    var tail: [4]u8 = undefined;
    try std.testing.expectEqual(@as(isize, 3), pread(rw, &tail, 20));
    var gap: [2]u8 = undefined;
    try std.testing.expectEqual(@as(isize, 2), pread(rw, &gap, 12));
    try std.testing.expectEqualSlices(u8, &.{ 0, 0 }, &gap);
    try std.testing.expect(truncate(rw, 5));
    try std.testing.expectEqual(@as(i64, 5), fstat(rw).?.size);
    close(rw);

    const t = open("/t_file/a.txt", .write); // write kipi icerigi keser
    try std.testing.expectEqual(@as(i64, 0), fstat(t).?.size);
    close(t);
}

test "hatalar: ebeveyn yok, dizin dosya olarak acilamaz, olmayan dosya okunamaz" {
    try std.testing.expectEqual(@as(i32, -1), open("/t_err_yok/a.txt", .write));
    try std.testing.expectEqual(@as(i32, -1), open("/t_err_yok.txt", .read));
    try std.testing.expect(createDir("/t_err"));
    try std.testing.expect(!createDir("/t_err")); // var
    try std.testing.expect(!createDir("/t_err_yok2/alt")); // ebeveyn yok
    try std.testing.expectEqual(@as(i32, -1), open("/t_err", .read)); // dizin
    try std.testing.expect(!remove("/t_err")); // remove dizin silmez
    try std.testing.expect(!remove("/t_err/yok"));
    try std.testing.expectEqual(@as(isize, -1), read(999, &.{}));
    try std.testing.expectEqual(@as(i64, -1), seek(999, 0));
    const f = open("/t_err/f", .write);
    try std.testing.expectEqual(@as(i64, -1), seek(f, -1));
    close(f);
    close(f); // cift kapatma zararsiz
}

test "stat ve readDir: dogrudan cocuklar, torunlar degil" {
    try std.testing.expect(createDir("/t_dir"));
    try std.testing.expect(createDir("/t_dir/sub"));
    var fd = open("/t_dir/a", .write);
    close(fd);
    fd = open("/t_dir/sub/deep", .write);
    close(fd);
    const info = stat("/t_dir").?;
    try std.testing.expect(info.is_dir);
    try std.testing.expect(!stat("/t_dir/a").?.is_dir);
    try std.testing.expect(stat("/t_dir/yok") == null);

    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (names.items) |n| gpa.free(n);
        names.deinit(gpa);
    }
    try std.testing.expect(readDir("/t_dir", &names));
    try std.testing.expectEqual(@as(usize, 2), names.items.len);
    var saw_a = false;
    var saw_sub = false;
    for (names.items) |n| {
        if (std.mem.eql(u8, n, "a")) saw_a = true;
        if (std.mem.eql(u8, n, "sub")) saw_sub = true;
    }
    try std.testing.expect(saw_a and saw_sub);
    var none: std.ArrayListUnmanaged([]const u8) = .empty;
    defer none.deinit(gpa);
    try std.testing.expect(!readDir("/t_dir/a", &none)); // dosya dizin degil
    try std.testing.expect(!readDir("/t_dir/yok", &none));
}

test "rename: dosya degistirir, dizin alt agacla tasinir, kendi altina tasinamaz" {
    try std.testing.expect(createDir("/t_mv"));
    var fd = open("/t_mv/x", .write);
    _ = write(fd, "X");
    close(fd);
    fd = open("/t_mv/y", .write);
    _ = write(fd, "Y");
    close(fd);
    try std.testing.expect(rename("/t_mv/x", "/t_mv/y")); // hedef dosya degistirilir
    try std.testing.expect(stat("/t_mv/x") == null);
    try std.testing.expectEqual(@as(i64, 1), stat("/t_mv/y").?.size);

    try std.testing.expect(createDir("/t_mv/d"));
    try std.testing.expect(createDir("/t_mv/d/e"));
    fd = open("/t_mv/d/e/f", .write);
    _ = write(fd, "abc");
    close(fd);
    try std.testing.expect(!rename("/t_mv/d", "/t_mv/d/e/in")); // kendi altina
    try std.testing.expect(rename("/t_mv/d", "/t_mv/z"));
    try std.testing.expect(stat("/t_mv/d") == null);
    try std.testing.expect(stat("/t_mv/z/e").?.is_dir);
    try std.testing.expectEqual(@as(i64, 3), stat("/t_mv/z/e/f").?.size);
    try std.testing.expect(!rename("/t_mv/yok", "/t_mv/q"));
    try std.testing.expect(!rename("/t_mv/y", "/t_mv/z")); // hedef dizin
    try std.testing.expect(!rename("/", "/t_mv/root"));
}

test "canonicalPath: var olan yolu normallestirir, olmayani reddeder" {
    try std.testing.expect(createDir("/t_canon"));
    const got = canonicalPath("t_canon/../t_canon/./").?;
    defer gpa.free(got);
    try std.testing.expectEqualStrings("/t_canon", got);
    try std.testing.expect(canonicalPath("/t_canon/yok") == null);
}

test "unlink semantigi: acik tanitici varken silinen dosya kapanana kadar yasar" {
    try std.testing.expect(createDir("/t_unlink"));
    const w = open("/t_unlink/f", .write);
    _ = write(w, "data");
    try std.testing.expect(remove("/t_unlink/f"));
    try std.testing.expect(stat("/t_unlink/f") == null);
    try std.testing.expectEqual(@as(isize, 3), write(w, "123")); // hala yazilabilir
    try std.testing.expectEqual(@as(i64, 7), fstat(w).?.size);
    close(w); // son tanitici: bellek serbest (GPA sizdirma denetimi yok ama cift serbest birakma olmamali)
    const again = open("/t_unlink/f", .write);
    try std.testing.expectEqual(@as(i64, 0), fstat(again).?.size); // yeni, bos dosya
    close(again);
}

test "tanitici numaralari 3'ten baslar ve kapaninca yeniden kullanilir" {
    try std.testing.expect(createDir("/t_fd"));
    const a = open("/t_fd/a", .write);
    const b = open("/t_fd/b", .write);
    try std.testing.expect(a >= 3 and b > a);
    close(a);
    const c = open("/t_fd/c", .write);
    try std.testing.expectEqual(a, c);
    close(b);
    close(c);
}

test "hostPut/hostMkdirAll/snapshot: onyukleme ve anlik goruntu gidis-donus" {
    try std.testing.expect(hostMkdirAll("/t_snap/bos"));
    try std.testing.expect(hostPut("/t_snap/a/b.txt", "içerik")); // ust dizinler kendiliginden olusur
    try std.testing.expect(hostPut("/t_snap/a/b.txt", "yeni")); // uzerine yazar
    try std.testing.expect(!hostPut("/t_snap/a", "x")); // dizin dosyayla degistirilmez
    try std.testing.expect(!hostMkdirAll("/t_snap/a/b.txt/alt")); // dosya yolu engeller
    const fd = open("/t_snap/a/b.txt", .read);
    var buf: [8]u8 = undefined;
    try std.testing.expectEqual(@as(isize, 4), read(fd, &buf));
    try std.testing.expectEqualStrings("yeni", buf[0..4]);
    close(fd);

    const snap = snapshot().?;
    defer gpa.free(snap);
    // Kayitlari ayristir; /t_snap altindakileri topla.
    var i: usize = 0;
    var seen_dir = false;
    var seen_file = false;
    while (i < snap.len) {
        const kind = snap[i];
        const plen = std.mem.readInt(u32, snap[i + 1 ..][0..4], .little);
        const path = snap[i + 5 ..][0..plen];
        const dlen = std.mem.readInt(u32, snap[i + 5 + plen ..][0..4], .little);
        const data = snap[i + 9 + plen ..][0..dlen];
        i += 9 + plen + dlen;
        if (std.mem.eql(u8, path, "/t_snap/bos")) {
            try std.testing.expectEqual(@as(u8, 0), kind);
            seen_dir = true;
        }
        if (std.mem.eql(u8, path, "/t_snap/a/b.txt")) {
            try std.testing.expectEqual(@as(u8, 1), kind);
            try std.testing.expectEqualStrings("yeni", data);
            seen_file = true;
        }
    }
    try std.testing.expect(seen_dir and seen_file);
}
