#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RELEASE_DIR="$ROOT_DIR/release"

echo "[release-build] Building Swift CLI..."
bash "$ROOT_DIR/scripts/build_swift_cli.sh"

echo "[release-build] Building driver IPAs..."
bash "$ROOT_DIR/scripts/build_driver.sh"

echo "[release-build] Preparing release assets..."
rm -rf "$RELEASE_DIR"
mkdir -p "$RELEASE_DIR"
cp "$ROOT_DIR/ios-use" "$RELEASE_DIR/ios-use-darwin-arm64"
chmod +x "$RELEASE_DIR/ios-use-darwin-arm64"
cp "$ROOT_DIR/assets/driver.ipa" "$RELEASE_DIR/driver.ipa"
cp "$ROOT_DIR/assets/driver-sim.ipa" "$RELEASE_DIR/driver-sim.ipa"

(cd "$RELEASE_DIR" && shasum -a 256 ios-use-darwin-arm64 driver.ipa driver-sim.ipa > SHA256SUMS)

echo "[release-build] Assets ready under $RELEASE_DIR"
