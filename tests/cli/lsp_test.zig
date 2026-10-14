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
const builtin = @import("builtin");

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
/// `noxlsp` yanıt vermezse `readMessage` pipe kapanana kadar bekler.
/// Süre dolunca süreç sonlanır, okuma hata döner, test düşer.
const LspWatchdog = struct {
    done: std.atomic.Value(bool) = .init(false),
    thread: std.Thread = undefined,
    active: bool = false,

    fn arm(self: *LspWatchdog, child: *const std.process.Child, timeout_ms: u32) !void {
        const id = child.id orelse return error.ProcessNotRunning;
        self.thread = try std.Thread.spawn(.{}, run, .{ self, id, timeout_ms });
        self.active = true;
    }

    fn run(self: *LspWatchdog, id: std.process.Child.Id, timeout_ms: u32) void {
        const step_ms: u32 = 200;
        var waited: u32 = 0;
        while (waited < timeout_ms) : (waited += step_ms) {
            if (self.done.load(.acquire)) return;
            sleepMs(step_ms);
        }
        if (self.done.load(.acquire)) return;
        switch (builtin.os.tag) {
            .windows => _ = std.os.windows.ntdll.NtTerminateProcess(id, @enumFromInt(1)),
            else => std.posix.kill(id, .KILL) catch {},
        }
    }

    fn disarm(self: *LspWatchdog) void {
        if (!self.active) return;
        self.done.store(true, .release);
        self.thread.join();
    }
};

const WinSleep = if (builtin.os.tag == .windows) struct {
    extern "kernel32" fn Sleep(dwMilliseconds: u32) callconv(.c) void;
} else struct {};

fn sleepMs(ms: u32) void {
    switch (builtin.os.tag) {
        .windows => WinSleep.Sleep(ms),
        else => {
            const ts: std.c.timespec = .{
                .sec = ms / std.time.ms_per_s,
                .nsec = (ms % std.time.ms_per_s) * std.time.ns_per_ms,
            };
            _ = std.c.nanosleep(&ts, null);
        },
    }
}

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
    var lsp_watchdog: LspWatchdog = .{};
    try lsp_watchdog.arm(&child, 45_000);
    defer lsp_watchdog.disarm();

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
    try std.testing.expect(std.mem.indexOf(u8, diag1, "undefined variable: y") != null);
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
    try std.testing.expect(std.mem.indexOf(u8, diag_syntax, "unterminated string") != null);
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
    var lsp_watchdog: LspWatchdog = .{};
    try lsp_watchdog.arm(&child, 45_000);
    defer lsp_watchdog.disarm();

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

// Faz ÜH.1: `textDocument/formatting` — `compiler/main.zig`nin `cmdFmt`ıyla
// AYNI zincirin (`formatter.formatModule`) beklendiği gibi TEK bir tam-
// belge `TextEdit` olarak dönüp döndürmediğini doğrular. Beklenen çıktı
// `tests/cli/subcommand_test.zig`nin AYNI "messy.nox" girdisiyle KANITLANMIŞ
// biçimlendirme sonucudur ("x:int=1+2\nprint(x)\n" -> "x: int = 1 + 2\nprint(x)\n").
test "uctan uca: textDocument/formatting kotu bicimli AMA gecerli bir kaynagi yeniden bicimlendirir" {
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
    var lsp_watchdog: LspWatchdog = .{};
    try lsp_watchdog.arm(&child, 45_000);
    defer lsp_watchdog.disarm();

    var stdin_buf: [4096]u8 = undefined;
    var stdin_writer = child.stdin.?.writer(io, &stdin_buf);
    const w = &stdin_writer.interface;

    var stdout_buf: [1 << 16]u8 = undefined;
    var stdout_reader = child.stdout.?.reader(io, &stdout_buf);
    const r = &stdout_reader.interface;

    try writeMessage(w, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}");
    const init_resp = try readMessage(a, r);
    try std.testing.expect(std.mem.indexOf(u8, init_resp, "\"documentFormattingProvider\":true") != null);
    try writeMessage(w, "{\"jsonrpc\":\"2.0\",\"method\":\"initialized\",\"params\":{}}");

    const uri = "file:///tmp/noxlsp_fmt_test.nox";
    try writeMessage(w, "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":" ++
        "{\"textDocument\":{\"uri\":\"" ++ uri ++ "\",\"languageId\":\"nox\",\"version\":1," ++
        "\"text\":\"x:int=1+2\\nprint(x)\\n\"}}}");
    const diag = try readMessage(a, r);
    try std.testing.expect(std.mem.indexOf(u8, diag, "publishDiagnostics") != null);

    try writeMessage(w, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/formatting\",\"params\":" ++
        "{\"textDocument\":{\"uri\":\"" ++ uri ++ "\"},\"options\":{\"tabSize\":4,\"insertSpaces\":true}}}");
    const fmt_resp = try readMessage(a, r);
    try std.testing.expect(std.mem.indexOf(u8, fmt_resp, "\"id\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, fmt_resp, "x: int = 1 + 2\\nprint(x)\\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, fmt_resp, "\"start\":{\"line\":0,\"character\":0}") != null);
    try std.testing.expect(std.mem.indexOf(u8, fmt_resp, "\"end\":{\"line\":2,\"character\":0}") != null);

    // GEÇERSİZ (sözdizimi hatalı) bir kaynağa güncellenince `formatting`
    // BOŞ bir edit dizisi dönmeli (arabelleği ASLA bozmaz) — bkz.
    // `formatSource`nin belge notu.
    try writeMessage(w, "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didChange\",\"params\":" ++
        "{\"textDocument\":{\"uri\":\"" ++ uri ++ "\",\"version\":2}," ++
        "\"contentChanges\":[{\"text\":\"x = \\\"abc\\n\"}]}}");
    _ = try readMessage(a, r);
    try writeMessage(w, "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"textDocument/formatting\",\"params\":" ++
        "{\"textDocument\":{\"uri\":\"" ++ uri ++ "\"}}}");
    const fmt_resp2 = try readMessage(a, r);
    try std.testing.expect(std.mem.indexOf(u8, fmt_resp2, "\"id\":3") != null);
    try std.testing.expect(std.mem.indexOf(u8, fmt_resp2, "\"result\":[]") != null);

    try writeMessage(w, "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"shutdown\",\"params\":null}");
    _ = try readMessage(a, r);
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
    var lsp_watchdog: LspWatchdog = .{};
    try lsp_watchdog.arm(&child, 45_000);
    defer lsp_watchdog.disarm();

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

test "uctan uca: anahat, imza, anlamsal belirtec, parametre ipucu, referans, yeniden adlandirma, sekme eylemi" {
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
    var lsp_watchdog: LspWatchdog = .{};
    try lsp_watchdog.arm(&child, 45_000);
    defer lsp_watchdog.disarm();
    var stdin_buf: [4096]u8 = undefined;
    var stdin_writer = child.stdin.?.writer(io, &stdin_buf);
    const w = &stdin_writer.interface;
    var stdout_buf: [1 << 16]u8 = undefined;
    var stdout_reader = child.stdout.?.reader(io, &stdout_buf);
    const r = &stdout_reader.interface;

    try writeMessage(w, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}");
    const init_resp = try readMessage(a, r);
    try std.testing.expect(std.mem.indexOf(u8, init_resp, "\"documentSymbolProvider\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, init_resp, "\"signatureHelpProvider\"") != null);
    try writeMessage(w, "{\"jsonrpc\":\"2.0\",\"method\":\"initialized\",\"params\":{}}");

    const uri = "file:///tmp/noxlsp_nav2.nox";
    try writeMessage(w, "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":" ++
        "{\"textDocument\":{\"uri\":\"" ++ uri ++ "\",\"languageId\":\"nox\",\"version\":1," ++
        "\"text\":\"def double(x: int) -> int:\\n    return x * 2\\n\\ny: int = double(21)\\n\"}}}");
    _ = try readMessage(a, r);

    try writeMessage(w, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/documentSymbol\",\"params\":" ++
        "{\"textDocument\":{\"uri\":\"" ++ uri ++ "\"}}}");
    const sym = try readMessage(a, r);
    try std.testing.expect(std.mem.indexOf(u8, sym, "\"name\":\"double\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, sym, "\"kind\":12") != null);

    try writeMessage(w, "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"textDocument/signatureHelp\",\"params\":" ++
        "{\"textDocument\":{\"uri\":\"" ++ uri ++ "\"},\"position\":{\"line\":3,\"character\":16}}}");
    const sig = try readMessage(a, r);
    try std.testing.expect(std.mem.indexOf(u8, sig, "double(x)") != null);
    try std.testing.expect(std.mem.indexOf(u8, sig, "\"label\":\"x\"") != null);

    try writeMessage(w, "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"textDocument/semanticTokens/full\",\"params\":" ++
        "{\"textDocument\":{\"uri\":\"" ++ uri ++ "\"}}}");
    const sem = try readMessage(a, r);
    try std.testing.expect(std.mem.indexOf(u8, sem, "\"data\":[") != null);
    try std.testing.expect(std.mem.indexOf(u8, sem, "\"data\":[]") == null);

    try writeMessage(w, "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"textDocument/inlayHint\",\"params\":" ++
        "{\"textDocument\":{\"uri\":\"" ++ uri ++ "\"},\"range\":{\"start\":{\"line\":0,\"character\":0},\"end\":{\"line\":4,\"character\":0}}}}");
    const hint = try readMessage(a, r);
    try std.testing.expect(std.mem.indexOf(u8, hint, "\"label\":\"x:\"") != null);

    try writeMessage(w, "{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"textDocument/references\",\"params\":" ++
        "{\"textDocument\":{\"uri\":\"" ++ uri ++ "\"},\"position\":{\"line\":3,\"character\":9},\"context\":{\"includeDeclaration\":true}}}");
    const refs = try readMessage(a, r);
    try std.testing.expect(std.mem.indexOf(u8, refs, "\"line\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, refs, "\"line\":3") != null);

    try writeMessage(w, "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"textDocument/rename\",\"params\":" ++
        "{\"textDocument\":{\"uri\":\"" ++ uri ++ "\"},\"position\":{\"line\":3,\"character\":9},\"newName\":\"triple\"}}");
    const renamed = try readMessage(a, r);
    try std.testing.expect(std.mem.indexOf(u8, renamed, "\"newText\":\"triple\"") != null);

    try writeMessage(w, "{\"jsonrpc\":\"2.0\",\"id\":8,\"method\":\"textDocument/rename\",\"params\":" ++
        "{\"textDocument\":{\"uri\":\"" ++ uri ++ "\"},\"position\":{\"line\":3,\"character\":9},\"newName\":\"1bad\"}}");
    const bad = try readMessage(a, r);
    try std.testing.expect(std.mem.indexOf(u8, bad, "not an identifier") != null);

    const tab_uri = "file:///tmp/noxlsp_tabs.nox";
    try writeMessage(w, "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":" ++
        "{\"textDocument\":{\"uri\":\"" ++ tab_uri ++ "\",\"languageId\":\"nox\",\"version\":1," ++
        "\"text\":\"def f() -> int:\\n\\treturn 1\\n\"}}}");
    const tab_diag = try readMessage(a, r);
    try std.testing.expect(std.mem.indexOf(u8, tab_diag, "\"code\":\"tabs\"") != null);

    try writeMessage(w, "{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"textDocument/codeAction\",\"params\":" ++
        "{\"textDocument\":{\"uri\":\"" ++ tab_uri ++ "\"},\"range\":{\"start\":{\"line\":1,\"character\":0},\"end\":{\"line\":1,\"character\":1}}," ++
        "\"context\":{\"diagnostics\":[{\"range\":{\"start\":{\"line\":1,\"character\":0},\"end\":{\"line\":1,\"character\":1}}," ++
        "\"message\":\"syntax error: TAB indentation is not supported (use spaces only)\",\"code\":\"tabs\"}]}}}");
    const action = try readMessage(a, r);
    try std.testing.expect(std.mem.indexOf(u8, action, "Replace tab indentation with spaces") != null);
    try std.testing.expect(std.mem.indexOf(u8, action, "    return 1") != null);

    try writeMessage(w, "{\"jsonrpc\":\"2.0\",\"id\":10,\"method\":\"shutdown\",\"params\":null}");
    _ = try readMessage(a, r);
    try writeMessage(w, "{\"jsonrpc\":\"2.0\",\"method\":\"exit\"}");
    const term = try child.wait(io);
    try std.testing.expect(term == .exited and term.exited == 0);
}

test "uctan uca: import edilen fonksiyonun tanimi ve imzasi hedef dosyadan gelir" {
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
    const root_uri = try std.fmt.allocPrint(a, "file://{s}", .{proj_path});

    var child = try std.process.spawn(io, .{
        .argv = &.{noxlspPath()},
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .inherit,
    });
    var lsp_watchdog: LspWatchdog = .{};
    try lsp_watchdog.arm(&child, 45_000);
    defer lsp_watchdog.disarm();
    var stdin_buf: [4096]u8 = undefined;
    var stdin_writer = child.stdin.?.writer(io, &stdin_buf);
    const w = &stdin_writer.interface;
    var stdout_buf: [1 << 16]u8 = undefined;
    var stdout_reader = child.stdout.?.reader(io, &stdout_buf);
    const r = &stdout_reader.interface;

    const init = try std.fmt.allocPrint(a, "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{{\"rootUri\":\"{s}\"}}}}", .{root_uri});
    try writeMessage(w, init);
    _ = try readMessage(a, r);
    try writeMessage(w, "{\"jsonrpc\":\"2.0\",\"method\":\"initialized\",\"params\":{}}");

    const did_open = try std.fmt.allocPrint(a, "{{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":" ++
        "{{\"textDocument\":{{\"uri\":\"{s}\",\"languageId\":\"nox\",\"version\":1," ++
        "\"text\":\"import helper\\n\\ny: int = helper.double(21)\\n\"}}}}}}", .{main_uri});
    try writeMessage(w, did_open);
    _ = try readMessage(a, r);

    const def_req = try std.fmt.allocPrint(a, "{{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/definition\",\"params\":" ++
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":2,\"character\":18}}}}}}", .{main_uri});
    try writeMessage(w, def_req);
    const def_resp = try readMessage(a, r);
    try std.testing.expect(std.mem.indexOf(u8, def_resp, "helper.nox") != null);
    try std.testing.expect(std.mem.indexOf(u8, def_resp, "\"start\":{\"line\":0,\"character\":0}") != null);

    const sig_req = try std.fmt.allocPrint(a, "{{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"textDocument/signatureHelp\",\"params\":" ++
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":2,\"character\":25}}}}}}", .{main_uri});
    try writeMessage(w, sig_req);
    const sig_resp = try readMessage(a, r);
    try std.testing.expect(std.mem.indexOf(u8, sig_resp, "double(x)") != null);

    const ref_req = try std.fmt.allocPrint(a, "{{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"textDocument/references\",\"params\":" ++
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":2,\"character\":18}},\"context\":{{\"includeDeclaration\":true}}}}}}", .{main_uri});
    try writeMessage(w, ref_req);
    const ref_resp = try readMessage(a, r);
    try std.testing.expect(std.mem.indexOf(u8, ref_resp, "helper.nox") != null);
    try std.testing.expect(std.mem.indexOf(u8, ref_resp, "main.nox") != null);

    const ren_req = try std.fmt.allocPrint(a, "{{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"textDocument/rename\",\"params\":" ++
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":2,\"character\":18}},\"newName\":\"triple\"}}}}", .{main_uri});
    try writeMessage(w, ren_req);
    const ren_resp = try readMessage(a, r);
    try std.testing.expect(std.mem.indexOf(u8, ren_resp, "\"newText\":\"triple\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ren_resp, "helper.nox") != null);
    try std.testing.expect(std.mem.indexOf(u8, ren_resp, "main.nox") != null);

    try writeMessage(w, "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"shutdown\",\"params\":null}");
    _ = try readMessage(a, r);
    try writeMessage(w, "{\"jsonrpc\":\"2.0\",\"method\":\"exit\"}");
    const term = try child.wait(io);
    try std.testing.expect(term == .exited and term.exited == 0);
}

const SrcPos = struct { line: usize, character: usize };

fn posOf(text: []const u8, needle: []const u8) !SrcPos {
    const at = std.mem.indexOf(u8, text, needle) orelse return error.NotFound;
    var line: usize = 0;
    var character: usize = 0;
    for (text[0..at]) |c| {
        if (c == '\n') {
            line += 1;
            character = 0;
        } else character += 1;
    }
    return .{ .line = line, .character = character };
}

fn posOfNth(text: []const u8, needle: []const u8, n: usize) !SrcPos {
    var from: usize = 0;
    var seen: usize = 0;
    while (std.mem.indexOfPos(u8, text, from, needle)) |at| {
        if (seen == n) {
            var line: usize = 0;
            var character: usize = 0;
            for (text[0..at]) |c| {
                if (c == '\n') {
                    line += 1;
                    character = 0;
                } else character += 1;
            }
            return .{ .line = line, .character = character };
        }
        seen += 1;
        from = at + needle.len;
    }
    return error.NotFound;
}

fn jsonEsc(a: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    for (text) |c| switch (c) {
        '\n' => try out.appendSlice(a, "\\n"),
        '"' => try out.appendSlice(a, "\\\""),
        '\\' => try out.appendSlice(a, "\\\\"),
        else => try out.append(a, c),
    };
    return out.toOwnedSlice(a);
}

fn hasPos(resp: []const u8, pos: SrcPos) bool {
    var buf: [80]u8 = undefined;
    const frag = std.fmt.bufPrint(&buf, "\"line\":{d},\"character\":{d}", .{ pos.line, pos.character }) catch return false;
    return std.mem.indexOf(u8, resp, frag) != null;
}

test "from import as: sembol adi, takma ad ve golge ayri yeniden adlandirilir" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const helper_src =
        \\def double(x: int) -> int:
        \\    return x * 2
        \\
    ;
    const main_src =
        \\from helper import double as twice
        \\
        \\def use() -> int:
        \\    return twice(1)
        \\
    ;
    const shadow_src =
        \\from helper import double as twice
        \\
        \\def twice(n: int) -> int:
        \\    return n
        \\
        \\def use() -> int:
        \\    return twice(1)
        \\
    ;

    var proj = std.testing.tmpDir(.{});
    defer proj.cleanup();
    try proj.dir.writeFile(io, .{ .sub_path = "nox.json", .data = "{\"name\":\"proj\",\"entry\":\"main.nox\"}" });
    try proj.dir.writeFile(io, .{ .sub_path = "helper.nox", .data = helper_src });
    try proj.dir.writeFile(io, .{ .sub_path = "main.nox", .data = main_src });
    try proj.dir.writeFile(io, .{ .sub_path = "shadow.nox", .data = shadow_src });
    var proj_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const proj_path = try absPath(io, proj.dir, &proj_buf);
    const main_uri = try std.fmt.allocPrint(a, "file://{s}/main.nox", .{proj_path});
    const helper_uri = try std.fmt.allocPrint(a, "file://{s}/helper.nox", .{proj_path});
    const shadow_uri = try std.fmt.allocPrint(a, "file://{s}/shadow.nox", .{proj_path});
    const root_uri = try std.fmt.allocPrint(a, "file://{s}", .{proj_path});

    const alias_pos = try posOf(main_src, "twice");
    const use_pos = try posOfNth(main_src, "twice", 1);
    const import_name = try posOf(main_src, "double");
    const def_pos = try posOf(helper_src, "double");
    const shadow_name = try posOf(shadow_src, "double");
    const shadow_def = try posOf(shadow_src, "def twice");
    const shadow_def_name = SrcPos{ .line = shadow_def.line, .character = shadow_def.character + 4 };

    var child = try std.process.spawn(io, .{
        .argv = &.{noxlspPath()},
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .inherit,
    });
    var lsp_watchdog: LspWatchdog = .{};
    try lsp_watchdog.arm(&child, 45_000);
    defer lsp_watchdog.disarm();
    var stdin_buf: [8192]u8 = undefined;
    var stdin_writer = child.stdin.?.writer(io, &stdin_buf);
    const w = &stdin_writer.interface;
    var stdout_buf: [1 << 16]u8 = undefined;
    var stdout_reader = child.stdout.?.reader(io, &stdout_buf);
    const r = &stdout_reader.interface;

    const init = try std.fmt.allocPrint(a, "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{{\"rootUri\":\"{s}\"}}}}", .{root_uri});
    try writeMessage(w, init);
    _ = try readMessage(a, r);
    try writeMessage(w, "{\"jsonrpc\":\"2.0\",\"method\":\"initialized\",\"params\":{}}");

    const open_main = try std.fmt.allocPrint(a, "{{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":" ++
        "{{\"textDocument\":{{\"uri\":\"{s}\",\"languageId\":\"nox\",\"version\":1,\"text\":\"{s}\"}}}}}}", .{ main_uri, try jsonEsc(a, main_src) });
    try writeMessage(w, open_main);
    _ = try readMessage(a, r);
    const open_helper = try std.fmt.allocPrint(a, "{{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":" ++
        "{{\"textDocument\":{{\"uri\":\"{s}\",\"languageId\":\"nox\",\"version\":1,\"text\":\"{s}\"}}}}}}", .{ helper_uri, try jsonEsc(a, helper_src) });
    try writeMessage(w, open_helper);
    _ = try readMessage(a, r);
    const open_shadow = try std.fmt.allocPrint(a, "{{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":" ++
        "{{\"textDocument\":{{\"uri\":\"{s}\",\"languageId\":\"nox\",\"version\":1,\"text\":\"{s}\"}}}}}}", .{ shadow_uri, try jsonEsc(a, shadow_src) });
    try writeMessage(w, open_shadow);
    _ = try readMessage(a, r);

    const alias_req = try std.fmt.allocPrint(a, "{{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/rename\",\"params\":" ++
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}},\"newName\":\"pair\"}}}}", .{ main_uri, alias_pos.line, alias_pos.character });
    try writeMessage(w, alias_req);
    const alias_resp = try readMessage(a, r);
    try std.testing.expect(hasPos(alias_resp, alias_pos));
    try std.testing.expect(hasPos(alias_resp, use_pos));
    try std.testing.expect(std.mem.indexOf(u8, alias_resp, "helper.nox") == null);
    try std.testing.expect(std.mem.indexOf(u8, alias_resp, "\"newText\":\"pair\"") != null);
    try std.testing.expect(!hasPos(alias_resp, import_name));

    const def_req = try std.fmt.allocPrint(a, "{{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"textDocument/rename\",\"params\":" ++
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}},\"newName\":\"triple\"}}}}", .{ helper_uri, def_pos.line, def_pos.character });
    try writeMessage(w, def_req);
    const def_resp = try readMessage(a, r);
    try std.testing.expect(std.mem.indexOf(u8, def_resp, "helper.nox") != null);
    try std.testing.expect(std.mem.indexOf(u8, def_resp, "main.nox") != null);
    try std.testing.expect(hasPos(def_resp, import_name));
    try std.testing.expect(hasPos(def_resp, def_pos));
    try std.testing.expect(!hasPos(def_resp, alias_pos));
    try std.testing.expect(!hasPos(def_resp, use_pos));

    const again = try std.fmt.allocPrint(a, "{{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"textDocument/rename\",\"params\":" ++
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}},\"newName\":\"triple\"}}}}", .{ helper_uri, def_pos.line, def_pos.character });
    try writeMessage(w, again);
    const again_resp = try readMessage(a, r);
    try std.testing.expect(hasPos(again_resp, import_name));

    const changed = try jsonEsc(a, "n: int = 1\n");
    const did_change = try std.fmt.allocPrint(a, "{{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didChange\",\"params\":" ++
        "{{\"textDocument\":{{\"uri\":\"{s}\",\"version\":2}},\"contentChanges\":[{{\"text\":\"{s}\"}}]}}}}", .{ main_uri, changed });
    try writeMessage(w, did_change);
    _ = try readMessage(a, r);

    const after = try std.fmt.allocPrint(a, "{{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"textDocument/rename\",\"params\":" ++
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}},\"newName\":\"triple\"}}}}", .{ helper_uri, def_pos.line, def_pos.character });
    try writeMessage(w, after);
    const after_resp = try readMessage(a, r);
    try std.testing.expect(std.mem.indexOf(u8, after_resp, "main.nox") == null);
    try std.testing.expect(hasPos(after_resp, def_pos));

    const sh_req = try std.fmt.allocPrint(a, "{{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"textDocument/rename\",\"params\":" ++
        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}},\"newName\":\"triple\"}}}}", .{ shadow_uri, shadow_name.line, shadow_name.character });
    try writeMessage(w, sh_req);
    const sh_resp = try readMessage(a, r);
    try std.testing.expect(hasPos(sh_resp, shadow_name));
    try std.testing.expect(!hasPos(sh_resp, shadow_def_name));
    try std.testing.expect(std.mem.indexOf(u8, sh_resp, "\"newText\":\"triple\"") != null);

    try writeMessage(w, "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"shutdown\",\"params\":null}");
    _ = try readMessage(a, r);
    try writeMessage(w, "{\"jsonrpc\":\"2.0\",\"method\":\"exit\"}");
    const term = try child.wait(io);
    try std.testing.expect(term == .exited and term.exited == 0);
}
