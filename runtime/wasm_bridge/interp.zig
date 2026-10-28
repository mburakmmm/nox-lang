//! Nox WASM köprüsü — yorumlayıcı (AGENTS.md §11).
//!
//! Minimal bir yığın makinesi: yalnızca DÜZ ÇİZGİ (dallanmasız) kod
//! yürütür — `block`/`loop`/`if` gibi kontrol akışı talimatları
//! desteklenmiyor (bkz. `execCode`, `else => error.UnsupportedInstruction`).
//! Desteklenen talimat kümesi: `unreachable`, `nop`, `end`/`return`,
//! `call`, `local.get`/`set`/`tee`, `i32.const`, `i32.add`/`sub`/`mul`.
//! Yalnızca `i32` parametre/dönüş tipleri desteklenir.
//!
//! **Handle birleştirmesi (AGENTS.md §11: "iki ayrı FFI mekanizması yoktur,
//! tek bir handle soyutlaması vardır"):** `callExport`, argümanları ve
//! dönüş değerini `runtime/hpy_bridge/context.zig`nin AYNI `HPy`/`Obj`
//! temsiliyle alıp verir — Tier 0'ın HPy köprüsüyle TAM OLARAK aynı
//! opaque handle sistemi, ayrı bir WASM-özel değer tipi YOKTUR.

const std = @import("std");
const module_mod = @import("module.zig");
const Module = module_mod.Module;
const hpy_context = @import("hpy_bridge").context;
const HPy = hpy_context.HPy;
const HPyContext = hpy_context.HPyContext;

const MAX_STACK = 64;
const MAX_CALL_ARGS = 8;

/// `callFunc`/`execCode` karşılıklı özyinelemelidir (`call` talimatı) — Zig
/// bunun için çıkarımsal (inferred) hata kümesini çözemez ("dependency
/// loop"), bu yüzden AÇIK bir hata kümesi gerekir.
pub const InterpError = error{
    OutOfMemory,
    TypeMismatch,
    UnsupportedInstruction,
    UnexpectedEof,
    Trap,
    StackUnderflow,
    StackOverflow,
    ExportNotFound,
    TooManyArgs,
};

/// Faz X.1 (bkz. `module.zig`nin `readVarU32`sinin AYNI belge notu, bkz.
/// docs/uretim-hazirlik-analizi.md P1 bulgusu #12): bayt-kod akışındaki
/// (`call`/`local.*` indeksleri) LEB128 okuyucu, AYNI "5 baytla SINIRLA +
/// u64 biriktir + u32 aralığına SIĞMA doğrula" düzeltmesini taşır — ESKİ
/// `shift: u5` tasarımı, 6+ devam baytlı bozuk bayt kodunda TAŞMA
/// PANİĞİNE (DoS) yol açardı. `error.Trap`, WASM'ın KENDİ "çalışma zamanı
/// hatası" terminolojisiyle TUTARLI (bkz. `InterpError`'ın MEVCUT üyesi).
fn readVarU32At(code: []const u8, pos: *usize) !u32 {
    var result: u64 = 0;
    var shift: u6 = 0;
    var nbytes: u8 = 0;
    while (true) {
        if (nbytes >= 5) return error.Trap;
        if (pos.* >= code.len) return error.UnexpectedEof;
        const b = code[pos.*];
        pos.* += 1;
        nbytes += 1;
        result |= @as(u64, b & 0x7f) << shift;
        if (b & 0x80 == 0) break;
        shift += 7;
    }
    if (result > std.math.maxInt(u32)) return error.Trap;
    return @intCast(result);
}

fn readVarI32At(code: []const u8, pos: *usize) !i32 {
    var result: i64 = 0;
    var shift: u6 = 0;
    var nbytes: u8 = 0;
    var b: u8 = 0;
    while (true) {
        if (nbytes >= 5) return error.Trap;
        if (pos.* >= code.len) return error.UnexpectedEof;
        b = code[pos.*];
        pos.* += 1;
        nbytes += 1;
        result |= @as(i64, b & 0x7f) << shift;
        shift += 7;
        if (b & 0x80 == 0) break;
    }
    if (shift < 64 and (b & 0x40) != 0) {
        result |= @as(i64, -1) << shift;
    }
    if (result < std.math.minInt(i32) or result > std.math.maxInt(i32)) return error.Trap;
    return @intCast(result);
}

/// `func_index`i, verilen `args` (yalnızca `i32`) ile çalıştırır. Fonksiyon
/// bir değer döndürüyorsa onu döner, `void` ise `null`.
pub fn callFunc(allocator: std.mem.Allocator, module: *const Module, func_index: u32, args: []const i32) InterpError!?i32 {
    const ftype = module.typeOf(func_index);
    if (ftype.params.len != args.len) return error.TypeMismatch;
    for (ftype.params) |p| {
        if (p != .i32) return error.UnsupportedInstruction; // yalnızca i32 (bkz. modül üstü not)
    }

    const body = module.bodies[func_index];
    const nlocals = ftype.params.len + body.locals.len;
    const locals = try allocator.alloc(i32, nlocals);
    defer allocator.free(locals);
    @memset(locals, 0);
    for (args, 0..) |a, i| locals[i] = a;

    const result = try execCode(allocator, module, body.code, locals);
    if (ftype.results.len == 0) return null;
    return result orelse error.StackUnderflow;
}

fn execCode(allocator: std.mem.Allocator, module: *const Module, code: []const u8, locals: []i32) InterpError!?i32 {
    var stack: [MAX_STACK]i32 = undefined;
    var sp: usize = 0;
    var pos: usize = 0;

    while (pos < code.len) {
        const op = code[pos];
        pos += 1;
        switch (op) {
            0x00 => return error.Trap, // unreachable
            0x01 => {}, // nop
            0x0b, 0x0f => break, // end / return — düz çizgi kod için eşdeğer
            0x10 => { // call
                const callee_idx = try readVarU32At(code, &pos);
                const callee_type = module.typeOf(callee_idx);
                const nargs = callee_type.params.len;
                if (nargs > sp or nargs > MAX_CALL_ARGS) return error.StackUnderflow;
                var call_args: [MAX_CALL_ARGS]i32 = undefined;
                var k: usize = 0;
                while (k < nargs) : (k += 1) call_args[k] = stack[sp - nargs + k];
                sp -= nargs;
                if (try callFunc(allocator, module, callee_idx, call_args[0..nargs])) |r| {
                    if (sp >= MAX_STACK) return error.StackOverflow;
                    stack[sp] = r;
                    sp += 1;
                }
            },
            0x20 => { // local.get
                const idx = try readVarU32At(code, &pos);
                if (idx >= locals.len) return error.UnexpectedEof;
                if (sp >= MAX_STACK) return error.StackOverflow;
                stack[sp] = locals[idx];
                sp += 1;
            },
            0x21 => { // local.set
                const idx = try readVarU32At(code, &pos);
                if (idx >= locals.len) return error.UnexpectedEof;
                if (sp == 0) return error.StackUnderflow;
                sp -= 1;
                locals[idx] = stack[sp];
            },
            0x22 => { // local.tee
                const idx = try readVarU32At(code, &pos);
                if (idx >= locals.len) return error.UnexpectedEof;
                if (sp == 0) return error.StackUnderflow;
                locals[idx] = stack[sp - 1];
            },
            0x41 => { // i32.const
                const v = try readVarI32At(code, &pos);
                if (sp >= MAX_STACK) return error.StackOverflow;
                stack[sp] = v;
                sp += 1;
            },
            0x6a => { // i32.add
                if (sp < 2) return error.StackUnderflow;
                stack[sp - 2] = stack[sp - 2] +% stack[sp - 1];
                sp -= 1;
            },
            0x6b => { // i32.sub
                if (sp < 2) return error.StackUnderflow;
                stack[sp - 2] = stack[sp - 2] -% stack[sp - 1];
                sp -= 1;
            },
            0x6c => { // i32.mul
                if (sp < 2) return error.StackUnderflow;
                stack[sp - 2] = stack[sp - 2] *% stack[sp - 1];
                sp -= 1;
            },
            0x1a => { // drop
                if (sp < 1) return error.StackUnderflow;
                sp -= 1;
            },
            0x1b => { // select: [a, b, c] -> c != 0 ? a : b
                if (sp < 3) return error.StackUnderflow;
                const chosen = if (stack[sp - 1] != 0) stack[sp - 3] else stack[sp - 2];
                sp -= 2;
                stack[sp - 1] = chosen;
            },
            0x45 => { // i32.eqz
                if (sp < 1) return error.StackUnderflow;
                stack[sp - 1] = @intFromBool(stack[sp - 1] == 0);
            },
            0x46...0x4f => { // i32 karşılaştırmaları: eq ne lt_s lt_u gt_s gt_u le_s le_u ge_s ge_u
                if (sp < 2) return error.StackUnderflow;
                const a = stack[sp - 2];
                const b = stack[sp - 1];
                const ua: u32 = @bitCast(a);
                const ub: u32 = @bitCast(b);
                const r = switch (op) {
                    0x46 => a == b,
                    0x47 => a != b,
                    0x48 => a < b,
                    0x49 => ua < ub,
                    0x4a => a > b,
                    0x4b => ua > ub,
                    0x4c => a <= b,
                    0x4d => ua <= ub,
                    0x4e => a >= b,
                    else => ua >= ub,
                };
                sp -= 1;
                stack[sp - 1] = @intFromBool(r);
            },
            0x6d...0x70 => { // div_s div_u rem_s rem_u: sıfıra bölme ve INT_MIN / -1 taşması trap'tir
                if (sp < 2) return error.StackUnderflow;
                const a = stack[sp - 2];
                const b = stack[sp - 1];
                if (b == 0) return error.Trap;
                const ua: u32 = @bitCast(a);
                const ub: u32 = @bitCast(b);
                const r: i32 = switch (op) {
                    0x6d => blk: {
                        if (a == std.math.minInt(i32) and b == -1) return error.Trap;
                        break :blk @divTrunc(a, b);
                    },
                    0x6e => @bitCast(ua / ub),
                    0x6f => if (b == -1) 0 else @rem(a, b), // INT_MIN rem -1 sonucu 0'dır (trap DEĞİL)
                    else => @bitCast(ua % ub),
                };
                sp -= 1;
                stack[sp - 1] = r;
            },
            0x71...0x76 => { // and or xor shl shr_s shr_u (kaydırma sayısı mod 32)
                if (sp < 2) return error.StackUnderflow;
                const a = stack[sp - 2];
                const b = stack[sp - 1];
                const ua: u32 = @bitCast(a);
                const sh: u5 = @truncate(@as(u32, @bitCast(b)));
                const r: i32 = switch (op) {
                    0x71 => a & b,
                    0x72 => a | b,
                    0x73 => a ^ b,
                    0x74 => @bitCast(ua << sh),
                    0x75 => a >> sh,
                    else => @bitCast(ua >> sh),
                };
                sp -= 1;
                stack[sp - 1] = r;
            },
            else => return error.UnsupportedInstruction,
        }
    }

    if (sp == 0) return null;
    return stack[sp - 1];
}

/// `module`nin `name` adında export edilmiş bir fonksiyonunu çağırır.
/// Argümanlar ve dönüş değeri, `hpy_bridge/context.zig`nin AYNI `HPy`
/// handle sistemiyle alınıp verilir (bkz. modül üstü not).
pub fn callExport(allocator: std.mem.Allocator, ctx: *HPyContext, module: *const Module, name: []const u8, args: []const HPy) InterpError!HPy {
    const func_index = module.findExportedFunc(name) orelse return error.ExportNotFound;

    var i32_args: [MAX_CALL_ARGS]i32 = undefined;
    if (args.len > MAX_CALL_ARGS) return error.TooManyArgs;
    for (args, 0..) |a, i| {
        i32_args[i] = @truncate(ctx.ctx_Long_AsInt64_t.?(ctx, a));
    }

    const result = try callFunc(allocator, module, func_index, i32_args[0..args.len]);
    const r = result orelse return hpy_context.HPy_NULL;
    return ctx.ctx_Long_FromInt64_t.?(ctx, r);
}

test "callFunc: gerçek zig-derlenmiş add_one modülünü çalıştırır" {
    const bytes = "\x00asm\x01\x00\x00\x00\x01\x06\x01\x60\x01\x7f\x01\x7f\x03\x02\x01\x00\x04\x05\x01\x70\x01\x01\x01\x05\x03\x01\x00\x10\x06\x09\x01\x7f\x01\x41\x80\x80\xc0\x00\x0b\x07\x14\x02\x06memory\x02\x00\x07add_one\x00\x00\x0a\x09\x01\x07\x00\x20\x00\x41\x01\x6a\x0b";
    var mod = try module_mod.parse(std.testing.allocator, bytes);
    defer mod.deinit();

    const idx = mod.findExportedFunc("add_one").?;
    const result = try callFunc(std.testing.allocator, &mod, idx, &.{41});
    try std.testing.expectEqual(@as(i32, 42), result.?);
}

test "callExport: HPy handle sistemi üzerinden çağrı" {
    const bytes = "\x00asm\x01\x00\x00\x00\x01\x06\x01\x60\x01\x7f\x01\x7f\x03\x02\x01\x00\x04\x05\x01\x70\x01\x01\x01\x05\x03\x01\x00\x10\x06\x09\x01\x7f\x01\x41\x80\x80\xc0\x00\x0b\x07\x14\x02\x06memory\x02\x00\x07add_one\x00\x00\x0a\x09\x01\x07\x00\x20\x00\x41\x01\x6a\x0b";
    var mod = try module_mod.parse(std.testing.allocator, bytes);
    defer mod.deinit();

    const ctx = try hpy_context.createContext(std.testing.allocator);
    defer hpy_context.destroyContext(std.testing.allocator, ctx);

    const arg = ctx.ctx_Long_FromInt64_t.?(ctx, 41);
    defer ctx.ctx_Close.?(ctx, arg);

    const result = try callExport(std.testing.allocator, ctx, &mod, "add_one", &.{arg});
    defer ctx.ctx_Close.?(ctx, result);

    try std.testing.expectEqual(@as(i64, 42), ctx.ctx_Long_AsInt64_t.?(ctx, result));
}

test "readVarU32At/readVarI32At: kanonik değerler doğru çözülür" {
    var pos: usize = 0;
    const bytes1 = &[_]u8{ 0xac, 0x02 };
    try std.testing.expectEqual(@as(u32, 300), try readVarU32At(bytes1, &pos));

    pos = 0;
    const bytes2 = &[_]u8{ 0x80, 0x7f };
    try std.testing.expectEqual(@as(i32, -128), try readVarI32At(bytes2, &pos));
}

test "readVarU32At/readVarI32At: Faz X.1 — 6+ devam baytı taşma sınırına takılır" {
    // `module.zig`nin `readVarU32`sinin AYNI Faz X.1 hatası — burada bayt-
    // kod akışında (call/local.* indeksleri, i32.const) YÜRÜTME sırasında
    // ortaya çıkan hali (bkz. modül üstü not, `error.Trap`).
    var pos1: usize = 0;
    const bytes1 = &[_]u8{ 0x80, 0x80, 0x80, 0x80, 0x80, 0x00 };
    try std.testing.expectError(error.Trap, readVarU32At(bytes1, &pos1));

    var pos2: usize = 0;
    try std.testing.expectError(error.Trap, readVarI32At(bytes1, &pos2));
}

fn runOps(code: []const u8, locals: []i32) InterpError!?i32 {
    const m: Module = .{ .allocator = std.testing.allocator, .types = &.{}, .func_type_indices = &.{}, .exports = &.{}, .bodies = &.{} };
    return execCode(std.testing.allocator, &m, code, locals);
}

test "i32 sayısal komutlar: karşılaştırma, bölme/kalan, bit işlemleri, kaydırma, select, drop" {
    // 7 / 2 = 3, -7 / 2 = -3 (sıfıra doğru), 7 rem -2 = 1
    try std.testing.expectEqual(@as(?i32, 3), try runOps(&.{ 0x41, 7, 0x41, 2, 0x6d, 0x0b }, &.{}));
    try std.testing.expectEqual(@as(?i32, -3), try runOps(&.{ 0x41, 0x79, 0x41, 2, 0x6d, 0x0b }, &.{}));
    try std.testing.expectEqual(@as(?i32, 1), try runOps(&.{ 0x41, 7, 0x41, 0x7e, 0x6f, 0x0b }, &.{}));
    // karşılaştırma: -1 < 1 işaretli doğru, işaretsiz yanlış
    try std.testing.expectEqual(@as(?i32, 1), try runOps(&.{ 0x41, 0x7f, 0x41, 1, 0x48, 0x0b }, &.{}));
    try std.testing.expectEqual(@as(?i32, 0), try runOps(&.{ 0x41, 0x7f, 0x41, 1, 0x49, 0x0b }, &.{}));
    try std.testing.expectEqual(@as(?i32, 1), try runOps(&.{ 0x41, 0, 0x45, 0x0b }, &.{})); // eqz
    // bit işlemleri ve kaydırma: 12 & 10 = 8, 12 | 10 = 14, 12 ^ 10 = 6, 1 << 33 = 2 (mod 32), -8 >> 1 = -4, -8 >>> 28 = 15
    try std.testing.expectEqual(@as(?i32, 8), try runOps(&.{ 0x41, 12, 0x41, 10, 0x71, 0x0b }, &.{}));
    try std.testing.expectEqual(@as(?i32, 14), try runOps(&.{ 0x41, 12, 0x41, 10, 0x72, 0x0b }, &.{}));
    try std.testing.expectEqual(@as(?i32, 6), try runOps(&.{ 0x41, 12, 0x41, 10, 0x73, 0x0b }, &.{}));
    try std.testing.expectEqual(@as(?i32, 2), try runOps(&.{ 0x41, 1, 0x41, 33, 0x74, 0x0b }, &.{}));
    try std.testing.expectEqual(@as(?i32, -4), try runOps(&.{ 0x41, 0x78, 0x41, 1, 0x75, 0x0b }, &.{}));
    try std.testing.expectEqual(@as(?i32, 15), try runOps(&.{ 0x41, 0x78, 0x41, 28, 0x76, 0x0b }, &.{}));
    // select ve drop: [10, 20, 1] -> 10; [10, 20, 0] -> 20; drop atılan değeri bırakır
    try std.testing.expectEqual(@as(?i32, 10), try runOps(&.{ 0x41, 10, 0x41, 20, 0x41, 1, 0x1b, 0x0b }, &.{}));
    try std.testing.expectEqual(@as(?i32, 20), try runOps(&.{ 0x41, 10, 0x41, 20, 0x41, 0, 0x1b, 0x0b }, &.{}));
    try std.testing.expectEqual(@as(?i32, 5), try runOps(&.{ 0x41, 5, 0x41, 9, 0x1a, 0x0b }, &.{}));
}

test "i32 bölme: sıfıra bölme ve INT_MIN / -1 trap, yığın yetersizliği hata verir" {
    try std.testing.expectError(error.Trap, runOps(&.{ 0x41, 1, 0x41, 0, 0x6d, 0x0b }, &.{}));
    try std.testing.expectError(error.Trap, runOps(&.{ 0x41, 1, 0x41, 0, 0x6f, 0x0b }, &.{}));
    // INT_MIN = -2147483648 (LEB128 80 80 80 80 78), -1
    try std.testing.expectError(error.Trap, runOps(&.{ 0x41, 0x80, 0x80, 0x80, 0x80, 0x78, 0x41, 0x7f, 0x6d, 0x0b }, &.{}));
    try std.testing.expectEqual(@as(?i32, 0), try runOps(&.{ 0x41, 0x80, 0x80, 0x80, 0x80, 0x78, 0x41, 0x7f, 0x6f, 0x0b }, &.{}));
    try std.testing.expectError(error.StackUnderflow, runOps(&.{ 0x41, 1, 0x71 }, &.{})); // 0x71 and, tek işlenen
    try std.testing.expectError(error.StackUnderflow, runOps(&.{0x1b}, &.{}));
}
