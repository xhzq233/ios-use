#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SKIP_BUILD=false
CASE_FILTER=""
TEST_IOS_USE_HOME="${IOS_USE_TEST_HOME:-$HOME/.ios-use/test-homes/simulator-commands}"

while [ $# -gt 0 ]; do
  case "$1" in
    --skip-build)
      SKIP_BUILD=true
      shift
      ;;
    --case)
      if [ $# -lt 2 ]; then
        echo "[sim-test] ERROR: --case requires a value"
        exit 1
      fi
      CASE_FILTER="${2:-}"
      shift 2
      ;;
    *)
      echo "[sim-test] ERROR: unknown option $1"
      exit 1
      ;;
  esac
done

if [ "$SKIP_BUILD" = false ]; then
  bash "$ROOT_DIR/scripts/build_driver.sh"
fi

echo "[sim-test] Resolving IOSUseTest Simulator..."
SIM_JSON="$(IOS_USE_HOME="$TEST_IOS_USE_HOME" bun "$ROOT_DIR/scripts/ios_use_test_simulator.js")"

sim_json_value() {
  printf '%s' "$SIM_JSON" | bun -e 'const key = Bun.argv[1]; const j = JSON.parse(await new Response(Bun.stdin.stream()).text()); console.log(j[key] ?? "");' "$1"
}

SIM_UDID="$(sim_json_value udid)"
SIM_NAME="$(sim_json_value name)"
SIM_RUNTIME="$(sim_json_value runtime)"
SIM_STATE="$(sim_json_value state)"
IOS_HOME="$(sim_json_value iosUseHome)"

STAMP="$(date -u +"%Y%m%dT%H%M%SZ")"
ARTIFACT_DIR="$IOS_HOME/artifacts/simulator-command-tests/$STAMP"
STATE_BACKUP_DIR="$ARTIFACT_DIR/local-state-backup"
mkdir -p "$ARTIFACT_DIR"

echo "[sim-test] IOS_USE_HOME: $IOS_HOME"
echo "[sim-test] Simulator: $SIM_NAME | $SIM_RUNTIME | $SIM_STATE | UDID: $SIM_UDID"
echo "[sim-test] driver-sim IPA: $ROOT_DIR/assets/driver-sim.ipa"
echo "[sim-test] Artifacts: $ARTIFACT_DIR"

PASSED=0
FAILED=0
SKIPPED=0

backup_state_file() {
  local rel="$1"
  local src="$IOS_HOME/$rel"
  local dst="$STATE_BACKUP_DIR/$rel"
  mkdir -p "$(dirname "$dst")"
  if [ -f "$src" ]; then
    cp "$src" "$dst"
  else
    touch "$dst.missing"
  fi
}

restore_state_file() {
  local rel="$1"
  local src="$STATE_BACKUP_DIR/$rel"
  local missing="$src.missing"
  local dst="$IOS_HOME/$rel"
  if [ -f "$src" ]; then
    mkdir -p "$(dirname "$dst")"
    cp "$src" "$dst"
  elif [ -f "$missing" ]; then
    rm -f "$dst"
  fi
}

backup_local_state() {
  mkdir -p "$STATE_BACKUP_DIR"
  backup_state_file "config.json"
  backup_state_file "state/session.json"
}

restore_local_state() {
  restore_state_file "config.json"
  restore_state_file "state/session.json"
}

case_selected() {
  local id="$1"
  if [ -z "$CASE_FILTER" ]; then return 0; fi
  local normalized_id
  normalized_id="$(printf '%s' "$id" | tr '[:lower:]' '[:upper:]')"
  IFS=',' read -ra parts <<< "$CASE_FILTER"
  for part in "${parts[@]}"; do
    local normalized_part
    normalized_part="$(printf '%s' "$part" | tr '[:lower:]' '[:upper:]')"
    if [ "$normalized_id" = "$normalized_part" ] || [[ "$normalized_id" == "$normalized_part"-* ]]; then return 0; fi
  done
  return 1
}

run_cli() {
  (cd "$ROOT_DIR" && IOS_USE_HOME="$IOS_HOME" bun run src/cli.ts "$@")
}

record_pass() {
  PASSED=$((PASSED + 1))
  echo "[sim-test] PASS $1"
}

record_fail() {
  FAILED=$((FAILED + 1))
  echo "[sim-test] FAIL $1"
}

record_skip() {
  SKIPPED=$((SKIPPED + 1))
  echo "[sim-test] SKIP $1"
}

run_case() {
  local id="$1"
  shift
  if ! case_selected "$id"; then record_skip "$id"; return; fi
  local out="$ARTIFACT_DIR/$id.out"
  local err="$ARTIFACT_DIR/$id.err"
  echo "[sim-test] RUN $id: ios-use $*"
  if run_cli "$@" > "$out" 2> "$err"; then
    record_pass "$id"
  else
    record_fail "$id"
    cat "$err" >&2 || true
  fi
}

run_case_contains() {
  local id="$1"
  local expected="$2"
  shift 2
  if ! case_selected "$id"; then record_skip "$id"; return; fi
  local out="$ARTIFACT_DIR/$id.out"
  local err="$ARTIFACT_DIR/$id.err"
  echo "[sim-test] RUN $id: ios-use $*"
  if run_cli "$@" > "$out" 2> "$err" && grep -q "$expected" "$out"; then
    record_pass "$id"
  else
    record_fail "$id"
    { cat "$out"; cat "$err"; } >&2 || true
  fi
}

run_case_fails_contains() {
  local id="$1"
  local expected="$2"
  shift 2
  if ! case_selected "$id"; then record_skip "$id"; return; fi
  local out="$ARTIFACT_DIR/$id.out"
  local err="$ARTIFACT_DIR/$id.err"
  echo "[sim-test] RUN $id: ios-use $* (expect fail)"
  if run_cli "$@" > "$out" 2> "$err"; then
    record_fail "$id"
    cat "$out" >&2 || true
    return
  fi
  if grep -qi "$expected" "$out" "$err"; then
    record_pass "$id"
  else
    record_fail "$id"
    { cat "$out"; cat "$err"; } >&2 || true
  fi
}

wait_for_driver() {
  local out="$ARTIFACT_DIR/driver-warmup.out"
  local err="$ARTIFACT_DIR/driver-warmup.err"
  echo "[sim-test] Waiting for driver..."
  for _ in {1..10}; do
    if run_cli dom --fresh --udid "$SIM_UDID" > "$out" 2> "$err"; then
      echo "[sim-test] Driver ready"
      return 0
    fi
    sleep 1
  done
  echo "[sim-test] Driver did not become ready" >&2
  { cat "$out"; cat "$err"; } >&2 || true
  return 1
}

cleanup() {
  run_cli stop >/dev/null 2>&1 || true
  if [ -f "$IOS_HOME/logs/driver.log" ]; then
    cp "$IOS_HOME/logs/driver.log" "$ARTIFACT_DIR/driver.log" || true
  fi
  restore_local_state
}
trap cleanup EXIT

backup_local_state

run_case "CFG-SIM" config --simulator --udid "$SIM_UDID"
if case_selected "CFG-SIM" || [ -z "$CASE_FILTER" ]; then
  wait_for_driver
fi
if [ -n "$CASE_FILTER" ] && ! case_selected "CFG-SIM"; then
  echo "[sim-test] Running prerequisite config"
  run_cli config --simulator --udid "$SIM_UDID" > "$ARTIFACT_DIR/prereq-config.out" 2> "$ARTIFACT_DIR/prereq-config.err"
  wait_for_driver
fi
if [ -n "$CASE_FILTER" ] && {
  case_selected "DOM-1" || case_selected "FIND-1" || case_selected "WF-1" || case_selected "SC-2";
}; then
  echo "[sim-test] Running prerequisite Settings activation"
  run_cli activateApp com.apple.Preferences --udid "$SIM_UDID" > "$ARTIFACT_DIR/prereq-activate-settings.out" 2> "$ARTIFACT_DIR/prereq-activate-settings.err"
fi
run_case_contains "AA-2" "App com.apple.Preferences activated" activateApp com.apple.Preferences --udid "$SIM_UDID"
run_case_contains "DOM-1" "App: com.apple.Preferences" dom --fresh --udid "$SIM_UDID"
run_case_contains "DOM-2" "Application" dom --raw --fresh --udid "$SIM_UDID"
run_case_contains "FIND-1" "Find" find "General" --udid "$SIM_UDID"
run_case_fails_contains "FIND-5B" "not found" find "__ios_use_missing_label__" --udid "$SIM_UDID"
run_case_contains "WF-1" "waited=" waitFor --label "com.apple.settings.general" --traits Button --timeout 2 --udid "$SIM_UDID"
run_case_fails_contains "WF-4" "timed out\\|not found" waitFor --label "__ios_use_missing_label__" --timeout 0.2 --udid "$SIM_UDID"
run_case "SC-2" screenshot --name sim_command_screenshot --udid "$SIM_UDID"
if case_selected "SC-2"; then
  SCREENSHOT="$IOS_HOME/artifacts/sim_command_screenshot.jpg"
  if [ -s "$SCREENSHOT" ]; then
    cp "$SCREENSHOT" "$ARTIFACT_DIR/sim_command_screenshot.jpg" || true
  else
    FAILED=$((FAILED + 1))
    echo "[sim-test] FAIL SC-2 screenshot file missing: $SCREENSHOT"
  fi
fi
run_case_contains "HOME-1" "Home" home --udid "$SIM_UDID"
run_case_contains "DOM-3" "App:" dom --fresh --udid "$SIM_UDID"
run_case_fails_contains "AA-5" "app not found\\|state=unknown\\|not installed" activateApp com.iosuse.invalid.bundle --udid "$SIM_UDID"
if case_selected "AS-1"; then
  run_cli stop >/dev/null 2>&1 || true
  run_case_contains "AS-1" "App:" dom --fresh --udid "$SIM_UDID"
else
  record_skip "AS-1"
fi
run_case "STOP-1" stop
run_case "STOP-2" stop

cat > "$ARTIFACT_DIR/summary.json" <<EOF
{
  "iosUseHome": "$IOS_HOME",
  "simulator": "$SIM_NAME",
  "simulatorUdid": "$SIM_UDID",
  "runtime": "$SIM_RUNTIME",
  "passed": $PASSED,
  "failed": $FAILED,
  "skipped": $SKIPPED,
  "artifacts": "$ARTIFACT_DIR"
}
EOF

cat "$ARTIFACT_DIR/summary.json"

if [ "$FAILED" -ne 0 ]; then
  exit 1
fi
