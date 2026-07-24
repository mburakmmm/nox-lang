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
    // Gerçek span sistemi (bkz. plan dosyası "Gerçek span sistemi +
    // yapılandırılmış tanılamalar") — Aşama 7 kabul kriteri: `range` ARTIK
    // ESKİDEN OLDUĞU GİBİ "TÜM SATIR" (`character:10000`) DEĞİL, `"x: int
    // = y"` deyiminin GERÇEK bitişini (sütun 10, 0-tabanlı) yansıtmalı.
    try std.testing.expect(std.mem.indexOf(u8, diag1, "\"character\":10000") == null);
    try std.testing.expect(std.mem.indexOf(u8, diag1, "\"start\":{\"line\":0,\"character\":0}") != null);
    try std.testing.expect(std.mem.indexOf(u8, diag1, "\"end\":{\"line\":0,\"character\":10}") != null);

    // 4) didChange: SÖZDİZİMİ hatası içeren bir kaynağa güncelle (sonlandırılmamış
    // dize) — `range`in ARTIK 0. satıra SABİTLENMEDİĞİNİ (gerçek açılış
    // tırnağı konumunu yansıttığını) doğrula.
    try writeMessage(w, "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didChange\",\"params\":" ++
        "{\"textDocument\":{\"uri\":\"" ++ bad_uri ++ "\",\"version\":2}," ++
        "\"contentChanges\":[{\"text\":\"x = 1\\ny = \\\"abc\\n\"}]}}");
    const diag_syntax = try readMessage(a, r);
    try std.testing.expect(std.mem.indexOf(u8, diag_syntax, "publishDiagnostics") != null);
    try std.testing.expect(std.mem.indexOf(u8, diag_syntax, "sonlandirilmamis string") != null);
    // Açılış tırnağı 2. satırda (0-tabanlı satır 1), sütun 4'te (0-tabanlı) —
    // ESKİDEN OLDUĞU GİBİ satır 0'a SABİTLENMEZ.
    try std.testing.expect(std.mem.indexOf(u8, diag_syntax, "\"line\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, diag_syntax, "\"character\":10000") == null);

    // 5) didChange: gecerli kaynaga guncelle -> tanilamalar BOSALMALI.
    try writeMessage(w, "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didChange\",\"params\":" ++
        "{\"textDocument\":{\"uri\":\"" ++ bad_uri ++ "\",\"version\":3}," ++
        "\"contentChanges\":[{\"text\":\"x: int = 1\\n\"}]}}");
    const diag2 = try readMessage(a, r);
    try std.testing.expect(std.mem.indexOf(u8, diag2, "publishDiagnostics") != null);
    try std.testing.expect(std.mem.indexOf(u8, diag2, "\"diagnostics\":[]") != null);

    // 6) shutdown -> yanit id=2, result:null.
    try writeMessage(w, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"shutdown\",\"params\":null}");
    const shutdown_resp = try readMessage(a, r);
    try std.testing.expect(std.mem.indexOf(u8, shutdown_resp, "\"id\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, shutdown_resp, "\"result\":null") != null);

    // 7) exit -> sunucu stdin EOF'unu bekletmeden dogrudan cikar.
    try writeMessage(w, "{\"jsonrpc\":\"2.0\",\"method\":\"exit\"}");

    const term = try child.wait(io);
    try std.testing.expect(term == .exited and term.exited == 0);
}

// P1.4: `lsp_nav.zig`nin gezinme katmanını (bkz. onun modül üstü notu)
// GERÇEK bir alt süreç üzerinden uçtan uca doğrular — `hover`in üst-düzey
// bir fonksiyonun İMZASINI, `definition`ın o fonksiyonun GERÇEK bildirim
// satırını, `completion`ın İSE (kapsayan fonksiyonun parametresi + modülün
// üst-düzey fonksiyonu + bir yerleşik) hepsinin AYNI ANDA döndüğünü
// doğrular.
test "uctan uca: hover/definition/completion ayni-dosya sembolleri gercekten cozer" {
    const io = std.testing.io;

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

    try writeMessage(w, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}");
    const init_resp = try readMessage(std.testing.allocator, r);
    std.testing.allocator.free(init_resp);
    try writeMessage(w, "{\"jsonrpc\":\"2.0\",\"method\":\"initialized\",\"params\":{}}");

    const uri = "file:///tmp/noxlsp_nav_test.nox";
    // satir0="def double(x: int) -> int:", satir1="    return x * 2",
    // satir2="", satir3="y: int = double(21)".
    try writeMessage(w, "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":" ++
        "{\"textDocument\":{\"uri\":\"" ++ uri ++ "\",\"languageId\":\"nox\",\"version\":1," ++
        "\"text\":\"def double(x: int) -> int:\\n    return x * 2\\n\\ny: int = double(21)\\n\"}}}");
    const diag = try readMessage(std.testing.allocator, r);
    defer std.testing.allocator.free(diag);
    try std.testing.expect(std.mem.indexOf(u8, diag, "publishDiagnostics") != null);

    // hover: satir3 (0-tabanli), "double" cagrisinin uzerinde (sutun 9,
    // 0-tabanli — "y: int = " onekinin uzunlugu).
    try writeMessage(w, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/hover\",\"params\":" ++
        "{\"textDocument\":{\"uri\":\"" ++ uri ++ "\"},\"position\":{\"line\":3,\"character\":9}}}");
    const hover_resp = try readMessage(std.testing.allocator, r);
    defer std.testing.allocator.free(hover_resp);
    try std.testing.expect(std.mem.indexOf(u8, hover_resp, "def double(x: int) -> int") != null);

    // definition: AYNI konum — GERCEK bildirim satirina (0. satir, 0.
    // sutun) isaret etmeli.
    try writeMessage(w, "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"textDocument/definition\",\"params\":" ++
        "{\"textDocument\":{\"uri\":\"" ++ uri ++ "\"},\"position\":{\"line\":3,\"character\":9}}}");
    const def_resp = try readMessage(std.testing.allocator, r);
    defer std.testing.allocator.free(def_resp);
    try std.testing.expect(std.mem.indexOf(u8, def_resp, uri) != null);
    try std.testing.expect(std.mem.indexOf(u8, def_resp, "\"start\":{\"line\":0,\"character\":0}") != null);

    // completion: fonksiyon govdesi icinde (satir1) — parametre "x",
    // ust-duzey "double", VE bir yerlesik ("print") HEPSI listede olmali.
    try writeMessage(w, "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"textDocument/completion\",\"params\":" ++
        "{\"textDocument\":{\"uri\":\"" ++ uri ++ "\"},\"position\":{\"line\":1,\"character\":10}}}");
    const comp_resp = try readMessage(std.testing.allocator, r);
    defer std.testing.allocator.free(comp_resp);
    try std.testing.expect(std.mem.indexOf(u8, comp_resp, "\"label\":\"x\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, comp_resp, "\"label\":\"double\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, comp_resp, "\"label\":\"print\"") != null);

    try writeMessage(w, "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"shutdown\",\"params\":null}");
    const shutdown_resp = try readMessage(std.testing.allocator, r);
    std.testing.allocator.free(shutdown_resp);
    try writeMessage(w, "{\"jsonrpc\":\"2.0\",\"method\":\"exit\"}");

    const term = try child.wait(io);
    try std.testing.expect(term == .exited and term.exited == 0);
}

fn absPath(io: std.Io, dir: std.Io.Dir, buf: []u8) ![]const u8 {
    const len = try dir.realPath(io, buf);
    return buf[0..len];
}

// P1.3: `lsp_main.zig`nin `resolveModuleForLsp`i (bkz. onun belge notu) —
// `nox.json` İÇEREN bir fixture proje kökünde, `requires[]`e HİÇ İHTİYAÇ
// DUYMADAN proje-içi (`helper.nox`) bir import'un ARTIK GERÇEKTEN
// çözüldüğünü doğrular. Bu senaryo P1.3'TEN ÖNCE (bkz. modül üstü notun
// eski hali) "tanımsız fonksiyon: helper_double" TÜRÜNDE bir YANLIŞ-
// POZİTİF tanılama ÜRETİRDİ — `didOpen` sonrası tanılama listesinin
// GERÇEKTEN boş olması, bu regresyonun DÜZELTİLDİĞİNİN kanıtıdır.
test "uctan uca: nox.json'lu bir projede proje-ici (requires'siz) import gercekten cozulur" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var proj = std.testing.tmpDir(.{});
    defer proj.cleanup();
    try proj.dir.writeFile(io, .{ .sub_path = "nox.json", .data = "{\"name\":\"proj\",\"entry\":\"main.nox\"}" });
    try proj.dir.writeFile(io, .{
        .sub_path = "helper.nox",
        .data =
        \\def double(x: int) -> int:
        \\    return x * 2
        \\
        ,
    });

    var proj_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const proj_path = try absPath(io, proj.dir, &proj_buf);
    const main_uri = try std.fmt.allocPrint(a, "file://{s}/main.nox", .{proj_path});

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

    try writeMessage(w, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}");
    _ = try readMessage(a, r);
    try writeMessage(w, "{\"jsonrpc\":\"2.0\",\"method\":\"initialized\",\"params\":{}}");

    const did_open = try std.fmt.allocPrint(a, "{{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":" ++
        "{{\"textDocument\":{{\"uri\":\"{s}\",\"languageId\":\"nox\",\"version\":1," ++
        "\"text\":\"import helper\\n\\nx: int = helper.double(21)\\n\"}}}}}}", .{main_uri});
    try writeMessage(w, did_open);
    const diag = try readMessage(a, r);
    try std.testing.expect(std.mem.indexOf(u8, diag, "publishDiagnostics") != null);
    try std.testing.expect(std.mem.indexOf(u8, diag, "\"diagnostics\":[]") != null);

    try writeMessage(w, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"shutdown\",\"params\":null}");
    _ = try readMessage(a, r);
    try writeMessage(w, "{\"jsonrpc\":\"2.0\",\"method\":\"exit\"}");

    const term = try child.wait(io);
    try std.testing.expect(term == .exited and term.exited == 0);
}
