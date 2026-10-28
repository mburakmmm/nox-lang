#!/usr/bin/env python3
"""runtime/ altındaki dosya-seviyesi `var`/`threadlocal var` bildirimlerini onaylı listeyle karşılaştırır (AGENTS §2.6).

Yeni bir global/gizli mutable durum eklemek, `project/global-state-allowlist.tsv`ye gerekçeli bir satır eklemeyi gerektirir
(kategori + neden). Listede olup kaynakta artık bulunmayan satır da hata sayılır, böylece liste bayatlamaz.
Kullanım: python3 scripts/check_global_state.py
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ALLOW = os.path.join(ROOT, "project", "global-state-allowlist.tsv")
PAT = re.compile(r"^(pub )?(threadlocal )?var (\w+)")


def scan():
    found = set()
    base = os.path.join(ROOT, "runtime")
    for d, _, files in os.walk(base):
        for f in files:
            if not f.endswith(".zig"):
                continue
            path = os.path.join(d, f)
            rel = os.path.relpath(path, ROOT)
            with open(path, encoding="utf-8") as fh:
                for line in fh:
                    m = PAT.match(line)
                    if m:
                        found.add((rel, m.group(3)))
    return found


def allowed():
    out = {}
    with open(ALLOW, encoding="utf-8") as fh:
        for line in fh:
            if line.startswith("#") or not line.strip():
                continue
            parts = line.rstrip("\n").split("\t")
            if len(parts) < 4 or not parts[2].strip() or not parts[3].strip():
                print(f"allowlist satırı eksik (dosya, ad, kategori, gerekçe gerekir): {line.strip()}")
                sys.exit(1)
            out[(parts[0], parts[1])] = parts[2]
    return out


def main():
    found, ok = scan(), allowed()
    new = sorted(found - set(ok))
    stale = sorted(set(ok) - found)
    for p, n in new:
        print(f"YENİ global durum: {p}: {n} — gerekçeyle project/global-state-allowlist.tsv'ye ekleyin ya da RuntimeState'e taşıyın")
    for p, n in stale:
        print(f"BAYAT allowlist satırı (kaynakta yok): {p}: {n}")
    if new or stale:
        sys.exit(1)
    print(f"global durum: temiz ({len(found)} onaylı bildirim)")


main()
