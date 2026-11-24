#!/bin/sh
# SessionStart hook: her oturuma/alt oturuma kısa araç-disiplini özeti enjekte eder (stdout = bağlam).
# Ayrıntı: CLAUDE.md §1-§3. Bu metin KASITLI kısa tutulur (token maliyeti).
cat <<'RULES'
[Nox araç disiplini — CLAUDE.md §1-§3 özeti, alt oturumlar dahil BAĞLAYICI]
1. Keşif: önce `graphify explain "<sembol>"` / `graphify query "<soru>" --budget 1500` → dosya:satır → dar `Read` (offset+limit). Tüm dosyayı körlemesine okuma; aynı dosyayı tekrar okuma.
2. Terminal: `rtk grep -rn`, `rtk read`, `rtk git`, `rtk gh`, `rtk ls`. Ham `cat`/`sed -n`/`head`/`tail`/`ls -la`/`grep -n` ve rtk çıktısını `| cut | head` ile süzme YOK.
3. rtk'nin tanımadığı komutlar (`zig build`, `python3 scripts/*`, `noxc`, `sh scripts/*.sh`): `sh scripts/qrun.sh <ad> <komut>`; çıkış kodunu boruda KAYBETME; testi VERDICT/Build Summary satırından oku.
4. Düzenleme: `Edit`/`Write`; tek-iki yerlik değişiklik için betik/sed yazma.
5. Kod değişince ve commit'ten önce: `sh scripts/graphify_refresh.sh --wait`.
6. Yanıtlar kısa; çıktıyı yeniden basma; doğruluk/test tamlığı tasarrufa feda edilmez.
RULES
exit 0
