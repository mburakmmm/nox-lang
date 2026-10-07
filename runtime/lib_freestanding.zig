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
pub const format = @import("format.zig");
pub const dict = @import("collections/dict.zig");
pub const list_sort = @import("collections/list_sort.zig");
pub const list_ops = @import("collections/list_ops.zig");
/// v4 Faz B, madde 1 (bkz. nox-teknik-spesifikasyon.md §3.2xx): `nox.math`
/// ARTIK Zig'in KENDİ `std.math`ı üzerine kurulu (ESKİDEN bare `extern def
/// ... from "m"`, libm'e DOĞRUDAN bağlıydı — freestanding'de HİÇBİR libc/
/// libm YOK). `stdlib_shims/math.zig` HİÇBİR OS/libc bağımlılığı
/// TAŞIMADIĞINDAN (SADECE `@sin`/`@sqrt`/vb. Zig BUILTIN'leri + `std.
/// math`nin SAF Zig algoritmaları) BU KÖKE GÜVENLE import EDİLİR —
/// `http_client.zig`/vb.nin (yukarıdaki modül-üstü not) AKSİNE.
pub const math_shim = @import("stdlib_shims/math.zig");
/// v4 Faz B devamı (bkz. nox-teknik-spesifikasyon.md §3.2xx): `nox.time`
/// ARTIK MODÜL-seviyesinde capability-SİZDİR (`time.nox`nin belge notu) —
/// SAF takvim aritmetiği (`to_epoch_ms_raw`/`year_raw`/vb.) HİÇBİR OS/libc
/// bağımlılığı TAŞIMADIĞINDAN bu KÖKE GÜVENLE import EDİLİR. `now_ms_raw`/
/// `monotonic_ms_raw`/`sleep_ms_raw` (GERÇEKTEN `std.c.clock_gettime`e
/// bağlı) `time.zig`nin KENDİ `is_freestanding` guard'ıyla SIFIR döner —
/// Nox tarafı BUNLARI `@capability.requires("clock")` İLE ÇAĞRILMAKTAN
/// ZATEN men eder, bu stub'lar SADECE linker'ın sembolleri ÇÖZEBİLMESİ
/// İçİndir (Nox'un "her üst-düzey fonksiyon koşulsuz derlenir" kuralı).
pub const time_shim = @import("stdlib_shims/time.zig");

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

/// v2.0 yol haritası madde 9 (bkz. plan dosyası "Freestanding Allocator
/// ABI"): yukarıdaki `g_kernel_fba`nın SABİT 4 MiB'lık `.bss` arabelleği
/// GERÇEK bir kernel PMM'e HİÇ bağlı DEĞİLDİ — bu ABI, bir kernel'in KENDİ
/// fiziksel sayfa allocator'ını (`extern def`/C/asm İLE yazılmış HERHANGİ
/// biri) `nox_allocator_install` ÜZERİNDEN Nox'un yönetilen heap'ine
/// (ARC/list/dict/class TAMAMI) enjekte etmesini sağlar. `alignment` DÜZ
/// bir bayt-sayısı `usize`dır (Zig'e ÖZGÜ `std.mem.Alignment`/`ret_addr`
/// YOK) — `aligned_alloc`/`posix_memalign`nin AYNI, sıradan C sözleşmesi,
/// böylece bir kernel yazarı BUNU Zig'in KENDİ `Allocator.VTable`ını
/// bilmeden implemente EDEBİLİR. Kurulum YAPILMAZSA (`g_kernel_alloc_fn ==
/// null`, VARSAYILAN durum) davranış AŞAĞIDAKİ 4 MiB FBA İLE BİREBİR
/// DEĞİŞMEDEN KALIR — madde 8'in `--target` bayrağının "opt-in, varsayılan
/// DEĞİŞMEZ" disipliniyle AYNI.
///
/// **Güven sınırı notu** (bkz. AGENTS.md §9.5): `alloc_fn`/`free_fn`,
/// Nox'un KENDİ tip/sahiplik garantilerinin DIŞINDA, TAM native yetkiyle
/// çalışır — `extern def`in KENDİSİ gibi, bu fonksiyonların KENDİ doğruluğu/
/// bellek güvenliği BU ABI TARAFINDAN HİÇ doğrulanmaz/sandbox'lanmaz.
pub const NoxKernelAllocFn = *const fn (size: usize, alignment: usize) callconv(.c) ?*anyopaque;
pub const NoxKernelFreeFn = *const fn (ptr: ?*anyopaque, size: usize, alignment: usize) callconv(.c) void;

/// `g_kernel_fba_ready`nin AYNI, ZATEN kabul edilmiş bootstrap-durumu
/// istisnası (bkz. AGENTS.md §2, invariant #6) — freestanding runtime'ın
/// KENDİ tek-seferlik kurulumu İçİn dar bir global, "gizli mutable state"
/// YASAĞININ kapsadığı GENEL runtime durumu DEĞİL.
var g_kernel_alloc_fn: ?NoxKernelAllocFn = null;
var g_kernel_free_fn: ?NoxKernelFreeFn = null;

export fn nox_allocator_install(alloc_fn: NoxKernelAllocFn, free_fn: NoxKernelFreeFn) callconv(.c) void {
    g_kernel_alloc_fn = alloc_fn;
    g_kernel_free_fn = free_fn;
}

fn kernelAllocAdapter(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
    _ = ctx;
    _ = ret_addr;
    const f = g_kernel_alloc_fn orelse return null;
    const raw = f(len, alignment.toByteUnits()) orelse return null;
    return @ptrCast(raw);
}

fn kernelResizeAdapter(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
    _ = ctx;
    _ = memory;
    _ = alignment;
    _ = new_len;
    _ = ret_addr;
    // v1: HER ZAMAN başarısız — sözleşme-yasal (SADECE bir kopyalama
    // MALİYETİ, ASLA bir doğruluk hatası), ABI'yi 2 fonksiyonda TUTAR.
    return false;
}

fn kernelRemapAdapter(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
    _ = ctx;
    _ = memory;
    _ = alignment;
    _ = new_len;
    _ = ret_addr;
    return null;
}

fn kernelFreeAdapter(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
    _ = ctx;
    _ = ret_addr;
    const f = g_kernel_free_fn orelse return;
    f(memory.ptr, memory.len, alignment.toByteUnits());
}

const kernel_vtable: std.mem.Allocator.VTable = .{
    .alloc = kernelAllocAdapter,
    .resize = kernelResizeAdapter,
    .remap = kernelRemapAdapter,
    .free = kernelFreeAdapter,
};

pub export fn nox_runtime_init_freestanding() callconv(.c) ?*anyopaque {
    if (g_kernel_alloc_fn != null) {
        const installed: std.mem.Allocator = .{ .ptr = undefined, .vtable = &kernel_vtable };
        return asap.nox_runtime_init_with_allocator(installed);
    }
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

// v3 sertleştirme yol haritası, madde 5 (bkz. nox-teknik-spesifikasyon.md
// ilgili bölüm): `nox.arch.x86_64` stdlib modülünün TEK, resmi çalışma
// zamanı temeli — port G/Ç (`outb`/`inb`/`outw`/`inw`/`outl`/`inl`) VE
// TEMEL kesme kontrolü (`halt`/`enable_interrupts`/`disable_interrupts`).
// `nox-kernel-demo` (v2.0 madde 10, AYRI repo) reposunun KENDİ, sadece
// KENDİ dosyasına VENDOR EDİLMİŞ `outb`/`inb`/`outl`/`inl`inin (o reponun
// KENDİ belge notu: "Nox'un dilinde ARTIK HİÇBİR port-I/O yerleşiği YOK
// — bu dışa-açık sarmalayıcılar TEK yol") RESMİ, YENİDEN KULLANILABİLİR
// KARŞILIĞI — HER YENİ freestanding x86_64 projesinin AYNI kodu YENİDEN
// yazmasına GEREK KALMAZ. `builtin.cpu.arch == .x86_64` DIŞINDAKİ HER
// hedefte bu fonksiyonların GÖVDESİ hiç ANALİZ EDİLMEZ (bkz. `printf_
// real`in AYNI deseni) — `noxrt-freestanding-generic-aarch64.o` GİBİ
// diğer mimarilerin nesne çıktısı BUNLARI HİÇ İÇERMEZ (derleme HATASI
// da VERMEZ, sadece SESSİZCE atlanır).
//
// **Güven sınırı notu (bkz. AGENTS.md §9.5):** bu fonksiyonlar (`extern
// def` aracılığıyla) `lowlevel:` bloğu GEREKTİRMEDEN Nox'tan çağrılabilir
// — port G/Ç TAMAMEN AYRI, KENDİ güven modeline sahiptir (herhangi bir
// `extern def` GİBİ, ÇIPLAK native yetki). `stdlib/nox/arch/x86_64.nox`
// bunu `nox.arch.x86_64` İSMİYLE saran İNCE bir sarmalayıcıdır.
//
// **`_raw` soneki (bkz. `stdlib/nox/os.nox`nin AYNI, ÖNCEDEN GERÇEKTEN
// yaşanmış tuzağı):** `module_loader.zig`nin `mangleWith`i, `nox.arch.
// x86_64` GİBİ İÇE AKTARILAN BİR stdlib modülünün KENDİ üst-düzey `def`
// adlarını `<modül-yolu>_<ad>` OLARAK mangle EDER — `outb` sarmalayıcısı
// BU YÜZDEN `nox_arch_x86_64_outb` OLUR. `extern def`ler ASLA mangle
// EDİLMEDİĞİNDEN, BU isim BURADAKİ GERÇEK Zig sembolüyle ÇAKIŞIRDI
// ("fonksiyon zaten tanımlı" derleme hatası — BU turda GERÇEKTEN
// karşılaşıldı). `_raw` soneki BU çakışmayı önler.
export fn nox_arch_x86_64_outb_raw(port: u16, value: u8) callconv(.c) void {
    if (comptime builtin.cpu.arch != .x86_64) return;
    asm volatile ("outb %[value], %[port]"
        :
        : [value] "{al}" (value),
          [port] "{dx}" (port),
    );
}

export fn nox_arch_x86_64_inb_raw(port: u16) callconv(.c) u8 {
    if (comptime builtin.cpu.arch != .x86_64) return 0;
    return asm volatile ("inb %[port], %[result]"
        : [result] "={al}" (-> u8),
        : [port] "{dx}" (port),
    );
}

export fn nox_arch_x86_64_outw_raw(port: u16, value: u16) callconv(.c) void {
    if (comptime builtin.cpu.arch != .x86_64) return;
    asm volatile ("outw %[value], %[port]"
        :
        : [value] "{ax}" (value),
          [port] "{dx}" (port),
    );
}

export fn nox_arch_x86_64_inw_raw(port: u16) callconv(.c) u16 {
    if (comptime builtin.cpu.arch != .x86_64) return 0;
    return asm volatile ("inw %[port], %[result]"
        : [result] "={ax}" (-> u16),
        : [port] "{dx}" (port),
    );
}

export fn nox_arch_x86_64_outl_raw(port: u16, value: u32) callconv(.c) void {
    if (comptime builtin.cpu.arch != .x86_64) return;
    asm volatile ("outl %[value], %[port]"
        :
        : [value] "{eax}" (value),
          [port] "{dx}" (port),
    );
}

export fn nox_arch_x86_64_inl_raw(port: u16) callconv(.c) u32 {
    if (comptime builtin.cpu.arch != .x86_64) return 0;
    return asm volatile ("inl %[port], %[result]"
        : [result] "={eax}" (-> u32),
        : [port] "{dx}" (port),
    );
}

/// `sti` — kesmeleri ETKİNLEŞTİRİR. `nox-kernel-demo`nun `nox_timer_
/// start`ının KENDİ İÇİNE gömdüğü `sti`nin AYRI, YENİDEN KULLANILABİLİR
/// karşılığı.
export fn nox_arch_x86_64_enable_interrupts_raw() callconv(.c) void {
    if (comptime builtin.cpu.arch != .x86_64) return;
    asm volatile ("sti");
}

/// `cli` — kesmeleri DEVRE DIŞI bırakır.
export fn nox_arch_x86_64_disable_interrupts_raw() callconv(.c) void {
    if (comptime builtin.cpu.arch != .x86_64) return;
    asm volatile ("cli");
}

/// `hlt` — İşlemciyi BİR SONRAKİ kesmeye kadar durdurur (bkz. `nox-kernel-
/// demo`nun `haltForever`ının AYNI `hlt` talimatı — burada TEK bir çağrı,
/// döngü Nox tarafında YAZILABİLİR).
export fn nox_arch_x86_64_halt_raw() callconv(.c) void {
    if (comptime builtin.cpu.arch != .x86_64) return;
    asm volatile ("hlt");
}

/// v2.0 madde 9 (bkz. plan dosyası "Freestanding Allocator ABI", Faz B):
/// `nox_allocator_install`/`kernel_vtable` mekanizmasını GERÇEK bir
/// QEMU/kernel GEREKMEDEN, host-NATİF bir `zig build test` çalışmasıyla
/// doğrular. TEK bir test fonksiyonunda, SIRALI 2 aşama olarak yazılır
/// (dosya-kapsamlı `g_kernel_fba_ready`/`g_kernel_alloc_fn` PAYLAŞILDIĞINDAN
/// — AYRI `test` bildirimlerine bölmek, Zig'in test-çalıştırma SIRASINA
/// SESSİZCE bağımlı KILARDI).
var g_test_kernel_buf: [64 * 1024]u8 align(std.atomic.cache_line) = undefined;
var g_test_kernel_offset: usize = 0;

fn testKernelAlloc(size: usize, alignment: usize) callconv(.c) ?*anyopaque {
    const base = @intFromPtr(&g_test_kernel_buf);
    const aligned = std.mem.alignForward(usize, base + g_test_kernel_offset, alignment) - base;
    if (aligned + size > g_test_kernel_buf.len) return null;
    g_test_kernel_offset = aligned + size;
    return @ptrFromInt(base + aligned);
}

fn testKernelFree(ptr: ?*anyopaque, size: usize, alignment: usize) callconv(.c) void {
    _ = ptr;
    _ = size;
    _ = alignment;
}

test "nox_runtime_init_freestanding: kurulum öncesi/sonrası doğru arabelleğe düşer" {
    // Aşama 1 — kurulum YOK (varsayılan durum): tahsis `g_kernel_heap_
    // backing`in (4 MiB'lık, SABİT `.bss` arabelleği) ARALIĞINA düşmeli.
    const rt1 = nox_runtime_init_freestanding() orelse return error.InitFailed;
    const rt1_addr = @intFromPtr(rt1);
    const backing_start = @intFromPtr(&g_kernel_heap_backing);
    const backing_end = backing_start + KERNEL_HEAP_BYTES;
    try std.testing.expect(rt1_addr >= backing_start and rt1_addr < backing_end);

    // Aşama 2 — SENTETİK bir kernel allocator `nox_allocator_install` İLE
    // kurulur: tahsis ARTIK O ikinci arabelleğin ARALIĞINA düşmeli, VE
    // adres `@alignOf(RuntimeState)`e (cache-line hizalamalı `pool_free_
    // lists_slot0` alanı YÜZÜNDEN genelde 64 bayt) UYGUN olmalı — bu
    // ABI'nin `alignment` parametresinin (kullanıcının 2. kararı) GERÇEKTEN
    // İŞLEDİĞİNİN kanıtı.
    nox_allocator_install(testKernelAlloc, testKernelFree);
    const rt2 = nox_runtime_init_freestanding() orelse return error.InitFailed;
    const rt2_addr = @intFromPtr(rt2);
    const test_buf_start = @intFromPtr(&g_test_kernel_buf);
    const test_buf_end = test_buf_start + g_test_kernel_buf.len;
    try std.testing.expect(rt2_addr >= test_buf_start and rt2_addr < test_buf_end);
    try std.testing.expectEqual(@as(usize, 0), rt2_addr % @alignOf(asap.RuntimeState));
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
    _ = format;
    _ = dict;
    _ = list_sort;
    _ = list_ops;
    _ = math_shim;
    _ = time_shim;
}
