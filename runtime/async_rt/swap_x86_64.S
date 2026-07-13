/*
 * Nox async runtime — x86-64 (SysV ABI) bağlam değişimi (bkz.
 * nox-teknik-spesifikasyon.md §3.21/Faz R.2). aarch64 sürümünün
 * (`swap_aarch64.S`) AKSİNE, SysV ABI'de callee-saved (çağrı-korumalı)
 * yazmaçlar (rbx, rbp, r12-r15) HER ZAMAN yığın üzerinden `push`/`pop`
 * edilir — bu yüzden `Context` (bkz. fiber.zig) yalnızca TEK bir alan
 * (`sp`) taşır; kaydedilen yazmaçların KENDİSİ fiber'ın KENDİ yığınının
 * İÇİNDE yaşar (aarch64'ün ayrı, düz alanlı `Context`inin AKSİNE).
 *
 * **XMM/YMM yazmaçları KAYDEDİLMEZ:** SysV ABI'de XMM0-15'in TÜMÜ
 * caller-saved'dir (aarch64'ün d8-d15'inin AKSİNE, ki onlar callee-saved'dir
 * ve BU YÜZDEN aarch64 sürümünde AÇIKÇA kaydedilir) — x86-64'te bağlam
 * değişimi İÇİN hiçbir SIMD/float durumu SAKLANMASI GEREKMEZ.
 *
 * `nox_swap_context(old: *Context [rdi], new: *Context [rsi])`:
 *   - Çağrı-korumalı 6 yazmacı (rbp, rbx, r12, r13, r14, r15 — BU SIRAYLA)
 *     KENDİ yığınına `push`lar, SONUÇ `rsp`i `old->sp`e (offset 0) yazar.
 *   - `new->sp`i `rsp`e YÜKLER, AYNI 6 yazmacı TERS sırayla `pop`lar,
 *     `ret` (yığındaki bir SONRAKİ değere atlar — bu, `new`in EN SON
 *     kaydedildiği NOKTAYA ya da fiber.zig'in `Fiber.createWithStack`ının
 *     EL İLE inşa ettiği SAHTE ilk çerçeveye "atlar").
 *
 * **Sahte ilk çerçeve hizalaması (KRİTİK, bkz. fiber.zig'in belge notu):**
 * `Fiber.createWithStack`, İLK KEZ resume edilecek bir fiber İÇİN bu
 * fonksiyonun ÇAĞIRACAĞI `pop` dizisinin BEKLEDİĞİ AYNI 7 sözcüklük
 * (6 yazmaç + dönüş adresi) düzeni YIĞINA elle YAZAR — `ctx.sp`in KENDİSİ
 * bu sahte çerçevenin BAŞLANGICINI (16 bayt hizalı) gösterir.
 */
#if defined(__APPLE__)
#define SYM(name) _##name
#else
#define SYM(name) name
#endif

.text
.balign 16
.globl SYM(nox_swap_context)
SYM(nox_swap_context):
    push %rbp
    push %rbx
    push %r12
    push %r13
    push %r14
    push %r15
    mov %rsp, (%rdi)
    mov (%rsi), %rsp
    pop %r15
    pop %r14
    pop %r13
    pop %r12
    pop %rbx
    pop %rbp
    ret
