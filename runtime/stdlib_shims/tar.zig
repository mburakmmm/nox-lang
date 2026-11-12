//! `nox.tar` Zig kabuğu (v2.1.71): ustar biçiminde tar paketleme/açma. Veri Nox `str` içinde ham bayt olarak taşınır (ikili güvenli).
//!   - `nox_tar_pack_raw(names: list[str], datas: list[str]) -> str`: adı `/` ile biten girdi dizindir (veri yok sayılır). Çıktı Python `tarfile` ustar çıktısıyla bayt-bayt aynıdır
//!     (mode 0644/0755, uid/gid/mtime 0, 10240 baytlık kayıt hizası); 100 baytı aşan adlar `prefix/name` olarak bölünür (≤ 155 + 100), sığmazsa hata.
//!   - `nox_tar_unpack_raw(data: str) -> list[str]`: düz liste `[ad0, veri0, ad1, veri1, ...]`; ustar, GNU `L` uzun adı ve PAX `x` (`path`, `size`) başlıkları okunur,
//!     düz dosya ve dizin dışındakiler (bağlantı, aygıt) atlanır. Geçersiz/kısaltılmış arşiv `nox_tar_valid_raw` ile ayırt edilir (sağlama toplamı denetlenir).
//! Hata ayıklama kolaylığı için `nox_tar_last_ok` (iş parçacığına yerel) son işlemin başarısını bildirir.

const std = @import("std");
const arc = @import("../alloc/arc.zig");
const abi_layout = @import("abi_layout");
const str_mod = @import("../str.zig");
const scratch_util = @import("shim_util.zig");

const LIST_HEADER_SIZE = abi_layout.LIST_HEADER_SIZE;
const FIELD_SLOT_SIZE = abi_layout.FIELD_SLOT_SIZE;
const BLOCK = 512;
const RECORD = 10240;

const LastOkSlot = scratch_util.TlsSlot(bool, true);

pub export fn nox_tar_last_ok() callconv(.c) i64 {
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

fn putOctal(dst: []u8, value: u64) void {
    // dst.len - 1 basamak, sol sıfır dolgulu, NUL sonlu
    var v = value;
    var i = dst.len - 1;
    dst[i] = 0;
    while (i > 0) {
        i -= 1;
        dst[i] = '0' + @as(u8, @intCast(v & 7));
        v >>= 3;
    }
}

fn writeHeader(block: *[BLOCK]u8, name: []const u8, size: u64, is_dir: bool) bool {
    @memset(block, 0);
    var name_part = name;
    var prefix_part: []const u8 = "";
    if (name.len > 100) {
        // Python tarfile (3.12+) gibi: en soldaki '/' konumunu seç ki kalan ad ≤ 100 ve önek ≤ 155 olsun
        var split: ?usize = null;
        for (name, 0..) |ch, idx| {
            if (ch == '/' and idx > 0 and idx <= 155 and name.len - idx - 1 <= 100 and name.len - idx - 1 > 0) {
                split = idx;
                break;
            }
        }
        const sp = split orelse return false;
        prefix_part = name[0..sp];
        name_part = name[sp + 1 ..];
    }
    @memcpy(block[0..name_part.len], name_part);
    putOctal(block[100..108], if (is_dir) 0o755 else 0o644);
    putOctal(block[108..116], 0);
    putOctal(block[116..124], 0);
    putOctal(block[124..136], if (is_dir) 0 else size);
    putOctal(block[136..148], 0);
    @memset(block[148..156], ' ');
    block[156] = if (is_dir) '5' else '0';
    @memcpy(block[257..263], "ustar\x00");
    @memcpy(block[263..265], "00");
    // devmajor/devminor: Python ustar çıktısında düz dosya/dizin için NUL kalır
    @memcpy(block[345 .. 345 + prefix_part.len], prefix_part);
    var sum: u64 = 0;
    for (block) |b| sum += b;
    putOctal(block[148..155], sum); // 6 basamak + NUL (7 bayt: Python "%06o\0 ")
    // putOctal 7 baytlık alanda 6 basamak + NUL yazar; ardından boşluk
    block[154] = 0;
    block[155] = ' ';
    return true;
}

pub export fn nox_tar_pack_raw(rt: ?*anyopaque, names: ?*anyopaque, datas: ?*anyopaque) callconv(.c) ?[*:0]u8 {
    const a = scratch_util.scratchAllocator();
    const n = listLen(names);
    if (listLen(datas) != n) return fail(rt);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    var block: [BLOCK]u8 = undefined;
    for (0..n) |i| {
        const name = listStr(names, i);
        const is_dir = name.len > 0 and name[name.len - 1] == '/';
        const data: []const u8 = if (is_dir) &.{} else listStr(datas, i);
        if (name.len == 0) return fail(rt);
        if (!writeHeader(&block, name, data.len, is_dir)) return fail(rt);
        out.appendSlice(a, &block) catch return fail(rt);
        out.appendSlice(a, data) catch return fail(rt);
        const pad = (BLOCK - data.len % BLOCK) % BLOCK;
        out.appendNTimes(a, 0, pad) catch return fail(rt);
    }
    out.appendNTimes(a, 0, 2 * BLOCK) catch return fail(rt);
    const rem = out.items.len % RECORD;
    if (rem != 0) out.appendNTimes(a, 0, RECORD - rem) catch return fail(rt);
    LastOkSlot.value = true;
    return str_mod.nox_str_from_bytes(rt, out.items);
}

fn fail(rt: ?*anyopaque) ?[*:0]u8 {
    LastOkSlot.value = false;
    _ = rt;
    return @constCast(str_mod.nox_empty_str());
}

fn parseOctal(field: []const u8) ?u64 {
    if (field.len > 0 and field[0] & 0x80 != 0) {
        // GNU base-256
        var v: u64 = field[0] & 0x7f;
        for (field[1..]) |b| v = (v << 8) | b;
        return v;
    }
    var v: u64 = 0;
    var seen = false;
    for (field) |c| {
        if (c == 0 or c == ' ') {
            if (seen) break;
            continue;
        }
        if (c < '0' or c > '7') return null;
        v = (v << 3) | (c - '0');
        seen = true;
    }
    return v;
}

fn cstr(field: []const u8) []const u8 {
    return field[0 .. std.mem.indexOfScalar(u8, field, 0) orelse field.len];
}

fn checksumOk(block: *const [BLOCK]u8) bool {
    const stored = parseOctal(block[148..156]) orelse return false;
    var sum: u64 = 0;
    for (block, 0..) |b, i| sum += if (i >= 148 and i < 156) ' ' else b;
    return sum == stored;
}

const Entry = struct { name: []const u8, data: []const u8 };

fn paxValue(records: []const u8, key: []const u8) ?[]const u8 {
    var i: usize = 0;
    var found: ?[]const u8 = null;
    while (i < records.len) {
        const sp = std.mem.indexOfScalarPos(u8, records, i, ' ') orelse break;
        const len = std.fmt.parseUnsigned(usize, records[i..sp], 10) catch break;
        if (len == 0 or i + len > records.len) break;
        const rec = records[sp + 1 .. i + len - 1]; // sondaki '\n' hariç
        if (std.mem.indexOfScalar(u8, rec, '=')) |eq| {
            if (std.mem.eql(u8, rec[0..eq], key)) found = rec[eq + 1 ..];
        }
        i += len;
    }
    return found;
}

/// Arşivi çözer; geçersizse `null`. Girdiler `a`dan tahsis edilir.
fn parse(a: std.mem.Allocator, data: []const u8, entries: *std.ArrayList(Entry), owned: *std.ArrayList([]u8)) bool {
    var pos: usize = 0;
    var long_name: ?[]const u8 = null;
    var pax_path: ?[]const u8 = null;
    var pax_size: ?u64 = null;
    while (pos + BLOCK <= data.len) {
        const block: *const [BLOCK]u8 = data[pos..][0..BLOCK];
        if (std.mem.allEqual(u8, block, 0)) return true;
        if (!checksumOk(block)) return false;
        var size = parseOctal(block[124..136]) orelse return false;
        const typeflag = block[156];
        pos += BLOCK;
        if (pax_size) |s| {
            if (typeflag != 'x' and typeflag != 'g') size = s;
        }
        if (size > data.len or pos + size > data.len) return false;
        const body = data[pos .. pos + @as(usize, @intCast(size))];
        pos += (@as(usize, @intCast(size)) + BLOCK - 1) / BLOCK * BLOCK;
        switch (typeflag) {
            'L' => long_name = cstr(body),
            'x' => {
                pax_path = paxValue(body, "path");
                if (paxValue(body, "size")) |sv| pax_size = std.fmt.parseUnsigned(u64, sv, 10) catch null;
            },
            'g', 'K' => {},
            '0', 0, '5' => {
                var name: []const u8 = undefined;
                if (long_name) |l| {
                    name = l;
                } else if (pax_path) |p| {
                    name = p;
                } else {
                    const base = cstr(block[0..100]);
                    const magic = block[257..262];
                    const prefix = if (std.mem.eql(u8, magic, "ustar")) cstr(block[345..500]) else "";
                    if (prefix.len > 0) {
                        const joined = std.fmt.allocPrint(a, "{s}/{s}", .{ prefix, base }) catch return false;
                        owned.append(a, joined) catch return false;
                        name = joined;
                    } else name = base;
                }
                var is_dir = typeflag == '5';
                if (name.len > 0 and name[name.len - 1] == '/') is_dir = true;
                if (is_dir and (name.len == 0 or name[name.len - 1] != '/')) {
                    const withslash = std.fmt.allocPrint(a, "{s}/", .{name}) catch return false;
                    owned.append(a, withslash) catch return false;
                    name = withslash;
                }
                entries.append(a, .{ .name = name, .data = if (is_dir) &.{} else body }) catch return false;
                long_name = null;
                pax_path = null;
                pax_size = null;
            },
            else => {
                long_name = null;
                pax_path = null;
                pax_size = null;
            },
        }
    }
    // sıfır bloğu görmeden, blok hizalı bittiyse kabul (GNU tar gibi uyarıyla); artık bayt kalmışsa kısaltılmıştır.
    return pos == data.len;
}

pub export fn nox_tar_unpack_raw(rt: ?*anyopaque, data: ?[*:0]const u8) callconv(.c) ?*anyopaque {
    const a = scratch_util.scratchAllocator();
    const bytes = str_mod.nox_str_slice(data orelse return buildStrList(rt, &.{}));
    var entries: std.ArrayList(Entry) = .empty;
    defer entries.deinit(a);
    var owned: std.ArrayList([]u8) = .empty;
    defer {
        for (owned.items) |o| a.free(o);
        owned.deinit(a);
    }
    if (!parse(a, bytes, &entries, &owned)) {
        LastOkSlot.value = false;
        return buildStrList(rt, &.{});
    }
    var flat = a.alloc([]const u8, entries.items.len * 2) catch {
        LastOkSlot.value = false;
        return buildStrList(rt, &.{});
    };
    defer a.free(flat);
    for (entries.items, 0..) |e, i| {
        flat[i * 2] = e.name;
        flat[i * 2 + 1] = e.data;
    }
    LastOkSlot.value = true;
    return buildStrList(rt, flat);
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

test "tar: paketle-aç gidiş-dönüş, 10240 hizası, bozuk sağlama toplamı reddi" {
    const asap = @import("../alloc/asap.zig");
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);
    const names = buildStrList(rt, &.{ "dir/", "dir/a.txt", "b.bin" }) orelse return error.Failed;
    defer releaseStrList(rt, names);
    const datas = buildStrList(rt, &.{ "", "hello", "\x00\xff\x01" }) orelse return error.Failed;
    defer releaseStrList(rt, datas);
    const packed_ = nox_tar_pack_raw(rt, names, datas) orelse return error.Failed;
    defer str_mod.nox_str_release(rt, packed_);
    try std.testing.expectEqual(@as(i64, 1), nox_tar_last_ok());
    const bytes = str_mod.nox_str_slice(packed_);
    try std.testing.expectEqual(@as(usize, 10240), bytes.len);
    const flat = nox_tar_unpack_raw(rt, packed_) orelse return error.Failed;
    defer releaseStrList(rt, flat);
    try std.testing.expectEqual(@as(i64, 1), nox_tar_last_ok());
    try std.testing.expectEqual(@as(usize, 6), listLen(flat));
    try std.testing.expectEqualStrings("dir/", listStr(flat, 0));
    try std.testing.expectEqualStrings("dir/a.txt", listStr(flat, 2));
    try std.testing.expectEqualStrings("hello", listStr(flat, 3));
    try std.testing.expectEqualSlices(u8, "\x00\xff\x01", listStr(flat, 5));
    // bozuk sağlama toplamı
    var copy = try std.testing.allocator.dupe(u8, bytes);
    defer std.testing.allocator.free(copy);
    copy[0] ^= 0x55;
    const bad = str_mod.nox_str_from_bytes(rt, copy) orelse return error.Failed;
    defer str_mod.nox_str_release(rt, bad);
    const none = nox_tar_unpack_raw(rt, bad);
    defer releaseStrList(rt, none);
    try std.testing.expectEqual(@as(i64, 0), nox_tar_last_ok());
}
