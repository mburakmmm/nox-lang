# selfhost perf raporu

Komut: `noxc-nightly`, runs=3, reps=10; süreler µs, ölçümlerin MEDYANI (min / yayılım %).

| senaryo | boyut | aşama | Zig medyan | Nox medyan | Nox/Zig | Nox min | yayılım % |
|---|---|---|---|---|---|---|---|
| 1 büyük korpus (stdlib+selfhost, ~1 MB) | 973 KB | lexer | 4980 | 2716 | 0.55× | 2656 | 4 |
| 1 büyük korpus (stdlib+selfhost, ~1 MB) | 973 KB | parse (lexer dahil) | 11849 | 8267 | 0.70× | 8204 | 2 |
| 1 büyük korpus (stdlib+selfhost, ~1 MB) | 973 KB | fmt hattı (lexer+parse dahil) | 15802 | 10889 | 0.69× | 10868 | 0 |
| 1 büyük korpus (stdlib+selfhost, ~1 MB) | | yalnız parse (parse−lexer) | 6869 | 5551 | 0.81× | | |
| 1 büyük korpus (stdlib+selfhost, ~1 MB) | | yalnız biçimleme (fmt−parse) | 3953 | 2622 | 0.66× | | |
| 1 büyük korpus (stdlib+selfhost, ~1 MB) | | köprü (Token dönüşümü) | | +644 | | | |
| 1 büyük korpus (stdlib+selfhost, ~1 MB) | | Nox ARC blok (parse, 10 tekrar toplamı) | | 684830 | | | |
| 2 küçük tek dosya (json.nox) | 25 KB | lexer | 84 | 49 | 0.58× | 49 | 6 |
| 2 küçük tek dosya (json.nox) | 25 KB | parse (lexer dahil) | 195 | 155 | 0.79× | 152 | 2 |
| 2 küçük tek dosya (json.nox) | 25 KB | fmt hattı (lexer+parse dahil) | 242 | 197 | 0.81× | 196 | 1 |
| 2 küçük tek dosya (json.nox) | | yalnız parse (parse−lexer) | 111 | 106 | 0.95× | | |
| 2 küçük tek dosya (json.nox) | | yalnız biçimleme (fmt−parse) | 47 | 42 | 0.89× | | |
| 2 küçük tek dosya (json.nox) | | köprü (Token dönüşümü) | | +13 | | | |
| 2 küçük tek dosya (json.nox) | | Nox ARC blok (parse, 10 tekrar toplamı) | | 15920 | | | |
| 3 orta (~100 KB) | 97 KB | lexer | 462 | 228 | 0.49× | 216 | 7 |
| 3 orta (~100 KB) | 97 KB | parse (lexer dahil) | 1005 | 745 | 0.74× | 739 | 1 |
| 3 orta (~100 KB) | 97 KB | fmt hattı (lexer+parse dahil) | 1214 | 963 | 0.79× | 956 | 2 |
| 3 orta (~100 KB) | | yalnız parse (parse−lexer) | 543 | 517 | 0.95× | | |
| 3 orta (~100 KB) | | yalnız biçimleme (fmt−parse) | 209 | 218 | 1.04× | | |
| 3 orta (~100 KB) | | köprü (Token dönüşümü) | | +74 | | | |
| 3 orta (~100 KB) | | Nox ARC blok (parse, 10 tekrar toplamı) | | 69060 | | | |
| 4 çok kısa deyim (200k satır) | 2148 KB | lexer | 21029 | 8924 | 0.42× | 8904 | 0 |
| 4 çok kısa deyim (200k satır) | 2148 KB | parse (lexer dahil) | 49128 | 37925 | 0.77× | 37656 | 1 |
| 4 çok kısa deyim (200k satır) | 2148 KB | fmt hattı (lexer+parse dahil) | 54793 | 48715 | 0.89× | 47720 | 2 |
| 4 çok kısa deyim (200k satır) | | yalnız parse (parse−lexer) | 28099 | 29001 | 1.03× | | |
| 4 çok kısa deyim (200k satır) | | yalnız biçimleme (fmt−parse) | 5665 | 10790 | 1.90× | | |
| 4 çok kısa deyim (200k satır) | | köprü (Token dönüşümü) | | +3933 | | | |
| 4 çok kısa deyim (200k satır) | | Nox ARC blok (parse, 10 tekrar toplamı) | | 2000920 | | | |
| 5 yorum ağırlıklı | 1207 KB | lexer | 970 | 915 | 0.94× | 910 | 1 |
| 5 yorum ağırlıklı | 1207 KB | parse (lexer dahil) | 1751 | 1796 | 1.03× | 1779 | 2 |
| 5 yorum ağırlıklı | 1207 KB | fmt hattı (lexer+parse dahil) | 2353 | 2270 | 0.96× | 2253 | 1 |
| 5 yorum ağırlıklı | | yalnız parse (parse−lexer) | 781 | 881 | 1.13× | | |
| 5 yorum ağırlıklı | | yalnız biçimleme (fmt−parse) | 602 | 474 | 0.79× | | |
| 5 yorum ağırlıklı | | köprü (Token dönüşümü) | | +122 | | | |
| 5 yorum ağırlıklı | | Nox ARC blok (parse, 10 tekrar toplamı) | | 60800 | | | |
| 6 dize ağırlıklı | 1035 KB | lexer | 1508 | 2047 | 1.36× | 2034 | 1 |
| 6 dize ağırlıklı | 1035 KB | parse (lexer dahil) | 4198 | 3714 | 0.88× | 3692 | 1 |
| 6 dize ağırlıklı | 1035 KB | fmt hattı (lexer+parse dahil) | 6576 | 7085 | 1.08× | 7076 | 0 |
| 6 dize ağırlıklı | | yalnız parse (parse−lexer) | 2690 | 1667 | 0.62× | | |
| 6 dize ağırlıklı | | yalnız biçimleme (fmt−parse) | 2378 | 3371 | 1.42× | | |
| 6 dize ağırlıklı | | köprü (Token dönüşümü) | | +144 | | | |
| 6 dize ağırlıklı | | Nox ARC blok (parse, 10 tekrar toplamı) | | 50790 | | | |
| 7 derin iç içe ifade | 1086 KB | lexer | 8539 | 5308 | 0.62× | 5273 | 2 |
| 7 derin iç içe ifade | 1086 KB | parse (lexer dahil) | 40729 | 31350 | 0.77× | 31061 | 3 |
| 7 derin iç içe ifade | 1086 KB | fmt hattı (lexer+parse dahil) | 44899 | 37463 | 0.83× | 37221 | 1 |
| 7 derin iç içe ifade | | yalnız parse (parse−lexer) | 32190 | 26042 | 0.81× | | |
| 7 derin iç içe ifade | | yalnız biçimleme (fmt−parse) | 4170 | 6113 | 1.47× | | |
| 7 derin iç içe ifade | | köprü (Token dönüşümü) | | +2424 | | | |
| 7 derin iç içe ifade | | Nox ARC blok (parse, 10 tekrar toplamı) | | 30810 | | | |
| 8 sınıf/metot ağırlıklı | 531 KB | lexer | 4348 | 1758 | 0.40× | 1739 | 3 |
| 8 sınıf/metot ağırlıklı | 531 KB | parse (lexer dahil) | 7194 | 5705 | 0.79× | 5676 | 3 |
| 8 sınıf/metot ağırlıklı | 531 KB | fmt hattı (lexer+parse dahil) | 8621 | 7013 | 0.81× | 6986 | 0 |
| 8 sınıf/metot ağırlıklı | | yalnız parse (parse−lexer) | 2846 | 3947 | 1.39× | | |
| 8 sınıf/metot ağırlıklı | | yalnız biçimleme (fmt−parse) | 1427 | 1308 | 0.92× | | |
| 8 sınıf/metot ağırlıklı | | köprü (Token dönüşümü) | | +709 | | | |
| 8 sınıf/metot ağırlıklı | | Nox ARC blok (parse, 10 tekrar toplamı) | | 1000980 | | | |
| 9 liste/sözlük literali | 718 KB | lexer | 5600 | 3115 | 0.56× | 3100 | 1 |
| 9 liste/sözlük literali | 718 KB | parse (lexer dahil) | 21127 | 12883 | 0.61× | 12519 | 3 |
| 9 liste/sözlük literali | 718 KB | fmt hattı (lexer+parse dahil) | 22639 | 16481 | 0.73× | 16055 | 3 |
| 9 liste/sözlük literali | | yalnız parse (parse−lexer) | 15527 | 9768 | 0.63× | | |
| 9 liste/sözlük literali | | yalnız biçimleme (fmt−parse) | 1512 | 3598 | 2.38× | | |
| 9 liste/sözlük literali | | köprü (Token dönüşümü) | | +1392 | | | |
| 9 liste/sözlük literali | | Nox ARC blok (parse, 10 tekrar toplamı) | | 1200870 | | | |
| 10 çağrı ağırlıklı | 854 KB | lexer | 15007 | 5092 | 0.34× | 5088 | 2 |
| 10 çağrı ağırlıklı | 854 KB | parse (lexer dahil) | 47322 | 24970 | 0.53× | 24516 | 4 |
| 10 çağrı ağırlıklı | 854 KB | fmt hattı (lexer+parse dahil) | 49644 | 28976 | 0.58× | 28934 | 2 |
| 10 çağrı ağırlıklı | | yalnız parse (parse−lexer) | 32315 | 19878 | 0.62× | | |
| 10 çağrı ağırlıklı | | yalnız biçimleme (fmt−parse) | 2322 | 4006 | 1.73× | | |
| 10 çağrı ağırlıklı | | köprü (Token dönüşümü) | | +2128 | | | |
| 10 çağrı ağırlıklı | | Nox ARC blok (parse, 10 tekrar toplamı) | | 2001220 | | | |
