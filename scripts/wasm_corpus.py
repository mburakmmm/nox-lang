#!/usr/bin/env python3
"""WASM fixture korpusunu PARALEL ve motor seçilebilir çalıştırır (Faz 10.8).

`zig build wasm-corpus-test` aynı korpusu seri ve yalnızca Node ile koşar (saatler sürebilir). Bu betik her fixture'ı `noxc build --target <hedef>` ile derler,
seçilen motorda çalıştırır ve çıktıyı `tests/golden/codegen_cases/<ad>.expected` ile karşılaştırır. Amaç, `compiler/wasm_host.mjs` (Node) dışındaki
motorlarda da aynı davranışı kanıtlamaktır.

Motorlar:
  node      compiler/wasm_host.mjs (tüm hedefler)
  wasmtime  yalnızca wasm32-wasi ve wasm32-wasi-asyncify (wasmtime 50 wasi-threads'i kaldırdı; freestanding'in nox_host import'larını sağlamaz)

Kullanım:
  scripts/wasm_corpus.py --target wasm32-wasi-asyncify --engine wasmtime [--jobs 8] [filtre]

Çıkış kodu: beklenmeyen FARK, derleme hatası ya da zaman aşımı varsa 1. Bilinçli farklar `tests/golden/wasm_corpus_test.zig` listeleriyle aynıdır.
"""
import argparse
import concurrent.futures as cf
import glob
import os
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CASES = os.path.join(ROOT, "tests/golden/codegen_cases")

# `wasm_corpus_test.zig`deki denylist'lerle AYNI (gerekçeler orada).
LIBM = {"mathx_trig_log_constants"}
DENY = {
    "default": LIBM | {"thread_spawn_ordering", "task_local_basic"},
    "asyncify": LIBM,
    "threads": LIBM | {"async_deadlock", "thread_spawn_ordering", "task_reassignment_frees_old", "task_local_basic"},
}


def family(target):
    if target.endswith("-threads"):
        return "threads"
    if target.endswith("-asyncify"):
        return "asyncify"
    return "default"


def run_engine(engine, wasm, cwd, timeout):
    if engine == "wasmtime":
        argv = ["wasmtime", "run", "--dir", ".", "--dir", "/tmp", wasm, "--"]
    else:
        argv = ["node", "--no-warnings", os.path.join(ROOT, "compiler/wasm_host.mjs"), wasm]
    return subprocess.run(argv, cwd=cwd, capture_output=True, text=True, timeout=timeout, input="")


def one(args, work, case):
    name = os.path.basename(case)[:-4]
    exp = case[:-4] + ".expected"
    if not os.path.exists(exp):
        return name, "noexp", ""
    d = os.path.join(work, name)
    os.makedirs(d, exist_ok=True)
    shutil.copy(case, os.path.join(d, name + ".nox"))
    try:
        b = subprocess.run([os.path.join(ROOT, "zig-out/bin/noxc"), "build", "--target", args.target, name + ".nox"],
                           cwd=d, capture_output=True, text=True, timeout=600)
    except subprocess.TimeoutExpired:
        return name, "timeout", "derleme"
    wasm = os.path.join(d, name + ".wasm")
    if b.returncode != 0 or not os.path.exists(wasm):
        # Hedefte olmayan modül (http/sqlite/...) kullanan fixture'ı derleyici açık iletiyle reddeder; bu başarıdır.
        if "wasm32-wasi target" in b.stderr or "wasm32-freestanding target" in b.stderr:
            return name, "rejected", ""
        return name, "build", (b.stderr or b.stdout)[-300:]
    try:
        p = run_engine(args.engine, wasm, d, args.timeout)
    except subprocess.TimeoutExpired:
        return name, "timeout", ""
    finally:
        for f in glob.glob(d + "/*.ll") + glob.glob(d + "/*.wasm"):
            os.remove(f)
    with open(exp, encoding="utf-8") as f:
        want = f.read()
    if p.stdout == want:
        return name, "ok", ""
    return name, "diff", (p.stderr[-300:] or p.stdout[-200:])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--target", default="wasm32-wasi")
    ap.add_argument("--engine", default="node", choices=["node", "wasmtime"])
    ap.add_argument("--jobs", type=int, default=8)
    ap.add_argument("--timeout", type=int, default=180)
    ap.add_argument("filter", nargs="?", default="")
    args = ap.parse_args()
    if args.engine == "wasmtime" and (args.target.endswith("-threads") or "freestanding" in args.target):
        sys.exit("wasmtime yalnızca wasm32-wasi ve wasm32-wasi-asyncify için kullanılabilir")
    deny = DENY[family(args.target)]
    cases = [c for c in sorted(glob.glob(CASES + "/*.nox")) if args.filter in c and os.path.basename(c)[:-4] not in deny]
    res = {}
    with tempfile.TemporaryDirectory(prefix="nox-wasm-corpus-") as work, cf.ThreadPoolExecutor(args.jobs) as ex:
        for name, st, msg in ex.map(lambda c: one(args, work, c), cases):
            res.setdefault(st, []).append((name, msg))
    print(f"== {args.target} / {args.engine}: " + ", ".join(f"{st} {len(l)}" for st, l in sorted(res.items())))
    bad = False
    for st in ("diff", "build", "timeout"):
        for name, msg in res.get(st, []):
            bad = True
            print(f"  {st.upper()}: {name}: {msg.strip()[:200]}")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
