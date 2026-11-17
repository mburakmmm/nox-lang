// 2.3 madde 5.1: Go TLS (HTTP/1.1 + h2 ALPN) ping sunucusu; Nox `serve_multicore_tls` ile karşılaştırma. Kullanım: go_tls_server PORT GOMAXPROCS CERT KEY
package main

import (
	"net/http"
	"os"
	"runtime"
	"strconv"
)

func main() {
	n, _ := strconv.Atoi(os.Args[2])
	runtime.GOMAXPROCS(n)
	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("x", "x")
		w.Write([]byte("ok"))
	})
	http.ListenAndServeTLS(":"+os.Args[1], os.Args[3], os.Args[4], nil)
}
