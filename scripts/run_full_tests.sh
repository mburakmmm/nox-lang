#!/bin/bash
cd /Users/melihburakmemis/Documents/nox-lang
L=$1
rm -f $L
zig build test > $L 2>&1
rc=$?
errs=$(grep -c "compile .* error" $L)
summ=$(grep "Build Summary" $L | head -1)
if [ $rc -eq 0 ] && [ "$errs" = "0" ]; then v=GREEN; else v=RED; fi
echo "VERDICT=$v rc=$rc compile_errors=$errs $summ" >> $L
