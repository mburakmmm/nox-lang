"""lang_perf.nox'un Python karşılığı: AYNI iş, AYNI sağlama toplamları (ad<TAB>ms<TAB>sağlama). Dil çekirdeği mikro/makro kıyas paketi (TODO 3.5.1)."""
import time, sys

S = int(sys.argv[1]) if len(sys.argv) > 1 else 1

def now(): return time.perf_counter() * 1000.0
def report(name, t0, check): print(f"{name}\t{now() - t0}\t{check}")

def fib(n):
    return n if n < 2 else fib(n - 1) + fib(n - 2)

class Counter:
    def __init__(self): self.total = 0
    def add(self, x): self.total = (self.total * 31 + x) % 1000000007
    def get(self): return self.total

class Shape:
    def area(self): return 0
class Sq(Shape):
    def __init__(self, s): self.s = s
    def area(self): return self.s * self.s
class Rect(Shape):
    def __init__(self, a, b): self.a = a; self.b = b
    def area(self): return self.a * self.b
class Tri(Shape):
    def __init__(self, a, b): self.a = a; self.b = b
    def area(self): return self.a * self.b // 2

class Node:
    def __init__(self, l, r): self.l = l; self.r = r

def build(d):
    if d == 0: return Node(None, None)
    return Node(build(d - 1), build(d - 1))
def count(n):
    if n is None: return 0
    return 1 + count(n.l) + count(n.r)

def apply(f, x): return f(x)
def inc(x): return x + 1

def gen(n):
    i = 0
    while i < n:
        yield i
        i += 1

def risky(i):
    if i % 3 == 0: raise ValueError("x")
    return i

def lcg(seed):
    return (seed * 1103515245 + 12345) % 2147483648

def bench():
    t = now(); s = 0
    for i in range(5000000 * S): s += (i * i) % 7 + (i ^ (i >> 3))
    report("loop_arith_5M", t, s)

    t = now(); ft = 0
    for r in range(S): ft += fib(30 + r % 3)
    report("fib_rec_30_32", t, ft)

    t = now(); tot = 0
    for n in range(1, 300000 * S + 1):
        x = n; steps = 0
        while x != 1:
            x = x // 2 if x % 2 == 0 else 3 * x + 1
            steps += 1
        tot += steps
    report("collatz_300k", t, tot)

    t = now(); n = 4000000 * S
    sieve = [True] * n; sieve[0] = False; sieve[1] = False
    i = 2
    while i * i < n:
        if sieve[i]:
            j = i * i
            while j < n:
                sieve[j] = False; j += i
        i += 1
    report("sieve_4M", t, sum(1 for v in sieve if v))

    t = now(); m = 100
    a = [[float((i * j) % 7) + 0.5 for j in range(m)] for i in range(m)]
    b = [[float((i + j) % 5) - 1.25 for j in range(m)] for i in range(m)]
    c = [[0.0] * m for _ in range(m)]
    tr = 0.0
    for rr in range(S):
        a[0][0] = float(rr) + 0.5
        for i in range(m):
            for j in range(m):
                acc = 0.0
                for k in range(m): acc += a[i][k] * b[k][j]
                c[i][j] = acc
        tr = 0.0
        for i in range(m): tr += c[i][i]
    report("matmul_100", t, int(tr * 1000.0))

    t = now(); x = 0.0; y = 1.0
    for i in range(3000000 * S):
        x = x * 0.999 + y * 0.001
        y = y * 1.0001 - x * 0.0001
    report("float_loop_3M", t, int(x * 1000000.0) + int(y * 1000000.0))

    t = now(); d = {}
    for i in range(1500000 * S):
        k = (i * 7919) % 100003
        d[k] = d.get(k, 0) + 1
    report("dict_int_1.5M", t, len(d) * 1000 + d[5])

    t = now(); ds = {}
    for i in range(500000 * S):
        k = "k" + str(i % 50000)
        ds[k] = ds.get(k, 0) + i
    report("dict_str_500k", t, len(ds) * 7 + ds["k123"])

    t = now(); xs = []
    for i in range(2000000 * S): xs.append(i * 3)
    tot = 0
    for v in xs: tot += v
    while len(xs) > 1000000 * S: xs.pop()
    report("list_append_sum_pop_2M", t, tot + len(xs))

    t = now(); parts = [str(i) for i in range(300000 * S)]
    joined = ",".join(parts)
    report("str_build_join_300k", t, len(joined))

    t = now(); cn = Counter()
    for i in range(3000000 * S): cn.add(i)
    report("method_calls_3M", t, cn.get())

    t = now(); shapes = []
    for i in range(1000): shapes.append(Sq(i) if i % 3 == 0 else (Rect(i, 2) if i % 3 == 1 else Tri(i, 4)))
    tot = 0
    for r in range(2000 * S):
        for sh in shapes: tot += sh.area()
    report("virtual_dispatch_2M", t, tot)

    t = now(); tot = 0
    for i in range(2000000 * S): tot += apply(inc, i)
    report("func_value_calls_2M", t, tot)

    t = now(); tot = 0
    for v in gen(1500000 * S): tot += v
    report("generator_1.5M", t, tot)

    t = now(); caught = 0; tot = 0
    for i in range(200000 * S):
        try: tot += risky(i)
        except ValueError: caught += 1
    report("exceptions_200k", t, caught * 1000003 + tot)

    t = now(); tot = 0
    for r in range(4 * S): tot += count(build(17))
    report("alloc_tree_17x4", t, tot)

    t = now(); seed = 7; arr = []
    for i in range(500000 * S):
        seed = lcg(seed); arr.append(seed)
    arr.sort()
    report("sort_500k", t, arr[0] + arr[250000 * S] + arr[500000 * S - 1])

    t = now(); chk = 0
    for rr in range(S):
        seed = 11 + rr; small = []
        for i in range(3000):
            seed = lcg(seed); small.append(seed % 10000)
        for i in range(1, len(small)):
            v = small[i]; j = i - 1
            while j >= 0 and small[j] > v:
                small[j + 1] = small[j]; j -= 1
            small[j + 1] = v
        chk = small[0] + small[1500] + small[2999]
    report("insertion_sort_3k", t, chk)

    t = now(); text = "abcab" * (200000 * S); c = 0
    for i in range(len(text)):
        if text[i] == "a": c += 1
    report("str_index_loop_1M", t, c)

bench()
