#!/bin/bash
set -euo pipefail

# =============================================================================
# Build IOSUseDriver artifacts
#
# Usage:
#   ./scripts/build_driver.sh        # Debug build with dSYM to IOS_USE_HOME or cwd/.ios-use
#   ./scripts/build_driver.sh --release # Release build to driver/build/
#   ./scripts/build_driver.sh --simulator-only # Build only the simulator IPA for the selected mode
#   ./scripts/build_driver.sh --debug-perf # Debug build with DEBUG_PERF driver timing enabled
# =============================================================================

BUILD_MODE="debug"
SIMULATOR_ONLY=false
DEBUG_PERF=false
BUILD_STARTED_AT="$(date +%s)"
for arg in "$@"; do
  case "$arg" in
    --debug)
      BUILD_MODE="debug"
      ;;
    --release)
      BUILD_MODE="release"
      ;;
    --simulator-only)
      SIMULATOR_ONLY=true
      ;;
    --debug-perf)
      BUILD_MODE="debug"
      DEBUG_PERF=true
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
  STEP_STARTED_AT="$(date +%s)"
  (cd "$PROJECT_DIR" && xcodegen generate --quiet)
  STEP_ELAPSED=$(($(date +%s) - STEP_STARTED_AT))
  printf '[build] Xcode project generation completed in %dm%02ds\n' "$((STEP_ELAPSED / 60))" "$((STEP_ELAPSED % 60))"
else
  echo "[build] ERROR: xcodegen not found. Install via: brew install xcodegen"
  exit 1
fi

BUILD_DIR="$PROJECT_DIR/build"
DERIVED_DATA="$BUILD_DIR/DerivedData"
XCTEST_WRAPPER_PATH="$BUILD_DIR/IOSUseDriver-Runner.app"

CLI_VERSION="$(find "$ROOT_DIR/swift-cli/Sources/IOSUseCLI" -name '*.swift' -print0 \
  | xargs -0 sed -n 's/.*public static let version = "\(.*\)".*/\1/p' \
  | head -1)"
if [ -z "$CLI_VERSION" ]; then
  echo "[build] ERROR: failed to read IOSUseCLI.version"
  exit 1
fi
echo "[build] Driver version: $CLI_VERSION"

# Debug artifacts go to IOS_USE_HOME, or cwd/.ios-use when IOS_USE_HOME is unset.
# Release artifacts stay under driver/build/ and are copied only by release packaging.
if [ "$BUILD_MODE" = "debug" ]; then
  CONFIGURATION="Debug"
  DEBUG_INFO_FORMAT="dwarf-with-dsym"
  DEBUG_IPA_ROOT="${IOS_USE_HOME:-$PWD/.ios-use}"
  IPA_OUTPUT="$DEBUG_IPA_ROOT/driver.ipa"
  SIM_IPA_OUTPUT="$DEBUG_IPA_ROOT/driver-sim.ipa"
  echo "[build] DEBUG mode: building with Debug configuration + dSYM into $DEBUG_IPA_ROOT"
else
  CONFIGURATION="Release"
  DEBUG_INFO_FORMAT="dwarf"
  IPA_OUTPUT="$BUILD_DIR/driver.ipa"
  SIM_IPA_OUTPUT="$BUILD_DIR/driver-sim.ipa"
  echo "[build] RELEASE mode: building with Release configuration into driver/build/"
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
  CURRENT_PROJECT_VERSION="$CLI_VERSION"
  CODE_SIGNING_ALLOWED=NO
)

if [ "$DEBUG_PERF" = true ]; then
  XCODE_COMMON+=(
    'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) FORY_SWIFT_MACRO DEBUG_PERF'
  )
  echo "[build] DEBUG_PERF enabled"
fi

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

stamp_driver_version() {
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
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $CLI_VERSION" "$plist" 2>/dev/null \
      || /usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $CLI_VERSION" "$plist"
  done
}

# =============================================================================
# Device build
# =============================================================================

if [ "$SIMULATOR_ONLY" != true ]; then
  echo "[build] Building IOSUseDriver for iOS (no signing)..."
  rm -rf "$XCTEST_WRAPPER_PATH"

  STEP_STARTED_AT="$(date +%s)"
  xcodebuild build-for-testing \
    "${XCODE_COMMON[@]}" \
    -destination 'generic/platform=iOS' \
    -skipMacroValidation \
    | tail -5
  STEP_ELAPSED=$(($(date +%s) - STEP_STARTED_AT))
  printf '[build] iOS device xcodebuild completed in %dm%02ds\n' "$((STEP_ELAPSED / 60))" "$((STEP_ELAPSED % 60))"

  if [ ! -d "$XCTEST_WRAPPER_PATH" ]; then
    echo "[build] ERROR: xctest wrapper app not found in $BUILD_DIR"
    exit 1
  fi
  echo "[build] Built xctest wrapper: $XCTEST_WRAPPER_PATH"
  stamp_driver_version "$XCTEST_WRAPPER_PATH"

  # Strip XC frameworks and libXCTestSwiftSupport.dylib for iOS 17+ compatibility.
  # On iOS 17+, device already has these frameworks / dylibs.
  echo "[build] Stripping XC frameworks..."
  STEP_STARTED_AT="$(date +%s)"
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
  STEP_ELAPSED=$(($(date +%s) - STEP_STARTED_AT))
  printf '[build] iOS device strip completed in %dm%02ds\n' "$((STEP_ELAPSED / 60))" "$((STEP_ELAPSED % 60))"

  echo "[build] Packaging device IPA..."
  STEP_STARTED_AT="$(date +%s)"
  package_ipa "$XCTEST_WRAPPER_PATH" "$IPA_OUTPUT"
  STEP_ELAPSED=$(($(date +%s) - STEP_STARTED_AT))
  printf '[build] iOS device packaging completed in %dm%02ds\n' "$((STEP_ELAPSED / 60))" "$((STEP_ELAPSED % 60))"
else
  echo "[build] SIMULATOR ONLY mode: skipping iOS device IPA"
fi

# =============================================================================
# Simulator build
# =============================================================================

echo "[build] Building IOSUseDriver for Simulator..."
rm -rf "$XCTEST_WRAPPER_PATH"

STEP_STARTED_AT="$(date +%s)"
xcodebuild build-for-testing \
  "${XCODE_COMMON[@]}" \
  -destination 'generic/platform=iOS Simulator' \
  -skipMacroValidation \
  | tail -5
STEP_ELAPSED=$(($(date +%s) - STEP_STARTED_AT))
printf '[build] Simulator xcodebuild completed in %dm%02ds\n' "$((STEP_ELAPSED / 60))" "$((STEP_ELAPSED % 60))"

if [ ! -d "$XCTEST_WRAPPER_PATH" ]; then
  echo "[build] ERROR: Simulator xctest wrapper app not found in $BUILD_DIR"
  exit 1
fi
echo "[build] Built Simulator xctest wrapper: $XCTEST_WRAPPER_PATH"
stamp_driver_version "$XCTEST_WRAPPER_PATH"

# Package Simulator IPA
echo "[build] Packaging simulator IPA..."
STEP_STARTED_AT="$(date +%s)"
package_ipa "$XCTEST_WRAPPER_PATH" "$SIM_IPA_OUTPUT"
STEP_ELAPSED=$(($(date +%s) - STEP_STARTED_AT))
printf '[build] Simulator packaging completed in %dm%02ds\n' "$((STEP_ELAPSED / 60))" "$((STEP_ELAPSED % 60))"
TOTAL_ELAPSED=$(($(date +%s) - BUILD_STARTED_AT))
printf '[build] Total completed in %dm%02ds\n' "$((TOTAL_ELAPSED / 60))" "$((TOTAL_ELAPSED % 60))"
