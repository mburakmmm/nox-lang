const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ---- Faz 21: async çalışma zamanı çekirdeği (`runtime/async_rt`) ----
    //
    // nox-teknik-spesifikasyon.md §3.21: Go tarzı yığınlı (stackful) fiber
    // ilkeli — elle yazılmış montaj bağlam değişimi (Zig'in kendisi 0.11'den
    // beri dilde async/await İÇERMEDİĞİNDEN, ve `callconv(.naked)` Zig'de
    // normal çağrı sözdizimiyle ÇAĞRILAMADIĞINDAN). Faz R.2: aarch64 VE
    // x86-64 destekleniyor (bkz. fiber.zig'deki comptime denetim) — HANGİ
    // `.S` dosyasının derleneceği HEDEF'in `cpu.arch`ına göre SEÇİLİR.
    // `noxrt_mod`dan ÖNCE tanımlanmalı ki hem gerçek `noxrt.o`ya (aşama 4'ten
    // beri `runtime/async_rt/bridge.zig` üzerinden) HEM standalone
    // fiber/scheduler/channel testlerine bağlanabilsin.
    //
    // Faz R.1: dosyalar `.S` (BÜYÜK harf) uzantısına sahiptir ki `cc` onları
    // C ÖN İŞLEMCİSİNDEN geçirsin (`SYM(...)` makrosu Mach-O/ELF sembol
    // adlandırma FARKINI çözer, bkz. dosyaların KENDİ belge notu) — macOS/
    // Linux AYNI kaynaktan doğru sembol adıyla derlenir.
    //
    // **Bilinçli sınırlama (Faz R.3'e bırakıldı):** `cc` burada HER ZAMAN
    // HOST derleyicisidir — `-Dtarget` ile ÇAPRAZ derleme yapılırken bu
    // adım HÂLÂ host'un KENDİ mimarisi İÇİN derler (`zig cc -target ...`e
    // geçiş, GERÇEK çapraz derleme desteği İÇİN, Faz R.3'ün kapsamıdır).
    const swap_asm_arch: enum { aarch64, x86_64 } = switch (target.result.cpu.arch) {
        .aarch64 => .aarch64,
        .x86_64 => .x86_64,
        else => @panic("runtime/async_rt şu an yalnızca aarch64/x86-64 hedeflerini destekler"),
    };
    const swap_asm_src, const swap_asm_o_path = switch (swap_asm_arch) {
        .aarch64 => .{ "runtime/async_rt/swap_aarch64.S", "runtime/async_rt/swap_aarch64.o" },
        .x86_64 => .{ "runtime/async_rt/swap_x86_64.S", "runtime/async_rt/swap_x86_64.o" },
    };
    const compile_swap_asm = b.addSystemCommand(&.{
        "cc", "-c", "-o", swap_asm_o_path, swap_asm_src,
    });

    const nox_mod = b.addModule("nox", .{
        .root_source_file = b.path("compiler/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    const noxc_mod = b.createModule(.{
        .root_source_file = b.path("compiler/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const noxc = b.addExecutable(.{
        .name = "noxc",
        .root_module = noxc_mod,
    });
    const install_noxc = b.addInstallArtifact(noxc, .{});
    b.getInstallStep().dependOn(&install_noxc.step);

    // Faz 12/13'ün köprüleri (Faz 14'ten beri `noxrt_mod`ün BİR PARÇASI —
    // bkz. runtime/foreign_bridge.zig, `nox_hpy_call`/`nox_wasm_call`); bu
    // yüzden `noxrt_mod`dan ÖNCE tanımlanmalılar ki ona named import olarak
    // verilebilsinler.
    const hpy_bridge_mod = b.addModule("hpy_bridge", .{
        .root_source_file = b.path("runtime/hpy_bridge/lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    const wasm_bridge_mod = b.addModule("wasm_bridge", .{
        .root_source_file = b.path("runtime/wasm_bridge/lib.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "hpy_bridge", .module = hpy_bridge_mod },
        },
    });

    const noxrt_mod = b.createModule(.{
        .root_source_file = b.path("runtime/lib.zig"),
        .target = target,
        .optimize = optimize,
        // Faz R.1: `runtime/`nin HER YERİNDE (async_rt, stdlib_shims, alloc)
        // `std.c.*` (soket/dosya sistemi ilkelleri, kqueue/epoll) KULLANILIYOR
        // — macOS'ta bu HER ZAMAN ÖRTÜK olarak çalışıyordu (Darwin ikilileri
        // libSystem'i KOŞULSUZ bağlar), ama Linux'ta `std.c.*` KULLANIMI
        // AÇIKÇA `link_libc` İSTEMEDEN "libc'ye bağımlılık AÇIKÇA belirtilmeli"
        // derleme hatası verir (bkz. Faz R.1'in Docker/aarch64-linux
        // doğrulaması sırasında keşfedilen gerçek hata).
        .link_libc = true,
        .imports = &.{
            .{ .name = "hpy_bridge", .module = hpy_bridge_mod },
            .{ .name = "wasm_bridge", .module = wasm_bridge_mod },
        },
    });
    // Faz 21: `runtime/async_rt/bridge.zig` (Faz 21 aşama 4, `runtime/lib.zig`
    // üzerinden `noxrt_mod`a bağlı), `fiber.zig` aracılığıyla AYNI
    // `nox_swap_context` sembolüne ihtiyaç duyar.
    noxrt_mod.addObjectFile(b.path(swap_asm_o_path));

    // Not: b.addLibrary(.static) burada bir .a arşivi üretiyor ama macOS'ta
    // bazı Zig sürümlerinde ar üyesi hizalama hatası veriyor (bkz. ld hatası:
    // "64-bit mach-o member not 8-byte aligned"). Tek bir çeviri birimi olan
    // bir runtime için doğrudan nesne dosyası üretmek daha güvenilir.
    const noxrt = b.addObject(.{
        .name = "noxrt",
        .root_module = noxrt_mod,
    });
    noxrt.step.dependOn(&compile_swap_asm.step);
    const install_noxrt = b.addInstallFile(noxrt.getEmittedBin(), "lib/noxrt.o");
    b.getInstallStep().dependOn(&install_noxrt.step);

    // Faz O §P.1: `noxc`nin proje kökü DIŞINDAN çalıştırılabilmesi İÇİN
    // `stdlib/` ağacı da (`noxrt.o` İLE AYNI kurulum kökü altına,
    // `compiler/project.zig`nin `ResourceDirs`i İLE EŞLEŞECEK şekilde)
    // kurulur (bkz. project.zig'in belge notu).
    const install_stdlib = b.addInstallDirectory(.{
        .source_dir = b.path("stdlib"),
        .install_dir = .lib,
        .install_subdir = "nox/stdlib",
    });
    b.getInstallStep().dependOn(&install_stdlib.step);

    const run_noxc = b.addRunArtifact(noxc);
    run_noxc.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_noxc.addArgs(args);
    const run_step = b.step("run", "noxc'yi çalıştır");
    run_step.dependOn(&run_noxc.step);

    // ---- Benchmark suite (bkz. benchmarks/run.zig) ----
    //
    // `noxc`/`noxrt.o` KENDİSİNİ derlemek için kullanır (yeni bir alt süreç
    // olarak `zig-out/bin/noxc`'yi çağırır), bu yüzden bu ikilinin önceden
    // kurulmuş olmasına bağımlıdır — proje kökünden çalıştırılmalıdır
    // (`.nox` dosya yolları ve `zig-out/...` yolları göreli).
    const noxbench_mod = b.createModule(.{
        .root_source_file = b.path("benchmarks/run.zig"),
        .target = target,
        .optimize = optimize,
    });
    const noxbench = b.addExecutable(.{
        .name = "noxbench",
        .root_module = noxbench_mod,
    });
    const run_noxbench = b.addRunArtifact(noxbench);
    run_noxbench.step.dependOn(b.getInstallStep());
    const bench_step = b.step("bench", "Nox benchmark takımını çalıştır");
    bench_step.dependOn(&run_noxbench.step);

    // ---- `nox.http.serve` verim (throughput) ölçümü (bkz. benchmarks/
    // http_bench.zig) — `noxbench`den AYRI bir adım: burada ölçülen şey tek
    // bir sürecin duvar-saati süresi DEĞİL, UZUN SÜRE çalışan bir sunucunun
    // GERÇEK eşzamanlı ağ isteklerini işleme HIZIdır ----
    const http_bench_mod = b.createModule(.{
        .root_source_file = b.path("benchmarks/http_bench.zig"),
        .target = target,
        .optimize = optimize,
    });
    const http_bench = b.addExecutable(.{
        .name = "noxhttpbench",
        .root_module = http_bench_mod,
    });
    const run_http_bench = b.addRunArtifact(http_bench);
    run_http_bench.step.dependOn(b.getInstallStep());
    const bench_http_step = b.step("bench-http", "nox.http.serve verim ölçümünü çalıştır");
    bench_http_step.dependOn(&run_http_bench.step);

    const test_step = b.step("test", "Tüm unit ve golden testleri çalıştır");
    // codegen golden testleri, üretilen binary'leri `zig-out/lib/noxrt.o`'ya
    // karşı linklemek için bu adımın önceden tamamlanmış olmasına ihtiyaç duyar.
    test_step.dependOn(&install_noxrt.step);
    // Faz R.3 (bkz. docs/uretim-hazirlik-analizi.md): `install_stdlib`
    // ÖNCEDEN yalnızca `b.getInstallStep()`e (varsayılan `zig build` hedefi)
    // bağlıydı, `test_step`e DEĞİL — `zig build test`, `zig-out/lib/nox/
    // stdlib/`nin `zig-out`u TAMAMEN silmeden ÖNCEKİ bir `zig build`
    // çalışmasından KALMA olmasına SESSİZCE güveniyordu (GERÇEK bir hata,
    // temiz bir `zig-out` üzerinde `zig build test` doğrudan çalıştırıldığında
    // `stdlib/nox/core.nox: FileNotFound` ile ORTAYA ÇIKAR — Faz R.3'ün
    // Docker doğrulaması SIRASINDA GERÇEKTEN yakalandı).
    test_step.dependOn(&install_stdlib.step);
    // Faz O §P.2: `tests/cli/subcommand_test.zig`, kurulu `zig-out/bin/noxc`yi
    // BİR ALT SÜREÇ olarak çalıştırıyor — `test_step`in bu adıma da bağımlı
    // olması GEREKİR, aksi halde `zig build test` `noxc`yi YENİDEN KURMADAN
    // (mevcut/eski bir ikiliye karşı) çalışabilir, bu da CLI'deki GERÇEK bir
    // regresyonu SESSİZCE KAÇIRABİLİR (bu eksiklik, tam da bu senaryoyu
    // sınayan bir kasıtlı-boz-restore ile keşfedildi).
    test_step.dependOn(&install_noxc.step);

    // "nox" modülünün kendi içindeki (lexer/parser dosyalarına gömülü) testler.
    const lib_test = b.addTest(.{ .root_module = nox_mod });
    test_step.dependOn(&b.addRunArtifact(lib_test).step);

    // Zig runtime'ının kendi içindeki testler (bkz. runtime/alloc/asap.zig).
    const noxrt_test = b.addTest(.{ .root_module = noxrt_mod });
    noxrt_test.step.dependOn(&compile_swap_asm.step);
    test_step.dependOn(&b.addRunArtifact(noxrt_test).step);

    // "nox" modülünü dışarıdan tüketen ayrı test dosyaları (tests/unit, tests/golden).
    const external_test_files = [_][]const u8{
        "tests/unit/lexer_test.zig",
        "tests/unit/parser_test.zig",
        "tests/unit/project_test.zig",
        "tests/unit/test_runner_test.zig",
        "tests/unit/fetch_test.zig",
        "tests/cli/subcommand_test.zig",
        "tests/cli/package_resolution_test.zig",
        "tests/golden/golden_test.zig",
        "tests/golden/typecheck_golden_test.zig",
        "tests/golden/ownership_golden_test.zig",
    };

    for (external_test_files) |path| {
        const mod = b.createModule(.{
            .root_source_file = b.path(path),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "nox", .module = nox_mod },
            },
        });
        const t = b.addTest(.{ .root_module = mod });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }

    // `codegen_golden_test.zig` ayrıca (Faz 14'ten beri) `hpy_call`/
    // `wasm_call` golden testleri içerir — bunlar aşağıda tanımlanan
    // `compile_ext`/`compile_wasm` adımlarının ÖNCEDEN tamamlanmış olmasını
    // gerektirir (gerçek `.so`/`.wasm` fixture'ları diske yazılmalı). Bu
    // yüzden generic döngünün dışında, çalıştırma adımını daha sonra
    // bağımlılık ekleyebilmek için ayrıca tutuyoruz.
    const codegen_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/golden/codegen_golden_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "nox", .module = nox_mod },
        },
    });
    const codegen_test = b.addTest(.{ .root_module = codegen_test_mod });
    const codegen_test_run = b.addRunArtifact(codegen_test);
    test_step.dependOn(&codegen_test_run.step);

    // ---- Faz 12: HPy köprüsü (Tier 0) uyumluluk testi ----
    //
    // AGENTS.md §10/§13: her Tier 0/1 eklemesi GERÇEK bir C eklentisiyle
    // doğrulanmalıdır. `tests/compat/hpy_ext/noxtest.c`, gerçek HPy
    // header'larına karşı derlenmiş, bağımsız bir paylaşımlı kütüphanedir.
    // Bu, `.hpy-venv` (bkz. nox-teknik-spesifikasyon.md §3.12, kurulum
    // notu — `python3 -m venv .hpy-venv && .hpy-venv/bin/pip install hpy`)
    // önceden oluşturulmuş olmasını gerektirir; yoksa bu test adımı
    // (yalnızca bu adım) sessizce atlanır, ana test takımı etkilenmez.
    const hpy_bridge_test = b.addTest(.{ .root_module = hpy_bridge_mod });
    test_step.dependOn(&b.addRunArtifact(hpy_bridge_test).step);

    const io = b.graph.io;
    if (b.build_root.handle.access(io, ".hpy-venv/lib", .{})) |_| {
        var venv_lib_dir = b.build_root.handle.openDir(io, ".hpy-venv/lib", .{ .iterate = true }) catch unreachable;
        defer venv_lib_dir.close(io);
        var it = venv_lib_dir.iterate();
        const python_dir_name = blk: {
            while (it.next(io) catch unreachable) |entry| {
                if (entry.kind == .directory and std.mem.startsWith(u8, entry.name, "python3")) {
                    break :blk b.dupe(entry.name);
                }
            }
            break :blk null;
        };
        if (python_dir_name) |py_dir| {
            const hpy_include = b.fmt(".hpy-venv/lib/{s}/site-packages/hpy/devel/include", .{py_dir});

            const so_path = "tests/compat/hpy_ext/noxtest.so";
            const compile_ext = b.addSystemCommand(&.{
                "cc",                             "-DHPY_ABI_UNIVERSAL",
                "-I",                             hpy_include,
                "-shared",                        "-fPIC",
                "-o",                             so_path,
                "tests/compat/hpy_ext/noxtest.c",
            });

            const build_options = b.addOptions();
            build_options.addOption([]const u8, "noxtest_so_path", b.pathFromRoot(so_path));

            const compat_mod = b.createModule(.{
                .root_source_file = b.path("tests/compat/hpy_tier0_test.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "hpy_bridge", .module = hpy_bridge_mod },
                    .{ .name = "build_options", .module = build_options.createModule() },
                },
            });
            const compat_test = b.addTest(.{ .root_module = compat_mod });
            compat_test.step.dependOn(&compile_ext.step);
            test_step.dependOn(&b.addRunArtifact(compat_test).step);

            // Faz 14: `hpy_call` yerleşiğinin gerçek bir .nox programından
            // GERÇEK bir HPy eklentisini çağırdığını doğrulayan golden test.
            // `codegen_golden_test.zig`e (her zaman çalışan ana takıma)
            // KASITLI OLARAK eklenmedi — bu, HPy venv'i kurulu olmayanlarda
            // ana takımı kırardı (bkz. Faz 12'nin "sessizce atlanır" ilkesi).
            // Bunun yerine, `noxtest.so` derlendiğinde ayrı ve koşullu
            // olarak eklenir.
            const hpy_call_golden_mod = b.createModule(.{
                .root_source_file = b.path("tests/compat/hpy_call_golden_test.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "nox", .module = nox_mod },
                },
            });
            const hpy_call_golden_test = b.addTest(.{ .root_module = hpy_call_golden_mod });
            hpy_call_golden_test.step.dependOn(&compile_ext.step);
            hpy_call_golden_test.step.dependOn(&install_noxrt.step);
            test_step.dependOn(&b.addRunArtifact(hpy_call_golden_test).step);
        }
    } else |_| {}

    // ---- Faz 13: WASM köprüsü uyumluluk testi ----
    //
    // AGENTS.md §11: gömülü WASM runtime seçimi olarak NATIF bir Zig
    // yorumlayıcısı seçildi (wasmtime/wasmer yerine) — bu, üçüncü bir yeni
    // sistem bağımlılığı eklemeden (QBE, HPy'den sonra) kendi kendine
    // yeten bir çözüm sağlar. Test fixture'ı, `zig`in KENDİSİYLE (zaten
    // zorunlu bir araç) `wasm32-freestanding` hedefine derlenmiş GERÇEK bir
    // `.wasm` ikilisidir — WABT/wasmtime gibi ek bir araç GEREKMEZ.
    const wasm_bridge_test = b.addTest(.{ .root_module = wasm_bridge_mod });
    test_step.dependOn(&b.addRunArtifact(wasm_bridge_test).step);

    const wasm_out_path = "tests/compat/wasm_ext/addone.wasm";
    const compile_wasm = b.addSystemCommand(&.{
        b.graph.zig_exe,
        "build-exe",
        "tests/compat/wasm_ext/addone.zig",
        "-target",
        "wasm32-freestanding",
        "-fno-entry",
        "--export=add_one",
        "--export=add_two",
        "-OReleaseSmall",
        b.fmt("-femit-bin={s}", .{wasm_out_path}),
    });

    // Faz 14: `codegen_golden_test.zig`deki `wasm_call` golden testi gerçek
    // `addone.wasm`ın önceden derlenmiş olmasını gerektirir.
    codegen_test_run.step.dependOn(&compile_wasm.step);

    const wasm_build_options = b.addOptions();
    wasm_build_options.addOption([]const u8, "addone_wasm_path", b.pathFromRoot(wasm_out_path));

    const wasm_compat_mod = b.createModule(.{
        .root_source_file = b.path("tests/compat/wasm_tier0_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "wasm_bridge", .module = wasm_bridge_mod },
            .{ .name = "hpy_bridge", .module = hpy_bridge_mod },
            .{ .name = "build_options", .module = wasm_build_options.createModule() },
        },
    });
    const wasm_compat_test = b.addTest(.{ .root_module = wasm_compat_mod });
    wasm_compat_test.step.dependOn(&compile_wasm.step);
    test_step.dependOn(&b.addRunArtifact(wasm_compat_test).step);

    // ---- Planlanan Faz 20: Zig/C ABI FFI (`extern def`) uyumluluk testi ----
    //
    // nox-teknik-spesifikasyon.md §3.20: HPy/WASM köprülerinden BAĞIMSIZ,
    // derleme/bağlama zamanında çözülen, kutulanmamış bir C ABI FFI'si.
    // Hem GERÇEK bir C dosyası (`cc -c`) HEM GERÇEK bir Zig dosyası (`zig
    // build-obj`, `export fn ... callconv(.c)`) ayrı ayrı nesne dosyalarına
    // derlenip AYNI mekanizmayla (`extern def ... from "<yol>"`) bağlanarak
    // test edilir — hiçbir YENİ sistem bağımlılığı gerekmez (`cc`/`zig`
    // zaten zorunlu), bu yüzden ana (koşulsuz) test takımında yer alır.
    const c_ext_o_path = "tests/compat/c_ext/mathutil.o";
    const compile_c_ext = b.addSystemCommand(&.{
        "cc", "-c", "-o", c_ext_o_path, "tests/compat/c_ext/mathutil.c",
    });

    // Faz 20'nin ikinci artımı (opak `ptr` tipi, bkz. nox-teknik-
    // spesifikasyon.md §3.20): `counter.c`, `FILE*`/`sqlite3*` gibi
    // handle-tabanlı GERÇEK bir C API desenini örnekler — AYNI derleme
    // deseniyle (`cc -c`) bağlanır.
    const counter_ext_o_path = "tests/compat/c_ext/counter.o";
    const compile_counter_ext = b.addSystemCommand(&.{
        "cc", "-c", "-o", counter_ext_o_path, "tests/compat/c_ext/counter.c",
    });

    const zig_ext_o_path = "tests/compat/zig_ext/util.o";
    const compile_zig_ext = b.addSystemCommand(&.{
        b.graph.zig_exe,
        "build-obj",
        "tests/compat/zig_ext/util.zig",
        b.fmt("-femit-bin={s}", .{zig_ext_o_path}),
    });

    const ffi_build_options = b.addOptions();
    ffi_build_options.addOption([]const u8, "mathutil_o_path", b.pathFromRoot(c_ext_o_path));
    ffi_build_options.addOption([]const u8, "util_o_path", b.pathFromRoot(zig_ext_o_path));
    ffi_build_options.addOption([]const u8, "counter_o_path", b.pathFromRoot(counter_ext_o_path));

    const ffi_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/compat/extern_ffi_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "nox", .module = nox_mod },
            .{ .name = "build_options", .module = ffi_build_options.createModule() },
        },
    });
    const ffi_test = b.addTest(.{ .root_module = ffi_test_mod });
    ffi_test.step.dependOn(&compile_c_ext.step);
    ffi_test.step.dependOn(&compile_zig_ext.step);
    ffi_test.step.dependOn(&compile_counter_ext.step);
    ffi_test.step.dependOn(&install_noxrt.step);
    test_step.dependOn(&b.addRunArtifact(ffi_test).step);

    // ---- Stdlib fazı §D.1.5: `stdlib/nox/http.nox` uçtan uca golden
    // testleri — yalnızca `zig-out/lib/noxrt.o`ya ihtiyaç duyar (EK bir
    // ayrı .o GEREKMEZ, `nox_http_*` sembolleri ZATEN `runtime/lib.zig`
    // üzerinden `noxrt.o`ya dahil) ----
    const http_stdlib_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/compat/http_stdlib_golden_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "nox", .module = nox_mod },
        },
    });
    const http_stdlib_test = b.addTest(.{ .root_module = http_stdlib_test_mod });
    http_stdlib_test.step.dependOn(&install_noxrt.step);
    test_step.dependOn(&b.addRunArtifact(http_stdlib_test).step);

    // ---- Stdlib fazı §D.1.6: `nox.http.serve` özel yerleşiğinin uçtan uca
    // golden testi — `http_stdlib_test` İLE AYNI bağımlılık (yalnızca
    // `zig-out/lib/noxrt.o`), AYRI bir dosya (bkz. http_serve_golden_test.zig'in
    // modül üstü notu: `std.process.spawn` ile ARKA PLANDA çalıştırılan bir
    // ikili + eşzamanlı istemci soketleri gerektirdiğinden `http_stdlib_test`in
    // `compileAndRun`ından FARKLI bir çalıştırma modeli kullanır) ----
    const http_serve_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/compat/http_serve_golden_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "nox", .module = nox_mod },
        },
    });
    const http_serve_test = b.addTest(.{ .root_module = http_serve_test_mod });
    http_serve_test.step.dependOn(&install_noxrt.step);
    test_step.dependOn(&b.addRunArtifact(http_serve_test).step);

    // ---- Faz 21 standalone testleri (`runtime/async_rt`, `noxrt.o`dan
    // BAĞIMSIZ doğrulama — bkz. bu dosyanın başındaki `compile_swap_asm`) ----
    const fiber_test_mod = b.createModule(.{
        .root_source_file = b.path("runtime/async_rt/fiber.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    fiber_test_mod.addObjectFile(b.path(swap_asm_o_path));
    const fiber_test = b.addTest(.{ .root_module = fiber_test_mod });
    fiber_test.step.dependOn(&compile_swap_asm.step);
    test_step.dependOn(&b.addRunArtifact(fiber_test).step);

    // ---- Planlanan Faz 21, aşama 2: zamanlayıcı + Task[T] ----
    //
    // `scheduler.zig`, `fiber.zig`yi içe aktardığından (transitively) AYNI
    // `nox_swap_context` sembolüne ihtiyaç duyar — aynı derlenmiş nesne
    // dosyası burada da bağlanır.
    const scheduler_test_mod = b.createModule(.{
        .root_source_file = b.path("runtime/async_rt/scheduler.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    scheduler_test_mod.addObjectFile(b.path(swap_asm_o_path));
    const scheduler_test = b.addTest(.{ .root_module = scheduler_test_mod });
    scheduler_test.step.dependOn(&compile_swap_asm.step);
    test_step.dependOn(&b.addRunArtifact(scheduler_test).step);

    // ---- Planlanan Faz 21, aşama 3: Channel[T] + deadlock tespiti ----
    const channel_test_mod = b.createModule(.{
        .root_source_file = b.path("runtime/async_rt/channel.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    channel_test_mod.addObjectFile(b.path(swap_asm_o_path));
    const channel_test = b.addTest(.{ .root_module = channel_test_mod });
    channel_test.step.dependOn(&compile_swap_asm.step);
    test_step.dependOn(&b.addRunArtifact(channel_test).step);

    // ---- D.0: Async I/O reaktörü (kqueue) + non-blocking soket ilkelleri
    // (bkz. nox-teknik-spesifikasyon.md §3.29) — `io.zig`, `scheduler.zig`
    // (dolayısıyla `fiber.zig`) aracılığıyla AYNI `nox_swap_context`e
    // ihtiyaç duyar. `io_reactor.zig`nin KENDİ testleri `scheduler_test`
    // (yukarı, transitif import yoluyla) TARAFINDAN ZATEN çalıştırılıyor —
    // burada YALNIZCA `io.zig`nin KENDİ (henüz başka hiçbir dosya tarafından
    // içe aktarılmayan) testleri için ayrı bir hedef gerekir.
    const io_test_mod = b.createModule(.{
        .root_source_file = b.path("runtime/async_rt/io.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    io_test_mod.addObjectFile(b.path(swap_asm_o_path));
    const io_test = b.addTest(.{ .root_module = io_test_mod });
    io_test.step.dependOn(&compile_swap_asm.step);
    test_step.dependOn(&b.addRunArtifact(io_test).step);
}
