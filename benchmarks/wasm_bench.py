#!/usr/bin/env python3
"""Native LLVM / wasm varsayılan / --asyncify / --threads maliyet karşılaştırması (Faz 10.10).

Her iş yükü beş kipte derlenir ve çalıştırılır; her çalıştırmanın çıktısı native çıktıyla birebir aynı olmalıdır (aksi halde ölçüm geçersizdir ve hata verir).
Süre: duvar saati, `--runs` çalıştırmanın en küçüğü. wasm kipleri `compiler/wasm_host.mjs` (Node/V8) ile çalışır; süre modül derleme + örnekleme + çalıştırmayı kapsar
(yaklaşık sabit bir başlangıç maliyeti: boş programın süresi `empty` satırında ölçülür). Threads kipi iki işçi sayısıyla (`NOX_POOL_WORKERS` 1 ve 4) ölçülür.

Kullanım:
  benchmarks/wasm_bench.py [--runs 3] [--out benchmarks/wasm/RESULTS.md] [iş yükü adı ...]
"""
import argparse
import os
import platform
import subprocess
import sys
import tempfile
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
NOXC = os.path.join(ROOT, "zig-out/bin/noxc")
HOST = os.path.join(ROOT, "compiler/wasm_host.mjs")
B = os.path.join(ROOT, "benchmarks")

CL = f"{B}/cross_lang/nox"
WORKLOADS = {
    # Uzun çalışan (0.1-3 sn) çapraz-dil kernelleri: süreç başlangıcı sonucu bulandırmaz.
    "fib": f"{CL}/fib.nox",
    "loop": f"{CL}/loop.nox",
    "sieve": f"{CL}/sieve.nox",
    "mandel": f"{CL}/mandel.nox",
    "matmul": f"{CL}/matmul.nox",
    "dict": f"{CL}/dict.nox",
    "strings": f"{CL}/strings.nox",
    "trees": f"{CL}/trees.nox",
    "sort": f"{CL}/sort.nox",
    "collatz": f"{CL}/collatz.nox",
    # Eşzamanlılık: küçük görev/kanal trafiği ve paralel ölçekleme.
    "async_task_churn": f"{B}/async_task_churn.nox",
    "channel_pingpong": f"{B}/wasm/channel_pingpong.nox",
    "parallel_compute": f"{B}/wasm/parallel_compute.nox",
}

# (ad, hedef, ortam)
MODES = [
    ("wasm", "wasm32-wasi", {}),
    ("asyncify", "wasm32-wasi-asyncify", {}),
    ("threads x1", "wasm32-wasi-threads", {"NOX_POOL_WORKERS": "1"}),
    ("threads x4", "wasm32-wasi-threads", {"NOX_POOL_WORKERS": "4"}),
]


def timed(argv, env, runs, cwd):
    best, out = None, None
    for _ in range(runs):
        t0 = time.perf_counter()
        p = subprocess.run(argv, capture_output=True, text=True, timeout=900, cwd=cwd, env={**os.environ, **env}, input="")
        dt = time.perf_counter() - t0
        if p.returncode != 0:
            raise RuntimeError(f"çıkış {p.returncode}: {p.stderr[-200:]}")
        out = p.stdout
        best = dt if best is None else min(best, dt)
    return best, out


def build(src, work, name, target=None):
    out = os.path.join(work, name + (".wasm" if target else ""))
    argv = [NOXC, "build", "--release"] + (["--target", target] if target else []) + [src, "-o", out]
    p = subprocess.run(argv, capture_output=True, text=True, cwd=work)
    if p.returncode != 0:
        raise RuntimeError(p.stderr[-300:])
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--runs", type=int, default=3)
    ap.add_argument("--out", default="")
    ap.add_argument("--sizes-only", action="store_true", help="yalnızca derle ve modül boyutlarını yaz (çalıştırma/süre yok)")
    ap.add_argument("names", nargs="*")
    args = ap.parse_args()
    names = args.names or list(WORKLOADS)
    empty = os.path.join(tempfile.mkdtemp(prefix="nox-wasm-bench-"), "empty.nox")
    open(empty, "w").write("print(1)\n")
    rows = []
    with tempfile.TemporaryDirectory(prefix="nox-wasm-bench-") as work:
        all_workloads = {"empty": empty, **{n: WORKLOADS[n] for n in names}}
        for name, src in all_workloads.items():
            row = {"name": name}
            ref = None
            if args.sizes_only:
                row["native"] = 0.0
            else:
                try:
                    native = build(src, work, f"{name}_native")
                    row["native"], ref = timed([native], {}, args.runs, work)
                except Exception as e:  # noqa: BLE001
                    print(f"{name}: native başarısız: {e}", file=sys.stderr)
                    continue
            for label, target, env in MODES:
                try:
                    wasm = build(src, work, f"{name}_{label.replace(' ', '_')}", target)
                    row["size " + label] = os.path.getsize(wasm)
                    if args.sizes_only:
                        continue
                    t, out = timed(["node", "--no-warnings", HOST, wasm], env, args.runs, work)
                    if out != ref:
                        raise RuntimeError(f"çıktı native'den farklı: {out[:80]!r} != {ref[:80]!r}")
                    row[label] = t
                except Exception as e:  # noqa: BLE001
                    row[label] = None
                    print(f"{name} [{label}]: {e}", file=sys.stderr)
            rows.append(row)
            print(f"  {name}: " + ", ".join(f"{k}={v:.2f}s" for k, v in row.items() if k in ["native"] + [m[0] for m in MODES] and v is not None), flush=True)

    labels = [m[0] for m in MODES]
    if args.sizes_only:
        labels = [m[0] for m in MODES]
        lines = ["wasm modül boyutu (bayt, `--release`):", "", "| İş yükü | " + " | ".join(labels) + " |", "|---|" + "---|" * len(labels)]
        for r in rows:
            lines.append(f"| {r['name']} | " + " | ".join(str(r.get("size " + l, "—")) for l in labels) + " |")
        print("\n".join(lines))
        return
    lines = [
        f"Ortam: {platform.system()} {platform.machine()}, {os.cpu_count()} mantıksal çekirdek, node {subprocess.run(['node', '--version'], capture_output=True, text=True).stdout.strip()}; "
        f"her hücre {args.runs} çalıştırmanın en küçüğü (sn); parantez içi native'e oran.",
        "",
        "| İş yükü | native (LLVM --release) | " + " | ".join(labels) + " |",
        "|---|---|" + "---|" * len(labels),
    ]
    for r in rows:
        cells = []
        for l in labels:
            v = r.get(l)
            cells.append("—" if v is None else f"{v:.2f} ({v / r['native']:.1f}x)" if r["native"] >= 0.05 else f"{v:.2f}")
        lines.append(f"| {r['name']} | {r['native']:.2f} | " + " | ".join(cells) + " |")
    lines += ["", "wasm modül boyutu (bayt, `--release`):", "", "| İş yükü | " + " | ".join(labels) + " |", "|---|" + "---|" * len(labels)]
    for r in rows:
        lines.append(f"| {r['name']} | " + " | ".join(str(r.get("size " + l, "—")) for l in labels) + " |")
    text = "\n".join(lines)
    print("\n" + text)
    if args.out:
        with open(args.out, "w", encoding="utf-8") as f:
            f.write(text + "\n")


if __name__ == "__main__":
    main()
