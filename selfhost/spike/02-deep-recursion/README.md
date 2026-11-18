# Aşama 0.8: derin özyineleme

`deep.nox`: `Node` zinciri (`kid`/`other`) + iki çocuklu özyinelemeli yürüyüş (LLVM'in döngüye çeviremeyeceği biçim) + zincirin serbest bırakılması. `harness.zig` bunu Zig'den ana iş parçacığında (`0`) ya da verilen MiB'lik yığınlı iş parçacığında çağırır; `run.sh` yeniden üretir.

## Sonuç (v2.2.30, LLVM -O2, macOS arm64, `ulimit -s` = 8 MiB)

| Derinlik | Ana iş parçacığı (8 MiB) | 256 MiB iş parçacığı |
|---|---|---|
| 10 bin / 100 bin | tamam | tamam |
| 300 bin | tamam | tamam |
| 1 milyon | **SIGSEGV** | tamam (serbest bırakma özyinelemesi dahil) |

- Plan 0.8'in "fiber yığını sabit 192 KiB" endişesi bu yolda **geçerli değil**: Nox bileşenleri `async`/`spawn` kullanmaz (`--selfhost-obj` bunu reddeder) ve Zig'den çağrılan senkron kod yerel iş parçacığı yığınında çalışır; fiber yığını yalnızca fiber içinde koşan kod için sınırdır.
- Karar: bileşenler `selfhost_glue.runOnBigStack` ile 256 MiB yığınlı bir iş parçacığında çalışır (sanal bellek; dokunulan kadarı fiziksel). 100 bin düğümlü AST ve 10 bin iç içe ifade ölçütleri bununla ~3 kat güvenlik payıyla sağlanır. Yığın taşması tanılanabilir bir hata değil SIGSEGV olduğundan parser/checker'a ayrıca bir derinlik sınırı (Zig derleyicisinin sınırıyla aynı hata iletisiyle) eklenecek (Aşama 2/3).
- QBE backend'inde çerçeveler daha büyük olabilir; nightly yalnızca LLVM yolunu kullanır.
