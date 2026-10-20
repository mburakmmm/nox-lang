# ADR-MOB-005 Bağlama

Durum: kabul.

## Karar

iOS çıktısı statik arşivdir. Android çıktısı konumdan bağımsız `libnoxapp.so` olur ve ELF yük hizası en az 16 KiB'dir. İndirilen kod JIT veya `dlopen` ile çalıştırılmaz. Skia Aura deposundadır; bu depo onu gömmez. Lisans ve SBOM, kullanılan Skia arşivinin kendi bildirimine aittir.

## Reddedilen

iOS'ta paylaşılan kütüphane ve Android'de çalışma anında inen kod. Geri alma: emit bayraklarını kapatmak.
