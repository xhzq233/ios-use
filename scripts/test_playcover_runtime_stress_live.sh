#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CLI="$ROOT_DIR/ios-use"
FIXTURE_APP="${IOS_USE_PLAYCOVER_FIXTURE_APP:-}"
EVIDENCE_ROOT="${IOS_USE_PLAYCOVER_EVIDENCE_ROOT:-$ROOT_DIR/.ios-use/live-evidence}"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
RUN_DIR="$EVIDENCE_ROOT/playcover-runtime-stress-v1/$RUN_ID"
SESSION_HOME=""
CANONICAL_SESSION_HOME=""
ARCHIVED_SESSION_HOME="$RUN_DIR/session-home"
MANIFEST="$RUN_DIR/manifest.tsv"
GATE_PASSED=0

config_fail() {
  echo "[playcover-runtime-stress] EX_CONFIG: $*" >&2
  exit 78
}

fail_gate() {
  echo "[playcover-runtime-stress] FAIL: $*" >&2
  exit 1
}

mkdir -p "$RUN_DIR"
printf 'schema\tcase\tcommand\tstdout\tstderr\n' >"$MANIFEST"

if [[ "$(uname -s)" != "Darwin" || "$(uname -m)" != "arm64" ]]; then
  config_fail "Apple-silicon macOS is required"
fi
for required in jq xcrun; do
  command -v "$required" >/dev/null 2>&1 ||
    config_fail "$required is required"
done
if [[ ! -x "$CLI" ]]; then
  config_fail "workspace CLI is not executable"
fi
if [[ ! -f "$ROOT_DIR/playcover-fixtures/runtime_socket_probe.swift" ]]; then
  config_fail "Runtime socket protocol probe is unavailable"
fi

SESSION_HOME="$(mktemp -d /tmp/iups.XXXXXX)"
if [[
  "$SESSION_HOME" != /tmp/iups.* ||
  ! -d "$SESSION_HOME" ||
  -L "$SESSION_HOME"
]]; then
  config_fail "could not create a safe isolated IOS_USE_HOME"
fi
CANONICAL_SESSION_HOME="$(cd "$SESSION_HOME" && pwd -P)"
printf '%s\n' "$SESSION_HOME" >"$RUN_DIR/session-home-origin"

archive_and_remove_session_home() {
  if [[ ! -d "$SESSION_HOME" ]]; then
    return 0
  fi
  if [[ -e "$ARCHIVED_SESSION_HOME" ]]; then
    fail_gate "refusing to replace archived session evidence"
  fi
  /usr/bin/ditto "$SESSION_HOME" "$ARCHIVED_SESSION_HOME"
  if [[
    "$SESSION_HOME" != /tmp/iups.* ||
    -L "$SESSION_HOME"
  ]]; then
    fail_gate "refusing to remove unexpected IOS_USE_HOME"
  fi
  /bin/rm -rf -- "$SESSION_HOME"
}

cleanup() {
  local exit_code=$?
  trap - EXIT
  set +e
  if [[ -d "$SESSION_HOME" && -x "$CLI" ]]; then
    IOS_USE_HOME="$SESSION_HOME" "$CLI" stop \
      >"$RUN_DIR/cleanup-stop.stdout" \
      2>"$RUN_DIR/cleanup-stop.stderr" || true
  fi
  if [[ -d "$SESSION_HOME" ]]; then
    archive_and_remove_session_home || exit_code=1
  fi
  if [[ "$GATE_PASSED" != "1" || "$exit_code" -ne 0 ]]; then
    echo \
      "[playcover-runtime-stress] Evidence retained for the failed gate." \
      >&2
  fi
  exit "$exit_code"
}
trap cleanup EXIT

record_command() {
  local case_name="$1"
  local stdout_file="$2"
  local stderr_file="$3"
  shift 3
  local command_text=""
  local argument
  for argument in "$@"; do
    local quoted
    printf -v quoted '%q' "$argument"
    command_text+="${command_text:+ }$quoted"
  done
  printf '1\t%s\t%s\t%s\t%s\n' \
    "$case_name" \
    "$command_text" \
    "$stdout_file" \
    "$stderr_file" >>"$MANIFEST"
}

run_cli() {
  local case_name="$1"
  shift
  local stdout_file="$RUN_DIR/${case_name}.stdout"
  local stderr_file="$RUN_DIR/${case_name}.stderr"
  record_command \
    "$case_name" \
    "$stdout_file" \
    "$stderr_file" \
    "$CLI" "$@"
  echo "[playcover-runtime-stress] RUN $case_name" >&2
  if ! IOS_USE_HOME="$SESSION_HOME" "$CLI" "$@" \
      >"$stdout_file" 2>"$stderr_file"; then
    fail_gate "$case_name"
  fi
}

assert_healthy_status() {
  local case_name="$1"
  if ! jq -e '
      .data.driver.status == "healthy" and
      .data.driver.runtime.status == "healthy" and
      .data.driver.runtime.identityVerified == true and
      .data.driver.bundleId == "com.iosuse.playfixture" and
      .data.driver.runtime.logicalWidth == 430 and
      .data.driver.runtime.logicalHeight == 932 and
      .data.driver.runtime.nativeWidth == 1290 and
      .data.driver.runtime.nativeHeight == 2796 and
      .data.driver.runtime.scale == 3
    ' "$RUN_DIR/${case_name}.stdout" >/dev/null; then
    fail_gate "$case_name did not prove an exact healthy fixture session"
  fi
}

assert_stopped() {
  local case_name="$1"
  if ! jq -e \
      '.data.driver.status == "notRunning"' \
      "$RUN_DIR/${case_name}.stdout" >/dev/null; then
    fail_gate "$case_name did not prove that the session lock was cleared"
  fi
}

assert_lock_matches_status() {
  local status_case="$1"
  local lock="$SESSION_HOME/state/driver.lock"
  if [[ ! -f "$lock" || -L "$lock" ]]; then
    fail_gate "$status_case has no private regular driver.lock"
  fi
  if ! jq -e \
      --arg rawHome "$SESSION_HOME" \
      --arg canonicalHome "$CANONICAL_SESSION_HOME" \
      --slurpfile status "$RUN_DIR/${status_case}.stdout" '
      . as $lock |
      $lock.deviceType == "playcover" and
      $lock.startMode == "playcover" and
      $lock.bundleId == "com.iosuse.playfixture" and
      ($lock.sessionIdentifier |
        test("^[0-9A-Fa-f-]{36}$")) and
      $lock.runnerPid == $status[0].data.driver.runnerPid and
      $lock.runnerPid > 1 and
      $lock.playcoverRuntimeSocketPath ==
        $status[0].data.driver.playcoverRuntimeSocketPath and
      $lock.playcoverExecutablePath ==
        $status[0].data.driver.playcoverExecutablePath and
      (
        ($lock.playcoverAppPath |
          startswith($rawHome + "/playcover/prepared/")) or
        ($lock.playcoverAppPath |
          startswith($canonicalHome + "/playcover/prepared/"))
      ) and
      ($lock.playcoverExecutablePath |
        startswith($lock.playcoverAppPath + "/")) and
      (
        ($lock.playcoverRuntimeSocketPath |
          startswith($rawHome + "/playcover/run/s-")) or
        ($lock.playcoverRuntimeSocketPath |
          startswith($canonicalHome + "/playcover/run/s-"))
      ) and
      ($lock.playcoverRuntimeSocketPath |
        endswith(".sock"))
    ' "$lock" >/dev/null; then
    fail_gate "$status_case driver.lock does not match the live exact identity"
  fi
}

if [[ -z "$FIXTURE_APP" ]]; then
  FIXTURE_APP="$ROOT_DIR/playcover-fixtures/.build/DerivedData/Build/Products/Release-iphoneos/IOSUsePlayFixture.app"
fi
if [[ ! -d "$FIXTURE_APP" ]]; then
  bash "$ROOT_DIR/playcover-fixtures/build.sh" \
    >"$RUN_DIR/build-fixture.stdout" \
    2>"$RUN_DIR/build-fixture.stderr" ||
    fail_gate "fixture build"
fi
if [[ ! -d "$FIXTURE_APP" || ! -f "$FIXTURE_APP/Info.plist" ]]; then
  config_fail "fixture App is unavailable"
fi

run_cli protocol_start start --playcover --app "$FIXTURE_APP"
run_cli protocol_status status --json
assert_healthy_status protocol_status
assert_lock_matches_status protocol_status
runtime_socket="$(
  jq -er '.data.driver.playcoverRuntimeSocketPath' \
    "$RUN_DIR/protocol_status.stdout"
)"
if [[
  ! -S "$runtime_socket" ||
  -L "$runtime_socket" ||
  "$(stat -f '%u' "$runtime_socket")" != "$(id -u)" ||
  "$(stat -f '%Lp' "$runtime_socket")" != "600"
]]; then
  fail_gate "Runtime socket is not the exact owner-only session socket"
fi

for probe_mode in oversized-frame malformed-json invalid-utf8; do
  probe_case="${probe_mode//-/_}"
  probe_stdout="$RUN_DIR/${probe_case}.stdout"
  probe_stderr="$RUN_DIR/${probe_case}.stderr"
  record_command \
    "$probe_case" \
    "$probe_stdout" \
    "$probe_stderr" \
    xcrun swift \
    "$ROOT_DIR/playcover-fixtures/runtime_socket_probe.swift" \
    "$runtime_socket" \
    "$probe_mode"
  if ! xcrun swift \
      "$ROOT_DIR/playcover-fixtures/runtime_socket_probe.swift" \
      "$runtime_socket" \
      "$probe_mode" \
      >"$probe_stdout" 2>"$probe_stderr"; then
    fail_gate "$probe_case"
  fi
  if ! jq -e \
      --arg mode "$probe_mode" '
      .schemaVersion == 1 and
      .mode == $mode and
      .runtimeListenerSurvived == true and
      (
        ($mode == "oversized-frame" and
          .runtimeErrorCode == "invalid_frame") or
        ($mode != "oversized-frame" and
          .runtimeErrorCode == "invalid_json")
      )
    ' "$probe_stdout" >/dev/null; then
    fail_gate "$probe_case did not return the exact bounded protocol error"
  fi
  run_cli "${probe_case}_status" status --json
  assert_healthy_status "${probe_case}_status"
done
run_cli protocol_stop stop
run_cli protocol_stopped status --json
assert_stopped protocol_stopped

run_cli endpoint_start start --playcover
run_cli endpoint_status status --json
assert_healthy_status endpoint_status
assert_lock_matches_status endpoint_status
endpoint_pid="$(
  jq -er '.data.driver.runnerPid' \
    "$RUN_DIR/endpoint_status.stdout"
)"
endpoint_socket="$(
  jq -er '.data.driver.playcoverRuntimeSocketPath' \
    "$RUN_DIR/endpoint_status.stdout"
)"
case "$endpoint_socket" in
  "$SESSION_HOME"/playcover/run/s-*.sock) ;;
  "$CANONICAL_SESSION_HOME"/playcover/run/s-*.sock) ;;
  *) fail_gate "endpoint-loss target escapes the isolated Runtime run directory" ;;
esac
if [[
  ! -S "$endpoint_socket" ||
  -L "$endpoint_socket" ||
  "$(stat -f '%u' "$endpoint_socket")" != "$(id -u)"
]]; then
  fail_gate "endpoint-loss target is not the exact owner socket"
fi
/bin/unlink "$endpoint_socket"
run_cli endpoint_unhealthy status --json
if ! jq -e \
    --argjson pid "$endpoint_pid" '
    .data.driver.status == "unhealthy" and
    .data.driver.runnerPid == $pid and
    .data.driver.runtime.status == "unhealthy" and
    .data.driver.runtime.identityVerified == false
  ' "$RUN_DIR/endpoint_unhealthy.stdout" >/dev/null; then
  fail_gate "Runtime endpoint loss was not classified as unhealthy"
fi
if ! /bin/kill -0 "$endpoint_pid" 2>/dev/null; then
  fail_gate "Runtime endpoint loss unexpectedly terminated the App"
fi
run_cli endpoint_stop stop
run_cli endpoint_stopped status --json
assert_stopped endpoint_stopped

run_cli crash_start start --playcover
run_cli crash_status status --json
assert_healthy_status crash_status
assert_lock_matches_status crash_status
crash_pid="$(
  jq -er '.data.driver.runnerPid' \
    "$RUN_DIR/crash_status.stdout"
)"
if [[
  ! "$crash_pid" =~ ^[0-9]+$ ||
  "$crash_pid" -le 1 ||
  "$crash_pid" != "$(
    jq -er '.runnerPid' "$SESSION_HOME/state/driver.lock"
  )"
]]; then
  fail_gate "App-crash PID is not bound to the exact driver.lock"
fi
/bin/kill -KILL "$crash_pid"
crash_observed=0
for attempt in $(seq 1 100); do
  run_cli crash_stale status --json
  if jq -e '
      .data.driver.status == "stale" and
      .data.driver.runtime.status == "stale" and
      .data.driver.runtime.identityVerified == false and
      (.data.driver.runtime.error |
        contains("recorded App process is not running"))
    ' "$RUN_DIR/crash_stale.stdout" >/dev/null; then
    crash_observed=1
    break
  fi
  sleep 0.05
done
if [[ "$crash_observed" != "1" ]]; then
  fail_gate "App crash was not classified as an exact stale session"
fi
run_cli crash_stop stop
run_cli crash_stopped status --json
assert_stopped crash_stopped

GATE_PASSED=1
archive_and_remove_session_home
trap - EXIT
echo \
  "[playcover-runtime-stress] PASS: bounded frames, endpoint loss, and App crash" \
  >&2
