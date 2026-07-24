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
//! `ast.Stmt.span`e dayanan KASITLI DAR bir statik katmandır — YALNIZCA AYNI
//! dosya İÇİ semboller (üst-düzey `func_def`/`class_def` + kapsayan
//! fonksiyon/metodun parametre/yerelleri + sabit yerleşik/anahtar-kelime
//! listesi) çözülür; `import`la GELEN semboller (stdlib/proje-içi/üçüncü-
//! taraf) İçin goto-definition/hover ÇÖZÜLMEZ (`nav.resolveAt` `null` döner).
//! `rename`/çapraz-dosya gezinme HÂLÂ v1 kapsamı DIŞINDA (W.2'nin "minimal"
//! sıfatının GERİ KALANI).
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
const lexer = @import("lexer/lexer.zig");
const parser = @import("parser/parser.zig");
const ast = @import("parser/ast.zig");
const checker = @import("typecheck/checker.zig");
const module_loader = @import("module_loader.zig");
const project = @import("project.zig");
const fetch = @import("pkg/fetch.zig");
const nav = @import("lsp_nav.zig");
const span_mod = @import("span.zig");
const Span = span_mod.Span;

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
    /// P1.3: üçüncü-taraf paket ÖNBELLEĞİNİN KÖKÜ — `main.zig`nin `nox_home`ı
    /// İLE AYNI kural (`NOX_HOME` env override, YOKSA `$HOME/.nox`), YALNIZCA
    /// `resolveModuleForLsp`nin ZATEN getirilmiş `requires[]` alias'larını
    /// bulabilmesi İÇİN okunur (bkz. onun belge notu — ASLA buraya YAZILMAZ).
    nox_home: []const u8,
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
    } else if (std.mem.eql(u8, method, "textDocument/completion")) {
        try handleCompletion(server, ma, params_opt, id_opt, w);
    } else if (std.mem.eql(u8, method, "textDocument/definition")) {
        try handleDefinition(server, ma, params_opt, id_opt, w);
    } else if (std.mem.eql(u8, method, "textDocument/hover")) {
        try handleHover(server, ma, params_opt, id_opt, w);
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

// ---- P1.4: gezinme (bkz. `lsp_nav.zig`nin modül üstü notu) ----

const NavQuery = struct { uri: []const u8, line1: u32, col1: u32 };

/// `textDocument/{completion,definition,hover}`in ORTAK `{textDocument:
/// {uri}, position: {line, character}}` gövdesini ayrıştırır — LSP
/// pozisyonları 0-tabanlıdır, `line1`/`col1` (bkz. `ast.Stmt.span`/`Token`)
/// 1-tabanlıdır (`diagnosticFromSpan`in AYNI dönüşümüyle TUTARLI).
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

    const Loc = struct { uri: []const u8, range: Range };
    var loc: ?Loc = null;
    if (parseNavQuery(params_opt)) |q| {
        if (try resolveNavSymbol(server, a, q)) |r| {
            if (!r.span.isNone()) loc = .{
                .uri = q.uri,
                .range = .{
                    .start = .{ .line = r.span.start_line - 1, .character = r.span.start_col - 1 },
                    .end = .{ .line = r.span.end_line - 1, .character = r.span.end_col - 1 },
                },
            };
        }
    }

    const Msg = struct {
        jsonrpc: []const u8 = "2.0",
        id: std.json.Value,
        result: ?Loc,
    };
    try sendJson(ma, w, Msg{ .id = id, .result = loc });
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
        try diags.append(a, diagnosticFromSpan(lex_result.err_span, 0, lexErrorMessage(e)));
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
        try diags.append(a, diagnosticFromSpan(checker_state.current_span, 0, checker_state.diagnostic orelse "bilinmeyen tip hatasi"));
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
