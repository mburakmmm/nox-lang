#!/usr/bin/env python3
"""Mobil ağ matrisi (TODO 3.8) için senaryo sunucuları. Mac'te çalışır; iOS simülatörü Mac ağını paylaşır, Android emülatörü `adb reverse` ile bağlanır.

Her sunucu ayrı bir ephemeral porta bağlanır; portlar JSON olarak `--ports-file`a yazılır, süreç sonlandırılana kadar çalışır.
  ok4      127.0.0.1  200 "hello4"
  ok6      ::1        200 "hello6"           (IPv6 literal'i)
  silent   127.0.0.1  bağlantıyı kabul eder, hiçbir şey yazmaz (boşta zaman aşımı)
  trunc    127.0.0.1  Content-Length: 1000 deyip 10 bayt yazar ve kapatır (kesik gövde)
  reset    127.0.0.1  kabul eder ve RST ile kapatır (bağlantı sıfırlama)
  tls      127.0.0.1  kendinden imzalı sertifikalı HTTPS (reddedilmeli)
  drip     0.0.0.0    5 bayt/sn, 6 sn, Content-Length: 30 (askıya alma / ağ değişimi senaryosu)
  closed   (yok)      kapalı bir port numarası (bağlantı reddedildi)
"""
import argparse
import json
import os
import socket
import ssl
import struct
import subprocess
import tempfile
import threading
import time


def listener(host, family=socket.AF_INET):
    s = socket.socket(family, socket.SOCK_STREAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind((host, 0))
    s.listen(64)
    return s, s.getsockname()[1]


def read_request(conn):
    conn.settimeout(10)
    data = b""
    while b"\r\n\r\n" not in data:
        chunk = conn.recv(4096)
        if not chunk:
            break
        data += chunk
    return data


def serve(sock, handler):
    def loop():
        while True:
            try:
                conn, _ = sock.accept()
            except OSError:
                return
            threading.Thread(target=handler, args=(conn,), daemon=True).start()
    threading.Thread(target=loop, daemon=True).start()


def ok_handler(body):
    def h(conn):
        try:
            read_request(conn)
            conn.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s" % (len(body), body))
        finally:
            conn.close()
    return h


def silent(conn):
    time.sleep(120)
    conn.close()


def trunc(conn):
    try:
        read_request(conn)
        conn.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 1000\r\nConnection: close\r\n\r\n0123456789")
    finally:
        conn.close()


def reset(conn):
    conn.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
    conn.close()


def drip(conn):
    try:
        read_request(conn)
        conn.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 30\r\nConnection: close\r\n\r\n")
        for _ in range(6):
            conn.sendall(b"abcde")
            time.sleep(1)
    except OSError:
        pass
    finally:
        conn.close()


def make_cert(d):
    key, crt = os.path.join(d, "key.pem"), os.path.join(d, "crt.pem")
    base = ["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", key, "-out", crt, "-days", "2", "-subj", "/CN=127.0.0.1"]
    # LibreSSL'in eski sürümleri `-addext`i bilmez; SAN'sız sertifika da aynı amaca (reddedilmeli) hizmet eder.
    if subprocess.run(base + ["-addext", "subjectAltName=IP:127.0.0.1"], capture_output=True).returncode != 0:
        subprocess.run(base, check=True, capture_output=True)
    return crt, key


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ports-file", required=True)
    args = ap.parse_args()
    ports = {}
    d = tempfile.mkdtemp(prefix="nox-net-")

    s, ports["ok4"] = listener("127.0.0.1")
    serve(s, ok_handler(b"hello4"))
    try:
        s, ports["ok6"] = listener("::1", socket.AF_INET6)
        serve(s, ok_handler(b"hello6"))
    except OSError:
        ports["ok6"] = 0  # IPv6 loopback yok
    s, ports["silent"] = listener("127.0.0.1")
    serve(s, silent)
    s, ports["trunc"] = listener("127.0.0.1")
    serve(s, trunc)
    s, ports["reset"] = listener("127.0.0.1")
    serve(s, reset)
    s, ports["drip"] = listener("0.0.0.0")
    serve(s, drip)

    crt, key = make_cert(d)
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(crt, key)
    s, ports["tls"] = listener("127.0.0.1")

    def tls_handler(conn):
        try:
            c = ctx.wrap_socket(conn, server_side=True)
            read_request(c)
            c.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 3\r\nConnection: close\r\n\r\nbad")
            c.close()
        except (ssl.SSLError, OSError):
            conn.close()
    serve(s, tls_handler)

    tmp, ports["closed"] = listener("127.0.0.1")
    tmp.close()
    with open(args.ports_file, "w") as f:
        json.dump(ports, f)
    while True:
        time.sleep(3600)


if __name__ == "__main__":
    main()
