//! Rune: `nox.terminal` gerçek bir pty'de (`scripts/terminal_pty_probe.py`): TTY algılama, `TIOCGWINSZ` boyutu, iç içe ham mod sayacı, bloklamayan
//! girdi okuma ve ham çıktı. Python/pty yoksa (Windows) atlanır.

const std = @import("std");
const builtin = @import("builtin");

test "terminal: gercek bir pty'de boyut, ham mod ve ham girdi/cikti" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    const r = std.process.run(std.testing.allocator, io, .{
        .argv = &.{ "python3", "scripts/terminal_pty_probe.py", "zig-out/bin/noxc", "tests/golden/terminal_pty_probe.nox" },
    }) catch return error.SkipZigTest; // python3 yok
    defer std.testing.allocator.free(r.stdout);
    defer std.testing.allocator.free(r.stderr);
    if (r.term == .exited and r.term.exited == 77) return error.SkipZigTest; // pty yok
    if (r.term != .exited or r.term.exited != 0) std.debug.print("pty probu basarisiz: {s}{s}\n", .{ r.stdout, r.stderr });
    try std.testing.expect(r.term == .exited and r.term.exited == 0);
}
