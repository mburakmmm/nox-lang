#!/usr/bin/env python3
import pathlib
import sys

root = pathlib.Path(__file__).resolve().parents[1]
matrix = (root / "docs/internals/mobile-matrix.md").read_text()
rows = []
for line in (root / "mobile-evidence/dod.txt").read_text().splitlines():
    if "=" not in line or line.startswith("#"):
        continue
    rows.append(line.strip())
claims_stable = "Stable: yes" in matrix
if "experimental" not in matrix and not claims_stable:
    sys.exit("mobile matrix must stay experimental until Stable: yes")
if claims_stable:
    missing = [row for row in rows if row.endswith("=no")]
    if missing:
        sys.exit("stable claim is blocked:\n" + "\n".join(missing))
print("mobile stable gate: experimental")
