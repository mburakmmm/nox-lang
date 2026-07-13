def make_data():
    return [3, 1, 4, 1, 5, 9, 2, 6, 5, 3, 5, 8, 9, 7, 9, 3, 2, 3, 8, 4]

def sum_list(xs):
    total = 0
    for v in xs:
        total = total + v
    return total

def compute(n):
    total = 0
    i = 0
    while i < n:
        total = total + sum_list(make_data())
        i = i + 1
    return total

print(compute(5000000))
