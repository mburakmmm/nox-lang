class Point:
    def __init__(self, x, y):
        self.x = x
        self.y = y

def compute(n):
    total = 0
    i = 0
    while i < n:
        p = Point(i, i + 1)
        nums = [1, 2, 3, 4, 5, 6, 7, 8]
        j = 0
        inner = 0
        while j < 8:
            inner = inner + nums[j]
            j = j + 1
        total = total + p.x + p.y + inner
        i = i + 1
    return total

print(compute(5000000))
