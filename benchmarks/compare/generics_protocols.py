class Circle:
    def __init__(self, r):
        self.r = r

    def area(self):
        return 3.14159 * self.r * self.r

class Square:
    def __init__(self, s):
        self.s = s

    def area(self):
        return self.s * self.s

def identity(x):
    return x

def total_area(shape, n):
    total = 0.0
    i = 0
    while i < n:
        total = total + shape.area()
        i = i + 1
    return total

def compute(n):
    c = Circle(2.0)
    s = Square(3.0)
    total = 0.0
    total = total + total_area(c, n)
    total = total + total_area(s, n)
    i = 0
    while i < n:
        total = total + identity(i) * 1.0
        i = i + 1
    return total

print(compute(15000000))
