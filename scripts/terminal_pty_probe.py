#!/usr/bin/env python3
"""nox.terminal'i GERÇEK bir pty'de sınar (Rune): boyut, iç içe ham mod, girdi baytları, ham çıktı.

Kullanım: terminal_pty_probe.py <noxc> <tests/golden/terminal_pty_probe.nox>. Çıkış 0 = başarılı, 77 = pty yok (atlandı).
"""
import os
import select
import struct
import subprocess
import sys
import tempfile
import time

try:
    import fcntl
    import pty
    import termios
except ImportError:
    sys.exit(77)

noxc, src = sys.argv[1], sys.argv[2]
with tempfile.TemporaryDirectory() as tmp:
    binary = os.path.join(tmp, "probe")
    r = subprocess.run([noxc, "build", "-o", binary, src], capture_output=True, text=True)
    if r.returncode != 0:
        print("derleme başarısız:", r.stderr)
        sys.exit(1)
    pid, fd = pty.fork()
    if pid == 0:
        # Pencere boyutu `exec`ten ÖNCE çocuğun kendi tty'sinde (stdin = slave) ayarlanır: ebeveynde fork'tan sonra ayarlamak yavaş koşucuda yarışır
        # (çocuk boyutu ayarlanmadan önce sorgulayıp varsayılan 80x24'ü görebilir).
        fcntl.ioctl(0, termios.TIOCSWINSZ, struct.pack("HHHH", 30, 100, 0, 0))
        os.execv(binary, [binary])
    out = b""
    sent = False
    end = time.time() + 20
    while time.time() < end:
        ready, _, _ = select.select([fd], [], [], 0.2)
        if ready:
            try:
                data = os.read(fd, 4096)
            except OSError:
                break
            if not data:
                break
            out += data
            # İki `enable_raw_mode` sonrası `is_raw_mode` (True) basıldıktan sonra girdiyi gönder (ham modda echo yok).
            if out.count(b"True") >= 3 and not sent:
                time.sleep(0.2)
                os.write(fd, b"a\x1b[A")
                sent = True
    _, status = os.waitpid(pid, 0)
    text = out.decode(errors="replace")
    expected = "True True\r\n100 30\r\nTrue\nTrue\nFalse\r\n4\r\n[a\x1b[A]\r\n"
    if text != expected or not os.WIFEXITED(status) or os.WEXITSTATUS(status) != 0:
        print("beklenmeyen çıktı:", repr(text), "çıkış:", status)
        sys.exit(1)
print("ok")
