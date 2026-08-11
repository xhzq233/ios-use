#!/bin/bash
set -euo pipefail
umask 077

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
GLOBAL_STATE_GUARD="$ROOT_DIR/scripts/test_playcover_global_state_guard.sh"
EVIDENCE_ROOT="${IOS_USE_PLAYCOVER_EVIDENCE_ROOT:-$ROOT_DIR/.ios-use/live-evidence}"
CYCLE_COUNT=20
BUILD_ROOT=""
SESSION_HOME=""
RUN_DIR=""
CLI=""
FIXTURE_A=""
FIXTURE_B=""

usage() {
  cat <<'EOF'
Usage: scripts/test_playcover_runtime_stress_live.sh --live

Builds a fresh CLI and fixture, proves fixed-slot A/B replacement, then runs
20 cold start/status/stop cycles through the current slot. This gate mutates the
account-global ios-use Mac slot for the fixture Bundle ID and therefore
requires the disposable-account acknowledgement used by the other live gates.
EOF
}

fail() {
  echo "[playcover-runtime-stress] FAIL: $*" >&2
  if [[ -n "$RUN_DIR" ]]; then
    echo "[playcover-runtime-stress] Evidence retained at $RUN_DIR" >&2
  fi
  exit 1
}

remove_home_descriptor() {
  local canonical_home
  local home_id
  local descriptor
  canonical_home="$(cd "$SESSION_HOME" 2>/dev/null && pwd -P)" || return 1
  home_id="$({ printf '%s' "$canonical_home"; } |
    shasum -a 256 | awk '{print $1}')"
  [[ "$home_id" =~ ^[0-9a-f]{64}$ ]] || return 1
  descriptor="$PLAYCOVER_KNOWN_HOMES_ROOT/$home_id.json"
  [[ -e "$descriptor" || -L "$descriptor" ]] || return 0
  case "$descriptor" in
    "$PLAYCOVER_KNOWN_HOMES_ROOT"/[0-9a-f]*.json) ;;
    *) return 1 ;;
  esac
  [[ -f "$descriptor" && ! -L "$descriptor" &&
     "$(stat -f '%u' "$descriptor")" == "$(id -u)" ]] || return 1
  rm -f -- "$descriptor"
}

if [[ "${1:-}" != "--live" || $# -ne 1 ]]; then
  usage >&2
  exit 64
fi

# shellcheck source=scripts/test_playcover_global_state_guard.sh
source "$GLOBAL_STATE_GUARD"
playcover_require_disposable_account_contract "playcover-runtime-stress"

if [[ "$(uname -s)" != "Darwin" || "$(uname -m)" != "arm64" ]]; then
  fail "Apple-silicon macOS is required"
fi
for command_name in git jq mktemp plutil shasum swift xcrun; do
  command -v "$command_name" >/dev/null 2>&1 ||
    fail "$command_name is required"
done

repository_status="$(
  git -C "$ROOT_DIR" status --porcelain=v1 --untracked-files=all
)" || fail "could not inspect repository state"
if [[ -n "$repository_status" ]]; then
  printf '%s\n' "$repository_status" >&2
  fail "the live gate requires a clean checkout"
fi
START_HEAD="$(git -C "$ROOT_DIR" rev-parse HEAD)" ||
  fail "could not resolve checkout HEAD"

mkdir -p "$EVIDENCE_ROOT/playcover-runtime-stress-v4"
RUN_DIR="$(
  mktemp -d "$EVIDENCE_ROOT/playcover-runtime-stress-v4/run.XXXXXX"
)" || fail "could not create evidence directory"
chmod 700 "$RUN_DIR"
BUILD_ROOT="$(mktemp -d /tmp/ios-use-slot-stress-build.XXXXXX)" ||
  fail "could not create build root"
SESSION_HOME="$(mktemp -d /tmp/ios-use-slot-stress-home.XXXXXX)" ||
  fail "could not create IOS_USE_HOME"

cleanup() {
  local status=$?
  if [[ -n "$SESSION_HOME" && -d "$SESSION_HOME" ]]; then
    IOS_USE_HOME="$SESSION_HOME" "$CLI" stop >/dev/null 2>&1 || true
    remove_home_descriptor || status=1
  fi
  case "$BUILD_ROOT" in
    /tmp/ios-use-slot-stress-build.*|/private/tmp/ios-use-slot-stress-build.*)
      rm -rf -- "$BUILD_ROOT"
      ;;
  esac
  case "$SESSION_HOME" in
    /tmp/ios-use-slot-stress-home.*|/private/tmp/ios-use-slot-stress-home.*)
      rm -rf -- "$SESSION_HOME"
      ;;
  esac
  exit "$status"
}
trap cleanup EXIT

CLI_DIR="$BUILD_ROOT/bin"
SCRATCH="$BUILD_ROOT/swiftpm"
DERIVED="$BUILD_ROOT/fixture-derived"
mkdir -p "$CLI_DIR/.ios-use/playcover"

echo "[playcover-runtime-stress] Building CLI and Runtime..." >&2
bash "$ROOT_DIR/scripts/build_playcover_runtime.sh" --replace \
  >"$RUN_DIR/build-runtime.stdout" \
  2>"$RUN_DIR/build-runtime.stderr" || fail "Runtime build failed"
swift build \
  --package-path "$ROOT_DIR/swift-cli" \
  --scratch-path "$SCRATCH" \
  -c release \
  >"$RUN_DIR/build-cli.stdout" \
  2>"$RUN_DIR/build-cli.stderr" || fail "CLI build failed"
CLI_BIN_DIR="$(
  swift build \
    --package-path "$ROOT_DIR/swift-cli" \
    --scratch-path "$SCRATCH" \
    -c release \
    --show-bin-path
)" || fail "could not resolve CLI output"
CLI="$CLI_DIR/ios-use"
cp "$CLI_BIN_DIR/ios-use-swift" "$CLI"
chmod 700 "$CLI"

RUNTIME_SOURCE="$ROOT_DIR/.ios-use/playcover/IOSUsePlayRuntime.framework"
FRIDA_SOURCE="${IOS_USE_PLAYCOVER_FRIDA_ENGINE:-$PLAYCOVER_ACCOUNT_HOME/.local/bin/.ios-use/playcover/IOSUseFridaEngine.framework}"
[[ -x "$RUNTIME_SOURCE/IOSUsePlayRuntime" ]] ||
  fail "built Runtime is unavailable"
[[ -x "$FRIDA_SOURCE/IOSUseFridaEngine" ]] ||
  fail "set IOS_USE_PLAYCOVER_FRIDA_ENGINE to a verified pinned Engine"
ditto "$RUNTIME_SOURCE" \
  "$CLI_DIR/.ios-use/playcover/IOSUsePlayRuntime.framework"
ditto "$FRIDA_SOURCE" \
  "$CLI_DIR/.ios-use/playcover/IOSUseFridaEngine.framework"

echo "[playcover-runtime-stress] Building fixture..." >&2
bash "$ROOT_DIR/playcover-fixtures/build.sh" \
  --configuration Release \
  --sdk iphoneos \
  --derived-data-path "$DERIVED" \
  >"$RUN_DIR/build-fixture.stdout" \
  2>"$RUN_DIR/build-fixture.stderr" || fail "fixture build failed"
FIXTURE_A="$DERIVED/Build/Products/Release-iphoneos/IOSUsePlayFixture.app"
[[ -d "$FIXTURE_A" ]] || fail "fixture App is unavailable"
FIXTURE_B="$BUILD_ROOT/IOSUseFixtureB.app"
ditto "$FIXTURE_A" "$FIXTURE_B"
EXECUTABLE_A="$(
  plutil -extract CFBundleExecutable raw -o - "$FIXTURE_A/Info.plist"
)" || fail "fixture executable is unavailable"
EXECUTABLE_B="${EXECUTABLE_A}B"
mv "$FIXTURE_B/$EXECUTABLE_A" "$FIXTURE_B/$EXECUTABLE_B"
plutil -replace CFBundleExecutable -string "$EXECUTABLE_B" \
  "$FIXTURE_B/Info.plist"
if ! plutil -replace CFBundleDisplayName -string "IOSUse Fixture B" \
    "$FIXTURE_B/Info.plist" 2>/dev/null; then
  plutil -insert CFBundleDisplayName -string "IOSUse Fixture B" \
    "$FIXTURE_B/Info.plist"
fi
plutil -replace CFBundleName -string "IOSUse Fixture B" \
  "$FIXTURE_B/Info.plist"
chmod 755 "$FIXTURE_B/$EXECUTABLE_B"
BUNDLE_ID="$(
  plutil -extract CFBundleIdentifier raw -o - "$FIXTURE_A/Info.plist"
)" || fail "fixture Bundle ID is unavailable"
SLOT_ROOT="$PLAYCOVER_APPS_ROOT/$BUNDLE_ID"

run_cli() {
  local name="$1"
  shift
  echo "[playcover-runtime-stress] RUN $name" >&2
  IOS_USE_HOME="$SESSION_HOME" "$CLI" "$@" \
    >"$RUN_DIR/$name.stdout" \
    2>"$RUN_DIR/$name.stderr" || fail "$name failed"
}

run_status() {
  local name="$1"
  local attempt
  for attempt in $(seq 1 60); do
    if IOS_USE_HOME="$SESSION_HOME" "$CLI" status --json \
        >"$RUN_DIR/$name.stdout" \
        2>"$RUN_DIR/$name.stderr" &&
      jq -e '
        .ok == true and
        .data.driver.status == "healthy" and
        .data.driver.runtime.identityVerified == true and
        (.data.driver.macInstallRevision |
          test("^[0-9a-f]{64}$"))
      ' "$RUN_DIR/$name.stdout" >/dev/null; then
      return 0
    fi
    sleep 0.1
  done
  fail "$name did not converge to a healthy Runtime"
}

assert_fixed_slot() {
  local status_name="$1"
  local expected_executable="$2"
  local app_path
  local executable_path
  local revision
  app_path="$(jq -er '.data.driver.macAppPath' "$RUN_DIR/$status_name.stdout")"
  executable_path="$(
    jq -er '.data.driver.macExecutablePath' "$RUN_DIR/$status_name.stdout"
  )"
  revision="$(
    jq -er '.data.driver.macInstallRevision' "$RUN_DIR/$status_name.stdout"
  )"
  [[ "$app_path" == "$SLOT_ROOT/App.app" ]] ||
    fail "$status_name escaped the canonical fixed Bundle slot: $app_path"
  [[ ! -L "$SLOT_ROOT" && ! -L "$app_path" ]] ||
    fail "$status_name launched a symlink/facade"
  [[ "$executable_path" == "$app_path/$expected_executable" ]] ||
    fail "$status_name launched an old executable"
  [[ -x "$executable_path" ]] || fail "$status_name executable is missing"
  [[ -f "$SLOT_ROOT/slot.json" && ! -L "$SLOT_ROOT/slot.json" ]] ||
    fail "$status_name slot.json is missing"
  jq -e \
    --arg bundle "$BUNDLE_ID" \
    --arg executable "$expected_executable" \
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
    fail "$status_name slot metadata is not exact"
  local visible_count
  visible_count="$(
    find "$SLOT_ROOT" -mindepth 1 -maxdepth 1 ! -name '.*' -print |
      wc -l | tr -d ' '
  )"
  [[ "$visible_count" == "2" ]] ||
    fail "$status_name slot does not contain exactly one App and slot.json"
}

assert_stopped() {
  local name="$1"
  run_cli "$name" status --json
  jq -e '.data.driver.status == "notRunning"' \
    "$RUN_DIR/$name.stdout" >/dev/null || fail "$name is not stopped"
  [[ ! -e "$SESSION_HOME/state/driver.lock" ]] ||
    fail "$name retained driver.lock"
  [[ ! -e "$SESSION_HOME/mac/launching.json" ]] ||
    fail "$name retained launching.json"
}

start_and_capture() {
  local prefix="$1"
  local mode="$2"
  local expected_executable="$3"
  if [[ "$mode" == "current" ]]; then
    run_cli "${prefix}_start" start --mac
  else
    run_cli "${prefix}_start" start --mac --app "$mode"
  fi
  run_status "${prefix}_status"
  assert_fixed_slot "${prefix}_status" "$expected_executable"
}

echo "[playcover-runtime-stress] Characterizing A -> B -> A swap..." >&2
start_and_capture install_a "$FIXTURE_A" "$EXECUTABLE_A"
APP_A="$(jq -er '.data.driver.macAppPath' "$RUN_DIR/install_a_status.stdout")"
HASH_A="$(jq -er '.sourceContentHash' "$SLOT_ROOT/slot.json")"
REVISION="$(
  jq -er '.data.driver.macInstallRevision' "$RUN_DIR/install_a_status.stdout"
)"
run_cli install_a_stop stop
assert_stopped install_a_stopped

start_and_capture install_b "$FIXTURE_B" "$EXECUTABLE_B"
APP_B="$(jq -er '.data.driver.macAppPath' "$RUN_DIR/install_b_status.stdout")"
[[ "$APP_A" == "$SLOT_ROOT/App.app" && "$APP_B" == "$APP_A" ]] ||
  fail "source replacement changed the canonical App.app path"
[[ "$(jq -er '.sourceContentHash' "$SLOT_ROOT/slot.json")" != "$HASH_A" ]] ||
  fail "changed source did not change sourceContentHash"
[[ "$(jq -er '.data.driver.macInstallRevision' "$RUN_DIR/install_b_status.stdout")" == "$REVISION" ]] ||
  fail "source replacement changed the compatibility revision"
run_cli install_b_stop stop
assert_stopped install_b_stopped

start_and_capture reinstall_a "$FIXTURE_A" "$EXECUTABLE_A"
[[ "$(jq -er '.data.driver.macAppPath' "$RUN_DIR/reinstall_a_status.stdout")" == "$APP_A" ]] ||
  fail "A reinstall did not restore the current App identity"
[[ "$(jq -er '.sourceContentHash' "$SLOT_ROOT/slot.json")" == "$HASH_A" ]] ||
  fail "A reinstall did not restore sourceContentHash"
run_cli debug_eval debug --json '1 + 1'
jq -e '.ok == true' "$RUN_DIR/debug_eval.stdout" >/dev/null ||
  fail "resident Frida eval failed"
run_cli debug_reset debug --reset --json
jq -e '.ok == true' "$RUN_DIR/debug_reset.stdout" >/dev/null ||
  fail "resident Frida reset failed"
run_cli dom dom --json
jq -e '.ok == true' "$RUN_DIR/dom.stdout" >/dev/null ||
  fail "DOM command failed"
run_cli reinstall_a_stop stop
assert_stopped reinstall_a_stopped

start_and_capture explicit_hit "$FIXTURE_A" "$EXECUTABLE_A"
rg -q '^Mac App slot reused:' "$RUN_DIR/explicit_hit_start.stdout" ||
  fail "unchanged explicit source did not reuse the installed slot"
run_cli explicit_hit_stop stop
assert_stopped explicit_hit_stopped

echo "[playcover-runtime-stress] Running $CYCLE_COUNT current-slot cycles..." >&2
printf 'cycle\tsession\tpid\tinstallRevision\tappPath\n' \
  >"$RUN_DIR/cycles.tsv"
for cycle in $(seq 1 "$CYCLE_COUNT"); do
  printf -v prefix 'cycle_%02d' "$cycle"
  start_and_capture "$prefix" current "$EXECUTABLE_A"
  jq -er --argjson cycle "$cycle" '
    [
      $cycle,
      .data.driver.sessionIdentifier,
      .data.driver.runnerPid,
      .data.driver.macInstallRevision,
      .data.driver.macAppPath
    ] | @tsv
  ' "$RUN_DIR/${prefix}_status.stdout" >>"$RUN_DIR/cycles.tsv" ||
    fail "$prefix identity is incomplete"
  [[ "$(jq -er '.data.driver.macInstallRevision' "$RUN_DIR/${prefix}_status.stdout")" == "$REVISION" ]] ||
    fail "$prefix changed installRevision"
  [[ "$(jq -er '.data.driver.macAppPath' "$RUN_DIR/${prefix}_status.stdout")" == "$APP_A" ]] ||
    fail "$prefix launched a stale LaunchServices registration"
  run_cli "${prefix}_stop" stop
  assert_stopped "${prefix}_stopped"
done

if ! awk -F '\t' -v expected="$CYCLE_COUNT" '
  NR == 1 { next }
  {
    rows += 1
    sessions[$2] = 1
    pids[$3] = 1
    revisions[$4] = 1
    apps[$5] = 1
  }
  END {
    for (key in sessions) session_count += 1
    for (key in revisions) revision_count += 1
    for (key in apps) app_count += 1
    if (rows != expected || session_count != expected ||
        revision_count != 1 || app_count != 1) exit 1
  }
' "$RUN_DIR/cycles.tsv"; then
  fail "current-slot cycles did not keep one slot with unique sessions"
fi

END_HEAD="$(git -C "$ROOT_DIR" rev-parse HEAD)"
[[ "$END_HEAD" == "$START_HEAD" ]] || fail "checkout HEAD changed"
[[ -z "$(git -C "$ROOT_DIR" status --porcelain=v1 --untracked-files=all)" ]] ||
  fail "checkout became dirty"

jq -n \
  --arg head "$START_HEAD" \
  --arg bundleIdentifier "$BUNDLE_ID" \
  --arg installRevision "$REVISION" \
  --arg appPath "$APP_A" \
  --argjson cycles "$CYCLE_COUNT" '
    {
      schemaVersion: 1,
      gate: "playcover-runtime-stress",
      result: "pass",
      gitHEAD: $head,
      bundleIdentifier: $bundleIdentifier,
      installRevision: $installRevision,
      appPath: $appPath,
      replacementSequence: ["A", "B", "A"],
      cleanReuseCycles: $cycles,
      residentFridaEvalAndReset: true,
      domVerified: true
    }
  ' >"$RUN_DIR/attestation.json"
chmod 600 "$RUN_DIR/attestation.json"

echo "[playcover-runtime-stress] PASS"
echo "[playcover-runtime-stress] Evidence: $RUN_DIR"
