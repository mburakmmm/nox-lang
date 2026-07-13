class Box:
    def __init__(self, items):
        self.items = items

    def sum(self):
        total = 0
        for x in self.items:
            total = total + x
        return total

def compute(n):
    b = Box([1, 2, 3, 4, 5, 6, 7, 8])
    total = 0
    i = 0
    while i < n:
        total = total + b.sum()
        i = i + 1
    return total

print(compute(300000))
