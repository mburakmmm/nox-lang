//! noxlsp — Faz W.2 (bkz. nox-teknik-spesifikasyon.md): Nox İÇİN minimal
//! bir Language Server Protocol (LSP) sunucusu.
//!
//! **Tanılama (diagnostics):** `textDocument/didOpen`/`didChange`/`didClose`
//! üzerinde derleyicinin GERÇEK lexer→parser→checker boru hattını
//! (`lexer.zig`/`parser.zig`/`typecheck/checker.zig` — Tree-sitter
//! grameriyle (Faz W.1) AYNI ilke, "editör ARACI derleyiciyi YENİDEN
//! UYGULAMAZ, ONU KULLANIR") çalıştırıp sonucu `textDocument/
//! publishDiagnostics` bildirimine çevirir.
//!
//! **P1.4 — gezinme (`completion`/`definition`/`hover`):** bkz. `lsp_nav.
//! zig`nin modül üstü notu — bu ÜÇ yetenek, checker'ın GERÇEK tip
//! denetim/sembol-tablosu motorunu YENİDEN KULLANMAK YERİNE (o motor tip
//! DENETİMİ için inşa edilmiştir, konum-tabanlı sorgu İçin DEĞİL), yalnızca
//! `ast.Stmt.span`e dayanan bir statik katmandır. Aynı dosyada üst düzey
//! `func_def`/`class_def`, kapsayan fonksiyonun parametre/yerelleri ve sabit
//! yerleşik listesi çözülür. `import` / `from ... import` ile gelen bir
//! sembolün tanımı, referansları ve yeniden adlandırması hedef dosyayı ayrı
//! ayrıştırarak proje kökünde ve açık belgelerde aranır. `rename` bir
//! `WorkspaceEdit` döner; sunucu dosyaya kendisi yazmaz.
//!
//! **Gerçek span sistemi (bkz. plan dosyası "Gerçek span sistemi +
//! yapılandırılmış tanılamalar"):** lex/parse hataları ARTIK (bkz.
//! `lexer.tokenizeCapturingSpan`/`Parser.last_diagnostic`) GERÇEK bir
//! bayt/satır/sütun aralığı TAŞIR — 0. satıra SABİTLENMEZ. Tip hataları
//! da (bkz. `checker.Diagnostic.span`) artık DEYİM granülerliğinde
//! (bazı durumlarda — ör. çağrı argümanı tip uyuşmazlığı, bkz. `checker.
//! zig`nin `checkArgs`i — DAHA DAR) GERÇEK bir `range` üretir; SATIRIN
//! TAMAMINI kapsayan `wholeLineDiagnostic` YALNIZCA span HİÇ
//! YAKALANAMADIĞINDA (ör. `error.OutOfMemory`) bir GERİ DÜŞÜŞ olarak
//! kullanılır (bkz. `diagnosticFromSpan`).
//!
//! **P1.3 — proje/bağımlılık-farkında import çözümlemesi:** `computeDiagnostics`
//! ARTIK yalnızca `nox.*` stdlibi DEĞİL, `main.zig`nin `resolveImportsForBuild`
//! İLE AYNI iskeleti (bkz. `resolveModuleForLsp`) kullanarak `nox.json`nin
//! `requires[]`ini VE proje-içi çoklu-dosya importunu (Faz O §P.6/Faz U.2)
//! da çözer. **Kasıtlı fark:** bu SALT-OKUNURDUR — `fetch.fetchToCache`
//! (ağ/`git`) HİÇ ÇAĞRILMAZ, `nox.lock` HİÇ GÜNCELLENMEZ (bir editör, KULLANICI
//! HER TUŞ BASIŞINDA ağ G/Ç'si TETİKLEMEMELİDİR) — bir `requires[]` alias'ı
//! HENÜZ getirilmemişse (ilk `noxc build`/`fetch` hiç ÇALIŞTIRILMAMIŞ) o
//! alias sessizce ATLANIR, ilgili importlar ÇÖZÜLEMEZ kalır ("tanımsız
//! fonksiyon" TÜRÜNDE YANLIŞ-POZİTİF tanılamalara yol AÇABİLİR, ama sunucuyu
//! ÇÖKERTMEZ — `resolveModuleForLsp` hiçbir zaman hata DÖNDÜRMEZ, HER
//! başarısızlıkta ham `user_module`e düşer).
//!
//! **Aktarım (transport):** LSP'nin standart stdio çerçevelemesi
//! (`Content-Length: N\r\n\r\n<N bayt JSON>`), JSON-RPC 2.0. `std.json.
//! Value` (dinamik ağaç) İLE ayrıştırılır/`std.json.Stringify.value`la
//! YAZILIR — TAM tipli LSP struct şemaları (onlarca mesaj türü) YAZILMAZ,
//! yalnızca BU sunucunun GERÇEKTEN işlediği alanlar okunur/üretilir.

const std = @import("std");
const builtin = @import("builtin");
const lexer = @import("lexer/lexer.zig");
const parser = @import("parser/parser.zig");
const ast = @import("parser/ast.zig");
const checker = @import("typecheck/checker.zig");
const module_loader = @import("module_loader.zig");
const project = @import("project.zig");
const fetch = @import("pkg/fetch.zig");
const nav = @import("lsp_nav.zig");
const token_mod = @import("lexer/token.zig");
const formatter = @import("fmt/formatter.zig");
const span_mod = @import("span.zig");
const Span = span_mod.Span;

const Position = struct { line: u32, character: u32 };
const Range = struct { start: Position, end: Position };
const Loc = struct { uri: []const u8, range: Range };
const LspDiagnostic = struct {
    range: Range,
    severity: u32 = 1, // 1 = Error (LSP DiagnosticSeverity) — bkz. modül üstü not, HER tanılama bir hatadır, uyarı kategorisi v1'de yok
    source: []const u8 = "noxc",
    message: []const u8,
    /// Yalnızca tek düzenlemesi olan tanılar (şimdilik sekme girintisi).
    code: ?[]const u8 = null,
};

const Server = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    /// URI -> belge metni (HER ikisi de `gpa` üzerinde sahiplenilir, bkz.
    /// `storeDocument`/`removeDocument`).
    documents: std.StringHashMapUnmanaged([]const u8) = .empty,
    /// URI -> ayrıştırılmış tanım/import önbelleği. `didOpen`/`didChange`
    /// yalnızca o dosyayı yeniler; aynı metinle ikinci sorgu yeniden
    /// ayrıştırmaz. Ayrıştırma hatası indekse girmez (`parsed == null`).
    symbols: std.StringHashMapUnmanaged(*FileSymbols) = .empty,
    /// `noxc`nin KENDİ çözülmüş `stdlib/` kökü (bkz. `project.
    /// resolveResourceDirs`) — başlangıçta BİR KEZ hesaplanır, İMPORT
    /// çözümlemesi BAŞARISIZ olursa (silinmiş kurulum, vb.) `null` kalır
    /// ve tanılama YALNIZCA HAM (stdlib'siz) modül üzerinden çalışır.
    stdlib_dir: ?[]const u8,
    /// P1.3: üçüncü-taraf paket ÖNBELLEĞİNİN KÖKÜ — `main.zig`nin `nox_home`ı
    /// İLE AYNI kural (`NOX_HOME` env override, YOKSA `$HOME/.nox`), YALNIZCA
    /// `resolveModuleForLsp`nin ZATEN getirilmiş `requires[]` alias'larını
    /// bulabilmesi İÇİN okunur (bkz. onun belge notu — ASLA buraya YAZILMAZ).
    nox_home: []const u8,
    /// `initialize` kökü. Proje içi importlar `nox.json` olmasa da bu
    /// dizinden çözülür.
    root_uri: ?[]const u8 = null,
    shutdown_requested: bool = false,

    fn deinit(self: *Server) void {
        var it = self.documents.iterator();
        while (it.next()) |entry| {
            self.gpa.free(entry.key_ptr.*);
            self.gpa.free(entry.value_ptr.*);
        }
        self.documents.deinit(self.gpa);
        var sit = self.symbols.iterator();
        while (sit.next()) |entry| {
            self.gpa.free(entry.key_ptr.*);
            entry.value_ptr.*.deinit(self.gpa);
        }
        self.symbols.deinit(self.gpa);
        if (self.root_uri) |u| self.gpa.free(u);
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
        self.reindex(owned_uri, owned_text);
    }

    fn removeDocument(self: *Server, uri: []const u8) void {
        if (self.documents.fetchRemove(uri)) |kv| {
            self.gpa.free(kv.key);
            self.gpa.free(kv.value);
        }
        self.dropIndex(uri);
    }

    fn reindex(self: *Server, uri: []const u8, text: []const u8) void {
        _ = self.cachedNav(uri, text);
    }

    fn dropIndex(self: *Server, uri: []const u8) void {
        if (self.symbols.fetchRemove(uri)) |kv| {
            self.gpa.free(kv.key);
            kv.value.deinit(self.gpa);
        }
    }

    fn cachedNav(self: *Server, uri: []const u8, text: []const u8) ?*FileSymbols {
        const hash = std.hash.Wyhash.hash(0, text);
        if (self.symbols.get(uri)) |fs| {
            if (fs.hash == hash) return fs;
            fs.rebuild(self.gpa, text);
            return fs;
        }
        const fs = self.gpa.create(FileSymbols) catch return null;
        fs.* = .{
            .arena = .init(self.gpa),
            .text = &.{},
            .hash = 0,
            .parsed = null,
        };
        fs.rebuild(self.gpa, text);
        const key = self.gpa.dupe(u8, uri) catch {
            fs.deinit(self.gpa);
            return null;
        };
        self.symbols.put(self.gpa, key, fs) catch {
            self.gpa.free(key);
            fs.deinit(self.gpa);
            return null;
        };
        return fs;
    }
};

const FileSymbols = struct {
    arena: std.heap.ArenaAllocator,
    text: []u8,
    hash: u64,
    parsed: ?nav.ParsedNav,

    fn deinit(self: *FileSymbols, gpa: std.mem.Allocator) void {
        self.arena.deinit();
        gpa.destroy(self);
    }

    fn rebuild(self: *FileSymbols, gpa: std.mem.Allocator, text: []const u8) void {
        self.arena.deinit();
        self.arena = .init(gpa);
        const a = self.arena.allocator();
        self.text = a.dupe(u8, text) catch {
            self.parsed = null;
            self.hash = 0;
            return;
        };
        self.hash = std.hash.Wyhash.hash(0, text);
        self.parsed = nav.parseForNav(a, self.text);
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

    // P1.3: `main.zig`nin `nox_home` hesaplamasıyla BİREBİR AYNI kural
    // (bkz. `Server.nox_home`nin belge notu).
    const nox_home = if (init.environ_map.get("NOX_HOME")) |h| try sa.dupe(u8, h) else blk: {
        const home = init.environ_map.get("HOME") orelse "";
        break :blk try std.fmt.allocPrint(sa, "{s}/.nox", .{home});
    };

    var server = Server{
        .gpa = gpa,
        .io = io,
        .stdlib_dir = if (resource_dirs) |rd| rd.stdlib_dir else null,
        .nox_home = nox_home,
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
            std.debug.print("noxlsp: message handling error: {t}\n", .{e});
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
        std.debug.print("noxlsp: JSON parse error: {t}\n", .{e});
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
        if (params_opt) |p| {
            if (getStrField(p, "rootUri")) |ru| {
                server.root_uri = server.gpa.dupe(u8, ru) catch null;
            }
        }
        try respondInitialize(ma, w, id_opt);
    } else if (std.mem.eql(u8, method, "shutdown")) {
        try respondNull(ma, w, id_opt);
    } else if (std.mem.eql(u8, method, "exit")) {
        server.shutdown_requested = true;
    } else if (std.mem.eql(u8, method, "textDocument/didOpen")) {
        try handleDidOpen(server, ma, params_opt, w);
    } else if (std.mem.eql(u8, method, "textDocument/didChange")) {
        try handleDidChange(server, ma, params_opt, w);
    } else if (std.mem.eql(u8, method, "textDocument/completion")) {
        try handleCompletion(server, ma, params_opt, id_opt, w);
    } else if (std.mem.eql(u8, method, "textDocument/definition")) {
        try handleDefinition(server, ma, params_opt, id_opt, w);
    } else if (std.mem.eql(u8, method, "textDocument/hover")) {
        try handleHover(server, ma, params_opt, id_opt, w);
    } else if (std.mem.eql(u8, method, "textDocument/didClose")) {
        try handleDidClose(server, ma, params_opt, w);
    } else if (std.mem.eql(u8, method, "textDocument/formatting")) {
        try handleFormatting(server, ma, params_opt, id_opt, w);
    } else if (std.mem.eql(u8, method, "textDocument/documentSymbol")) {
        try handleDocumentSymbol(server, ma, params_opt, id_opt, w);
    } else if (std.mem.eql(u8, method, "textDocument/signatureHelp")) {
        try handleSignatureHelp(server, ma, params_opt, id_opt, w);
    } else if (std.mem.eql(u8, method, "textDocument/semanticTokens/full")) {
        try handleSemanticTokens(server, ma, params_opt, id_opt, w);
    } else if (std.mem.eql(u8, method, "textDocument/inlayHint")) {
        try handleInlayHint(server, ma, params_opt, id_opt, w);
    } else if (std.mem.eql(u8, method, "textDocument/references")) {
        try handleReferences(server, ma, params_opt, id_opt, w);
    } else if (std.mem.eql(u8, method, "textDocument/rename")) {
        try handleRename(server, ma, params_opt, id_opt, w);
    } else if (std.mem.eql(u8, method, "textDocument/codeAction")) {
        try handleCodeAction(server, ma, params_opt, id_opt, w);
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

// ---- Faz ÜH.1: `textDocument/formatting` ----

/// `textDocument/formatting`in `{textDocument: {uri}}` gövdesi — `options`
/// (tabSize/insertSpaces) OKUNMAZ, `formatter.formatModule` KENDİ, SABİT
/// biçimlendirme kurallarını uygular (istemcinin girinti tercihi v1 kapsamı
/// DIŞINDA — `compiler/fmt/formatter.zig`nin KENDİSİ de HİÇBİR seçenek
/// PARAMETRESİ almıyor).
fn parseFormattingQuery(params_opt: ?std.json.Value) ?[]const u8 {
    const params = params_opt orelse return null;
    const td = getObjField(params, "textDocument") orelse return null;
    return getStrField(td, "uri");
}

/// `compiler/main.zig`nin `cmdFmt`ıyla BİREBİR AYNI zincir (lex→parse→
/// format) — SADECE dosyaya YAZMAK yerine sonucu DÖNER. `source` GEÇERSİZ
/// sözdizimine sahipse (kullanıcı O AN yazıyor olabilir) `null` döner —
/// ÇAĞIRAN taraf BUNU "hiçbir değişiklik yok" olarak yorumlar, kullanıcının
/// arabelleğini ASLA bozmaz.
fn formatSource(a: std.mem.Allocator, source: []const u8) ?[]const u8 {
    const result = lexer.tokenizeWithTrivia(a, source) catch return null;
    const module = parser.parseModule(a, result.tokens) catch return null;
    return formatter.formatModule(a, module, result.trivia) catch null;
}

/// `source`un TAMAMINI kapsayan GERÇEK (0-tabanlı) bir LSP `Range`i —
/// `\n` sayısı + SON satırın uzunluğu SAYILARAK hesaplanır (keyfi BÜYÜK
/// bir sentinel YERİNE — bkz. `wholeLineDiagnostic`nin AYNI, KASITLI
/// olarak burada TEKRARLANMAYAN "10000 sütun" kısayolu, BU dönüş değeri
/// bir `TextEdit.range`e gittiğinden bazı istemciler AŞIRI-BÜYÜK
/// aralıklara KARŞI HASSAS olabilir).
fn wholeDocumentRange(source: []const u8) Range {
    var end_line: u32 = 0;
    var last_newline: ?usize = null;
    for (source, 0..) |c, i| {
        if (c == '\n') {
            end_line += 1;
            last_newline = i;
        }
    }
    const line_start = if (last_newline) |idx| idx + 1 else 0;
    const end_char: u32 = @intCast(source.len - line_start);
    return .{
        .start = .{ .line = 0, .character = 0 },
        .end = .{ .line = end_line, .character = end_char },
    };
}

fn handleFormatting(server: *Server, ma: std.mem.Allocator, params_opt: ?std.json.Value, id_opt: ?std.json.Value, w: *std.Io.Writer) !void {
    const id = id_opt orelse return;
    var arena = std.heap.ArenaAllocator.init(server.gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const TextEdit = struct { range: Range, newText: []const u8 };
    var edits: []const TextEdit = &.{};
    if (parseFormattingQuery(params_opt)) |uri| {
        if (server.documents.get(uri)) |source| {
            if (formatSource(a, source)) |formatted| {
                edits = &.{.{ .range = wholeDocumentRange(source), .newText = formatted }};
            }
        }
    }

    const Msg = struct {
        jsonrpc: []const u8 = "2.0",
        id: std.json.Value,
        result: []const TextEdit,
    };
    try sendJson(ma, w, Msg{ .id = id, .result = edits });
}

// ---- P1.4: gezinme (bkz. `lsp_nav.zig`nin modül üstü notu) ----

const NavQuery = struct { uri: []const u8, line1: u32, col1: u32 };

/// `textDocument/{completion,definition,hover}`in ORTAK `{textDocument:
/// {uri}, position: {line, character}}` gövdesini ayrıştırır — LSP
/// pozisyonları 0-tabanlıdır, `line1`/`col1` (bkz. `ast.Stmt.span`/`Token`)
/// 1-tabanlıdır (`diagnosticFromSpan`in AYNI dönüşümüyle TUTARLI).
fn parseDocUri(params_opt: ?std.json.Value) ?[]const u8 {
    const params = params_opt orelse return null;
    const td = getObjField(params, "textDocument") orelse return null;
    return getStrField(td, "uri");
}

fn parseNavQuery(params_opt: ?std.json.Value) ?NavQuery {
    const params = params_opt orelse return null;
    const td = getObjField(params, "textDocument") orelse return null;
    const uri = getStrField(td, "uri") orelse return null;
    const pos = getObjField(params, "position") orelse return null;
    const line0 = getIntField(pos, "line") orelse return null;
    const char0 = getIntField(pos, "character") orelse return null;
    if (line0 < 0 or char0 < 0) return null;
    return .{ .uri = uri, .line1 = @as(u32, @intCast(line0)) + 1, .col1 = @as(u32, @intCast(char0)) + 1 };
}

fn resolveNavSymbol(server: *Server, a: std.mem.Allocator, q: NavQuery) !?nav.ResolveResult {
    const source = server.documents.get(q.uri) orelse return null;
    const parsed = nav.parseForNav(a, source) orelse return null;
    const name = nav.identifierAt(parsed.tokens, q.line1, q.col1) orelse return null;
    return nav.resolveAt(a, parsed.module, q.line1, name);
}

fn symbolKindToLsp(kind: nav.SymbolKind) u32 {
    // LSP `CompletionItemKind` — Function=3, Class=7, Variable=6, Keyword=14.
    return switch (kind) {
        .function, .builtin => 3,
        .class => 7,
        .parameter, .local_var => 6,
        .keyword => 14,
    };
}

fn handleCompletion(server: *Server, ma: std.mem.Allocator, params_opt: ?std.json.Value, id_opt: ?std.json.Value, w: *std.Io.Writer) !void {
    const id = id_opt orelse return;
    var arena = std.heap.ArenaAllocator.init(server.gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const CompletionItem = struct { label: []const u8, kind: u32, detail: []const u8 };
    var items: std.ArrayListUnmanaged(CompletionItem) = .empty;

    if (parseNavQuery(params_opt)) |q| {
        if (server.documents.get(q.uri)) |source| {
            if (nav.parseForNav(a, source)) |parsed| {
                const syms = try nav.completionItems(a, parsed.module, q.line1);
                for (syms) |s| try items.append(a, .{ .label = s.name, .kind = symbolKindToLsp(s.kind), .detail = s.detail });
            }
        }
    }

    const Msg = struct {
        jsonrpc: []const u8 = "2.0",
        id: std.json.Value,
        result: []const CompletionItem,
    };
    try sendJson(ma, w, Msg{ .id = id, .result = items.items });
}

fn handleHover(server: *Server, ma: std.mem.Allocator, params_opt: ?std.json.Value, id_opt: ?std.json.Value, w: *std.Io.Writer) !void {
    const id = id_opt orelse return;
    var arena = std.heap.ArenaAllocator.init(server.gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var detail: ?[]const u8 = null;
    if (parseNavQuery(params_opt)) |q| {
        if (try resolveNavSymbol(server, a, q)) |r| detail = r.detail;
    }

    const Contents = struct { kind: []const u8 = "plaintext", value: []const u8 };
    const HoverResult = struct { contents: Contents };
    const Msg = struct {
        jsonrpc: []const u8 = "2.0",
        id: std.json.Value,
        result: ?HoverResult,
    };
    const result: ?HoverResult = if (detail) |d| .{ .contents = .{ .value = d } } else null;
    try sendJson(ma, w, Msg{ .id = id, .result = result });
}

fn handleDefinition(server: *Server, ma: std.mem.Allocator, params_opt: ?std.json.Value, id_opt: ?std.json.Value, w: *std.Io.Writer) !void {
    const id = id_opt orelse return;
    var arena = std.heap.ArenaAllocator.init(server.gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var loc: ?Loc = null;
    if (parseNavQuery(params_opt)) |q| loc = locateDefinition(server, a, q);
    const Msg = struct {
        jsonrpc: []const u8 = "2.0",
        id: std.json.Value,
        result: ?Loc,
    };
    try sendJson(ma, w, Msg{ .id = id, .result = loc });
}

fn spanRange(span: Span) Range {
    if (span.isNone() or span.start_line == 0 or span.start_col == 0) {
        return .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 0 } };
    }
    return .{
        .start = .{ .line = span.start_line - 1, .character = span.start_col - 1 },
        .end = .{ .line = span.end_line - 1, .character = span.end_col - 1 },
    };
}

fn locOf(uri: []const u8, span: Span) Loc {
    return .{ .uri = uri, .range = spanRange(span) };
}

fn locateDefinition(server: *Server, a: std.mem.Allocator, q: NavQuery) ?Loc {
    const source = server.documents.get(q.uri) orelse return null;
    const parsed = nav.parseForNav(a, source) orelse return null;
    const chain = nav.chainAt(a, parsed.tokens, q.line1, q.col1) catch null orelse return null;
    if (chain.len == 0) return null;
    if (chain.len == 1) {
        if (nav.resolveAt(a, parsed.module, q.line1, chain[0]) catch null) |r| {
            if (!r.span.isNone()) return locOf(q.uri, r.span);
        }
        if (nav.importBinding(parsed.module, chain[0])) |imp| {
            return definitionOfImport(server, a, q.uri, imp.segments, imp.symbol);
        }
        return null;
    }
    const head = nav.importBinding(parsed.module, chain[0]) orelse return null;
    if (head.symbol.len != 0) return definitionOfImport(server, a, q.uri, head.segments, head.symbol);
    const prefix: usize = if (head.segments.len > 0 and std.mem.eql(u8, head.local, head.segments[0])) head.segments.len else 1;
    if (chain.len <= prefix) return definitionOfImport(server, a, q.uri, head.segments, "");
    return definitionOfImport(server, a, q.uri, head.segments, chain[chain.len - 1]);
}

fn definitionOfImport(server: *Server, a: std.mem.Allocator, from_uri: []const u8, segments: []const []const u8, symbol: []const u8) ?Loc {
    const path = resolveImport(server, a, from_uri, segments) orelse return null;
    const uri = pathToUri(a, path) catch return null;
    const text = textOfPath(server, a, uri, path) orelse return null;
    if (symbol.len == 0) {
        return .{ .uri = uri, .range = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 0 } } };
    }
    const parsed = nav.parseForNav(a, text) orelse return null;
    for (parsed.module.body) |s| {
        switch (s.kind) {
            .func_def => |fd| if (std.mem.eql(u8, fd.name, symbol) and !s.span.isNone()) return locOf(uri, s.span),
            .class_def => |cd| if (std.mem.eql(u8, cd.name, symbol) and !s.span.isNone()) return locOf(uri, s.span),
            else => {},
        }
    }
    return null;
}

fn textOfPath(server: *Server, a: std.mem.Allocator, uri: []const u8, path: []const u8) ?[]const u8 {
    if (server.documents.get(uri)) |open| return open;
    return std.Io.Dir.cwd().readFileAlloc(server.io, path, a, .limited(1024 * 1024)) catch null;
}

fn resolveImport(server: *Server, a: std.mem.Allocator, from_uri: []const u8, segments: []const []const u8) ?[]const u8 {
    const stdlib = server.stdlib_dir orelse return null;
    var roots: std.StringHashMapUnmanaged([]const u8) = .empty;
    const proot = fillAliasRoots(server, a, from_uri, &roots);
    return module_loader.resolveImportFilePath(a, server.io, segments, &roots, stdlib, proot) catch null;
}

fn fillAliasRoots(server: *Server, a: std.mem.Allocator, file_uri: []const u8, roots: *std.StringHashMapUnmanaged([]const u8)) ?[]const u8 {
    const dir = uriToDir(a, file_uri) catch null;
    const found = if (dir) |d| (project.findProjectRoot(a, server.io, d) catch null) else null;
    const root = found orelse blk: {
        if (server.root_uri) |ru| break :blk uriToPath(a, ru) catch null;
        break :blk dir;
    };
    const proot = root orelse return null;
    const manifest = project.loadManifest(a, server.io, proot) catch return proot;
    const lock = project.loadLockfile(a, server.io, proot) catch project.Lockfile{};
    for (manifest.requires) |req| {
        const locked = project.findLocked(lock, req.alias) orelse continue;
        const cache_dir = fetch.cachedDirFor(a, server.nox_home, locked.repo, locked.resolved) catch continue;
        if (std.Io.Dir.accessAbsolute(server.io, cache_dir, .{})) |_| {
            roots.put(a, req.alias, cache_dir) catch continue;
        } else |_| {}
    }
    return proot;
}

fn pathToUri(a: std.mem.Allocator, path: []const u8) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    try buf.appendSlice(a, "file://");
    for (path) |c| {
        const plain = std.ascii.isAlphanumeric(c) or c == '/' or c == '.' or c == '_' or c == '-' or c == ':';
        if (plain) {
            try buf.append(a, c);
        } else {
            const esc = try std.fmt.allocPrint(a, "%{X:0>2}", .{c});
            try buf.appendSlice(a, esc);
        }
    }
    return buf.toOwnedSlice(a);
}

fn uriToPath(a: std.mem.Allocator, uri: []const u8) ![]const u8 {
    const prefix = "file://";
    if (!std.mem.startsWith(u8, uri, prefix)) return error.BadUri;
    const encoded_path = uri[prefix.len..];
    var decoded: std.ArrayListUnmanaged(u8) = .empty;
    var i: usize = 0;
    while (i < encoded_path.len) {
        if (encoded_path[i] == '%' and i + 2 < encoded_path.len) {
            const byte = std.fmt.parseInt(u8, encoded_path[i + 1 .. i + 3], 16) catch {
                try decoded.append(a, encoded_path[i]);
                i += 1;
                continue;
            };
            try decoded.append(a, byte);
            i += 3;
        } else {
            try decoded.append(a, encoded_path[i]);
            i += 1;
        }
    }
    return decoded.toOwnedSlice(a);
}

const SymOut = struct {
    name: []const u8,
    kind: u32,
    range: Range,
    selectionRange: Range,
    children: []const SymOut = &.{},
};

fn handleDocumentSymbol(server: *Server, ma: std.mem.Allocator, params_opt: ?std.json.Value, id_opt: ?std.json.Value, w: *std.Io.Writer) !void {
    const id = id_opt orelse return;
    var arena = std.heap.ArenaAllocator.init(server.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const empty: []const SymOut = &.{};
    const uri = parseDocUri(params_opt) orelse {
        try sendJson(ma, w, .{ .jsonrpc = "2.0", .id = id, .result = empty });
        return;
    };
    const source = server.documents.get(uri) orelse {
        try sendJson(ma, w, .{ .jsonrpc = "2.0", .id = id, .result = empty });
        return;
    };
    const parsed = nav.parseForNav(a, source) orelse {
        try sendJson(ma, w, .{ .jsonrpc = "2.0", .id = id, .result = empty });
        return;
    };
    const items = nav.outline(a, parsed.module) catch {
        try sendJson(ma, w, .{ .jsonrpc = "2.0", .id = id, .result = empty });
        return;
    };
    var out: std.ArrayListUnmanaged(SymOut) = .empty;
    for (items) |it| {
        var kids: std.ArrayListUnmanaged(SymOut) = .empty;
        for (it.children) |c| try kids.append(a, .{
            .name = c.name,
            .kind = c.kind,
            .range = spanRange(c.span),
            .selectionRange = spanRange(c.span),
        });
        try out.append(a, .{
            .name = it.name,
            .kind = it.kind,
            .range = spanRange(it.span),
            .selectionRange = spanRange(it.span),
            .children = kids.items,
        });
    }
    try sendJson(ma, w, .{ .jsonrpc = "2.0", .id = id, .result = out.items });
}

const SigParamOut = struct { label: []const u8 };
const SigInfoOut = struct {
    label: []const u8,
    parameters: []const SigParamOut,
    activeParameter: u32,
};
const SigHelpOut = struct {
    signatures: []const SigInfoOut,
    activeSignature: u32 = 0,
};

fn handleSignatureHelp(server: *Server, ma: std.mem.Allocator, params_opt: ?std.json.Value, id_opt: ?std.json.Value, w: *std.Io.Writer) !void {
    const id = id_opt orelse return;
    var arena = std.heap.ArenaAllocator.init(server.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const sig = signatureLookup(server, a, params_opt);
    const result: ?SigHelpOut = if (sig) |found| blk: {
        var params: std.ArrayListUnmanaged(SigParamOut) = .empty;
        for (found.params) |p| try params.append(a, .{ .label = p.name });
        const info = SigInfoOut{
            .label = found.label,
            .parameters = params.items,
            .activeParameter = found.active,
        };
        break :blk .{ .signatures = &.{info} };
    } else null;
    try sendJson(ma, w, .{ .jsonrpc = "2.0", .id = id, .result = result });
}

fn signatureLookup(server: *Server, a: std.mem.Allocator, params_opt: ?std.json.Value) ?nav.SignatureInfo {
    const q = parseNavQuery(params_opt) orelse return null;
    const source = server.documents.get(q.uri) orelse return null;
    const parsed = nav.parseForNav(a, source) orelse return null;
    if (nav.signatureAt(a, parsed.tokens, parsed.module, q.line1, q.col1) catch null) |sig| return sig;
    const site = nav.callSiteAt(a, parsed.tokens, q.line1, q.col1) catch null orelse return null;
    if (site.chain.len == 0) return null;
    const head = nav.importBinding(parsed.module, site.chain[0]) orelse return null;
    const path = resolveImport(server, a, q.uri, head.segments) orelse return null;
    const uri = pathToUri(a, path) catch return null;
    const text = textOfPath(server, a, uri, path) orelse return null;
    const foreign = nav.parseForNav(a, text) orelse return null;
    const lookup: []const []const u8 = if (head.symbol.len > 0)
        &.{head.symbol}
    else if (site.chain.len > 1)
        site.chain[site.chain.len - 1 ..]
    else
        return null;
    return nav.signatureFor(a, foreign.module, lookup, site.active) catch null;
}

const TokResult = struct { data: []const u32 };

fn handleSemanticTokens(server: *Server, ma: std.mem.Allocator, params_opt: ?std.json.Value, id_opt: ?std.json.Value, w: *std.Io.Writer) !void {
    const id = id_opt orelse return;
    var arena = std.heap.ArenaAllocator.init(server.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const empty = TokResult{ .data = &.{} };
    const uri = parseDocUri(params_opt) orelse {
        try sendJson(ma, w, .{ .jsonrpc = "2.0", .id = id, .result = empty });
        return;
    };
    const source = server.documents.get(uri) orelse {
        try sendJson(ma, w, .{ .jsonrpc = "2.0", .id = id, .result = empty });
        return;
    };
    const parsed = nav.parseForNav(a, source) orelse {
        try sendJson(ma, w, .{ .jsonrpc = "2.0", .id = id, .result = empty });
        return;
    };
    const data = nav.semanticTokens(a, parsed.tokens, parsed.module) catch {
        try sendJson(ma, w, .{ .jsonrpc = "2.0", .id = id, .result = empty });
        return;
    };
    try sendJson(ma, w, .{ .jsonrpc = "2.0", .id = id, .result = TokResult{ .data = data } });
}

const HintOut = struct {
    position: Position,
    label: []const u8,
    paddingLeft: bool = false,
    paddingRight: bool = true,
};

fn handleInlayHint(server: *Server, ma: std.mem.Allocator, params_opt: ?std.json.Value, id_opt: ?std.json.Value, w: *std.Io.Writer) !void {
    const id = id_opt orelse return;
    var arena = std.heap.ArenaAllocator.init(server.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const empty: []const HintOut = &.{};
    const uri = parseDocUri(params_opt) orelse {
        try sendJson(ma, w, .{ .jsonrpc = "2.0", .id = id, .result = empty });
        return;
    };
    const source = server.documents.get(uri) orelse {
        try sendJson(ma, w, .{ .jsonrpc = "2.0", .id = id, .result = empty });
        return;
    };
    const parsed = nav.parseForNav(a, source) orelse {
        try sendJson(ma, w, .{ .jsonrpc = "2.0", .id = id, .result = empty });
        return;
    };
    const hints = nav.parameterInlays(a, parsed.tokens, parsed.module) catch {
        try sendJson(ma, w, .{ .jsonrpc = "2.0", .id = id, .result = empty });
        return;
    };
    var out: std.ArrayListUnmanaged(HintOut) = .empty;
    for (hints) |h| try out.append(a, .{
        .position = .{ .line = h.line0, .character = h.character0 },
        .label = h.label,
    });
    try sendJson(ma, w, .{ .jsonrpc = "2.0", .id = id, .result = out.items });
}

fn handleReferences(server: *Server, ma: std.mem.Allocator, params_opt: ?std.json.Value, id_opt: ?std.json.Value, w: *std.Io.Writer) !void {
    const id = id_opt orelse return;
    var arena = std.heap.ArenaAllocator.init(server.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const locs = if (parseNavQuery(params_opt)) |q| collectRefs(server, a, q) else &.{};
    try sendJson(ma, w, .{ .jsonrpc = "2.0", .id = id, .result = locs });
}

const RefHit = struct { uri: []const u8, span: Span };

fn collectRefs(server: *Server, a: std.mem.Allocator, q: NavQuery) []const Loc {
    var hits: std.ArrayListUnmanaged(RefHit) = .empty;
    const source = server.documents.get(q.uri) orelse return &.{};
    const cached = server.cachedNav(q.uri, source) orelse return &.{};
    const parsed = cached.parsed orelse return &.{};
    const chain = (nav.chainAt(a, parsed.tokens, q.line1, q.col1) catch return &.{}) orelse return &.{};
    if (chain.len == 0) return &.{};
    if (chain.len == 1) {
        if (isAliasToken(parsed, q.line1, q.col1)) {
            collectAliasRefs(server, a, q.uri, chain[0], &hits) catch return &.{};
        } else if (nav.resolveAt(a, parsed.module, q.line1, chain[0]) catch null) |r| {
            if (r.span.isNone()) return &.{};
            if (isPublishedDef(parsed.module, r.span)) {
                const segs = moduleSegments(server, a, q.uri);
                const before = hits.items.len;
                if (segs.len != 0) refsOfSymbol(server, a, q.uri, segs, chain[0], &hits) catch {};
                if (hits.items.len == before) appendLocalUses(a, q.uri, parsed, r.span, &hits) catch return &.{};
            } else {
                appendLocalUses(a, q.uri, parsed, r.span, &hits) catch return &.{};
            }
        } else if (nav.importBinding(parsed.module, chain[0])) |imp| {
            if (imp.symbol.len == 0) return &.{};
            if (!std.mem.eql(u8, imp.symbol, imp.local)) {
                collectAliasRefs(server, a, q.uri, chain[0], &hits) catch return &.{};
            } else {
                refsOfSymbol(server, a, q.uri, imp.segments, imp.symbol, &hits) catch return &.{};
            }
        } else if (originalImportAt(parsed, q.line1, q.col1)) |imp| {
            refsOfSymbol(server, a, q.uri, imp.segments, imp.symbol, &hits) catch return &.{};
        }
    } else if (nav.importBinding(parsed.module, chain[0])) |head| {
        if (head.symbol.len != 0) {
            refsOfSymbol(server, a, q.uri, head.segments, head.symbol, &hits) catch return &.{};
        } else {
            const prefix: usize = if (head.segments.len > 0 and std.mem.eql(u8, head.local, head.segments[0])) head.segments.len else 1;
            if (chain.len > prefix) refsOfSymbol(server, a, q.uri, head.segments, chain[chain.len - 1], &hits) catch return &.{};
        }
    }
    var out: std.ArrayListUnmanaged(Loc) = .empty;
    for (hits.items) |h| {
        if (h.span.isNone()) continue;
        out.append(a, locOf(h.uri, h.span)) catch return &.{};
    }
    return out.items;
}

fn refsOfSymbol(server: *Server, a: std.mem.Allocator, from_uri: []const u8, segments: []const []const u8, symbol: []const u8, hits: *std.ArrayListUnmanaged(RefHit)) !void {
    const path = resolveImport(server, a, from_uri, segments) orelse return;
    const def_uri = pathToUri(a, path) catch return;
    if (textOfPath(server, a, def_uri, path)) |text| {
        if (server.cachedNav(def_uri, text)) |cached| {
            if (cached.parsed) |parsed| {
                var def_span: Span = .{};
                for (parsed.module.body) |s| {
                    switch (s.kind) {
                        .func_def => |fd| {
                            if (std.mem.eql(u8, fd.name, symbol)) def_span = s.span;
                        },
                        .class_def => |cd| {
                            if (std.mem.eql(u8, cd.name, symbol)) def_span = s.span;
                        },
                        else => {},
                    }
                }
                if (!def_span.isNone()) {
                    const uses = nav.usesOfSpan(a, parsed.tokens, parsed.module, def_span) catch &[_]Span{};
                    for (uses) |u| try hits.append(a, .{ .uri = def_uri, .span = u });
                }
            }
        }
    }
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    try seen.put(a, def_uri, {});
    var docs = server.documents.iterator();
    while (docs.next()) |entry| {
        try seen.put(a, entry.key_ptr.*, {});
        try refsInText(server, a, entry.value_ptr.*, entry.key_ptr.*, segments, symbol, hits);
    }
    var unused_roots: std.StringHashMapUnmanaged([]const u8) = .empty;
    const root = fillAliasRoots(server, a, from_uri, &unused_roots) orelse return;
    var files: std.ArrayListUnmanaged([]const u8) = .empty;
    walkNox(a, server.io, root, &files);
    for (files.items) |fp| {
        const furi = pathToUri(a, fp) catch continue;
        if (seen.contains(furi)) continue;
        const text = std.Io.Dir.cwd().readFileAlloc(server.io, fp, a, .limited(1024 * 1024)) catch continue;
        try refsInText(server, a, text, furi, segments, symbol, hits);
    }
}

fn refsInText(server: *Server, a: std.mem.Allocator, text: []const u8, uri: []const u8, segments: []const []const u8, symbol: []const u8, hits: *std.ArrayListUnmanaged(RefHit)) !void {
    const cached = server.cachedNav(uri, text) orelse return;
    const parsed = cached.parsed orelse return;
    if (fromImportOf(parsed.module, segments, symbol)) |imported| {
        if (originalNameSpan(parsed.tokens, segments, symbol)) |sp| {
            try hits.append(a, .{ .uri = uri, .span = sp });
        }
        if (imported.alias == null) {
            for (parsed.tokens) |t| {
                if (t.kind != .identifier or !std.mem.eql(u8, t.lexeme, symbol)) continue;
                if (nav.resolveAt(a, parsed.module, t.line, t.lexeme) catch null) |r| {
                    if (!r.span.isNone()) continue;
                }
                const sp = tokenSpan(t);
                if (spanEq(sp, originalNameSpan(parsed.tokens, segments, symbol) orelse .{})) continue;
                try hits.append(a, .{ .uri = uri, .span = sp });
            }
        }
    }
    if (importedModuleLocal(parsed.module, segments)) |local| {
        const tokens = parsed.tokens;
        var i: usize = 0;
        while (i + 2 < tokens.len) : (i += 1) {
            if (tokens[i].kind != .identifier or !std.mem.eql(u8, tokens[i].lexeme, local)) continue;
            if (tokens[i + 1].kind != .dot) continue;
            if (tokens[i + 2].kind != .identifier or !std.mem.eql(u8, tokens[i + 2].lexeme, symbol)) continue;
            try hits.append(a, .{ .uri = uri, .span = tokenSpan(tokens[i + 2]) });
        }
    }
}

fn tokenSpan(t: token_mod.Token) Span {
    return .{
        .start_line = t.line,
        .start_col = t.col,
        .end_line = t.end_line,
        .end_col = t.end_col,
    };
}

fn importedModuleLocal(module: ast.Module, segments: []const []const u8) ?[]const u8 {
    for (module.body) |s| {
        switch (s.kind) {
            .import_stmt => |imp| {
                if (!segmentsEql(imp.segments, segments)) continue;
                if (imp.alias) |al| return al;
                if (imp.segments.len == 0) return null;
                return imp.segments[imp.segments.len - 1];
            },
            else => {},
        }
    }
    return null;
}

const ImportedName = struct { alias: ?[]const u8 };

fn fromImportOf(module: ast.Module, segments: []const []const u8, symbol: []const u8) ?ImportedName {
    for (module.body) |s| {
        switch (s.kind) {
            .from_import_stmt => |fi| {
                if (!segmentsEql(fi.segments, segments)) continue;
                for (fi.names) |n| {
                    if (std.mem.eql(u8, n.name, symbol)) return .{ .alias = n.alias };
                }
            },
            else => {},
        }
    }
    return null;
}

fn spanEq(a: Span, b: Span) bool {
    return a.start_line == b.start_line and a.start_col == b.start_col and a.end_line == b.end_line and a.end_col == b.end_col;
}

fn identifierIndex(tokens: []const token_mod.Token, line1: u32, col1: u32) ?usize {
    for (tokens, 0..) |t, i| {
        if (t.kind != .identifier) continue;
        if (t.line == line1 and col1 >= t.col and col1 <= t.end_col) return i;
    }
    return null;
}

fn isAliasToken(parsed: nav.ParsedNav, line1: u32, col1: u32) bool {
    const idx = identifierIndex(parsed.tokens, line1, col1) orelse return false;
    if (idx == 0 or parsed.tokens[idx - 1].kind != .kw_as) return false;
    const name = parsed.tokens[idx].lexeme;
    for (parsed.module.body) |s| {
        switch (s.kind) {
            .from_import_stmt => |fi| {
                for (fi.names) |n| {
                    if (n.alias) |al| if (std.mem.eql(u8, al, name)) return true;
                }
            },
            else => {},
        }
    }
    return false;
}

fn originalImportAt(parsed: nav.ParsedNav, line1: u32, col1: u32) ?nav.ImportRef {
    const idx = identifierIndex(parsed.tokens, line1, col1) orelse return null;
    if (idx + 1 >= parsed.tokens.len or parsed.tokens[idx + 1].kind != .kw_as) return null;
    const name = parsed.tokens[idx].lexeme;
    for (parsed.module.body) |s| {
        switch (s.kind) {
            .from_import_stmt => |fi| {
                for (fi.names) |n| {
                    if (n.alias == null) continue;
                    if (!std.mem.eql(u8, n.name, name)) continue;
                    const local = n.alias orelse n.name;
                    return .{ .segments = fi.segments, .symbol = n.name, .local = local, .span = s.span };
                }
            },
            else => {},
        }
    }
    return null;
}

fn originalNameSpan(tokens: []const token_mod.Token, segments: []const []const u8, symbol: []const u8) ?Span {
    var i: usize = 0;
    while (i < tokens.len) : (i += 1) {
        if (tokens[i].kind != .kw_from) continue;
        var j = i + 1;
        var ok = true;
        for (segments, 0..) |seg, si| {
            if (j >= tokens.len or tokens[j].kind != .identifier or !std.mem.eql(u8, tokens[j].lexeme, seg)) {
                ok = false;
                break;
            }
            j += 1;
            if (si + 1 < segments.len) {
                if (j >= tokens.len or tokens[j].kind != .dot) {
                    ok = false;
                    break;
                }
                j += 1;
            }
        }
        if (!ok or j >= tokens.len or tokens[j].kind != .kw_import) continue;
        j += 1;
        while (j < tokens.len and tokens[j].kind != .newline) : (j += 1) {
            if (tokens[j].kind != .identifier) continue;
            if (j > 0 and tokens[j - 1].kind == .kw_as) continue;
            if (!std.mem.eql(u8, tokens[j].lexeme, symbol)) continue;
            return tokenSpan(tokens[j]);
        }
    }
    return null;
}

fn isPublishedDef(module: ast.Module, span: Span) bool {
    if (span.isNone()) return false;
    for (module.body) |s| {
        switch (s.kind) {
            .func_def, .class_def => if (spanEq(s.span, span)) return true,
            else => {},
        }
    }
    return false;
}

fn appendLocalUses(a: std.mem.Allocator, uri: []const u8, parsed: nav.ParsedNav, span: Span, hits: *std.ArrayListUnmanaged(RefHit)) !void {
    const uses = try nav.usesOfSpan(a, parsed.tokens, parsed.module, span);
    for (uses) |s| try hits.append(a, .{ .uri = uri, .span = s });
}

fn collectAliasRefs(server: *Server, a: std.mem.Allocator, uri: []const u8, local: []const u8, hits: *std.ArrayListUnmanaged(RefHit)) !void {
    const source = server.documents.get(uri) orelse return;
    const cached = server.cachedNav(uri, source) orelse return;
    const parsed = cached.parsed orelse return;
    for (parsed.tokens, 0..) |t, i| {
        if (t.kind != .identifier or !std.mem.eql(u8, t.lexeme, local)) continue;
        const binding = i > 0 and parsed.tokens[i - 1].kind == .kw_as;
        if (!binding) {
            if (nav.resolveAt(a, parsed.module, t.line, t.lexeme) catch null) |r| {
                if (!r.span.isNone()) continue;
            }
        }
        try hits.append(a, .{ .uri = uri, .span = tokenSpan(t) });
    }
}

fn moduleSegments(server: *Server, a: std.mem.Allocator, uri: []const u8) []const []const u8 {
    const path = uriToPath(a, uri) catch return &.{};
    var roots: std.StringHashMapUnmanaged([]const u8) = .empty;
    const proot = fillAliasRoots(server, a, uri, &roots) orelse return &.{};
    var rel = path;
    if (std.mem.startsWith(u8, path, proot) and path.len >= proot.len) {
        rel = path[proot.len..];
        if (rel.len > 0 and rel[0] == '/') rel = rel[1..];
    }
    if (std.mem.endsWith(u8, rel, ".nox")) rel = rel[0 .. rel.len - 4];
    if (rel.len == 0) return &.{};
    var parts: std.ArrayListUnmanaged([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, rel, '/');
    while (it.next()) |part| {
        if (part.len == 0) continue;
        parts.append(a, part) catch return &.{};
    }
    return parts.items;
}

fn segmentsEql(left: []const []const u8, right: []const []const u8) bool {
    if (left.len != right.len) return false;
    for (left, right) |x, y| if (!std.mem.eql(u8, x, y)) return false;
    return true;
}

fn walkNox(a: std.mem.Allocator, io: std.Io, root: []const u8, out: *std.ArrayListUnmanaged([]const u8)) void {
    var dir = std.Io.Dir.openDirAbsolute(io, root, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var walker = dir.walk(a) catch return;
    defer walker.deinit();
    var count: usize = 0;
    while (walker.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".nox")) continue;
        if (count > 400) return;
        var skip = false;
        var part_start: usize = 0;
        var depth: u8 = 0;
        for (entry.path, 0..) |c, i| {
            if (c != '/') continue;
            const part = entry.path[part_start..i];
            if (part.len > 0 and (part[0] == '.' or std.mem.eql(u8, part, "zig-out") or std.mem.eql(u8, part, "zig-cache"))) skip = true;
            depth += 1;
            part_start = i + 1;
        }
        if (skip or depth > 6) continue;
        const full = std.fmt.allocPrint(a, "{s}/{s}", .{ root, entry.path }) catch continue;
        out.append(a, full) catch {};
        count += 1;
    }
}

fn handleRename(server: *Server, ma: std.mem.Allocator, params_opt: ?std.json.Value, id_opt: ?std.json.Value, w: *std.Io.Writer) !void {
    const id = id_opt orelse return;
    var arena = std.heap.ArenaAllocator.init(server.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const q = parseNavQuery(params_opt) orelse {
        try sendJson(ma, w, .{ .jsonrpc = "2.0", .id = id, .result = null });
        return;
    };
    const new_name = if (params_opt) |p| (getStrField(p, "newName") orelse "") else "";
    if (!isIdent(new_name)) {
        try sendError(ma, w, id, -32602, "new name is not an identifier");
        return;
    }
    if (renameRejected(server, a, q)) {
        try sendError(ma, w, id, -32602, "cannot rename this symbol");
        return;
    }
    const locs = collectRefs(server, a, q);
    if (locs.len == 0) {
        try sendJson(ma, w, .{ .jsonrpc = "2.0", .id = id, .result = null });
        return;
    }
    var changes: std.json.ObjectMap = .empty;
    for (locs) |loc| {
        const edit = try editValue(a, loc.range, new_name);
        const gop = try changes.getOrPut(a, loc.uri);
        if (!gop.found_existing) gop.value_ptr.* = .{ .array = std.json.Array.init(a) };
        try gop.value_ptr.array.append(edit);
    }
    var result_obj: std.json.ObjectMap = .empty;
    try result_obj.put(a, "changes", .{ .object = changes });
    try sendJson(ma, w, .{ .jsonrpc = "2.0", .id = id, .result = std.json.Value{ .object = result_obj } });
}

fn renameRejected(server: *Server, a: std.mem.Allocator, q: NavQuery) bool {
    const source = server.documents.get(q.uri) orelse return true;
    const cached = server.cachedNav(q.uri, source) orelse return true;
    const parsed = cached.parsed orelse return true;
    const chain = (nav.chainAt(a, parsed.tokens, q.line1, q.col1) catch return true) orelse return true;
    if (chain.len != 1) return false;
    if (isAliasToken(parsed, q.line1, q.col1)) return false;
    if (originalImportAt(parsed, q.line1, q.col1) != null) return false;
    if (nav.importBinding(parsed.module, chain[0]) != null) return false;
    if (nav.resolveAt(a, parsed.module, q.line1, chain[0]) catch null) |r| return r.span.isNone();
    return true;
}

fn isIdent(name: []const u8) bool {
    if (name.len == 0) return false;
    const c0 = name[0];
    if (!(std.ascii.isAlphabetic(c0) or c0 == '_')) return false;
    for (name[1..]) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_')) return false;
    return true;
}

fn editValue(a: std.mem.Allocator, range: Range, text: []const u8) !std.json.Value {
    var obj: std.json.ObjectMap = .empty;
    try obj.put(a, "range", try rangeValue(a, range));
    try obj.put(a, "newText", .{ .string = text });
    return .{ .object = obj };
}

fn rangeValue(a: std.mem.Allocator, range: Range) !std.json.Value {
    var obj: std.json.ObjectMap = .empty;
    try obj.put(a, "start", try posValue(a, range.start));
    try obj.put(a, "end", try posValue(a, range.end));
    return .{ .object = obj };
}

fn posValue(a: std.mem.Allocator, pos: Position) !std.json.Value {
    var obj: std.json.ObjectMap = .empty;
    try obj.put(a, "line", .{ .integer = pos.line });
    try obj.put(a, "character", .{ .integer = pos.character });
    return .{ .object = obj };
}

fn handleCodeAction(server: *Server, ma: std.mem.Allocator, params_opt: ?std.json.Value, id_opt: ?std.json.Value, w: *std.Io.Writer) !void {
    const id = id_opt orelse return;
    var arena = std.heap.ArenaAllocator.init(server.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const empty: []const std.json.Value = &.{};
    const uri = parseFormattingQuery(params_opt) orelse {
        try sendJson(ma, w, .{ .jsonrpc = "2.0", .id = id, .result = empty });
        return;
    };
    const source = server.documents.get(uri) orelse {
        try sendJson(ma, w, .{ .jsonrpc = "2.0", .id = id, .result = empty });
        return;
    };
    var wants = false;
    if (params_opt) |p| {
        if (getObjField(p, "context")) |ctx| {
            if (getArrField(ctx, "diagnostics")) |ds| {
                for (ds.items) |d| {
                    const msg = getStrField(d, "message") orelse "";
                    const code = getStrField(d, "code") orelse "";
                    if (std.mem.eql(u8, code, "tabs") or std.mem.indexOf(u8, msg, "TAB indentation") != null) wants = true;
                }
            }
        }
    }
    if (!wants or std.mem.indexOfScalar(u8, source, '\t') == null) {
        try sendJson(ma, w, .{ .jsonrpc = "2.0", .id = id, .result = empty });
        return;
    }
    const replaced = try std.mem.replaceOwned(u8, a, source, "\t", "    ");
    var changes: std.json.ObjectMap = .empty;
    var edits: std.json.Array = .init(a);
    try edits.append(try editValue(a, wholeDocumentRange(source), replaced));
    try changes.put(a, uri, .{ .array = edits });
    var edit: std.json.ObjectMap = .empty;
    try edit.put(a, "changes", .{ .object = changes });
    var action: std.json.ObjectMap = .empty;
    try action.put(a, "title", .{ .string = "Replace tab indentation with spaces" });
    try action.put(a, "kind", .{ .string = "quickfix" });
    try action.put(a, "edit", .{ .object = edit });
    var actions: std.json.Array = .init(a);
    try actions.append(.{ .object = action });
    try sendJson(ma, w, .{ .jsonrpc = "2.0", .id = id, .result = std.json.Value{ .array = actions } });
}

fn publishDiagnostics(server: *Server, ma: std.mem.Allocator, w: *std.Io.Writer, uri: []const u8) !void {
    const text = server.documents.get(uri) orelse return;

    var diag_arena = std.heap.ArenaAllocator.init(server.gpa);
    defer diag_arena.deinit();
    const da = diag_arena.allocator();
    const file_dir = uriToDir(da, uri) catch null;
    const diagnostics = try computeDiagnostics(da, server.stdlib_dir, server.nox_home, server.io, text, file_dir);

    try sendPublishDiagnostics(ma, w, uri, diagnostics);
}

/// `uri`nin (YALNIZCA `file://` şeması destekli — başka bir şemaysa, ör.
/// `untitled:`, `null` döner: kaydedilmemiş/proje-siz bir belge İÇİN proje
/// kökü aranacak bir dosya sistemi konumu YOKTUR) İÇERDİĞİ MUTLAK dosya
/// yolunun DİZİNİNİ (dosyanın KENDİSİ DEĞİL — `project.findProjectRoot`
/// bir dizinden başlar) döner. `%XX` yüzde-kaçışları (ör. boşluk İÇİN
/// `%20`) TEK katman çözülür — LSP istemcilerinin (VSCode DAHİL) ÜRETTİĞİ
/// URI'ler bunun ÖTESİNDE bir kodlama İÇERMEZ.
fn uriToDir(a: std.mem.Allocator, uri: []const u8) !?[]const u8 {
    const prefix = "file://";
    if (!std.mem.startsWith(u8, uri, prefix)) return null;
    const encoded_path = uri[prefix.len..];
    if (encoded_path.len == 0) return null;

    var decoded: std.ArrayListUnmanaged(u8) = .empty;
    var i: usize = 0;
    while (i < encoded_path.len) {
        if (encoded_path[i] == '%' and i + 2 < encoded_path.len) {
            const byte = std.fmt.parseInt(u8, encoded_path[i + 1 .. i + 3], 16) catch {
                try decoded.append(a, encoded_path[i]);
                i += 1;
                continue;
            };
            try decoded.append(a, byte);
            i += 3;
        } else {
            try decoded.append(a, encoded_path[i]);
            i += 1;
        }
    }
    const path = decoded.items;
    if (builtin.os.tag == .windows) {
        var start: usize = 0;
        if (std.mem.startsWith(u8, path, "//?/") or std.mem.startsWith(u8, path, "\\\\?\\")) start = 4;
        // `file:///D:/foo` → kod çözülünce `/D:/foo`. Sürücü harfinden
        // önceki eğik çizgi NT yolunu geçersiz kılar.
        if (path.len >= start + 3 and path[start] == '/' and std.ascii.isAlphabetic(path[start + 1]) and path[start + 2] == ':') {
            start += 1;
        }
        var j = start;
        while (j < path.len) : (j += 1) {
            if (decoded.items[j] == '/') decoded.items[j] = '\\';
        }
        return std.fs.path.dirname(decoded.items[start..]);
    }
    return std.fs.path.dirname(path);
}

/// P1.3 (bkz. modül üstü not): `main.zig`nin `resolveImportsForBuild`ıyla
/// AYNI iskelet — `nox.json` bul → `requires[]`in HER alias'ını `nox.lock`
/// üzerinden ZATEN getirilmiş önbellek dizinine eşle → `module_loader.
/// resolveProjectImports`ı çağır. **Bilinçli fark:** SALT-OKUNUR — `fetch.
/// fetchToCache` (ağ/`git`) HİÇ ÇAĞRILMAZ, `nox.lock` HİÇ YAZILMAZ. HİÇBİR
/// ZAMAN hata DÖNDÜRMEZ — her başarısızlık noktasında (proje kökü yok,
/// manifest bozuk, alias önbellekte yok, `resolveProjectImports` başarısız)
/// bir ÖNCEKİ (v1) davranışa (`resolveImportsFrom`/ham `user_module`) düşer.
fn resolveModuleForLsp(
    a: std.mem.Allocator,
    io: std.Io,
    user_module: ast.Module,
    stdlib_dir: ?[]const u8,
    nox_home: []const u8,
    file_dir: ?[]const u8,
) ast.Module {
    const stdlib_only = struct {
        fn resolve(aa: std.mem.Allocator, ioo: std.Io, um: ast.Module, sd: ?[]const u8) ast.Module {
            return if (sd) |dir| (module_loader.resolveImportsFrom(aa, ioo, um, dir) catch um) else um;
        }
    }.resolve;

    const dir = file_dir orelse return stdlib_only(a, io, user_module, stdlib_dir);
    const root = (project.findProjectRoot(a, io, dir) catch null) orelse return stdlib_only(a, io, user_module, stdlib_dir);
    const sd = stdlib_dir orelse return user_module;

    const manifest = project.loadManifest(a, io, root) catch return stdlib_only(a, io, user_module, stdlib_dir);
    const lock = project.loadLockfile(a, io, root) catch project.Lockfile{};

    var roots: std.StringHashMapUnmanaged([]const u8) = .empty;
    for (manifest.requires) |req| {
        const locked = project.findLocked(lock, req.alias) orelse continue;
        const cache_dir = fetch.cachedDirFor(a, nox_home, locked.repo, locked.resolved) catch continue;
        if (std.Io.Dir.accessAbsolute(io, cache_dir, .{})) |_| {
            roots.put(a, req.alias, cache_dir) catch continue;
        } else |_| {}
    }

    return module_loader.resolveProjectImports(a, io, user_module, roots, sd, root) catch user_module;
}

/// `source`u lex→parse→(proje/bağımlılık-farkında import çözümlemesi, bkz.
/// `resolveModuleForLsp`)→tip denetiminden geçirir, TÜM tanılamaları `a`
/// ÜZERİNDE tahsis edilmiş bir dilim olarak döner. Zincirin İLK aşaması
/// (lex/parse) BAŞARISIZ olursa TEK bir (konumsuz) tanılamayla ERKEN döner
/// — sonraki aşamalar hiç ÇALIŞMAZ (bkz. modül üstü not, konum sınırlaması).
fn computeDiagnostics(a: std.mem.Allocator, stdlib_dir: ?[]const u8, nox_home: []const u8, io: std.Io, source: []const u8, file_dir: ?[]const u8) ![]const LspDiagnostic {
    var diags: std.ArrayListUnmanaged(LspDiagnostic) = .empty;

    // Gerçek span sistemi (bkz. plan dosyası "Gerçek span sistemi +
    // yapılandırılmış tanılamalar"): `tokenize`/`parseModule`in SIRADAN
    // (İMZASI DEĞİŞMEMİŞ) sürümleri YERİNE, GERÇEK konum bilgisi
    // TAŞIYAN `tokenizeCapturingSpan`/`Parser.last_diagnostic` kullanılır
    // — ARTIK ne lex/parse hataları 0. satıra SABİTLENİR NE DE tip
    // hataları "TÜM SATIRI" işaretler (bkz. AŞAĞIDAKİ `diagnosticFromSpan`).
    const lex_result = lexer.tokenizeCapturingSpan(a, source);
    if (lex_result.err) |e| {
        var d = diagnosticFromSpan(lex_result.err_span, 0, lexErrorMessage(e));
        if (e == error.TabsNotAllowed) d.code = "tabs";
        try diags.append(a, d);
        return diags.toOwnedSlice(a);
    }
    const tokens = lex_result.tokens.?;

    var p = parser.Parser.init(a, tokens);
    const user_module = p.parseModule() catch |e| {
        const span: Span = if (p.last_diagnostic) |d| d.span else .{};
        try diags.append(a, diagnosticFromSpan(span, 0, parseErrorMessage(e)));
        return diags.toOwnedSlice(a);
    };

    const module = resolveModuleForLsp(a, io, user_module, stdlib_dir, nox_home, file_dir);

    var checker_state = checker.Checker.init(a);
    checker_state.checkModule(module) catch {
        try diags.append(a, diagnosticFromSpan(checker_state.current_span, 0, checker_state.diagnostic orelse "unknown type error"));
        return diags.toOwnedSlice(a);
    };
    for (checker_state.diagnostics.items) |d| {
        const line0: u32 = if (d.line > 0) d.line - 1 else 0; // LSP satırları 0-tabanlı, checker'ınki 1-tabanlı
        try diags.append(a, diagnosticFromSpan(d.span, line0, d.message));
    }
    return diags.toOwnedSlice(a);
}

fn wholeLineDiagnostic(line0: u32, message: []const u8) LspDiagnostic {
    return .{
        .range = .{
            .start = .{ .line = line0, .character = 0 },
            // Sütun bilgisi YOK — SATIRIN TAMAMINI kapsayacak kadar
            // büyük, keyfi bir sütun (editörler bunu GERÇEK satır sonuna
            // KENDİLERİ kırpar). Yalnızca `span` sentinel'i (`isNone()`)
            // İÇİN GERİ DÜŞÜŞ olarak KULLANILIR — bkz. `diagnosticFromSpan`.
            .end = .{ .line = line0, .character = 10_000 },
        },
        .message = message,
    };
}

/// Gerçek span sistemi: `span` GERÇEK bir konum TAŞIYORSA (`!isNone()`)
/// BUNU TAM (satır/sütun) bir LSP `range`ine çevirir; AKSİ HALDE (span
/// hiç YAKALANAMADIYSA — ör. `error.OutOfMemory`, ya da HENÜZ span
/// KAPSAMINA alınmamış bir tanılama türü) `line0_fallback`e "TÜM SATIR"
/// İLE GERİ DÜŞER — HİÇBİR ÇAĞRI SİTESİ regresyon YAŞAMAZ.
fn diagnosticFromSpan(span: Span, line0_fallback: u32, message: []const u8) LspDiagnostic {
    if (span.isNone()) return wholeLineDiagnostic(line0_fallback, message);
    return .{
        .range = .{
            .start = .{ .line = span.start_line - 1, .character = span.start_col - 1 },
            .end = .{ .line = span.end_line - 1, .character = span.end_col - 1 },
        },
        .message = message,
    };
}

fn lexErrorMessage(e: lexer.LexError) []const u8 {
    return switch (e) {
        error.UnexpectedCharacter => "syntax error: unexpected character",
        error.UnterminatedString => "syntax error: unterminated string literal",
        error.InconsistentIndentation => "syntax error: inconsistent indentation",
        error.TabsNotAllowed => "syntax error: TAB indentation is not supported (use spaces only)",
        error.OutOfMemory => "noxlsp: out of memory",
    };
}

fn parseErrorMessage(e: parser.ParseError) []const u8 {
    return switch (e) {
        error.UnexpectedToken => "syntax error: unexpected token",
        error.InvalidNumberLiteral => "syntax error: invalid number literal",
        error.OutOfMemory => "noxlsp: out of memory",
        error.RecursionLimitExceeded => "syntax error: expression nested too deeply (safety limit exceeded)",
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

/// P1.4: `position.line`/`position.character` gibi (LSP'nin HER zaman
/// tamsayı olarak gönderdiği) alanlar İçin — `std.json.Value`nin `.integer`
/// varyantı `i64`tür, çağıranlar (satır/sütun HER ZAMAN negatif olmayan)
/// `u32`ye GÜVENLE daraltır.
fn getIntField(v: std.json.Value, key: []const u8) ?i64 {
    return switch (getObjField(v, key) orelse return null) {
        .integer => |n| n,
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
    const EmptyObj = struct {};
    const SigHelp = struct {
        triggerCharacters: []const []const u8 = &.{ "(", "," },
    };
    const SemLegend = struct {
        tokenTypes: []const []const u8 = &.{ "function", "class", "parameter", "variable" },
        tokenModifiers: []const []const u8 = &.{},
    };
    const SemTok = struct {
        legend: SemLegend = .{},
        full: bool = true,
    };
    const Capabilities = struct {
        // 1 = TextDocumentSyncKind.Full — HER değişiklikte TAM belge metni
        // gönderilir (bkz. `handleDidChange`in belge notu); artımlı (range
        // tabanlı) senkronizasyon v1 kapsamı DIŞINDA (basitlik).
        textDocumentSync: u32 = 1,
        // P1.4: bkz. `lsp_nav.zig`nin modül üstü notu — üçü de KASITLI dar
        // (yalnızca aynı-dosya sembolleri) statik gezinme sağlar.
        completionProvider: EmptyObj = .{},
        definitionProvider: bool = true,
        hoverProvider: bool = true,
        // Faz ÜH.1: `compiler/main.zig`nin `cmdFmt`ıyla AYNI, MEVCUT
        // `formatter.formatModule` zincirini (lex→parse→format) yeniden
        // kullanır — bkz. `handleFormatting`.
        documentFormattingProvider: bool = true,
        documentSymbolProvider: bool = true,
        referencesProvider: bool = true,
        renameProvider: bool = true,
        codeActionProvider: bool = true,
        inlayHintProvider: bool = true,
        signatureHelpProvider: SigHelp = .{},
        semanticTokensProvider: SemTok = .{},
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

fn sendError(ma: std.mem.Allocator, w: *std.Io.Writer, id: std.json.Value, code: i32, message: []const u8) !void {
    const ErrObj = struct { code: i32, message: []const u8 };
    const Msg = struct {
        jsonrpc: []const u8 = "2.0",
        id: std.json.Value,
        @"error": ErrObj,
    };
    try sendJson(ma, w, Msg{ .id = id, .@"error" = .{ .code = code, .message = message } });
}

fn respondMethodNotFound(ma: std.mem.Allocator, w: *std.Io.Writer, id: std.json.Value) !void {
    const ErrObj = struct {
        code: i32 = -32601,
        message: []const u8 = "method not found (noxlsp supports diagnostics only)",
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
