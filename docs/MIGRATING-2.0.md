# Nox 1.x → 2.0 geçiş rehberi

Nox 2.0, 1.x serisinde `deprecated` olarak işaretlenen eski adları kaldırır ve birkaç davranışı Python/yaygın beklentiyle hizalar.
Politika (bkz. [`VERSIONING.md`](../VERSIONING.md)): kaldırma yalnızca bir MAJOR sürümde yapılır; bu belge 2.0'da gözle görülür her değişikliği listeler.

## 1. Kaldırılan eski adlar (derleme hatası verir)

`nox.json` (v1.x'te `parse`/`dump` ailesine yeniden adlandırılmıştı):

| Eski (kaldırıldı) | Yeni |
|---|---|
| `decode` | `parse` |
| `encode` | `dump` |
| `encode_pretty` | `dump_pretty` |
| `encode_string` | `dump_string` |
| `encode_array` | `dump_array` |
| `encode_object` | `dump_object` |
| `encode_pretty_at` | `dump_pretty_at` |
| `encode_pretty_array` | `dump_pretty_array` |
| `encode_pretty_object` | `dump_pretty_object` |

`nox.csv`:

| Eski (kaldırıldı) | Yeni |
|---|---|
| `write` | `dump` |
| `write_row` | `dump_row` |

Düzeltme mekanik bir ad değiştirmedir; imzalar aynıdır.

## 2. Davranış değişiklikleri (1.x kodunu sessizce etkileyebilir)

| Konu | 1.x | 2.0 |
|---|---|---|
| `float` yazdırma | ham `printf` biçimi | Python `repr` biçimi (`0.1`, `1e+16`, `inf`, `nan`) |
| Negatif indeks | `xs[-1]` tanımsızdı | Python anlamı: `xs[-1]` son eleman, aralık dışı çalışma zamanı hatası (`list`, `str`, atama ve `remove` dahil) |
| Sabit genişlikli tamsayı taşması (`u8`/`i32`/`u64`…) | LLVM sarıyor, QBE tuzaklıyordu | **İki backend'de de tuzak** (program durur); düz `int` her iki backend'de sarar |
| `//` ve `%` sıfıra bölme | tanımsız | `ZeroDivisionError` fırlatır (yakalanabilir) |
| Anahtar kelime argüman değerlendirme sırası | bildirim sırası | yan etkili argümanlar **kaynakta yazıldıkları sırayla** değerlendirilir; `spawn` çağrısında yan etkili kwarg'lar parametre sırasında olmalıdır |
| `print(Optional)` | boş işaretçide çökebilirdi | `None` yazdırır |
| `print(obj)` | yalnızca sınıf adı | `__str__` / `__repr__` tanımlıysa onu kullanır; konteyner elemanları `__repr__` ile yazılır |
| Ayrıştırıcı iç içe ifade derinliği | sınırsız (yığın taşabilir) | 200 ile sınırlı, okunur hata verir |
| Sözdizimi hataları | tek satır ham mesaj | `dosya:satır:sütun` + imleç |

## 3. Yeni (kırıcı değil) özellikler

Okunabilir sözdizimi hataları, `0x/0b/0o/1_000/1e3` sayı literalleri, f-string biçim belirteçleri ve `str.format`, `"""…"""` ve docstring'ler,
`except (A, B) as e`, zincirli karşılaştırma, `assert`, üreteç ifadeleri (**istekli** — liste üretir, tembel değildir), `set[T]`, `__iter__`
protokolü, operatör aşırı yükleme (dunder), `str()/repr()/f-string` konteynerler için, genişletilmiş yerleşikler (`sorted`, `min/max key=`,
`round(x, n)`, `divmod`, `any/all`, `map/filter` …), `break/continue`, `in`/`not in`, üçlü ifade, varsayılan/anahtar argümanlar,
`nox.native` (Nox Native Interface v1). Ayrıntı için [`LANGUAGE.md`](LANGUAGE.md) ve `CHANGELOG.md`.

## 4. Bilinen sınırlar (2.0'da bilinçli olarak yok)

`*args` / `**kwargs`, çoklu kalıtım, sınıf düzeyinde öznitelik varsayılanları, `self.x: T = v` biçimli ek açıklamalı atama, literal içine
gömülü boş `[]`/`{}`, `str(Optional)`, f-string `!r`, `set` eleman tipi olarak `int/float/bool/str` dışındakiler. `set` yazdırma/yineleme sırası **ekleme
sırasıdır** (Nox anlambilimi). Bunlar 2.x'te eklenebilir; eklenmeleri mevcut kodu kırmaz.

## 5. Kararlılık

2.x boyunca: dil anlambilimi, belgelenmiş `nox.*` imzaları, `nox.json` bildirimi ve **NNI v1** ([`NATIVE-API.md`](NATIVE-API.md)) geriye uyumludur.
İç runtime ABI'si, IR çıktısı ve üretilen sembol adları değildir.
