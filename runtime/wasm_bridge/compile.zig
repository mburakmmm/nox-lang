//! Nox WASM köprüsü — doğrulayıcı + derleyici (AGENTS.md §11).
//!
//! Her işlev gövdesi, WASM spesifikasyonunun doğrulama algoritmasıyla (tipli operand yığını + denetim yığını, "unreachable" çok-biçimli yığın)
//! tek geçişte doğrulanırken düz bir `Instr` dizisine derlenir: bloklar/döngüler/`if` komut üretmez, dallanma hedefleri (`pc`), dallanmada atılacak
//! operand yüksekliği ve taşınacak değer sayısı derleme zamanında çözülür. Böylece yorumlayıcı (`interp.zig`) ne `end` aramalarına ne etiket yığınına
//! ne de çalışma zamanı tip denetimine ihtiyaç duyar; bozuk bir modül çalıştırılmadan önce `error.InvalidModule` ile reddedilir.
//!
//! Desteklenenler: MVP + çok değerli dönüş/blok tipleri + sign-extension + doymalı dönüşümler (0xFC 0-7) + bulk-memory (0xFC 8-17) + reference types
//! (`ref.*`, `table.get/set`, tipli `select`). SIMD (0xFD) ve threads (0xFE) desteklenmez.

const std = @import("std");
const mod = @import("module.zig");
const ValType = mod.ValType;
const Module = mod.Module;
const Reader = mod.Reader;

pub const Instr = extern struct {
    op: u16,
    arity: u16 = 0,
    a: u32 = 0,
    b: u64 = 0,
};

pub const BrTarget = extern struct { pc: u32, height: u32, arity: u32 };

/// Derlenmiş işlev. Çerçeve düzeni (değer yığınında): `[parametreler][yerel değişkenler][operandlar]`.
pub const FuncCode = struct {
    instrs: []Instr,
    brt: []BrTarget,
    num_params: u32,
    num_results: u32,
    /// Parametreler DAHİL toplam yerel sayısı.
    num_locals: u32,
    /// Operand yığınının ulaşabileceği azami yükseklik.
    max_stack: u32,
};

/// Yorumlayıcının iç operasyon kodları: tek baytlık WASM opcode'ları aynen; `0xFC xx` -> `0x100 + xx`.
pub const OP_IF: u16 = 0x04; // koşul 0 ise `a`ya atla
pub const OP_JUMP: u16 = 0x05; // `else` kolundan blok sonuna koşulsuz atlama
pub const OP_BR: u16 = 0x0c;
pub const OP_BR_IF: u16 = 0x0d;
pub const OP_BR_TABLE: u16 = 0x0e; // `a` = brt başlangıcı, `b` = hedef sayısı (varsayılan hedef en sondadır)
pub const OP_RETURN: u16 = 0x0f;
pub const OP_CALL: u16 = 0x10;
pub const OP_CALL_INDIRECT: u16 = 0x11; // `a` = tür indeksi, `b` = tablo indeksi
pub const OP_FC: u16 = 0x100;

pub const CompileError = error{ InvalidModule, OutOfMemory };

const one_i32 = [_]ValType{.i32};
const one_i64 = [_]ValType{.i64};
const one_f32 = [_]ValType{.f32};
const one_f64 = [_]ValType{.f64};
const one_funcref = [_]ValType{.funcref};
const one_externref = [_]ValType{.externref};
const empty_types = [_]ValType{};

fn oneOf(t: ValType) []const ValType {
    return switch (t) {
        .i32 => &one_i32,
        .i64 => &one_i64,
        .f32 => &one_f32,
        .f64 => &one_f64,
        .funcref => &one_funcref,
        .externref => &one_externref,
    };
}

const Sig = struct { in: [2]ValType, n: u2, out: ValType };

fn un(i: ValType, o: ValType) Sig {
    return .{ .in = .{ i, i }, .n = 1, .out = o };
}
fn bin(i: ValType, o: ValType) Sig {
    return .{ .in = .{ i, i }, .n = 2, .out = o };
}

/// Sayısal opcode'un (0x45..0xc4) operand/sonuç tipleri.
fn numSig(op: u8) ?Sig {
    return switch (op) {
        0x45 => un(.i32, .i32),
        0x46...0x4f => bin(.i32, .i32),
        0x50 => un(.i64, .i32),
        0x51...0x5a => bin(.i64, .i32),
        0x5b...0x60 => bin(.f32, .i32),
        0x61...0x66 => bin(.f64, .i32),
        0x67...0x69 => un(.i32, .i32),
        0x6a...0x78 => bin(.i32, .i32),
        0x79...0x7b => un(.i64, .i64),
        0x7c...0x8a => bin(.i64, .i64),
        0x8b...0x91 => un(.f32, .f32),
        0x92...0x98 => bin(.f32, .f32),
        0x99...0x9f => un(.f64, .f64),
        0xa0...0xa6 => bin(.f64, .f64),
        0xa7 => un(.i64, .i32),
        0xa8, 0xa9 => un(.f32, .i32),
        0xaa, 0xab => un(.f64, .i32),
        0xac, 0xad => un(.i32, .i64),
        0xae, 0xaf => un(.f32, .i64),
        0xb0, 0xb1 => un(.f64, .i64),
        0xb2, 0xb3 => un(.i32, .f32),
        0xb4, 0xb5 => un(.i64, .f32),
        0xb6 => un(.f64, .f32),
        0xb7, 0xb8 => un(.i32, .f64),
        0xb9, 0xba => un(.i64, .f64),
        0xbb => un(.f32, .f64),
        0xbc => un(.f32, .i32),
        0xbd => un(.f64, .i64),
        0xbe => un(.i32, .f32),
        0xbf => un(.i64, .f64),
        0xc0, 0xc1 => un(.i32, .i32),
        0xc2...0xc4 => un(.i64, .i64),
        else => null,
    };
}

fn satSig(sub: u32) ?Sig {
    return switch (sub) {
        0, 1 => un(.f32, .i32),
        2, 3 => un(.f64, .i32),
        4, 5 => un(.f32, .i64),
        6, 7 => un(.f64, .i64),
        else => null,
    };
}

/// Bellek komutunun (tür, boyut) bilgisi: yükleme için sonuç tipi, depolama için operand tipi ve doğal hizalama (log2).
const MemOp = struct { ty: ValType, align_log2: u32, is_store: bool };

fn memOp(op: u8) ?MemOp {
    return switch (op) {
        0x28 => .{ .ty = .i32, .align_log2 = 2, .is_store = false },
        0x29 => .{ .ty = .i64, .align_log2 = 3, .is_store = false },
        0x2a => .{ .ty = .f32, .align_log2 = 2, .is_store = false },
        0x2b => .{ .ty = .f64, .align_log2 = 3, .is_store = false },
        0x2c, 0x2d => .{ .ty = .i32, .align_log2 = 0, .is_store = false },
        0x2e, 0x2f => .{ .ty = .i32, .align_log2 = 1, .is_store = false },
        0x30, 0x31 => .{ .ty = .i64, .align_log2 = 0, .is_store = false },
        0x32, 0x33 => .{ .ty = .i64, .align_log2 = 1, .is_store = false },
        0x34, 0x35 => .{ .ty = .i64, .align_log2 = 2, .is_store = false },
        0x36 => .{ .ty = .i32, .align_log2 = 2, .is_store = true },
        0x37 => .{ .ty = .i64, .align_log2 = 3, .is_store = true },
        0x38 => .{ .ty = .f32, .align_log2 = 2, .is_store = true },
        0x39 => .{ .ty = .f64, .align_log2 = 3, .is_store = true },
        0x3a => .{ .ty = .i32, .align_log2 = 0, .is_store = true },
        0x3b => .{ .ty = .i32, .align_log2 = 1, .is_store = true },
        0x3c => .{ .ty = .i64, .align_log2 = 0, .is_store = true },
        0x3d => .{ .ty = .i64, .align_log2 = 1, .is_store = true },
        0x3e => .{ .ty = .i64, .align_log2 = 2, .is_store = true },
        else => null,
    };
}

const CtlKind = enum { func, block, loop, @"if", @"else" };

const Ctl = struct {
    kind: CtlKind,
    params: []const ValType,
    results: []const ValType,
    height: u32,
    unreachable_: bool = false,
    start_pc: u32 = 0,
    if_pc: u32 = 0,

    fn labelTypes(self: *const Ctl) []const ValType {
        return if (self.kind == .loop) self.params else self.results;
    }
};

const Fixup = struct { in_pool: bool, idx: u32, ctl: u32 };

const Compiler = struct {
    a: std.mem.Allocator,
    m: *const Module,
    local_types: []const ValType,
    ftype: mod.FuncType,
    instrs: std.ArrayList(Instr) = .empty,
    brt: std.ArrayList(BrTarget) = .empty,
    vals: std.ArrayList(?ValType) = .empty,
    ctls: std.ArrayList(Ctl) = .empty,
    fixups: std.ArrayList(Fixup) = .empty,
    max_height: u32 = 0,

    fn deinit(self: *Compiler) void {
        self.instrs.deinit(self.a);
        self.brt.deinit(self.a);
        self.vals.deinit(self.a);
        self.ctls.deinit(self.a);
        self.fixups.deinit(self.a);
    }

    fn emit(self: *Compiler, i: Instr) !u32 {
        const pc: u32 = @intCast(self.instrs.items.len);
        try self.instrs.append(self.a, i);
        return pc;
    }

    fn top(self: *Compiler) *Ctl {
        return &self.ctls.items[self.ctls.items.len - 1];
    }

    fn push(self: *Compiler, t: ?ValType) !void {
        try self.vals.append(self.a, t);
        if (self.vals.items.len > self.max_height) self.max_height = @intCast(self.vals.items.len);
    }

    fn pushAll(self: *Compiler, ts: []const ValType) !void {
        for (ts) |t| try self.push(t);
    }

    fn pop(self: *Compiler) !?ValType {
        const c = self.top();
        if (self.vals.items.len == c.height) {
            if (c.unreachable_) return null;
            return error.InvalidModule;
        }
        return self.vals.pop().?;
    }

    fn popExpect(self: *Compiler, want: ValType) !void {
        const got = try self.pop();
        if (got) |g| if (g != want) return error.InvalidModule;
    }

    fn popAll(self: *Compiler, ts: []const ValType) !void {
        var i = ts.len;
        while (i > 0) {
            i -= 1;
            try self.popExpect(ts[i]);
        }
    }

    fn setUnreachable(self: *Compiler) void {
        const c = self.top();
        self.vals.shrinkRetainingCapacity(c.height);
        c.unreachable_ = true;
    }

    fn pushCtl(self: *Compiler, kind: CtlKind, params: []const ValType, results: []const ValType) !void {
        try self.ctls.append(self.a, .{
            .kind = kind,
            .params = params,
            .results = results,
            .height = @intCast(self.vals.items.len),
            .start_pc = @intCast(self.instrs.items.len),
        });
        try self.pushAll(params);
    }

    fn patch(self: *Compiler, f: Fixup, pc: u32) void {
        if (f.in_pool) self.brt.items[f.idx].pc = pc else self.instrs.items[f.idx].a = pc;
    }

    fn blockType(self: *Compiler, r: *Reader) !struct { params: []const ValType, results: []const ValType } {
        const v = try r.readVarS33();
        if (v >= 0) {
            if (v >= self.m.types.len) return error.InvalidModule;
            const t = self.m.types[@intCast(v)];
            return .{ .params = t.params, .results = t.results };
        }
        if (v == -64) return .{ .params = &empty_types, .results = &empty_types };
        const vt: ValType = switch (v) {
            -1 => .i32,
            -2 => .i64,
            -3 => .f32,
            -4 => .f64,
            -16 => .funcref,
            -17 => .externref,
            else => return error.InvalidModule,
        };
        return .{ .params = &empty_types, .results = oneOf(vt) };
    }

    /// `depth` etiketine dallanma için hedef bilgisi; `fixup_idx` hedef `pc` henüz bilinmiyorsa (döngü değilse) yamalanacak yer.
    fn labelFor(self: *Compiler, depth: u32) !*Ctl {
        if (depth >= self.ctls.items.len) return error.InvalidModule;
        return &self.ctls.items[self.ctls.items.len - 1 - depth];
    }

    fn ctlIndex(self: *Compiler, c: *const Ctl) u32 {
        return @intCast(c - self.ctls.items.ptr);
    }

    fn localType(self: *Compiler, idx: u32) !ValType {
        if (idx >= self.local_types.len) return error.InvalidModule;
        return self.local_types[idx];
    }

    fn run(self: *Compiler, code: []const u8) !void {
        var r: Reader = .{ .bytes = code };
        try self.pushCtl(.func, &empty_types, self.ftype.results);
        // pushCtl `start_pc` = 0 ve params boş; işlev çerçevesi bir "block"tur.
        while (self.ctls.items.len > 0) {
            if (r.atEnd()) return error.InvalidModule;
            const op = try r.byte();
            try self.step(&r, op);
        }
        if (!r.atEnd()) return error.InvalidModule;
    }

    fn step(self: *Compiler, r: *Reader, op: u8) !void {
        if (numSig(op)) |s| {
            var i: u2 = s.n;
            while (i > 0) {
                i -= 1;
                try self.popExpect(s.in[i]);
            }
            try self.push(s.out);
            _ = try self.emit(.{ .op = op });
            return;
        }
        if (memOp(op)) |mo| {
            if (self.m.mems.len == 0) return error.InvalidModule;
            const al = try r.readVarU32();
            const off = try r.readVarU32();
            if (al > mo.align_log2) return error.InvalidModule;
            if (mo.is_store) {
                try self.popExpect(mo.ty);
                try self.popExpect(.i32);
            } else {
                try self.popExpect(.i32);
                try self.push(mo.ty);
            }
            _ = try self.emit(.{ .op = op, .a = off });
            return;
        }
        switch (op) {
            0x00 => { // unreachable
                _ = try self.emit(.{ .op = 0x00 });
                self.setUnreachable();
            },
            0x01 => {}, // nop
            0x02, 0x03 => { // block / loop
                const bt = try self.blockType(r);
                try self.popAll(bt.params);
                try self.pushCtl(if (op == 0x02) .block else .loop, bt.params, bt.results);
            },
            0x04 => { // if
                const bt = try self.blockType(r);
                try self.popExpect(.i32);
                try self.popAll(bt.params);
                const pc = try self.emit(.{ .op = OP_IF });
                try self.pushCtl(.@"if", bt.params, bt.results);
                self.top().if_pc = pc;
            },
            0x05 => { // else
                const c = self.top();
                if (c.kind != .@"if") return error.InvalidModule;
                try self.popAll(c.results);
                if (self.vals.items.len != c.height) return error.InvalidModule;
                const j = try self.emit(.{ .op = OP_JUMP });
                try self.fixups.append(self.a, .{ .in_pool = false, .idx = j, .ctl = @intCast(self.ctls.items.len - 1) });
                self.instrs.items[c.if_pc].a = @intCast(self.instrs.items.len);
                c.kind = .@"else";
                c.unreachable_ = false;
                try self.pushAll(c.params);
            },
            0x0b => try self.end(),
            0x0c => { // br
                const depth = try r.readVarU32();
                const c = try self.labelFor(depth);
                const lt = c.labelTypes();
                try self.popAll(lt);
                try self.emitBranch(OP_BR, c);
                self.setUnreachable();
            },
            0x0d => { // br_if
                const depth = try r.readVarU32();
                try self.popExpect(.i32);
                const c = try self.labelFor(depth);
                const lt = c.labelTypes();
                try self.popAll(lt);
                try self.emitBranch(OP_BR_IF, c);
                try self.pushAll(lt);
            },
            0x0e => { // br_table
                const n = try r.readCount();
                try self.popExpect(.i32);
                const start: u32 = @intCast(self.brt.items.len);
                const labels = try self.a.alloc(u32, n + 1);
                defer self.a.free(labels);
                for (labels) |*l| l.* = try r.readVarU32();
                const def = try self.labelFor(labels[n]);
                const arity = def.labelTypes().len;
                for (labels) |l| {
                    const c = try self.labelFor(l);
                    const lt = c.labelTypes();
                    if (lt.len != arity) return error.InvalidModule;
                    // tür denetimi: operandlar çok-biçimli olabileceğinden pop/push ile doğrulanır
                    try self.popAll(lt);
                    try self.pushAll(lt);
                    const target: u32 = @intCast(self.brt.items.len);
                    try self.brt.append(self.a, .{ .pc = if (c.kind == .loop) c.start_pc else 0, .height = c.height, .arity = @intCast(lt.len) });
                    if (c.kind != .loop) try self.fixups.append(self.a, .{ .in_pool = true, .idx = target, .ctl = self.ctlIndex(c) });
                }
                try self.popAll(def.labelTypes());
                _ = try self.emit(.{ .op = OP_BR_TABLE, .a = start, .b = n });
                self.setUnreachable();
            },
            0x0f => { // return
                try self.popAll(self.ftype.results);
                _ = try self.emit(.{ .op = OP_RETURN, .arity = @intCast(self.ftype.results.len) });
                self.setUnreachable();
            },
            0x10 => { // call
                const idx = try r.readVarU32();
                if (idx >= self.m.numFuncs()) return error.InvalidModule;
                const ft = self.m.typeOf(idx);
                try self.popAll(ft.params);
                try self.pushAll(ft.results);
                _ = try self.emit(.{ .op = OP_CALL, .a = idx });
            },
            0x11 => { // call_indirect
                const ti = try r.readVarU32();
                const tab = try r.readVarU32();
                if (ti >= self.m.types.len or tab >= self.m.tables.len) return error.InvalidModule;
                if (self.m.tables[tab].elem != .funcref) return error.InvalidModule;
                try self.popExpect(.i32);
                const ft = self.m.types[ti];
                try self.popAll(ft.params);
                try self.pushAll(ft.results);
                _ = try self.emit(.{ .op = OP_CALL_INDIRECT, .a = ti, .b = tab });
            },
            0x1a => { // drop
                _ = try self.pop();
                _ = try self.emit(.{ .op = 0x1a });
            },
            0x1b, 0x1c => { // select / select t
                if (op == 0x1c) {
                    const n = try r.readCount();
                    if (n != 1) return error.InvalidModule;
                    const t = try r.readValType();
                    try self.popExpect(.i32);
                    try self.popExpect(t);
                    try self.popExpect(t);
                    try self.push(t);
                } else {
                    try self.popExpect(.i32);
                    const t1 = try self.pop();
                    const t2 = try self.pop();
                    if (t1) |x| if (x.isRef()) return error.InvalidModule;
                    if (t2) |x| if (x.isRef()) return error.InvalidModule;
                    if (t1 != null and t2 != null and t1.? != t2.?) return error.InvalidModule;
                    try self.push(t1 orelse t2);
                }
                _ = try self.emit(.{ .op = 0x1b });
            },
            0x20 => { // local.get
                const idx = try r.readVarU32();
                try self.push(try self.localType(idx));
                _ = try self.emit(.{ .op = 0x20, .a = idx });
            },
            0x21 => { // local.set
                const idx = try r.readVarU32();
                try self.popExpect(try self.localType(idx));
                _ = try self.emit(.{ .op = 0x21, .a = idx });
            },
            0x22 => { // local.tee
                const idx = try r.readVarU32();
                const t = try self.localType(idx);
                try self.popExpect(t);
                try self.push(t);
                _ = try self.emit(.{ .op = 0x22, .a = idx });
            },
            0x23 => { // global.get
                const idx = try r.readVarU32();
                if (idx >= self.m.globals.len) return error.InvalidModule;
                try self.push(self.m.globals[idx].valtype);
                _ = try self.emit(.{ .op = 0x23, .a = idx });
            },
            0x24 => { // global.set
                const idx = try r.readVarU32();
                if (idx >= self.m.globals.len or !self.m.globals[idx].mutable) return error.InvalidModule;
                try self.popExpect(self.m.globals[idx].valtype);
                _ = try self.emit(.{ .op = 0x24, .a = idx });
            },
            0x25 => { // table.get
                const t = try r.readVarU32();
                if (t >= self.m.tables.len) return error.InvalidModule;
                try self.popExpect(.i32);
                try self.push(self.m.tables[t].elem);
                _ = try self.emit(.{ .op = 0x25, .a = t });
            },
            0x26 => { // table.set
                const t = try r.readVarU32();
                if (t >= self.m.tables.len) return error.InvalidModule;
                try self.popExpect(self.m.tables[t].elem);
                try self.popExpect(.i32);
                _ = try self.emit(.{ .op = 0x26, .a = t });
            },
            0x3f, 0x40 => { // memory.size / memory.grow
                if ((try r.byte()) != 0 or self.m.mems.len == 0) return error.InvalidModule;
                if (op == 0x40) try self.popExpect(.i32);
                try self.push(.i32);
                _ = try self.emit(.{ .op = op });
            },
            0x41 => {
                const v = try r.readVarI32();
                try self.push(.i32);
                _ = try self.emit(.{ .op = 0x41, .b = @as(u32, @bitCast(v)) });
            },
            0x42 => {
                const v = try r.readVarI64();
                try self.push(.i64);
                _ = try self.emit(.{ .op = 0x42, .b = @bitCast(v) });
            },
            0x43 => {
                const v = try r.readF32Bits();
                try self.push(.f32);
                _ = try self.emit(.{ .op = 0x43, .b = v });
            },
            0x44 => {
                const v = try r.readF64Bits();
                try self.push(.f64);
                _ = try self.emit(.{ .op = 0x44, .b = v });
            },
            0xd0 => { // ref.null
                const t = try r.readRefType();
                try self.push(t);
                _ = try self.emit(.{ .op = 0xd0 });
            },
            0xd1 => { // ref.is_null
                const t = try self.pop();
                if (t) |x| if (!x.isRef()) return error.InvalidModule;
                try self.push(.i32);
                _ = try self.emit(.{ .op = 0xd1 });
            },
            0xd2 => { // ref.func
                const idx = try r.readVarU32();
                if (idx >= self.m.numFuncs()) return error.InvalidModule;
                try self.push(.funcref);
                _ = try self.emit(.{ .op = 0xd2, .a = idx });
            },
            0xfc => try self.stepFc(r),
            else => return error.InvalidModule,
        }
    }

    fn stepFc(self: *Compiler, r: *Reader) !void {
        const sub = try r.readVarU32();
        if (satSig(sub)) |s| {
            try self.popExpect(s.in[0]);
            try self.push(s.out);
            _ = try self.emit(.{ .op = OP_FC + @as(u16, @intCast(sub)) });
            return;
        }
        switch (sub) {
            8 => { // memory.init
                const di = try r.readVarU32();
                if ((try r.byte()) != 0 or self.m.mems.len == 0) return error.InvalidModule;
                const dc = self.m.data_count orelse return error.InvalidModule;
                if (di >= dc) return error.InvalidModule;
                try self.popExpect(.i32);
                try self.popExpect(.i32);
                try self.popExpect(.i32);
                _ = try self.emit(.{ .op = OP_FC + 8, .a = di });
            },
            9 => { // data.drop
                const di = try r.readVarU32();
                const dc = self.m.data_count orelse return error.InvalidModule;
                if (di >= dc) return error.InvalidModule;
                _ = try self.emit(.{ .op = OP_FC + 9, .a = di });
            },
            10 => { // memory.copy
                if ((try r.byte()) != 0 or (try r.byte()) != 0 or self.m.mems.len == 0) return error.InvalidModule;
                try self.popExpect(.i32);
                try self.popExpect(.i32);
                try self.popExpect(.i32);
                _ = try self.emit(.{ .op = OP_FC + 10 });
            },
            11 => { // memory.fill
                if ((try r.byte()) != 0 or self.m.mems.len == 0) return error.InvalidModule;
                try self.popExpect(.i32);
                try self.popExpect(.i32);
                try self.popExpect(.i32);
                _ = try self.emit(.{ .op = OP_FC + 11 });
            },
            12 => { // table.init elem table
                const ei = try r.readVarU32();
                const ti = try r.readVarU32();
                if (ei >= self.m.elems.len or ti >= self.m.tables.len) return error.InvalidModule;
                if (self.m.elems[ei].elem_type != self.m.tables[ti].elem) return error.InvalidModule;
                try self.popExpect(.i32);
                try self.popExpect(.i32);
                try self.popExpect(.i32);
                _ = try self.emit(.{ .op = OP_FC + 12, .a = ei, .b = ti });
            },
            13 => { // elem.drop
                const ei = try r.readVarU32();
                if (ei >= self.m.elems.len) return error.InvalidModule;
                _ = try self.emit(.{ .op = OP_FC + 13, .a = ei });
            },
            14 => { // table.copy dst src
                const dst = try r.readVarU32();
                const src = try r.readVarU32();
                if (dst >= self.m.tables.len or src >= self.m.tables.len) return error.InvalidModule;
                if (self.m.tables[dst].elem != self.m.tables[src].elem) return error.InvalidModule;
                try self.popExpect(.i32);
                try self.popExpect(.i32);
                try self.popExpect(.i32);
                _ = try self.emit(.{ .op = OP_FC + 14, .a = dst, .b = src });
            },
            15 => { // table.grow
                const t = try r.readVarU32();
                if (t >= self.m.tables.len) return error.InvalidModule;
                try self.popExpect(.i32);
                try self.popExpect(self.m.tables[t].elem);
                try self.push(.i32);
                _ = try self.emit(.{ .op = OP_FC + 15, .a = t });
            },
            16 => { // table.size
                const t = try r.readVarU32();
                if (t >= self.m.tables.len) return error.InvalidModule;
                try self.push(.i32);
                _ = try self.emit(.{ .op = OP_FC + 16, .a = t });
            },
            17 => { // table.fill
                const t = try r.readVarU32();
                if (t >= self.m.tables.len) return error.InvalidModule;
                try self.popExpect(.i32);
                try self.popExpect(self.m.tables[t].elem);
                try self.popExpect(.i32);
                _ = try self.emit(.{ .op = OP_FC + 17, .a = t });
            },
            else => return error.InvalidModule,
        }
    }

    fn emitBranch(self: *Compiler, op: u16, c: *Ctl) !void {
        const lt = c.labelTypes();
        const pc = try self.emit(.{ .op = op, .arity = @intCast(lt.len), .a = if (c.kind == .loop) c.start_pc else 0, .b = c.height });
        if (c.kind != .loop) try self.fixups.append(self.a, .{ .in_pool = false, .idx = pc, .ctl = self.ctlIndex(c) });
    }

    fn end(self: *Compiler) !void {
        const c = self.top().*;
        try self.popAll(c.results);
        if (self.vals.items.len != c.height) return error.InvalidModule;
        if (c.kind == .@"if") {
            // else'siz if: params == results olmalı; koşul sıfırsa bloğun sonuna atlanır
            if (!std.mem.eql(ValType, c.params, c.results)) return error.InvalidModule;
            self.instrs.items[c.if_pc].a = @intCast(self.instrs.items.len);
        }
        const end_pc: u32 = @intCast(self.instrs.items.len);
        const my_idx: u32 = @intCast(self.ctls.items.len - 1);
        var keep: usize = 0;
        for (self.fixups.items) |f| {
            if (f.ctl == my_idx) {
                self.patch(f, end_pc);
            } else {
                self.fixups.items[keep] = f;
                keep += 1;
            }
        }
        self.fixups.shrinkRetainingCapacity(keep);
        _ = self.ctls.pop();
        if (c.kind == .func) {
            _ = try self.emit(.{ .op = OP_RETURN, .arity = @intCast(c.results.len) });
            return;
        }
        try self.pushAll(c.results);
    }
};

/// Tek bir tanımlı işlevi doğrular ve derler. Bellek `a`dan gelir (çağıran `a`yı arena olarak kullanmalıdır).
pub fn compileFunc(a: std.mem.Allocator, m: *const Module, func_index: u32) CompileError!FuncCode {
    const body = m.bodies[func_index - m.num_imported_funcs];
    const ft = m.typeOf(func_index);
    const local_types = try a.alloc(ValType, ft.params.len + body.locals.len);
    @memcpy(local_types[0..ft.params.len], ft.params);
    @memcpy(local_types[ft.params.len..], body.locals);

    var c: Compiler = .{ .a = a, .m = m, .local_types = local_types, .ftype = ft };
    defer c.deinit();
    c.run(body.code) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidModule,
    };
    return .{
        .instrs = try a.dupe(Instr, c.instrs.items),
        .brt = try a.dupe(BrTarget, c.brt.items),
        .num_params = @intCast(ft.params.len),
        .num_results = @intCast(ft.results.len),
        .num_locals = @intCast(local_types.len),
        .max_stack = c.max_height,
    };
}

fn constExprType(m: *const Module, e: mod.ConstExpr) !ValType {
    return switch (e) {
        .i32 => .i32,
        .i64 => .i64,
        .f32 => .f32,
        .f64 => .f64,
        .ref_null => |t| t,
        .ref_func => |f| blk: {
            if (f >= m.numFuncs()) return error.InvalidModule;
            break :blk .funcref;
        },
        .global_get => |g| blk: {
            // yalnızca içe aktarılan, değişmez globallere başvurulabilir
            if (g >= m.num_imported_globals) return error.InvalidModule;
            if (m.globals[g].mutable) return error.InvalidModule;
            break :blk m.globals[g].valtype;
        },
    };
}

/// Modül düzeyi doğrulama (dizin sınırları, sabit ifade tipleri, start/export/segment tutarlılığı). İşlev gövdeleri `compileFunc` ile ayrıca doğrulanır.
pub fn validateModule(m: *const Module) CompileError!void {
    if (m.mems.len > 1) return error.InvalidModule;
    for (m.tables) |t| {
        if (t.limits.max) |mx| if (mx < t.limits.min) return error.InvalidModule;
    }
    for (m.global_inits, 0..) |init, i| {
        const gt = m.globals[m.num_imported_globals + i];
        if ((try constExprType(m, init)) != gt.valtype) return error.InvalidModule;
    }
    for (m.exports) |e| {
        const limit: usize = switch (e.kind) {
            .func => m.numFuncs(),
            .table => m.tables.len,
            .mem => m.mems.len,
            .global => m.globals.len,
        };
        if (e.index >= limit) return error.InvalidModule;
    }
    if (m.start) |s| {
        if (s >= m.numFuncs()) return error.InvalidModule;
        const ft = m.typeOf(s);
        if (ft.params.len != 0 or ft.results.len != 0) return error.InvalidModule;
    }
    for (m.elems) |el| {
        if (el.mode == .active) {
            if (el.table >= m.tables.len) return error.InvalidModule;
            if (m.tables[el.table].elem != el.elem_type) return error.InvalidModule;
            if ((try constExprType(m, el.offset)) != .i32) return error.InvalidModule;
        }
        for (el.items) |it| if ((try constExprType(m, it)) != el.elem_type) return error.InvalidModule;
    }
    for (m.datas) |d| {
        if (d.mode == .active) {
            if (d.mem >= m.mems.len) return error.InvalidModule;
            if ((try constExprType(m, d.offset)) != .i32) return error.InvalidModule;
        }
    }
}

/// Modülü doğrular ve tüm tanımlı işlevleri derler; sonuç `a`dan tahsis edilir (çağıran `a`yı arena olarak yönetmelidir).
pub fn compileModule(a: std.mem.Allocator, m: *const Module) CompileError![]FuncCode {
    try validateModule(m);
    const codes = try a.alloc(FuncCode, m.bodies.len);
    for (codes, 0..) |*c, i| c.* = try compileFunc(a, m, m.num_imported_funcs + @as(u32, @intCast(i)));
    return codes;
}
