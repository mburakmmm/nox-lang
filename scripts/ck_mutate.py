#!/usr/bin/env python3
"""Nox tip denetleyicisi (selfhost/typecheck.nox.in) mutasyon testi: her mutant farksal korpusta (Zig ↔ Nox) yakalanmalıdır.

Kullanım: python3 scripts/ck_mutate.py <mutants.json> <korpus_dizini> [<korpus_dizini> ...] [--repo]
  mutants: .json ([{"ad": "...", "eski": "<tam metin>", "yeni": "<yerine>"}, ...]) ya da `MUTANTS = [(ad, eski, yeni), ...]` tanımlayan .py (`eski` .nox.in içinde TAM BİR KEZ geçmeli)
  korpus: her biri `*.nox` dosyaları içeren dizin (ör. `ck_gen.py --import` çıktısı + elle yazılmış kenar-durum dizini); --repo: depo .nox dosyaları da eklenir.
Her mutant için: uygula → `gen_selfhost_parser.py` → `zig build nightly` → `noxc-nightly ck-diff check` (çıkış kodu ≠ 0 ya da çıktı "ck-diff: OK" değilse YAKALANDI).
Bitişte kaynak geri yüklenir ve nightly YENİDEN derlenir (bayat mutant ikilisi tuzağı). Betik ölse bile `git diff selfhost/typecheck.nox.in` ile kontrol et.
"""
import builtins
import functools
import json
import subprocess
import sys

print = functools.partial(builtins.print, flush=True)  # noqa: A001 (arka planda anlık günlük)

SRC = "selfhost/typecheck.nox.in"
BIN = "./zig-out/bin/noxc-nightly"


def sh(cmd, **kw):
    return subprocess.run(cmd, shell=True, capture_output=True, text=True, **kw)


def build():
    r = sh("python3 scripts/gen_selfhost_parser.py && zig build nightly")
    return r.returncode == 0, (r.stdout + r.stderr)[-600:]


def corpus_files(dirs, repo):
    files = []
    for d in dirs:
        r = sh(f"ls {d}/*.nox")
        files += r.stdout.split()
    if repo:
        r = sh("git ls-files '*.nox' | grep -v '^selfhost/'")
        files += r.stdout.split()
    return files


def run_diff(files):
    """(eşit_mi, imza): imza = tüm xargs gruplarının "ck-diff: OK ..." satırları (kapsam dışı/kabul/ret sayıları dahil). Mutant, Zig ile farklı VEYA taban imzadan farklı sayı veriyorsa yakalanır (kapsam dışına düşen mutant da)."""
    p = subprocess.run(f"xargs {BIN} ck-diff check", shell=True, input="\n".join(files), capture_output=True, text=True)
    sig = " | ".join(l for l in (p.stdout + p.stderr).splitlines() if l.startswith("ck-diff: OK"))
    return p.returncode == 0 and bool(sig), sig


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    repo = "--repo" in sys.argv
    if args[0].endswith(".py"):
        import runpy
        mutants = [{"ad": a, "eski": o, "yeni": n} for a, o, n in runpy.run_path(args[0])["MUTANTS"]]
    else:
        mutants = json.load(open(args[0], encoding="utf-8"))
    only = [a[7:] for a in sys.argv[1:] if a.startswith("--only=")]
    if only:
        names = set(only[0].split(","))
        mutants = [m for m in mutants if m["ad"] in names]
    files = corpus_files(args[1:], repo)
    orig = open(SRC, encoding="utf-8").read()
    caught, survived = [], []
    base_ok, base_sig = run_diff(files)
    if not base_ok:
        print("taban çizgisi Zig ile eşit değil, mutasyon testi anlamsız:", base_sig[:200])
        sys.exit(2)
    try:
        for m in mutants:
            n = orig.count(m["eski"])
            if n != 1:
                print(f"[{m['ad']}] ATLANDI: 'eski' {n} kez geçiyor (1 olmalı)")
                survived.append(m["ad"] + " (eşleşme yok)")
                continue
            open(SRC, "w", encoding="utf-8").write(orig.replace(m["eski"], m["yeni"], 1))
            ok, tail = build()
            if not ok:
                print(f"[{m['ad']}] derlenemedi (mutant geçersiz sayıldı): {tail[-200:]}")
                survived.append(m["ad"] + " (derlenmedi)")
                continue
            same, first = run_diff(files)
            if same and first == base_sig:
                print(f"[{m['ad']}] YAŞADI (yakalanmadı)")
                survived.append(m["ad"])
            else:
                print(f"[{m['ad']}] yakalandı: {first[:100]}")
                caught.append(m["ad"])
    finally:
        open(SRC, "w", encoding="utf-8").write(orig)
        ok, tail = build()
        print("kaynak geri yüklendi; nightly yeniden derlendi:", "tamam" if ok else "HATA " + tail)
    print(f"özet: yakalanan={len(caught)} yaşayan={len(survived)}")
    for s in survived:
        print("  YAŞAYAN:", s)
    sys.exit(1 if survived else 0)


if __name__ == "__main__":
    main()
