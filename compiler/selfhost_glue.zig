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
extern fn nox_lex_run(rt: ?*anyopaque, base: i64, n: i64, want_trivia: i64) i64;
extern fn nox_lex_trivia_count(rt: ?*anyopaque) i64;
extern fn nox_lex_trivia_buffer(rt: ?*anyopaque) i64;
extern fn nox_lex_buffer(rt: ?*anyopaque) i64;
extern fn nox_lex_err_line(rt: ?*anyopaque) i64;
extern fn nox_lex_err_col(rt: ?*anyopaque) i64;

pub const LexOut = lexer.HookResult;

/// Bir Nox çalışma zamanı bağlamı: `start` ... `stop`. Bileşen çağrıları arasında paylaşılır; iş parçacıkları arası kullanım yok (derleyici tek iş parçacıklıdır).
pub const Runtime = struct {
    rt: ?*anyopaque,

    pub fn start() Runtime {
        const rt = nox_runtime_init();
        nox_lib_init(rt);
        return .{ .rt = rt };
    }

    pub fn stop(self: Runtime) void {
        nox_lib_fini(self.rt);
        nox_runtime_deinit(self.rt);
    }

    /// Yalnızca Nox tarafının tarama süresi (token dizisine dönüştürme dahil değil): token sayısını ya da negatif hata kodunu döner (`lex-bench`).
    pub fn lexRaw(self: Runtime, source: []const u8) i64 {
        return nox_lex_run(self.rt, @intCast(@intFromPtr(source.ptr)), @intCast(source.len), 0);
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
        const code = nox_lex_run(self.rt, @intCast(@intFromPtr(source.ptr)), @intCast(source.len), @intFromBool(want_trivia));
        if (code < 0) {
            const err: lexer.LexError = switch (-code) {
                1 => error.UnexpectedCharacter,
                2 => error.UnterminatedString,
                3 => error.InconsistentIndentation,
                4 => error.TabsNotAllowed,
                else => unreachable,
            };
            const line: u32 = @intCast(nox_lex_err_line(self.rt));
            const col: u32 = @intCast(nox_lex_err_col(self.rt));
            return .{ .tokens = null, .err = err, .err_span = if (line == 0) .{} else .{ .start_byte = 0, .end_byte = 0, .start_line = line, .start_col = col, .end_line = line, .end_col = col + 1 }, .trivia = &.{} };
        }
        const n: usize = @intCast(code);
        const buf: [*]const i64 = @ptrFromInt(@as(usize, @intCast(nox_lex_buffer(self.rt))));
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
            const tn: usize = @intCast(nox_lex_trivia_count(self.rt));
            const tbuf: [*]const i64 = @ptrFromInt(@as(usize, @intCast(nox_lex_trivia_buffer(self.rt))));
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
    const Thunk = struct {
        fn entry(c: Ctx) void {
            const nrt = Runtime.start();
            defer nrt.stop();
            f(c, nrt);
        }
    };
    const t = try std.Thread.spawn(.{ .stack_size = BIG_STACK_BYTES }, Thunk.entry, .{ctx});
    t.join();
}

test "selfhost_glue: bileşen simgeleri bu birimde çözülmez (yalnızca nightly ikilisinde bağlanır)" {
    // Bu dosya normal test derlemesinde analiz edilmez; yer tutucu.
}
