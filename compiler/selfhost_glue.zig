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
extern fn parser_nox_parse_validate(rt: ?*anyopaque) i64;
extern fn parser_nox_parse_dg(rt: ?*anyopaque, i: i64) i64;
extern fn parser_nox_parse_dg_note_len(rt: ?*anyopaque) i64;
extern fn parser_nox_parse_dg_note_byte(rt: ?*anyopaque, i: i64) i64;

extern fn formatter_nox_fmt_run(rt: ?*anyopaque, base: i64, n: i64) i64;
extern fn formatter_nox_fmt_mem(rt: ?*anyopaque) i64;
extern fn formatter_nox_fmt_len(rt: ?*anyopaque) i64;
extern fn formatter_nox_fmt_out_buffer(rt: ?*anyopaque) i64;

// Aşama 3.1 (selfhost/types.nox): tip tablosu (TypeId/hash-consing/SymbolId) test köprüsü.
extern fn types_nox_ty_reset(rt: ?*anyopaque) i64;
extern fn types_nox_ty_names(rt: ?*anyopaque, base: i64) i64;
extern fn types_nox_ty_sym(rt: ?*anyopaque, off: i64, n: i64) i64;
extern fn types_nox_ty_scalar(rt: ?*anyopaque, tag: i64) i64;
extern fn types_nox_ty_fixed(rt: ?*anyopaque, kind: i64) i64;
extern fn types_nox_ty_unary(rt: ?*anyopaque, tag: i64, e: i64) i64;
extern fn types_nox_ty_class(rt: ?*anyopaque, sym: i64) i64;
extern fn types_nox_ty_dict(rt: ?*anyopaque, k: i64, v: i64) i64;
extern fn types_nox_ty_func_begin(rt: ?*anyopaque) i64;
extern fn types_nox_ty_func_param(rt: ?*anyopaque, p: i64) i64;
extern fn types_nox_ty_func_end(rt: ?*anyopaque, ret: i64) i64;
extern fn types_nox_ty_class_base(rt: ?*anyopaque, sym: i64, base: i64) i64;
extern fn types_nox_ty_class_mixin(rt: ?*anyopaque, sym: i64, m: i64) i64;
extern fn types_nox_ty_class_reg(rt: ?*anyopaque, sym: i64) i64;
extern fn types_nox_ty_format(rt: ?*anyopaque, id: i64) i64;
extern fn types_nox_ty_mangle(rt: ?*anyopaque, id: i64) i64;
extern fn types_nox_ty_out_buffer(rt: ?*anyopaque) i64;
extern fn types_nox_ty_numeric(rt: ?*anyopaque, id: i64) i64;
extern fn types_nox_ty_bitwise(rt: ?*anyopaque, id: i64) i64;
extern fn types_nox_ty_assignable(rt: ?*anyopaque, d: i64, v: i64) i64;
extern fn types_nox_ty_fx(rt: ?*anyopaque, which: i64, kind: i64, v: i64) i64;
extern fn types_nox_ty_count(rt: ?*anyopaque) i64;
extern fn types_nox_ty_validate(rt: ?*anyopaque) i64;
extern fn types_nox_ty_mem(rt: ?*anyopaque) i64;
extern fn types_nox_ty_bench(rt: ?*anyopaque, seed: i64, k: i64, m: i64) i64;

extern fn typecheck_nox_ck_reset(rt: ?*anyopaque) i64;
extern fn typecheck_nox_ck_scope_new(rt: ?*anyopaque, parent: i64, has_caps: i64) i64;
extern fn typecheck_nox_ck_declare(rt: ?*anyopaque, scope: i64, sym: i64, ty: i64) i64;
extern fn typecheck_nox_ck_lookup_local(rt: ?*anyopaque, scope: i64, sym: i64) i64;
extern fn typecheck_nox_ck_lookup(rt: ?*anyopaque, scope: i64, sym: i64) i64;
extern fn typecheck_nox_ck_exists(rt: ?*anyopaque, scope: i64, sym: i64) i64;
extern fn typecheck_nox_ck_declare_var(rt: ?*anyopaque, scope: i64, sym: i64, ty: i64) i64;
extern fn typecheck_nox_ck_set_nonarc(rt: ?*anyopaque, sym: i64, flag: i64) i64;
extern fn typecheck_nox_ck_caps_n(rt: ?*anyopaque, scope: i64) i64;
extern fn typecheck_nox_ck_cap(rt: ?*anyopaque, scope: i64, i: i64, which: i64) i64;
extern fn typecheck_nox_ck_tab_put(rt: ?*anyopaque, which: i64, sym: i64, v: i64) i64;
extern fn typecheck_nox_ck_tab_has(rt: ?*anyopaque, which: i64, sym: i64) i64;
extern fn typecheck_nox_ck_tab_get(rt: ?*anyopaque, which: i64, sym: i64) i64;
extern fn typecheck_nox_ck_tab_remove(rt: ?*anyopaque, which: i64, sym: i64) i64;
extern fn typecheck_nox_ck_tab_live(rt: ?*anyopaque, which: i64) i64;
extern fn typecheck_nox_ck_assigns_name(rt: ?*anyopaque, base: i64, off: i64, n: i64) i64;
extern fn typecheck_nox_ck_mem(rt: ?*anyopaque) i64;
extern fn typecheck_nox_ck_check(rt: ?*anyopaque) i64;
extern fn typecheck_nox_ck_check_loaded(rt: ?*anyopaque, body_start: i64, body_len: i64) i64;
extern fn typecheck_nox_ck_text(rt: ?*anyopaque, which: i64, i: i64) i64;
extern fn typecheck_nox_ck_out_buffer(rt: ?*anyopaque) i64;
extern fn typecheck_nox_ck_diag_n(rt: ?*anyopaque) i64;
extern fn typecheck_nox_ck_diag_int(rt: ?*anyopaque, i: i64, field: i64) i64;
extern fn typecheck_nox_ck_bench(rt: ?*anyopaque, seed: i64, ns: i64, nn: i64, m: i64) i64;

/// Aşama 3.2+: Nox tip denetleyicisinin (`selfhost/typecheck.nox`) Zig tarafı sarmalayıcısı. Ad = SymbolId (`TypeApi.sym`), tip = TypeId; yokluk = -1.
pub const CheckApi = struct {
    rt: ?*anyopaque,

    pub fn reset(self: CheckApi) void {
        _ = typecheck_nox_ck_reset(self.rt);
    }
    pub fn scopeNew(self: CheckApi, parent: i64, has_caps: bool) i64 {
        return typecheck_nox_ck_scope_new(self.rt, parent, @intFromBool(has_caps));
    }
    pub fn declare(self: CheckApi, scope: i64, sym: i64, ty: i64) void {
        _ = typecheck_nox_ck_declare(self.rt, scope, sym, ty);
    }
    pub fn lookupLocal(self: CheckApi, scope: i64, sym: i64) i64 {
        return typecheck_nox_ck_lookup_local(self.rt, scope, sym);
    }
    pub fn lookup(self: CheckApi, scope: i64, sym: i64) i64 {
        return typecheck_nox_ck_lookup(self.rt, scope, sym);
    }
    pub fn exists(self: CheckApi, scope: i64, sym: i64) bool {
        return typecheck_nox_ck_exists(self.rt, scope, sym) != 0;
    }
    /// 0 = bildirildi, 1 = uyuşmazlık.
    pub fn declareVar(self: CheckApi, scope: i64, sym: i64, ty: i64) i64 {
        return typecheck_nox_ck_declare_var(self.rt, scope, sym, ty);
    }
    pub fn setNonArc(self: CheckApi, sym: i64, flag: bool) void {
        _ = typecheck_nox_ck_set_nonarc(self.rt, sym, @intFromBool(flag));
    }
    pub fn capsN(self: CheckApi, scope: i64) i64 {
        return typecheck_nox_ck_caps_n(self.rt, scope);
    }
    /// which: 0 sembol, 1 tip.
    pub fn cap(self: CheckApi, scope: i64, i: i64, which: i64) i64 {
        return typecheck_nox_ck_cap(self.rt, scope, i, which);
    }
    /// which: 0 module_globals (tip), 1 module_int_consts (değer).
    pub fn tabPut(self: CheckApi, which: i64, sym: i64, v: i64) void {
        _ = typecheck_nox_ck_tab_put(self.rt, which, sym, v);
    }
    pub fn tabHas(self: CheckApi, which: i64, sym: i64) bool {
        return typecheck_nox_ck_tab_has(self.rt, which, sym) != 0;
    }
    pub fn tabGet(self: CheckApi, which: i64, sym: i64) i64 {
        return typecheck_nox_ck_tab_get(self.rt, which, sym);
    }
    pub fn tabRemove(self: CheckApi, which: i64, sym: i64) bool {
        return typecheck_nox_ck_tab_remove(self.rt, which, sym) != 0;
    }
    pub fn tabLive(self: CheckApi, which: i64) i64 {
        return typecheck_nox_ck_tab_live(self.rt, which);
    }
    /// Son Nox ayrıştırmasının modül gövdesinde `name` atanıyor mu (`stmtsAssignName`).
    pub fn assignsName(self: CheckApi, name: []const u8) bool {
        return typecheck_nox_ck_assigns_name(self.rt, @intCast(@intFromPtr(name.ptr)), 0, @intCast(name.len)) != 0;
    }
    pub fn mem(self: CheckApi) i64 {
        return typecheck_nox_ck_mem(self.rt);
    }
    /// 3.3: son Nox ayrıştırmasının modülünü denetler. 0 = kabul, 1 = tanılama/hata, 2 = kapsam dışı (henüz taşınmamış yapı).
    pub fn checkRun(self: CheckApi) i64 {
        return typecheck_nox_ck_check(self.rt);
    }
    /// Zig'den `Runtime.loadAst` ile yüklenmiş birleşik modülü denetler (aynı durum kodları).
    pub fn checkLoaded(self: CheckApi, body_start: i64, body_len: i64) i64 {
        return typecheck_nox_ck_check_loaded(self.rt, body_start, body_len);
    }
    /// which: 0 sonuç hata kodu adı, 1 sonuç iletisi, 2 i. tanılamanın kodu, 3 i. tanılamanın iletisi.
    pub fn text(self: CheckApi, a: std.mem.Allocator, which: i64, i: i64) ![]u8 {
        const n: usize = @intCast(typecheck_nox_ck_text(self.rt, which, i));
        const buf: [*]const i64 = @ptrFromInt(@as(usize, @intCast(typecheck_nox_ck_out_buffer(self.rt))));
        const out = try a.alloc(u8, n);
        for (out, 0..) |*b, k| b.* = @intCast(buf[k]);
        return out;
    }
    pub fn diagN(self: CheckApi) i64 {
        return typecheck_nox_ck_diag_n(self.rt);
    }
    /// field 0 satır, 1..6 span (start_byte, end_byte, start_line, start_col, end_line, end_col).
    pub fn diagInt(self: CheckApi, i: i64, field: i64) i64 {
        return typecheck_nox_ck_diag_int(self.rt, i, field);
    }
    /// `ck-bench` Nox tarafı iş yükü (sağlama toplamı Zig `benchZig` ile aynı olmalı).
    pub fn bench(self: CheckApi, seed: i64, ns: i64, nn: i64, m: i64) i64 {
        return typecheck_nox_ck_bench(self.rt, seed, ns, nn, m);
    }
};

/// Aşama 3.1: Nox tip tablosunun (`selfhost/types.nox`) Zig tarafı sarmalayıcısı. TypeId'ler düz `i64`dür.
pub const TypeApi = struct {
    rt: ?*anyopaque,

    pub fn reset(self: TypeApi) i64 {
        return types_nox_ty_reset(self.rt);
    }
    pub fn names(self: TypeApi, base: []const u8) void {
        _ = types_nox_ty_names(self.rt, @intCast(@intFromPtr(base.ptr)));
    }
    pub fn sym(self: TypeApi, off: usize, n: usize) i64 {
        return types_nox_ty_sym(self.rt, @intCast(off), @intCast(n));
    }
    pub fn scalar(self: TypeApi, tag: i64) i64 {
        return types_nox_ty_scalar(self.rt, tag);
    }
    pub fn fixed(self: TypeApi, kind: i64) i64 {
        return types_nox_ty_fixed(self.rt, kind);
    }
    pub fn unary(self: TypeApi, tag: i64, e: i64) i64 {
        return types_nox_ty_unary(self.rt, tag, e);
    }
    pub fn class(self: TypeApi, s: i64) i64 {
        return types_nox_ty_class(self.rt, s);
    }
    pub fn dict(self: TypeApi, k: i64, v: i64) i64 {
        return types_nox_ty_dict(self.rt, k, v);
    }
    pub fn funcBegin(self: TypeApi) void {
        _ = types_nox_ty_func_begin(self.rt);
    }
    pub fn funcParam(self: TypeApi, p: i64) void {
        _ = types_nox_ty_func_param(self.rt, p);
    }
    pub fn funcEnd(self: TypeApi, ret: i64) i64 {
        return types_nox_ty_func_end(self.rt, ret);
    }
    pub fn classBase(self: TypeApi, s: i64, base: i64) void {
        _ = types_nox_ty_class_base(self.rt, s, base);
    }
    pub fn classMixin(self: TypeApi, s: i64, m: i64) void {
        _ = types_nox_ty_class_mixin(self.rt, s, m);
    }
    pub fn classReg(self: TypeApi, s: i64) void {
        _ = types_nox_ty_class_reg(self.rt, s);
    }
    /// `format`/`mangle` çıktısını (Nox `list[int]`, her bayt bir i64) `a` ile ayrılan bir bayt dilimine kopyalar.
    pub fn copyOut(self: TypeApi, a: std.mem.Allocator, len: i64) ![]u8 {
        const n: usize = @intCast(len);
        const buf: [*]const i64 = @ptrFromInt(@as(usize, @intCast(types_nox_ty_out_buffer(self.rt))));
        const out = try a.alloc(u8, n);
        for (out, 0..) |*b, k| b.* = @intCast(buf[k]);
        return out;
    }
    pub fn formatAlloc(self: TypeApi, a: std.mem.Allocator, id: i64) ![]u8 {
        return self.copyOut(a, types_nox_ty_format(self.rt, id));
    }
    pub fn mangleAlloc(self: TypeApi, a: std.mem.Allocator, id: i64) ![]u8 {
        return self.copyOut(a, types_nox_ty_mangle(self.rt, id));
    }
    pub fn numeric(self: TypeApi, id: i64) bool {
        return types_nox_ty_numeric(self.rt, id) != 0;
    }
    pub fn bitwise(self: TypeApi, id: i64) bool {
        return types_nox_ty_bitwise(self.rt, id) != 0;
    }
    pub fn assignable(self: TypeApi, d: i64, v: i64) bool {
        return types_nox_ty_assignable(self.rt, d, v) != 0;
    }
    /// which: 0 bitWidth, 1 isSigned, 2 fitsValue(v)
    pub fn fx(self: TypeApi, which: i64, kind: i64, v: i64) i64 {
        return types_nox_ty_fx(self.rt, which, kind, v);
    }
    pub fn count(self: TypeApi) i64 {
        return types_nox_ty_count(self.rt);
    }
    /// 0 = invariantlar sağlam (bkz. `ty_validate`).
    pub fn validate(self: TypeApi) i64 {
        return types_nox_ty_validate(self.rt);
    }
    pub fn mem(self: TypeApi) i64 {
        return types_nox_ty_mem(self.rt);
    }
    /// `types-bench` Nox tarafı iş yükü (sağlama toplamı Zig `benchZig` ile aynı olmalı).
    pub fn bench(self: TypeApi, seed: i64, k: i64, m: i64) i64 {
        return types_nox_ty_bench(self.rt, seed, k, m);
    }
};

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

    /// Aşama 3.1 tip tablosu köprüsü (`selfhost/types.nox`).
    pub fn types(self: Runtime) TypeApi {
        return .{ .rt = self.rt };
    }

    /// Aşama 3.2+ tip denetleyici köprüsü (`selfhost/typecheck.nox`).
    pub fn check(self: Runtime) CheckApi {
        return .{ .rt = self.rt };
    }

    /// Zig `ast.Module`ünün düz-dizi kodlamasını Nox AST şemasına (`ast_schema.G`) yükler (denetleyici farksalı için; `astRoundtripDump`ın yükleme yarısı).
    pub fn loadAst(self: Runtime, flat: @import("parser/ast_flat.zig").Flat, src: []const u8) void {
        _ = ast_schema_nox_ast_reset(self.rt, @intCast(@intFromPtr(src.ptr)), @intCast(src.len));
        for (flat.n.items) |v| _ = ast_schema_nox_ast_push_n(self.rt, v);
        for (flat.l.items) |v| _ = ast_schema_nox_ast_push_l(self.rt, v);
        for (flat.sb.items) |b| _ = ast_schema_nox_ast_push_sb(self.rt, b);
        var i: usize = 0;
        while (i + 1 < flat.sp.items.len) : (i += 2) _ = ast_schema_nox_ast_push_sp(self.rt, flat.sp.items[i], flat.sp.items[i + 1]);
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
        const buf: [*]const u8 = @ptrFromInt(@as(usize, @intCast(formatter_nox_fmt_out_buffer(self.rt))));
        const out = try a.alloc(u8, len);
        @memcpy(out, buf[0..len]);
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
    /// R2-E.1: son ayrıştırmanın düz dizi AST invariant denetimi (0 = tamam; bkz. `nox_parse_validate`).
    pub fn parseValidate(self: Runtime) i64 {
        return parser_nox_parse_validate(self.rt);
    }

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
