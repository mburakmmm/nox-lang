//! noxc-nightly (Aşama 0.3): Nox ile yazılmış bileşenlerin (`selfhost/*.nox`) Zig tarafı köprüsü. YALNIZCA nightly ikilisinde derlenir (`build_options.nightly`); normal `noxc` bu dosyayı
//! hiç analiz etmez (simgeler `zig build nightly`nin bağladığı `selfhost.o`dan gelir). Sözleşme: `selfhost/README.md`.

const std = @import("std");
const token_mod = @import("lexer/token.zig");
const lexer = @import("lexer/lexer.zig");
const span_mod = @import("span.zig");

extern fn nox_runtime_init() ?*anyopaque;
extern fn nox_runtime_deinit(rt: ?*anyopaque) void;
extern fn nox_lib_init(rt: ?*anyopaque) void;
extern fn nox_lib_fini(rt: ?*anyopaque) void;
extern fn nox_mem_stat(rt: ?*anyopaque, which: i64) i64;
extern fn lexer_nox_lex_run(rt: ?*anyopaque, base: i64, n: i64, want_trivia: i64) i64;
extern fn lexer_nox_lex_trivia_count(rt: ?*anyopaque) i64;
extern fn lexer_nox_lex_trivia_buffer(rt: ?*anyopaque) i64;
extern fn lexer_nox_lex_buffer(rt: ?*anyopaque) i64;
extern fn lexer_nox_lex_err_line(rt: ?*anyopaque) i64;
extern fn lexer_nox_lex_err_col(rt: ?*anyopaque) i64;
extern fn lexer_nox_lex_err_byte(rt: ?*anyopaque) i64;
extern fn ast_schema_nox_ast_reset(rt: ?*anyopaque, src: i64, src_len: i64) i64;
extern fn ast_schema_nox_ast_push_n(rt: ?*anyopaque, v: i64) i64;
extern fn ast_schema_nox_ast_push_l(rt: ?*anyopaque, v: i64) i64;
extern fn ast_schema_nox_ast_push_sb(rt: ?*anyopaque, v: i64) i64;
extern fn ast_schema_nox_ast_push_sp(rt: ?*anyopaque, id: i64, span: i64) i64;
extern fn ast_schema_nox_ast_dump(rt: ?*anyopaque, body_start: i64, body_len: i64, exp_start: i64, exp_len: i64) i64;
extern fn ast_schema_nox_ast_out_buffer(rt: ?*anyopaque) i64;

extern fn parser_nox_parse_run(rt: ?*anyopaque, base: i64, n: i64) i64;
extern fn parser_nox_parse_dump(rt: ?*anyopaque) i64;
extern fn parser_nox_parse_out_buffer(rt: ?*anyopaque) i64;
extern fn parser_nox_parse_mem(rt: ?*anyopaque) i64;
extern fn parser_nox_parse_dg(rt: ?*anyopaque, i: i64) i64;
extern fn parser_nox_parse_dg_note_len(rt: ?*anyopaque) i64;
extern fn parser_nox_parse_dg_note_byte(rt: ?*anyopaque, i: i64) i64;

extern fn formatter_nox_fmt_run(rt: ?*anyopaque, base: i64, n: i64) i64;
extern fn formatter_nox_fmt_mem(rt: ?*anyopaque) i64;
extern fn formatter_nox_fmt_len(rt: ?*anyopaque) i64;
extern fn formatter_nox_fmt_out_buffer(rt: ?*anyopaque) i64;

pub const LexOut = lexer.HookResult;

/// Bir Nox çalışma zamanı bağlamı: `start` ... `stop`. Bileşen çağrıları arasında paylaşılır; iş parçacıkları arası kullanım yok (derleyici tek iş parçacıklıdır).
pub const Runtime = struct {
    rt: ?*anyopaque,

    /// R1-P1.6: `nox_runtime_init` bellek yetersizliğinde null döner; null ile `nox_lib_init` çağrılırsa tanımsız davranış olurdu → kontrollü hata.
    pub fn start() error{RuntimeInitFailed}!Runtime {
        const rt = nox_runtime_init() orelse return error.RuntimeInitFailed;
        nox_lib_init(rt);
        return .{ .rt = rt };
    }

    pub fn stop(self: Runtime) void {
        nox_lib_fini(self.rt);
        nox_runtime_deinit(self.rt);
    }

    /// Aşama 2.B doğrulaması: Zig `ast.Module`ünün düz-dizi kodlamasını Nox AST şemasına yükler ve Nox `dump_module` yazıcısının ürettiği baytları döner (`noxc ast --full` ile BİREBİR aynı olmalı).
    pub fn astRoundtripDump(self: Runtime, a: std.mem.Allocator, flat: @import("parser/ast_flat.zig").Flat, src: []const u8) ![]u8 {
        _ = ast_schema_nox_ast_reset(self.rt, @intCast(@intFromPtr(src.ptr)), @intCast(src.len));
        for (flat.n.items) |v| _ = ast_schema_nox_ast_push_n(self.rt, v);
        for (flat.l.items) |v| _ = ast_schema_nox_ast_push_l(self.rt, v);
        for (flat.sb.items) |b| _ = ast_schema_nox_ast_push_sb(self.rt, b);
        var i: usize = 0;
        while (i + 1 < flat.sp.items.len) : (i += 2) _ = ast_schema_nox_ast_push_sp(self.rt, flat.sp.items[i], flat.sp.items[i + 1]);
        const len: usize = @intCast(ast_schema_nox_ast_dump(self.rt, flat.body_start, flat.body_len, flat.exp_start, flat.exp_len));
        const buf: [*]const i64 = @ptrFromInt(@as(usize, @intCast(ast_schema_nox_ast_out_buffer(self.rt))));
        const out = try a.alloc(u8, len);
        for (out, 0..) |*b, k| b.* = @intCast(buf[k]);
        return out;
    }

    /// Aşama 2.C: Nox parser'ı (`selfhost/parser.nox`) kaynağı ayrıştırır; başarıda `noxc ast --full` biçiminde döküm baytları, hatada `error.ParseFailed` ve `code` (1..4 sözcük, 10 UnexpectedToken, 11 InvalidNumberLiteral, 12 RecursionLimitExceeded).
    pub fn parseDump(self: Runtime, a: std.mem.Allocator, src: []const u8, code: *i64) ![]u8 {
        code.* = parser_nox_parse_run(self.rt, @intCast(@intFromPtr(src.ptr)), @intCast(src.len));
        if (code.* != 0) return error.ParseFailed;
        const len: usize = @intCast(parser_nox_parse_dump(self.rt));
        const buf: [*]const i64 = @ptrFromInt(@as(usize, @intCast(parser_nox_parse_out_buffer(self.rt))));
        const out = try a.alloc(u8, len);
        for (out, 0..) |*b, k| b.* = @intCast(buf[k]);
        return out;
    }

    /// Aşama 2.13: Nox biçimlendirici (`selfhost/formatter.nox`; Nox lexer + Nox parser). Başarıda biçimlenmiş kaynak, hatada `error.FormatFailed` ve `code` (1..4 sözcük hatası, 10..12 ayrıştırma hatası).
    pub fn formatSource(self: Runtime, a: std.mem.Allocator, src: []const u8, code: *i64) ![]u8 {
        code.* = formatter_nox_fmt_run(self.rt, @intCast(@intFromPtr(src.ptr)), @intCast(src.len));
        if (code.* != 0) return error.FormatFailed;
        const len: usize = @intCast(formatter_nox_fmt_len(self.rt));
        const buf: [*]const i64 = @ptrFromInt(@as(usize, @intCast(formatter_nox_fmt_out_buffer(self.rt))));
        const out = try a.alloc(u8, len);
        for (out, 0..) |*b, k| b.* = @intCast(buf[k]);
        return out;
    }

    /// Son `formatSource`ın canlı Nox verisi (bayt).
    /// R1-P1.13 (v2.2.51): Nox çalışma zamanı ARC tahsis sayaçları (ilk çağrı sayımı BAŞLATIR): 0 = tahsis sayısı, 1 = serbest bırakma sayısı, 2 = toplam tahsis edilen bayt.
    pub fn memStat(self: Runtime, which: i64) i64 {
        return nox_mem_stat(self.rt, which);
    }

    pub fn fmtMem(self: Runtime) i64 {
        return formatter_nox_fmt_mem(self.rt);
    }

    /// Yalnızca ayrıştırma (döküm yok): Nox parser'ını çalıştırır; 0 ya da hata kodu.
    pub fn parseRaw(self: Runtime, src: []const u8) i64 {
        return parser_nox_parse_run(self.rt, @intCast(@intFromPtr(src.ptr)), @intCast(src.len));
    }

    /// Son ayrıştırmanın canlı Nox verisi (bayt).
    pub fn parseMem(self: Runtime) i64 {
        return parser_nox_parse_mem(self.rt);
    }

    /// Son `parseDump` hatasının tanılaması (`i`: 0 var mı, 1 beklenen tür (-1 yok), 2 bulunan tür, 3..8 span, 9..13 geçerli simge).
    pub fn parseDiag(self: Runtime, i: i64) i64 {
        return parser_nox_parse_dg(self.rt, i);
    }

    /// Son `parseDump` hatasını `syntax_report` ile (Zig parser'ıyla aynı işlevler) `sink`e yazar; tanılama alanları Nox parser'ından gelir.
    pub fn reportParseError(self: Runtime, a: std.mem.Allocator, sink: @import("report_sink.zig").Sink, source: []const u8, label: []const u8, code: i64) !void {
        const syntax_report = @import("syntax_report.zig");
        const parser_mod = @import("parser/parser.zig");
        if (code >= 1 and code <= 4) {
            const err: lexer.LexError = switch (code) {
                1 => error.UnexpectedCharacter,
                2 => error.UnterminatedString,
                3 => error.InconsistentIndentation,
                else => error.TabsNotAllowed,
            };
            syntax_report.reportLexFailure(sink, source, label, err, @intCast(self.parseDiag(5)), @intCast(self.parseDiag(6)));
            return;
        }
        const e: parser_mod.ParseError = switch (code) {
            10 => error.UnexpectedToken,
            11 => error.InvalidNumberLiteral,
            else => error.RecursionLimitExceeded,
        };
        var diag: ?parser_mod.ParserDiagnostic = null;
        if (self.parseDiag(0) != 0) {
            const note = try self.parseDiagNote(a);
            diag = .{
                .expected = if (self.parseDiag(1) < 0) null else @enumFromInt(self.parseDiag(1)),
                .found = @enumFromInt(self.parseDiag(2)),
                .span = .{ .start_byte = @intCast(self.parseDiag(3)), .end_byte = @intCast(self.parseDiag(4)), .start_line = @intCast(self.parseDiag(5)), .start_col = @intCast(self.parseDiag(6)), .end_line = @intCast(self.parseDiag(7)), .end_col = @intCast(self.parseDiag(8)) },
                .note = if (note.len == 0) null else note,
            };
        }
        const lo: usize = @intCast(self.parseDiag(12));
        const hi: usize = @intCast(self.parseDiag(13));
        const cur: token_mod.Token = .{
            .kind = @enumFromInt(self.parseDiag(9)),
            .lexeme = if (hi <= source.len and lo <= hi) source[lo..hi] else "",
            .line = @intCast(self.parseDiag(10)),
            .col = @intCast(self.parseDiag(11)),
            .start_byte = lo,
            .end_byte = hi,
            .end_line = @intCast(self.parseDiag(10)),
            .end_col = @intCast(self.parseDiag(11) + @as(i64, @intCast(hi - lo))),
        };
        syntax_report.reportParseFailure(sink, source, label, e, diag, cur);
    }

    pub fn parseDiagNote(self: Runtime, a: std.mem.Allocator) ![]u8 {
        const n: usize = @intCast(parser_nox_parse_dg_note_len(self.rt));
        const out = try a.alloc(u8, n);
        for (out, 0..) |*b, k| b.* = @intCast(parser_nox_parse_dg_note_byte(self.rt, @intCast(k)));
        return out;
    }

    /// Yalnızca Nox tarafının tarama süresi (token dizisine dönüştürme dahil değil): token sayısını ya da negatif hata kodunu döner (`lex-bench`).
    pub fn lexRaw(self: Runtime, source: []const u8) i64 {
        return lexer_nox_lex_run(self.rt, @intCast(@intFromPtr(source.ptr)), @intCast(source.len), 0);
    }

    /// Aşama 1: Nox lexer'ı (`selfhost/lexer.nox`). `compiler/lexer/lexer.zig` ile aynı sonucu (token dizisi ya da `LexError` + hata konumu) üretir; belirteçler `a` ile ayrılan bir dilime kopyalanır
    /// (lexeme'ler `source`a işaret eder, kopyalanmaz). Hata konumu Zig `posSpan` gibi yalnızca başlangıç satır/sütundur (`end_*` doldurulmaz).
    pub fn lex(self: Runtime, a: std.mem.Allocator, source: []const u8) LexOut {
        return self.lexImpl(a, source, false);
    }

    /// `lex` + formatter için trivia (yorum/boş satır) kanalı; yorum metinleri `a` ile kopyalanır (Zig `tokenizeWithTrivia` ile aynı).
    pub fn lexWithTrivia(self: Runtime, a: std.mem.Allocator, source: []const u8) LexOut {
        return self.lexImpl(a, source, true);
    }

    fn lexImpl(self: Runtime, a: std.mem.Allocator, source: []const u8, want_trivia: bool) LexOut {
        const code = lexer_nox_lex_run(self.rt, @intCast(@intFromPtr(source.ptr)), @intCast(source.len), @intFromBool(want_trivia));
        if (code < 0) {
            const err: lexer.LexError = switch (-code) {
                1 => error.UnexpectedCharacter,
                2 => error.UnterminatedString,
                3 => error.InconsistentIndentation,
                4 => error.TabsNotAllowed,
                else => unreachable,
            };
            const line: u32 = @intCast(lexer_nox_lex_err_line(self.rt));
            const col: u32 = @intCast(lexer_nox_lex_err_col(self.rt));
            const byte: usize = @intCast(lexer_nox_lex_err_byte(self.rt));
            return .{ .tokens = null, .err = err, .err_span = if (line == 0) .{} else .{ .start_byte = byte, .end_byte = byte + 1, .start_line = line, .start_col = col, .end_line = line, .end_col = col + 1 }, .trivia = &.{} };
        }
        const n: usize = @intCast(code);
        const buf: [*]const i64 = @ptrFromInt(@as(usize, @intCast(lexer_nox_lex_buffer(self.rt))));
        const toks = a.alloc(token_mod.Token, n) catch return .{ .tokens = null, .err = error.OutOfMemory, .err_span = .{}, .trivia = &.{} };
        for (toks, 0..) |*t, i| {
            const kind_int: i64 = buf[i * 5];
            const lo: usize = @intCast(buf[i * 5 + 3]);
            const hi: usize = @intCast(buf[i * 5 + 4]);
            const line: u32 = @intCast(buf[i * 5 + 1]);
            const col: u32 = @intCast(buf[i * 5 + 2]);
            t.* = .{
                .kind = @enumFromInt(kind_int),
                .lexeme = source[lo..hi],
                .line = line,
                .col = col,
                .start_byte = lo,
                .end_byte = hi,
                .end_line = line,
                .end_col = col + @as(u32, @intCast(hi - lo)),
            };
        }
        var trivia: []token_mod.Trivia = &.{};
        if (want_trivia) {
            const tn: usize = @intCast(lexer_nox_lex_trivia_count(self.rt));
            const tbuf: [*]const i64 = @ptrFromInt(@as(usize, @intCast(lexer_nox_lex_trivia_buffer(self.rt))));
            trivia = a.alloc(token_mod.Trivia, tn) catch return .{ .tokens = null, .err = error.OutOfMemory, .err_span = .{}, .trivia = &.{} };
            for (trivia, 0..) |*tv, i| {
                const is_comment = tbuf[i * 5] == 0;
                tv.* = if (is_comment)
                    .{ .kind = .comment, .line = @intCast(tbuf[i * 5 + 1]), .text = a.dupe(u8, source[@intCast(tbuf[i * 5 + 3])..@intCast(tbuf[i * 5 + 4])]) catch "", .trailing = tbuf[i * 5 + 2] != 0 }
                else
                    .{ .kind = .blank_line, .line = @intCast(tbuf[i * 5 + 1]) };
            }
        }
        return .{ .tokens = toks, .err = null, .err_span = .{}, .trivia = trivia };
    }
};

fn hookRun(ctx: *anyopaque, a: std.mem.Allocator, source: []const u8, want_trivia: bool) lexer.HookResult {
    const nrt: *Runtime = @ptrCast(@alignCast(ctx));
    return if (want_trivia) nrt.lexWithTrivia(a, source) else nrt.lex(a, source);
}

/// Nox lexer'ını derleme hattının TÜM lexer çağrılarının (parser, f-string iç ifadeleri, fmt, modül yükleyici) arkasına takar (`lexer.hook`). `nrt` işlem ömrü boyunca yaşamalıdır.
pub fn installLexerHook(nrt: *Runtime) void {
    lexer.hook = .{ .ctx = nrt, .run = hookRun };
}

/// Nox bileşenleri (parser/checker özyinelemesi) için ayrılan yığın: 256 MiB (yalnızca sanal bellek; dokunulan kadarı fiziksel). Deney (`selfhost/spike/02-deep-recursion`, LLVM -O2): 8 MiB'lık ana yığın
/// iki çocuklu özyinelemede ~300 bin derinliğe yetiyor, 1 milyon çöküyor; 256 MiB 1 milyonu rahat taşıyor (zincir serbest bırakma dahil).
pub const BIG_STACK_BYTES: usize = 256 * 1024 * 1024;

/// `f(ctx, runtime)`ü büyük yığınlı yeni bir iş parçacığında çalıştırır (`Runtime` o iş parçacığında kurulur/yıkılır; çalışma zamanı tek iş parçacığına aittir). `join` ile bekler.
pub fn runOnBigStack(ctx: anytype, comptime f: fn (@TypeOf(ctx), Runtime) void) !void {
    const Ctx = @TypeOf(ctx);
    const Shared = struct { ctx: Ctx, failed: bool = false };
    var shared: Shared = .{ .ctx = ctx };
    const Thunk = struct {
        fn entry(sh: *Shared) void {
            const nrt = Runtime.start() catch {
                sh.failed = true;
                return;
            };
            defer nrt.stop();
            f(sh.ctx, nrt);
        }
    };
    const t = try std.Thread.spawn(.{ .stack_size = BIG_STACK_BYTES }, Thunk.entry, .{&shared});
    t.join();
    if (shared.failed) return error.RuntimeInitFailed;
}

test "selfhost_glue: bileşen simgeleri bu birimde çözülmez (yalnızca nightly ikilisinde bağlanır)" {
    // Bu dosya normal test derlemesinde analiz edilmez; yer tutucu.
}
