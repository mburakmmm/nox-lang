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

On every push to `main`, `ci.yml` runs the full suite on Linux x86-64, Linux aarch64 and macOS arm64 (all required) and a Windows job (the Debug `zig build test` corpus plus end-to-end smoke tests of both back ends). Extra workflows run the opt-in stress
suites and the external-integration fixtures (the Aether and Nyx frameworks compiled against the new compiler).

## Publishing

Pushing a `v*` tag triggers `release.yml`:

1. **Gate job** — verifies that the tag, `build.zig.zon` and `CHANGELOG.md` agree, then **waits for the `ci.yml` run on the tagged commit and fails the release unless it succeeded**. A red commit is never published.
2. **Build jobs** — build `noxc`, `noxlsp`, `noxrt.o`, `noxrt-freestanding.o` and the standard library in `ReleaseFast` for macOS arm64, Linux x86-64, Linux arm64 and Windows x86-64 (with explicit `-Dcpu` baselines so the binaries run on
   older machines), bundle `qbe` where applicable, and upload archives plus SHA-256 files to the **draft** GitHub release (opened by the `create-release` job).
   The Windows job also builds the **installer** (`packaging/windows/nox.iss`, Inno Setup) and runs `packaging/windows/test-installer.ps1` on it — silent install, reinstall (no duplicate `PATH` entry), uninstall, and a check
   that the user's `PATH` is restored byte for byte — before uploading `nox-lang-<tag>-windows-x64-setup.exe` and its SHA-256. A failing installer test stops the release. To iterate on the installer without cutting a release, push to a branch
   that changes `packaging/windows/**` (or run *Windows installer* manually): it builds the installer from an existing release's archive and runs the same test.
   **Publishing is atomic.** The release stays a draft, invisible to `noxc upgrade`, the installers and the website, until every core archive (macOS arm64, Linux x86-64, Linux arm64, Windows zip and installer) is uploaded; only then the
   `publish` job flips it to public and marks it *Latest*. If any build job fails the release stays a draft, so a half-uploaded version is never visible — fix the cause and re-run the failed jobs. (Before v2.0.173 each job published the
   release as soon as its own archive landed, and `noxc upgrade` could see a "latest" release whose archive for your platform did not exist yet and fail with HTTP 404.) The Homebrew, AUR, AppImage, Snap and site-image jobs run after `publish`.
   **Signing and SBOM.** Each build job signs its archives with `actions/attest-build-provenance` (keyless, GitHub/Sigstore) before uploading them; the `publish` job generates `nox-lang-<tag>-sbom.spdx.json` with `scripts/gen_sbom.py`, attaches it to the draft and signs it. `gen_sbom.py` reads the SQLite, QBE and Zig versions from the repository and fails if one cannot be read, and CI runs `gen_sbom.py --check` on every change. The attest steps are `continue-on-error` for now, so an infrastructure hiccup cannot block a release; after the first releases show them green they should become required. Users verify with `gh attestation verify` ([Install](../install/index.md#verify-where-an-archive-came-from)).
3. Tags containing a `-` (such as `v2.0.0-rc.1`) are published as **pre-releases**, so `noxc upgrade` and the installers keep pointing at the latest stable release.
4. **Homebrew tap job** — for stable tags only, after the build jobs, it generates `Formula/noxc.rb` from the release's `.sha256` files (`scripts/update_homebrew_formula.py`, template `packaging/homebrew/noxc.rb.in`) and pushes it to
   [`mburakmmm/homebrew-nox`](https://github.com/mburakmmm/homebrew-nox). It needs a repository secret `HOMEBREW_TAP_TOKEN` (a fine-grained personal access token with *Contents: Read and write* on that one repository);
   without it the job only warns and the release is unaffected. The tap's own CI then audits, installs and tests the formula on macOS arm64, Linux x86-64 and Linux arm64.
5. **AUR job** — for stable tags only, it builds the `noxc-bin` package from the release in a clean Arch Linux container (`packaging/aur/test-in-arch.sh`: `makepkg`, `.SRCINFO` identical to `makepkg --printsrcinfo`, install, run, upgrade guard,
   remove), then pushes `PKGBUILD` and `.SRCINFO` (`scripts/update_aur_package.py`, template `packaging/aur/PKGBUILD.in`) to `ssh://aur@aur.archlinux.org/noxc-bin.git`. The push needs a repository secret `AUR_SSH_PRIVATE_KEY` (the private
   half of an SSH key registered in your AUR account); without it only the container test runs. To iterate without a release, push to a branch that changes `packaging/aur/**` (or run *AUR package* manually).
6. **AppImage jobs** — x86-64 and aarch64, each on its own runner: `packaging/appimage/build-appimage.sh` assembles an AppDir from the release archive (checksum verified) and runs `appimagetool`; `test-appimage.sh` runs the result (`version`, `run`, the QBE
   back end, the `noxlsp` dispatch, the upgrade guard) before `noxc-<version>-<arch>.AppImage` and its SHA-256 are uploaded to the release. No account or secret is involved.
7. **Snap jobs** — stable tags only, amd64 and arm64: `scripts/update_snap_package.py` writes `snapcraft.yaml` (classic confinement, built from the release archive with `patchelf` so the binaries use the core24 libraries), `snapcraft pack --destructive-mode`
   builds it and `packaging/snap/test-snap.sh` installs it with `--classic`, runs it and removes it; the `.snap` is attached to the release. If the repository secret `SNAPCRAFT_STORE_CREDENTIALS` exists
   (`snapcraft export-login --snaps noxc --acls package_access,package_push,package_release -`) the job also uploads to the Snap Store's `stable` channel; this needs the name registered (`snapcraft register noxc`) and
   [classic confinement approved](https://forum.snapcraft.io/c/store-requests/19) by the Snap Store reviewers first. The upload step never fails the release.
   To iterate on AppImage, Snap or AUR packaging without a release, push to a branch that changes `packaging/<format>/**` (or run the matching workflow manually): each builds from the newest release that has all the needed assets and runs the same tests.

Because the workflow concurrency cancels a superseded CI run, a later push can cancel the CI run of an earlier tag and make that tag's release fail its gate; push one release at a time and wait for CI.

## Installers and upgrades

`install.sh` and `install.ps1` download the archive for the platform from the latest GitHub release. `noxc upgrade` replaces the running installation with the latest (or a requested) release after verifying the checksum.

## Documentation and website

The documentation in `docs/` is built into the website; the site and the noxpkg registry are deployed from `services/`. Docs are checked in CI-adjacent tooling (`scripts/check_docs.py`) so a release never ships examples that do not compile.

A stable release also publishes the website image to GHCR (the `site-image` job), and the production machine picks it up on its own; see [Deploying](deployment.md#automatic-site-updates).
