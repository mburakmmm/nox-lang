i = 0
total = 0
n = 20000000
while i < n:
    total = total + i * i - i
    i = i + 1
print(total)
