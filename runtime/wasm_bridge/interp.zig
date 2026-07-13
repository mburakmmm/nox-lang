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

fn readVarU32At(code: []const u8, pos: *usize) !u32 {
    var result: u32 = 0;
    var shift: u5 = 0;
    while (true) {
        if (pos.* >= code.len) return error.UnexpectedEof;
        const b = code[pos.*];
        pos.* += 1;
        result |= @as(u32, b & 0x7f) << shift;
        if (b & 0x80 == 0) break;
        shift += 7;
    }
    return result;
}

fn readVarI32At(code: []const u8, pos: *usize) !i32 {
    var result: i32 = 0;
    var shift: u5 = 0;
    var b: u8 = 0;
    while (true) {
        if (pos.* >= code.len) return error.UnexpectedEof;
        b = code[pos.*];
        pos.* += 1;
        result |= @as(i32, b & 0x7f) << shift;
        shift += 7;
        if (b & 0x80 == 0) break;
    }
    if (shift < 32 and (b & 0x40) != 0) {
        result |= @as(i32, -1) << shift;
    }
    return result;
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
