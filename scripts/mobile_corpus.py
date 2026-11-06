#!/usr/bin/env python3
"""Mobil fixture korpusu: `tests/golden/codegen_cases` (`.nox` + `.expected`) iOS simülatöründe çalıştırılır ve çıktı `.expected` ile karşılaştırılır
(WASM karşılığı: `tests/golden/wasm_corpus_test.zig`). Kullanım: scripts/mobile_corpus.py ios <simülatör-UDID> [--filter alt-dize] [--jobs N]
          scripts/mobile_corpus.py android [--filter alt-dize] [--jobs N]   (bağlı emülatör; NOX_ANDROID_ABI=arm64|x64, ANDROID_NDK_HOME)

Sınıflandırma (WASM korpusuyla aynı ilke):
  ok        çıktı beklenenle birebir aynı
  reddedildi derleyici modülü "cannot be used on a mobile target" iletisiyle reddetti: mobilde bulunmayan modül (hpy/native/plugin/process/sharedmem/mysql/postgres); başarı sayılır
  atlandı   `tests/golden/mobile_corpus_denylist.txt` içinde gerekçeyle listelenmiş
  HATA      derleme/bağlama/çalıştırma hatası ya da çıktı farkı: betik 1 ile çıkar
"""
import concurrent.futures as cf
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import mobile_run  # noqa: E402

ROOT = mobile_run.ROOT
CASES = ROOT / "tests/golden/codegen_cases"
MOBILE_CASES = ROOT / "tests/golden/mobile_cases"  # mobil kök politikasına uyarlanmış varyantlar
DENY = ROOT / "tests/golden/mobile_corpus_denylist.txt"


def load_denylist():
    deny = {}
    if DENY.exists():
        for line in DENY.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            name, _, why = line.partition("#")
            deny[name.strip()] = why.strip()
    return deny


def one(name, ctx, work):
    """Bir fixture'ı hedefte çalıştırır ve çıktıyı .expected ile karşılaştırır."""
    base = MOBILE_CASES if name.startswith("mobile_cases/") else CASES
    stem = name.split("/")[-1]
    flat = name.replace("/", "__")
    text = (base / f"{stem}.nox").read_text(encoding="utf-8")
    expected = (base / f"{stem}.expected").read_text(encoding="utf-8")
    if ctx["platform"] == "android":
        # Android'de /tmp yoktur; uygulamanın geçici dizin kökü /data/local/tmp'dir (fixture'lardaki mutlak /tmp yolları oraya taşınır).
        text = text.replace('"/tmp/', '"/data/local/tmp/').replace('"/tmp"', '"/data/local/tmp"')
        expected = expected.replace("/tmp/", "/data/local/tmp/")
    src = work / f"{flat}.nox"
    src.write_text(text, encoding="utf-8")
    r = mobile_run.run_program(ctx, flat, src, work)
    src.unlink(missing_ok=True)
    if r.status == "rejected":
        return ("reddedildi", r.detail)
    if r.status == "error":
        return ("HATA", r.detail)
    if r.stdout == expected:
        return ("ok", "")
    return ("HATA", f"çıktı farkı (çıkış {r.returncode}); stderr: {r.stderr.strip()[:200]}")


def main():
    args = sys.argv[1:]
    if not args or args[0] not in ("ios", "android") or (args[0] == "ios" and len(args) < 2):
        sys.exit(__doc__)
    platform = args[0]
    udid = args[1] if platform == "ios" else ""
    flt = ""
    jobs = 4
    for i, a in enumerate(args):
        if a == "--filter":
            flt = args[i + 1]
        if a == "--jobs":
            jobs = int(args[i + 1])
    names = sorted(p.stem for p in CASES.glob("*.nox") if (CASES / f"{p.stem}.expected").exists() and flt in p.stem)
    names += sorted("mobile_cases/" + p.stem for p in MOBILE_CASES.glob("*.nox") if (MOBILE_CASES / f"{p.stem}.expected").exists() and flt in p.stem)
    deny = load_denylist()
    counts = {"ok": 0, "reddedildi": 0, "atlandı": 0, "HATA": 0}
    failures = []
    with tempfile.TemporaryDirectory(prefix="nox-mobile-corpus-") as w:
        work = Path(w)
        ctx = mobile_run.setup(platform, work, udid)
        todo = []
        for n in names:
            if n in deny:
                counts["atlandı"] += 1
            else:
                todo.append(n)
        with cf.ThreadPoolExecutor(jobs) as ex:
            for n, (status, detail) in zip(todo, ex.map(lambda n: one(n, ctx, work), todo)):
                counts[status] += 1
                if status == "HATA":
                    failures.append((n, detail))
                    print(f"HATA {n}: {detail}", flush=True)
    print(f"\nmobil korpus ({platform}): {len(names)} fixture; ok {counts['ok']}, reddedildi {counts['reddedildi']}, atlandı {counts['atlandı']}, HATA {counts['HATA']}")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
