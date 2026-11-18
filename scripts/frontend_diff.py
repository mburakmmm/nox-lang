#!/usr/bin/env python3
"""noxc-nightly farksal test koşucusu (plan Aşama 0.6): Zig ve Nox ön yüz bileşenlerini aynı girdilerde çalıştırıp çıktıları karşılaştırır.

  scripts/frontend_diff.py --component lexer                 # depodaki TÜM .nox dosyaları: `noxc tokens` ile `noxc-nightly --frontend nox tokens`
  scripts/frontend_diff.py --component lexer --zig-only      # Nox bileşeni henüz yokken: Zig'i iki kez çalıştırıp koşucunun kendisini sınar (fark 0 olmalı)
  scripts/frontend_diff.py --component ast                   # `noxc ast` ile `noxc-nightly --frontend nox ast`
  scripts/frontend_diff.py --selftest                        # koşucunun fark YAKALADIĞINI ve küçültücünün çalıştığını sınar (CI: `zig build frontend-diff-test`)
  scripts/frontend_diff.py --files a.nox b.nox ...           # yalnızca verilen dosyalar

Karşılaştırılan: çıkış kodu + stdout (+ `--stderr` ile stderr). Bir fark bulunursa ilk farkı gösterir ve dosyayı satır düzeyinde küçültür (ddmin); en küçük örnek `--out` dizinine yazılır.
Çıkış: 0 = fark yok, 1 = fark var, 2 = ortam hatası (ikili yok vb.).
"""
import argparse, concurrent.futures, difflib, os, subprocess, sys, tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
NOXC = os.path.join(ROOT, "zig-out/bin/noxc")
NIGHTLY = os.path.join(ROOT, "zig-out/bin/noxc-nightly")
COMPONENTS = {"lexer": "tokens", "ast": "ast"}


def corpus(extra_dirs):
    out = subprocess.run(["git", "ls-files", "--cached", "--others", "--exclude-standard", "*.nox"], cwd=ROOT, capture_output=True, text=True, check=True).stdout.split("\n")
    files = [os.path.join(ROOT, f) for f in out if f.strip()]
    for d in extra_dirs:
        for dp, _, fns in os.walk(d):
            files += [os.path.join(dp, f) for f in fns if f.endswith(".nox")]
    return sorted(set(files))


def run(cmd, timeout=30):
    try:
        p = subprocess.run(cmd, capture_output=True, timeout=timeout)
        return p.returncode, p.stdout, p.stderr
    except subprocess.TimeoutExpired:
        return -9, b"", b"TIMEOUT"


def make_runners(args):
    sub = COMPONENTS[args.component]
    zig = [NOXC, sub]
    if args.zig_only:
        other = [NOXC, sub]
    else:
        other = [NIGHTLY, "--frontend", "nox", sub]
    if args.zig_cmd:
        zig = args.zig_cmd.split() + [sub]
    if args.nox_cmd:
        other = args.nox_cmd.split() + [sub]
    return zig, other


def same(a, b, with_stderr):
    return a[0] == b[0] and a[1] == b[1] and (not with_stderr or a[2] == b[2])


def compare_file(path, zig, other, with_stderr):
    ra = run(zig + [path])
    rb = run(other + [path])
    return None if same(ra, rb, with_stderr) else (path, ra, rb)


def show_first_diff(ra, rb):
    sa = ra[1].decode("utf-8", "replace").splitlines()
    sb = rb[1].decode("utf-8", "replace").splitlines()
    print(f"  çıkış kodları: zig={ra[0]} nox={rb[0]}")
    for i, line in enumerate(difflib.unified_diff(sa, sb, "zig", "nox", lineterm="", n=1)):
        if i > 14:
            print("  ...")
            break
        print("  " + line)
    if ra[0] != rb[0] or not (sa or sb):
        print("  stderr zig:", ra[2][:300].decode("utf-8", "replace"))
        print("  stderr nox:", rb[2][:300].decode("utf-8", "replace"))


def shrink(path, zig, other, with_stderr):
    """Satır düzeyinde ddmin: farkı koruyan en küçük satır kümesi."""
    lines = open(path, "rb").read().split(b"\n")

    def differs(ls):
        with tempfile.NamedTemporaryFile(suffix=".nox", delete=False) as f:
            f.write(b"\n".join(ls))
            name = f.name
        try:
            return not same(run(zig + [name]), run(other + [name]), with_stderr)
        finally:
            os.unlink(name)

    n = 2
    while len(lines) >= 2:
        chunk = max(1, len(lines) // n)
        reduced = False
        for i in range(0, len(lines), chunk):
            cand = lines[:i] + lines[i + chunk:]
            if cand and differs(cand):
                lines = cand
                n = max(n - 1, 2)
                reduced = True
                break
        if not reduced:
            if chunk == 1:
                break
            n = min(len(lines), n * 2)
    return b"\n".join(lines)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--component", choices=sorted(COMPONENTS), default="lexer")
    ap.add_argument("--zig-only", action="store_true", help="Nox bileşeni yerine Zig'i yeniden çalıştır (koşucu sağlık denetimi)")
    ap.add_argument("--zig-cmd", help="Zig tarafı komutu (alt komut hariç), ör. 'zig-out/bin/noxc'")
    ap.add_argument("--nox-cmd", help="Nox tarafı komutu (alt komut hariç), ör. 'zig-out/bin/noxc-nightly --frontend nox'")
    ap.add_argument("--stderr", action="store_true", help="stderr'i de karşılaştır")
    ap.add_argument("--files", nargs="*", help="yalnızca bu dosyalar")
    ap.add_argument("--dir", action="append", default=[], help="korpusa ek dizin")
    ap.add_argument("--jobs", type=int, default=os.cpu_count() or 4)
    ap.add_argument("--max-diffs", type=int, default=5)
    ap.add_argument("--out", default=os.path.join(tempfile.gettempdir(), "frontend-diff"))
    ap.add_argument("--selftest", action="store_true")
    args = ap.parse_args()

    if args.selftest:
        return selftest()
    zig, other = make_runners(args)
    for exe in {zig[0], other[0]}:
        if not os.path.exists(exe) or not os.access(exe, os.X_OK):
            print(f"frontend_diff: {exe} yok (önce `zig build` / `zig build nightly`)", file=sys.stderr)
            return 2
    files = args.files if args.files else corpus(args.dir)
    print(f"frontend_diff: bileşen={args.component} dosya={len(files)}  zig={' '.join(zig)}  nox={' '.join(other)}")
    diffs = []
    with concurrent.futures.ThreadPoolExecutor(args.jobs) as ex:
        for r in ex.map(lambda f: compare_file(f, zig, other, args.stderr), files):
            if r:
                diffs.append(r)
    if not diffs:
        print(f"frontend_diff: FARK YOK ({len(files)} dosya)")
        return 0
    os.makedirs(args.out, exist_ok=True)
    print(f"frontend_diff: {len(diffs)} dosyada FARK (toplam {len(files)})")
    for path, ra, rb in diffs[: args.max_diffs]:
        print(f"- {os.path.relpath(path, ROOT)}")
        show_first_diff(ra, rb)
        mn = shrink(path, zig, other, args.stderr)
        out = os.path.join(args.out, os.path.basename(path) + ".min.nox")
        open(out, "wb").write(mn)
        print(f"  en küçük örnek ({len(mn.splitlines())} satır): {out}")
    return 1


def selftest():
    """Koşucunun fark yakaladığını ve küçültücünün farkı koruyan en küçük girdiyi bulduğunu gösterir (Nox bileşeni gerekmez)."""
    if not os.path.exists(NOXC):
        print("frontend_diff --selftest: zig-out/bin/noxc yok", file=sys.stderr)
        return 2
    with tempfile.TemporaryDirectory() as d:
        good = os.path.join(d, "good.nox")
        open(good, "w").write("def f(x: int) -> int:\n    return x + 1\n")
        # 1) aynı komut iki kez: fark yok
        zig = [NOXC, "tokens"]
        assert compare_file(good, zig, zig, False) is None, "aynı komut fark üretmemeli"
        # 2) sahte 'nox' tarafı: bozuk bir dosyada farklı çıktı veren sarmalayıcı
        wrapper = os.path.join(d, "fake_nox.sh")
        open(wrapper, "w").write('#!/bin/sh\n"$0.real" "$@" | sed "s/marker_line/MARKER_LINE/"\n')
        bad2 = os.path.join(d, "bad2.nox")
        open(bad2, "w").write("def f(x: int) -> int:\n    return x + 1\n" + "pass\n" * 6 + "marker_line = 1\n")
        os.symlink(NOXC, wrapper + ".real")
        os.chmod(wrapper, 0o755)
        other = [wrapper, "tokens"]
        assert compare_file(good, zig, other, False) is None, "marker içermeyen dosyada fark olmamalı"
        r = compare_file(bad2, zig, other, False)
        assert r is not None, "marker içeren dosyada fark YAKALANMALI"
        mn = shrink(bad2, zig, other, False)
        assert b"marker_line" in mn and len(mn.splitlines()) <= 2, f"küçültücü en küçük örneği bulmalı, bulduğu: {mn!r}"
    print("frontend_diff --selftest: tamam (fark yakalama + küçültme)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
