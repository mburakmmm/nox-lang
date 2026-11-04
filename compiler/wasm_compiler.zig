//! Tarayıcıda (ya da herhangi bir WASM host'unda) çalışan Nox derleyicisinin ön yüzü (spec §3.353): Nox kaynağı -> LLVM IR metni + bağlama planı. Dosya sistemi, süreç ya da ağ GEREKTİRMEZ:
//! stdlib derleme zamanında modüle gömülüdür (`tools/bundle_stdlib.zig`), kullanıcı modülleri `nox_fc_add_file` ile bellekte verilir. `wasm32-freestanding` modülü olarak derlenir
//! (`zig build wasm-compiler` -> `zig-out/lib/noxc-frontend.wasm`); import'u yoktur. IR'ı `.wasm`a çevirmek (clang + wasm-ld) JS tarafındadır (`compiler/wasm_compiler.mjs`).
//!
//! Protokol: `nox_fc_alloc/free` ile bellek ayrılır, `nox_fc_add_file(yol, veri)` sanal dosya ekler, `nox_fc_compile(kaynak, seçenekler)` derler (`0` başarı, `1` hata) ve sonuç
//! `nox_fc_result_*` ile okunur: başarıda `ir`, `plan` (bağlama planı, bkz. `wasm_link.serialize`) ve `diag`; hatada yalnızca `diag` (okunaklı tanılama metni).
//! Seçenekler satır başına `anahtar=değer`: `target=<wasm32-...>` (varsayılan wasm32-freestanding), `deny=<yetenek listesi>`, `label=<kaynak adı>`.
//! Küresel durum (dosya tablosu, son sonuç) tek örnekli bir WASM modülünün ürettiği çağrılar arasında yaşar; derleyici iş parçacıklı değildir.

const std = @import("std");
const ast = @import("parser/ast.zig");
const syntax_report = @import("syntax_report.zig");
const module_loader = @import("module_loader.zig");
const frontend = @import("frontend.zig");
const qbe_target = @import("qbe_target.zig");
const report_sink = @import("report_sink.zig");
const wasm_link = @import("wasm_link.zig");

const stdlib_bundle = @embedFile("stdlib_bundle");

const gpa = std.heap.page_allocator;

var g_files: std.StringHashMapUnmanaged([]const u8) = .empty;
var g_stdlib_loaded: bool = false;
var g_ir: []u8 = &.{};
var g_plan: []u8 = &.{};
var g_diag: []u8 = &.{};

fn loadStdlib() void {
    if (g_stdlib_loaded) return;
    g_stdlib_loaded = true;
    var i: usize = 0;
    while (i + 4 <= stdlib_bundle.len) {
        const plen = std.mem.readInt(u32, stdlib_bundle[i..][0..4], .little);
        const path = stdlib_bundle[i + 4 ..][0..plen];
        const dlen = std.mem.readInt(u32, stdlib_bundle[i + 4 + plen ..][0..4], .little);
        const data = stdlib_bundle[i + 8 + plen ..][0..dlen];
        i += 8 + plen + dlen;
        const key = std.fmt.allocPrint(gpa, "/stdlib/{s}", .{path}) catch return;
        g_files.put(gpa, key, data) catch return;
    }
}

fn fsExists(_: ?*anyopaque, path: []const u8) bool {
    return g_files.contains(path);
}

fn fsRead(_: ?*anyopaque, a: std.mem.Allocator, path: []const u8) error{ FileNotFound, OutOfMemory }![]u8 {
    const data = g_files.get(path) orelse return error.FileNotFound;
    return a.dupe(u8, data);
}

/// Sonuç tamponlarını (önceki derlemeden) serbest bırakır.
fn clearResult() void {
    if (g_ir.len > 0) gpa.free(g_ir);
    if (g_plan.len > 0) gpa.free(g_plan);
    if (g_diag.len > 0) gpa.free(g_diag);
    g_ir = &.{};
    g_plan = &.{};
    g_diag = &.{};
}

const Options = struct {
    target: []const u8 = "wasm32-freestanding",
    deny: []const u8 = "",
    label: []const u8 = "main.nox",
};

fn parseOptions(text: []const u8) Options {
    var o: Options = .{};
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const k = line[0..eq];
        const v = std.mem.trim(u8, line[eq + 1 ..], "\r ");
        if (std.mem.eql(u8, k, "target")) o.target = v else if (std.mem.eql(u8, k, "deny")) o.deny = v else if (std.mem.eql(u8, k, "label")) o.label = v;
    }
    return o;
}

fn compileImpl(arena: std.mem.Allocator, source: []const u8, opt_text: []const u8, diag: *report_sink.Collector) !void {
    const opts = parseOptions(opt_text);
    const sink = diag.sink();
    const info = qbe_target.hostedTargetInfo(opts.target) orelse {
        sink.print("unknown --target '{s}'\n", .{opts.target});
        return error.BuildFailed;
    };
    if (!info.wasm) {
        sink.print("the in-browser compiler only targets wasm32-* (got '{s}')\n", .{opts.target});
        return error.BuildFailed;
    }
    loadStdlib();
    const user_module = syntax_report.parseSourceTo(sink, arena, source, opts.label) catch return error.BuildFailed;
    const env: module_loader.LoadEnv = .{ .io = std.Io.failing, .exists_fn = fsExists, .read_fn = fsRead, .sink = sink };
    const module = module_loader.resolveImportsWithEnv(arena, env, user_module, "/stdlib") catch |e| {
        if (e != error.SyntaxError) sink.print("import error: {t}\n", .{e});
        return error.BuildFailed;
    };
    const cfg: frontend.Config = .{ .backend = .llvm, .profile = .hosted, .hosted_info = info, .deny_capabilities = opts.deny };
    var analysis = try frontend.analyze(arena, module, cfg, sink);
    const ir = try frontend.emit(arena, module, &analysis, cfg, .{ .llvm_triple = if (info.llvmOnly()) info.llvmTriple() else "" }, sink);
    const link_plan = try wasm_link.plan(arena, info, ir);
    const plan_text = try wasm_link.serialize(arena, info, link_plan);
    g_ir = try gpa.dupe(u8, ir);
    g_plan = try gpa.dupe(u8, plan_text);
}

// ---- Dışa aktarımlar ---------------------------------------------------------------------------------------------------------------------------------

export fn nox_fc_alloc(len: usize) callconv(.c) ?[*]u8 {
    const block = gpa.alloc(u8, @max(len, 1)) catch return null;
    return block.ptr;
}

export fn nox_fc_free(ptr: ?[*]u8, len: usize) callconv(.c) void {
    const p = ptr orelse return;
    gpa.free(p[0..@max(len, 1)]);
}

/// Sanal dosya ekler/değiştirir (`yol` tam yoldur; stdlib `/stdlib/nox/...` altındadır). `0` başarı.
export fn nox_fc_add_file(path: [*]const u8, path_len: usize, data: [*]const u8, data_len: usize) callconv(.c) i32 {
    loadStdlib();
    const key = gpa.dupe(u8, path[0..path_len]) catch return -1;
    const val = gpa.dupe(u8, data[0..data_len]) catch {
        gpa.free(key);
        return -1;
    };
    g_files.put(gpa, key, val) catch return -1;
    return 0;
}

/// Derler. `0` başarı (`nox_fc_result_ir/plan`), `1` hata (`nox_fc_result_diag`). Her çağrı önceki sonucu siler.
export fn nox_fc_compile(src: [*]const u8, src_len: usize, opts: [*]const u8, opts_len: usize) callconv(.c) i32 {
    clearResult();
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diag = report_sink.Collector{ .allocator = arena };
    const ok = if (compileImpl(arena, src[0..src_len], opts[0..opts_len], &diag)) |_| true else |e| blk: {
        if (diag.list.items.len == 0) diag.sink().print("compile failed: {t}\n", .{e});
        break :blk false;
    };
    g_diag = gpa.dupe(u8, diag.list.items) catch &.{};
    if (!ok) {
        if (g_ir.len > 0) gpa.free(g_ir);
        g_ir = &.{};
        return 1;
    }
    return 0;
}

export fn nox_fc_result_ir(len: *usize) callconv(.c) ?[*]const u8 {
    len.* = g_ir.len;
    return g_ir.ptr;
}

export fn nox_fc_result_plan(len: *usize) callconv(.c) ?[*]const u8 {
    len.* = g_plan.len;
    return g_plan.ptr;
}

export fn nox_fc_result_diag(len: *usize) callconv(.c) ?[*]const u8 {
    len.* = g_diag.len;
    return g_diag.ptr;
}
