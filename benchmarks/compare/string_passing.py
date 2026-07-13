def pick(i):
    if i % 3 == 0:
        return "alpha"
    if i % 3 == 1:
        return "beta"
    return "gamma"

def pass_through(s):
    return s

def compute(n):
    count = 0
    i = 0
    while i < n:
        s = pass_through(pass_through(pick(i)))
        if i % 3 == 0:
            count = count + 1
        i = i + 1
    return count

print(compute(15000000))
