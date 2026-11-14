# PCRE2 (vendored)

- Upstream: https://github.com/PCRE2Project/pcre2, release **pcre2-10.49** (`pcre2-10.49.tar.gz`)
- Archive SHA-256: `929f0b20e62879252a15886b06c89f1edef61a363cbd5826fb041080a5e557ae`
- License: BSD-3-Clause with the PCRE2 exemption (`LICENCE.md`); sljit (JIT back end): BSD-2-Clause (`deps/sljit/LICENSE`)
- Used by: `nox.pcre2` (glue `runtime/c_glue/pcre2_glue.c`, archive `noxclibs-<target>.a`). 8-bit library with Unicode and JIT.
- Included: the library sources `src/pcre2_*.c` (no `pcre2test`, `pcre2grep`, POSIX wrapper, `dftables`, fuzz or JIT-test sources), their headers, `src/pcre2_chartables.c` (= `pcre2_chartables.c.dist`), `src/config.h` (= `config.h.generic`), `src/pcre2.h` (= `pcre2.h.generic`) and `deps/sljit/sljit_src`. Unmodified apart from those two renamed generic files; build flags are in `build.zig` (`-DSUPPORT_UNICODE -DSUPPORT_JIT -DPCRE2_CODE_UNIT_WIDTH=8 -DPCRE2_STATIC -DHAVE_CONFIG_H`).
