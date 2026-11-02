#!/usr/bin/env python3
"""`scripts/http_fiber_load.sh` için üst-akım sunucu: her isteğe 0,5 sn sonra `ok` döner (eşzamanlı isteklerin hepsi aynı anda açık kalsın diye). İlk satıra portu yazar, 120 sn sonra çıkar."""
import asyncio
async def handle(r, w):
    try:
        await r.readuntil(b"\r\n\r\n")
        await asyncio.sleep(0.5)
        w.write(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok")
        await w.drain()
    except Exception:
        pass
    finally:
        w.close()
async def main():
    srv = await asyncio.start_server(handle, "127.0.0.1", 0, backlog=8192)
    print(srv.sockets[0].getsockname()[1], flush=True)
    await asyncio.sleep(120)
asyncio.run(main())
