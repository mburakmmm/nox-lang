//! v2.0.180 (Faz 11.4c): HTTP/2 sunucusunun saldırgan kontrollü başlık bloklarını ayrıştıran HPACK çözücüsü (`runtime/stdlib_shims/http2.zig`) ve Huffman çözücüsü için fuzz hedefi.
//! `lexer_parser_checker_fuzz.zig` ile aynı Zig-yerleşik fuzzer gerekçesi geçerlidir. İki parça vardır: (1) `std.testing.fuzz` (kapsam güdümlü; `zig build test --fuzz`), (2) her
//! `zig build test` koşusunda çalışan, deterministik tohumlu bir tarama: tamamen rastgele baytlar ile geçerli bloklardan türetilmiş mutasyonlar. Testler `std.testing.allocator` ile
//! koşar: sızıntı ve çift serbest bırakma yakalanır (AGENTS §6).

const std = @import("std");
const http2 = @import("http2");

/// Aynı çözücüde iki ardışık blok (dinamik tablo durumu bloklar arasında yaşar), Huffman ve çerçeve başlığı: hiçbiri çökmemeli, sızdırmamalı, sınır aşmamalıdır.
fn exercise(bytes: []const u8) !void {
    var hout: std.ArrayListUnmanaged(u8) = .empty;
    defer hout.deinit(std.testing.allocator);
    http2.huffmanDecode(std.testing.allocator, bytes, &hout) catch {};

    var dec = http2.Decoder.init(std.testing.allocator, 4096);
    defer dec.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var out: std.ArrayListUnmanaged(http2.Header) = .empty;
    const half = bytes.len / 2;
    _ = dec.decode(bytes[0..half], arena.allocator(), &out, 16 * 1024) catch {};
    _ = dec.decode(bytes[half..], arena.allocator(), &out, 16 * 1024) catch {};

    if (bytes.len >= 9) _ = http2.parseFrameHeader(bytes[0..9]);
}

test "fuzz: HPACK Decoder.decode, huffmanDecode ve parseFrameHeader asla cokmez" {
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

test "HPACK: rastgele ve mutasyonlu bloklar (deterministik tohum) cokmeden islenir" {
    var prng = std.Random.DefaultPrng.init(0x4850_4143_4b00_0001);
    const rand = prng.random();
    var buf: [1024]u8 = undefined;

    // Geçerli bir blok: RFC 7541 Ek C.3.1 (":method: GET, :scheme: http, :path: /, :authority: www.example.com").
    const valid = [_]u8{ 0x82, 0x86, 0x84, 0x41, 0x0f, 'w', 'w', 'w', '.', 'e', 'x', 'a', 'm', 'p', 'l', 'e', '.', 'c', 'o', 'm' };

    var i: usize = 0;
    while (i < 20_000) : (i += 1) {
        if (i % 2 == 0) {
            // Tamamen rastgele baytlar.
            const n = rand.uintLessThan(usize, buf.len + 1);
            rand.bytes(buf[0..n]);
            try exercise(buf[0..n]);
        } else {
            // Geçerli bloktan türetilmiş: birkaç baytı bozulmuş, kırpılmış veya rastgele uzatılmış.
            var n: usize = valid.len;
            @memcpy(buf[0..n], &valid);
            const flips = rand.uintLessThan(usize, 4);
            var f: usize = 0;
            while (f < flips) : (f += 1) buf[rand.uintLessThan(usize, n)] ^= @as(u8, 1) << @intCast(rand.uintLessThan(u8, 8));
            if (rand.boolean()) n = rand.uintLessThan(usize, n + 1);
            if (rand.boolean()) {
                const extra = rand.uintLessThan(usize, 64);
                rand.bytes(buf[n .. n + extra]);
                n += extra;
            }
            try exercise(buf[0..n]);
        }
    }
}

test "HPACK: RFC 7541 Ek C.3.1 gecerli blogu dogru cozulur (fuzz govdesinin kontrol noktasi)" {
    const valid = [_]u8{ 0x82, 0x86, 0x84, 0x41, 0x0f, 'w', 'w', 'w', '.', 'e', 'x', 'a', 'm', 'p', 'l', 'e', '.', 'c', 'o', 'm' };
    var dec = http2.Decoder.init(std.testing.allocator, 4096);
    defer dec.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var out: std.ArrayListUnmanaged(http2.Header) = .empty;
    _ = try dec.decode(&valid, arena.allocator(), &out, 16 * 1024);
    try std.testing.expectEqual(@as(usize, 4), out.items.len);
    try std.testing.expectEqualStrings(":method", out.items[0].name);
    try std.testing.expectEqualStrings("GET", out.items[0].value);
    try std.testing.expectEqualStrings("www.example.com", out.items[3].value);
}
