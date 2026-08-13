-- json_post.lua — wrk script for run_json_worker_sweep.sh: POSTs a small,
-- fixed JSON body (mirrors the shape used to profile+fix the Faz MN.10
-- pool_free_lists lock contention: a handful of scalars + a nested array +
-- a nested object, ~30-50 tiny ARC allocations per nox.json.decode/encode
-- round-trip) to the JSON echo handler.
wrk.method = "POST"
wrk.body = '{"name":"nox","value":42,"tags":["a","b","c"],"nested":{"x":1,"y":2}}'
wrk.headers["Content-Type"] = "application/json"
