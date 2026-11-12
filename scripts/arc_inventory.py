#!/usr/bin/env python3
"""ASAP/ARC envanteri (TODO 4.5.1): `noxc explain --release` çıktısını bir dizindeki tüm .nox dosyaları üzerinde toplar ve yerel değişkenlerin tahsis kararlarını
(stack / arena / ARC) ile ARC'ye düşme nedenlerinin dağılımını yazar. Kullanım: scripts/arc_inventory.py [dizin ...] [--top N] [--json out.json]
Yalnızca dosya yolu verilen dizinlerdeki kaynaklara ait kararlar sayılır (stdlib yerelleri hariç)."""
import argparse, collections, concurrent.futures, glob, json, os, re, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
NOXC = os.path.join(ROOT, "zig-out/bin/noxc")

ap = argparse.ArgumentParser()
ap.add_argument("dirs", nargs="*", default=[os.path.join(ROOT, "tests/golden/codegen_cases")])
ap.add_argument("--top", type=int, default=25)
ap.add_argument("--json")
a = ap.parse_args()

def explain(path):
    r = subprocess.run([NOXC, "explain", "--release", path], capture_output=True, text=True, timeout=120)
    return path, r.stdout

def parse(path, out):
    decisions = []
    cur = None
    for line in out.splitlines():
        m = re.match(r"^(\S+):(\d+)\s+(\S+)$", line)
        if m:
            cur = {"file": m.group(1), "line": int(m.group(2)), "name": m.group(3), "alloc": "", "reasons": []}
            decisions.append(cur)
        elif cur and line.strip().startswith("allocation:"):
            cur["alloc"] = line.split(":", 1)[1].strip()
        elif cur and line.strip().startswith("- "):
            cur["reasons"].append(line.strip()[2:])
    return [d for d in decisions if os.path.abspath(d["file"]) == os.path.abspath(path) or d["file"].endswith(os.path.basename(path))]

files = []
for d in a.dirs:
    files += sorted(glob.glob(os.path.join(d, "*.nox")))
alloc = collections.Counter()
reasons = collections.Counter()
per_file = {}
with concurrent.futures.ThreadPoolExecutor(max_workers=6) as ex:
    for path, out in ex.map(explain, files):
        ds = parse(path, out)
        per_file[os.path.basename(path)] = len(ds)
        for dd in ds:
            kind = "ARC" if dd["alloc"].startswith("ARC") else ("arena" if "arena" in dd["alloc"].lower() else ("stack" if "stack" in dd["alloc"].lower() else dd["alloc"] or "?"))
            alloc[kind] += 1
            if kind == "ARC":
                # son neden genellikle "... -> ARC" kararını veren olandır
                key = next((r for r in reversed(dd["reasons"]) if "ARC" in r), dd["reasons"][-1] if dd["reasons"] else "(neden yok)")
                key = re.sub(r"\(\d+ bytes\)", "(N bytes)", key)
                reasons[key] += 1
total = sum(alloc.values())
print(f"{len(files)} dosya, {total} yerel değişken kararı")
for k, v in alloc.most_common():
    print(f"  {k:8s} {v:6d}  {100.0 * v / total:5.1f}%")
print(f"\nARC'ye düşme nedenleri (ilk {a.top}):")
for k, v in reasons.most_common(a.top):
    print(f"  {v:6d}  {k}")
if a.json:
    json.dump({"alloc": alloc, "reasons": reasons, "files": len(files)}, open(a.json, "w"), indent=1)
