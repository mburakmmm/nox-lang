# Releasing

How a version reaches users, and the gates in between.

## Version numbers

Semantic versioning (`MAJOR.MINOR.PATCH`, pre-releases like `2.0.0-rc.1`). The single source of truth is `.version` in `build.zig.zon`; the git tag is `v` plus that string. The policy for what each part means is in
[Versioning](../reference/versioning.md) and [Stability](../apis/stability.md). Bump with `scripts/bump_version.sh {patch|minor|major}` (patch by default, minor for genuine new features).

## The release gate

`scripts/release.sh` is the local gate; run it before tagging.

| Step | Check |
|---|---|
| 1 | the version in `build.zig.zon` is valid semver, `CHANGELOG.md` has a `## [version]` entry, the tag does not exist yet, the working tree is clean |
| 2 | `zig fmt --check` |
| 3 | `zig build` |
| 4 | `zig build test` — and no IR snapshot changed |
| 5 | `zig build backend-differential-corpus-test` — LLVM and QBE agree on the whole corpus |
| 6 | (with `--stress`) stress, both torture suites and the HTTP soak test |
| 7 | (with `--tag`) create `vX.Y.Z`, push `main` and the tag |

```sh
scripts/release.sh             # checks only (a dry run)
scripts/release.sh --tag       # checks, then tag and push
scripts/release.sh --tag --stress
```

## CI

On every push to `main`, `ci.yml` runs the full suite on Linux x86-64, Linux aarch64 and macOS arm64 (all required) and a Windows job (front-end tests plus end-to-end smoke tests of both back ends). Extra workflows run the opt-in stress
suites and the external-integration fixtures (the Aether and Nyx frameworks compiled against the new compiler).

## Publishing

Pushing a `v*` tag triggers `release.yml`:

1. **Gate job** — verifies that the tag, `build.zig.zon` and `CHANGELOG.md` agree, then **waits for the `ci.yml` run on the tagged commit and fails the release unless it succeeded**. A red commit is never published.
2. **Build jobs** — build `noxc`, `noxlsp`, `noxrt.o`, `noxrt-freestanding.o` and the standard library in `ReleaseFast` for macOS arm64, Linux x86-64, Linux arm64 and Windows x86-64 (with explicit `-Dcpu` baselines so the binaries run on
   older machines), bundle `qbe` where applicable, and upload archives plus SHA-256 files to the GitHub release.
3. Tags containing a `-` (such as `v2.0.0-rc.1`) are published as **pre-releases**, so `noxc upgrade` and the installers keep pointing at the latest stable release.

Because the workflow concurrency cancels a superseded CI run, a later push can cancel the CI run of an earlier tag and make that tag's release fail its gate; push one release at a time and wait for CI.

## Installers and upgrades

`install.sh` and `install.ps1` download the archive for the platform from the latest GitHub release. `noxc upgrade` replaces the running installation with the latest (or a requested) release after verifying the checksum.

## Documentation and website

The documentation in `docs/` is built into the website; the site and the noxpkg registry are deployed from `services/`. Docs are checked in CI-adjacent tooling (`scripts/check_docs.py`) so a release never ships examples that do not compile.
