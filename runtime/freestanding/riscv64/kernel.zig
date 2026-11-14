//! Freestanding riscv64 (QEMU `virt`, `-bios none`) çekirdek yardımcıları (v2.1.151, TODO 1.11). `boot.S` `nox_freestanding_early_init`i `main`den önce, `nox_freestanding_halt`ı `main` döndüğünde
//! çağırır. aarch64 karşılığıyla (`freestanding/aarch64/kernel.zig`) aynı sözleşme; yalnızca UART (NS16550 @ 0x10000000) ve çıkış (SiFive test finisher @ 0x100000) farklıdır.

const std = @import("std");
const diag_sink = @import("diag_sink");
const fiber_mod = @import("../../async_rt/fiber.zig");
const errors_mod = @import("../../errors/handle.zig");

const UART_BASE: usize = 0x1000_0000;
const TEST_FINISHER: usize = 0x10_0000;

inline fn mmioWrite8(addr: usize, v: u8) void {
    @as(*volatile u8, @ptrFromInt(addr)).* = v;
}

inline fn mmioRead8(addr: usize) u8 {
    return @as(*volatile u8, @ptrFromInt(addr)).*;
}

fn uartPutc(c: u8) void {
    while ((mmioRead8(UART_BASE + 5) & 0x20) == 0) {} // LSR.THRE
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

/// SiFive test finisher: `0x5555` = başarı (çıkış 0), `(kod << 16) | 0x3333` = hata (çıkış kodu `kod`).
fn finisherExit(code: u32) noreturn {
    const v: u32 = if (code == 0) 0x5555 else ((code << 16) | 0x3333);
    @as(*volatile u32, @ptrFromInt(TEST_FINISHER)).* = v;
    while (true) asm volatile ("wfi");
}

fn fatalHalt(ctx: ?*anyopaque) noreturn {
    _ = ctx;
    finisherExit(0x11);
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

export fn nox_freestanding_halt() callconv(.c) void {
    finisherExit(0);
}
