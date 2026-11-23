#!/usr/bin/env python3
"""R1-P1.12: biçimlendirici ÖZELLİK denetimi (depo korpusu + isteğe bağlı mutasyonlu girdiler).

Her geçerli kaynak (`noxc fmt --stdout` başarılı) için:
  1. idempotence:   fmt(fmt(x)) == fmt(x)
  2. semantik koruma: `noxc ast`(x) == `noxc ast`(fmt(x))   (span/trivia içermeyen S-ifade dökümü; yorum ve boşluk farkı AST'yi değiştirmemeli)
  3. CRLF:           fmt(x'in CRLF'i) == fmt(x)

  scripts/fmt_properties.py [--fuzz N] [--seed S] [--bin zig-out/bin/noxc] [--baseline scripts/fmt_properties_baseline.txt] [--update-baseline]

Taban (ratchet): `--baseline` dosyasındaki BİLİNEN ihlaller (`tür yol`) hata sayılmaz; YENİ ihlal çıkış 1 verir, düzelen kayıtlar "taban eskimiş" olarak listelenir (silinmeli).

Çıkış: 0 = ihlal yok, 1 = ihlal var (ilk 10 gösterilir), 2 = ortam hatası. Geçersiz kaynaklar (fmt hatası) atlanır ve sayılır.
"""
import argparse, concurrent.futures, os, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import frontend_diff as fd  # noqa: E402


def sh(cmd, data=None):
    p = subprocess.run(cmd, input=data, capture_output=True, timeout=60)
    return p.returncode, p.stdout, p.stderr


def check(noxc, path, tmp):
    rc, out1, _ = sh([noxc, "fmt", "--stdout", path])
    if rc != 0:
        return "skip", None
    src = open(path, "rb").read()
    base = os.path.join(tmp, "f_%d.nox" % (abs(hash(path)) % 10**9))
    open(base, "wb").write(out1)
    rc2, out2, _ = sh([noxc, "fmt", "--stdout", base])
    if rc2 != 0 or out2 != out1:
        return "idempotence", "fmt(fmt(x)) != fmt(x)" if rc2 == 0 else "fmt(fmt(x)) hata verdi"
    ra, a1, _ = sh([noxc, "ast", path])
    rb, a2, _ = sh([noxc, "ast", base])
    if ra == 0 and (rb != 0 or a1 != a2):
        return "semantik", "ast(x) != ast(fmt(x))" if rb == 0 else "fmt(x) ayrıştırılamıyor"
    crlf = base + ".crlf.nox"
    open(crlf, "wb").write(src.replace(b"\r\n", b"\n").replace(b"\n", b"\r\n"))
    rc3, out3, _ = sh([noxc, "fmt", "--stdout", crlf])
    if rc3 == 0 and out3 != out1:
        return "crlf", "fmt(CRLF x) != fmt(x)"
    return "ok", None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--fuzz", type=int, default=0)
    ap.add_argument("--seed", type=int, default=7)
    ap.add_argument("--bin", default=fd.NOXC)
    ap.add_argument("--baseline", default=None)
    ap.add_argument("--update-baseline", action="store_true")
    args = ap.parse_args()
    if not os.path.exists(args.bin):
        print("ikili yok:", args.bin, file=sys.stderr)
        return 2
    files = fd.corpus([])
    with tempfile.TemporaryDirectory() as tmp:
        if args.fuzz:
            files += fd.make_fuzz(files, args.fuzz, args.seed, os.path.join(tmp, "fuzz"))
        counts, bad = {}, []
        with concurrent.futures.ThreadPoolExecutor(max_workers=os.cpu_count() or 4) as ex:
            for f, (kind, why) in zip(files, ex.map(lambda p: check(args.bin, p, tmp), files)):
                counts[kind] = counts.get(kind, 0) + 1
                if kind not in ("ok", "skip"):
                    bad.append((kind, f, why))
    print("fmt_properties:", ", ".join("%s=%d" % kv for kv in sorted(counts.items())))
    rel = lambda f: os.path.relpath(f, fd.ROOT) if f.startswith(fd.ROOT) else f
    if args.baseline:
        if args.update_baseline:
            open(args.baseline, "w").write("# R1-P1.12 bilinen biçimlendirici ihlalleri (tür yol). Düzeltilince satır SİLİNİR; yeni ihlal eklenmez.\n" + "".join("%s %s\n" % (k, rel(f)) for k, f, _ in sorted(bad, key=lambda b: (b[0], b[1]))))
            print("taban yazildi:", len(bad))
            return 0
        known = set(l.split(None, 1)[0] + " " + l.split(None, 1)[1].strip() for l in open(args.baseline) if l.strip() and not l.startswith("#"))
        now = set("%s %s" % (k, rel(f)) for k, f, _ in bad)
        stale = sorted(known - now)
        if stale:
            print("  taban eskimis (duzelmis, taban dosyasindan silin): %d" % len(stale), *stale[:5], sep="\n    ")
        bad = [b for b in bad if "%s %s" % (b[0], rel(b[1])) not in known]
        if args.fuzz:
            pass  # mutasyonlu girdiler taban dışıdır: her ihlal rapor edilir
    for kind, f, why in bad[:10]:
        print("  IHLAL [%s] %s: %s" % (kind, os.path.relpath(f, fd.ROOT) if f.startswith(fd.ROOT) else f, why))
    if len(bad) > 10:
        print("  ... %d ihlal daha" % (len(bad) - 10))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
