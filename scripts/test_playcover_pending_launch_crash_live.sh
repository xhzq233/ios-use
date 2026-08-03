#!/bin/bash
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"
GLOBAL_STATE_GUARD="$SCRIPT_DIR/test_playcover_global_state_guard.sh"
EVIDENCE_ROOT="${IOS_USE_PLAYCOVER_CRASH_EVIDENCE_ROOT:-/tmp/ios-use-playcover-pending-crash-evidence}"
CRASH_ENV="IOS_USE_PLAYCOVER_LAUNCH_CRASH_CUT"
ALIAS_ENV="IOS_USE_PLAYCOVER_LAUNCH_CRASH_ALIAS_ROOT"
CRASH_EXIT=86
START_GIT_HEAD=""
INITIAL_REPOSITORY_STATUS=""
RUN_DIR=""
BUILD_ROOT=""
SOURCE_ROOT=""
DEBUG_CLI=""
RUNTIME_FRAMEWORK=""
RUNTIME_PROBE=""
FIXTURE_APP=""
TEST_HOME=""
SUCCESS=0

usage() {
  cat <<'USAGE'
Usage: scripts/test_playcover_pending_launch_crash_live.sh --live

Build committed HEAD in scratch, launch the public fixture, and crash the
debug CLI at the five durable launch boundaries. The gate verifies the exact
three-phase pending journal, fail-closed intent behavior, exact-owner stop,
and driver.lock handoff. It requires the documented disposable-account ACK,
the matching passwd Home, and an unlocked launch-capable GUI session.
USAGE
}

config_fail() {
  echo "[playcover-pending-crash] EX_CONFIG: $*" >&2
  exit 78
}

fail_gate() {
  echo "[playcover-pending-crash] FAIL: $*" >&2
  if [[ -n "$RUN_DIR" ]]; then
    echo "[playcover-pending-crash] Evidence retained at $RUN_DIR" >&2
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
  if [[
    "$end_head" != "$START_GIT_HEAD" ||
    "$end_status" != "$INITIAL_REPOSITORY_STATUS"
  ]]; then
    fail_gate "checkout changed during the gate"
  fi
}

canonical_directory() {
  local path="$1"
  [[ -d "$path" && ! -L "$path" ]] || return 1
  (cd "$path" && pwd -P)
}

canonical_file() {
  local path="$1"
  local directory
  [[ -f "$path" && ! -L "$path" ]] || return 1
  directory="$(cd "$(dirname "$path")" && pwd -P)" || return 1
  printf '%s/%s\n' "$directory" "$(basename "$path")"
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

require_test_home() {
  local home="$1"
  local canonical
  case "$home" in
    /tmp/iupc.*|/private/tmp/iupc.*) ;;
    *) return 1 ;;
  esac
  canonical="$(canonical_directory "$home")" || return 1
  case "$canonical" in
    /private/tmp/iupc.*) ;;
    *) return 1 ;;
  esac
  [[
    "$(/usr/bin/stat -f '%u' "$home")" == "$(/usr/bin/id -u)" &&
    "$(/usr/bin/stat -f '%Lp' "$home")" == "700"
  ]]
}

require_build_root() {
  local canonical
  case "$BUILD_ROOT" in
    /tmp/ios-use-playcover-pending-crash-build.*|\
    /private/tmp/ios-use-playcover-pending-crash-build.*) ;;
    *) return 1 ;;
  esac
  canonical="$(canonical_directory "$BUILD_ROOT")" || return 1
  case "$canonical" in
    /private/tmp/ios-use-playcover-pending-crash-build.*) ;;
    *) return 1 ;;
  esac
  [[
    "$(/usr/bin/stat -f '%u' "$BUILD_ROOT")" == "$(/usr/bin/id -u)" &&
    "$(/usr/bin/stat -f '%Lp' "$BUILD_ROOT")" == "700"
  ]]
}

home_descriptor_path() {
  local home="$1"
  local canonical
  local home_id
  canonical="$(canonical_directory "$home")" || return 1
  home_id="$({ printf '%s' "$canonical"; } | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')"
  [[ "$home_id" =~ ^[0-9a-f]{64}$ ]] || return 1
  printf '%s/%s.json\n' "$PLAYCOVER_KNOWN_HOMES_ROOT" "$home_id"
}

remove_home_descriptor() {
  local home="$1"
  local descriptor
  descriptor="$(home_descriptor_path "$home")" || return 1
  if [[ ! -e "$descriptor" && ! -L "$descriptor" ]]; then
    return 0
  fi
  case "$descriptor" in
    "$PLAYCOVER_KNOWN_HOMES_ROOT"/[0-9a-f]*.json) ;;
    *) return 1 ;;
  esac
  if [[
    ! -f "$descriptor" ||
    -L "$descriptor" ||
    "$(/usr/bin/stat -f '%u' "$descriptor")" != "$(/usr/bin/id -u)"
  ]]; then
    return 1
  fi
  /bin/rm -f -- "$descriptor"
}

cli_env() {
  local home="$1"
  shift
  env \
    "IOS_USE_HOME=$home" \
    "$ALIAS_ENV=$home/launch-alias" \
    "$@"
}

try_stop() {
  if [[ -n "$TEST_HOME" && -d "$TEST_HOME" && -x "$DEBUG_CLI" ]]; then
    cli_env "$TEST_HOME" "$DEBUG_CLI" --json stop >/dev/null 2>&1 || true
  fi
}

cleanup() {
  local exit_status=$?
  if [[ "$SUCCESS" -eq 1 ]]; then
    try_stop
    if [[ -n "$TEST_HOME" && -d "$TEST_HOME" ]]; then
      remove_home_descriptor "$TEST_HOME" || exit_status=1
      require_test_home "$TEST_HOME" || exit_status=1
      if [[ "$exit_status" -eq 0 ]]; then
        /bin/rm -rf -- "$TEST_HOME"
        TEST_HOME=""
      fi
    fi
    if [[ -n "$BUILD_ROOT" && -d "$BUILD_ROOT" ]]; then
      require_build_root || exit_status=1
      if [[ "$exit_status" -eq 0 ]]; then
        /bin/rm -rf -- "$BUILD_ROOT"
        BUILD_ROOT=""
      fi
    fi
  else
    [[ -z "$TEST_HOME" ]] ||
      echo "[playcover-pending-crash] Home retained: $TEST_HOME" >&2
    [[ -z "$BUILD_ROOT" ]] ||
      echo "[playcover-pending-crash] Build retained: $BUILD_ROOT" >&2
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
playcover_require_disposable_account_contract "playcover-pending-crash"

if [[ "$(uname -s)" != "Darwin" || "$(uname -m)" != "arm64" ]]; then
  config_fail "Apple-silicon macOS is required"
fi
for tool in git jq mktemp shasum swift swiftc tar xcrun xcodegen; do
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

if [[ "$EVIDENCE_ROOT" != /* ]]; then
  config_fail "evidence root must be absolute"
fi
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

BUILD_ROOT="$(mktemp -d /tmp/ios-use-playcover-pending-crash-build.XXXXXX)" ||
  config_fail "could not create build root"
/bin/chmod 700 "$BUILD_ROOT"
require_build_root || config_fail "build root failed safety checks"
assert_outside_checkout "$BUILD_ROOT" "build root"

SOURCE_ROOT="$BUILD_ROOT/source-head"
RUNTIME_FRAMEWORK="$BUILD_ROOT/runtime/IOSUsePlayRuntime.framework"
DEBUG_CLI="$BUILD_ROOT/ios-use"
RUNTIME_PROBE="$BUILD_ROOT/runtime-socket-probe"
fixture_derived="$BUILD_ROOT/fixture-derived"
FIXTURE_APP="$fixture_derived/Build/Products/Release-iphoneos/IOSUsePlayFixture.app"

/bin/mkdir -m 700 "$SOURCE_ROOT"
git -C "$ROOT_DIR" archive "$START_GIT_HEAD" |
  /usr/bin/tar -x -C "$SOURCE_ROOT" ||
  fail_gate "could not materialize committed HEAD"

echo "[playcover-pending-crash] Building committed HEAD..." >&2
bash "$SOURCE_ROOT/scripts/build_playcover_runtime.sh" \
  --output "$RUNTIME_FRAMEWORK" --replace \
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
  --show-bin-path)"
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

if [[
  ! -x "$DEBUG_CLI" ||
  ! -x "$RUNTIME_PROBE" ||
  ! -x "$RUNTIME_FRAMEWORK/IOSUsePlayRuntime" ||
  ! -d "$FIXTURE_APP" ||
  -L "$FIXTURE_APP"
]]; then
  fail_gate "scratch outputs are incomplete"
fi

TEST_HOME="$(mktemp -d /tmp/iupc.XXXXXX)" ||
  fail_gate "could not create temporary IOS_USE_HOME"
/bin/chmod 700 "$TEST_HOME"
require_test_home "$TEST_HOME" || fail_gate "unsafe temporary IOS_USE_HOME"
/bin/mkdir -m 700 "$TEST_HOME/mac"
/usr/bin/ditto \
  "$RUNTIME_FRAMEWORK" \
  "$TEST_HOME/mac/IOSUsePlayRuntime.framework"

assert_machine_success() {
  local file="$1"
  local command="$2"
  if ! jq -e \
      --arg command "$command" '
        .ok == true and
        .command == $command
      ' "$file" >/dev/null; then
    fail_gate "$file is not a successful $command envelope"
  fi
}

assert_pending_failure() {
  local file="$1"
  local command="$2"
  if ! jq -e \
      --arg command "$command" '
        .ok == false and
        .command == $command and
        .error.category == "session" and
        .error.code == "mac_pending_launch_unresolved" and
        .error.phase == "mac_pending_launch" and
        .error.retryable == false and
        .error.fatal == false and
        .error.mutationMayHaveApplied == false
      ' "$file" >/dev/null; then
    fail_gate "$file is not the typed unresolved-pending error"
  fi
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

assert_pending_phase() {
  local expected="$1"
  local case_name="$2"
  local journal="$TEST_HOME/mac/pending-launch.json"
  assert_private_file "$journal" "$case_name pending journal"
  if ! jq -e \
      --arg phase "$expected" '
        .phase == $phase and
        (keys | sort) == (
          if $phase == "intent" then
            ["aliasPath", "appPath", "bundleIdentifier", "executablePath",
             "generationKey", "phase", "runtimeSocketPath", "sessionID"]
          else
            ["aliasPath", "appPath", "bundleIdentifier", "executablePath",
             "generationKey", "owner", "phase", "runtimeSocketPath", "sessionID"]
          end | sort
        ) and
        ($phase == "intent" or (
          .owner.pid > 1 and
          (.owner.processBirthMicroseconds | strings | length) > 0 and
          (.owner.source == "workspaceCallback" or
           .owner.source == "authenticatedRuntime")
        ))
      ' "$journal" >/dev/null; then
    fail_gate "$case_name journal is not exact phase $expected"
  fi
  /bin/cp "$journal" "$RUN_DIR/$case_name.pending-launch.json"
  local generation
  local alias_path
  generation="$(jq -er '.generationKey' "$journal")"
  alias_path="$(jq -er '.aliasPath' "$journal")"
  [[ -d "$PLAYCOVER_GLOBAL_OBJECTS_ROOT/$generation" ]] ||
    fail_gate "$case_name generation is unavailable"
  case "$alias_path" in
    "$TEST_HOME"/launch-alias/*.app|/private"$TEST_HOME"/launch-alias/*.app) ;;
    *) fail_gate "$case_name alias escaped the temporary Home" ;;
  esac
  [[ -d "$alias_path" && ! -L "$alias_path" ]] ||
    fail_gate "$case_name alias is unavailable"
}

assert_no_pending() {
  [[ ! -e "$TEST_HOME/mac/pending-launch.json" &&
     ! -L "$TEST_HOME/mac/pending-launch.json" ]] ||
    fail_gate "$1 retained pending-launch.json"
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
  local case_name="$1"
  cli_env "$TEST_HOME" "$DEBUG_CLI" --json status \
    >"$RUN_DIR/$case_name.status.json" \
    2>"$RUN_DIR/$case_name.status.stderr" ||
    fail_gate "$case_name status failed"
  assert_machine_success "$RUN_DIR/$case_name.status.json" status
}

assert_exact_process_live() {
  local case_name="$1"
  local pid="$2"
  local birth="$3"
  local executable="$4"
  local output="$RUN_DIR/$case_name.process.json"
  local observed_executable
  local canonical_expected
  local canonical_observed
  "$RUNTIME_PROBE" "$pid" process-identity >"$output" \
    2>"$RUN_DIR/$case_name.process.stderr" ||
    fail_gate "$case_name process probe failed"
  if ! jq -e \
      --argjson pid "$pid" \
      --argjson birth "$birth" '
        .alive == true and
        .pid == $pid and
        .processBirthMicroseconds == $birth and
        (.executablePath | type) == "string"
      ' "$output" >/dev/null; then
    fail_gate "$case_name exact process identity is not live"
  fi
  observed_executable="$(jq -er '.executablePath' "$output")"
  canonical_expected="$(canonical_file "$executable")" ||
    fail_gate "$case_name expected executable is unavailable"
  canonical_observed="$(canonical_file "$observed_executable")" ||
    fail_gate "$case_name observed executable is unavailable"
  [[ "$canonical_expected" == "$canonical_observed" ]] ||
    fail_gate "$case_name process executable does not match"
}

wait_exact_process_gone() {
  local case_name="$1"
  local pid="$2"
  local birth="$3"
  local deadline=$((SECONDS + 10))
  local output="$RUN_DIR/$case_name.process-after-stop.json"
  while (( SECONDS < deadline )); do
    "$RUNTIME_PROBE" "$pid" process-identity >"$output" 2>/dev/null || true
    if jq -e \
        --argjson birth "$birth" '
          .alive == false or .processBirthMicroseconds != $birth
        ' "$output" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.05
  done
  fail_gate "$case_name exact PID/birth remained live after stop"
}

stop_and_verify() {
  local case_name="$1"
  local pid="$2"
  local birth="$3"
  cli_env "$TEST_HOME" "$DEBUG_CLI" --json stop \
    >"$RUN_DIR/$case_name.stop.json" \
    2>"$RUN_DIR/$case_name.stop.stderr" ||
    fail_gate "$case_name stop failed"
  assert_machine_success "$RUN_DIR/$case_name.stop.json" stop
  assert_no_pending "$case_name"
  assert_no_driver_lock "$case_name"
  wait_exact_process_gone "$case_name" "$pid" "$birth"
}

run_crash_start() {
  local case_name="$1"
  local cut="$2"
  shift 2
  set +e
  cli_env "$TEST_HOME" \
    "$CRASH_ENV=$cut" \
    "$DEBUG_CLI" --json start --mac --timeout 30s "$@" \
    >"$RUN_DIR/$case_name.start.json" \
    2>"$RUN_DIR/$case_name.start.stderr"
  local status=$?
  set -e
  if [[ "$status" -ne "$CRASH_EXIT" ]]; then
    fail_gate "$case_name exited $status instead of $CRASH_EXIT"
  fi
}

run_owned_case() {
  local case_name="afterOwnerDurable"
  run_crash_start "$case_name" "$case_name" --reuse
  assert_pending_phase owned "$case_name"
  assert_no_driver_lock "$case_name"
  capture_status "$case_name"
  jq -e '
    .data.driver.status == "unresolvedOpen" and
    .data.driver.phase == "owned" and
    .data.driver.ownerPid > 1
  ' "$RUN_DIR/$case_name.status.json" >/dev/null ||
    fail_gate "$case_name status did not expose the exact owned journal"
  local pid
  local birth
  local executable
  pid="$(jq -er '.owner.pid' "$RUN_DIR/$case_name.pending-launch.json")"
  birth="$(jq -er '.owner.processBirthMicroseconds' "$RUN_DIR/$case_name.pending-launch.json")"
  executable="$(jq -er '.executablePath' "$RUN_DIR/$case_name.pending-launch.json")"
  assert_exact_process_live "$case_name" "$pid" "$birth" "$executable"
  stop_and_verify "$case_name" "$pid" "$birth"
}

run_driver_handoff_case() {
  local cut="$1"
  run_crash_start "$cut" "$cut" --reuse
  assert_driver_lock "$cut"
  case "$cut" in
    afterDriverLockDurable)
      assert_pending_phase owned "$cut"
      ;;
    afterPendingDriverLockCommitted)
      assert_pending_phase driverLockCommitted "$cut"
      ;;
    afterPendingJournalRemoved)
      assert_no_pending "$cut"
      ;;
    *)
      fail_gate "unknown handoff cut $cut"
      ;;
  esac
  capture_status "$cut"
  jq -e '.data.driver.status == "healthy"' \
    "$RUN_DIR/$cut.status.json" >/dev/null ||
    fail_gate "$cut status did not use the committed driver.lock"
  local lock="$TEST_HOME/state/driver.lock"
  local pid
  local executable
  local birth
  pid="$(jq -er '.runnerPid' "$lock")"
  executable="$(jq -er '.macExecutablePath' "$lock")"
  "$RUNTIME_PROBE" "$pid" process-identity \
    >"$RUN_DIR/$cut.process.json" 2>"$RUN_DIR/$cut.process.stderr" ||
    fail_gate "$cut process probe failed"
  birth="$(jq -er '.processBirthMicroseconds' "$RUN_DIR/$cut.process.json")"
  assert_exact_process_live "$cut" "$pid" "$birth" "$executable"
  stop_and_verify "$cut" "$pid" "$birth"
}

wait_for_intent_runtime() {
  local case_name="$1"
  local journal="$TEST_HOME/mac/pending-launch.json"
  local socket
  local session
  local expected_executable
  local expected_bundle
  local observed_executable
  local canonical_expected
  local canonical_observed
  local output="$RUN_DIR/$case_name.runtime.json"
  local deadline=$((SECONDS + 30))
  socket="$(jq -er '.runtimeSocketPath' "$journal")"
  session="$(jq -er '.sessionID' "$journal")"
  expected_executable="$(jq -er '.executablePath' "$journal")"
  expected_bundle="$(jq -er '.bundleIdentifier' "$journal")"
  while (( SECONDS < deadline )); do
    if "$RUNTIME_PROBE" "$socket" identified-ping "$session" \
        >"$output" 2>"$RUN_DIR/$case_name.runtime.stderr"; then
      break
    fi
    sleep 0.05
  done
  if ! jq -e \
      --arg bundle "$expected_bundle" \
      '
        .runtimeListenerSurvived == true and
        .runtimePID > 1 and
        .processBirthMicroseconds > 0 and
        .runtimeBundleIdentifier == $bundle and
        (.runtimeExecutablePath | type) == "string"
      ' "$output" >/dev/null 2>&1; then
    fail_gate "$case_name never exposed an authenticated exact Runtime owner"
  fi
  observed_executable="$(jq -er '.runtimeExecutablePath' "$output")"
  canonical_expected="$(canonical_file "$expected_executable")" ||
    fail_gate "$case_name pending executable is unavailable"
  canonical_observed="$(canonical_file "$observed_executable")" ||
    fail_gate "$case_name Runtime executable is unavailable"
  [[ "$canonical_expected" == "$canonical_observed" ]] ||
    fail_gate "$case_name Runtime executable does not match the intent"
}

promote_intent_for_test_cleanup() {
  local case_name="$1"
  local journal="$TEST_HOME/mac/pending-launch.json"
  local runtime="$RUN_DIR/$case_name.runtime.json"
  local pid
  local birth
  local executable
  local temporary
  pid="$(jq -er '.runtimePID' "$runtime")"
  birth="$(jq -er '.processBirthMicroseconds' "$runtime")"
  executable="$(jq -er '.runtimeExecutablePath' "$runtime")"
  assert_exact_process_live "$case_name" "$pid" "$birth" "$executable"
  temporary="$(mktemp "$TEST_HOME/mac/.pending-cleanup.XXXXXX")" ||
    fail_gate "$case_name could not create cleanup journal"
  jq \
    --argjson pid "$pid" \
    --arg birth "$birth" '
      .phase = "owned" |
      .owner = {
        pid: $pid,
        processBirthMicroseconds: $birth,
        source: "authenticatedRuntime"
      }
    ' "$journal" >"$temporary" ||
    fail_gate "$case_name could not encode cleanup authority"
  /bin/chmod 600 "$temporary"
  /bin/mv -f "$temporary" "$journal"
  stop_and_verify "$case_name.test-cleanup" "$pid" "$birth"
}

run_intent_case() {
  local case_name="afterOpenReturned"
  run_crash_start "$case_name" "$case_name" --reuse
  assert_pending_phase intent "$case_name"
  assert_no_driver_lock "$case_name"
  capture_status "$case_name"
  jq -e '
    .data.driver.status == "unresolvedOpen" and
    .data.driver.phase == "intent" and
    .data.driver.ownerPid == null
  ' "$RUN_DIR/$case_name.status.json" >/dev/null ||
    fail_gate "$case_name status did not expose the unresolved intent"

  local before_sha
  local after_sha
  before_sha="$(/usr/bin/shasum -a 256 "$TEST_HOME/mac/pending-launch.json" | /usr/bin/awk '{print $1}')"
  for command in start stop; do
    set +e
    if [[ "$command" == "start" ]]; then
      cli_env "$TEST_HOME" "$DEBUG_CLI" --json start --mac --reuse --timeout 5s \
        >"$RUN_DIR/$case_name.blocked-$command.stdout" \
        2>"$RUN_DIR/$case_name.blocked-$command.json"
    else
      cli_env "$TEST_HOME" "$DEBUG_CLI" --json stop \
        >"$RUN_DIR/$case_name.blocked-$command.stdout" \
        2>"$RUN_DIR/$case_name.blocked-$command.json"
    fi
    local status=$?
    set -e
    [[ "$status" -ne 0 ]] ||
      fail_gate "$case_name unexpectedly allowed $command"
    [[ ! -s "$RUN_DIR/$case_name.blocked-$command.stdout" ]] ||
      fail_gate "$case_name $command wrote failure data to stdout"
    assert_pending_failure \
      "$RUN_DIR/$case_name.blocked-$command.json" "$command"
  done
  after_sha="$(/usr/bin/shasum -a 256 "$TEST_HOME/mac/pending-launch.json" | /usr/bin/awk '{print $1}')"
  [[ "$before_sha" == "$after_sha" ]] ||
    fail_gate "$case_name commands mutated the unresolved intent"

  # Product code must not guess ownership. The disposable-account harness
  # independently authenticates the exact Runtime, writes that observed owner
  # only to make its own residue stoppable, then exercises the normal exact-
  # owner stop path. This is test cleanup, not a recovery behavior.
  wait_for_intent_runtime "$case_name"
  promote_intent_for_test_cleanup "$case_name"
}

echo "[playcover-pending-crash] Baseline prepare/start..." >&2
cli_env "$TEST_HOME" "$DEBUG_CLI" --json start --mac \
  --app "$FIXTURE_APP" --timeout 30s \
  >"$RUN_DIR/baseline.start.json" \
  2>"$RUN_DIR/baseline.start.stderr" ||
  fail_gate "baseline start failed"
assert_machine_success "$RUN_DIR/baseline.start.json" start
assert_driver_lock baseline
baseline_pid="$(jq -er '.runnerPid' "$TEST_HOME/state/driver.lock")"
"$RUNTIME_PROBE" "$baseline_pid" process-identity \
  >"$RUN_DIR/baseline.process.json" 2>"$RUN_DIR/baseline.process.stderr"
baseline_birth="$(jq -er '.processBirthMicroseconds' "$RUN_DIR/baseline.process.json")"
stop_and_verify baseline "$baseline_pid" "$baseline_birth"

echo "[playcover-pending-crash] afterOwnerDurable" >&2
run_owned_case
for cut in \
  afterDriverLockDurable \
  afterPendingDriverLockCommitted \
  afterPendingJournalRemoved; do
  echo "[playcover-pending-crash] $cut" >&2
  run_driver_handoff_case "$cut"
done
echo "[playcover-pending-crash] afterOpenReturned" >&2
run_intent_case

echo "[playcover-pending-crash] Final normal reuse..." >&2
cli_env "$TEST_HOME" "$DEBUG_CLI" --json start --mac --reuse --timeout 30s \
  >"$RUN_DIR/final.start.json" \
  2>"$RUN_DIR/final.start.stderr" ||
  fail_gate "final reuse start failed"
assert_machine_success "$RUN_DIR/final.start.json" start
assert_driver_lock final
final_pid="$(jq -er '.runnerPid' "$TEST_HOME/state/driver.lock")"
"$RUNTIME_PROBE" "$final_pid" process-identity \
  >"$RUN_DIR/final.process.json" 2>"$RUN_DIR/final.process.stderr"
final_birth="$(jq -er '.processBirthMicroseconds' "$RUN_DIR/final.process.json")"
stop_and_verify final "$final_pid" "$final_birth"

assert_repository_unchanged
SUCCESS=1
echo "[playcover-pending-crash] PASS"
