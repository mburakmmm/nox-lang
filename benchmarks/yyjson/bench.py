"""Aynı belge/işlem, CPython json (referans)."""
import json, time

def build_doc(n):
    return "[" + ",".join('{"id":%d,"name":"item-%d","active":%s,"score":%s,"tags":["a","b"]}' % (i, i, "false" if i % 3 == 0 else "true", repr(i * 0.5 + 0.25)) for i in range(n)) + "]"

def walk(text):
    v = json.loads(text)
    ids = active = 0
    score = 0.0
    for item in v:
        ids += item["id"]
        if item["active"]:
            active += 1
        score += item["score"]
    return ids + 1000 * active + int(score)

def roundtrip(text):
    return len(json.dumps(json.loads(text), separators=(",", ":")))

text = build_doc(20000)
reps = 10
t0 = time.perf_counter()
for _ in range(reps):
    check = walk(text)
print("parse+walk python json\t%f\t%d" % ((time.perf_counter() - t0) * 1000 / reps, check))
t0 = time.perf_counter()
for _ in range(reps):
    check = roundtrip(text)
print("parse+write python json\t%f\t%d" % ((time.perf_counter() - t0) * 1000 / reps, check))
