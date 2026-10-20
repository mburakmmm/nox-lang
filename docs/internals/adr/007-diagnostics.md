# ADR-MOB-007 Tanı

Durum: kabul.

## Karar

Hata ayıklama sembolleri yayın işinde ayrı durur: iOS için dSYM, Android için soyulmamış `.so`. Release paketinde bir hata ayıklama soketi açık kalmaz. Günlük, hata ayıklamada OSLog ve logcat köprüsüdür; release'te kısadır. Anahtar malzeme günlüğe veya Nox yığınına yazılmaz.

## Reddedilen

Release ikilisine bir debug sunucusu bırakmak. Geri alma: köprüyü hosttan çıkarmak.
