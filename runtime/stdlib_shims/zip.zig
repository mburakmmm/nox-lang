//! `nox.zip` Zig kabuğu (v2.1.72): ZIP arşivi yazma/okuma (yöntem 0 = depolanmış, 8 = deflate). Veri Nox `str` içinde ham bayt (ikili güvenli).
//! Ham deflate akışı için `gzip.zig`nin (libdeflate / Zig flate) gzip kabı kullanılır: gzip = 10 baytlık başlık + ham deflate + (crc32, isize). Bu yüzden ayrı bir deflate
//! uygulaması yoktur ve açarken gzip kabının CRC32/boyut denetimi ZIP girdisinin bütünlük denetimi olarak da çalışır.
//!   - `nox_zip_pack_raw(names, datas, compress) -> str`: adı `/` ile biten girdi dizindir. Sıkıştırma küçültüyorsa yöntem 8, aksi halde 0. Tarih 1980-01-01, Unix öznitelikleri
//!     (dosya 0644, dizin 0755); UTF-8 olmayan ASCII dışı ad için bayrak biti 11 ayarlanır. ZIP64 desteklenmez (65535 girdi, 4 GiB sınırı → hata).
//!   - `nox_zip_unpack_raw(data) -> list[str]`: `[ad0, veri0, ad1, veri1, ...]`; merkezi dizin esas alınır. Şifreli girdi, ZIP64 ve yöntem 0/8 dışı hata.
//!     Hata → `nox_zip_last_ok() == 0` ve boş liste. Girdi başına açılmış boyut 1 GiB ile sınırlıdır.

const std = @import("std");
const arc = @import("../alloc/arc.zig");
const abi_layout = @import("abi_layout");
const str_mod = @import("../str.zig");
const scratch_util = @import("shim_util.zig");
const gzip = @import("gzip.zig");

const LIST_HEADER_SIZE = abi_layout.LIST_HEADER_SIZE;
const FIELD_SLOT_SIZE = abi_layout.FIELD_SLOT_SIZE;
const LastOkSlot = scratch_util.TlsSlot(bool, true);
const MAX_ENTRY: u64 = 1 << 30;

pub export fn nox_zip_last_ok() callconv(.c) i64 {
    return @intFromBool(LastOkSlot.value);
}

fn listLen(list_ptr: ?*anyopaque) usize {
    const p = list_ptr orelse return 0;
    const base: [*]u8 = @ptrCast(p);
    return @intCast(@as(*align(1) i64, @ptrCast(base)).*);
}

fn listStr(list_ptr: ?*anyopaque, i: usize) []const u8 {
    const base: [*]u8 = @ptrCast(list_ptr.?);
    const slot = base + LIST_HEADER_SIZE + FIELD_SLOT_SIZE * i;
    const addr: usize = @intCast(@as(u64, @bitCast(@as(*align(1) i64, @ptrCast(slot)).*)));
    if (addr == 0) return &.{};
    return str_mod.nox_str_slice(@ptrFromInt(addr));
}

fn buildStrList(rt: ?*anyopaque, parts: []const []const u8) ?*anyopaque {
    const raw = arc.nox_rc_alloc(rt, LIST_HEADER_SIZE + FIELD_SLOT_SIZE * parts.len) orelse return null;
    const bytes: [*]u8 = @ptrCast(raw);
    @as(*align(1) i64, @ptrCast(bytes)).* = @intCast(parts.len);
    @as(*align(1) i64, @ptrCast(bytes + 8)).* = @intCast(parts.len);
    for (parts, 0..) |part, i| {
        const dup = str_mod.nox_str_from_bytes(rt, part) orelse return null;
        const slot = bytes + LIST_HEADER_SIZE + FIELD_SLOT_SIZE * i;
        @as(*align(1) i64, @ptrCast(slot)).* = @as(i64, @bitCast(@as(u64, @intFromPtr(dup))));
    }
    return @ptrCast(bytes);
}

fn failStr() ?[*:0]u8 {
    LastOkSlot.value = false;
    return @constCast(str_mod.nox_empty_str());
}

fn isAscii(s: []const u8) bool {
    for (s) |c| if (c >= 0x80) return false;
    return true;
}

fn put16(out: *std.ArrayList(u8), a: std.mem.Allocator, v: u16) !void {
    var b: [2]u8 = undefined;
    std.mem.writeInt(u16, &b, v, .little);
    try out.appendSlice(a, &b);
}

fn put32(out: *std.ArrayList(u8), a: std.mem.Allocator, v: u32) !void {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, v, .little);
    try out.appendSlice(a, &b);
}

const Central = struct { name: []const u8, method: u16, flags: u16, crc: u32, csize: u32, usize_: u32, offset: u32, external: u32 };

pub export fn nox_zip_pack_raw(rt: ?*anyopaque, names: ?*anyopaque, datas: ?*anyopaque, compress: i64) callconv(.c) ?[*:0]u8 {
    const a = scratch_util.scratchAllocator();
    const n = listLen(names);
    if (listLen(datas) != n or n > 65535) return failStr();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    var cds = a.alloc(Central, n) catch return failStr();
    defer a.free(cds);
    for (0..n) |i| {
        const name = listStr(names, i);
        if (name.len == 0 or name.len > 65535) return failStr();
        const is_dir = name[name.len - 1] == '/';
        const data: []const u8 = if (is_dir) &.{} else listStr(datas, i);
        if (data.len >= 0xFFFFFFFF or out.items.len >= 0xFFFFFFFF - 1024) return failStr();
        const crc = std.hash.Crc32.hash(data);
        var method: u16 = 0;
        var payload: []const u8 = data;
        var packed_buf: ?[]u8 = null;
        defer if (packed_buf) |p| a.free(p);
        if (compress != 0 and data.len > 0) {
            if (gzip.gzipCompress(a, data)) |gz| {
                defer a.free(gz);
                if (gz.len > 18 and gz.len - 18 < data.len) {
                    const raw = a.dupe(u8, gz[10 .. gz.len - 8]) catch return failStr();
                    packed_buf = raw;
                    payload = raw;
                    method = 8;
                }
            } else |_| {}
        }
        const flags: u16 = if (isAscii(name)) 0 else 0x0800;
        const offset: u32 = @intCast(out.items.len);
        const version: u16 = if (method == 8) 20 else 10;
        (blk: {
            put32(&out, a, 0x04034b50) catch break :blk error.OutOfMemory;
            put16(&out, a, version) catch break :blk error.OutOfMemory;
            put16(&out, a, flags) catch break :blk error.OutOfMemory;
            put16(&out, a, method) catch break :blk error.OutOfMemory;
            put16(&out, a, 0) catch break :blk error.OutOfMemory; // saat
            put16(&out, a, 0x0021) catch break :blk error.OutOfMemory; // tarih 1980-01-01
            put32(&out, a, crc) catch break :blk error.OutOfMemory;
            put32(&out, a, @intCast(payload.len)) catch break :blk error.OutOfMemory;
            put32(&out, a, @intCast(data.len)) catch break :blk error.OutOfMemory;
            put16(&out, a, @intCast(name.len)) catch break :blk error.OutOfMemory;
            put16(&out, a, 0) catch break :blk error.OutOfMemory;
            out.appendSlice(a, name) catch break :blk error.OutOfMemory;
            out.appendSlice(a, payload) catch break :blk error.OutOfMemory;
            break :blk {};
        }) catch return failStr();
        cds[i] = .{
            .name = name,
            .method = method,
            .flags = flags,
            .crc = crc,
            .csize = @intCast(payload.len),
            .usize_ = @intCast(data.len),
            .offset = offset,
            .external = if (is_dir) (0o040755 << 16) | 0x10 else (0o100644 << 16),
        };
    }
    const cd_start: u32 = @intCast(out.items.len);
    for (cds) |c| {
        (blk: {
            put32(&out, a, 0x02014b50) catch break :blk error.OutOfMemory;
            put16(&out, a, (3 << 8) | 20) catch break :blk error.OutOfMemory; // oluşturan: Unix, 2.0
            put16(&out, a, if (c.method == 8) 20 else 10) catch break :blk error.OutOfMemory;
            put16(&out, a, c.flags) catch break :blk error.OutOfMemory;
            put16(&out, a, c.method) catch break :blk error.OutOfMemory;
            put16(&out, a, 0) catch break :blk error.OutOfMemory;
            put16(&out, a, 0x0021) catch break :blk error.OutOfMemory;
            put32(&out, a, c.crc) catch break :blk error.OutOfMemory;
            put32(&out, a, c.csize) catch break :blk error.OutOfMemory;
            put32(&out, a, c.usize_) catch break :blk error.OutOfMemory;
            put16(&out, a, @intCast(c.name.len)) catch break :blk error.OutOfMemory;
            put16(&out, a, 0) catch break :blk error.OutOfMemory; // extra
            put16(&out, a, 0) catch break :blk error.OutOfMemory; // yorum
            put16(&out, a, 0) catch break :blk error.OutOfMemory; // disk
            put16(&out, a, 0) catch break :blk error.OutOfMemory; // iç öznitelik
            put32(&out, a, c.external) catch break :blk error.OutOfMemory;
            put32(&out, a, c.offset) catch break :blk error.OutOfMemory;
            out.appendSlice(a, c.name) catch break :blk error.OutOfMemory;
            break :blk {};
        }) catch return failStr();
    }
    const cd_size: u32 = @intCast(out.items.len - cd_start);
    (blk: {
        put32(&out, a, 0x06054b50) catch break :blk error.OutOfMemory;
        put16(&out, a, 0) catch break :blk error.OutOfMemory;
        put16(&out, a, 0) catch break :blk error.OutOfMemory;
        put16(&out, a, @intCast(n)) catch break :blk error.OutOfMemory;
        put16(&out, a, @intCast(n)) catch break :blk error.OutOfMemory;
        put32(&out, a, cd_size) catch break :blk error.OutOfMemory;
        put32(&out, a, cd_start) catch break :blk error.OutOfMemory;
        put16(&out, a, 0) catch break :blk error.OutOfMemory;
        break :blk {};
    }) catch return failStr();
    LastOkSlot.value = true;
    return str_mod.nox_str_from_bytes(rt, out.items);
}

fn rd16(b: []const u8, off: usize) ?u16 {
    if (off + 2 > b.len) return null;
    return std.mem.readInt(u16, b[off..][0..2], .little);
}
fn rd32(b: []const u8, off: usize) ?u32 {
    if (off + 4 > b.len) return null;
    return std.mem.readInt(u32, b[off..][0..4], .little);
}

/// Ham deflate akışını gzip kabına sarıp açar; `expect_crc`/`expect_size` ile bütünlük denetlenir.
fn inflateRaw(a: std.mem.Allocator, raw: []const u8, expect_crc: u32, expect_size: u32) ![]u8 {
    const wrapped = try a.alloc(u8, 10 + raw.len + 8);
    defer a.free(wrapped);
    @memcpy(wrapped[0..10], &[_]u8{ 0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 0, 3 });
    @memcpy(wrapped[10..][0..raw.len], raw);
    std.mem.writeInt(u32, wrapped[10 + raw.len ..][0..4], expect_crc, .little);
    std.mem.writeInt(u32, wrapped[10 + raw.len + 4 ..][0..4], expect_size, .little);
    return gzip.gzipDecompress(a, wrapped);
}

pub export fn nox_zip_unpack_raw(rt: ?*anyopaque, data: ?[*:0]const u8) callconv(.c) ?*anyopaque {
    const a = scratch_util.scratchAllocator();
    const empty = struct {
        fn f(r: ?*anyopaque) ?*anyopaque {
            LastOkSlot.value = false;
            return buildStrList(r, &.{});
        }
    }.f;
    const b = str_mod.nox_str_slice(data orelse return empty(rt));
    if (b.len < 22) return empty(rt);
    // EOCD'yi sondan ara (yorum en çok 65535 bayt)
    var eocd: ?usize = null;
    var pos: usize = b.len - 22;
    const lowest: usize = if (b.len > 22 + 65535) b.len - 22 - 65535 else 0;
    while (true) {
        if (rd32(b, pos) == 0x06054b50) {
            eocd = pos;
            break;
        }
        if (pos == lowest) break;
        pos -= 1;
    }
    const e = eocd orelse return empty(rt);
    const count = rd16(b, e + 10) orelse return empty(rt);
    const cd_size = rd32(b, e + 12) orelse return empty(rt);
    const cd_off = rd32(b, e + 16) orelse return empty(rt);
    if (count == 0xFFFF or cd_size == 0xFFFFFFFF or cd_off == 0xFFFFFFFF) return empty(rt); // ZIP64
    if (@as(u64, cd_off) + cd_size > e) return empty(rt);

    var flat: std.ArrayList([]const u8) = .empty;
    defer flat.deinit(a);
    var owned: std.ArrayList([]u8) = .empty;
    defer {
        for (owned.items) |o| a.free(o);
        owned.deinit(a);
    }
    var p: usize = cd_off;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        if (rd32(b, p) != 0x02014b50) return empty(rt);
        const flags = rd16(b, p + 8) orelse return empty(rt);
        const method = rd16(b, p + 10) orelse return empty(rt);
        const crc = rd32(b, p + 16) orelse return empty(rt);
        const csize = rd32(b, p + 20) orelse return empty(rt);
        const usize_ = rd32(b, p + 24) orelse return empty(rt);
        const nlen = rd16(b, p + 28) orelse return empty(rt);
        const elen = rd16(b, p + 30) orelse return empty(rt);
        const clen = rd16(b, p + 32) orelse return empty(rt);
        const loff = rd32(b, p + 42) orelse return empty(rt);
        if (p + 46 + nlen > b.len) return empty(rt);
        const name = b[p + 46 ..][0..nlen];
        p += 46 + nlen + elen + clen;
        if (flags & 1 != 0) return empty(rt); // şifreli
        if (csize == 0xFFFFFFFF or usize_ == 0xFFFFFFFF or loff == 0xFFFFFFFF) return empty(rt); // ZIP64
        if (usize_ > MAX_ENTRY) return empty(rt);
        // yerel başlık
        if (rd32(b, loff) != 0x04034b50) return empty(rt);
        const lnlen = rd16(b, loff + 26) orelse return empty(rt);
        const lelen = rd16(b, loff + 28) orelse return empty(rt);
        const dstart: usize = @as(usize, loff) + 30 + lnlen + lelen;
        if (dstart + csize > b.len) return empty(rt);
        const payload = b[dstart..][0..csize];
        var content: []const u8 = undefined;
        const is_dir = name.len > 0 and name[name.len - 1] == '/';
        if (is_dir) {
            content = &.{};
        } else switch (method) {
            0 => {
                if (csize != usize_ or std.hash.Crc32.hash(payload) != crc) return empty(rt);
                content = payload;
            },
            8 => {
                const out = inflateRaw(a, payload, crc, usize_) catch return empty(rt);
                if (out.len != usize_) {
                    a.free(out);
                    return empty(rt);
                }
                owned.append(a, out) catch {
                    a.free(out);
                    return empty(rt);
                };
                content = out;
            },
            else => return empty(rt),
        }
        flat.append(a, name) catch return empty(rt);
        flat.append(a, content) catch return empty(rt);
    }
    LastOkSlot.value = true;
    return buildStrList(rt, flat.items);
}

fn releaseStrList(rt: ?*anyopaque, list: ?*anyopaque) void {
    const n = listLen(list);
    const base: [*]u8 = @ptrCast(list.?);
    for (0..n) |i| {
        const slot = base + LIST_HEADER_SIZE + FIELD_SLOT_SIZE * i;
        const addr: usize = @intCast(@as(u64, @bitCast(@as(*align(1) i64, @ptrCast(slot)).*)));
        str_mod.nox_str_release(rt, @ptrFromInt(addr));
    }
    arc.nox_rc_release(rt, list.?, LIST_HEADER_SIZE + FIELD_SLOT_SIZE * n);
}

test "zip: paketle-aç gidiş-dönüş (deflate ve depolanmış), bozuk veri reddi" {
    const asap = @import("../alloc/asap.zig");
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);
    const big = "abcdefgh" ** 400;
    const names = buildStrList(rt, &.{ "d/", "d/a.txt", "e", "ü.bin" }) orelse return error.Failed;
    defer releaseStrList(rt, names);
    const datas = buildStrList(rt, &.{ "", big, "", "\x00\xff\x01" }) orelse return error.Failed;
    defer releaseStrList(rt, datas);
    for ([_]i64{ 1, 0 }) |compress| {
        const z = nox_zip_pack_raw(rt, names, datas, compress) orelse return error.Failed;
        defer str_mod.nox_str_release(rt, z);
        try std.testing.expectEqual(@as(i64, 1), nox_zip_last_ok());
        if (compress == 1) try std.testing.expect(str_mod.nox_str_slice(z).len < big.len);
        const flat = nox_zip_unpack_raw(rt, z) orelse return error.Failed;
        defer releaseStrList(rt, flat);
        try std.testing.expectEqual(@as(i64, 1), nox_zip_last_ok());
        try std.testing.expectEqual(@as(usize, 8), listLen(flat));
        try std.testing.expectEqualStrings("d/a.txt", listStr(flat, 2));
        try std.testing.expectEqualStrings(big, listStr(flat, 3));
        try std.testing.expectEqualSlices(u8, "\x00\xff\x01", listStr(flat, 7));
    }
    const junk = str_mod.nox_str_from_bytes(rt, "definitely not a zip archive!") orelse return error.Failed;
    defer str_mod.nox_str_release(rt, junk);
    const none = nox_zip_unpack_raw(rt, junk);
    defer releaseStrList(rt, none);
    try std.testing.expectEqual(@as(i64, 0), nox_zip_last_ok());
}
