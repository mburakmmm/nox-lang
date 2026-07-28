//! `nox.sharedmem` uçtan uca golden testi — bkz. proje belleği "nyx v2
//! limitasyon listesi doğrulaması" (#6, süreçler arası paylaşılan state) +
//! plan dosyası "7 fazlı düzeltme planı" Faz 6. `tests/cli/sqlite_test.zig`
//! İLE AYNI desen (kurulu `zig-out/bin/noxc`yi GERÇEK bir alt süreç olarak
//! çalıştırır) — AMA bu testin ÖZEL amacı, tek bir process İÇİNDEKİ round-
//! trip DEĞİL, GERÇEKTEN AYRI (fork EDİLMEMİŞ, bağımsız) İKİ `noxc run`
//! çalıştırmasının AYNI isimli paylaşımlı bellek bölgesini GÖRDÜĞÜNÜ
//! doğrulamak — bu YÜZDEN İKİ AYRI `.nox` dosyası, İKİ AYRI `std.process.run`
//! çağrısıyla (biri YAZAR biri OKUR) çalıştırılır.

const std = @import("std");

fn noxcPath() []const u8 {
    return "zig-out/bin/noxc";
}

test "nox.sharedmem: iki BAGIMSIZ noxc run process'i AYNI isimli paylasimli bellek bolgesini gorur" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(io, &path_buf);
    const dir_path = path_buf[0..dir_len];

    // Her test çalıştırmasında ÇAKIŞMayı önlemek İçin PID'e göre BENZERSİZ
    // bir segment adı kullan (paralel test çalıştırmaları / önceki başarısız
    // bir çalıştırmadan kalan bir segment İLE ÇAKIŞMAMASI İçin).
    const shm_name = try std.fmt.allocPrint(gpa, "nox_test_shm_cli_{d}", .{std.c.getpid()});
    defer gpa.free(shm_name);

    const writer_source = try std.fmt.allocPrint(gpa,
        \\from nox.sharedmem import open as shm_open, SharedBuffer
        \\
        \\buf: SharedBuffer = shm_open("{s}", 64)
        \\buf.lock()
        \\buf.write_int(0, 123456789)
        \\buf.write_str(8, "paylasimli")
        \\buf.unlock()
        \\buf.close()
        \\print("yazildi")
        \\
    , .{shm_name});
    defer gpa.free(writer_source);
    try tmp.dir.writeFile(io, .{ .sub_path = "writer.nox", .data = writer_source });
    const writer_path = try std.fmt.allocPrint(gpa, "{s}/writer.nox", .{dir_path});
    defer gpa.free(writer_path);

    const reader_source = try std.fmt.allocPrint(gpa,
        \\from nox.sharedmem import open as shm_open, unlink as shm_unlink, SharedBuffer
        \\
        \\buf: SharedBuffer = shm_open("{s}", 64)
        \\buf.lock()
        \\result: int = buf.read_int(0)
        \\s: str = buf.read_str(8, 10)
        \\buf.unlock()
        \\print(result)
        \\print(s)
        \\buf.close()
        \\shm_unlink("{s}")
        \\
    , .{ shm_name, shm_name });
    defer gpa.free(reader_source);
    try tmp.dir.writeFile(io, .{ .sub_path = "reader.nox", .data = reader_source });
    const reader_path = try std.fmt.allocPrint(gpa, "{s}/reader.nox", .{dir_path});
    defer gpa.free(reader_path);

    // Yazar SÜRECİ ÖNCE, TAMAMEN biter (segment ONA rağmen YAŞAMAYA devam
    // eder — `close()` sadece bu process'in eşlemesini kapatır, `unlink`
    // ÇAĞRILMADIĞI sürece segment SİLİNMEZ). Process spawn sıralaması
    // GARANTİLİ olmasa bile burada İKİ AYRI `std.process.run` çağrısı ZATEN
    // SIRALI (birbirini BEKLER) olduğundan ekstra bir retry/timeout
    // döngüsüne GEREK YOK.
    const writer_result = try std.process.run(gpa, io, .{
        .argv = &.{ noxcPath(), "run", writer_path },
    });
    defer gpa.free(writer_result.stdout);
    defer gpa.free(writer_result.stderr);
    if (writer_result.term != .exited or writer_result.term.exited != 0) {
        std.debug.print("yazar process basarisiz oldu (stderr): {s}\n", .{writer_result.stderr});
        return error.WriterFailed;
    }
    if (writer_result.stderr.len != 0) {
        std.debug.print("yazar process stderr'e beklenmeyen cikti yazdi (olasi bellek sizintisi): {s}\n", .{writer_result.stderr});
        return error.UnexpectedStderrOutput;
    }
    try std.testing.expectEqualStrings("yazildi\n", writer_result.stdout);

    const reader_result = try std.process.run(gpa, io, .{
        .argv = &.{ noxcPath(), "run", reader_path },
    });
    defer gpa.free(reader_result.stdout);
    defer gpa.free(reader_result.stderr);
    if (reader_result.term != .exited or reader_result.term.exited != 0) {
        std.debug.print("okuyucu process basarisiz oldu (stderr): {s}\n", .{reader_result.stderr});
        return error.ReaderFailed;
    }
    if (reader_result.stderr.len != 0) {
        std.debug.print("okuyucu process stderr'e beklenmeyen cikti yazdi (olasi bellek sizintisi): {s}\n", .{reader_result.stderr});
        return error.UnexpectedStderrOutput;
    }
    try std.testing.expectEqualStrings("123456789\npaylasimli\n", reader_result.stdout);
}

test "nox.sharedmem: var olmayan bir segment acilirsa bos/sifir baslar (O_CREAT semantigi)" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(io, &path_buf);
    const dir_path = path_buf[0..dir_len];

    const shm_name = try std.fmt.allocPrint(gpa, "nox_test_shm_fresh_{d}", .{std.c.getpid()});
    defer gpa.free(shm_name);

    const source = try std.fmt.allocPrint(gpa,
        \\from nox.sharedmem import open as shm_open, unlink as shm_unlink, SharedBuffer
        \\
        \\buf: SharedBuffer = shm_open("{s}", 32)
        \\print(buf.read_int(0))
        \\buf.close()
        \\shm_unlink("{s}")
        \\
    , .{ shm_name, shm_name });
    defer gpa.free(source);
    try tmp.dir.writeFile(io, .{ .sub_path = "fresh.nox", .data = source });
    const nox_path = try std.fmt.allocPrint(gpa, "{s}/fresh.nox", .{dir_path});
    defer gpa.free(nox_path);

    const result = try std.process.run(gpa, io, .{
        .argv = &.{ noxcPath(), "run", nox_path },
    });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) {
        std.debug.print("program basarisiz cikti (stderr): {s}\n", .{result.stderr});
        return error.ProgramFailed;
    }
    if (result.stderr.len != 0) {
        std.debug.print("program stderr'e beklenmeyen bir cikti yazdi (olasi bellek sizintisi): {s}\n", .{result.stderr});
        return error.UnexpectedStderrOutput;
    }
    try std.testing.expectEqualStrings("0\n", result.stdout);
}
