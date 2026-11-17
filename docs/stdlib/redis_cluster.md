# nox.redis_cluster

A Redis Cluster client on top of [`nox.redis`](redis.md). It computes each key's hash slot (CRC16, with `{hash tag}` support), sends the command to the node that owns the slot, follows `-MOVED` and `-ASK` redirects,
and refreshes the slot map when a node goes away. Pure Nox; RESP2.

**Capability:** `network`.

```nox
import nox.redis_cluster

slot: int = nox.redis_cluster.key_slot("user:1000")
print(slot >= 0 and slot < 16384)
print(nox.redis_cluster.key_slot("a{b}c") == nox.redis_cluster.key_slot("b"))
print(nox.redis_cluster.same_slot(["{u}.a", "{u}.b"]), nox.redis_cluster.same_slot(["a", "b"]))
```

```output
True
True
True False
```

Connecting and using a cluster:

```text
c: nox.redis_cluster.ClusterClient = nox.redis_cluster.connect(["10.0.0.1:7000", "10.0.0.2:7000"])
c.command("user:1", ["SET", "user:1", "ada"])
print(c.command("user:1", ["GET", "user:1"]).as_str())
c.close()
```

| Call | Description |
|---|---|
| `connect(seeds, tls=False, username="", password="", ca_file="", read_timeout_ms=0, max_redirects=5) -> ClusterClient` | `seeds` is a list of `"host:port"`; at least one must answer `CLUSTER SLOTS`. Node connections are opened lazily and reused; the options are applied to every node |
| `c.command(key, args) -> Reply` | runs `args` on the node that owns `key`'s slot (the key must also appear in `args`). Raises the same `RedisError` as `nox.redis` for server errors |
| `c.refresh()` | re-reads the topology (`CLUSTER SLOTS`) from a known node or a seed |
| `c.slot_owner(slot) -> str` | the `"host:port"` that serves a slot |
| `c.close()` | closes every node connection |
| `key_slot(key) -> int`, `same_slot(keys) -> bool` | the hash slot (0–16383) and a same-slot check for multi-key commands |

Redirects: a `-MOVED` updates the slot map and the command is retried on the new owner; an `-ASK` (slot migration in progress) sends `ASKING` plus the command to the target without changing the map; a broken
connection triggers one topology refresh and a retry. More than `max_redirects` hops raises `ClusterError`.

Limits: multi-key commands (`MGET`, `MSET`, Lua scripts) need all keys in one slot (use `{tags}`; the server answers `-CROSSSLOT` otherwise); there is no pub/sub, no pipelining across nodes, and every command goes to the slot's primary
(no reads from replicas). Verified against a real three-node cluster (slot arithmetic cross-checked with the server's `CLUSTER KEYSLOT`, `-MOVED` self-healing and `-ASK`), see `scripts/redis_cluster_probe.py`.
