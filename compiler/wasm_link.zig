//! `--target wasm32-*` bağlama PLANI: hangi nesnelerin bağlanacağı ve bağlayıcıya hangi bayrakların verileceği. `noxc` (`zig cc`, `linkWasm` in `main.zig`) ve tarayıcıdaki WASM
//! derleyici (clang/wasm-ld WASM'ı, spec §3.353) AYNI planı kullanır; böylece iki yol arasında bayrak sürüklenmesi olmaz. Bayraklar sürücüden bağımsızdır (`-Wl,...`);
//! sürücüye özgü olan tek şey iş parçacıklı kipin özellik bayrağıdır (`threads_features`: zig `-mcpu=generic+atomics+bulk_memory`, clang `-matomics -mbulk-memory`).

const std = @import("std");
const qbe_target = @import("qbe_target.zig");

pub const Plan = struct {
    /// Programın kullandığı `nox_sqlite_*` için SQLite nesnesi (`<runtime>-sqlite3.o`) bağlanır.
    sqlite: bool,
    /// `--threads`: atomics + bulk_memory özellikleri (tüm nesnelerde).
    threads_features: bool,
    /// Sürücüden bağımsız `-Wl,...` bayrakları.
    ld_flags: []const []const u8,
    /// Bağlama sonrası `wasm-opt --asyncify` gerekir.
    asyncify: bool,
};

fn has(ir: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, ir, needle) != null;
}

pub fn plan(a: std.mem.Allocator, info: qbe_target.HostedTargetInfo, ir: []const u8) std.mem.Allocator.Error!Plan {
    var flags: std.ArrayListUnmanaged([]const u8) = .empty;
    try flags.append(a, "-Wl,-z,stack-size=8388608");
    // Çalışma zamanı nesnesindeki DWARF ~3 MB ekler. `--strip-debug` `target_features` bölümünü de siler ve `wasm-opt` (asyncify/threads) onu okur; bu yollarda DWARF
    // zaten `wasm-opt --strip-dwarf` ile atılır. wasm-opt kullanmayan varsayılan kip burada soyulur; işlev adları korunur.
    if (!info.wasm_asyncify and !info.wasm_threads) try flags.append(a, "-Wl,--strip-debug");
    if (info.wasm_threads) {
        // ADR-015: paylaşımlı bellek + atomikler; Zig'in WasiThreadImpl'i `wasi_thread_start`ı dışa aktarılmış ister, host `wasi::thread-spawn` sağlar.
        try flags.appendSlice(a, &.{ "-Wl,--shared-memory", "-Wl,--import-memory", "-Wl,--initial-memory=33554432", "-Wl,--max-memory=1073741824" });
        if (!info.wasm_freestanding) try flags.append(a, "-Wl,--export=wasi_thread_start");
    }
    // wasm32-freestanding: libc/WASI başlangıcı yok; giriş `_start` (runtime/wasm_libc.zig), host import'ları `nox_host` ad alanından.
    if (info.wasm_freestanding) try flags.appendSlice(a, &.{ "-Wl,--no-entry", "-Wl,--export=_start", "-Wl,--export=nox_host_abi_version" });
    if (info.wasm_freestanding and info.wasm_threads) try flags.append(a, "-Wl,--export=nox_host_thread_start");
    // `--asyncify` freestanding'de `nox.http` istemcisi host `fetch`ini kullanabilir (spec §3.351); host'un çağıracağı dışa aktarımlar.
    if (info.wasm_freestanding and info.wasm_asyncify and !info.wasm_threads and (has(ir, "nox_http_") or has(ir, "nox_ws_") or has(ir, "nox_tls_") or has(ir, "nox_smtp_") or has(ir, "nox_pg_") or has(ir, "nox_process_"))) {
        try flags.appendSlice(a, &.{ "-Wl,--export=nox_host_caps_set", "-Wl,--export=nox_host_alloc", "-Wl,--export=nox_host_free", "-Wl,--export=nox_host_fetch_pending", "-Wl,--export=nox_host_fetch_complete", "-Wl,--export=nox_host_status", "-Wl,--export=nox_host_resume" });
    }
    // Sanal dosya sistemini kalıcı kılmak isteyen host için önyükleme/anlık görüntü dışa aktarımları (spec §3.350); yalnızca dosya sistemini kullanan programlara.
    if (info.wasm_freestanding and (has(ir, "nox_fs_") or has(ir, "nox_sqlite_"))) {
        try flags.appendSlice(a, &.{ "-Wl,--export=nox_vfs_host_alloc", "-Wl,--export=nox_vfs_host_free", "-Wl,--export=nox_vfs_host_put", "-Wl,--export=nox_vfs_host_mkdir", "-Wl,--export=nox_vfs_host_snapshot" });
    }
    return .{
        .sqlite = has(ir, "nox_sqlite_"),
        .threads_features = info.wasm_threads,
        .ld_flags = flags.items,
        .asyncify = info.wasm_asyncify,
    };
}

/// Compiler-rt arşivinin dosya adı (`zig cc` bunu kendiliğinden bağlar; `zig`siz bağlayıcılar `lib/` altından alır).
pub fn compilerRtName(info: qbe_target.HostedTargetInfo) []const u8 {
    return if (info.wasm_threads) "compiler-rt-wasm32-threads.a" else "compiler-rt-wasm32.a";
}

/// Düz metin biçimi (satır başına bir kayıt): tarayıcıdaki orkestratör ayrıştırır. `runtime <ad>`, `compiler_rt <dosya>`, `sqlite`, `threads_features`, `asyncify`, `flag <bayrak>`.
pub fn serialize(a: std.mem.Allocator, info: qbe_target.HostedTargetInfo, p: Plan) std.mem.Allocator.Error![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    try out.print(a, "runtime {s}\ncompiler_rt {s}\n", .{ info.runtime_object_name, compilerRtName(info) });
    if (p.sqlite) try out.appendSlice(a, "sqlite\n");
    if (p.threads_features) try out.appendSlice(a, "threads_features\n");
    if (p.asyncify) try out.appendSlice(a, "asyncify\n");
    for (p.ld_flags) |f| try out.print(a, "flag {s}\n", .{f});
    return out.items;
}

test "plan: freestanding + sqlite + fs + http(asyncify) bayraklari" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const info = qbe_target.hostedTargetInfo("wasm32-freestanding-asyncify").?;
    const p = try plan(a, info, "call @nox_sqlite_open_raw call @nox_http_get_raw");
    try std.testing.expect(p.sqlite and p.asyncify and !p.threads_features);
    var saw_start = false;
    var saw_fetch = false;
    var saw_vfs = false;
    var saw_strip = false;
    for (p.ld_flags) |f| {
        if (std.mem.eql(u8, f, "-Wl,--export=_start")) saw_start = true;
        if (std.mem.eql(u8, f, "-Wl,--export=nox_host_resume")) saw_fetch = true;
        if (std.mem.eql(u8, f, "-Wl,--export=nox_vfs_host_snapshot")) saw_vfs = true;
        if (std.mem.eql(u8, f, "-Wl,--strip-debug")) saw_strip = true;
    }
    try std.testing.expect(saw_start and saw_fetch and saw_vfs and !saw_strip);
}

test "plan: wasi duz kip dosya sistemi dışa aktarımı almaz, strip-debug alır" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const info = qbe_target.hostedTargetInfo("wasm32-wasi").?;
    const p = try plan(a, info, "call @nox_fs_exists_raw");
    try std.testing.expect(!p.sqlite);
    for (p.ld_flags) |f| try std.testing.expect(std.mem.indexOf(u8, f, "nox_vfs_host") == null);
    var saw_strip = false;
    for (p.ld_flags) |f| if (std.mem.eql(u8, f, "-Wl,--strip-debug")) {
        saw_strip = true;
    };
    try std.testing.expect(saw_strip);
}
