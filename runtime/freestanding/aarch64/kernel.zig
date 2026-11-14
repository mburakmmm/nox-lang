//! Freestanding aarch64 (QEMU `virt`) çekirdek yardımcıları (v2.1.151, TODO 1.11). `boot.S` `nox_freestanding_early_init`i `main`den önce, `nox_freestanding_halt`ı `main` döndüğünde çağırır.
//! Yalnızca `lib_freestanding_kernel_aarch64.zig` kökünden çekilir; x86_64'ün `kernel.zig`sinin dar karşılığıdır (kesme tablosu/sayfa havuzu yok: MVP = UART çıktısı + yığın havuzu + çıkış).

const std = @import("std");
const diag_sink = @import("diag_sink");
const fiber_mod = @import("../../async_rt/fiber.zig");
const errors_mod = @import("../../errors/handle.zig");

/// QEMU `virt` PL011 UART (DR @ +0x00, FR @ +0x18, TXFF = bit 5). QEMU'da başlatma gerekmez.
const UART_BASE: usize = 0x0900_0000;

inline fn mmioWrite8(addr: usize, v: u8) void {
    @as(*volatile u8, @ptrFromInt(addr)).* = v;
}

inline fn mmioRead32(addr: usize) u32 {
    return @as(*volatile u32, @ptrFromInt(addr)).*;
}

fn uartPutc(c: u8) void {
    while ((mmioRead32(UART_BASE + 0x18) & (1 << 5)) != 0) {}
    mmioWrite8(UART_BASE, c);
}

fn uartDiagSink(rt: ?*anyopaque, bytes: [*]const u8, len: usize) callconv(.c) void {
    _ = rt;
    var i: usize = 0;
    while (i < len) : (i += 1) {
        if (bytes[i] == '\n') uartPutc('\r');
        uartPutc(bytes[i]);
    }
}

/// ARM semihosting `SYS_EXIT_EXTENDED` (0x20): `hlt #0xf000`; QEMU `-semihosting` ile süreç çıkış kodunu `code` yapar.
fn semihostExit(code: u64) noreturn {
    const block = [2]u64{ 0x20026, code }; // ADP_Stopped_ApplicationExit
    asm volatile ("hlt #0xf000"
        :
        : [op] "{x0}" (@as(u64, 0x20)),
          [arg] "{x1}" (@intFromPtr(&block)),
        : .{ .memory = true });
    while (true) asm volatile ("wfe");
}

fn fatalHalt(ctx: ?*anyopaque) noreturn {
    _ = ctx;
    semihostExit(0x11);
}

const fatal_halt_vtable: errors_mod.HaltProviderVTable = .{ .halt = fatalHalt };
const fatal_halt_provider: errors_mod.HaltProvider = .{ .ctx = null, .vtable = &fatal_halt_vtable };

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

export fn nox_freestanding_early_init() callconv(.c) void {
    errors_mod.nox_register_halt_provider(&fatal_halt_provider);
    diag_sink.nox_register_diag_sink(uartDiagSink);
    fiber_mod.nox_register_stack_provider(&fiber_stack_provider);
}

/// `main` döndükten sonra: sıfır çıkış kodu (testin ana iddiası UART çıktısındaki işaretlerdir).
export fn nox_freestanding_halt() callconv(.c) void {
    semihostExit(0);
}
