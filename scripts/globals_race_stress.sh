#!/bin/bash
# 2.3 madde 1.7: modül-global ilklendirme yarışı için yük altı stres. Kullanım: scripts/globals_race_stress.sh <ikili> <beklenen-çıktı-dosyası> [paralel=90] [yineleme=60]
#   zig-out/bin/noxc build --release tests/golden/codegen_cases/signal_install_take_wait.nox -o /tmp/sig && scripts/globals_race_stress.sh /tmp/sig tests/golden/codegen_cases/signal_install_take_wait.expected
# Düzeltmeden önce bu yükte ~%0,07 hata (ReleaseFast: `s` 0 okunur); düzeltmeden sonra 0. Çıkış 1 = hata var.
bin=$1; exp=$2; par=${3:-90}; it=${4:-60}
fail=0
for p in $(seq 1 $par); do
  ( f=0; for i in $(seq 1 $it); do $bin > /tmp/r17_out_$p.txt 2>&1; cmp -s /tmp/r17_out_$p.txt $exp || { f=$((f+1)); cp /tmp/r17_out_$p.txt /tmp/r17_fail_${p}_$i.txt; }; done; echo $f > /tmp/r17_f_$p.txt ) &
done
wait
tot=0; for p in $(seq 1 $par); do tot=$((tot+$(cat /tmp/r17_f_$p.txt))); done
echo "failures=$tot of $((par*it))"
[ "$tot" -eq 0 ]
