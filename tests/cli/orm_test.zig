//! `nox.orm` uçtan uca golden testi — bkz. plan dosyası "Faz STD.6: `nox.orm`".
//! `tests/cli/sqlite_test.zig`nin AYNI deseni: kurulu `zig-out/bin/noxc`yi
//! GERÇEK bir alt süreç olarak çalıştırır (`appendExternLinkArgs`ın `from
//! "sqlite3"` extern def'lerini görüp `-lsqlite3`yi OTOMATİK eklemesi
//! İçİn) — GERÇEK bir SQLite'a karşı Table/Column tanımlama → create_table
//! → insert (int/float/str/null KARIŞIK) → select (parametreli where_sql)
//! → update → delete akışını uçtan uca doğrular.

const std = @import("std");

fn noxcPath() []const u8 {
    return "zig-out/bin/noxc";
}

test "nox.orm: Table/Column tanimla + create_table + parametreli insert/select/update/delete" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(io, &path_buf);
    const db_path = try std.fmt.allocPrint(gpa, "{s}/orm_test.db", .{path_buf[0..dir_len]});
    defer gpa.free(db_path);

    const source = try std.fmt.allocPrint(gpa,
        \\import nox.orm
        \\from nox.orm import Table, Column, Value
        \\from nox.sqlite import open, Connection
        \\from nox.db import Row
        \\
        \\users_table: Table = Table("users", [Column("id", 0, True), Column("name", 1, False), Column("age", 0, False), Column("score", 2, False)])
        \\
        \\conn: Connection = open("{s}")
        \\nox.orm.create_table(conn, users_table)
        \\
        \\v1: dict[str, Value] = {{}}
        \\v1["name"] = nox.orm.val_str("Ayse")
        \\v1["age"] = nox.orm.val_int(30)
        \\v1["score"] = nox.orm.val_float(9.5)
        \\n1: int = nox.orm.insert(conn, users_table, v1)
        \\print(n1)
        \\
        \\v2: dict[str, Value] = {{}}
        \\v2["name"] = nox.orm.val_str("Mehmet")
        \\v2["age"] = nox.orm.val_int(25)
        \\v2["score"] = nox.orm.val_null()
        \\n2: int = nox.orm.insert(conn, users_table, v2)
        \\print(n2)
        \\
        \\all_rows: list[Row] = nox.orm.select(conn, users_table, "", [])
        \\print(len(all_rows))
        \\
        \\filtered: list[Row] = nox.orm.select(conn, users_table, "age > ?", [nox.orm.val_int(26)])
        \\print(len(filtered))
        \\print(filtered[0].get_str(1))
        \\
        \\upd_vals: dict[str, Value] = {{}}
        \\upd_vals["age"] = nox.orm.val_int(31)
        \\updated: int = nox.orm.update(conn, users_table, upd_vals, "name = ?", [nox.orm.val_str("Ayse")])
        \\print(updated)
        \\
        \\check: list[Row] = nox.orm.select(conn, users_table, "name = ?", [nox.orm.val_str("Ayse")])
        \\print(check[0].get_int(2))
        \\print(check[0].is_null(3))
        \\
        \\deleted: int = nox.orm.delete(conn, users_table, "name = ?", [nox.orm.val_str("Mehmet")])
        \\print(deleted)
        \\
        \\remaining: list[Row] = nox.orm.select(conn, users_table, "", [])
        \\print(len(remaining))
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
        "1\n1\n2\n1\nAyse\n1\n31\nFalse\n1\n1\n",
        result.stdout,
    );
}
