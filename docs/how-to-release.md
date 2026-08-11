# How To Release

ios-use releases from Git tags. A release publishes exactly five assets: the
CLI, two driver IPAs, the Mac resource archive, and their checksum manifest.

## 1. Pin the version

Update `IOSUseCLI.version` in
`swift-cli/Sources/IOSUseCLI/CLI/Version.swift`, its intentionally pinned
tests, and `release-notes/CHANGELOG-vX.Y.Z.md`. The binary and tag must match:

```text
IOSUseCLI.version = "X.Y.Z"
tag = vX.Y.Z
```

## 2. Run the repository gate

Use Apple-silicon macOS with full Xcode and `xcodegen` installed:

```bash
bash scripts/ci_test.sh
git diff --check
```

The repository gate runs the Swift CLI and Driver unit suites, the pinned
PlayCover differential contracts, script syntax and install smoke checks, then
builds the Release CLI and Simulator Driver. The release build below owns fresh
Runtime, Frida Engine and real-device Driver production builds. Account-global
live tests remain explicit because they require an unlocked GUI session and a
disposable account.

## 3. Build release assets

Start from a clean Git checkout. The build refuses tracked or untracked changes
both before and after compiling:

```bash
IOS_USE_RELEASE_VERSION=vX.Y.Z bash scripts/release_build.sh
```

The build:

1. audits the pinned PlayCover, PlayTools, and `inject` sources, licenses, and
   recorded local patches;
2. forces fresh Runtime, CLI, and real-device/simulator driver builds;
3. fetches and validates the exact public Frida commits before building the
   resident GumJS Engine;
4. packages only `IOSUsePlayRuntime.framework` and
   `IOSUseFridaEngine.framework` in the Mac resource archive;
5. rejects local source/cache paths in the frameworks; and
6. writes `SHA256SUMS` for the four content assets and rejects any release
   directory that is not the exact five-file set.

Expected `release/` entries:

- `ios-use-darwin-arm64`
- `driver.ipa`
- `driver-sim.ipa`
- `ios-use-mac-resources.tar.gz`
- `SHA256SUMS`

The Engine's required third-party notices are embedded at
`IOSUseFridaEngine.framework/Resources/ThirdPartyNotices.txt`. Project and
vendored source/license material is carried by the exact GitHub tag source;
Frida source locations and commits are pinned in
`ThirdParty/Frida/PROVENANCE.md`. No duplicate source, license, provenance,
changelog, or build-manifest release assets are produced.

## 4. Validate the staged install

```bash
./ios-use --version
bash scripts/test_playcover_installed_layout.sh \
  --release-dir release \
  --verify-only
```

This verifies the exact asset set, every checksum, both framework signatures,
the embedded Frida notices, and an isolated-prefix install. It does not launch
an App or touch account-global Mac state.

For a local release candidate on a disposable, launch-capable Mac, run the live
installed-layout gate separately:

```bash
bash playcover-fixtures/build.sh
bash scripts/test_playcover_installed_layout.sh --release-dir release
```

The live form validates `start/status/stop` and requires the safety
acknowledgement documented by the script.

## 5. Commit, tag, and push

```bash
git add <release changes>
git commit -m "chore(release): prepare X.Y.Z"
git tag vX.Y.Z
git push origin main
git push origin vX.Y.Z
```

Pushing the tag triggers `.github/workflows/release.yml`. The workflow rebuilds
from the tag, reruns the isolated installed-layout validation, uses the tracked
release note as the GitHub Release body, and uploads only the five explicit
paths above.

Release assets are immutable in the normal workflow: a tag whose Release
already has assets is rejected, and duplicate names are never overwritten.
Normally fix a failed publication and use a new patch version.

## 6. Verify GitHub

After the workflow succeeds, confirm:

- the tag resolves to the intended commit;
- the Release body matches `release-notes/CHANGELOG-vX.Y.Z.md`;
- the Release has exactly the five expected assets;
- `SHA256SUMS` has exactly four entries and validates every content asset;
- the GitHub tag source contains the project/vendored licenses and source; and
- every public Frida repository resolves the commit recorded in
  `ThirdParty/Frida/PROVENANCE.md`.

## Checklist

- [ ] `IOSUseCLI.version` and `vX.Y.Z` match.
- [ ] `bash scripts/ci_test.sh` passes.
- [ ] The checkout is clean before the release build.
- [ ] `IOS_USE_RELEASE_VERSION=vX.Y.Z bash scripts/release_build.sh` passes.
- [ ] Isolated installed-layout verification passes for `release/`.
- [ ] `release/` contains exactly five files.
- [ ] `git diff --check` passes.
- [ ] Branch and tag are pushed.
- [ ] GitHub Actions succeeds and the Release has exactly five assets.
