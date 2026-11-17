#!/usr/bin/env python3
"""`tests/golden/codegen_cases/*.nox` (+ `.expected`) bir test dosyasında anılmıyorsa `zig build test` onu HİÇ çalıştırmaz (yalnızca opt-in korpus testleri çalıştırır). v2.1.195-196'da 11, 2.2 işlerinde 16 fixture böyle
kayıtsız kaldı. Bu denetim yeni kayıtsız fixture'ı yakalar; bilinçli istisnalar `BASELINE`dadır (gerekçesiyle)."""
import glob, os, re, sys

ROOT = os.path.join(os.path.dirname(__file__), "..", "tests", "golden")
# Bilinçli istisnalar: standart `zig build test` harness'i bunları çalıştıramaz (gerekçe sağda).
BASELINE = {
}

embedded = set()
for f in glob.glob(os.path.join(ROOT, "*.zig")):
    with open(f, encoding="utf-8") as fh:
        embedded.update(re.findall(r"codegen_cases/([A-Za-z0-9_]+)\.nox", fh.read()))

missing = []
for nox in sorted(glob.glob(os.path.join(ROOT, "codegen_cases", "*.nox"))):
    name = os.path.basename(nox)[:-4]
    if not os.path.exists(nox[:-4] + ".expected"):
        continue
    if name not in embedded and name not in BASELINE:
        missing.append(name)

if missing:
    print("KAYITSIZ fixture (hiçbir test dosyasında anılmıyor, `zig build test` çalıştırmaz):")
    for n in missing:
        print("  -", n)
    print("tests/golden/fixture_corpus.zig'ye ekleyin (ya da gerekçeyle BASELINE'a).")
    sys.exit(1)
print(f"fixture kaydı: temiz ({len(embedded)} anılan, {len(BASELINE)} gerekçeli istisna)")
