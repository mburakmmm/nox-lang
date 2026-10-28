# Global durum denetimi

AGENTS §2.6: runtime gizli/global mutable durum taşımaz, ayırıcıları açıkça alır. Bu sayfa `runtime/` altındaki dosya-seviyesi `var` ve `threadlocal var` bildirimlerinin (v2.0.32'de 82 adet) sınıflandırmasıdır. Onaylı liste `project/global-state-allowlist.tsv`dir; `scripts/check_global_state.py` CI'da yeni bir bildirimi (ya da silinmiş bir satırı) hata sayar.

| Kategori | Anlamı | Neden kabul |
|---|---|---|
| `lazy-lib` | tembel yüklenen dış kütüphane ve CA önbelleği | yüklendikten sonra değişmez, atomik durum korumalı, runtime verisi taşımaz |
| `provider` | program başında bir kez kaydedilen işlev işaretçisi | atomik, kullanıcı durumu değil |
| `immutable` | sabitlenmiş değişmez nesne | yazılmaz |
| `process` | işlem argv'si, Windows dinleme-soketi önbelleği | işlem-geneli OS kaynağı |
| `shared-io` | tek `std.Io.Threaded` | `SIGIO`/`SIGPIPE` işleyicisi işlem-geneli |
| `tl-sched` | iş parçacığının worker yuvası | M:N zamanlayıcının parçası |
| `tl-hpy` | HPy hata metni, hash tohumu | bir `HPyContext` tek iş parçacığına aittir |
| `tl-scratch` | JSON için geçici arena ve sınıf kimliği önbelleği | sonuç runtime ayırıcısına kopyalanır |
| `diag` | `NOX_STACK_PAINT`, havuz ölçümü | salt-ölçüm |
| `freestanding` | çekirdek bootstrap durumu | §2.6'daki belgeli istisna |
| `test` | birim test sayaçları | üretim kodu okumaz |
| **`tl-errno`** | `errno` benzeri son-işlem durumu ve fiber dışı stdin artığı | **açık borç** |

## Açık borç: `tl-errno`

`nox.fs`, `nox.path`, `nox.json`, `nox.gzip` ve `nox.io` son işlemin başarısını (`last_op_ok()`) ve stdin'in okunmamış kalanını bir fiber alanında tutar. Fiber dışındaki (senkron üst-düzey) kod aynı değeri iş parçacığı-yerel bir yedekte tutar. Aynı iş parçacığında çalışan iki runtime bu yedeği paylaşır. Çözüm `RuntimeState`e taşımaktır, ancak `last_op_ok()` API şeklini değiştirir; bu yüzden ayrı bir görev olarak açık bırakıldı (TODO 1.5 çoklu-runtime korpusu bunu ölçer).

## Ayırıcı

Çalışma zamanı varsayılan olarak sistem ayırıcısını (`page_allocator`) `RuntimeState.bootstrap_allocator` olarak kullanır; `nox_runtime_init_with_allocator` ve gömme ABI'sindeki `NoxHostAllocator` ([ADR-009](adr/009-embed-allocator.md)) bunu değiştirir. `page_allocator`ı doğrudan çağıran yerler: `nox.thread` çocuk runtime'ları ve havuz iş parçacıkları (sistem ayırıcısı, ADR-009), HTTP istemcisinin istek-ömürlü arenası ve `Shared` durumu, `json` ayrıştırma arenası, `Io.Threaded` başlatması. Bunlar runtime'ın yönetilen heap'i değildir (kullanıcı değerlerini taşımazlar), bu yüzden host ayırıcısı kapsamı dışındadır.
