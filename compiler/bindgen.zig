//! `noxc bindgen` — C başlığından Nox binding'i üretir (v2.1.104, TODO 3.4/5.1 F4; tasarım: `project/ffi-binding-tasarimi-2026-11.md`).
//!
//! Boru hattı: `cc -E` ile ön işlenmiş metin (+ `cc -E -dM` ile makro tanımları) -> `lex` -> tolerant bir C BİLDİRİM ayrıştırıcısı (`Parser`) -> `Emitter`
//! (Nox `extern def`/sabit çıktısı + gerektiğinde C kabuğu). Dış bağımlılık yok. Ayrıştırıcı tolerandır: sistem başlıklarındaki anlamadığı bildirimi sessizce
//! atlar (yalnızca hedef başlıktaki bir bildirim ayrıştırılamazsa uyarı üretir); işlev GÖVDELERİ ve ilklendiriciler dengeli parantezle atlanır.
//!
//! Kapsam (MVP): işlev bildirimleri/tanımları (satır içi `static inline` dahil), `typedef`, `enum` (sabitler), `struct/union` (opak + gövdeli), `static const` tamsayı
//! değişkenleri, nesne-benzeri `#define` tamsayı/dize sabitleri. Tür eşleme: tamsayı aileleri -> `i8…i64`/`u8…u64`/`usize`/`isize`, `double` -> `float`, `_Bool` -> `bool`,
//! `const char *` parametresi -> `str`, diğer işaretçiler/işlev işaretçileri/dizi parametreleri -> `ptr`, `enum` -> `i32`. Değerle `struct`/`union`, `long double`, `_Complex`,
//! değişken argümanlı (`...`) işlevler ATLANIR (uyarı). `float` (f32) ve `static inline` işlevler üretilen C kabuğundan geçer (`nox_shim_<ad>`); Nox tarafında C adıyla bir
//! sarmalayıcı `def` bulunur (dış sembolü olan işlevlerde `<ad>_`: Nox'un üst-düzey `def`i de ham sembol üretir ve bağlama çakışırdı).

const std = @import("std");

pub const Options = struct {
    /// Hedef başlık yolu (linemarker eşleştirmesi için taban adı kullanılır).
    header: []const u8,
    /// `extern def ... from "<lib>"` için kütüphane (yol ya da sistem adı).
    lib: []const u8,
    /// Kabuk işlevlerinin `from` değeri (üretilen kabuğun nesne dosyası).
    shim_lib: []const u8,
    /// Kabuğun `#include` edeceği başlık (varsayılan: `header`).
    include_name: []const u8,
    /// Yalnızca bu önekle başlayan işlevler/sabitler çıkarılır (boş = hedef başlıktakilerin hepsi; makrolar için BÜYÜK/küçük harf duyarsız önek ZORUNLU).
    prefix: []const u8 = "",
};

pub const Output = struct {
    nox: []const u8,
    shim: []const u8,
    warnings: []const []const u8,
    n_funcs: usize,
    n_shims: usize,
    n_consts: usize,
};

// ------------------------------------------------------------------------------------------------ sözcük çözümleyici

const TokKind = enum { ident, number, string, char_lit, punct, eof };

const Tok = struct {
    kind: TokKind,
    text: []const u8,
    in_target: bool,
    line: u32,
};

fn baseName(path: []const u8) []const u8 {
    var i = path.len;
    while (i > 0) : (i -= 1) {
        if (path[i - 1] == '/' or path[i - 1] == '\\') return path[i..];
    }
    return path;
}

fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_' or c == '$';
}
fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '$';
}

/// `# 12 "dosya" bayraklar` satırından dosya adını çıkarır.
fn linemarkerFile(line: []const u8) ?[]const u8 {
    const q1 = std.mem.indexOfScalar(u8, line, '"') orelse return null;
    const rest = line[q1 + 1 ..];
    const q2 = std.mem.indexOfScalar(u8, rest, '"') orelse return null;
    return rest[0..q2];
}

fn lex(a: std.mem.Allocator, text: []const u8, target_base: []const u8, all_in_target: bool) ![]Tok {
    var toks: std.ArrayListUnmanaged(Tok) = .empty;
    var i: usize = 0;
    var line_no: u32 = 1;
    var in_target = all_in_target;
    var at_line_start = true;
    while (i < text.len) {
        const c = text[i];
        if (c == '\n') {
            line_no += 1;
            at_line_start = true;
            i += 1;
            continue;
        }
        if (c == ' ' or c == '\t' or c == '\r' or c == 0x0c) {
            i += 1;
            continue;
        }
        if (c == '#' and at_line_start) {
            var e = i;
            while (e < text.len and text[e] != '\n') e += 1;
            if (!all_in_target) {
                if (linemarkerFile(text[i..e])) |f| in_target = std.mem.eql(u8, baseName(f), target_base);
            }
            i = e;
            continue;
        }
        at_line_start = false;
        if (c == '/' and i + 1 < text.len and text[i + 1] == '/') {
            while (i < text.len and text[i] != '\n') i += 1;
            continue;
        }
        if (c == '/' and i + 1 < text.len and text[i + 1] == '*') {
            i += 2;
            while (i + 1 < text.len and !(text[i] == '*' and text[i + 1] == '/')) : (i += 1) {
                if (text[i] == '\n') line_no += 1;
            }
            i += 2;
            continue;
        }
        if (isIdentStart(c)) {
            var e = i + 1;
            while (e < text.len and isIdentChar(text[e])) e += 1;
            // dize/karakter önekleri: L"..", u8"..", u".."
            if (e < text.len and (text[e] == '"' or text[e] == '\'') and (std.mem.eql(u8, text[i..e], "L") or std.mem.eql(u8, text[i..e], "u8") or std.mem.eql(u8, text[i..e], "u") or std.mem.eql(u8, text[i..e], "U"))) {
                i = e;
                continue;
            }
            try toks.append(a, .{ .kind = .ident, .text = text[i..e], .in_target = in_target, .line = line_no });
            i = e;
            continue;
        }
        if (std.ascii.isDigit(c) or (c == '.' and i + 1 < text.len and std.ascii.isDigit(text[i + 1]))) {
            var e = i + 1;
            while (e < text.len) : (e += 1) {
                const d = text[e];
                if (isIdentChar(d) or d == '.') continue;
                if ((d == '+' or d == '-') and (text[e - 1] == 'e' or text[e - 1] == 'E' or text[e - 1] == 'p' or text[e - 1] == 'P')) continue;
                break;
            }
            try toks.append(a, .{ .kind = .number, .text = text[i..e], .in_target = in_target, .line = line_no });
            i = e;
            continue;
        }
        if (c == '"' or c == '\'') {
            var e = i + 1;
            while (e < text.len and text[e] != c) : (e += 1) {
                if (text[e] == '\\') e += 1;
            }
            e = @min(e + 1, text.len);
            try toks.append(a, .{ .kind = if (c == '"') .string else .char_lit, .text = text[i..e], .in_target = in_target, .line = line_no });
            i = e;
            continue;
        }
        const puncts = [_][]const u8{ "...", "<<=", ">>=", "->", "++", "--", "<<", ">>", "<=", ">=", "==", "!=", "&&", "||", "+=", "-=", "*=", "/=", "%=", "&=", "|=", "^=", "##" };
        var matched: ?[]const u8 = null;
        for (puncts) |p| {
            if (std.mem.startsWith(u8, text[i..], p)) {
                matched = p;
                break;
            }
        }
        const len: usize = if (matched) |m| m.len else 1;
        try toks.append(a, .{ .kind = .punct, .text = text[i .. i + len], .in_target = in_target, .line = line_no });
        i += len;
    }
    try toks.append(a, .{ .kind = .eof, .text = "", .in_target = in_target, .line = line_no });
    return toks.items;
}

// ------------------------------------------------------------------------------------------------ C tür modeli

const IntKind = struct { bits: u8, signed: bool, is_size: bool = false, is_char: bool = false };

const CType = union(enum) {
    void,
    bool_,
    int: IntKind,
    f32,
    f64,
    ptr: Ptr,
    array: Array,
    func: *const FuncSig,
    record: []const u8, // kayıt anahtarı (etiket ya da sentetik)
    enum_: []const u8,
    named: []const u8, // typedef adı (tembelce çözülür)
    unsupported: []const u8,

    const Ptr = struct { to: *const CType, const_pointee: bool };
    const Array = struct { elem: *const CType, len: ?u64 };
};

const Param = struct { name: []const u8, ty: CType };

const FuncSig = struct {
    ret: CType,
    params: []const Param,
    variadic: bool,
};

const FuncDecl = struct {
    name: []const u8,
    sig: *const FuncSig,
    is_inline: bool, // static / inline: dış sembol yok -> kabuk
    line: u32,
};

const Field = struct { name: []const u8, ty: CType, bitfield: bool = false, is_const: bool = false };

/// Gövdesi görülmüş (ya da yalnızca etiketi anılmış) struct/union.
const Record = struct {
    tag: []const u8,
    is_union: bool,
    fields: []const Field = &.{},
    /// Gövde (`{...}`) görüldü mü (tam tip)?
    complete: bool = false,
    /// Alanlar hatasız ayrıştırıldı mı (gövde atlanmışsa false)?
    fields_ok: bool = false,
    in_target: bool = false,
};

const GlobalDecl = struct { name: []const u8, ty: CType, is_const: bool, line: u32 };

const ConstDecl = struct { name: []const u8, ty_text: []const u8, value: i128, is_str: bool = false, str_text: []const u8 = "" };

const Specs = struct {
    is_typedef: bool = false,
    is_static: bool = false,
    is_inline: bool = false,
    is_extern: bool = false,
    is_const: bool = false,
    base: ?CType = null,
};

const Parser = struct {
    a: std.mem.Allocator,
    toks: []const Tok,
    pos: usize = 0,
    typedefs: std.StringHashMapUnmanaged(CType) = .empty,
    enum_consts: std.StringHashMapUnmanaged(i128) = .empty,
    funcs: std.ArrayListUnmanaged(FuncDecl) = .empty,
    consts: std.ArrayListUnmanaged(ConstDecl) = .empty,
    records: std.StringHashMapUnmanaged(Record) = .empty,
    /// etiket -> o kayda işaret eden ilk typedef adı
    record_alias: std.StringHashMapUnmanaged([]const u8) = .empty,
    globals: std.ArrayListUnmanaged(GlobalDecl) = .empty,
    /// Hedef ABI (cc -dM makrolarından): `long` genişliği, düz `char` işaretliliği.
    long_bits: u8 = 64,
    char_signed: bool = true,
    warnings: std.ArrayListUnmanaged([]const u8) = .empty,
    anon_counter: u32 = 0,

    fn cur(self: *Parser) Tok {
        return self.toks[self.pos];
    }
    fn peekAt(self: *Parser, n: usize) Tok {
        const idx = @min(self.pos + n, self.toks.len - 1);
        return self.toks[idx];
    }
    fn atEof(self: *Parser) bool {
        return self.cur().kind == .eof;
    }
    fn isP(self: *Parser, p: []const u8) bool {
        const t = self.cur();
        return t.kind == .punct and std.mem.eql(u8, t.text, p);
    }
    fn isId(self: *Parser, s: []const u8) bool {
        const t = self.cur();
        return t.kind == .ident and std.mem.eql(u8, t.text, s);
    }
    fn acceptP(self: *Parser, p: []const u8) bool {
        if (self.isP(p)) {
            self.pos += 1;
            return true;
        }
        return false;
    }
    fn warn(self: *Parser, comptime fmt: []const u8, args: anytype) !void {
        try self.warnings.append(self.a, try std.fmt.allocPrint(self.a, fmt, args));
    }

    /// Eşleşen kapanış parantezine kadar atlar (`pos` açılış belirtecinde başlar, kapanışın ARDINDA biter).
    fn skipBalanced(self: *Parser) void {
        const open = self.cur().text;
        const close: []const u8 = if (std.mem.eql(u8, open, "(")) ")" else if (std.mem.eql(u8, open, "[")) "]" else "}";
        var depth: usize = 0;
        while (!self.atEof()) {
            const t = self.cur();
            if (t.kind == .punct) {
                if (std.mem.eql(u8, t.text, open)) depth += 1;
                if (std.mem.eql(u8, t.text, close)) {
                    depth -= 1;
                    self.pos += 1;
                    if (depth == 0) return;
                    continue;
                }
            }
            self.pos += 1;
        }
    }

    fn skipAttrs(self: *Parser) void {
        while (self.cur().kind == .ident) {
            const t = self.cur().text;
            const is_attr = std.mem.eql(u8, t, "__attribute__") or std.mem.eql(u8, t, "__attribute") or std.mem.eql(u8, t, "__asm__") or std.mem.eql(u8, t, "__asm") or
                std.mem.eql(u8, t, "asm") or std.mem.eql(u8, t, "__declspec") or std.mem.eql(u8, t, "_Alignas") or std.mem.eql(u8, t, "__alignas");
            const is_marker = std.mem.eql(u8, t, "__extension__") or std.mem.eql(u8, t, "_Noreturn") or std.mem.eql(u8, t, "__noreturn__") or std.mem.eql(u8, t, "_Nonnull") or
                std.mem.eql(u8, t, "_Nullable") or std.mem.eql(u8, t, "_Null_unspecified") or std.mem.eql(u8, t, "__unaligned") or std.mem.eql(u8, t, "__cdecl") or
                std.mem.eql(u8, t, "__stdcall") or std.mem.eql(u8, t, "__fastcall") or std.mem.eql(u8, t, "_Thread_local") or std.mem.eql(u8, t, "__thread");
            if (is_attr) {
                self.pos += 1;
                if (self.isP("(")) self.skipBalanced();
            } else if (is_marker) {
                self.pos += 1;
            } else break;
        }
    }

    fn isQualifier(t: []const u8) bool {
        const qs = [_][]const u8{ "const", "volatile", "restrict", "__restrict", "__restrict__", "_Atomic", "__const", "__volatile__", "__const__" };
        for (qs) |q| if (std.mem.eql(u8, t, q)) return true;
        return false;
    }

    fn box(self: *Parser, t: CType) !*const CType {
        const p = try self.a.create(CType);
        p.* = t;
        return p;
    }

    // ---- bildirim belirticileri

    fn parseSpecs(self: *Parser) anyerror!Specs {
        var sp: Specs = .{};
        var n_long: u8 = 0;
        var n_short = false;
        var is_signed = false;
        var is_unsigned = false;
        var kw_int = false;
        var kw_char = false;
        var kw_float = false;
        var kw_double = false;
        var kw_bool = false;
        var kw_void = false;
        var kw_other_unsupported: ?[]const u8 = null;
        var have_type = false;
        while (!self.atEof()) {
            self.skipAttrs();
            const t = self.cur();
            if (t.kind != .ident) break;
            const s = t.text;
            if (std.mem.eql(u8, s, "typedef")) {
                sp.is_typedef = true;
            } else if (std.mem.eql(u8, s, "static")) {
                sp.is_static = true;
            } else if (std.mem.eql(u8, s, "extern")) {
                sp.is_extern = true;
            } else if (std.mem.eql(u8, s, "inline") or std.mem.eql(u8, s, "__inline") or std.mem.eql(u8, s, "__inline__")) {
                sp.is_inline = true;
            } else if (std.mem.eql(u8, s, "register") or std.mem.eql(u8, s, "auto")) {
                // yok say
            } else if (isQualifier(s)) {
                if (std.mem.eql(u8, s, "const") or std.mem.eql(u8, s, "__const") or std.mem.eql(u8, s, "__const__")) sp.is_const = true;
            } else if (std.mem.eql(u8, s, "void")) {
                kw_void = true;
                have_type = true;
            } else if (std.mem.eql(u8, s, "char")) {
                kw_char = true;
                have_type = true;
            } else if (std.mem.eql(u8, s, "short")) {
                n_short = true;
                have_type = true;
            } else if (std.mem.eql(u8, s, "int")) {
                kw_int = true;
                have_type = true;
            } else if (std.mem.eql(u8, s, "long")) {
                n_long += 1;
                have_type = true;
            } else if (std.mem.eql(u8, s, "float")) {
                kw_float = true;
                have_type = true;
            } else if (std.mem.eql(u8, s, "double")) {
                kw_double = true;
                have_type = true;
            } else if (std.mem.eql(u8, s, "signed") or std.mem.eql(u8, s, "__signed__") or std.mem.eql(u8, s, "__signed")) {
                is_signed = true;
                have_type = true;
            } else if (std.mem.eql(u8, s, "unsigned")) {
                is_unsigned = true;
                have_type = true;
            } else if (std.mem.eql(u8, s, "_Bool")) {
                kw_bool = true;
                have_type = true;
            } else if (std.mem.eql(u8, s, "_Complex") or std.mem.eql(u8, s, "__complex__")) {
                kw_other_unsupported = "_Complex";
                have_type = true;
            } else if (std.mem.eql(u8, s, "__int128") or std.mem.eql(u8, s, "__int128_t") or std.mem.eql(u8, s, "__uint128_t")) {
                kw_other_unsupported = "__int128";
                have_type = true;
            } else if (std.mem.eql(u8, s, "__builtin_va_list")) {
                sp.base = .{ .ptr = .{ .to = try self.box(.void), .const_pointee = false } };
                have_type = true;
            } else if (std.mem.eql(u8, s, "struct") or std.mem.eql(u8, s, "union")) {
                self.pos += 1;
                sp.base = try self.parseRecord(std.mem.eql(u8, s, "union"));
                have_type = true;
                continue;
            } else if (std.mem.eql(u8, s, "enum")) {
                self.pos += 1;
                sp.base = try self.parseEnum();
                have_type = true;
                continue;
            } else if (std.mem.eql(u8, s, "typeof") or std.mem.eql(u8, s, "__typeof__") or std.mem.eql(u8, s, "__typeof") or std.mem.eql(u8, s, "_Atomic")) {
                self.pos += 1;
                if (self.isP("(")) self.skipBalanced();
                sp.base = .{ .unsupported = "typeof" };
                have_type = true;
                continue;
            } else if (!have_type and self.typedefs.contains(s)) {
                sp.base = .{ .named = s };
                have_type = true;
            } else if (!have_type and (std.mem.endsWith(u8, s, "_t") or std.mem.startsWith(u8, s, "__")) and !self.isDeclaratorFollowing()) {
                // bilinmeyen typedef adı (kaçırılmış sistem tipi): isimli olarak tut, çözümlenemezse desteklenmez sayılır
                sp.base = .{ .named = s };
                have_type = true;
            } else break;
            self.pos += 1;
        }
        if (sp.base == null) {
            if (kw_other_unsupported) |u| {
                sp.base = .{ .unsupported = u };
            } else if (kw_void) {
                sp.base = .void;
            } else if (kw_bool) {
                sp.base = .bool_;
            } else if (kw_float) {
                sp.base = .f32;
            } else if (kw_double) {
                sp.base = if (n_long > 0) .{ .unsupported = "long double" } else .f64;
            } else if (kw_char) {
                sp.base = .{ .int = .{ .bits = 8, .signed = if (is_signed) true else if (is_unsigned) false else self.char_signed, .is_char = !is_signed and !is_unsigned } };
            } else if (n_short) {
                sp.base = .{ .int = .{ .bits = 16, .signed = !is_unsigned } };
            } else if (n_long > 0) {
                sp.base = .{ .int = .{ .bits = if (n_long >= 2) 64 else self.long_bits, .signed = !is_unsigned } };
            } else if (kw_int or is_signed or is_unsigned) {
                sp.base = .{ .int = .{ .bits = 32, .signed = !is_unsigned } };
            }
        }
        return sp;
    }

    /// Bir tanımlayıcıdan hemen sonra bildirici işareti (`;`, `,`, `(`, `[`, `=`, `)`) geliyorsa o tanımlayıcı tip adı DEĞİL, bildirici adıdır.
    fn isDeclaratorFollowing(self: *Parser) bool {
        const n = self.peekAt(1);
        if (n.kind != .punct) return false;
        return std.mem.eql(u8, n.text, ";") or std.mem.eql(u8, n.text, ",") or std.mem.eql(u8, n.text, "[") or std.mem.eql(u8, n.text, "=") or std.mem.eql(u8, n.text, ")") or
            std.mem.eql(u8, n.text, ":");
    }

    fn parseRecord(self: *Parser, is_union: bool) anyerror!CType {
        self.skipAttrs();
        var tag: []const u8 = "";
        const in_target = self.cur().in_target;
        if (self.cur().kind == .ident) {
            tag = self.cur().text;
            self.pos += 1;
        } else {
            self.anon_counter += 1;
            tag = try std.fmt.allocPrint(self.a, "__anon_record_{d}", .{self.anon_counter});
        }
        self.skipAttrs();
        if (self.isP("{")) {
            const body_start = self.pos;
            var rec: Record = .{ .tag = tag, .is_union = is_union, .complete = true, .in_target = in_target };
            if (self.parseRecordBody()) |fields| {
                rec.fields = fields;
                rec.fields_ok = true;
            } else |_| {
                self.pos = body_start;
                self.skipBalanced();
            }
            try self.records.put(self.a, tag, rec);
        } else if (!self.records.contains(tag)) {
            try self.records.put(self.a, tag, .{ .tag = tag, .is_union = is_union });
        }
        self.skipAttrs();
        return .{ .record = tag };
    }

    /// `{` üzerinde başlar; alanları okuyup `}`in ardında biter.
    fn parseRecordBody(self: *Parser) anyerror![]const Field {
        var list: std.ArrayListUnmanaged(Field) = .empty;
        self.pos += 1; // `{`
        while (!self.atEof() and !self.isP("}")) {
            if (self.acceptP(";")) continue;
            const sp = try self.parseSpecs();
            const base = sp.base orelse return error.BadField;
            if (self.acceptP(";")) {
                // adsız iç struct/union (C11): alanları üst kayıtta doğrudan erişilir
                if (base == .record) try list.append(self.a, .{ .name = "", .ty = base });
                continue;
            }
            while (true) {
                const d = try self.parseDeclarator(base, sp.is_const, true);
                var bit = false;
                if (self.acceptP(":")) {
                    bit = true;
                    while (!self.atEof() and !self.isP(",") and !self.isP(";")) {
                        if (self.isP("(")) self.skipBalanced() else self.pos += 1;
                    }
                }
                self.skipAttrs();
                if (d.name.len > 0) try list.append(self.a, .{ .name = d.name, .ty = d.ty, .bitfield = bit, .is_const = sp.is_const });
                if (self.acceptP(",")) continue;
                if (!self.acceptP(";")) return error.BadField;
                break;
            }
        }
        if (!self.acceptP("}")) return error.BadField;
        return list.items;
    }

    fn parseEnum(self: *Parser) !CType {
        self.skipAttrs();
        var tag: []const u8 = "";
        if (self.cur().kind == .ident) {
            tag = self.cur().text;
            self.pos += 1;
        } else {
            self.anon_counter += 1;
            tag = try std.fmt.allocPrint(self.a, "__anon_enum_{d}", .{self.anon_counter});
        }
        self.skipAttrs();
        if (self.isP("{")) {
            self.pos += 1;
            var next_val: ?i128 = 0;
            while (!self.atEof() and !self.isP("}")) {
                self.skipAttrs();
                if (self.cur().kind != .ident) {
                    self.pos += 1;
                    continue;
                }
                const name = self.cur().text;
                const in_target = self.cur().in_target;
                self.pos += 1;
                self.skipAttrs();
                var val: ?i128 = next_val;
                if (self.acceptP("=")) {
                    const start = self.pos;
                    while (!self.atEof() and !self.isP(",") and !self.isP("}")) {
                        if (self.isP("(") or self.isP("[") or self.isP("{")) self.skipBalanced() else self.pos += 1;
                    }
                    val = self.evalRange(start, self.pos);
                }
                if (val) |v| {
                    try self.enum_consts.put(self.a, name, v);
                    if (in_target) try self.consts.append(self.a, .{ .name = name, .ty_text = "i32", .value = v });
                    next_val = v + 1;
                } else next_val = null;
                _ = self.acceptP(",");
            }
            _ = self.acceptP("}");
        }
        return .{ .enum_ = tag };
    }

    // ---- bildiriciler

    const Declared = struct { name: []const u8, ty: CType };

    fn parseParams(self: *Parser) !struct { params: []const Param, variadic: bool } {
        // `(` zaten tüketildi
        var list: std.ArrayListUnmanaged(Param) = .empty;
        var variadic = false;
        if (self.acceptP(")")) return .{ .params = list.items, .variadic = false };
        while (!self.atEof()) {
            if (self.isP("...")) {
                self.pos += 1;
                variadic = true;
                break;
            }
            const sp = try self.parseSpecs();
            const base = sp.base orelse CType{ .int = .{ .bits = 32, .signed = true } };
            const d = try self.parseDeclarator(base, sp.is_const, true);
            var ty = d.ty;
            // dizi/işlev parametreleri işaretçiye çürür
            switch (ty) {
                .array => |arr| ty = .{ .ptr = .{ .to = arr.elem, .const_pointee = false } },
                .func => ty = .{ .ptr = .{ .to = try self.box(.void), .const_pointee = false } },
                else => {},
            }
            try list.append(self.a, .{ .name = d.name, .ty = ty });
            if (!self.acceptP(",")) break;
        }
        _ = self.acceptP(")");
        // `(void)` = parametresiz
        if (list.items.len == 1 and list.items[0].ty == .void and list.items[0].name.len == 0) list.items.len = 0;
        return .{ .params = list.items, .variadic = variadic };
    }

    fn parseDeclarator(self: *Parser, base: CType, base_const: bool, abstract_ok: bool) anyerror!Declared {
        var t = base;
        var last_const = base_const;
        while (self.isP("*")) {
            self.pos += 1;
            const boxed = try self.box(t); // sonuç-konum örtüşmesini önlemek için önce kutula
            t = .{ .ptr = .{ .to = boxed, .const_pointee = last_const } };
            last_const = false;
            while (self.cur().kind == .ident) {
                self.skipAttrs();
                if (self.cur().kind == .ident and isQualifier(self.cur().text)) {
                    if (std.mem.eql(u8, self.cur().text, "const")) last_const = false; // işaretçinin kendi const'u: pointee const'unu etkilemez
                    self.pos += 1;
                } else break;
            }
        }
        self.skipAttrs();
        var name: []const u8 = "";
        var inner_start: usize = 0;
        var has_inner = false;
        if (self.isP("(")) {
            const n = self.peekAt(1);
            const grouping = (n.kind == .punct and (std.mem.eql(u8, n.text, "*") or std.mem.eql(u8, n.text, "(") or std.mem.eql(u8, n.text, "^"))) or
                (n.kind == .ident and (std.mem.eql(u8, n.text, "__attribute__") or std.mem.eql(u8, n.text, "__cdecl") or std.mem.eql(u8, n.text, "__stdcall")));
            if (grouping) {
                inner_start = self.pos + 1;
                self.skipBalanced();
                has_inner = true;
            }
        }
        if (!has_inner and self.cur().kind == .ident and !(abstract_ok and isQualifier(self.cur().text))) {
            name = self.cur().text;
            self.pos += 1;
        }
        self.skipAttrs();
        // sonekler: önce hepsini topla, sonra sağdan sola uygula
        const Suffix = union(enum) { arr: ?u64, func: struct { params: []const Param, variadic: bool } };
        var suffixes: std.ArrayListUnmanaged(Suffix) = .empty;
        while (true) {
            if (self.isP("[")) {
                const open_pos = self.pos;
                self.skipBalanced();
                var alen: ?u64 = null;
                if (self.pos - open_pos >= 3) {
                    if (self.evalRange(open_pos + 1, self.pos - 1)) |v| {
                        if (v >= 0 and v <= std.math.maxInt(u32)) alen = @intCast(v);
                    }
                }
                try suffixes.append(self.a, .{ .arr = alen });
            } else if (self.isP("(")) {
                self.pos += 1;
                const pr = try self.parseParams();
                try suffixes.append(self.a, .{ .func = .{ .params = pr.params, .variadic = pr.variadic } });
            } else break;
            self.skipAttrs();
        }
        var i = suffixes.items.len;
        while (i > 0) {
            i -= 1;
            switch (suffixes.items[i]) {
                .arr => |alen| {
                    const boxed = try self.box(t);
                    t = .{ .array = .{ .elem = boxed, .len = alen } };
                },
                .func => |f| {
                    const sig = try self.a.create(FuncSig);
                    sig.* = .{ .ret = t, .params = f.params, .variadic = f.variadic };
                    t = CType{ .func = sig };
                },
            }
        }
        if (has_inner) {
            const saved = self.pos;
            self.pos = inner_start;
            const inner = try self.parseDeclarator(t, false, abstract_ok);
            self.pos = saved;
            return inner;
        }
        return .{ .name = name, .ty = t };
    }

    // ---- sabit ifade değerlendirmesi

    fn evalRange(self: *Parser, start: usize, end: usize) ?i128 {
        var p = ExprParser{ .toks = self.toks[start..end], .parser = self };
        const v = p.parseTernary() orelse return null;
        if (p.pos != p.toks.len) return null;
        return v;
    }

    // ---- üst düzey

    fn recover(self: *Parser) void {
        // sonraki `;` ya da dengeli `{...}` sonuna kadar
        while (!self.atEof()) {
            if (self.isP(";")) {
                self.pos += 1;
                return;
            }
            if (self.isP("{") or self.isP("(") or self.isP("[")) {
                const was_brace = self.isP("{");
                self.skipBalanced();
                if (was_brace) return;
                continue;
            }
            self.pos += 1;
        }
    }

    fn parseTop(self: *Parser) !void {
        while (!self.atEof()) {
            if (self.acceptP(";")) continue;
            if (self.isId("_Static_assert") or self.isId("static_assert")) {
                self.pos += 1;
                if (self.isP("(")) self.skipBalanced();
                _ = self.acceptP(";");
                continue;
            }
            const start = self.pos;
            const in_target = self.cur().in_target;
            const line = self.cur().line;
            self.parseDecl(in_target, line) catch {
                self.pos = start;
                if (in_target) try self.warn("line {d}: could not parse a declaration, skipped", .{line});
                self.recover();
                if (self.pos == start) self.pos += 1;
            };
        }
    }

    fn parseDecl(self: *Parser, in_target: bool, line: u32) !void {
        const sp = try self.parseSpecs();
        if (sp.base == null) return error.NoType;
        const base = sp.base.?;
        if (self.acceptP(";")) return; // yalnızca struct/enum bildirimi
        while (true) {
            const d = try self.parseDeclarator(base, sp.is_const, false);
            self.skipAttrs();
            if (sp.is_typedef) {
                if (d.name.len > 0) {
                    try self.typedefs.put(self.a, d.name, d.ty);
                    if (d.ty == .record and !self.record_alias.contains(d.ty.record)) try self.record_alias.put(self.a, d.ty.record, d.name);
                }
            } else if (d.ty == .func) {
                if (d.name.len > 0 and in_target) {
                    try self.funcs.append(self.a, .{ .name = d.name, .sig = d.ty.func, .is_inline = sp.is_static or sp.is_inline, .line = line });
                }
            } else if (d.name.len > 0 and in_target and !sp.is_static and (sp.is_extern or !self.isP("{")) and d.ty != .func) {
                // dış değişken (extern T x; ya da tanım): okuma/yazma erişimcileri üretilir
                try self.globals.append(self.a, .{ .name = d.name, .ty = d.ty, .is_const = sp.is_const, .line = line });
                if (self.isP("=")) {
                    self.pos += 1;
                    while (!self.atEof() and !self.isP(",") and !self.isP(";")) {
                        if (self.isP("(") or self.isP("[") or self.isP("{")) self.skipBalanced() else self.pos += 1;
                    }
                }
                if (self.acceptP(",")) continue;
                _ = self.acceptP(";");
                return;
            } else if (d.name.len > 0 and sp.is_static and sp.is_const and in_target and self.isP("=")) {
                // static const <int> NAME = <const-expr>;
                if (self.resolveInt(d.ty)) |_| {
                    self.pos += 1;
                    const s = self.pos;
                    while (!self.atEof() and !self.isP(",") and !self.isP(";")) {
                        if (self.isP("(") or self.isP("[") or self.isP("{")) self.skipBalanced() else self.pos += 1;
                    }
                    if (self.evalRange(s, self.pos)) |v| {
                        const ik = self.resolveInt(d.ty).?;
                        const tt = try intNoxName(self.a, ik);
                        try self.enum_consts.put(self.a, d.name, v); // sonraki sabitler bu adı kullanabilsin
                        try self.consts.append(self.a, .{ .name = d.name, .ty_text = tt, .value = v });
                    }
                    if (self.acceptP(",")) continue;
                    _ = self.acceptP(";");
                    return;
                }
            }
            if (self.isP("=")) {
                self.pos += 1;
                while (!self.atEof() and !self.isP(",") and !self.isP(";")) {
                    if (self.isP("(") or self.isP("[") or self.isP("{")) self.skipBalanced() else self.pos += 1;
                }
            }
            if (self.isP("{")) {
                self.skipBalanced(); // işlev gövdesi
                return;
            }
            if (self.acceptP(",")) continue;
            _ = self.acceptP(";");
            return;
        }
    }

    // ---- typedef çözümleme

    fn resolve(self: *Parser, t: CType) CType {
        var cur_t = t;
        var guard: u8 = 0;
        while (cur_t == .named and guard < 32) : (guard += 1) {
            const n = cur_t.named;
            if (builtinTypedef(n)) |b| return b;
            cur_t = self.typedefs.get(n) orelse return .{ .unsupported = n };
        }
        return cur_t;
    }

    fn resolveInt(self: *Parser, t: CType) ?IntKind {
        const r = self.resolve(t);
        return switch (r) {
            .int => |k| k,
            .bool_ => .{ .bits = 8, .signed = false },
            else => null,
        };
    }
};

/// Sistem başlıkları ayrıştırılamazsa bile bilinen standart tipler.
fn builtinTypedef(name: []const u8) ?CType {
    const T = struct { n: []const u8, k: IntKind };
    const table = [_]T{
        .{ .n = "int8_t", .k = .{ .bits = 8, .signed = true } },                       .{ .n = "uint8_t", .k = .{ .bits = 8, .signed = false } },
        .{ .n = "int16_t", .k = .{ .bits = 16, .signed = true } },                     .{ .n = "uint16_t", .k = .{ .bits = 16, .signed = false } },
        .{ .n = "int32_t", .k = .{ .bits = 32, .signed = true } },                     .{ .n = "uint32_t", .k = .{ .bits = 32, .signed = false } },
        .{ .n = "int64_t", .k = .{ .bits = 64, .signed = true } },                     .{ .n = "uint64_t", .k = .{ .bits = 64, .signed = false } },
        .{ .n = "size_t", .k = .{ .bits = 64, .signed = false, .is_size = true } },    .{ .n = "ssize_t", .k = .{ .bits = 64, .signed = true, .is_size = true } },
        .{ .n = "ptrdiff_t", .k = .{ .bits = 64, .signed = true, .is_size = true } },  .{ .n = "intptr_t", .k = .{ .bits = 64, .signed = true, .is_size = true } },
        .{ .n = "uintptr_t", .k = .{ .bits = 64, .signed = false, .is_size = true } }, .{ .n = "intmax_t", .k = .{ .bits = 64, .signed = true } },
        .{ .n = "uintmax_t", .k = .{ .bits = 64, .signed = false } },                  .{ .n = "off_t", .k = .{ .bits = 64, .signed = true } },
        .{ .n = "time_t", .k = .{ .bits = 64, .signed = true } },
    };
    for (table) |e| if (std.mem.eql(u8, e.n, name)) return .{ .int = e.k };
    return null;
}

// ------------------------------------------------------------------------------------------------ ifade değerlendirici

const ExprParser = struct {
    toks: []const Tok,
    parser: *Parser,
    pos: usize = 0,
    macros: ?*const MacroEval = null,

    fn isP(self: *ExprParser, p: []const u8) bool {
        if (self.pos >= self.toks.len) return false;
        const t = self.toks[self.pos];
        return t.kind == .punct and std.mem.eql(u8, t.text, p);
    }

    fn parseTernary(self: *ExprParser) ?i128 {
        const c = self.parseBin(1) orelse return null;
        if (self.isP("?")) {
            self.pos += 1;
            const a = self.parseTernary() orelse return null;
            if (!self.isP(":")) return null;
            self.pos += 1;
            const b = self.parseTernary() orelse return null;
            return if (c != 0) a else b;
        }
        return c;
    }

    fn prec(op: []const u8) u8 {
        if (std.mem.eql(u8, op, "*") or std.mem.eql(u8, op, "/") or std.mem.eql(u8, op, "%")) return 10;
        if (std.mem.eql(u8, op, "+") or std.mem.eql(u8, op, "-")) return 9;
        if (std.mem.eql(u8, op, "<<") or std.mem.eql(u8, op, ">>")) return 8;
        if (std.mem.eql(u8, op, "<") or std.mem.eql(u8, op, ">") or std.mem.eql(u8, op, "<=") or std.mem.eql(u8, op, ">=")) return 7;
        if (std.mem.eql(u8, op, "==") or std.mem.eql(u8, op, "!=")) return 6;
        if (std.mem.eql(u8, op, "&")) return 5;
        if (std.mem.eql(u8, op, "^")) return 4;
        if (std.mem.eql(u8, op, "|")) return 3;
        if (std.mem.eql(u8, op, "&&")) return 2;
        if (std.mem.eql(u8, op, "||")) return 1;
        return 0;
    }

    fn parseBin(self: *ExprParser, min_prec: u8) ?i128 {
        var lhs = self.parseUnary() orelse return null;
        while (self.pos < self.toks.len) {
            const t = self.toks[self.pos];
            if (t.kind != .punct) break;
            const p = prec(t.text);
            if (p == 0 or p < min_prec) break;
            self.pos += 1;
            const rhs = self.parseBin(p + 1) orelse return null;
            const op = t.text;
            lhs = apply(op, lhs, rhs) orelse return null;
        }
        return lhs;
    }

    fn apply(op: []const u8, l: i128, r: i128) ?i128 {
        if (std.mem.eql(u8, op, "*")) return l *% r;
        if (std.mem.eql(u8, op, "/")) return if (r == 0) null else @divTrunc(l, r);
        if (std.mem.eql(u8, op, "%")) return if (r == 0) null else @rem(l, r);
        if (std.mem.eql(u8, op, "+")) return l +% r;
        if (std.mem.eql(u8, op, "-")) return l -% r;
        if (std.mem.eql(u8, op, "<<")) return if (r < 0 or r > 100) null else l << @intCast(r);
        if (std.mem.eql(u8, op, ">>")) return if (r < 0 or r > 100) null else l >> @intCast(r);
        if (std.mem.eql(u8, op, "<")) return @intFromBool(l < r);
        if (std.mem.eql(u8, op, ">")) return @intFromBool(l > r);
        if (std.mem.eql(u8, op, "<=")) return @intFromBool(l <= r);
        if (std.mem.eql(u8, op, ">=")) return @intFromBool(l >= r);
        if (std.mem.eql(u8, op, "==")) return @intFromBool(l == r);
        if (std.mem.eql(u8, op, "!=")) return @intFromBool(l != r);
        if (std.mem.eql(u8, op, "&")) return l & r;
        if (std.mem.eql(u8, op, "^")) return l ^ r;
        if (std.mem.eql(u8, op, "|")) return l | r;
        if (std.mem.eql(u8, op, "&&")) return @intFromBool(l != 0 and r != 0);
        if (std.mem.eql(u8, op, "||")) return @intFromBool(l != 0 or r != 0);
        return null;
    }

    fn looksLikeCast(self: *ExprParser) bool {
        // `(` tipAnahtarı/typedef-adı ... `)` ardından bir işlenen
        if (self.pos + 2 >= self.toks.len) return false;
        const t = self.toks[self.pos + 1];
        if (t.kind != .ident) return false;
        const kws = [_][]const u8{ "int", "unsigned", "signed", "long", "short", "char", "uint8_t", "uint16_t", "uint32_t", "uint64_t", "int8_t", "int16_t", "int32_t", "int64_t", "size_t", "_Bool" };
        var is_type = self.parser.typedefs.contains(t.text);
        for (kws) |k| if (std.mem.eql(u8, k, t.text)) {
            is_type = true;
        };
        return is_type;
    }

    fn parseUnary(self: *ExprParser) ?i128 {
        if (self.pos >= self.toks.len) return null;
        const t = self.toks[self.pos];
        if (t.kind == .punct) {
            if (std.mem.eql(u8, t.text, "-")) {
                self.pos += 1;
                return -%(self.parseUnary() orelse return null);
            }
            if (std.mem.eql(u8, t.text, "+")) {
                self.pos += 1;
                return self.parseUnary();
            }
            if (std.mem.eql(u8, t.text, "~")) {
                self.pos += 1;
                return ~(self.parseUnary() orelse return null);
            }
            if (std.mem.eql(u8, t.text, "!")) {
                self.pos += 1;
                return @intFromBool((self.parseUnary() orelse return null) == 0);
            }
            if (std.mem.eql(u8, t.text, "(")) {
                if (self.looksLikeCast()) {
                    // tür belirtecini `)`e kadar atla, değeri değiştirme
                    while (self.pos < self.toks.len and !self.isP(")")) self.pos += 1;
                    self.pos += 1;
                    return self.parseUnary();
                }
                self.pos += 1;
                const v = self.parseTernary() orelse return null;
                if (!self.isP(")")) return null;
                self.pos += 1;
                return v;
            }
            return null;
        }
        self.pos += 1;
        switch (t.kind) {
            .number => return parseCInt(t.text),
            .char_lit => {
                const s = t.text;
                if (s.len >= 3 and s[1] != '\\') return s[1];
                if (s.len >= 4 and s[1] == '\\') return switch (s[2]) {
                    'n' => 10,
                    't' => 9,
                    'r' => 13,
                    '0' => 0,
                    '\\' => '\\',
                    '\'' => '\'',
                    else => null,
                };
                return null;
            },
            .ident => {
                if (self.parser.enum_consts.get(t.text)) |v| return v;
                if (self.macros) |m| return m.lookup(t.text);
                return null;
            },
            else => return null,
        }
    }
};

fn parseCInt(text: []const u8) ?i128 {
    var s = text;
    // sonekler
    while (s.len > 0 and (s[s.len - 1] == 'u' or s[s.len - 1] == 'U' or s[s.len - 1] == 'l' or s[s.len - 1] == 'L')) s = s[0 .. s.len - 1];
    if (s.len == 0) return null;
    if (std.mem.indexOfScalar(u8, s, '.') != null) return null;
    if (s.len > 2 and s[0] == '0' and (s[1] == 'x' or s[1] == 'X')) return std.fmt.parseInt(i128, s[2..], 16) catch null;
    if (s.len > 2 and s[0] == '0' and (s[1] == 'b' or s[1] == 'B')) return std.fmt.parseInt(i128, s[2..], 2) catch null;
    if (s.len > 1 and s[0] == '0') return std.fmt.parseInt(i128, s[1..], 8) catch null;
    return std.fmt.parseInt(i128, s, 10) catch null;
}

// ------------------------------------------------------------------------------------------------ makro sabitleri

const MacroEval = struct {
    a: std.mem.Allocator,
    parser: *Parser,
    bodies: std.StringHashMapUnmanaged([]const u8) = .empty,
    cache: std.StringHashMapUnmanaged(?i128) = .empty,
    depth: u8 = 0,

    fn lookup(self_const: *const MacroEval, name: []const u8) ?i128 {
        const self: *MacroEval = @constCast(self_const);
        if (self.cache.get(name)) |c| return c;
        const body = self.bodies.get(name) orelse return null;
        if (self.depth > 16) return null;
        self.depth += 1;
        defer self.depth -= 1;
        const toks = lex(self.a, body, "", true) catch return null;
        var p = ExprParser{ .toks = toks[0 .. toks.len - 1], .parser = self.parser, .macros = self };
        const v = p.parseTernary();
        const res: ?i128 = if (v != null and p.pos == p.toks.len - 0) v else null;
        self.cache.put(self.a, name, res) catch {};
        return res;
    }
};

// ------------------------------------------------------------------------------------------------ üretici

const nox_reserved = [_][]const u8{
    "and",    "as",   "assert", "async",    "await",  "break",  "class",    "continue", "def",   "del",   "elif",   "else",   "except", "finally", "for",     "from",
    "global", "if",   "import", "in",       "is",     "lambda", "nonlocal", "not",      "or",    "pass",  "raise",  "return", "try",    "while",   "with",    "yield",
    "None",   "True", "False",  "lowlevel", "extern", "defer",  "spawn",    "match",    "case",  "enum",  "print",  "len",    "str",    "int",     "float",   "bool",
    "list",   "dict", "ptr",    "range",    "abs",    "min",    "max",      "round",    "sum",   "input", "type",   "self",   "super",  "sizeof",  "alignof", "offsetof",
    "u8",     "u16",  "u32",    "u64",      "i8",     "i16",    "i32",      "i64",      "usize", "isize", "detach", "adopt",  "main",
};

fn isReserved(name: []const u8) bool {
    for (nox_reserved) |r| if (std.mem.eql(u8, r, name)) return true;
    return false;
}

fn intNoxName(a: std.mem.Allocator, k: IntKind) ![]const u8 {
    if (k.is_size) return if (k.signed) "isize" else "usize";
    return try std.fmt.allocPrint(a, "{s}{d}", .{ if (k.signed) "i" else "u", k.bits });
}

const NoxType = struct {
    nox: []const u8,
    /// Kabuk imzasında kullanılacak C türü
    c: []const u8,
    is_f32: bool = false,
    needs_shim: bool = false,
    /// değerle struct/union: kabukta `*(<rec> *)ptr` olarak geçer; değer C tür metni
    rec: ?[]const u8 = null,
    rec_tag: []const u8 = "",
};

const Emitter = struct {
    a: std.mem.Allocator,
    p: *Parser,
    opts: Options,
    warnings: std.ArrayListUnmanaged([]const u8) = .empty,
    /// değerle geçirilen kayıtlar: etiket -> C tür metni (yardımcılar bunlar için de üretilir)
    by_value: std.StringHashMapUnmanaged([]const u8) = .empty,

    /// Kaydın yardımcı/erişimci adlarında kullanılan görünen ad: typedef takma adı, yoksa (adsız değilse) etiket.
    fn recordDisplay(self: *Emitter, tag: []const u8) ?[]const u8 {
        if (self.p.record_alias.get(tag)) |al| return al;
        if (std.mem.startsWith(u8, tag, "__anon_record_")) return null;
        return tag;
    }

    /// Kaydın C tür metni (`Vec` ya da `struct vec`/`union u`).
    fn recordCText(self: *Emitter, tag: []const u8) !?[]const u8 {
        if (self.p.record_alias.get(tag)) |al| return al;
        if (std.mem.startsWith(u8, tag, "__anon_record_")) return null;
        const rec = self.p.records.get(tag) orelse return null;
        return try std.fmt.allocPrint(self.a, "{s} {s}", .{ if (rec.is_union) "union" else "struct", tag });
    }

    fn warn(self: *Emitter, comptime fmt: []const u8, args: anytype) !void {
        try self.warnings.append(self.a, try std.fmt.allocPrint(self.a, fmt, args));
    }

    fn cIntName(self: *Emitter, k: IntKind) ![]const u8 {
        if (k.is_size) return if (k.signed) "intptr_t" else "size_t";
        return try std.fmt.allocPrint(self.a, "{s}int{d}_t", .{ if (k.signed) "" else "u", k.bits });
    }

    /// `as_param`: `const char *` parametreleri `str` olur. Desteklenmeyenler `null` + neden.
    fn mapType(self: *Emitter, t: CType, as_param: bool, reason: *[]const u8) !?NoxType {
        const r = self.p.resolve(t);
        switch (r) {
            .void => return .{ .nox = "None", .c = "void" },
            .bool_ => return .{ .nox = "bool", .c = "_Bool" },
            .int => |k| return .{ .nox = try intNoxName(self.a, k), .c = try self.cIntName(k) },
            .f64 => return .{ .nox = "float", .c = "double" },
            .f32 => return .{ .nox = "float", .c = "double", .is_f32 = true, .needs_shim = true },
            .enum_ => return .{ .nox = "i32", .c = "int32_t" },
            .ptr => |pt| {
                if (as_param and pt.const_pointee) {
                    const to = self.p.resolve(pt.to.*);
                    // yalnızca düz `char` (metin): `unsigned char`/`uint8_t`/`signed char` ikili veridir ve `ptr` kalır
                    if (to == .int and to.int.is_char) return .{ .nox = "str", .c = "const char *" };
                }
                return .{ .nox = "ptr", .c = "void *" };
            },
            .array => return .{ .nox = "ptr", .c = "void *" },
            .func => return .{ .nox = "ptr", .c = "void *" },
            .record => |tag| {
                const rec = self.p.records.get(tag) orelse {
                    reason.* = "struct/union with an unknown definition";
                    return null;
                };
                if (!rec.complete) {
                    reason.* = "incomplete (opaque) struct/union cannot be passed by value";
                    return null;
                }
                // özgün (çözülmemiş) tipte typedef adı varsa onu, yoksa etiketli metni kullan
                const ct: []const u8 = switch (t) {
                    .named => |n| n,
                    else => (try self.recordCText(tag)) orelse {
                        reason.* = "anonymous struct/union";
                        return null;
                    },
                };
                try self.by_value.put(self.a, tag, ct);
                return .{ .nox = "ptr", .c = "const void *", .needs_shim = true, .rec = ct, .rec_tag = tag };
            },
            .unsupported => |u| {
                reason.* = try std.fmt.allocPrint(self.a, "unsupported type '{s}'", .{u});
                return null;
            },
            .named => {
                reason.* = "unresolved type";
                return null;
            },
        }
    }

    /// `prefix` virgülle ayrılmış birden çok önek olabilir (`sqlite3_,sqlite_`); BÜYÜK/küçük harf duyarsız.
    fn matchesPrefix(self: *Emitter, name: []const u8) bool {
        if (self.opts.prefix.len == 0) return true;
        var it = std.mem.splitScalar(u8, self.opts.prefix, ',');
        while (it.next()) |pre| {
            if (pre.len == 0) continue;
            if (name.len >= pre.len and std.ascii.eqlIgnoreCase(name[0..pre.len], pre)) return true;
        }
        return false;
    }
};

pub fn generateFromText(a: std.mem.Allocator, pp_text: []const u8, defines_text: []const u8, opts: Options, all_in_target: bool) !Output {
    const toks = try lex(a, pp_text, baseName(opts.header), all_in_target);
    var parser = Parser{ .a = a, .toks = toks };

    // makro sabitleri (ve hedef ABI: `long` genişliği, düz `char` işaretliliği)
    var macros = MacroEval{ .a = a, .parser = &parser };
    var lines = std.mem.splitScalar(u8, defines_text, '\n');
    var macro_names: std.ArrayListUnmanaged([]const u8) = .empty;
    while (lines.next()) |ln| {
        const prefix = "#define ";
        if (!std.mem.startsWith(u8, ln, prefix)) continue;
        const rest = ln[prefix.len..];
        var e: usize = 0;
        while (e < rest.len and isIdentChar(rest[e])) e += 1;
        if (e == 0) continue;
        const name = rest[0..e];
        if (e < rest.len and rest[e] == '(') continue; // işlev-benzeri makro
        const body = std.mem.trim(u8, rest[e..], " \t");
        try macros.bodies.put(a, name, body);
        try macro_names.append(a, name);
        if (std.mem.eql(u8, name, "__SIZEOF_LONG__")) {
            if (std.fmt.parseInt(u8, body, 10)) |n| parser.long_bits = n * 8 else |_| {}
        } else if (std.mem.eql(u8, name, "__CHAR_UNSIGNED__")) {
            parser.char_signed = false;
        }
    }
    try parser.parseTop();

    var em = Emitter{ .a = a, .p = &parser, .opts = opts };
    for (parser.warnings.items) |w| try em.warnings.append(a, w);

    var nox: std.ArrayListUnmanaged(u8) = .empty;
    var shim: std.ArrayListUnmanaged(u8) = .empty;
    var n_funcs: usize = 0;
    var n_shims: usize = 0;
    var n_consts: usize = 0;

    try appendF(a, &nox, "# Generated by `noxc bindgen` from {s}. Do not edit by hand: regenerate.\n#\n# Pointers are `ptr`; `const char *` parameters are `str`; enums are `i32`.\n# Functions marked (shim) are `static inline` or take a `float`: they call a generated C shim.\n\n", .{baseName(opts.header)});
    try appendF(a, &shim, "/* Generated by `noxc bindgen` from {s}. Compile with the same flags as the library: cc -c <this file> -I<header dir>. */\n#include <stdint.h>\n#include <stddef.h>\n#include <stdlib.h>\n#include \"{s}\"\n\n", .{ baseName(opts.header), opts.include_name });

    const shim_prelude_len = shim.items.len;

    // sabitler: enum üyeleri + static const + makrolar
    var emitted: std.StringHashMapUnmanaged(void) = .empty;
    for (parser.consts.items) |c| {
        if (!em.matchesPrefix(c.name) or emitted.contains(c.name)) continue;
        if (isReserved(c.name)) continue;
        try emitted.put(a, c.name, {});
        try appendF(a, &nox, "{s}: {s} = {s}({d})\n", .{ c.name, c.ty_text, c.ty_text, c.value });
        n_consts += 1;
    }
    if (opts.prefix.len > 0) {
        std.mem.sort([]const u8, macro_names.items, {}, struct {
            fn lt(_: void, x: []const u8, y: []const u8) bool {
                return std.mem.lessThan(u8, x, y);
            }
        }.lt);
        for (macro_names.items) |mn| {
            if (!em.matchesPrefix(mn) or emitted.contains(mn) or isReserved(mn)) continue;
            const body = macros.bodies.get(mn).?;
            if (body.len >= 2 and body[0] == '"' and body[body.len - 1] == '"') {
                try emitted.put(a, mn, {});
                try appendF(a, &nox, "{s}: str = {s}\n", .{ mn, body });
                n_consts += 1;
                continue;
            }
            if (macros.lookup(mn)) |v| {
                if (v >= std.math.minInt(i64) and v <= std.math.maxInt(i64)) {
                    try emitted.put(a, mn, {});
                    try appendF(a, &nox, "{s}: int = {d}\n", .{ mn, @as(i64, @intCast(v)) });
                    n_consts += 1;
                }
            }
        }
    }
    if (n_consts > 0) try nox.append(a, '\n');

    // dış ad çakışması denetimi: kütüphanenin (ve kabuğun) tüm işlev adları
    var taken: std.StringHashMapUnmanaged(void) = .empty;
    for (parser.funcs.items) |f| try taken.put(a, f.name, {});
    for (parser.globals.items) |g| try taken.put(a, g.name, {});

    // işlevler
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var pending_wrappers: std.ArrayListUnmanaged(u8) = .empty; // değerle-struct sarmalayıcıları `Name_new`i sonra tanımlanan yardımcılardan çağırır
    for (parser.funcs.items) |f| {
        if (!em.matchesPrefix(f.name) or seen.contains(f.name)) continue;
        try seen.put(a, f.name, {});
        if (f.sig.variadic) {
            try em.warn("line {d}: skipped {s}: variadic function (see TODO 8.6)", .{ f.line, f.name });
            continue;
        }
        var reason: []const u8 = "";
        const ret_t = (try em.mapType(f.sig.ret, false, &reason)) orelse {
            try em.warn("line {d}: skipped {s}: return type: {s}", .{ f.line, f.name, reason });
            continue;
        };
        var params: std.ArrayListUnmanaged(NoxType) = .empty;
        var ok = true;
        for (f.sig.params, 0..) |pa, i| {
            const pt = (try em.mapType(pa.ty, true, &reason)) orelse {
                try em.warn("line {d}: skipped {s}: parameter {d}: {s}", .{ f.line, f.name, i + 1, reason });
                ok = false;
                break;
            };
            try params.append(a, pt);
        }
        if (!ok) continue;
        var needs_shim = f.is_inline or ret_t.needs_shim or isReserved(f.name);
        for (params.items) |pt| needs_shim = needs_shim or pt.needs_shim;

        // parametre adları
        const names = try a.alloc([]const u8, params.items.len);
        for (names, 0..) |*nm, i| {
            const raw = f.sig.params[i].name;
            nm.* = if (raw.len == 0) try std.fmt.allocPrint(a, "a{d}", .{i}) else if (isReserved(raw)) try std.fmt.allocPrint(a, "{s}_", .{raw}) else raw;
        }
        n_funcs += 1;
        if (!needs_shim) {
            const cbp = try detectCallback(&em, f);
            if (cbp) |cp| {
                const dflt = f.sig.params[cp.cb_idx];
                _ = dflt;
                const cs = em.p.resolve(em.p.resolve(f.sig.params[cp.cb_idx].ty).ptr.to.*).func;
                try appendF(a, &nox, "@ffi.callback(\"{s}\", \"{s}\"", .{ names[cp.cb_idx], names[cp.ud_outer] });
                if (cp.ud_pos != cs.params.len - 1) try appendF(a, &nox, ", ud_index={d}", .{cp.ud_pos});
                try nox.appendSlice(a, ")\n");
            }
            try appendF(a, &nox, "extern def {s}(", .{f.name});
            for (names, params.items, 0..) |nm, pt, i| {
                if (i > 0) try nox.appendSlice(a, ", ");
                const ty_text: []const u8 = if (cbp != null and i == cbp.?.cb_idx) cbp.?.type_text else pt.nox;
                try appendF(a, &nox, "{s}: {s}", .{ nm, ty_text });
            }
            try appendF(a, &nox, ") -> {s} from \"{s}\"\n", .{ ret_t.nox, opts.lib });
        } else {
            n_shims += 1;
            const shim_name = try std.fmt.allocPrint(a, "nox_shim_{s}", .{f.name});
            const ret_is_rec = ret_t.rec != null;
            // C kabuğu: değerle dönen struct, son parametre `void *nox_ret` ile yazılır
            try appendF(a, &shim, "{s} {s}(", .{ if (ret_is_rec) "void" else ret_t.c, shim_name });
            if (names.len == 0 and !ret_is_rec) try shim.appendSlice(a, "void");
            for (names, params.items, 0..) |nm, pt, i| {
                if (i > 0) try shim.appendSlice(a, ", ");
                try appendF(a, &shim, "{s}{s}{s}", .{ pt.c, if (std.mem.endsWith(u8, pt.c, "*")) "" else " ", nm });
            }
            if (ret_is_rec) try appendF(a, &shim, "{s}void *nox_ret", .{if (names.len > 0) ", " else ""});
            try shim.appendSlice(a, ") { ");
            if (ret_is_rec) {
                try appendF(a, &shim, "*({s} *)nox_ret = ", .{ret_t.rec.?});
            } else if (!std.mem.eql(u8, ret_t.c, "void")) try shim.appendSlice(a, "return ");
            try appendF(a, &shim, "{s}(", .{f.name});
            for (names, params.items, 0..) |nm, pt, i| {
                if (i > 0) try shim.appendSlice(a, ", ");
                if (pt.rec) |rt| try appendF(a, &shim, "*({s} *){s}", .{ rt, nm }) else try shim.appendSlice(a, nm);
            }
            try shim.appendSlice(a, "); }\n");
            // Nox: ham extern + sarmalayıcı
            // Dış sembolü olan (satır içi OLMAYAN) bir işlevin sarmalayıcısı C adını kullanamaz: Nox'un üst-düzey `def`i de AYNI ham sembolü üretir ve bağlama çakışır.
            const wrapper_name: []const u8 = if (!f.is_inline or isReserved(f.name)) try std.fmt.allocPrint(a, "{s}_", .{f.name}) else f.name;
            try appendF(a, &nox, "extern def {s}(", .{shim_name});
            for (names, params.items, 0..) |nm, pt, i| {
                if (i > 0) try nox.appendSlice(a, ", ");
                try appendF(a, &nox, "{s}: {s}", .{ nm, pt.nox });
            }
            if (ret_is_rec) try appendF(a, &nox, "{s}nox_ret: ptr", .{if (names.len > 0) ", " else ""});
            try appendF(a, &nox, ") -> {s} from \"{s}\"\n", .{ if (ret_is_rec) "None" else ret_t.nox, opts.shim_lib });
            const out_list: *std.ArrayListUnmanaged(u8) = if (ret_is_rec) &pending_wrappers else &nox;
            try appendF(a, out_list, "def {s}(", .{wrapper_name});
            for (names, params.items, 0..) |nm, pt, i| {
                if (i > 0) try out_list.appendSlice(a, ", ");
                try appendF(a, out_list, "{s}: {s}", .{ nm, pt.nox });
            }
            try appendF(a, out_list, ") -> {s}:\n", .{ret_t.nox});
            if (ret_is_rec) {
                const helper = em.recordDisplay(ret_t.rec_tag) orelse "rec";
                try appendF(a, out_list, "    nox_ret: ptr = {s}_new()\n    {s}(", .{ helper, shim_name });
                for (names) |nm| try appendF(a, out_list, "{s}, ", .{nm});
                try out_list.appendSlice(a, "nox_ret)\n    return nox_ret\n");
            } else {
                try out_list.appendSlice(a, "    ");
                if (!std.mem.eql(u8, ret_t.nox, "None")) try out_list.appendSlice(a, "return ");
                try appendF(a, out_list, "{s}(", .{shim_name});
                for (names, 0..) |nm, i| {
                    if (i > 0) try out_list.appendSlice(a, ", ");
                    try out_list.appendSlice(a, nm);
                }
                try out_list.appendSlice(a, ")\n");
            }
        }
    }
    if (pending_wrappers.items.len > 0) {
        try nox.appendSlice(a, "\n# by-value struct/union wrappers: arguments are pointers to the struct memory; a returned struct is a NEW block the caller frees with <Name>_free\n");
        try nox.appendSlice(a, pending_wrappers.items);
    }

    // struct/union yardımcıları ve alan erişimcileri; değerle geçirilen kayıtlar için de yardımcılar
    var rec_names: std.ArrayListUnmanaged([]const u8) = .empty;
    var rit = parser.records.iterator();
    while (rit.next()) |e| {
        const rec = e.value_ptr.*;
        const wanted_by_value = em.by_value.contains(rec.tag);
        const display = em.recordDisplay(rec.tag) orelse continue;
        if ((rec.in_target and rec.complete and em.matchesPrefix(display)) or wanted_by_value) try rec_names.append(a, rec.tag);
    }
    std.mem.sort([]const u8, rec_names.items, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);
    if (rec_names.items.len > 0) try nox.appendSlice(a, "\n# struct/union helpers: <Name>_new / _free / _size and per-field <Name>_get_<f> / <Name>_set_<f> (struct memory is always a `ptr`)\n");
    for (rec_names.items) |tag| {
        const rec = parser.records.get(tag).?;
        const display = em.recordDisplay(tag).?;
        const ctext = (try em.recordCText(tag)) orelse continue;
        try emitRecord(&em, rec, display, ctext, &nox, &shim, &taken);
    }

    // global değişkenler
    for (parser.globals.items) |g| {
        if (!em.matchesPrefix(g.name)) continue;
        var reason: []const u8 = "";
        const r = parser.resolve(g.ty);
        if (r == .array or r == .record) {
            const nm = try uniqueName(a, &taken, try std.fmt.allocPrint(a, "{s}_ptr", .{g.name}));
            try appendF(a, &shim, "void *{s}(void) {{ return (void *)&{s}; }}\n", .{ nm, g.name });
            try appendF(a, &nox, "extern def {s}() -> ptr from \"{s}\"\n", .{ nm, opts.shim_lib });
            n_shims += 1;
            continue;
        }
        const mt = (try em.mapType(g.ty, false, &reason)) orelse {
            try em.warn("line {d}: skipped global {s}: {s}", .{ g.line, g.name, reason });
            continue;
        };
        const get = try uniqueName(a, &taken, try std.fmt.allocPrint(a, "{s}_get", .{g.name}));
        const cast: []const u8 = if (std.mem.endsWith(u8, mt.c, "*")) "(void *)" else if (mt.is_f32) "(double)" else "";
        try appendF(a, &shim, "{s} {s}(void) {{ return {s}{s}; }}\n", .{ mt.c, get, cast, g.name });
        try appendF(a, &nox, "extern def {s}() -> {s} from \"{s}\"\n", .{ get, mt.nox, opts.shim_lib });
        if (!g.is_const) {
            const set = try uniqueName(a, &taken, try std.fmt.allocPrint(a, "{s}_set", .{g.name}));
            try appendF(a, &shim, "void {s}({s}{s}v) {{ {s} = (__typeof__({s}))v; }}\n", .{ set, mt.c, if (std.mem.endsWith(u8, mt.c, "*")) "" else " ", g.name, g.name });
            try appendF(a, &nox, "extern def {s}(v: {s}) -> None from \"{s}\"\n", .{ set, mt.nox, opts.shim_lib });
        }
        n_shims += 1;
    }

    // yalnızca yapı yardımcıları/erişimcileri kabuğa yazıldıysa da kabuk dosyası gerekir
    if (n_shims == 0 and shim.items.len > shim_prelude_len) n_shims = 1;
    return .{ .nox = nox.items, .shim = shim.items, .warnings = em.warnings.items, .n_funcs = n_funcs, .n_shims = n_shims, .n_consts = n_consts };
}

const CallbackPattern = struct {
    cb_idx: usize,
    ud_outer: usize,
    ud_pos: usize,
    /// Nox callback tipi metni, ör. `(ptr, i32, ptr) -> i32` (userdata dahil — C imzasının aynısı)
    type_text: []const u8,
};

/// `T (*cb)(..., void *ud, ...)` parametresi + yanında bir `void *` userdata parametresi varsa `@ffi.callback` kalıbını bulur (yoksa null).
fn detectCallback(em: *Emitter, f: FuncDecl) !?CallbackPattern {
    const ps = f.sig.params;
    for (ps, 0..) |pa, i| {
        const r = em.p.resolve(pa.ty);
        if (r != .ptr) continue;
        const target = em.p.resolve(r.ptr.to.*);
        if (target != .func) continue;
        const cs = target.func;
        if (cs.variadic) continue;
        // callback imzasında userdata adayı: `const` OLMAYAN `void *` (birden çoksa sonuncusu)
        var ud_pos: ?usize = null;
        for (cs.params, 0..) |cp, k| {
            const cr = em.p.resolve(cp.ty);
            if (cr == .ptr and !cr.ptr.const_pointee and em.p.resolve(cr.ptr.to.*) == .void) ud_pos = k;
        }
        const k = ud_pos orelse continue;
        // dış işlevde yanındaki `void *` parametresi (önce sonraki, sonra önceki)
        var ud_outer: ?usize = null;
        const cand_idx = [_]isize{ @as(isize, @intCast(i)) + 1, @as(isize, @intCast(i)) - 1 };
        for (cand_idx) |ci| {
            if (ci < 0 or ci >= ps.len) continue;
            const pr = em.p.resolve(ps[@intCast(ci)].ty);
            if (pr == .ptr and em.p.resolve(pr.ptr.to.*) == .void) {
                ud_outer = @intCast(ci);
                break;
            }
        }
        const uo = ud_outer orelse continue;
        // callback tipi: her parametre/dönüş Nox'ta ifade edilebilmeli (f32/struct değil)
        var text: std.ArrayListUnmanaged(u8) = .empty;
        try text.append(em.a, '(');
        var ok = true;
        var reason: []const u8 = "";
        for (cs.params, 0..) |cp, kk| {
            const mt = (try em.mapType(cp.ty, false, &reason)) orelse {
                ok = false;
                break;
            };
            if (mt.is_f32 or mt.rec != null) {
                ok = false;
                break;
            }
            if (kk > 0) try text.appendSlice(em.a, ", ");
            try text.appendSlice(em.a, mt.nox);
        }
        if (!ok) continue;
        const rt = (try em.mapType(cs.ret, false, &reason)) orelse continue;
        if (rt.is_f32 or rt.rec != null) continue;
        try appendF(em.a, &text, ") -> {s}", .{rt.nox});
        return .{ .cb_idx = i, .ud_outer = uo, .ud_pos = k, .type_text = text.items };
    }
    return null;
}

fn uniqueName(a: std.mem.Allocator, taken: *std.StringHashMapUnmanaged(void), base: []const u8) ![]const u8 {
    var name = base;
    while (taken.contains(name)) name = try std.fmt.allocPrint(a, "{s}_", .{name});
    try taken.put(a, name, {});
    return name;
}

/// Bir struct/union için `_new/_free/_size` ve (alanları ayrıştırılmışsa) alan erişimcilerini üretir. Erişim C derleyicisince derlenen kabuktan geçer:
/// yerleşim, bit alanları, hizalama, `const` ve sendikalar elle hesaplanmaz.
fn emitRecord(em: *Emitter, rec: Record, display: []const u8, ctext: []const u8, nox: *std.ArrayListUnmanaged(u8), shim: *std.ArrayListUnmanaged(u8), taken: *std.StringHashMapUnmanaged(void)) !void {
    const a = em.a;
    const lib = em.opts.shim_lib;
    const new_n = try uniqueName(a, taken, try std.fmt.allocPrint(a, "{s}_new", .{display}));
    const free_n = try uniqueName(a, taken, try std.fmt.allocPrint(a, "{s}_free", .{display}));
    const size_n = try uniqueName(a, taken, try std.fmt.allocPrint(a, "{s}_size", .{display}));
    try appendF(a, shim, "void *{s}(void) {{ return calloc(1, sizeof({s})); }}\nvoid {s}(void *p) {{ free(p); }}\nsize_t {s}(void) {{ return sizeof({s}); }}\n", .{ new_n, ctext, free_n, size_n, ctext });
    try appendF(a, nox, "extern def {s}() -> ptr from \"{s}\"\nextern def {s}(p: ptr) -> None from \"{s}\"\nextern def {s}() -> usize from \"{s}\"\n", .{ new_n, lib, free_n, lib, size_n, lib });
    if (rec.in_target and rec.fields_ok) try emitFields(em, rec, display, ctext, "", nox, shim, taken);
}

fn emitFields(em: *Emitter, rec: Record, display: []const u8, ctext: []const u8, unused: []const u8, nox: *std.ArrayListUnmanaged(u8), shim: *std.ArrayListUnmanaged(u8), taken: *std.StringHashMapUnmanaged(void)) !void {
    _ = unused;
    const a = em.a;
    const lib = em.opts.shim_lib;
    for (rec.fields) |f| {
        if (f.name.len == 0) {
            // adsız iç struct/union: alanları doğrudan `p->alan` ile erişilir
            if (f.ty == .record) {
                if (em.p.records.get(f.ty.record)) |inner| if (inner.fields_ok) try emitFields(em, inner, display, ctext, "", nox, shim, taken);
            }
            continue;
        }
        const acc = try std.fmt.allocPrint(a, "(({s} *)p)->{s}", .{ ctext, f.name });
        const r = em.p.resolve(f.ty);
        var reason: []const u8 = "";
        switch (r) {
            .array => |arr| {
                const er = em.p.resolve(arr.elem.*);
                const ptr_n = try uniqueName(a, taken, try std.fmt.allocPrint(a, "{s}_{s}_ptr", .{ display, f.name }));
                try appendF(a, shim, "void *{s}(void *p) {{ return (void *){s}; }}\n", .{ ptr_n, acc });
                try appendF(a, nox, "extern def {s}(p: ptr) -> ptr from \"{s}\"\n", .{ ptr_n, lib });
                if (arr.len) |n| try appendF(a, nox, "{s}_{s}_LEN: int = {d}\n", .{ display, f.name, n });
                if (er == .record) {
                    const addr_n = try uniqueName(a, taken, try std.fmt.allocPrint(a, "{s}_get_{s}", .{ display, f.name }));
                    try appendF(a, shim, "void *{s}(void *p, size_t i) {{ return (void *)&{s}[i]; }}\n", .{ addr_n, acc });
                    try appendF(a, nox, "extern def {s}(p: ptr, i: usize) -> ptr from \"{s}\"\n", .{ addr_n, lib });
                    continue;
                }
                const mt = (try em.mapType(arr.elem.*, false, &reason)) orelse {
                    try em.warn("skipped field {s}.{s}: {s}", .{ display, f.name, reason });
                    continue;
                };
                const get_n = try uniqueName(a, taken, try std.fmt.allocPrint(a, "{s}_get_{s}", .{ display, f.name }));
                const cast: []const u8 = if (std.mem.endsWith(u8, mt.c, "*")) "(void *)" else if (mt.is_f32) "(double)" else "";
                try appendF(a, shim, "{s} {s}(void *p, size_t i) {{ return {s}{s}[i]; }}\n", .{ mt.c, get_n, cast, acc });
                try appendF(a, nox, "extern def {s}(p: ptr, i: usize) -> {s} from \"{s}\"\n", .{ get_n, mt.nox, lib });
                if (!f.is_const) {
                    const set_n = try uniqueName(a, taken, try std.fmt.allocPrint(a, "{s}_set_{s}", .{ display, f.name }));
                    try appendF(a, shim, "void {s}(void *p, size_t i, {s}{s}v) {{ {s}[i] = (__typeof__({s}[0]))v; }}\n", .{ set_n, mt.c, if (std.mem.endsWith(u8, mt.c, "*")) "" else " ", acc, acc });
                    try appendF(a, nox, "extern def {s}(p: ptr, i: usize, v: {s}) -> None from \"{s}\"\n", .{ set_n, mt.nox, lib });
                }
            },
            .record => {
                const addr_n = try uniqueName(a, taken, try std.fmt.allocPrint(a, "{s}_get_{s}", .{ display, f.name }));
                try appendF(a, shim, "void *{s}(void *p) {{ return (void *)&{s}; }}\n", .{ addr_n, acc });
                try appendF(a, nox, "extern def {s}(p: ptr) -> ptr from \"{s}\"\n", .{ addr_n, lib });
                if (!f.is_const) {
                    const set_n = try uniqueName(a, taken, try std.fmt.allocPrint(a, "{s}_set_{s}", .{ display, f.name }));
                    try appendF(a, shim, "void {s}(void *p, const void *v) {{ {s} = *(const __typeof__({s}) *)v; }}\n", .{ set_n, acc, acc });
                    try appendF(a, nox, "extern def {s}(p: ptr, v: ptr) -> None from \"{s}\"\n", .{ set_n, lib });
                }
            },
            else => {
                const mt = (try em.mapType(f.ty, false, &reason)) orelse {
                    try em.warn("skipped field {s}.{s}: {s}", .{ display, f.name, reason });
                    continue;
                };
                const get_n = try uniqueName(a, taken, try std.fmt.allocPrint(a, "{s}_get_{s}", .{ display, f.name }));
                const cast: []const u8 = if (std.mem.endsWith(u8, mt.c, "*")) "(void *)" else if (mt.is_f32) "(double)" else "";
                try appendF(a, shim, "{s} {s}(void *p) {{ return {s}{s}; }}\n", .{ mt.c, get_n, cast, acc });
                try appendF(a, nox, "extern def {s}(p: ptr) -> {s} from \"{s}\"\n", .{ get_n, mt.nox, lib });
                if (!f.is_const) {
                    const set_n = try uniqueName(a, taken, try std.fmt.allocPrint(a, "{s}_set_{s}", .{ display, f.name }));
                    // bit alanlarında `__typeof__` kullanılamaz: düz atama (örtük dönüşüm)
                    const rhs: []const u8 = if (f.bitfield) "v" else try std.fmt.allocPrint(a, "(__typeof__({s}))v", .{acc});
                    try appendF(a, shim, "void {s}(void *p, {s}{s}v) {{ {s} = {s}; }}\n", .{ set_n, mt.c, if (std.mem.endsWith(u8, mt.c, "*")) "" else " ", acc, rhs });
                    try appendF(a, nox, "extern def {s}(p: ptr, v: {s}) -> None from \"{s}\"\n", .{ set_n, mt.nox, lib });
                }
            },
        }
    }
}

fn appendF(a: std.mem.Allocator, list: *std.ArrayListUnmanaged(u8), comptime fmt: []const u8, args: anytype) !void {
    try list.appendSlice(a, try std.fmt.allocPrint(a, fmt, args));
}

// ------------------------------------------------------------------------------------------------ komut satırı

fn stemOf(path: []const u8) []const u8 {
    const b = baseName(path);
    return if (std.mem.lastIndexOfScalar(u8, b, '.')) |d| b[0..d] else b;
}

fn dirOf(path: []const u8) []const u8 {
    var i = path.len;
    while (i > 0) : (i -= 1) {
        if (path[i - 1] == '/' or path[i - 1] == '\\') return path[0 .. i - 1];
    }
    return ".";
}

const usage =
    \\usage: noxc bindgen <header.h> --lib <library> [options]
    \\
    \\  --lib <name|path>     where the C symbols live: a system library name ("m") or an object/archive path ("build/libfoo.a")  [required]
    \\  -o <file.nox>         output file (default: <header>.nox in the current directory)
    \\  --prefix <p[,p2]>     only emit functions/constants whose name starts with <p> (case-insensitive, comma-separated; REQUIRED to emit #define constants)
    \\  -I <dir>, -D <n[=v]>  forwarded to the C preprocessor / shim compiler
    \\  --shim <file.c>       generated C shim for static inline functions and `float` (default: <out>_shim.c)
    \\  --shim-lib <file.o>   object name written into the generated `from` clauses (default: <out>_shim.o)
    \\  --no-compile          do not compile the shim (you compile it yourself: cc -c <shim.c> -I<header dir>)
    \\  --cc <compiler>       C compiler (default: cc)
    \\
;

/// `noxc bindgen` komutu. Çıkış kodunu döndürür.
pub fn runCli(gpa: std.mem.Allocator, io: std.Io, a: std.mem.Allocator, args: []const []const u8) !u8 {
    var header: ?[]const u8 = null;
    var lib: ?[]const u8 = null;
    var out_path: ?[]const u8 = null;
    var prefix: []const u8 = "";
    var shim_path: ?[]const u8 = null;
    var shim_lib: ?[]const u8 = null;
    var no_compile = false;
    var cc: []const u8 = "cc";
    var cpp_flags: std.ArrayListUnmanaged([]const u8) = .empty;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        const needs_val = std.mem.eql(u8, arg, "--lib") or std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--prefix") or std.mem.eql(u8, arg, "--shim") or
            std.mem.eql(u8, arg, "--shim-lib") or std.mem.eql(u8, arg, "--cc") or std.mem.eql(u8, arg, "-I") or std.mem.eql(u8, arg, "-D");
        if (needs_val) {
            if (i + 1 >= args.len) {
                std.debug.print("{s}: missing value\n{s}", .{ arg, usage });
                return 2;
            }
            i += 1;
            const v = args[i];
            if (std.mem.eql(u8, arg, "--lib")) lib = v else if (std.mem.eql(u8, arg, "-o")) out_path = v else if (std.mem.eql(u8, arg, "--prefix")) prefix = v else if (std.mem.eql(u8, arg, "--shim")) shim_path = v else if (std.mem.eql(u8, arg, "--shim-lib")) shim_lib = v else if (std.mem.eql(u8, arg, "--cc")) cc = v else {
                try cpp_flags.append(a, arg);
                try cpp_flags.append(a, v);
            }
        } else if (std.mem.startsWith(u8, arg, "-I") or std.mem.startsWith(u8, arg, "-D")) {
            try cpp_flags.append(a, arg);
        } else if (std.mem.eql(u8, arg, "--no-compile")) {
            no_compile = true;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            std.debug.print("{s}", .{usage});
            return 0;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            std.debug.print("unknown option: {s}\n{s}", .{ arg, usage });
            return 2;
        } else if (header == null) {
            header = arg;
        } else {
            std.debug.print("unexpected argument: {s}\n{s}", .{ arg, usage });
            return 2;
        }
    }
    const hdr = header orelse {
        std.debug.print("{s}", .{usage});
        return 2;
    };
    const lib_v = lib orelse {
        std.debug.print("--lib is required\n{s}", .{usage});
        return 2;
    };
    const out_v = out_path orelse try std.fmt.allocPrint(a, "{s}.nox", .{stemOf(hdr)});
    const out_stem = if (std.mem.endsWith(u8, out_v, ".nox")) out_v[0 .. out_v.len - 4] else out_v;
    const shim_v = shim_path orelse try std.fmt.allocPrint(a, "{s}_shim.c", .{out_stem});
    const shim_lib_v = shim_lib orelse try std.fmt.allocPrint(a, "{s}_shim.o", .{out_stem});

    // 1) ön işleme (+ makro tanımları)
    var pp_argv: std.ArrayListUnmanaged([]const u8) = .empty;
    try pp_argv.appendSlice(a, &.{ cc, "-x", "c", "-E" });
    try pp_argv.appendSlice(a, cpp_flags.items);
    try pp_argv.append(a, hdr);
    const pp = std.process.run(gpa, io, .{ .argv = pp_argv.items }) catch |err| {
        std.debug.print("could not run '{s}': {t}\n", .{ cc, err });
        return 1;
    };
    defer gpa.free(pp.stdout);
    defer gpa.free(pp.stderr);
    if (pp.term != .exited or pp.term.exited != 0) {
        std.debug.print("preprocessing {s} failed:\n{s}\n", .{ hdr, pp.stderr });
        return 1;
    }
    var dm_argv: std.ArrayListUnmanaged([]const u8) = .empty;
    try dm_argv.appendSlice(a, &.{ cc, "-x", "c", "-E", "-dM" });
    try dm_argv.appendSlice(a, cpp_flags.items);
    try dm_argv.append(a, hdr);
    const dm = std.process.run(gpa, io, .{ .argv = dm_argv.items }) catch {
        std.debug.print("could not run '{s}'\n", .{cc});
        return 1;
    };
    defer gpa.free(dm.stdout);
    defer gpa.free(dm.stderr);

    // 2) üretim
    const include_name = baseName(hdr);
    const result = try generateFromText(a, pp.stdout, dm.stdout, .{
        .header = hdr,
        .lib = lib_v,
        .shim_lib = shim_lib_v,
        .include_name = include_name,
        .prefix = prefix,
    }, false);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out_v, .data = result.nox });
    if (result.n_shims > 0) try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = shim_v, .data = result.shim });
    for (result.warnings) |w| std.debug.print("warning: {s}\n", .{w});
    std.debug.print("{s}: {d} function(s) ({d} through the C shim), {d} constant(s), {d} warning(s)\n", .{ out_v, result.n_funcs, result.n_shims, result.n_consts, result.warnings.len });

    // 3) kabuğu derle
    if (result.n_shims > 0 and !no_compile) {
        var cc_argv: std.ArrayListUnmanaged([]const u8) = .empty;
        try cc_argv.appendSlice(a, &.{ cc, "-c", "-fPIC", shim_v, "-o", shim_lib_v, "-I", dirOf(hdr) });
        try cc_argv.appendSlice(a, cpp_flags.items);
        const cr = std.process.run(gpa, io, .{ .argv = cc_argv.items }) catch {
            std.debug.print("could not run '{s}'\n", .{cc});
            return 1;
        };
        defer gpa.free(cr.stdout);
        defer gpa.free(cr.stderr);
        if (cr.term != .exited or cr.term.exited != 0) {
            std.debug.print("compiling the shim failed:\n{s}\n", .{cr.stderr});
            return 1;
        }
        std.debug.print("{s}: compiled\n", .{shim_lib_v});
    } else if (result.n_shims > 0) {
        std.debug.print("compile the shim yourself: {s} -c -fPIC {s} -o {s} -I {s}\n", .{ cc, shim_v, shim_lib_v, dirOf(hdr) });
    }
    return 0;
}

// ------------------------------------------------------------------------------------------------ testler

test "temel işlevler, enum, typedef ve işaretçiler eşlenir" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src =
        \\typedef unsigned int u32_t;
        \\typedef struct foo foo;
        \\typedef enum { RED, GREEN = 5, BLUE } color;
        \\int add(int a, long b);
        \\foo *foo_new(const char *name, size_t n);
        \\void foo_free(foo *f);
        \\color pick(void);
        \\double scale(double x, u32_t k);
        \\const char *foo_name(const foo *f);
    ;
    const out = try generateFromText(a, src, "", .{ .header = "x.h", .lib = "libx", .shim_lib = "x_shim.o", .include_name = "x.h" }, true);
    try std.testing.expect(std.mem.indexOf(u8, out.nox, "extern def add(a: i32, b: i64) -> i32 from \"libx\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.nox, "extern def foo_new(name: str, n: usize) -> ptr from \"libx\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.nox, "extern def foo_free(f: ptr) -> None from \"libx\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.nox, "extern def pick() -> i32 from \"libx\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.nox, "extern def scale(x: float, k: u32) -> float from \"libx\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.nox, "extern def foo_name(f: ptr) -> ptr from \"libx\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.nox, "RED: i32 = i32(0)") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.nox, "GREEN: i32 = i32(5)") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.nox, "BLUE: i32 = i32(6)") != null);
    try std.testing.expectEqual(@as(usize, 6), out.n_funcs);
    try std.testing.expectEqual(@as(usize, 0), out.n_shims);
}

test "satır içi işlev, float ve ayrılmış ad kabuktan geçer; gövdeler atlanır" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src =
        \\typedef struct doc doc;
        \\static inline int doc_len(const doc *d) { int n = 0; while (d) { n++; } return n; }
        \\float halve(float x);
        \\int in(int from, int to);
        \\int ok(int x);
    ;
    const out = try generateFromText(a, src, "", .{ .header = "x.h", .lib = "libx", .shim_lib = "x_shim.o", .include_name = "x.h" }, true);
    try std.testing.expect(std.mem.indexOf(u8, out.nox, "extern def nox_shim_doc_len(d: ptr) -> i32 from \"x_shim.o\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.nox, "def doc_len(d: ptr) -> i32:\n    return nox_shim_doc_len(d)") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.nox, "extern def nox_shim_halve(x: float) -> float") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.nox, "def halve_(x: float) -> float:") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.nox, "def in_(from_: i32, to: i32) -> i32:") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.nox, "extern def ok(x: i32) -> i32 from \"libx\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.shim, "int32_t nox_shim_doc_len(const char *d)") == null);
    try std.testing.expect(std.mem.indexOf(u8, out.shim, "int32_t nox_shim_doc_len(void *d) { return doc_len(d); }") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.shim, "double nox_shim_halve(double x) { return halve(x); }") != null);
    try std.testing.expectEqual(@as(usize, 3), out.n_shims);
}

test "değerle struct, değişken argüman ve long double uyarıyla atlanır; fonksiyon işaretçileri ptr olur" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src =
        \\typedef struct { int x; int y; } vec;
        \\vec vec_add(vec a, vec b);
        \\int logf2(const char *fmt, ...);
        \\long double big(long double x);
        \\typedef int (*cmp_fn)(const void *, const void *);
        \\void sort_it(void *base, int n, cmp_fn cmp);
        \\void apply(int (*cb)(int), int v);
        \\int total(int xs[], int n);
    ;
    const out = try generateFromText(a, src, "", .{ .header = "x.h", .lib = "libx", .shim_lib = "x_shim.o", .include_name = "x.h" }, true);
    try std.testing.expect(std.mem.indexOf(u8, out.nox, "def vec_add_(a: ptr, b: ptr) -> ptr:") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.nox, "logf2") == null);
    try std.testing.expect(std.mem.indexOf(u8, out.nox, "extern def sort_it(base: ptr, n: i32, cmp: ptr) -> None") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.nox, "extern def apply(cb: ptr, v: i32) -> None") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.nox, "extern def total(xs: ptr, n: i32) -> i32") != null);
    try std.testing.expect(out.warnings.len >= 2);
}

test "static const tamsayıları ve #define sabitleri (önek süzgeci) sabit olur" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src =
        \\typedef unsigned int xx_flag;
        \\static const xx_flag XX_READ_NOFLAG = 0;
        \\static const xx_flag XX_READ_STOP = (1 << 1);
        \\static const xx_flag XX_READ_BOTH = XX_READ_STOP | 4;
        \\enum xx_type { XX_NONE = 0, XX_RAW = 1 };
    ;
    const defs =
        \\#define XX_VERSION_MAJOR 0
        \\#define XX_VERSION_HEX ((XX_VERSION_MAJOR << 16) | 0x0a)
        \\#define XX_NAME "xx"
        \\#define XX_FN(x) ((x)+1)
        \\#define OTHER_THING 7
    ;
    const out = try generateFromText(a, src, defs, .{ .header = "x.h", .lib = "libx", .shim_lib = "x_shim.o", .include_name = "x.h", .prefix = "xx_" }, true);
    try std.testing.expect(std.mem.indexOf(u8, out.nox, "XX_READ_NOFLAG: u32 = u32(0)") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.nox, "XX_READ_STOP: u32 = u32(2)") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.nox, "XX_NONE: i32 = i32(0)") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.nox, "XX_VERSION_MAJOR: int = 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.nox, "XX_VERSION_HEX: int = 10") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.nox, "XX_NAME: str = \"xx\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.nox, "XX_FN") == null);
    try std.testing.expect(std.mem.indexOf(u8, out.nox, "OTHER_THING") == null);
}

test "linemarker: yalnızca hedef başlıktaki bildirimler çıkar, sistem tipleri çözülür" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src =
        \\# 1 "/usr/include/sys.h" 1
        \\typedef unsigned long my_size;
        \\int sys_func(int x);
        \\# 5 "/tmp/mylib.h" 2
        \\int my_func(my_size n, uint16_t k);
    ;
    const out = try generateFromText(a, src, "", .{ .header = "/tmp/mylib.h", .lib = "libm", .shim_lib = "s.o", .include_name = "mylib.h" }, false);
    try std.testing.expect(std.mem.indexOf(u8, out.nox, "sys_func") == null);
    try std.testing.expect(std.mem.indexOf(u8, out.nox, "extern def my_func(n: u64, k: u16) -> i32 from \"libm\"") != null);
}

test "struct alanları, değerle struct, global değişkenler ve dizi/bit alanı/adsız sendika erişimcileri" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src =
        \\typedef struct { int x; int y; } vec;
        \\vec vec_add(vec a, vec b);
        \\struct node { int id; const char *name; double w[3]; struct node *next; unsigned flag : 3; union { int i; float f; }; vec pos; const int fixed; };
        \\extern int counter;
        \\extern const char *const version;
        \\extern double table[4];
    ;
    const out = try generateFromText(a, src, "", .{ .header = "x.h", .lib = "libx", .shim_lib = "x_shim.o", .include_name = "x.h" }, true);
    const has = struct {
        fn f(hay: []const u8, needle: []const u8) bool {
            return std.mem.indexOf(u8, hay, needle) != null;
        }
    }.f;
    // değerle struct: işaretçi alan/dönen sarmalayıcı + yardımcılar
    try std.testing.expect(has(out.nox, "def vec_add_(a: ptr, b: ptr) -> ptr:\n    nox_ret: ptr = vec_new()"));
    try std.testing.expect(has(out.shim, "void nox_shim_vec_add(const void *a, const void *b, void *nox_ret) { *(vec *)nox_ret = vec_add(*(vec *)a, *(vec *)b); }"));
    try std.testing.expect(has(out.nox, "extern def vec_new() -> ptr"));
    try std.testing.expect(has(out.nox, "extern def vec_get_x(p: ptr) -> i32"));
    try std.testing.expect(has(out.nox, "extern def vec_set_y(p: ptr, v: i32) -> None"));
    // alanlar
    try std.testing.expect(has(out.nox, "extern def node_get_id(p: ptr) -> i32"));
    try std.testing.expect(has(out.nox, "extern def node_get_name(p: ptr) -> ptr"));
    try std.testing.expect(has(out.nox, "extern def node_get_w(p: ptr, i: usize) -> float"));
    try std.testing.expect(has(out.nox, "extern def node_w_ptr(p: ptr) -> ptr"));
    try std.testing.expect(has(out.nox, "node_w_LEN: int = 3"));
    try std.testing.expect(has(out.nox, "extern def node_set_flag(p: ptr, v: u32) -> None"));
    try std.testing.expect(has(out.shim, "((struct node *)p)->flag = v;"));
    try std.testing.expect(has(out.nox, "extern def node_get_i(p: ptr) -> i32")); // adsız sendikanın alanı
    try std.testing.expect(has(out.nox, "extern def node_get_pos(p: ptr) -> ptr")); // iç içe struct: adres
    try std.testing.expect(!has(out.nox, "node_set_fixed")); // const alan: yazıcı yok
    // global değişkenler
    try std.testing.expect(has(out.nox, "extern def counter_get() -> i32"));
    try std.testing.expect(has(out.nox, "extern def counter_set(v: i32) -> None"));
    try std.testing.expect(has(out.nox, "extern def version_get() -> ptr"));
    try std.testing.expect(!has(out.nox, "version_set"));
    try std.testing.expect(has(out.nox, "extern def table_ptr() -> ptr"));
}

test "hedef ABI: __SIZEOF_LONG__=4 ve __CHAR_UNSIGNED__ tür eşlemesini değiştirir" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const defs =
        \\#define __SIZEOF_LONG__ 4
        \\#define __CHAR_UNSIGNED__ 1
    ;
    const out = try generateFromText(a, "long f(long x, char c, long long y);", defs, .{ .header = "x.h", .lib = "libx", .shim_lib = "s.o", .include_name = "x.h" }, true);
    try std.testing.expect(std.mem.indexOf(u8, out.nox, "extern def f(x: i32, c: u8, y: i64) -> i32") != null);
}
