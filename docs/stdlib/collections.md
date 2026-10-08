# nox.collections

Data structures beyond the built-in `list`, `dict` and `set`: stacks, queues, deques, counters, ordered maps, an LRU cache, a binary heap and a priority
queue. All are generic classes — you name the element type: `Stack[int]()`, `OrderedDict[str, int]()`.

```text
from nox.collections import Stack, Queue, Deque, Set, Counter, OrderedDict, LRUCache, Heap, PriorityQueue
```

**Capability:** none.

Operations that cannot succeed on an empty or missing element raise: `IndexError` for `pop`/`peek` on an empty container, `KeyError` for `OrderedDict.get`
of a missing key.

## Reference

### `Stack[T]` — last in, first out

| Method | Description |
|---|---|
| `Stack[T]()` | an empty stack |
| `push(v)` | adds `v` on top |
| `pop()` | removes and returns the top element |
| `peek()` | returns the top element without removing it |
| `is_empty()`, `size()` | emptiness and element count |

### `Queue[T]` — first in, first out

| Method | Description |
|---|---|
| `Queue[T]()` | an empty queue |
| `push(v)` | adds `v` at the back |
| `pop()` | removes and returns the front element |
| `peek()` | returns the front element |
| `is_empty()`, `size()` | emptiness and element count |

### `Deque[T]` — double-ended queue

| Method | Description |
|---|---|
| `Deque[T]()` | an empty deque |
| `push_front(v)`, `push_back(v)` | add at either end |
| `pop_front()`, `pop_back()` | remove and return from either end |
| `peek_front()`, `peek_back()` | look at either end |
| `is_empty()`, `size()` | emptiness and element count |

### `Set[T]`

A class-based set with explicit set algebra (the language also has the built-in `set[T]` type with literals and operators — see [Types](../language/types.md#collection-types)).

| Method | Description |
|---|---|
| `Set[T]()` | an empty set |
| `add(v)` | inserts `v` (a no-op if present) |
| `contains(v)` | membership |
| `remove(v)` | removes `v`; returns whether it was present |
| `size()`, `is_empty()` | count and emptiness |
| `to_list()` | the elements as a list |
| `union(other)`, `intersection(other)`, `difference(other)` | new sets |

### `Counter[T]`

| Method | Description |
|---|---|
| `Counter[T]()` | an empty counter |
| `add(v)` | increments the count of `v` |
| `count(v)` | the count of `v` (`0` if never added) |
| `total()` | the sum of all counts |
| `size()` | the number of distinct values |

### `OrderedDict[K, V]` — insertion-ordered map

| Method | Description |
|---|---|
| `OrderedDict[K, V]()` | an empty map |
| `set(k, v)` | inserts or replaces (replacing keeps the original position) |
| `get(k)` | the value for `k`; `KeyError` if absent |
| `contains(k)` | key membership |
| `remove(k)` | removes `k`; returns whether it was present |
| `keys_list()`, `values_list()` | keys / values in insertion order |
| `size()` | number of entries |

### `LRUCache[K, V]` — least-recently-used cache

| Method | Description |
|---|---|
| `LRUCache[K, V](capacity)` | a cache holding at most `capacity` entries |
| `put(k, v)` | inserts or updates; evicts the least recently used entry when full |
| `get(k)` | the value, marking it most recently used |
| `contains(k)` | membership (does not change recency) |
| `size()` | number of entries |

### `Heap[T]` — binary min-heap

| Method | Description |
|---|---|
| `Heap[T]()` | an empty heap of `int`, `float` or `str` elements |
| `push(v)` | inserts |
| `pop_min()` | removes and returns the smallest element |
| `peek_min()` | the smallest element |
| `size()`, `is_empty()` | count and emptiness |

### `PriorityQueue[T]`

| Method | Description |
|---|---|
| `PriorityQueue[T]()` | an empty queue |
| `push(priority, v)` | inserts `v` with an `int` priority (smaller is served first) |
| `pop_min()` | removes and returns the value with the smallest priority |
| `peek_min()`, `peek_min_priority()` | the next value and its priority |
| `size()`, `is_empty()` | count and emptiness |

## Examples

```nox
from nox.collections import Stack, Queue, Deque

s: Stack[int] = Stack[int]()
s.push(1)
s.push(2)
print(s.peek(), s.pop(), s.size(), s.is_empty())

q: Queue[str] = Queue[str]()
q.push("a")
q.push("b")
print(q.pop(), q.peek(), q.size())

d: Deque[int] = Deque[int]()
d.push_back(1)
d.push_front(0)
d.push_back(2)
print(d.pop_front(), d.pop_back(), d.peek_front(), d.peek_back(), d.size())
```

```output
2 2 1 False
a b 1
0 2 1 1 1
```

```nox
from nox.collections import Set, Counter, OrderedDict, LRUCache, Heap, PriorityQueue

st: Set[int] = Set[int]()
st.add(1)
st.add(2)
st.add(2)
ot: Set[int] = Set[int]()
ot.add(2)
ot.add(3)
print(st.size(), st.contains(2), st.remove(9), st.remove(1), st.to_list())
print(st.union(ot).to_list(), st.intersection(ot).to_list(), st.difference(ot).to_list())

c: Counter[str] = Counter[str]()
c.add("a")
c.add("b")
c.add("a")
print(c.count("a"), c.count("z"), c.total(), c.size())

od: OrderedDict[str, int] = OrderedDict[str, int]()
od.set("x", 1)
od.set("y", 2)
od.set("x", 3)
print(od.get("x"), od.contains("y"), od.keys_list(), od.values_list(), od.remove("y"), od.size())

lru: LRUCache[str, int] = LRUCache[str, int](2)
lru.put("a", 1)
lru.put("b", 2)
lru.get("a")
lru.put("c", 3)
print(lru.contains("a"), lru.contains("b"), lru.contains("c"), lru.size())

h: Heap[int] = Heap[int]()
h.push(5)
h.push(1)
h.push(3)
print(h.peek_min(), h.pop_min(), h.pop_min(), h.size())
pq: PriorityQueue[str] = PriorityQueue[str]()
pq.push(2, "two")
pq.push(1, "one")
print(pq.peek_min_priority(), pq.pop_min(), pq.pop_min(), pq.is_empty())
```

```output
2 True False True [2]
[2, 3] [2] []
2 0 3 2
3 True ['x', 'y'] [3, 2] True 1
True False True 2
1 1 3 1
1 one two True
```

## Notes

- Empty-container operations raise instead of returning a sentinel:

```nox
from nox.collections import Stack

s: Stack[int] = Stack[int]()
try:
    s.pop()
except IndexError as e:
    print("empty stack")
```

```output
empty stack
```

- The classes are ordinary Nox code; they are not thread-safe. Share a container between tasks through a [channel](../language/concurrency.md#channels), not by sharing the object.
