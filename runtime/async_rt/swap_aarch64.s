/*
 * Nox async runtime — aarch64 (AAPCS64) bağlam değişimi (bkz.
 * nox-teknik-spesifikasyon.md §3.21). Elle yazılmış, minimal bir
 * `swapcontext` benzeri: yalnızca ÇAĞRI-KORUMALI (callee-saved) yazmaçları
 * (x19-x28, x29/fp, x30/lr, sp, d8-d15) kaydeder/geri yükler — çağıran
 * tarafın zaten kendi sorumluluğunda olan çağıran-korumalı (caller-saved)
 * yazmaçlara DOKUNULMAZ (AAPCS64 sözleşmesi zaten bunu garanti eder).
 *
 * `nox_swap_context(old: *Context, new: *Context)`:
 *   - `old`e (x0) MEVCUT bağlamı kaydeder
 *   - `new`den (x1) HEDEF bağlamı yükler
 *   - `ret` (yüklenen x30/lr'a) — bu, `new`in EN SON kaydedildiği (ya da
 *     ilk kez inşa edildiği, bkz. fiber.zig'in `trampoline`ı) noktaya
 *     "atlar".
 *
 * Context alan düzeni (bkz. runtime/async_rt/fiber.zig, `Context`):
 *   0:x19 8:x20 16:x21 24:x22 32:x23 40:x24 48:x25 56:x26 64:x27 72:x28
 *   80:fp 88:lr 96:sp
 *   104:d8 112:d9 120:d10 128:d11 136:d12 144:d13 152:d14 160:d15
 */
.text
.balign 4
.globl _nox_swap_context
_nox_swap_context:
    mov x9, sp
    str x9,  [x0, #96]
    str x19, [x0, #0]
    str x20, [x0, #8]
    str x21, [x0, #16]
    str x22, [x0, #24]
    str x23, [x0, #32]
    str x24, [x0, #40]
    str x25, [x0, #48]
    str x26, [x0, #56]
    str x27, [x0, #64]
    str x28, [x0, #72]
    str x29, [x0, #80]
    str x30, [x0, #88]
    str d8,  [x0, #104]
    str d9,  [x0, #112]
    str d10, [x0, #120]
    str d11, [x0, #128]
    str d12, [x0, #136]
    str d13, [x0, #144]
    str d14, [x0, #152]
    str d15, [x0, #160]

    ldr x19, [x1, #0]
    ldr x20, [x1, #8]
    ldr x21, [x1, #16]
    ldr x22, [x1, #24]
    ldr x23, [x1, #32]
    ldr x24, [x1, #40]
    ldr x25, [x1, #48]
    ldr x26, [x1, #56]
    ldr x27, [x1, #64]
    ldr x28, [x1, #72]
    ldr x29, [x1, #80]
    ldr x30, [x1, #88]
    ldr x9,  [x1, #96]
    mov sp, x9
    ldr d8,  [x1, #104]
    ldr d9,  [x1, #112]
    ldr d10, [x1, #120]
    ldr d11, [x1, #128]
    ldr d12, [x1, #136]
    ldr d13, [x1, #144]
    ldr d14, [x1, #152]
    ldr d15, [x1, #160]
    ret
