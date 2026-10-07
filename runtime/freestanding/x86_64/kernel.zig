//! Faz F.4 (bkz. plan dosyası "Gerçek bare-metal boot zinciri (x86_64)"):
//! x86_64'e ÖZGÜ HER ŞEY BURADA yaşar — `runtime/lib_freestanding.zig`ye
//! SADECE `builtin.cpu.arch == .x86_64` İKEN (Zig'in tembel-analiz
//! modeliyle) force-ref edilir, aarch64 host'un KENDİ freestanding
//! zinciri BU dosyayı HİÇ GÖRMEZ.
//!
//! `boot.S`nin `long_mode_start`ı, `main`e atlamadan HEMEN ÖNCE, TEK bir
//! Zig bootstrap noktasını (`nox_freestanding_early_init`) çağırır — seri
//! port başlatma + `diag_sink` kaydı + PIC maskeleme + IDT kurulumu.

const std = @import("std");
const diag_sink = @import("diag_sink");
/// v4 Faz C (bkz. nox-teknik-spesifikasyon.md §3.2xx): `spawn`/`await`nin
/// freestanding'de GERÇEKTEN uçtan uca çalışması İçİn (madde 1'in 2 GERÇEK
/// hatasını — TLS/`threadlocal` çökmesi + `moduleUsesAsync`nin aşırı-geniş
/// `.generic_construct` kontrolü — düzelttikten SONRA KEŞFEDİLEN üçüncü,
/// AYRI bir eksik: fiber yığını ayırmak İçİn bir "stack provider" HİÇ
/// kayıtlı DEĞİLDİ, `nox_async_spawn` HER ZAMAN `error.StackAllocFailed`
/// İLE temiz bir `@panic`/`@trap()`e (#UD) düşüyordu) — `runtime/async_rt/
/// fiber.zig`nin `StackProvider` arayüzü (`nox_allocator_install`ın GENEL
/// heap İçİn yaptığının AYNISI, AMA fiber yığınları İçİn) BURADA somutlaştırılır.
const fiber_mod = @import("../../async_rt/fiber.zig");

// ---------------------------------------------------------------------
// `outb`/`inb` — Zig 0.16'nın inline-asm sözdizimi doğrudan
// `/opt/homebrew/Cellar/zig/0.16.0_1/lib/zig/std/zig/system/x86.zig:755-783`
// (`cpuid`/`getXCR0`) referans alınarak doğrulandı: `"={eax}"`/`"{eax}"`
// operand kısıtları, `.{ .edx = true }` struct-literal clobber'lar.
// ---------------------------------------------------------------------

pub inline fn outb(port: u16, value: u8) void {
    asm volatile ("outb %[value], %[port]"
        :
        : [value] "{al}" (value),
          [port] "{dx}" (port),
    );
}

pub inline fn inb(port: u16) u8 {
    return asm volatile ("inb %[port], %[result]"
        : [result] "={al}" (-> u8),
        : [port] "{dx}" (port),
    );
}

// ---------------------------------------------------------------------
// 16550 UART (COM1, I/O port 0x3F8) — standart init dizisi.
// ---------------------------------------------------------------------
const COM1: u16 = 0x3F8;

fn serialInit() void {
    outb(COM1 + 1, 0x00); // kesmeleri kapat
    outb(COM1 + 3, 0x80); // DLAB=1
    outb(COM1 + 0, 0x03); // bölen düşük bayt (115200 / 3 = 38400 baud)
    outb(COM1 + 1, 0x00); // bölen yüksek bayt
    outb(COM1 + 3, 0x03); // DLAB=0, 8N1
    outb(COM1 + 2, 0xC7); // FIFO etkin, temizle, 14-baytlık eşik
    outb(COM1 + 4, 0x0B); // DTR|RTS|OUT2
}

fn serialTxReady() bool {
    return (inb(COM1 + 5) & 0x20) != 0;
}

fn serialPutc(c: u8) void {
    while (!serialTxReady()) {}
    outb(COM1, c);
}

/// `diag_sink.DiagSinkFn` imzasına uyan fonksiyon — `\n`'yi `\r\n`'ye
/// çevirir (gerçek terminaller İçİn).
fn serialDiagSink(rt: ?*anyopaque, bytes: [*]const u8, len: usize) callconv(.c) void {
    _ = rt;
    var i: usize = 0;
    while (i < len) : (i += 1) {
        if (bytes[i] == '\n') serialPutc('\r');
        serialPutc(bytes[i]);
    }
}

// ---------------------------------------------------------------------
// IDT — minimal, hata-raporlayan (bkz. plan dosyasının madde 5'i).
// ---------------------------------------------------------------------

const IdtEntry = extern struct {
    offset_low: u16,
    selector: u16,
    ist: u8,
    type_attr: u8,
    offset_mid: u16,
    offset_high: u32,
    reserved: u32,
};

const IDT_ENTRY_COUNT = 256;
var g_idt: [IDT_ENTRY_COUNT]IdtEntry align(16) = undefined;

extern const nox_isr_table: [32]usize;

fn setIdtEntry(vec: usize, handler: usize) void {
    g_idt[vec] = .{
        .offset_low = @truncate(handler),
        .selector = 0x08,
        .ist = 0,
        .type_attr = 0x8E, // P=1, DPL=0, type=0xE (64-bit interrupt gate)
        .offset_mid = @truncate(handler >> 16),
        .offset_high = @truncate(handler >> 32),
        .reserved = 0,
    };
}

fn idtInstall() void {
    @memset(g_idt[0..], std.mem.zeroes(IdtEntry));
    for (0..32) |vec| setIdtEntry(vec, nox_isr_table[vec]);

    const IdtPtr = extern struct { limit: u16 align(1), base: u64 align(1) };
    var ptr: IdtPtr = .{ .limit = @sizeOf(@TypeOf(g_idt)) - 1, .base = @intFromPtr(&g_idt) };
    asm volatile ("lidt (%[p])"
        :
        : [p] "r" (&ptr),
        : .{ .memory = true });
}

fn picMaskAll() void {
    outb(0x21, 0xFF);
    outb(0xA1, 0xFF);
}

fn haltForever() noreturn {
    while (true) {
        asm volatile ("cli");
        asm volatile ("hlt");
    }
}

/// `boot.S`nin `nox_isr_common`i TARAFINDAN ÇAĞRILIR. `vec==3` (`#BP`)
/// TEK GERİ-DÖNEN handler — `int3` bir TRAP olduğundan (kaydedilen RIP
/// komuttan SONRAYI gösterir) dönmek GÜVENLİDİR VE IDT'nin GERÇEKTEN
/// ateşlediğini, çekirdeği DURDURMADAN kanıtlar. DİĞER TÜM vektörler
/// FAULT sayılır (dönmek sonsuz döngü olurdu, RIP hatalı komutu gösterir)
/// — rapor edilip `haltForever()` çağrılır.
export fn nox_isr_dispatch(vec: u64, err: u64, rip: u64) callconv(.c) void {
    if (vec == 3) {
        diag_sink.report(null, "IDT_BP_OK vector=3 rip=0x{x}\n", .{rip});
        return;
    }
    diag_sink.report(null, "KERNEL_FAULT vector={d} err=0x{x} rip=0x{x}\n", .{ vec, err, rip });
    haltForever();
}

/// `boot.S`nin `long_mode_start`ının `main`e atlamadan HEMEN ÖNCE çağırdığı
/// TEK Zig bootstrap noktası.
export fn nox_freestanding_early_init() callconv(.c) void {
    serialInit();
    diag_sink.nox_register_diag_sink(serialDiagSink);
    picMaskAll();
    idtInstall();
    // v2.0 madde 9 (bkz. plan dosyası "Freestanding Allocator ABI"):
    // Nox'un yönetilen heap'ini (list/dict/ARC — HER ŞEY) BU çekirdeğin
    // GERÇEK, aşağıdaki fiziksel sayfa havuzuna (`kernelAlloc`/`kernelFree`)
    // bağlar — `rt` HENÜZ bootstrap EDİLMEDEN (`nox_runtime_init_
    // freestanding` BUNDAN SONRA, `boot.S`nin `main`e atlamasıyla çağrılır)
    // GÜVENLE çalışır, ÇÜNKÜ `kernelAlloc`/`nox_alloc_page`/`ensurePageInit`
    // HİÇBİRİ `rt`ye ihtiyaç DUYMAZ (bkz. aşağıdaki bölümün belge notu).
    nox_allocator_install(kernelAlloc, kernelFree);
    // v4 Faz C: fiber yığını sağlayıcısı — AŞAĞIDAKİ `fiberStackAlloc`/
    // `fiberStackFree`, SABİT boyutlu STATİK bir havuzdan (`g_fiber_stack_
    // pool`) hizmet eder. `nox_allocator_install`ın SAYFA-TABANLI genel
    // heap'inin AKSİNE: `fiber.STACK_SIZE` (192 KiB) `kernelAlloc`ın TEK
    // bir isteği İçİn SINADIĞI 4096-bayt sınırını ZATEN AŞAR (kernelAlloc
    // BİLİNÇLİ olarak tek-sayfa-üstü isteği reddeder, bkz. onun belge
    // notu) VE `nox_alloc_page`nin art arda çağrıları FİZİKSEL olarak
    // BİTİŞİK sayfalar GARANTİ ETMEZ (basit bir LIFO serbest-liste) — bir
    // fiber yığınının TEK, BİTİŞİK bir bellek bloğu OLMASI GEREKTİĞİNDEN
    // (yığın işaretçisi aritmetiği BUNU VARSAYAR) SABİT bir statik
    // havuz, BU v1 İçİn EN BASİT/EN GÜVENLİ çözümdür.
    fiber_mod.nox_register_stack_provider(&fiber_stack_provider);
}

// ---------------------------------------------------------------------
// v4 Faz C: fiber yığını sağlayıcısı (`fiber.StackProvider`) — SABİT
// boyutlu, statik bir havuzdan HİZMET eder (`g_kernel_heap_backing`nin
// AYNI "sabit .bss arabelleği" deseni, bkz. `lib_freestanding.zig`).
// **v1 sınırı** (AÇIKÇA belgelenir): EN FAZLA `MAX_FIBER_STACKS` (8) EŞ
// ZAMANLI CANLI fiber — freestanding v0.1'in KENDİ kapsamı İçİn (BİR
// kernel demo'su, AĞIR eşzamanlılık HEDEFLEMİYOR) YETERLİ; havuz
// TÜKENİRSE `alloc` `null` döner, `nox_async_spawn` BUNU `error.
// StackAllocFailed`e ÇEVİRİP temiz bir `@panic` İLE sonlanır (sessiz
// bir bellek bozulması DEĞİL).
// ---------------------------------------------------------------------

const MAX_FIBER_STACKS = 8;
var g_fiber_stack_pool: [MAX_FIBER_STACKS][fiber_mod.STACK_SIZE]u8 align(fiber_mod.STACK_ALIGN) = undefined;
var g_fiber_stack_used: [MAX_FIBER_STACKS]bool = @splat(false);

fn fiberStackAlloc(ctx: ?*anyopaque) ?[]align(fiber_mod.STACK_ALIGN) u8 {
    _ = ctx;
    for (&g_fiber_stack_used, 0..) |*used, i| {
        if (!used.*) {
            used.* = true;
            return &g_fiber_stack_pool[i];
        }
    }
    return null;
}

fn fiberStackFree(ctx: ?*anyopaque, stack: []align(fiber_mod.STACK_ALIGN) u8) void {
    _ = ctx;
    const base = @intFromPtr(stack.ptr);
    for (&g_fiber_stack_pool, 0..) |*slot, i| {
        if (@intFromPtr(slot) == base) {
            g_fiber_stack_used[i] = false;
            return;
        }
    }
}

const fiber_stack_vtable: fiber_mod.StackProviderVTable = .{ .alloc = fiberStackAlloc, .free = fiberStackFree };
const fiber_stack_provider: fiber_mod.StackProvider = .{ .ctx = null, .vtable = &fiber_stack_vtable };

/// `runtime/lib_freestanding.zig`nin `export fn nox_allocator_install`ı —
/// AYNI final nesneye (`noxrt-freestanding-x86_64.o`) derlendiğinden,
/// modül-İçİ bir `@import` YERİNE sıradan bir C-ABI `extern fn` BİLDİRİMİ
/// YETERLİ (`kernel_demo.nox`nin `extern def ... from "..."`ının AYNI
/// ilkesi, AMA link-time çözümlemesi AYNI derleme İçİnde olur).
extern fn nox_allocator_install(
    alloc_fn: *const fn (size: usize, alignment: usize) callconv(.c) ?*anyopaque,
    free_fn: *const fn (ptr: ?*anyopaque, size: usize, alignment: usize) callconv(.c) void,
) callconv(.c) void;

/// `boot.S`nin `main`den DÖNDÜKTEN SONRA çağırdığı, QEMU `isa-debug-exit`
/// mekanizmasını (GERÇEK donanımda ETKİSİZ bir ISA portu) kullanan çıkış
/// noktası — `0x10` yazmak QEMU'yu `(0x10<<1)|1 = 33` çıkış koduyla
/// sonlandırır.
export fn nox_freestanding_halt() callconv(.c) void {
    outb(0xF4, 0x10);
    haltForever();
}

// ---------------------------------------------------------------------
// Nox-çağrılabilir yardımcılar (madde 6'nın fiziksel sayfa allocator'ı
// İçİn) — `extern def ... from "zig-out/lib/noxrt-freestanding-x86_64.o"`
// İLE `kernel_demo.nox`dan doğrudan çağrılır.
// ---------------------------------------------------------------------

extern const _kernel_end: u8;

/// `_kernel_end`i 4K'ya YUKARI yuvarlar — fiziksel sayfa allocator'ının
/// TABANI.
export fn nox_kernel_phys_base() callconv(.c) i64 {
    const raw: usize = @intFromPtr(&_kernel_end);
    const aligned = (raw + 0xFFF) & ~@as(usize, 0xFFF);
    return @intCast(aligned);
}

/// SABİT 32MiB — `boot.S`nin `PD_ENTRIES=16` (0..32MiB identity-map) İLE
/// EŞLEŞMELİDİR.
export fn nox_kernel_phys_limit() callconv(.c) i64 {
    return 32 * 1024 * 1024;
}

export fn nox_kernel_trigger_breakpoint() callconv(.c) void {
    asm volatile ("int3");
}

// ---------------------------------------------------------------------
// v2.0 madde 9 (bkz. plan dosyası "Freestanding Allocator ABI"): GERÇEK,
// `rt`-BAĞIMSIZ bir fiziksel sayfa serbest-listesi — `kernel_demo.nox`nin
// KENDİ `page_init`/`alloc_page`/`free_page`/`free_pages`ının (SAF Nox'ta
// yazılmış, `lowlevel:`+`ptr_*` ÜZERİNDEN, "kontrol sayfası" hilesiyle
// durum tutan) BİREBİR algoritmik karşılığı — AMA durum BURADA düz Zig
// dosya-kapsamlı `var`larında (Zig'in KENDİSİ SORUNSUZ, "kontrol sayfası"
// hilesi GEREKMEZ). `rt`ye (RuntimeState) HİÇ ihtiyaç DUYMADIĞINDAN,
// `nox_freestanding_early_init`in bootstrap SIRASINDA GÜVENLE çağrılabilir
// — `alloc_page()`nin DERLENMİŞ Nox gövdesinin (`nox_arena_create(rt)`/
// `nox_arena_destroy(rt)` çağırdığı, bu YÜZDEN GEÇERLİ bir `rt` OLMADAN
// ÇÖKECEĞİ, BU turda GERÇEK assembly OKUNARAK bulunan) tavuk-yumurta
// SORUNUNUN çözümü.
// ---------------------------------------------------------------------

var g_page_init_done: bool = false;
var g_page_head: i64 = 0;
var g_page_free_count: i64 = 0;
var g_page_total: i64 = 0;

/// İDEMPOTENT: HEM `nox_freestanding_early_init` (bootstrap SIRASINDA)
/// HEM `kernel_demo.nox`nin KENDİ `page_init()` sarmalayıcısı (managed Nox
/// koşarken) BUNU ÇAĞIRABİLİR — İKİNCİ çağrı serbest listeyi SIFIRLAMAZ
/// (aksi halde bootstrap SIRASINDA ZATEN dağıtılmış sayfalar YETİM kalırdı).
fn ensurePageInit() void {
    if (g_page_init_done) return;
    g_page_init_done = true;
    const base = nox_kernel_phys_base();
    const limit = nox_kernel_phys_limit();
    // `kernel_demo.nox`nin ESKİ algoritmasıyla BİREBİR: İLK sayfa (`base`)
    // BİLİNÇLİ olarak serbest listeye DAHİL EDİLMEZ (ESKİ implementasyonda
    // "kontrol sayfası" olarak KULLANILIYORDU — BURADA durum Zig `var`
    // larında OLDUĞUNDAN o sayfa ARTIK kullanılmıyor, AMA sayı/davranış
    // PARİTESİ İçİn AYNI TABAN kaydırması KORUNUR).
    const first_page = base + 4096;
    const count: i64 = @divTrunc(limit - first_page, 4096);
    var head: i64 = 0;
    if (count > 0) head = first_page;
    var i: i64 = 0;
    while (i < count) : (i += 1) {
        const page_addr = first_page + i * 4096;
        var next_addr: i64 = 0;
        if (i < count - 1) next_addr = first_page + (i + 1) * 4096;
        const page_ptr: *i64 = @ptrFromInt(@as(usize, @intCast(page_addr)));
        page_ptr.* = next_addr;
    }
    g_page_head = head;
    g_page_free_count = count;
    g_page_total = count;
}

export fn nox_page_init() callconv(.c) i64 {
    ensurePageInit();
    return g_page_total;
}

export fn nox_alloc_page() callconv(.c) i64 {
    ensurePageInit();
    if (g_page_head == 0) return 0;
    const head = g_page_head;
    const next_ptr: *i64 = @ptrFromInt(@as(usize, @intCast(head)));
    g_page_head = next_ptr.*;
    g_page_free_count -= 1;
    return head;
}

export fn nox_free_page(addr: i64) callconv(.c) void {
    ensurePageInit();
    const page_ptr: *i64 = @ptrFromInt(@as(usize, @intCast(addr)));
    page_ptr.* = g_page_head;
    g_page_head = addr;
    g_page_free_count += 1;
}

export fn nox_free_pages() callconv(.c) i64 {
    ensurePageInit();
    return g_page_free_count;
}

/// Basit bir bump/sayfa-üstü katman — Nox'un yönetilen heap'inin
/// DEĞİŞKEN boyutlu isteklerini (`nox_alloc_page`nin SADECE SABİT
/// 4096-baytlık sayfalar VERMESİNE karşılık) `nox_allocator_install`
/// ABI'sine (bkz. `lib_freestanding.zig`) bağlar.
var g_bump_page: i64 = 0;
var g_bump_offset: usize = 0;

/// **v1 sınırı** (AÇIKÇA belgelenir, bkz. plan dosyasının "Kapsam DIŞI"
/// bölümü): `size`/`alignment` bir sayfadan (4096 bayt) BÜYÜKSE `null`
/// döner — çoklu-sayfa BİTİŞİK ayırma DESTEKLENMEZ (`kernel_demo.nox`nin
/// KENDİ kullanımı, küçük `list[int]`, BUNA HİÇ ihtiyaç DUYMUYOR).
fn kernelAlloc(size: usize, alignment: usize) callconv(.c) ?*anyopaque {
    if (alignment > 4096 or size > 4096) return null;
    const page_base: usize = if (g_bump_page != 0) @intCast(g_bump_page) else 0;
    const aligned_offset = if (g_bump_page != 0) std.mem.alignForward(usize, page_base + g_bump_offset, alignment) - page_base else 0;
    if (g_bump_page == 0 or aligned_offset + size > 4096) {
        const p = nox_alloc_page();
        if (p == 0) return null;
        g_bump_page = p;
        const new_base: usize = @intCast(p);
        const new_aligned_offset = std.mem.alignForward(usize, new_base, alignment) - new_base;
        if (new_aligned_offset + size > 4096) return null;
        g_bump_offset = new_aligned_offset + size;
        return @ptrFromInt(new_base + new_aligned_offset);
    }
    g_bump_offset = aligned_offset + size;
    return @ptrFromInt(page_base + aligned_offset);
}

/// **v1 sınırı** (AÇIKÇA belgelenir): bump-İçİ sub-page geri-kazanım YOK —
/// SADECE tam-sayfa granülerliğinde geri kazanım VAR (`nox_free_page`
/// ÜZERİNDEN, bu bump katmanı TARAFINDAN ŞU AN hiç ÇAĞRILMAZ). Bu HER
/// ZAMAN sözleşme-yasal bir seçimdir (SADECE bellek İSRAFI, ASLA bir
/// doğruluk hatası).
fn kernelFree(ptr: ?*anyopaque, size: usize, alignment: usize) callconv(.c) void {
    _ = ptr;
    _ = size;
    _ = alignment;
}
