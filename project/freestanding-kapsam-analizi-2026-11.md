# Freestanding Nox kapsam analizi (2026-11-11)

Amaç: `--profile freestanding` ile **neyin gerçekten çalıştığını** ölçmek; belgelenen vaatle gerçeği ayırmak; açık kusurları kök nedenleriyle sıralamak. Ölçüm aracı yeniden çalıştırılabilir: `scripts/freestanding_survey.py` (ilerlemeyi aynı komutla karşılaştırın).

## Yöntem

İki aşama, **524 fixture** (`tests/golden/codegen_cases/*.nox`) üzerinde, hedef `x86_64`:

1. `noxc build --profile freestanding --target x86_64` — yetenek denetimi + derleme + bağlama.
2. Bağlananlar GERÇEK bir QEMU önyüklemesinde çalıştırılır (`boot.S` + `kernel.ld` + `noxrt-freestanding-x86_64.o`, seri çıktı, `isa-debug-exit`; `freestanding_dogfood_test.zig`'in zinciri) ve seri çıktı hosted `.expected` ile **birebir** karşılaştırılır.

Ek olarak 63 stdlib modülünün her biri tek başına `import` edilip aynı profille derlendi.

## Sonuç özeti

| Kategori | Fixture | Anlamı |
|---|---:|---|
| **PASS** | **323** | QEMU'da çalıştı, çıktı hosted ile aynı |
| DIFF | 20 | çalıştı, çıktı farklı (aşağıda: 16'sı tek hata `%llu`) |
| HALT-OK | 12 | işlenmemiş istisna / kilitlenme: makine durur (tasarım; hosted da hatayla biter) |
| HALT | 3 | hosted başarılı, freestanding'de istisna ile durdu: **kusur** |
| FAULT | 2 | CPU istisnası (#UD, #GP): **kusur** |
| NOEXP | 2 | beklenen çıktı dosyası yok (çalıştı, çıkış kodu 33) |
| LINK | 76 | runtime sembolü eksik (kabuk freestanding köke alınmamış) |
| CAP | 69 | yetenek denetimi reddetti (tasarım gereği) |
| OTHER | 17 | negatif fixture'lar (beklenen reddetme) ve harici `.o` isteyen FFI fixture'ları |

Yani çekirdek dil (sınıf, kalıtım, generic, protokol, closure, istisna/`finally`/`with`/`defer`, jeneratör, `spawn`/`await`/`Task`/`Channel`, enum/`match`, `lowlevel`/arena, sabit genişlikli tamsayı, `ptr`/MMIO, `@repr`) QEMU'da büyük ölçüde çalışıyor. Sorun dil çekirdeğinde değil, **runtime kabuklarının eksikliği** ve **birkaç sessiz veri bozulması**nda.

### CAP reddi (tasarım gereği, değişmez)
`filesystem` 18, `clock` 15, `threads` 14, `network` 14, `entropy` 3, `libc_math` 2, `process` 2. Bunlar `--profile freestanding` sözleşmesinin parçasıdır.

## stdlib modül matrisi (63 modül)

- **Çalışır (derler + bağlanır):** `binary`, `bits`, `buffer`, `collections`, `console`, `csv`, `db`, `mathx`, `mem`, `property`, `tasks`, `time` (takvim kısmı).
- **Yetenek reddi (tasarım):** `atomic`, `fs`, `grpc`, `grpc_server`, `hpy`, `http`, `jwt`, `log`, `math`, `mysql`, `native`, `plugin`, `postgres`, `process`, `redis`, `reflect`, `router`, `sharedmem`, `signal`, `smtp`, `sqlite`, `terminal`, `test`, `thread`, `timezone`, `tls`, `transfer`, `udp`, `unicode`, `uuid`, `web`, `websocket`.
- **Yetenek denetiminden geçer ama BAĞLANMAZ (belge/gerçek uyuşmazlığı):** `base64`, `bytes`, `crypto`, `gzip`, `json`, `orm`, `os`, `path`, `protobuf`, `random`, `regex`, `strings`, `template`, `toml`, `url`, `validate`, `yaml` (toplam 64 benzersiz eksik sembol).

`docs/tools/freestanding.md` "`nox.strings`, `nox.json` … izinlidir" diyor; gerçekte `import nox.strings` bile bağlama hatası veriyor. Eksik semboller şu runtime dosyalarında: `stdlib_shims/strings.zig` (16), `crypto.zig` (12), `path.zig` (9), `regex.zig` (7), `os.zig` (7), `gzip.zig` (7), `random.zig` (3), `json.zig` (3). Bu kabukların hepsi zaten **wasm-freestanding** köküne (`lib_wasm_freestanding.zig`) dahil; yani OS'tan bağımsız oldukları kanıtlı. 76 LINK fixture'ının ~59'u yalnızca `strings` yüzünden düşüyor (örn. `str.split/upper/find/replace` gibi yöntemler freestanding'de kullanılamıyor).

## Açık kusurlar (kök neden durumuyla)

| # | Kusur | Etki | Durum |
|---|---|---|---|
| **F1** | `printf` yorumlayıcısı yalnızca `%lld`, `%g`, `%s` biliyor (`runtime/lib_freestanding.zig` `printfReal`); codegen unsigned için `%llu` üretiyor (`$fmt_uint`) | `u8/u16/u32/u64` ve `fixed_int` yazdırma `%llu` basar; 16 fixture | **Kök neden kesin.** Düzeltme birkaç satır. |
| **F2** | **Bir liste 128 elemanı aşıp büyüyünce ilk 128 eleman bozulur** (`xs.append` ile 129. eleman; ayrıca `[0] * 600` için `len()` çöp) | Sessiz veri bozulması | **Kök neden bilinmiyor.** Debug ve ReleaseFast'ta aynı; heap'i 4→16 MiB yapmak ve belleği sıfırlamak çözmedi; `nox_list_grow` kodu doğru görünüyor. Aşağıda 4 satırlık repro. |
| F3 | `Set`/`OrderedDict`/`Counter` ~1000 elemanda `IndexError` (`_hx_find`, `items[s-1]`) | `collections_hashed_index`, `ordered_dict_remove_tombstones` | Büyük olasılıkla F2'nin sonucu (yuva tablosu 128'den büyük `list[int]`). F2 düzelince yeniden ölçülmeli. |
| F4 | `pinned_string_passthrough`: ~466 bin yinelemeden sonra **sessizce yanlış sayım**; `str_append_in_place`: 8 KiB üstü dize döngüsünde `IndexError` | Sessiz yanlış sonuç | Kök neden bilinmiyor. Heap büyütmek sonucu değiştirdi ama düzeltmedi (hipotez "heap tükendi" **çürütüldü**). |
| F5 | Biçim belirteçli f-string / `str.format` (`{x:5d}`, `{pi:.2f}`): program sessizce çöker (#PF, `RSP` çöp) | `fstring_format_specs`, `str_format_method` | Tanı yapılmadı; yığın bozulması / çöp dönüş adresi. |
| F6 | `dict[float, …]` değer listesinde #GP (`dict_list_dict_values_float_keys`) | CPU istisnası | Tanı yapılmadı (SSE hizalaması şüphesi, **doğrulanmadı**). |
| F7 | `async_task_churn_long` #UD | CPU istisnası | Tanı yapılmadı (fiber yığını sağlayıcısı tükenmesi şüphesi, **doğrulanmadı**). |
| F8 | `mathx.exp(1.0)` son basamakta 1 ULP farkı (2.7182818284590455 / …45) | Sayısal | Freestanding `std.math` ile hosted libm farkı; büyük olasılıkla kabul edilebilir (karar). |

### F2 minimal repro

```nox
xs: list[int] = []
i: int = 0
while i < 129:
    xs.append(1000 + i)
    i = i + 1
print(xs[0])      # 1000 beklenir; freestanding'de çöp
```

128 eleman doğru, 129 bozuk. `[5] * 129` doğru, `[0] * 600` için `len` bozuk. Hosted QBE (aynı codegen) doğru çalışıyor; fark runtime/hedefte.

## Tasarım gereği davranışlar (kusur değil)

- **İşlenmemiş istisna ve kilitlenme makineyi durdurur** (belgelenmiş). Mesaj seri porta yazılır (`nox: uncaught exception: … — terminating the program`). 12 fixture. Test düzeneği için `isa-debug-exit` ile sıfırdan farklı kodla çıkmak isteğe bağlı bir iyileştirmedir (karar).
- Bu analiz **yalnızca x86_64'te çalıştırma** ölçtü. aarch64 yalnızca derleme (QEMU boot zinciri yok), riscv64 yalnızca `--emit-asm`.

## Öneri (öncelik sırası)

1. **F2'nin kök nedenini bul ve düzelt** (sessiz bozulma; P0). F3/F4'ü sonra yeniden ölç.
2. **F1**: `printfReal`'a `%llu` ekle (P0, ucuz). `printfReal` hâlâ `%f`/genişlik bilmiyor; codegen'in ürettiği tüm biçimler tarandı: yalnızca `%lld`, `%llu`, `%g`, `%s`.
3. **76 LINK fixture / 17 modül**: yukarıdaki sekiz kabuğu `lib_freestanding.zig` köküne ekle (wasm-freestanding'de zaten derleniyorlar); sonra `docs/tools/freestanding.md`'yi gerçeğe uydur. `nox.strings` en yüksek değer (≈59 fixture). `gzip.zig` `builtin.os.tag == .freestanding` dalıyla zaten iş parçacığı kullanmaz.
4. F5, F6, F7'yi ayrı ayrı tanıla.
5. Karar bekleyenler (kullanıcıya): QEMU'da fatal hatada `isa-debug-exit`; aarch64/riscv64 için QEMU boot zinciri; libm doğruluk politikası (F8); `strings` gibi kabukların freestanding'de bellek sınırı davranışı.

## Yeniden ölçüm

```sh
zig build && python3 scripts/freestanding_survey.py          # tam (≈15 dk, 6 paralel)
python3 scripts/freestanding_survey.py --only list_api_basic,bitwise_ops
python3 scripts/freestanding_survey.py --no-boot             # yalnızca derleme/bağlama
```

Başlangıç değerleri (2026-11-11, v2.1.47): PASS 323 · DIFF 20 · HALT-OK 12 · HALT 3 · FAULT 2 · NOEXP 2 · LINK 76 · CAP 69 · OTHER 17.
