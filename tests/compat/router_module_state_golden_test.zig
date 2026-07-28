//! `stdlib/nox/router.nox` + `nox.http.serve*` etkileşiminin uçtan uca
//! regresyon testi — bkz. proje belleği "modül-seviyesi global durum"
//! planı.
//!
//! **Geçmiş (bkz. proje belleği "noxc add/delete/publish + noxpkg
//! merkezi sunucusu" fazı):** `services/noxpkg/` inşa edilirken
//! BULUNDU: Nox'ta üst-düzey (script-seviyesi) `var_decl` durumu HİÇBİR
//! fonksiyonun İÇİNDEN GÖRÜLEMİYORDU — bu YÜZDEN `Router`nin İNŞASI
//! `handle`nin DIŞINDA, script top-level'da OLURSA ÇALIŞMIYORDU. Bu
//! kısıt "modül-seviyesi global durum" planıyla ÇÖZÜLDÜ (bkz. `compiler/
//! typecheck/checker.zig`nin `collectModuleGlobals`ı + `compiler/
//! codegen_qbe/globals.zig`).
//!
//! Bu dosya İKİ senaryoyu doğrular: (1) `Router` `handle`nin KENDİSİNİN
//! (ya da ondan çağrılan bir yardımcı fonksiyonun) İÇİNDE, HER istekte
//! yeniden inşa edilirse GERÇEK bir alt-süreç+soket İLE ÇALIŞIR (ESKİ
//! desen, HÂLÂ geçerli/desteklenen bir alternatif); (2) `Router` script
//! top-level'da BİR KEZ inşa edilip `handle`den REFERANS ALINIRSA da
//! (YENİ, tercih edilen desen) ARTIK GERÇEK bir alt-süreç+soket İLE
//! ÇALIŞIR — bu İKİNCİ test ÖNCEDEN (`error.UndefinedVariable` BEKLEYEN)
//! bir "regresyon kilidi" İDİ, ARTIK özelliğin VARLIĞINI doğrular.

const std = @import("std");
const posix = std.posix;
const nox = @import("nox");

fn compileToBinary(allocator: std.mem.Allocator, tmp: *std.testing.TmpDir, source: []const u8) ![]const u8 {
    const io = std.testing.io;

    const tokens = try nox.lexer.tokenize(allocator, source);
    const user_module = try nox.parser.parseModule(allocator, tokens);
    const module = try nox.module_loader.resolveImports(allocator, io, user_module);

    var checker_state = nox.checker.Checker.init(allocator);
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

    const ir = try nox.codegen.generateModule(allocator, module, checker_state.instantiations.items, generic_names.items, &.{}, &.{}, null, closure_infos, checker_state.defer_synthetic_names, checker_state.from_imports, functions_used_as_value.items, checker_state.module_aliases);

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &path_buf);
    const dir_path = path_buf[0..len];

    const ssa_path = try std.fmt.allocPrint(allocator, "{s}/prog.ssa", .{dir_path});
    const asm_path = try std.fmt.allocPrint(allocator, "{s}/prog.s", .{dir_path});
    const bin_path = try std.fmt.allocPrint(allocator, "{s}/prog", .{dir_path});

    try tmp.dir.writeFile(io, .{ .sub_path = "prog.ssa", .data = ir });

    const qbe_result = try std.process.run(allocator, io, .{
        .argv = &.{ "qbe", "-t", nox.qbe_target.name(), "-o", asm_path, ssa_path },
    });
    if (qbe_result.term != .exited or qbe_result.term.exited != 0) {
        std.debug.print("qbe basarisiz: {s}\n", .{qbe_result.stderr});
        return error.QbeFailed;
    }

    const cc_result = try std.process.run(allocator, io, .{
        .argv = &.{ "cc", "-rdynamic", "-o", bin_path, asm_path, "zig-out/lib/noxrt.o", "-lm" },
    });
    if (cc_result.term != .exited or cc_result.term.exited != 0) {
        std.debug.print("cc basarisiz: {s}\n", .{cc_result.stderr});
        return error.CcFailed;
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

test "nox.router + nox.http.serve: Router handle'in ICINDE (her istekte yeniden) insa edilirse GERCEKTEN calisir" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const port = try probeFreePort();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const source = try std.fmt.allocPrint(a,
        \\import nox.http
        \\from nox.router import Router, Context
        \\from nox.http import HttpRequest, HttpResponse
        \\
        \\def hello(ctx: Context) -> HttpResponse:
        \\    return HttpResponse(200, "hello", {{}})
        \\
        \\def build_router() -> Router:
        \\    r: Router = Router()
        \\    r.get("/", hello)
        \\    return r
        \\
        \\def handle(req: HttpRequest) -> HttpResponse:
        \\    r: Router = build_router()
        \\    return r.dispatch(req)
        \\
        \\nox.http.serve({d}, handle, 1)
        \\
    , .{port});

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const bin_path = try compileToBinary(a, &tmp, source);

    var child = try std.process.spawn(io, .{
        .argv = &.{bin_path},
        .stdout = .pipe,
        .stderr = .pipe,
    });

    var resp_buf: [256]u8 = undefined;
    var resp_len: usize = 0;
    const client_thread = try std.Thread.spawn(.{}, struct {
        fn run(p: u16, out: []u8, out_len: *usize) void {
            const fd = testConnect(p) catch return;
            defer _ = std.c.close(fd);
            const req = "GET / HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n";
            var off: usize = 0;
            while (off < req.len) {
                const n = std.c.write(fd, req[off..].ptr, req.len - off);
                if (n <= 0) return;
                off += @intCast(n);
            }
            var total: usize = 0;
            while (total < out.len) {
                const n = std.c.read(fd, out[total..].ptr, out.len - total);
                if (n <= 0) break;
                total += @intCast(n);
            }
            out_len.* = total;
        }
    }.run, .{ port, &resp_buf, &resp_len });
    client_thread.join();

    var stderr_buf: [4096]u8 = undefined;
    var stderr_reader = child.stderr.?.reader(io, &stderr_buf);
    const stderr_data = try stderr_reader.interface.allocRemaining(allocator, .unlimited);
    defer allocator.free(stderr_data);

    const term = try child.wait(io);
    try std.testing.expect(term == .exited);
    try std.testing.expectEqual(@as(u8, 0), term.exited);

    if (stderr_data.len != 0) {
        std.debug.print("program stderr'e beklenmeyen bir çıktı yazdı (olası bellek sızıntısı/UAF): {s}\n", .{stderr_data});
        return error.UnexpectedStderrOutput;
    }

    const resp = resp_buf[0..resp_len];
    try std.testing.expect(std.mem.indexOf(u8, resp, "200") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "hello") != null);
}

// Bulundu (bkz. proje belleği "modül-seviyesi global durum" planı):
// ÖNCEDEN bu test `Router` script top-level'da inşa edilip `handle`den
// REFERANS alındığında tip denetiminin `error.UndefinedVariable` İLE
// BAŞARISIZ OLMASINI bekleyen bir "regresyon kilidi" İDİ. Artık modül-
// seviyesi global durum desteklendiğinden bu desen GERÇEKTEN çalışır —
// bu test şimdi TAM UÇTAN UCA (gerçek alt-süreç+soket) doğrular: `r`
// SADECE BİR KEZ inşa edilir (`handle` HER istekte YENİDEN inşa ETMEZ),
// AMA HER istek yine de doğru yanıtlanır.
test "nox.router + nox.http.serve: Router script top-level'da BIR KEZ insa edilip handle'dan REFERANS alinirsa GERCEKTEN calisir" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const port = try probeFreePort();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const source = try std.fmt.allocPrint(a,
        \\import nox.http
        \\from nox.router import Router, Context
        \\from nox.http import HttpRequest, HttpResponse
        \\
        \\def hello(ctx: Context) -> HttpResponse:
        \\    return HttpResponse(200, "hello", {{}})
        \\
        \\r: Router = Router()
        \\r.get("/", hello)
        \\
        \\def handle(req: HttpRequest) -> HttpResponse:
        \\    return r.dispatch(req)
        \\
        \\nox.http.serve({d}, handle, 1)
        \\
    , .{port});

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const bin_path = try compileToBinary(a, &tmp, source);

    var child = try std.process.spawn(io, .{
        .argv = &.{bin_path},
        .stdout = .pipe,
        .stderr = .pipe,
    });

    var resp_buf: [256]u8 = undefined;
    var resp_len: usize = 0;
    const client_thread = try std.Thread.spawn(.{}, struct {
        fn run(p: u16, out: []u8, out_len: *usize) void {
            const fd = testConnect(p) catch return;
            defer _ = std.c.close(fd);
            const req = "GET / HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n";
            var off: usize = 0;
            while (off < req.len) {
                const n = std.c.write(fd, req[off..].ptr, req.len - off);
                if (n <= 0) return;
                off += @intCast(n);
            }
            var total: usize = 0;
            while (total < out.len) {
                const n = std.c.read(fd, out[total..].ptr, out.len - total);
                if (n <= 0) break;
                total += @intCast(n);
            }
            out_len.* = total;
        }
    }.run, .{ port, &resp_buf, &resp_len });
    client_thread.join();

    var stderr_buf: [4096]u8 = undefined;
    var stderr_reader = child.stderr.?.reader(io, &stderr_buf);
    const stderr_data = try stderr_reader.interface.allocRemaining(allocator, .unlimited);
    defer allocator.free(stderr_data);

    const term = try child.wait(io);
    try std.testing.expect(term == .exited);
    try std.testing.expectEqual(@as(u8, 0), term.exited);

    if (stderr_data.len != 0) {
        std.debug.print("program stderr'e beklenmeyen bir çıktı yazdı (olası bellek sızıntısı/UAF): {s}\n", .{stderr_data});
        return error.UnexpectedStderrOutput;
    }

    const resp = resp_buf[0..resp_len];
    try std.testing.expect(std.mem.indexOf(u8, resp, "200") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "hello") != null);
}
