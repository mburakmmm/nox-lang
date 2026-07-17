//! noxbench — Nox dilini çeşitli alanlarda (özyineleme, ham döngü, liste
//! işleme, ARC-ağırlıklı OOP, generics/protokoller, istisna kontrol akışı,
//! `lowlevel` arena, str geçişi) sınayan benchmark takımı çalıştırıcısı.
//!
//! İki bölüm çalıştırır:
//! 1. `benchmarks/*.nox` — büyük N ile "stres" testleri (yalnızca Nox,
//!    çalışma zamanının büyük ölçekte çökmediğini/sızdırmadığını doğrular).
//! 2. `benchmarks/compare/*.nox` + `*.py` — AYNI algoritmanın Python
//!    karşılığıyla eşleştirildiği, küçültülmüş N'li bir karşılaştırma takımı
//!    (python3 kuruluysa çalışır; değilse bu bölüm sessizce atlanır).
//!
//! Her `.nox` dosyası önce `noxc` ile GERÇEK bir native ikiliye derlenir,
//! sonra bir kez çalıştırılıp çıktısı doğrulanır (yanlış sonuç veya stderr'e
//! yazılan herhangi bir şey — olası bir sızıntı/hata — bir başarısızlıktır),
//! ardından zamanlama için birkaç kez daha çalıştırılır.
//!
//! **Hız için:** `zig build bench -Doptimize=ReleaseFast` kullanın. Debug
//! modunda çalışma zamanı `std.heap.DebugAllocator` (sızıntı tespiti aktif,
//! ama yüksek hacimli tahsis/serbest bırakma döngülerinde YAPAY OLARAK YAVAŞ
//! — bkz. runtime/alloc/asap.zig) kullanır; Release modlarında (`ReleaseFast`/
//! `ReleaseSafe`/`ReleaseSmall`) `std.heap.smp_allocator`a (üretim kalitesinde,
//! sızıntı tespiti OLMADAN) geçer. `zig build bench`in kendisi (varsayılan
//! Debug) hâlâ çalışır ama sayılar gerçekçi değildir — Python'a karşı adil
//! bir karşılaştırma için ReleaseFast şarttır.
//!
//! `zig-out/bin/noxc`/`zig-out/lib/noxrt.o`ya göreli yollar kullandığından
//! proje kökünden çalıştırılmalıdır — bkz. build.zig.

const std = @import("std");

const STRESS_REPEATS = 5;
const COMPARE_REPEATS = 3;

const Benchmark = struct {
    name: []const u8,
    path: []const u8,
    expected: []const u8,
};

const stress_benchmarks = [_]Benchmark{
    .{ .name = "numeric_recursion", .path = "benchmarks/numeric_recursion.nox", .expected = "9227465\n" },
    .{ .name = "tight_loop_arithmetic", .path = "benchmarks/tight_loop_arithmetic.nox", .expected = "2838615082755021824\n" },
    .{ .name = "list_traversal", .path = "benchmarks/list_traversal.nox", .expected = "1455000\n" },
    .{ .name = "oop_arc_churn", .path = "benchmarks/oop_arc_churn.nox", .expected = "49995000\n" },
    .{ .name = "generics_protocols", .path = "benchmarks/generics_protocols.nox", .expected = "2e+14\n" },
    .{ .name = "exceptions_control_flow", .path = "benchmarks/exceptions_control_flow.nox", .expected = "8333316667\n" },
    .{ .name = "lowlevel_arena", .path = "benchmarks/lowlevel_arena.nox", .expected = "25180000\n" },
    .{ .name = "string_passing", .path = "benchmarks/string_passing.nox", .expected = "6666667\n" },
    .{ .name = "deep_equality", .path = "benchmarks/deep_equality.nox", .expected = "4000000\n" },
    .{ .name = "list_class_field", .path = "benchmarks/list_class_field.nox", .expected = "36000000\n" },
    // Async/Task/Channel churn'ün Python'a karşı adil bir eşdeğeri yok
    // (asyncio/threading TAMAMEN farklı bir eşzamanlılık modeli, GIL dahil)
    // — bu yüzden yalnızca STRES bölümünde (kendi doğruluğu + büyük ölçekte
    // performans regresyon takibi için), karşılaştırma bölümünde DEĞİL.
    .{ .name = "async_task_churn", .path = "benchmarks/async_task_churn.nox", .expected = "249999500000\n" },
    // Dil stabilizasyonu fazı §N.7: `dict[K,V]`nin ÖNCE ölçümü —
    // `runtime/collections/dict.zig`nin doğrusal-arama (`findIndex`)
    // temelli olduğu KANITLANMIŞ bir taban çizgisi (bkz. nox-teknik-
    // spesifikasyon.md §3.28) — N adet `set` + N adet `get`, HER İKİSİ DE
    // O(mevcut boyut) olduğundan TOPLAM O(n²) — M.3'ün hash tablosuna
    // geçişi SONRASI bu AYNI benchmark O(n)'e düşmeli, fark WALL-CLOCK
    // sürede SOMUT olarak görülür.
    .{ .name = "dict_bench", .path = "benchmarks/dict_bench.nox", .expected = "24995000\n" },
    // Dil stabilizasyonu fazı §N.6: `nox.json`nin ÖNCE ölçümü —
    // `nox_json_decode_raw` (`std.json.parseFromSlice` + `buildNode`)
    // `std.heap.page_allocator`a DOĞRUDAN çok sayıda küçük tahsis yapıyor
    // (HER JSON düğümü KENDİ ayrı tahsisini alıyor) — M.6'nın (tek bir
    // `ArenaAllocator`a sarma) taban çizgisi. 200 elemanlı iç içe bir
    // JSON dizisini 50 kez decode+encode eder.
    .{ .name = "json_bench", .path = "benchmarks/json_bench.nox", .expected = "384550\n" },
    // Dil stabilizasyonu fazı §N.2-N.5: `nox.strings`/`nox.math`/`nox.os`+
    // `nox.fs`/`nox.time` — HİÇBİRİNİN benchmark kapsamı YOKTU (yalnızca
    // golden/birim testleri). Bunlar bir DARBOĞAZ BULMAK için DEĞİL,
    // gelecekteki regresyonları YAKALAMAK VE (özellikle `nox.math` İÇİN)
    // "darboğaz YOK" bulgusunu somutlaştırmak için eklendi.
    .{ .name = "strings_bench", .path = "benchmarks/strings_bench.nox", .expected = "160000\n" },
    .{ .name = "math_bench", .path = "benchmarks/math_bench.nox", .expected = "1.49791e+10\n" },
    .{ .name = "os_fs_bench", .path = "benchmarks/os_fs_bench.nox", .expected = "30000\n" },
    .{ .name = "time_bench", .path = "benchmarks/time_bench.nox", .expected = "200000\n" },
    // Faz M.8 (yeniden ele alındı, bkz. nox-teknik-spesifikasyon.md §3.59):
    // `Counter.increment`in `self.value`ye yaptığı basit aritmetik ATAMA
    // DIŞINDA HİÇBİR şey yapmaz (raise/başka bir metod/serbest fonksiyon
    // çağrısı YOK) — bu yüzden PROVABLY-SAFE'dir, `nox_exception_pending`
    // kontrolü her çağrı sitesinde ELENİR. 300M çağrı, izole mikro-
    // benchmark'ın (bu fazı tetikleyen ölçüm, bkz. RESULTS.md) AYNI
    // ölçeği — hem doğruluk (basit toplama) hem regresyon takibi içindir.
    .{ .name = "method_call_elision", .path = "benchmarks/method_call_elision.nox", .expected = "300000000\n" },
    // Faz GG.3 (bkz. nox-teknik-spesifikasyon.md §3.68): `for b in boxes:
    // ... b.get() ...` deseni — `boxes` parametresi `list[Box]` OLDUĞUNDAN
    // döngü değişkeninin sınıfı ARTIK çözümlenir, `sum_boxes` PROVABLY-SAFE
    // sayılır (`Box.__init__`/`Box.get` HİÇBİRİ raise ETMEZ). 30M dış
    // yineleme × 8 elemanlı liste = 240M metod çağrısı — `method_call_
    // elision`ın ÖLÇEĞİYLE TUTARLI, ama for-loop üzerinden (GG.3'ün
    // ELEDİĞİ GERÇEK boşluk).
    .{ .name = "for_loop_method_elision", .path = "benchmarks/for_loop_method_elision.nox", .expected = "1080000000\n" },
    // Faz EE.1 (bkz. nox-teknik-spesifikasyon.md §3.61) — `nox.strings.
    // contains`/`index_of`/`starts_with`/`ends_with`nin (`s[i]` YERİNE
    // alloc-sız `byte_at` kullanan) VE `nox.strings.join`in (saf Nox O(n²)
    // döngü YERİNE Zig'de tek-geçiş O(n)) İKİ AYRI EE.1 optimizasyonunu
    // BİRLİKTE ölçer — 50000 `contains` taraması + 500 `join` çağrısı
    // (3000 elemanlı bir liste üzerinde).
    .{ .name = "strings_perf_bench", .path = "benchmarks/strings_perf_bench.nox", .expected = "50000\n7499500\n" },
};

/// **C karşılaştırması (kullanıcı isteği):** Python'un yanına, AYNI on
/// çiftin HER BİRİ İÇİN bir de elle yazılmış bir C eşdeğeri eklendi
/// (`benchmarks/compare/*.c`) — `cc -O2` ile derlenip AYNI `timeRuns`
/// mekanizmasıyla ölçülür. C dosyaları algoritmik olarak nox/py İLE
/// BİREBİR AYNI hesaplamayı yapar (aynı `n`, aynı döngü/dallanma yapısı)
/// ama dilin KENDİ deyimleriyle (ör. `oop_arc_churn` İÇİN `malloc`/`free`,
/// `exceptions_control_flow` İÇİN `setjmp`/`longjmp` — ARC/gerçek istisna
/// YERİNE C'nin KENDİ eşdeğer ilkelleri, "aynı iş" yapılırken "o dilde
/// doğal olan" YOLLA yapılması İÇİN). `generics_protocols` İÇİN dinamik
/// gönderim `Shape{area: fn ptr, data: void*}` İLE simüle edilir (C'de
/// protokol/arayüz YOK, fonksiyon işaretçisi EN YAKIN eşdeğer). Beklenen
/// çıktılar GERÇEKTEN derlenip ÇALIŞTIRILARAK doğrulandı (elle
/// HESAPLANMADI) — `generics_protocols.c`nin `%.17g` formatlı float
/// çıktısı Python'un KENDİ `repr`iyle BİREBİR aynı dizgeyi ÜRETTİ
/// (`112500315995399.97`), tesadüf DEĞİL — ikisi de IEEE-754 double
/// aritmetiği kullanıyor, yalnızca biçimlendirme YOLU farklı olabilirdi.
const ComparePair = struct {
    name: []const u8,
    nox_path: []const u8,
    nox_expected: []const u8,
    py_path: []const u8,
    py_expected: []const u8,
    c_path: []const u8,
    c_expected: []const u8,
};

const compare_pairs = [_]ComparePair{
    .{
        .name = "numeric_recursion",
        .nox_path = "benchmarks/compare/numeric_recursion.nox",
        .nox_expected = "5702887\n",
        .py_path = "benchmarks/compare/numeric_recursion.py",
        .py_expected = "5702887\n",
        .c_path = "benchmarks/compare/numeric_recursion.c",
        .c_expected = "5702887\n",
    },
    .{
        .name = "tight_loop_arithmetic",
        .nox_path = "benchmarks/compare/tight_loop_arithmetic.nox",
        .nox_expected = "-8111624021204984320\n",
        .py_path = "benchmarks/compare/tight_loop_arithmetic.py",
        .py_expected = "2666666266666680000000\n",
        .c_path = "benchmarks/compare/tight_loop_arithmetic.c",
        .c_expected = "-8111624021204984320\n",
    },
    .{
        .name = "list_traversal",
        .nox_path = "benchmarks/compare/list_traversal.nox",
        .nox_expected = "485000000\n",
        .py_path = "benchmarks/compare/list_traversal.py",
        .py_expected = "485000000\n",
        .c_path = "benchmarks/compare/list_traversal.c",
        .c_expected = "485000000\n",
    },
    .{
        .name = "oop_arc_churn",
        .nox_path = "benchmarks/compare/oop_arc_churn.nox",
        .nox_expected = "4499998500000\n",
        .py_path = "benchmarks/compare/oop_arc_churn.py",
        .py_expected = "4499998500000\n",
        .c_path = "benchmarks/compare/oop_arc_churn.c",
        .c_expected = "4499998500000\n",
    },
    .{
        .name = "generics_protocols",
        .nox_path = "benchmarks/compare/generics_protocols.nox",
        .nox_expected = "1.125e+14\n",
        .py_path = "benchmarks/compare/generics_protocols.py",
        .py_expected = "112500315995399.97\n",
        .c_path = "benchmarks/compare/generics_protocols.c",
        .c_expected = "112500315995399.97\n",
    },
    .{
        .name = "exceptions_control_flow",
        .nox_path = "benchmarks/compare/exceptions_control_flow.nox",
        .nox_expected = "20833334166667\n",
        .py_path = "benchmarks/compare/exceptions_control_flow.py",
        .py_expected = "20833334166667\n",
        .c_path = "benchmarks/compare/exceptions_control_flow.c",
        .c_expected = "20833334166667\n",
    },
    .{
        .name = "lowlevel_arena",
        .nox_path = "benchmarks/compare/lowlevel_arena.nox",
        .nox_expected = "25000180000000\n",
        .py_path = "benchmarks/compare/lowlevel_arena.py",
        .py_expected = "25000180000000\n",
        .c_path = "benchmarks/compare/lowlevel_arena.c",
        .c_expected = "25000180000000\n",
    },
    .{
        .name = "string_passing",
        .nox_path = "benchmarks/compare/string_passing.nox",
        .nox_expected = "5000000\n",
        .py_path = "benchmarks/compare/string_passing.py",
        .py_expected = "5000000\n",
        .c_path = "benchmarks/compare/string_passing.c",
        .c_expected = "5000000\n",
    },
    .{
        .name = "deep_equality",
        .nox_path = "benchmarks/compare/deep_equality.nox",
        .nox_expected = "1000000\n",
        .py_path = "benchmarks/compare/deep_equality.py",
        .py_expected = "1000000\n",
        .c_path = "benchmarks/compare/deep_equality.c",
        .c_expected = "1000000\n",
    },
    .{
        .name = "list_class_field",
        .nox_path = "benchmarks/compare/list_class_field.nox",
        .nox_expected = "10800000\n",
        .py_path = "benchmarks/compare/list_class_field.py",
        .py_expected = "10800000\n",
        .c_path = "benchmarks/compare/list_class_field.c",
        .c_expected = "10800000\n",
    },
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buf);
    const out = &stdout_writer.interface;

    try out.writeAll("nox benchmark suite\n");
    try out.writeAll("====================\n");
    try out.writeAll(
        \\not: Debug modunda çalışma zamanı `std.heap.DebugAllocator` kullanır
        \\(sızıntı tespiti açık, ama yüksek hacimli tahsis/serbest bırakma
        \\döngülerinde YAPAY OLARAK YAVAŞ). `-Doptimize=ReleaseFast` ile
        \\derlenirse `std.heap.smp_allocator`a (üretim kalitesinde, sızıntı
        \\tespiti kapalı) geçilir — gerçekçi/karşılaştırmalı sayılar için bunu
        \\kullanın (bkz. runtime/alloc/asap.zig, nox-teknik-spesifikasyon.md).
        \\
        \\
    );
    try out.flush();

    try out.writeAll("-- Bölüm 1: stres testleri (yalnızca Nox, büyük N) --\n\n");
    try out.flush();

    var stress_pass: usize = 0;
    for (stress_benchmarks) |b| {
        if ((try runNoxOnce(gpa, io, out, b.name, b.path, b.expected, STRESS_REPEATS)) != null) stress_pass += 1;
    }
    try out.print("\n{d}/{d} stres testi başarıyla tamamlandı.\n\n", .{ stress_pass, stress_benchmarks.len });
    try out.flush();

    try out.writeAll("-- Bölüm 2: Python karşılaştırması (aynı algoritma, küçültülmüş N) --\n\n");
    try out.flush();

    const python_available = blk: {
        const r = std.process.run(gpa, io, .{ .argv = &.{ "python3", "--version" } }) catch break :blk false;
        defer gpa.free(r.stdout);
        defer gpa.free(r.stderr);
        break :blk r.term == .exited and r.term.exited == 0;
    };

    // `cc` teorik olarak HER ZAMAN mevcuttur (noxc'nin KENDİSİ zaten HER
    // derlemede `cc`ye bağımlı, bkz. main.zig) — ama YİNE DE Python'la AYNI
    // "sessizce atla" hassasiyetiyle KONTROL edilir (ör. `cc` PATH'ten
    // ÇIKARILMIŞ bir CI ortamı gibi beklenmedik durumlar İÇİN).
    const cc_available = blk: {
        const r = std.process.run(gpa, io, .{ .argv = &.{ "cc", "--version" } }) catch break :blk false;
        defer gpa.free(r.stdout);
        defer gpa.free(r.stderr);
        break :blk r.term == .exited and r.term.exited == 0;
    };

    if (!python_available and !cc_available) {
        try out.writeAll("python3 VE cc bulunamadı — karşılaştırma bölümü atlanıyor.\n");
        try out.flush();
        try out.print("\nToplam: {d}/{d} stres testi geçti.\n", .{ stress_pass, stress_benchmarks.len });
        try out.flush();
        if (stress_pass != stress_benchmarks.len) std.process.exit(1);
        return;
    }
    if (!python_available) try out.writeAll("not: python3 bulunamadı — yalnızca C karşılaştırması yapılacak.\n\n");
    if (!cc_available) try out.writeAll("not: cc bulunamadı — yalnızca Python karşılaştırması yapılacak.\n\n");
    try out.flush();

    var compare_pass: usize = 0;
    for (compare_pairs) |p| {
        try out.print("[{s}]\n", .{p.name});
        try out.flush();

        const nox_ms = (try runNoxOnce(gpa, io, out, "  nox", p.nox_path, p.nox_expected, COMPARE_REPEATS)) orelse {
            try out.flush();
            continue;
        };

        var pair_ok = true;
        var py_ms: ?f64 = null;
        var c_ms: ?f64 = null;

        if (python_available) {
            const py_check = try std.process.run(gpa, io, .{ .argv = &.{ "python3", p.py_path } });
            defer gpa.free(py_check.stdout);
            defer gpa.free(py_check.stderr);
            if (py_check.term != .exited or py_check.term.exited != 0) {
                try out.print("  python  ÇALIŞTIRMA BAŞARISIZ\n", .{});
                pair_ok = false;
            } else if (!std.mem.eql(u8, py_check.stdout, p.py_expected)) {
                try out.print("  python  BAŞARISIZ: beklenmeyen çıktı: {s} (beklenen: {s})\n", .{ py_check.stdout, p.py_expected });
                pair_ok = false;
            } else {
                const ms = try timeRuns(gpa, io, &.{ "python3", p.py_path }, COMPARE_REPEATS);
                try out.print("  python  min={d:.1}ms  ({d} koşu)\n", .{ ms, COMPARE_REPEATS });
                py_ms = ms;
            }
        }

        if (cc_available) {
            c_ms = try runCOnce(gpa, io, out, p.c_path, p.c_expected, COMPARE_REPEATS);
            if (c_ms == null) pair_ok = false;
        }

        try out.flush();
        if (!pair_ok) continue;

        if (py_ms) |ms| try out.print("  hızlanma (nox / python): {d:.1}x\n", .{ms / nox_ms});
        // C, python'ın AKSİNE beklenen YÖNÜ TERSTİR (nox genelde C'DEN
        // yavaştır, C'den DEĞİL) — bu yüzden "hızlanma" YERİNE "yavaşlama"
        // (nox_ms / c_ms, tipik olarak >1) etiketiyle raporlanır, ki
        // okuyucu yanlışlıkla "nox C'den X kat HIZLI" diye OKUMASIN.
        if (c_ms) |ms| try out.print("  yavaşlama (nox / c): {d:.2}x\n", .{nox_ms / ms});
        try out.writeAll("\n");
        try out.flush();
        compare_pass += 1;
    }

    try out.print("{d}/{d} karşılaştırma çifti başarıyla tamamlandı.\n", .{ compare_pass, compare_pairs.len });
    try out.print("\nToplam: {d}/{d} stres testi, {d}/{d} karşılaştırma çifti geçti.\n", .{
        stress_pass,  stress_benchmarks.len,
        compare_pass, compare_pairs.len,
    });
    try out.flush();

    if (stress_pass != stress_benchmarks.len or compare_pass != compare_pairs.len) std.process.exit(1);
}

/// Bir `.nox` dosyasını derler, BİR KEZ çalıştırıp çıktı/stderr'i doğrular,
/// sonra `repeats` kez daha çalıştırıp en iyi (min) süreyi ms cinsinden
/// döner. Doğrulama başarısız olursa `null` döner (çağıran bunu "atla"
/// olarak yorumlar).
fn runNoxOnce(
    gpa: std.mem.Allocator,
    io: std.Io,
    out: *std.Io.Writer,
    label: []const u8,
    nox_path: []const u8,
    expected: []const u8,
    repeats: usize,
) !?f64 {
    try out.print("  [{s}] derleniyor...\n", .{label});
    try out.flush();

    const compile_result = try std.process.run(gpa, io, .{
        .argv = &.{ "zig-out/bin/noxc", nox_path },
    });
    defer gpa.free(compile_result.stdout);
    defer gpa.free(compile_result.stderr);
    if (compile_result.term != .exited or compile_result.term.exited != 0) {
        try out.print("  DERLEME BAŞARISIZ:\n{s}\n", .{compile_result.stderr});
        return null;
    }

    const bin_path = stemOf(nox_path);

    // Doğrulama koşusu: çıktı beklenenle eşleşmeli, stderr BOŞ olmalı (nox
    // runtime Debug modunda bir sızıntı algılarsa stderr'e yazar — bkz.
    // runtime/alloc/asap.zig; Release modlarında bu kontrol devre dışıdır).
    const check_result = try std.process.run(gpa, io, .{ .argv = &.{bin_path} });
    defer gpa.free(check_result.stdout);
    defer gpa.free(check_result.stderr);

    if (check_result.term != .exited or check_result.term.exited != 0) {
        try out.print("  ÇALIŞTIRMA BAŞARISIZ (çıkış kodu)\n", .{});
        return null;
    }
    if (check_result.stderr.len != 0) {
        try out.print("  BAŞARISIZ: stderr'e yazıldı (olası sızıntı):\n{s}\n", .{check_result.stderr});
        return null;
    }
    if (!std.mem.eql(u8, check_result.stdout, expected)) {
        try out.print("  BAŞARISIZ: beklenmeyen çıktı: {s} (beklenen: {s})\n", .{ check_result.stdout, expected });
        return null;
    }

    const min_ms = try timeRuns(gpa, io, &.{bin_path}, repeats);
    try out.print("  OK  min={d:.1}ms  ({d} koşu)\n", .{ min_ms, repeats });
    return min_ms;
}

/// Bir `.c` dosyasını `cc -O2` ile derler (nox'un KENDİ `cc` çağrısıyla
/// AYNI derleyici, ama `noxc`nin AKSİNE burada `-O2` VERİLİR — bkz. bu
/// dosyanın en üstündeki `ComparePair` belge notu, "neden -O2" gerekçesi:
/// hiçbir gerçek dünya C karşılaştırması `-O0` ile yapılmaz, bu yüzden
/// C'ye kendi olağan/beklenen optimizasyon seviyesi TANINIR), BİR KEZ
/// çalıştırıp çıktıyı doğrular, sonra `repeats` kez daha çalıştırıp en
/// iyi (min) süreyi ms cinsinden döner. Doğrulama başarısız olursa `null`
/// döner (çağıran bunu "atla" olarak yorumlar) — `runNoxOnce` İLE AYNI
/// sözleşme, yalnızca derleme komutu (`cc -O2` vs `noxc`) FARKLI.
fn runCOnce(
    gpa: std.mem.Allocator,
    io: std.Io,
    out: *std.Io.Writer,
    c_path: []const u8,
    expected: []const u8,
    repeats: usize,
) !?f64 {
    const bin_path = try std.fmt.allocPrint(gpa, "{s}_c", .{c_path[0 .. c_path.len - 2]});
    defer gpa.free(bin_path);

    const compile_result = try std.process.run(gpa, io, .{
        .argv = &.{ "cc", "-O2", "-o", bin_path, c_path },
    });
    defer gpa.free(compile_result.stdout);
    defer gpa.free(compile_result.stderr);
    if (compile_result.term != .exited or compile_result.term.exited != 0) {
        try out.print("  c  DERLEME BAŞARISIZ:\n{s}\n", .{compile_result.stderr});
        return null;
    }

    const check_result = try std.process.run(gpa, io, .{ .argv = &.{bin_path} });
    defer gpa.free(check_result.stdout);
    defer gpa.free(check_result.stderr);

    if (check_result.term != .exited or check_result.term.exited != 0) {
        try out.print("  c  ÇALIŞTIRMA BAŞARISIZ (çıkış kodu)\n", .{});
        return null;
    }
    if (!std.mem.eql(u8, check_result.stdout, expected)) {
        try out.print("  c  BAŞARISIZ: beklenmeyen çıktı: {s} (beklenen: {s})\n", .{ check_result.stdout, expected });
        return null;
    }

    const min_ms = try timeRuns(gpa, io, &.{bin_path}, repeats);
    try out.print("  c       min={d:.1}ms  ({d} koşu)\n", .{ min_ms, repeats });
    return min_ms;
}

/// `argv`yi `repeats` kez çalıştırır, en iyi (min) süreyi milisaniye
/// cinsinden döner.
fn timeRuns(gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8, repeats: usize) !f64 {
    var best_ns: i96 = std.math.maxInt(i96);
    for (0..repeats) |_| {
        const start = std.Io.Clock.Timestamp.now(io, .awake);
        const r = try std.process.run(gpa, io, .{ .argv = argv });
        const end = std.Io.Clock.Timestamp.now(io, .awake);
        gpa.free(r.stdout);
        gpa.free(r.stderr);
        const elapsed = start.durationTo(end).raw.nanoseconds;
        best_ns = @min(best_ns, elapsed);
    }
    return @as(f64, @floatFromInt(best_ns)) / 1_000_000.0;
}

fn stemOf(path: []const u8) []const u8 {
    if (std.mem.endsWith(u8, path, ".nox")) return path[0 .. path.len - 4];
    return path;
}
