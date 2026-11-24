# CLAUDE.md — Nox (Claude Code çalışma kuralları)

Nox dil/derleyici geliştirme kuralları (değişmez ilkeler, test/DoD, sürümleme, spesifikasyon) TEK kaynakta tutulur ve burada AYNEN geçerlidir:

@AGENTS.md

Çelişkide `AGENTS.md` kazanır. Aşağısı yalnızca **araç kullanımı** (graphify + rtk) kurallarıdır; **doğruluk ve test tamlığı hiçbir zaman token tasarrufu için feda edilmez.**

## 1. Keşif sırası (kod okumadan ÖNCE)

1. Mimari / çapraz-dosya / "bu nerede, kim çağırıyor, Zig↔Nox karşılığı ne" soruları → **önce graphify** (graf `graphify-out/` altında, yoksa `sh scripts/graphify_refresh.sh --wait` üretir):
   - `graphify query "<soru>" --budget 1500` — kavramsal arama (`--seed <düğüm|dosya>` ile başlangıç sabitlenir)
   - `graphify explain "<Düğüm>"` — düğüm + komşular, **dosya:satır** döner
   - `graphify path "A" "B" [--undirected]` — iki sembol arası bağ (Nox↔Zig bağı: `binds_ffi` kenarları)
   - Genel görünüm için `graphify-out/GRAPH_REPORT.md` (yalnızca ilgili bölümü oku).
2. Graf dosya:satır verdikten sonra **yalnızca o aralığı** oku (`Read` + `offset`/`limit`, ya da `rtk read <dosya> --tail-lines/--head-lines`).
3. Graf yetersizse (kapsam dışı: yeni/değişmiş kod, metin kalıbı, tam ifade gerek) → `rtk grep` / yerel okuma. Tam içerik gerektiğinde (düzenleme, kesin metin, hata ayıklama) **ham/tam okuma serbesttir** — özetlenmiş çıktıya güvenerek düzenleme yapma.
4. Kodu değiştirdikten sonra, grafı sorgulamadan önce ve **her commit'ten önce**: `sh scripts/graphify_refresh.sh --wait` (~15 sn).
5. graphify'ın kendi `update`/`install` hook'unu KULLANMA (Nox ek çıkarımını siler; `AGENTS.md` §0). `selfhost/*.nox` üretilmiştir; düzenleme `.nox.in` + `scripts/gen_selfhost_*.py`'de, sonra grafı yenile.

## 2. Terminal komutları (rtk)

Hook durumu: kullanıcı-düzeyi `~/.claude/settings.json` içinde `PreToolUse/Bash → rtk hook claude` AKTİF; proje düzeyinde ayrı hook YOK (çift hook çakışır — ekleme). Hook şunları OTOMATİK yeniden yazar: `git`, `grep`, `rg`, `cat`, `head`, `tail`, `ls`, `find`, `diff`, `wc`, `gh`, `curl`, `docker`. Yine de komutu doğrudan rtk biçiminde yaz:

| Amaç | Kullan | Kaçın |
|---|---|---|
| Git | `rtk git status/diff/log/add` | ham `git` çıktısı + boru |
| Arama | `rtk grep -n`, `rtk rg`, `rtk find` | `grep -n … \| head`, `find … \| xargs` |
| Dosya okuma | `Read` (aralıklı) veya `rtk read <f> [--head-lines N\|--tail-lines N]` | `cat`, `sed -n`, `head`, `tail` |
| Dizin | `rtk ls`, `rtk tree` | `ls -la` |
| Sayım | `rtk wc` | `wc -l` |
| GitHub | `rtk gh run/pr/issue` | ham `gh` |

Kurallar:
- Düzenleme için `Edit`/`Write` araçları; kabukta `sed -i`/`echo >`/`cat <<EOF >` ile kaynak değiştirme.
- rtk çıktısını `| cut -c… | head` ile **süzme** (rtk süzgecini bozar, çıktıyı yine ham basar). Gerekirse `rtk bypass <komut>` yalnızca sonuç kullanılamazsa (boş/çelişkili/bozuk).
- rtk'nin TANIMADIĞI komutlar (hook yeniden yazmaz, çıktı ham gelir): `zig build …`, `zig fmt`, `python3 scripts/*.py`, `noxc …`, `sed`, `sh scripts/*.sh`, `qbe`, `clang`. Bunlar için **`sh scripts/qrun.sh <ad> <komut…>`** kullan (tam çıktı log'a, ekrana sinyal satırları + son 6 satır + **çıkış kodu korunur**); ayrıntıyı log'dan `rtk grep`/`rtk read` ile oku, komutu yeniden çalıştırma.
- Uzun işleri `run_in_background` ile çalıştır; beklemek için `sleep` değil bildirimi/`until` döngüsünü kullan.

## 3. Test ve doğruluk (tasarruf ASLA bunların önüne geçmez)

- Test sonucunu **çıkış kodundan ve VERDICT/Build Summary satırından** oku. `qrun … | tail` gibi borularla çıkış kodunu KAYBETME; çıktı özetine bakıp "yeşil" deme.
- Tek iş = tek tam test koşusu: değiştir → `sh scripts/test-fast.sh` (1 kez) → VERDICT → `scripts/precheck.sh` → sürüm artır → yayın. Bump sonrası tekrar test yok. Yayın öncesi tam kanıt gerekirse `zig build test`.
- Kırmızı testi/başarısız adımı süzgeçle gizleme; hata çıktısını eksiksiz oku, kök nedeni bul. Testi azaltma, atlama, baseline'ı gevşetme (açık gerekçe ve kullanıcı onayı olmadan).
- Codegen değişikliği: golden test + İKİ backend (LLVM, QBE). Zig formatter/parser değişikliği: Nox karşılığı + `frontend_diff.py` paritesi aynı turda.
- Bellek/sızıntı, hata yönetimi, spesifikasyon güncellemesi: `AGENTS.md` §13–14.

## 4. Etkin zorlama mekanizmaları (bu dosya ne yapar / yapmaz)

- **Zorlayan:** yalnızca kullanıcı-düzeyi rtk `PreToolUse` Bash hook'u (otomatik yeniden yazım).
- **Yönlendiren (zorlamaz):** bu dosya + `AGENTS.md` + global `~/.claude/CLAUDE.md` (`@RTK.md`, graphify skill). graphify için hook YOK; kullanımı talimata dayanır.
- Kapsam dışı/çakışma riski: proje düzeyine ikinci bir rtk veya graphify hook'u eklenmez. Zorlama sertleştirilecekse önce kullanıcıya sor.
