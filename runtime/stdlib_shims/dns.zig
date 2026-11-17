//! `nox.dns` (v2.1.195): açık DNS çözümlemesi. `nox.http` bağlanırken ana makine adını KENDİSİ tekrar çözer; SSRF/DNS-rebinding savunması isteyen çağıranın "çöz, doğrula, o IP'ye bağlan"
//! diyebilmesi için çözümleme ayrı bir adım olarak sunulur (`nox.http.request(..., connect_ip=...)` ile birlikte kullanılır). Çözümleme `net_dial.zig`nin sınırlı (son tarihli, singleflight,
//! iş parçacığı sınırlı) `getaddrinfo`sunu kullanır; fiber içinde yalnızca çağıran fiber bekler. Yetenek: `network` (reddedilirse durum 4).

const std = @import("std");
const builtin = @import("builtin");
const shim_util = @import("shim_util.zig");
/// wasm'da (tarayıcı/WASI) sistem çözümleyicisi yoktur: çağıran açık bir DoH (DNS-over-HTTPS JSON) adresi verip host `fetch` yeteneği varsa çözümleme o adrese yapılır (2.3 madde 2.7),
/// aksi halde "desteklenmiyor" (durum 5) döner. Varsayılan bir üçüncü taraf çözümleyici YOKTUR: ana makine adları yalnızca çağıranın seçtiği sunucuya gider.
const is_wasm = builtin.cpu.arch.isWasm();
const doh_enabled = is_wasm and @import("../wasm_host.zig").is_freestanding_wasm and @import("wasm_options").asyncify;
const doh_fetch = if (doh_enabled) @import("http_fetch.zig") else struct {};
const net_dial = if (is_wasm) struct {
    pub const enabled = false;
    pub fn resolveHost(_: []const u8, _: u64, _: anytype) error{ TimedOut, Failed, Unsupported }!usize {
        return error.Unsupported;
    }
} else @import("net_dial.zig");
const http_client = if (is_wasm) struct {
    pub fn networkDenied() bool {
        return false;
    }
} else @import("http_client.zig");
const str_mod = @import("../str.zig");

const gpa = std.heap.page_allocator;
const IpAddress = std.Io.net.IpAddress;

const Handle = struct {
    /// 0 = tamam, 1 = zaman aşımı, 2 = çözülemedi, 3 = geçersiz ad, 4 = `network` yeteneği yok, 5 = bu hedefte desteklenmiyor.
    status: i64 = 2,
    count: usize = 0,
    addrs: [16]IpAddress = undefined,
};

/// `host` adını `timeout_ms` (0 = üst sınırlı süresiz) içinde çözer. Daima bir tutamak döner (`nox_dns_status_raw`); yalnızca bellek yetersizliğinde `null`.
pub export fn nox_dns_resolve_raw(host: ?[*:0]const u8, timeout_ms: i64, doh_url: ?[*:0]const u8) callconv(.c) ?*anyopaque {
    const h = gpa.create(Handle) catch return null;
    h.* = .{};
    const name = str_mod.nox_str_slice(host orelse return h);
    if (comptime doh_enabled) {
        const doh = if (doh_url) |u| str_mod.nox_str_slice(u) else "";
        if (doh.len > 0) {
            resolveDoh(h, name, doh, timeout_ms);
            return h;
        }
    }
    if (http_client.networkDenied()) {
        h.status = 4;
        return h;
    }
    const n = net_dial.resolveHost(name, if (timeout_ms > 0) @intCast(timeout_ms) else 0, &h.addrs) catch |e| {
        h.status = switch (e) {
            error.TimedOut => 1,
            error.Failed => 2,
            error.Unsupported => 5,
        };
        return h;
    };
    h.count = n;
    h.status = 0;
    return h;
}

/// Ana makine adı DoH isteğinde yalnızca bu karakterleri taşıyabilir (URL/sorgu enjeksiyonunu önler); IP literal'ler ve `localhost` ağ kullanmadan çözülür.
fn validDnsName(name: []const u8) bool {
    if (name.len == 0 or name.len > 253) return false;
    for (name) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '.' or c == '_')) return false;
    }
    return true;
}

fn addAddr(h: *Handle, a: IpAddress) void {
    if (h.count >= h.addrs.len) return;
    h.addrs[h.count] = a;
    h.count += 1;
}

/// `doh` adresine (`?name=<ad>&type=A|AAAA`, `application/dns-json` gövdesi: `{"Status":0,"Answer":[{"type":1,"data":"..."}]}`) host `fetch`i üzerinden sorar.
/// Durum: ağ yeteneği yok -> 4, zaman aşımı -> 1, geçersiz ad -> 3, bulunamadı/hata -> 2. A ve AAAA ayrı sorgudur; biri yanıt verirse başarılıdır.
fn resolveDoh(h: *Handle, name: []const u8, doh: []const u8, timeout_ms: i64) void {
    if (comptime !doh_enabled) return;
    // IP literal ve localhost ağ kullanmaz.
    const lit = if (name.len > 1 and name[0] == '[' and name[name.len - 1] == ']') name[1 .. name.len - 1] else name;
    if (IpAddress.parse(lit, 0)) |a| {
        addAddr(h, a);
        h.status = 0;
        return;
    } else |_| {}
    if (std.ascii.eqlIgnoreCase(name, "localhost")) {
        addAddr(h, IpAddress.parse("127.0.0.1", 0) catch unreachable);
        addAddr(h, IpAddress.parse("::1", 0) catch unreachable);
        h.status = 0;
        return;
    }
    if (!validDnsName(name)) {
        h.status = 3;
        return;
    }
    if (!doh_fetch.available()) {
        h.status = 4;
        return;
    }
    var worst: i64 = 2;
    const types = [_][]const u8{ "A", "AAAA" };
    for (types) |t| {
        var url_buf: [1024]u8 = undefined;
        const sep: []const u8 = if (std.mem.indexOfScalar(u8, doh, '?') != null) "&" else "?";
        const url = std.fmt.bufPrint(&url_buf, "{s}{s}name={s}&type={s}", .{ doh, sep, name, t }) catch {
            h.status = 3;
            return;
        };
        const resp = doh_fetch.request("GET", url, null, null, timeout_ms) orelse {
            worst = 2;
            continue;
        };
        defer doh_fetch.responseFree(resp);
        if (!resp.ok) {
            worst = switch (resp.error_kind) {
                1 => 1,
                4 => 4,
                else => 2,
            };
            if (worst == 4) {
                h.status = 4;
                return;
            }
            continue;
        }
        if (resp.status != 200) continue;
        parseDohAnswers(h, resp.body);
    }
    h.status = if (h.count > 0) 0 else worst;
}

/// DoH JSON gövdesinden A (1) / AAAA (28) yanıtlarını `h`ye ekler; bozuk gövde sessizce yok sayılır (adres yoksa çağıran "çözülemedi" der).
fn parseDohAnswers(h: *Handle, body: []const u8) void {
    var parsed = std.json.parseFromSlice(std.json.Value, gpa, body, .{}) catch return;
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |o| o,
        else => return,
    };
    if (root.get("Status")) |st| switch (st) {
        .integer => |i| if (i != 0) return,
        else => {},
    };
    const answers = switch (root.get("Answer") orelse return) {
        .array => |a| a,
        else => return,
    };
    for (answers.items) |item| {
        const o = switch (item) {
            .object => |x| x,
            else => continue,
        };
        const ty = switch (o.get("type") orelse continue) {
            .integer => |i| i,
            else => continue,
        };
        if (ty != 1 and ty != 28) continue;
        const data = switch (o.get("data") orelse continue) {
            .string => |sv| sv,
            else => continue,
        };
        const addr = IpAddress.parse(data, 0) catch continue;
        if ((ty == 1 and addr != .ip4) or (ty == 28 and addr != .ip6)) continue;
        addAddr(h, addr);
    }
}

pub export fn nox_dns_status_raw(h: ?*anyopaque) callconv(.c) i64 {
    const handle: *Handle = @ptrCast(@alignCast(h orelse return 2));
    return handle.status;
}

pub export fn nox_dns_count_raw(h: ?*anyopaque) callconv(.c) i64 {
    const handle: *Handle = @ptrCast(@alignCast(h orelse return 0));
    return @intCast(handle.count);
}

/// `i`. adres, bağlantı noktasız metin biçiminde (`203.0.113.7` / `2001:db8::1`).
pub export fn nox_dns_at_raw(rt: ?*anyopaque, h: ?*anyopaque, i: i64) callconv(.c) ?[*:0]u8 {
    const handle: *Handle = @ptrCast(@alignCast(h orelse return shim_util.dupeToNoxStr(rt, "")));
    if (i < 0 or i >= handle.count) return shim_util.dupeToNoxStr(rt, "");
    var buf: [96]u8 = undefined;
    return shim_util.dupeToNoxStr(rt, formatAddr(&buf, handle.addrs[@intCast(i)]));
}

pub export fn nox_dns_free_raw(h: ?*anyopaque) callconv(.c) void {
    const handle: *Handle = @ptrCast(@alignCast(h orelse return));
    gpa.destroy(handle);
}

/// Adresi bağlantı noktası olmadan biçimlendirir (`IpAddress.format` `ip:port` / `[ip6]:port` yazar).
fn formatAddr(buf: []u8, a: IpAddress) []const u8 {
    const full = std.fmt.bufPrint(buf, "{f}", .{a}) catch return "";
    switch (a) {
        .ip4 => {
            const colon = std.mem.lastIndexOfScalar(u8, full, ':') orelse return full;
            return full[0..colon];
        },
        .ip6 => {
            const close = std.mem.lastIndexOfScalar(u8, full, ']') orelse return full;
            return if (full.len > 0 and full[0] == '[') full[1..close] else full[0..close];
        },
    }
}

test "formatAddr bağlantı noktasını atar" {
    var buf: [96]u8 = undefined;
    try std.testing.expectEqualStrings("203.0.113.7", formatAddr(&buf, .{ .ip4 = .{ .bytes = .{ 203, 0, 113, 7 }, .port = 443 } }));
    var b6: [96]u8 = undefined;
    try std.testing.expectEqualStrings("::1", formatAddr(&b6, .{ .ip6 = .{ .bytes = [_]u8{0} ** 15 ++ [_]u8{1}, .port = 80 } }));
}

test "resolveHost IP literal ve localhost için ağ kullanmaz" {
    var out: [16]IpAddress = undefined;
    if (comptime !net_dial.enabled) return error.SkipZigTest;
    try std.testing.expectEqual(@as(usize, 1), try net_dial.resolveHost("203.0.113.7", 100, &out));
    try std.testing.expect(try net_dial.resolveHost("localhost", 100, &out) == 2);
    try std.testing.expect(try net_dial.resolveHost("[2001:db8::1]", 100, &out) == 1);
}

test "validDnsName yalnızca ad karakterlerini kabul eder" {
    try std.testing.expect(validDnsName("example.com"));
    try std.testing.expect(validDnsName("a-b_c.d1.example"));
    try std.testing.expect(!validDnsName(""));
    try std.testing.expect(!validDnsName("a b"));
    try std.testing.expect(!validDnsName("a&type=TXT"));
    try std.testing.expect(!validDnsName("a/../b"));
}

test "parseDohAnswers A/AAAA yanıtlarını ayrıştırır, Status!=0 ve bozuk gövdeyi yok sayar" {
    var h: Handle = .{};
    parseDohAnswers(&h, "{\"Status\":0,\"Answer\":[{\"type\":5,\"data\":\"cname.example.\"},{\"type\":1,\"data\":\"192.0.2.7\"},{\"type\":28,\"data\":\"2001:db8::7\"},{\"type\":1,\"data\":\"nope\"}]}");
    try std.testing.expectEqual(@as(usize, 2), h.count);
    var buf: [96]u8 = undefined;
    try std.testing.expectEqualStrings("192.0.2.7", formatAddr(&buf, h.addrs[0]));
    var b2: [96]u8 = undefined;
    try std.testing.expectEqualStrings("2001:db8::7", formatAddr(&b2, h.addrs[1]));
    var h2: Handle = .{};
    parseDohAnswers(&h2, "{\"Status\":3,\"Answer\":[{\"type\":1,\"data\":\"192.0.2.7\"}]}");
    try std.testing.expectEqual(@as(usize, 0), h2.count);
    parseDohAnswers(&h2, "not json");
    parseDohAnswers(&h2, "[]");
    try std.testing.expectEqual(@as(usize, 0), h2.count);
}
