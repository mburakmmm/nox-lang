//! `nox.dns` (v2.1.195): açık DNS çözümlemesi. `nox.http` bağlanırken ana makine adını KENDİSİ tekrar çözer; SSRF/DNS-rebinding savunması isteyen çağıranın "çöz, doğrula, o IP'ye bağlan"
//! diyebilmesi için çözümleme ayrı bir adım olarak sunulur (`nox.http.request(..., connect_ip=...)` ile birlikte kullanılır). Çözümleme `net_dial.zig`nin sınırlı (son tarihli, singleflight,
//! iş parçacığı sınırlı) `getaddrinfo`sunu kullanır; fiber içinde yalnızca çağıran fiber bekler. Yetenek: `network` (reddedilirse durum 4).

const std = @import("std");
const builtin = @import("builtin");
const shim_util = @import("shim_util.zig");
/// wasm'da (tarayıcı/WASI) sistem çözümleyicisi yoktur: tüm çağrılar "desteklenmiyor" (durum 5) döner.
const is_wasm = builtin.cpu.arch.isWasm();
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
pub export fn nox_dns_resolve_raw(host: ?[*:0]const u8, timeout_ms: i64) callconv(.c) ?*anyopaque {
    const h = gpa.create(Handle) catch return null;
    h.* = .{};
    const name = str_mod.nox_str_slice(host orelse return h);
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
