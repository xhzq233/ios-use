# How To Release

ios-use releases from Git tags. A release publishes six assets: two host
CLIs, two driver IPAs, the Mac resource archive, and their checksum manifest.

## 1. Pin the version

Update `IOSUseCLI.version` in
`swift-cli/Sources/IOSUseCLI/CLI/Version.swift`, the README install example,
and `release-notes/CHANGELOG-vX.Y.Z.md`. The release build verifies that the
binary and tag match:

```text
IOSUseCLI.version = "X.Y.Z"
tag = vX.Y.Z
```

For a PR pre-release, use a full version such as `2.1.0-alpha.1` and tag
`v2.1.0-alpha.1` on the PR commit. Push that branch and tag without merging it
into main. Tags containing a hyphen publish as GitHub pre-releases and do not
replace the stable latest release. Use the same full version in the changelog
filename and explicit installer command. Use the tag in the installer URL for
PR pre-releases so platform support comes from that release, even while main
still contains an older installer.

Driver IPAs retain the full version in `IOSUseDriverVersion`. Their Apple
bundle version fields use the numeric release version (for example `2.1.0`);
`config` checks the full identity and still reads older IPAs without that key.

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

Expected local Mac `release/` entries:

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

Pushing the tag triggers `.github/workflows/release.yml`. Linux CLI, Mac CLI,
device Driver, Simulator Driver, and Mac resources build in five independent
jobs. Each Driver has its own checkout and build cache, including both DerivedData
and the products written outside it by `CONFIGURATION_BUILD_DIR`. The final
job downloads those artifacts, assembles the Mac package without recompiling,
runs the isolated installed-layout validation, then adds the Linux checksum
and publishes all six assets with the tracked release note. Linux uses Swift
6.2.4 on Ubuntu 22.04 with the Swift runtime statically linked.

To measure the complete build without publishing, dispatch the workflow on
the candidate branch with `publish=false` and the version in that branch:

```bash
gh workflow run release.yml --ref <branch> -f tag=vX.Y.Z -F publish=false
```

This uses the selected branch commit, retains the verified `release-assets`
Actions artifact, and leaves the existing tag and Release untouched. A normal
publication always checks out the tag. Independent versions can build at the
same time; publication attempts for the same tag remain serialized.

For separate local component builds, `build_swift_cli.sh --skip-runtime` skips
the companion Runtime, `build_driver.sh --release --device-only` or
`--simulator-only` selects one IPA, and `build_release_mac_resources.sh` builds
the resource archive. Driver variants must use separate checkouts if run
concurrently. `release_build.sh --assemble-only` stamps the checksum manifest
for the four Mac artifacts already in `release/`; it does not compile them.

Release assets are immutable in the normal workflow: a tag whose Release
already has assets is rejected, and duplicate names are never overwritten.
Normally fix a failed publication and use a new patch version.

## 6. Verify GitHub

After the workflow succeeds, confirm:

- the tag resolves to the intended commit;
- the Release body matches `release-notes/CHANGELOG-vX.Y.Z.md`;
- the Release has exactly the six expected assets;
- `SHA256SUMS` has exactly five entries and validates every content asset;
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
- [ ] GitHub Actions succeeds and the Release has exactly six assets.
