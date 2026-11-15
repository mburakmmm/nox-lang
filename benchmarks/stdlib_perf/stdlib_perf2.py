# stdlib_perf2.nox'un Python karşılığı (aynı iş, aynı sağlama toplamı). Bkz. stdlib_perf2.nox.
import collections, hashlib, hmac, heapq, math, sys, time, tomllib, fnmatch, unicodedata, datetime

if hasattr(sys, "set_int_max_str_digits"):
    sys.set_int_max_str_digits(0)

def now_ms():
    return time.monotonic_ns() / 1000000.0

def report(name, t0, check):
    print(f"{name}\t{now_ms() - t0}\t{check}")

def bench():
    t = now_ms()
    dq = collections.deque()
    for i in range(1000000):
        dq.append(i)
    s = 0
    while dq:
        s += dq.popleft()
    report("deque_push_pop_1M", t, s)

    t = now_ms()
    h = []
    for i in range(200000):
        heapq.heappush(h, (i * 7919) % 100003)
    s = 0
    while h:
        s += heapq.heappop(h) % 7
    report("heap_push_pop_200k", t, s)

    t = now_ms()
    c = {}
    for i in range(500000):
        k = (i * 31) % 1009
        c[k] = c.get(k, 0) + 1
    report("counter_add_500k", t, c.get(5, 0) * 1000 + len(c))

    t = now_ms()
    lru = collections.OrderedDict()
    s = 0
    for i in range(300000):
        k = (i * 17) % 1500
        if i % 4 != 0:
            k = i % 300
        if k in lru:
            lru.move_to_end(k)
            s += lru[k]
        else:
            lru[k] = i
            if len(lru) > 1000:
                lru.popitem(last=False)
    report("lru_get_put_300k", t, s)

    data = ("abcdefghijklmnop" * 4096).encode()
    t = now_ms()
    s = 0
    for _ in range(16):
        s += len(hashlib.sha512(data).hexdigest())
    report("sha512_64KiB_x16", t, s)

    t = now_ms()
    s = 0
    for _ in range(16):
        s += len(hashlib.sha1(data).hexdigest()) + len(hashlib.md5(data).hexdigest())
    report("sha1_md5_64KiB_x16", t, s)

    t = now_ms()
    s = 0
    for i in range(20000):
        s += len(hmac.new(("key" + str(i % 10)).encode(), ("message-" + str(i)).encode(), hashlib.sha256).hexdigest())
    report("hmac_sha256_20k", t, s)

    t = now_ms()
    txt = str(math.factorial(3000))
    report("bigint_factorial_3000_str", t, len(txt))

    parts = []
    for i in range(3000):
        parts.append(f'[t{i}]\nname = "item{i}"\nvalue = {i}\nflag = true\n')
    doc = "".join(parts)
    t = now_ms()
    tomllib.loads(doc)
    report("toml_parse_3000_tables", t, len(doc))

    t = now_ms()
    s = 0
    for i in range(200000):
        if fnmatch.fnmatch("file" + str(i) + ".txt", "file*9.t?t"):
            s += 1
    report("fnmatch_200k", t, s)

    big = "café résumé naïve " * 2000
    t = now_ms()
    s = 0
    for _ in range(20):
        s += len(unicodedata.normalize("NFC", big))
    report("unicode_nfc_x20", t, s)

    t = now_ms()
    s = 0
    utc = datetime.timezone.utc
    for i in range(100000):
        s += len(datetime.datetime.fromtimestamp((1700000000000 + i * 86400000) // 1000, tz=utc).strftime("%Y-%m-%d %H:%M:%S"))
    report("time_from_epoch_to_str_100k", t, s)

    body = "0123456789abcdef" * 65536
    path = "/tmp/nox_stdlib_perf2.bin"
    t = now_ms()
    s = 0
    for _ in range(8):
        with open(path, "w") as f:
            f.write(body)
        with open(path) as f:
            s += len(f.read())
    report("fs_write_read_1MiB_x8", t, s)

bench()
