# fastapi_server.py -- minimal FastAPI baseline for the Nox/Go/Zig/FastAPI
# HTTP throughput comparison (see benchmarks/RESULTS.md). Returns the same
# response shape as the other three servers: status 200, header "x: x",
# body "ok". Run with:
#   uvicorn fastapi_server:app --host 0.0.0.0 --port 8801 --workers 10
# (--workers spawns N separate processes, FastAPI/uvicorn's standard way
# of using multiple cores -- there is no shared-memory multi-threading
# option the way Go/Zig/Nox use here).
from fastapi import FastAPI
from fastapi.responses import PlainTextResponse

app = FastAPI()


@app.get("/")
def root() -> PlainTextResponse:
    return PlainTextResponse("ok", headers={"x": "x"})
