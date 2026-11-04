//! `noxc build`in ön yüzü: tip denetimi -> sahiplik/codegen meta verisi -> LLVM/QBE IR metni. `compiler/main.zig` (CLI) ve `compiler/wasm_compiler.zig` (tarayıcıda çalışan WASM derleyici,
//! spec §3.353) AYNI kodu kullanır; böylece iki yolun ürettiği IR byte-birebir aynıdır (bkz. `tests/golden/wasm_frontend_test.zig`). Bu dosya dosya sistemi, süreç ya da stderr'e DOKUNMAZ:
//! tanılamalar `report_sink.Sink`e yazılır.

const std = @import("std");
const ast = @import("parser/ast.zig");
const checker = @import("typecheck/checker.zig");
const codegen = @import("codegen_qbe/codegen.zig");
const qbe_target = @import("qbe_target.zig");
const report_sink = @import("report_sink.zig");

pub fn mobileMaskOf(info: ?qbe_target.HostedTargetInfo) checker.MobileMask {
    const ht = info orelse return .none;
    return switch (ht.mobile) {
        .none => .none,
        .ios_device, .ios_simulator => .ios,
        .android => .android,
    };
}

pub const Config = struct {
    backend: codegen.Backend,
    profile: codegen.Profile,
    hosted_info: ?qbe_target.HostedTargetInfo = null,
    /// `--deny-capability` listesi (virgülle ayrılmış); bilinmeyen ad `error.BuildFailed` (tanılama `sink`e yazılır).
    deny_capabilities: []const u8 = "",
};

/// Tip denetimi sonucu ve codegen'in ihtiyaç duyduğu, denetleyiciden türetilmiş meta veri.
pub const Analysis = struct {
    state: checker.Checker,
    generic_names: []const []const u8,
    functions_used_as_value: []const []const u8,
    callback_targets: []const []const u8,
    resolved_bases: std.StringHashMapUnmanaged([]const u8),
    generic_class_names: []const []const u8,
    closure_infos: std.StringHashMapUnmanaged([]const []const u8),

    pub fn instantiations(self: *const Analysis) []const ast.FuncDef {
        return self.state.instantiations.items;
    }

    pub fn classInstantiations(self: *const Analysis) []const ast.ClassDef {
        return self.state.class_instantiations.items;
    }
};

/// `module`ü (import'lar çözülmüş) denetler. Tip hatalarında `sink`e `type error (...)` satırları yazıp `error.BuildFailed` döner.
pub fn analyze(a: std.mem.Allocator, module: ast.Module, cfg: Config, sink: report_sink.Sink) !Analysis {
    var state = checker.Checker.init(a);
    state.denyCapabilities(cfg.deny_capabilities) catch {
        sink.print("unknown capability in --deny-capability / NOX_DENY_CAPABILITY: '{s}' (valid: filesystem|fs, network|net, clock, entropy|random, threads, process, shared_memory|shm, libc_math, dynamic_code|dynamic)\n", .{cfg.deny_capabilities});
        return error.BuildFailed;
    };
    state.backend = cfg.backend;
    state.profile = cfg.profile;
    state.mobile_mask = mobileMaskOf(cfg.hosted_info);
    state.wasm_target = if (cfg.hosted_info) |ht| ht.wasm else false;
    state.wasm_freestanding = if (cfg.hosted_info) |ht| ht.wasm_freestanding else false;
    state.checkModule(module) catch |e| {
        sink.print("type error ({t}): {s}\n", .{ e, state.diagnostic orelse "(no message)" });
        return error.BuildFailed;
    };
    // `checkModule` fonksiyon/sınıf/metod/gevşek-deyim sınırındaki hataları FIRLATMAZ, `diagnostics`e kaydeder: başarılı dönüş tek başına "tip hatasız" değildir.
    if (state.diagnostics.items.len > 0) {
        for (state.diagnostics.items) |d| sink.print("type error ({t}): {s}\n", .{ d.code, d.message });
        return error.BuildFailed;
    }

    // Codegen'in `module.body`deki generic ŞABLONLARINI (açık `[T]` ya da örtük protokol parametresi) atlayabilmesi için isimleri, değer olarak kullanılan fonksiyonlar,
    // `@ffi.callback` hedefleri, çözülmüş sınıf tabanları, generic sınıf adları ve closure yakalama listeleri (isim + yalnızca yakalanan İSİMLER) iletilir.
    var generic_names: std.ArrayListUnmanaged([]const u8) = .empty;
    var generic_it = state.generic_functions.keyIterator();
    while (generic_it.next()) |k| try generic_names.append(a, k.*);

    var functions_used_as_value: std.ArrayListUnmanaged([]const u8) = .empty;
    var fn_value_it = state.functions_used_as_value.keyIterator();
    while (fn_value_it.next()) |k| try functions_used_as_value.append(a, k.*);

    var callback_targets: std.ArrayListUnmanaged([]const u8) = .empty;
    var cb_target_it = state.callback_targets.keyIterator();
    while (cb_target_it.next()) |k| try callback_targets.append(a, k.*);

    // Çapraz-modül sınıf kalıtımı: `classes`in her girdisinin `.base`i (`registerClassSignatures`ın `from_imports` geri-düşüşüyle ZATEN doğru çözülmüş) haritaya kopyalanır;
    // codegen kendi başına çözümleme uygulamaz.
    var resolved_bases: std.StringHashMapUnmanaged([]const u8) = .empty;
    var class_base_it = state.classes.iterator();
    while (class_base_it.next()) |e| {
        if (e.value_ptr.*.base) |b| try resolved_bases.put(a, e.key_ptr.*, b);
    }

    var generic_class_names: std.ArrayListUnmanaged([]const u8) = .empty;
    var generic_class_it = state.generic_classes.keyIterator();
    while (generic_class_it.next()) |k| try generic_class_names.append(a, k.*);

    var closure_infos: std.StringHashMapUnmanaged([]const []const u8) = .empty;
    var closure_it = state.closure_infos.iterator();
    while (closure_it.next()) |entry| {
        const names = try a.alloc([]const u8, entry.value_ptr.captures.len);
        for (entry.value_ptr.captures, 0..) |c, i| names[i] = c.name;
        try closure_infos.put(a, entry.key_ptr.*, names);
    }

    return .{
        .state = state,
        .generic_names = generic_names.items,
        .functions_used_as_value = functions_used_as_value.items,
        .callback_targets = callback_targets.items,
        .resolved_bases = resolved_bases,
        .generic_class_names = generic_class_names.items,
        .closure_infos = closure_infos,
    };
}

pub const EmitOptions = struct {
    /// `-g`: kaynak yolu gömülür (codegen `dbgfile`).
    debug_source_path: ?[]const u8 = null,
    library_mode: bool = false,
    llvm_triple: []const u8 = "",
};

/// `analyze` sonucundan IR metnini üretir. Desteklenmeyen bir yapı ya da global başlatma sırası hatası `sink`e yazılır ve `error.BuildFailed` döner.
pub fn emit(a: std.mem.Allocator, module: ast.Module, an: *const Analysis, cfg: Config, opts: EmitOptions, sink: report_sink.Sink) ![]const u8 {
    return codegen.generateModuleWithMetaSink(a, module, an.instantiations(), an.generic_names, an.classInstantiations(), an.generic_class_names, opts.debug_source_path, an.closure_infos, an.state.defer_synthetic_names, an.state.from_imports, an.functions_used_as_value, an.state.module_aliases, an.state.decorated_functions.items, cfg.backend, cfg.profile, null, an.callback_targets, an.resolved_bases, an.state.class_ctors.items, opts.library_mode, opts.llvm_triple, sink) catch |err| switch (err) {
        error.Unsupported => {
            sink.print(
                "codegen: this program contains a construct that is not supported at the moment " ++
                    "(e.g. a nested function/class definition, an unsupported " ++
                    "type expression, or a for loop over an iterable other than " ++
                    "range()/list[T]) - see the language reference at " ++
                    "https://noxlang.com/docs/language/\n",
                .{},
            );
            return error.BuildFailed;
        },
        // Ayrıntılı ileti (hangi değişken hangisini okuyor) codegen'de basıldı.
        error.GlobalInitOrder => return error.BuildFailed,
        else => |e| return e,
    };
}
