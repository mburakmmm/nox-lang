#!/usr/bin/env python3
"""`.claude/token-audit/*.jsonl` özeti: araç başına boyut, tüm-dosya Read'ler, tekrar okumalar, ham (rtk'siz) Bash, ana/alt oturum ayrımı.
Kullanım: python3 scripts/token_audit.py [--days N] [--top K]"""
import argparse, collections, glob, json, os, re, time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RAW = re.compile(r"^(cat|head|tail|sed|awk|ls|find|grep|rg|wc|git|gh|diff)\b")
BIG = 20000  # karakter; ~5k token

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--days", type=int, default=7)
    ap.add_argument("--top", type=int, default=8)
    a = ap.parse_args()
    cut = time.time() - a.days * 86400
    recs = []
    for p in sorted(glob.glob(os.path.join(ROOT, ".claude/token-audit/*.jsonl"))):
        for line in open(p, encoding="utf-8"):
            try:
                r = json.loads(line)
            except ValueError:
                continue
            if r.get("t", 0) >= cut:
                recs.append(r)
    if not recs:
        print("kayıt yok (hook henüz çalışmadı mı? yeni oturum başlatın)")
        return
    print(f"{len(recs)} çağrı, {len({r['s'] for r in recs})} oturum, son {a.days} gün")
    print("\n== araç başına (çağrı / toplam karakter) ==")
    by = collections.defaultdict(lambda: [0, 0])
    for r in recs:
        by[r["tool"]][0] += 1
        by[r["tool"]][1] += r["size"]
    for t, (n, sz) in sorted(by.items(), key=lambda x: -x[1][1]):
        print(f"  {t:8} {n:6} {sz:10}")
    sub = [r for r in recs if r.get("agent")]
    print(f"\n== alt oturum (agent alanlı) çağrıları: {len(sub)} / {len(recs)}, karakter {sum(r['size'] for r in sub)} ==")
    reads = [r for r in recs if r["tool"] == "Read"]
    full = [r for r in reads if not r.get("ranged") and r["size"] >= BIG]
    print(f"\n== aralıksız büyük Read (≥{BIG} kar): {len(full)} / {len(reads)} Read ==")
    for r in sorted(full, key=lambda r: -r["size"])[: a.top]:
        print(f"  {r['size']:8}  {os.path.relpath(r['path'], ROOT) if r['path'].startswith(ROOT) else r['path']}")
    cnt = collections.Counter((r["s"], r["path"]) for r in reads)
    rep = [(k, n) for k, n in cnt.items() if n >= 3]
    print(f"\n== aynı oturumda ≥3 kez okunan dosya: {len(rep)} ==")
    for (s, p), n in sorted(rep, key=lambda x: -x[1])[: a.top]:
        print(f"  {n}x  {s}  {os.path.relpath(p, ROOT) if p.startswith(ROOT) else p}")
    bash = [r for r in recs if r["tool"] == "Bash"]
    raw = [r for r in bash if RAW.match(r.get("cmd", "")) and not r["cmd"].startswith("rtk ")]
    gr = [r for r in bash if r.get("cmd", "").startswith("graphify")]
    print(f"\n== Bash: {len(bash)} çağrı; rtk'siz ham (cat/grep/ls/git…): {len(raw)}; graphify: {len(gr)}; Grep/Glob aracı: {by['Grep'][0] + by['Glob'][0]} ==")
    c = collections.Counter(r["cmd"].split()[0] for r in raw)
    for k, n in c.most_common(a.top):
        print(f"  {n:5}  {k}")
    print("\n== en büyük 5 çıktı ==")
    for r in sorted(recs, key=lambda r: -r["size"])[:5]:
        print(f"  {r['size']:8}  {r['tool']:5} {(r.get('path') or r.get('cmd') or r.get('pat') or '')[:90]}")

main()
