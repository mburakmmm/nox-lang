# selfhost perf raporu

Komut: `noxc-nightly`, runs=3, reps=10; süreler µs, ölçümlerin MEDYANI (min / yayılım %).

| senaryo | boyut | aşama | Zig medyan | Nox medyan | Nox/Zig | Nox min | yayılım % |
|---|---|---|---|---|---|---|---|
| 1 büyük korpus (stdlib+selfhost, ~1 MB) | 972 KB | lexer | 5257 | 2767 | 0.53× | 2763 | 0 |
| 1 büyük korpus (stdlib+selfhost, ~1 MB) | 972 KB | parse (lexer dahil) | 12127 | 8438 | 0.70× | 8395 | 1 |
| 1 büyük korpus (stdlib+selfhost, ~1 MB) | 972 KB | fmt hattı (lexer+parse dahil) | 16049 | 11441 | 0.71× | 11419 | 1 |
| 1 büyük korpus (stdlib+selfhost, ~1 MB) | | yalnız parse (parse−lexer) | 6870 | 5671 | 0.83× | | |
| 1 büyük korpus (stdlib+selfhost, ~1 MB) | | yalnız biçimleme (fmt−parse) | 3922 | 3003 | 0.77× | | |
| 1 büyük korpus (stdlib+selfhost, ~1 MB) | | köprü (Token dönüşümü) | | +696 | | | |
| 1 büyük korpus (stdlib+selfhost, ~1 MB) | | Nox ARC blok (parse, 10 tekrar toplamı) | | 684210 | | | |
| 2 küçük tek dosya (json.nox) | 25 KB | lexer | 89 | 52 | 0.58× | 49 | 12 |
| 2 küçük tek dosya (json.nox) | 25 KB | parse (lexer dahil) | 199 | 155 | 0.78× | 154 | 1 |
| 2 küçük tek dosya (json.nox) | 25 KB | fmt hattı (lexer+parse dahil) | 241 | 213 | 0.88× | 211 | 2 |
| 2 küçük tek dosya (json.nox) | | yalnız parse (parse−lexer) | 110 | 103 | 0.94× | | |
| 2 küçük tek dosya (json.nox) | | yalnız biçimleme (fmt−parse) | 42 | 58 | 1.38× | | |
| 2 küçük tek dosya (json.nox) | | köprü (Token dönüşümü) | | +14 | | | |
| 2 küçük tek dosya (json.nox) | | Nox ARC blok (parse, 10 tekrar toplamı) | | 15920 | | | |
| 3 orta (~100 KB) | 97 KB | lexer | 482 | 235 | 0.49× | 232 | 2 |
| 3 orta (~100 KB) | 97 KB | parse (lexer dahil) | 1001 | 741 | 0.74× | 738 | 2 |
| 3 orta (~100 KB) | 97 KB | fmt hattı (lexer+parse dahil) | 1226 | 1014 | 0.83× | 1010 | 1 |
| 3 orta (~100 KB) | | yalnız parse (parse−lexer) | 519 | 506 | 0.97× | | |
| 3 orta (~100 KB) | | yalnız biçimleme (fmt−parse) | 225 | 273 | 1.21× | | |
| 3 orta (~100 KB) | | köprü (Token dönüşümü) | | +63 | | | |
| 3 orta (~100 KB) | | Nox ARC blok (parse, 10 tekrar toplamı) | | 69060 | | | |
| 4 çok kısa deyim (200k satır) | 2148 KB | lexer | 21437 | 8857 | 0.41× | 8746 | 5 |
| 4 çok kısa deyim (200k satır) | 2148 KB | parse (lexer dahil) | 49713 | 38023 | 0.76× | 37882 | 1 |
| 4 çok kısa deyim (200k satır) | 2148 KB | fmt hattı (lexer+parse dahil) | 55054 | 49304 | 0.90× | 49067 | 1 |
| 4 çok kısa deyim (200k satır) | | yalnız parse (parse−lexer) | 28276 | 29166 | 1.03× | | |
| 4 çok kısa deyim (200k satır) | | yalnız biçimleme (fmt−parse) | 5341 | 11281 | 2.11× | | |
| 4 çok kısa deyim (200k satır) | | köprü (Token dönüşümü) | | +4251 | | | |
| 4 çok kısa deyim (200k satır) | | Nox ARC blok (parse, 10 tekrar toplamı) | | 2000920 | | | |
| 5 yorum ağırlıklı | 1207 KB | lexer | 969 | 905 | 0.93× | 902 | 1 |
| 5 yorum ağırlıklı | 1207 KB | parse (lexer dahil) | 1756 | 1805 | 1.03× | 1769 | 2 |
| 5 yorum ağırlıklı | 1207 KB | fmt hattı (lexer+parse dahil) | 2384 | 3015 | 1.26× | 3009 | 0 |
| 5 yorum ağırlıklı | | yalnız parse (parse−lexer) | 787 | 900 | 1.14× | | |
| 5 yorum ağırlıklı | | yalnız biçimleme (fmt−parse) | 628 | 1210 | 1.93× | | |
| 5 yorum ağırlıklı | | köprü (Token dönüşümü) | | +135 | | | |
| 5 yorum ağırlıklı | | Nox ARC blok (parse, 10 tekrar toplamı) | | 60800 | | | |
| 6 dize ağırlıklı | 1035 KB | lexer | 1517 | 2069 | 1.36× | 2046 | 1 |
| 6 dize ağırlıklı | 1035 KB | parse (lexer dahil) | 4332 | 3712 | 0.86× | 3693 | 1 |
| 6 dize ağırlıklı | 1035 KB | fmt hattı (lexer+parse dahil) | 6570 | 7203 | 1.10× | 7158 | 4 |
| 6 dize ağırlıklı | | yalnız parse (parse−lexer) | 2815 | 1643 | 0.58× | | |
| 6 dize ağırlıklı | | yalnız biçimleme (fmt−parse) | 2238 | 3491 | 1.56× | | |
| 6 dize ağırlıklı | | köprü (Token dönüşümü) | | +129 | | | |
| 6 dize ağırlıklı | | Nox ARC blok (parse, 10 tekrar toplamı) | | 50790 | | | |
| 7 derin iç içe ifade | 1086 KB | lexer | 8613 | 5281 | 0.61× | 5186 | 2 |
| 7 derin iç içe ifade | 1086 KB | parse (lexer dahil) | 40706 | 31377 | 0.77× | 31343 | 1 |
| 7 derin iç içe ifade | 1086 KB | fmt hattı (lexer+parse dahil) | 44884 | 37888 | 0.84× | 37770 | 0 |
| 7 derin iç içe ifade | | yalnız parse (parse−lexer) | 32093 | 26096 | 0.81× | | |
| 7 derin iç içe ifade | | yalnız biçimleme (fmt−parse) | 4178 | 6511 | 1.56× | | |
| 7 derin iç içe ifade | | köprü (Token dönüşümü) | | +2425 | | | |
| 7 derin iç içe ifade | | Nox ARC blok (parse, 10 tekrar toplamı) | | 30810 | | | |
| 8 sınıf/metot ağırlıklı | 531 KB | lexer | 4279 | 1739 | 0.41× | 1700 | 3 |
| 8 sınıf/metot ağırlıklı | 531 KB | parse (lexer dahil) | 6987 | 5565 | 0.80× | 5547 | 1 |
| 8 sınıf/metot ağırlıklı | 531 KB | fmt hattı (lexer+parse dahil) | 8731 | 7093 | 0.81× | 7066 | 1 |
| 8 sınıf/metot ağırlıklı | | yalnız parse (parse−lexer) | 2708 | 3826 | 1.41× | | |
| 8 sınıf/metot ağırlıklı | | yalnız biçimleme (fmt−parse) | 1744 | 1528 | 0.88× | | |
| 8 sınıf/metot ağırlıklı | | köprü (Token dönüşümü) | | +691 | | | |
| 8 sınıf/metot ağırlıklı | | Nox ARC blok (parse, 10 tekrar toplamı) | | 1000980 | | | |
| 9 liste/sözlük literali | 718 KB | lexer | 5591 | 3128 | 0.56× | 3101 | 3 |
| 9 liste/sözlük literali | 718 KB | parse (lexer dahil) | 21184 | 12751 | 0.60× | 12686 | 1 |
| 9 liste/sözlük literali | 718 KB | fmt hattı (lexer+parse dahil) | 22859 | 16571 | 0.72× | 16564 | 2 |
| 9 liste/sözlük literali | | yalnız parse (parse−lexer) | 15593 | 9623 | 0.62× | | |
| 9 liste/sözlük literali | | yalnız biçimleme (fmt−parse) | 1675 | 3820 | 2.28× | | |
| 9 liste/sözlük literali | | köprü (Token dönüşümü) | | +1400 | | | |
| 9 liste/sözlük literali | | Nox ARC blok (parse, 10 tekrar toplamı) | | 1200870 | | | |
| 10 çağrı ağırlıklı | 854 KB | lexer | 15083 | 5174 | 0.34× | 5124 | 2 |
| 10 çağrı ağırlıklı | 854 KB | parse (lexer dahil) | 47712 | 25240 | 0.53× | 24783 | 2 |
| 10 çağrı ağırlıklı | 854 KB | fmt hattı (lexer+parse dahil) | 49708 | 29086 | 0.59× | 28783 | 6 |
| 10 çağrı ağırlıklı | | yalnız parse (parse−lexer) | 32629 | 20066 | 0.61× | | |
| 10 çağrı ağırlıklı | | yalnız biçimleme (fmt−parse) | 1996 | 3846 | 1.93× | | |
| 10 çağrı ağırlıklı | | köprü (Token dönüşümü) | | +2124 | | | |
| 10 çağrı ağırlıklı | | Nox ARC blok (parse, 10 tekrar toplamı) | | 2001220 | | | |
