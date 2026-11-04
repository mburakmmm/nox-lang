//! Faz 10 (WASM, bkz. nox-teknik-spesifikasyon.md): `noxc build --target wasm32-wasi` uçtan uca — LLVM `.ll` -> `zig cc -target wasm32-wasi` ->
//! `.wasm`, Node'un WASI'siyle çalıştırılır. Her fixture `codegen_cases/` korpusundan alınır; beklenen çıktı native (QBE/LLVM) çalıştırmayla AYNIDIR
//! (Python referansıyla doğrulanmış `.expected`). Kapsanan alanlar: ABI uyarlaması (32-bit işaretçi / 64-bit sözcük), düz (atomik olmayan) ARC,
//! döngü çözücü, iz arabelleği, async üreteç (iç içe çalıştırma benzetimi), kapanış yakalamada Channel retain'i, JSON, fs/regex/gzip/crypto kabukları,
//! çoklu kalıtım vtable'ları. Ayrıca wasm'de olmayan modüllerin DERLEME ZAMANINDA açık iletiyle reddedildiği doğrulanır.
//!
//! Her fixture HEM `wasm32-wasi` HEM `wasm32-freestanding` (ADR-013, `nox_host` import'ları) hedefinde çalışır.
//! `node`/`zig` PATH'te yoksa test SESSİZCE atlanır. Tüm korpus için opt-in `zig build wasm-corpus-test`.

const std = @import("std");
const build_options = @import("build_options");
const wasm_helpers = @import("wasm_helpers.zig");

fn expectGolden(name: []const u8, source: []const u8, expected: []const u8) !void {
    inline for (.{ wasm_helpers.Target.wasi, wasm_helpers.Target.freestanding }) |t| try expectGoldenOn(t, name, source, expected);
}

fn expectGoldenOn(target: wasm_helpers.Target, name: []const u8, source: []const u8, expected: []const u8) !void {
    const allocator = std.testing.allocator;
    const outcome = try wasm_helpers.buildAndRun(allocator, build_options.noxc_path, build_options.runner_path, target, source);
    switch (outcome) {
        .tool_missing => return error.SkipZigTest,
        .rejected => |msg| {
            defer allocator.free(msg);
            std.debug.print("{s} [{s}]: wasm hedefinde reddedildi: {s}\n", .{ name, wasm_helpers.targetName(target), msg });
            return error.UnexpectedlyRejected;
        },
        .build_failed => |msg| {
            defer allocator.free(msg);
            std.debug.print("{s} [{s}]: wasm derlemesi basarisiz: {s}\n", .{ name, wasm_helpers.targetName(target), msg });
            return error.BuildFailed;
        },
        .ran => |r| {
            defer allocator.free(r.stdout);
            defer allocator.free(r.stderr);
            if (r.term != .exited or r.term.exited != 0) {
                std.debug.print("{s} [{s}]: wasm programi basarisiz (stderr): {s}\n", .{ name, wasm_helpers.targetName(target), r.stderr });
                return error.ProgramFailed;
            }
            try std.testing.expectEqualStrings(expected, r.stdout);
        },
    }
}

fn expectRejected(source: []const u8, needle: []const u8) !void {
    try expectRejectedOn(.wasi, source, needle);
    try expectRejectedOn(.freestanding, source, needle);
}

fn expectRejectedOn(target: wasm_helpers.Target, source: []const u8, needle: []const u8) !void {
    const allocator = std.testing.allocator;
    const outcome = try wasm_helpers.buildAndRun(allocator, build_options.noxc_path, build_options.runner_path, target, source);
    switch (outcome) {
        .tool_missing => return error.SkipZigTest,
        .rejected => |msg| {
            defer allocator.free(msg);
            try std.testing.expect(std.mem.indexOf(u8, msg, needle) != null);
        },
        .build_failed => |msg| {
            defer allocator.free(msg);
            std.debug.print("beklenen ret degil, baska bir derleme hatasi: {s}\n", .{msg});
            return error.BuildFailed;
        },
        .ran => |r| {
            allocator.free(r.stdout);
            allocator.free(r.stderr);
            return error.ExpectedRejection;
        },
    }
}

test "wasm32-wasi: fibonacci (özyineleme + while + print)" {
    try expectGolden("fibonacci", @embedFile("codegen_cases/fibonacci.nox"), @embedFile("codegen_cases/fibonacci.expected"));
}

test "wasm32-wasi: float yazdırma Python repr ile birebir (printf değişken argüman ABI'si)" {
    try expectGolden("float_repr_python", @embedFile("codegen_cases/float_repr_python.nox"), @embedFile("codegen_cases/float_repr_python.expected"));
}

test "wasm32-wasi: list/dict comprehension + sınıf + istisna mesajı" {
    try expectGolden("comprehensions", @embedFile("codegen_cases/comprehensions.nox"), @embedFile("codegen_cases/comprehensions.expected"));
    try expectGolden("exception_str_message", @embedFile("codegen_cases/exception_str_message.nox"), @embedFile("codegen_cases/exception_str_message.expected"));
    try expectGolden("dunder_protocol", @embedFile("codegen_cases/dunder_protocol.nox"), @embedFile("codegen_cases/dunder_protocol.expected"));
}

test "wasm32-wasi: çoklu kalıtım vtable'ları ({i32,i32} çift sabitleri)" {
    try expectGolden("multiple_inheritance_mixins", @embedFile("codegen_cases/multiple_inheritance_mixins.nox"), @embedFile("codegen_cases/multiple_inheritance_mixins.expected"));
    try expectGolden("multiple_inheritance_subtyping", @embedFile("codegen_cases/multiple_inheritance_subtyping.nox"), @embedFile("codegen_cases/multiple_inheritance_subtyping.expected"));
}

test "wasm32-wasi: döngü çözücü + iz arabelleği 8 baytlık yuvalar" {
    try expectGolden("class_reference_cycle_collected", @embedFile("codegen_cases/class_reference_cycle_collected.nox"), @embedFile("codegen_cases/class_reference_cycle_collected.expected"));
    try expectGolden("cycle_nested_list_class_fields", @embedFile("codegen_cases/cycle_nested_list_class_fields.nox"), @embedFile("codegen_cases/cycle_nested_list_class_fields.expected"));
}

test "wasm32-wasi: jeneratörler ve async üreteçler (Channel parametresi kapanışta retain edilir)" {
    try expectGolden("generators_auto_close", @embedFile("codegen_cases/generators_auto_close.nox"), @embedFile("codegen_cases/generators_auto_close.expected"));
    try expectGolden("async_generators", @embedFile("codegen_cases/async_generators.nox"), @embedFile("codegen_cases/async_generators.expected"));
}

test "wasm32-wasi: JSON, regex, gzip, sha256, fs kabukları" {
    try expectGolden("json_encode_roundtrip", @embedFile("codegen_cases/json_encode_roundtrip.nox"), @embedFile("codegen_cases/json_encode_roundtrip.expected"));
    try expectGolden("regex_engine", @embedFile("codegen_cases/regex_engine.nox"), @embedFile("codegen_cases/regex_engine.expected"));
    try expectGolden("gzip_roundtrip", @embedFile("codegen_cases/gzip_compress_decompress_str_roundtrip.nox"), @embedFile("codegen_cases/gzip_compress_decompress_str_roundtrip.expected"));
    try expectGolden("crypto_sha256", @embedFile("codegen_cases/crypto_sha256_known_vectors.nox"), @embedFile("codegen_cases/crypto_sha256_known_vectors.expected"));
    try expectGoldenOn(.wasi, "fs_read_write_roundtrip", @embedFile("codegen_cases/fs_read_write_roundtrip.nox"), @embedFile("codegen_cases/fs_read_write_roundtrip.expected"));
}

test "wasm32-wasi: henüz desteklenmeyen modül derleme zamanında açık iletiyle reddedilir" {
    try expectRejected("import nox.sharedmem\nprint(1)\n", "cannot be used on the wasm32-wasi target");
    try expectRejected("import nox.native\nprint(1)\n", "cannot be used on the wasm32-wasi target");
}

// v2.0.146 (spec §3.348): `nox.sqlite` WASM'da DERLENİR; SQLite amalgamation'ı ayrı bir nesne olarak (`noxrt-wasm32-*-sqlite3.o`) yalnızca `nox_sqlite_*` kullanan
// programlara bağlanır. wasm32-wasi'de dosya tabanlı veritabanı ön-açılmış dizinlerde, wasm32-freestanding'de yalnızca bellek-içi (`:memory:`) çalışır.
test "wasm: nox.sqlite bellek-içi sorgu + hata yolu" {
    try expectGolden("sqlite_memory_roundtrip", @embedFile("codegen_cases/sqlite_memory_roundtrip.nox"), @embedFile("codegen_cases/sqlite_memory_roundtrip.expected"));
}

// v2.0.144 (spec §3.346): `nox.http` ve ona bağlı router/web/reflect/transfer WASM'da DERLENİR. Yönlendirme ve bir handler'ın doğrudan çağrılarak sınanması saf Nox'tur
// ve çalışır; yalnızca soket gerektiren çağrılar host'ta "network" yeteneği yoksa yakalanabilir bir `HttpCapabilityError` fırlatır (`HttpError`ın alt sınıfı).
const http_capability_program =
    \\import nox.http
    \\import nox.router
    \\from nox.http import HttpRequest, HttpResponse, HttpError, HttpCapabilityError
    \\from nox.router import Router, Context
    \\
    \\def hello(ctx: Context) -> HttpResponse:
    \\    return HttpResponse(200, "hello " + ctx.param("name"), {"Content-Type": "text/plain"})
    \\
    \\r: Router = Router()
    \\r.get("/hi/:name", hello)
    \\resp: HttpResponse = r.dispatch(HttpRequest("GET", "/hi/nox", "", {}))
    \\print(resp.status, resp.body)
    \\
    \\try:
    \\    nox.http.get("http://example.com/", {})
    \\    print("unexpected")
    \\except HttpCapabilityError as e:
    \\    print("capability:", e.message)
    \\
    \\try:
    \\    nox.http.post("http://example.com/", "x", {})
    \\except HttpError:
    \\    print("generic HttpError catch ok")
    \\
    \\try:
    \\    nox.http.request("DELETE", "http://example.com/x", "", {}, 1000)
    \\except HttpCapabilityError as e:
    \\    print("request:", e.message)
    \\
;

const http_capability_expected =
    \\200 hello nox
    \\capability: the 'network' capability is not available on this host: GET http://example.com/
    \\generic HttpError catch ok
    \\request: the 'network' capability is not available on this host: DELETE http://example.com/x
    \\
;

test "wasm: nox.http + nox.router derlenir; handler doğrudan çalışır; ağ çağrıları HttpCapabilityError verir (6 hedef)" {
    inline for (.{ wasm_helpers.Target.wasi, .freestanding, .wasi_asyncify, .freestanding_asyncify, .wasi_threads, .freestanding_threads }) |t| {
        try expectGoldenOn(t, "http_capability", http_capability_program, http_capability_expected);
    }
}

test "wasm: nox.http.serve dinleyemez, tanı yazıp bir bind hatası gibi hemen döner (program çökmez)" {
    const src =
        \\import nox.http
        \\from nox.http import HttpRequest, HttpResponse
        \\
        \\def handle(req: HttpRequest) -> HttpResponse:
        \\    return HttpResponse(200, "x", {})
        \\
        \\nox.http.serve(8080, handle)
        \\print("after serve")
        \\
    ;
    try expectGolden("serve_unavailable", src, "after serve\n");
}

test "wasm: web / router / reflect / akışlı yanıt fixture'ları artık wasm'da native ile aynı çıktıyı verir" {
    try expectGolden("web_building_blocks", @embedFile("codegen_cases/web_building_blocks.nox"), @embedFile("codegen_cases/web_building_blocks.expected"));
    try expectGolden("router_basic", @embedFile("codegen_cases/router_basic_routing_and_middleware.nox"), @embedFile("codegen_cases/router_basic_routing_and_middleware.expected"));
    try expectGolden("router_query", @embedFile("codegen_cases/router_query_string.nox"), @embedFile("codegen_cases/router_query_string.expected"));
    try expectGolden("reflect_signature", @embedFile("codegen_cases/reflect_signature_metadata.nox"), @embedFile("codegen_cases/reflect_signature_metadata.expected"));
    try expectGolden("response_stream_detached", @embedFile("codegen_cases/response_stream_detached.nox"), @embedFile("codegen_cases/response_stream_detached.expected"));
    try expectGolden("http_request_methods_errors", @embedFile("codegen_cases/http_request_methods_errors.nox"), @embedFile("codegen_cases/http_request_methods_errors.expected"));
}

test "wasm32-wasi: HPy/WASM köprü yerleşikleri reddedilir" {
    try expectRejected("print(wasm_call(\"a.wasm\", \"f\", 1))\n", "cannot be used on the wasm32-wasi target");
}

test "wasm32-freestanding: nox_host stdout/stderr, ortam tablosu, argv[0], libm" {
    // Yalnızca freestanding'e özgü davranışlar: boş başlangıç ortamı + modüle özel set_var, argv[0] = "nox", math (compiler-rt + atan2).
    try expectGoldenOn(.freestanding, "os_new_operations", @embedFile("codegen_cases/os_new_operations.nox"), @embedFile("codegen_cases/os_new_operations.expected"));
    try expectGoldenOn(.freestanding, "os_args_basic", @embedFile("codegen_cases/os_args_basic.nox"), @embedFile("codegen_cases/os_args_basic.expected"));
    try expectGoldenOn(.freestanding, "mathx_basic", @embedFile("codegen_cases/mathx_basic.nox"), @embedFile("codegen_cases/mathx_basic.expected"));
}

// v2.0.147 (spec §3.349): wasm32-freestanding'de `nox.fs` çalışma zamanının bellek içi sanal dosya sistemi üzerinde ÇALIŞIR (host import'u gerekmez). Tüm `fs_*` fixture'ları ve
// dosya tabanlı `nox.sqlite` hem native hem 6 WASM hedefinde aynı çıktıyı verir; iş parçacıklı kiplerde sanal dosya sistemi paylaşılır.
test "wasm: nox.fs sanal dosya sistemi (freestanding) ve dosya tabanlı sqlite" {
    inline for (.{ wasm_helpers.Target.wasi, .freestanding, .wasi_asyncify, .freestanding_asyncify, .wasi_threads, .freestanding_threads }) |t| {
        try expectGoldenOn(t, "fs_tree_semantics", @embedFile("codegen_cases/fs_tree_semantics.nox"), @embedFile("codegen_cases/fs_tree_semantics.expected"));
        try expectGoldenOn(t, "fs_new_operations", @embedFile("codegen_cases/fs_new_operations.nox"), @embedFile("codegen_cases/fs_new_operations.expected"));
        try expectGoldenOn(t, "path_new_operations", @embedFile("codegen_cases/path_new_operations.nox"), @embedFile("codegen_cases/path_new_operations.expected"));
        try expectGoldenOn(t, "fs_dir_removal", @embedFile("codegen_cases/fs_dir_removal.nox"), @embedFile("codegen_cases/fs_dir_removal.expected"));
        try expectGoldenOn(t, "fs_streaming", @embedFile("codegen_cases/fs_streaming.nox"), @embedFile("codegen_cases/fs_streaming.expected"));
        try expectGoldenOn(t, "sqlite_file_roundtrip", @embedFile("codegen_cases/sqlite_file_roundtrip.nox"), @embedFile("codegen_cases/sqlite_file_roundtrip.expected"));
    }
}

test "wasm32 --asyncify: gerçek fiber askıya alma (iç içe benzetimin deadlock sınırı yok)" {
    // Asyncify (ADR-014): `wasm-opt --asyncify` gerekir (yoksa atlanır). Bu fixture'lar iç içe benzetimde zamanlama farkıyla ayrışır ya da kilitlenirdi.
    inline for (.{ wasm_helpers.Target.wasi_asyncify, wasm_helpers.Target.freestanding_asyncify }) |t| {
        try expectGoldenOn(t, "async_channel", @embedFile("codegen_cases/async_channel.nox"), @embedFile("codegen_cases/async_channel.expected"));
        try expectGoldenOn(t, "async_generators", @embedFile("codegen_cases/async_generators.nox"), @embedFile("codegen_cases/async_generators.expected"));
        try expectGoldenOn(t, "async_spawn_await", @embedFile("codegen_cases/async_spawn_await.nox"), @embedFile("codegen_cases/async_spawn_await.expected"));
        try expectGoldenOn(t, "task_local_basic", @embedFile("codegen_cases/task_local_basic.nox"), @embedFile("codegen_cases/task_local_basic.expected"));
        try expectGoldenOn(t, "thread_spawn_ordering", @embedFile("codegen_cases/thread_spawn_ordering.nox"), @embedFile("codegen_cases/thread_spawn_ordering.expected"));
        try expectGoldenOn(t, "closure_captures_channel_retained", @embedFile("codegen_cases/closure_captures_channel_retained.nox"), @embedFile("codegen_cases/closure_captures_channel_retained.expected"));
        // v2.0.84: her swap bir çerçeve sızdırıyordu; 8 MiB gölge yığın birkaç yüz bin askıya almada taşardı.
        try expectGoldenOn(t, "async_task_churn_long", @embedFile("codegen_cases/async_task_churn_long.nox"), @embedFile("codegen_cases/async_task_churn_long.expected"));
    }
}

test "wasm32 --asyncify: --asyncify yalnızca wasm hedeflerinde geçerlidir" {
    const allocator = std.testing.allocator;
    const result = std.process.run(allocator, std.testing.io, .{ .argv = &.{ build_options.noxc_path, "build", "--asyncify", "--target", "linux-x64", "x.nox" } }) catch return error.SkipZigTest;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    try std.testing.expect(result.term == .exited and result.term.exited != 0);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "--asyncify only applies") != null);
}

test "wasm32-wasi-threads: gerçek iş parçacığı (paylaşımlı bellek + atomikler + M:N havuzu)" {
    // ADR-015: `wasm_host.mjs` her wasm iş parçacığını bir Node Worker'ı olarak açar (`wasi::thread-spawn`). Havuz birden çok işçiyle kurulur.
    inline for (.{ wasm_helpers.Target.wasi_threads, wasm_helpers.Target.freestanding_threads }) |t| try threadsSmoke(t);
}

fn threadsSmoke(t: wasm_helpers.Target) !void {
    try expectGoldenOn(t, "async_channel", @embedFile("codegen_cases/async_channel.nox"), @embedFile("codegen_cases/async_channel.expected"));
    try expectGoldenOn(t, "async_generators", @embedFile("codegen_cases/async_generators.nox"), @embedFile("codegen_cases/async_generators.expected"));
    try expectGoldenOn(t, "atomic_shared_counter_across_threads", @embedFile("codegen_cases/atomic_shared_counter_across_threads.nox"), @embedFile("codegen_cases/atomic_shared_counter_across_threads.expected"));
    try expectGoldenOn(t, "thread_spawn_join_int", @embedFile("codegen_cases/thread_spawn_join_int.nox"), @embedFile("codegen_cases/thread_spawn_join_int.expected"));
    try expectGoldenOn(t, "thread_spawn_stress", @embedFile("codegen_cases/thread_spawn_stress.nox"), @embedFile("codegen_cases/thread_spawn_stress.expected"));
    try expectGoldenOn(t, "async_task_churn_long", @embedFile("codegen_cases/async_task_churn_long.nox"), @embedFile("codegen_cases/async_task_churn_long.expected"));
    try expectGoldenOn(t, "thread_channel_backpressure", @embedFile("codegen_cases/thread_channel_backpressure.nox"), @embedFile("codegen_cases/thread_channel_backpressure.expected"));
    try expectGoldenOn(t, "class_reference_cycle_collected", @embedFile("codegen_cases/class_reference_cycle_collected.nox"), @embedFile("codegen_cases/class_reference_cycle_collected.expected"));
    try expectGoldenOn(t, "fs_written_by_threads", @embedFile("codegen_cases/fs_written_by_threads.nox"), @embedFile("codegen_cases/fs_written_by_threads.expected"));
}

test "wasm32 --threads: yalnızca wasm32-wasi ve wasm32-freestanding hedeflerinde geçerlidir" {
    const allocator = std.testing.allocator;
    const result = std.process.run(allocator, std.testing.io, .{ .argv = &.{ build_options.noxc_path, "build", "--threads", "--target", "linux-x64", "x.nox" } }) catch return error.SkipZigTest;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    try std.testing.expect(result.term == .exited and result.term.exited != 0);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "--threads only applies") != null);
}

// v2.0.148 (spec §3.350): kalıcı sanal dosya sistemi. `node wasm_host.mjs prog.wasm --vfs-dir=DIR` dizini yükler ve çıkışta geri yazar: program art arda çalıştırılınca
// dosyalar ve dosya tabanlı sqlite korunur, programın sildiği dosya diskten silinir, `/tmp` kaydedilmez. Aynı program dosya sistemini kullanmıyorsa `--vfs-dir` zararsızdır.
const persist_program =
    \\import nox.fs
    \\import nox.sqlite
    \\from nox.sqlite import Connection
    \\from nox.db import Row
    \\
    \\n: int = 0
    \\if nox.fs.exists("/data/counter.txt"):
    \\    n = int(nox.fs.read_to_string("/data/counter.txt"))
    \\else:
    \\    nox.fs.create_dir("/data")
    \\n = n + 1
    \\nox.fs.write_string("/data/counter.txt", str(n))
    \\nox.fs.write_string("/tmp/scratch.txt", "gecici")
    \\conn: Connection = nox.sqlite.open("/data/app.db")
    \\conn.execute("CREATE TABLE IF NOT EXISTS runs (n INTEGER)")
    \\conn.execute("INSERT INTO runs VALUES (" + str(n) + ")")
    \\rows: list[Row] = conn.query("SELECT n FROM runs")
    \\print("run", n, "rows", len(rows))
    \\conn.close()
    \\
;

test "wasm32-freestanding: --vfs-dir sanal dosya sistemini kalıcı kılar (3 çalıştırma, 3 hedef kipi)" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    inline for (.{ wasm_helpers.Target.freestanding, .freestanding_asyncify, .freestanding_threads }) |t| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const len = try tmp.dir.realPath(io, &path_buf);
        const arg = try std.fmt.allocPrint(allocator, "--vfs-dir={s}/state", .{path_buf[0..len]});
        defer allocator.free(arg);
        const outcome = try wasm_helpers.buildAndRunRepeated(allocator, build_options.noxc_path, build_options.runner_path, t, persist_program, &.{arg}, 3);
        switch (outcome) {
            .tool_missing => return error.SkipZigTest,
            .rejected, .build_failed => |msg| {
                defer allocator.free(msg);
                std.debug.print("persist [{s}]: derleme basarisiz: {s}\n", .{ wasm_helpers.targetName(t), msg });
                return error.BuildFailed;
            },
            .ran => |r| {
                defer allocator.free(r.stdout);
                defer allocator.free(r.stderr);
                if (r.term != .exited or r.term.exited != 0) {
                    std.debug.print("persist [{s}]: program basarisiz: {s}\n", .{ wasm_helpers.targetName(t), r.stderr });
                    return error.ProgramFailed;
                }
                try std.testing.expectEqualStrings("run 1 rows 1\nrun 2 rows 2\nrun 3 rows 3\n", r.stdout);
            },
        }
        // Diskte: sayaç ve veritabanı var, /tmp'ye yazılan dosya yok.
        var state = try tmp.dir.openDir(io, "state", .{});
        defer state.close(io);
        const counter = try state.readFileAlloc(io, "data/counter.txt", allocator, .limited(64));
        defer allocator.free(counter);
        try std.testing.expectEqualStrings("3", counter);
        const db = try state.statFile(io, "data/app.db", .{});
        try std.testing.expect(db.size > 0);
        try std.testing.expectError(error.FileNotFound, state.statFile(io, "tmp/scratch.txt", .{}));
    }
}

test "wasm32-freestanding: dosya sistemini kullanmayan program --vfs-dir dizinine dokunmaz" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "state");
    try tmp.dir.writeFile(io, .{ .sub_path = "state/keep.txt", .data = "korunmali" });
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &path_buf);
    const arg = try std.fmt.allocPrint(allocator, "--vfs-dir={s}/state", .{path_buf[0..len]});
    defer allocator.free(arg);
    const outcome = try wasm_helpers.buildAndRunRepeated(allocator, build_options.noxc_path, build_options.runner_path, .freestanding, "print(1)\n", &.{arg}, 1);
    switch (outcome) {
        .tool_missing => return error.SkipZigTest,
        .rejected, .build_failed => |msg| {
            defer allocator.free(msg);
            return error.BuildFailed;
        },
        .ran => |r| {
            defer allocator.free(r.stdout);
            defer allocator.free(r.stderr);
            try std.testing.expectEqualStrings("1\n", r.stdout);
        },
    }
    const kept = try tmp.dir.readFileAlloc(io, "state/keep.txt", allocator, .limited(64));
    defer allocator.free(kept);
    try std.testing.expectEqualStrings("korunmali", kept);
}

// v2.0.149 (spec §3.351): `wasm32-freestanding --asyncify` + `nox.http` istemcisi host `fetch`ine dayanır. Sürücü (`wasm_fetch_driver.mjs`) süreç içi sahte bir `fetch` verir:
// sıralı istekler, gövde/başlık iletimi, 404, bağlantı hatası, zaman aşımı ve `spawn` ile PARALEL istekler (en çok eşzamanlı 2) sınanır; ağ yeteneği kapalıyken
// `HttpCapabilityError` alınır.
const fetch_program =
    \\import nox.http
    \\from nox.http import HttpResponse, HttpError, HttpTimeoutError
    \\
    \\def hdrs() -> dict[str, str]:
    \\    h: dict[str, str] = {}
    \\    h["X-Test"] = "nox"
    \\    return h
    \\
    \\async def slow_len(path: str) -> int:
    \\    r: HttpResponse = nox.http.get("http://t.invalid" + path, hdrs())
    \\    return len(r.body)
    \\
    \\r: HttpResponse = nox.http.get("http://t.invalid/hello", hdrs())
    \\print(r.status, r.body, r.headers["x-reply"])
    \\p: HttpResponse = nox.http.post("http://t.invalid/echo", "payload", hdrs())
    \\print(p.status, p.body)
    \\m: HttpResponse = nox.http.get("http://t.invalid/missing", hdrs())
    \\print(m.status)
    \\try:
    \\    c: HttpResponse = nox.http.get("http://t.invalid/refuse", hdrs())
    \\    print("unreachable")
    \\except HttpError:
    \\    print("connect error")
    \\try:
    \\    t: HttpResponse = nox.http.request("GET", "http://t.invalid/timeout", "", hdrs(), 30)
    \\    print("unreachable")
    \\except HttpTimeoutError:
    \\    print("timeout")
    \\t1: Task[int] = spawn slow_len("/slow")
    \\t2: Task[int] = spawn slow_len("/slow")
    \\a: int = await t1
    \\b: int = await t2
    \\print("parallel", a, b)
    \\
;

const fetch_expected =
    \\200 GET:/hello:- yes
    \\200 POST:/echo:payload
    \\404
    \\connect error
    \\timeout
    \\parallel 11 11
    \\exit 0
    \\max concurrent 2
    \\fetch GET /hello x-test=nox body=-
    \\fetch GET /missing x-test=nox body=-
    \\fetch GET /refuse x-test=nox body=-
    \\fetch GET /slow x-test=nox body=-
    \\fetch GET /slow x-test=nox body=-
    \\fetch GET /timeout x-test=nox body=-
    \\fetch POST /echo x-test=nox body=payload
    \\
;

fn runFetchDriver(source: []const u8, mode: []const u8) !?[]u8 {
    const allocator = std.testing.allocator;
    const outcome = try wasm_helpers.buildAndRunRepeated(allocator, build_options.noxc_path, build_options.fetch_driver_path, .freestanding_asyncify, source, &.{mode}, 1);
    switch (outcome) {
        .tool_missing => return null,
        .rejected, .build_failed => |msg| {
            defer allocator.free(msg);
            std.debug.print("fetch [{s}]: derleme basarisiz: {s}\n", .{ mode, msg });
            return error.BuildFailed;
        },
        .ran => |r| {
            defer allocator.free(r.stderr);
            if (r.term != .exited or r.term.exited != 0) {
                std.debug.print("fetch [{s}]: surucu basarisiz: {s}\n{s}\n", .{ mode, r.stderr, r.stdout });
                allocator.free(r.stdout);
                return error.ProgramFailed;
            }
            return r.stdout;
        },
    }
}

test "wasm32-freestanding --asyncify: nox.http host fetch'ine dayanır (sıralı, hata, zaman aşımı, paralel)" {
    const out = (try runFetchDriver(fetch_program, "allow")) orelse return error.SkipZigTest;
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings(fetch_expected, out);
}

test "wasm32-freestanding --asyncify: host ağ yeteneğini vermezse HttpCapabilityError" {
    const src =
        \\import nox.http
        \\from nox.http import HttpResponse, HttpCapabilityError
        \\
        \\h: dict[str, str] = {}
        \\try:
        \\    r: HttpResponse = nox.http.get("http://t.invalid/hello", h)
        \\    print("unreachable")
        \\except HttpCapabilityError:
        \\    print("capability")
        \\
    ;
    const out = (try runFetchDriver(src, "deny")) orelse return error.SkipZigTest;
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("capability\nexit 0\nmax concurrent 0\n", out);
}

// v2.0.152 (spec §3.354): akışlı istemci (`stream`, `stream_upload`). İndirme `fetch` yanıtının okuyucusundan parça parça okunur (geri basınç: yalnızca `read_chunk` çağrıldıkça),
// yükleme çalışma zamanında tamponlanıp `finish` ile tek istek olarak gönderilir, `read_chunk` boşta kalma zaman aşımı `HttpTimeoutError` verir.
const stream_program =
    \\import nox.http
    \\from nox.http import HttpStream, HttpError, HttpTimeoutError
    \\
    \\def hdrs() -> dict[str, str]:
    \\    h: dict[str, str] = {}
    \\    h["X-Test"] = "nox"
    \\    return h
    \\
    \\with nox.http.stream("GET", "http://t.invalid/chunks", hdrs()) as s:
    \\    print(s.status, s.headers["x-reply"])
    \\    total: int = 0
    \\    while True:
    \\        chunk: str = s.read_chunk(3)
    \\        if len(chunk) == 0:
    \\            break
    \\        total = total + len(chunk)
    \\        print(chunk)
    \\    print("total", total)
    \\
    \\up: HttpStream = nox.http.stream_upload("POST", "http://t.invalid/echo", hdrs(), 9)
    \\up.write("abc")
    \\up.write("defghi")
    \\up.finish()
    \\print(up.status, up.read_chunk(100))
    \\up.close()
    \\
    \\try:
    \\    with nox.http.stream("GET", "http://t.invalid/stall", hdrs(), "", 40) as st:
    \\        print(st.read_chunk(100))
    \\        print(st.read_chunk(100))
    \\        print("unreachable")
    \\except HttpTimeoutError:
    \\    print("idle timeout")
    \\
    \\try:
    \\    with nox.http.stream("GET", "http://t.invalid/refuse", hdrs()) as bad:
    \\        print("unreachable")
    \\except HttpError:
    \\    print("stream connect error")
    \\
;

const stream_expected =
    \\200 streamed
    \\aaa
    \\a
    \\bbb
    \\bbb
    \\cc
    \\total 12
    \\200 POST:/echo:abcdefghi
    \\first
    \\idle timeout
    \\stream connect error
    \\exit 0
    \\max concurrent 1
    \\fetch GET /chunks x-test=nox body=-
    \\fetch GET /refuse x-test=nox body=-
    \\fetch GET /stall x-test=nox body=-
    \\fetch POST /echo x-test=nox body=abcdefghi
    \\
;

test "wasm32-freestanding --asyncify: akışlı istemci (indirme, yükleme, boşta zaman aşımı) host fetch'ine dayanır" {
    const out = (try runFetchDriver(stream_program, "allow")) orelse return error.SkipZigTest;
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings(stream_expected, out);
}

test "wasm32-freestanding --asyncify: nox.transfer (download_to_file / upload_file) akışlı istemciyi ve sanal dosya sistemini birlikte kullanır" {
    const src =
        \\import nox.http
        \\import nox.transfer
        \\import nox.fs
        \\from nox.http import HttpResponse
        \\
        \\h: dict[str, str] = {}
        \\n: int = nox.transfer.download_to_file("http://t.invalid/chunks", "/tmp/dl.bin", h)
        \\print(n, nox.fs.read_to_string("/tmp/dl.bin"))
        \\nox.fs.write_string("/tmp/up.bin", "payload-xyz")
        \\r: HttpResponse = nox.transfer.upload_file("POST", "http://t.invalid/echo", "/tmp/up.bin", h)
        \\print(r.status, r.body)
        \\
    ;
    const out = (try runFetchDriver(src, "allow")) orelse return error.SkipZigTest;
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("200 aaaabbbbbbcc\n200 POST:/echo:payload-xyz\nexit 0\nmax concurrent 1\nfetch GET /chunks x-test=- body=-\nfetch POST /echo x-test=- body=payload-xyz\n", out);
}

// v2.0.153 (spec §3.355): `--threads` modüllerinde `nox.http` istemcisi. Çağıran iş parçacığı `nox_host.net_fetch` içinde bloke olur (Node'da yardımcı Worker + Atomics.wait,
// tarayıcı Worker'ında eşzamanlı XHR); sürücü gerçek bir yerel HTTP sunucusu başlatır. Yetenek `--allow-net` ile açılır, açılmazsa `HttpCapabilityError`.
fn runThreadsNet(mode: []const u8) !?[]u8 {
    const allocator = std.testing.allocator;
    const res = std.process.run(allocator, std.testing.io, .{
        .argv = &.{ "node", "--no-warnings", build_options.threads_net_driver_path, build_options.noxc_path, build_options.threads_net_program_path, build_options.wasm_host_path, mode },
    }) catch |err| {
        if (err == error.FileNotFound) return null;
        return err;
    };
    defer allocator.free(res.stderr);
    if (res.term != .exited or res.term.exited != 0) {
        if (std.mem.indexOf(u8, res.stderr, "zig not found") != null) {
            allocator.free(res.stdout);
            return null;
        }
        std.debug.print("threads net [{s}]: surucu basarisiz: {s}\n{s}\n", .{ mode, res.stderr, res.stdout });
        allocator.free(res.stdout);
        return error.ProgramFailed;
    }
    return res.stdout;
}

test "wasm32-freestanding-threads: nox.http iş parçacıklarında bloke eden eşzamanlı ağ ile çalışır" {
    const out = (try runThreadsNet("allow")) orelse return error.SkipZigTest;
    defer std.testing.allocator.free(out);
    // Sürücü ilk satırda derleme iletisini yazmaz (stderr'e gider); stdout: program çıktısı + çıkış kodu + sunucu günlüğü.
    try std.testing.expectEqualStrings(
        \\200 GET:/main: yes
        \\200 POST:/echo:payload
        \\threads 7 8
        \\timeout
        \\connect error
        \\exit 0
        \\server GET /a x-test=nox body=-
        \\server GET /bb x-test=nox body=-
        \\server GET /main x-test=nox body=-
        \\server GET /slow x-test=nox body=-
        \\server POST /echo x-test=nox body=payload
        \\
    , out);
}

test "wasm32-freestanding-threads: ağ yeteneği verilmezse HttpCapabilityError" {
    const out = (try runThreadsNet("deny")) orelse return error.SkipZigTest;
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("capability\nexit 0\n", out);
}

// v2.0.154 (spec §3.356): `nox.websocket` istemcisi WASM'da derlenir; wasm32-freestanding --asyncify'da host'un `WebSocket`ine dayanır (gönderme yanıtsız, `recv` fiber'ı bekletir),
// diğer kiplerde/yetenek yokken `connect` "ağ yeteneği yok" iletisiyle `WebSocketError` verir.
test "wasm32-freestanding --asyncify: nox.websocket istemcisi host WebSocket'ine dayanır" {
    const src =
        \\import nox.websocket
        \\from nox.websocket import WebSocketClient, WebSocketError
        \\
        \\c: WebSocketClient = nox.websocket.connect("ws://t.invalid:9000/echo")
        \\c.send_text("hello")
        \\print(c.recv())
        \\c.send_text("again")
        \\print(c.recv())
        \\print(c.is_open())
        \\c.close()
        \\
        \\d: WebSocketClient = nox.websocket.connect("ws://t.invalid/close-after-2")
        \\print(d.recv())
        \\print(d.recv())
        \\print(len(d.recv()))
        \\print(d.is_open())
        \\d.close()
        \\
        \\try:
        \\    e: WebSocketClient = nox.websocket.connect("ws://t.invalid/refuse")
        \\    print("unreachable")
        \\except WebSocketError:
        \\    print("ws connect error")
        \\
    ;
    const out = (try runFetchDriver(src, "allow")) orelse return error.SkipZigTest;
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings(
        \\echo:hello
        \\echo:again
        \\True
        \\a
        \\b
        \\0
        \\False
        \\ws connect error
        \\exit 0
        \\max concurrent 0
        \\ws open ws://t.invalid:9000/echo
        \\ws send hello
        \\ws send again
        \\ws close
        \\ws open ws://t.invalid:80/close-after-2
        \\ws open ws://t.invalid:80/refuse
        \\
    , out);
}

test "wasm32-freestanding --asyncify: host ağ yeteneğini vermezse WebSocket bağlantısı yetenek iletisiyle başarısız olur" {
    const src =
        \\import nox.websocket
        \\from nox.websocket import WebSocketClient, WebSocketError
        \\
        \\try:
        \\    c: WebSocketClient = nox.websocket.connect("ws://t.invalid/echo")
        \\    print("unreachable")
        \\except WebSocketError as e:
        \\    print("denied" if "network" in e.message else e.message)
        \\
    ;
    const out = (try runFetchDriver(src, "deny")) orelse return error.SkipZigTest;
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("denied\nexit 0\nmax concurrent 0\n", out);
}

// v2.0.155 (spec §3.357): ham TCP host yeteneği (`nox.tls`, `nox.smtp`). TLS HOST'ta sonlanır (Node `tls`, sertifika doğrulaması dahil); STARTTLS yükseltmesi host'ta yapılır.
// Sürücü yerel bir TLS yankı sunucusu ve STARTTLS destekli sahte SMTP sunucusu başlatır (`openssl` ile kendinden imzalı sertifika; `NODE_EXTRA_CA_CERTS`). `openssl`/`node` yoksa atlanır.
fn runTcpDriver(mode: []const u8) !?[]u8 {
    const allocator = std.testing.allocator;
    const res = std.process.run(allocator, std.testing.io, .{
        .argv = &.{ "node", "--no-warnings", build_options.tcp_driver_path, build_options.noxc_path, build_options.tcp_program_path, build_options.wasm_host_path, mode },
    }) catch |err| {
        if (err == error.FileNotFound) return null;
        return err;
    };
    defer allocator.free(res.stderr);
    if (res.term != .exited or res.term.exited != 0) {
        const missing = std.mem.indexOf(u8, res.stderr, "openssl") != null or std.mem.indexOf(u8, res.stderr, "zig not found") != null or std.mem.indexOf(u8, res.stderr, "wasm-opt") != null;
        if (missing) {
            allocator.free(res.stdout);
            return null;
        }
        std.debug.print("tcp [{s}]: surucu basarisiz: {s}\n{s}\n", .{ mode, res.stderr, res.stdout });
        allocator.free(res.stdout);
        return error.ProgramFailed;
    }
    return res.stdout;
}

test "wasm32-freestanding --asyncify: nox.tls ve nox.smtp (STARTTLS) host TCP yeteneğiyle çalışır" {
    const out = (try runTcpDriver("allow")) orelse return error.SkipZigTest;
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings(
        \\9
        \\HELLO TLS
        \\BYE
        \\0
        \\mail sent
        \\exit 0
        \\server tls recv hello tls
        \\server tls recv bye
        \\server smtp EHLO nox.test
        \\server smtp STARTTLS
        \\server smtp tls EHLO nox.test
        \\server smtp tls MAIL FROM:<me@example.com>
        \\server smtp tls RCPT TO:<a@example.com>
        \\server smtp tls RCPT TO:<b@example.com>
        \\server smtp tls DATA
        \\server smtp data From: me@example.com
        \\server smtp data To: a@example.com, b@example.com
        \\server smtp data Subject: Merhaba
        \\server smtp data 
        \\server smtp data line one
        \\server smtp data ..dotted line
        \\server smtp data last
        \\server smtp tls QUIT
        \\
    , out);
}

test "wasm32-freestanding --asyncify: host TCP yeteneğini vermezse TlsError (tcp capability)" {
    const out = (try runTcpDriver("deny")) orelse return error.SkipZigTest;
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("tls error: tcp\nexit 0\n", out);
}

// v2.0.156 (spec §3.358): `nox.postgres` WASM'da libpq yerine Zig'de yazılmış PostgreSQL protokol istemcisiyle çalışır (host TCP üzerinde). Sürücü GERÇEK bir PostgreSQL kümesi kurar
// (`initdb`, scram-sha-256) ve sunucuya karşı tam bir oturum çalıştırır; `initdb`/`pg_ctl` yoksa atlanır.
test "wasm32-freestanding --asyncify: nox.postgres gerçek bir PostgreSQL sunucusuna karşı (SCRAM-SHA-256, basit + genişletilmiş protokol)" {
    const allocator = std.testing.allocator;
    const res = std.process.run(allocator, std.testing.io, .{
        .argv = &.{ "node", "--no-warnings", build_options.pg_driver_path, build_options.noxc_path, build_options.pg_program_path, build_options.wasm_host_path },
    }) catch |err| {
        if (err == error.FileNotFound) return error.SkipZigTest;
        return err;
    };
    defer allocator.free(res.stdout);
    defer allocator.free(res.stderr);
    if (std.mem.eql(u8, std.mem.trim(u8, res.stdout, "\n "), "SKIP")) return error.SkipZigTest;
    if (res.term != .exited or res.term.exited != 0) {
        if (std.mem.indexOf(u8, res.stderr, "zig not found") != null or std.mem.indexOf(u8, res.stderr, "wasm-opt") != null) return error.SkipZigTest;
        std.debug.print("pg: surucu basarisiz: {s}\n{s}\n", .{ res.stderr, res.stdout });
        return error.ProgramFailed;
    }
    try std.testing.expectEqualStrings(
        \\inserted id 1
        \\affected 1
        \\updated 2
        \\1 alice False False
        \\2 bob False True
        \\3 carol True True
        \\31 42
        \\çok satırlı
        \\metin 'tırnak'
        \\older: bob
        \\error: statement failed: ERROR:  relation "no_such_table" does not exist
        \\
        \\1
        \\auth failed: True
        \\exit 0
        \\
    , res.stdout);
}

// v2.0.159 (spec §3.361): `nox.mysql` WASM'da libmysqlclient yerine Zig'de yazılmış MySQL protokol istemcisiyle çalışır (host TCP üzerinde). Sürücü yerelde bulunan `mysql:8.4`
// imajından atılabilir bir kapsayıcı açar (caching_sha2_password: RSA ile tam + hızlı yol, mysql_native_password); Docker/imaj yoksa atlanır.
test "wasm32-freestanding --asyncify: nox.mysql gerçek bir MySQL sunucusuna karşı (caching_sha2 tam+hızlı yol, native parola, kaçışlama, hata yolları)" {
    const allocator = std.testing.allocator;
    const res = std.process.run(allocator, std.testing.io, .{
        .argv = &.{ "node", "--no-warnings", build_options.mysql_driver_path, build_options.noxc_path, build_options.mysql_program_path, build_options.wasm_host_path },
    }) catch |err| {
        if (err == error.FileNotFound) return error.SkipZigTest;
        return err;
    };
    defer allocator.free(res.stdout);
    defer allocator.free(res.stderr);
    if (std.mem.eql(u8, std.mem.trim(u8, res.stdout, "\n "), "SKIP")) return error.SkipZigTest;
    if (res.term != .exited or res.term.exited != 0) {
        if (std.mem.indexOf(u8, res.stderr, "zig not found") != null or std.mem.indexOf(u8, res.stderr, "wasm-opt") != null) return error.SkipZigTest;
        std.debug.print("mysql: surucu basarisiz: {s}\n{s}\n", .{ res.stderr, res.stdout });
        return error.ProgramFailed;
    }
    try std.testing.expectEqualStrings(
        \\affected 1 id 1
        \\affected 1 id 2
        \\updated 2
        \\1 alice False False
        \\2 bob False True
        \\3 carol True True
        \\31 42
        \\çok satırlı
        \\metin 'tırnak' "çift" \ ters
        \\older: bob
        \\syntax error: True
        \\not null: True
        \\deleted 1
        \\count 2
        \\fast path 2
        \\native alice
        \\auth failed: True
        \\exit 0
        \\
    , res.stdout);
}

// v2.0.157 (spec §3.359): `nox.process` WASM'da bir HOST yeteneğidir (bit 2): `wasm32-freestanding --asyncify` + host `process` sağlayıcısı. Sürücü süreç içi sahte sağlayıcı verir;
// gerçek `child_process.spawn` yolu (`nodeProcess`) ayrı testte `--allow-process` ile denenir.
test "wasm32-freestanding --asyncify: nox.process host süreç sağlayıcısıyla (çıkış kodu, stdout/stderr, hata, zaman aşımı)" {
    const src =
        \\import nox.process
        \\from nox.process import Command, Output, ProcessError
        \\
        \\a: list[str] = ["one", "two words", "three"]
        \\o: Output = Command("echo-tool").arg_list(a).set_cwd("/work").set_timeout(500).run()
        \\print(o.status, o.stdout, o.stderr, o.success())
        \\f: Output = Command("fails").run()
        \\print(f.status, f.stdout, f.stderr, f.success())
        \\try:
        \\    m: Output = Command("missing").run()
        \\    print("unreachable")
        \\except ProcessError:
        \\    print("process error")
        \\try:
        \\    t: Output = Command("slow").set_timeout(10).run()
        \\    print("unreachable")
        \\except ProcessError:
        \\    print("timeout error")
        \\
    ;
    const out = (try runFetchDriver(src, "allow")) orelse return error.SkipZigTest;
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings(
        \\0 one,two words,three warn True
        \\3 partial boom False
        \\process error
        \\timeout error
        \\exit 0
        \\max concurrent 0
        \\proc echo-tool [one|two words|three] cwd=/work timeout=500
        \\proc fails [] cwd=- timeout=0
        \\proc missing [] cwd=- timeout=0
        \\proc slow [] cwd=- timeout=10
        \\
    , out);
}

test "wasm32-freestanding --asyncify: host süreç yeteneğini vermezse ProcessError" {
    const src =
        \\import nox.process
        \\from nox.process import Command, Output, ProcessError
        \\
        \\try:
        \\    o: Output = Command("echo-tool").run()
        \\    print("unreachable")
        \\except ProcessError:
        \\    print("denied")
        \\
    ;
    const out = (try runFetchDriver(src, "deny")) orelse return error.SkipZigTest;
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("denied\nexit 0\nmax concurrent 0\n", out);
}

test "wasm32-freestanding --asyncify: gerçek alt süreç (Node child_process, --allow-process, kabuksuz)" {
    const allocator = std.testing.allocator;
    const src =
        \\import nox.process
        \\from nox.process import Command, Output
        \\
        \\o: Output = Command("node").arg("-e").arg("console.log(process.argv[1] + '!'); console.error('err'); process.exit(7)").arg("a b; echo injected").run()
        \\print(o.status, o.stdout, o.stderr)
        \\
    ;
    const outcome = try wasm_helpers.buildAndRunRepeated(allocator, build_options.noxc_path, build_options.runner_path, .freestanding_asyncify, src, &.{"--allow-process"}, 1);
    switch (outcome) {
        .tool_missing => return error.SkipZigTest,
        .rejected, .build_failed => |msg| {
            defer allocator.free(msg);
            return error.BuildFailed;
        },
        .ran => |r| {
            defer allocator.free(r.stdout);
            defer allocator.free(r.stderr);
            try std.testing.expectEqualStrings("7 a b; echo injected!\n err\n\n", r.stdout);
        },
    }
}

// v2.0.158 (spec §3.360): `nox.http.serve` WASM\'da bir HOST yeteneğidir: host (Node `node:http`) dinler, istekleri modüle iletir, modül her istek için bir fiber\'da handler\'ı çalıştırır.
// Sürücü gerçek HTTP istemci istekleri yollar (POST gövdesi/başlıklar, 404, çoklu Set-Cookie, handler\'ın `nox.http.get` ile upstream\'e gitmesi, paralel istekler) ve zarifçe kapatır.
test "wasm32-freestanding --asyncify: nox.http.serve host sunucusuyla (istek/yanıt, handler içinde fetch, paralel, zarif kapanış)" {
    const src =
        \\import nox.http
        \\from nox.http import HttpRequest, HttpResponse
        \\
        \\def handle(req: HttpRequest) -> HttpResponse:
        \\    h: dict[str, str] = {}
        \\    h["Content-Type"] = "text/plain"
        \\    h["X-Echo-Method"] = req.method
        \\    h["Set-Cookie"] = "a=1\nb=2"
        \\    if req.target == "/echo":
        \\        return HttpResponse(200, req.method + " " + req.target + " body=" + req.body + " ua=" + req.headers["user-agent"], h)
        \\    if req.target == "/proxy":
        \\        none: dict[str, str] = {}
        \\        up: HttpResponse = nox.http.get("http://upstream.invalid/data", none)
        \\        return HttpResponse(200, "via proxy: " + up.body, h)
        \\    return HttpResponse(404, "nope", h)
        \\
        \\print("starting")
        \\nox.http.serve(0, handle)
        \\print("stopped")
        \\
    ;
    const allocator = std.testing.allocator;
    const outcome = try wasm_helpers.buildAndRunRepeated(allocator, build_options.noxc_path, build_options.serve_driver_path, .freestanding_asyncify, src, &.{}, 1);
    switch (outcome) {
        .tool_missing => return error.SkipZigTest,
        .rejected, .build_failed => |msg| {
            defer allocator.free(msg);
            std.debug.print("serve: derleme basarisiz: {s}\n", .{msg});
            return error.BuildFailed;
        },
        .ran => |r| {
            defer allocator.free(r.stdout);
            defer allocator.free(r.stderr);
            if (r.term != .exited or r.term.exited != 0) {
                std.debug.print("serve: surucu basarisiz: {s}\n{s}\n", .{ r.stderr, r.stdout });
                return error.ProgramFailed;
            }
            try std.testing.expectEqualStrings(
                \\starting
                \\stopped
                \\echo 200 POST /echo body=hello ua=tester POST ["a=1","b=2"]
                \\missing 404 nope
                \\proxy 200 via proxy: UPSTREAM-DATA
                \\parallel POST /echo body=p1 ua=u | POST /echo body=p2 ua=u | POST /echo body=p3 ua=u | POST /echo body=p4 ua=u
                \\exit 0
                \\upstream http://upstream.invalid/data
                \\
            , r.stdout);
        },
    }
}
