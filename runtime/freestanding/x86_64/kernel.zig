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
        : .{ .memory = true }
    );
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
}

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
