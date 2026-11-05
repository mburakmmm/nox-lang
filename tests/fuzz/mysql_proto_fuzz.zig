//! v2.0.180 (Faz 11.4c): MySQL/MariaDB istemcisinin SUNUCUDAN gelen baytları ayrıştıran saf işlevleri (`runtime/stdlib_shims/mysql_proto.zig`): el sıkışma, OK/ERR/EOF paketleri, sütun adı, sunucunun
//! RSA genel anahtarı (PEM/SPKI/DER). TLS'siz bir bağlantıda ağdaki bir saldırgan ya da ele geçirilmiş bir sunucu bu baytları kontrol eder; bu yüzden hiçbiri çökmemeli, sınır aşmamalı, sızdırmamalıdır.
//! Yapı `hpack_fuzz.zig` ile aynıdır: kapsam güdümlü `std.testing.fuzz` + her `zig build test`te çalışan deterministik tohumlu tarama; `std.testing.allocator` sızıntı/çift serbest bırakmayı yakalar.

const std = @import("std");
const mp = @import("mysql_proto");

fn exercise(bytes: []const u8) !void {
    if (mp.parseHandshake(std.testing.allocator, bytes)) |hs| {
        std.testing.allocator.free(hs.scramble);
    } else |_| {}
    _ = mp.parseOk(bytes);
    _ = mp.errMessage(bytes);
    _ = mp.isEof(bytes);
    _ = mp.eofStatus(bytes);
    _ = mp.columnName(bytes);
    _ = mp.parseSpki(bytes);
    if (mp.pemToDer(std.testing.allocator, bytes)) |der| {
        defer std.testing.allocator.free(der);
        _ = mp.parseSpki(der);
    } else |_| {}
}

test "fuzz: mysql_proto sunucu paketi ayristiricilari asla cokmez" {
    return std.testing.fuzz({}, fuzzOne, .{});
}

fn fuzzOne(_: void, smith: *std.testing.Smith) !void {
    @disableInstrumentation();
    var buf: [2048]u8 = undefined;
    const len = smith.sliceWeightedBytes(&buf, &.{
        .rangeAtMost(u8, 0x00, 0xff, 1),
    });
    try exercise(buf[0..len]);
}

test "mysql_proto: rastgele ve mutasyonlu paketler (deterministik tohum) cokmeden islenir" {
    var prng = std.Random.DefaultPrng.init(0x4d59_5351_4c00_0001);
    const rand = prng.random();
    var buf: [1024]u8 = undefined;

    // Geçerli bir HandshakeV10 paketi: protokol 10, sürüm "8.0", bağlantı kimliği, 8 bayt tuz, dolgu, yetenekler, karakter kümesi, durum, tuzun kalanı, eklenti adı.
    var valid: std.ArrayListUnmanaged(u8) = .empty;
    defer valid.deinit(std.testing.allocator);
    try valid.append(std.testing.allocator, 10);
    try valid.appendSlice(std.testing.allocator, "8.0.36\x00");
    try valid.appendSlice(std.testing.allocator, &[_]u8{ 1, 0, 0, 0 });
    try valid.appendSlice(std.testing.allocator, "abcdefgh");
    try valid.append(std.testing.allocator, 0);
    try valid.appendSlice(std.testing.allocator, &[_]u8{ 0xff, 0xf7, 0x21, 0x02, 0x00, 0xff, 0x81, 21, 0 });
    try valid.appendNTimes(std.testing.allocator, 0, 10);
    try valid.appendSlice(std.testing.allocator, "ijklmnopqrst\x00caching_sha2_password\x00");

    var i: usize = 0;
    while (i < 20_000) : (i += 1) {
        if (i % 2 == 0) {
            const n = rand.uintLessThan(usize, buf.len + 1);
            rand.bytes(buf[0..n]);
            try exercise(buf[0..n]);
        } else {
            var n: usize = @min(valid.items.len, buf.len);
            @memcpy(buf[0..n], valid.items[0..n]);
            const flips = rand.uintLessThan(usize, 5);
            var f: usize = 0;
            while (f < flips) : (f += 1) buf[rand.uintLessThan(usize, n)] ^= @as(u8, 1) << @intCast(rand.uintLessThan(u8, 8));
            if (rand.boolean()) n = rand.uintLessThan(usize, n + 1);
            try exercise(buf[0..n]);
        }
    }
}

test "mysql_proto: gecerli HandshakeV10 paketi dogru ayristirilir (fuzz govdesinin kontrol noktasi)" {
    var valid: std.ArrayListUnmanaged(u8) = .empty;
    defer valid.deinit(std.testing.allocator);
    try valid.append(std.testing.allocator, 10);
    try valid.appendSlice(std.testing.allocator, "8.0.36\x00");
    try valid.appendSlice(std.testing.allocator, &[_]u8{ 1, 0, 0, 0 });
    try valid.appendSlice(std.testing.allocator, "abcdefgh");
    try valid.append(std.testing.allocator, 0);
    try valid.appendSlice(std.testing.allocator, &[_]u8{ 0xff, 0xf7, 0x21, 0x02, 0x00, 0xff, 0x81, 21, 0 });
    try valid.appendNTimes(std.testing.allocator, 0, 10);
    try valid.appendSlice(std.testing.allocator, "ijklmnopqrst\x00caching_sha2_password\x00");
    const hs = try mp.parseHandshake(std.testing.allocator, valid.items);
    defer std.testing.allocator.free(hs.scramble);
    try std.testing.expectEqualStrings("8.0.36", hs.server_version);
    try std.testing.expectEqual(@as(usize, 20), hs.scramble.len);
}
