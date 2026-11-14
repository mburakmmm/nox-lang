//! `noxrt-freestanding-riscv64.o` (QEMU `virt` çekirdek zinciri, v2.1.151) kök dosyası: `lib_freestanding.zig` + `freestanding/riscv64/kernel.zig`.
//! Kök dosyayı ayırmanın gerekçesi `lib_freestanding_kernel.zig`dedir (kernel koduna yalnızca kernel zinciri bağlansın).

const lib_freestanding = @import("lib_freestanding.zig");
const kernel_riscv64 = @import("freestanding/riscv64/kernel.zig");

comptime {
    _ = lib_freestanding;
    _ = kernel_riscv64;
}
