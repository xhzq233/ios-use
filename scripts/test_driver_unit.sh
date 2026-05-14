#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_DIR="$ROOT_DIR/driver"
RUNTIME=""

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
if [ -n "$RUNTIME" ]; then
  SIM_JSON="$(IOS_USE_TEST_SIM_RUNTIME="$RUNTIME" bun "$ROOT_DIR/scripts/ios_use_test_simulator.js")"
else
  SIM_JSON="$(bun "$ROOT_DIR/scripts/ios_use_test_simulator.js")"
fi

sim_json_value() {
  printf '%s' "$SIM_JSON" | bun -e 'const key = Bun.argv[1]; const j = JSON.parse(await new Response(Bun.stdin.stream()).text()); console.log(j[key] ?? "");' "$1"
}

SIM_UDID="$(sim_json_value udid)"
SIM_NAME="$(sim_json_value name)"
SIM_RUNTIME="$(sim_json_value runtime)"
SIM_STATE="$(sim_json_value state)"
IOS_HOME="$(sim_json_value iosUseHome)"

echo "[unit] IOS_USE_HOME: $IOS_HOME"
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
