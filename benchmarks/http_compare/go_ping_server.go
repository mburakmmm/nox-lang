// 2.3 madde 5.1: Go ping sunucusu (GOMAXPROCS = işçi sayısı); Nox/C ile aynı yanıt (200, "x: x", "ok").
package main

import (
	"net/http"
	"os"
	"strconv"
	"runtime"
)

func main() {
	port := ":8806"
	if len(os.Args) > 1 { port = ":" + os.Args[1] }
	if len(os.Args) > 2 { n, _ := strconv.Atoi(os.Args[2]); runtime.GOMAXPROCS(n) }
	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("x", "x")
		w.Write([]byte("ok"))
	})
	http.ListenAndServe(port, nil)
}
