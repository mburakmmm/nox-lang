# WebSockets and jobs

`aether.gateway` is the WebSocket entry. `aether.queue` is the SQLite job queue. Both are worker-aware: an in-memory hub or a metric on one worker is not visible on another.

## Gateways

`AETHER_WS=1` enables the upgrade path. A gateway registers rooms. Broadcast goes to the sockets in that room **on this worker**. The default room policy is the safe one: a client does not join an arbitrary room name taken from the query string unless you opted into that.

Token auth for the upgrade uses the same JWT helper as HTTP. Check it before the socket is accepted.

## Queue

Jobs live in the SQLite file `AETHER_JOBS_DB`. A worker leases a job. The lease is considered stale after `AETHER_JOB_STALE_MS`, and a later worker may reclaim it. Reclaim is atomic: two workers do not both win the same row.

A failed job can be marked dead. `list_dead`, `requeue_dead` and `mark_dead` are the dead-letter operations. The lease update checks the affected-row count, so a lost race does not look like success.

Run the consumer in the same process family as the API only if you accept that each OS worker has its own view of in-memory state. The database is the shared part. Do not keep the only copy of a job payload in a module global.

## Metrics

`AETHER_METRICS=1` exposes `/metrics`. `AETHER_METRICS_ROUTES=1` adds per-route counters. Those counters are per worker. A scrape of one process is not a cluster total. Pattern keys, not raw URLs, are what get counted, so a parameter does not explode the metric set.
