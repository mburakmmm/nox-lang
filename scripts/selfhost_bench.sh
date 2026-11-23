#!/bin/sh
# R1-P1.13/P1.14: noxc-nightly parse-bench / fmt-bench için EŞDEĞER bellek ölçümü.
# Zig ve Nox tarafı AYRI süreçlerde (--side=zig / --side=nox) çalışır; her süreç için tepe RSS (işletim sistemi ölçümü) raporlanır.
# Kapılar: Debug kip reddedilir (bench kendisi çıkış 1 verir), boş/anlamsız sonuç kapıdan geçmez, rapor kip/commit başlığı taşır.
#
#   sh scripts/selfhost_bench.sh <parse-bench|fmt-bench> <dosya.nox> [tekrar=20]
#
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
rss_of() { # $1 = time çıktı dosyası → bayt
    if [ "$(uname)" = Darwin ]; then
        awk '/maximum resident set size/ {print $1}' "$1"
    else
        awk -F: '/Maximum resident set size/ {gsub(/ /,"",$2); print $2*1024}' "$1"
    fi
}
run_side() { # $1 = zig|nox
    $timecmd "$bin" "$kind" "$file" "$reps" --side="$1" >"$tmp/$1.out" 2>"$tmp/$1.err"
    rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "selfhost_bench: $1 tarafi basarisiz (cikis=$rc):" >&2
        grep -v "maximum resident\|Maximum resident" "$tmp/$1.err" | head -5 >&2
        exit 1
    fi
    rss_of "$tmp/$1.err"
}
zrss=$(run_side zig)
nrss=$(run_side nox)
[ -n "$zrss" ] && [ -n "$nrss" ] && [ "$zrss" -gt 0 ] && [ "$nrss" -gt 0 ] || { echo "selfhost_bench: anlamsiz RSS (zig=$zrss nox=$nrss)" >&2; exit 1; }
head -1 "$tmp/zig.err"
commit=$(git rev-parse --short HEAD 2>/dev/null || echo bilinmiyor)
echo "[selfhost_bench] $kind dosya=$file ($(wc -c <"$file" | tr -d ' ') B) tekrar=$reps commit=$commit"
awk -v z="$zrss" -v n="$nrss" 'BEGIN { printf "tepe RSS (ayri surec): zig=%.1f MiB  nox=%.1f MiB  oran=%.2fx\n", z/1048576, n/1048576, n/z }'
