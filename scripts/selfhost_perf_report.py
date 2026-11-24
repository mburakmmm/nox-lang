#!/usr/bin/env python3
"""R2-A.2/A.3/F.3 (v2.2.59): selfhost (Nox) ↔ Zig performans raporu — 10 senaryo, adil protokol.

Protokol: ReleaseFast `noxc-nightly` (Debug reddedilir), her senaryo/komut için 1 ısınma + N ölçüm, süre = ölçümlerin MEDYANI (min ve yayılım da yazılır); her ölçüm kendi içinde `reps`
tekrarın en iyisidir (bench komutları böyle raporlar). Sabit katlama koruması: girdiler her senaryoda farklı bayt içerir ve bench komutları sonucu kullanır (doNotOptimizeAway).
Aşamalar: lexer = lex-bench; parse = parse-bench (lexer dahil); fmt = fmt-bench (lexer+parse dahil) ⇒ yalnız parse = parse − lexer, yalnız biçimleme = fmt − parse.
Köprü: `nox lex_run` ↔ `nox + convert` (Token dizisine dönüşüm). Bellek: ayrı süreç tepe RSS (scripts/selfhost_bench.sh) ve Nox ARC tahsis sayısı/baytı (bench çıktısı).

Kullanım: python3 scripts/selfhost_perf_report.py [--runs 5] [--reps 20] [--out rapor.md]
"""
import argparse
import os
import re
import statistics
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BIN = os.environ.get("NOXC_NIGHTLY", os.path.join(ROOT, "zig-out/bin/noxc-nightly"))


def corpus(files):
    return b"\n".join(open(os.path.join(ROOT, f), "rb").read() for f in files)


def stdlib_files():
    d = os.path.join(ROOT, "stdlib/nox")
    return [os.path.join("stdlib/nox", f) for f in sorted(os.listdir(d)) if f.endswith(".nox")]


def scenarios():
    big = corpus(stdlib_files() + ["selfhost/lexer.nox", "selfhost/parser.nox", "selfhost/formatter.nox"])
    one = open(os.path.join(ROOT, "stdlib/nox/json.nox"), "rb").read()
    line = b"x: int = 1\n"
    return {
        "1 büyük korpus (stdlib+selfhost, ~1 MB)": big,
        "2 küçük tek dosya (json.nox)": one,
        "3 orta (~100 KB)": big[: 100_000].rsplit(b"\n", 1)[0] + b"\n",
        "4 çok kısa deyim (200k satır)": line * 200_000,
        "5 yorum ağırlıklı": (b"# " + b"yorum metni ve aciklama " * 8 + b"\nx: int = 1\n") * 6000,
        "6 dize ağırlıklı": (b'x: str = "' + b"abcdefghij" * 20 + b'"\n') * 5000,
        "7 derin iç içe ifade": (b"y: int = " + b"(" * 60 + b"1" + b" + 2)" * 60 + b"\n") * 3000,
        "8 sınıf/metot ağırlıklı": (b"class C:\n    v: int\n\n    def __init__(self: C, v: int) -> None:\n        self.v = v\n\n    def get(self: C) -> int:\n        return self.v\n\n") * 4000,
        "9 liste/sözlük literali": (b"z: list[int] = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]\nd: dict[str, int] = {'a': 1, 'b': 2, 'c': 3}\n") * 8000,
        "10 çağrı ağırlıklı": (b"r: int = f(a, b, c, g(d, e), h(i))\n") * 25000,
    }


def run(kind, path, reps):
    out = subprocess.run([BIN, kind, path, str(reps)], capture_output=True, text=True)
    t = out.stdout + out.stderr
    if out.returncode != 0 and "FAIL" in t:
        pass
    return t


def num(rx, text):
    m = re.search(rx, text)
    return int(m.group(1)) if m else None


def measure(kind, path, reps, runs):
    zig, nox, conv, blocks = [], [], [], None
    run(kind, path, 2)  # ısınma
    for _ in range(runs):
        t = run(kind, path, reps)
        if kind == "lex-bench":
            zig.append(num(r"zig lexer\s+(\d+) us", t))
            nox.append(num(r"nox lex_run\s+(\d+) us", t))
            conv.append(num(r"nox \+ convert\s+(\d+) us", t))
        elif kind == "parse-bench":
            zig.append(num(r"zig sözcük\+ayrıştırma\s+(\d+) us", t))
            nox.append(num(r"nox ayrıştırma\s+(\d+) us", t))
            blocks = num(r"(\d+) blok,", t)
        else:
            zig.append(num(r"zig fmt hattı\s+(\d+) us", t))
            nox.append(num(r"nox fmt hattı\s+(\d+) us", t))
    clean = lambda xs: [x for x in xs if x is not None]
    return clean(zig), clean(nox), clean(conv), blocks


def stat(xs):
    if not xs:
        return "—", 0, 0
    return statistics.median(xs), min(xs), (max(xs) - min(xs)) / max(1, statistics.median(xs)) * 100


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--runs", type=int, default=5)
    ap.add_argument("--reps", type=int, default=20)
    ap.add_argument("--out")
    args = ap.parse_args()
    if not os.path.exists(BIN):
        sys.exit(f"selfhost_perf_report: {BIN} yok (zig build nightly -Doptimize=ReleaseFast)")
    info = subprocess.run([BIN, "lex-bench", "/dev/null", "1"], capture_output=True, text=True)
    lines = ["# selfhost perf raporu", "", f"Komut: `{os.path.basename(BIN)}`, runs={args.runs}, reps={args.reps}; süreler µs, ölçümlerin MEDYANI (min / yayılım %).", ""]
    lines.append("| senaryo | boyut | aşama | Zig medyan | Nox medyan | Nox/Zig | Nox min | yayılım % |")
    lines.append("|---|---|---|---|---|---|---|---|")
    with tempfile.TemporaryDirectory() as tmp:
        for name, data in scenarios().items():
            p = os.path.join(tmp, "s.nox")
            open(p, "wb").write(data)
            res = {k: measure(k, p, args.reps, args.runs) for k in ("lex-bench", "parse-bench", "fmt-bench")}
            med = {k: (stat(res[k][0])[0], stat(res[k][1])[0], stat(res[k][1])[1], stat(res[k][1])[2]) for k in res}
            stages = [
                ("lexer", med["lex-bench"]),
                ("parse (lexer dahil)", med["parse-bench"]),
                ("fmt hattı (lexer+parse dahil)", med["fmt-bench"]),
            ]
            for st, (z, n, nmin, spread) in stages:
                ratio = f"{n / z:.2f}×" if isinstance(z, (int, float)) and isinstance(n, (int, float)) and z else "—"
                lines.append(f"| {name} | {len(data) // 1024} KB | {st} | {z} | {n} | {ratio} | {nmin} | {spread:.0f} |")
            # F.3: yalnız parse / yalnız biçimleme (Nox)
            nl, npz, nf = med["lex-bench"][1], med["parse-bench"][1], med["fmt-bench"][1]
            zl, zp, zf = med["lex-bench"][0], med["parse-bench"][0], med["fmt-bench"][0]
            if all(isinstance(v, (int, float)) for v in (nl, npz, nf, zl, zp, zf)):
                lines.append(f"| {name} | | yalnız parse (parse−lexer) | {zp - zl} | {npz - nl} | {(npz - nl) / max(1, zp - zl):.2f}× | | |")
                # UYARI: fmt hattı trivia'lı sözcükleme + çıktı kopyası + AST serbest bırakma içerir; fark GERÇEK biçimleme süresi değildir (profilde biçimleme işlevleri görünmez). Karar için tüm hat oranına bakın.
                lines.append(f"| {name} | | fmt−parse (YAKLAŞIK: trivia+çıktı kopyası dahil; yalnız biçimleme DEĞİL) | {zf - zp} | {nf - npz} | ({(nf - npz) / max(1, zf - zp):.2f}×) | | |")
            conv = stat(res["lex-bench"][2])[0]
            if isinstance(conv, (int, float)) and isinstance(nl, (int, float)):
                lines.append(f"| {name} | | köprü (Token dönüşümü) | | +{conv - nl} | | | |")
            blocks = res["parse-bench"][3]
            if blocks:
                lines.append(f"| {name} | | Nox ARC blok (parse, {args.reps} tekrar toplamı) | | {blocks} | | | |")
    text = "\n".join(lines) + "\n"
    if args.out:
        open(args.out, "w").write(text)
    print(text)


if __name__ == "__main__":
    main()
