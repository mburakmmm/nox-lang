# noxc-nightly dağıtım ve platform sözleşmesi (R1-P2.2, v2.2.52)

`noxc-nightly` = kararlı `noxc` + Nox ile yazılmış bileşenler (`selfhost/`: lexer, parser, biçimlendirici, AST şeması). Kararlı sürüm hattını (`release.yml`, `noxc upgrade`) etkilemez.

## Platform durumu (kaynak: `.github/workflows/nightly.yml`, `build.zig` nightly adımı)
| Platform | Durum | Kanıt |
|---|---|---|
| Linux x86_64 | DOĞRULANMIŞ | nightly CI matrisi (`ubuntu-latest`): `zig build nightly`, `frontend-diff-test`, lex-bench, compiler_bench |
| macOS aarch64 | DOĞRULANMIŞ | nightly CI matrisi (`macos-latest`) + yerel geliştirme |
| Windows (herhangi) | DESTEKLENMEZ | CI matrisinde yok; `zig build nightly` Windows hedefinde açık hatayla başarısız olur (`build.zig` `addFail`); `mkdir -p`/POSIX yol varsayımı |
| Diğerleri (Linux arm64/riscv64, freestanding, WASM, mobil) | DOĞRULANMAMIŞ | CI'da yok; "doğrulandı" diye raporlanmaz |

`noxc-nightly selfhost-info` çıktısı çalışılan platformu ve doğrulama durumunu yazar (`DOĞRULANMIŞ` / `DOĞRULANMAMIŞ`).

## Dağıtım sözleşmesi (nightly neye bağlı)
- **stage0:** kurulu kararlı `noxc` (+ stdlib + `lib/noxrt.o`); `zig build` önce çalışmalıdır (nightly adımı kurulum adımına bağlıdır).
- **backend:** yalnızca yerel LLVM (`--selfhost-obj`): `clang` gerekir. QBE yolu nightly için kullanılmaz.
- **çıktı:** tek ikili `zig-out/bin/noxc-nightly` (Zig `compiler/main.zig` `nightly` seçeneği + `nightly/selfhost.o` + `noxrt.o`). Zig bileşenleri her zaman yedekte kalır; `--frontend nox` ile Nox bileşenleri seçilir.
- **runtime:** nightly ikilisi runtime'ı ikilinin içinde taşır; stdlib derlemesi için normal `noxc` kurulumu gerekir (nightly stdlib'i dağıtmaz).
- **araçlar:** Zig 0.16.0, python3 (farksal koşucu `scripts/frontend_diff.py`), `/usr/bin/time` (`scripts/selfhost_bench.sh`).
- **kip:** performans/bellek ölçümü yalnızca `-Doptimize=ReleaseFast` ile geçerlidir; Debug kipinde bench reddedilir (R1-P1.14).

## Raporlama kuralı
Bir platform/yapılandırma için "doğrulandı" demek, o platformda CI (ya da kayıtlı elle koşu) kanıtı gerektirir. Kanıtsız olan "DOĞRULANMAMIŞ", desteklenmeyen "DESTEKLENMEZ" olarak yazılır.
