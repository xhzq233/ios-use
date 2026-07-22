# How To Release

This repository releases from Git tags. The release workflow builds the Swift CLI, builds both driver IPAs, packages release assets, and uploads them to the GitHub Release that matches the tag.

## 1. Bump Version

Update the CLI version constant in `swift-cli/Sources/IOSUseCLI/CLI/IOSUseCLI.swift` and refresh any hard-coded tests or docs that intentionally pin the public version.

The release tag must match the binary version exactly, for example:

- `IOSUseCLI.version = "1.2.0"`
- Git tag: `v1.2.0`

## 2. Build Release Assets Locally

Run the release build script with the intended tag:

```bash
IOS_USE_RELEASE_VERSION=v1.2.0 bash scripts/release_build.sh
```

This script:

1. Builds the Swift CLI.
2. Verifies `./ios-use --version` matches `IOS_USE_RELEASE_VERSION` when provided.
3. Builds the real-device and simulator driver IPAs.
4. Stages release assets under `release/`.
5. Stages the matching versioned changelog.
6. Writes `release/SHA256SUMS` for every staged content asset.

Expected assets:

- `release/ios-use-darwin-arm64`
- `release/driver.ipa`
- `release/driver-sim.ipa`
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
- `CHANGELOG-vX.Y.Z.md`
- `SHA256SUMS`

To watch it:

1. Open the GitHub Actions run for the `Build & Release` workflow.
2. Confirm `scripts/release_build.sh` passes its version check.
3. Confirm the upload step publishes all five assets.
4. Open the GitHub Release page for the tag and verify the assets are attached.

## 7. Release Checklist

- `IOSUseCLI.version` matches the release tag.
- `scripts/release_build.sh` succeeds with `IOS_USE_RELEASE_VERSION=vX.Y.Z`.
- `release/` contains all expected assets.
- `git diff --check` passes.
- The tag is pushed to origin.
- The GitHub Release has all five uploaded assets.
