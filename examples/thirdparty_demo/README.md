# Üçüncü-Taraf Paket Ekosistemi Örneği (Faz Y.2)

Bu dizin, Nox'un merkeziyetsiz (Git tabanlı) paket sisteminin GERÇEKTEN
çalıştığını kanıtlar. `nox.json`'daki `requires[]`, GitHub'da yayımlanmış
BEŞ gerçek, genel, MIT lisanslı paketi (`github.com/mburakmmm/nox-pkg-*`,
hepsi `v1.0.0` etiketli) işaret eder:

- [nox-pkg-greet](https://github.com/mburakmmm/nox-pkg-greet) — basit selamlama fonksiyonları
- [nox-pkg-mathx](https://github.com/mburakmmm/nox-pkg-mathx) — `nox.math` üzerine ek yardımcılar
- [nox-pkg-stack](https://github.com/mburakmmm/nox-pkg-stack) — `list[int]` tabanlı `IntStack` sınıfı
- [nox-pkg-strfmt](https://github.com/mburakmmm/nox-pkg-strfmt) — `nox.strings` üzerine biçimlendirme yardımcıları
- [nox-pkg-collections](https://github.com/mburakmmm/nox-pkg-collections) — `list[int]` yardımcı fonksiyonları

## Çalıştırma

Proje kökünden:

```
./zig-out/bin/noxc build examples/thirdparty_demo/main.nox -o /tmp/out
/tmp/out
```

İlk çalıştırma her paketi GERÇEK `git clone` ile (GERÇEK ağ üzerinden)
getirip `$NOX_HOME/pkg/mod/`e önbellekler ve çözülen commit SHA'larını
`nox.lock`a yazar; SONRAKİ çalıştırmalar tamamen önbellekten/offline
çalışır (bkz. `compiler/pkg/fetch.zig`).

## `noxc search` ile keşif (Faz Y.1)

`package_index.json`, bu beş paketi listeleyen örnek bir statik paket
dizinidir (bkz. `compiler/pkg/index.zig`):

```
./zig-out/bin/noxc search examples/thirdparty_demo/package_index.json
./zig-out/bin/noxc search examples/thirdparty_demo/package_index.json collections
```
