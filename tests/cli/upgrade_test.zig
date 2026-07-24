//! `noxc upgrade` (bkz. `compiler/pkg/upgrade.zig`nin modül üstü notu)
//! uçtan uca testleri — `search_test.zig`nin AYNI ham-soket yerel-sunucu
//! deseni (`testListenerOn127001`), AMA burada sunucu BİRDEN FAZLA
//! isteği (API + indirme + sağlama-toplamı) YOL'a göre YÖNLENDİRİR
//! (`resolveTargetVersion`/`performUpgrade`nin YAPTIĞI 3 AYRI HTTP isteği
//! İçin). Kurulum kökü HER ZAMAN `NOX_RESOURCE_DIR` İLE bir `std.testing.
//! tmpDir`e YÖNLENDİRİLİR — GERÇEK kurulu makine ORTAMI ASLA hedef alınmaz.

const std = @import("std");
const posix = std.posix;

fn noxcPath() []const u8 {
    return "zig-out/bin/noxc";
}

fn currentVersion(gpa: std.mem.Allocator, io: std.Io) ![]const u8 {
    const result = try std.process.run(gpa, io, .{ .argv = &.{ noxcPath(), "--version" } });
    defer gpa.free(result.stdout);
    // `noxc --version` (bkz. main.zig'in `std.debug.print` KULLANIMI) HER
    // ZAMAN stderr'e yazar, stdout'a DEGIL -- "noxc X.Y.Z\n" -> "X.Y.Z".
    const trimmed = std.mem.trimEnd(u8, result.stderr, "\n");
    const prefix = "noxc ";
    if (std.mem.startsWith(u8, trimmed, prefix)) {
        const v = try gpa.dupe(u8, trimmed[prefix.len..]);
        gpa.free(result.stderr);
        return v;
    }
    gpa.free(result.stderr);
    return error.UnexpectedVersionOutput;
}

fn testListenerOn127001(port_out: *u16) !posix.fd_t {
    const fd = std.c.socket(std.c.AF.INET, std.c.SOCK.STREAM, 0);
    if (fd < 0) return error.SocketFailed;
    var reuse: c_int = 1;
    _ = std.c.setsockopt(fd, std.c.SOL.SOCKET, std.c.SO.REUSEADDR, &reuse, @sizeOf(c_int));

    var addr: std.c.sockaddr.in = .{ .port = 0, .addr = std.mem.nativeToBig(u32, 0x7f000001) };
    if (std.c.bind(fd, @ptrCast(&addr), @sizeOf(std.c.sockaddr.in)) != 0) return error.BindFailed;
    if (std.c.listen(fd, 4) != 0) return error.ListenFailed;

    var got: std.c.sockaddr.in = undefined;
    var got_len: std.c.socklen_t = @sizeOf(std.c.sockaddr.in);
    if (std.c.getsockname(fd, @ptrCast(&got), &got_len) != 0) return error.GetsocknameFailed;
    port_out.* = std.mem.bigToNative(u16, got.port);
    return fd;
}

const Route = struct {
    /// Bir istek yolunun SONU BUNUNLA BİTERSE (tam eşleşme yerine —
    /// `noxc`nin gönderdiği TAM yol `/repos/mburakmmm/nox-lang/...` GİBİ
    /// uzun olabilir, testler yalnızca AYIRT EDİCİ son parçayı bilir)
    /// bu rota EŞLEŞİR.
    suffix: []const u8,
    body: []const u8,
    content_type: []const u8 = "application/octet-stream",
};

fn extractPath(req: []const u8) []const u8 {
    // "GET /a/b/c HTTP/1.1\r\n..." -> "/a/b/c"
    const line_end = std.mem.indexOf(u8, req, "\r\n") orelse req.len;
    const line = req[0..line_end];
    var it = std.mem.tokenizeScalar(u8, line, ' ');
    _ = it.next(); // "GET"
    return it.next() orelse "";
}

/// `routes`teki İLK EŞLEŞEN rotayı bulup yanıtlar; hiçbiri EŞLEŞMEZSE 404
/// döner. `num_requests` bağlantı KABUL EDİLİR (HER biri TEK bir istek/
/// yanıt) — `noxc upgrade`nin YAPACAĞI TOPLAM HTTP çağrısı sayısıyla AYNI
/// olmalı (sırayla API + indirme [+ sağlama-toplamı]).
fn serveFixtureRoutes(listen_fd: posix.fd_t, routes: []const Route, num_requests: usize) void {
    var handled: usize = 0;
    while (handled < num_requests) : (handled += 1) {
        const conn = std.c.accept(listen_fd, null, null);
        if (conn < 0) return;
        defer _ = std.c.close(conn);

        var req_buf: [8192]u8 = undefined;
        var total: usize = 0;
        while (total < req_buf.len) {
            const n = std.c.read(conn, req_buf[total..].ptr, req_buf.len - total);
            if (n <= 0) break;
            total += @intCast(n);
            if (std.mem.indexOf(u8, req_buf[0..total], "\r\n\r\n") != null) break;
        }
        const path = extractPath(req_buf[0..total]);

        var matched: ?Route = null;
        for (routes) |r| {
            if (std.mem.endsWith(u8, path, r.suffix)) {
                matched = r;
                break;
            }
        }

        var header_buf: [512]u8 = undefined;
        const header = if (matched) |r|
            std.fmt.bufPrint(&header_buf, "HTTP/1.1 200 OK\r\nContent-Length: {d}\r\nContent-Type: {s}\r\nConnection: close\r\n\r\n", .{ r.body.len, r.content_type }) catch return
        else
            std.fmt.bufPrint(&header_buf, "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", .{}) catch return;

        var written: usize = 0;
        while (written < header.len) {
            const n = std.c.write(conn, header[written..].ptr, header.len - written);
            if (n <= 0) return;
            written += @intCast(n);
        }
        if (matched) |r| {
            written = 0;
            while (written < r.body.len) {
                const n = std.c.write(conn, r.body[written..].ptr, r.body.len - written);
                if (n <= 0) return;
                written += @intCast(n);
            }
        }
    }
}

fn hexEncode(buf: []u8, digest: []const u8) []const u8 {
    const chars = "0123456789abcdef";
    for (digest, 0..) |byte, i| {
        buf[i * 2] = chars[byte >> 4];
        buf[i * 2 + 1] = chars[byte & 0xF];
    }
    return buf[0 .. digest.len * 2];
}

/// `stage_name/bin/{noxc,noxlsp,qbe}` + `lib/noxrt.o` + bir stdlib
/// dosyasından oluşan KÜÇÜK, uydurma bir tar.gz arşivi üretir — GERÇEK
/// ikili DEĞİL (yalnızca içerik-değişimini doğrulamak İçin ayırt edici
/// metin baytları).
fn buildFakeTarGz(gpa: std.mem.Allocator, stage_name: []const u8, marker: []const u8) ![]u8 {
    var raw: std.Io.Writer.Allocating = .init(gpa);
    defer raw.deinit();
    var tar_writer = std.tar.Writer{ .underlying_writer = &raw.writer };
    try tar_writer.setRoot(stage_name);
    const noxc_content = try std.fmt.allocPrint(gpa, "FAKE-NOXC-{s}", .{marker});
    defer gpa.free(noxc_content);
    try tar_writer.writeFileBytes("bin/noxc", noxc_content, .{ .mode = 0o755 });
    try tar_writer.writeFileBytes("bin/noxlsp", "FAKE-NOXLSP", .{ .mode = 0o755 });
    try tar_writer.writeFileBytes("bin/qbe", "FAKE-QBE", .{ .mode = 0o755 });
    try tar_writer.writeFileBytes("lib/noxrt.o", "FAKE-NOXRT", .{});
    try tar_writer.writeFileBytes("lib/nox/stdlib/nox/core.nox", "# fake stdlib\n", .{});
    try tar_writer.finishPedantically();

    var compressed: std.Io.Writer.Allocating = try .initCapacity(gpa, 256);
    var gz_buf: [std.compress.flate.max_window_len]u8 = undefined;
    var gz_compress = try std.compress.flate.Compress.init(&compressed.writer, &gz_buf, .gzip, .default);
    try gz_compress.writer.writeAll(raw.written());
    try gz_compress.finish();
    return compressed.toOwnedSlice();
}

/// Var olan, GERÇEĞE benzer BASİT bir kurulum düzeni (`bin/{noxc,noxlsp,
/// qbe}` + `lib/noxrt.o`) oluşturur — `installFromScratch`nin "ONCEKI
/// upgrade'den kalan .old dosyaları temizle" VE "bin/<exe>'yi rename-
/// aside/kopyala" yollarının GERÇEK bir HEDEFİ olması İçin.
fn seedFakeInstall(io: std.Io, dir: std.Io.Dir) !void {
    try dir.createDirPath(io, "bin");
    try dir.createDirPath(io, "lib");
    try dir.writeFile(io, .{ .sub_path = "bin/noxc", .data = "OLD-NOXC" });
    try dir.writeFile(io, .{ .sub_path = "bin/noxlsp", .data = "OLD-NOXLSP" });
    try dir.writeFile(io, .{ .sub_path = "bin/qbe", .data = "OLD-QBE" });
    try dir.writeFile(io, .{ .sub_path = "lib/noxrt.o", .data = "OLD-NOXRT" });
}

test "noxc upgrade <acik-surum> --check: API'ye HIC gitmeden mevcut/hedef surumu raporlar" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const current = try currentVersion(gpa, io);
    defer gpa.free(current);
    const current_tag = try std.fmt.allocPrint(gpa, "v{s}", .{current});
    defer gpa.free(current_tag);

    var env = try std.testing.environ.createMap(gpa);
    defer env.deinit();
    // Ulasilamaz bir API tabani -- GERCEKTEN cagrilirsa test TIMEOUT/hata
    // ile BASARISIZ olur, acik surum PIN'i BUNU atlamalidir.
    try env.put("NOX_UPGRADE_API_BASE", "http://127.0.0.1:1");

    const result = try std.process.run(gpa, io, .{
        .argv = &.{ noxcPath(), "upgrade", "--check", current_tag },
        .environ_map = &env,
    });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    try std.testing.expect(result.term == .exited);
    // Ayni surumu istedigi icin "zaten guncel" yazip 0 ile cikmali.
    try std.testing.expectEqual(@as(u8, 0), result.term.exited);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "already up to date") != null);
}

test "noxc upgrade --check: zaten guncelse indirme/cikarma HIC tetiklenmeden 0 doner" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const current = try currentVersion(gpa, io);
    defer gpa.free(current);
    const current_tag = try std.fmt.allocPrint(gpa, "v{s}", .{current});
    defer gpa.free(current_tag);

    const latest_json = try std.fmt.allocPrint(gpa, "{{\"tag_name\": \"{s}\"}}", .{current_tag});
    defer gpa.free(latest_json);

    var port: u16 = 0;
    const listen_fd = try testListenerOn127001(&port);
    defer _ = std.c.close(listen_fd);
    const routes = [_]Route{.{ .suffix = "/releases/latest", .body = latest_json, .content_type = "application/json" }};
    const server_thread = try std.Thread.spawn(.{}, serveFixtureRoutes, .{ listen_fd, &routes, @as(usize, 1) });
    defer server_thread.join();

    const api_base = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}", .{port});
    defer gpa.free(api_base);

    var env = try std.testing.environ.createMap(gpa);
    defer env.deinit();
    try env.put("NOX_UPGRADE_API_BASE", api_base);
    try env.put("NOX_ALLOW_INSECURE_TRANSPORT", "1");

    const result = try std.process.run(gpa, io, .{
        .argv = &.{ noxcPath(), "upgrade", "--check" },
        .environ_map = &env,
    });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    try std.testing.expectEqual(@as(u8, 0), result.term.exited);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "already up to date") != null);
}

test "noxc upgrade: http:// API tabani varsayilan olarak reddedilir" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var port: u16 = 0;
    const listen_fd = try testListenerOn127001(&port);
    defer _ = std.c.close(listen_fd);

    const api_base = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}", .{port});
    defer gpa.free(api_base);

    var env = try std.testing.environ.createMap(gpa);
    defer env.deinit();
    try env.put("NOX_UPGRADE_API_BASE", api_base);
    // NOX_ALLOW_INSECURE_TRANSPORT BILINCLI olarak AYARLANMADI.

    const result = try std.process.run(gpa, io, .{
        .argv = &.{ noxcPath(), "upgrade", "--check" },
        .environ_map = &env,
    });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    try std.testing.expectEqual(@as(u8, 1), result.term.exited);
}

test "noxc upgrade: bozuk JSON API yaniti temiz bir hatayla cikis kodu 1 doner" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var port: u16 = 0;
    const listen_fd = try testListenerOn127001(&port);
    defer _ = std.c.close(listen_fd);
    const routes = [_]Route{.{ .suffix = "/releases/latest", .body = "{ bozuk json", .content_type = "application/json" }};
    const server_thread = try std.Thread.spawn(.{}, serveFixtureRoutes, .{ listen_fd, &routes, @as(usize, 1) });
    defer server_thread.join();

    const api_base = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}", .{port});
    defer gpa.free(api_base);

    var env = try std.testing.environ.createMap(gpa);
    defer env.deinit();
    try env.put("NOX_UPGRADE_API_BASE", api_base);
    try env.put("NOX_ALLOW_INSECURE_TRANSPORT", "1");

    const result = try std.process.run(gpa, io, .{
        .argv = &.{ noxcPath(), "upgrade", "--check" },
        .environ_map = &env,
    });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    try std.testing.expectEqual(@as(u8, 1), result.term.exited);
}

test "noxc upgrade: GERCEK uctan-uca cikarma+degistirme (sahte tar.gz, izole kurulum koku)" {
    if (@import("builtin").os.tag != .macos and @import("builtin").os.tag != .linux) return error.SkipZigTest;

    const io = std.testing.io;
    const gpa = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try seedFakeInstall(io, tmp.dir);

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const install_root_len = try tmp.dir.realPath(io, &path_buf);
    const install_root = try gpa.dupe(u8, path_buf[0..install_root_len]);
    defer gpa.free(install_root);

    const fake_tag = "v99.0.0-fixture";
    const asset_name = if (@import("builtin").cpu.arch == .aarch64 and @import("builtin").os.tag == .macos)
        "macos-arm64"
    else
        "linux-x64";
    const stage_name = try std.fmt.allocPrint(gpa, "nox-lang-{s}-{s}", .{ fake_tag, asset_name });
    defer gpa.free(stage_name);
    const archive_bytes = try buildFakeTarGz(gpa, stage_name, "V2");
    defer gpa.free(archive_bytes);

    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(archive_bytes, &digest, .{});
    var hex_buf: [64]u8 = undefined;
    const hex = hexEncode(&hex_buf, &digest);
    const sha_body = try std.fmt.allocPrint(gpa, "{s}  {s}.tar.gz\n", .{ hex, stage_name });
    defer gpa.free(sha_body);

    const latest_json = try std.fmt.allocPrint(gpa, "{{\"tag_name\": \"{s}\"}}", .{fake_tag});
    defer gpa.free(latest_json);

    var port: u16 = 0;
    const listen_fd = try testListenerOn127001(&port);
    defer _ = std.c.close(listen_fd);
    const routes = [_]Route{
        .{ .suffix = "/releases/latest", .body = latest_json, .content_type = "application/json" },
        .{ .suffix = ".tar.gz.sha256", .body = sha_body },
        .{ .suffix = ".tar.gz", .body = archive_bytes },
    };
    // Sira: resolveTargetVersion (API) -> downloadToFile (arsiv) ->
    // verifyChecksum (sha256) = 3 istek.
    const server_thread = try std.Thread.spawn(.{}, serveFixtureRoutes, .{ listen_fd, &routes, @as(usize, 3) });
    defer server_thread.join();

    const base_url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}", .{port});
    defer gpa.free(base_url);

    var env = try std.testing.environ.createMap(gpa);
    defer env.deinit();
    try env.put("NOX_UPGRADE_API_BASE", base_url);
    try env.put("NOX_UPGRADE_DOWNLOAD_BASE", base_url);
    try env.put("NOX_ALLOW_INSECURE_TRANSPORT", "1");
    try env.put("NOX_RESOURCE_DIR", install_root);

    const result = try std.process.run(gpa, io, .{
        .argv = &.{ noxcPath(), "upgrade" },
        .environ_map = &env,
    });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) {
        std.debug.print("upgrade basarisiz (stderr): {s}\n", .{result.stderr});
        return error.UpgradeFailed;
    }

    // YENİ icerik GERCEKTEN yerine gecti mi?
    const new_noxc = try tmp.dir.readFileAlloc(io, "bin/noxc", gpa, .limited(4096));
    defer gpa.free(new_noxc);
    try std.testing.expectEqualStrings("FAKE-NOXC-V2", new_noxc);

    const new_noxrt = try tmp.dir.readFileAlloc(io, "lib/noxrt.o", gpa, .limited(4096));
    defer gpa.free(new_noxrt);
    try std.testing.expectEqualStrings("FAKE-NOXRT", new_noxrt);

    const new_stdlib = try tmp.dir.readFileAlloc(io, "lib/nox/stdlib/nox/core.nox", gpa, .limited(4096));
    defer gpa.free(new_stdlib);
    try std.testing.expectEqualStrings("# fake stdlib\n", new_stdlib);

    // Scratch dizini temizlendi mi?
    try std.testing.expectError(error.FileNotFound, tmp.dir.openDir(io, ".upgrade-scratch", .{}));
}
