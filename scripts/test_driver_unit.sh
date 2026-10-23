#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_DIR="$ROOT_DIR/driver"
DERIVED_DATA="$PROJECT_DIR/build/DerivedData"
RUNTIME="${IOS_USE_TEST_SIM_RUNTIME:-}"
IOS_USE_HOME_RESOLVED="${IOS_USE_HOME:-$HOME/.ios-use/test-homes/driver-unit}"
SIM_NAME="${IOS_USE_TEST_SIM_NAME:-IOSUseTest}"
BOOT_TIMEOUT_MS="${IOS_USE_TEST_SIM_BOOT_TIMEOUT_MS:-300000}"

while [ $# -gt 0 ]; do
  case "$1" in
    --runtime)
      if [ $# -lt 2 ]; then
        echo "[unit] ERROR: --runtime requires a value"
        exit 1
      fi
      RUNTIME="${2:-}"
      shift 2
      ;;
    *)
      echo "[unit] ERROR: unknown option $1"
      exit 1
      ;;
  esac
done

if ! [[ "$BOOT_TIMEOUT_MS" =~ ^[1-9][0-9]*$ ]]; then
  echo "[unit] ERROR: IOS_USE_TEST_SIM_BOOT_TIMEOUT_MS must be a positive integer"
  exit 1
fi

if command -v xcodegen &>/dev/null; then
  echo "[unit] Regenerating Xcode project..."
  (cd "$PROJECT_DIR" && xcodegen generate --quiet)
else
  echo "[unit] ERROR: xcodegen not found. Install via: brew install xcodegen"
  exit 1
fi

echo "[unit] Checking effective iOS deployment target..."
DEPLOYMENT_TARGETS="$(
  xcodebuild -showBuildSettings \
    -project "$PROJECT_DIR/IOSUseDriver.xcodeproj" \
    -target IOSUseDriverUnitTests \
    -sdk iphonesimulator \
    2>/dev/null |
    sed -n 's/^[[:space:]]*IPHONEOS_DEPLOYMENT_TARGET = //p' |
    sort -u
)"
if [[ "$DEPLOYMENT_TARGETS" != "17.0" ]]; then
  echo "[unit] ERROR: effective IPHONEOS_DEPLOYMENT_TARGET must be exactly 17.0; observed: ${DEPLOYMENT_TARGETS:-<missing>}" >&2
  exit 1
fi

echo "[unit] Resolving a compatible test Simulator..."
command -v node >/dev/null 2>&1 || {
  echo "[unit] ERROR: Node.js is required for Simulator selection" >&2
  exit 1
}
SIM_INFO="$(IOS_USE_HOME="$IOS_USE_HOME_RESOLVED" \
  IOS_USE_TEST_SIM_RUNTIME="$RUNTIME" \
  node "$ROOT_DIR/scripts/ios_use_test_simulator.js" resolve)"
SIM_UDID="$(printf '%s' "$SIM_INFO" | node -e 'process.stdout.write(JSON.parse(require("fs").readFileSync(0, "utf8")).udid)')"
SIM_RUNTIME="$(printf '%s' "$SIM_INFO" | node -e 'process.stdout.write(JSON.parse(require("fs").readFileSync(0, "utf8")).runtime)')"

if ! xcrun simctl boot "$SIM_UDID" >/dev/null 2>&1; then
  # Already booted or booting.
  true
fi

BUILD_LOG="$(mktemp)"
TEST_LOG="$(mktemp)"
BOOT_PID=""
cleanup() {
  if [[ -n "$BOOT_PID" ]] && kill -0 "$BOOT_PID" >/dev/null 2>&1; then
    kill "$BOOT_PID" >/dev/null 2>&1 || true
  fi
  rm -f "$BUILD_LOG" "$TEST_LOG"
}
trap cleanup EXIT

xcrun simctl bootstatus "$SIM_UDID" -b >/dev/null 2>&1 &
BOOT_PID=$!
BOOT_STARTED_AT="$(date +%s)"

echo "[unit] Building tests while Simulator boots..."
set +e
xcodebuild build-for-testing \
  -project "$PROJECT_DIR/IOSUseDriver.xcodeproj" \
  -scheme IOSUseDriverUnitTests \
  -destination "platform=iOS Simulator,id=$SIM_UDID" \
  -derivedDataPath "$DERIVED_DATA" \
  -IDEPackageEnablePrebuilts=NO \
  -skipMacroValidation \
  CODE_SIGNING_ALLOWED=NO \
  >"$BUILD_LOG" 2>&1
BUILD_EXIT=$?
set -e
if [[ "$BUILD_EXIT" -ne 0 ]]; then
  echo "[unit] Swift unit-test build failed (exit $BUILD_EXIT). Log: $BUILD_LOG"
  exit 1
fi

while kill -0 "$BOOT_PID" >/dev/null 2>&1; do
  ELAPSED_SECONDS="$(($(date +%s) - BOOT_STARTED_AT))"
  if [ "$ELAPSED_SECONDS" -ge "$((BOOT_TIMEOUT_MS / 1000))" ]; then
    kill "$BOOT_PID" >/dev/null 2>&1 || true
    echo "[unit] ERROR: Simulator boot timed out after ${BOOT_TIMEOUT_MS}ms"
    exit 1
  fi
  sleep 1
done
if ! wait "$BOOT_PID"; then
  echo "[unit] ERROR: Simulator failed to finish booting" >&2
  exit 1
fi
BOOT_PID=""
SIM_STATE="Booted"
IOS_USE_HOME="$IOS_USE_HOME_RESOLVED" IOS_USE_TEST_SIM_RUNTIME="$RUNTIME" \
  node "$ROOT_DIR/scripts/ios_use_test_simulator.js" ensure >/dev/null

echo "[unit] IOS_USE_HOME: $IOS_USE_HOME_RESOLVED"
echo "[unit] Simulator: $SIM_NAME | $SIM_RUNTIME | $SIM_STATE | UDID: $SIM_UDID"

set +e
xcodebuild test-without-building \
  -project "$PROJECT_DIR/IOSUseDriver.xcodeproj" \
  -scheme IOSUseDriverUnitTests \
  -destination "platform=iOS Simulator,id=$SIM_UDID" \
  -derivedDataPath "$DERIVED_DATA" \
  -IDEPackageEnablePrebuilts=NO \
  -skipMacroValidation \
  CODE_SIGNING_ALLOWED=NO \
  > "$TEST_LOG" 2>&1
TEST_EXIT=$?
set -e

if [ $TEST_EXIT -ne 0 ]; then
  echo "[unit] Swift unit tests failed (exit $TEST_EXIT). Log: $TEST_LOG"
  exit 1
fi

grep -E "(Test Suite|Executed|passed|failed|TEST)" "$TEST_LOG" || true
echo "[unit] Swift unit tests passed"
