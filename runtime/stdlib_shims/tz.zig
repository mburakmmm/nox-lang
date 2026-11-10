//! IANA zaman dilimi desteği (Ember NL-014): sistemin `tzdata` dosyalarından (TZif v2+) bir UTC anının yerel UTC farkını, kısaltmasını ve yaz saati bayrağını hesaplar.
//!
//! Kaynak dizinler: `$TZDIR`, `/usr/share/zoneinfo`, `/var/db/timezone/zoneinfo`, `/usr/share/lib/zoneinfo`, Android `/system/usr/share/zoneinfo`. Dosya her çağrıda okunup ayrıştırılır (durum tutulmaz).
//! Son geçişten sonraki anlar için TZif altbilgisindeki POSIX TZ dizesi (`EST5EDT,M3.2.0,M11.1.0`, `<+03>-3`) değerlendirilir (`Mm.w.d[/saat]` kuralları).
//! Windows, WebAssembly ve freestanding'de tzdata yoktur: `nox_tz_lookup_raw` `-1` (desteklenmiyor) döner. Bilinmeyen/bozuk bölge `-2`.

const std = @import("std");
const builtin = @import("builtin");
const str_mod = @import("../str.zig");
const shim_util = @import("shim_util.zig");

const supported = switch (builtin.os.tag) {
    .windows, .freestanding, .wasi, .other => false,
    else => !builtin.cpu.arch.isWasm(),
};

const gpa = std.heap.page_allocator;

const TType = struct { utoff: i32, isdst: bool, abbr_idx: u8 };

const Zone = struct {
    times: []i64 = &.{},
    idxs: []u8 = &.{},
    types: []TType = &.{},
    abbrs: []u8 = &.{},
    footer: []u8 = &.{},
    raw: []u8 = &.{},

    fn deinit(self: *Zone) void {
        if (self.raw.len > 0) gpa.free(self.raw);
        if (self.times.len > 0) gpa.free(self.times);
        if (self.types.len > 0) gpa.free(self.types);
        self.* = .{};
    }
};

fn be32(b: []const u8) u32 {
    return std.mem.readInt(u32, b[0..4], .big);
}

fn be64s(b: []const u8) i64 {
    return std.mem.readInt(i64, b[0..8], .big);
}

fn abbrAt(z: *const Zone, idx: u8) []const u8 {
    if (idx >= z.abbrs.len) return "";
    const end = std.mem.indexOfScalarPos(u8, z.abbrs, idx, 0) orelse z.abbrs.len;
    return z.abbrs[idx..end];
}

fn parseZone(data: []u8) ?Zone {
    if (data.len < 44 or !std.mem.eql(u8, data[0..4], "TZif")) return null;
    const version = data[4];
    var pos: usize = 0;
    var time_size: usize = 4;
    var counts = [6]u32{ be32(data[20..]), be32(data[24..]), be32(data[28..]), be32(data[32..]), be32(data[36..]), be32(data[40..]) };
    if (version >= '2') {
        // v1 bloğunu atla, ikinci başlık ve 64-bit blok.
        const v1_len: usize = 44 + counts[3] * 4 + counts[3] + counts[4] * 6 + counts[5] + counts[2] * 8 + counts[1] + counts[0];
        if (data.len < v1_len + 44) return null;
        pos = v1_len;
        counts = .{ be32(data[pos + 20 ..]), be32(data[pos + 24 ..]), be32(data[pos + 28 ..]), be32(data[pos + 32 ..]), be32(data[pos + 36 ..]), be32(data[pos + 40 ..]) };
        time_size = 8;
    }
    const isut = counts[0];
    const isstd = counts[1];
    const leap = counts[2];
    const timecnt = counts[3];
    const typecnt = counts[4];
    const charcnt = counts[5];
    var p = pos + 44;
    const need = timecnt * time_size + timecnt + typecnt * 6 + charcnt + leap * (time_size + 4) + isstd + isut;
    if (p + need > data.len or typecnt == 0) return null;
    var z: Zone = .{ .raw = data };
    z.times = gpa.alloc(i64, timecnt) catch return null;
    for (0..timecnt) |i| {
        z.times[i] = if (time_size == 8) be64s(data[p + i * 8 ..]) else @as(i32, @bitCast(be32(data[p + i * 4 ..])));
    }
    p += timecnt * time_size;
    z.idxs = data[p .. p + timecnt];
    p += timecnt;
    z.types = gpa.alloc(TType, typecnt) catch {
        gpa.free(z.times);
        return null;
    };
    for (0..typecnt) |i| {
        z.types[i] = .{ .utoff = @bitCast(be32(data[p + i * 6 ..])), .isdst = data[p + i * 6 + 4] != 0, .abbr_idx = data[p + i * 6 + 5] };
    }
    p += typecnt * 6;
    z.abbrs = data[p .. p + charcnt];
    p += charcnt + leap * (time_size + 4) + isstd + isut;
    if (time_size == 8 and p < data.len and data[p] == '\n') {
        const rest = data[p + 1 ..];
        const end = std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len;
        z.footer = rest[0..end];
    }
    return z;
}

const Result = struct { utoff: i32, isdst: bool, abbr: []const u8 };

// ---- POSIX TZ altbilgisi ------------------------------------------------------------------------------------------------------------------------

const Rule = struct { month: u8 = 0, week: u8 = 0, day: u8 = 0, time: i32 = 7200 };
const Posix = struct {
    std_abbr: []const u8 = "",
    std_off: i32 = 0, // UTC'den saniye (doğu +)
    dst_abbr: []const u8 = "",
    dst_off: i32 = 0,
    has_dst: bool = false,
    start: Rule = .{},
    end: Rule = .{},
};

fn parseAbbr(s: []const u8, i: *usize) ?[]const u8 {
    if (i.* >= s.len) return null;
    if (s[i.*] == '<') {
        const close = std.mem.indexOfScalarPos(u8, s, i.*, '>') orelse return null;
        const a = s[i.* + 1 .. close];
        i.* = close + 1;
        return a;
    }
    const st = i.*;
    while (i.* < s.len and std.ascii.isAlphabetic(s[i.*])) i.* += 1;
    if (i.* - st < 3) return null;
    return s[st..i.*];
}

/// `[+-]hh[:mm[:ss]]` → saniye (işaret dahil).
fn parseHms(s: []const u8, i: *usize) ?i32 {
    var sign: i32 = 1;
    if (i.* < s.len and (s[i.*] == '+' or s[i.*] == '-')) {
        if (s[i.*] == '-') sign = -1;
        i.* += 1;
    }
    var total: i32 = 0;
    var part: usize = 0;
    var mult: i32 = 3600;
    while (part < 3) : (part += 1) {
        const st = i.*;
        var v: i32 = 0;
        while (i.* < s.len and std.ascii.isDigit(s[i.*])) : (i.* += 1) v = v * 10 + @as(i32, s[i.*] - '0');
        if (i.* == st) {
            if (part == 0) return null;
            break;
        }
        total += v * mult;
        mult = @divTrunc(mult, 60);
        if (i.* < s.len and s[i.*] == ':') i.* += 1 else break;
    }
    return sign * total;
}

fn parseRule(s: []const u8, i: *usize) ?Rule {
    var r: Rule = .{};
    if (i.* >= s.len or s[i.*] != 'M') return null; // yalnızca Mm.w.d desteklenir
    i.* += 1;
    var nums: [3]u8 = undefined;
    for (0..3) |k| {
        var v: u32 = 0;
        const st = i.*;
        while (i.* < s.len and std.ascii.isDigit(s[i.*])) : (i.* += 1) v = v * 10 + (s[i.*] - '0');
        if (i.* == st) return null;
        nums[k] = @intCast(v);
        if (k < 2) {
            if (i.* >= s.len or s[i.*] != '.') return null;
            i.* += 1;
        }
    }
    r.month = nums[0];
    r.week = nums[1];
    r.day = nums[2];
    if (i.* < s.len and s[i.*] == '/') {
        i.* += 1;
        r.time = parseHms(s, i) orelse return null;
    }
    return r;
}

fn parsePosix(s: []const u8) ?Posix {
    var p: Posix = .{};
    var i: usize = 0;
    p.std_abbr = parseAbbr(s, &i) orelse return null;
    const so = parseHms(s, &i) orelse return null;
    p.std_off = -so;
    if (i >= s.len) return p;
    p.dst_abbr = parseAbbr(s, &i) orelse return null;
    p.has_dst = true;
    p.dst_off = p.std_off + 3600;
    if (i < s.len and s[i] != ',') {
        const d = parseHms(s, &i) orelse return null;
        p.dst_off = -d;
    }
    if (i >= s.len or s[i] != ',') return null;
    i += 1;
    p.start = parseRule(s, &i) orelse return null;
    if (i >= s.len or s[i] != ',') return null;
    i += 1;
    p.end = parseRule(s, &i) orelse return null;
    return p;
}

fn daysFromCivil(y_in: i64, m: i64, d: i64) i64 {
    const y = if (m <= 2) y_in - 1 else y_in;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const mp = @mod(m + 9, 12);
    const doy = @divFloor(153 * mp + 2, 5) + d - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

fn civilYear(days: i64) i64 {
    const z = days + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const y = yoe + era * 400;
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const m = if (mp < 10) mp + 3 else mp - 9;
    return if (m <= 2) y + 1 else y;
}

/// Kuralın verilen yıldaki YEREL duvar-saati epoch'u (saniye): `Mm.w.d` = m. ayın w. haftasının d. günü (w=5: son).
fn ruleLocalEpoch(y: i64, r: Rule) i64 {
    const first = daysFromCivil(y, r.month, 1);
    const wd_first: i64 = @mod(first + 4, 7); // 1970-01-01 Perşembe (4); 0 = Pazar
    var delta: i64 = @as(i64, r.day) - wd_first;
    if (delta < 0) delta += 7;
    var day = first + delta + (@as(i64, r.week) - 1) * 7;
    const next_month_first = if (r.month == 12) daysFromCivil(y + 1, 1, 1) else daysFromCivil(y, r.month + 1, 1);
    while (day >= next_month_first) day -= 7;
    return day * 86400 + r.time;
}

fn evalPosix(p: Posix, t: i64) Result {
    if (!p.has_dst) return .{ .utoff = p.std_off, .isdst = false, .abbr = p.std_abbr };
    const y = civilYear(@divFloor(t + p.std_off, 86400));
    const start_utc = ruleLocalEpoch(y, p.start) - p.std_off;
    const end_utc = ruleLocalEpoch(y, p.end) - p.dst_off;
    const in_dst = if (start_utc < end_utc) (t >= start_utc and t < end_utc) else (t >= start_utc or t < end_utc);
    if (in_dst) return .{ .utoff = p.dst_off, .isdst = true, .abbr = p.dst_abbr };
    return .{ .utoff = p.std_off, .isdst = false, .abbr = p.std_abbr };
}

fn lookup(z: *const Zone, t: i64) Result {
    if (z.times.len == 0 or t < z.times[0]) {
        // İlk geçişten önce: ilk standart (dst olmayan) tür, yoksa tür 0.
        var ti: usize = 0;
        for (z.types, 0..) |ty, k| {
            if (!ty.isdst) {
                ti = k;
                break;
            }
        }
        if (z.times.len == 0 and z.footer.len > 0) {
            if (parsePosix(z.footer)) |pp| return evalPosix(pp, t);
        }
        const ty = z.types[ti];
        return .{ .utoff = ty.utoff, .isdst = ty.isdst, .abbr = abbrAt(z, ty.abbr_idx) };
    }
    // Son geçiş ≤ t.
    var lo: usize = 0;
    var hi: usize = z.times.len;
    while (lo + 1 < hi) {
        const mid = (lo + hi) / 2;
        if (z.times[mid] <= t) lo = mid else hi = mid;
    }
    if (lo == z.times.len - 1 and z.footer.len > 0) {
        if (parsePosix(z.footer)) |pp| return evalPosix(pp, t);
    }
    const ty = z.types[z.idxs[lo]];
    return .{ .utoff = ty.utoff, .isdst = ty.isdst, .abbr = abbrAt(z, ty.abbr_idx) };
}

fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64 or name[0] == '/' or name[0] == '.') return false;
    if (std.mem.indexOf(u8, name, "..") != null) return false;
    for (name) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '/' or c == '_' or c == '-' or c == '+')) return false;
    }
    return true;
}

fn readZoneFile(name: []const u8) ?[]u8 {
    var dirs_buf: [5][]const u8 = undefined;
    var n: usize = 0;
    if (std.c.getenv("TZDIR")) |d| {
        dirs_buf[n] = std.mem.span(d);
        n += 1;
    }
    for ([_][]const u8{ "/usr/share/zoneinfo", "/var/db/timezone/zoneinfo", "/usr/share/lib/zoneinfo", "/system/usr/share/zoneinfo" }) |d| {
        if (n < dirs_buf.len) {
            dirs_buf[n] = d;
            n += 1;
        }
    }
    for (dirs_buf[0..n]) |dir| {
        var path_buf: [512]u8 = undefined;
        const path = std.fmt.bufPrintZ(&path_buf, "{s}/{s}", .{ dir, name }) catch continue;
        var oflags: std.c.O = .{};
        oflags.ACCMODE = .RDONLY;
        const fd = std.c.open(path.ptr, oflags, @as(c_uint, 0));
        if (fd < 0) continue;
        defer _ = std.c.close(fd);
        var out: std.ArrayListUnmanaged(u8) = .empty;
        var chunk: [8192]u8 = undefined;
        while (true) {
            const r = std.c.read(fd, &chunk, chunk.len);
            if (r < 0) {
                out.deinit(gpa);
                break;
            }
            if (r == 0) return out.toOwnedSlice(gpa) catch null;
            out.appendSlice(gpa, chunk[0..@intCast(r)]) catch {
                out.deinit(gpa);
                break;
            };
            if (out.items.len > 1 << 20) {
                out.deinit(gpa);
                break;
            }
        }
    }
    return null;
}

/// `nox_tz_offset_raw` hata sentinelleri (gerçek UTC farkları ±1 gün içindedir).
const ERR_UNSUPPORTED: i64 = std.math.minInt(i64);
const ERR_UNKNOWN: i64 = std.math.minInt(i64) + 1;

const Lookup = union(enum) { ok: Result, unsupported, unknown };

/// Bölgeyi çözer; kısaltma, `Zone` serbest bırakıldıktan sonra da geçerli kalsın diye çağıranın `abbr_out` arabelleğine kopyalanır (durum tutulmaz).
fn resolve(zone: ?[*:0]const u8, unix_s: i64, abbr_out: *[16]u8, abbr_len: *usize) Lookup {
    abbr_len.* = 0;
    const zp = zone orelse return .unknown;
    const name = str_mod.nox_str_slice(zp);
    if (std.mem.eql(u8, name, "UTC") or std.mem.eql(u8, name, "Etc/UTC") or std.mem.eql(u8, name, "GMT")) {
        const a = "UTC";
        @memcpy(abbr_out[0..a.len], a);
        abbr_len.* = a.len;
        return .{ .ok = .{ .utoff = 0, .isdst = false, .abbr = abbr_out[0..a.len] } };
    }
    if (comptime !supported) return .unsupported;
    if (!validName(name)) return .unknown;
    const data = readZoneFile(name) orelse return .unknown;
    var z = parseZone(data) orelse {
        gpa.free(data);
        return .unknown;
    };
    defer z.deinit();
    const r = lookup(&z, unix_s);
    const n = @min(r.abbr.len, abbr_out.len);
    @memcpy(abbr_out[0..n], r.abbr[0..n]);
    abbr_len.* = n;
    return .{ .ok = .{ .utoff = r.utoff, .isdst = r.isdst, .abbr = abbr_out[0..n] } };
}

/// `zone` bölgesinin UTC `unix_s` anındaki UTC farkı (saniye); desteklenmiyorsa `ERR_UNSUPPORTED`, bilinmeyen/bozuk bölge ise `ERR_UNKNOWN`.
pub export fn nox_tz_offset_raw(zone: ?[*:0]const u8, unix_s: i64) callconv(.c) i64 {
    var buf: [16]u8 = undefined;
    var len: usize = 0;
    return switch (resolve(zone, unix_s, &buf, &len)) {
        .ok => |r| r.utoff,
        .unsupported => ERR_UNSUPPORTED,
        .unknown => ERR_UNKNOWN,
    };
}

/// Yaz saati bayrağı (1/0); hata durumunda `nox_tz_offset_raw` ile aynı sentinel.
pub export fn nox_tz_isdst_raw(zone: ?[*:0]const u8, unix_s: i64) callconv(.c) i64 {
    var buf: [16]u8 = undefined;
    var len: usize = 0;
    return switch (resolve(zone, unix_s, &buf, &len)) {
        .ok => |r| if (r.isdst) 1 else 0,
        .unsupported => ERR_UNSUPPORTED,
        .unknown => ERR_UNKNOWN,
    };
}

/// Bölge kısaltması (`CET`, `EDT`, `+03`); hata durumunda boş dize (çağıran önce `nox_tz_offset_raw` ile doğrular).
pub export fn nox_tz_abbr_raw(rt: ?*anyopaque, zone: ?[*:0]const u8, unix_s: i64) callconv(.c) ?[*:0]u8 {
    var buf: [16]u8 = undefined;
    var len: usize = 0;
    _ = resolve(zone, unix_s, &buf, &len);
    return shim_util.dupeToNoxStr(rt, buf[0..len]);
}

/// tzdata bu makinede okunabilir mi: hedef destekliyor VE bir kaynak dizinde `Etc/UTC` bulunuyor (Windows/wasm/freestanding, tzdata'sız kapsayıcı ve iOS'ta 0).
pub export fn nox_tz_supported_raw() callconv(.c) i64 {
    if (comptime !supported) return 0;
    const data = readZoneFile("Etc/UTC") orelse return 0;
    gpa.free(data);
    return 1;
}

test "tz: POSIX TZ ayrıştırma ve DST kuralı (New York 2024)" {
    const p = parsePosix("EST5EDT,M3.2.0,M11.1.0").?;
    try std.testing.expectEqual(@as(i32, -18000), p.std_off);
    try std.testing.expectEqual(@as(i32, -14400), p.dst_off);
    // 2024-01-15 12:00 UTC → EST; 2024-07-15 12:00 UTC → EDT.
    const jan = evalPosix(p, 1705320000);
    const jul = evalPosix(p, 1721044800);
    try std.testing.expect(!jan.isdst and jan.utoff == -18000);
    try std.testing.expect(jul.isdst and jul.utoff == -14400);
    // DST başlangıcı: 2024-03-10 07:00 UTC (02:00 EST) tam sınır.
    try std.testing.expect(!evalPosix(p, 1710054000 - 1).isdst);
    try std.testing.expect(evalPosix(p, 1710054000).isdst);
}

test "tz: sabit ofsetli ve güney yarımküre kuralı" {
    const t = parsePosix("<+03>-3").?;
    try std.testing.expectEqual(@as(i32, 10800), t.std_off);
    try std.testing.expectEqualStrings("+03", t.std_abbr);
    const syd = parsePosix("AEST-10AEDT,M10.1.0,M4.1.0/3").?;
    // Sydney, 2024-01-15 (yaz, DST) ve 2024-07-15 (kış).
    try std.testing.expect(evalPosix(syd, 1705320000).isdst);
    try std.testing.expect(!evalPosix(syd, 1721044800).isdst);
}
