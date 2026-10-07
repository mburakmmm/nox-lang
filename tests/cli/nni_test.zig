//! NNI v1 (Nox Native Interface) uçtan uca testi — GERÇEK bir C eklentisi (`tests/compat/nni_ext/plugin.c`, `include/nox_nni.h`'ye karşı)
//! `cc -shared` ile derlenir, kurulu `noxc` ile derlenen bir Nox programı onu `nox.native` üzerinden yükleyip çağırır
//! (tamsayı/ondalık/bool/dize argümanları, hata iletisi, bilinmeyen işlev, yerel iş parçacığından `post_event`).

const std = @import("std");

test "NNI v1: gercek bir C eklentisi yuklenir, cagrilir, hata ve iplik olaylari calisir" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(io, &path_buf);
    const dir = path_buf[0..dir_len];

    const so_path = try std.fmt.allocPrint(gpa, "{s}/libnni_test.so", .{dir});
    defer gpa.free(so_path);
    const cc = try std.process.run(gpa, io, .{
        .argv = &.{ "cc", "-shared", "-fPIC", "-I", "include", "-o", so_path, "tests/compat/nni_ext/plugin.c", "-lpthread" },
    });
    defer gpa.free(cc.stdout);
    defer gpa.free(cc.stderr);
    if (cc.term != .exited or cc.term.exited != 0) {
        std.debug.print("eklenti derlenemedi: {s}\n", .{cc.stderr});
        return error.PluginBuildFailed;
    }

    const source = try std.fmt.allocPrint(gpa,
        \\from nox.native import open_plugin, Plugin, Event, NativeError
        \\
        \\p: Plugin = open_plugin("{s}")
        \\p.arg_int(1)
        \\p.arg_int(2)
        \\p.arg_int(39)
        \\print(p.call_int("add"))
        \\p.arg_float(21.0)
        \\p.arg_bool(True)
        \\print(p.call_float("scale"))
        \\p.arg_str("dünya")
        \\print(p.call_str("greet"))
        \\try:
        \\    p.call("fail")
        \\except NativeError as e:
        \\    print("hata:", e.message)
        \\try:
        \\    p.call("yok")
        \\except NativeError as e:
        \\    print("hata:", e.message)
        \\p.arg_int(3)
        \\p.call("start_thread")
        \\got: int = 0
        \\done: bool = False
        \\while not done:
        \\    ev: Event | None = p.wait_event(2000)
        \\    if ev == None:
        \\        print("zaman asimi")
        \\        done = True
        \\    else:
        \\        if ev.kind == 7:
        \\            got += ev.int_value
        \\        else:
        \\            print(ev.str_value, got)
        \\            done = True
        \\p.close()
        \\try:
        \\    open_plugin("{s}/yok.so")
        \\except NativeError as e:
        \\    print("acilamadi")
        \\
    , .{ so_path, dir });
    defer gpa.free(source);

    const nox_path = try std.fmt.allocPrint(gpa, "{s}/prog.nox", .{dir});
    defer gpa.free(nox_path);
    try tmp.dir.writeFile(io, .{ .sub_path = "prog.nox", .data = source });

    const expected =
        "42\n42.0\nmerhaba, dünya! (6 bayt)\nhata: fail: bilerek basarisiz\nhata: yok: kayitli yerel islev bulunamadi\nbitti 30\nacilamadi\n";
    for ([_][]const u8{ "llvm", "qbe" }) |backend| {
        const result = try std.process.run(gpa, io, .{
            .argv = &.{ "zig-out/bin/noxc", "run", "--backend", backend, nox_path },
        });
        defer gpa.free(result.stdout);
        defer gpa.free(result.stderr);
        if (result.term != .exited or result.term.exited != 0) {
            std.debug.print("program basarisiz ({s}): {s}\n", .{ backend, result.stderr });
            return error.ProgramFailed;
        }
        if (result.stderr.len != 0) {
            std.debug.print("stderr'e beklenmeyen cikti ({s}): {s}\n", .{ backend, result.stderr });
            return error.UnexpectedStderrOutput;
        }
        try std.testing.expectEqualStrings(expected, result.stdout);
    }
}
