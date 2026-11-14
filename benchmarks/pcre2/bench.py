import re, time
def build_numbers(n): return " ".join("n" + str(i * 37 % 100003) for i in range(n))
def build_prose(n):
    words = ["alpha", "beta", "foo", "gamma", "bar", "delta", "baz", "epsilon", "zeta", "contact", "bob@example.com", "eta"]
    return " ".join(words[(i * 7 + i // 3) % len(words)] for i in range(n))
nums = build_numbers(50000); prose = build_prose(200000); reps = 10
def run(name, rx, text):
    t0 = time.perf_counter(); c = 0
    for _ in range(reps): c = sum(1 for _ in rx.finditer(text))
    print(f"{name}\t{(time.perf_counter() - t0) * 1000 / reps}\t{c}")
run("digits count python re", re.compile("[0-9]+"), nums)
run("words count python re", re.compile(r"\b(foo|bar|baz)\b"), prose)
run("email count python re", re.compile(r"(\w+)@(\w+)\.com"), prose)
