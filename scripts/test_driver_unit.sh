#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_DIR="$ROOT_DIR/driver"
RUNTIME=""
IOS_USE_HOME_RESOLVED="${IOS_USE_HOME:-$HOME/.ios-use/test-homes/driver-unit}"
SIM_NAME="${IOS_USE_TEST_SIM_NAME:-IOSUseTest}"
SIM_DEVICE_TYPE="${IOS_USE_TEST_SIM_DEVICE_TYPE:-iPhone 16}"
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

resolve_runtime_id() {
  local requested="$1"
  xcrun simctl list runtimes available | awk -v requested="$requested" '
    /^iOS / {
      if (requested == "" || index($0, requested) > 0) {
        print $NF
        exit
      }
    }
  '
}

resolve_device_type_id() {
  local requested="$1"
  local line name identifier
  while IFS= read -r line; do
    name="${line% (*}"
    identifier="${line##*(}"
    identifier="${identifier%)}"
    if [ "$name" = "$requested" ]; then
      printf '%s\n' "$identifier"
      return
    fi
  done < <(xcrun simctl list devicetypes)
  xcrun simctl list devicetypes | sed -nE 's/^iPhone 16 \(([^)]+)\)$/\1/p' | head -n 1
}

resolve_existing_simulator() {
  xcrun simctl list devices available | sed -nE "s/^[[:space:]]*${SIM_NAME//\//\\/} \\(([A-F0-9-]+)\\) \\(([^)]+)\\).*$/\\1|\\2/p" | head -n 1
}

echo "[unit] Resolving IOSUseTest Simulator..."
SIM_MATCH="$(resolve_existing_simulator)"
if [ -n "$SIM_MATCH" ]; then
  SIM_UDID="${SIM_MATCH%%|*}"
  SIM_STATE="${SIM_MATCH#*|}"
else
  RUNTIME_ID="$(resolve_runtime_id "$RUNTIME")"
  if [ -z "$RUNTIME_ID" ]; then
    if [ -n "$RUNTIME" ]; then
      echo "[unit] ERROR: no available iOS Simulator runtime matches $RUNTIME"
    else
      echo "[unit] ERROR: no available iOS Simulator runtime found"
    fi
    exit 1
  fi
  DEVICE_TYPE_ID="$(resolve_device_type_id "$SIM_DEVICE_TYPE")"
  if [ -z "$DEVICE_TYPE_ID" ]; then
    echo "[unit] ERROR: no usable iPhone Simulator device type found"
    exit 1
  fi
  SIM_UDID="$(xcrun simctl create "$SIM_NAME" "$DEVICE_TYPE_ID" "$RUNTIME_ID")"
  SIM_STATE="Shutdown"
fi

if ! xcrun simctl boot "$SIM_UDID" >/dev/null 2>&1; then
  # Already booted or booting.
  true
fi
xcrun simctl bootstatus "$SIM_UDID" -b >/dev/null 2>&1 &
BOOT_PID=$!
SECONDS_WAITED=0
while kill -0 "$BOOT_PID" >/dev/null 2>&1; do
  if [ "$SECONDS_WAITED" -ge "$((BOOT_TIMEOUT_MS / 1000))" ]; then
    kill "$BOOT_PID" >/dev/null 2>&1 || true
    echo "[unit] ERROR: Simulator boot timed out after ${BOOT_TIMEOUT_MS}ms"
    exit 1
  fi
  sleep 1
  SECONDS_WAITED=$((SECONDS_WAITED + 1))
done
wait "$BOOT_PID"
SIM_STATE="Booted"
SIM_RUNTIME="$(xcrun simctl list devices available | awk -v udid="$SIM_UDID" '
  /^-- iOS / { current=$0; gsub(/^-- /, "", current); gsub(/ --$/, "", current) }
  index($0, udid) > 0 { print current; exit }
')"
if [ -z "$SIM_RUNTIME" ]; then
  SIM_RUNTIME="unknown"
fi
STATE_FILE="$IOS_USE_HOME_RESOLVED/simulators/ios-use-test.json"
mkdir -p "$(dirname "$STATE_FILE")"
cat > "$STATE_FILE" <<JSON
{
  "iosUseHome": "$IOS_USE_HOME_RESOLVED",
  "stateFile": "$STATE_FILE",
  "name": "$SIM_NAME",
  "udid": "$SIM_UDID",
  "runtime": "$SIM_RUNTIME",
  "state": "$SIM_STATE",
  "updatedAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
JSON

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
