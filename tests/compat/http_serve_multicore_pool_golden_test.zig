//! Faz MN.7b: `nox.http.serve_multicore`nin havuz-tabanlı (`--release`/LLVM)
//! lowering'i İçİn uçtan-uca golden test — `http_serve_multicore_golden_
//! test.zig`nin AYNI `probeFreePort`/`testConnect`/"N=2 iş parçacığı,
//! iş-parçacığı-başına max_connections=1" ispat DESENİNİN KASITLI TEKRARI
//! (bkz. o dosyanın belge notu), TEK fark: `.qbe`+`qbe`/`cc` YERİNE
//! `.llvm`+`clang` (bkz. `llvm_golden_test.zig`nin `compileAndRunLlvm`ı) —
//! `genHttpServeMulticore`nin `self.backend == .llvm` dalının GERÇEKTEN
//! `$nox_pool_serve` ÜZERİNDEN, TÜM worker'ların TEK bir paylaşılan
//! `WorkerPool`a bağlandığı, GERÇEK bir HTTP sunucusunu ÇALIŞTIRDIĞININ
//! kanıtı.
//!
//! **Kapsam notu (bilinçli, DENEYEREK keşfedilen bir sınır — plan dosyasının
//! "Hatalar" bölümünde AYRICA belgelendi):** `nox.http.serve*`nin `handle`
//! işleyicisi `checker.zig`nin `validateHttpHandler`ı TARAFINDAN AÇIKÇA
//! `async def` OLAMAZ diye KISITLANMIŞTIR ("bağlantı işleyicisi zaten kendi
//! fiber'ında senkron çalışır") — bu YÜZDEN `handle` İçİNDEN `spawn`/`await`
//! KULLANILAMAZ, "handler İçİNDE spawn edilen bir alt-görevin BAŞKA worker'a
//! ÇALINDIĞI" DOĞRUDAN bir Nox-seviyesi ispatı MÜMKÜN DEĞİLDİR (planın İLK
//! taslağının BU noktadaki beklentisi YANLIŞTI). AYRICA: kabul edilen HER
//! bağlantı `serveImpl`nin `s.markReady(fiber)` çağrısıyla (bkz. `http_
//! server.zig`) DOĞRUDAN o worker'ın KENDİ `ready` listesine eklenir —
//! `nox_async_spawn`ın havuz-farkındalıklı deque-yönlendirmesinden GEÇMEZ,
//! bu YÜZDEN bağlantılar da worker'lar ARASI ÇALINAMAZ (bağlantı-seviyesi
//! dengeleme ZATEN paylaşılan-fd üzerindeki OS-seviyesi `accept()`
//! yarışıyla sağlanıyor — bu MN.7b'DEN BAĞIMSIZ, DEĞİŞMEDİ). MN.7b'nin
//! GERÇEK, BU testin kanıtladığı kazanımı: TÜM worker'lar ARTIK TEK bir
//! paylaşılan `RuntimeState`/ARC havuzu/STW döngü-çözücüyü PAYLAŞIYOR
//! (`nox_thread_spawn`nin ESKİ, N-BAĞIMSIZ-runtime modeli YERİNE) — bu
//! test BUNUN GERÇEK bir HTTP sunucusunda ÇÖKMEDEN/SIZMADAN çalıştığını
//! doğrular. Çapraz-worker GÖREV çalmanın KENDİSİ `pool_bridge.zig`nin
//! `nox_pool_serve`/`nox_pool_run` Zig-seviyesi testlerinde ZATEN (`stolen_
//! count > 0` İLE) KANITLANMIŞTIR (bkz. MN.7a.7/MN.7b.1).
//!
//! Önkoşul: `clang` PATH üzerinde bulunmalıdır (bkz. `llvm_golden_test.
//! zig`nin AYNI notu).

const std = @import("std");
const posix = std.posix;
const nox = @import("nox");

fn compileToBinaryLlvm(allocator: std.mem.Allocator, tmp: *std.testing.TmpDir, source: []const u8) ![]const u8 {
    const io = std.testing.io;

    const tokens = try nox.lexer.tokenize(allocator, source);
    const user_module = try nox.parser.parseModule(allocator, tokens);
    const module = try nox.module_loader.resolveImports(allocator, io, user_module);

    var checker_state = nox.checker.Checker.init(allocator);
    // Faz MN.9.4: bkz. `llvm_golden_test.zig`nin AYNI notu — bu dosya
    // `.llvm` backend'i test EDİYOR, `Checker.backend` da ONU YANSITMALI.
    checker_state.backend = .llvm;
    checker_state.checkModule(module) catch |e| {
        std.debug.print("beklenmeyen tip hatasi ({t}): {s}\n", .{ e, checker_state.diagnostic orelse "(mesaj yok)" });
        return error.FixtureNotWellTyped;
    };
    if (checker_state.diagnostics.items.len > 0) {
        for (checker_state.diagnostics.items) |d| {
            std.debug.print("beklenmeyen tip hatasi ({t}): {s}\n", .{ d.code, d.message });
        }
        return error.FixtureNotWellTyped;
    }

    var generic_names: std.ArrayListUnmanaged([]const u8) = .empty;
    var generic_it = checker_state.generic_functions.keyIterator();
    while (generic_it.next()) |k| try generic_names.append(allocator, k.*);

    var generic_class_names: std.ArrayListUnmanaged([]const u8) = .empty;
    var generic_class_it = checker_state.generic_classes.keyIterator();
    while (generic_class_it.next()) |k| try generic_class_names.append(allocator, k.*);

    var closure_infos: std.StringHashMapUnmanaged([]const []const u8) = .empty;
    var closure_it = checker_state.closure_infos.iterator();
    while (closure_it.next()) |entry| {
        const names = try allocator.alloc([]const u8, entry.value_ptr.captures.len);
        for (entry.value_ptr.captures, 0..) |c, i| names[i] = c.name;
        try closure_infos.put(allocator, entry.key_ptr.*, names);
    }

    var functions_used_as_value: std.ArrayListUnmanaged([]const u8) = .empty;
    var fn_value_it = checker_state.functions_used_as_value.keyIterator();
    while (fn_value_it.next()) |k| try functions_used_as_value.append(allocator, k.*);

    const ir = try nox.codegen.generateModule(allocator, module, checker_state.instantiations.items, generic_names.items, checker_state.class_instantiations.items, generic_class_names.items, null, closure_infos, checker_state.defer_synthetic_names, checker_state.from_imports, functions_used_as_value.items, checker_state.module_aliases, checker_state.decorated_functions.items, .llvm);

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &path_buf);
    const dir_path = path_buf[0..len];

    const ll_path = try std.fmt.allocPrint(allocator, "{s}/prog.ll", .{dir_path});
    const bin_path = try std.fmt.allocPrint(allocator, "{s}/prog", .{dir_path});

    try tmp.dir.writeFile(io, .{ .sub_path = "prog.ll", .data = ir });

    const clang_result = std.process.run(allocator, io, .{
        .argv = &.{ "clang", "-O2", "-rdynamic", "-o", bin_path, ll_path, "zig-out/lib/noxrt.o", "-lm" },
    }) catch |err| {
        if (err == error.FileNotFound) {
            std.debug.print("clang bulunamadi (PATH'te yok) - bu test 'brew install llvm' gerektirir\n", .{});
            return error.ClangNotFound;
        }
        return err;
    };
    if (clang_result.term != .exited or clang_result.term.exited != 0) {
        std.debug.print("clang basarisiz: {s}\n", .{clang_result.stderr});
        return error.ClangFailed;
    }

    return bin_path;
}

fn probeFreePort() !u16 {
    const fd = std.c.socket(std.c.AF.INET, std.c.SOCK.STREAM, 0);
    if (fd < 0) return error.SocketFailed;
    defer _ = std.c.close(fd);
    var reuse: c_int = 1;
    _ = std.c.setsockopt(fd, std.c.SOL.SOCKET, std.c.SO.REUSEADDR, &reuse, @sizeOf(c_int));

    var addr: std.c.sockaddr.in = .{ .port = 0, .addr = std.mem.nativeToBig(u32, 0x7f000001) };
    if (std.c.bind(fd, @ptrCast(&addr), @sizeOf(std.c.sockaddr.in)) != 0) return error.BindFailed;

    var got: std.c.sockaddr.in = undefined;
    var got_len: std.c.socklen_t = @sizeOf(std.c.sockaddr.in);
    if (std.c.getsockname(fd, @ptrCast(&got), &got_len) != 0) return error.GetsocknameFailed;
    return std.mem.bigToNative(u16, got.port);
}

fn testConnect(port: u16) !posix.fd_t {
    var attempt: usize = 0;
    while (attempt < 200) : (attempt += 1) {
        const fd = std.c.socket(std.c.AF.INET, std.c.SOCK.STREAM, 0);
        if (fd < 0) return error.SocketFailed;
        var addr: std.c.sockaddr.in = .{
            .port = std.mem.nativeToBig(u16, port),
            .addr = std.mem.nativeToBig(u32, 0x7f000001),
        };
        if (std.c.connect(fd, @ptrCast(&addr), @sizeOf(std.c.sockaddr.in)) == 0) return fd;
        _ = std.c.close(fd);
        const ts: posix.timespec = .{ .sec = 0, .nsec = 10 * std.time.ns_per_ms };
        _ = std.c.nanosleep(&ts, null);
    }
    return error.ConnectFailed;
}

fn testSendGet(fd: posix.fd_t, path: []const u8) void {
    var buf: [256]u8 = undefined;
    const req = std.fmt.bufPrint(&buf, "GET {s} HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n", .{path}) catch unreachable;
    var off: usize = 0;
    while (off < req.len) {
        const n = std.c.write(fd, req[off..].ptr, req.len - off);
        if (n <= 0) break;
        off += @intCast(n);
    }
}

fn testSendGetAndExpectOk(port: u16, path: []const u8, results: *[2]bool, idx: usize) void {
    const fd = testConnect(port) catch {
        results[idx] = false;
        return;
    };
    defer _ = std.c.close(fd);
    testSendGet(fd, path);
    var buf: [256]u8 = undefined;
    const n = std.c.read(fd, &buf, buf.len);
    results[idx] = n > 0 and std.mem.startsWith(u8, buf[0..@intCast(n)], "HTTP/1.1 200");
}

test "nox.http.serve_multicore (--release/havuz): N=2 worker, iki EZSAMANLI istemci de GERCEKTEN sunulur" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const port = try probeFreePort();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const source = try std.fmt.allocPrint(a,
        \\import nox.http
        \\
        \\def handle(req: nox_http_HttpRequest) -> nox_http_HttpResponse:
        \\    return nox_http_HttpResponse(200, "ok", {{"x": "x"}})
        \\
        \\nox.http.serve_multicore({d}, handle, 2, 1)
        \\
    , .{port});

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const bin_path = compileToBinaryLlvm(a, &tmp, source) catch |err| {
        if (err == error.ClangNotFound) return error.SkipZigTest;
        return err;
    };

    var child = try std.process.spawn(io, .{
        .argv = &.{bin_path},
        .stdout = .pipe,
        .stderr = .pipe,
    });

    var results: [2]bool = .{ false, false };
    const t1 = try std.Thread.spawn(.{}, testSendGetAndExpectOk, .{ port, "/a", &results, 0 });
    const t2 = try std.Thread.spawn(.{}, testSendGetAndExpectOk, .{ port, "/b", &results, 1 });
    t1.join();
    t2.join();

    var stdout_buf: [4096]u8 = undefined;
    var stdout_reader = child.stdout.?.reader(io, &stdout_buf);
    const stdout_data = try stdout_reader.interface.allocRemaining(allocator, .unlimited);
    defer allocator.free(stdout_data);

    var stderr_buf: [4096]u8 = undefined;
    var stderr_reader = child.stderr.?.reader(io, &stderr_buf);
    const stderr_data = try stderr_reader.interface.allocRemaining(allocator, .unlimited);
    defer allocator.free(stderr_data);

    const term = try child.wait(io);
    try std.testing.expect(term == .exited);
    try std.testing.expectEqual(@as(u8, 0), term.exited);

    if (stderr_data.len != 0) {
        std.debug.print("program stderr'e beklenmeyen bir çıktı yazdı (olası bellek sızıntısı): {s}\n", .{stderr_data});
        return error.UnexpectedStderrOutput;
    }

    try std.testing.expect(results[0]);
    try std.testing.expect(results[1]);
}

test "nox.http.serve_multicore (--release/havuz): N=4 worker, siniRSIZ baglanti, cok sayida ardisik istek GUVENLE sunulur" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const port = try probeFreePort();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const source = try std.fmt.allocPrint(a,
        \\import nox.http
        \\
        \\def handle(req: nox_http_HttpRequest) -> nox_http_HttpResponse:
        \\    return nox_http_HttpResponse(200, "ok", {{"x": "x"}})
        \\
        \\nox.http.serve_multicore({d}, handle, 4, 0)
        \\
    , .{port});

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const bin_path = compileToBinaryLlvm(a, &tmp, source) catch |err| {
        if (err == error.ClangNotFound) return error.SkipZigTest;
        return err;
    };

    var child = try std.process.spawn(io, .{
        .argv = &.{bin_path},
        .stdout = .pipe,
        .stderr = .pipe,
    });

    var i: usize = 0;
    while (i < 20) : (i += 1) {
        const fd = try testConnect(port);
        testSendGet(fd, "/");
        var buf: [256]u8 = undefined;
        const n = std.c.read(fd, &buf, buf.len);
        _ = std.c.close(fd);
        try std.testing.expect(n > 0);
        try std.testing.expect(std.mem.startsWith(u8, buf[0..@intCast(n)], "HTTP/1.1 200"));
    }

    // `max_connections=0` (sınırsız) — sunucu KENDİLİĞİNDEN dönmez, testin
    // KENDİSİ sonlandırmalıdır. `Child.kill`nin KENDİSİ ZATEN süreci
    // BEKLER/reap eder (bkz. `assert(child.id == null)` sonrasında) —
    // AYRICA `wait` ÇAĞIRMAK `assert(child.id != null)`E ÇARPARDI.
    child.kill(io);
}
