//! Faz F.0.7 (bkz. plan dosyası "Kritik düzeltme #3"in çözümü): `noxrt_mod`nin
//! freestanding hedeflerdeki KÖK modülü — `runtime/lib.zig`nin AYNI "her
//! dosyayı isim üzerinden yeniden dışa-aktar + comptime force-ref" deseni,
//! AMA SADECE ARC/scheduler/dict/handle ÇEKİRDEĞİNİ kapsayan, DAHA DAR bir
//! liste. `foreign_bridge.zig`/`stdlib_shims/*`/`pool_bridge.zig`/
//! `thread_bridge.zig`/`thread_channel.zig` (VE `stdlib_shims/io.zig`) BU
//! DOSYAYA HİÇ İMPORT EDİLMEZ — Zig'in tembel analiz modelinde ("hiçbir şey
//! onları başvurmadıkça analiz edilmez", bkz. `lib.zig`nin AYNI notu) bu,
//! bunların freestanding derlemesinden TAMAMEN SESSİZCE dışlandığı anlamına
//! gelir (YENİ bir derleme hatası RİSKİ YOK — sadece hiç analiz edilmiyorlar).
//!
//! **Kapsam kararı (kullanıcının "Scheduler'ı da kapsama al" seçimiyle):**
//! `spawn`/`await`/`Task[T]`/`Channel[T]` (ÇEKİRDEK dil özelliği) freestanding
//! profilinde ÇALIŞIR — AMA `nox.thread.pool_run`/`nox.http.serve_multicore`
//! (GERÇEK OS iş parçacığı havuzu) VE gerçek soket/dosya G/Ç'si F.2'nin
//! capability allowlist'i TARAFINDAN ZATEN reddedilir, bu YÜZDEN onların
//! runtime karşılıkları (`worker_pool.zig`/`pool_bridge.zig`/`thread_bridge.
//! zig`/`thread_channel.zig`/`stdlib_shims/*`) BU KÖKTEN HİÇ erişilemez —
//! `bridge.zig`nin `nox_async_init`indeki `if (comptime !is_freestanding)`
//! guard'ı (bkz. onun belge notu) bunu GARANTİ eder.

const std = @import("std");
const builtin = @import("builtin");

pub const asap = @import("alloc/asap.zig");
pub const arc = @import("alloc/arc.zig");
pub const dispatch_registry = @import("alloc/dispatch_registry.zig");
pub const diag_sink = @import("diag_sink");
pub const lowlevel = @import("alloc/lowlevel.zig");
pub const cycle_detector = @import("alloc/cycle_detector.zig");
pub const defer_stack = @import("alloc/defer_stack.zig");
pub const errors = @import("errors/handle.zig");
pub const async_bridge = @import("async_rt/bridge.zig");
pub const task_local = @import("async_rt/task_local.zig");
/// `lib.zig`nin AYNI "bağımsız, sadece test-keşfi İçİn KAYITLI" deseni —
/// `scheduler.zig` ZATEN `chase_lev_deque.zig`yi DOĞRUDAN import ETTİĞİNDEN
/// bu satır davranışı DEĞİŞTİRMEZ, sadece isim-üzerinden ERİŞİLEBİLİR kılar.
pub const chase_lev_deque = @import("async_rt/chase_lev_deque.zig");
pub const str = @import("str.zig");
pub const dict = @import("collections/dict.zig");
pub const list_sort = @import("collections/list_sort.zig");

// Faz R.3+F.1 tamamlama (bkz. plan dosyası "Faz R.3 + F.1'in
// tamamlanması"): BU turda GERÇEK bir `noxc build --profile freestanding`
// denemesiyle (madde 5'in linker akışı) ÖLÇÜLEREK bulunan, ÖNCEDEN
// bilinmeyen bir gerçek — codegen'in `genMain`/`genMainAsync`i (bkz.
// `compiler/codegen_qbe/registration.zig`) HER ZAMAN, KOŞULSUZ olarak
// `$nox_os_init`i çağırıyor; `stdlib/nox/core.nox`nin `input()` fonksiyonu
// İSE (HER programa OTOMATİK birleştirilen, KULLANILIP KULLANILMADIĞINDAN
// BAĞIMSIZ olarak QBE IR'ına HER ZAMAN gömülen bir üst-düzey `def` — Nox
// HİÇBİR üst-düzey fonksiyon İçİn ölü-kod eleme YAPMIYOR) `nox_stdin_read_
// line_raw`i çağırıyor. HER İKİSİ de `runtime/stdlib_shims/os.zig`/`io.zig`
// de tanımlı — bu dosyalar (BİLİNÇLİ olarak, `http_client.zig`/soket G/Ç'sine
// bağımlı OLDUKLARINDAN) BU KÖKE HİÇ import EDİLMİYOR. Bu YÜZDEN aşağıdaki
// İKİ sembol, o dosyaların TAMAMINI import ETMEDEN, BURADA minimal/
// freestanding-güvenli birer tanım OLARAK sağlanır: `nox_os_init`
// GERÇEKTEN kullanışlı (argc/argv'yi saklar, `os.zig`nin KENDİ gövdesiyle
// BİREBİR AYNI); `nox_stdin_read_line_raw` İSE SADECE LİNKLEMEYİ sağlayan
// bir placeholder'dır (GERÇEK bir konsol/UART HENÜZ YOK — bu Faz F.4'ün
// İŞİ) — BU FAZ SADECE derleme+linkleme zincirini kanıtlıyor, ÜRETİLEN
// ikiliyi ÇALIŞTIRMIYOR (bkz. plan dosyasının "Kapsam Dışı" bölümü).
var g_os_argc: i32 = 0;
var g_os_argv: ?[*]const ?[*:0]const u8 = null;

export fn nox_os_init(argc: i32, argv: ?[*]const ?[*:0]const u8) callconv(.c) void {
    g_os_argc = argc;
    g_os_argv = argv;
}

/// Faz F.4 (bkz. plan dosyası "Gerçek bare-metal boot zinciri"): `genMain`/
/// `genMainAsync`nin (bkz. `registration.zig`nin `runtimeInitSymbol`ı)
/// `--profile freestanding` İKEN çağırdığı GERÇEK giriş noktası — SABİT,
/// program-ömürlü bir `.bss`-yerleşimli 4 MiB tampon ÜZERİNE kurulu bir
/// `std.heap.FixedBufferAllocator`i (arch-NÖTR — x86_64'e ÖZGÜ bir dosyada
/// DEĞİL, AKSİ HALDE aarch64 host'ta `noxc build --profile freestanding`
/// ÇÖZÜLMEMİŞ sembol verirdi) `asap.nox_runtime_init_with_allocator`e
/// bootstrap+injected allocator OLARAK geçirir — ARC/list/dict/class
/// tahsisi GERÇEKTEN BU "kernel heap"ten akar (F.0.2'nin enjeksiyon
/// noktası). ÜRETİLEN `.elf`nin `= undefined` global'in GERÇEKTEN `.bss`e
/// GİTTİĞİ (dosya boyutunu ŞİŞİRMEDİĞİ), `zig build kernel-boot-test`in
/// ELF-boyutu iddiasıyla DOLAYLI olarak doğrulanır.
const KERNEL_HEAP_BYTES: usize = 4 * 1024 * 1024;
var g_kernel_heap_backing: [KERNEL_HEAP_BYTES]u8 align(16) = undefined;
var g_kernel_fba: std.heap.FixedBufferAllocator = undefined;
var g_kernel_fba_ready: bool = false;

pub export fn nox_runtime_init_freestanding() callconv(.c) ?*anyopaque {
    if (!g_kernel_fba_ready) {
        g_kernel_fba = std.heap.FixedBufferAllocator.init(&g_kernel_heap_backing);
        g_kernel_fba_ready = true;
    }
    return asap.nox_runtime_init_with_allocator(g_kernel_fba.allocator());
}

export fn nox_stdin_read_line_raw(rt: ?*anyopaque) callconv(.c) ?[*:0]u8 {
    _ = rt;
    return null;
}

/// Faz R.3+F.1 tamamlama: `Exception`/`ValueError`/`IndexError`/`KeyError`
/// (HER programa OTOMATİK birleştirilen `core.nox`nin sınıfları) HER
/// ZAMAN, KOŞULSUZ olarak bir `_eq` metodu ÜRETİYOR — `str` tipli alanları
/// (ör. `message`) karşılaştırmak İçİn `$strcmp`i çağırıyor (bkz.
/// `compiler/codegen_qbe/expr.zig`nin `genStrEquals`ı). `printf`/`nox_
/// stdin_read_line_raw`nin AKSİNE, `strcmp` HİÇBİR G/Ç/OS ilkeli
/// GEREKTİRMEZ (SAF bellek karşılaştırması) — bu YÜZDEN burada libc'nin
/// KENDİ semantiğine BİREBİR uyan, GERÇEK/doğru bir implementasyon olarak
/// (bir placeholder DEĞİL) sağlanır.
export fn strcmp(a: ?[*:0]const u8, b: ?[*:0]const u8) callconv(.c) c_int {
    const pa = a orelse return 0;
    const pb = b orelse return 0;
    var i: usize = 0;
    while (true) : (i += 1) {
        const ca = pa[i];
        const cb = pb[i];
        if (ca != cb) return @as(c_int, ca) - @as(c_int, cb);
        if (ca == 0) return 0;
    }
}

/// Faz F.4 (bkz. plan dosyası "Gerçek bare-metal boot zinciri"): `print()`
/// builtin'inin (bkz. `compiler/codegen_qbe/expr.zig`nin `genPrint`ı)
/// KOŞULSUZ lowerlandığı `$printf`nin GERÇEK implementasyonu — R.3+F.1'in
/// no-op STUB'ı YÜKSELTİLDİ. `genPrint`nin ÜRETTİĞİ TÜM format string'leri
/// (`$fmt_int`/`$fmt_float`/`$fmt_str`/`$fmt_bool_true`/`$fmt_bool_false`/
/// `$fmt_newline`/`$fmt_int_frag`/`$fmt_float_frag`/`$fmt_str_frag`/
/// `$fmt_bool_true_frag`/`$fmt_bool_false_frag`/`$fmt_lbracket`/`$fmt_
/// rbracket`/`$fmt_rparen`/`$fmt_comma_sp`, VE sınıf-adı/alan-adı literal
/// string'leri) EN FAZLA TEK bir `%lld`/`%g`/`%s` yer-tutucusu TAŞIR — BU
/// YÜZDEN genel bir C printf yerine, BU DAR yer-tutucu kümesini `@cVaStart`/
/// `@cVaArg` İLE okuyan minimal bir yorumlayıcı YETERLİDİR.
///
/// **SADECE x86_64'te GERÇEK** (bkz. `printfReal`) — `std.builtin.VaList`
/// aarch64-freestanding+LLVM backend İçİn `@compileError("disabled due to
/// miscompilations")` İLE KOŞULSUZ REDDEDİYOR (Zig 0.16'nın KENDİ stdlib'i,
/// `x86_64`'ün freestanding OS'ta BU KISITTAN MUAF olmasının AKSİNE) —
/// `runtime/lib_freestanding.zig` HEM x86_64 kernel zincirine (F.4'ün
/// ASIL hedefi, GERÇEKTEN çalıştırılır) HEM host-mimarisi zincirine
/// (F.0.7'nin KENDİ, SADECE derleme-regresyonu kanıtlayan — HİÇ ÇALIŞTIRILMAYAN
/// — zinciri) KÖK olduğundan, `@cVaStart`nin `if (comptime ...)` İLE
/// TAMAMEN ELENMESİ (aarch64 host'ta printf'in KENDİ gövdesinin HİÇ analiz
/// EDİLMEMESİ) BU çakışmayı YAPISAL olarak ORTADAN KALDIRIR — `nox_os_init`/
/// `nox_stdin_read_line_raw`nin AYNI "SADECE linklemeyi sağlayan no-op"
/// ilkesiyle, aarch64 host'ta printf ARTIK OLDUĞU GİBİ (F.0.7-ÖNCESİ,
/// SADECE bir linkleme-kanıtı) KALIR.
const printf_real = builtin.cpu.arch == .x86_64;

fn printfReal(f: [*:0]const u8, ap_ptr: *std.builtin.VaList) usize {
    var buf: [1024]u8 = undefined;
    var pos: usize = 0;
    var i: usize = 0;
    while (f[i] != 0) : (i += 1) {
        if (f[i] == '%' and f[i + 1] == 'l' and f[i + 2] == 'l' and f[i + 3] == 'd') {
            i += 3;
            const v = @cVaArg(ap_ptr, i64);
            const written = std.fmt.bufPrint(buf[pos..], "{d}", .{v}) catch break;
            pos += written.len;
        } else if (f[i] == '%' and f[i + 1] == 'g') {
            i += 1;
            const v = @cVaArg(ap_ptr, f64);
            const written = std.fmt.bufPrint(buf[pos..], "{d}", .{v}) catch break;
            pos += written.len;
        } else if (f[i] == '%' and f[i + 1] == 's') {
            i += 1;
            const v = @cVaArg(ap_ptr, ?[*:0]const u8);
            if (v) |s| {
                const slen = std.mem.len(s);
                const copy_len = @min(slen, buf.len - pos);
                @memcpy(buf[pos..][0..copy_len], s[0..copy_len]);
                pos += copy_len;
            }
        } else if (pos < buf.len) {
            buf[pos] = f[i];
            pos += 1;
        }
    }
    diag_sink.diagSink()(null, &buf, pos);
    return pos;
}

export fn printf(fmt: ?[*:0]const u8, ...) callconv(.c) c_int {
    if (comptime !printf_real) return 0;
    const f = fmt orelse return 0;
    var ap = @cVaStart();
    defer @cVaEnd(&ap);
    return @intCast(printfReal(f, &ap));
}

// `lib.zig`nin AYNI zorunlu force-ref bloğu — bu modüllerin `export fn`
// bildirimlerinin freestanding `noxrt.o`nun nesne çıktısına DAHİL olması
// İçİn (hiçbir şey onları başvurmadıkça analiz edilmez).
comptime {
    _ = asap;
    _ = arc;
    _ = dispatch_registry;
    _ = diag_sink;
    _ = lowlevel;
    _ = cycle_detector;
    _ = defer_stack;
    _ = errors;
    _ = async_bridge;
    _ = task_local;
    _ = chase_lev_deque;
    _ = str;
    _ = dict;
    _ = list_sort;
}
