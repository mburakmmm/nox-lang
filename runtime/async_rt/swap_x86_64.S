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

#if defined(_WIN32)
/*
 * Faz LL.3 (bkz. nox-teknik-spesifikasyon.md §3.71): Windows x64 çağrı
 * kuralı SysV'den İKİ yönden FARKLIDIR — (1) callee-saved (çağrı-korumalı)
 * GENEL AMAÇLI yazmaç kümesi FARKLIDIR: SysV'nin rbp/rbx/r12-r15'ine EK
 * olarak Win64'te rdi/rsi de ÇAĞRI-KORUMALIDIR (SysV'de İKİSİ de çağıran-
 * korumalıdır); (2) Win64'te XMM6-XMM15 ÇAĞRI-KORUMALIDIR (SysV'nin AKSİNE,
 * ki ORADA TÜM XMM0-15 çağıran-korumalıdır — bkz. bu dosyanın SysV
 * gövdesinin belge notu, "XMM/YMM yazmaçları KAYDEDİLMEZ") — bu YÜZDEN
 * Windows dalı AYRICA XMM6-15'i (10 × 16 bayt = 160 bayt) KAYDETMEK
 * ZORUNDADIR, aksi halde bir fiber-değişimi SIRASINDA CANLI bir kayan-
 * noktalı değer SESSİZCE bozulabilir. `movdqu` (hizasız) KULLANILIR —
 * hizalama GARANTİSİ gerekmez, yalnızca DOĞRU bayt-ofsetleri gerekir.
 * İlk argüman (`old`) rcx'te, ikinci (`new`) rdx'tedir (SysV'nin rdi/rsi'sinin
 * AKSİNE).
 *
 * **Sahte ilk çerçeve** (bkz. `fiber.zig`nin `createWithStack`ının Windows
 * dalı) AYNI 232 baytlık düzeni (160 xmm + 8×8 gpr + 8 dönüş adresi) ELLE
 * yazar — `rbx`, SysV dalıyla AYNI "kaçak self işaretçisi" hilesini taşır
 * (`trampoline`in KENDİSİ zaten platform-bağımsız, yalnızca rbx okur).
 */
.text
.balign 16
.globl SYM(nox_swap_context)
SYM(nox_swap_context):
    push %rbp
    push %rbx
    push %rdi
    push %rsi
    push %r12
    push %r13
    push %r14
    push %r15
    sub $160, %rsp
    movdqu %xmm6, 0(%rsp)
    movdqu %xmm7, 16(%rsp)
    movdqu %xmm8, 32(%rsp)
    movdqu %xmm9, 48(%rsp)
    movdqu %xmm10, 64(%rsp)
    movdqu %xmm11, 80(%rsp)
    movdqu %xmm12, 96(%rsp)
    movdqu %xmm13, 112(%rsp)
    movdqu %xmm14, 128(%rsp)
    movdqu %xmm15, 144(%rsp)
    mov %rsp, (%rcx)
    mov (%rdx), %rsp
    movdqu 0(%rsp), %xmm6
    movdqu 16(%rsp), %xmm7
    movdqu 32(%rsp), %xmm8
    movdqu 48(%rsp), %xmm9
    movdqu 64(%rsp), %xmm10
    movdqu 80(%rsp), %xmm11
    movdqu 96(%rsp), %xmm12
    movdqu 112(%rsp), %xmm13
    movdqu 128(%rsp), %xmm14
    movdqu 144(%rsp), %xmm15
    add $160, %rsp
    pop %r15
    pop %r14
    pop %r13
    pop %r12
    pop %rsi
    pop %rdi
    pop %rbx
    pop %rbp
    ret
#else
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
#endif
