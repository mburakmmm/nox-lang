#include <stdio.h>

/* check() basarili olursa 0 doner ve *out'a x*2 yazar; "x%3==0" durumunda
   (nox/py'nin raise ettigi durum) 1 doner ve *out'a x (istisna degeri)
   yazar - idiomatic C'nin exception yerine kullandigi sentinel-donus-kodu
   deseni. (setjmp/longjmp DE denendi - macOS/arm64'te ~2.9s/5M cagri,
   dusuk seviyeli context kaydetme/geri yukleme maliyeti yuzunden -
   bu, gercek C kodunun rutin kontrol akisi icin bu mekanizmayi NEDEN
   neredeyse hic kullanmadigini gosteriyor; bu yuzden benchmark, gercek
   C programcilarinin bu is icin GERCEKTEN yazacagi deyimi kullanir.) */
int check(long long x, long long *out) {
    if (x % 3 == 0) {
        *out = x;
        return 1;
    }
    *out = x * 2;
    return 0;
}

long long compute(long long n) {
    long long total = 0;
    long long i = 0;
    while (i < n) {
        long long value;
        check(i, &value);
        total += value;
        total += 1;
        i++;
    }
    return total;
}

int main(void) {
    printf("%lld\n", compute(5000000));
    return 0;
}
