# How To Release

This repository releases from Git tags. The release workflow builds the Swift CLI, builds both driver IPAs, packages release assets, and uploads them to the GitHub Release that matches the tag.

## 1. Bump Version

Update the CLI version constant in `swift-cli/Sources/IOSUseCLI/CLI/IOSUseCLI.swift` and refresh any hard-coded tests or docs that intentionally pin the public version.

The release tag must match the binary version exactly, for example:

- `IOSUseCLI.version = "1.2.0"`
- Git tag: `v1.2.0`

## 2. Build Release Assets Locally

Use Apple-silicon macOS with full Xcode and `xcodegen` installed. Start from a
clean Git tree: the script fails before building when tracked or untracked
source differs from `HEAD`, and checks again after the build.

Run the release build script with the intended tag:

```bash
IOS_USE_RELEASE_VERSION=v1.2.0 bash scripts/release_build.sh
```

Every release builds and verifies the pinned Frida Catalyst Engine together
with the base Runtime. The installer keeps both as read-only resources; only
`start --mac --frida` copies the Engine into a prepared App.
The Engine build normalizes compiler-visible source paths so local source,
cache, and temporary build-root paths are not embedded in the binary. Frida's
generated source maps may still vary between otherwise equivalent builds, so
the release records the framework's actual digest and size in its build
manifest and protects the complete resources archive with `SHA256SUMS`; it
does not duplicate one toolchain-specific framework hash in source code.

This script:

1. Refuses a dirty source tree and audits pinned PlayCover, PlayTools, `inject`,
   and Yams remotes, commits, licenses, expected vendored files, local patch
   sets, and SwiftPM resolutions.
2. Hashes the complete tracked Runtime build-input set, then forces a fresh
   Runtime build from a new derived-data directory.
3. Builds the Swift CLI and verifies `./ios-use --version` matches
   `IOS_USE_RELEASE_VERSION` when provided.
4. Builds the real-device and simulator driver IPAs.
5. Refuses any source-input change during the build and stages the Runtime and
   pinned Engine as read-only source resources under `release/`; preparation
   may sign only a managed copy.
6. Builds corresponding source from the exact current `HEAD`, adds the complete
   pinned Yams Git tree, and proves its Runtime inputs have the same digest as
   the fresh binary build.
7. Stages the versioned build digest manifest, licenses, upstream provenance,
   and changelog.
8. Verifies every source/archive file set and writes `release/SHA256SUMS` for
   every content asset.

Expected assets:

- `release/ios-use-darwin-arm64`
- `release/driver.ipa`
- `release/driver-sim.ipa`
- `release/ios-use-mac-resources.tar.gz`
- `release/ios-use-v1.2.0-corresponding-source.tar.gz`
- `release/LICENSE`, `release/*-LICENSE-*` (including Yams MIT), and
  `release/THIRD-PARTY-LICENSES.md`
- `release/MAC-BACKEND-BUILD-MANIFEST-v1.2.0.txt`
- `release/MAC-BACKEND-PROVENANCE-v1.2.0.md`
- `release/CHANGELOG-v1.2.0.md`
- `release/SHA256SUMS`

## 3. Sanity Check

Verify the staged binary and assets before publishing:

```bash
./ios-use --version
ls -lh release/
git diff --check
```

`./ios-use --version` must print the same version as the tag you will publish.
The tag workflow builds the fixture and runs the exact files under `release/`
through checksum/build-manifest/source-manifest validation, `install.sh`, and
installed `start/status/stop` before any upload. The manually dispatched
non-live integration gate also exercises the same installed path with freshly
built local assets.

## 4. Commit And Tag

Commit the version bump, then create the release tag:

```bash
git add README.md release-notes/CHANGELOG-v1.2.0.md swift-cli/Sources/IOSUseCLI/CLI/IOSUseCLI.swift
git commit -m "chore(release): bump version to 1.2.0"
git tag v1.2.0
```

Use the current version number in both the commit message and tag name.

## 5. Push

Push the branch and tag:

```bash
git push origin main
git push origin v1.2.0
```

Pushing the tag triggers `.github/workflows/release.yml`.

Release assets are immutable through the workflow: it refuses to start when the
tag's Release already contains any asset. The upload action is additionally
configured to skip, rather than overwrite, an unexpected duplicate filename. Do not
retry a partially uploaded tag because a second build could produce checksums for
different bytes. Fix the issue and publish a new patch version instead.

## 6. Watch The GitHub Release

The release workflow runs on tag pushes that match `v*` and uploads:

- `ios-use-darwin-arm64`
- `driver.ipa`
- `driver-sim.ipa`
- `ios-use-mac-resources.tar.gz`
- `ios-use-vX.Y.Z-corresponding-source.tar.gz`
- license, upstream provenance, and versioned Runtime/source digest assets
- `CHANGELOG-vX.Y.Z.md`
- `SHA256SUMS`

To watch it:

1. Open the GitHub Actions run for the `Build & Release` workflow.
2. Confirm `scripts/release_build.sh` passes its version check.
3. Confirm the exact-release installed-layout step passes before upload.
4. Open the GitHub Release page for the tag and verify the assets are attached.

## 7. Release Checklist

- `IOSUseCLI.version` matches the release tag.
- The checkout is clean before and after release builds.
- `xcodegen` and full Xcode are present on Apple Silicon.
- `scripts/release_build.sh` succeeds with `IOS_USE_RELEASE_VERSION=vX.Y.Z`.
- `scripts/test_playcover_installed_layout.sh --release-dir release` succeeds
  for those exact assets.
- `release/` contains all expected assets.
- `git diff --check` passes.
- The tag is pushed to origin.
- The GitHub Release has the Mac backend resources archive, corresponding source, license,
  provenance, build manifest, changelog, and checksums in addition to the CLI
  and driver IPAs.

The non-live integration and core PlayCover live gates are explicit
`workflow_dispatch` entries because they mutate account-global state on the
provisioned Apple-silicon runner. The release workflow uses that same runner for
its installed-layout gate. That host must already have the stable signer
initialized and an unlocked, launch-capable GUI session. A release still
requires the core gate to pass for the exact release commit. The jobs need no
operator App, private scenario/evidence directory, or external-App
attestation; CI uploads its runner-temporary `run.log`. The two-display fixture
and generic external-App workflows remain optional additive diagnostics. A
queued or unavailable provisioned runner is an infrastructure gap, never a
passing live result.
