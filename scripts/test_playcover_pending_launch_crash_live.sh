#!/bin/bash
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"
GLOBAL_STATE_GUARD="$SCRIPT_DIR/test_playcover_global_state_guard.sh"
EVIDENCE_ROOT="${IOS_USE_PLAYCOVER_CRASH_EVIDENCE_ROOT:-/tmp/ios-use-playcover-launch-recovery-evidence}"
CRASH_ENV="IOS_USE_PLAYCOVER_LAUNCH_CRASH_CUT"
CRASH_EXIT=86
START_GIT_HEAD=""
INITIAL_REPOSITORY_STATUS=""
RUN_DIR=""
BUILD_ROOT=""
SOURCE_ROOT=""
DEBUG_CLI=""
RUNTIME_PROBE=""
FIXTURE_APP=""
TEST_HOME=""
BUNDLE_ID=""
EXECUTABLE_NAME=""
SLOT_ROOT=""
SUCCESS=0

usage() {
  cat <<'USAGE'
Usage: scripts/test_playcover_pending_launch_crash_live.sh --live

Builds committed HEAD in scratch and exercises the two durable Mac launch
crash boundaries. The gate proves phase-free launching.json recovery after
NSWorkspace submission and exact cleanup after driver.lock becomes durable.
It requires the documented disposable-account acknowledgement and an
unlocked launch-capable GUI session.
USAGE
}

config_fail() {
  echo "[playcover-launch-recovery] EX_CONFIG: $*" >&2
  exit 78
}

fail_gate() {
  echo "[playcover-launch-recovery] FAIL: $*" >&2
  if [[ -n "$RUN_DIR" ]]; then
    echo "[playcover-launch-recovery] Evidence retained at $RUN_DIR" >&2
  fi
  exit 1
}

repository_status() {
  git -C "$ROOT_DIR" status \
    --porcelain=v1 \
    --untracked-files=all \
    --ignore-submodules=none
}

assert_clean_committed_head() {
  START_GIT_HEAD="$(git -C "$ROOT_DIR" rev-parse --verify HEAD)" ||
    config_fail "could not resolve current HEAD"
  if [[
    ! "$START_GIT_HEAD" =~ ^[0-9a-f]{40}$ &&
    ! "$START_GIT_HEAD" =~ ^[0-9a-f]{64}$
  ]]; then
    config_fail "current HEAD is not an exact Git object ID"
  fi
  INITIAL_REPOSITORY_STATUS="$(repository_status)" ||
    config_fail "could not inspect repository status"
  if [[ -n "$INITIAL_REPOSITORY_STATUS" ]]; then
    printf '%s\n' "$INITIAL_REPOSITORY_STATUS" >&2
    config_fail "a clean committed checkout is required"
  fi
}

assert_repository_unchanged() {
  local end_head
  local end_status
  end_head="$(git -C "$ROOT_DIR" rev-parse --verify HEAD)" ||
    fail_gate "could not resolve HEAD after the gate"
  end_status="$(repository_status)" ||
    fail_gate "could not inspect repository status after the gate"
  [[ "$end_head" == "$START_GIT_HEAD" &&
     "$end_status" == "$INITIAL_REPOSITORY_STATUS" ]] ||
    fail_gate "checkout changed during the gate"
}

canonical_directory() {
  local path="$1"
  [[ -d "$path" && ! -L "$path" ]] || return 1
  (cd "$path" && pwd -P)
}

assert_owner_only_directory() {
  local path="$1"
  local label="$2"
  if [[
    ! -d "$path" ||
    -L "$path" ||
    "$(/usr/bin/stat -f '%u' "$path")" != "$(/usr/bin/id -u)" ||
    "$(/usr/bin/stat -f '%Lp' "$path")" != "700"
  ]]; then
    config_fail "$label is not an owner-only directory: $path"
  fi
}

assert_outside_checkout() {
  local canonical
  canonical="$(canonical_directory "$1")" ||
    config_fail "$2 cannot be canonicalized"
  case "$canonical" in
    "$ROOT_DIR"|"$ROOT_DIR"/*)
      config_fail "$2 must stay outside the checkout: $canonical"
      ;;
  esac
}

home_descriptor_path() {
  local canonical
  local home_id
  canonical="$(canonical_directory "$1")" || return 1
  home_id="$({ printf '%s' "$canonical"; } |
    /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')"
  [[ "$home_id" =~ ^[0-9a-f]{64}$ ]] || return 1
  printf '%s/%s.json\n' "$PLAYCOVER_KNOWN_HOMES_ROOT" "$home_id"
}

remove_home_descriptor() {
  local descriptor
  descriptor="$(home_descriptor_path "$1")" || return 1
  [[ -e "$descriptor" || -L "$descriptor" ]] || return 0
  case "$descriptor" in
    "$PLAYCOVER_KNOWN_HOMES_ROOT"/[0-9a-f]*.json) ;;
    *) return 1 ;;
  esac
  [[ -f "$descriptor" && ! -L "$descriptor" &&
     "$(/usr/bin/stat -f '%u' "$descriptor")" == "$(/usr/bin/id -u)" ]] ||
    return 1
  /bin/rm -f -- "$descriptor"
}

cli_env() {
  local home="$1"
  shift
  env "IOS_USE_HOME=$home" "$@"
}

try_stop() {
  if [[ -n "$TEST_HOME" && -d "$TEST_HOME" && -x "$DEBUG_CLI" ]]; then
    cli_env "$TEST_HOME" "$DEBUG_CLI" --json stop >/dev/null 2>&1 || true
  fi
}

cleanup() {
  local exit_status=$?
  try_stop
  if [[ "$SUCCESS" -eq 1 ]]; then
    if [[ -n "$TEST_HOME" && -d "$TEST_HOME" ]]; then
      remove_home_descriptor "$TEST_HOME" || exit_status=1
      case "$(canonical_directory "$TEST_HOME" 2>/dev/null || true)" in
        /private/tmp/ios-use-launch-recovery-home.*)
          /bin/rm -rf -- "$TEST_HOME"
          ;;
        *) exit_status=1 ;;
      esac
    fi
    if [[ -n "$BUILD_ROOT" && -d "$BUILD_ROOT" ]]; then
      case "$(canonical_directory "$BUILD_ROOT" 2>/dev/null || true)" in
        /private/tmp/ios-use-launch-recovery-build.*)
          /bin/rm -rf -- "$BUILD_ROOT"
          ;;
        *) exit_status=1 ;;
      esac
    fi
  else
    [[ -z "$TEST_HOME" ]] ||
      echo "[playcover-launch-recovery] Home retained: $TEST_HOME" >&2
    [[ -z "$BUILD_ROOT" ]] ||
      echo "[playcover-launch-recovery] Build retained: $BUILD_ROOT" >&2
  fi
  exit "$exit_status"
}
trap cleanup EXIT

if [[ $# -ne 1 ]]; then
  usage >&2
  exit 64
fi
case "$1" in
  --live) ;;
  --help|-h)
    usage
    exit 0
    ;;
  *)
    usage >&2
    exit 64
    ;;
esac

if [[ ! -f "$GLOBAL_STATE_GUARD" || -L "$GLOBAL_STATE_GUARD" ]]; then
  config_fail "the account-global PlayCover safety guard is unavailable"
fi
# shellcheck source=scripts/test_playcover_global_state_guard.sh
source "$GLOBAL_STATE_GUARD"
playcover_require_disposable_account_contract "playcover-launch-recovery"

if [[ "$(uname -s)" != "Darwin" || "$(uname -m)" != "arm64" ]]; then
  config_fail "Apple-silicon macOS is required"
fi
for tool in git jq mktemp plutil rg shasum swift swiftc tar xcodegen xcrun; do
  command -v "$tool" >/dev/null 2>&1 ||
    config_fail "missing required tool: $tool"
done
if [[
  "${IOS_USE_PLAYCOVER_FIXTURE_APP+x}" == "x" ||
  "${IOS_USE_FIXTURE_CONFIGURATION+x}" == "x" ||
  "${IOS_USE_FIXTURE_SDK+x}" == "x"
]]; then
  config_fail "fixture overrides are forbidden for this committed-HEAD gate"
fi

assert_clean_committed_head

[[ "$EVIDENCE_ROOT" == /* ]] ||
  config_fail "evidence root must be absolute"
if [[ ! -e "$EVIDENCE_ROOT" ]]; then
  /bin/mkdir -p "$EVIDENCE_ROOT" ||
    config_fail "could not create evidence root"
  /bin/chmod 700 "$EVIDENCE_ROOT" ||
    config_fail "could not secure evidence root"
fi
assert_owner_only_directory "$EVIDENCE_ROOT" "evidence root"
assert_outside_checkout "$EVIDENCE_ROOT" "evidence root"
RUN_DIR="$(mktemp -d "$EVIDENCE_ROOT/run.XXXXXX")" ||
  config_fail "could not create evidence directory"
/bin/chmod 700 "$RUN_DIR"
printf '%s\n' "$START_GIT_HEAD" >"$RUN_DIR/git-head"

console_session_state="$(/usr/sbin/ioreg -n Root -d1)"
if rg -q '"CGSSessionScreenIsLocked"=(Yes|true|1)' \
    <<<"$console_session_state"; then
  config_fail "the macOS console session is locked"
fi

BUILD_ROOT="$(mktemp -d /tmp/ios-use-launch-recovery-build.XXXXXX)" ||
  config_fail "could not create build root"
TEST_HOME="$(mktemp -d /tmp/ios-use-launch-recovery-home.XXXXXX)" ||
  config_fail "could not create temporary IOS_USE_HOME"
/bin/chmod 700 "$BUILD_ROOT" "$TEST_HOME"
assert_outside_checkout "$BUILD_ROOT" "build root"

SOURCE_ROOT="$BUILD_ROOT/source-head"
runtime_framework="$BUILD_ROOT/runtime/IOSUsePlayRuntime.framework"
fixture_derived="$BUILD_ROOT/fixture-derived"
FIXTURE_APP="$fixture_derived/Build/Products/Release-iphoneos/IOSUsePlayFixture.app"
cli_dir="$BUILD_ROOT/bin"
DEBUG_CLI="$cli_dir/ios-use"
RUNTIME_PROBE="$BUILD_ROOT/runtime-socket-probe"
/bin/mkdir -m 700 "$SOURCE_ROOT" "$cli_dir"
/bin/mkdir -m 700 -p "$cli_dir/.ios-use/playcover"

git -C "$ROOT_DIR" archive "$START_GIT_HEAD" |
  /usr/bin/tar -x -C "$SOURCE_ROOT" ||
  fail_gate "could not materialize committed HEAD"

echo "[playcover-launch-recovery] Building committed HEAD..." >&2
bash "$SOURCE_ROOT/scripts/build_playcover_runtime.sh" \
  --output "$runtime_framework" --replace \
  >"$RUN_DIR/build-runtime.stdout" \
  2>"$RUN_DIR/build-runtime.stderr" ||
  fail_gate "Runtime build failed"
swift build \
  --package-path "$SOURCE_ROOT/swift-cli" \
  --scratch-path "$BUILD_ROOT/swiftpm" \
  --configuration debug \
  --product ios-use-swift \
  >"$RUN_DIR/build-cli.stdout" \
  2>"$RUN_DIR/build-cli.stderr" ||
  fail_gate "debug CLI build failed"
cli_bin_dir="$(swift build \
  --package-path "$SOURCE_ROOT/swift-cli" \
  --scratch-path "$BUILD_ROOT/swiftpm" \
  --configuration debug \
  --show-bin-path)" || fail_gate "could not resolve CLI output"
/bin/cp "$cli_bin_dir/ios-use-swift" "$DEBUG_CLI"
/bin/chmod 700 "$DEBUG_CLI"

bash "$SOURCE_ROOT/playcover-fixtures/build.sh" \
  --configuration Release \
  --sdk iphoneos \
  --derived-data-path "$fixture_derived" \
  >"$RUN_DIR/build-fixture.stdout" \
  2>"$RUN_DIR/build-fixture.stderr" ||
  fail_gate "fixture build failed"

xcrun swiftc \
  -module-cache-path "$BUILD_ROOT/probe-module-cache" \
  "$SOURCE_ROOT/playcover-fixtures/runtime_socket_probe.swift" \
  -o "$RUNTIME_PROBE" \
  >"$RUN_DIR/build-probe.stdout" \
  2>"$RUN_DIR/build-probe.stderr" ||
  fail_gate "Runtime probe build failed"

frida_source="${IOS_USE_PLAYCOVER_FRIDA_ENGINE:-$PLAYCOVER_ACCOUNT_HOME/.local/bin/.ios-use/playcover/IOSUseFridaEngine.framework}"
if [[
  ! -x "$DEBUG_CLI" ||
  ! -x "$RUNTIME_PROBE" ||
  ! -x "$runtime_framework/IOSUsePlayRuntime" ||
  ! -x "$frida_source/IOSUseFridaEngine" ||
  ! -d "$FIXTURE_APP" ||
  -L "$FIXTURE_APP"
]]; then
  fail_gate "scratch outputs or pinned Frida Engine are incomplete"
fi
/usr/bin/ditto "$runtime_framework" \
  "$cli_dir/.ios-use/playcover/IOSUsePlayRuntime.framework"
/usr/bin/ditto "$frida_source" \
  "$cli_dir/.ios-use/playcover/IOSUseFridaEngine.framework"

BUNDLE_ID="$(plutil -extract CFBundleIdentifier raw -o - \
  "$FIXTURE_APP/Info.plist")" || fail_gate "fixture Bundle ID is unavailable"
EXECUTABLE_NAME="$(plutil -extract CFBundleExecutable raw -o - \
  "$FIXTURE_APP/Info.plist")" || fail_gate "fixture executable is unavailable"
SLOT_ROOT="$PLAYCOVER_APPS_ROOT/$BUNDLE_ID"

assert_machine_success() {
  local file="$1"
  local command="$2"
  jq -e --arg command "$command" '
    .ok == true and .command == $command
  ' "$file" >/dev/null ||
    fail_gate "$file is not a successful $command envelope"
}

assert_private_file() {
  local path="$1"
  local label="$2"
  if [[
    ! -f "$path" ||
    -L "$path" ||
    "$(/usr/bin/stat -f '%u' "$path")" != "$(/usr/bin/id -u)" ||
    "$(/usr/bin/stat -f '%Lp' "$path")" != "600" ||
    "$(/usr/bin/stat -f '%l' "$path")" != "1"
  ]]; then
    fail_gate "$label is not an owner-only single-link file"
  fi
}

assert_launching_record() {
  local case_name="$1"
  local record="$TEST_HOME/mac/launching.json"
  assert_private_file "$record" "$case_name launching.json"
  jq -e \
    --arg bundle "$BUNDLE_ID" \
    --arg executable "$EXECUTABLE_NAME" '
      (keys | sort) == [
        "bundleIdentifier", "executableRelativePath",
        "runtimeSocketPath", "sessionID", "submittedAt"
      ] and
      .bundleIdentifier == $bundle and
      .executableRelativePath == $executable and
      (.sessionID | test(
        "^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"
      )) and
      (.runtimeSocketPath | type) == "string" and
      (.runtimeSocketPath | length) > 0 and
      (.submittedAt | numbers) > 0
    ' "$record" >/dev/null ||
    fail_gate "$case_name launching.json is not the exact phase-free record"
  /bin/cp "$record" "$RUN_DIR/$case_name.launching.json"
}

assert_no_launching() {
  [[ ! -e "$TEST_HOME/mac/launching.json" &&
     ! -L "$TEST_HOME/mac/launching.json" ]] ||
    fail_gate "$1 retained launching.json"
}

assert_driver_lock() {
  assert_private_file "$TEST_HOME/state/driver.lock" "$1 driver.lock"
}

assert_no_driver_lock() {
  [[ ! -e "$TEST_HOME/state/driver.lock" &&
     ! -L "$TEST_HOME/state/driver.lock" ]] ||
    fail_gate "$1 retained driver.lock"
}

capture_status() {
  local name="$1"
  cli_env "$TEST_HOME" "$DEBUG_CLI" --json status \
    >"$RUN_DIR/$name.status.json" \
    2>"$RUN_DIR/$name.status.stderr" ||
    fail_gate "$name status failed"
  assert_machine_success "$RUN_DIR/$name.status.json" status
}

capture_healthy_status() {
  local name="$1"
  local attempt
  for attempt in $(seq 1 60); do
    if cli_env "$TEST_HOME" "$DEBUG_CLI" --json status \
        >"$RUN_DIR/$name.status.json" \
        2>"$RUN_DIR/$name.status.stderr" &&
      jq -e '
        .ok == true and
        .command == "status" and
        .data.driver.status == "healthy" and
        .data.driver.runtime.identityVerified == true and
        (.data.driver.macInstallRevision |
          test("^[0-9a-f]{64}$"))
      ' "$RUN_DIR/$name.status.json" >/dev/null; then
      return 0
    fi
    sleep 0.1
  done
  fail_gate "$name did not converge to a healthy Runtime"
}

assert_fixed_slot() {
  local name="$1"
  local status="$RUN_DIR/$name.status.json"
  local app_path
  local executable_path
  local revision
  local visible_count
  app_path="$(jq -er '.data.driver.macAppPath' "$status")"
  executable_path="$(jq -er '.data.driver.macExecutablePath' "$status")"
  revision="$(jq -er '.data.driver.macInstallRevision' "$status")"
  [[ "$app_path" == "$SLOT_ROOT/App.app" ]] ||
    fail_gate "$name escaped the canonical fixed Bundle slot: $app_path"
  [[ ! -L "$SLOT_ROOT" && ! -L "$app_path" ]] ||
    fail_gate "$name launched a symlink or facade"
  [[ "$executable_path" == "$app_path/$EXECUTABLE_NAME" &&
     -x "$executable_path" ]] ||
    fail_gate "$name launched the wrong executable"
  assert_private_file "$SLOT_ROOT/slot.json" "$name slot.json"
  jq -e \
    --arg bundle "$BUNDLE_ID" \
    --arg executable "$EXECUTABLE_NAME" \
    --arg revision "$revision" '
      keys == [
        "bundleIdentifier", "executableRelativePath", "installRevision",
        "signingCertificateSHA256", "sourceContentHash"
      ] and
      .bundleIdentifier == $bundle and
      .executableRelativePath == $executable and
      .installRevision == $revision and
      (.sourceContentHash | test("^[0-9a-f]{64}$")) and
      (.signingCertificateSHA256 | test("^[0-9A-F]{64}$"))
    ' "$SLOT_ROOT/slot.json" >/dev/null ||
    fail_gate "$name slot metadata is not exact"
  visible_count="$(find "$SLOT_ROOT" -mindepth 1 -maxdepth 1 \
    ! -name '.*' -print | wc -l | tr -d ' ')"
  [[ "$visible_count" == "2" ]] ||
    fail_gate "$name slot does not contain exactly one App and slot.json"
}

capture_process_identity() {
  local name="$1"
  local pid="$2"
  local executable="$3"
  "$RUNTIME_PROBE" "$pid" process-identity \
    >"$RUN_DIR/$name.process.json" \
    2>"$RUN_DIR/$name.process.stderr" ||
    fail_gate "$name process probe failed"
  jq -e --argjson pid "$pid" --arg executable "$executable" '
    .alive == true and
    .pid == $pid and
    .processBirthMicroseconds > 0 and
    .executablePath == $executable
  ' "$RUN_DIR/$name.process.json" >/dev/null ||
    fail_gate "$name exact process identity is not live"
}

wait_process_gone() {
  local name="$1"
  local pid="$2"
  local birth="$3"
  local output="$RUN_DIR/$name.process-after-stop.json"
  local deadline=$((SECONDS + 10))
  while (( SECONDS < deadline )); do
    "$RUNTIME_PROBE" "$pid" process-identity >"$output" 2>/dev/null || true
    if jq -e --argjson birth "$birth" '
      .alive == false or .processBirthMicroseconds != $birth
    ' "$output" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.05
  done
  fail_gate "$name exact process remained live after stop"
}

stop_and_verify() {
  local name="$1"
  local pid="$2"
  local birth="$3"
  cli_env "$TEST_HOME" "$DEBUG_CLI" --json stop \
    >"$RUN_DIR/$name.stop.json" \
    2>"$RUN_DIR/$name.stop.stderr" ||
    fail_gate "$name stop failed"
  assert_machine_success "$RUN_DIR/$name.stop.json" stop
  assert_no_driver_lock "$name"
  assert_no_launching "$name"
  wait_process_gone "$name" "$pid" "$birth"
}

run_crash_start() {
  local name="$1"
  local cut="$2"
  set +e
  cli_env "$TEST_HOME" "$CRASH_ENV=$cut" \
    "$DEBUG_CLI" --json start --mac --timeout 30s \
    >"$RUN_DIR/$name.start.json" \
    2>"$RUN_DIR/$name.start.stderr"
  local exit_status=$?
  set -e
  [[ "$exit_status" -eq "$CRASH_EXIT" ]] ||
    fail_gate "$name exited $exit_status instead of $CRASH_EXIT"
}

echo "[playcover-launch-recovery] Baseline fixed-slot install..." >&2
cli_env "$TEST_HOME" "$DEBUG_CLI" --json start --mac \
  --app "$FIXTURE_APP" --timeout 30s \
  >"$RUN_DIR/baseline.start.json" \
  2>"$RUN_DIR/baseline.start.stderr" ||
  fail_gate "baseline start failed"
assert_machine_success "$RUN_DIR/baseline.start.json" start
assert_driver_lock baseline
assert_no_launching baseline
capture_healthy_status baseline
assert_fixed_slot baseline
baseline_pid="$(jq -er '.data.driver.runnerPid' \
  "$RUN_DIR/baseline.status.json")"
baseline_executable="$(jq -er '.data.driver.macExecutablePath' \
  "$RUN_DIR/baseline.status.json")"
capture_process_identity baseline "$baseline_pid" "$baseline_executable"
baseline_birth="$(jq -er '.processBirthMicroseconds' \
  "$RUN_DIR/baseline.process.json")"
stop_and_verify baseline "$baseline_pid" "$baseline_birth"

echo "[playcover-launch-recovery] afterOpenReturned..." >&2
run_crash_start afterOpenReturned afterOpenReturned
assert_launching_record afterOpenReturned
assert_no_driver_lock afterOpenReturned
capture_status afterOpenReturned
open_session="$(jq -er '.sessionID' \
  "$RUN_DIR/afterOpenReturned.launching.json")"
jq -e \
  --arg bundle "$BUNDLE_ID" \
  --arg session "$open_session" '
    .data.driver.status == "unresolvedOpen" and
    .data.driver.bundleId == $bundle and
    .data.driver.sessionIdentifier == $session
  ' "$RUN_DIR/afterOpenReturned.status.json" >/dev/null ||
  fail_gate "afterOpenReturned status did not expose unresolvedOpen"

recovered=0
for attempt in $(seq 1 100); do
  printf -v attempt_name 'afterOpenReturned.recover-%03d' "$attempt"
  set +e
  cli_env "$TEST_HOME" "$DEBUG_CLI" --json start --mac \
    --timeout 5s \
    >"$RUN_DIR/$attempt_name.stdout" \
    2>"$RUN_DIR/$attempt_name.stderr"
  attempt_status=$?
  set -e
  if [[ "$attempt_status" -eq 0 ]]; then
    assert_machine_success "$RUN_DIR/$attempt_name.stdout" start
    recovered=1
    break
  fi
  jq -e '
    .ok == false and
    .command == "start" and
    .error.category == "session" and
    .error.code == "mac_launch_recovery_unresolved" and
    .error.phase == "mac_launch_recovery" and
    .error.retryable == true and
    .error.fatal == false and
    .error.mutationMayHaveApplied == false
  ' "$RUN_DIR/$attempt_name.stderr" >/dev/null ||
    fail_gate "afterOpenReturned recovery failed with an unexpected error"
  sleep 0.1
done
[[ "$recovered" -eq 1 ]] ||
  fail_gate "afterOpenReturned did not recover the authenticated launch"
assert_driver_lock afterOpenReturned.recovered
assert_no_launching afterOpenReturned.recovered
capture_healthy_status afterOpenReturned.recovered
assert_fixed_slot afterOpenReturned.recovered
jq -e --arg session "$open_session" '
  .data.driver.sessionIdentifier == $session
' "$RUN_DIR/afterOpenReturned.recovered.status.json" >/dev/null ||
  fail_gate "afterOpenReturned recovery did not adopt the submitted session"
open_pid="$(jq -er '.data.driver.runnerPid' \
  "$RUN_DIR/afterOpenReturned.recovered.status.json")"
open_executable="$(jq -er '.data.driver.macExecutablePath' \
  "$RUN_DIR/afterOpenReturned.recovered.status.json")"
capture_process_identity afterOpenReturned.recovered \
  "$open_pid" "$open_executable"
open_birth="$(jq -er '.processBirthMicroseconds' \
  "$RUN_DIR/afterOpenReturned.recovered.process.json")"
stop_and_verify afterOpenReturned.recovered "$open_pid" "$open_birth"

echo "[playcover-launch-recovery] afterDriverLockDurable..." >&2
run_crash_start afterDriverLockDurable afterDriverLockDurable
assert_launching_record afterDriverLockDurable
assert_driver_lock afterDriverLockDurable
driver_session="$(jq -er '.sessionID' \
  "$RUN_DIR/afterDriverLockDurable.launching.json")"
launching_sha_before="$(shasum -a 256 \
  "$TEST_HOME/mac/launching.json" | awk '{print $1}')"
lock_sha_before="$(shasum -a 256 \
  "$TEST_HOME/state/driver.lock" | awk '{print $1}')"
capture_healthy_status afterDriverLockDurable
assert_fixed_slot afterDriverLockDurable
jq -e --arg session "$driver_session" '
  .data.driver.sessionIdentifier == $session
' "$RUN_DIR/afterDriverLockDurable.status.json" >/dev/null ||
  fail_gate "driver.lock and launching.json disagree on session identity"
driver_pid="$(jq -er '.data.driver.runnerPid' \
  "$RUN_DIR/afterDriverLockDurable.status.json")"
driver_executable="$(jq -er '.data.driver.macExecutablePath' \
  "$RUN_DIR/afterDriverLockDurable.status.json")"
capture_process_identity afterDriverLockDurable \
  "$driver_pid" "$driver_executable"
driver_birth="$(jq -er '.processBirthMicroseconds' \
  "$RUN_DIR/afterDriverLockDurable.process.json")"

set +e
cli_env "$TEST_HOME" "$DEBUG_CLI" --json start --mac \
  >"$RUN_DIR/afterDriverLockDurable.blocked-start.stdout" \
  2>"$RUN_DIR/afterDriverLockDurable.blocked-start.stderr"
blocked_status=$?
set -e
[[ "$blocked_status" -ne 0 ]] ||
  fail_gate "second start unexpectedly replaced the active session"
jq -e '
  .ok == false and
  .command == "start" and
  (.error.message | contains("Driver already started"))
' "$RUN_DIR/afterDriverLockDurable.blocked-start.stderr" >/dev/null ||
  fail_gate "second start did not return the active-driver error"
[[ "$launching_sha_before" == "$(shasum -a 256 \
     "$TEST_HOME/mac/launching.json" | awk '{print $1}')" &&
   "$lock_sha_before" == "$(shasum -a 256 \
     "$TEST_HOME/state/driver.lock" | awk '{print $1}')" ]] ||
  fail_gate "blocked start mutated the durable launch state"
stop_and_verify afterDriverLockDurable "$driver_pid" "$driver_birth"

echo "[playcover-launch-recovery] Final current-slot start..." >&2
cli_env "$TEST_HOME" "$DEBUG_CLI" --json start --mac \
  --timeout 30s \
  >"$RUN_DIR/final.start.json" \
  2>"$RUN_DIR/final.start.stderr" ||
  fail_gate "final reuse start failed"
assert_machine_success "$RUN_DIR/final.start.json" start
capture_healthy_status final
assert_fixed_slot final
final_pid="$(jq -er '.data.driver.runnerPid' "$RUN_DIR/final.status.json")"
final_executable="$(jq -er '.data.driver.macExecutablePath' \
  "$RUN_DIR/final.status.json")"
capture_process_identity final "$final_pid" "$final_executable"
final_birth="$(jq -er '.processBirthMicroseconds' \
  "$RUN_DIR/final.process.json")"
stop_and_verify final "$final_pid" "$final_birth"

assert_repository_unchanged
jq -n \
  --arg head "$START_GIT_HEAD" \
  --arg bundleIdentifier "$BUNDLE_ID" '
    {
      schemaVersion: 1,
      gate: "playcover-launch-recovery",
      result: "pass",
      gitHEAD: $head,
      bundleIdentifier: $bundleIdentifier,
      crashCuts: ["afterOpenReturned", "afterDriverLockDurable"],
      phaseFreeLaunchingRecord: true,
      authenticatedOpenRecovery: true,
      exactStopAfterDriverLockCommit: true
    }
  ' >"$RUN_DIR/attestation.json"
/bin/chmod 600 "$RUN_DIR/attestation.json"
SUCCESS=1
echo "[playcover-launch-recovery] PASS"
echo "[playcover-launch-recovery] Evidence: $RUN_DIR"
