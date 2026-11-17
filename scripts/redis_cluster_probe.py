#!/usr/bin/env python3
"""`nox.redis_cluster` GERÇEK bir 3 düğümlü Redis Cluster'a karşı (v2.2.2): CRC16 yuva hesabı (sunucunun `CLUSTER KEYSLOT`ı ile çapraz), yuvalar arası okuma/yazma, bayat yuva tablosunun `-MOVED` ile
düzelmesi ve göç sürerken `-ASK` yönetimi. İki arka uç (LLVM ve QBE). `redis-server`/`redis-cli` yoksa 77 ile çıkar (test atlanır). Kullanım: scripts/redis_cluster_probe.py [zig-out/bin/noxc]"""
import os, shutil, socket, subprocess, sys, tempfile, time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
noxc = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, "zig-out/bin/noxc")
server, cli = shutil.which("redis-server"), shutil.which("redis-cli")
if not server or not cli:
    sys.exit(77)

def free_port():
    s = socket.socket(); s.bind(("127.0.0.1", 0)); p = s.getsockname()[1]; s.close(); return p

def rcli(port, *args):
    return subprocess.run([cli, "-p", str(port), *args], capture_output=True, text=True, timeout=30).stdout.strip()

procs = []
try:
    with tempfile.TemporaryDirectory() as tmp:
        ports = []
        for i in range(3):
            # küme veri yolu: p ve p+10000 (küme veriyolu) boş olmalı
            while True:
                p = free_port()
                if p < 50000:
                    ports.append(p); break
        for p in ports:
            d = os.path.join(tmp, str(p)); os.makedirs(d)
            procs.append(subprocess.Popen([server, "--port", str(p), "--bind", "127.0.0.1", "--cluster-enabled", "yes", "--cluster-config-file", os.path.join(d, "nodes.conf"),
                                           "--cluster-node-timeout", "5000", "--save", "", "--appendonly", "no", "--dir", d], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
        for p in ports:
            for _ in range(60):
                try:
                    socket.create_connection(("127.0.0.1", p), timeout=0.2).close(); break
                except OSError:
                    time.sleep(0.2)
        r = subprocess.run([cli, "--cluster", "create", *[f"127.0.0.1:{p}" for p in ports], "--cluster-replicas", "0", "--cluster-yes"], capture_output=True, text=True, timeout=60)
        if r.returncode != 0:
            print("küme kurulamadı:", r.stdout, r.stderr); sys.exit(77)
        for _ in range(60):  # küme durumu "ok"
            if "cluster_state:ok" in rcli(ports[0], "cluster", "info"):
                break
            time.sleep(0.3)

        keys = ["foo", "bar", "123456789", "user:1000", "{user1000}.following", "{user1000}.followers", "a{b}c", "a{}c", "a{b", "x{}{y}", "çalışma", "k" * 40]
        want = [rcli(ports[0], "cluster", "keyslot", k) for k in keys]
        nox_keys = ", ".join('"%s"' % k for k in keys)
        program = f'''import nox.redis_cluster
from nox.redis import Reply

c: nox.redis_cluster.ClusterClient = nox.redis_cluster.connect(["127.0.0.1:{ports[0]}"])
for k in [{nox_keys}]:
    print(k, nox.redis_cluster.key_slot(k))
print(nox.redis_cluster.same_slot(["{{u}}a", "{{u}}b"]), nox.redis_cluster.same_slot(["a", "b"]))
i: int = 0
while i < 200:
    c.command("key:" + str(i), ["SET", "key:" + str(i), "v" + str(i)])
    i = i + 1
bad: int = 0
i = 0
while i < 200:
    if c.command("key:" + str(i), ["GET", "key:" + str(i)]).as_str() != "v" + str(i):
        bad = bad + 1
    i = i + 1
print("roundtrip bad", bad, "nodes used", len(c.nodes))
# bayat yuva tablosu: yanlış düğümü sahip göster -> MOVED ile düzelir
slot: int = nox.redis_cluster.key_slot("key:7")
right: str = c.slot_owner(slot)
wrong: str = ""
for a in c.nodes:
    if a != right and len(wrong) == 0:
        wrong = a
c.owner[slot] = wrong
before: int = c.redirects
print("after MOVED", c.command("key:7", ["GET", "key:7"]).as_str(), "redirects", c.redirects - before, "owner fixed", c.slot_owner(slot) == right)
# göç sürerken: kaynak düğümde olmayan anahtar için -ASK
ask_slot: int = nox.redis_cluster.key_slot("askkey")
print("ask slot", ask_slot, c.slot_owner(ask_slot))
c.close()
'''
        path = os.path.join(tmp, "p.nox"); open(path, "w").write(program)
        outs = {}
        for backend in ("llvm", "qbe"):
            r = subprocess.run([noxc, "run", "--backend", backend, path], capture_output=True, text=True, timeout=300)
            if r.returncode != 0:
                print(f"[{backend}] çıkış {r.returncode}\n{r.stdout}\n{r.stderr}"); sys.exit(1)
            outs[backend] = r.stdout
        if outs["llvm"] != outs["qbe"]:
            print("iki arka uç farklı çıktı verdi\n", outs); sys.exit(1)
        lines = outs["llvm"].splitlines()
        for k, w in zip(keys, want):
            line = lines.pop(0)
            if line != f"{k} {w}":
                print("yuva uyuşmuyor:", line, "beklenen", w); sys.exit(1)
        expect = ["True False", "roundtrip bad 0 nodes used 3", "after MOVED v7 redirects 1 owner fixed True"]
        for e in expect:
            got = lines.pop(0)
            if got != e:
                print("beklenmeyen:", got, "beklenen:", e); sys.exit(1)
        # --- ASK: kaynak MIGRATING, hedef IMPORTING ---
        ask_slot = int(lines[0].split()[2]); src_addr = lines[0].split()[3]
        src_port = int(src_addr.split(":")[1]); dst_port = next(p for p in ports if p != src_port)
        src_id, dst_id = rcli(src_port, "cluster", "myid"), rcli(dst_port, "cluster", "myid")
        rcli(dst_port, "cluster", "setslot", str(ask_slot), "importing", src_id)
        rcli(src_port, "cluster", "setslot", str(ask_slot), "migrating", dst_id)
        # hedefte anahtar var, kaynakta yok: kaynak -ASK döner, istemci ASKING + GET ile hedeften okur
        rcli(dst_port, "asking")
        subprocess.run([cli, "-p", str(dst_port)], input="ASKING\nSET askkey askvalue\n", capture_output=True, text=True, timeout=30)
        program2 = f'''import nox.redis_cluster

c: nox.redis_cluster.ClusterClient = nox.redis_cluster.connect(["127.0.0.1:{ports[0]}"])
before: int = c.redirects
r: nox_redis_Reply = c.command("askkey", ["GET", "askkey"])
print("ask value", r.as_str(), "redirects", c.redirects - before)
c.close()
'''
        path2 = os.path.join(tmp, "p2.nox"); open(path2, "w").write(program2.replace("nox_redis_Reply", "nox.redis.Reply").replace("import nox.redis_cluster\n", "import nox.redis\nimport nox.redis_cluster\n"))
        for backend in ("llvm", "qbe"):
            r = subprocess.run([noxc, "run", "--backend", backend, path2], capture_output=True, text=True, timeout=300)
            if r.returncode != 0 or r.stdout.strip() != "ask value askvalue redirects 1":
                print(f"[ask {backend}] beklenmeyen: {r.stdout!r} {r.stderr!r}"); sys.exit(1)
        rcli(src_port, "cluster", "setslot", str(ask_slot), "stable"); rcli(dst_port, "cluster", "setslot", str(ask_slot), "stable")
    print("ok")
finally:
    for p in procs:
        p.kill()
