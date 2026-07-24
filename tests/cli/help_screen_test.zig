//! `noxc`nin yardım ekranı + bilinmeyen-komut ipucu testleri (kullanıcı
//! geri bildirimi, 2026-07-24): çıplak `noxc` daha önce tek satırlık bir
//! "kullanim" mesajı veriyordu, `noxc upgrade` gibi mistyped bir alt komut
//! ise ham "error: FileNotFound" İLE BAŞARISIZ oluyordu. `search_test.zig`
//! İLE AYNI desen (gerçek `noxc` alt süreç, `std.testing.environ.createMap`
//! İLE `LANG` override).

const std = @import("std");

fn noxcPath() []const u8 {
    return "zig-out/bin/noxc";
}

fn runWithLang(gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8, lang: []const u8) !std.process.RunResult {
    var env = try std.testing.environ.createMap(gpa);
    defer env.deinit();
    try env.put("LANG", lang);
    try env.put("LC_ALL", lang);
    return std.process.run(gpa, io, .{ .argv = argv, .environ_map = &env });
}

test "noxc (argumansiz): LANG=tr_TR ile Turkce yardim ekrani gosterir" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const result = try runWithLang(gpa, io, &.{noxcPath()}, "tr_TR.UTF-8");
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "Kullanım") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "Alt komutlar") != null);
}

test "noxc (argumansiz): LANG=en_US ile Ingilizce yardim ekrani gosterir" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const result = try runWithLang(gpa, io, &.{noxcPath()}, "en_US.UTF-8");
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "Usage") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "Subcommands") != null);
}

test "noxc --help/-h/help: uc esanlami da ayni yardim ekranini gosterir" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    for ([_][]const u8{ "--help", "-h", "help" }) |flag| {
        const result = try std.process.run(gpa, io, .{ .argv = &.{ noxcPath(), flag } });
        defer gpa.free(result.stdout);
        defer gpa.free(result.stderr);
        try std.testing.expect(result.term == .exited and result.term.exited == 0);
        try std.testing.expect(std.mem.indexOf(u8, result.stderr, "noxc") != null);
    }
}

test "noxc <bilinmeyen-komut>: ham FileNotFound yerine ipucu verir, exit 1" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const result = try runWithLang(gpa, io, &.{ noxcPath(), "upgrade" }, "en_US.UTF-8");
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    try std.testing.expect(result.term == .exited and result.term.exited == 1);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "unknown command or file") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "--help") != null);
    // Ham Zig panik izi (ESKİ davranış) ARTIK gorunmemeli.
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "std.zig") == null);
}

test "noxc <gercekten-eksik.nox>: bilinmeyen-komut ipucu YERINE normal dosya-bulunamadi mesaji verir" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const result = try runWithLang(gpa, io, &.{ noxcPath(), "kesinlikle-yok-boyle-bir-dosya.nox" }, "en_US.UTF-8");
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    try std.testing.expect(result.term == .exited and result.term.exited == 1);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "file not found") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "unknown command") == null);
}
