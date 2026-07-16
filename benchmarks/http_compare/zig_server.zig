//! zig_server.zig — a minimal, hand-rolled multi-threaded HTTP/1.1
//! responder using only std.c sockets (no std.http.Server) for the
//! Nox/Go/Zig/FastAPI HTTP throughput comparison (see
//! benchmarks/RESULTS.md). This intentionally mirrors nox.http.serve's
//! own one-request-per-connection behavior (accept -> read -> respond ->
//! close, no keep-alive) so the Nox-vs-Zig half of the comparison isolates
//! the overhead Nox's ARC/fiber/QBE-codegen abstraction adds over hand-
//! rolled Zig sockets, rather than a difference in connection-reuse
//! policy. N acceptor threads share ONE listening socket (the kernel
//! load-balances accept() across them) — the same shared-listen-fd,
//! N-independent-worker-threads shape as nox.http.serve_multicore
//! (bkz. runtime/stdlib_shims/http_server.zig'in bindAndListen/
//! nox_http_listen_fd'si — bu dosyanın socket API kullanımı BUNUNLA
//! BİREBİR AYNI, ayrı bir Zig std.net/std.posix API riski almamak için).
const std = @import("std");

const RESPONSE = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nx: x\r\nConnection: close\r\n\r\nok";
const NUM_THREADS = 10;

fn bindAndListen(port: u16) c_int {
    const fd = std.c.socket(std.c.AF.INET, std.c.SOCK.STREAM, 0);
    var reuse: c_int = 1;
    _ = std.c.setsockopt(fd, std.c.SOL.SOCKET, std.c.SO.REUSEADDR, &reuse, @sizeOf(c_int));
    var addr: std.c.sockaddr.in = .{
        .port = std.mem.nativeToBig(u16, port),
        .addr = 0, // INADDR_ANY
    };
    if (std.c.bind(fd, @ptrCast(&addr), @sizeOf(std.c.sockaddr.in)) != 0) unreachable;
    if (std.c.listen(fd, 1024) != 0) unreachable;
    return fd;
}

fn worker(listen_fd: c_int) void {
    while (true) {
        const conn_fd = std.c.accept(listen_fd, null, null);
        if (conn_fd < 0) continue;
        defer _ = std.c.close(conn_fd);
        var buf: [4096]u8 = undefined;
        _ = std.c.read(conn_fd, &buf, buf.len);
        _ = std.c.write(conn_fd, RESPONSE.ptr, RESPONSE.len);
    }
}

pub fn main() !void {
    const listen_fd = bindAndListen(8801);

    var threads: [NUM_THREADS]std.Thread = undefined;
    for (0..NUM_THREADS) |i| {
        threads[i] = try std.Thread.spawn(.{}, worker, .{listen_fd});
    }
    for (threads) |t| t.join();
}
