#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RELEASE_DIR="$ROOT_DIR/release"
RELEASE_STARTED_AT="$(date +%s)"

echo "[release-build] Building Swift CLI..."
STEP_STARTED_AT="$(date +%s)"
bash "$ROOT_DIR/scripts/build_swift_cli.sh"
STEP_ELAPSED=$(($(date +%s) - STEP_STARTED_AT))
printf '[release-build] Swift CLI completed in %dm%02ds\n' "$((STEP_ELAPSED / 60))" "$((STEP_ELAPSED % 60))"

if [ -n "${IOS_USE_RELEASE_VERSION:-}" ]; then
  STEP_STARTED_AT="$(date +%s)"
  EXPECTED_VERSION="${IOS_USE_RELEASE_VERSION#v}"
  ACTUAL_VERSION="$("$ROOT_DIR/ios-use" --version | tr -d '[:space:]')"
  if [ "$ACTUAL_VERSION" != "$EXPECTED_VERSION" ]; then
    echo "[release-build] ERROR: binary version $ACTUAL_VERSION does not match release tag $IOS_USE_RELEASE_VERSION" >&2
    exit 1
  fi
  echo "[release-build] Version check passed: $ACTUAL_VERSION"
  STEP_ELAPSED=$(($(date +%s) - STEP_STARTED_AT))
  printf '[release-build] Version check completed in %dm%02ds\n' "$((STEP_ELAPSED / 60))" "$((STEP_ELAPSED % 60))"
fi

echo "[release-build] Building driver IPAs..."
STEP_STARTED_AT="$(date +%s)"
bash "$ROOT_DIR/scripts/build_driver.sh" --release
STEP_ELAPSED=$(($(date +%s) - STEP_STARTED_AT))
printf '[release-build] Driver IPAs completed in %dm%02ds\n' "$((STEP_ELAPSED / 60))" "$((STEP_ELAPSED % 60))"

echo "[release-build] Preparing release assets..."
STEP_STARTED_AT="$(date +%s)"
rm -rf "$RELEASE_DIR"
mkdir -p "$RELEASE_DIR"
cp "$ROOT_DIR/ios-use" "$RELEASE_DIR/ios-use-darwin-arm64"
chmod +x "$RELEASE_DIR/ios-use-darwin-arm64"
cp "$ROOT_DIR/driver/build/driver.ipa" "$RELEASE_DIR/driver.ipa"
cp "$ROOT_DIR/driver/build/driver-sim.ipa" "$RELEASE_DIR/driver-sim.ipa"

for asset in ios-use-darwin-arm64 driver.ipa driver-sim.ipa; do
  if [ ! -s "$RELEASE_DIR/$asset" ]; then
    echo "[release-build] ERROR: missing or empty release asset: $asset" >&2
    exit 1
  fi
done

(cd "$RELEASE_DIR" && shasum -a 256 ios-use-darwin-arm64 driver.ipa driver-sim.ipa > SHA256SUMS)

STEP_ELAPSED=$(($(date +%s) - STEP_STARTED_AT))
printf '[release-build] Asset staging completed in %dm%02ds\n' "$((STEP_ELAPSED / 60))" "$((STEP_ELAPSED % 60))"
echo "[release-build] Assets ready under $RELEASE_DIR"
TOTAL_ELAPSED=$(($(date +%s) - RELEASE_STARTED_AT))
printf '[release-build] Total completed in %dm%02ds\n' "$((TOTAL_ELAPSED / 60))" "$((TOTAL_ELAPSED % 60))"
