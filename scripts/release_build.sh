#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RELEASE_DIR="$ROOT_DIR/release"
RELEASE_STARTED_AT="$(date +%s)"
ASSEMBLE_ONLY=false
case "${1:-}" in
  "") ;;
  --assemble-only) ASSEMBLE_ONLY=true; shift ;;
  *) echo "Usage: scripts/release_build.sh [--assemble-only]" >&2; exit 64 ;;
esac
[ "$#" -eq 0 ] || { echo "Unexpected release build arguments" >&2; exit 64; }

require_clean_source_tree() {
  local phase="$1"
  local dirty
  if ! git -C "$ROOT_DIR" rev-parse --verify HEAD >/dev/null 2>&1; then
    echo "[release-build] ERROR: release assets must be produced from a Git checkout" >&2
    exit 1
  fi
  dirty="$(git -C "$ROOT_DIR" status --porcelain=v1 --untracked-files=all)"
  if [[ -n "$dirty" ]]; then
    echo "[release-build] ERROR: source tree is dirty $phase; refusing release assets." >&2
    printf '%s\n' "$dirty" >&2
    exit 1
  fi
}

require_clean_source_tree "before the build"
if [ "$ASSEMBLE_ONLY" = false ]; then
  rm -rf "$RELEASE_DIR"
  mkdir -p "$RELEASE_DIR"
  bash "$ROOT_DIR/scripts/build_swift_cli.sh" --skip-runtime
  bash "$ROOT_DIR/scripts/build_driver.sh" --release
  bash "$ROOT_DIR/scripts/build_release_mac_resources.sh"
  cp "$ROOT_DIR/ios-use" "$RELEASE_DIR/ios-use-darwin-arm64"
  cp "$ROOT_DIR/driver/build/driver.ipa" "$RELEASE_DIR/driver.ipa"
  cp "$ROOT_DIR/driver/build/driver-sim.ipa" "$RELEASE_DIR/driver-sim.ipa"
fi
chmod +x "$RELEASE_DIR/ios-use-darwin-arm64"
STEP_STARTED_AT="$(date +%s)"
ACTUAL_VERSION="$("$RELEASE_DIR/ios-use-darwin-arm64" --version | tr -d '[:space:]')"
if [ -n "${IOS_USE_RELEASE_VERSION:-}" ]; then
  STEP_STARTED_AT="$(date +%s)"
  EXPECTED_VERSION="${IOS_USE_RELEASE_VERSION#v}"
  if [ "$ACTUAL_VERSION" != "$EXPECTED_VERSION" ]; then
    echo "[release-build] ERROR: binary version $ACTUAL_VERSION does not match release tag $IOS_USE_RELEASE_VERSION" >&2
    exit 1
  fi
  echo "[release-build] Version check passed: $ACTUAL_VERSION"
  STEP_ELAPSED=$(($(date +%s) - STEP_STARTED_AT))
  printf '[release-build] Version check completed in %dm%02ds\n' "$((STEP_ELAPSED / 60))" "$((STEP_ELAPSED % 60))"
fi

require_clean_source_tree "after the build"
CHANGELOG_SOURCE="$ROOT_DIR/release-notes/CHANGELOG-v$ACTUAL_VERSION.md"
if [ ! -s "$CHANGELOG_SOURCE" ]; then
  echo "[release-build] ERROR: missing or empty release changelog: $CHANGELOG_SOURCE" >&2
  exit 1
fi

for asset in \
  ios-use-darwin-arm64 \
  driver.ipa \
  driver-sim.ipa \
  ios-use-mac-resources.tar.gz; do
  if [ ! -s "$RELEASE_DIR/$asset" ]; then
    echo "[release-build] ERROR: missing or empty release asset: $asset" >&2
    exit 1
  fi
done

(
  cd "$RELEASE_DIR"
  shasum -a 256 \
    ios-use-darwin-arm64 \
    driver.ipa \
    driver-sim.ipa \
    ios-use-mac-resources.tar.gz > SHA256SUMS
)

EXPECTED_ASSETS="$(printf '%s\n' \
  SHA256SUMS \
  driver-sim.ipa \
  driver.ipa \
  ios-use-darwin-arm64 \
  ios-use-mac-resources.tar.gz)"
ACTUAL_ASSETS="$(
  cd "$RELEASE_DIR"
  printf '%s\n' * | LC_ALL=C sort
)"
if [[ "$ACTUAL_ASSETS" != "$EXPECTED_ASSETS" ]]; then
  echo "[release-build] ERROR: release directory is not the exact five-asset set" >&2
  printf '%s\n' "$ACTUAL_ASSETS" >&2
  exit 1
fi

STEP_ELAPSED=$(($(date +%s) - STEP_STARTED_AT))
printf '[release-build] Asset staging completed in %dm%02ds\n' "$((STEP_ELAPSED / 60))" "$((STEP_ELAPSED % 60))"
echo "[release-build] Assets ready under $RELEASE_DIR"
TOTAL_ELAPSED=$(($(date +%s) - RELEASE_STARTED_AT))
printf '[release-build] Total completed in %dm%02ds\n' "$((TOTAL_ELAPSED / 60))" "$((TOTAL_ELAPSED % 60))"
