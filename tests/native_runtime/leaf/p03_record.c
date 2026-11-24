/* P03 harness: Nox'un sizeof/alignof/offsetof sonuclari == C struct; bayt deseni + kanarya. */
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
typedef int64_t w;
/* Nox'un @repr("C") sinif nesnesi: 8 B ARC baslik yuvasi + alanlar (offsetof/sizeof baslik DAHIL). */
typedef struct { uint64_t arc_hdr; uint32_t rc; uint32_t flags; int64_t len; void *data; } RawHdr;
extern size_t rec_size(w rt);
extern size_t rec_align(w rt);
extern size_t rec_off_len(w rt);
extern size_t rec_off_data(w rt);
extern w rec_get_len(w rt, void *p);
extern void rec_set_len(w rt, void *p, w v);
extern w rec_get_data(w rt, void *p);
extern void rec_set_data(w rt, void *p, w v);
int main(void) {
    if (rec_size(0) != sizeof(RawHdr)) return 10;
    if (rec_align(0) != _Alignof(RawHdr)) return 11;
    if (rec_off_len(0) != offsetof(RawHdr, len)) return 12;
    if (rec_off_data(0) != offsetof(RawHdr, data)) return 13;
    struct { RawHdr h; uint64_t canary; } s;
    memset(&s, 0xAB, sizeof s);
    s.h.rc = 7; s.h.flags = 9; s.canary = 0xC0FFEE;
    rec_set_len(0, &s.h, 123456789012345LL);
    rec_set_data(0, &s.h, (w)(intptr_t)&s);
    if (s.h.len != 123456789012345LL || s.h.data != (void *)&s) return 14;
    if (rec_get_len(0, &s.h) != s.h.len || rec_get_data(0, &s.h) != (w)(intptr_t)s.h.data) return 15;
    if (s.h.rc != 7 || s.h.flags != 9 || s.canary != 0xC0FFEE) return 16; /* komsu alanlara tasma yok */
    puts("ok");
    return 0;
}
