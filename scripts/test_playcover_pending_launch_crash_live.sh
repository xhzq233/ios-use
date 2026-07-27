#!/bin/bash
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"
EVIDENCE_ROOT="${IOS_USE_PLAYCOVER_CRASH_EVIDENCE_ROOT:-/tmp/ios-use-playcover-pending-crash-evidence}"
CRASH_ENV="IOS_USE_PLAYCOVER_LAUNCH_CRASH_CUT"
ALIAS_ENV="IOS_USE_PLAYCOVER_LAUNCH_CRASH_ALIAS_ROOT"
CRASH_EXIT=86
START_GIT_HEAD=""
INITIAL_REPOSITORY_STATUS=""
RUN_DIR=""
BUILD_ROOT=""
SOURCE_ROOT=""
CLI_SCRATCH_PATH=""
FIXTURE_DERIVED_DATA=""
RUNTIME_FRAMEWORK=""
FIXTURE_APP=""
DEBUG_CLI=""
RUNTIME_PROBE=""
MAIN_HOME=""
ARMED_HOME=""
SUCCESS=0
IDENTITY_PID=""
IDENTITY_BIRTH=""
IDENTITY_SOCKET=""
IDENTITY_SESSION=""
IDENTITY_EXECUTABLE=""

usage() {
  cat <<'USAGE'
Usage: scripts/test_playcover_pending_launch_crash_live.sh --live

--live    Build committed HEAD in a fresh scratch tree, then deliberately
          terminate the debug CLI at durable pending-launch boundaries and
          verify recovery from independent CLI processes. The launch façade
          is confined to an isolated /tmp alias root. This debug-only gate does
          not attest production installed-layout callback ordering.
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

assert_initial_repository_state() {
  START_GIT_HEAD="$(
    git -C "$ROOT_DIR" rev-parse --verify HEAD
  )" || config_fail "could not resolve current HEAD"
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
  if [[ "$end_head" != "$START_GIT_HEAD" ]]; then
    fail_gate "checkout HEAD changed during the gate"
  fi
  end_status="$(repository_status)" ||
    fail_gate "could not inspect repository status after the gate"
  if [[ "$end_status" != "$INITIAL_REPOSITORY_STATUS" ]]; then
    printf '%s\n' "$end_status" >&2
    fail_gate "checkout state changed during the gate"
  fi
}

canonical_directory() {
  local path="$1"
  if [[ ! -d "$path" || -L "$path" ]]; then
    return 1
  fi
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
    config_fail "$label is not an owner-only regular directory: $path"
  fi
}

assert_outside_checkout() {
  local path="$1"
  local label="$2"
  local canonical
  canonical="$(canonical_directory "$path")" ||
    config_fail "$label cannot be canonicalized"
  case "$canonical" in
    "$ROOT_DIR"|"$ROOT_DIR"/*)
      config_fail "$label must stay outside the checkout: $canonical"
      ;;
  esac
}

require_build_root() {
  local canonical
  if [[ -z "$BUILD_ROOT" ]]; then
    return 1
  fi
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

require_temporary_home() {
  local home="$1"
  local canonical
  case "$home" in
    /tmp/iupc.*|/private/tmp/iupc.*) ;;
    *) fail_gate "refusing an unexpected temporary home: $home" ;;
  esac
  canonical="$(canonical_directory "$home")" ||
    fail_gate "temporary home cannot be canonicalized: $home"
  case "$canonical" in
    /private/tmp/iupc.*) ;;
    *) fail_gate "temporary home escaped /private/tmp: $canonical" ;;
  esac
  if [[
    "$(/usr/bin/stat -f '%u' "$home")" != "$(/usr/bin/id -u)" ||
    "$(/usr/bin/stat -f '%Lp' "$home")" != "700"
  ]]; then
    fail_gate "temporary home is not owner-only: $home"
  fi
}

canonical_existing_file() {
  local path="$1"
  local directory
  local base
  if [[ ! -e "$path" || -L "$path" ]]; then
    return 1
  fi
  directory="$(cd "$(dirname "$path")" && pwd -P)" || return 1
  base="$(basename "$path")"
  printf '%s/%s\n' "$directory" "$base"
}

cli_env() {
  local home="$1"
  shift
  env \
    "IOS_USE_HOME=$home" \
    "$ALIAS_ENV=$home/launch-alias" \
    "$@"
}

try_stop_home() {
  local home="$1"
  if [[
    -z "$DEBUG_CLI" ||
    ! -x "$DEBUG_CLI" ||
    -z "$home" ||
    ! -d "$home"
  ]]; then
    return 0
  fi
  cli_env "$home" "$DEBUG_CLI" --json stop >/dev/null 2>&1 || true
}

remove_build_root() {
  if [[ -z "$BUILD_ROOT" ]]; then
    return 0
  fi
  if ! require_build_root; then
    echo \
      "[playcover-pending-crash] Refusing unsafe build-root cleanup: $BUILD_ROOT" \
      >&2
    return 1
  fi
  /bin/rm -rf -- "$BUILD_ROOT"
  BUILD_ROOT=""
}

remove_home() {
  local home="$1"
  require_temporary_home "$home"
  /bin/rm -rf -- "$home"
}

cleanup() {
  local exit_status=$?
  if [[ "$SUCCESS" -eq 1 ]]; then
    try_stop_home "$MAIN_HOME"
    try_stop_home "$ARMED_HOME"
    if [[ -n "$MAIN_HOME" && -d "$MAIN_HOME" ]]; then
      remove_home "$MAIN_HOME" || exit_status=1
    fi
    if [[ -n "$ARMED_HOME" && -d "$ARMED_HOME" ]]; then
      remove_home "$ARMED_HOME" || exit_status=1
    fi
    remove_build_root || exit_status=1
  else
    if [[ -n "$MAIN_HOME" && -d "$MAIN_HOME" ]]; then
      echo \
        "[playcover-pending-crash] Main home retained for recovery: $MAIN_HOME" \
        >&2
    fi
    if [[ -n "$ARMED_HOME" && -d "$ARMED_HOME" ]]; then
      echo \
        "[playcover-pending-crash] Armed home retained for evidence: $ARMED_HOME" \
        >&2
    fi
    if [[ -n "$BUILD_ROOT" && -d "$BUILD_ROOT" ]]; then
      echo \
        "[playcover-pending-crash] Scratch build retained for recovery: $BUILD_ROOT" \
        >&2
    fi
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

if [[ "$(uname -s)" != "Darwin" || "$(uname -m)" != "arm64" ]]; then
  config_fail "Apple-silicon macOS is required"
fi
for tool in git jq mktemp plutil rg shasum swift swiftc tar xcrun xcodegen; do
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

assert_initial_repository_state

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
  config_fail "could not create exclusive evidence directory"
/bin/chmod 700 "$RUN_DIR" ||
  config_fail "could not secure evidence directory"
assert_owner_only_directory "$RUN_DIR" "evidence directory"
assert_outside_checkout "$RUN_DIR" "evidence directory"
printf '%s\n' "$START_GIT_HEAD" >"$RUN_DIR/git-head"
printf '%s\n' "$CRASH_EXIT" >"$RUN_DIR/crash-exit"
printf '%s\n' \
  "isolated-debug-alias-gate; not production installed-layout callback ordering" \
  >"$RUN_DIR/scope"

console_session_state="$(/usr/sbin/ioreg -n Root -d1)"
if rg -q '"CGSSessionScreenIsLocked"=(Yes|true|1)' \
    <<<"$console_session_state"; then
  config_fail "the macOS console session is locked"
fi

BUILD_ROOT="$(
  mktemp -d /tmp/ios-use-playcover-pending-crash-build.XXXXXX
)" || config_fail "could not create isolated build root"
/bin/chmod 700 "$BUILD_ROOT" ||
  config_fail "could not secure isolated build root"
require_build_root ||
  config_fail "isolated build root failed canonical/owner checks"
assert_outside_checkout "$BUILD_ROOT" "isolated build root"

SOURCE_ROOT="$BUILD_ROOT/source-head"
CLI_SCRATCH_PATH="$BUILD_ROOT/swiftpm"
FIXTURE_DERIVED_DATA="$BUILD_ROOT/fixture-derived"
RUNTIME_FRAMEWORK="$BUILD_ROOT/runtime/IOSUsePlayRuntime.framework"
FIXTURE_APP="$FIXTURE_DERIVED_DATA/Build/Products/Release-iphoneos/IOSUsePlayFixture.app"
DEBUG_CLI="$BUILD_ROOT/ios-use"
RUNTIME_PROBE="$BUILD_ROOT/runtime-socket-probe"

/bin/mkdir -m 700 "$SOURCE_ROOT" ||
  config_fail "could not create committed-HEAD source root"
if ! git -C "$ROOT_DIR" archive "$START_GIT_HEAD" |
    /usr/bin/tar -x -C "$SOURCE_ROOT"; then
  fail_gate "could not materialize committed HEAD in scratch"
fi
if [[
  ! -f "$SOURCE_ROOT/swift-cli/Package.swift" ||
  ! -f "$SOURCE_ROOT/playcover-runtime/project.yml" ||
  ! -f "$SOURCE_ROOT/playcover-fixtures/project.yml"
]]; then
  fail_gate "committed-HEAD source archive is incomplete"
fi

echo \
  "[playcover-pending-crash] Building Runtime from committed HEAD $START_GIT_HEAD..." \
  >&2
bash "$SOURCE_ROOT/scripts/build_playcover_runtime.sh" \
  --output "$RUNTIME_FRAMEWORK" \
  --replace \
  >"$RUN_DIR/build-runtime.stdout" \
  2>"$RUN_DIR/build-runtime.stderr" ||
  fail_gate "Runtime scratch build failed"

echo \
  "[playcover-pending-crash] Building debug CLI in isolated SwiftPM scratch..." \
  >&2
if ! {
  swift build \
    --package-path "$SOURCE_ROOT/swift-cli" \
    --scratch-path "$CLI_SCRATCH_PATH" \
    --configuration debug \
    --product ios-use-swift
  debug_bin_dir="$(
    swift build \
      --package-path "$SOURCE_ROOT/swift-cli" \
      --scratch-path "$CLI_SCRATCH_PATH" \
      --configuration debug \
      --show-bin-path
  )"
  /bin/cp "$debug_bin_dir/ios-use-swift" "$DEBUG_CLI"
  /bin/chmod 700 "$DEBUG_CLI"
} >"$RUN_DIR/build-debug-cli.stdout" \
  2>"$RUN_DIR/build-debug-cli.stderr"; then
  fail_gate "debug CLI scratch build failed"
fi

echo \
  "[playcover-pending-crash] Building fixture in isolated DerivedData..." \
  >&2
bash "$SOURCE_ROOT/playcover-fixtures/build.sh" \
  --configuration Release \
  --sdk iphoneos \
  --derived-data-path "$FIXTURE_DERIVED_DATA" \
  >"$RUN_DIR/build-fixture.stdout" \
  2>"$RUN_DIR/build-fixture.stderr" ||
  fail_gate "fixture scratch build failed"

if [[
  ! -x "$DEBUG_CLI" ||
  ! -x "$RUNTIME_FRAMEWORK/IOSUsePlayRuntime" ||
  ! -d "$FIXTURE_APP" ||
  -L "$FIXTURE_APP" ||
  ! -f "$FIXTURE_APP/Info.plist"
]]; then
  fail_gate "scratch CLI, Runtime, or fixture is unavailable"
fi

if ! xcrun swiftc \
    -module-cache-path "$BUILD_ROOT/probe-module-cache" \
    "$SOURCE_ROOT/playcover-fixtures/runtime_socket_probe.swift" \
    -o "$RUNTIME_PROBE" \
    >"$RUN_DIR/build-runtime-probe.stdout" \
    2>"$RUN_DIR/build-runtime-probe.stderr"; then
  fail_gate "could not compile the read-only Runtime socket probe"
fi
/bin/chmod 700 "$RUNTIME_PROBE"

make_home() {
  local home
  home="$(mktemp -d /tmp/iupc.XXXXXX)" ||
    fail_gate "could not create isolated IOS_USE_HOME"
  /bin/chmod 700 "$home" ||
    fail_gate "could not secure isolated IOS_USE_HOME"
  require_temporary_home "$home"
  /bin/mkdir -m 700 "$home/playcover" ||
    fail_gate "could not create isolated PlayCover home"
  /usr/bin/ditto \
    "$RUNTIME_FRAMEWORK" \
    "$home/playcover/IOSUsePlayRuntime.framework" ||
    fail_gate "could not install scratch Runtime in isolated home"
  printf '%s\n' "$home"
}

assert_no_driver_lock() {
  local home="$1"
  if [[ -e "$home/state/driver.lock" || -L "$home/state/driver.lock" ]]; then
    fail_gate "unexpected driver.lock in $home"
  fi
}

assert_driver_lock_present() {
  local home="$1"
  local case_name="$2"
  local lock="$home/state/driver.lock"
  if [[
    ! -f "$lock" ||
    -L "$lock" ||
    "$(/usr/bin/stat -f '%u' "$lock")" != "$(/usr/bin/id -u)" ||
    "$(/usr/bin/stat -f '%Lp' "$lock")" != "600" ||
    "$(/usr/bin/stat -f '%l' "$lock")" != "1"
  ]]; then
    fail_gate "$case_name has no exact owner-only driver.lock"
  fi
}

assert_pending_evidence() {
  local home="$1"
  local case_name="$2"
  local journal="$home/playcover/pending-launch.json"
  local canonical_home
  if [[
    ! -f "$journal" ||
    -L "$journal" ||
    "$(/usr/bin/stat -f '%u' "$journal")" != "$(/usr/bin/id -u)" ||
    "$(/usr/bin/stat -f '%Lp' "$journal")" != "600" ||
    "$(/usr/bin/stat -f '%l' "$journal")" != "1"
  ]]; then
    fail_gate "$case_name did not retain an exact owner-only pending journal"
  fi
  /bin/cp "$journal" "$RUN_DIR/$case_name.pending-launch.json"
  local generation
  local alias_path
  generation="$(jq -er '.generationKey' "$journal")" ||
    fail_gate "$case_name journal has no generation"
  alias_path="$(jq -er '.aliasPath' "$journal")" ||
    fail_gate "$case_name journal has no façade"
  canonical_home="$(canonical_directory "$home")" ||
    fail_gate "$case_name home cannot be canonicalized"
  case "$alias_path" in
    "$home"/launch-alias/*.app|\
    "$canonical_home"/launch-alias/*.app) ;;
    *)
      fail_gate "$case_name façade escaped the isolated alias root"
      ;;
  esac
  if [[
    ! -d "$home/playcover/prepared/$generation" ||
    -L "$home/playcover/prepared/$generation"
  ]]; then
    fail_gate "$case_name did not retain its pending generation"
  fi
  if [[ ! -d "$alias_path" || -L "$alias_path" ]]; then
    fail_gate "$case_name did not retain its exact isolated façade"
  fi
}

tree_archive_sha256() {
  local root="$1"
  local digest
  digest="$(
    COPYFILE_DISABLE=1 /usr/bin/tar -cf - -C "$root" . |
      /usr/bin/shasum -a 256 |
      /usr/bin/awk '{ print $1 }'
  )" || fail_gate "could not hash preserved tree: $root"
  if [[ ! "$digest" =~ ^[0-9a-f]{64}$ ]]; then
    fail_gate "tree hash was not a SHA-256 digest: $root"
  fi
  printf '%s\n' "$digest"
}

capture_pending_fingerprint() {
  local home="$1"
  local label="$2"
  assert_pending_evidence "$home" "$label"
  local journal="$RUN_DIR/$label.pending-launch.json"
  local alias_path
  local generation
  local generation_path
  local alias_device
  local alias_inode
  local alias_stat
  local generation_stat
  local manifest_stat
  local completed_stat
  local journal_sha
  local journal_stat
  local alias_tree_sha
  local generation_tree_sha
  alias_path="$(jq -er '.aliasPath' "$journal")" ||
    fail_gate "$label journal has no façade path"
  generation="$(jq -er '.generationKey' "$journal")" ||
    fail_gate "$label journal has no generation"
  generation_path="$home/playcover/prepared/$generation"
  alias_device="$(/usr/bin/stat -f '%d' "$alias_path")" ||
    fail_gate "$label could not stat façade device"
  alias_inode="$(/usr/bin/stat -f '%i' "$alias_path")" ||
    fail_gate "$label could not stat façade inode"
  if ! jq -e \
      --argjson device "$alias_device" \
      --argjson inode "$alias_inode" '
      .aliasDevice == $device and
      .aliasInode == $inode and
      (.aliasInventory | type) == "array" and
      (.aliasInventory | length) > 0
    ' "$journal" >/dev/null; then
    fail_gate "$label façade identity does not match its journal"
  fi
  shopt -s nullglob dotglob
  local alias_entries=("$alias_path"/*)
  shopt -u dotglob nullglob
  local expected_alias_count
  expected_alias_count="$(jq -er '.aliasInventory | length' "$journal")" ||
    fail_gate "$label journal has no façade inventory"
  if [[ "${#alias_entries[@]}" -ne "$expected_alias_count" ]]; then
    fail_gate "$label façade inventory count changed"
  fi
  local entry
  local entry_name
  local entry_destination
  for entry in "${alias_entries[@]}"; do
    if [[ ! -L "$entry" ]]; then
      fail_gate "$label façade contains a non-symlink entry"
    fi
    entry_name="$(basename "$entry")"
    entry_destination="$(/usr/bin/readlink "$entry")" ||
      fail_gate "$label could not read façade entry $entry_name"
    if ! jq -e \
        --arg name "$entry_name" \
        --arg destination "$entry_destination" '
        [
          .aliasInventory[] |
          select(
            .name == $name and
            .destination == $destination
          )
        ] | length == 1
      ' "$journal" >/dev/null; then
      fail_gate "$label façade entry does not match its journal"
    fi
  done
  if [[
    ! -f "$generation_path/manifest.json" ||
    -L "$generation_path/manifest.json" ||
    ! -f "$generation_path/completed.json" ||
    -L "$generation_path/completed.json"
  ]]; then
    fail_gate "$label generation markers are unavailable"
  fi
  journal_sha="$(
    /usr/bin/shasum -a 256 "$journal" |
      /usr/bin/awk '{ print $1 }'
  )"
  journal_stat="$(
    /usr/bin/stat -f '%d:%i:%u:%Lp:%l:%z' \
      "$home/playcover/pending-launch.json"
  )"
  alias_stat="$(/usr/bin/stat -f '%d:%i:%Lp:%l' "$alias_path")"
  generation_stat="$(
    /usr/bin/stat -f '%d:%i:%Lp:%l' "$generation_path"
  )"
  manifest_stat="$(
    /usr/bin/stat -f '%d:%i:%Lp:%l:%z' \
      "$generation_path/manifest.json"
  )"
  completed_stat="$(
    /usr/bin/stat -f '%d:%i:%Lp:%l:%z' \
      "$generation_path/completed.json"
  )"
  alias_tree_sha="$(tree_archive_sha256 "$alias_path")"
  generation_tree_sha="$(tree_archive_sha256 "$generation_path")"
  jq -n \
    --arg journalSHA256 "$journal_sha" \
    --arg journalStat "$journal_stat" \
    --arg aliasPath "$alias_path" \
    --arg aliasStat "$alias_stat" \
    --arg aliasTreeSHA256 "$alias_tree_sha" \
    --arg generationPath "$generation_path" \
    --arg generationStat "$generation_stat" \
    --arg manifestStat "$manifest_stat" \
    --arg completedStat "$completed_stat" \
    --arg generationTreeSHA256 "$generation_tree_sha" '
      {
        journalSHA256: $journalSHA256,
        journalStat: $journalStat,
        aliasPath: $aliasPath,
        aliasStat: $aliasStat,
        aliasTreeSHA256: $aliasTreeSHA256,
        generationPath: $generationPath,
        generationStat: $generationStat,
        manifestStat: $manifestStat,
        completedStat: $completedStat,
        generationTreeSHA256: $generationTreeSHA256
      }
    ' >"$RUN_DIR/$label.pending-fingerprint.json"
}

assert_pending_fingerprint_unchanged() {
  local home="$1"
  local before_label="$2"
  local after_label="$3"
  capture_pending_fingerprint "$home" "$after_label"
  if ! /usr/bin/cmp -s \
      "$RUN_DIR/$before_label.pending-fingerprint.json" \
      "$RUN_DIR/$after_label.pending-fingerprint.json"; then
    /usr/bin/diff -u \
      "$RUN_DIR/$before_label.pending-fingerprint.json" \
      "$RUN_DIR/$after_label.pending-fingerprint.json" >&2 || true
    fail_gate "$after_label mutated pending launch evidence"
  fi
}

capture_status() {
  local home="$1"
  local case_name="$2"
  cli_env "$home" "$DEBUG_CLI" status --json \
    >"$RUN_DIR/$case_name.status.stdout" \
    2>"$RUN_DIR/$case_name.status.stderr" ||
    fail_gate "$case_name status failed"
  if [[ -s "$RUN_DIR/$case_name.status.stderr" ]] ||
    ! jq -se '
      length == 1 and
      (.[0] |
        .schemaVersion == 1 and
        .ok == true and
        .command == "status"
      )
    ' "$RUN_DIR/$case_name.status.stdout" >/dev/null; then
    fail_gate "$case_name status did not emit one success envelope"
  fi
}

assert_pending_status_matches_journal() {
  local case_name="$1"
  local journal="$RUN_DIR/$case_name.pending-launch.json"
  local status_file="$RUN_DIR/$case_name.status.stdout"
  local phase
  local session
  local generation
  local bundle
  local owner_pid
  phase="$(jq -er '.phase' "$journal")" ||
    fail_gate "$case_name journal has no phase"
  session="$(jq -er '.sessionID' "$journal")" ||
    fail_gate "$case_name journal has no session"
  generation="$(jq -er '.generationKey' "$journal")" ||
    fail_gate "$case_name journal has no generation"
  bundle="$(jq -er '.bundleIdentifier' "$journal")" ||
    fail_gate "$case_name journal has no bundle"
  owner_pid="$(jq -c '.owner.pid // null' "$journal")" ||
    fail_gate "$case_name journal has no owner field"
  if ! jq -e \
      --arg phase "$phase" \
      --arg session "$session" \
      --arg generation "$generation" \
      --arg bundle "$bundle" \
      --argjson ownerPID "$owner_pid" '
      .data.driver.phase == $phase and
      .data.driver.sessionIdentifier == $session and
      .data.driver.playcoverGenerationKey == $generation and
      .data.driver.bundleId == $bundle and
      .data.driver.ownerPid == $ownerPID and
      (
        (
          $phase == "submissionArmed" and
          .data.driver.status == "unresolvedOpen"
        ) or
        (
          $phase == "terminalCallback" and
          (
            .data.driver.status == "unresolvedOpen" or
            .data.driver.status == "launchPending"
          )
        ) or
        (
          $phase == "owned" and
          .data.driver.status == "launchPending"
        )
      )
    ' "$status_file" >/dev/null; then
    fail_gate "$case_name status did not match its durable journal"
  fi
}

assert_phase() {
  local case_name="$1"
  shift
  local journal="$RUN_DIR/$case_name.pending-launch.json"
  local phase
  phase="$(jq -er '.phase' "$journal")" ||
    fail_gate "$case_name has no durable phase"
  local expected
  for expected in "$@"; do
    if [[ "$phase" == "$expected" ]]; then
      return 0
    fi
  done
  fail_gate "$case_name phase $phase was not one of: $*"
}

assert_owner_source() {
  local case_name="$1"
  if ! jq -e '
      .phase == "owned" and
      (
        .owner.source == "workspaceCallback" or
        .owner.source == "authenticatedRuntime"
      )
    ' "$RUN_DIR/$case_name.pending-launch.json" >/dev/null; then
    fail_gate "$case_name did not persist a real owner source"
  fi
}

capture_live_process() {
  local case_name="$1"
  local pid="$2"
  local output="$RUN_DIR/$case_name.process-live.json"
  "$RUNTIME_PROBE" "$pid" process-identity >"$output" \
    2>"$RUN_DIR/$case_name.process-live.stderr" ||
    fail_gate "$case_name could not read exact live process identity"
  jq -se \
    --argjson pid "$pid" '
      length == 1 and
      (.[0] |
        .schemaVersion == 1 and
        .mode == "process-identity" and
        .alive == true and
        .pid == $pid and
        (.processBirthMicroseconds | type) == "number" and
        .processBirthMicroseconds > 0 and
        (.executablePath | type) == "string" and
        (.executablePath | length) > 0
      )
    ' "$output" >/dev/null ||
    fail_gate "$case_name process probe returned incomplete identity"
}

assert_identified_runtime_live() {
  local home="$1"
  local case_name="$2"
  local socket_path="$3"
  local session_id="$4"
  local expected_pid="$5"
  local expected_birth="$6"
  local expected_executable="$7"
  local canonical_home
  local canonical_expected
  local canonical_runtime
  canonical_home="$(canonical_directory "$home")" ||
    fail_gate "$case_name home cannot be canonicalized"
  case "$socket_path" in
    "$home"/playcover/run/s-*.sock|\
    "$canonical_home"/playcover/run/s-*.sock) ;;
    *)
      fail_gate "$case_name Runtime socket escaped the isolated home"
      ;;
  esac
  if [[
    ! -S "$socket_path" ||
    -L "$socket_path" ||
    "$(/usr/bin/stat -f '%u' "$socket_path")" != "$(/usr/bin/id -u)" ||
    "$(/usr/bin/stat -f '%Lp' "$socket_path")" != "600"
  ]]; then
    fail_gate "$case_name Runtime socket is not an exact owner-only endpoint"
  fi
  "$RUNTIME_PROBE" \
    "$socket_path" \
    identified-ping \
    "$session_id" \
    >"$RUN_DIR/$case_name.runtime-live.json" \
    2>"$RUN_DIR/$case_name.runtime-live.stderr" ||
    fail_gate "$case_name Runtime did not authenticate the recorded session"
  jq -se \
    --argjson pid "$expected_pid" \
    --argjson birth "$expected_birth" '
    length == 1 and
    (.[0] |
      .schemaVersion == 1 and
      .mode == "identified-ping" and
      .runtimeListenerSurvived == true and
      .runtimePID == $pid and
      .runtimeBundleIdentifier == "com.iosuse.playfixture" and
      .processBirthMicroseconds == $birth and
      (.runtimeExecutablePath | type) == "string"
    )
  ' "$RUN_DIR/$case_name.runtime-live.json" >/dev/null ||
    fail_gate "$case_name Runtime probe did not match PID/birth/bundle"
  canonical_expected="$(canonical_existing_file "$expected_executable")" ||
    fail_gate "$case_name expected Runtime executable is unavailable"
  canonical_runtime="$(
    canonical_existing_file "$(
      jq -er '.runtimeExecutablePath' \
        "$RUN_DIR/$case_name.runtime-live.json"
    )"
  )" || fail_gate "$case_name Runtime-reported executable is unavailable"
  if [[ "$canonical_runtime" != "$canonical_expected" ]]; then
    fail_gate "$case_name Runtime probe did not match the exact executable"
  fi
}

set_identity_from_owned_journal() {
  local home="$1"
  local case_name="$2"
  local journal="$RUN_DIR/$case_name.pending-launch.json"
  local canonical_expected
  local canonical_observed
  local owner_source
  IDENTITY_PID="$(jq -er '.owner.pid' "$journal")" ||
    fail_gate "$case_name owned journal has no PID"
  IDENTITY_BIRTH="$(
    jq -er '.owner.processBirthMicroseconds' "$journal"
  )" || fail_gate "$case_name owned journal has no process birth"
  IDENTITY_SOCKET="$(jq -er '.runtimeSocketPath' "$journal")" ||
    fail_gate "$case_name owned journal has no Runtime socket"
  IDENTITY_SESSION="$(jq -er '.sessionID' "$journal")" ||
    fail_gate "$case_name owned journal has no session"
  IDENTITY_EXECUTABLE="$(jq -er '.executablePath' "$journal")" ||
    fail_gate "$case_name owned journal has no executable"
  owner_source="$(jq -er '.owner.source' "$journal")" ||
    fail_gate "$case_name owned journal has no owner source"
  if [[
    ! "$IDENTITY_PID" =~ ^[0-9]+$ ||
    "$IDENTITY_PID" -le 1 ||
    ! "$IDENTITY_BIRTH" =~ ^[0-9]+$ ||
    "$IDENTITY_BIRTH" -le 0
  ]]; then
    fail_gate "$case_name owned journal has invalid PID/birth identity"
  fi
  capture_live_process "$case_name" "$IDENTITY_PID"
  if ! jq -e \
      --argjson birth "$IDENTITY_BIRTH" '
      .processBirthMicroseconds == $birth
    ' "$RUN_DIR/$case_name.process-live.json" >/dev/null; then
    fail_gate "$case_name live PID does not match the durable birth identity"
  fi
  canonical_expected="$(canonical_existing_file "$IDENTITY_EXECUTABLE")" ||
    fail_gate "$case_name durable executable is unavailable"
  canonical_observed="$(
    canonical_existing_file "$(
      jq -er '.executablePath' "$RUN_DIR/$case_name.process-live.json"
    )"
  )" || fail_gate "$case_name observed executable is unavailable"
  if [[ "$canonical_observed" != "$canonical_expected" ]]; then
    fail_gate "$case_name live PID belongs to a different executable"
  fi
  case "$owner_source" in
    authenticatedRuntime)
      assert_identified_runtime_live \
        "$home" \
        "$case_name" \
        "$IDENTITY_SOCKET" \
        "$IDENTITY_SESSION" \
        "$IDENTITY_PID" \
        "$IDENTITY_BIRTH" \
        "$IDENTITY_EXECUTABLE"
      ;;
    workspaceCallback)
      printf '%s\n' \
        "not-required: workspaceCallback façade/process authority" \
        >"$RUN_DIR/$case_name.runtime-live.disposition"
      printf '%s\n' "null" >"$RUN_DIR/$case_name.runtime-live.json"
      ;;
    *)
      fail_gate "$case_name has an unsupported durable owner source"
      ;;
  esac
  capture_status "$home" "$case_name"
  assert_pending_status_matches_journal "$case_name"
  jq -e \
    --argjson pid "$IDENTITY_PID" '
      .data.driver.status == "launchPending" and
      .data.driver.phase == "owned" and
      .data.driver.ownerPid == $pid and
      (
        .data.driver.reason ==
          ("durable pending owner pid " + ($pid | tostring) + " is live")
      )
    ' "$RUN_DIR/$case_name.status.stdout" >/dev/null ||
    fail_gate "$case_name status did not revalidate the durable PID/birth"
  jq -n \
    --slurpfile journal "$journal" \
    --slurpfile process "$RUN_DIR/$case_name.process-live.json" \
    --slurpfile runtime "$RUN_DIR/$case_name.runtime-live.json" '
      {
        authority: "pending-launch.json",
        ownerSource: $journal[0].owner.source,
        journal: $journal[0],
        process: $process[0],
        runtimeProbeRequired:
          ($journal[0].owner.source == "authenticatedRuntime"),
        runtimeProbe: $runtime[0]
      }
    ' >"$RUN_DIR/$case_name.identity.json"
}

set_identity_from_undurable_journal() {
  local home="$1"
  local case_name="$2"
  local timeout_seconds="${3:-30}"
  local journal="$RUN_DIR/$case_name.pending-launch.json"
  local expected_bundle
  local canonical_expected
  local canonical_observed
  local deadline=$((SECONDS + timeout_seconds))
  local probe_status=1
  IDENTITY_SOCKET="$(jq -er '.runtimeSocketPath' "$journal")" ||
    fail_gate "$case_name pending journal has no Runtime socket"
  IDENTITY_SESSION="$(jq -er '.sessionID' "$journal")" ||
    fail_gate "$case_name pending journal has no session"
  IDENTITY_EXECUTABLE="$(jq -er '.executablePath' "$journal")" ||
    fail_gate "$case_name pending journal has no executable"
  expected_bundle="$(jq -er '.bundleIdentifier' "$journal")" ||
    fail_gate "$case_name pending journal has no bundle"
  while (( SECONDS < deadline )); do
    set +e
    "$RUNTIME_PROBE" \
      "$IDENTITY_SOCKET" \
      identified-ping \
      "$IDENTITY_SESSION" \
      >"$RUN_DIR/$case_name.runtime-live.json" \
      2>"$RUN_DIR/$case_name.runtime-live.stderr"
    probe_status=$?
    set -e
    if [[ "$probe_status" -eq 0 ]]; then
      break
    fi
    sleep 0.1
  done
  if [[ "$probe_status" -ne 0 ]] ||
    ! jq -se \
      --arg bundle "$expected_bundle" '
      length == 1 and
      (.[0] |
        .schemaVersion == 1 and
        .mode == "identified-ping" and
        .runtimeListenerSurvived == true and
        .runtimeBundleIdentifier == $bundle and
        (.runtimePID | type) == "number" and
        .runtimePID > 1 and
        (.processBirthMicroseconds | type) == "number" and
        .processBirthMicroseconds > 0 and
        (.runtimeExecutablePath | type) == "string" and
        (.runtimeExecutablePath | length) > 0
      )
    ' "$RUN_DIR/$case_name.runtime-live.json" >/dev/null; then
    return 1
  fi
  IDENTITY_PID="$(
    jq -er '.runtimePID' "$RUN_DIR/$case_name.runtime-live.json"
  )"
  IDENTITY_BIRTH="$(
    jq -er \
      '.processBirthMicroseconds' \
      "$RUN_DIR/$case_name.runtime-live.json"
  )"
  assert_identified_runtime_live \
    "$home" \
    "$case_name" \
    "$IDENTITY_SOCKET" \
    "$IDENTITY_SESSION" \
    "$IDENTITY_PID" \
    "$IDENTITY_BIRTH" \
    "$IDENTITY_EXECUTABLE"
  capture_live_process "$case_name" "$IDENTITY_PID"
  if ! jq -e \
      --argjson birth "$IDENTITY_BIRTH" '
      .processBirthMicroseconds == $birth
    ' "$RUN_DIR/$case_name.process-live.json" >/dev/null; then
    fail_gate "$case_name Runtime owner birth changed while probing"
  fi
  canonical_expected="$(canonical_existing_file "$IDENTITY_EXECUTABLE")" ||
    fail_gate "$case_name pending executable is unavailable"
  canonical_observed="$(
    canonical_existing_file "$(
      jq -er '.executablePath' "$RUN_DIR/$case_name.process-live.json"
    )"
  )" || fail_gate "$case_name pending process executable is unavailable"
  if [[ "$canonical_observed" != "$canonical_expected" ]]; then
    fail_gate "$case_name authenticated PID has the wrong executable"
  fi
  capture_status "$home" "$case_name"
  assert_pending_status_matches_journal "$case_name"
  jq -n \
    --slurpfile journal "$journal" \
    --slurpfile process "$RUN_DIR/$case_name.process-live.json" \
    --slurpfile runtime "$RUN_DIR/$case_name.runtime-live.json" '
      {
        authority: "authenticated-pending-candidate",
        journal: $journal[0],
        process: $process[0],
        runtimeProbe: $runtime[0]
      }
    ' >"$RUN_DIR/$case_name.identity.json"
}

set_identity_from_driver_lock() {
  local home="$1"
  local case_name="$2"
  local lock="$home/state/driver.lock"
  local journal="$home/playcover/pending-launch.json"
  local canonical_expected
  local canonical_observed
  assert_driver_lock_present "$home" "$case_name"
  /bin/cp "$lock" "$RUN_DIR/$case_name.driver.lock.json"
  IDENTITY_PID="$(jq -er '.runnerPid' "$lock")" ||
    fail_gate "$case_name driver.lock has no runner PID"
  IDENTITY_SOCKET="$(
    jq -er '.playcoverRuntimeSocketPath' "$lock"
  )" || fail_gate "$case_name driver.lock has no Runtime socket"
  IDENTITY_SESSION="$(jq -er '.sessionIdentifier' "$lock")" ||
    fail_gate "$case_name driver.lock has no session"
  IDENTITY_EXECUTABLE="$(
    jq -er '.playcoverExecutablePath' "$lock"
  )" || fail_gate "$case_name driver.lock has no executable"
  if [[ ! "$IDENTITY_PID" =~ ^[0-9]+$ || "$IDENTITY_PID" -le 1 ]]; then
    fail_gate "$case_name driver.lock has an invalid runner PID"
  fi
  capture_live_process "$case_name" "$IDENTITY_PID"
  IDENTITY_BIRTH="$(
    jq -er '.processBirthMicroseconds' \
      "$RUN_DIR/$case_name.process-live.json"
  )" || fail_gate "$case_name process probe has no stable birth"
  canonical_expected="$(canonical_existing_file "$IDENTITY_EXECUTABLE")" ||
    fail_gate "$case_name locked executable is unavailable"
  canonical_observed="$(
    canonical_existing_file "$(
      jq -er '.executablePath' "$RUN_DIR/$case_name.process-live.json"
    )"
  )" || fail_gate "$case_name observed executable is unavailable"
  if [[ "$canonical_observed" != "$canonical_expected" ]]; then
    fail_gate "$case_name driver.lock PID belongs to a different executable"
  fi
  if [[ -f "$journal" && ! -L "$journal" ]]; then
    if ! jq -e \
        --argjson pid "$IDENTITY_PID" \
        --argjson birth "$IDENTITY_BIRTH" \
        --arg socket "$IDENTITY_SOCKET" \
        --arg session "$IDENTITY_SESSION" '
        .owner.pid == $pid and
        .owner.processBirthMicroseconds == $birth and
        .runtimeSocketPath == $socket and
        .sessionID == $session
      ' "$journal" >/dev/null; then
      fail_gate "$case_name driver.lock does not match pending PID/birth/socket"
    fi
  fi
  assert_identified_runtime_live \
    "$home" \
    "$case_name" \
    "$IDENTITY_SOCKET" \
    "$IDENTITY_SESSION" \
    "$IDENTITY_PID" \
    "$IDENTITY_BIRTH" \
    "$IDENTITY_EXECUTABLE"
  capture_status "$home" "$case_name"
  if ! jq -e \
      --argjson pid "$IDENTITY_PID" \
      --arg socket "$IDENTITY_SOCKET" \
      --arg session "$IDENTITY_SESSION" '
      .data.driver.status == "healthy" and
      .data.driver.runnerPid == $pid and
      .data.driver.sessionIdentifier == $session and
      .data.driver.playcoverRuntimeSocketPath == $socket and
      .data.driver.runtime.status == "healthy" and
      .data.driver.runtime.identityVerified == true and
      .data.driver.runtime.pid == $pid
    ' "$RUN_DIR/$case_name.status.stdout" >/dev/null; then
    fail_gate "$case_name status did not authenticate driver.lock identity"
  fi
  jq -n \
    --slurpfile lock "$RUN_DIR/$case_name.driver.lock.json" \
    --slurpfile process "$RUN_DIR/$case_name.process-live.json" \
    --slurpfile runtime "$RUN_DIR/$case_name.runtime-live.json" '
      {
        authority: "driver.lock",
        driverLock: $lock[0],
        process: $process[0],
        runtimeProbe: $runtime[0]
      }
    ' >"$RUN_DIR/$case_name.identity.json"
}

assert_exact_process_gone() {
  local case_name="$1"
  local pid="$2"
  local birth="$3"
  local output="$RUN_DIR/$case_name.process-after-stop.json"
  "$RUNTIME_PROBE" "$pid" process-identity >"$output" \
    2>"$RUN_DIR/$case_name.process-after-stop.stderr" ||
    fail_gate "$case_name could not recheck process identity after stop"
  if ! jq -se \
      --argjson pid "$pid" \
      --argjson birth "$birth" '
      length == 1 and
      (.[0] |
        .schemaVersion == 1 and
        .mode == "process-identity" and
        .pid == $pid and
        (
          .alive == false or
          (
            .alive == true and
            .processBirthMicroseconds != $birth
          )
        )
      )
    ' "$output" >/dev/null; then
    fail_gate "$case_name left exact PID/birth $pid/$birth alive"
  fi
}

assert_runtime_socket_unavailable() {
  local case_name="$1"
  local socket_path="$2"
  local session_id="$3"
  if [[ -L "$socket_path" ]]; then
    fail_gate "$case_name replaced the Runtime socket with a symlink"
  fi
  set +e
  "$RUNTIME_PROBE" \
    "$socket_path" \
    identified-ping \
    "$session_id" \
    >"$RUN_DIR/$case_name.runtime-after-stop.stdout" \
    2>"$RUN_DIR/$case_name.runtime-after-stop.stderr"
  local probe_status=$?
  set -e
  if [[ "$probe_status" -eq 0 ]]; then
    fail_gate "$case_name Runtime socket still authenticated after stop"
  fi
  if [[ ! -e "$socket_path" && ! -L "$socket_path" ]]; then
    printf '%s\n' "path-absent" \
      >"$RUN_DIR/$case_name.runtime-after-stop.disposition"
  else
    printf '%s\n' "connection-unavailable" \
      >"$RUN_DIR/$case_name.runtime-after-stop.disposition"
  fi
}

run_crash_start() {
  local home="$1"
  local case_name="$2"
  local cut="$3"
  shift 3
  set +e
  cli_env "$home" \
    "$CRASH_ENV=$cut" \
    "$DEBUG_CLI" start --playcover --timeout 30s "$@" \
    >"$RUN_DIR/$case_name.start.stdout" \
    2>"$RUN_DIR/$case_name.start.stderr"
  local status=$?
  set -e
  if [[ "$status" -ne "$CRASH_EXIT" ]]; then
    fail_gate "$case_name exited $status instead of $CRASH_EXIT"
  fi
}

assert_machine_failure() {
  local case_name="$1"
  local command="$2"
  local stdout_file="$RUN_DIR/$case_name.stdout"
  local stderr_file="$RUN_DIR/$case_name.stderr"
  if [[ -s "$stdout_file" ]]; then
    fail_gate "$case_name wrote machine failure data to stdout"
  fi
  if ! jq -se \
      --arg command "$command" '
      length == 1 and
      (.[0] |
        .schemaVersion == 1 and
        .ok == false and
        .command == $command and
        (.data | type) == "object" and
        (.warnings | type) == "array" and
        .error.category == "validation" and
        .error.code == "invalid_value" and
        .error.phase == "validation" and
        (
          .error.message |
          contains("PlayCover launch is unresolved:")
        ) and
        (
          .error.message |
          contains(
            "The pending journal, facade, and generation were preserved."
          )
        ) and
        .error.retryable == false and
        .error.fatal == false and
        .error.mutationMayHaveApplied == false and
        .evidenceManifest == null
      )
    ' "$stderr_file" >/dev/null; then
    fail_gate "$case_name did not emit the stable invalid_value envelope"
  fi
}

assert_machine_success() {
  local case_name="$1"
  local command="$2"
  local stdout_file="$RUN_DIR/$case_name.stdout"
  local stderr_file="$RUN_DIR/$case_name.stderr"
  if [[ -s "$stderr_file" ]] ||
    ! jq -se \
      --arg command "$command" '
      length == 1 and
      (.[0] |
        .schemaVersion == 1 and
        .ok == true and
        .command == $command
      )
    ' "$stdout_file" >/dev/null; then
    fail_gate "$case_name did not emit one success envelope"
  fi
}

assert_start_blocked() {
  local home="$1"
  local case_name="$2"
  set +e
  cli_env "$home" "$DEBUG_CLI" --json start --playcover --timeout 5s \
    >"$RUN_DIR/$case_name.blocked-start.stdout" \
    2>"$RUN_DIR/$case_name.blocked-start.stderr"
  local status=$?
  set -e
  if [[ "$status" -eq 0 ]]; then
    fail_gate "$case_name unexpectedly allowed a new start"
  fi
  assert_machine_failure "$case_name.blocked-start" start
}

assert_stop_blocked() {
  local home="$1"
  local case_name="$2"
  set +e
  cli_env "$home" "$DEBUG_CLI" --json stop \
    >"$RUN_DIR/$case_name.blocked-stop.stdout" \
    2>"$RUN_DIR/$case_name.blocked-stop.stderr"
  local status=$?
  set -e
  if [[ "$status" -eq 0 ]]; then
    fail_gate "$case_name unexpectedly allowed stop cleanup"
  fi
  assert_machine_failure "$case_name.blocked-stop" stop
}

assert_home_stopped() {
  local home="$1"
  local case_name="$2"
  if [[
    -e "$home/playcover/pending-launch.json" ||
    -L "$home/playcover/pending-launch.json"
  ]]; then
    fail_gate "$case_name retained its journal after successful stop"
  fi
  assert_no_driver_lock "$home"
  shopt -s nullglob
  local aliases=("$home/launch-alias"/*.app)
  shopt -u nullglob
  if [[ "${#aliases[@]}" -ne 0 ]]; then
    fail_gate "$case_name retained an isolated façade after successful stop"
  fi
}

stop_current_identity_once() {
  local home="$1"
  local case_name="$2"
  local pid="$IDENTITY_PID"
  local birth="$IDENTITY_BIRTH"
  local socket="$IDENTITY_SOCKET"
  local session="$IDENTITY_SESSION"
  cli_env "$home" "$DEBUG_CLI" --json stop \
    >"$RUN_DIR/$case_name.stop.stdout" \
    2>"$RUN_DIR/$case_name.stop.stderr" ||
    fail_gate "$case_name first stop attempt failed"
  assert_machine_success "$case_name.stop" stop
  assert_home_stopped "$home" "$case_name"
  assert_exact_process_gone "$case_name" "$pid" "$birth"
  assert_runtime_socket_unavailable "$case_name" "$socket" "$session"
}

start_new_session_and_prove() {
  local home="$1"
  local case_name="$2"
  local old_pid="$3"
  local old_birth="$4"
  local old_socket="$5"
  local old_session="$6"
  cli_env "$home" "$DEBUG_CLI" --json start --playcover --timeout 30s \
    >"$RUN_DIR/$case_name.start.stdout" \
    2>"$RUN_DIR/$case_name.start.stderr" ||
    fail_gate "$case_name first bare start attempt failed"
  assert_machine_success "$case_name.start" start
  assert_exact_process_gone \
    "$case_name.old-owner" \
    "$old_pid" \
    "$old_birth"
  assert_runtime_socket_unavailable \
    "$case_name.old-owner" \
    "$old_socket" \
    "$old_session"
  set_identity_from_driver_lock "$home" "$case_name.new-driver"
  if [[ "$IDENTITY_SESSION" == "$old_session" ]]; then
    fail_gate "$case_name reused the recovered session identifier"
  fi
  if [[ "$IDENTITY_SOCKET" == "$old_socket" ]]; then
    fail_gate "$case_name reused the recovered Runtime socket path"
  fi
  if [[
    "$IDENTITY_PID" == "$old_pid" &&
    "$IDENTITY_BIRTH" == "$old_birth"
  ]]; then
    fail_gate "$case_name reused the recovered exact process identity"
  fi
  stop_current_identity_once "$home" "$case_name.new-driver"
}

prove_fresh_start() {
  local home="$1"
  local case_name="$2"
  local old_pid="$IDENTITY_PID"
  local old_birth="$IDENTITY_BIRTH"
  local old_socket="$IDENTITY_SOCKET"
  local old_session="$IDENTITY_SESSION"
  start_new_session_and_prove \
    "$home" \
    "$case_name.fresh" \
    "$old_pid" \
    "$old_birth" \
    "$old_socket" \
    "$old_session"
}

recover_terminal_without_live_candidate() {
  local home="$1"
  local case_name="$2"
  local journal="$RUN_DIR/$case_name.pending-launch.json"
  local old_session
  local old_socket
  old_session="$(jq -er '.sessionID' "$journal")" ||
    fail_gate "$case_name terminal journal has no session"
  old_socket="$(jq -er '.runtimeSocketPath' "$journal")" ||
    fail_gate "$case_name terminal journal has no socket"
  assert_pending_evidence "$home" "$case_name"
  capture_status "$home" "$case_name"
  assert_pending_status_matches_journal "$case_name"
  if ! jq -e '
      .data.driver.status == "launchPending" and
      .data.driver.phase == "terminalCallback" and
      (
        .data.driver.reason |
        contains("terminalCallbackAndEmptyCensus")
      )
    ' "$RUN_DIR/$case_name.status.stdout" >/dev/null; then
    config_fail \
      "$case_name has neither an authenticated candidate nor safe terminal cleanup"
  fi
  cli_env "$home" "$DEBUG_CLI" --json start --playcover --timeout 30s \
    >"$RUN_DIR/$case_name.safe-recovery.start.stdout" \
    2>"$RUN_DIR/$case_name.safe-recovery.start.stderr" ||
    fail_gate "$case_name safe terminal recovery start failed"
  assert_machine_success "$case_name.safe-recovery.start" start
  assert_runtime_socket_unavailable \
    "$case_name.safe-recovery.old-owner" \
    "$old_socket" \
    "$old_session"
  set_identity_from_driver_lock "$home" "$case_name.safe-recovery.new-driver"
  if [[ "$IDENTITY_SESSION" == "$old_session" ]]; then
    fail_gate "$case_name safe terminal recovery reused its old session"
  fi
  if [[ "$IDENTITY_SOCKET" == "$old_socket" ]]; then
    fail_gate "$case_name safe terminal recovery reused its old socket"
  fi
  stop_current_identity_once \
    "$home" \
    "$case_name.safe-recovery.new-driver"
}

run_after_open_returned_sampling() {
  local maximum_attempts=8
  local attempt
  local case_name
  local phase
  local canonical_attempt_home
  local home_index="$RUN_DIR/afterOpenReturned-home-index"
  : >"$home_index"
  for ((attempt = 1; attempt <= maximum_attempts; attempt++)); do
    printf -v case_name 'afterOpenReturned-attempt-%02d' "$attempt"
    MAIN_HOME="$(make_home)"
    canonical_attempt_home="$(canonical_directory "$MAIN_HOME")" ||
      fail_gate "$case_name home cannot be canonicalized"
    if rg -Fqx "$canonical_attempt_home" "$home_index"; then
      fail_gate "$case_name reused an earlier attempt home"
    fi
    printf '%s\n' "$canonical_attempt_home" >>"$home_index"
    printf '%s\n' "$canonical_attempt_home" \
      >"$RUN_DIR/$case_name.home-origin"
    echo "[playcover-pending-crash] Running $case_name"
    run_crash_start \
      "$MAIN_HOME" \
      "$case_name" \
      afterOpenReturned \
      --app "$FIXTURE_APP"
    capture_pending_fingerprint "$MAIN_HOME" "$case_name"
    phase="$(jq -er '.phase' "$RUN_DIR/$case_name.pending-launch.json")" ||
      fail_gate "$case_name has no durable phase"
    assert_no_driver_lock "$MAIN_HOME"
    capture_status "$MAIN_HOME" "$case_name"
    assert_pending_status_matches_journal "$case_name"
    case "$phase" in
      submissionArmed)
        assert_start_blocked "$MAIN_HOME" "$case_name"
        assert_pending_fingerprint_unchanged \
          "$MAIN_HOME" \
          "$case_name" \
          "$case_name.after-blocked-start"
        capture_status "$MAIN_HOME" "$case_name.after-blocked-start"
        assert_pending_status_matches_journal \
          "$case_name.after-blocked-start"
        if ! set_identity_from_undurable_journal \
            "$MAIN_HOME" \
            "$case_name.after-blocked-start" \
            30; then
          config_fail \
            "$case_name caught submissionArmed but no exact owner became recoverable"
        fi
        local old_pid="$IDENTITY_PID"
        local old_birth="$IDENTITY_BIRTH"
        local old_socket="$IDENTITY_SOCKET"
        local old_session="$IDENTITY_SESSION"
        start_new_session_and_prove \
          "$MAIN_HOME" \
          "$case_name.recover-before-start" \
          "$old_pid" \
          "$old_birth" \
          "$old_socket" \
          "$old_session"
        printf '%s\n' "$attempt" \
          >"$RUN_DIR/afterOpenReturned-submissionArmed-attempt"
        remove_home "$MAIN_HOME"
        MAIN_HOME=""
        return 0
        ;;
      terminalCallback)
        if set_identity_from_undurable_journal \
            "$MAIN_HOME" \
            "$case_name" \
            5; then
          local old_pid="$IDENTITY_PID"
          local old_birth="$IDENTITY_BIRTH"
          local old_socket="$IDENTITY_SOCKET"
          local old_session="$IDENTITY_SESSION"
          start_new_session_and_prove \
            "$MAIN_HOME" \
            "$case_name.advanced-recover-before-start" \
            "$old_pid" \
            "$old_birth" \
            "$old_socket" \
            "$old_session"
        else
          recover_terminal_without_live_candidate \
            "$MAIN_HOME" \
            "$case_name"
        fi
        ;;
      owned)
        assert_owner_source "$case_name"
        set_identity_from_owned_journal "$MAIN_HOME" "$case_name"
        local old_pid="$IDENTITY_PID"
        local old_birth="$IDENTITY_BIRTH"
        local old_socket="$IDENTITY_SOCKET"
        local old_session="$IDENTITY_SESSION"
        start_new_session_and_prove \
          "$MAIN_HOME" \
          "$case_name.advanced-recover-before-start" \
          "$old_pid" \
          "$old_birth" \
          "$old_socket" \
          "$old_session"
        ;;
      *)
        config_fail "$case_name reached unsupported advanced phase $phase"
        ;;
    esac
    remove_home "$MAIN_HOME"
    MAIN_HOME=""
  done
  config_fail \
    "afterOpenReturned did not capture submissionArmed in $maximum_attempts independent attempts"
}

run_before_owner_case() {
  local case_name="beforeOwnerDurable"
  run_crash_start \
    "$MAIN_HOME" \
    "$case_name" \
    beforeOwnerDurable \
    --app "$FIXTURE_APP"
  assert_pending_evidence "$MAIN_HOME" "$case_name"
  assert_phase "$case_name" submissionArmed terminalCallback
  assert_no_driver_lock "$MAIN_HOME"
  capture_status "$MAIN_HOME" "$case_name"
  assert_pending_status_matches_journal "$case_name"
  if ! set_identity_from_undurable_journal \
      "$MAIN_HOME" \
      "$case_name" \
      30; then
    fail_gate "$case_name did not expose its authenticated exact owner"
  fi
  local old_pid="$IDENTITY_PID"
  local old_birth="$IDENTITY_BIRTH"
  local old_socket="$IDENTITY_SOCKET"
  local old_session="$IDENTITY_SESSION"
  start_new_session_and_prove \
    "$MAIN_HOME" \
    "$case_name.recover-before-start" \
    "$old_pid" \
    "$old_birth" \
    "$old_socket" \
    "$old_session"
}

run_owned_case() {
  local cut="$1"
  local case_name="$cut"
  run_crash_start "$MAIN_HOME" "$case_name" "$cut"
  assert_pending_evidence "$MAIN_HOME" "$case_name"
  assert_phase "$case_name" owned
  assert_owner_source "$case_name"
  assert_no_driver_lock "$MAIN_HOME"
  set_identity_from_owned_journal "$MAIN_HOME" "$case_name"
  local old_pid="$IDENTITY_PID"
  local old_birth="$IDENTITY_BIRTH"
  local old_socket="$IDENTITY_SOCKET"
  local old_session="$IDENTITY_SESSION"
  if [[ "$cut" == "afterOwnerDurable" ]]; then
    stop_current_identity_once "$MAIN_HOME" "$case_name.pending-owner"
    prove_fresh_start "$MAIN_HOME" "$case_name.pending-owner"
  else
    start_new_session_and_prove \
      "$MAIN_HOME" \
      "$case_name.recover-before-start" \
      "$old_pid" \
      "$old_birth" \
      "$old_socket" \
      "$old_session"
  fi
}

run_handoff_case() {
  local cut="$1"
  local case_name="$cut"
  run_crash_start "$MAIN_HOME" "$case_name" "$cut"
  case "$cut" in
    afterDriverLockDurable)
      assert_pending_evidence "$MAIN_HOME" "$case_name"
      assert_phase "$case_name" owned
      ;;
    afterPendingDriverLockCommitted)
      assert_pending_evidence "$MAIN_HOME" "$case_name"
      assert_phase "$case_name" driverLockCommitted
      ;;
    afterPendingDriverLockRetired)
      assert_pending_evidence "$MAIN_HOME" "$case_name"
      assert_phase "$case_name" confirmedStopped
      jq -e '.cleanupProof == "driverLockRetired"' \
        "$RUN_DIR/$case_name.pending-launch.json" >/dev/null ||
        fail_gate "$case_name omitted driverLockRetired cleanup proof"
      ;;
    afterPendingJournalRemoved)
      if [[
        -e "$MAIN_HOME/playcover/pending-launch.json" ||
        -L "$MAIN_HOME/playcover/pending-launch.json"
      ]]; then
        fail_gate "$case_name retained the removed pending journal"
      fi
      ;;
    *)
      fail_gate "unhandled driver-lock handoff cut: $cut"
      ;;
  esac
  set_identity_from_driver_lock "$MAIN_HOME" "$case_name"
  stop_current_identity_once "$MAIN_HOME" "$case_name"
  prove_fresh_start "$MAIN_HOME" "$case_name"
}

MAIN_HOME="$(make_home)"
cli_env "$MAIN_HOME" "$DEBUG_CLI" --json start --playcover \
  --app "$FIXTURE_APP" --timeout 30s \
  >"$RUN_DIR/baseline-start.stdout" \
  2>"$RUN_DIR/baseline-start.stderr" ||
  fail_gate "baseline fixture start failed"
assert_machine_success baseline-start start
set_identity_from_driver_lock "$MAIN_HOME" baseline-driver
stop_current_identity_once "$MAIN_HOME" baseline-driver
remove_home "$MAIN_HOME"
MAIN_HOME=""

run_after_open_returned_sampling

MAIN_HOME="$(make_home)"
echo "[playcover-pending-crash] Running beforeOwnerDurable"
run_before_owner_case

for cut in afterOwnerDurable afterReadyGate; do
  echo "[playcover-pending-crash] Running $cut"
  run_owned_case "$cut"
done

handoff_cuts=(
  afterDriverLockDurable
  afterPendingDriverLockCommitted
  afterPendingDriverLockRetired
  afterPendingJournalRemoved
)
for cut in "${handoff_cuts[@]}"; do
  echo "[playcover-pending-crash] Running $cut"
  run_handoff_case "$cut"
done

ARMED_HOME="$(make_home)"
run_crash_start \
  "$ARMED_HOME" \
  afterSubmissionArmed \
  afterSubmissionArmed \
  --app "$FIXTURE_APP"
capture_pending_fingerprint "$ARMED_HOME" afterSubmissionArmed
assert_phase afterSubmissionArmed submissionArmed
assert_no_driver_lock "$ARMED_HOME"
capture_status "$ARMED_HOME" afterSubmissionArmed
assert_pending_status_matches_journal afterSubmissionArmed
assert_start_blocked "$ARMED_HOME" afterSubmissionArmed
assert_pending_fingerprint_unchanged \
  "$ARMED_HOME" \
  afterSubmissionArmed \
  afterSubmissionArmed.after-blocked-start
capture_status "$ARMED_HOME" afterSubmissionArmed.after-blocked-start
assert_pending_status_matches_journal \
  afterSubmissionArmed.after-blocked-start
assert_stop_blocked "$ARMED_HOME" afterSubmissionArmed
assert_pending_fingerprint_unchanged \
  "$ARMED_HOME" \
  afterSubmissionArmed \
  afterSubmissionArmed.after-blocked-stop
capture_status "$ARMED_HOME" afterSubmissionArmed.after-blocked-stop
assert_pending_status_matches_journal \
  afterSubmissionArmed.after-blocked-stop
printf '%s\n' \
  "pre-submission fail-closed only; excluded from recovery/cut PASS" \
  >"$RUN_DIR/afterSubmissionArmed.scope"

assert_repository_unchanged
SUCCESS=1
echo \
  "[playcover-pending-crash] PASS: isolated debug-alias durable crash/restart recovery"
echo \
  "[playcover-pending-crash] Scope: not production installed-layout callback ordering"
echo \
  "[playcover-pending-crash] afterSubmissionArmed: pre-submission fail-closed evidence only"
echo "[playcover-pending-crash] Evidence: $RUN_DIR"
