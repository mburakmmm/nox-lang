#!/bin/sh
# qrun.sh — uzun/gürültülü komutları token-dostu çalıştırır (rtk'nin tanımadığı zig build,
# test-fast.sh, python betikleri vb. için). Hook'a/ayarlara dokunmaz; yalnızca bir sarmalayıcıdır.
#
#   sh scripts/qrun.sh <ad> <komut> [argümanlar...]
#
# - Tam çıktı $QRUN_DIR/<ad>.log dosyasına yazılır (varsayılan: ${TMPDIR:-/tmp}/nox-qrun).
# - Ekrana yalnızca: sinyal satırları (hata/VERDICT/Build Summary/panic/FAIL...) + son 6 satır
#   + log yolu + çıkış kodu basılır. Her satır 200 karaktere kırpılır, sinyal satırı en fazla 40.
# - Çıkış kodu komutunki AYNEN korunur (zincirleme/&& güvenli).
# - Ayrıntı gerekirse: tail/grep ile log dosyasından OKU; komutu yeniden çalıştırma.
set -u
if [ "$#" -lt 2 ]; then
    echo "kullanim: sh scripts/qrun.sh <ad> <komut> [arg...]" >&2
    exit 2
fi
name=$1
shift
dir=${QRUN_DIR:-${TMPDIR:-/tmp}/nox-qrun}
mkdir -p "$dir"
log="$dir/$name.log"
"$@" >"$log" 2>&1
rc=$?
total=$(wc -l <"$log" | tr -d ' ')
echo "[qrun] $name: cikis=$rc, $total satir, log=$log"
grep -E 'VERDICT|Build Summary|error:|error\(|panic|FAIL|failed|Segmentation|Traceback|AssertionError|leak|[Uu]nreachable' "$log" | cut -c1-200 | head -40
echo "[qrun] son satirlar:"
tail -n 6 "$log" | cut -c1-200
exit "$rc"
