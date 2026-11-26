#!/usr/bin/env python3
"""noxc-nightly farksal test koşucusu (plan Aşama 0.6): Zig ve Nox ön yüz bileşenlerini aynı girdilerde çalıştırıp çıktıları karşılaştırır.

  scripts/frontend_diff.py --component lexer                 # depodaki TÜM .nox dosyaları: `noxc tokens` ile `noxc-nightly --frontend nox tokens`
  scripts/frontend_diff.py --component lexer --zig-only      # Nox bileşeni henüz yokken: Zig'i iki kez çalıştırıp koşucunun kendisini sınar (fark 0 olmalı)
  scripts/frontend_diff.py --component ast                   # `noxc ast` ile `noxc-nightly --frontend nox ast`
  scripts/frontend_diff.py --component lexer --fuzz 3000     # korpustan rastgele bozulmuş 3000 girdi daha; hata yolları dahil (`--seed` ile tekrarlanabilir)
  scripts/frontend_diff.py --selftest                        # koşucunun fark YAKALADIĞINI ve küçültücünün çalıştığını sınar (CI: `zig build frontend-diff-test`)
  scripts/frontend_diff.py --files a.nox b.nox ...           # yalnızca verilen dosyalar

Karşılaştırılan: çıkış kodu + stdout (+ `--stderr` ile stderr). Bir fark bulunursa ilk farkı gösterir ve dosyayı satır düzeyinde küçültür (ddmin); en küçük örnek `--out` dizinine yazılır.
Çıkış: 0 = fark yok, 1 = fark var, 2 = ortam hatası (ikili yok vb.).
"""
import argparse, concurrent.futures, difflib, json, os, subprocess, sys, tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
NOXC = os.path.join(ROOT, "zig-out/bin/noxc")
NIGHTLY = os.path.join(ROOT, "zig-out/bin/noxc-nightly")
COMPONENTS = {"lexer": "tokens", "ast": "ast", "check": "check", "astdump": "ast --full", "parser": "ast --full", "fmt": "fmt --stdout"}  # check: tüm hat (modül yükleme + ayrıştırma + tip denetimi) kararlı noxc ↔ nightly (Nox lexer varsayılan)


def corpus(extra_dirs):
    out = subprocess.run(["git", "ls-files", "--cached", "--others", "--exclude-standard", "*.nox"], cwd=ROOT, capture_output=True, text=True, check=True).stdout.split("\n")
    files = [os.path.join(ROOT, f) for f in out if f.strip()]
    for d in extra_dirs:
        for dp, _, fns in os.walk(d):
            files += [os.path.join(dp, f) for f in fns if f.endswith(".nox")]
    return sorted(set(files))


TRIPLE_D = b'"' * 3
TRIPLE_S = b"'" * 3
MUTATIONS = [b"\t", b"\r", b"\r\n", b'"', b"'", TRIPLE_D, TRIPLE_S, b"f'", b'f"', b'r"', b"{", b"}", b"(", b")", b"[", b"]", b"#", b"\\", b"\\\n", b":=", b"...", b";", b"!", b"$", b"?", b"`",
             "é".encode(), "ğ".encode(), "世".encode(), b"\xc3", b"\xe2\x82", b"\xf0\x9f", b"\xff", b"\xed\xa0\x80", b"\xc0\x80", b"\x00", b"0x", b"0b", b"1e", b"1_", b"protocol ", b"\n    ", b"\n  "]


def make_fuzz(files, count, seed, out_dir):
    """Korpus dosyalarından rastgele (deterministik) mutasyonlu girdiler: bayt sil/ekle/çoğalt/kes, özel karakter ve UTF-8 parçası ekle. Hata yollarını ve kenar durumları zorlar."""
    import random
    rnd = random.Random(seed)
    srcs = [f for f in files if os.path.getsize(f) < 20000] or files
    made = []
    for k in range(count):
        data = bytearray(open(rnd.choice(srcs), "rb").read())
        for _ in range(rnd.randint(1, 4)):
            op = rnd.randint(0, 5)
            pos = rnd.randint(0, max(len(data) - 1, 0))
            if op == 0 and data:
                del data[pos:pos + rnd.randint(1, 8)]
            elif op == 1:
                data[pos:pos] = rnd.choice(MUTATIONS)
            elif op == 2 and data:
                data[pos] = rnd.randint(0, 255)
            elif op == 3 and data:
                data[pos:pos] = data[max(0, pos - rnd.randint(1, 40)):pos]
            elif op == 4:
                del data[pos:]
            else:
                data[pos:pos] = rnd.choice(MUTATIONS) * rnd.randint(1, 3)
        path = os.path.join(out_dir, f"fz{seed}_{k}.nox")
        open(path, "wb").write(bytes(data))
        made.append(path)
    return made


def run(cmd, timeout=30):
    try:
        p = subprocess.run(cmd, capture_output=True, timeout=timeout)
        return p.returncode, p.stdout, p.stderr
    except subprocess.TimeoutExpired:
        return -9, b"", b"TIMEOUT"


def make_runners(args):
    sub = COMPONENTS[args.component]
    extra = args.sub_args.split() if args.sub_args else []
    sub_parts = sub.split()
    zig = [NOXC] + sub_parts + extra
    if args.zig_only:
        other = [NOXC] + sub_parts + extra
    elif args.component == "fmt":
        # Aşama 2.13: kararlı `noxc fmt --stdout` ↔ `noxc-nightly fmt --stdout` (Nox lexer + Nox parser + Nox biçimlendirici)
        other = [NIGHTLY] + sub_parts + extra
    elif args.component == "parser":
        # Aşama 2.C: Zig `ast --full` ↔ Nox parser'ının düz-dizi AST'sinin Nox yazıcısı (`parse-nox`)
        other = [NIGHTLY, "parse-nox"] + extra
    elif args.component == "astdump":
        # Aşama 2.B: Zig `ast --full` ↔ Zig AST'si → düz diziler → Nox yazıcısı (`ast-roundtrip`)
        other = [NIGHTLY, "ast-roundtrip"] + extra
    else:
        other = [NIGHTLY, "--frontend", "nox", sub] + extra
    if args.zig_cmd:
        zig = args.zig_cmd.split() + sub_parts + extra
    if args.nox_cmd:
        other = args.nox_cmd.split() + [sub] + extra
    return zig, other


import re

CRASH_RE = re.compile(rb"panic|Segmentation fault|SIGSEGV|SIGABRT|unreachable|stack overflow|Bus error|aborted|reached unreachable|attempt to use null", re.I)
OOM_RE = re.compile(rb"out of memory|OutOfMemory", re.I)
OK_CATEGORIES = ("SUCCESS", "EXPECTED_LANGUAGE_ERROR")


def _is_json_lex_error(out):
    s = out.strip()
    if not s.startswith(b"{"):
        return False
    try:
        obj = json.loads(s.decode("utf-8"))
    except Exception:
        return False
    err = obj.get("error") if isinstance(obj, dict) else None
    return isinstance(err, str) and bool(err) and not OOM_RE.search(err.encode("utf-8"))


def classify(rc, err, out=b""):
    """R1-P1.9: bir çalıştırmanın sonucunu sınıflandırır. Yalnızca SUCCESS ve EXPECTED_LANGUAGE_ERROR eşdeğerlik KANITI olabilir; ortak çökme/timeout/OOM başarı DEĞİLDİR."""
    if rc == 0:
        return "SUCCESS"
    if err == b"TIMEOUT" or (rc == -9 and b"TIMEOUT" in err):
        return "TIMEOUT"
    if OOM_RE.search(err):
        return "OOM"
    if rc < 0 or rc >= 128 or CRASH_RE.search(err):  # sinyal (POSIX) / Windows özel durum kodları (0xC0000005 ...) / Zig panic izi
        return "COMPILER_CRASH"
    if rc == 1 and (re.search(rb"error|unexpected|unterminated|inconsistent|tab used", err, re.I) or out.startswith(b"ERROR ") or b"\nERROR " in out[-400:] or _is_json_lex_error(out)):
        return "EXPECTED_LANGUAGE_ERROR"  # `noxc tokens` sözcük hatasını stdout'a `ERROR <ad>` veya `--json`'da `{"error":"<ad>"}` olarak yazar
    if rc == 1 and not err.strip():
        return "UNEXPECTED_EXIT"
    return "INFRASTRUCTURE_ERROR" if rc in (126, 127) else "UNEXPECTED_EXIT"


def same(a, b, with_stderr):
    ca, cb = classify(a[0], a[2], a[1]), classify(b[0], b[2], b[1])
    if ca != cb or ca not in OK_CATEGORIES:
        return False  # iki taraf da AYNI şekilde çökse/zaman aşımına uğrasa bile eşdeğerlik başarısı sayılmaz
    return a[0] == b[0] and a[1] == b[1] and (not with_stderr or a[2] == b[2])


def compare_file(path, zig, other, with_stderr):
    ra = run(zig + [path])
    rb = run(other + [path])
    return None if same(ra, rb, with_stderr) else (path, ra, rb)


def show_first_diff(ra, rb):
    sa = ra[1].decode("utf-8", "replace").splitlines()
    sb = rb[1].decode("utf-8", "replace").splitlines()
    print(f"  çıkış kodları: zig={ra[0]} nox={rb[0]}  kategoriler: zig={classify(ra[0], ra[2], ra[1])} nox={classify(rb[0], rb[2], rb[1])}")
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
    ap.add_argument("--sub-args", default="", help="alt komuttan sonra eklenecek bayraklar, ör. '--trivia' (lexer'ın yorum/boş satır kanalı)")
    ap.add_argument("--stderr", action="store_true", help="stderr'i de karşılaştır")
    ap.add_argument("--files", nargs="*", help="yalnızca bu dosyalar")
    ap.add_argument("--dir", action="append", default=[], help="korpusa ek dizin")
    ap.add_argument("--jobs", type=int, default=os.cpu_count() or 4)
    ap.add_argument("--max-diffs", type=int, default=5)
    ap.add_argument("--out", default=os.path.join(tempfile.gettempdir(), "frontend-diff"))
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--fuzz", type=int, default=0, help="korpus dosyalarından N mutasyonlu girdi üret ve onları da karşılaştır")
    ap.add_argument("--seed", type=int, default=1)
    args = ap.parse_args()

    if args.selftest:
        return selftest()
    zig, other = make_runners(args)
    for exe in {zig[0], other[0]}:
        if not os.path.exists(exe) or not os.access(exe, os.X_OK):
            print(f"frontend_diff: {exe} yok (önce `zig build` / `zig build nightly`)", file=sys.stderr)
            return 2
    files = args.files if args.files else corpus(args.dir)
    if args.fuzz:
        fuzz_dir = tempfile.mkdtemp(prefix="frontend-fuzz-")
        files = files + make_fuzz(files, args.fuzz, args.seed, fuzz_dir)
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
    # 3) R1-P1.9: ortak çökme / ortak timeout / ortak beklenmeyen çıkış EŞDEĞERLİK DEĞİLDİR; beklenen dil hatası ise eşdeğerdir
    crash = (-6, b"", b"thread 1 panic: attempt to use null value\n")
    assert not same(crash, crash, True), "ortak çökme başarı sayılmamalı"
    assert not same((-9, b"", b"TIMEOUT"), (-9, b"", b"TIMEOUT"), True), "ortak timeout başarı sayılmamalı"
    assert not same((134, b"", b""), (134, b"", b""), False), "ortak sinyal çıkışı başarı sayılmamalı"
    assert not same((1, b"", b""), (1, b"", b""), False), "tanılamasız çıkış 1 beklenmeyen çıkıştır"
    assert not same((1, b"", b"error: out of memory\n"), (1, b"", b"error: out of memory\n"), True), "ortak OOM başarı sayılmamalı"
    err = (1, b"", b"f.nox:1:9: syntax error: unexpected '2'\n")
    assert same(err, err, True), "aynı beklenen sözdizimi hatası eşdeğerdir"
    assert not same(err, (0, b"", b""), False), "hata ↔ başarı fark olmalı"
    assert classify(crash[0], crash[2]) == "COMPILER_CRASH" and classify(-9, b"TIMEOUT") == "TIMEOUT" and classify(1, b"x: syntax error") == "EXPECTED_LANGUAGE_ERROR"
    assert classify(1, b"", b'{"error":"UnterminatedString"}\n') == "EXPECTED_LANGUAGE_ERROR"
    assert classify(1, b"", b'{"error":"UnexpectedChar","line":1,"col":1,"start":0,"end":1}\n') == "EXPECTED_LANGUAGE_ERROR"
    assert same((1, b'{"error":"UnterminatedString"}\n', b""), (1, b'{"error":"UnterminatedString"}\n', b""), False)
    assert classify(1, b"", b'{"error":""}\n') == "UNEXPECTED_EXIT"
    assert classify(1, b"", b'{"tokens":[]}\n') == "UNEXPECTED_EXIT"
    assert classify(1, b"", b'{"error":"OutOfMemory"}\n') == "UNEXPECTED_EXIT"
    print("frontend_diff --selftest: tamam (fark yakalama + küçültme + ortak çökme/timeout başarı sayılmaz)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
