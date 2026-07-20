//! noxlsp — Faz W.2 (bkz. nox-teknik-spesifikasyon.md): Nox İÇİN minimal
//! bir Language Server Protocol (LSP) sunucusu.
//!
//! **Bilinçli v1 kapsamı — YALNIZCA tanılama (diagnostics):**
//! `textDocument/didOpen`/`didChange`/`didClose` üzerinde derleyicinin
//! GERÇEK lexer→parser→checker boru hattını (`lexer.zig`/`parser.zig`/
//! `typecheck/checker.zig` — Tree-sitter grameriyle (Faz W.1) AYNI ilke,
//! "editör ARACI derleyiciyi YENİDEN UYGULAMAZ, ONU KULLANIR") çalıştırıp
//! sonucu `textDocument/publishDiagnostics` bildirimine çevirir.
//! `hover`/`completion`/`definition`/`rename` gibi diğer TÜM LSP
//! yetenekleri BİLİNÇLİ olarak v1 kapsamı DIŞINDA bırakılmıştır — bunlar
//! AYRI, kendi doğrulama turlarını gerektiren GENİŞLEMELERDİR (W.2'nin
//! "minimal" sıfatı TAM OLARAK bunu ifade eder).
//!
//! **Bilinen sınırlama — SÜTUN bilgisi YOK:** `ast.Stmt.line` (Faz T.1)
//! yalnızca SATIR taşır, `checker.Diagnostic` de AYNI şekilde (bkz.
//! checker.zig'in modül üstü notu, "İFADE düzeyi hassasiyet HENÜZ yok").
//! Bu yüzden HER tanılamanın `range`i, o SATIRIN TAMAMINI (0. sütundan
//! keyfi büyük bir sütuna kadar) kapsar — GERÇEK bir editörde bu, "hatalı
//! TOKEN'in altını çizme" YERİNE "hatalı SATIRI vurgulama" gibi görünür.
//! Lex/parse hataları (`LexError`/`ParseError`) HİÇ konum TAŞIMADIĞINDAN
//! (bkz. `lexErrorMessage`/`parseErrorMessage`in belge notu) 1. satıra
//! (0-tabanlı `line: 0`) sabitlenir — dosyanın BİR YERİNDE bir sözdizimi
//! hatası OLDUĞUNU bildirir, ama TAM konumu vermez.
//!
//! **Bilinçli v1 sınırlaması — proje-farkında `requires[]`/birinci-taraf
//! çoklu-dosya import ÇÖZÜLMEZ:** yalnızca `nox.*` stdlib importları
//! (`module_loader.resolveImportsFrom`, `noxc`nin KENDİ çözülmüş
//! `stdlib_dir`i ÜZERİNDEN) çözülür — `nox.json`nin `requires[]`i/proje-içi
//! çoklu-dosya importu (Faz O §P.6/Faz U.2) GEREKTİREN dosyalar İÇİN
//! import çözümlemesi BAŞARISIZ olur ve ham (BİRLEŞTİRİLMEMİŞ) modül
//! DOĞRUDAN tip denetimine verilir — bu, "tanımsız fonksiyon" TÜRÜNDE
//! YANLIŞ-POZİTİF tanılamalara yol AÇABİLİR, ama sunucuyu ÇÖKERTMEZ
//! (`LoadError` her zaman YAKALANIR).
//!
//! **Aktarım (transport):** LSP'nin standart stdio çerçevelemesi
//! (`Content-Length: N\r\n\r\n<N bayt JSON>`), JSON-RPC 2.0. `std.json.
//! Value` (dinamik ağaç) İLE ayrıştırılır/`std.json.Stringify.value`la
//! YAZILIR — TAM tipli LSP struct şemaları (onlarca mesaj türü) YAZILMAZ,
//! yalnızca BU sunucunun GERÇEKTEN işlediği alanlar okunur/üretilir.

const std = @import("std");
const lexer = @import("lexer/lexer.zig");
const parser = @import("parser/parser.zig");
const checker = @import("typecheck/checker.zig");
const module_loader = @import("module_loader.zig");
const project = @import("project.zig");

const Position = struct { line: u32, character: u32 };
const Range = struct { start: Position, end: Position };
const LspDiagnostic = struct {
    range: Range,
    severity: u32 = 1, // 1 = Error (LSP DiagnosticSeverity) — bkz. modül üstü not, HER tanılama bir hatadır, uyarı kategorisi v1'de yok
    source: []const u8 = "noxc",
    message: []const u8,
};

const Server = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    /// URI -> belge metni (HER ikisi de `gpa` üzerinde sahiplenilir, bkz.
    /// `storeDocument`/`removeDocument`).
    documents: std.StringHashMapUnmanaged([]const u8) = .empty,
    /// `noxc`nin KENDİ çözülmüş `stdlib/` kökü (bkz. `project.
    /// resolveResourceDirs`) — başlangıçta BİR KEZ hesaplanır, İMPORT
    /// çözümlemesi BAŞARISIZ olursa (silinmiş kurulum, vb.) `null` kalır
    /// ve tanılama YALNIZCA HAM (stdlib'siz) modül üzerinden çalışır.
    stdlib_dir: ?[]const u8,
    shutdown_requested: bool = false,

    fn deinit(self: *Server) void {
        var it = self.documents.iterator();
        while (it.next()) |entry| {
            self.gpa.free(entry.key_ptr.*);
            self.gpa.free(entry.value_ptr.*);
        }
        self.documents.deinit(self.gpa);
    }

    fn storeDocument(self: *Server, uri: []const u8, text: []const u8) !void {
        const owned_text = try self.gpa.dupe(u8, text);
        errdefer self.gpa.free(owned_text);
        if (self.documents.fetchRemove(uri)) |kv| {
            self.gpa.free(kv.key);
            self.gpa.free(kv.value);
        }
        const owned_uri = try self.gpa.dupe(u8, uri);
        try self.documents.put(self.gpa, owned_uri, owned_text);
    }

    fn removeDocument(self: *Server, uri: []const u8) void {
        if (self.documents.fetchRemove(uri)) |kv| {
            self.gpa.free(kv.key);
            self.gpa.free(kv.value);
        }
    }
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var setup_arena = std.heap.ArenaAllocator.init(gpa);
    defer setup_arena.deinit();
    const sa = setup_arena.allocator();

    // Faz Q.3 İLE AYNI kural (bkz. `main.zig`nin `resource_dir_override`ı):
    // `NOX_RESOURCE_DIR` AÇIKÇA verilmişse O kök kullanılır, YOKSA
    // çalıştırılabilir dosyanın KENDİ dizininden (`<exe_dir>/..`) hesaplanır.
    const resource_dir_override = if (init.environ_map.get("NOX_RESOURCE_DIR")) |h| try sa.dupe(u8, h) else null;
    const resource_dirs = project.resolveResourceDirs(sa, io, resource_dir_override) catch null;

    var server = Server{
        .gpa = gpa,
        .io = io,
        .stdlib_dir = if (resource_dirs) |rd| rd.stdlib_dir else null,
    };
    defer server.deinit();

    var stdin_buf: [1 << 16]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().reader(io, &stdin_buf);
    var stdout_buf: [1 << 16]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buf);
    const w = &stdout_writer.interface;

    while (!server.shutdown_requested) {
        const body = readMessage(gpa, &stdin_reader.interface) catch |e| switch (e) {
            error.EndOfStream => break, // istemci stdin'i kapattı — normal çıkış
            else => return e,
        };
        defer gpa.free(body);

        var msg_arena = std.heap.ArenaAllocator.init(gpa);
        defer msg_arena.deinit();
        handleMessage(&server, msg_arena.allocator(), body, w) catch |e| {
            std.debug.print("noxlsp: mesaj isleme hatasi: {t}\n", .{e});
        };
    }
}

/// `Content-Length: N\r\n\r\n` başlığını okuyup TAM `N` baytlık gövdeyi
/// (çağıranın sahiplendiği, `gpa` üzerinde tahsis edilmiş) döner.
fn readMessage(gpa: std.mem.Allocator, r: *std.Io.Reader) ![]u8 {
    var content_length: ?usize = null;
    while (true) {
        // DİKKAT: `takeDelimiterExclusive` delimiter'ı (`\n`) TÜKETMEZ
        // (bkz. `std.Io.Reader`nin KENDİ belge notu — "advancing the seek
        // position up to (but not past) the delimiter") — `Inclusive`
        // varyantı KULLANILMALI (delimiter'ı DAHİL EDER VE TÜKETİR),
        // aksi halde HER satırdan SONRA `\n` buferde KALIR ve bir SONRAKİ
        // okuma (BURADA `readAlloc`) YANLIŞ konumdan BAŞLAR — bu GERÇEKTEN
        // yaşandı (bkz. nox-teknik-spesifikasyon.md'nin W.2 bölümü).
        const line = try r.takeDelimiterInclusive('\n');
        const trimmed = std.mem.trimEnd(u8, line, "\r\n");
        if (trimmed.len == 0) break; // başlıkların sonu
        if (std.mem.startsWith(u8, trimmed, "Content-Length:")) {
            const value = std.mem.trim(u8, trimmed["Content-Length:".len..], " \t");
            content_length = try std.fmt.parseInt(usize, value, 10);
        }
        // diğer başlıklar (ör. Content-Type) YOK SAYILIR — bu sunucu asla üretmez.
    }
    const len = content_length orelse return error.MissingContentLength;
    return r.readAlloc(gpa, len);
}

fn handleMessage(server: *Server, ma: std.mem.Allocator, body: []const u8, w: *std.Io.Writer) !void {
    var parsed = std.json.parseFromSlice(std.json.Value, ma, body, .{}) catch |e| {
        std.debug.print("noxlsp: JSON ayristirma hatasi: {t}\n", .{e});
        return;
    };
    defer parsed.deinit();

    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return,
    };
    const method = switch (obj.get("method") orelse return) {
        .string => |s| s,
        else => return,
    };
    // Bildirimlerde ("id" ALANI YOK) `id_opt == null` — bu, bir YANIT
    // GÖNDERİLMEMESİ GEREKTİĞİNİN (JSON-RPC 2.0) TEK ayırt edicisidir.
    const id_opt = obj.get("id");
    const params_opt = obj.get("params");

    if (std.mem.eql(u8, method, "initialize")) {
        try respondInitialize(ma, w, id_opt);
    } else if (std.mem.eql(u8, method, "shutdown")) {
        try respondNull(ma, w, id_opt);
    } else if (std.mem.eql(u8, method, "exit")) {
        server.shutdown_requested = true;
    } else if (std.mem.eql(u8, method, "textDocument/didOpen")) {
        try handleDidOpen(server, ma, params_opt, w);
    } else if (std.mem.eql(u8, method, "textDocument/didChange")) {
        try handleDidChange(server, ma, params_opt, w);
    } else if (std.mem.eql(u8, method, "textDocument/didClose")) {
        try handleDidClose(server, ma, params_opt, w);
    } else if (id_opt) |id| {
        // Tanınmayan bir İSTEK (bildirim DEĞİL — "initialized" DAHİL diğer
        // TÜM bildirimler burada sessizce yok sayılır) — JSON-RPC 2.0
        // istemcinin HER isteğe bir yanıt BEKLEDİĞİNİ varsayar.
        try respondMethodNotFound(ma, w, id);
    }
}

fn handleDidOpen(server: *Server, ma: std.mem.Allocator, params_opt: ?std.json.Value, w: *std.Io.Writer) !void {
    const params = params_opt orelse return;
    const td = getObjField(params, "textDocument") orelse return;
    const uri = getStrField(td, "uri") orelse return;
    const text = getStrField(td, "text") orelse return;
    try server.storeDocument(uri, text);
    try publishDiagnostics(server, ma, w, uri);
}

fn handleDidChange(server: *Server, ma: std.mem.Allocator, params_opt: ?std.json.Value, w: *std.Io.Writer) !void {
    const params = params_opt orelse return;
    const td = getObjField(params, "textDocument") orelse return;
    const uri = getStrField(td, "uri") orelse return;
    const changes = getArrField(params, "contentChanges") orelse return;
    if (changes.items.len == 0) return;
    // `textDocumentSync = Full` (bkz. `respondInitialize`) İLAN edildiğinden
    // istemci HER zaman TEK, `range`SİZ bir değişiklik (TAM belge metni)
    // gönderir — birden fazla girdi olsa BİLE SONUNCUSU en güncel TAM
    // metindir.
    const text = getStrField(changes.items[changes.items.len - 1], "text") orelse return;
    try server.storeDocument(uri, text);
    try publishDiagnostics(server, ma, w, uri);
}

fn handleDidClose(server: *Server, ma: std.mem.Allocator, params_opt: ?std.json.Value, w: *std.Io.Writer) !void {
    const params = params_opt orelse return;
    const td = getObjField(params, "textDocument") orelse return;
    const uri = getStrField(td, "uri") orelse return;
    server.removeDocument(uri);
    try sendPublishDiagnostics(ma, w, uri, &.{});
}

fn publishDiagnostics(server: *Server, ma: std.mem.Allocator, w: *std.Io.Writer, uri: []const u8) !void {
    const text = server.documents.get(uri) orelse return;

    var diag_arena = std.heap.ArenaAllocator.init(server.gpa);
    defer diag_arena.deinit();
    const diagnostics = try computeDiagnostics(diag_arena.allocator(), server.stdlib_dir, server.io, text);

    try sendPublishDiagnostics(ma, w, uri, diagnostics);
}

/// `source`u lex→parse→(stdlib import çözümlemesi)→tip denetiminden
/// geçirir, TÜM tanılamaları `a` ÜZERİNDE tahsis edilmiş bir dilim olarak
/// döner. Zincirin İLK aşaması (lex/parse) BAŞARISIZ olursa TEK bir
/// (konumsuz) tanılamayla ERKEN döner — sonraki aşamalar hiç ÇALIŞMAZ
/// (bkz. modül üstü not, konum sınırlaması).
fn computeDiagnostics(a: std.mem.Allocator, stdlib_dir: ?[]const u8, io: std.Io, source: []const u8) ![]const LspDiagnostic {
    var diags: std.ArrayListUnmanaged(LspDiagnostic) = .empty;

    const tokens = lexer.tokenize(a, source) catch |e| {
        try diags.append(a, wholeLineDiagnostic(0, lexErrorMessage(e)));
        return diags.toOwnedSlice(a);
    };
    const user_module = parser.parseModule(a, tokens) catch |e| {
        try diags.append(a, wholeLineDiagnostic(0, parseErrorMessage(e)));
        return diags.toOwnedSlice(a);
    };

    const module = if (stdlib_dir) |dir|
        module_loader.resolveImportsFrom(a, io, user_module, dir) catch user_module
    else
        user_module;

    var checker_state = checker.Checker.init(a);
    checker_state.checkModule(module) catch {
        try diags.append(a, wholeLineDiagnostic(0, checker_state.diagnostic orelse "bilinmeyen tip hatasi"));
        return diags.toOwnedSlice(a);
    };
    for (checker_state.diagnostics.items) |d| {
        const line0: u32 = if (d.line > 0) d.line - 1 else 0; // LSP satırları 0-tabanlı, checker'ınki 1-tabanlı
        try diags.append(a, wholeLineDiagnostic(line0, d.message));
    }
    return diags.toOwnedSlice(a);
}

fn wholeLineDiagnostic(line0: u32, message: []const u8) LspDiagnostic {
    return .{
        .range = .{
            .start = .{ .line = line0, .character = 0 },
            // Sütun bilgisi YOK (bkz. modül üstü not) — SATIRIN TAMAMINI
            // kapsayacak kadar büyük, keyfi bir sütun (editörler bunu
            // GERÇEK satır sonuna KENDİLERİ kırpar).
            .end = .{ .line = line0, .character = 10_000 },
        },
        .message = message,
    };
}

fn lexErrorMessage(e: lexer.LexError) []const u8 {
    return switch (e) {
        error.UnexpectedCharacter => "sozdizimi hatasi: beklenmeyen karakter",
        error.UnterminatedString => "sozdizimi hatasi: sonlandirilmamis string literali",
        error.InconsistentIndentation => "sozdizimi hatasi: tutarsiz girinti",
        error.TabsNotAllowed => "sozdizimi hatasi: TAB girintisi desteklenmiyor (yalnizca bosluk kullanin)",
        error.OutOfMemory => "noxlsp: bellek yetersiz",
    };
}

fn parseErrorMessage(e: parser.ParseError) []const u8 {
    return switch (e) {
        error.UnexpectedToken => "sozdizimi hatasi: beklenmeyen token",
        error.InvalidNumberLiteral => "sozdizimi hatasi: gecersiz sayi literali",
        error.OutOfMemory => "noxlsp: bellek yetersiz",
        error.RecursionLimitExceeded => "sozdizimi hatasi: ifade cok derin ic ice (guvenlik siniri asildi)",
    };
}

fn getObjField(v: std.json.Value, key: []const u8) ?std.json.Value {
    return switch (v) {
        .object => |o| o.get(key),
        else => null,
    };
}

fn getStrField(v: std.json.Value, key: []const u8) ?[]const u8 {
    return switch (getObjField(v, key) orelse return null) {
        .string => |s| s,
        else => null,
    };
}

fn getArrField(v: std.json.Value, key: []const u8) ?std.json.Array {
    return switch (getObjField(v, key) orelse return null) {
        .array => |arr| arr,
        else => null,
    };
}

// ---- JSON-RPC yanıt/bildirim gönderimi ----

fn sendJson(ma: std.mem.Allocator, w: *std.Io.Writer, value: anytype) !void {
    var allocating = std.Io.Writer.Allocating.init(ma);
    defer allocating.deinit();
    try std.json.Stringify.value(value, .{}, &allocating.writer);
    const encoded = allocating.written();
    try w.print("Content-Length: {d}\r\n\r\n", .{encoded.len});
    try w.writeAll(encoded);
    try w.flush();
}

fn respondInitialize(ma: std.mem.Allocator, w: *std.Io.Writer, id_opt: ?std.json.Value) !void {
    const id = id_opt orelse return;
    const Capabilities = struct {
        // 1 = TextDocumentSyncKind.Full — HER değişiklikte TAM belge metni
        // gönderilir (bkz. `handleDidChange`in belge notu); artımlı (range
        // tabanlı) senkronizasyon v1 kapsamı DIŞINDA (basitlik).
        textDocumentSync: u32 = 1,
    };
    const ServerInfo = struct {
        name: []const u8 = "noxlsp",
        version: []const u8 = "0.1.0",
    };
    const Result = struct {
        capabilities: Capabilities = .{},
        serverInfo: ServerInfo = .{},
    };
    const Msg = struct {
        jsonrpc: []const u8 = "2.0",
        id: std.json.Value,
        result: Result = .{},
    };
    try sendJson(ma, w, Msg{ .id = id });
}

fn respondNull(ma: std.mem.Allocator, w: *std.Io.Writer, id_opt: ?std.json.Value) !void {
    const id = id_opt orelse return;
    const Msg = struct {
        jsonrpc: []const u8 = "2.0",
        id: std.json.Value,
        result: std.json.Value = .null,
    };
    try sendJson(ma, w, Msg{ .id = id });
}

fn respondMethodNotFound(ma: std.mem.Allocator, w: *std.Io.Writer, id: std.json.Value) !void {
    const ErrObj = struct {
        code: i32 = -32601,
        message: []const u8 = "yontem bulunamadi (noxlsp yalniz tanilama destekler)",
    };
    const Msg = struct {
        jsonrpc: []const u8 = "2.0",
        id: std.json.Value,
        @"error": ErrObj = .{},
    };
    try sendJson(ma, w, Msg{ .id = id });
}

fn sendPublishDiagnostics(ma: std.mem.Allocator, w: *std.Io.Writer, uri: []const u8, diagnostics: []const LspDiagnostic) !void {
    const Params = struct {
        uri: []const u8,
        diagnostics: []const LspDiagnostic,
    };
    const Msg = struct {
        jsonrpc: []const u8 = "2.0",
        method: []const u8 = "textDocument/publishDiagnostics",
        params: Params,
    };
    try sendJson(ma, w, Msg{ .params = .{ .uri = uri, .diagnostics = diagnostics } });
}
