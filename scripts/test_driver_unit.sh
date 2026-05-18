#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_DIR="$ROOT_DIR/driver"
RUNTIME=""
IOS_USE_HOME_RESOLVED="${IOS_USE_HOME:-$HOME/.ios-use/test-homes/driver-unit}"

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

if command -v xcodegen &>/dev/null; then
  echo "[unit] Regenerating Xcode project..."
  (cd "$PROJECT_DIR" && xcodegen generate --quiet)
else
  echo "[unit] ERROR: xcodegen not found. Install via: brew install xcodegen"
  exit 1
fi

echo "[unit] Resolving IOSUseTest Simulator..."
SIM_INFO_FILE="$(mktemp)"
if [ -n "$RUNTIME" ]; then
  IOS_USE_HOME="$IOS_USE_HOME_RESOLVED" IOS_USE_TEST_SIM_RUNTIME="$RUNTIME" node "$ROOT_DIR/scripts/ios_use_test_simulator.js" > "$SIM_INFO_FILE"
else
  IOS_USE_HOME="$IOS_USE_HOME_RESOLVED" node "$ROOT_DIR/scripts/ios_use_test_simulator.js" > "$SIM_INFO_FILE"
fi
SIM_UDID="$(node -e "const fs=require('fs'); const info=JSON.parse(fs.readFileSync(process.argv[1], 'utf8')); console.log(info.udid);" "$SIM_INFO_FILE")"
SIM_NAME="$(node -e "const fs=require('fs'); const info=JSON.parse(fs.readFileSync(process.argv[1], 'utf8')); console.log(info.name);" "$SIM_INFO_FILE")"
SIM_RUNTIME="$(node -e "const fs=require('fs'); const info=JSON.parse(fs.readFileSync(process.argv[1], 'utf8')); console.log(info.runtime);" "$SIM_INFO_FILE")"
SIM_STATE="$(node -e "const fs=require('fs'); const info=JSON.parse(fs.readFileSync(process.argv[1], 'utf8')); console.log(info.state);" "$SIM_INFO_FILE")"
rm -f "$SIM_INFO_FILE"

echo "[unit] IOS_USE_HOME: $IOS_USE_HOME_RESOLVED"
echo "[unit] Simulator: $SIM_NAME | $SIM_RUNTIME | $SIM_STATE | UDID: $SIM_UDID"

TEST_LOG="$(mktemp)"
set +e
xcodebuild test \
  -project "$PROJECT_DIR/IOSUseDriver.xcodeproj" \
  -scheme IOSUseDriverUnitTests \
  -destination "platform=iOS Simulator,id=$SIM_UDID" \
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
rm -f "$TEST_LOG"
echo "[unit] Swift unit tests passed"
