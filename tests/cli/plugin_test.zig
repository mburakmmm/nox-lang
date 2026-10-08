//! Plugin API v1 uçtan uca testi: NNI test eklentisi + `nox-plugin.json` manifesti `nox.plugin` ile yüklenir; tipli imza denetimi,
//! yetenek onayı, kayıtlı-işlev ↔ manifest çapraz doğrulaması, native hata, iş parçacığı olayı ve `nox_plugin_shutdown_v1` doğrulanır.

const std = @import("std");

test "Plugin API v1: manifest, imza denetimi, yetenek onayi, shutdown" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(io, &path_buf);
    const dir = path_buf[0..dir_len];

    const so_path = try std.fmt.allocPrint(gpa, "{s}/libplug.so", .{dir});
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

    const manifest =
        \\{
        \\  "name": "test.plug", "version": "0.1.0", "plugin_api": 1,
        \\  "library": {"macos-arm64": "libplug.so", "linux-x64": "libplug.so", "linux-arm64": "libplug.so", "windows-x64": "libplug.so"},
        \\  "capabilities": ["threads"],
        \\  "functions": [
        \\    {"name": "add", "args": ["int", "..."], "returns": "int"},
        \\    {"name": "scale", "args": ["float", "bool"], "returns": "float"},
        \\    {"name": "greet", "args": ["str"], "returns": "str"},
        \\    {"name": "fail", "returns": "none"},
        \\    {"name": "start_thread", "args": ["int"], "returns": "none"}
        \\  ]
        \\}
    ;
    try tmp.dir.writeFile(io, .{ .sub_path = "nox-plugin.json", .data = manifest });
    // Eksik işlev: kayıtlı küme manifestle uyuşmazsa yükleme REDDEDİLMELİ.
    try tmp.dir.writeFile(io, .{ .sub_path = "bad-plugin.json", .data =
        \\{"name": "test.bad", "version": "0.1.0", "plugin_api": 1,
        \\ "library": {"macos-arm64": "libplug.so", "linux-x64": "libplug.so", "linux-arm64": "libplug.so", "windows-x64": "libplug.so"},
        \\ "functions": [{"name": "add", "args": ["int", "..."], "returns": "int"}]}
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "future-plugin.json", .data =
        \\{"name": "test.future", "version": "9.0.0", "plugin_api": 2, "library": {}, "functions": []}
    });

    const marker_path = try std.fmt.allocPrint(gpa, "{s}/marker.txt", .{dir});
    defer gpa.free(marker_path);

    const source = try std.fmt.allocPrint(gpa,
        \\from nox.plugin import load_plugin, LoadedPlugin, PluginError
        \\from nox.native import Event
        \\
        \\p: LoadedPlugin = load_plugin("{[d]s}/nox-plugin.json", ["threads"])
        \\p.arg_int(1)
        \\p.arg_int(2)
        \\p.arg_int(39)
        \\print(p.call_int("add"))
        \\p.arg_float(21.0)
        \\p.arg_bool(True)
        \\print(p.call_float("scale"))
        \\p.arg_str("dünya")
        \\print(p.call_str("greet"))
        \\p.arg_str("x")
        \\try:
        \\    print(p.call_int("add"))
        \\except PluginError as e:
        \\    print("hata:", e.message)
        \\p.arg_int(5)
        \\p.arg_int(6)
        \\print(p.call_int("add"))
        \\try:
        \\    p.call_int("yok")
        \\except PluginError as e:
        \\    print("hata:", e.message)
        \\try:
        \\    print(p.call_str("add"))
        \\except PluginError as e:
        \\    print("hata:", e.message)
        \\try:
        \\    p.call("fail")
        \\except Exception as e:
        \\    print("native:", e.message)
        \\p.arg_int(3)
        \\p.call("start_thread")
        \\done: bool = False
        \\got: int = 0
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
        \\try:
        \\    load_plugin("{[d]s}/nox-plugin.json", ["fs.read"])
        \\except PluginError as e:
        \\    print("hata:", e.message)
        \\try:
        \\    load_plugin("{[d]s}/nox-plugin.json", ["*"]).shutdown()
        \\    print("joker tamam")
        \\except PluginError as e:
        \\    print("beklenmeyen:", e.message)
        \\try:
        \\    load_plugin("{[d]s}/bad-plugin.json", [])
        \\except PluginError as e:
        \\    print("hata:", e.message)
        \\try:
        \\    load_plugin("{[d]s}/future-plugin.json", [])
        \\except PluginError as e:
        \\    print("hata:", e.message)
        \\try:
        \\    load_plugin("{[d]s}/yok.json", [])
        \\except PluginError as e:
        \\    print("hata:", e.message)
        \\p.shutdown()
        \\try:
        \\    p.call_int("add")
        \\except PluginError as e:
        \\    print("hata:", e.message)
        \\
    , .{ .d = dir });
    defer gpa.free(source);
    try tmp.dir.writeFile(io, .{ .sub_path = "prog.nox", .data = source });
    const nox_path = try std.fmt.allocPrint(gpa, "{s}/prog.nox", .{dir});
    defer gpa.free(nox_path);

    const expected = try std.fmt.allocPrint(
        gpa,
        "42\n42.0\nmerhaba, dünya! (6 bayt)\nhata: add: argument 1 must be int, got str\n11\n" ++
            "hata: test.plug: the manifest declares no function 'yok'\nhata: add: returns int, not str\nnative: fail: bilerek basarisiz\n" ++
            "bitti 30\nhata: test.plug: capability not granted: threads\njoker tamam\n" ++
            "hata: test.bad: registered functions do not match the manifest (5 registered, 1 declared)\n" ++
            "hata: test.future: unsupported plugin_api 2 (this runtime supports 1)\n" ++
            "hata: manifest not found: {s}/yok.json\nhata: test.plug: the plugin is closed\n",
        .{dir},
    );
    defer gpa.free(expected);

    var env_map = try std.testing.environ.createMap(gpa);
    defer env_map.deinit();
    try env_map.put("NOX_NNI_TEST_MARKER", marker_path);

    for ([_][]const u8{ "llvm", "qbe" }) |backend| {
        tmp.dir.deleteFile(io, "marker.txt") catch {};
        const result = try std.process.run(gpa, io, .{
            .argv = &.{ "zig-out/bin/noxc", "run", "--backend", backend, nox_path },
            .environ_map = &env_map,
        });
        defer gpa.free(result.stdout);
        defer gpa.free(result.stderr);
        if (result.term != .exited or result.term.exited != 0) {
            std.debug.print("program basarisiz ({s}): {s}\n", .{ backend, result.stderr });
            return error.ProgramFailed;
        }
        try std.testing.expectEqualStrings(expected, result.stdout);
        // shutdown kancası: joker-yetenekli geçici yükleme + uyuşmazlık nedeniyle kapatılan `bad` yüklemesi + son `p.shutdown()` = üç satır.
        const marker = try tmp.dir.readFileAlloc(io, "marker.txt", gpa, .limited(4096));
        defer gpa.free(marker);
        try std.testing.expectEqualStrings("shutdown\nshutdown\nshutdown\n", marker);
    }
}
