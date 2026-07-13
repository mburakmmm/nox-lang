//! `nox.fs` Zig kabuğu — stdlib fazı §J (bkz. nox-teknik-spesifikasyon.md).
//! Basit senkron dosya G/Ç — bu Zig sürümünde `std.fs.cwd()` KALDIRILMIŞ
//! (yalnızca `io: std.Io` bağlamı gerektiren `std.Io.Dir` VAR, bkz.
//! `compiler/main.zig`nin kullanımı) — main.zig'in AKSİNE burada bir `Io`
//! bağlamı YOK, bu yüzden `http_client.zig`/`http_server.zig` İLE AYNI
//! desen: HAM libc çağrıları (`std.c.open`/`read`/`write`/`close`)
//! DOĞRUDAN kullanılır.
//!
//! Tasarım: `read_to_string_raw`/`write_string_raw` HER ZAMAN bir değer
//! döner (hata durumunda BOŞ bir `str`/hiçbir şey), `nox_fs_last_op_ok()`
//! SON çağrının başarılı olup olmadığını AYRICA bildirir (`nox.http`in
//! `nox_http_response_ok` deseniyle AYNI) — `stdlib/nox/fs.nox`nin KENDİSİ
//! sıradan `if`/`raise` İLE `FsError` fırlatır (HİÇBİR yeni checker/codegen
//! özel-durumu GEREKMEZ). Tek bir statik bayrak KULLANILMASI GÜVENLİDİR:
//! Nox'un M:1 fiber modelinde AYNI ANDA yalnızca TEK bir fiber ÇALIŞIR,
//! bu yüzden bir çağrı SONRASI hemen okunan bu bayrakta YARIŞ DURUMU
//! OLUŞMAZ.

const std = @import("std");
const http_client = @import("http_client.zig");

const dupeToNoxStr = http_client.dupeToNoxStr;

var g_last_ok: bool = true;

export fn nox_fs_last_op_ok() callconv(.c) i32 {
    return if (g_last_ok) 1 else 0;
}

export fn nox_fs_read_to_string_raw(rt: ?*anyopaque, path: ?[*:0]const u8) callconv(.c) ?[*:0]u8 {
    const p = path orelse {
        g_last_ok = false;
        return dupeToNoxStr(rt, "");
    };

    const o_read: std.c.O = .{ .ACCMODE = .RDONLY };
    const fd = std.c.open(p, o_read, @as(c_uint, 0));
    if (fd < 0) {
        g_last_ok = false;
        return dupeToNoxStr(rt, "");
    }
    defer _ = std.c.close(fd);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(std.heap.page_allocator);
    var chunk: [4096]u8 = undefined;
    while (true) {
        const n = std.c.read(fd, &chunk, chunk.len);
        if (n < 0) {
            g_last_ok = false;
            return dupeToNoxStr(rt, "");
        }
        if (n == 0) break;
        buf.appendSlice(std.heap.page_allocator, chunk[0..@intCast(n)]) catch {
            g_last_ok = false;
            return dupeToNoxStr(rt, "");
        };
    }
    g_last_ok = true;
    return dupeToNoxStr(rt, buf.items);
}

export fn nox_fs_write_string_raw(rt: ?*anyopaque, path: ?[*:0]const u8, content: ?[*:0]const u8) callconv(.c) void {
    _ = rt;
    const p = path orelse {
        g_last_ok = false;
        return;
    };
    const c = content orelse {
        g_last_ok = false;
        return;
    };

    const o_write: std.c.O = .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true };
    const fd = std.c.open(p, o_write, @as(c_uint, 0o644));
    if (fd < 0) {
        g_last_ok = false;
        return;
    }
    defer _ = std.c.close(fd);

    const bytes = std.mem.span(c);
    var off: usize = 0;
    while (off < bytes.len) {
        const n = std.c.write(fd, bytes[off..].ptr, bytes.len - off);
        if (n <= 0) {
            g_last_ok = false;
            return;
        }
        off += @intCast(n);
    }
    g_last_ok = true;
}
