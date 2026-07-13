class NegativeError(Exception):
    def __init__(self, value):
        self.value = value

def check(x):
    if x % 3 == 0:
        raise NegativeError(x)
    return x * 2

def compute(n):
    total = 0
    i = 0
    while i < n:
        try:
            total = total + check(i)
        except NegativeError as e:
            total = total + e.value
        finally:
            total = total + 1
        i = i + 1
    return total

print(compute(5000000))
