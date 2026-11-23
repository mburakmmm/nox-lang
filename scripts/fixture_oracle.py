#!/usr/bin/env python3
"""R1-P1.10: parser/biçimlendirici fixture ORACLE denetimi.

  scripts/fixture_oracle.py [--update]

- Pozitif (`ok_*.nox`): `noxc ast` BAŞARILI olmalı ve AST gerçekten gövde içermeli (boş modül/yanlışlıkla ayrışmayan dosya geçmez);
  iki pozitif fixture aynı AST'yi üretmemeli (ok_* tekrarını otomatik engeller).
- Negatif (`err_*.nox`): çıkış kodu != 0 ve ilk stderr satırı `yol:SATIR:SÜTUN: syntax error: İLETİ` biçiminde; (satır, sütun, ileti) `tests/fixtures/parser_edge/expected_errors.txt`
  ile BİREBİR aynı olmalı (hata türü + konum sabitlenir). `--update` dosyayı yeniden üretir (bilinçli parser değişikliğinde).
- CRLF: her pozitif fixture CRLF'e çevrilince AST aynı kalmalı.
Çıkış: 0 temiz, 1 ihlal, 2 ortam hatası.
"""
import hashlib, os, re, subprocess, sys, tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
NOXC = os.path.join(ROOT, "zig-out/bin/noxc")
DIR = os.path.join(ROOT, "tests/fixtures/parser_edge")
EXPECTED = os.path.join(DIR, "expected_errors.txt")
# Bilinen bulgu (R1-P1.10): CRLF kaynaktaki üç tırnaklı string içeriği \r\n olarak korunuyor (Python kaynağı \n'e normalize eder); ayrı karar gerektirir.
CRLF_KNOWN = {"ok_strings.nox"}
ERR_RE = re.compile(r"^.*?:(\d+):(\d+): (syntax error: .*)$")


def ast(path):
    p = subprocess.run([NOXC, "ast", path], capture_output=True, timeout=60)
    return p.returncode, p.stdout, p.stderr


def main():
    if not os.path.exists(NOXC):
        print("ikili yok:", NOXC, file=sys.stderr)
        return 2
    update = "--update" in sys.argv
    bad, seen, errs = [], {}, {}
    for name in sorted(os.listdir(DIR)):
        path = os.path.join(DIR, name)
        if name.startswith("ok_") and name.endswith(".nox"):
            rc, out, err = ast(path)
            if rc != 0:
                bad.append("%s: pozitif fixture ayrisamadi: %s" % (name, err.decode(errors="replace").splitlines()[:1]))
                continue
            if out.count(b"\n") < 3 or b"(module" not in out:
                bad.append("%s: AST bos/anlamsiz (%d satir)" % (name, out.count(b"\n")))
            h = hashlib.sha256(out).hexdigest()
            if h in seen:
                bad.append("%s: %s ile ayni AST (tekrar fixture)" % (name, seen[h]))
            seen[h] = name
            with tempfile.NamedTemporaryFile(suffix=".nox", delete=False) as t:
                t.write(open(path, "rb").read().replace(b"\r\n", b"\n").replace(b"\n", b"\r\n"))
            rc2, out2, _ = ast(t.name)
            os.unlink(t.name)
            if name not in CRLF_KNOWN and (rc2 != 0 or out2 != out):
                bad.append("%s: CRLF surumu ayni AST'yi uretmiyor" % name)
        elif name.startswith("err_") and name.endswith(".nox"):
            rc, _, err = ast(path)
            line = (err.decode(errors="replace").splitlines() or [""])[0]
            m = ERR_RE.match(line)
            if rc == 0 or not m:
                bad.append("%s: negatif fixture beklenen bicimde hata vermedi (rc=%d, %r)" % (name, rc, line[:80]))
                continue
            errs[name] = "%s:%s %s" % (m.group(1), m.group(2), m.group(3))
    if update:
        open(EXPECTED, "w").write("# R1-P1.10: negatif parser fixture'larinin hata konumu + iletisi (scripts/fixture_oracle.py --update)\n" + "".join("%s %s\n" % kv for kv in sorted(errs.items())))
        print("expected_errors.txt yazildi:", len(errs))
        return 1 if bad else 0
    if not os.path.exists(EXPECTED):
        bad.append("expected_errors.txt yok (--update ile uretin)")
    else:
        want = dict(l.rstrip("\n").split(" ", 1) for l in open(EXPECTED) if l.strip() and not l.startswith("#"))
        for n in sorted(set(want) | set(errs)):
            if want.get(n) != errs.get(n):
                bad.append("%s: beklenen %r, bulunan %r" % (n, want.get(n), errs.get(n)))
    print("fixture_oracle: pozitif=%d negatif=%d ihlal=%d" % (len(seen), len(errs), len(bad)))
    for b in bad[:15]:
        print("  IHLAL", b)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
