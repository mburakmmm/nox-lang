//! Yerel (iOS/Android) ham TCP + STARTTLS taşıması (v2.0.189): `tcp_host.zig` ile AYNI arayüz (`Conn`, `connect`, `write`, `readSome`, `startTls`, `close`), ama bir WASM ana makinesi yerine
//! işletim sisteminin soketleri üzerinde. `pg_wasm.zig` (PostgreSQL protokol 3.0) ve `mysql_wasm.zig` (MySQL/MariaDB) saf Zig istemcileri `tcp` adını bu modüle ya da `tcp_host.zig`e
//! derleme zamanında bağlar; böylece mobil hedeflerde `nox.postgres`/`nox.mysql`, ana makine kütüphanesi (`libpq`/`libmysqlclient`) YÜKLEMEDEN çalışır.
//!
//! TLS, `nox.tls` ile aynı Zig `std.crypto.tls` istemcisi ve aynı sistem CA deposudur (`tls.zig`): `startTls` mevcut düz bağlantıyı aynı soket üzerinde yükseltir (PostgreSQL `SSLRequest`,
//! MySQL SSL el sıkışması); sertifika ve sunucu adı doğrulanır, doğrulanamazsa bağlantı kurulmaz.
//!
//! **Senkron/bloklayan** (`nox.tls`, `nox.sqlite` ile aynı v1 deseni): `connect`/`read`/`write` çağıran iş parçacığını bloklar. Okuma/yazma zaman aşımı YOKTUR; yanıt vermeyen bir sunucu çağrıyı
//! bekletir (bilinen sınır, `docs/stdlib/postgres.md`/`mysql.md`).

const std = @import("std");
const builtin = @import("builtin");
const http_client = @import("http_client.zig");
const tls_mod = @import("tls.zig");
/// `std.crypto.tls.Client` DEĞİL — `certificate_request` düzeltmesi içeren yamalı kopya (bkz. `tls.zig`).
const TlsClient = @import("../vendor/tls_client.zig");
const client_cert_mod = @import("client_cert.zig");

const gpa = std.heap.page_allocator;

const SOCK_BUF: usize = TlsClient.min_buffer_len;
const TLS_READ_BUF: usize = TlsClient.min_buffer_len;
const TLS_WRITE_BUF: usize = TlsClient.min_buffer_len;

const OwnCa = struct {
    bundle: std.crypto.Certificate.Bundle = .empty,
    lock: std.Io.RwLock = .init,
};

pub const Conn = struct {
    ok: bool = false,
    eof: bool = false,
    errmsg: []const u8 = "",
    errmsg_owned: bool = false,
    use_tls: bool = false,
    /// `readSome`un döndürdüğü dilimin sahibi (bir sonraki okumaya kadar geçerli).
    buf: std.ArrayListUnmanaged(u8) = .empty,
    io: std.Io = undefined,
    stream: std.Io.net.Stream = undefined,
    sock_read_buf: [SOCK_BUF]u8 = undefined,
    sock_write_buf: [SOCK_BUF]u8 = undefined,
    tls_read_buf: [TLS_READ_BUF]u8 = undefined,
    tls_write_buf: [TLS_WRITE_BUF]u8 = undefined,
    stream_reader: std.Io.net.Stream.Reader = undefined,
    stream_writer: std.Io.net.Stream.Writer = undefined,
    client: TlsClient = undefined,
    socket_open: bool = false,
    /// `startTlsEx`in `ca_file` ile kurduğu, bağlantıya özgü CA deposu (varsa `close` serbest bırakır).
    own_ca: ?*OwnCa = null,
    /// `startTlsMtls`in yüklediği istemci sertifikası/anahtarı (varsa `close` serbest bırakır ve anahtarı sıfırlar).
    own_client_cert: ?*client_cert_mod.Loaded = null,

    pub fn setErr(self: *Conn, msg: []const u8) void {
        if (self.errmsg_owned) gpa.free(self.errmsg);
        if (gpa.dupe(u8, msg)) |d| {
            self.errmsg = d;
            self.errmsg_owned = true;
        } else |_| {
            self.errmsg = "out of memory";
            self.errmsg_owned = false;
        }
    }
};

/// Bağlantı kurar. Başarısız olsa da GEÇERLİ bir `Conn` döner (`ok == false`, `errmsg` dolu); yalnızca bellek yetersizliğinde `null`. `tls`: bağlanır bağlanmaz TLS'e yükseltir.
/// `Conn`un adresi sabit kalmalıdır (okuyucu/yazıcı/TLS istemcisi kendi alanlarının adreslerini tutar): bu yüzden heap'te tahsis edilir.
pub fn connect(host: []const u8, port: i64, tls: bool) ?*Conn {
    const c = gpa.create(Conn) catch return null;
    c.* = .{};
    if (port <= 0 or port > 65535) {
        c.setErr("invalid port");
        return c;
    }
    c.io = http_client.sharedClientIo();
    c.stream = http_client.connectTcp(c.io, host, @intCast(port)) catch |err| {
        c.setErr(@errorName(err));
        return c;
    };
    c.socket_open = true;
    c.stream_reader = c.stream.reader(c.io, &c.sock_read_buf);
    c.stream_writer = c.stream.writer(c.io, &c.sock_write_buf);
    c.ok = true;
    if (tls and !startTls(c, host)) c.ok = false;
    return c;
}

/// Yazar ve soketi boşaltır. Başarıda `true`; hata `errmsg`e yazılır ve bağlantı artık kullanılamaz.
pub fn write(c: *Conn, data: []const u8) bool {
    if (!c.ok or data.len == 0) return c.ok;
    if (c.use_tls) {
        c.client.writer.writeAll(data) catch |err| return fail(c, err);
        c.client.writer.flush() catch |err| return fail(c, err);
        // `client.writer.flush()` yalnızca şifreli kaydı `stream_writer`a yazar; soketi boşaltmak ayrıca gerekir (bkz. `tls.zig`, nox_tls_write_raw).
        c.stream_writer.interface.flush() catch |err| return fail(c, err);
    } else {
        c.stream_writer.interface.writeAll(data) catch |err| return fail(c, err);
        c.stream_writer.interface.flush() catch |err| return fail(c, err);
    }
    return true;
}

fn fail(c: *Conn, err: anyerror) bool {
    c.setErr(@errorName(err));
    c.ok = false;
    return false;
}

/// En çok `max` bayt döner (en az bir bayt gelene kadar bekler); EOF'ta ya da hatada boş dilim (`c.eof` / `c.ok == false`). Dilim bir sonraki okumaya kadar geçerlidir.
pub fn readSome(c: *Conn, max: usize) []const u8 {
    if (!c.ok or c.eof or max == 0) return &.{};
    const r: *std.Io.Reader = if (c.use_tls) &c.client.reader else &c.stream_reader.interface;
    // TLS 1.3'te uygulama verisi taşımayan kayıtlar (oturum bileti) `fillMore`u başarıyla bitirip tamponu boş bırakabilir: veri, EOF ya da hata gelene kadar tekrarla.
    while (r.bufferedLen() == 0) {
        r.fillMore() catch |err| {
            if (err == error.EndOfStream) {
                c.eof = true;
            } else {
                c.setErr(@errorName(err));
                c.ok = false;
            }
            return &.{};
        };
    }
    const data = r.buffered();
    const take = @min(max, data.len);
    c.buf.clearRetainingCapacity();
    c.buf.appendSlice(gpa, data[0..take]) catch {
        c.setErr("out of memory");
        c.ok = false;
        return &.{};
    };
    r.toss(take);
    return c.buf.items;
}

/// Mevcut düz bağlantıyı aynı soket üzerinde TLS'e yükseltir (`servername`: SNI + sertifika doğrulaması). Başarıda `true`.
/// Yükseltme öncesi tamponlanmış düz metin kalmamalıdır: kalırsa (STARTTLS enjeksiyonu) yükseltme reddedilir.
pub fn startTls(c: *Conn, servername: []const u8) bool {
    return startTlsEx(c, servername, false, "");
}

/// `startTls` + isteğe bağlı ALPN `h2` (v2.1.35, gRPC) ve `ca_file` (PEM; doluysa sistem deposu YERİNE yalnızca bu dosyadaki CA'lara güvenilir: kurumsal/özel CA ve testler).
/// `alpn_h2` istenip sunucu `h2` seçmezse yükseltme başarısız olur.
pub fn startTlsEx(c: *Conn, servername: []const u8, alpn_h2: bool, ca_file: []const u8) bool {
    return startTlsMtls(c, servername, alpn_h2, ca_file, "", "");
}

/// `startTlsEx` + mTLS (v2.1.40): `cert_file` (PEM zincir) ve `key_file` (PEM özel anahtar: ECDSA P-256/P-384 ya da Ed25519; RSA desteklenmez) doluysa sunucu
/// istemci sertifikası isterse (TLS 1.3 `certificate_request`) sunulur.
pub fn startTlsMtls(c: *Conn, servername: []const u8, alpn_h2: bool, ca_file: []const u8, cert_file: []const u8, key_file: []const u8) bool {
    if (!c.ok or c.use_tls) return false;
    if (c.stream_reader.interface.bufferedLen() != 0) {
        c.setErr("unexpected data received before the TLS upgrade");
        c.ok = false;
        return false;
    }
    var bundle_ptr: *std.crypto.Certificate.Bundle = &tls_mod.g_ca_bundle;
    var lock_ptr: *std.Io.RwLock = &tls_mod.g_ca_lock;
    if (ca_file.len > 0) {
        const own = gpa.create(OwnCa) catch {
            c.setErr("out of memory");
            c.ok = false;
            return false;
        };
        own.* = .{};
        const now0 = std.Io.Timestamp.now(c.io, .real);
        own.bundle.addCertsFromFilePathAbsolute(gpa, c.io, now0, ca_file) catch |err| {
            own.bundle.deinit(gpa);
            gpa.destroy(own);
            var buf: [200]u8 = undefined;
            c.setErr(std.fmt.bufPrint(&buf, "could not load the CA file: {s}", .{@errorName(err)}) catch "could not load the CA file");
            c.ok = false;
            return false;
        };
        c.own_ca = own;
        bundle_ptr = &own.bundle;
        lock_ptr = &own.lock;
    } else if (!tls_mod.ensureCaBundle(c.io)) {
        c.setErr("could not load the system CA certificates");
        c.ok = false;
        return false;
    }
    var client_cert: ?TlsClient.ClientCert = null;
    if (cert_file.len > 0) {
        const loaded = client_cert_mod.load(gpa, c.io, cert_file, key_file) catch |err| {
            var buf: [200]u8 = undefined;
            c.setErr(std.fmt.bufPrint(&buf, "could not load the client certificate or key: {s}", .{@errorName(err)}) catch "could not load the client certificate or key");
            c.ok = false;
            return false;
        };
        c.own_client_cert = loaded;
        client_cert = loaded.cert;
    }
    var random_buffer: [TlsClient.Options.entropy_len]u8 = undefined;
    c.io.random(&random_buffer);
    const now = std.Io.Timestamp.now(c.io, .real);
    c.client = TlsClient.init(&c.stream_reader.interface, &c.stream_writer.interface, .{
        .host = .{ .explicit = servername },
        .ca = .{ .bundle = .{
            .gpa = gpa,
            .io = c.io,
            .lock = lock_ptr,
            .bundle = bundle_ptr,
        } },
        .ssl_key_log = null,
        .read_buffer = &c.tls_read_buf,
        .write_buffer = &c.tls_write_buf,
        .entropy = &random_buffer,
        .realtime_now = now,
        .allow_truncation_attacks = false,
        .alpn_h2 = alpn_h2,
        .client_cert = client_cert,
    }) catch |err| {
        c.setErr(@errorName(err));
        c.ok = false;
        return false;
    };
    if (alpn_h2 and !c.client.alpn_h2_selected) {
        c.setErr("the server did not negotiate HTTP/2 (ALPN h2)");
        c.ok = false;
        return false;
    }
    c.use_tls = true;
    return true;
}

pub fn close(c: *Conn) void {
    if (c.use_tls) c.client.end() catch {};
    if (c.socket_open) c.stream.close(c.io);
    c.buf.deinit(gpa);
    if (c.own_ca) |own| {
        own.bundle.deinit(gpa);
        gpa.destroy(own);
    }
    if (c.own_client_cert) |cc| {
        std.crypto.secureZero(u8, std.mem.asBytes(&cc.cert.key));
        cc.deinit();
        gpa.destroy(cc);
    }
    if (c.errmsg_owned) gpa.free(c.errmsg);
    gpa.destroy(c);
}

/// Kriptografik olarak güvenli rastgele bayt (SCRAM istemci nonce'u gibi tahmin edilemez olması gereken değerler için).
pub fn randomFill(buf: []u8) void {
    http_client.sharedClientIo().random(buf);
}

test "tcp_native: yerel soket uzerinde yaz, oku ve EOF'u tani" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest; // bu taşıma yalnızca mobil (iOS/Android) çalışma zamanında kullanılır
    var port: u16 = 0;
    const listen_fd = try http_client.testListenerOn127001(&port);
    defer _ = std.c.close(listen_fd);
    const server = try std.Thread.spawn(.{}, struct {
        fn run(fd: std.posix.fd_t) void {
            const cfd = http_client.acceptWithTimeout(fd, 5000);
            if (cfd < 0) return;
            var buf: [4]u8 = undefined;
            _ = std.c.read(cfd, &buf, buf.len);
            _ = std.c.write(cfd, "PONG", 4);
            _ = std.c.close(cfd);
        }
    }.run, .{listen_fd});
    defer server.join();

    const c = connect("127.0.0.1", port, false) orelse return error.OutOfMemory;
    defer close(c);
    try std.testing.expect(c.ok);
    try std.testing.expect(write(c, "PING"));
    var got: [16]u8 = undefined;
    var n: usize = 0;
    while (true) {
        const chunk = readSome(c, got.len - n);
        if (chunk.len == 0) break;
        @memcpy(got[n..][0..chunk.len], chunk);
        n += chunk.len;
    }
    try std.testing.expectEqualStrings("PONG", got[0..n]);
    try std.testing.expect(c.eof);
    try std.testing.expect(c.ok); // EOF hata değildir
}

test "tcp_native: ulasilamayan adres gecerli bir Conn doner (ok=false, errmsg dolu) ve gecersiz port reddedilir" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    // Dinleyen yokken bir portu boşalt: dinleyiciyi açıp kapatırız, port artık kapalıdır.
    var port: u16 = 0;
    const fd = try http_client.testListenerOn127001(&port);
    _ = std.c.close(fd);
    const c = connect("127.0.0.1", port, false) orelse return error.OutOfMemory;
    defer close(c);
    try std.testing.expect(!c.ok);
    try std.testing.expect(c.errmsg.len > 0);
    try std.testing.expectEqual(@as(usize, 0), readSome(c, 8).len);
    try std.testing.expect(!write(c, "x"));

    const bad = connect("127.0.0.1", 70000, false) orelse return error.OutOfMemory;
    defer close(bad);
    try std.testing.expect(!bad.ok);
    try std.testing.expectEqualStrings("invalid port", bad.errmsg);
}

test "tcp_native: randomFill her cagrida farkli, sifir olmayan bayt uretir" {
    var a: [32]u8 = undefined;
    var b: [32]u8 = undefined;
    randomFill(&a);
    randomFill(&b);
    try std.testing.expect(!std.mem.eql(u8, &a, &b));
    try std.testing.expect(!std.mem.allEqual(u8, &a, 0));
}
