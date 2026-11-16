# QBE 1.3 (vendored build input)

`qbe-1.3.tar.xz` is the unmodified upstream release archive (MIT, (c) Quentin Carbonneaux). It is NOT linked into Nox: CI, the release workflow and the service images build the `qbe` back end from it
(see `scripts/build_qbe.sh`, which also applies the `amd64_win` ABI text patch and checks the archive SHA-256).

- SHA-256: `d587905d620dc5e1d2bfa7c2cc642b9b837aa89a3188c6e37b53d756cf66e320` (the same value pinned in `scripts/build_qbe.sh`)
- Upstream URL: https://c9x.me/compile/release/qbe-1.3.tar.xz
- Why it is vendored: on 2026-11-16 `c9x.me` was unreachable (connection timeouts from GitHub Actions runners and from a developer machine) and every CI job that downloads QBE failed. The archive was recovered from the Internet Archive and verified against the pinned checksum before it was committed.
- To update QBE: replace the archive, update the checksum here, in `scripts/build_qbe.sh` and in `scripts/gen_sbom.py`'s source (it reads `scripts/build_qbe.sh`), and re-check that the `amd64_win` patch needle still exists.
