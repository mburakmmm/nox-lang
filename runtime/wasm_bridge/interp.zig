//! Nox WASM köprüsü — yorumlayıcı (AGENTS.md §11).
//!
//! `module.zig` ikiliyi ayrıştırır, `compile.zig` her işlevi doğrulayıp düz `Instr` dizisine derler, burası kalıcı bir `Instance` (bellek, tablolar,
//! globaller, segmentler) üzerinde bu diziyi çalıştırır. Yorumlayıcı yinelemelidir (özyineleme yok): çağrı yığını ayrı bir `Frame` dizisidir, değerler
//! tek bir `[]u64` yığınında durur (`i32`/`f32` sıfır-genişletilmiş, `i64`/`f64` ham bit). Doğrulama sayesinde yığın taşması/yetersizliği, tip karışması
//! ve etiket hataları çalışma zamanında denetlenmez; yalnızca belirsiz davranış üretebilecek durumlar denetlenir: bellek/tablo sınırları, sıfıra bölme,
//! taşma, çağrı yığını/değer yığını derinliği, yakıt (sonsuz döngü), dolaylı çağrı tipi.
//!
//! **Handle birleştirmesi (AGENTS.md §11: "iki ayrı FFI mekanizması yoktur, tek bir handle soyutlaması vardır"):** `callExport`, argümanları ve dönüş
//! değerini `runtime/hpy_bridge/context.zig`nin AYNI `HPy`/`Obj` temsiliyle alıp verir.
//!
//! **Güven sınırı (AGENTS §9.5):** `.wasm` modülü GÜVENİLMEYEN koddur; bellek erişimi doğrusal belleğe kapalıdır, host işlevleri yalnızca `Imports`
//! ile açıkça verilenlerdir (varsayılan: hiç yok), yakıt/yığın/bellek tavanları `Config`dedir.

const std = @import("std");
const module_mod = @import("module.zig");
const compile = @import("compile.zig");
const simd = @import("simd.zig");
const Module = module_mod.Module;
const ValType = module_mod.ValType;
const FuncCode = compile.FuncCode;
const hpy_context = @import("hpy_bridge").context;
const HPy = hpy_context.HPy;
const HPyContext = hpy_context.HPyContext;

pub const Trap = error{
    Unreachable,
    IntegerDivideByZero,
    IntegerOverflow,
    InvalidConversionToInteger,
    OutOfBoundsMemoryAccess,
    OutOfBoundsTableAccess,
    UndefinedElement,
    UninitializedElement,
    IndirectCallTypeMismatch,
    StackExhausted,
    OutOfFuel,
    OutOfMemory,
    HostFailure,
};

pub const LinkError = error{ InvalidModule, UnsupportedVersion, ImportNotFound, ImportTypeMismatch, OutOfMemory };

pub const InterpError = Trap || LinkError || error{ ExportNotFound, TypeMismatch, TooManyArgs };

pub const HostFn = *const fn (ctx: ?*anyopaque, inst: *Instance, args: []const u64, results: []u64) Trap!void;

pub const HostFunc = struct {
    params: []const ValType,
    results: []const ValType,
    f: HostFn,
    ctx: ?*anyopaque = null,
};

pub const HostGlobal = struct { ty: module_mod.GlobalType, value: u64 };

pub const HostItem = union(enum) {
    func: HostFunc,
    global: HostGlobal,
};

pub const HostBinding = struct { module: []const u8, name: []const u8, item: HostItem };

pub const Config = struct {
    /// Her dallanma/çağrı 1 yakıt harcar (sonsuz döngü ve özyineleme sınırı).
    fuel: u64 = 2_000_000_000,
    /// Değer yığını (u64 yuvası).
    max_stack_slots: usize = 1 << 18,
    max_call_depth: usize = 16384,
    max_memory_pages: u32 = 4096,
    max_table_elems: u32 = 10_000_000,
};

const MAX_HOST_RESULTS = 16;
pub const NULL_REF: u64 = 0;

const Table = struct {
    elems: []u64,
    max: u32,
    elem_type: ValType,
};

const Frame = struct {
    code: *const FuncCode,
    pc: u32,
    base: usize,
};

pub const Instance = struct {
    allocator: std.mem.Allocator,
    module: *const Module,
    arena: std.heap.ArenaAllocator,
    codes: []FuncCode,
    cfg: Config,

    host_funcs: []HostFunc,
    mem: []u8 = &.{},
    mem_max_pages: u32 = module_mod.MAX_PAGES,
    tables: []Table,
    globals: []u64,
    data_dropped: []bool,
    elem_dropped: []bool,
    elem_vals: [][]u64,
    /// Tür indeksi -> kanonik tür indeksi (yapısal eşitlik), dolaylı çağrı denetimi için.
    canon: []u32,

    stack: []u64,
    /// SIMD gölge yığını: v128 değeri `stack` ile AYNI indeksli yuvada (yalnızca modül SIMD kullanıyorsa tahsis edilir).
    vstack: []u128 = &.{},
    frames: []Frame,
    frame_top: usize = 0,
    sp_top: usize = 0,
    fuel: u64,

    /// Modülü örnekler: içe aktarmaları bağlar, bellek/tablo/global kurar, etkin segmentleri uygular, `start`ı çalıştırır.
    pub fn init(allocator: std.mem.Allocator, module: *const Module, bindings: []const HostBinding, cfg: Config) (LinkError || Trap)!*Instance {
        const self = try allocator.create(Instance);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .module = module,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .codes = &.{},
            .cfg = cfg,
            .host_funcs = &.{},
            .tables = &.{},
            .globals = &.{},
            .data_dropped = &.{},
            .elem_dropped = &.{},
            .elem_vals = &.{},
            .canon = &.{},
            .stack = &.{},
            .frames = &.{},
            .fuel = cfg.fuel,
        };
        errdefer self.arena.deinit();
        const a = self.arena.allocator();

        self.codes = compile.compileModule(a, module) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidModule => return error.InvalidModule,
        };

        // tür kanonikleştirme
        self.canon = try a.alloc(u32, module.types.len);
        for (module.types, 0..) |t, i| {
            self.canon[i] = @intCast(i);
            for (module.types[0..i], 0..) |u, j| {
                if (t.eql(u)) {
                    self.canon[i] = self.canon[j];
                    break;
                }
            }
        }

        // içe aktarmalar
        self.host_funcs = try a.alloc(HostFunc, module.num_imported_funcs);
        self.globals = try a.alloc(u64, module.globals.len);
        @memset(self.globals, 0);
        self.tables = try a.alloc(Table, module.tables.len);
        var fi: usize = 0;
        var gi: usize = 0;
        var ti: usize = 0;
        var have_mem = false;
        var mem_min: u32 = 0;
        var mem_max: ?u32 = null;
        for (module.imports) |imp| {
            switch (imp.desc) {
                .func => |type_idx| {
                    const ft = module.types[type_idx];
                    // v128 değerleri ana bilgisayar sınırından geçemez (u64 yuvaları).
                    for (ft.params) |t| if (t == .v128) return error.ImportTypeMismatch;
                    for (ft.results) |t| if (t == .v128) return error.ImportTypeMismatch;
                    const b = findBinding(bindings, imp.module, imp.name) orelse return error.ImportNotFound;
                    switch (b.item) {
                        .func => |hf| {
                            if (!std.mem.eql(ValType, hf.params, ft.params) or !std.mem.eql(ValType, hf.results, ft.results)) return error.ImportTypeMismatch;
                            if (hf.results.len > MAX_HOST_RESULTS) return error.ImportTypeMismatch;
                            self.host_funcs[fi] = hf;
                        },
                        else => return error.ImportTypeMismatch,
                    }
                    fi += 1;
                },
                .global => |gt| {
                    const b = findBinding(bindings, imp.module, imp.name) orelse return error.ImportNotFound;
                    switch (b.item) {
                        .global => |hg| {
                            if (hg.ty.valtype != gt.valtype or hg.ty.mutable != gt.mutable) return error.ImportTypeMismatch;
                            self.globals[gi] = hg.value;
                        },
                        else => return error.ImportTypeMismatch,
                    }
                    gi += 1;
                },
                // İçe aktarılan tablo/bellek: ana bilgisayardan paylaşılmaz; bildirilen sınırlarla modüle özel yeni nesne olarak yaratılır.
                .table => ti += 1,
                .mem => |l| {
                    have_mem = true;
                    mem_min = l.min;
                    mem_max = l.max;
                },
            }
        }

        // tablolar
        for (self.tables, module.tables) |*t, tt| {
            if (tt.limits.min > cfg.max_table_elems) return error.OutOfMemory;
            t.* = .{ .elems = try a.alloc(u64, tt.limits.min), .max = @min(tt.limits.max orelse cfg.max_table_elems, cfg.max_table_elems), .elem_type = tt.elem };
            @memset(t.elems, NULL_REF);
        }

        // bellek
        if (module.mems.len > 0) {
            const l = module.mems[0];
            if (!have_mem) {
                mem_min = l.min;
                mem_max = l.max;
            }
            self.mem_max_pages = @min(mem_max orelse module_mod.MAX_PAGES, cfg.max_memory_pages);
            if (mem_min > self.mem_max_pages) return error.OutOfMemory;
            self.mem = allocator.alloc(u8, @as(usize, mem_min) * 65536) catch return error.OutOfMemory;
            @memset(self.mem, 0);
        }
        errdefer allocator.free(self.mem);

        // globaller (tanımlanan)
        for (module.global_inits, 0..) |init_expr, i| {
            self.globals[module.num_imported_globals + i] = self.evalConst(init_expr);
        }

        // segment durumu
        self.data_dropped = try a.alloc(bool, module.datas.len);
        @memset(self.data_dropped, false);
        self.elem_dropped = try a.alloc(bool, module.elems.len);
        @memset(self.elem_dropped, false);
        self.elem_vals = try a.alloc([]u64, module.elems.len);
        for (module.elems, 0..) |el, i| {
            self.elem_vals[i] = try a.alloc(u64, el.items.len);
            for (el.items, 0..) |it, k| self.elem_vals[i][k] = self.evalConst(it);
        }

        // yığınlar
        self.stack = allocator.alloc(u64, cfg.max_stack_slots) catch return error.OutOfMemory;
        errdefer allocator.free(self.stack);
        self.frames = allocator.alloc(Frame, cfg.max_call_depth) catch return error.OutOfMemory;
        errdefer allocator.free(self.frames);
        var any_simd = false;
        for (self.codes) |c| any_simd = any_simd or c.uses_simd;
        if (any_simd) self.vstack = allocator.alloc(u128, cfg.max_stack_slots) catch return error.OutOfMemory;
        errdefer allocator.free(self.vstack);

        // etkin elem segmentleri, sonra etkin data segmentleri (spec sırası)
        for (module.elems, 0..) |el, i| {
            switch (el.mode) {
                .active => {
                    const off: u32 = @truncate(self.evalConst(el.offset));
                    const t = &self.tables[el.table];
                    if (@as(u64, off) + el.items.len > t.elems.len) return error.OutOfBoundsTableAccess;
                    @memcpy(t.elems[off..][0..el.items.len], self.elem_vals[i]);
                    self.elem_dropped[i] = true;
                },
                .declarative => self.elem_dropped[i] = true,
                .passive => {},
            }
        }
        for (module.datas, 0..) |d, i| {
            if (d.mode == .active) {
                const off: u32 = @truncate(self.evalConst(d.offset));
                if (@as(u64, off) + d.bytes.len > self.mem.len) return error.OutOfBoundsMemoryAccess;
                @memcpy(self.mem[off..][0..d.bytes.len], d.bytes);
                self.data_dropped[i] = true;
            }
        }

        if (module.start) |s| try self.invoke(s, &.{}, &.{});
        return self;
    }

    pub fn deinit(self: *Instance) void {
        const allocator = self.allocator;
        allocator.free(self.mem);
        allocator.free(self.stack);
        allocator.free(self.vstack);
        allocator.free(self.frames);
        self.arena.deinit();
        allocator.destroy(self);
    }

    fn evalConst(self: *const Instance, e: module_mod.ConstExpr) u64 {
        return switch (e) {
            .i32 => |v| @as(u32, @bitCast(v)),
            .i64 => |v| @bitCast(v),
            .f32 => |v| v,
            .f64 => |v| v,
            .global_get => |g| self.globals[g],
            .ref_null => NULL_REF,
            .ref_func => |f| @as(u64, f) + 1,
        };
    }

    pub fn findExport(self: *const Instance, name: []const u8, kind: module_mod.ExportKind) ?u32 {
        for (self.module.exports) |e| {
            if (e.kind == kind and std.mem.eql(u8, e.name, name)) return e.index;
        }
        return null;
    }

    /// Doğrusal belleğin şu anki içeriği (bellek yoksa boş). `memory.grow` sonrası yeniden alınmalıdır.
    pub fn memory(self: *Instance) []u8 {
        return self.mem;
    }

    pub fn global(self: *const Instance, idx: u32) u64 {
        return self.globals[idx];
    }

    /// `func_idx` işlevini `args` ile çağırır; sonuçlar `results`a yazılır (uzunluk = sonuç sayısı). Değerler ham yuvalardır
    /// (`i32` alt 32 bit, `f32` bit deseni, `f64`/`i64` 64 bit). Yeniden girişli: host işlevleri içinden de çağrılabilir.
    pub fn invoke(self: *Instance, func_idx: u32, args: []const u64, results: []u64) Trap!void {
        const ft = self.module.typeOf(func_idx);
        std.debug.assert(args.len == ft.params.len and results.len == ft.results.len);
        if (self.frame_top == 0) self.fuel = self.cfg.fuel; // yakıt, en dıştaki çağrı başına yenilenir
        const base = self.sp_top;
        if (base + args.len + ft.results.len + 1 > self.stack.len) return error.StackExhausted;
        @memcpy(self.stack[base..][0..args.len], args);

        const saved_top = self.sp_top;
        const saved_frames = self.frame_top;
        defer {
            self.sp_top = saved_top;
            self.frame_top = saved_frames;
        }

        if (func_idx < self.module.num_imported_funcs) {
            const hf = self.host_funcs[func_idx];
            var res: [MAX_HOST_RESULTS]u64 = undefined;
            self.sp_top = base + args.len;
            try hf.f(hf.ctx, self, self.stack[base..][0..args.len], res[0..hf.results.len]);
            @memcpy(results, res[0..results.len]);
            return;
        }

        const code = &self.codes[func_idx - self.module.num_imported_funcs];
        try self.enter(code, base + args.len);
        try self.run(saved_frames);
        @memcpy(results, self.stack[base..][0..results.len]);
    }

    /// Yeni bir çerçeve açar: argümanlar `sp - num_params`dan başlar.
    fn enter(self: *Instance, code: *const FuncCode, sp: usize) Trap!void {
        const base = sp - code.num_params;
        if (self.frame_top >= self.frames.len) return error.StackExhausted;
        if (base + code.num_locals + code.max_stack + 1 > self.stack.len) return error.StackExhausted;
        @memset(self.stack[sp .. base + code.num_locals], 0);
        if (code.uses_simd) @memset(self.vstack[sp .. base + code.num_locals], 0);
        self.frames[self.frame_top] = .{ .code = code, .pc = 0, .base = base };
        self.frame_top += 1;
        self.sp_top = base + code.num_locals;
    }

    fn run(self: *Instance, stop_depth: usize) Trap!void {
        const stack = self.stack;
        const vstack = self.vstack;
        const module = self.module;
        const n_imp = module.num_imported_funcs;
        var fr: *Frame = &self.frames[self.frame_top - 1];
        var instrs = fr.code.instrs;
        var pc: u32 = fr.pc;
        var base = fr.base;
        var opb = base + fr.code.num_locals;
        var sp = self.sp_top;

        while (true) {
            const ins = instrs[pc];
            pc += 1;
            switch (ins.op) {
                0x00 => return error.Unreachable,
                compile.OP_IF => {
                    sp -= 1;
                    if (@as(u32, @truncate(stack[sp])) == 0) pc = ins.a;
                },
                compile.OP_JUMP => pc = ins.a,
                compile.OP_BR, compile.OP_BR_IF, compile.OP_BR_TABLE => {
                    var target_pc: u32 = ins.a;
                    var height: u64 = ins.b;
                    var arity: usize = ins.arity;
                    if (ins.op == compile.OP_BR_IF) {
                        sp -= 1;
                        if (@as(u32, @truncate(stack[sp])) == 0) continue;
                    } else if (ins.op == compile.OP_BR_TABLE) {
                        sp -= 1;
                        const idx = @as(u32, @truncate(stack[sp]));
                        const n: u32 = @intCast(ins.b);
                        const t = fr.code.brt[ins.a + @min(idx, n)];
                        target_pc = t.pc;
                        height = t.height;
                        arity = t.arity;
                    }
                    if (self.fuel == 0) return error.OutOfFuel;
                    self.fuel -= 1;
                    const dst = opb + @as(usize, @intCast(height));
                    if (sp - arity != dst) {
                        std.mem.copyForwards(u64, stack[dst..][0..arity], stack[sp - arity .. sp]);
                    }
                    sp = dst + arity;
                    pc = target_pc;
                },
                compile.OP_BR_V, compile.OP_BR_IF_V, compile.OP_BR_TABLE_V => {
                    var target_pc: u32 = ins.a;
                    var height: u64 = ins.b;
                    var arity: usize = ins.arity;
                    if (ins.op == compile.OP_BR_IF_V) {
                        sp -= 1;
                        if (@as(u32, @truncate(stack[sp])) == 0) continue;
                    } else if (ins.op == compile.OP_BR_TABLE_V) {
                        sp -= 1;
                        const idx = @as(u32, @truncate(stack[sp]));
                        const n: u32 = @intCast(ins.b);
                        const t = fr.code.brt[ins.a + @min(idx, n)];
                        target_pc = t.pc;
                        height = t.height;
                        arity = t.arity;
                    }
                    if (self.fuel == 0) return error.OutOfFuel;
                    self.fuel -= 1;
                    const dst = opb + @as(usize, @intCast(height));
                    if (sp - arity != dst) {
                        std.mem.copyForwards(u64, stack[dst..][0..arity], stack[sp - arity .. sp]);
                        std.mem.copyForwards(u128, vstack[dst..][0..arity], vstack[sp - arity .. sp]);
                    }
                    sp = dst + arity;
                    pc = target_pc;
                },
                compile.OP_RETURN, compile.OP_RETURN_V => {
                    const nres: usize = ins.arity;
                    if (sp - nres != base) {
                        std.mem.copyForwards(u64, stack[base..][0..nres], stack[sp - nres .. sp]);
                        if (ins.op == compile.OP_RETURN_V) std.mem.copyForwards(u128, vstack[base..][0..nres], vstack[sp - nres .. sp]);
                    }
                    sp = base + nres;
                    self.frame_top -= 1;
                    if (self.frame_top == stop_depth) {
                        self.sp_top = sp;
                        return;
                    }
                    fr = &self.frames[self.frame_top - 1];
                    instrs = fr.code.instrs;
                    pc = fr.pc;
                    base = fr.base;
                    opb = base + fr.code.num_locals;
                },
                compile.OP_CALL, compile.OP_CALL_INDIRECT => {
                    var callee: u32 = ins.a;
                    if (ins.op == compile.OP_CALL_INDIRECT) {
                        sp -= 1;
                        const idx = @as(u32, @truncate(stack[sp]));
                        const t = &self.tables[@intCast(ins.b)];
                        if (idx >= t.elems.len) return error.UndefinedElement;
                        const ref = t.elems[idx];
                        if (ref == NULL_REF) return error.UninitializedElement;
                        callee = @intCast(ref - 1);
                        if (self.canon[module.func_type_indices[callee]] != self.canon[ins.a]) return error.IndirectCallTypeMismatch;
                    }
                    if (self.fuel == 0) return error.OutOfFuel;
                    self.fuel -= 1;
                    if (callee < n_imp) {
                        const hf = self.host_funcs[callee];
                        const np = hf.params.len;
                        const nr = hf.results.len;
                        self.sp_top = sp;
                        var res: [MAX_HOST_RESULTS]u64 = undefined;
                        try hf.f(hf.ctx, self, stack[sp - np .. sp], res[0..nr]);
                        @memcpy(stack[sp - np ..][0..nr], res[0..nr]);
                        sp = sp - np + nr;
                    } else {
                        fr.pc = pc;
                        try self.enter(&self.codes[callee - n_imp], sp);
                        fr = &self.frames[self.frame_top - 1];
                        instrs = fr.code.instrs;
                        pc = 0;
                        base = fr.base;
                        opb = base + fr.code.num_locals;
                        sp = opb;
                    }
                },
                compile.OP_LOCAL_GET_V => {
                    vstack[sp] = vstack[base + ins.a];
                    sp += 1;
                },
                compile.OP_LOCAL_SET_V => {
                    sp -= 1;
                    vstack[base + ins.a] = vstack[sp];
                },
                compile.OP_LOCAL_TEE_V => vstack[base + ins.a] = vstack[sp - 1],
                compile.OP_SELECT_V => {
                    sp -= 2;
                    if (@as(u32, @truncate(stack[sp + 1])) == 0) vstack[sp - 1] = vstack[sp];
                },
                compile.OP_FD...compile.OP_FD + 0xff => sp = try simd.exec(self.mem, @enumFromInt(ins.arity), ins.op - compile.OP_FD, ins.a, ins.b, fr.code.consts, stack, vstack, sp),
                0x1a => sp -= 1, // drop
                0x1b => { // select
                    sp -= 2;
                    if (@as(u32, @truncate(stack[sp + 1])) == 0) stack[sp - 1] = stack[sp];
                },
                0x20 => {
                    stack[sp] = stack[base + ins.a];
                    sp += 1;
                },
                0x21 => {
                    sp -= 1;
                    stack[base + ins.a] = stack[sp];
                },
                0x22 => stack[base + ins.a] = stack[sp - 1],
                0x23 => {
                    stack[sp] = self.globals[ins.a];
                    sp += 1;
                },
                0x24 => {
                    sp -= 1;
                    self.globals[ins.a] = stack[sp];
                },
                0x25 => { // table.get
                    const t = &self.tables[ins.a];
                    const i = @as(u32, @truncate(stack[sp - 1]));
                    if (i >= t.elems.len) return error.OutOfBoundsTableAccess;
                    stack[sp - 1] = t.elems[i];
                },
                0x26 => { // table.set
                    const t = &self.tables[ins.a];
                    sp -= 2;
                    const i = @as(u32, @truncate(stack[sp]));
                    if (i >= t.elems.len) return error.OutOfBoundsTableAccess;
                    t.elems[i] = stack[sp + 1];
                },

                // ---- bellek ----
                0x28, 0x2c...0x2f, 0x34, 0x35, 0x29, 0x30...0x33, 0x2a, 0x2b => {
                    const size: usize = switch (ins.op) {
                        0x28, 0x2a, 0x34, 0x35 => 4,
                        0x29, 0x2b => 8,
                        0x2c, 0x2d, 0x30, 0x31 => 1,
                        else => 2,
                    };
                    const e = try self.effAddr(stack[sp - 1], ins.a, size);
                    const m = self.mem;
                    stack[sp - 1] = switch (ins.op) {
                        0x28, 0x2a => std.mem.readInt(u32, m[e..][0..4], .little),
                        0x29, 0x2b => std.mem.readInt(u64, m[e..][0..8], .little),
                        0x2c => @as(u32, @bitCast(@as(i32, @as(i8, @bitCast(m[e]))))),
                        0x2d => m[e],
                        0x2e => @as(u32, @bitCast(@as(i32, std.mem.readInt(i16, m[e..][0..2], .little)))),
                        0x2f => std.mem.readInt(u16, m[e..][0..2], .little),
                        0x30 => @bitCast(@as(i64, @as(i8, @bitCast(m[e])))),
                        0x31 => m[e],
                        0x32 => @bitCast(@as(i64, std.mem.readInt(i16, m[e..][0..2], .little))),
                        0x33 => std.mem.readInt(u16, m[e..][0..2], .little),
                        0x34 => @bitCast(@as(i64, std.mem.readInt(i32, m[e..][0..4], .little))),
                        else => std.mem.readInt(u32, m[e..][0..4], .little),
                    };
                },
                0x36...0x3e => {
                    sp -= 2;
                    const size: usize = switch (ins.op) {
                        0x36, 0x38, 0x3e => 4,
                        0x37, 0x39 => 8,
                        0x3a, 0x3c => 1,
                        else => 2,
                    };
                    const e = try self.effAddr(stack[sp], ins.a, size);
                    const v = stack[sp + 1];
                    const m = self.mem;
                    switch (size) {
                        1 => m[e] = @truncate(v),
                        2 => std.mem.writeInt(u16, m[e..][0..2], @truncate(v), .little),
                        4 => std.mem.writeInt(u32, m[e..][0..4], @truncate(v), .little),
                        else => std.mem.writeInt(u64, m[e..][0..8], v, .little),
                    }
                },
                0x3f => {
                    stack[sp] = self.mem.len / 65536;
                    sp += 1;
                },
                0x40 => stack[sp - 1] = self.memGrow(@truncate(stack[sp - 1])),

                // ---- sabitler ----
                0x41, 0x42, 0x43, 0x44 => {
                    stack[sp] = ins.b;
                    sp += 1;
                },

                // ---- i32 ----
                0x45 => stack[sp - 1] = @intFromBool(@as(u32, @truncate(stack[sp - 1])) == 0),
                0x46...0x4f => {
                    sp -= 1;
                    const a: u32 = @truncate(stack[sp - 1]);
                    const b: u32 = @truncate(stack[sp]);
                    const sa: i32 = @bitCast(a);
                    const sb: i32 = @bitCast(b);
                    stack[sp - 1] = @intFromBool(switch (ins.op) {
                        0x46 => a == b,
                        0x47 => a != b,
                        0x48 => sa < sb,
                        0x49 => a < b,
                        0x4a => sa > sb,
                        0x4b => a > b,
                        0x4c => sa <= sb,
                        0x4d => a <= b,
                        0x4e => sa >= sb,
                        else => a >= b,
                    });
                },
                0x50 => stack[sp - 1] = @intFromBool(stack[sp - 1] == 0),
                0x51...0x5a => {
                    sp -= 1;
                    const a = stack[sp - 1];
                    const b = stack[sp];
                    const sa: i64 = @bitCast(a);
                    const sb: i64 = @bitCast(b);
                    stack[sp - 1] = @intFromBool(switch (ins.op) {
                        0x51 => a == b,
                        0x52 => a != b,
                        0x53 => sa < sb,
                        0x54 => a < b,
                        0x55 => sa > sb,
                        0x56 => a > b,
                        0x57 => sa <= sb,
                        0x58 => a <= b,
                        0x59 => sa >= sb,
                        else => a >= b,
                    });
                },
                0x5b...0x60 => {
                    sp -= 1;
                    const a = f32v(stack[sp - 1]);
                    const b = f32v(stack[sp]);
                    stack[sp - 1] = @intFromBool(switch (ins.op) {
                        0x5b => a == b,
                        0x5c => a != b,
                        0x5d => a < b,
                        0x5e => a > b,
                        0x5f => a <= b,
                        else => a >= b,
                    });
                },
                0x61...0x66 => {
                    sp -= 1;
                    const a = f64v(stack[sp - 1]);
                    const b = f64v(stack[sp]);
                    stack[sp - 1] = @intFromBool(switch (ins.op) {
                        0x61 => a == b,
                        0x62 => a != b,
                        0x63 => a < b,
                        0x64 => a > b,
                        0x65 => a <= b,
                        else => a >= b,
                    });
                },
                0x67 => stack[sp - 1] = @clz(@as(u32, @truncate(stack[sp - 1]))),
                0x68 => stack[sp - 1] = @ctz(@as(u32, @truncate(stack[sp - 1]))),
                0x69 => stack[sp - 1] = @popCount(@as(u32, @truncate(stack[sp - 1]))),
                0x6a...0x78 => {
                    sp -= 1;
                    const a: u32 = @truncate(stack[sp - 1]);
                    const b: u32 = @truncate(stack[sp]);
                    const sa: i32 = @bitCast(a);
                    const sb: i32 = @bitCast(b);
                    const sh: u5 = @truncate(b);
                    stack[sp - 1] = switch (ins.op) {
                        0x6a => a +% b,
                        0x6b => a -% b,
                        0x6c => a *% b,
                        0x6d => blk: {
                            if (b == 0) return error.IntegerDivideByZero;
                            if (sa == std.math.minInt(i32) and sb == -1) return error.IntegerOverflow;
                            break :blk @as(u32, @bitCast(@divTrunc(sa, sb)));
                        },
                        0x6e => blk: {
                            if (b == 0) return error.IntegerDivideByZero;
                            break :blk a / b;
                        },
                        0x6f => blk: {
                            if (b == 0) return error.IntegerDivideByZero;
                            if (sb == -1) break :blk 0;
                            break :blk @as(u32, @bitCast(@rem(sa, sb)));
                        },
                        0x70 => blk: {
                            if (b == 0) return error.IntegerDivideByZero;
                            break :blk a % b;
                        },
                        0x71 => a & b,
                        0x72 => a | b,
                        0x73 => a ^ b,
                        0x74 => a << sh,
                        0x75 => @as(u32, @bitCast(sa >> sh)),
                        0x76 => a >> sh,
                        0x77 => std.math.rotl(u32, a, sh),
                        else => std.math.rotr(u32, a, sh),
                    };
                },

                // ---- i64 ----
                0x79 => stack[sp - 1] = @clz(stack[sp - 1]),
                0x7a => stack[sp - 1] = @ctz(stack[sp - 1]),
                0x7b => stack[sp - 1] = @popCount(stack[sp - 1]),
                0x7c...0x8a => {
                    sp -= 1;
                    const a = stack[sp - 1];
                    const b = stack[sp];
                    const sa: i64 = @bitCast(a);
                    const sb: i64 = @bitCast(b);
                    const sh: u6 = @truncate(b);
                    stack[sp - 1] = switch (ins.op) {
                        0x7c => a +% b,
                        0x7d => a -% b,
                        0x7e => a *% b,
                        0x7f => blk: {
                            if (b == 0) return error.IntegerDivideByZero;
                            if (sa == std.math.minInt(i64) and sb == -1) return error.IntegerOverflow;
                            break :blk @as(u64, @bitCast(@divTrunc(sa, sb)));
                        },
                        0x80 => blk: {
                            if (b == 0) return error.IntegerDivideByZero;
                            break :blk a / b;
                        },
                        0x81 => blk: {
                            if (b == 0) return error.IntegerDivideByZero;
                            if (sb == -1) break :blk 0;
                            break :blk @as(u64, @bitCast(@rem(sa, sb)));
                        },
                        0x82 => blk: {
                            if (b == 0) return error.IntegerDivideByZero;
                            break :blk a % b;
                        },
                        0x83 => a & b,
                        0x84 => a | b,
                        0x85 => a ^ b,
                        0x86 => a << sh,
                        0x87 => @as(u64, @bitCast(sa >> sh)),
                        0x88 => a >> sh,
                        0x89 => std.math.rotl(u64, a, sh),
                        else => std.math.rotr(u64, a, sh),
                    };
                },

                // ---- f32 ----
                0x8b...0x91 => {
                    const x = f32v(stack[sp - 1]);
                    stack[sp - 1] = switch (ins.op) {
                        0x8b => stack[sp - 1] & 0x7fff_ffff,
                        0x8c => (stack[sp - 1] ^ 0x8000_0000) & 0xffff_ffff,
                        0x8d => vf32(@ceil(x)),
                        0x8e => vf32(@floor(x)),
                        0x8f => vf32(@trunc(x)),
                        0x90 => vf32(nearest(f32, x)),
                        else => vf32(@sqrt(x)),
                    };
                },
                0x92...0x98 => {
                    sp -= 1;
                    const a = f32v(stack[sp - 1]);
                    const b = f32v(stack[sp]);
                    stack[sp - 1] = switch (ins.op) {
                        0x92 => vf32(a + b),
                        0x93 => vf32(a - b),
                        0x94 => vf32(a * b),
                        0x95 => vf32(a / b),
                        0x96 => vf32(fmin(f32, a, b)),
                        0x97 => vf32(fmax(f32, a, b)),
                        else => vf32(std.math.copysign(a, b)),
                    };
                },

                // ---- f64 ----
                0x99...0x9f => {
                    const x = f64v(stack[sp - 1]);
                    stack[sp - 1] = switch (ins.op) {
                        0x99 => stack[sp - 1] & 0x7fff_ffff_ffff_ffff,
                        0x9a => stack[sp - 1] ^ 0x8000_0000_0000_0000,
                        0x9b => vf64(@ceil(x)),
                        0x9c => vf64(@floor(x)),
                        0x9d => vf64(@trunc(x)),
                        0x9e => vf64(nearest(f64, x)),
                        else => vf64(@sqrt(x)),
                    };
                },
                0xa0...0xa6 => {
                    sp -= 1;
                    const a = f64v(stack[sp - 1]);
                    const b = f64v(stack[sp]);
                    stack[sp - 1] = switch (ins.op) {
                        0xa0 => vf64(a + b),
                        0xa1 => vf64(a - b),
                        0xa2 => vf64(a * b),
                        0xa3 => vf64(a / b),
                        0xa4 => vf64(fmin(f64, a, b)),
                        0xa5 => vf64(fmax(f64, a, b)),
                        else => vf64(std.math.copysign(a, b)),
                    };
                },

                // ---- dönüşümler ----
                0xa7 => stack[sp - 1] = stack[sp - 1] & 0xffff_ffff,
                0xa8 => stack[sp - 1] = @as(u32, @bitCast(try truncTrap(i32, f32, f32v(stack[sp - 1])))),
                0xa9 => stack[sp - 1] = try truncTrap(u32, f32, f32v(stack[sp - 1])),
                0xaa => stack[sp - 1] = @as(u32, @bitCast(try truncTrap(i32, f64, f64v(stack[sp - 1])))),
                0xab => stack[sp - 1] = try truncTrap(u32, f64, f64v(stack[sp - 1])),
                0xac => stack[sp - 1] = @bitCast(@as(i64, @as(i32, @bitCast(@as(u32, @truncate(stack[sp - 1])))))),
                0xad => stack[sp - 1] = stack[sp - 1] & 0xffff_ffff,
                0xae => stack[sp - 1] = @bitCast(try truncTrap(i64, f32, f32v(stack[sp - 1]))),
                0xaf => stack[sp - 1] = try truncTrap(u64, f32, f32v(stack[sp - 1])),
                0xb0 => stack[sp - 1] = @bitCast(try truncTrap(i64, f64, f64v(stack[sp - 1]))),
                0xb1 => stack[sp - 1] = try truncTrap(u64, f64, f64v(stack[sp - 1])),
                0xb2 => stack[sp - 1] = vf32(@floatFromInt(@as(i32, @bitCast(@as(u32, @truncate(stack[sp - 1])))))),
                0xb3 => stack[sp - 1] = vf32(@floatFromInt(@as(u32, @truncate(stack[sp - 1])))),
                0xb4 => stack[sp - 1] = vf32(@floatFromInt(@as(i64, @bitCast(stack[sp - 1])))),
                0xb5 => stack[sp - 1] = vf32(@floatFromInt(stack[sp - 1])),
                0xb6 => stack[sp - 1] = vf32(@floatCast(f64v(stack[sp - 1]))),
                0xb7 => stack[sp - 1] = vf64(@floatFromInt(@as(i32, @bitCast(@as(u32, @truncate(stack[sp - 1])))))),
                0xb8 => stack[sp - 1] = vf64(@floatFromInt(@as(u32, @truncate(stack[sp - 1])))),
                0xb9 => stack[sp - 1] = vf64(@floatFromInt(@as(i64, @bitCast(stack[sp - 1])))),
                0xba => stack[sp - 1] = vf64(@floatFromInt(stack[sp - 1])),
                0xbb => stack[sp - 1] = vf64(@floatCast(f32v(stack[sp - 1]))),
                0xbc, 0xbd, 0xbe, 0xbf => {}, // reinterpret: bit deseni aynı
                0xc0 => stack[sp - 1] = @as(u32, @bitCast(@as(i32, @as(i8, @truncate(@as(i64, @bitCast(stack[sp - 1]))))))),
                0xc1 => stack[sp - 1] = @as(u32, @bitCast(@as(i32, @as(i16, @truncate(@as(i64, @bitCast(stack[sp - 1]))))))),
                0xc2 => stack[sp - 1] = @bitCast(@as(i64, @as(i8, @truncate(@as(i64, @bitCast(stack[sp - 1])))))),
                0xc3 => stack[sp - 1] = @bitCast(@as(i64, @as(i16, @truncate(@as(i64, @bitCast(stack[sp - 1])))))),
                0xc4 => stack[sp - 1] = @bitCast(@as(i64, @as(i32, @truncate(@as(i64, @bitCast(stack[sp - 1])))))),

                // ---- referanslar ----
                0xd0 => {
                    stack[sp] = NULL_REF;
                    sp += 1;
                },
                0xd1 => stack[sp - 1] = @intFromBool(stack[sp - 1] == NULL_REF),
                0xd2 => {
                    stack[sp] = @as(u64, ins.a) + 1;
                    sp += 1;
                },

                // ---- 0xFC: doymalı dönüşümler ----
                compile.OP_FC + 0 => stack[sp - 1] = @as(u32, @bitCast(truncSat(i32, f32, f32v(stack[sp - 1])))),
                compile.OP_FC + 1 => stack[sp - 1] = truncSat(u32, f32, f32v(stack[sp - 1])),
                compile.OP_FC + 2 => stack[sp - 1] = @as(u32, @bitCast(truncSat(i32, f64, f64v(stack[sp - 1])))),
                compile.OP_FC + 3 => stack[sp - 1] = truncSat(u32, f64, f64v(stack[sp - 1])),
                compile.OP_FC + 4 => stack[sp - 1] = @bitCast(truncSat(i64, f32, f32v(stack[sp - 1]))),
                compile.OP_FC + 5 => stack[sp - 1] = truncSat(u64, f32, f32v(stack[sp - 1])),
                compile.OP_FC + 6 => stack[sp - 1] = @bitCast(truncSat(i64, f64, f64v(stack[sp - 1]))),
                compile.OP_FC + 7 => stack[sp - 1] = truncSat(u64, f64, f64v(stack[sp - 1])),

                // ---- 0xFC: bulk-memory ve tablo ----
                compile.OP_FC + 8 => { // memory.init
                    sp -= 3;
                    const d: u32 = @truncate(stack[sp]);
                    const s: u32 = @truncate(stack[sp + 1]);
                    const n: u32 = @truncate(stack[sp + 2]);
                    const seg: []const u8 = if (self.data_dropped[ins.a]) &.{} else module.datas[ins.a].bytes;
                    if (@as(u64, s) + n > seg.len or @as(u64, d) + n > self.mem.len) return error.OutOfBoundsMemoryAccess;
                    @memcpy(self.mem[d..][0..n], seg[s..][0..n]);
                },
                compile.OP_FC + 9 => self.data_dropped[ins.a] = true,
                compile.OP_FC + 10 => { // memory.copy
                    sp -= 3;
                    const d: u32 = @truncate(stack[sp]);
                    const s: u32 = @truncate(stack[sp + 1]);
                    const n: u32 = @truncate(stack[sp + 2]);
                    if (@as(u64, s) + n > self.mem.len or @as(u64, d) + n > self.mem.len) return error.OutOfBoundsMemoryAccess;
                    @memmove(self.mem[d..][0..n], self.mem[s..][0..n]);
                },
                compile.OP_FC + 11 => { // memory.fill
                    sp -= 3;
                    const d: u32 = @truncate(stack[sp]);
                    const v: u8 = @truncate(stack[sp + 1]);
                    const n: u32 = @truncate(stack[sp + 2]);
                    if (@as(u64, d) + n > self.mem.len) return error.OutOfBoundsMemoryAccess;
                    @memset(self.mem[d..][0..n], v);
                },
                compile.OP_FC + 12 => { // table.init
                    sp -= 3;
                    const d: u32 = @truncate(stack[sp]);
                    const s: u32 = @truncate(stack[sp + 1]);
                    const n: u32 = @truncate(stack[sp + 2]);
                    const seg: []const u64 = if (self.elem_dropped[ins.a]) &.{} else self.elem_vals[ins.a];
                    const t = &self.tables[@intCast(ins.b)];
                    if (@as(u64, s) + n > seg.len or @as(u64, d) + n > t.elems.len) return error.OutOfBoundsTableAccess;
                    @memcpy(t.elems[d..][0..n], seg[s..][0..n]);
                },
                compile.OP_FC + 13 => self.elem_dropped[ins.a] = true,
                compile.OP_FC + 14 => { // table.copy
                    sp -= 3;
                    const d: u32 = @truncate(stack[sp]);
                    const s: u32 = @truncate(stack[sp + 1]);
                    const n: u32 = @truncate(stack[sp + 2]);
                    const dt = &self.tables[ins.a];
                    const st = &self.tables[@intCast(ins.b)];
                    if (@as(u64, s) + n > st.elems.len or @as(u64, d) + n > dt.elems.len) return error.OutOfBoundsTableAccess;
                    @memmove(dt.elems[d..][0..n], st.elems[s..][0..n]);
                },
                compile.OP_FC + 15 => { // table.grow: [ref, n] -> eski boyut | -1
                    sp -= 1;
                    const n: u32 = @truncate(stack[sp]);
                    const init_v = stack[sp - 1];
                    stack[sp - 1] = self.tableGrow(ins.a, init_v, n);
                },
                compile.OP_FC + 16 => {
                    stack[sp] = self.tables[ins.a].elems.len;
                    sp += 1;
                },
                compile.OP_FC + 17 => { // table.fill: [i, ref, n]
                    sp -= 3;
                    const i: u32 = @truncate(stack[sp]);
                    const v = stack[sp + 1];
                    const n: u32 = @truncate(stack[sp + 2]);
                    const t = &self.tables[ins.a];
                    if (@as(u64, i) + n > t.elems.len) return error.OutOfBoundsTableAccess;
                    @memset(t.elems[i..][0..n], v);
                },
                else => unreachable, // derleyici yalnızca yukarıdaki op'ları üretir
            }
        }
    }

    inline fn effAddr(self: *const Instance, slot: u64, offset: u32, size: usize) Trap!usize {
        const e: u64 = @as(u64, @as(u32, @truncate(slot))) + offset;
        if (e + size > self.mem.len) return error.OutOfBoundsMemoryAccess;
        return @intCast(e);
    }

    fn memGrow(self: *Instance, delta: u32) u64 {
        const old: u32 = @intCast(self.mem.len / 65536);
        const new: u64 = @as(u64, old) + delta;
        if (new > self.mem_max_pages) return 0xffff_ffff;
        if (delta == 0) return old;
        const nm = self.allocator.realloc(self.mem, @as(usize, @intCast(new)) * 65536) catch return 0xffff_ffff;
        @memset(nm[self.mem.len..], 0);
        self.mem = nm;
        return old;
    }

    fn tableGrow(self: *Instance, tidx: u32, init_v: u64, n: u32) u64 {
        const t = &self.tables[tidx];
        const old: u32 = @intCast(t.elems.len);
        const new: u64 = @as(u64, old) + n;
        if (new > t.max) return 0xffff_ffff;
        if (n == 0) return old;
        const a = self.arena.allocator();
        const ne = a.alloc(u64, @intCast(new)) catch return 0xffff_ffff;
        @memcpy(ne[0..old], t.elems);
        @memset(ne[old..], init_v);
        t.elems = ne;
        return old;
    }

    /// Dışa aktarılan işlevi adıyla çağırır (ham yuvalar).
    pub fn callByName(self: *Instance, name: []const u8, args: []const u64, results: []u64) InterpError!void {
        const idx = self.findExport(name, .func) orelse return error.ExportNotFound;
        const ft = self.module.typeOf(idx);
        if (ft.params.len != args.len or ft.results.len != results.len) return error.TypeMismatch;
        for (ft.params) |t| if (t == .v128) return error.TypeMismatch;
        for (ft.results) |t| if (t == .v128) return error.TypeMismatch;
        try self.invoke(idx, args, results);
    }
};

fn findBinding(bindings: []const HostBinding, module: []const u8, name: []const u8) ?HostBinding {
    for (bindings) |b| {
        if (std.mem.eql(u8, b.module, module) and std.mem.eql(u8, b.name, name)) return b;
    }
    return null;
}

inline fn f32v(x: u64) f32 {
    return @bitCast(@as(u32, @truncate(x)));
}
inline fn vf32(f: f32) u64 {
    return @as(u32, @bitCast(f));
}
inline fn f64v(x: u64) f64 {
    return @bitCast(x);
}
inline fn vf64(f: f64) u64 {
    return @bitCast(f);
}

pub fn fmin(comptime T: type, a: T, b: T) T {
    if (std.math.isNan(a) or std.math.isNan(b)) return std.math.nan(T);
    if (a == 0 and b == 0) return if (std.math.signbit(a)) a else b;
    return if (a < b) a else b;
}

pub fn fmax(comptime T: type, a: T, b: T) T {
    if (std.math.isNan(a) or std.math.isNan(b)) return std.math.nan(T);
    if (a == 0 and b == 0) return if (std.math.signbit(a)) b else a;
    return if (a > b) a else b;
}

/// En yakın tamsayı, eşitlikte çifte yuvarlama (IEEE roundToIntegralTiesToEven).
pub fn nearest(comptime T: type, x: T) T {
    if (!std.math.isFinite(x) or x == 0) return x;
    const lim: T = if (T == f32) 8388608.0 else 4503599627370496.0;
    if (@abs(x) >= lim) return x;
    const t = @trunc(x);
    const diff = @abs(x - t);
    if (diff < 0.5) return if (t == 0) std.math.copysign(@as(T, 0), x) else t;
    if (diff > 0.5) return t + std.math.sign(x);
    // tam yarı: çifte git
    if (@mod(t, 2) == 0) return if (t == 0) std.math.copysign(@as(T, 0), x) else t;
    return t + std.math.sign(x);
}

fn truncBounds(comptime I: type, comptime F: type) struct { lo: F, hi: F } {
    const bits = @typeInfo(I).int.bits;
    const signed = @typeInfo(I).int.signedness == .signed;
    const hi: F = std.math.ldexp(@as(F, 1.0), if (signed) bits - 1 else bits);
    const lo: F = if (signed) -hi else 0;
    return .{ .lo = lo, .hi = hi };
}

fn truncTrap(comptime I: type, comptime F: type, x: F) Trap!I {
    if (std.math.isNan(x)) return error.InvalidConversionToInteger;
    const t = @trunc(x);
    const b = comptime truncBounds(I, F);
    if (t < b.lo or t >= b.hi) return error.IntegerOverflow;
    return @intFromFloat(t);
}

pub fn truncSat(comptime I: type, comptime F: type, x: F) I {
    if (std.math.isNan(x)) return 0;
    const t = @trunc(x);
    const b = comptime truncBounds(I, F);
    if (t < b.lo) return std.math.minInt(I);
    if (t >= b.hi) return std.math.maxInt(I);
    return @intFromFloat(t);
}

// ---------------------------------------------------------------- eski (i32) API ve HPy birleştirmesi

/// `func_index`i, verilen `args` (i32) ile çalıştırır (eski basit API: içe aktarmasız modüller için). Bir değer döndürüyorsa onu, `void` ise `null` döner.
pub fn callFunc(allocator: std.mem.Allocator, module: *const Module, func_index: u32, args: []const i32) InterpError!?i32 {
    const ftype = module.typeOf(func_index);
    if (ftype.params.len != args.len) return error.TypeMismatch;
    if (args.len > 16) return error.TooManyArgs;
    for (ftype.params) |p| if (p != .i32) return error.TypeMismatch;
    for (ftype.results) |p| if (p != .i32) return error.TypeMismatch;
    if (ftype.results.len > 1) return error.TypeMismatch;
    var slots: [16]u64 = undefined;
    for (args, 0..) |a, i| slots[i] = @as(u32, @bitCast(a));
    const inst = try Instance.init(allocator, module, &.{}, .{});
    defer inst.deinit();
    var res: [1]u64 = undefined;
    try inst.invoke(func_index, slots[0..args.len], res[0..ftype.results.len]);
    if (ftype.results.len == 0) return null;
    return @bitCast(@as(u32, @truncate(res[0])));
}

/// `module`nin `name` adında export edilmiş bir işlevini çağırır. Argümanlar ve dönüş değeri, `hpy_bridge/context.zig`nin AYNI `HPy` handle sistemiyle
/// alınıp verilir (tamsayı ve `f32`/`f64` argümanlar; tek sonuç).
pub fn callExport(allocator: std.mem.Allocator, ctx: *HPyContext, module: *const Module, name: []const u8, args: []const HPy) InterpError!HPy {
    const func_index = module.findExportedFunc(name) orelse return error.ExportNotFound;
    const ft = module.typeOf(func_index);
    if (args.len != ft.params.len) return error.TypeMismatch;
    if (args.len > 16) return error.TooManyArgs;
    var slots: [16]u64 = undefined;
    for (args, 0..) |a, i| {
        slots[i] = switch (ft.params[i]) {
            .i32 => @as(u32, @truncate(@as(u64, @bitCast(ctx.ctx_Long_AsInt64_t.?(ctx, a))))),
            .i64 => @bitCast(ctx.ctx_Long_AsInt64_t.?(ctx, a)),
            .f32 => vf32(@floatCast(ctx.ctx_Float_AsDouble.?(ctx, a))),
            .f64 => vf64(ctx.ctx_Float_AsDouble.?(ctx, a)),
            else => return error.TypeMismatch,
        };
    }
    if (ft.results.len > 1) return error.TypeMismatch;
    const inst = try Instance.init(allocator, module, &.{}, .{});
    defer inst.deinit();
    var res: [1]u64 = undefined;
    try inst.invoke(func_index, slots[0..args.len], res[0..ft.results.len]);
    if (ft.results.len == 0) return hpy_context.HPy_NULL;
    return switch (ft.results[0]) {
        .i32 => ctx.ctx_Long_FromInt64_t.?(ctx, @as(i32, @bitCast(@as(u32, @truncate(res[0]))))),
        .i64 => ctx.ctx_Long_FromInt64_t.?(ctx, @bitCast(res[0])),
        .f32 => ctx.ctx_Float_FromDouble.?(ctx, f32v(res[0])),
        .f64 => ctx.ctx_Float_FromDouble.?(ctx, f64v(res[0])),
        else => error.TypeMismatch,
    };
}

// ---------------------------------------------------------------- testler

const add_one_bytes = "\x00asm\x01\x00\x00\x00\x01\x06\x01\x60\x01\x7f\x01\x7f\x03\x02\x01\x00\x04\x05\x01\x70\x01\x01\x01\x05\x03\x01\x00\x10\x06\x09\x01\x7f\x01\x41\x80\x80\xc0\x00\x0b\x07\x14\x02\x06memory\x02\x00\x07add_one\x00\x00\x0a\x09\x01\x07\x00\x20\x00\x41\x01\x6a\x0b";

test "callFunc: gerçek zig-derlenmiş add_one modülünü çalıştırır" {
    var mod = try module_mod.parse(std.testing.allocator, add_one_bytes);
    defer mod.deinit();
    const idx = mod.findExportedFunc("add_one").?;
    const result = try callFunc(std.testing.allocator, &mod, idx, &.{41});
    try std.testing.expectEqual(@as(i32, 42), result.?);
}

test "callExport: HPy handle sistemi üzerinden çağrı" {
    var mod = try module_mod.parse(std.testing.allocator, add_one_bytes);
    defer mod.deinit();

    const ctx = try hpy_context.createContext(std.testing.allocator);
    defer hpy_context.destroyContext(std.testing.allocator, ctx);

    const arg = ctx.ctx_Long_FromInt64_t.?(ctx, 41);
    defer ctx.ctx_Close.?(ctx, arg);

    const result = try callExport(std.testing.allocator, ctx, &mod, "add_one", &.{arg});
    defer ctx.ctx_Close.?(ctx, result);

    try std.testing.expectEqual(@as(i64, 42), ctx.ctx_Long_AsInt64_t.?(ctx, result));
}

test "nearest: eşitlikte çifte yuvarlama, işaretli sıfır" {
    try std.testing.expectEqual(@as(f64, 2), nearest(f64, 2.5));
    try std.testing.expectEqual(@as(f64, 4), nearest(f64, 3.5));
    try std.testing.expectEqual(@as(f64, -2), nearest(f64, -1.5));
    try std.testing.expectEqual(@as(f64, 0), nearest(f64, 0.5));
    try std.testing.expect(std.math.signbit(nearest(f64, -0.5)));
    try std.testing.expect(std.math.signbit(nearest(f64, -0.2)));
    try std.testing.expectEqual(@as(f32, 8388609), nearest(f32, 8388609));
}

test "truncTrap/truncSat: sınırlar" {
    try std.testing.expectEqual(@as(i32, -2147483648), try truncTrap(i32, f64, -2147483648.9));
    try std.testing.expectError(error.IntegerOverflow, truncTrap(i32, f64, 2147483648.0));
    try std.testing.expectError(error.InvalidConversionToInteger, truncTrap(i32, f32, std.math.nan(f32)));
    try std.testing.expectEqual(@as(u32, 0), try truncTrap(u32, f32, -0.9));
    try std.testing.expectError(error.IntegerOverflow, truncTrap(u32, f32, -1.0));
    try std.testing.expectEqual(@as(i32, std.math.maxInt(i32)), truncSat(i32, f32, 3e10));
    try std.testing.expectEqual(@as(u64, std.math.maxInt(u64)), truncSat(u64, f64, 1e30));
    try std.testing.expectEqual(@as(i64, 0), truncSat(i64, f64, std.math.nan(f64)));
}
