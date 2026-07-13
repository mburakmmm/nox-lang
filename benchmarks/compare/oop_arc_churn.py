class Engine:
    def __init__(self, hp):
        self.hp = hp

class Car:
    def __init__(self, engine):
        self.engine = engine

    def swap(self, other):
        self.engine = other

def make_car(hp):
    return Car(Engine(hp))

def compute(n):
    total = 0
    c = Car(Engine(0))
    i = 0
    while i < n:
        c.swap(make_car(i).engine)
        total = total + c.engine.hp
        i = i + 1
    return total

print(compute(3000000))
