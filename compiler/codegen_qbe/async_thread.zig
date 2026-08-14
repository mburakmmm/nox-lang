//! Async/thread/HTTP-sarmalayıcı tespiti + codegen'i — bkz. plan dosyası
//! "QBE codegen backend'ini alt modüllere bölme". `spawn`/`await`/
//! `Channel[T]`/`nox.thread.start`/`nox.http.serve*` ile ilgili KOD YOLLARI
//! burada toplanır.

const std = @import("std");
const ast = @import("../parser/ast.zig");
const types = @import("types.zig");
const abi = @import("abi.zig");
const codegen = @import("codegen.zig");

const Codegen = codegen.Codegen;
const Value = types.Value;
const QbeType = types.QbeType;
const ElemHeapInfo = types.ElemHeapInfo;
const SpawnWrapperSpec = types.SpawnWrapperSpec;
const ThreadWrapperSpec = types.ThreadWrapperSpec;
const RT_PARAM = types.RT_PARAM;
const CodegenError = abi.CodegenError;
const valueFromElemDescriptor = abi.valueFromElemDescriptor;

/// Modülün (üst düzey deyimler + tüm fonksiyon/metod gövdeleri) HERHANGİ bir
/// yerinde `async` özelliği (bir `async def`, `spawn`, `await`, ya da
/// `Channel[T](...)`) kullanılıp kullanılmadığını belirler — `generateModule`
/// bunu, `main`i fiber-sarmalı bir kökle mi (`genMainAsync`) yoksa ŞİMDİYE
/// KADAR OLDUĞU GİBİ değişmeden mi (`genMain`) üreteceğine karar vermek için
/// kullanır.
pub fn moduleUsesAsync(module: ast.Module, extra_functions: []const ast.FuncDef) bool {
    for (module.body) |stmt| if (stmtUsesAsync(stmt)) return true;
    for (extra_functions) |fd| {
        if (fd.is_async) return true;
        for (fd.body) |s| if (stmtUsesAsync(s)) return true;
    }
    return false;
}

pub fn stmtUsesAsync(stmt: ast.Stmt) bool {
    return switch (stmt.kind) {
        .expr_stmt => |e| exprUsesAsync(e),
        .var_decl => |v| exprUsesAsync(v.value),
        .assign => |a| exprUsesAsync(a.target) or exprUsesAsync(a.value),
        .if_stmt => |f| blk: {
            if (exprUsesAsync(f.cond)) break :blk true;
            for (f.then_body) |s| if (stmtUsesAsync(s)) break :blk true;
            for (f.elif_clauses) |ec| {
                if (exprUsesAsync(ec.cond)) break :blk true;
                for (ec.body) |s| if (stmtUsesAsync(s)) break :blk true;
            }
            if (f.else_body) |eb| for (eb) |s| if (stmtUsesAsync(s)) break :blk true;
            break :blk false;
        },
        .while_stmt => |w| blk: {
            if (exprUsesAsync(w.cond)) break :blk true;
            for (w.body) |s| if (stmtUsesAsync(s)) break :blk true;
            break :blk false;
        },
        .for_stmt => |f| blk: {
            if (exprUsesAsync(f.iterable)) break :blk true;
            for (f.body) |s| if (stmtUsesAsync(s)) break :blk true;
            break :blk false;
        },
        .func_def => |fd| blk: {
            if (fd.is_async) break :blk true;
            for (fd.body) |s| if (stmtUsesAsync(s)) break :blk true;
            break :blk false;
        },
        .class_def => |cd| blk: {
            for (cd.methods) |m| {
                if (m.is_async) break :blk true;
                for (m.body) |s| if (stmtUsesAsync(s)) break :blk true;
            }
            break :blk false;
        },
        .protocol_def, .extern_def, .pass_stmt, .import_stmt, .from_import_stmt => false,
        .return_stmt => |r| if (r) |e| exprUsesAsync(e) else false,
        .raise_stmt => |e| exprUsesAsync(e),
        .try_stmt => |t| blk: {
            for (t.try_body) |s| if (stmtUsesAsync(s)) break :blk true;
            for (t.except_clauses) |ec| for (ec.body) |s| if (stmtUsesAsync(s)) break :blk true;
            if (t.finally_body) |fb| for (fb) |s| if (stmtUsesAsync(s)) break :blk true;
            break :blk false;
        },
        .lowlevel_stmt => |ll| blk: {
            for (ll.body) |s| if (stmtUsesAsync(s)) break :blk true;
            break :blk false;
        },
        .with_stmt => |w| blk: {
            if (exprUsesAsync(w.ctx_expr)) break :blk true;
            for (w.body) |s| if (stmtUsesAsync(s)) break :blk true;
            break :blk false;
        },
        .defer_stmt => |d| exprUsesAsync(ast.Expr{ .call = d.call }),
    };
}

/// `nox.<module>.<name>(...)` çağrı sitesinin callee'sinin TAM OLARAK bu
/// şekilde (üç seviyeli `Attribute`/`Attribute`/`identifier` zinciri)
/// ayrıştırılıp ayrıştırılMADIĞINI belirler.
///
/// Faz P1.6 (bkz. proje belleği "stdlib-vs-language boundary" kararı):
/// ÖNCEDEN bu, yalnızca "http" modülüne özel `matchesNoxHttpAttr` OLARAK
/// (VE `nox.thread.start` İçin AYNI yürüyüşü TEKRARLAYAN AYRI bir
/// `isThreadStartCallee` OLARAK) İKİ KOPYA halinde vardı — TEK parametrik
/// sürüme birleştirildi (bkz. AŞAĞIDAKİ `intrinsic_table`/`matchIntrinsicKind`).
pub fn matchesNoxAttr(callee: ast.Expr, module: []const u8, name: []const u8) bool {
    if (callee != .attribute) return false;
    const attr = callee.attribute;
    if (!std.mem.eql(u8, attr.attr, name)) return false;
    if (attr.obj.* != .attribute) return false;
    const mod_attr = attr.obj.attribute;
    if (!std.mem.eql(u8, mod_attr.attr, module)) return false;
    if (mod_attr.obj.* != .identifier) return false;
    return std.mem.eql(u8, mod_attr.obj.identifier, "nox");
}

/// Codegen'in genel çağrı yolunun (bkz. `calls.zig`nin `genCall`i, `.attribute`
/// dalı) ÖZEL bir kod yolu GEREKTİREN (sıradan bir fonksiyon çağrısına
/// İNDİRGENEMEYEN — ör. bir sarmalayıcı/thread/worker fonksiyonu İNŞA ETMESİ
/// gereken) bir stdlib "intrinsic" çağrısını sınıflandırır. Bu, P1.1'in
/// `http_intrinsics.zig`nin modül üstü notunun İŞARET ettiği "P1.6'nın GENEL
/// intrinsic mekanizması" — ÖNCEDEN `genCall`/`exprUsesAsync` HER İKİSİ de,
/// HER intrinsic İçin AYRI bir `isXCallee` fonksiyonuna karşı SIRALI `if`
/// zincirleri taşıyordu (4 kontrol × 2 çağrı sitesi). YENİ bir intrinsic
/// EKLEMEK ARTIK yalnızca `intrinsic_table`e BİR satır + `IntrinsicKind`e
/// BİR varyant + `genCall`nin dispatch switch'ine BİR `case` eklemektir —
/// `exprUsesAsync` HİÇ DEĞİŞMEZ (TÜM intrinsic'ler ZATEN async-tetikleyici
/// olduğundan `matchIntrinsicKind(...) != null` TEK kontrolü yeterlidir).
pub const IntrinsicKind = enum {
    http_serve,
    http_serve_fd,
    http_serve_multicore,
    // Faz "sunucu-tarafı TLS + WebSocket Upgrade" (bkz. plan dosyası §6,
    // TAM 12'lik isim matrisi) — çıplak `http_serve`/`http_serve_fd`/
    // `http_serve_multicore`nin `_tls`/`_ws`/`_ws_tls` UZANTILARI. Codegen
    // TARAFI (`calls.zig`nin dispatch switch'i) HEPSİNİ `genHttpServe*
    // Generic(c, want_tls, want_ws)` ÜÇLÜSÜNE yönlendirir — bu varyantların
    // HİÇBİRİ KENDİ AYRI bir codegen fonksiyonuna İHTİYAÇ DUYMAZ.
    http_serve_tls,
    http_serve_ws,
    http_serve_ws_tls,
    http_serve_fd_tls,
    http_serve_fd_ws,
    http_serve_fd_ws_tls,
    http_serve_multicore_tls,
    http_serve_multicore_ws,
    http_serve_multicore_ws_tls,
    thread_start,
    pool_run,
};

const IntrinsicEntry = struct { module: []const u8, name: []const u8, kind: IntrinsicKind };

const intrinsic_table = [_]IntrinsicEntry{
    .{ .module = "http", .name = "serve", .kind = .http_serve },
    .{ .module = "http", .name = "serve_fd", .kind = .http_serve_fd },
    .{ .module = "http", .name = "serve_multicore", .kind = .http_serve_multicore },
    .{ .module = "http", .name = "serve_tls", .kind = .http_serve_tls },
    .{ .module = "http", .name = "serve_ws", .kind = .http_serve_ws },
    .{ .module = "http", .name = "serve_ws_tls", .kind = .http_serve_ws_tls },
    .{ .module = "http", .name = "serve_fd_tls", .kind = .http_serve_fd_tls },
    .{ .module = "http", .name = "serve_fd_ws", .kind = .http_serve_fd_ws },
    .{ .module = "http", .name = "serve_fd_ws_tls", .kind = .http_serve_fd_ws_tls },
    .{ .module = "http", .name = "serve_multicore_tls", .kind = .http_serve_multicore_tls },
    .{ .module = "http", .name = "serve_multicore_ws", .kind = .http_serve_multicore_ws },
    .{ .module = "http", .name = "serve_multicore_ws_tls", .kind = .http_serve_multicore_ws_tls },
    .{ .module = "thread", .name = "start", .kind = .thread_start },
    .{ .module = "thread", .name = "pool_run", .kind = .pool_run },
};

pub fn matchIntrinsicKind(callee: ast.Expr) ?IntrinsicKind {
    for (intrinsic_table) |entry| {
        if (matchesNoxAttr(callee, entry.module, entry.name)) return entry.kind;
    }
    return null;
}

pub fn exprUsesAsync(expr: ast.Expr) bool {
    return switch (expr) {
        .await_expr, .spawn_expr, .generic_construct => true,
        .unary => |u| exprUsesAsync(u.operand.*),
        .binary => |b| exprUsesAsync(b.left.*) or exprUsesAsync(b.right.*),
        .call => |c| blk: {
            if (matchIntrinsicKind(c.callee.*) != null) break :blk true;
            if (exprUsesAsync(c.callee.*)) break :blk true;
            for (c.args) |a| if (exprUsesAsync(a)) break :blk true;
            break :blk false;
        },
        .attribute => |a| exprUsesAsync(a.obj.*),
        .index => |idx| exprUsesAsync(idx.obj.*) or exprUsesAsync(idx.index.*),
        .list_lit => |elems| blk: {
            for (elems) |el| if (exprUsesAsync(el)) break :blk true;
            break :blk false;
        },
        .dict_lit => |pairs| blk: {
            for (pairs) |p| {
                if (exprUsesAsync(p.key) or exprUsesAsync(p.value)) break :blk true;
            }
            break :blk false;
        },
        .int_lit, .float_lit, .bool_lit, .string_lit, .none_lit, .identifier => false,
    };
}

/// Performans (bkz. proje planı, "Nox tavan hızı" bölümü, Madde 3):
/// `matchIntrinsicKind`in 5 türünden (`serve_multicore` AİLESİ + `pool_run`)
/// SADECE BUNLARIN "GERÇEKTEN çoklu-worker İSTİYOR" SAYILDIĞINI belirler
/// — çıplak `spawn`/`await`/`Channel[T]`/`nox.thread.start` (`moduleUsesAsync`nin
/// KOŞULSUZ `true` SAYDIĞI türler) BU sınıflandırmaya DAHİL DEĞİL.
fn isMulticorePoolKind(kind: IntrinsicKind) bool {
    return switch (kind) {
        .http_serve_multicore,
        .http_serve_multicore_tls,
        .http_serve_multicore_ws,
        .http_serve_multicore_ws_tls,
        .pool_run,
        => true,
        .http_serve, .http_serve_fd, .http_serve_tls, .http_serve_ws, .http_serve_ws_tls, .http_serve_fd_tls, .http_serve_fd_ws, .http_serve_fd_ws_tls, .thread_start => false,
    };
}

/// Performans (bkz. proje planı, "Nox tavan hızı" bölümü, Madde 3):
/// `moduleUsesAsync`/`stmtUsesAsync`/`exprUsesAsync`nin (yukarıda) AYNI
/// AST-yürüyüş ŞEKLİNİ TEKRARLAYAN, AMA BAĞIMSIZ, DAHA DAR bir İKİNCİ
/// geçiş — `$main`in `--release` altındaki otomatik havuzunun (bkz.
/// `pool_bridge.zig`nin `pickMainWorkerCount`ı) CPU-sayısı YERİNE küçük
/// bir SABİTE düşüp DÜŞMEYECEĞİNE karar vermek İçİn kullanılır. AYRI bir
/// fonksiyon OLARAK tutulması (mevcut `moduleUsesAsync`i GENİŞLETMEK
/// YERİNE) BİLİNÇLİ bir tasarım kararı: `moduleUsesAsync`nin agresif
/// kısa-devresi (`break :blk true`, İLK tetikleyicide) BU DAHA DAR sinyali
/// YAKALAYAMAZ (ör. modülün BAŞINDA bir çıplak `spawn` VARSA `moduleUsesAsync`
/// HEMEN `true` döner AMA modülün SONUNDAKİ bir `serve_multicore` çağrısı
/// ASLA ziyaret EDİLMEZ) — İKİ AYRI, TAM geçiş bunu ÖNLER. Zig'in
/// ayrıntılı-switch zorunluluğu (gelecekte YENİ bir `ast.Expr`/`Stmt`
/// varyantı HER İKİ yürüyüşTE de AYRI AYRI derleme hatası verir) "iki
/// yürüyüşün senkron kalması" riskini KENDİLİĞİNDEN sınırlar.
pub fn moduleUsesMulticorePool(module: ast.Module, extra_functions: []const ast.FuncDef) bool {
    for (module.body) |stmt| if (stmtUsesMulticorePool(stmt)) return true;
    for (extra_functions) |fd| {
        for (fd.body) |s| if (stmtUsesMulticorePool(s)) return true;
    }
    return false;
}

pub fn stmtUsesMulticorePool(stmt: ast.Stmt) bool {
    return switch (stmt.kind) {
        .expr_stmt => |e| exprUsesMulticorePool(e),
        .var_decl => |v| exprUsesMulticorePool(v.value),
        .assign => |a| exprUsesMulticorePool(a.target) or exprUsesMulticorePool(a.value),
        .if_stmt => |f| blk: {
            if (exprUsesMulticorePool(f.cond)) break :blk true;
            for (f.then_body) |s| if (stmtUsesMulticorePool(s)) break :blk true;
            for (f.elif_clauses) |ec| {
                if (exprUsesMulticorePool(ec.cond)) break :blk true;
                for (ec.body) |s| if (stmtUsesMulticorePool(s)) break :blk true;
            }
            if (f.else_body) |eb| for (eb) |s| if (stmtUsesMulticorePool(s)) break :blk true;
            break :blk false;
        },
        .while_stmt => |w| blk: {
            if (exprUsesMulticorePool(w.cond)) break :blk true;
            for (w.body) |s| if (stmtUsesMulticorePool(s)) break :blk true;
            break :blk false;
        },
        .for_stmt => |f| blk: {
            if (exprUsesMulticorePool(f.iterable)) break :blk true;
            for (f.body) |s| if (stmtUsesMulticorePool(s)) break :blk true;
            break :blk false;
        },
        .func_def => |fd| blk: {
            for (fd.body) |s| if (stmtUsesMulticorePool(s)) break :blk true;
            break :blk false;
        },
        .class_def => |cd| blk: {
            for (cd.methods) |m| {
                for (m.body) |s| if (stmtUsesMulticorePool(s)) break :blk true;
            }
            break :blk false;
        },
        .protocol_def, .extern_def, .pass_stmt, .import_stmt, .from_import_stmt => false,
        .return_stmt => |r| if (r) |e| exprUsesMulticorePool(e) else false,
        .raise_stmt => |e| exprUsesMulticorePool(e),
        .try_stmt => |t| blk: {
            for (t.try_body) |s| if (stmtUsesMulticorePool(s)) break :blk true;
            for (t.except_clauses) |ec| for (ec.body) |s| if (stmtUsesMulticorePool(s)) break :blk true;
            if (t.finally_body) |fb| for (fb) |s| if (stmtUsesMulticorePool(s)) break :blk true;
            break :blk false;
        },
        .lowlevel_stmt => |ll| blk: {
            for (ll.body) |s| if (stmtUsesMulticorePool(s)) break :blk true;
            break :blk false;
        },
        .with_stmt => |w| blk: {
            if (exprUsesMulticorePool(w.ctx_expr)) break :blk true;
            for (w.body) |s| if (stmtUsesMulticorePool(s)) break :blk true;
            break :blk false;
        },
        .defer_stmt => |d| exprUsesMulticorePool(ast.Expr{ .call = d.call }),
    };
}

pub fn exprUsesMulticorePool(expr: ast.Expr) bool {
    return switch (expr) {
        .await_expr => |e| exprUsesMulticorePool(e.*),
        .spawn_expr => |e| exprUsesMulticorePool(e.*),
        .generic_construct => |gc| blk: {
            for (gc.args) |a| if (exprUsesMulticorePool(a)) break :blk true;
            break :blk false;
        },
        .unary => |u| exprUsesMulticorePool(u.operand.*),
        .binary => |b| exprUsesMulticorePool(b.left.*) or exprUsesMulticorePool(b.right.*),
        .call => |c| blk: {
            if (matchIntrinsicKind(c.callee.*)) |k| if (isMulticorePoolKind(k)) break :blk true;
            if (exprUsesMulticorePool(c.callee.*)) break :blk true;
            for (c.args) |a| if (exprUsesMulticorePool(a)) break :blk true;
            break :blk false;
        },
        .attribute => |a| exprUsesMulticorePool(a.obj.*),
        .index => |idx| exprUsesMulticorePool(idx.obj.*) or exprUsesMulticorePool(idx.index.*),
        .list_lit => |elems| blk: {
            for (elems) |el| if (exprUsesMulticorePool(el)) break :blk true;
            break :blk false;
        },
        .dict_lit => |pairs| blk: {
            for (pairs) |p| {
                if (exprUsesMulticorePool(p.key) or exprUsesMulticorePool(p.value)) break :blk true;
            }
            break :blk false;
        },
        .int_lit, .float_lit, .bool_lit, .string_lit, .none_lit, .identifier => false,
    };
}

/// `spawn <hedef_fn>(args...)` — checker ZATEN operandın `.call` olup
/// `.identifier` bir `async def`e başvurduğunu doğruladı (bkz.
/// checker.zig'in `.spawn_expr` dalı); codegen burada bu ŞEKLE GÜVENİR.
/// Argümanlar bir kapanış (closure) struct'ına PAKETLENİR (`rt` + her
/// argüman, 8 baytlık aralıklarla — `nox_alloc` ile tahsis edilir,
/// sarmalayıcı KENDİSİ tüketip serbest bırakır, bkz. `genSpawnWrapper`).
/// `async def` parametreleri checker tarafından FFI-güvenli tiplerle
/// (int/float/bool/str/None) SINIRLANDI (bkz. checker.zig, `registerFunc`)
/// — bu yüzden hiçbir ARC retain/release GEREKMEZ.
pub fn genSpawnExpr(self: *Codegen, operand: ast.Expr) CodegenError!Value {
    const call = operand.call;
    const fn_name = call.callee.identifier;
    const sig = self.functions.get(fn_name) orelse return error.Unsupported;
    if (sig.params.len != call.args.len) return error.Unsupported;

    const arg_values = try self.allocator.alloc(Value, call.args.len);
    for (call.args, 0..) |a, i| {
        const v0 = try self.genExpr(a);
        arg_values[i] = try self.convert(v0, sig.params[i].qtype);
    }

    const closure_size = 8 + 8 * call.args.len;
    const closure = try self.newTemp();
    try self.qbeCall(.{ .name = closure, .ty = .l }, "$nox_alloc", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = try std.fmt.allocPrint(self.allocator, "{d}", .{closure_size}) } });
    try self.qbeStoreL(RT_PARAM, closure);
    for (arg_values, 0..) |av, i| {
        // Faz MN.9.4: `self.backend == .llvm` İKEN `list`/`class`/`dict`
        // tipli bir argüman (checker'ın `isSpawnParamSafeType`si BUNLARI
        // SADECE LLVM altında geçirir, bkz. onun belge notu) kapanışa
        // YAZILMADAN ÖNCE RETAIN edilir — kapanış (VE onu tüketen `genSpawn
        // Wrapper`) böylece BAĞIMSIZ, KENDİ sahip olduğu bir referans taşır
        // (görev BAŞKA bir worker'a ÇALINIP, ÇAĞIRAN çoktan dönmüş/`av`nin
        // ORİJİNAL kaynağı [YEREL değişken İSE kapsam-sonunda, GEÇİCİ İSE
        // aşağıdaki `releaseIfTemporary` İLE] serbest bırakılmış OLSA BİLE
        // GÜVENLE hayatta kalır). `emitInlineRetain`nin KENDİSİ `qbeAtomicAdd`
        // ÜZERİNDEN (MN.1) GERÇEKTEN atomiktir — QBE'de BU KOD YOLU HİÇ
        // ÇALIŞMAZ (checker list/class/dict'i `.qbe`de HİÇ GEÇİRMEZ).
        if (self.backend == .llvm and (av.heap == .list or av.heap == .class or av.heap == .dict)) {
            try self.emitInlineRetain(av.text, av.heap);
        } else if (self.isSpawnRefcountedType(av.heap)) {
            // v1.29.12: `Task[T]`/`Channel[T]` (bkz. `ownership.zig`nin
            // `isSpawnRefcountedType`sinin belge notu — GERÇEK, canlı bir
            // SIGSEGV reprodüksiyonuyla bulunan bir hata İçİn) — list/
            // class/dict'in AKSİNE BACKEND-BAĞIMSIZ (`isSpawnParamSafeType`
            // BUNLARI HER İKİ backend'de de İZİN VERİR).
            try self.retainNonArcValue(av.text, av.heap);
        }
        const off = 8 + 8 * i;
        const addr = try self.newTemp();
        try self.qbeOp2Imm(addr, .l, "add", closure, @intCast(off));
        try self.qbeStore(av.qtype, av.text, addr);
    }
    // Faz MN.9.4: YUKARIDAKİ retain'in EŞLEŞEN yarısı — ÇAĞIRANIN KENDİ
    // (GEÇİCİYSE) sahipliği BIRAKILIR (kapanış ZATEN KENDİ bağımsız
    // referansını ALDI); bir DEĞİŞKEN İSE bu NO-OP'tur (`releaseIfTemporary`
    // SADECE GERÇEKTEN geçici ifadeler İçİn serbest bırakır), değişkenin
    // KENDİ kapsamı DEĞİŞMEDEN normal şekilde YÖNETMEYE devam eder.
    if (self.backend == .llvm) {
        for (call.args, 0..) |a, i| {
            if (arg_values[i].heap == .list or arg_values[i].heap == .class or arg_values[i].heap == .dict) {
                try self.releaseIfTemporary(a, arg_values[i]);
            }
        }
    }
    // v1.29.12: YUKARIDAKİ `Task[T]`/`Channel[T]` retain'inin EŞLEŞEN
    // yarısı — BACKEND-BAĞIMSIZ (bkz. YUKARIDAKİ retain'in AYNI notu).
    for (call.args, 0..) |a, i| {
        try self.releaseNonArcIfTemporary(a, arg_values[i]);
    }

    const wrapper_name = try std.fmt.allocPrint(self.allocator, "spawn_wrap_{d}", .{self.spawn_wrapper_counter});
    self.spawn_wrapper_counter += 1;
    try self.spawn_wrappers.append(self.allocator, .{ .name = wrapper_name, .target_fn = fn_name, .sig = sig });

    const wrapper_sym = try std.fmt.allocPrint(self.allocator, "${s}", .{wrapper_name});
    const task_ptr = try self.newTemp();
    try self.qbeCall(.{ .name = task_ptr, .ty = .l }, "$nox_async_spawn", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = wrapper_sym }, .{ .ty = .l, .text = closure } });

    var elem_heap_info: ?*const ElemHeapInfo = null;
    if (sig.ret.heap == .class or sig.ret.heap == .list) {
        const info = try self.allocator.create(ElemHeapInfo);
        info.* = .{ .heap = sig.ret.heap, .class_name = sig.ret.class_name, .elem_qtype = sig.ret.elem_qtype, .nested = sig.ret.elem_heap_info, .elem_is_str = sig.ret.elem_is_str };
        elem_heap_info = info;
    }
    // `Task[T]`nin KENDİSİ (görev tutamacı) ARC-yönetimli DEĞİLDİR (bkz.
    // `HeapKind`in belge notu) — `heap = .task` yalnızca kapsam-sonu
    // `nox_async_destroy_task` çağrısını tetiklemek İÇİNDİR; `elem_*`
    // alanları T'yi (payload tipini) taşır.
    return .{
        .text = task_ptr,
        .qtype = .l,
        .heap = .task,
        .elem_qtype = sig.ret.qtype,
        .elem_heap_info = elem_heap_info,
        .elem_is_str = sig.ret.heap == .str,
    };
}

/// `nox_async_spawn`in çağırdığı, `spawn` çağrı sitesi başına üretilen
/// bir fiber girişi — bkz. `SpawnWrapperSpec`in belge notu. `%argp`den
/// (kapanış) argümanları paketten çıkarır, `spec.target_fn`i normal
/// şekilde çağırır, sonucu bir `i64` payload'a çevirir, kapanışı serbest
/// bırakır.
///
/// **Bilinçli v0.1 sınırlaması:** `spec.target_fn`in içinde bir istisna
/// oluşup YAKALANMAZSA, bu BURADA denetlenmez/temizlenmez (bkz.
/// nox-teknik-spesifikasyon.md §3.21'in "kalan" notu) — Nox'un istisna
/// mekanizmasının async görevlerle tam entegrasyonu ayrı bir artımdır.
pub fn genSpawnWrapper(self: *Codegen, spec: SpawnWrapperSpec) CodegenError!void {
    self.temp_counter = 0;
    self.label_counter = 0;
    // Bkz. `Codegen.mod_cache`nin belge notu: slot ADLARI ("%t0", ...)
    // SADECE bir FONKSİYON içinde benzersizdir (`temp_counter` HER
    // fonksiyon BAŞLANGICINDA sıfırlanır, tıpkı BURADA olduğu gibi) —
    // BİR ÖNCEKİ fonksiyondan kalan bir önbellek girdisi, BU fonksiyonda
    // AYNI ADI TAŞIYAN TAMAMEN FARKLI bir slotla YANLIŞLIKLA eşleşebilir
    // (çapraz-fonksiyon çakışması). Bu YÜZDEN HER fonksiyon-benzeri
    // codegen girişinde (`temp_counter`/`label_counter` İLE AYNI
    // noktalarda) TAMAMEN BOŞALTILIR.
    self.mod_cache.deinit(self.allocator);
    self.mod_cache = .empty;

    const wrapper_sym = try std.fmt.allocPrint(self.allocator, "${s}", .{spec.name});
    try self.qbeFuncHeaderStart(.l, wrapper_sym);
    try self.qbeFuncParam(.l, "%argp", true);
    try self.qbeFuncHeaderEnd();
    try self.qbeLoadL(RT_PARAM, "%argp");

    const arg_texts = try self.allocator.alloc([]const u8, spec.sig.params.len);
    for (spec.sig.params, 0..) |p, i| {
        const off = 8 + 8 * i;
        const addr = try self.newTemp();
        try self.qbeOp2Imm(addr, .l, "add", "%argp", @intCast(off));
        const val = try self.newTemp();
        try self.qbeLoad(val, p.qtype, p.qtype, addr);
        arg_texts[i] = val;
    }

    const target_sym = try std.fmt.allocPrint(self.allocator, "${s}", .{spec.target_fn});
    const call_args = try self.allocator.alloc(codegen.QbeArg, 1 + spec.sig.params.len);
    call_args[0] = .{ .ty = .l, .text = RT_PARAM };
    for (spec.sig.params, arg_texts, 0..) |p, at, i| call_args[1 + i] = .{ .ty = p.qtype, .text = at };
    const payload = blk: {
        if (spec.sig.ret.qtype == .none) {
            try self.qbeCall(null, target_sym, call_args);
            break :blk Value{ .text = "0", .qtype = .l };
        }
        const result_t = try self.newTemp();
        try self.qbeCall(.{ .name = result_t, .ty = spec.sig.ret.qtype }, target_sym, call_args);
        break :blk try self.toPayload(.{ .text = result_t, .qtype = spec.sig.ret.qtype });
    };

    // Faz MN.9.4: `genSpawnExpr`nin `emitInlineRetain`inin EŞLEŞEN yarısı
    // — `target_fn` parametrelerini ÖDÜNÇ ALIR (bkz. `genThreadStartWrapper`nin
    // AYNI "çağrı SİTESİ sahipliği ELİNDE TUTAR" sözleşmesi), bu YÜZDEN
    // kapanışın (BU sarmalayıcının) KENDİ retain edilmiş referansı `target_
    // fn` DÖNDÜKTEN SONRA BURADA serbest bırakılmalıdır — `.qbe`de BU KOD
    // YOLU HİÇ ÇALIŞMAZ (checker list/class/dict'i `.qbe`de HİÇ GEÇİRMEZ).
    if (self.backend == .llvm) {
        for (spec.sig.params, arg_texts) |p, at| {
            if (p.heap == .list or p.heap == .class or p.heap == .dict) {
                try self.releaseValueIfSet(at, p.heap, p.elem_qtype, p.class_name, p.elem_heap_info, p.dict_info);
            }
        }
    }
    // v1.29.12: YUKARIDAKİ İLE AYNI, `Task[T]`/`Channel[T]` İçİn (bkz.
    // `ownership.zig`nin `isSpawnRefcountedType`sinin belge notu) —
    // BACKEND-BAĞIMSIZ, sarmalayıcının KENDİ retain edilmiş referansını
    // `target_fn` (ÖDÜNÇ ALAN taraf) İŞİNİ BİTİRDİKTEN SONRA serbest
    // bırakır.
    for (spec.sig.params, arg_texts) |p, at| {
        if (self.isSpawnRefcountedType(p.heap)) {
            try self.destroyNonArcValue(at, p.heap);
        }
    }

    const closure_size = 8 + 8 * spec.sig.params.len;
    try self.qbeCall(null, "$nox_free", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = "%argp" }, .{ .ty = .l, .text = try std.fmt.allocPrint(self.allocator, "{d}", .{closure_size}) } });
    try self.qbeRet(payload.text);
    try self.qbeFuncEnd();
}

/// `nox.thread.start(entry, arg)` çağrı sitesi codegen'i — Faz BB.4
/// (bkz. nox-teknik-spesifikasyon.md §3.50). Checker ZATEN `entry`in
/// ÇIPLAK bir `async def` ismi OLDUĞUNU, `arg`ın tipinin `entry`in TEK
/// parametresiyle UYUŞTUĞUNU VE HER İKİSİNİN de `isThreadTransferSafeType`den
/// GEÇTİĞİNİ doğruladı (bkz. checker.zig'in `tryResolveThreadSpawnCall`ı).
///
/// `genSpawnExpr`DEN FARKLI: `arg`ın (str İSE) hazırlık-arabelleğine
/// KOPYALANMASI VE ÇOCUK iş parçacığının KENDİ `RuntimeState`i ÜZERİNDEN
/// taze bir ARC `str` İNŞA ETMESİ TAMAMEN `runtime/async_rt/thread_bridge.
/// zig`nin `nox_thread_spawn`ının/`childThreadMain`inin İÇİNDE olur —
/// BURADA (çağrı SİTESİNDE) `arg`ın kendisi SADECE `toPayload`a çevrilip
/// `nox_thread_spawn`a AKTARILIR, `arg_is_str`/`result_is_str` (statik
/// olarak `entry`in İMZASINDAN türetilir) O tarafın HANGİ protokolü
/// (düz payload mı, str-klonlama mı) İZLEYECEĞİNİ SÖYLER. `arg` İÇİN
/// (Faz BB.2'nin belge notunda AÇIKLANDIĞI GİBİ) HİÇBİR ÖZEL retain
/// GEREKMEZ — `nox_thread_spawn` orijinal işaretçiyi ASLA SAKLAMAZ,
/// yalnızca SENKRON olarak baytlarını OKUR/KOPYALAR (normal bir
/// fonksiyon argümanı GİBİ davranır, `spawn`ın kapanış-paketlemesinin
/// AKSİNE).
pub fn genThreadStartExpr(self: *Codegen, c: ast.Call) CodegenError!Value {
    if (c.args.len != 2) return error.Unsupported;
    const fn_name = switch (c.args[0]) {
        .identifier => |n| n,
        else => return error.Unsupported,
    };
    const sig = self.functions.get(fn_name) orelse return error.Unsupported;
    if (sig.params.len != 1) return error.Unsupported;

    // Faz MN.9.4: `--release` altında `nox.thread.start`, GERÇEK bir OS
    // iş parçacığı AÇAN `$nox_thread_spawn` YERİNE, `genSpawnExpr`in AYNI
    // mekanizmasını (ARC-heap kapanış + `SpawnWrapperSpec` + `$nox_async_
    // spawn`) yeniden kullanır — `entry(arg)` sentetik bir spawn-ifadesi
    // OLARAK inşa edilip DOĞRUDAN `genSpawnExpr`e devredilir (`list`/
    // `class`/`dict`/`task`/`channel`/`task_local` argümanları İçİn YENİ
    // retain/release paketlemesi ORADA ZATEN VAR — bkz. onun MN.9.4 notu).
    // Nox-KAYNAK seviyesinde `ThreadHandle[T]` tip adı KORUNUR (checker
    // DEĞİŞMEDİ, `--release`de de `.qbe`de de AYNI STATİK tip) — SADECE
    // dönen `Value`nin `.heap` etiketi `.task`tan `.thread_handle`a
    // ÇEVRİLİR: İKİSİNİN ÇALIŞMA-ZAMANI temsili ZATEN BİREBİR AYNIDIR
    // (bir `*Task(i64)` işaretçisi) — TEK fark, `destroyNonArcValue`/
    // `genThreadHandleJoin`nin (bkz. onların MN.9.4 notları) HANGİ
    // runtime fonksiyonlarını ÇAĞIRACAĞINI seçen STATİK dispatch
    // etiketidir.
    if (self.backend == .llvm) {
        const arg_arr = try self.allocator.alloc(ast.Expr, 1);
        arg_arr[0] = c.args[1];
        const callee_expr = try self.allocator.create(ast.Expr);
        callee_expr.* = .{ .identifier = fn_name };
        const synthetic: ast.Expr = .{ .call = .{ .callee = callee_expr, .args = arg_arr } };
        var result = try self.genSpawnExpr(synthetic);
        result.heap = .thread_handle;
        return result;
    }

    const arg_v0 = try self.genExpr(c.args[1]);
    const arg_v = try self.convert(arg_v0, sig.params[0].qtype);
    const arg_payload = try self.toPayload(arg_v);

    const arg_is_str: []const u8 = if (sig.params[0].heap == .str) "1" else "0";
    const result_is_str: []const u8 = if (sig.ret.heap == .str) "1" else "0";

    const wrapper_name = try std.fmt.allocPrint(self.allocator, "thread_wrap_{d}", .{self.thread_wrapper_counter});
    self.thread_wrapper_counter += 1;
    try self.thread_wrappers.append(self.allocator, .{ .name = wrapper_name, .target_fn = fn_name, .sig = sig });

    const wrapper_sym = try std.fmt.allocPrint(self.allocator, "${s}", .{wrapper_name});
    const handle_ptr = try self.newTemp();
    try self.qbeCall(.{ .name = handle_ptr, .ty = .l }, "$nox_thread_spawn", &.{
        .{ .ty = .l, .text = RT_PARAM },
        .{ .ty = .l, .text = wrapper_sym },
        .{ .ty = .l, .text = arg_payload.text },
        .{ .ty = .w, .text = arg_is_str },
        .{ .ty = .w, .text = result_is_str },
    });

    var elem_heap_info: ?*const ElemHeapInfo = null;
    if (sig.ret.heap == .class or sig.ret.heap == .list) {
        const info = try self.allocator.create(ElemHeapInfo);
        info.* = .{ .heap = sig.ret.heap, .class_name = sig.ret.class_name, .elem_qtype = sig.ret.elem_qtype, .nested = sig.ret.elem_heap_info, .elem_is_str = sig.ret.elem_is_str };
        elem_heap_info = info;
    }
    // `ThreadHandle[T]`in KENDİSİ (bkz. `HeapKind`in belge notu) ARC-
    // yönetimli DEĞİLDİR — `heap = .thread_handle` yalnızca kapsam-sonu
    // `nox_thread_destroy` çağrısını TETİKLEMEK içindir; `elem_*` alanları
    // T'yi (payload tipini) taşır.
    return .{
        .text = handle_ptr,
        .qtype = .l,
        .heap = .thread_handle,
        .elem_qtype = sig.ret.qtype,
        .elem_heap_info = elem_heap_info,
        .elem_is_str = sig.ret.heap == .str,
    };
}

/// `nox_thread_spawn`ın çağırdığı, `nox.thread.start` çağrı sitesi
/// başına üretilen bir ÇOCUK İŞ PARÇACIĞI girişi — bkz. `ThreadWrapperSpec`in
/// belge notu. `genSpawnWrapper`DEN İKİ noktada FARKLI: (1) argüman
/// SAYISI HER ZAMAN TAM OLARAK 1'dir (Tier 1'in kısıtı); (2) kapanış
/// (`ThreadEntryClosure`) native-qtype'lı DEĞİL, HER ZAMAN `l` (i64)
/// genişliğinde bir `payload` alanı TAŞIR (bkz. `thread_bridge.zig`nin
/// Zig struct TANIMI) — bu yüzden argüman `loadl` İLE okunup `fromPayload`
/// İLE hedef tipe ÇEVRİLİR (`genSpawnWrapper`nin native `load{qtype}`inin
/// AKSİNE). Kapanışın KENDİSİ (`ThreadEntryClosure`) `runtime/async_rt/
/// thread_bridge.zig`nin `childThreadMain`i TARAFINDAN (SAF Zig'de)
/// tahsis edilip serbest BIRAKILIR — BURADA `nox_free` ÇAĞRILMAZ
/// (`genSpawnWrapper`nin kapanışının AKSİNE, bkz. `ThreadWrapperSpec`in
/// belge notu).
pub fn genThreadStartWrapper(self: *Codegen, spec: ThreadWrapperSpec) CodegenError!void {
    self.temp_counter = 0;
    self.label_counter = 0;
    // Bkz. `Codegen.mod_cache`nin belge notu: slot ADLARI ("%t0", ...)
    // SADECE bir FONKSİYON içinde benzersizdir (`temp_counter` HER
    // fonksiyon BAŞLANGICINDA sıfırlanır, tıpkı BURADA olduğu gibi) —
    // BİR ÖNCEKİ fonksiyondan kalan bir önbellek girdisi, BU fonksiyonda
    // AYNI ADI TAŞIYAN TAMAMEN FARKLI bir slotla YANLIŞLIKLA eşleşebilir
    // (çapraz-fonksiyon çakışması). Bu YÜZDEN HER fonksiyon-benzeri
    // codegen girişinde (`temp_counter`/`label_counter` İLE AYNI
    // noktalarda) TAMAMEN BOŞALTILIR.
    self.mod_cache.deinit(self.allocator);
    self.mod_cache = .empty;

    const wrapper_sym = try std.fmt.allocPrint(self.allocator, "${s}", .{spec.name});
    try self.qbeFuncHeaderStart(.l, wrapper_sym);
    try self.qbeFuncParam(.l, "%argp", true);
    try self.qbeFuncHeaderEnd();
    try self.qbeLoadL(RT_PARAM, "%argp");
    // Bulundu (bkz. proje belleği "modül-seviyesi global durum" planı):
    // `nox.thread.start` İLE oluşturulan HER GERÇEK OS iş parçacığı KENDİ
    // bağımsız `RuntimeState`ine (bkz. `childThreadMain`) sahiptir —
    // `globals_block`u BAŞTA `null`, KENDİ taze kopyasını burada
    // ilklendirir. `nox.http.serve_multicore`nin worker'ından FARKLI
    // olarak bu iş parçacığı GERÇEKTEN döner (`childThreadMain`
    // `ret`ten SONRA `nox_runtime_deinit` ÇAĞIRIR) — bu YÜZDEN deinit
    // de (aşağıda, `ret`ten HEMEN ÖNCE) ÇAĞRILMALIDIR, aksi halde HER
    // `nox.thread.start` çağrısı heap-yönetimli bir global TAŞIYAN
    // programlarda sızdırır.
    if (self.module_globals.count() > 0) {
        try self.qbeCall(null, "$nox_init_globals", &.{.{ .ty = .l, .text = RT_PARAM }});
    }

    const payload_addr = try self.newTemp();
    try self.qbeOp2Imm(payload_addr, .l, "add", "%argp", 8);
    const payload_val = try self.newTemp();
    try self.qbeLoadL(payload_val, payload_addr);
    const arg_val = try self.fromPayload(.{ .text = payload_val, .qtype = .l }, spec.sig.params[0].qtype);

    const target_sym = try std.fmt.allocPrint(self.allocator, "${s}", .{spec.target_fn});
    const result_payload = blk: {
        if (spec.sig.ret.qtype == .none) {
            try self.qbeCall(null, target_sym, &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = arg_val.qtype, .text = arg_val.text } });
            break :blk Value{ .text = "0", .qtype = .l };
        }
        const result_t = try self.newTemp();
        try self.qbeCall(.{ .name = result_t, .ty = spec.sig.ret.qtype }, target_sym, &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = arg_val.qtype, .text = arg_val.text } });
        break :blk try self.toPayload(.{ .text = result_t, .qtype = spec.sig.ret.qtype });
    };

    // Parametreler `spec.target_fn` TARAFINDAN ÖDÜNÇ ALINIR (bkz.
    // `collectLocals`/`allocSlot`in `is_param` notu — kapsam-sonu
    // otomatik release'i HER ZAMAN ATLAR) — çağrı SİTESİ (BURASI)
    // sahipliği ELİNDE TUTAR (normal `genCall`nin `releaseTemporaryArgs`
    // İLE AYNI sözleşme). `arg_val` BURADA `childThreadMain`in TAZE
    // klonladığı, TEK sahipli bir ARC `str`tir (Tier 1 SADECE `str`i
    // heap-yönetimli tip olarak KABUL EDER) — çağrı DÖNDÜKTEN SONRA
    // BURADA serbest bırakılMAZSA sızar (bu, `dupeToNoxStr`in Faz BB.4
    // uçtan uca golden testinde YAKALANAN GERÇEK bir sızıntıydı).
    if (spec.sig.params[0].heap == .str) {
        try self.releaseValueIfSet(arg_val.text, .str, .none, null, null, null);
    }

    // Bulundu (bkz. proje belleği "modül-seviyesi global durum" planı):
    // `ret`ten HEMEN ÖNCE — `childThreadMain` BUNDAN SONRA GERÇEKTEN
    // `nox_runtime_deinit` ÇAĞIRACAĞINDAN (bkz. yukarıdaki init notu),
    // heap-yönetimli global'ler BURADA serbest bırakılMAZSA sızar.
    if (self.module_globals.count() > 0) {
        try self.qbeCall(null, "$nox_deinit_globals", &.{.{ .ty = .l, .text = RT_PARAM }});
    }

    try self.qbeRet(result_payload.text);
    try self.qbeFuncEnd();
}

/// `nox.thread.pool_run(num_workers, entry)` — Faz MN.7a. `genThreadStartExpr`
/// İLE AYNI "çıplak fonksiyon adını sarmalayıcıya sar, TEMBEL kaydet"
/// deseni, AMA İKİ noktada BASİTLEŞTİRİLMİŞ: (1) `entry` SIFIR parametre
/// aldığından (checker ZATEN garanti ETTİ) `toPayload`/`arg_is_str` YOK
/// — kapanış SADECE `RT_PARAM`i taşır; (2) `$nox_thread_spawn` YERİNE
/// `$nox_pool_run` çağrılır (bkz. `runtime/async_rt/pool_bridge.zig`nin
/// `nox_pool_run`ı) VE dönüş `i32` bir durum kodudur (`ThreadHandle`
/// GİBİ bir tutamaç DEĞİL — `pool_run` ZATEN BLOKE OLUP TAMAMLANMAYI
/// BEKLER, bkz. onun modül üstü notu), Nox-seviyesinde `None` döner.
///
/// **Backend sınırı** (bkz. proje planı Tasarım #1): `WorkerPool`nin
/// paylaşılan `RuntimeState`si, İKİ FARKLI OS iş parçacığının AYNI ARC
/// nesnesine EŞ ZAMANLI dokunmasına (work-stealing SAYESİNDE) izin
/// VERİR — `ownership.zig`nin inline retain/predecrement hızlı yolu
/// (`qbeAtomicAdd`/`qbeAtomicSub`) SADECE LLVM'de GERÇEK `atomicrmw`dır,
/// QBE'de DÜZ, ATOMİK OLMAYAN `load→add/sub→store`dur (`qbe_emit.zig`)
/// — bu YÜZDEN `nox.thread.pool_run` SADECE `--release` (LLVM backend)
/// İLE derlenebilir.
pub fn genPoolRunExpr(self: *Codegen, c: ast.Call) CodegenError!Value {
    if (self.backend == .qbe) return error.Unsupported;
    if (c.args.len != 2) return error.Unsupported;
    const num_workers_v0 = try self.genExpr(c.args[0]);
    try self.checkNoLowlevelEscape(num_workers_v0);
    const num_workers_v = try self.convert(num_workers_v0, .l);
    try self.releaseIfTemporary(c.args[0], num_workers_v0);

    const fn_name = switch (c.args[1]) {
        .identifier => |n| n,
        else => return error.Unsupported,
    };
    if (self.functions.get(fn_name) == null) return error.Unsupported;

    const wrapper_name = try std.fmt.allocPrint(self.allocator, "pool_run_wrap_{d}", .{self.pool_run_wrapper_counter});
    self.pool_run_wrapper_counter += 1;

    // Faz MN.8, Bulgu A: `pool_run`ın sibling (saf-çalma) worker'ları
    // KENDİ worker slotu İçİn modül-global durumu HİÇ ilklendirmiyordu
    // (SADECE sürücü/slot-0, `entry()`nin GERÇEK çalıştığı worker,
    // `genPoolRunWrapper`nin AŞAĞIDAKİ init/deinit çiftini alıyordu) —
    // çalınan bir görev bir sibling'de modül-global OKUR/YAZARSA `null`
    // işaretçi dereferansıyla ÇÖKÜYORDU. Düzeltme: SADECE modül-global
    // VARSA (`module_globals.count() > 0`) İKİ minik sarmalayıcı DAHA
    // kaydedilir — `nox_pool_run`ın C-ABI'sine EK parametre OLARAK
    // geçilir, `pool_bridge.zig`nin `poolWorkerMain`ı (sibling'ler)
    // BUNLARI KENDİ slotu İçİn ÇAĞIRIR.
    var globals_init_wrapper_name: ?[]const u8 = null;
    var globals_deinit_wrapper_name: ?[]const u8 = null;
    var globals_init_sym: []const u8 = "0";
    var globals_deinit_sym: []const u8 = "0";
    if (self.module_globals.count() > 0) {
        const ginit_name = try std.fmt.allocPrint(self.allocator, "{s}_ginit", .{wrapper_name});
        const gdeinit_name = try std.fmt.allocPrint(self.allocator, "{s}_gdeinit", .{wrapper_name});
        globals_init_wrapper_name = ginit_name;
        globals_deinit_wrapper_name = gdeinit_name;
        globals_init_sym = try std.fmt.allocPrint(self.allocator, "${s}", .{ginit_name});
        globals_deinit_sym = try std.fmt.allocPrint(self.allocator, "${s}", .{gdeinit_name});
    }
    try self.pool_run_wrappers.append(self.allocator, .{
        .name = wrapper_name,
        .target_fn = fn_name,
        .globals_init_wrapper_name = globals_init_wrapper_name,
        .globals_deinit_wrapper_name = globals_deinit_wrapper_name,
    });

    const wrapper_sym = try std.fmt.allocPrint(self.allocator, "${s}", .{wrapper_name});
    const rc = try self.newTemp();
    try self.qbeCall(.{ .name = rc, .ty = .w }, "$nox_pool_run", &.{
        .{ .ty = .l, .text = RT_PARAM },
        .{ .ty = .l, .text = num_workers_v.text },
        .{ .ty = .l, .text = wrapper_sym },
        .{ .ty = .l, .text = globals_init_sym },
        .{ .ty = .l, .text = globals_deinit_sym },
    });
    return .{ .text = "0", .qtype = .none };
}

/// `nox_pool_run`ın çağırdığı, `nox.thread.pool_run` çağrı sitesi
/// başına üretilen sarmalayıcı — bkz. `PoolRunWrapperSpec`in belge notu.
/// **`genThreadStartWrapper`den FARKLI**: `%argp` bir KAPANIŞ struct'ına
/// (`rt`+`payload`) İşaret ETMEZ — `runtime/async_rt/pool_bridge.zig`nin
/// `poolWorkerMain`ı `entry_fn`i KENDİ (havuzun paylaşılan) `rt`sini
/// DOĞRUDAN `arg` OLARAK GEÇİREREK spawn eder (bkz. onun belge notu) —
/// bu YÜZDEN `%argp`nin KENDİSİ `rt` DEĞERİDİR, bir POINTER-TO-rt DEĞİL
/// (`genHttpServeWrapper`nin `%ctx→RT_PARAM` KOPYASIYLA AYNI desen,
/// `genThreadStartWrapper`nin `loadl`İYLE DEĞİL).
///
/// **Globals: `entry()` KENDİ, BAĞLANTISIZ bir kopya alır** (bkz. proje
/// planı Tasarım #5) — `WorkerPool.create`in KENDİ `RuntimeState`si
/// PROGRAMIN ana `rt`sinden TAMAMEN BAĞIMSIZDIR.
///
/// **`$nox_init_globals`/`$nox_deinit_globals`i BURADA ÇAĞIRMAZ** (Faz
/// MN.8, Bulgu A'nın İKİNCİ, DAHA DERİN düzeltmesi — bkz. `pool_bridge.
/// zig`nin `poolRunDriverThreadMain`ının belge notu): bu sarmalayıcı,
/// `entry()`in fiber'ının GÖVDESİDİR — VE o fiber, SPAWN EDİLDİĞİ ANDA
/// KENDİ deque'ine PUSH EDİLDİĞİNDEN (`Scheduler.spawn`nin "spawn-anında
/// çal" modeli), driver KENDİ `run()`una BİLE ULAŞMADAN bir KARDEŞ
/// TARAFINDAN ÇALINABİLİR — bu YÜZDEN "BURADA çağrılan `$nox_init_
/// globals` slot-0'ı ilklendirir" VARSAYIMI YANLIŞTIR (`entry()` HANGİ
/// worker'da ÇALIŞIRSA çalışsın, O worker'ın globals'ı `poolRunDriver
/// ThreadMain`/`poolWorkerMain` TARAFINDAN, run() BAŞLAMADAN ÖNCE,
/// KOŞULSUZ VE run-KONUMUNDAN BAĞIMSIZ olarak ZATEN ilklendirilmiştir
/// — BURADA TEKRAR çağırmak `$nox_init_globals`in İDEMPOTENT OLMAYAN
/// `nox_alloc`ı YÜZÜNDEN ÇİFT-tahsis/SIZINTI olurdu).
pub fn genPoolRunWrapper(self: *Codegen, spec: types.PoolRunWrapperSpec) CodegenError!void {
    self.temp_counter = 0;
    self.label_counter = 0;
    self.mod_cache.deinit(self.allocator);
    self.mod_cache = .empty;

    const wrapper_sym = try std.fmt.allocPrint(self.allocator, "${s}", .{spec.name});
    try self.qbeFuncHeaderStart(.l, wrapper_sym);
    try self.qbeFuncParam(.l, "%argp", true);
    try self.qbeFuncHeaderEnd();
    try self.qbeOp1(RT_PARAM, .l, "copy", "%argp");

    const target_sym = try std.fmt.allocPrint(self.allocator, "${s}", .{spec.target_fn});
    try self.qbeCall(null, target_sym, &.{.{ .ty = .l, .text = RT_PARAM }});

    try self.qbeRet("0");
    try self.qbeFuncEnd();
}

/// Faz MN.8, Bulgu A: `pool_run`ın sibling worker'larının KENDİ slotu
/// İçİn modül-global durumu ilklendirmesi/temizlemesi İçİn TEK satırlık
/// (`%argp` DOĞRUDAN `rt`dir, `genPoolRunWrapper` İLE AYNI "kapanış
/// YOK" şekli) minik sarmalayıcılar — `spec.globals_init_wrapper_name`/
/// `globals_deinit_wrapper_name` `null` DEĞİLSE (yani `module_globals.
/// count() > 0` İSE) çağrılır (bkz. `genPoolRunExpr`nin belge notu).
pub fn genPoolRunGlobalsInitWrapper(self: *Codegen, wrapper_name: []const u8) CodegenError!void {
    self.temp_counter = 0;
    self.label_counter = 0;
    self.mod_cache.deinit(self.allocator);
    self.mod_cache = .empty;

    const wrapper_sym = try std.fmt.allocPrint(self.allocator, "${s}", .{wrapper_name});
    try self.qbeFuncHeaderStart(.l, wrapper_sym);
    try self.qbeFuncParam(.l, "%argp", true);
    try self.qbeFuncHeaderEnd();
    try self.qbeOp1(RT_PARAM, .l, "copy", "%argp");
    try self.qbeCall(null, "$nox_init_globals", &.{.{ .ty = .l, .text = RT_PARAM }});
    try self.qbeRet("0");
    try self.qbeFuncEnd();
}

pub fn genPoolRunGlobalsDeinitWrapper(self: *Codegen, wrapper_name: []const u8) CodegenError!void {
    self.temp_counter = 0;
    self.label_counter = 0;
    self.mod_cache.deinit(self.allocator);
    self.mod_cache = .empty;

    const wrapper_sym = try std.fmt.allocPrint(self.allocator, "${s}", .{wrapper_name});
    try self.qbeFuncHeaderStart(.l, wrapper_sym);
    try self.qbeFuncParam(.l, "%argp", true);
    try self.qbeFuncHeaderEnd();
    try self.qbeOp1(RT_PARAM, .l, "copy", "%argp");
    try self.qbeCall(null, "$nox_deinit_globals", &.{.{ .ty = .l, .text = RT_PARAM }});
    try self.qbeRet("0");
    try self.qbeFuncEnd();
}

/// `handle.join()` — YALNIZCA `await` üzerinden (bkz. `genAwaitExpr`)
/// çağrılır, `genCall`in normal metod-çağrısı yolundan GEÇMEZ
/// (`ThreadHandle` `self.classes`de yok, yerleşik bir tiptir) —
/// `genChannelOp`in `recv` dalıyla AYNI desen.
pub fn genThreadHandleJoin(self: *Codegen, a: ast.Attribute) CodegenError!Value {
    const handle_val = try self.genExpr(a.obj.*);
    const payload_t = try self.newTemp();
    // Faz MN.9.4: `--release` altında `handle_val.text` GERÇEKTEN bir
    // `*Task(i64)`dir (bkz. `genThreadStartExpr`nin MN.9.4 notu) — `$nox_
    // async_await` `$nox_thread_join` İLE BİREBİR AYNI ŞEKLİ (`(rt,
    // işaretçi) -> i64 payload`) taşıdığından SADECE sembol adı DEĞİŞİR.
    const join_sym = if (self.backend == .llvm) "$nox_async_await" else "$nox_thread_join";
    try self.qbeCall(.{ .name = payload_t, .ty = .l }, join_sym, &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = handle_val.text } });
    const converted = try self.fromPayload(.{ .text = payload_t, .qtype = .l }, handle_val.elem_qtype);
    return valueFromElemDescriptor(converted.text, converted.qtype, handle_val.elem_heap_info, handle_val.elem_is_str);
}

/// `await <ifade>` — checker ZATEN operandın ya bir `Task` değeri ya da
/// bir `Channel.send`/`recv` çağrısı olduğunu doğruladı (bkz. checker'ın
/// `.await_expr` dalı); codegen AYNI şekle bakarak dallanır.
pub fn genAwaitExpr(self: *Codegen, operand: ast.Expr) CodegenError!Value {
    if (operand == .call) {
        const c = operand.call;
        if (c.callee.* == .attribute) {
            const a = c.callee.attribute;
            if (std.mem.eql(u8, a.attr, "send") or std.mem.eql(u8, a.attr, "recv")) {
                // Alıcının statik tipi (`Channel[T]` mi `ThreadChannel[T]`
                // mi) BİR KEZ değerlendirilir — Faz BB.6: `ThreadChannel`
                // AYRI bir çalışma-zamanı protokolü (`nox_threadchannel_*`,
                // dual-pipe) kullandığından `genChannelOp`DAN AYRI bir
                // fonksiyona (`genThreadChannelOp`) dispatch edilir.
                const recv_val = try self.genExpr(a.obj.*);
                if (recv_val.heap == .thread_channel) return self.genThreadChannelOp(a, c.args, recv_val);
                return self.genChannelOp(a, c.args, recv_val);
            }
            // Faz BB.4: `ThreadHandle[T].join()` — `Channel.send`/`.recv`
            // İLE AYNI "yalnızca await üzerinden" desen (bkz.
            // `genThreadHandleJoin`in belge notu).
            if (std.mem.eql(u8, a.attr, "join")) {
                return self.genThreadHandleJoin(a);
            }
        }
    }
    const task_val = try self.genExpr(operand);
    const payload_t = try self.newTemp();
    try self.qbeCall(.{ .name = payload_t, .ty = .l }, "$nox_async_await", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = task_val.text } });
    const converted = try self.fromPayload(.{ .text = payload_t, .qtype = .l }, task_val.elem_qtype);
    return valueFromElemDescriptor(converted.text, converted.qtype, task_val.elem_heap_info, task_val.elem_is_str);
}

/// `ch.send(v)`/`ch.recv()` — YALNIZCA `await` üzerinden (bkz.
/// `genAwaitExpr`) çağrılır, `genCall`in normal metod-çağrısı yolundan
/// GEÇMEZ (`Channel` `self.classes`de yok, yerleşik bir tiptir). `ch_val`
/// `genAwaitExpr` TARAFINDAN ZATEN değerlendirilmiştir (Faz BB.6: alıcı
/// tipinin `Channel` mi `ThreadChannel` mi OLDUĞUNU görmek İÇİN zaten
/// BİR KEZ değerlendirilmesi GEREKTİĞİNDEN, burada TEKRAR değerlendirip
/// yan etkileri İKİ KEZ tetiklemek yerine parametre olarak alınır).
pub fn genChannelOp(self: *Codegen, a: ast.Attribute, args: []const ast.Expr, ch_val: Value) CodegenError!Value {
    if (std.mem.eql(u8, a.attr, "send")) {
        if (args.len != 1) return error.Unsupported;
        const v = try self.genExpr(args[0]);
        const converted = try self.convert(v, ch_val.elem_qtype);
        const payload = try self.toPayload(converted);
        try self.qbeCall(null, "$nox_channel_send", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = ch_val.text }, .{ .ty = .l, .text = payload.text } });
        return .{ .text = "0", .qtype = .none };
    }
    if (std.mem.eql(u8, a.attr, "recv")) {
        if (args.len != 0) return error.Unsupported;
        const payload_t = try self.newTemp();
        try self.qbeCall(.{ .name = payload_t, .ty = .l }, "$nox_channel_recv", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = ch_val.text } });
        const converted = try self.fromPayload(.{ .text = payload_t, .qtype = .l }, ch_val.elem_qtype);
        return valueFromElemDescriptor(converted.text, converted.qtype, ch_val.elem_heap_info, ch_val.elem_is_str);
    }
    return error.Unsupported;
}

/// `tl.get()`/`tl.set(v)`/`tl.clear()` — Faz OO.2 (bkz. nox-teknik-
/// spesifikasyon.md §3.83): `genChannelOp`in AYNI "opak payload taşı,
/// TÜM tip-farkındalığı BURADA kal" felsefesi, AMA `Channel`in AKSİNE
/// `await` GEREKTİRMEZ — `calls.zig`nin `genMethodCall`ı `tl_val`i
/// (obj.heap == .task_local İSE) NORMAL metod-çağrısı yolunda BURAYA
/// dispatch eder (`genAwaitExpr` YOLUNDAN GEÇMEZ). Checker `T`nin HEP
/// HEAP-yönetimli (sınıf/str/list/dict) OLMASINI ZORUNLU KILAR (bkz.
/// `checkGenericConstruct`in `TaskLocal` dalı) — bu SAYEDE `None`
/// (boş yuva) HER ZAMAN `0` işaretçisiyle temsil edilir, çıplak bir
/// ilkelin (`int`/`float`/`bool`) "0 mı YOKSA ayarlanmamış mı" belirsizliği
/// (Optional-ilkel'in `boxed_scalar` KUTULAMASI GEREKTİRDİĞİ SORUN)
/// HİÇ ORTAYA ÇIKMAZ.
pub fn genTaskLocalOp(self: *Codegen, tl_val: Value, a: ast.Attribute, args: []const ast.Expr) CodegenError!Value {
    const elem_heap: types.HeapKind = if (tl_val.elem_heap_info) |ehi| ehi.heap else if (tl_val.elem_is_str) .str else .none;
    const elem_class_name: ?[]const u8 = if (tl_val.elem_heap_info) |ehi| ehi.class_name else null;
    const elem_nested: ?*const ElemHeapInfo = if (tl_val.elem_heap_info) |ehi| ehi.nested else null;
    if (std.mem.eql(u8, a.attr, "get")) {
        if (args.len != 0) return error.Unsupported;
        const payload_t = try self.newTemp();
        try self.qbeCall(.{ .name = payload_t, .ty = .l }, "$nox_tasklocal_get", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = tl_val.text } });
        // `nox_tasklocal_get` ÖDÜNÇ bir referans döner (fiber'ın KENDİ
        // haritası kendi referansını KORUR) — `.call` sonucu HER YERDE
        // "taze/sahipli" SAYILDIĞINDAN (bkz. `isTemporaryExpr`), bunu
        // GERÇEKTEN TUTARLI kılmak İçİn burada (NULL DEĞİLSE) retain
        // edilir — `genDictGet`in AYNI "ödünç okuma → çağrı SİTESİNDE
        // retain" ilkesi, `Channel.recv`den (kuyruktan çıkan değerin
        // sahipliği ZATEN tamamen devredildiğinden retain GEREKMEZ)
        // BİLİNÇLİ OLARAK FARKLI.
        try self.emitInlineRetain(payload_t, elem_heap);
        try self.releaseIfTemporary(a.obj.*, tl_val);
        return valueFromElemDescriptor(payload_t, tl_val.elem_qtype, tl_val.elem_heap_info, tl_val.elem_is_str);
    }
    if (std.mem.eql(u8, a.attr, "set")) {
        if (args.len != 1) return error.Unsupported;
        const v0 = try self.genExpr(args[0]);
        try self.checkNoLowlevelEscape(v0);
        const retained = try self.retainIfAliasing(args[0], v0);
        const converted = try self.convert(retained, tl_val.elem_qtype);
        const payload = try self.toPayload(converted);
        const old_t = try self.newTemp();
        try self.qbeCall(.{ .name = old_t, .ty = .l }, "$nox_tasklocal_set", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = tl_val.text }, .{ .ty = .l, .text = payload.text } });
        try self.releaseValueIfSet(old_t, elem_heap, tl_val.elem_qtype, elem_class_name, elem_nested, null);
        try self.releaseIfTemporary(a.obj.*, tl_val);
        return .{ .text = "0", .qtype = .none };
    }
    if (std.mem.eql(u8, a.attr, "clear")) {
        if (args.len != 0) return error.Unsupported;
        const old_t = try self.newTemp();
        try self.qbeCall(.{ .name = old_t, .ty = .l }, "$nox_tasklocal_clear", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = tl_val.text } });
        try self.releaseValueIfSet(old_t, elem_heap, tl_val.elem_qtype, elem_class_name, elem_nested, null);
        try self.releaseIfTemporary(a.obj.*, tl_val);
        return .{ .text = "0", .qtype = .none };
    }
    return error.Unsupported;
}

/// `tc.send(v)`/`tc.recv()` — Faz BB.6 (bkz. nox-teknik-spesifikasyon.md
/// §3.52): `genChannelOp`in AYNI deseni, AMA `nox_channel_*` yerine
/// `nox_threadchannel_*`e ÇAĞRI YAPAR VE `T`nin `str` OLUP OLMADIĞINA
/// (statik olarak `ch_val.elem_is_str`den BİLİNİR — `thread_channel.zig`nin
/// `_val`/`_str` ikili API'sinin GEREĞİ) GÖRE `_val`/`_str` varyantı
/// SEÇER.
pub fn genThreadChannelOp(self: *Codegen, a: ast.Attribute, args: []const ast.Expr, ch_val: Value) CodegenError!Value {
    // Faz MN.9.4: `--release` altında `ch_val.text` GERÇEKTEN bir
    // `Channel(T)*`dir (bkz. `genGenericConstruct`nin MN.9.4 notu —
    // `nox_channel_new` ile inşa edildi) — `genChannelOp`in AYNI şekli
    // (`(self, a, args, ch_val) -> Value`) taşıdığından DOĞRUDAN devredilir
    // (`nox_channel_send`/`_recv`, ZATEN her `T` İçİn ÇALIŞAN, MN.9.1'de
    // çapraz-worker GÜVENLİ hale getirilmiş mekanizma). `.qbe` dalı
    // BİREBİR DEĞİŞMEDEN kalır (`nox_threadchannel_*`nin `_val`/`_str`
    // ikili API'si).
    if (self.backend == .llvm) return self.genChannelOp(a, args, ch_val);
    if (std.mem.eql(u8, a.attr, "send")) {
        if (args.len != 1) return error.Unsupported;
        const v = try self.genExpr(args[0]);
        const converted = try self.convert(v, ch_val.elem_qtype);
        const payload = try self.toPayload(converted);
        const fn_name = if (ch_val.elem_is_str) "nox_threadchannel_send_str" else "nox_threadchannel_send_val";
        const fn_sym = try std.fmt.allocPrint(self.allocator, "${s}", .{fn_name});
        try self.qbeCall(null, fn_sym, &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = ch_val.text }, .{ .ty = .l, .text = payload.text } });
        return .{ .text = "0", .qtype = .none };
    }
    if (std.mem.eql(u8, a.attr, "recv")) {
        if (args.len != 0) return error.Unsupported;
        const fn_name = if (ch_val.elem_is_str) "nox_threadchannel_recv_str" else "nox_threadchannel_recv_val";
        const fn_sym = try std.fmt.allocPrint(self.allocator, "${s}", .{fn_name});
        const payload_t = try self.newTemp();
        try self.qbeCall(.{ .name = payload_t, .ty = .l }, fn_sym, &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = ch_val.text } });
        const converted = try self.fromPayload(.{ .text = payload_t, .qtype = .l }, ch_val.elem_qtype);
        return valueFromElemDescriptor(converted.text, converted.qtype, ch_val.elem_heap_info, ch_val.elem_is_str);
    }
    return error.Unsupported;
}
