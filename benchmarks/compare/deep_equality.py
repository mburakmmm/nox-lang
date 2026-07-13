class Point:
    def __init__(self, x, y):
        self.x = x
        self.y = y

    def __eq__(self, other):
        return self.x == other.x and self.y == other.y

def count_equal(n):
    a = Point(1, 2)
    b = Point(1, 2)
    la = [1, 2, 3, 4, 5, 6, 7, 8]
    lb = [1, 2, 3, 4, 5, 6, 7, 8]
    total = 0
    i = 0
    while i < n:
        if a == b:
            total = total + 1
        if la == lb:
            total = total + 1
        i = i + 1
    return total

print(count_equal(500000))
