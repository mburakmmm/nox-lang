/*
 * Nox async runtime — riscv64 (LP64D, Linux psABI) bağlam değişimi.
 * Yalnızca çağrı-korumalı yazmaçlar: s0–s11 (x8, x9, x18–x27), ra, sp,
 * fs0–fs11 (f8–f19). Çağıranın sorumluluğundaki yazmaçlara dokunulmaz.
 * gp (x3) ve tp (x4) aynı işletim sistemi iş parçacığında değişmez;
 * kaydedilmez.
 *
 * `nox_swap_context(old: *Context, new: *Context)` — a0 eski, a1 yeni.
 * `ret`, yüklenen ra'ya gider. İlk açılışta ra `trampoline`, s1 ise
 * `Fiber` işaretçisidir (bkz. fiber.zig `createWithStack`).
 *
 * Context ofsetleri (fiber.zig, riscv64 `Context`):
 *   0:s1 8:s2 16:s3 24:s4 32:s5 40:s6 48:s7 56:s8 64:s9 72:s10 80:s11
 *   88:s0/fp 96:ra 104:sp
 *   112:fs0 … 200:fs11  (her biri 8 bayt)
 */
#if defined(__APPLE__)
#define SYM(name) _##name
#else
#define SYM(name) name
#endif

.text
.balign 4
.globl SYM(nox_swap_context)
SYM(nox_swap_context):
    sd s1,  0(a0)
    sd s2,  8(a0)
    sd s3,  16(a0)
    sd s4,  24(a0)
    sd s5,  32(a0)
    sd s6,  40(a0)
    sd s7,  48(a0)
    sd s8,  56(a0)
    sd s9,  64(a0)
    sd s10, 72(a0)
    sd s11, 80(a0)
    sd s0,  88(a0)
    sd ra,  96(a0)
    sd sp,  104(a0)
    fsd fs0,  112(a0)
    fsd fs1,  120(a0)
    fsd fs2,  128(a0)
    fsd fs3,  136(a0)
    fsd fs4,  144(a0)
    fsd fs5,  152(a0)
    fsd fs6,  160(a0)
    fsd fs7,  168(a0)
    fsd fs8,  176(a0)
    fsd fs9,  184(a0)
    fsd fs10, 192(a0)
    fsd fs11, 200(a0)

    ld s1,  0(a1)
    ld s2,  8(a1)
    ld s3,  16(a1)
    ld s4,  24(a1)
    ld s5,  32(a1)
    ld s6,  40(a1)
    ld s7,  48(a1)
    ld s8,  56(a1)
    ld s9,  64(a1)
    ld s10, 72(a1)
    ld s11, 80(a1)
    ld s0,  88(a1)
    ld ra,  96(a1)
    ld t0,  104(a1)
    fld fs0,  112(a1)
    fld fs1,  120(a1)
    fld fs2,  128(a1)
    fld fs3,  136(a1)
    fld fs4,  144(a1)
    fld fs5,  152(a1)
    fld fs6,  160(a1)
    fld fs7,  168(a1)
    fld fs8,  176(a1)
    fld fs9,  184(a1)
    fld fs10, 192(a1)
    fld fs11, 200(a1)
    mv sp, t0
    ret
