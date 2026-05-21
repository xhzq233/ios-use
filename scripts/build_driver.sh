#!/bin/bash
set -euo pipefail

# =============================================================================
# Build IOSUseDriver artifacts
#
# Usage:
#   ./scripts/build_driver.sh        # Release build (fastest, no dSYM)
#   ./scripts/build_driver.sh --debug # Debug build with dSYM for troubleshooting
#   ./scripts/build_driver.sh --simulator-only # Build only assets/driver-sim.ipa
# =============================================================================

DEBUG_MODE=false
SIMULATOR_ONLY=false
for arg in "$@"; do
  case "$arg" in
    --debug)
      DEBUG_MODE=true
      ;;
    --simulator-only)
      SIMULATOR_ONLY=true
      ;;
    *)
      echo "[build] ERROR: unknown option $arg"
      exit 1
      ;;
  esac
done

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_DIR="$ROOT_DIR/driver"

# Regenerate Xcode project from project.yml
if command -v xcodegen &>/dev/null; then
  echo "[build] Regenerating Xcode project..."
  (cd "$PROJECT_DIR" && xcodegen generate --quiet)
else
  echo "[build] ERROR: xcodegen not found. Install via: brew install xcodegen"
  exit 1
fi

BUILD_DIR="$PROJECT_DIR/build"
DERIVED_DATA="$BUILD_DIR/DerivedData"
XCTEST_WRAPPER_PATH="$BUILD_DIR/IOSUseDriver-Runner.app"

CLI_VERSION="$(sed -n 's/.*public static let version = "\(.*\)".*/\1/p' "$ROOT_DIR/swift-cli/Sources/IOSUseCLI/IOSUseCLI.swift" | head -1)"
if [ -z "$CLI_VERSION" ]; then
  echo "[build] ERROR: failed to read IOSUseCLI.version"
  exit 1
fi
DRIVER_GIT_SHA="$(git -C "$ROOT_DIR" rev-parse --short=12 HEAD 2>/dev/null || echo unknown)"
DRIVER_BUILD_ID="$(date -u +%Y%m%d%H%M%S)"
PROTOCOL_ID="$(
  find "$ROOT_DIR/shared/IOSUseProtocol" "$ROOT_DIR/driver/tcp" "$ROOT_DIR/driver/ui" -name '*.swift' -type f -print0 \
    | sort -z \
    | xargs -0 shasum \
    | shasum \
    | awk '{print $1}'
)"
echo "[build] Driver identity: version=$CLI_VERSION build=$DRIVER_BUILD_ID git=$DRIVER_GIT_SHA protocol=$PROTOCOL_ID"

# Release artifacts go to assets/ (ignored local build outputs).
# Debug artifacts go to build/ (not tracked) to avoid accidental commits.
if [ "$DEBUG_MODE" = true ]; then
  CONFIGURATION="Debug"
  DEBUG_INFO_FORMAT="dwarf-with-dsym"
  IPA_OUTPUT="$BUILD_DIR/driver-debug.ipa"
  SIM_IPA_OUTPUT="$BUILD_DIR/driver-sim-debug.ipa"
  echo "[build] DEBUG mode: building with Debug configuration + dSYM (assets/ are not overwritten)"
else
  CONFIGURATION="Release"
  DEBUG_INFO_FORMAT="dwarf"
  IPA_OUTPUT="$ROOT_DIR/assets/driver.ipa"
  SIM_IPA_OUTPUT="$ROOT_DIR/assets/driver-sim.ipa"
  echo "[build] RELEASE mode: building with Release configuration (no dSYM)"
fi

# Common xcodebuild flags.
XCODE_COMMON=(
  -project "$PROJECT_DIR/IOSUseDriver.xcodeproj"
  -scheme IOSUseDriver
  -configuration "$CONFIGURATION"
  CONFIGURATION_BUILD_DIR="$BUILD_DIR"
  -derivedDataPath "$DERIVED_DATA"
  DEBUG_INFORMATION_FORMAT="$DEBUG_INFO_FORMAT"
  MARKETING_VERSION="$CLI_VERSION"
  CURRENT_PROJECT_VERSION="$DRIVER_BUILD_ID"
  IOS_USE_DRIVER_GIT_SHA="$DRIVER_GIT_SHA"
  IOS_USE_DRIVER_PROTOCOL_ID="$PROTOCOL_ID"
  CODE_SIGNING_ALLOWED=NO
)

# Helper: package a .app into an IPA.
package_ipa() {
  local src_app="$1"
  local dst_ipa="$2"
  local staging
  staging="$(mktemp -d)"

  mkdir -p "$(dirname "$dst_ipa")"
  mkdir -p "$staging/Payload"
  cp -r "$src_app" "$staging/Payload/"
  find "$staging/Payload" -name "*.dSYM" -type d -prune -exec rm -rf {} +
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

stamp_driver_identity() {
  local app_path="$1"
  local plist_paths=("$app_path/Info.plist")
  if [ -d "$app_path/PlugIns" ]; then
    while IFS= read -r -d '' plugin_plist; do
      plist_paths+=("$plugin_plist")
    done < <(find "$app_path/PlugIns" -name Info.plist -type f -print0)
  fi

  for plist in "${plist_paths[@]}"; do
    [ -f "$plist" ] || continue
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $CLI_VERSION" "$plist" 2>/dev/null \
      || /usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $CLI_VERSION" "$plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $DRIVER_BUILD_ID" "$plist" 2>/dev/null \
      || /usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $DRIVER_BUILD_ID" "$plist"
    /usr/libexec/PlistBuddy -c "Set :IOSUseDriverGitSHA $DRIVER_GIT_SHA" "$plist" 2>/dev/null \
      || /usr/libexec/PlistBuddy -c "Add :IOSUseDriverGitSHA string $DRIVER_GIT_SHA" "$plist"
    /usr/libexec/PlistBuddy -c "Set :IOSUseDriverProtocolID $PROTOCOL_ID" "$plist" 2>/dev/null \
      || /usr/libexec/PlistBuddy -c "Add :IOSUseDriverProtocolID string $PROTOCOL_ID" "$plist"
  done
}

# =============================================================================
# Device build
# =============================================================================

if [ "$SIMULATOR_ONLY" != true ]; then
  echo "[build] Building IOSUseDriver for iOS (no signing)..."
  rm -rf "$XCTEST_WRAPPER_PATH"

  xcodebuild build-for-testing \
    "${XCODE_COMMON[@]}" \
    -destination 'generic/platform=iOS' \
    -skipMacroValidation \
    | tail -5

  if [ ! -d "$XCTEST_WRAPPER_PATH" ]; then
    echo "[build] ERROR: xctest wrapper app not found in $BUILD_DIR"
    exit 1
  fi
  echo "[build] Built xctest wrapper: $XCTEST_WRAPPER_PATH"
  stamp_driver_identity "$XCTEST_WRAPPER_PATH"

  # Strip XC frameworks and libXCTestSwiftSupport.dylib for iOS 17+ compatibility.
  # On iOS 17+, device already has these frameworks / dylibs.
  echo "[build] Stripping XC frameworks..."
  STRIPPED=0
  if [ -d "$XCTEST_WRAPPER_PATH/Frameworks" ]; then
    for fw in "$XCTEST_WRAPPER_PATH/Frameworks"/XC*.framework; do
      [ -d "$fw" ] && rm -rf "$fw" && ((STRIPPED++)) || true
    done
    # libXCTestSwiftSupport.dylib from newer Xcode may reference symbols
    # absent on older iOS versions (e.g. iOS 18.7.1). Strip it — system has it.
    if [ -f "$XCTEST_WRAPPER_PATH/Frameworks/libXCTestSwiftSupport.dylib" ]; then
      rm -f "$XCTEST_WRAPPER_PATH/Frameworks/libXCTestSwiftSupport.dylib"
      ((STRIPPED++)) || true
    fi
    # Testing.framework from Xcode 16 may mismatch the system libXCTestSwiftSupport
    # on iOS 18. Strip it so the system uses its own compatible version.
    if [ -d "$XCTEST_WRAPPER_PATH/Frameworks/Testing.framework" ]; then
      rm -rf "$XCTEST_WRAPPER_PATH/Frameworks/Testing.framework"
      ((STRIPPED++)) || true
    fi
  fi
  echo "[build] Stripped $STRIPPED XC framework(s) / dylib(s)"

  echo "[build] Packaging device IPA..."
  package_ipa "$XCTEST_WRAPPER_PATH" "$IPA_OUTPUT"
else
  echo "[build] SIMULATOR ONLY mode: skipping iOS device IPA"
fi

# =============================================================================
# Simulator build
# =============================================================================

echo "[build] Building IOSUseDriver for Simulator..."
rm -rf "$XCTEST_WRAPPER_PATH"

xcodebuild build-for-testing \
  "${XCODE_COMMON[@]}" \
  -destination 'generic/platform=iOS Simulator' \
  -skipMacroValidation \
  | tail -5

if [ ! -d "$XCTEST_WRAPPER_PATH" ]; then
  echo "[build] ERROR: Simulator xctest wrapper app not found in $BUILD_DIR"
  exit 1
fi
echo "[build] Built Simulator xctest wrapper: $XCTEST_WRAPPER_PATH"
stamp_driver_identity "$XCTEST_WRAPPER_PATH"

# Package Simulator IPA
echo "[build] Packaging simulator IPA..."
package_ipa "$XCTEST_WRAPPER_PATH" "$SIM_IPA_OUTPUT"
