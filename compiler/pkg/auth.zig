//! v2.0.136: `noxc login/logout/whoami` — noxpkg sunucusunun GitHub aygıt-akışı API'sinin istemcisi.
//!
//! `noxc` GitHub'la HİÇ konuşmaz (bkz. `services/noxpkg/github.nox`): aygıt kodunu noxpkg'den ister, kullanıcı github.com/login/device'ta
//! onaylar, `noxc` onayı noxpkg'ye sorar; noxpkg GitHub'dan kullanıcıyı doğrular ve KENDİ API jetonunu döner. Böylece `noxc`de GitHub
//! `client_id`si yoktur, GitHub jetonu istemciye hiç inmez ve sağlayıcı değişirse istemci değişmez.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const registry = @import("registry.zig");

pub const DeviceStart = struct {
    ok: bool = false,
    device_code: []const u8 = "",
    user_code: []const u8 = "",
    verification_uri: []const u8 = "",
    interval: i64 = 5,
    expires_in: i64 = 900,
    @"error": []const u8 = "",
};

const DevicePollReply = struct {
    ok: bool = false,
    status: []const u8 = "",
    token: []const u8 = "",
    login: []const u8 = "",
    @"error": []const u8 = "",
};

pub const Whoami = struct {
    ok: bool = false,
    login: []const u8 = "",
    @"error": []const u8 = "",
};

pub const AuthError = error{ AuthRequestFailed, AuthBadReply };

fn parse(comptime T: type, a: Allocator, reply: registry.HttpReply) !T {
    const parsed = std.json.parseFromSlice(T, a, reply.body, .{ .ignore_unknown_fields = true }) catch return error.AuthBadReply;
    return parsed.value;
}

fn call(a: Allocator, io: Io, method: std.http.Method, api_base: []const u8, route: []const u8, body: ?[]const u8, bearer: ?[]const u8, insecure: bool) !registry.HttpReply {
    const url = try std.fmt.allocPrint(a, "{s}{s}", .{ std.mem.trimEnd(u8, api_base, "/"), route });
    return registry.jsonRequest(a, io, method, url, body, bearer, insecure) catch return error.AuthRequestFailed;
}

pub fn deviceStart(a: Allocator, io: Io, api_base: []const u8, insecure: bool) !DeviceStart {
    const reply = try call(a, io, .POST, api_base, "/api/auth/device/start", "{}", null, insecure);
    return parse(DeviceStart, a, reply);
}

pub fn whoami(a: Allocator, io: Io, api_base: []const u8, token: []const u8, insecure: bool) !struct { status: u16, who: Whoami } {
    const reply = try call(a, io, .GET, api_base, "/api/auth/whoami", null, token, insecure);
    return .{ .status = reply.status, .who = try parse(Whoami, a, reply) };
}

/// Sunucudaki jetonu iptal eder. Yalnızca HTTP durumunu döner (200: iptal edildi).
pub fn logout(a: Allocator, io: Io, api_base: []const u8, token: []const u8, insecure: bool) !u16 {
    const reply = try call(a, io, .POST, api_base, "/api/auth/logout", "{}", token, insecure);
    return reply.status;
}

pub const LoginOutcome = union(enum) {
    ok: struct { token: []const u8, login: []const u8 },
    denied,
    expired,
    failed: []const u8,
};

/// Kullanıcı GitHub'da onaylayana kadar sunucuya sorar. Aralık sunucudan gelir (en az 1 sn); `slow_down` aralığı 5 sn artırır.
/// Geçici ağ hataları (art arda en çok 4) tolere edilir; son tarih `expires_in`dir.
pub fn pollUntilDone(a: Allocator, io: Io, api_base: []const u8, start: DeviceStart, insecure: bool) !LoginOutcome {
    const body = try std.json.Stringify.valueAlloc(a, .{ .device_code = start.device_code }, .{});
    var interval: i64 = @max(1, start.interval);
    var waited: i64 = 0;
    var consecutive_errors: u32 = 0;
    while (waited <= start.expires_in) {
        io.sleep(.fromSeconds(interval), .awake) catch {};
        waited += interval;
        const reply = call(a, io, .POST, api_base, "/api/auth/device/poll", body, null, insecure) catch {
            consecutive_errors += 1;
            if (consecutive_errors > 4) return .{ .failed = "the server did not answer" };
            continue;
        };
        const poll = parse(DevicePollReply, a, reply) catch {
            consecutive_errors += 1;
            if (consecutive_errors > 4) return .{ .failed = "the server sent an unreadable answer" };
            continue;
        };
        consecutive_errors = 0;
        if (!poll.ok) return .{ .failed = if (poll.@"error".len > 0) poll.@"error" else "login failed" };
        if (std.mem.eql(u8, poll.status, "ok")) return .{ .ok = .{ .token = poll.token, .login = poll.login } };
        if (std.mem.eql(u8, poll.status, "denied")) return .denied;
        if (std.mem.eql(u8, poll.status, "expired")) return .expired;
        if (std.mem.eql(u8, poll.status, "slow_down")) interval += 5;
    }
    return .expired;
}

/// Tarayıcıyı en iyi çabayla açar (macOS `open`, Linux `xdg-open`, Windows `start`). Başarısızlık sessizce yutulur: kullanıcıya adres
/// zaten yazdırılmıştır.
pub fn openBrowser(a: Allocator, io: Io, url: []const u8) void {
    const builtin = @import("builtin");
    const argv: []const []const u8 = switch (builtin.os.tag) {
        .macos => &.{ "open", url },
        .windows => &.{ "cmd", "/c", "start", "", url },
        else => &.{ "xdg-open", url },
    };
    const result = std.process.run(a, io, .{ .argv = argv }) catch return;
    a.free(result.stdout);
    a.free(result.stderr);
}

test "DeviceStart ve DevicePollReply: eksik alanlar varsayilanlara duser, bilinmeyen alanlar yok sayilir" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ds = try parse(DeviceStart, a, .{ .status = 200, .body = "{\"ok\": true, \"device_code\": \"d1\", \"user_code\": \"ABCD-1234\", \"verification_uri\": \"https://github.com/login/device\", \"extra\": 1}" });
    try std.testing.expect(ds.ok);
    try std.testing.expectEqualStrings("ABCD-1234", ds.user_code);
    try std.testing.expectEqual(@as(i64, 5), ds.interval);
    const dp = try parse(DevicePollReply, a, .{ .status = 200, .body = "{\"ok\": true, \"status\": \"pending\"}" });
    try std.testing.expectEqualStrings("pending", dp.status);
    try std.testing.expectEqualStrings("", dp.token);
    try std.testing.expectError(error.AuthBadReply, parse(Whoami, a, .{ .status = 502, .body = "<html>Bad gateway</html>" }));
}
