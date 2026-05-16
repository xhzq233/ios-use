#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_DIR="$ROOT_DIR/driver"
RUNTIME=""
IOS_USE_HOME_RESOLVED="${IOS_USE_HOME:-$HOME/.ios-use}"
SIM_STATE_FILE="$IOS_USE_HOME_RESOLVED/simulators/ios-use-test.json"
SIM_NAME="${IOS_USE_TEST_SIM_NAME:-IOSUseTest}"
SIM_DEVICE_TYPE="${IOS_USE_TEST_SIM_DEVICE_TYPE:-iPhone 16}"

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
sim_list_line() {
  xcrun simctl list devices available | awk -v name="$SIM_NAME" '
    /^-- / {
      runtime=$0
      gsub(/^-- /, "", runtime)
      gsub(/ --$/, "", runtime)
      next
    }
    index($0, name " (") {
      print runtime "\t" $0
      exit
    }
  '
}

sim_udid_from_line() {
  sed -E 's/.* \(([0-9A-Fa-f-]{36})\).*/\1/'
}

sim_state_from_line() {
  sed -E 's/[[:space:]]*$//' | sed -E 's/.*\(([A-Za-z ]+)\)$/\1/'
}

choose_runtime_identifier() {
  local requested="${RUNTIME:-${IOS_USE_TEST_SIM_RUNTIME:-}}"
  xcrun simctl list runtimes available | awk -v requested="$requested" '
    /^iOS / {
      line=$0
      identifier=$NF
      version=$2
      if (requested == "" || line ~ requested || version == requested || identifier == requested) {
        chosen=identifier
      }
    }
    END {
      if (chosen != "") print chosen
    }
  '
}

choose_device_type_identifier() {
  local requested="$SIM_DEVICE_TYPE"
  local exact
  exact="$(xcrun simctl list devicetypes | awk -v requested="$requested" '
    index($0, requested " (") {
      match($0, /\(([^)]+)\)/)
      print substr($0, RSTART + 1, RLENGTH - 2)
      exit
    }
  ')"
  if [ -n "$exact" ]; then
    printf '%s\n' "$exact"
    return
  fi
  xcrun simctl list devicetypes | awk '
    /^iPhone / {
      match($0, /\(([^)]+)\)/)
      print substr($0, RSTART + 1, RLENGTH - 2)
      exit
    }
  '
}

ensure_simulator() {
  local line runtime_line device_line runtime_id device_type udid
  line="$(sim_list_line || true)"
  if [ -z "$line" ]; then
    runtime_id="$(choose_runtime_identifier)"
    if [ -z "$runtime_id" ]; then
      echo "[unit] ERROR: No available iOS Simulator runtime found" >&2
      exit 1
    fi
    device_type="$(choose_device_type_identifier)"
    if [ -z "$device_type" ]; then
      echo "[unit] ERROR: No usable iPhone Simulator device type found" >&2
      exit 1
    fi
    udid="$(xcrun simctl create "$SIM_NAME" "$device_type" "$runtime_id")"
  else
    device_line="${line#*$'\t'}"
    udid="$(printf '%s\n' "$device_line" | sim_udid_from_line)"
  fi

  xcrun simctl boot "$udid" >/dev/null 2>&1 || true
  xcrun simctl bootstatus "$udid" -b >/dev/null

  line="$(sim_list_line)"
  runtime_line="${line%%$'\t'*}"
  device_line="${line#*$'\t'}"
  SIM_UDID="$(printf '%s\n' "$device_line" | sim_udid_from_line)"
  SIM_RUNTIME="$runtime_line"
  SIM_STATE="$(printf '%s\n' "$device_line" | sim_state_from_line)"
}

ensure_simulator
mkdir -p "$(dirname "$SIM_STATE_FILE")"
cat > "$SIM_STATE_FILE" <<JSON
{
  "iosUseHome": "$IOS_USE_HOME_RESOLVED",
  "stateFile": "$SIM_STATE_FILE",
  "name": "$SIM_NAME",
  "udid": "$SIM_UDID",
  "runtime": "$SIM_RUNTIME",
  "state": "$SIM_STATE",
  "updatedAt": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
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
