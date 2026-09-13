//! noxhpycallbench — HPy köprüsünün `hpy_call_on` yolunun (kalıcı tutamaç
//! ÜZERİNDEN, tekrarlı çağrı) verim ölçümü — Faz FFI.2'nin (bkz. plan
//! dosyası "HPy `Obj` havuzlama...") `Obj` havuzlama + `MarshalCtx`/
//! `packed_args` tahsis azaltmasının GERÇEK etkisini ölçmek İçİn.
//!
//! `benchmarks/http_bench.zig`nin AYNI deseni: GERÇEK bir `.nox` programı
//! `noxc` İLE derlenip ÇALIŞTIRILIR, SADECE SÜRECİN YÜRÜTÜLME SÜRESİ
//! (derleme HARİÇ) `std.Io.Clock.Timestamp` İLE ÖLÇÜLÜR.
//!
//! Yöntem: `tests/compat/hpy_ext/noxtest.c`nin (GERÇEK bir HPy C uzantısı,
//! `.hpy-venv` KURULUYSA `zig build test` SIRASINDA `tests/compat/hpy_ext/
//! noxtest.so`ya derlenir) MEVCUT `sum_two_ints(a, b)` (HPyFunc_KEYWORDS,
//! `hpy_call_golden_test.zig`nin ZATEN kanıtladığı) test fonksiyonu, TEK
//! bir `hpy_open` İLE açılan kalıcı bir tutamaç ÜZERİNDEN BÜYÜK bir N TUR
//! boyunca `hpy_call_on(h, "sum_two_ints", i, i+1)` İLE çağrılır — TAM
//! OLARAK Faz FFI.2'nin hedeflediği "kalıcı tutamaç + tekrarlı çağrı"
//! deseni (`nox_hpy_open`+`hpy_call_on`, Faz 16'nın standart kullanımı).
//!
//! `.hpy-venv`/`noxtest.so` YOKSA (bkz. `build.zig`nin AYNI koşullu kurulum
//! notu) bu program AÇIK bir hatayla ÇIKAR — `zig build bench-hpy`
//! ÇALIŞTIRILMADAN ÖNCE `zig build test` (VEYA `.hpy-venv` kurulumu) EN AZ
//! BİR KEZ çalıştırılmış OLMALIDIR.
//!
//! **Hız için:** `zig build bench-hpy -Doptimize=ReleaseFast` kullanın —
//! havuzlama (`use_pool`) SADECE Release modlarında AKTİFTİR, Debug'da BU
//! ölçüm hem YAVAŞ (DebugAllocator) HEM havuzlamayı HİÇ EGZERSİZ ETMEZ.
//!
//! Proje kökünden çalıştırılmalıdır (`zig-out/bin/noxc`/`zig-out/lib/
//! noxrt.o`/`tests/compat/hpy_ext/noxtest.so`ya göreli yollar kullanır).

const std = @import("std");

const ITERATIONS: usize = 2_000_000;
const NOXTEST_SO_PATH = "tests/compat/hpy_ext/noxtest.so";

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buf);
    const out = &stdout_writer.interface;

    try out.writeAll("hpy_call_on verim (throughput) ölçümü — Faz FFI.2\n");
    try out.writeAll("==================================================\n");
    try out.print("tur sayısı: {d}\n\n", .{ITERATIONS});
    try out.flush();

    std.Io.Dir.cwd().access(io, NOXTEST_SO_PATH, .{}) catch {
        try out.print(
            "HATA: '{s}' bulunamadı — önce `zig build test` (VEYA `.hpy-venv`\n" ++
                "kurulumu + `cc -DHPY_ABI_UNIVERSAL ... -o {s} tests/compat/hpy_ext/noxtest.c`)\n" ++
                "çalıştırılmalı.\n",
            .{ NOXTEST_SO_PATH, NOXTEST_SO_PATH },
        );
        std.process.exit(1);
    };

    const source = try std.fmt.allocPrint(gpa,
        \\h: ptr = hpy_open("{s}", "noxtest")
        \\total: int = 0
        \\i: int = 0
        \\while i < {d}:
        \\    total = total + hpy_call_on(h, "sum_two_ints", i, i + 1)
        \\    i = i + 1
        \\print(total)
        \\
    , .{ NOXTEST_SO_PATH, ITERATIONS });
    defer gpa.free(source);

    const nox_path = "benchmarks/.hpy_call_bench_gen.nox";
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = nox_path, .data = source });

    try out.writeAll("derleniyor...\n");
    try out.flush();
    const compile_result = try std.process.run(gpa, io, .{
        .argv = &.{ "zig-out/bin/noxc", nox_path },
    });
    defer gpa.free(compile_result.stdout);
    defer gpa.free(compile_result.stderr);
    if (compile_result.term != .exited or compile_result.term.exited != 0) {
        try out.print("DERLEME BAŞARISIZ:\n{s}\n", .{compile_result.stderr});
        std.process.exit(1);
    }

    const bin_path = "benchmarks/.hpy_call_bench_gen";

    try out.writeAll("çalıştırılıyor...\n");
    try out.flush();

    const start = std.Io.Clock.Timestamp.now(io, .awake);
    const run_result = try std.process.run(gpa, io, .{ .argv = &.{bin_path} });
    const end = std.Io.Clock.Timestamp.now(io, .awake);
    defer gpa.free(run_result.stdout);
    defer gpa.free(run_result.stderr);

    const elapsed_ns: f64 = @floatFromInt(start.durationTo(end).raw.nanoseconds);
    const elapsed_s = elapsed_ns / 1_000_000_000.0;

    if (run_result.term != .exited or run_result.term.exited != 0) {
        try out.print("PROGRAM BAŞARISIZ ÇIKTI (stderr):\n{s}\n", .{run_result.stderr});
        std.process.exit(1);
    }
    if (run_result.stderr.len != 0) {
        try out.print("program stderr'e beklenmeyen bir çıktı yazdı (olası sızıntı):\n{s}\n", .{run_result.stderr});
    }

    try out.print("\nprogram çıktısı: {s}", .{run_result.stdout});
    try out.print("geçen süre: {d:.3}s\n", .{elapsed_s});
    try out.print("verim: {d:.0} çağrı/saniye\n", .{@as(f64, @floatFromInt(ITERATIONS)) / elapsed_s});
    try out.print("çağrı başına ortalama: {d:.1}ns\n", .{elapsed_ns / @as(f64, @floatFromInt(ITERATIONS))});
    try out.flush();

    std.Io.Dir.cwd().deleteFile(io, nox_path) catch {};
    std.Io.Dir.cwd().deleteFile(io, bin_path) catch {};
    std.Io.Dir.cwd().deleteFile(io, "benchmarks/.hpy_call_bench_gen.ssa") catch {};
    std.Io.Dir.cwd().deleteFile(io, "benchmarks/.hpy_call_bench_gen.s") catch {};
}
