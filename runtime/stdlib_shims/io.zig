//! `input()` builtin'i için stdin okuma kabuğu — `fs.zig`nin AYNI ham
//! libc/CRT çağrıları deseni, ancak dosya açma/`fstat` GEREKMEZ (fd 0
//! zaten açıktır VE stdin'in boyutu ÖNCEDEN BİLİNEMEZ — bu YÜZDEN
//! `nox_fs_read_to_string_raw`in TEK-tahsisli fstat-optimizasyonu BURADA
//! UYGULANAMAZ, `fs.zig`nin KENDİ yorumunda belgelenen ESKİ İKİ-tahsisli
//! büyüyen-tampon yaklaşımı BURADA doğru olan YAKLAŞIMDIR).
//!
//! Satır SONU (`\n`) Python'ın `input()`i GİBİ KIRPILIR (VE bir ÖNCEKİ
//! `\r` varsa o da kırpılır — CRLF ile sonlandırılmış bir giriş akışı
//! İçin). Bir okuma ÇAĞRISI, gelen `\n`den SONRAKİ fazla baytları
//! `threadlocal` bir "leftover" tamponunda SAKLAR — böylece stdin'i
//! büyük PARÇALAR halinde okumak (verimlilik İçin, bayt-bayt DEĞİL)
//! SONRAKİ `input()` çağrılarının baytlarını ÇALMAZ.
//!
//! `threadlocal` (Faz BB.1'in AYNI gerekçesi, bkz. `fs.zig`): `nox.thread.
//! spawn`in paylaşımsız modeli altında HER OS iş parçacığının KENDİ
//! bağımsız stdin-leftover tamponu OLMALIDIR.

const std = @import("std");
const builtin = @import("builtin");
const http_client = @import("http_client.zig");

const dupeToNoxStr = http_client.dupeToNoxStr;

const WinIo = if (builtin.os.tag == .windows) struct {
    extern "c" fn _read(fd: c_int, buf: [*]u8, count: c_uint) callconv(.c) c_int;
} else struct {};

fn readStdinChunk(buf: []u8) isize {
    if (builtin.os.tag == .windows) {
        const n = WinIo._read(0, buf.ptr, @intCast(@min(buf.len, std.math.maxInt(c_uint))));
        return @intCast(n);
    }
    return std.c.read(0, buf.ptr, buf.len);
}

threadlocal var g_stdin_leftover: std.ArrayListUnmanaged(u8) = .empty;

fn finishLine(rt: ?*anyopaque, line: *std.ArrayListUnmanaged(u8)) ?[*:0]u8 {
    var slice = line.items;
    if (slice.len > 0 and slice[slice.len - 1] == '\r') slice = slice[0 .. slice.len - 1];
    return dupeToNoxStr(rt, slice);
}

/// Python'ın `input()`ine eşdeğer — argümansız (v1 kapsamı: `prompt`
/// parametresi YOK, gerekirse çağıran taraf ÖNCE `print(prompt)` çağırır).
export fn nox_stdin_read_line_raw(rt: ?*anyopaque) callconv(.c) ?[*:0]u8 {
    const a = std.heap.page_allocator;
    var line: std.ArrayListUnmanaged(u8) = .empty;
    defer line.deinit(a);

    if (std.mem.indexOfScalar(u8, g_stdin_leftover.items, '\n')) |nl_idx| {
        line.appendSlice(a, g_stdin_leftover.items[0..nl_idx]) catch {};
        const rest_start = nl_idx + 1;
        const remaining = g_stdin_leftover.items.len - rest_start;
        std.mem.copyForwards(u8, g_stdin_leftover.items[0..remaining], g_stdin_leftover.items[rest_start..]);
        g_stdin_leftover.shrinkRetainingCapacity(remaining);
        return finishLine(rt, &line);
    }
    line.appendSlice(a, g_stdin_leftover.items) catch {};
    g_stdin_leftover.clearRetainingCapacity();

    var chunk: [256]u8 = undefined;
    while (true) {
        const n = readStdinChunk(&chunk);
        if (n <= 0) break;
        const bytes = chunk[0..@intCast(n)];
        if (std.mem.indexOfScalar(u8, bytes, '\n')) |idx| {
            line.appendSlice(a, bytes[0..idx]) catch {};
            g_stdin_leftover.appendSlice(a, bytes[idx + 1 ..]) catch {};
            break;
        }
        line.appendSlice(a, bytes) catch {};
    }
    return finishLine(rt, &line);
}
