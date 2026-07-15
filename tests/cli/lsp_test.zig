//! Faz W.2 golden testi: `noxlsp`yi (bkz. `compiler/lsp_main.zig`nin modül
//! üstü notu) `tests/cli/subcommand_test.zig` İLE AYNI desende (kurulu
//! `zig-out/bin/noxlsp`yi gerçek bir ALT SÜREÇ olarak çalıştırarak) DOĞRULAR
//! — AMA `subcommand_test.zig`nin AKSİNE, `noxlsp` TEK-ATIŞLIK/tam-çıktı-
//! yakalayan `std.process.run` İLE ÇALIŞTIRILAMAZ (protokol UZUN ÖMÜRLÜ,
//! ÇİFT YÖNLÜ stdio ister) — bunun yerine `std.process.spawn` (pipe'lı
//! stdin/stdout) + LSP'nin KENDİ `Content-Length` çerçevelemesini (bkz.
//! `readMessage`/`writeMessage`, `lsp_main.zig`nin `readMessage`iyle KASITLI
//! olarak AYNI TELİ, ama BAĞIMSIZ/kopya bir uygulamayla — GERÇEK bir
//! istemcinin ne göreceğini test eder, sunucunun İÇ fonksiyonunu ÇAĞIRMAZ)
//! kullanılır.
//!
//! Uçtan uca senaryo: `initialize` → `initialized` → tanımsız bir değişken
//! İÇEREN bir `.nox` kaynağı `didOpen` İLE gönderilip DÖNEN
//! `publishDiagnostics`in GERÇEKTEN checker'ın "tanımsız değişken" hatasını
//! taşıdığı doğrulanır → AYNI URI `didChange` İLE DÜZELTİLMİŞ bir kaynağa
//! GÜNCELLENİP tanılamaların BOŞALDIĞI doğrulanır → `shutdown`/`exit` İLE
//! temiz kapanış (çıkış kodu 0) doğrulanır.

const std = @import("std");

fn noxlspPath() []const u8 {
    return "zig-out/bin/noxlsp";
}

fn writeMessage(w: *std.Io.Writer, json_text: []const u8) !void {
    try w.print("Content-Length: {d}\r\n\r\n", .{json_text.len});
    try w.writeAll(json_text);
    try w.flush();
}

/// `lsp_main.zig`nin `readMessage`iyle KASITLI olarak AYNI çerçeveleme
/// mantığı — bkz. modül üstü not (BAĞIMSIZ kopya, GERÇEK istemci davranışını
/// taklit eder).
fn readMessage(gpa: std.mem.Allocator, r: *std.Io.Reader) ![]u8 {
    var content_length: ?usize = null;
    while (true) {
        // bkz. `lsp_main.zig`nin `readMessage`inin AYNI notu: `Inclusive`
        // varyantı ZORUNLU (delimiter'ı TÜKETİR), `Exclusive` TÜKETMEZ.
        const line = try r.takeDelimiterInclusive('\n');
        const trimmed = std.mem.trimEnd(u8, line, "\r\n");
        if (trimmed.len == 0) break;
        if (std.mem.startsWith(u8, trimmed, "Content-Length:")) {
            const value = std.mem.trim(u8, trimmed["Content-Length:".len..], " \t");
            content_length = try std.fmt.parseInt(usize, value, 10);
        }
    }
    const len = content_length orelse return error.MissingContentLength;
    return r.readAlloc(gpa, len);
}

test "uctan uca: initialize + didOpen/didChange tanilama dongusu + shutdown" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var child = try std.process.spawn(io, .{
        .argv = &.{noxlspPath()},
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .inherit,
    });

    var stdin_buf: [4096]u8 = undefined;
    var stdin_writer = child.stdin.?.writer(io, &stdin_buf);
    const w = &stdin_writer.interface;

    var stdout_buf: [1 << 16]u8 = undefined;
    var stdout_reader = child.stdout.?.reader(io, &stdout_buf);
    const r = &stdout_reader.interface;

    // 1) initialize -> yanit id=1, sonucta capabilities.textDocumentSync=1 tasimali.
    try writeMessage(w, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}");
    const init_resp = try readMessage(a, r);
    try std.testing.expect(std.mem.indexOf(u8, init_resp, "\"id\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, init_resp, "\"textDocumentSync\":1") != null);

    // 2) initialized (bildirim, yanit YOK).
    try writeMessage(w, "{\"jsonrpc\":\"2.0\",\"method\":\"initialized\",\"params\":{}}");

    // 3) didOpen: "y" tanimsiz -> checker'in "tanimsiz degisken: y" tanilamasi beklenir.
    const bad_uri = "file:///tmp/noxlsp_test.nox";
    try writeMessage(w, "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":" ++
        "{\"textDocument\":{\"uri\":\"" ++ bad_uri ++ "\",\"languageId\":\"nox\",\"version\":1," ++
        "\"text\":\"x: int = y\\n\"}}}");
    const diag1 = try readMessage(a, r);
    try std.testing.expect(std.mem.indexOf(u8, diag1, "publishDiagnostics") != null);
    try std.testing.expect(std.mem.indexOf(u8, diag1, bad_uri) != null);
    try std.testing.expect(std.mem.indexOf(u8, diag1, "tan\\u0131ms\\u0131z de\\u011fi\\u015fken: y") != null or
        std.mem.indexOf(u8, diag1, "tanımsız değişken: y") != null);

    // 4) didChange: gecerli kaynaga guncelle -> tanilamalar BOSALMALI.
    try writeMessage(w, "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didChange\",\"params\":" ++
        "{\"textDocument\":{\"uri\":\"" ++ bad_uri ++ "\",\"version\":2}," ++
        "\"contentChanges\":[{\"text\":\"x: int = 1\\n\"}]}}");
    const diag2 = try readMessage(a, r);
    try std.testing.expect(std.mem.indexOf(u8, diag2, "publishDiagnostics") != null);
    try std.testing.expect(std.mem.indexOf(u8, diag2, "\"diagnostics\":[]") != null);

    // 5) shutdown -> yanit id=2, result:null.
    try writeMessage(w, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"shutdown\",\"params\":null}");
    const shutdown_resp = try readMessage(a, r);
    try std.testing.expect(std.mem.indexOf(u8, shutdown_resp, "\"id\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, shutdown_resp, "\"result\":null") != null);

    // 6) exit -> sunucu stdin EOF'unu bekletmeden dogrudan cikar.
    try writeMessage(w, "{\"jsonrpc\":\"2.0\",\"method\":\"exit\"}");

    const term = try child.wait(io);
    try std.testing.expect(term == .exited and term.exited == 0);
}
