//! Faz 10 (WASM): TÜM `codegen_cases/` korpusunu (`fixture_corpus.zig`) `--target wasm32-wasi` ile derleyip Node WASI'sinde çalıştırır ve native
//! `.expected` çıktısıyla karşılaştırır — `backend_differential_corpus_test.zig`nin wasm karşılığı. Opt-in ve yavaş: `zig build wasm-corpus-test`.
//!
//! Atlananlar (bilinçli, gerekçeli):
//! - wasm'de olmayan modülleri (http/sqlite/postgres/...) KULLANAN fixture'lar: derleyici onları açık iletiyle REDDEDER; bu da başarı sayılır.
//! - `thread_spawn_ordering`: wasm32-wasi tek iş parçacıklıdır; `nox.thread` aynı yığında eşzamanlı çalışır, `sleep_ms` ile yarışan sıra native'den farklıdır.
//! - `task_local_basic`: iki işçinin yazdırma sırası zamanlayıcıya bağlıdır (testin amacı per-fiber izolasyon).
//! - `mathx_trig_log_constants`: wasi-libc (musl) `exp(1.0)` değeri 1 ULP farklıdır (2.7182818284590455); Python/macOS libm 2.718281828459045 verir.

const std = @import("std");
const build_options = @import("build_options");
const fixture_corpus = @import("fixture_corpus.zig");
const wasm_helpers = @import("wasm_helpers.zig");

const DENYLISTED_SOURCES = [_][]const u8{
    @embedFile("codegen_cases/thread_spawn_ordering.nox"),
    @embedFile("codegen_cases/task_local_basic.nox"),
    @embedFile("codegen_cases/mathx_trig_log_constants.nox"),
};

fn isDenylisted(source: []const u8) bool {
    for (DENYLISTED_SOURCES) |s| if (std.mem.eql(u8, s, source)) return true;
    return false;
}

test "wasm(korpus): tüm codegen_cases fixture'ları wasm32-wasi'de native ile aynı çıktıyı verir" {
    const allocator = std.testing.allocator;
    var failures: usize = 0;
    var ran: usize = 0;
    var rejected: usize = 0;
    var skipped: usize = 0;
    for (fixture_corpus.fixtures) |fx| {
        if (isDenylisted(fx.source)) {
            skipped += 1;
            continue;
        }
        const outcome = try wasm_helpers.buildAndRun(allocator, build_options.noxc_path, build_options.runner_path, fx.source);
        switch (outcome) {
            .tool_missing => return error.SkipZigTest,
            .rejected => |msg| {
                allocator.free(msg);
                rejected += 1;
            },
            .build_failed => |msg| {
                defer allocator.free(msg);
                std.debug.print("FARK (derleme): '{s}': {s}\n", .{ fx.name, msg });
                failures += 1;
            },
            .ran => |r| {
                defer allocator.free(r.stdout);
                defer allocator.free(r.stderr);
                ran += 1;
                const exited_ok = r.term == .exited and r.term.exited == 0;
                const want_ok = fx.kind == .golden;
                if (exited_ok != want_ok or !std.mem.eql(u8, fx.expected_stdout, r.stdout)) {
                    std.debug.print("FARK: '{s}'\n  beklenen stdout: {s}\n  gelen stdout: {s}\n  stderr: {s}\n", .{ fx.name, fx.expected_stdout, r.stdout, r.stderr });
                    failures += 1;
                }
            },
        }
    }
    std.debug.print("wasm(korpus): {d} calistirildi, {d} reddedildi (wasm'de olmayan modul), {d} atlandi (denylist), {d} FARK\n", .{ ran, rejected, skipped, failures });
    try std.testing.expectEqual(@as(usize, 0), failures);
}
