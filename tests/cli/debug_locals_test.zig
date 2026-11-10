//! `-g` skaler yerel adını üretilen derlemeye yazar. QBE'nin değişken
//! yönergesi yoktur; ad, `qbe` çıktısından sonra `.debug_str` bölümüne eklenir.

const std = @import("std");

fn noxcPath() []const u8 {
    return "zig-out/bin/noxc";
}

test "noxc build -g --emit-asm: skaler yerel adi .s icinde" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{
        .sub_path = "slot.nox",
        .data =
        \\def add(x: int) -> int:
        \\    slot_local: int = x + 1
        \\    return slot_local
        \\
        \\print(add(2))
        \\
        ,
    });
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &path_buf);
    const dir = path_buf[0..len];
    const src = try std.fmt.allocPrint(gpa, "{s}/slot.nox", .{dir});
    defer gpa.free(src);
    const out = try std.fmt.allocPrint(gpa, "{s}/slot", .{dir});
    defer gpa.free(out);

    const build = try std.process.run(gpa, io, .{
        .argv = &.{ noxcPath(), "build", "-g", "--emit-asm", "-o", out, src },
    });
    defer gpa.free(build.stdout);
    defer gpa.free(build.stderr);
    try std.testing.expect(build.term == .exited and build.term.exited == 0);

    const asm_path = try std.fmt.allocPrint(gpa, "{s}.s", .{out});
    defer gpa.free(asm_path);
    const asm_text = try std.Io.Dir.cwd().readFileAlloc(io, asm_path, gpa, .limited(32 * 1024 * 1024));
    defer gpa.free(asm_text);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "slot_local") != null);
    try std.testing.expect(std.mem.indexOf(u8, asm_text, "debug_str") != null);
}
