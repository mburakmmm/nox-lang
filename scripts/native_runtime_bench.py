#!/usr/bin/env python3
"""Native-runtime readiness R2/R3 olcumleri (project/native-runtime-performance.md). Yalniz olcum: gercek runtime degismez.

  python3 scripts/native_runtime_bench.py [--runs 5]

Cikti: her olcum icin min/medyan (ns). Ortam satiri (CPU/OS/derleyici) basa yazilir. ReleaseFast/-O2 ile; instrumentation yok.
"""
import os
import platform
import re
import statistics
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import runtime_leaf_audit as A  # noqa: E402

ROOT = A.ROOT
LEAF = os.path.join(ROOT, "tests", "native_runtime", "leaf")
NR = os.path.join(ROOT, "tests", "native_runtime")


def build(noxc, src, out):
    obj, _ = A.build_obj(noxc, src, out)
    return obj


def cc(out, srcs, exe):
    gc = "-Wl,-dead_strip" if sys.platform == "darwin" else "-Wl,--gc-sections"
    r = subprocess.run(["clang", "-O2", "-pthread", *srcs, gc, "-o", exe], capture_output=True, text=True)
    if r.returncode:
        raise RuntimeError(r.stderr[-800:])


def runs(exe, args, n):
    outs = []
    for _ in range(n):
        outs.append(subprocess.run([exe, *args], capture_output=True, text=True).stdout.strip())
    return outs


def nums(line, key):
    m = re.search(re.escape(key) + r"[^0-9]*([0-9.]+)", line)
    return float(m.group(1))


def main():
    n = int(sys.argv[sys.argv.index("--runs") + 1]) if "--runs" in sys.argv else 5
    noxc = os.environ.get("NOXC", os.path.join(ROOT, "zig-out", "bin", "noxc"))
    cpu = subprocess.run(["sysctl", "-n", "machdep.cpu.brand_string"], capture_output=True, text=True).stdout.strip() or platform.processor()
    print(f"ortam: {platform.system()} {platform.machine()} | {cpu} | clang -O2 | tekrar={n}")
    with tempfile.TemporaryDirectory(prefix="nrbench_") as td:
        # allocator: nox-alloc vs libc malloc
        d1 = os.path.join(td, "a"); os.makedirs(d1)
        obj = build(noxc, os.path.join(LEAF, "p06_allocator.nox"), d1)
        exe = os.path.join(td, "alloc_bench")
        cc(td, [os.path.join(LEAF, "p06_allocator.c"), os.path.join(NR, "shim", "rtcore_provider.c"), obj], exe)
        o = runs(exe, ["--bench"], n)
        a = [nums(x, "nox-alloc alloc+free(64B):") for x in o]
        m = [nums(x, "libc malloc+free:") for x in o]
        print(f"allocator alloc+free(64B) : nox-alloc min {min(a):.2f} med {statistics.median(a):.2f} ns | libc malloc min {min(m):.2f} med {statistics.median(m):.2f} ns | oran(med) {statistics.median(a)/statistics.median(m):.2f}x")
        # atomics
        d2 = os.path.join(td, "b"); os.makedirs(d2)
        obj = build(noxc, os.path.join(LEAF, "p05_atomics.nox"), d2)
        exe = os.path.join(td, "atomic_bench")
        cc(td, [os.path.join(NR, "bench", "atomic_bench.c"), os.path.join(NR, "shim", "rtcore_atomic_shim.c"), obj], exe)
        o = runs(exe, [], n)
        for key, label in (("nox-leaf->shim:", "Nox leaf -> extern shim"), ("C inline __atomic:", "C satir ici __atomic   "), ("C->shim call:", "C -> shim cagrisi      ")):
            v = [nums(x, key) for x in o]
            print(f"atomic fetch_add relaxed  : {label} min {min(v):.3f} med {statistics.median(v):.3f} ns/op")
    return 0


if __name__ == "__main__":
    sys.exit(main())
