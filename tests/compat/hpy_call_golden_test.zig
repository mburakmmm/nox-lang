//! Faz 14: `hpy_call` yerleşiğinin GERÇEK bir .nox programından derlenmiş
//! bir native ikiliye, ve o ikilinin çalışma zamanında GERÇEK bir HPy
//! eklentisini (`tests/compat/hpy_ext/noxtest.so`) yükleyip çağırdığını
//! doğrular. `tests/golden/codegen_golden_test.zig`e (her zaman çalışan ana
//! takıma) KASITLI OLARAK eklenmedi — bu, `.hpy-venv` kurulu olmayanlarda
//! ana takımı kırardı (bkz. build.zig, Faz 12'nin "sessizce atlanır"
//! ilkesi). Bu dosya yalnızca `noxtest.so` derlendiğinde koşullu olarak
//! test takımına eklenir.
//!
//! `compileAndRun`/`expectGolden`, `tests/golden/codegen_golden_test.zig`
//! ile AYNI yapıdadır (kasıtlı bir kod tekrarı — bu dosyanın koşullu
//! olması, paylaşılan bir yardımcıyı build.zig'de ayrıca koşullu hale
//! getirmekten daha basit).

const std = @import("std");
const nox = @import("nox");

fn compileAndRun(allocator: std.mem.Allocator, source: []const u8) !std.process.RunResult {
    const tokens = try nox.lexer.tokenize(allocator, source);
    const module = try nox.parser.parseModule(allocator, tokens);

    var checker_state = nox.checker.Checker.init(allocator);
    checker_state.checkModule(module) catch |e| {
        std.debug.print("beklenmeyen tip hatasi ({t}): {s}\n", .{ e, checker_state.diagnostic orelse "(mesaj yok)" });
        return error.FixtureNotWellTyped;
    };

    var generic_names: std.ArrayListUnmanaged([]const u8) = .empty;
    var generic_it = checker_state.generic_functions.keyIterator();
    while (generic_it.next()) |k| try generic_names.append(allocator, k.*);

    const ir = try nox.codegen.generateModule(allocator, module, checker_state.instantiations.items, generic_names.items);

    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &path_buf);
    const dir_path = path_buf[0..len];

    const ssa_path = try std.fmt.allocPrint(allocator, "{s}/prog.ssa", .{dir_path});
    const asm_path = try std.fmt.allocPrint(allocator, "{s}/prog.s", .{dir_path});
    const bin_path = try std.fmt.allocPrint(allocator, "{s}/prog", .{dir_path});

    try tmp.dir.writeFile(io, .{ .sub_path = "prog.ssa", .data = ir });

    const qbe_result = try std.process.run(allocator, io, .{
        .argv = &.{ "qbe", "-o", asm_path, ssa_path },
    });
    if (qbe_result.term != .exited or qbe_result.term.exited != 0) {
        std.debug.print("qbe basarisiz: {s}\n", .{qbe_result.stderr});
        return error.QbeFailed;
    }

    const cc_result = try std.process.run(allocator, io, .{
        .argv = &.{ "cc", "-o", bin_path, asm_path, "zig-out/lib/noxrt.o", "-lm" },
    });
    if (cc_result.term != .exited or cc_result.term.exited != 0) {
        std.debug.print("cc basarisiz: {s}\n", .{cc_result.stderr});
        return error.CcFailed;
    }

    return std.process.run(allocator, io, .{ .argv = &.{bin_path} });
}

fn expectGolden(source: []const u8, expected: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const run_result = try compileAndRun(arena.allocator(), source);
    if (run_result.term != .exited or run_result.term.exited != 0) {
        std.debug.print("program basarisiz cikti (stderr): {s}\n", .{run_result.stderr});
        return error.ProgramFailed;
    }
    if (run_result.stderr.len != 0) {
        std.debug.print("program stderr'e beklenmeyen bir çıktı yazdı (olası bellek sızıntısı): {s}\n", .{run_result.stderr});
        return error.UnexpectedStderrOutput;
    }
    try std.testing.expectEqualStrings(expected, run_result.stdout);
}

test "hpy_call: gerçek bir .nox programından gerçek bir HPy eklentisi çağrılır" {
    try expectGolden(
        \\print(hpy_call("tests/compat/hpy_ext/noxtest.so", "noxtest", "add_one", 41))
        \\
    ,
        "42\n",
    );
}
