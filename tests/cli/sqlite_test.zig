//! `nox.sqlite` uçtan uca golden testi — bkz. plan dosyası "nox.sqlite —
//! libsqlite3'e extern def ile bağlanan bir SQLite sürücüsü". Kurulu
//! `zig-out/bin/noxc`yi GERÇEK bir alt süreç olarak çalıştırarak doğrular
//! (`tests/cli/search_test.zig`/`package_resolution_test.zig` İLE AYNI
//! desen) — GERÇEK `noxc`nin `appendExternLinkArgs`ı (main.zig) `from
//! "sqlite3"` extern def'lerini GÖRÜP `-lsqlite3`yi OTOMATİK ekler; hand-
//! rolled bir `compileAndRun` test yardımcısı (`codegen_golden_test.zig`
//! gibi diğer golden testlerin kullandığı) BUNU YAPMAZ (sabit `-lm`
//! dışında hiçbir extern-link mantığı YOK) — bu YÜZDEN bu test BİLEREK
//! gerçek `noxc`yi çağırır.

const std = @import("std");

fn noxcPath() []const u8 {
    return "zig-out/bin/noxc";
}

test "nox.sqlite: tablo olustur + parametreli INSERT (int/float/str/NULL) + SELECT + tip/NULL dogrulama" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(io, &path_buf);
    const db_path = try std.fmt.allocPrint(gpa, "{s}/test.db", .{path_buf[0..dir_len]});
    defer gpa.free(db_path);

    const source = try std.fmt.allocPrint(gpa,
        \\from nox.sqlite import open, Connection, Statement, Row
        \\
        \\conn: Connection = open("{s}")
        \\conn.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT, score REAL, bio TEXT)")
        \\
        \\stmt: Statement = conn.prepare("INSERT INTO users (name, score, bio) VALUES (?, ?, ?)")
        \\stmt.bind_str(0, "Ayse")
        \\stmt.bind_float(1, 95.5)
        \\stmt.bind_null(2)
        \\stmt.execute()
        \\print(conn.last_insert_rowid())
        \\print(conn.changes())
        \\
        \\stmt2: Statement = conn.prepare("INSERT INTO users (name, score, bio) VALUES (?, ?, ?)")
        \\stmt2.bind_str(0, "Mehmet")
        \\stmt2.bind_float(1, 88.0)
        \\stmt2.bind_str(2, "merhaba")
        \\stmt2.execute()
        \\
        \\rows: list[Row] = conn.query("SELECT id, name, score, bio FROM users ORDER BY id")
        \\print(len(rows))
        \\i: int = 0
        \\while i < len(rows):
        \\    row: Row = rows[i]
        \\    print(row.get_int(0))
        \\    print(row.get_str(1))
        \\    print(row.get_float(2))
        \\    print(row.is_null(3))
        \\    i = i + 1
        \\conn.close()
        \\
    , .{db_path});
    defer gpa.free(source);

    const nox_path = try std.fmt.allocPrint(gpa, "{s}/prog.nox", .{path_buf[0..dir_len]});
    defer gpa.free(nox_path);
    try tmp.dir.writeFile(io, .{ .sub_path = "prog.nox", .data = source });

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
    try std.testing.expectEqualStrings(
        "1\n1\n2\n1\nAyse\n95.5\nTrue\n2\nMehmet\n88\nFalse\n",
        result.stdout,
    );
}

test "nox.sqlite: bozuk SQL SqliteError firlatir, try/except yakalar; bos tablo bos liste doner" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(io, &path_buf);
    const db_path = try std.fmt.allocPrint(gpa, "{s}/test2.db", .{path_buf[0..dir_len]});
    defer gpa.free(db_path);

    const source = try std.fmt.allocPrint(gpa,
        \\from nox.sqlite import open, Connection, Row, SqliteError
        \\
        \\conn: Connection = open("{s}")
        \\try:
        \\    conn.execute("THIS IS NOT VALID SQL")
        \\except SqliteError as e:
        \\    print("caught")
        \\
        \\conn.execute("CREATE TABLE empty_t (id INTEGER)")
        \\rows: list[Row] = conn.query("SELECT id FROM empty_t")
        \\print(len(rows))
        \\conn.close()
        \\
    , .{db_path});
    defer gpa.free(source);

    const nox_path = try std.fmt.allocPrint(gpa, "{s}/prog2.nox", .{path_buf[0..dir_len]});
    defer gpa.free(nox_path);
    try tmp.dir.writeFile(io, .{ .sub_path = "prog2.nox", .data = source });

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
    try std.testing.expectEqualStrings("caught\n0\n", result.stdout);
}
