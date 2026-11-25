#!/bin/sh
# SessionStart + SubagentStart hook: her oturuma/alt oturuma kısa araç-disiplini özeti enjekte eder. Ayrıntı: CLAUDE.md §1-§4.
# SessionStart'ta stdout düz metin bağlamdır; SubagentStart'ta JSON `additionalContext` gerekir (stdin'deki hook_event_name'e göre seçilir).
# Metin KASITLI kısa (token maliyeti). Hata olursa sessizce çıkar; ASLA engellemez.
cd "${CLAUDE_PROJECT_DIR:-.}" 2>/dev/null || exit 0
input=$(cat 2>/dev/null)
text=$(cat <<'RULES'
[Nox araç disiplini — CLAUDE.md §1-§4 özeti, alt oturumlar dahil BAĞLAYICI]
1. Keşif: önce `graphify explain "<sembol>"` / `graphify query "<soru>" --budget 1500` → dosya:satır → dar `Read` (offset+limit). Aynı dosyayı tekrar okuma.
2. Terminal: `rtk grep -rn`, `rtk read`, `rtk git`, `rtk gh`, `rtk ls`. Ham `cat`/`sed -n`/`head`/`tail`/`ls -la`/`grep -n` ve rtk çıktısını `| cut | head` ile süzme YOK.
3. rtk'nin tanımadığı gürültülü komutlar (`zig build`, `scripts/test-fast.sh`, `python3 scripts/*`, `noxc`): `sh scripts/qrun.sh <ad> <komut>`; çıkış kodunu boruda KAYBETME; sonucu VERDICT/Build Summary/çıkış kodundan oku.
4. Düzenleme: `Edit`/`Write`; tek-iki yerlik değişiklik için betik/sed yazma. Kod değişince ve commit'ten önce: `sh scripts/graphify_refresh.sh --wait`.
5. Doğruluk tasarrufa feda edilmez: düzenleme, kesin metin, hata ayıklama ve tam tanılama için TAM/HAM okuma serbesttir; rtk çıktısı kullanılamazsa `rtk bypass <komut>`.
RULES
)
warn=""
command -v rtk >/dev/null 2>&1 || warn="${warn}UYARI: rtk PATH'te yok (kullanıcı-düzeyi PreToolUse hook'u sessizce işlemez). "
if [ ! -f graphify-out/graph.json ]; then
  warn="${warn}UYARI: graf yok → sh scripts/graphify_refresh.sh --wait. "
elif [ -n "$(find compiler runtime stdlib selfhost -type f \( -name '*.zig' -o -name '*.nox' -o -name '*.nox.in' \) -newer graphify-out/graph.json -print -quit 2>/dev/null)" ]; then
  warn="${warn}Graf bayat olabilir (kaynak grafikten yeni): sorgulamadan önce sh scripts/graphify_refresh.sh --wait. "
fi
[ -n "$warn" ] && text="$text
$warn"
case "$input" in
  *'"SubagentStart"'*)
    printf '%s' "$text" | python3 -c 'import json,sys; print(json.dumps({"hookSpecificOutput":{"hookEventName":"SubagentStart","additionalContext":sys.stdin.read()}}, ensure_ascii=False))' 2>/dev/null || true ;;
  *) printf '%s\n' "$text" ;;
esac
exit 0
