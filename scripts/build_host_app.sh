#!/bin/bash
set -euo pipefail

# =============================================================================
# Build XCUIDriverRunner and package as IPA
#
# Usage:
#   ./scripts/build_host_app.sh        # Release build (fastest, no dSYM)
#   ./scripts/build_host_app.sh --debug # Debug build with dSYM for troubleshooting
# =============================================================================

DEBUG_MODE=false
for arg in "$@"; do
  if [ "$arg" = "--debug" ]; then
    DEBUG_MODE=true
  fi
done

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_DIR="$ROOT_DIR/driver"

BUILD_DIR="$PROJECT_DIR/build"
DERIVED_DATA="$BUILD_DIR/DerivedData"
APP_PATH="$BUILD_DIR/XCUIDriverRunner-Runner.app"

# Release artifacts go to assets/ (tracked by git).
# Debug artifacts go to build/ (not tracked) to avoid accidental commits.
if [ "$DEBUG_MODE" = true ]; then
  CONFIGURATION="Debug"
  DEBUG_INFO_FORMAT="dwarf-with-dsym"
  IPA_OUTPUT="$ROOT_DIR/assets/driver.ipa"
  SIM_IPA_OUTPUT="$ROOT_DIR/assets/driver-sim.ipa"
  echo "[build] DEBUG mode: building with Debug configuration + dSYM"
else
  CONFIGURATION="Release"
  DEBUG_INFO_FORMAT="dwarf"
  IPA_OUTPUT="$ROOT_DIR/assets/driver.ipa"
  SIM_IPA_OUTPUT="$ROOT_DIR/assets/driver-sim.ipa"
  echo "[build] RELEASE mode: building with Release configuration (no dSYM)"
fi

# Common xcodebuild flags.
XCODE_COMMON=(
  -project "$PROJECT_DIR/XCUIDriver.xcodeproj"
  -scheme XCUIDriverRunner
  -configuration "$CONFIGURATION"
  CONFIGURATION_BUILD_DIR="$BUILD_DIR"
  -derivedDataPath "$DERIVED_DATA"
  DEBUG_INFORMATION_FORMAT="$DEBUG_INFO_FORMAT"
  CODE_SIGNING_ALLOWED=NO
)

# Run unit tests first (logic tests on a booted Simulator, or skip if none)
BOOTED_UDID=$(xcrun simctl list devices booted 2>/dev/null | grep -o -E '[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}' | head -1)
BOOTED_OS=$(xcrun simctl list devices booted 2>/dev/null | grep -o -E '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1)
if [ -n "$BOOTED_UDID" ] && [ -n "$BOOTED_OS" ]; then
  echo "[build] Running Swift unit tests (Simulator $BOOTED_UDID OS=$BOOTED_OS)..."
  TEST_LOG=$(mktemp)
  set +e
  xcodebuild test \
    -project "$PROJECT_DIR/XCUIDriver.xcodeproj" \
    -scheme XCUIDriverUnitTests \
    -destination "platform=iOS Simulator,id=$BOOTED_UDID,OS=$BOOTED_OS" \
    CODE_SIGNING_ALLOWED=NO \
    > "$TEST_LOG" 2>&1
  TEST_EXIT=$?
  set -e
  if [ $TEST_EXIT -ne 0 ]; then
    echo "[build] Unit tests/build failed. Full log:"
    cat "$TEST_LOG"
    rm -f "$TEST_LOG"
    exit 1
  fi
  grep -E "(Test Suite|Executed|passed|failed|TEST)" "$TEST_LOG" || true
  rm -f "$TEST_LOG"
  echo ""
else
  echo "[build] No booted Simulator, skipping Swift unit tests"
fi

# Helper: package a .app into an IPA.
package_ipa() {
  local src_app="$1"
  local dst_ipa="$2"
  local staging
  staging="$(mktemp -d)"

  mkdir -p "$staging/Payload"
  cp -r "$src_app" "$staging/Payload/"
  rm -f "$dst_ipa"

  (cd "$staging" && zip -r -q "$dst_ipa" Payload/)
  rm -rf "$staging"

  if [ -f "$dst_ipa" ]; then
    du -h "$dst_ipa" | awk -v path="$dst_ipa" '{print path " (" $1 ")"}'
  else
    echo "[build] ERROR: Failed to create $dst_ipa"
    exit 1
  fi
}

# =============================================================================
# Device build
# =============================================================================

echo "[build] Building XCUIDriverRunner for iOS (no signing)..."
rm -rf "$APP_PATH"

xcodebuild build-for-testing \
  "${XCODE_COMMON[@]}" \
  -destination 'generic/platform=iOS' \
  | tail -5

if [ ! -d "$APP_PATH" ]; then
  echo "[build] ERROR: Runner.app not found in $BUILD_DIR"
  exit 1
fi
echo "[build] Built: $APP_PATH"

# Strip XC frameworks for iOS 17+ compatibility.
# On iOS 17+, device already has these frameworks.
echo "[build] Stripping XC frameworks..."
STRIPPED=0
if [ -d "$APP_PATH/Frameworks" ]; then
  for fw in "$APP_PATH/Frameworks"/XC*.framework; do
    [ -d "$fw" ] && rm -rf "$fw" && ((STRIPPED++)) || true
  done
fi
echo "[build] Stripped $STRIPPED XC framework(s)"

# Package as IPA
echo "[build] Packaging device IPA..."
package_ipa "$APP_PATH" "$IPA_OUTPUT"

# =============================================================================
# Simulator build
# =============================================================================

echo "[build] Building XCUIDriverRunner for Simulator..."
rm -rf "$APP_PATH"

xcodebuild build-for-testing \
  "${XCODE_COMMON[@]}" \
  -destination 'generic/platform=iOS Simulator' \
  | tail -5

if [ ! -d "$APP_PATH" ]; then
  echo "[build] ERROR: Simulator Runner.app not found in $BUILD_DIR"
  exit 1
fi
echo "[build] Built Simulator app: $APP_PATH"

# Package Simulator IPA
echo "[build] Packaging simulator IPA..."
package_ipa "$APP_PATH" "$SIM_IPA_OUTPUT"
