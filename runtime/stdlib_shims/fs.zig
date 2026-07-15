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
//! özel-durumu GEREKMEZ).
//!
//! **`threadlocal` (Faz BB.1, bkz. nox-teknik-spesifikasyon.md §3.47):**
//! Bu bayrak ESKİDEN düz bir `var`dı, GEREKÇESİ AÇIKÇA "Nox'un M:1 fiber
//! modelinde AYNI ANDA yalnızca TEK bir fiber ÇALIŞIR, bu yüzden bir çağrı
//! SONRASI hemen okunan bu bayrakta YARIŞ DURUMU OLUŞMAZ" İDİ — BU ÖNCÜL,
//! `nox.thread.spawn`in paylaşımsız (shared-nothing) modeliyle ARTIK
//! GEÇERSİZDİR (İKİ GERÇEK OS iş parçacığı AYNI ANDA `nox.fs.*`
//! ÇAĞIRABİLİR). `threadlocal`, HER iş parçacığına KENDİ BAĞIMSIZ bayrağını
//! VERİR — SIFIR ek senkronizasyon MALİYETİYLE ÖNCÜLÜ YENİDEN GEÇERLİ KILAR.

const std = @import("std");
const http_client = @import("http_client.zig");

const dupeToNoxStr = http_client.dupeToNoxStr;

threadlocal var g_last_ok: bool = true;

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

// Faz BB.1: `g_last_ok`nin `threadlocal` OLMASININ, İKİ GERÇEK OS iş
// parçacığının AYNI ANDA `nox.fs` ÇAĞIRDIĞINDA birbirinin bayrağını
// EZMEDİĞİNİ kanıtlar — biri BAŞARISIZ (var olmayan yol), diğeri BAŞARILI
// (gerçek yazma+okuma) işlemi TEKRAR TEKRAR, AYNI ANDA yapar; HER iş
// parçacığı KENDİ `nox_fs_last_op_ok()` sonucunu GÖZLEMLER — paylaşılan bir
// bayrak OLSAYDI bu SONUÇLAR ARA SIRA birbirini EZERDİ.
test "g_last_ok threadlocal: iki gerçek OS iş parçacığı bağımsız bayrak görür" {
    // Bu dosya ZATEN "ham libc çağrıları" katmanında (bkz. modül üstü not) —
    // `std.testing.tmpDir`/`std.Io.Dir` KARMAŞIKLIĞINDAN kaçınmak İÇİN
    // `/tmp` altında PID'e göre BENZERSİZ bir yol DOĞRUDAN inşa edilir.
    var full_buf: [64]u8 = undefined;
    const full_path = try std.fmt.bufPrintZ(&full_buf, "/tmp/nox_bb1_fs_test_{d}.txt", .{std.c.getpid()});
    defer _ = std.c.unlink(full_path.ptr);

    const Worker = struct {
        fn failing(iterations: usize, all_false: *bool) void {
            var i: usize = 0;
            while (i < iterations) : (i += 1) {
                _ = nox_fs_read_to_string_raw(null, "/definitely/does/not/exist/nox_bb1_test");
                if (nox_fs_last_op_ok() != 0) all_false.* = false;
            }
        }
        fn succeeding(iterations: usize, path: [*:0]const u8, all_true: *bool) void {
            var i: usize = 0;
            while (i < iterations) : (i += 1) {
                nox_fs_write_string_raw(null, path, "hi");
                if (nox_fs_last_op_ok() == 0) all_true.* = false;
            }
        }
    };

    var all_false = true;
    var all_true = true;
    const thread_a = try std.Thread.spawn(.{}, Worker.failing, .{ 2000, &all_false });
    const thread_b = try std.Thread.spawn(.{}, Worker.succeeding, .{ 2000, full_path.ptr, &all_true });
    thread_a.join();
    thread_b.join();

    try std.testing.expect(all_false);
    try std.testing.expect(all_true);
}
