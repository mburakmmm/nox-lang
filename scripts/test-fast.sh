#!/bin/bash
# v2.1.86: yerel hızlı test koşusu. Tam kanıt için (CI, yayın öncesi) `zig build test` kullanın.
#  - DebugAllocator yığın izi kapalı (-Dtrace-frames=0): Debug çalışma zamanında tahsis başına yığın çözme en büyük maliyetti;
#    güvenlik denetimleri (sızıntı / çift serbest / kullanım sonrası) AYNEN açık kalır, yalnızca sızıntı raporunda yığın izi yoktur.
#  - NOX_TEST_FAST=1: tests/golden/fixture_corpus.zig içinde `.slow = true` işaretli ağır fixture'lar atlanır.
cd "$(dirname "$0")/.." || exit 1
NOX_TEST_FAST=1 exec zig build test -Dtrace-frames=0 "$@"
