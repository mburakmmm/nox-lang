const std = @import("std");
const builtin = @import("builtin");

/// Faz R.4 (bkz. docs/uretim-hazirlik-analizi.md): `build.zig.zon`nin
/// `minimum_zig_version`i Zig'in KENDİ araç zincirinin uyguladığı bir
/// TABANDIR (daha ESKİ bir derleyiciyi REDDEDER) — ama DAHA YENİ bir
/// derleyiciyi ASLA reddetmez. Zig HENÜZ 1.0 ÖNCESİ olduğundan (sık sık
/// KIRICI değişiklikler), "en az bu sürüm" TEK BAŞINA yeterli bir
/// tekrarlanabilirlik garantisi DEĞİLDİR — bu proje TAM OLARAK bu sürümle
/// geliştirilip doğrulanmıştır (bkz. `.github/workflows/ci.yml`nin AYNI
/// `version: "0.16.0"` PİNİ). Bu sabit, GERÇEK derleyici sürümüyle
/// (`builtin.zig_version`) AŞAĞIDA KARŞILAŞTIRILIR — EŞLEŞMEZSE (daha ESKİ
/// YA DA daha YENİ FARK ETMEZ) net bir UYARI basılır (KOŞULSUZ bir
/// `@compileError` DEĞİL — bir sonraki Zig sürümüne GEÇİŞ SIRASINDA
/// projenin build.zig.zon'daki `minimum_zig_version`i GÜNCELLEMEDEN bu
/// sabiti de GÜNCELLEMESİ gerektiğini HATIRLATAN, ama geliştiriciyi
/// TAMAMEN ENGELLEMEYEN bir denetim — sert bir hata DEĞİL, ÇÜNKÜ yama
/// sürümleri (ör. 0.16.1) çoğunlukla GERİYE UYUMLUDUR).
const EXPECTED_ZIG_VERSION = std.SemanticVersion{ .major = 0, .minor = 16, .patch = 0 };

/// Faz HH.4 (bkz. nox-teknik-spesifikasyon.md, "build artifact izolasyonu"):
/// `-Doptimize` moduna göre dosya-sistemi-güvenli bir etiket — `zig-out/
/// <slug>/` altında HER modun KENDİ, izole kaynak-kökünü adlandırmak İçİn
/// (bkz. `pub fn build`in `install_*_tagged` adımları).
fn optimizeModeSlug(mode: std.builtin.OptimizeMode) []const u8 {
    return switch (mode) {
        .Debug => "debug",
        .ReleaseSafe => "release-safe",
        .ReleaseFast => "release-fast",
        .ReleaseSmall => "release-small",
    };
}

pub fn build(b: *std.Build) void {
    if (builtin.zig_version.order(EXPECTED_ZIG_VERSION) != .eq) {
        std.debug.print(
            "UYARI: bu proje Zig {f} ile geliştirilip doğrulandı, ama şu an Zig {f} ile derleniyorsunuz. " ++
                "Zig henüz 1.0 öncesi olduğundan sürüm farkları beklenmeyen derleme/çalışma zamanı hatalarına yol açabilir " ++
                "(bkz. nox-teknik-spesifikasyon.md §3.11, Faz R.4). Devam ediliyor...\n",
            .{ EXPECTED_ZIG_VERSION, builtin.zig_version },
        );
    }

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Faz F.1 (bkz. plan dosyası "Cross-compile İSKELETİ"): Windows'un
    // KENDİ, ZATEN kanıtlanmış `target.result.os.tag == .windows` deseniyle
    // PARALEL bir kontrol — SADECE İSKELET (link_libc/HPy-WASM hariç tutma),
    // `noxrt_mod`nin KÖK dosyası BU turda HÂLÂ `runtime/lib.zig`DİR (`lib_
    // freestanding.zig` HENÜZ YOK — fiber.zig/self_pipe.zig'in OS-fallback
    // kodu comptime-gate'lenmediğinden, freestanding hedefte `noxrt_mod`
    // HÂLÂ BAŞARISIZ olur, bu BEKLENEN/belgelenmiş bir durumdur, bkz.
    // nox-teknik-spesifikasyon.md §3.167).
    const is_freestanding = target.result.os.tag == .freestanding or target.result.os.tag == .other;

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
    // Faz R.3+F.1 tamamlama (bkz. plan dosyası "Faz R.3 + F.1'in
    // tamamlanması"): `is_freestanding` İKEN (top-level `-Dtarget`
    // freestanding bir OS'a işaret ediyorsa) HOST `cc` YERİNE `zig cc
    // -target <arch>-freestanding-none` — `tests/golden/
    // freestanding_link_test.zig`nin (Faz F.1) ZATEN kanıtladığı, TEK
    // linker sürücüsü macOS'un native `ld`sinin ELF nesnelerini
    // işleyemediği İçİn (`compile_swap_asm_freestanding`, aşağıda, AYNI
    // çağrı şeklini KULLANIR). Hosted derlemede (`is_freestanding ==
    // false`, EZİCİ ÇOĞUNLUK) bu dal HİÇ tetiklenmez — SIFIR davranış
    // değişikliği.
    const compile_swap_asm = if (is_freestanding) b.addSystemCommand(&.{
        b.graph.zig_exe, "cc",
        "-target", b.fmt("{s}-freestanding-none", .{@tagName(target.result.cpu.arch)}),
        "-c", "-o", swap_asm_o_path, swap_asm_src,
    }) else b.addSystemCommand(&.{
        "cc", "-c", "-o", swap_asm_o_path, swap_asm_src,
    });

    // Faz P1.2: derleyici (`nox_mod`) VE çalışma zamanı (`noxrt_mod`) İKİ
    // BAĞIMSIZ Zig modülü olduğundan (aşağıda), ABI/bellek-düzeni
    // sabitlerinin (`LIST_HEADER_SIZE`/`TAG_SIZE`/`ARC_HEADER_SIZE`/vb.)
    // TEK doğruluk kaynağı olması İçin ÜÇÜNCÜ, bağımsız bir yaprak modül —
    // `hpy_bridge_mod`/`wasm_bridge_mod` İLE AYNI desen (aşağıda), HER İKİ
    // tarafa da named import olarak verilir. Hiçbir şey import ETMEZ (saf
    // sabitler) — bu yüzden `nox_mod`/`noxrt_mod`dan ÖNCE tanımlanabilir.
    const abi_layout_mod = b.addModule("abi_layout", .{
        .root_source_file = b.path("shared/abi_layout.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Faz F.0.3 (bkz. plan dosyası "Panik/tanı çıktısı enjeksiyonu"):
    // `abi_layout_mod` İLE AYNI gerekçe — `runtime/errors/diag_sink.zig`
    // (SIFIR bağımlılıklı, `runtime/`nin İÇİNDE yaşıyor OLSA da) `runtime/
    // async_rt/fiber.zig`/`io.zig`/`io_reactor.zig` TARAFINDAN import
    // ediliyor VE bu üç dosya, `noxrt_mod` (kökü `runtime/lib.zig`) DIŞINDA,
    // KENDİ BAŞLARINA AYRI modül kökleri OLARAK da derleniyor (`fiber_test_
    // mod`/`scheduler_test_mod`/`channel_test_mod`/`io_test_mod`, aşağıda —
    // kökleri `runtime/async_rt/`, `runtime/errors/`in BİR ÜST DİZİNİ) —
    // relative bir import (`../errors/diag_sink.zig`) bu YÜZDEN o AYRI
    // modül köklerinde SINIRI aşardı ("import of file outside module
    // path"). Named-module olarak PAYLAŞMAK bu sınırı ORTADAN KALDIRIR.
    const diag_sink_mod = b.addModule("diag_sink", .{
        .root_source_file = b.path("runtime/errors/diag_sink.zig"),
        .target = target,
        .optimize = optimize,
    });

    const nox_mod = b.addModule("nox", .{
        .root_source_file = b.path("compiler/lib.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "abi_layout", .module = abi_layout_mod },
        },
    });

    const noxc_mod = b.createModule(.{
        .root_source_file = b.path("compiler/main.zig"),
        .target = target,
        .optimize = optimize,
        // Faz F.4: `buildOne`nin `NOX_FREESTANDING_KERNEL_ARCH` dâhilî
        // kancası `std.c.getenv` KULLANIR — macOS'ta libSystem HER ZAMAN
        // ÖRTÜK olarak linklendiğinden BU sessizce çalışıyordu, AMA Linux'ta
        // (`zig build-exe`nin VARSAYILANI libc-SİZ) "dependency on libc must
        // be explicitly specified" İLE DERLEME hatasına yol AÇTI — GERÇEK
        // CI çalışmasıyla BULUNDU. `noxc` SIRADAN bir HOST CLI aracı
        // OLDUĞUNDAN (freestanding runtime İLE KARIŞTIRILMAMALI) libc'yi
        // AÇIKÇA istemek GÜVENLİ/standart bir çözümdür.
        .link_libc = true,
        // Faz P1.2: `noxc_mod`, `nox_mod`dan BAĞIMSIZ bir modül grafiğidir
        // (relative import'larla `compiler/`i KENDİ İÇİNDE yeniden derler,
        // bkz. bu dosyanın modül üstü notu) — bu yüzden `codegen_qbe/
        // types.zig`nin `@import("abi_layout")`sinin BURADA da AYRICA
        // sağlanması gerekir (`nox_mod`a eklemek YETERLİ DEĞİLDİR).
        .imports = &.{
            .{ .name = "abi_layout", .module = abi_layout_mod },
        },
    });

    // `noxc --version`/`noxc version` (bkz. `compiler/main.zig`nin `cmdVersion`ı)
    // İÇİN — `build.zig.zon`nin `version` alanı TEK doğruluk kaynağıdır,
    // BURADA yinelenmez (Zig'in build.zig'in KENDİ `build.zig.zon`sunu
    // comptime struct olarak `@import` edebilme desteği kullanılır).
    const build_zig_zon = @import("build.zig.zon");
    const version_options = b.addOptions();
    version_options.addOption([]const u8, "version", build_zig_zon.version);
    noxc_mod.addOptions("build_options", version_options);
    // `compiler/pkg/upgrade.zig` (bkz. `noxc upgrade`nin belge notu) `nox_mod`
    // (lib_test'in kökü, bkz. `compiler/lib.zig`) ÜZERİNDEN de erişildiği
    // İçin (birim testlerinin `currentVersionTag`/`isAlreadyUpToDate`yi
    // ÇAĞIRABİLMESİ İçin) AYNI `version_options` BURAYA da eklenir.
    nox_mod.addOptions("build_options", version_options);

    const noxc = b.addExecutable(.{
        .name = "noxc",
        .root_module = noxc_mod,
    });
    const install_noxc = b.addInstallArtifact(noxc, .{});
    b.getInstallStep().dependOn(&install_noxc.step);

    // Faz W.2: `noxlsp` — minimal LSP sunucusu (bkz. compiler/lsp_main.zig'in
    // modül üstü notu). `noxc_mod` İLE AYNI desen (kendi kök dosyası, relative
    // import'lar — `nox_mod`a İHTİYAÇ YOK, `main.zig` GİBİ `compiler/`
    // İÇİNDEN doğrudan lexer/parser/checker/module_loader/project'i import eder).
    const noxlsp_mod = b.createModule(.{
        .root_source_file = b.path("compiler/lsp_main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const noxlsp = b.addExecutable(.{
        .name = "noxlsp",
        .root_module = noxlsp_mod,
    });
    const install_noxlsp = b.addInstallArtifact(noxlsp, .{});
    b.getInstallStep().dependOn(&install_noxlsp.step);

    // Faz LL.1 (bkz. nox-teknik-spesifikasyon.md §3.71): `noxc`/`noxlsp`
    // HİÇBİR POSIX-özgü çağrı (`std.posix.*`/`std.c.*`) İÇERMEZ — runtime'ın
    // (`noxrt_mod`/`compile_swap_asm`, aşağıda) AKSİNE, Windows'ta İLKE
    // OLARAK derlenip çalışabilirler. Bu adım `noxrt`e (VE onun İÇİNDEN
    // `io_reactor.zig`nin şu anki macOS/Linux-only `@compileError`ına) HİÇ
    // DOKUNMADAN yalnızca derleyici ÖN-UCUNU (+ ÇALIŞMASI İÇİN gereken
    // `stdlib/`i — `noxc check`in KENDİSİ `core.nox`u module_loader
    // üzerinden ÇÖZER, bu YÜZDEN `install_stdlib`e de bağımlı; DAHA AŞAĞIDA
    // tanımlandığından burada YALNIZCA referans TUTULUR, bağımlılık asıl
    // `install_stdlib` tanımlandıktan SONRA eklenir) kurar — `.github/
    // workflows/ci.yml`nin `windows-frontend` işinin `zig build noxc` İLE
    // çağırdığı TAM OLARAK budur.
    const noxc_only_step = b.step("noxc", "Yalnızca noxc + noxlsp'yi (+ stdlib'i) derler (runtime'a bağımlı DEĞİL)");
    noxc_only_step.dependOn(&install_noxc.step);
    noxc_only_step.dependOn(&install_noxlsp.step);

    // Faz 12/13'ün köprüleri (Faz 14'ten beri `noxrt_mod`ün BİR PARÇASI —
    // bkz. runtime/foreign_bridge.zig, `nox_hpy_call`/`nox_wasm_call`); bu
    // yüzden `noxrt_mod`dan ÖNCE tanımlanmalılar ki ona named import olarak
    // verilebilsinler.
    // NOT: `hpy_bridge_mod`/`wasm_bridge_mod`, `noxrt_mod`a İTHAL EDİLDİĞİNDE
    // ONUN `.link_libc = true`SUNU (aşağıdaki Faz R.1 notu) MİRAS ALIYOR
    // GİBİ GÖRÜNSE de, KENDİ BAĞIMSIZ test hedefleri (`hpy_bridge_test`/
    // `wasm_bridge_test`, aşağıda) BU İKİ modülü KENDİ KÖK modülleri olarak
    // derliyor — bu YÜZDEN `link_libc` HER İKİSİNE de AYRICA (`noxrt_mod`dan
    // BAĞIMSIZ) tanımlı OLMALI. GERÇEK bir Linux CI çalıştırmasında BULUNDU:
    // `hpy_bridge/context.zig`nin `std.c.arc4random_buf` ÇAĞRISI (dict.zig'in
    // AYNI Faz LL.4 deseni) `link_libc` OLMADAN "dependency on libc must be
    // explicitly specified"/"type 'void' not a function" hatalarıyla
    // BAŞARISIZ oluyordu.
    const hpy_bridge_mod = b.addModule("hpy_bridge", .{
        .root_source_file = b.path("runtime/hpy_bridge/lib.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = !is_freestanding,
    });
    const wasm_bridge_mod = b.addModule("wasm_bridge", .{
        .root_source_file = b.path("runtime/wasm_bridge/lib.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = !is_freestanding,
        .imports = &.{
            .{ .name = "hpy_bridge", .module = hpy_bridge_mod },
        },
    });

    const noxrt_mod = b.createModule(.{
        // Faz F.0.7 (bkz. plan dosyası "Kritik düzeltme #3"in çözümü):
        // freestanding hedeflerde `runtime/lib_freestanding.zig` KÖK olarak
        // kullanılır (SADECE ARC/scheduler/dict/handle çekirdeği — bkz. onun
        // modül üstü notu) — hosted derlemeler `runtime/lib.zig`yi DEĞİŞMEDEN
        // kullanmaya DEVAM eder (SIFIR davranış değişikliği).
        .root_source_file = b.path(if (is_freestanding) "runtime/lib_freestanding.zig" else "runtime/lib.zig"),
        .target = target,
        .optimize = optimize,
        // Faz R.1: `runtime/`nin HER YERİNDE (async_rt, stdlib_shims, alloc)
        // `std.c.*` (soket/dosya sistemi ilkelleri, kqueue/epoll) KULLANILIYOR
        // — macOS'ta bu HER ZAMAN ÖRTÜK olarak çalışıyordu (Darwin ikilileri
        // libSystem'i KOŞULSUZ bağlar), ama Linux'ta `std.c.*` KULLANIMI
        // AÇIKÇA `link_libc` İSTEMEDEN "libc'ye bağımlılık AÇIKÇA belirtilmeli"
        // derleme hatası verir (bkz. Faz R.1'in Docker/aarch64-linux
        // doğrulaması sırasında keşfedilen gerçek hata). Faz F.1: freestanding
        // hedefte libc HİÇ YOK — `is_freestanding` İSE `false` (bkz. yukarıdaki
        // `is_freestanding` notu — bu SADECE `link_libc` YÜZÜNDEN ANLAMSIZ bir
        // hatayı ÖNLER, `noxrt_mod`nin KENDİSİ YİNE DE fiber.zig/self_pipe.zig'in
        // comptime-gate'lenmemiş OS-fallback kodu YÜZÜNDEN BAŞARISIZ OLUR).
        .link_libc = !is_freestanding,
        .imports = if (is_freestanding) &.{
            .{ .name = "abi_layout", .module = abi_layout_mod },
            .{ .name = "diag_sink", .module = diag_sink_mod },
        } else &.{
            .{ .name = "hpy_bridge", .module = hpy_bridge_mod },
            .{ .name = "wasm_bridge", .module = wasm_bridge_mod },
            .{ .name = "abi_layout", .module = abi_layout_mod },
            .{ .name = "diag_sink", .module = diag_sink_mod },
        },
    });
    // Faz 21: `runtime/async_rt/bridge.zig` (Faz 21 aşama 4, `runtime/lib.zig`
    // üzerinden `noxrt_mod`a bağlı), `fiber.zig` aracılığıyla AYNI
    // `nox_swap_context` sembolüne ihtiyaç duyar.
    //
    // Faz LL.6 (bkz. nox-teknik-spesifikasyon.md §3.71) — **GERÇEK bir Zig
    // derleyici hatası, elle YALITILMIŞ ve DOĞRULANMIŞ (macOS'ta, `zig
    // build-obj -target x86_64-windows-gnu` DOĞRUDAN çağrılarak):** `zig
    // build-obj`, COFF (Windows) hedefi İçİN, `addObjectFile` İLE eklenmiş
    // HAM bir nesne dosyası VARKEN, Zig'in KENDİ derlediği TÜM içeriği
    // SESSİZCE (hata VERMEDEN) atıp yalnızca O HAM dosyayı ÇIKTI olarak
    // veriyor (`noxrt.o` bu YÜZDEN 515 bayta — TEK `nox_swap_context`
    // sembolüne — düşüyordu; `use_llvm=true`/`link_gc_sections=false`
    // denemeleri BU YÜZDEN HİÇBİR ŞEYİ DEĞİŞTİRMEDİ, GERÇEK neden ne
    // ARKA UÇ ne de GC-sections'dı). **ELF/Mach-O'da bu hata YOK**
    // (macOS/Linux'ta `addObjectFile` + `build-obj` proje BOYUNCA binlerce
    // kez doğrulandı) — bu YÜZDEN çözüm YALNIZCA Windows'ta FARKLI bir yol
    // izlemek: `swap_asm.o`yu `noxrt.o`nun İÇİNE GÖMMEK YERİNE AYRI bir
    // dosya olarak kurup (`install_swap_asm`, aşağıda) NİHAİ `cc` bağlama
    // adımına (`compiler/main.zig`nin `cc_argv`ı) AYRI bir girdi olarak
    // vermek — tıpkı `noxrt.o`nun KENDİSİ gibi, sıradan bir statik bağlama.
    // (`fiber_test`/`scheduler_test`/`channel_test`/`io_test` — AŞAĞIDA,
    // KENDİ `addObjectFile` çağrılarıyla — Windows'ta ZATEN ÇALIŞIYOR
    // olması bu hatanın `build-obj`/`.kind == .obj`e ÖZGÜ olduğunu, `addTest`
    // gibi yürütülebilir ÜRETEN hedefleri ETKİLEMEDİĞİNİ DOĞRULAR.)
    if (target.result.os.tag != .windows) noxrt_mod.addObjectFile(b.path(swap_asm_o_path));

    // Not: b.addLibrary(.static) burada bir .a arşivi üretiyor ama macOS'ta
    // bazı Zig sürümlerinde ar üyesi hizalama hatası veriyor (bkz. ld hatası:
    // "64-bit mach-o member not 8-byte aligned"). Tek bir çeviri birimi olan
    // bir runtime için doğrudan nesne dosyası üretmek daha güvenilir.
    const noxrt = b.addObject(.{
        .name = "noxrt",
        .root_module = noxrt_mod,
    });
    // Faz FFI.3 (bkz. plan dosyası "-rdynamic'in dead-code-stripping'i
    // engellemesi"): GERÇEK bir Linux (aarch64 VE x86-64) CI koşusunda
    // BULUNAN bir ek boşluk — `Compile.link_function_sections`/`link_data_
    // sections`in VARSAYILANI `false` OLDUĞUNDAN, `noxrt.o` (ELF hedeflerinde)
    // TEK, MONOLİTİK bir `.text` bölümü OLARAK üretiliyordu (`readelf -SW`
    // İLE doğrulandı) — bu YÜZDEN linker'ın `--gc-sections`/`-dead_strip`ı
    // (`compiler/main.zig`nin `computeLinkerVisibilityArgs`ı) HİÇBİR ŞEYİ
    // silemiyordu (BÖLÜM-seviyesi granülerlik YOKTU). macOS'ta (Mach-O)
    // Zig ZATEN per-fonksiyon bölüm ÜRETİYOR (BU YÜZDEN macOS'ta `-dead_
    // strip` ÖNCEDEN ÖLÇÜLDÜĞÜ GİBİ ÇALIŞIYORDU) — ELF hedefleri İçİn BU
    // AÇIKÇA İSTENMELİDİR.
    noxrt.link_function_sections = true;
    noxrt.link_data_sections = true;
    noxrt.step.dependOn(&compile_swap_asm.step);
    const install_noxrt = b.addInstallFile(noxrt.getEmittedBin(), "lib/noxrt.o");
    b.getInstallStep().dependOn(&install_noxrt.step);

    // Faz LL.6: `swap_asm.o`nun Windows'taki AYRI kurulumu — bkz. yukarıdaki
    // belge notu. `compiler/project.zig`nin `ResourceDirs.swap_asm_path`ıyla
    // EŞLEŞİR.
    if (target.result.os.tag == .windows) {
        const install_swap_asm = b.addInstallFile(b.path(swap_asm_o_path), "lib/swap_asm.o");
        install_swap_asm.step.dependOn(&compile_swap_asm.step);
        b.getInstallStep().dependOn(&install_swap_asm.step);
    }

    // Faz R.3+F.1 tamamlama (bkz. plan dosyası "Faz R.3 + F.1'in
    // tamamlanması"): host'un KENDİ mimarisi + freestanding OS İçİn,
    // top-level `-Dtarget`DEN TAMAMEN BAĞIMSIZ, HER `zig build`/`zig build
    // test` çağrısında (host mimarisi + freestanding OS İçİn) ÇALIŞAN YENİ
    // bir ikinci derleme zinciri — F.0.7'nin SADECE ELLE `zig build-obj`
    // İLE doğrulanan çalışmasını KALICI bir regresyon KORUMASINA çevirir,
    // VE `noxc build --profile freestanding`nin GERÇEKTEN LİNKLEYECEĞİ
    // STABİL bir `noxrt-freestanding.o` SAĞLAR. (`noxrt_mod`/`noxc_mod`/
    // `noxlsp_mod`nin MEVCUT `target`i HİÇ DEĞİŞMEZ — BU zincir TAMAMEN
    // AYRI/PARALEL, SIFIR etkileşim.)
    const freestanding_target = b.resolveTargetQuery(.{
        .cpu_arch = b.graph.host.result.cpu.arch,
        .os_tag = .freestanding,
        .abi = .none,
    });
    const abi_layout_mod_fs = b.createModule(.{
        .root_source_file = b.path("shared/abi_layout.zig"),
        .target = freestanding_target,
        .optimize = optimize,
    });
    const diag_sink_mod_fs = b.createModule(.{
        .root_source_file = b.path("runtime/errors/diag_sink.zig"),
        .target = freestanding_target,
        .optimize = optimize,
    });
    const noxrt_freestanding_mod = b.createModule(.{
        .root_source_file = b.path("runtime/lib_freestanding.zig"),
        .target = freestanding_target,
        .optimize = optimize,
        .link_libc = false,
        .imports = &.{
            .{ .name = "abi_layout", .module = abi_layout_mod_fs },
            .{ .name = "diag_sink", .module = diag_sink_mod_fs },
        },
    });
    // `swap_asm_arch`in (yukarıda, TOP-LEVEL `-Dtarget`e bağlı) AYNI arch-
    // seçme deseni, AMA HOST mimarisi İçİn (BU zincir top-level target'tan
    // BAĞIMSIZ OLDUĞUNDAN) — `compile_swap_asm_freestanding`nin AYNI `zig
    // cc -target ...` deseni (`compile_swap_asm`nin `is_freestanding` dalı
    // İLE AYNI, YENİ bir mekanizma İCAT EDİLMEZ).
    const freestanding_swap_arch: enum { aarch64, x86_64 } = switch (b.graph.host.result.cpu.arch) {
        .aarch64 => .aarch64,
        .x86_64 => .x86_64,
        else => @panic("runtime/async_rt şu an yalnızca aarch64/x86-64 hedeflerini destekler"),
    };
    const swap_asm_freestanding_src, const swap_asm_freestanding_o_path = switch (freestanding_swap_arch) {
        .aarch64 => .{ "runtime/async_rt/swap_aarch64.S", "runtime/async_rt/swap_aarch64_freestanding.o" },
        .x86_64 => .{ "runtime/async_rt/swap_x86_64.S", "runtime/async_rt/swap_x86_64_freestanding.o" },
    };
    const compile_swap_asm_freestanding = b.addSystemCommand(&.{
        b.graph.zig_exe, "cc",
        "-target", b.fmt("{s}-freestanding-none", .{@tagName(b.graph.host.result.cpu.arch)}),
        "-c", "-o", swap_asm_freestanding_o_path, swap_asm_freestanding_src,
    });
    noxrt_freestanding_mod.addObjectFile(b.path(swap_asm_freestanding_o_path));
    const noxrt_freestanding = b.addObject(.{
        .name = "noxrt-freestanding",
        .root_module = noxrt_freestanding_mod,
    });
    // Faz R.3+F.1 tamamlama: GERÇEK bir freestanding link denemesiyle
    // ÖLÇÜLEREK BULUNDU — `Compile.bundle_compiler_rt`in VARSAYILANI
    // (`compile.kind == .exe or compile.isDynamicLibrary()`) SADECE
    // yürütülebilir/dinamik kütüphaneler İçİn `true`dır, `b.addObject`nin
    // (`.kind == .obj`) ÜRETTİĞİ NESNE dosyaları İçİn DEĞİL — bu YÜZDEN
    // Zig'in `memcpy`/`memset`/`memmove`/`__udivti3`/`__umodti3` GİBİ
    // KENDİ derleyici-runtime (compiler-rt) sembolleri VARSAYILAN olarak
    // BU nesneye GÖMÜLMÜYORDU (libc OLMADAN, `-nostdlib` bağlamında BUNLAR
    // BAŞKA HİÇBİR yerden GELMEZ) — AÇIKÇA `true` YAPILMASI GEREKİR.
    noxrt_freestanding.bundle_compiler_rt = true;
    // Faz F.4 (bkz. plan dosyası "Gerçek bare-metal boot zinciri"): `aarch64`
    // host'ta BU alana HİÇ DOKUNULMAZ (VARSAYILAN backend seçimi — F.0.7'DEN
    // BERİ ZATEN kanıtlanmış, DEĞİŞMEYEN davranış; `printf`nin `@cVaStart`ı
    // ARTIK `builtin.cpu.arch == .x86_64` İLE `comptime`-gate'li OLDUĞUNDAN
    // — bkz. `lib_freestanding.zig` — aarch64'te HİÇ analiz EDİLMİYOR, bu
    // YÜZDEN Zig'in `VaList`in aarch64+LLVM İçİn KOŞULSUZ `@compileError`ı
    // BURADA hiç tetiklenmez). `x86_64` host'ta İSE (kernel_x86_64'ün AYNI
    // hedefte force-ref edildiği durum) LLVM GEREKİR (aşağıdaki `noxrt_
    // kernel`in AYNI gerekçesi — self-hosted x86_64 backend'in inline-asm
    // ayrıştırıcısı `lidt`in bellek-operandı sözdizimini REDDEDİYOR).
    if (freestanding_swap_arch == .x86_64) noxrt_freestanding.use_llvm = true;
    noxrt_freestanding.step.dependOn(&compile_swap_asm_freestanding.step);
    const install_noxrt_freestanding = b.addInstallFile(noxrt_freestanding.getEmittedBin(), "lib/noxrt-freestanding.o");
    b.getInstallStep().dependOn(&install_noxrt_freestanding.step);

    // Faz F.4 (bkz. plan dosyası "Gerçek bare-metal boot zinciri (x86_64)"):
    // ÜÇÜNCÜ, SABİT x86_64 freestanding zinciri — İKİNCİ zincirin (yukarıda,
    // host mimarisine bağlı) AKSİNE, HER ZAMAN x86_64 hedefler (host'tan
    // BAĞIMSIZ — Zig'in cross-compile'ı BU makinede (aarch64) GERÇEKTEN
    // denenip DOĞRULANDI, bkz. plan dosyasının "Doğrulanmış zemin" bölümü).
    // `noxrt_kernel_mod`nin KÖKÜ AYNI, ARCH-NÖTR `runtime/lib_freestanding.
    // zig` — `kernel_x86_64` (`runtime/freestanding/x86_64/kernel.zig`)
    // SADECE `builtin.cpu.arch == .x86_64` İKEN force-ref edilir (bkz. o
    // dosyanın belge notu), bu YÜZDEN İKİNCİ zincirin (aarch64 host'ta)
    // BU dosyayı HİÇ GÖRMEMESİ YAPISAL olarak garantidir.
    const kernel_target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .freestanding,
        .abi = .none,
    });
    const abi_layout_mod_k = b.createModule(.{
        .root_source_file = b.path("shared/abi_layout.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });
    const diag_sink_mod_k = b.createModule(.{
        .root_source_file = b.path("runtime/errors/diag_sink.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });
    const noxrt_kernel_mod = b.createModule(.{
        .root_source_file = b.path("runtime/lib_freestanding.zig"),
        .target = kernel_target,
        .optimize = optimize,
        .link_libc = false,
        .imports = &.{
            .{ .name = "abi_layout", .module = abi_layout_mod_k },
            .{ .name = "diag_sink", .module = diag_sink_mod_k },
        },
    });
    // `swap_x86_64.S`nin SABİT x86_64 hedefi İçİn AYRI bir derlemesi
    // (`compile_swap_asm_freestanding`nin AYNI `zig cc -target ...` deseni,
    // AMA host mimarisinden BAĞIMSIZ — HER ZAMAN x86_64).
    const compile_swap_asm_kernel = b.addSystemCommand(&.{
        b.graph.zig_exe, "cc",
        "-target", "x86_64-freestanding-none",
        "-c", "-o", "runtime/async_rt/swap_x86_64_kernel.o", "runtime/async_rt/swap_x86_64.S",
    });
    noxrt_kernel_mod.addObjectFile(b.path("runtime/async_rt/swap_x86_64_kernel.o"));
    const noxrt_kernel = b.addObject(.{
        .name = "noxrt-freestanding-x86_64",
        .root_module = noxrt_kernel_mod,
    });
    // `noxrt_freestanding.bundle_compiler_rt`in AYNI, ÖLÇÜLMÜŞ gerekçesi
    // (`b.addObject`nin `.kind == .obj` çıktıları İçİn `bundle_compiler_rt`
    // VARSAYILAN olarak `false`dır).
    noxrt_kernel.bundle_compiler_rt = true;
    // Faz F.4: GERÇEK bir derlemeyle ÖLÇÜLEREK bulundu — `kernel.zig`nin
    // `idtInstall()`ındaki `lidt (%[p])` inline-asm'i, Zig'in SELF-HOSTED
    // x86_64 backend'inin (VARSAYILAN, `-fllvm` OLMADAN) inline-asm
    // ayrıştırıcısı TARAFINDAN "invalid memory operand" İLE REDDEDİLİYOR —
    // LLVM backend'i (`use_llvm = true`) BU sözdizimini DOĞRU işliyor.
    // `x86_64`in `VaList`ı (`printf`nin `@cVaStart`ı İçİn) freestanding
    // OS'ta backend'DEN BAĞIMSIZ ÇALIŞTIĞINDAN (bkz. `std.builtin.VaList`,
    // KISIT SADECE `.uefi`/`.windows`e ÖZGÜ) BU değişiklik `printf`i ETKİLEMEZ.
    noxrt_kernel.use_llvm = true;
    noxrt_kernel.step.dependOn(&compile_swap_asm_kernel.step);
    const install_noxrt_kernel = b.addInstallFile(noxrt_kernel.getEmittedBin(), "lib/noxrt-freestanding-x86_64.o");
    b.getInstallStep().dependOn(&install_noxrt_kernel.step);

    // `boot.S` (Multiboot1 header + 32-bit boot stub + long-mode geçişi +
    // GDT + ISR trambolinleri) — `noxrt_kernel_mod`nin PARÇASI DEĞİL, ayrı
    // derlenip `kernel_boot_x86_64_test.zig`nin KENDİ, SONRAKİ link adımında
    // (madde 9) DOĞRUDAN kullanılır (`swap_asm_o_path`nin AYNI, kaynak-
    // ağacı-İçİ nesne-dosyası konvansiyonu).
    const compile_boot_x86_64 = b.addSystemCommand(&.{
        b.graph.zig_exe, "cc",
        "-target", "x86_64-freestanding-none",
        "-c", "-o", "runtime/freestanding/x86_64/boot_x86_64.o", "runtime/freestanding/x86_64/boot.S",
    });
    b.getInstallStep().dependOn(&compile_boot_x86_64.step);

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
    // Faz LL.1: bkz. `noxc_only_step`in yukarıdaki belge notu.
    noxc_only_step.dependOn(&install_stdlib.step);

    // Faz HH.4 (bkz. plan dosyası "build artifact izolasyonu"): PAYLAŞILAN
    // `zig-out/bin/noxc`/`zig-out/lib/noxrt.o`/`zig-out/lib/nox/stdlib`
    // yollarına HİÇ DOKUNMADAN (mevcut TÜM tüketiciler SIFIR değişiklikle
    // çalışmaya devam eder), HER `zig build` çağrısının KENDİ `-Doptimize`
    // moduna göre adlandırılmış, KALICI bir EK kopyası bırakılır —
    // `compiler/project.zig`nin ZATEN VAR OLAN `NOX_RESOURCE_DIR` ortam
    // değişkeni (bkz. `resolveResourceDirs`) bu dizini DOĞRUDAN bir
    // kaynak-kökü olarak kabul eder (ör. `NOX_RESOURCE_DIR=$PWD/zig-out/
    // release-fast zig-out/release-fast/bin/noxc build --release ...`).
    // Bu, BU OTURUMDA İKİ KEZ yaşanan GERÇEK bir kontaminasyon hatasını
    // (bir ReleaseFast ölçümünün SONRADAN, İLGİSİZ bir `zig build test`
    // [Debug] çağrısıyla SESSİZCE bozulması) kalıcı olarak çözer.
    const mode_slug = optimizeModeSlug(optimize);
    const install_noxc_tagged = b.addInstallFile(noxc.getEmittedBin(), b.fmt("{s}/bin/noxc", .{mode_slug}));
    const install_noxrt_tagged = b.addInstallFile(noxrt.getEmittedBin(), b.fmt("{s}/lib/noxrt.o", .{mode_slug}));
    const install_stdlib_tagged = b.addInstallDirectory(.{
        .source_dir = b.path("stdlib"),
        .install_dir = .prefix,
        .install_subdir = b.fmt("{s}/lib/nox/stdlib", .{mode_slug}),
    });
    b.getInstallStep().dependOn(&install_noxc_tagged.step);
    b.getInstallStep().dependOn(&install_noxrt_tagged.step);
    b.getInstallStep().dependOn(&install_stdlib_tagged.step);
    noxc_only_step.dependOn(&install_noxc_tagged.step);
    noxc_only_step.dependOn(&install_stdlib_tagged.step);
    if (target.result.os.tag == .windows) {
        const install_swap_asm_tagged = b.addInstallFile(b.path(swap_asm_o_path), b.fmt("{s}/lib/swap_asm.o", .{mode_slug}));
        install_swap_asm_tagged.step.dependOn(&compile_swap_asm.step);
        b.getInstallStep().dependOn(&install_swap_asm_tagged.step);
    }

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

    // ---- `hpy_call_on` verim (throughput) ölçümü (bkz. benchmarks/
    // hpy_call_bench.zig) — Faz FFI.2'nin Obj havuzlama + MarshalCtx/
    // packed_args tahsis azaltmasının GERÇEK etkisini ölçmek İçİn — `bench_
    // http_step`in AYNI deseni. `tests/compat/hpy_ext/noxtest.so`ya bağımlı
    // olduğundan (`.hpy-venv` KURULUYSA `zig build test` SIRASINDA derlenir)
    // bu adım `b.getInstallStep()`e BAĞLIDIR AMA `noxtest.so`nun KENDİSİNİ
    // ZORUNLU KILMAZ — program KENDİSİ eksikse AÇIK bir hatayla ÇIKAR ----
    const hpy_call_bench_mod = b.createModule(.{
        .root_source_file = b.path("benchmarks/hpy_call_bench.zig"),
        .target = target,
        .optimize = optimize,
    });
    const hpy_call_bench = b.addExecutable(.{
        .name = "noxhpycallbench",
        .root_module = hpy_call_bench_mod,
    });
    const run_hpy_call_bench = b.addRunArtifact(hpy_call_bench);
    run_hpy_call_bench.step.dependOn(b.getInstallStep());
    const bench_hpy_step = b.step("bench-hpy", "hpy_call_on verim ölçümünü çalıştır (Faz FFI.2)");
    bench_hpy_step.dependOn(&run_hpy_call_bench.step);

    const test_step = b.step("test", "Tüm unit ve golden testleri çalıştır");
    // codegen golden testleri, üretilen binary'leri `zig-out/lib/noxrt.o`'ya
    // karşı linklemek için bu adımın önceden tamamlanmış olmasına ihtiyaç duyar.
    test_step.dependOn(&install_noxrt.step);
    // Faz R.3+F.1 tamamlama: `noxrt-freestanding.o`nun HER `zig build test`
    // çağrısında GERÇEKTEN derlendiğinden emin olmak İçİn (bkz. yukarıdaki
    // `install_noxrt_freestanding`nin belge notu — F.0.7'nin manuel
    // doğrulamasını KALICI bir regresyon KORUMASINA çevirir).
    test_step.dependOn(&install_noxrt_freestanding.step);
    // Faz HH.4: `zig build test`nin KENDİSİ de PAYLAŞILAN yolları YENİDEN
    // KURDUĞUNDAN (test_step, `b.getInstallStep()`DEN BAĞIMSIZ KENDİ
    // bağımlılıklarını taşır) — kontaminasyon senaryosunun İKİNCİ YARISINI
    // (`zig build test` çağrısının KENDİSİ) da kapsamak İçİn, YUKARIDAKİ
    // etiketli adımlar BURAYA da bağlanır (bkz. plan dosyası "build
    // artifact izolasyonu").
    test_step.dependOn(&install_noxrt_tagged.step);
    // Faz R.3 (bkz. docs/uretim-hazirlik-analizi.md): `install_stdlib`
    // ÖNCEDEN yalnızca `b.getInstallStep()`e (varsayılan `zig build` hedefi)
    // bağlıydı, `test_step`e DEĞİL — `zig build test`, `zig-out/lib/nox/
    // stdlib/`nin `zig-out`u TAMAMEN silmeden ÖNCEKİ bir `zig build`
    // çalışmasından KALMA olmasına SESSİZCE güveniyordu (GERÇEK bir hata,
    // temiz bir `zig-out` üzerinde `zig build test` doğrudan çalıştırıldığında
    // `stdlib/nox/core.nox: FileNotFound` ile ORTAYA ÇIKAR — Faz R.3'ün
    // Docker doğrulaması SIRASINDA GERÇEKTEN yakalandı).
    test_step.dependOn(&install_stdlib.step);
    // Faz HH.4: bkz. yukarıdaki `install_noxrt_tagged`in belge notu.
    test_step.dependOn(&install_stdlib_tagged.step);
    // Faz O §P.2: `tests/cli/subcommand_test.zig`, kurulu `zig-out/bin/noxc`yi
    // BİR ALT SÜREÇ olarak çalıştırıyor — `test_step`in bu adıma da bağımlı
    // olması GEREKİR, aksi halde `zig build test` `noxc`yi YENİDEN KURMADAN
    // (mevcut/eski bir ikiliye karşı) çalışabilir, bu da CLI'deki GERÇEK bir
    // regresyonu SESSİZCE KAÇIRABİLİR (bu eksiklik, tam da bu senaryoyu
    // sınayan bir kasıtlı-boz-restore ile keşfedildi).
    test_step.dependOn(&install_noxc.step);
    // Faz HH.4: bkz. yukarıdaki `install_noxrt_tagged`in belge notu.
    test_step.dependOn(&install_noxc_tagged.step);
    // Faz W.2: `noxlsp`nin KENDİSİ İÇİN AYRI bir golden/entegrasyon test
    // hedefi YOK (bkz. `tests/cli/lsp_test.zig`nin belge notu — protokol
    // seviyesinde stdio üzerinden ALT SÜREÇ olarak çalıştırılıp doğrulanır),
    // ama BU adım en azından `noxlsp`nin HER `zig build test`te GERÇEKTEN
    // DERLENDİĞİNİ garanti eder (`install_noxc`in YUKARIDAKİ AYNI gerekçesi).
    test_step.dependOn(&install_noxlsp.step);

    // "nox" modülünün kendi içindeki (lexer/parser dosyalarına gömülü) testler.
    const lib_test = b.addTest(.{ .root_module = nox_mod });
    test_step.dependOn(&b.addRunArtifact(lib_test).step);

    // Faz LL.1: `lib_test` (yukarıda) `compiler/lib.zig`nin (lexer/parser/
    // checker/module_loader) testleridir — bunlar da (noxc/noxlsp gibi)
    // runtime'a bağımlı DEĞİL, Windows'ta İLKE OLARAK çalışabilir. `ci.yml`nin
    // `windows-frontend` işinin `zig build frontend-test` İLE çağırdığı budur.
    const frontend_test_step = b.step("frontend-test", "Yalnızca derleyici ön-ucu (lexer/parser/checker) testlerini çalıştırır — runtime'a bağımlı DEĞİL");
    frontend_test_step.dependOn(&b.addRunArtifact(lib_test).step);

    // Zig runtime'ının kendi içindeki testler (bkz. runtime/alloc/asap.zig).
    const noxrt_test = b.addTest(.{ .root_module = noxrt_mod });
    noxrt_test.step.dependOn(&compile_swap_asm.step);
    test_step.dependOn(&b.addRunArtifact(noxrt_test).step);
    // Faz MN.8: `worker-pool-test`/`async-rt-test` İLE AYNI desen — SADECE
    // `noxrt_test`i (pool_bridge.zig/scheduler.zig/http_server.zig DAHİL
    // TÜM Zig-seviyesi runtime testleri) TAM takımın 700+ saniyelik golden/
    // codegen fixture'larını BEKLEMEDEN hızlı yineleme İçİn.
    const noxrt_test_step = b.step("noxrt-test", "Yalnızca noxrt_test'i (runtime/ altındaki TÜM Zig-seviyesi testler) çalıştırır (hızlı yineleme İçİn)");
    noxrt_test_step.dependOn(&b.addRunArtifact(noxrt_test).step);

    // "nox" modülünü dışarıdan tüketen ayrı test dosyaları (tests/unit, tests/golden).
    const external_test_files = [_][]const u8{
        "tests/unit/lexer_test.zig",
        "tests/unit/parser_test.zig",
        "tests/unit/project_test.zig",
        "tests/unit/test_runner_test.zig",
        "tests/unit/fetch_test.zig",
        "tests/unit/module_loader_test.zig",
        "tests/cli/subcommand_test.zig",
        "tests/cli/package_resolution_test.zig",
        "tests/cli/add_delete_test.zig",
        "tests/cli/local_import_test.zig",
        "tests/cli/lsp_test.zig",
        "tests/cli/sqlite_test.zig",
        "tests/cli/orm_test.zig",
        "tests/cli/shared_mem_test.zig",
        "tests/cli/install_test.zig",
        "tests/cli/help_screen_test.zig",
        "tests/cli/explain_test.zig",
        "tests/cli/profile_test.zig",
        "tests/cli/freestanding_build_test.zig",
        "tests/cli/binary_size_test.zig",
        "tests/cli/lowlevel_manual_test.zig",
        "tests/fuzz/lexer_parser_checker_fuzz.zig",
        "tests/golden/golden_test.zig",
        "tests/golden/typecheck_golden_test.zig",
        "tests/golden/ownership_golden_test.zig",
        "tests/golden/fmt_golden_test.zig",
        "tests/golden/codegen_ir_diff_test.zig",
        "tests/golden/llvm_golden_test.zig",
        "tests/golden/backend_conformance_test.zig",
    };

    for (external_test_files) |path| {
        const mod = b.createModule(.{
            .root_source_file = b.path(path),
            .target = target,
            .optimize = optimize,
            // NOT: `tests/cli/shared_mem_test.zig`nin KENDİSİ `std.c.getpid()`
            // ÇAĞIRIYOR (paylaşımlı bellek testinin İKİ ayrı process'i AYNI
            // PID uzayında OLMADIĞINI doğrulamak İçİn) — `hpy_bridge_mod`/
            // `wasm_bridge_mod`İLE AYNI, GERÇEK bir Linux CI çalıştırmasında
            // BULUNAN sınıf hatası: `std.c.*` KULLANIMI Linux'ta `link_libc`
            // OLMADAN "dependency on libc must be explicitly specified"
            // derleme hatası verir. Bu döngüdeki DİĞER dosyaların HİÇBİRİ
            // `std.c.*` KULLANMASA da `link_libc` EKLEMEK ZARARSIZDIR — bu
            // YÜZDEN dosya-başına özel durum AYIRT ETMEK yerine TÜMÜNE
            // uygulanır.
            .link_libc = true,
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

    // Faz X.2: `wasm_bridge.module.parse`nin fuzz hedefi (bkz. tests/fuzz/
    // wasm_parser_fuzz.zig'in modül üstü notu) — `wasm_bridge_mod`ü
    // DOĞRUDAN İTHAL EDEN, `wasm_bridge_test`ten AYRI bir hedef (`module.
    // zig`nin KENDİ gömülü testlerinden AYRI tutulur, çünkü BU dosya
    // `tests/fuzz/`nin KENDİSİNDE yaşamalıdır — görev tanımının AÇIKÇA
    // istediği KONUM).
    const wasm_fuzz_mod = b.createModule(.{
        .root_source_file = b.path("tests/fuzz/wasm_parser_fuzz.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "wasm_bridge", .module = wasm_bridge_mod },
        },
    });
    const wasm_fuzz_test = b.addTest(.{ .root_module = wasm_fuzz_mod });
    test_step.dependOn(&b.addRunArtifact(wasm_fuzz_test).step);

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
        // `cc -c` (yukarıdaki `compile_c_ext`/`compile_counter_ext`) HOST
        // dağıtımının PIE-varsayılan davranışını KENDİLİĞİNDEN
        // devralır (Linux'ta modern GCC/Clang'ın SİSTEM ÖNTANIMLI
        // yapılandırması) — AMA `zig build-obj` AYRI bir araç zincirdir,
        // BUNU otomatik yapmaz. Linux/x86-64 CI'de GERÇEKTEN gözlemlenen
        // bir link hatası (`relocation R_X86_64_32S ... recompile with
        // -fPIE`) `util.o`nun PIC-UYUMSUZ relokasyonlarla derlendiğini
        // (sonra PIE-varsayılan bir `cc`ye BAĞLANMAYA ÇALIŞILDIĞINI)
        // KANITLADI — `-fPIC` BUNU çözer (macOS/aarch64'te ZATEN ZARARSIZ
        // bir no-op, o platformlarda kod ZATEN PIC).
        "-fPIC",
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
        // Faz R.3: bu dosya `std.c.socket` (serbest port arama) DOĞRUDAN
        // ÇAĞIRIR — Linux'ta AÇIKÇA `link_libc` GEREKİR (bkz. `noxrt_mod`in
        // AYNI gerekçeli notu).
        .link_libc = true,
        .imports = &.{
            .{ .name = "nox", .module = nox_mod },
        },
    });
    const http_stdlib_test = b.addTest(.{ .root_module = http_stdlib_test_mod });
    http_stdlib_test.step.dependOn(&install_noxrt.step);
    test_step.dependOn(&b.addRunArtifact(http_stdlib_test).step);

    // Bulundu (bkz. proje belleği "f-string + augmented atama" görevi):
    // `noxc search`in YENİ `loadIndexFromUrl` yolunu GERÇEK bir yerel HTTP
    // sunucusuna karşı doğrulayan `search_test.zig`, `http_stdlib_test_mod`la
    // AYNI gerekçeyle (`std.c.socket` DOĞRUDAN çağrısı) `link_libc`
    // gerektirir — bu YÜZDEN `external_test_files`in GENEL listesinden
    // ÇIKARILIP burada KENDİ modülü olarak tanımlandı.
    const search_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/cli/search_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const search_test = b.addTest(.{ .root_module = search_test_mod });
    test_step.dependOn(&b.addRunArtifact(search_test).step);

    // `noxc upgrade` (bkz. `compiler/pkg/upgrade.zig`nin modül üstü notu)
    // uçtan uca testleri — `search_test_mod` İLE AYNI gerekçeyle (`std.c.
    // socket` DOĞRUDAN çağrısı, birden fazla yolu YÖNLENDİREN bir yerel
    // sunucu) `link_libc` gerektirir, KENDİ modülü olarak tanımlandı.
    const upgrade_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/cli/upgrade_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const upgrade_test = b.addTest(.{ .root_module = upgrade_test_mod });
    test_step.dependOn(&b.addRunArtifact(upgrade_test).step);

    // `noxc publish` (bkz. `compiler/pkg/registry.zig`nin modül üstü notu)
    // uçtan uca testleri — `search_test_mod`/`upgrade_test_mod` İLE AYNI
    // gerekçeyle (`std.c.socket` DOĞRUDAN çağrısı) `link_libc` gerektirir.
    const publish_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/cli/publish_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const publish_test = b.addTest(.{ .root_module = publish_test_mod });
    test_step.dependOn(&b.addRunArtifact(publish_test).step);

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
        // Faz R.3: `std.c.socket` (serbest port arama) DOĞRUDAN ÇAĞRILIR —
        // bkz. `http_stdlib_test_mod`in AYNI gerekçeli notu.
        .link_libc = true,
        .imports = &.{
            .{ .name = "nox", .module = nox_mod },
        },
    });
    const http_serve_test = b.addTest(.{ .root_module = http_serve_test_mod });
    http_serve_test.step.dependOn(&install_noxrt.step);
    test_step.dependOn(&b.addRunArtifact(http_serve_test).step);

    // ---- `stdlib/nox/router.nox` + `nox.http.serve*` etkileşiminin
    // regresyon testi (bkz. router_module_state_golden_test.zig'in modül
    // üstü notu — `services/noxpkg/` inşa edilirken BULUNAN, GERÇEK bir
    // kısıt) — `http_serve_test` İLE AYNI bağımlılık/model ----
    const router_module_state_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/compat/router_module_state_golden_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "nox", .module = nox_mod },
        },
    });
    const router_module_state_test = b.addTest(.{ .root_module = router_module_state_test_mod });
    router_module_state_test.step.dependOn(&install_noxrt.step);
    test_step.dependOn(&b.addRunArtifact(router_module_state_test).step);

    // ---- Faz DD.1: çok-çekirdekli `nox.http.serve` uçtan uca golden
    // testleri — `http_serve_test` İLE AYNI bağımlılık/model, AYRI bir
    // dosya (bkz. http_serve_multicore_golden_test.zig'in modül üstü notu) ----
    const http_serve_multicore_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/compat/http_serve_multicore_golden_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "nox", .module = nox_mod },
        },
    });
    const http_serve_multicore_test = b.addTest(.{ .root_module = http_serve_multicore_test_mod });
    http_serve_multicore_test.step.dependOn(&install_noxrt.step);
    test_step.dependOn(&b.addRunArtifact(http_serve_multicore_test).step);

    // ---- Faz MN.7b: `nox.http.serve_multicore`nin havuz-tabanlı
    // (`--release`/LLVM) lowering'i İçİn AYNI uçtan uca golden desen —
    // AYRI dosya (bkz. http_serve_multicore_pool_golden_test.zig'in modül
    // üstü notu) — `llvm_golden_test.zig`nin AKSİNE `std.c.*` (socket/
    // connect) KULLANDIĞINDAN `http_serve_multicore_test`in AYNI `link_libc`
    // + AÇIK `install_noxrt.step` bağımlılığı deseni İZLENİR.
    const http_serve_multicore_pool_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/compat/http_serve_multicore_pool_golden_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "nox", .module = nox_mod },
        },
    });
    const http_serve_multicore_pool_test = b.addTest(.{ .root_module = http_serve_multicore_pool_test_mod });
    http_serve_multicore_pool_test.step.dependOn(&install_noxrt.step);
    test_step.dependOn(&b.addRunArtifact(http_serve_multicore_pool_test).step);

    // ---- Faz "sunucu-tarafı TLS terminasyonu + WebSocket Upgrade" —
    // `nox.http.serve_tls`/`serve_ws` uçtan uca golden testleri — `http_
    // serve_test` İLE AYNI bağımlılık/model, AYRI dosyalar (bkz. ilgili
    // dosyaların modül üstü notu) ----
    const http_serve_tls_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/compat/http_serve_tls_golden_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "nox", .module = nox_mod },
        },
    });
    const http_serve_tls_test = b.addTest(.{ .root_module = http_serve_tls_test_mod });
    http_serve_tls_test.step.dependOn(&install_noxrt.step);
    test_step.dependOn(&b.addRunArtifact(http_serve_tls_test).step);

    const http_serve_ws_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/compat/http_serve_ws_golden_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "nox", .module = nox_mod },
        },
    });
    const http_serve_ws_test = b.addTest(.{ .root_module = http_serve_ws_test_mod });
    http_serve_ws_test.step.dependOn(&install_noxrt.step);
    test_step.dependOn(&b.addRunArtifact(http_serve_ws_test).step);

    // ---- Faz 21 standalone testleri (`runtime/async_rt`, `noxrt.o`dan
    // BAĞIMSIZ doğrulama — bkz. bu dosyanın başındaki `compile_swap_asm`) ----
    const fiber_test_mod = b.createModule(.{
        .root_source_file = b.path("runtime/async_rt/fiber.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "diag_sink", .module = diag_sink_mod },
        },
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
        .imports = &.{
            .{ .name = "diag_sink", .module = diag_sink_mod },
        },
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
        .imports = &.{
            .{ .name = "diag_sink", .module = diag_sink_mod },
        },
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
        .imports = &.{
            .{ .name = "diag_sink", .module = diag_sink_mod },
        },
    });
    io_test_mod.addObjectFile(b.path(swap_asm_o_path));
    const io_test = b.addTest(.{ .root_module = io_test_mod });
    io_test.step.dependOn(&compile_swap_asm.step);
    test_step.dependOn(&b.addRunArtifact(io_test).step);

    // Faz LL.2/LL.3 (bkz. nox-teknik-spesifikasyon.md §3.71): `fiber_test`/
    // `scheduler_test`/`channel_test`/`io_test` (yukarıda) `runtime/
    // stdlib_shims`e (os/fs/http gibi HENÜZ Windows'a taşınmamış dosyalara)
    // HİÇ BAĞIMLI DEĞİL — yalnızca `swap_asm_o_path`e (bu derlemenin
    // `.S` dosyasına) VE birbirlerine bağımlılar. Bu YÜZDEN `noxrt`in
    // TAMAMI (dolayısıyla TÜM stdlib_shims'in Windows'a taşınmasını)
    // BEKLEMEDEN, YALNIZCA fiber/reaktör/zamanlayıcı katmanının Windows'ta
    // GERÇEKTEN çalıştığını doğrulayan İZOLE bir adım — `windows-frontend`
    // CI işinin `zig build async-rt-test` İLE çağırdığı TAM OLARAK budur.
    const async_rt_test_step = b.step("async-rt-test", "Yalnızca runtime/async_rt testlerini çalıştırır (stdlib_shims'e bağımlı DEĞİL)");
    async_rt_test_step.dependOn(&b.addRunArtifact(fiber_test).step);
    async_rt_test_step.dependOn(&b.addRunArtifact(scheduler_test).step);
    async_rt_test_step.dependOn(&b.addRunArtifact(channel_test).step);
    async_rt_test_step.dependOn(&b.addRunArtifact(io_test).step);

    // Faz MN.3b: `worker_pool.zig`nin KENDİ eşzamanlı stres testi — `noxrt`in
    // TAMAMINI (TÜM stdlib_shims) BEKLEMEDEN hızlı yineleme İçİn AYRI, DAR
    // bir hedef (`fiber_test`/`scheduler_test` İLE AYNI desen, TEK FARKLA:
    // `arc.zig`/`cycle_detector.zig` `abi_layout`e ihtiyaç duyar). `test_step`e
    // de eklenir (tam regresyonun BİR PARÇASI olsun diye).
    const worker_pool_test_mod = b.createModule(.{
        .root_source_file = b.path("runtime/worker_pool_test_root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "abi_layout", .module = abi_layout_mod },
            .{ .name = "diag_sink", .module = diag_sink_mod },
        },
    });
    worker_pool_test_mod.addObjectFile(b.path(swap_asm_o_path));
    const worker_pool_test = b.addTest(.{ .root_module = worker_pool_test_mod });
    worker_pool_test.step.dependOn(&compile_swap_asm.step);
    const worker_pool_test_step = b.step("worker-pool-test", "Yalnızca Faz MN.3b'nin worker_pool.zig testini çalıştırır (hızlı yineleme İçİn)");
    worker_pool_test_step.dependOn(&b.addRunArtifact(worker_pool_test).step);
    test_step.dependOn(&b.addRunArtifact(worker_pool_test).step);

    // v1.31.0 (bkz. plan dosyası "Eşzamanlılık stres-test altyapısı"):
    // `worker_pool.zig`nin ZATEN kanıtlanmış İKİ 20-tekrarlı çapraz-worker
    // stres testini (Channel/Task await_()) ÇOK DAHA FAZLA tur İLE
    // çalıştıran, GERÇEKTEN opt-in bir hedef — AYNI `worker_pool_test`
    // ikilisini (YUKARIDA ZATEN derlenmiş) YENİDEN KULLANIR, SADECE
    // `NOX_STRESS_ROUNDS` ortam değişkenini `worker_pool.zig`nin
    // `stressRoundsFromEnv`inin okuyacağı ŞEKİLDE AYARLAR. BİLİNÇLİ:
    // `test_step.dependOn(...)` YOK — bu, deponun İLK GERÇEKTEN opt-in
    // (varsayılan `zig build test`in PARÇASI OLMAYAN) test hedefidir; HER
    // push'ta çalışan hızlı paketi YAVAŞLATMADAN, gecelik bir CI cron
    // işinin (`.github/workflows/stress.yml`) çağırması İçİndir.
    const stress_rounds = b.option(usize, "stress-rounds", "stress-test adımının çapraz-worker Channel/Task stres tur sayısı (varsayılan: 2000)") orelse 2000;
    const stress_run = b.addRunArtifact(worker_pool_test);
    stress_run.setEnvironmentVariable("NOX_STRESS_ROUNDS", b.fmt("{d}", .{stress_rounds}));
    const stress_test_step = b.step("stress-test", "worker_pool.zig'in çapraz-worker Channel/Task stres testlerini ÇOK DAHA FAZLA tur (-Dstress-rounds, varsayılan 2000) İLE çalıştırır — opt-in, YAVAŞ, 'test' adımının PARÇASI DEĞİL");
    stress_test_step.dependOn(&stress_run.step);

    // v1.36.0 (bkz. plan dosyası "HTTP/TLS için gecelik soak testi"):
    // `stress-test`in (v1.31.0) AYNI "gerçekten opt-in" ilkesi — GERÇEK
    // `zig-out/bin/noxc`yi çağıran (`benchmarks/http_bench.zig`nin AYNI
    // deseni, checker/codegen İç API'lerine bağımlı DEĞİL) bir soak testi.
    // `b.getInstallStep()`e bağımlı (GERÇEK `noxc`/`noxrt.o`nin İNŞA
    // EDİLDİĞİNDEN emin olmak İçİn — `bench_http_step`in AYNI deseni).
    // BİLİNÇLİ: `test_step.dependOn(...)` YOK — GERÇEK ağ I/O + BİRDEN
    // FAZLA saniye süren bir test, HER push'ta çalışan hızlı paketi
    // YAVAŞLATMAMALI.
    const http_soak_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/compat/http_soak_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const http_soak_test = b.addTest(.{ .root_module = http_soak_test_mod });
    http_soak_test.step.dependOn(b.getInstallStep());

    const soak_seconds = b.option(u32, "soak-seconds", "http-soak-test adımının süresi (saniye, varsayılan: 5)") orelse 5;
    const soak_run = b.addRunArtifact(http_soak_test);
    soak_run.setEnvironmentVariable("NOX_SOAK_SECONDS", b.fmt("{d}", .{soak_seconds}));
    const http_soak_test_step = b.step("http-soak-test", "nox.http.serve_multicore/serve_tls soak testi (-Dsoak-seconds, varsayılan 5) — opt-in, YAVAŞ, 'test' adımının PARÇASI DEĞİL");
    http_soak_test_step.dependOn(&soak_run.step);

    // Faz F.1 (bkz. plan dosyası "Cross-compile İSKELETİ"): QBE'nin çıktısı
    // freestanding, statik bir ELF olarak linklenebiliyor mu deneyini
    // (`wasm_build_options`nin AYNI "zig'in KENDİ yolunu build_options
    // üzerinden testin İçİNE geçir" deseni) kalıcı bir teste çevirir.
    // `windows-frontend` CI işi `zig build frontend-test` çağırır (bkz.
    // yukarıdaki `frontend_test_step`) — bu YÜZDEN `test_step`e EKLENEN
    // bu test Windows'ta HİÇ çalışmaz, AYRI bir hariç-tutma GEREKMEZ.
    const freestanding_link_options = b.addOptions();
    freestanding_link_options.addOption([]const u8, "zig_exe_path", b.graph.zig_exe);
    const freestanding_link_mod = b.createModule(.{
        .root_source_file = b.path("tests/golden/freestanding_link_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "build_options", .module = freestanding_link_options.createModule() },
        },
    });
    const freestanding_link_test = b.addTest(.{ .root_module = freestanding_link_mod });
    test_step.dependOn(&b.addRunArtifact(freestanding_link_test).step);

    // Faz F.4 (bkz. plan dosyası "Gerçek bare-metal boot zinciri (x86_64)"):
    // `freestanding_link_test`in AYNI `b.addOptions()` deseni — GERÇEK QEMU
    // boot testinin (`tests/golden/kernel_boot_x86_64_test.zig`) İhtiyaç
    // duyduğu TÜM yolları (zig'in KENDİ yürütülebilir dosyası + `noxc`/
    // linker-script/boot-nesnesi/runtime-nesnesi/kernel-kaynağı) TEK bir
    // yerden (bu dosyadan) geçirir — testin KENDİSİ bu yolları İKİNCİ KEZ
    // hardcode ETMEZ.
    const kernel_boot_options = b.addOptions();
    kernel_boot_options.addOption([]const u8, "zig_exe_path", b.graph.zig_exe);
    kernel_boot_options.addOption([]const u8, "noxc_path", "zig-out/bin/noxc");
    kernel_boot_options.addOption([]const u8, "kernel_ld_path", "runtime/freestanding/x86_64/kernel.ld");
    kernel_boot_options.addOption([]const u8, "boot_obj_path", "runtime/freestanding/x86_64/boot_x86_64.o");
    kernel_boot_options.addOption([]const u8, "noxrt_kernel_obj_path", "zig-out/lib/noxrt-freestanding-x86_64.o");
    kernel_boot_options.addOption([]const u8, "kernel_src_path", "runtime/freestanding/x86_64/kernel_demo.nox");
    const kernel_boot_mod = b.createModule(.{
        .root_source_file = b.path("tests/golden/kernel_boot_x86_64_test.zig"),
        .target = target,
        .optimize = optimize,
        // `shared_mem_test.zig`'in AYNI gerekçesi — bu dosya `extern "c" fn
        // setenv` KULLANIR (`NOX_FREESTANDING_KERNEL_ARCH`i alt-sürece
        // AKTARMAK İçİn, bkz. testin belge notu).
        .link_libc = true,
        .imports = &.{
            .{ .name = "build_options", .module = kernel_boot_options.createModule() },
        },
    });
    const kernel_boot_test = b.addTest(.{ .root_module = kernel_boot_mod });
    kernel_boot_test.step.dependOn(&install_noxc.step);
    kernel_boot_test.step.dependOn(&install_noxrt_kernel.step);
    kernel_boot_test.step.dependOn(&compile_boot_x86_64.step);
    kernel_boot_test.step.dependOn(&install_stdlib.step);
    const kernel_boot_test_run = b.addRunArtifact(kernel_boot_test);
    test_step.dependOn(&kernel_boot_test_run.step);
    // Faz F.5'in (gelecekteki, AYRI bir tur) İhtiyaç duyacağı TEK çağrı
    // noktası — CI'ye qemu KURULMADAN BU adım ZATEN test_step İçİnde
    // SESSİZCE atlanıyor (bkz. testin KENDİ "qemu yoksa SkipZigTest" notu),
    // AMA opt-in bir `zig build kernel-boot-test` de HAZIR bekler.
    const kernel_boot_test_step = b.step("kernel-boot-test", "Faz F.4'ün x86_64 QEMU boot testini (GERÇEK bare-metal çalıştırma) çalıştırır — qemu/qbe PATH'te olmalı");
    kernel_boot_test_step.dependOn(&kernel_boot_test_run.step);
}
