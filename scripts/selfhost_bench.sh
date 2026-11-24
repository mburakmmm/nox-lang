#!/bin/sh
# R1-P1.13/P1.14: noxc-nightly parse-bench / fmt-bench için EŞDEĞER bellek ölçümü.
# Zig ve Nox tarafı AYRI süreçlerde (--side=zig / --side=nox) çalışır; her süreç için tepe RSS (işletim sistemi ölçümü) raporlanır.
# Kapılar: Debug kip reddedilir (bench kendisi çıkış 1 verir), boş/anlamsız sonuç kapıdan geçmez, rapor kip/commit başlığı taşır.
#
#   sh scripts/selfhost_bench.sh <parse-bench|fmt-bench> <dosya.nox> [tekrar=20]
#
# R1-P1.14 (v2.2.51): soğuk başlangıç (tekrar=1, ayrı süreç) duvar saati + tepe RSS ayrı raporlanır. R1-P1.7b kapısı: tekrar>1 iken tepe RSS(tekrar) / tepe RSS(1) oranı
# NOX_BENCH_RSS_GROWTH (varsayılan 2.0) üstündeyse çıkış 1 (art arda çağrıda bellek tutulması).
# Not: "mantıksal bayt" (Nox) ↔ "arena ayrılmış" (Zig) oranı eşdeğer DEĞİLDİR; bütçe kararları bu betiğin tepe-RSS oranıyla verilir.
set -u
kind=${1:-}
file=${2:-}
reps=${3:-20}
case "$kind" in parse-bench | fmt-bench) ;; *) echo "kullanim: sh scripts/selfhost_bench.sh <parse-bench|fmt-bench> <dosya.nox> [tekrar]" >&2; exit 2 ;; esac
[ -s "$file" ] || { echo "selfhost_bench: bos ya da yok: $file" >&2; exit 1; }
bin=${NOXC_NIGHTLY:-zig-out/bin/noxc-nightly}
[ -x "$bin" ] || { echo "selfhost_bench: $bin yok (zig build nightly -Doptimize=ReleaseFast)" >&2; exit 1; }
tmp=$(mktemp -d "${TMPDIR:-/tmp}/nox-sb.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

if [ "$(uname)" = Darwin ]; then
    timecmd="/usr/bin/time -l"
else
    timecmd="/usr/bin/time -v"
fi
wall_of() { # $1 = time çıktı dosyası → saniye (ondalık)
    if [ "$(uname)" = Darwin ]; then
        awk '/ real / {print $1; exit}' "$1"
    else
        awk -F': ' '/Elapsed \(wall clock\)/ {n=split($2, t, ":"); s=0; for (i=1;i<=n;i++) s=s*60+t[i]; print s; exit}' "$1"
    fi
}
rss_of() { # $1 = time çıktı dosyası → bayt
    if [ "$(uname)" = Darwin ]; then
        awk '/maximum resident set size/ {print $1}' "$1"
    else
        awk -F: '/Maximum resident set size/ {gsub(/ /,"",$2); print $2*1024}' "$1"
    fi
}
run_side() { # $1 = zig|nox  $2 = tekrar  $3 = çıktı etiketi
    $timecmd "$bin" "$kind" "$file" "$2" --side="$1" >"$tmp/$3.out" 2>"$tmp/$3.err"
    rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "selfhost_bench: $1 tarafi basarisiz (cikis=$rc):" >&2
        grep -v "maximum resident\|Maximum resident" "$tmp/$3.err" | head -5 >&2
        exit 1
    fi
    rss_of "$tmp/$3.err"
}
zrss=$(run_side zig "$reps" zig)
nrss=$(run_side nox "$reps" nox)
zcold=$(run_side zig 1 zig1)
ncold=$(run_side nox 1 nox1)
[ -n "$zrss" ] && [ -n "$nrss" ] && [ "$zrss" -gt 0 ] && [ "$nrss" -gt 0 ] || { echo "selfhost_bench: anlamsiz RSS (zig=$zrss nox=$nrss)" >&2; exit 1; }
head -1 "$tmp/zig.err"
commit=$(git rev-parse --short HEAD 2>/dev/null || echo bilinmiyor)
echo "[selfhost_bench] $kind dosya=$file ($(wc -c <"$file" | tr -d ' ') B) tekrar=$reps commit=$commit"
zw=$(wall_of "$tmp/zig1.err")
nw=$(wall_of "$tmp/nox1.err")
awk -v zw="${zw:-0}" -v nw="${nw:-0}" -v zr="$zcold" -v nr="$ncold" 'BEGIN { printf "soguk baslangic (tekrar=1, ayri surec): zig=%.2f s / %.1f MiB  nox=%.2f s / %.1f MiB\n", zw, zr/1048576, nw, nr/1048576 }'
if [ "$reps" -gt 1 ]; then
    max=${NOX_BENCH_RSS_GROWTH:-2.0}
    for side in zig nox; do
        if [ "$side" = zig ]; then rn=$zrss; r1=$zcold; else rn=$nrss; r1=$ncold; fi
        awk -v rn="$rn" -v r1="$r1" -v m="$max" -v s="$side" 'BEGIN { g = rn / r1; printf "RSS buyume (%s): tekrar=N / tekrar=1 = %.2fx (sinir %.1fx)\n", s, g, m; exit (g > m) ? 1 : 0 }' || { echo "selfhost_bench: $side RSS buyume kapisi asildi (art arda cagrida bellek tutuluyor)" >&2; exit 1; }
    done
fi
awk -v z="$zrss" -v n="$nrss" 'BEGIN { printf "tepe RSS (ayri surec): zig=%.1f MiB  nox=%.1f MiB  oran=%.2fx\n", z/1048576, n/1048576, n/z }'
