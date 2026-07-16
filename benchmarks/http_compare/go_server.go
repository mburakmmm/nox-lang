// go_server.go — minimal net/http baseline for the Nox/Go/Zig/FastAPI HTTP
// throughput comparison (see benchmarks/RESULTS.md). Returns EXACTLY the
// same response shape as nox_server.nox: status 200, header "x: x", body
// "ok" — Go's net/http uses GOMAXPROCS goroutines across all CPU cores by
// default, no extra flags needed for multi-core.
package main

import (
	"net/http"
)

func handler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("x", "x")
	w.WriteHeader(200)
	w.Write([]byte("ok"))
}

func main() {
	http.HandleFunc("/", handler)
	http.ListenAndServe(":8801", nil)
}
