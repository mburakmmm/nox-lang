"""stdlib_perf.nox'un Python karşılığı: AYNI iş, AYNI sağlama toplamları (ad<TAB>ms<TAB>sağlama)."""
import base64, csv, gzip, hashlib, io, json, os, random, re, time, uuid
from urllib.parse import urlsplit, quote, unquote

def now(): return time.perf_counter() * 1000.0
def report(name, t0, check): print(f"{name}\t{now() - t0}\t{check}")

def bench():
    t = now(); src = ",".join(str(i) for i in range(200000)); report("str_build_join_200k", t, len(src))
    t = now(); tot = 0
    for _ in range(5): tot += len(src.split(","))
    report("str_split_200k_x5", t, tot)
    t = now(); tot = 0
    for _ in range(5): tot += len(src.replace("1", "xyz"))
    report("str_replace_x5", t, tot)
    t = now(); cnt = 0
    for pos in range(300000):
        k = ("item" + str(pos) + "tail").find("9")
        if k >= 0: cnt += k
    report("str_find_300k_small", t, cnt)
    t = now(); tot = 0
    for _ in range(20): tot += len(src.upper()) + len(src.lower()) + len(("  " + src + "  ").strip())
    report("str_upper_lower_trim_x20", t, tot)
    t = now(); acc = ""
    for _ in range(1000000): acc += "x"
    report("str_concat_1M", t, len(acc))
    t = now(); tot = 0
    for i in range(300000): tot += len(f"{i}:{i * 2}")
    report("fstring_300k", t, tot)

    parts = ['{"id":' + str(i) + ',"name":"item_' + str(i) + '","tags":["a","b"],"v":1.5}' for i in range(50000)]
    jtext = "[" + ",".join(parts) + "]"
    t = now(); jv = json.loads(jtext); report("json_parse_50k_objs", t, len(jv))
    t = now(); out = json.dumps(jv, separators=(",", ":")); report("json_dump_50k_objs", t, len(out))

    rtext = " ".join("w" + str(i) + "x" for i in range(50000))
    t = now(); ms = re.findall("[0-9]+", rtext); report("regex_find_all_digits", t, len(ms))
    t = now(); rr = re.sub("[0-9]+", "#", rtext); report("regex_replace_digits", t, len(rr))

    blob = "The quick brown fox jumps over the lazy dog. " * 90000
    t = now(); enc = base64.b64encode(blob.encode()).decode(); report("base64_encode_4MB", t, len(enc))
    t = now(); dec = base64.b64decode(enc).decode(); report("base64_decode_4MB", t, len(dec))
    t = now(); tot = 0; chunk = ("abcdefgh" * 8192).encode()
    for _ in range(128): tot += len(hashlib.sha256(chunk).hexdigest())
    report("sha256_64KiB_x128", t, tot)
    t = now(); z = gzip.compress(blob.encode()); report("gzip_compress_4MB", t, "n/a")
    t = now(); unz = gzip.decompress(z).decode(); report("gzip_decompress_4MB", t, len(unz))

    rows = [str(i) + ",name" + str(i) + ',"quoted, text",' + str(i * 3) + ",end" for i in range(50000)]
    ctext = "\n".join(rows)
    t = now(); parsed = list(csv.reader(io.StringIO(ctext))); report("csv_parse_50k_rows", t, len(parsed))
    t = now(); tot = 0
    for i in range(100000): tot += len(urlsplit("https://example.com:8080/a/b/c?x=" + str(i) + "&y=hello%20world#frag").path)
    report("url_parse_100k", t, tot)
    t = now(); tot = 0
    for i in range(100000): tot += len(unquote(quote("hello world/" + str(i) + "?&=", safe="")))
    report("url_percent_roundtrip_100k", t, tot)
    t = now(); tot = 0
    for i in range(300000): tot += len(os.path.basename(os.path.join("/usr/local/lib", "file" + str(i) + ".txt")))
    report("path_join_basename_300k", t, tot)

    t = now(); st = set()
    for i in range(200000): st.add(i % 150000)
    hits = 0
    for i in range(200000):
        if i in st: hits += 1
    report("set_add_contains_200k", t, hits + len(st))
    t = now(); d = {}
    for i in range(300000): d["key" + str(i)] = i
    tot = 0
    for i in range(300000): tot += d["key" + str(i)]
    report("dict_str_insert_lookup_300k", t, tot % 1000003)
    t = now(); nums = []; x = 12345
    for _ in range(1000000):
        x = (x * 1103515245 + 12345) % 2147483648
        nums.append(x)
    nums.sort(); report("sort_1M_ints", t, nums[0] + nums[999999] % 1000003)
    t = now(); strs = []
    for _ in range(200000):
        x = (x * 1103515245 + 12345) % 2147483648
        strs.append("s" + str(x))
    strs.sort(); report("sort_200k_strs", t, len(strs[0]) + len(strs[199999]))
    random.seed(1)
    t = now(); fsum = 0.0
    for _ in range(3000000): fsum += random.random()
    report("random_3M", t, 1 if fsum > 1000000.0 else 0)
    t = now(); tot = 0
    for _ in range(100000): tot += len(str(uuid.uuid4()))
    report("uuid4_100k", t, tot)

bench()
