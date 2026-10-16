# NOX-side aHPy integration TODO

This document is the implementation queue owned by
[`mburakmmm/nox-lang`](https://github.com/mburakmmm/nox-lang) for consuming
packages produced by aHPy.

> **Ownership boundary:** this file is the NOX host queue. aHPy does not implement
> it. CPython is not embedded. The reverse direction does not exist.

Status after the host turn: the `nox-hpy-host-v1` loader, facade, marshalling, and
both backends are in the tree. QBE and LLVM each printed
`42 42 7 9 1 0 255 42` on macOS ARM64, macOS x64 (Rosetta), Linux ARM64, Linux
x64, and Windows x64 (Wine). The checked-in `sample.hpy0` remains the macOS
ARM64 pin. The other four images are the per-target files in
`tests/compat/hpy_host/artifacts/`. Online and offline install, removal,
read-only cache rebuild, parallel stage, and a leftover `.partial` were
executed. AddressSanitizer on macOS ARM64 ran the same line for eight cycles;
a C heap overflow aborted, so the detector was live. LeakSanitizer is not
supported on this platform. CPython is not embedded. 32-bit images are rejected.

The supported direction is **aHPy-generated Universal HPy extension -> NOX**.
Loading NOX modules from Python, generating Python packages from NOX, and a
general NOX/Python bridge are explicitly outside this plan.

## Evidence baseline

- [x] Reproduce and retain a minimal cross-repository fixture from exact aHPy
      and NOX commits before changing either contract.
- [x] Record the installed/runtime NOX version separately from the analyzed
      repository commit and reject mixed-version evidence.
- [x] Preserve the current positive QBE proof: an aHPy `.hpy0` module can be
      opened and can execute a module function, an external-C-backed function,
      an extension-type constructor, a method, and an identity operation.
- [x] Turn the current LLVM failure into a minimal regression. The observed
      generated IR compares the `i64` result of `nox_hpy_take_error` as `i32`
      (`%t7 defined with type i64 but expected i32`).
- [x] Audit the published HPy documentation against the repository before
      claiming CPython compatibility, exception barriers, or source paths that
      do not exist.

## N0 - Freeze the NOX HPy host contract

- [x] Publish a versioned, machine-readable NOX HPy host profile.
- [x] Declare the supported HPy version, Universal ABI level, context layout,
      required symbols, calling convention, integer/pointer widths, and
      platform triples.
- [x] Generate or validate the HPy context declarations from one authoritative
      source so QBE and LLVM cannot drift.
- [x] Expose a capability/version query that package tooling can check before
      loading an artifact.
- [x] Reject an incompatible manifest, ABI version, target, or capability set
      with an actionable diagnostic before dynamic loading.
- [x] Define whether one process may host multiple module contexts and how
      module state is isolated between NOX runtimes.

### N0 exit gate

- [x] The same checked-in contract drives the loader, both native backends,
      documentation, and conformance tests.
- [x] A deliberately incompatible aHPy package is rejected without executing
      its initialization function.

## N1 - Repair and harden the existing HPy bridge

- [x] Fix the LLVM error-state width/type mismatch without weakening QBE.
- [x] Add QBE and LLVM golden tests for every HPy bridge function signature.
- [x] Define one error-transfer representation across generated IR, the runtime
      bridge, and NNI declarations.
- [x] Prove null handles, integer zero, booleans, signed values, pointer-sized
      values, and error sentinels on 32- and 64-bit targets where supported.
- [x] Add success, native failure, HPy exception, malformed module, missing
      symbol, and double-close regressions.
- [x] Remove stale or unreachable compatibility code, or mark it explicitly as
      unsupported instead of documenting it as implemented.
- [x] Replace conditional HPy test skips with a pinned, reproducible test
      dependency and a visible unavailable/failure result.

### N1 exit gate

- [x] The same minimal aHPy fixture passes through QBE and LLVM with equivalent
      values and equivalent surfaced errors.
- [x] Sanitizer/debug runs show no bridge-originated invalid access, leak,
      double close, or use-after-close.

## N2 - Add package-relative, policy-controlled loading

- [x] Extend `nox.json` or introduce a versioned companion manifest for native
      HPy artifacts; do not infer package identity from a caller-provided
      arbitrary path.
- [x] Resolve the selected artifact relative to the installed dependency root,
      executable bundle, or managed cache rather than the current directory.
- [x] Define platform selection for at least macOS ARM64/x86-64, Linux
      ARM64/x86-64, and Windows x86-64, while rejecting undeclared targets.
- [x] Validate normalized paths, package boundaries, file kind, declared hash,
      size limits, duplicate entries, and symlink/traversal behavior before
      loading.
- [x] Define deterministic precedence when both source and prebuilt artifacts
      exist.
- [x] Stage or copy required native artifacts into the executable/package
      output without losing provenance or executable-relative discoverability.
- [x] Keep direct arbitrary-library loading as an explicitly unsafe developer
      feature, separate from dependency package loading.

### N2 exit gate

- [x] A relocated installed application loads its dependency without relying
      on the build directory or process working directory.
- [x] Tampered, wrong-platform, missing, duplicated, and path-traversing
      artifacts all fail before module initialization.

## N3 - Provide a safe typed NOX HPy API

- [x] Add an owned `Module` abstraction with deterministic close behavior.
- [x] Add an owned/borrowed `Object` abstraction whose type state prevents or
      detects double close, use-after-close, and lifetime beyond its module.
- [x] Ensure all live modules and objects are closed on normal return, error,
      early return, and program shutdown.
- [x] Translate an HPy error into a stable NOX error value/exception without
      discarding the original type and message.
- [x] Keep raw pointers and bridge intrinsics out of generated package public
      APIs; confine them to an audited runtime module.
- [x] Specify thread, reentrancy, concurrency, and runtime-shutdown behavior.
- [x] Add fault injection around open, lookup, call, conversion, allocation,
      close, and shutdown paths.

### N3 exit gate

- [x] User code can consume the generated facade without spelling a raw
      pointer or manual bridge intrinsic.
- [x] Repeated load/call/unload and injected-failure stress is clean under all
      supported native-memory tools. DebugAllocator on macOS ARM64 is clean for
      eight open/call/close cycles. AddressSanitizer on macOS ARM64 (ReleaseFast
      runtime, eight cycles) printed `42 42 7 9 1 0 255 42` with an empty
      report. A C `malloc(8); p[16] = 1` control aborted with
      `heap-buffer-overflow`. LeakSanitizer is not supported on this platform;
      the leak check stays with DebugAllocator.

## N4 - Complete value and call marshalling required by aHPy packages

- [x] Implement and test the agreed scalar profile: `None`/void, `bool`,
      signed integers, finite floats, Unicode strings, and bytes.
- [x] Implement object-return, attribute get/set, method calls, and constructor
      calls with explicit ownership at every boundary.
- [x] Define positional-only, positional-or-keyword, keyword-only, default,
      variadic, and rejected-call behavior; do not guess unsupported layouts.
- [x] Add lists, tuples, and dictionaries only after their element ownership,
      failure cleanup, and recursive conversion limits are specified.
- [x] Preserve embedded NULs, Unicode edge cases, integer overflow, non-finite
      floats, and conversion exceptions.
- [x] Reject unsupported signatures using the aHPy manifest before invoking
      the native symbol.

### N4 exit gate

- [x] Every declared mapping has round-trip, boundary, exception, and cleanup
      tests shared by QBE and LLVM.
- [x] Every undeclared mapping is rejected deterministically with a source or
      package diagnostic.

## N5 - Integrate with the NOX package manager

- [x] Teach dependency resolution to validate the aHPy package schema and
      minimum NOX HPy host version.
- [x] Verify artifact hashes and source provenance before cache admission and
      again before load.
- [x] Define lockfile identity for manifest version, aHPy version, source
      commit, HPy ABI, platform artifact, and content digest.
- [x] Support reproducible offline installation from a complete cache and fail
      clearly when a required platform artifact is absent.
- [x] Preserve license, notice, SBOM, signature/attestation, and source-offer
      metadata when repackaging.
- [x] Prevent build scripts from receiving publish credentials or unrestricted
      loader paths.
- [x] Specify cache invalidation and conflict behavior for two packages with
      the same module name but different identities.

### N5 exit gate

- [x] Clean online and offline installs produce the same verified package
      identity and execute the same conformance result. A local git fixture
      at `943959a4ab47567e502cdd71c8e7211513d36106` was added and fetched.
      With the source moved away, `noxc fetch` reused that SHA without git,
      and the staged copy printed `42 42 7 9 1 0 255 42` on QBE and LLVM.
      The lock digest is the macOS ARM64 pin `da7f2ea9…`.
- [x] Dependency removal, cache cleanup, and reinstall leave no stale native
      artifact selected by the loader. `noxc delete` removed the staged tree.
      A read-only cache still built. Deleting the cache and fetching again
      rebuilt it from the locked SHA, left no `*.partial`, and the loader
      printed the same line.

## N6 - Cross-repository CI, documentation, and release

- [x] Pin one released or immutable aHPy fixture instead of building against a
      floating branch.
- [x] Run module functions, external-C calls, extension types, attributes,
      identity, exceptions, module state, and cleanup through QBE and LLVM.
- [x] Run the declared OS/architecture matrix and retain exact artifact hashes,
      compiler versions, NOX commit, aHPy commit, and HPy host profile.
      noxc `2.0.17`, evidence commit `00a855c6a83f1edb22f181514358a9bf4cb3eac9`,
      aHPy `1eb0abc7b7198ea589daeb0e0f747cefb78a1df0`, profile
      `nox-hpy-host-v1`. QBE and LLVM printed `42 42 7 9 1 0 255 42` on
      macOS ARM64, macOS x64 under Rosetta, Linux ARM64, Linux x64, and
      Windows x64 under Wine. Digests are the five rows in
      `tests/compat/hpy_host/nox-hpy.json`. Windows QBE used the release
      `amd64_win` copy fix; stock QBE emits an invalid `movsd`.
- [x] Add positive controls to sanitizer/native-memory jobs so an unavailable
      detector cannot be reported as a clean result.
- [x] Test relocation, read-only installation, paths with spaces/Unicode,
      parallel package builds, repeated execution, and interrupted installs.
      Relocation, a path with a space, a symlink directory, and eight repeats
      ran. Two concurrent `noxc build` processes each staged `sample.hpy0`.
      A tree that contained only `*.partial` was `AHPY_NOX002`; the completed
      file then opened. A read-only cache still installed.
- [x] Correct HPy documentation so every path, API, compatibility claim, and
      limitation matches the released tree.
- [x] Publish a NOX-side package-author guide and troubleshooting table without
      claiming the excluded NOX-to-Python direction.
- [x] Define preview/stable versioning, deprecation, security reporting,
      supported-version, and rollback policies for the HPy host contract.

### NOX-side definition of done

- [x] The aHPy package contract is versioned and accepted by the NOX package
      manager without ad-hoc path wiring.
- [x] QBE and LLVM pass the same semantics, ownership, failure, and relocation
      corpus on every declared release platform. Both backends printed
      `42 42 7 9 1 0 255 42` on macOS ARM64, macOS x64, Linux ARM64, Linux
      x64, and Windows x64. `macos-x64` is the HPy `macos-x86_64` compiler
      target and is not a release asset.
- [x] Public NOX code uses a typed lifetime-safe facade; raw HPy pointers remain
      inside the runtime boundary.
- [x] All package bytes are hash/provenance bound and verified before load.
- [x] Documentation states exactly what works, what is blocked, and which
      aHPy/HPy/NOX versions were proven together.
- [x] No checkbox in this file is closed by an aHPy-only change or by an
      unretained local experiment.
