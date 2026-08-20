#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
GLOBAL_STATE_GUARD="$ROOT_DIR/scripts/test_playcover_global_state_guard.sh"
CLI="$ROOT_DIR/ios-use"
SCENARIO_PATH="${IOS_USE_PLAYCOVER_LIVE_SCENARIO:-}"
PRIVATE_EVIDENCE_ROOT="${IOS_USE_PLAYCOVER_PRIVATE_EVIDENCE_DIR:-}"
ATTESTATION_ROOT="${IOS_USE_PLAYCOVER_LIVE_ATTESTATION_DIR:-}"
LIVE_APP=""
LIVE_BUNDLE_ID=""
RESTORE_DIALOG=""
RESTORE_CANCEL=""
RESTORE_CONTINUE=""
HOME_ANCHOR=""
TAB_LABELS=("" "" "")
CYCLE_COUNT=20
EVIDENCE_SCHEMA="${IOS_USE_PLAYCOVER_LIVE_EVIDENCE_SCHEMA:-2}"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
RUN_DIR=""
MANIFEST=""
ARTIFACT_INDEX=""
CYCLE_INDEX=""
SCENARIO_DIGEST=""
SESSION_HOME=""
SOURCE_EXECUTABLE=""
SOURCE_HASH_BEFORE=""
SOURCE_HASH_AFTER=""
INSTALL_REVISION=""
GATE_PASSED=0
MOUSE_SEQUENCE=0
RETAINED_SCREENSHOT=""
EXPECTED_HOST_TITLE=""
UNIQUE_RUNNER_PID_COUNT=0
PID_REUSE_OBSERVED=false

usage() {
  cat <<'USAGE'
Usage: scripts/test_playcover_external_app_live.sh --live

--live    Run the generic external-App PlayCover live gate, including real
          native-host UI/mouse checks and 20 clean lifecycle cycles. This
          requires the private runner inputs below.

Run the generic external-App PlayCover live gate. Required private
runner inputs:

  IOS_USE_PLAYCOVER_LIVE_SCENARIO
  IOS_USE_PLAYCOVER_PRIVATE_EVIDENCE_DIR

The scenario is a private JSON file with schemaVersion, appPath,
bundleIdentifier, recovery-dialog labels, a home anchor, and exactly three tab
labels. Raw screenshots, DOM, logs, and session state are retained only below
the private evidence directory, which must be outside this public checkout.
IOS_USE_PLAYCOVER_LIVE_ATTESTATION_DIR may select a separate directory for one
redacted pass attestation. Missing prerequisites exit with EX_CONFIG (78).
The documented disposable-account ACK and expected passwd Home are mandatory;
a temporary IOS_USE_HOME does not isolate account-global PlayCover state.
Crash/stale Runtime behavior is covered by the Runtime stress gate, and
synthetic PID-reuse identity handling is covered by focused unit tests.
USAGE
}

if [[ $# -ne 1 ]]; then
  usage >&2
  exit 64
fi
case "${1:-}" in
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

fail_gate() {
  echo "[playcover-external-live] FAIL: $*" >&2
  echo "[playcover-external-live] Private evidence retained." >&2
  exit 1
}

config_fail() {
  echo "[playcover-external-live] EX_CONFIG: $*" >&2
  exit 78
}

if [[ ! -f "$GLOBAL_STATE_GUARD" || -L "$GLOBAL_STATE_GUARD" ]]; then
  config_fail "the account-global PlayCover safety guard is unavailable"
fi
# shellcheck source=scripts/test_playcover_global_state_guard.sh
source "$GLOBAL_STATE_GUARD"
playcover_require_disposable_account_contract "playcover-external-live"

if [[ -z "$SCENARIO_PATH" ]]; then
  config_fail "IOS_USE_PLAYCOVER_LIVE_SCENARIO is required"
fi
if [[ -z "$PRIVATE_EVIDENCE_ROOT" ]]; then
  config_fail "IOS_USE_PLAYCOVER_PRIVATE_EVIDENCE_DIR is required"
fi
if [[ "$SCENARIO_PATH" != /* || ! -f "$SCENARIO_PATH" ]]; then
  config_fail "the private live scenario must be an absolute regular file"
fi
if [[ "$PRIVATE_EVIDENCE_ROOT" != /* ]]; then
  config_fail "the private evidence directory must be absolute"
fi
if [[ -n "$ATTESTATION_ROOT" && "$ATTESTATION_ROOT" != /* ]]; then
  config_fail "the redacted attestation directory must be absolute"
fi
command -v jq >/dev/null 2>&1 ||
  config_fail "jq is required"
if ! jq -e '
    .schemaVersion == 1 and
    (.appPath | type) == "string" and
    (.appPath | length) > 0 and
    (.bundleIdentifier | type) == "string" and
    (.bundleIdentifier | length) > 0 and
    (.recoveryDialog.label | type) == "string" and
    (.recoveryDialog.label | length) > 0 and
    (.recoveryDialog.dismissLabel | type) == "string" and
    (.recoveryDialog.dismissLabel | length) > 0 and
    (.recoveryDialog.alternateLabel | type) == "string" and
    (.recoveryDialog.alternateLabel | length) > 0 and
    (.home.anchorLabel | type) == "string" and
    (.home.anchorLabel | length) > 0 and
    (.home.tabLabels | type) == "array" and
    (.home.tabLabels | length) == 3 and
    all(.home.tabLabels[];
      type == "string" and length > 0)
  ' "$SCENARIO_PATH" >/dev/null; then
  config_fail "the private live scenario does not match schema v1"
fi

LIVE_APP="$(jq -er '.appPath' "$SCENARIO_PATH")"
LIVE_APP="${LIVE_APP%/}"
LIVE_BUNDLE_ID="$(jq -er '.bundleIdentifier' "$SCENARIO_PATH")"
RESTORE_DIALOG="$(jq -er '.recoveryDialog.label' "$SCENARIO_PATH")"
RESTORE_CANCEL="$(
  jq -er '.recoveryDialog.dismissLabel' "$SCENARIO_PATH"
)"
RESTORE_CONTINUE="$(
  jq -er '.recoveryDialog.alternateLabel' "$SCENARIO_PATH"
)"
HOME_ANCHOR="$(jq -er '.home.anchorLabel' "$SCENARIO_PATH")"
TAB_LABELS[0]="$(jq -er '.home.tabLabels[0]' "$SCENARIO_PATH")"
TAB_LABELS[1]="$(jq -er '.home.tabLabels[1]' "$SCENARIO_PATH")"
TAB_LABELS[2]="$(jq -er '.home.tabLabels[2]' "$SCENARIO_PATH")"
SCENARIO_DIGEST="$(
  /usr/bin/shasum -a 256 "$SCENARIO_PATH" |
    /usr/bin/awk '{print $1}'
)"

mkdir -p "$PRIVATE_EVIDENCE_ROOT"
PRIVATE_EVIDENCE_ROOT="$(
  cd "$PRIVATE_EVIDENCE_ROOT" && pwd -P
)"
case "$PRIVATE_EVIDENCE_ROOT/" in
  "$ROOT_DIR/"*)
    config_fail \
      "private live evidence must remain outside the public checkout"
    ;;
esac
RUN_DIR="$PRIVATE_EVIDENCE_ROOT/external-app-v2/$RUN_ID"
if [[ -e "$RUN_DIR" ]]; then
  config_fail "the private live evidence run directory already exists"
fi
MANIFEST="$RUN_DIR/manifest.tsv"
ARTIFACT_INDEX="$RUN_DIR/artifacts.tsv"
CYCLE_INDEX="$RUN_DIR/cycles.tsv"
mkdir -p "$RUN_DIR/images"
printf 'schema\tcase\tcommand\tstdout\tstderr\n' >"$MANIFEST"
printf 'case\tsource\tretained\tsha256\n' >"$ARTIFACT_INDEX"
printf 'cycle\tsessionIdentifier\trunnerPid\tinstallRevision\n' >"$CYCLE_INDEX"
cat >"$RUN_DIR/lifecycle-scope.txt" <<'SCOPE'
This external-App gate exercises only clean start/status/screenshot/stop
lifecycles against the real App process. Runtime endpoint loss, App crash/stale
classification, and synthetic PID-reuse identities remain owned by
test_playcover_runtime_stress_live.sh and
PlayCoverSessionTests.testTerminateRefusesPIDWhoseExecutableChanged; this gate
does not forge locks, kill the App, or substitute fake process identities.
SCOPE
printf '%s\n' "$EVIDENCE_SCHEMA" >"$RUN_DIR/schema-version"
printf '%s\n' "$SCENARIO_DIGEST" >"$RUN_DIR/scenario-sha256"
printf '%s\n' "$LIVE_APP" >"$RUN_DIR/source-app-path"

source_executable_hash() {
  /usr/bin/shasum -a 256 "$SOURCE_EXECUTABLE" |
    /usr/bin/awk '{print $1}'
}

copy_failure_state() {
  local retained_root="$RUN_DIR/failure-home"
  local component
  mkdir -p "$retained_root"
  for component in artifacts logs state; do
    if [[ -d "$SESSION_HOME/$component" ]]; then
      /usr/bin/ditto \
        "$SESSION_HOME/$component" \
        "$retained_root/$component" ||
        echo \
          "[playcover-external-live] Could not retain $component from the failed home." \
          >&2
    fi
  done
  if [[ -f "$SESSION_HOME/mac/last-prepared.json" ]]; then
    mkdir -p "$retained_root/mac"
    /bin/cp -p \
      "$SESSION_HOME/mac/last-prepared.json" \
      "$retained_root/mac/last-prepared.json" ||
      echo \
        "[playcover-external-live] Could not retain last-prepared.json." \
        >&2
  fi
}

cleanup() {
  local exit_code=$?
  local failure_state_copied=0
  trap - EXIT
  set +e

  if [[
    -n "$SESSION_HOME" &&
    -d "$SESSION_HOME" &&
    ("$GATE_PASSED" != "1" || "$exit_code" -ne 0)
  ]]; then
    # Preserve the exact failing lock/session before the best-effort stop
    # changes live state.
    copy_failure_state
    failure_state_copied=1
  fi

  if [[
    -n "$SESSION_HOME" &&
    -d "$SESSION_HOME" &&
    -x "$CLI" &&
    ("$GATE_PASSED" != "1" || "$exit_code" -ne 0)
  ]]; then
    IOS_USE_HOME="$SESSION_HOME" "$CLI" stop \
      >"$RUN_DIR/cleanup-stop.stdout" \
      2>"$RUN_DIR/cleanup-stop.stderr" || true
  fi

  if [[ -n "$SOURCE_EXECUTABLE" && -f "$SOURCE_EXECUTABLE" ]]; then
    local cleanup_hash
    if [[ "$GATE_PASSED" == "1" && -n "$SOURCE_HASH_AFTER" ]]; then
      cleanup_hash="$SOURCE_HASH_AFTER"
    else
      cleanup_hash="$(source_executable_hash 2>/dev/null)"
    fi
    printf '%s\n' "$cleanup_hash" >"$RUN_DIR/source-executable-sha256-after"
    if [[
      -n "$SOURCE_HASH_BEFORE" &&
      "$cleanup_hash" != "$SOURCE_HASH_BEFORE"
    ]]; then
      echo \
        "[playcover-external-live] FAIL: source executable hash changed." \
        >&2
      exit_code=1
    fi
  fi

  if [[ -n "$SESSION_HOME" && -d "$SESSION_HOME" ]]; then
    if [[ "$GATE_PASSED" == "1" && "$exit_code" -eq 0 ]]; then
      if [[
        "$SESSION_HOME" == /tmp/iupr.* &&
        ! -L "$SESSION_HOME"
      ]]; then
        /bin/rm -rf -- "$SESSION_HOME"
      else
        echo \
          "[playcover-external-live] Refusing to remove unexpected IOS_USE_HOME: $SESSION_HOME" \
          >&2
        exit_code=1
      fi
    else
      printf '%s\n' "$SESSION_HOME" >"$RUN_DIR/retained-session-home"
      if [[ "$failure_state_copied" != "1" ]]; then
        copy_failure_state
      fi
      echo \
        "[playcover-external-live] Failed IOS_USE_HOME retained at $SESSION_HOME" \
        >&2
    fi
  fi

  echo "[playcover-external-live] Private evidence retained." >&2
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
  printf '%s\t%s\t%s\t%s\t%s\n' \
    "$EVIDENCE_SCHEMA" \
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
  echo "[playcover-external-live] RUN $case_name" >&2
  if ! IOS_USE_HOME="$SESSION_HOME" "$CLI" "$@" \
      >"$stdout_file" 2>"$stderr_file"; then
    fail_gate "$case_name"
  fi
}

expected_host_title_for_app() {
  local app_path="$1"
  local info_path="$app_path/Info.plist"
  local key
  local value
  for key in CFBundleDisplayName CFBundleName CFBundleIdentifier; do
    value="$(
      /usr/bin/plutil -extract "$key" raw "$info_path" 2>/dev/null || true
    )"
    if [[ -n "$value" && "$value" != "(null)" ]]; then
      printf '%s\n' "$value"
      return 0
    fi
  done
  return 1
}

assert_status() {
  local case_name="$1"
  if ! jq -e \
      --arg installRevision "$INSTALL_REVISION" \
      --arg sourceApp "$LIVE_APP" \
      --arg sourceExecutable "$SOURCE_EXECUTABLE" \
      --arg bundleIdentifier "$LIVE_BUNDLE_ID" \
      --arg appsRoot "$PLAYCOVER_APPS_ROOT" \
      --arg title "$EXPECTED_HOST_TITLE" '
      def rectangle:
        type == "object" and
        (.x | type) == "number" and
        (.y | type) == "number" and
        (.width | type) == "number" and .width > 0 and
        (.height | type) == "number" and .height > 0;
      def rects_agree($lhs; $rhs):
        (($lhs.x - $rhs.x) | abs) <= 0.5 and
        (($lhs.y - $rhs.y) | abs) <= 0.5 and
        (($lhs.width - $rhs.width) | abs) <= 0.5 and
        (($lhs.height - $rhs.height) | abs) <= 0.5;
      .data.driver as $driver |
      ($driver.runtime) as $runtime |
      ($runtime.host) as $host |
      ($runtime.diagnostics.runtime.window) as $window |
      ($host.capture) as $capture |
      $driver.macAppPath != $sourceApp and
      ($driver.macAppPath |
        startswith($appsRoot + "/" + $bundleIdentifier + "/")) and
      $driver.macExecutablePath != $sourceExecutable and
      ($driver.macExecutablePath |
        startswith($driver.macAppPath + "/")) and
      $driver.status == "healthy" and
      $driver.bundleId == $bundleIdentifier and
      $driver.macInstallRevision == $installRevision and
      ($driver.sessionIdentifier | type) == "string" and
      ($driver.sessionIdentifier |
        test("^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$")) and
      ($driver.runnerPid | type) == "number" and
      $driver.runnerPid > 1 and
      $runtime.status == "healthy" and
      $runtime.identityVerified == true and
      $runtime.uiState.state == "ready" and
      $runtime.logicalWidth == 430 and
      $runtime.logicalHeight == 932 and
      $runtime.windowWidth == 430 and
      $runtime.windowHeight == 932 and
      $runtime.nativeWidth == 1290 and
      $runtime.nativeHeight == 2796 and
      $runtime.scale == 3 and
      $runtime.safeAreaTop == 59 and
      $runtime.safeAreaLeft == 0 and
      $runtime.safeAreaBottom == 34 and
      $runtime.safeAreaRight == 0 and
      $runtime.host.opaque == true and
      $host.status == "configured" and
      $host.opaque == true and
      $host.publicTitleBar == true and
      $host.resizable == false and
      $host.hostPolicy == true and
      $host.title == $title and
      $host.titleExpected == $title and
      $host.titleVisible == true and
      $window.nativeContentView == 1 and
      $host.canvasBounds == {"x":0,"y":0,"width":430,"height":932} and
      ($host.contentBounds | rectangle) and
      $capture.ready == true and
      $capture.error == null and
      ($capture.hostContentCGWindowRect | rectangle) and
      ($capture.canvasCGWindowRect | rectangle) and
      rects_agree(
        $capture.hostContentCGWindowRect;
        $capture.canvasCGWindowRect
      ) and
      ($host.backingScaleFactor | type) == "number" and
      $host.backingScaleFactor > 0 and
      $host.backingScaleFactor <= 4 and
      ($host.sceneRasterizationScale | type) == "number" and
      $host.sceneRasterizationScale > 0 and
      ($host.fixedBackingScale == 0 or
        $host.fixedBackingScale == 3) and
      (if $host.fixedBackingScale == 3 then
        (($host.sceneRasterizationScale - 3) | abs) <= 0.01
       else
        (($host.sceneRasterizationScale -
          $host.backingScaleFactor) | abs) <= 0.01
       end)
    ' "$RUN_DIR/$case_name.stdout" >/dev/null; then
    fail_gate "$case_name does not prove the native Catalyst external App session"
  fi
}

assert_cycle_identity() {
  local case_name="$1"
  local cycle="$2"
  local status_file="$RUN_DIR/${case_name}.stdout"
  local lock_file="$SESSION_HOME/state/driver.lock"
  if [[ ! -f "$lock_file" || -L "$lock_file" ]]; then
    fail_gate "$case_name has no private regular driver.lock"
  fi
  if [[ "$(stat -f '%Lp' "$lock_file")" != "600" ]]; then
    fail_gate "$case_name driver.lock is not owner-only"
  fi
  if ! jq -e \
      --argjson cycle "$cycle" \
      --arg installRevision "$INSTALL_REVISION" \
      --slurpfile status "$status_file" '
        ($status[0].data.driver) as $driver |
        .deviceType == "mac" and
        .startMode == "mac" and
        .bundleId == $driver.bundleId and
        .runnerPid == $driver.runnerPid and
        .runnerPid > 1 and
        .sessionIdentifier == $driver.sessionIdentifier and
        (.sessionIdentifier |
          test("^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$")) and
        .macInstallRevision == $installRevision and
        .macInstallRevision == $driver.macInstallRevision and
        .macAppPath == $driver.macAppPath and
        .macExecutablePath == $driver.macExecutablePath and
        .macRuntimeSocketPath ==
          $driver.macRuntimeSocketPath and
        ($cycle | type) == "number" and
        $cycle >= 1
      ' "$lock_file" >/dev/null; then
    fail_gate \
      "$case_name driver.lock does not match runner PID/session/install revision"
  fi
  local runner_pid
  runner_pid="$(jq -er '.data.driver.runnerPid' "$status_file")"
  if ! /bin/kill -0 "$runner_pid" 2>/dev/null; then
    fail_gate "$case_name runner PID is not a live process"
  fi
  local runtime_socket
  runtime_socket="$(
    jq -er '.data.driver.macRuntimeSocketPath' "$status_file"
  )"
  case "$runtime_socket" in
    "$PLAYCOVER_SOCKET_ROOT"/s-*.sock) ;;
    *)
      fail_gate "$case_name Runtime socket escaped the fixed UID socket root"
      ;;
  esac
  if [[ ! -S "$runtime_socket" || -L "$runtime_socket" ]]; then
    fail_gate "$case_name Runtime socket is not the live session endpoint"
  fi
}

assert_clean_cycle_stopped() {
  local case_name="$1"
  local runner_pid="$2"
  if ! jq -e \
      '.data.driver.status == "notRunning"' \
      "$RUN_DIR/${case_name}.stdout" >/dev/null; then
    fail_gate "$case_name stop left an active driver session"
  fi
  if [[ -e "$SESSION_HOME/state/driver.lock" ]]; then
    fail_gate "$case_name stop left the exact driver.lock behind"
  fi
  local attempt
  for attempt in $(seq 1 50); do
    if ! /bin/kill -0 "$runner_pid" 2>/dev/null; then
      return 0
    fi
    sleep 0.1
  done
  fail_gate "$case_name stop left runner PID $runner_pid alive"
}

assert_screenshot() {
  local case_name="$1"
  if ! jq -e --arg title "$EXPECTED_HOST_TITLE" '
      def rects_agree($lhs; $rhs):
        (($lhs.x - $rhs.x) | abs) <= 0.5 and
        (($lhs.y - $rhs.y) | abs) <= 0.5 and
        (($lhs.width - $rhs.width) | abs) <= 0.5 and
        (($lhs.height - $rhs.height) | abs) <= 0.5;
      .data.pixelSize == [1290,2796] and
      .data.logicalSize == [430,932] and
      .data.runtimeEvidence.complete == true and
      .data.runtimeEvidence.captureGeneration > 0 and
      .data.runtimeEvidence.syntheticChrome == false and
      (.data.runtimeEvidence.fullFrame as $fullFrame |
        $fullFrame == {
          "logicalRect":{"x":0,"y":0,"width":430,"height":932},
          "pixelWidth":1290,
          "pixelHeight":2796,
          "scale":3,
          "uncropped":true,
          "safeAreaCropped":false,
          "nativeCanvas":true
        } and
        .data.runtimeEvidence.compositor.fullFrame == $fullFrame) and
      (.data.runtimeEvidence.compositor as $compositor |
        $compositor.syntheticChrome == false and
        $compositor.canvasOnly == true and
        $compositor.hostDecorationsExcluded == true and
        ($compositor.completeness |
          .allVisibleNativeWindowsOrdered == true and
          .allVisibleUIKitWindowsMapped == true and
          .allWindowGeometryInsideDevice == true and
          .baseWindowCoversDevice == true and
          .requestedCapturedCountMatch == true and
          .windowSetStableDuringCapture == true)) and
      (.data.runtimeEvidence.appKitWindowEvidence as $window |
        ($window.canvasCapture) as $capture |
        $window.status == "configured" and
        $window.opaque == true and
        $window.publicTitleBar == true and
        $window.resizable == false and
        $window.hostPolicy == true and
        $window.nativeContentView == 1 and
        $window.title == $title and
        $capture.title == $title and
        $window.canvasBounds ==
          {"x":0,"y":0,"width":430,"height":932} and
        ($window.hostContentBounds.width | type) == "number" and
        $window.hostContentBounds.width > 0 and
        ($window.hostContentBounds.height | type) == "number" and
        $window.hostContentBounds.height > 0 and
        $capture.hostContentBounds == $window.hostContentBounds and
        rects_agree(
          $capture.canvasCGWindowRect;
          $capture.hostContentCGWindowRect
        ))
    ' "$RUN_DIR/$case_name.stdout" >/dev/null; then
    fail_gate "$case_name is not a complete native-canvas 1290x2796 screenshot"
  fi
}

retain_screenshot() {
  local case_name="$1"
  local source_image
  source_image="$(
    jq -er '.data.imagePath' "$RUN_DIR/${case_name}.stdout"
  )" || fail_gate "$case_name does not report an imagePath"
  if [[ ! -f "$source_image" ]]; then
    fail_gate "$case_name image does not exist: $source_image"
  fi
  local suffix="${source_image##*.}"
  if [[ "$suffix" == "$source_image" || -z "$suffix" ]]; then
    suffix="jpg"
  fi
  local retained="$RUN_DIR/images/${case_name}.${suffix}"
  /bin/cp -p "$source_image" "$retained" ||
    fail_gate "could not retain $case_name screenshot"
  local digest
  digest="$(
    /usr/bin/shasum -a 256 "$retained" |
      /usr/bin/awk '{print $1}'
  )"
  printf '%s\t%s\t%s\t%s\n' \
    "$case_name" \
    "$source_image" \
    "$retained" \
    "$digest" >>"$ARTIFACT_INDEX"
  RETAINED_SCREENSHOT="$retained"
}

tab_selected_in_file() {
  local json_file="$1"
  local tab_label="$2"
  jq -e --arg tab "$tab_label" '
      def selected:
        (.state.selected == true) or
        (((.value // "") | tostring) == "1") or
        any((.traits // [])[];
          ((. | tostring | ascii_downcase) == "selected"));
      ([.data.elements[] |
        select(
          .label == $tab and
          .state.visible == true and
          selected
        )] | length) == 1
    ' "$json_file" >/dev/null
}

poll_tab_selected() {
  local case_name="$1"
  local tab_label="$2"
  local stdout_file="$RUN_DIR/${case_name}.stdout"
  local stderr_file="$RUN_DIR/${case_name}.stderr"
  record_command \
    "$case_name" \
    "$stdout_file" \
    "$stderr_file" \
    "$CLI" dom --json
  local attempt
  for attempt in $(seq 1 50); do
    if IOS_USE_HOME="$SESSION_HOME" "$CLI" dom --json \
        >"$stdout_file" 2>"$stderr_file" &&
      tab_selected_in_file "$stdout_file" "$tab_label"; then
      return 0
    fi
    sleep 0.1
  done
  fail_gate "$case_name did not observe the expected selected tab"
}

runtime_select_tab() {
  local case_name="$1"
  local tab_label="$2"
  run_cli \
    "${case_name}_touch" \
    tap "$tab_label" --dom --json
  if ! jq -e --arg tab "$tab_label" '
      .data.element.label == $tab
    ' "$RUN_DIR/${case_name}_touch.stdout" >/dev/null; then
    fail_gate "Runtime touch targeted a different tab"
  fi
  poll_tab_selected "${case_name}_selected" "$tab_label"
}

derive_mouse_coordinates() {
  local case_name="$1"
  local element_label="$2"
  local element_role="${3:-bottom-tab}"
  local dom_case="${case_name}_fresh_dom"
  local status_case="${case_name}_fresh_status"
  run_cli "$dom_case" dom --json
  run_cli "$status_case" status --json
  assert_status "$status_case"
  if ! jq -e \
      --arg label "$element_label" \
      --arg role "$element_role" \
      --slurpfile status "$RUN_DIR/${status_case}.stdout" '
        ($status[0].data.driver.runtime) as $runtime |
        ($runtime.diagnostics.runtime.window) as $window |
        ($window.canvasCapture.canvasCGWindowRect) as $canvas |
        [.data.elements[] |
          select(
            .label == $label and
            .state.visible == true and
            .state.enabled == true and
            (.frame | type) == "array" and
            (.frame | length) == 4 and
            .frame[2] > 0 and
            .frame[3] > 0 and
            (
              $role == "dialog-action" or
              (
                $role == "bottom-tab" and
                (.frame[1] + (.frame[3] / 2)) >
                  ($runtime.logicalHeight * 0.75)
              )
            )
          )
        ] as $matches |
        if ($matches | length) != 1 then
          error(
            "fresh DOM does not contain one visible enabled " +
            $role + " named " + $label
          )
        elif (
          $window.canvasBounds !=
            {"x":0,"y":0,"width":430,"height":932} or
          $window.resizable != false or
          $window.nativeContentView != 1 or
          ($canvas | type) != "object" or
          ($canvas.width | type) != "number" or
          $canvas.width <= 0 or
          ($canvas.height | type) != "number" or
          $canvas.height <= 0
        ) then
          error("canonical canvas geometry is unavailable")
        else
          ($matches[0].frame) as $frame |
          ($frame[0] + ($frame[2] / 2)) as $logicalX |
          ($frame[1] + ($frame[3] / 2)) as $logicalY |
          ($canvas.x + ($logicalX * $canvas.width / 430)) as $globalX |
          ($canvas.y + ($logicalY * $canvas.height / 932)) as $globalY |
          (($globalX - $canvas.x) * 430 / $canvas.width) as $inverseX |
          (($globalY - $canvas.y) * 932 / $canvas.height) as $inverseY |
          if (
            (($inverseX - $logicalX) | abs) > 0.5 or
            (($inverseY - $logicalY) | abs) > 0.5
          ) then
            error("canonical canvas inverse transform exceeds 0.5pt")
          else
            {
              label: $label,
              role: $role,
              snapshotGeneration: $matches[0].snapshotGeneration,
              frame: $frame,
              logicalPoint: {
                x: $logicalX,
                y: $logicalY
              },
              globalPoint: {
                x: $globalX,
                y: $globalY
              },
              canvasCGWindowRect: $canvas,
              runnerPID: $status[0].data.driver.runnerPid,
              mouseDeliveryCountBefore: 0
            }
          end
        end
      ' \
      "$RUN_DIR/${dom_case}.stdout" \
      >"$RUN_DIR/${case_name}_coordinates.json"; then
    fail_gate "could not derive expected-tab mouse coordinates from fresh DOM"
  fi
}

run_mouse_helper() {
  local case_name="$1"
  local postcondition="${2:-tab-selected}"
  local coordinates_file="$RUN_DIR/${case_name}_coordinates.json"
  local logical_x
  local logical_y
  local global_x
  local global_y
  local runner_pid
  read -r logical_x logical_y global_x global_y runner_pid < <(
    jq -r '
      [
        .logicalPoint.x,
        .logicalPoint.y,
        .globalPoint.x,
        .globalPoint.y,
        .runnerPID
      ] |
      @tsv
    ' "$coordinates_file"
  )
  MOUSE_SEQUENCE="$((MOUSE_SEQUENCE + 1))"
  local event_token
  event_token="$(
    printf '%s%04d%02d' \
      "$(date +%s)" \
      "$(( $$ % 10000 ))" \
      "$MOUSE_SEQUENCE"
  )"
  local stdout_file="$RUN_DIR/${case_name}_mouse.stdout"
  local stderr_file="$RUN_DIR/${case_name}_mouse.stderr"
  record_command \
    "${case_name}_mouse" \
    "$stdout_file" \
    "$stderr_file" \
    xcrun swift \
    "$ROOT_DIR/playcover-fixtures/appkit_mouse_event.swift" \
    "$global_x" \
    "$global_y" \
    "$event_token" \
    "$runner_pid"
  if ! xcrun swift \
      "$ROOT_DIR/playcover-fixtures/appkit_mouse_event.swift" \
      "$global_x" \
      "$global_y" \
      "$event_token" \
      "$runner_pid" \
      >"$stdout_file" 2>"$stderr_file"; then
    if rg -q -- \
        'console session is locked|PostEvent access is not granted' \
        "$stderr_file"; then
      config_fail \
        "global mouse requires an unlocked console with PostEvent permission"
    fi
    fail_gate "$case_name global AppKit mouse helper"
  fi
  if ! jq -e \
      --argjson token "$event_token" \
      --argjson pid "$runner_pid" '
        .operation == "click" and
        .token == $token and
        .targetPID == $pid and
        .postEventAccess == true
      ' "$stdout_file" >/dev/null; then
    fail_gate "$case_name mouse helper output is not bound to the target PID/token"
  fi

  case "$postcondition" in
    tab-selected)
      poll_tab_selected "${case_name}_selected" "$(
        jq -r '.label' "$coordinates_file"
      )"
      ;;
    delivery-only) ;;
    *)
      fail_gate "$case_name has unknown mouse postcondition: $postcondition"
      ;;
  esac
  run_cli "${case_name}_delivery_evidence" screenshot \
    --name "${case_name}-delivery" --no-ocr --json
  assert_screenshot "${case_name}_delivery_evidence"
  if ! jq -e \
      --argjson token "$event_token" \
      --argjson pid "$runner_pid" \
      --slurpfile coordinates "$coordinates_file" \
      --slurpfile mouse "$stdout_file" '
        ($coordinates[0].logicalPoint) as $point |
        (.data.runtimeEvidence.appKitWindowEvidence) as $appKit |
        ($appKit.lastMouseDownDelivery) as $down |
        ($appKit.lastMouseUpDelivery) as $up |
        $down.token == $token and
        $up.token == $token and
        $down.targetPID == $pid and
        $up.targetPID == $pid and
        $down.windowNumber == $mouse[0].targetWindowNumber and
        $up.windowNumber == $mouse[0].targetWindowNumber and
        $down.sourcePID == $mouse[0].sourcePID and
        $up.sourcePID == $mouse[0].sourcePID and
        $down.phase == "down" and
        $up.phase == "up" and
        $down.geometryReady == true and
        $up.geometryReady == true and
        $down.targetHitTest == true and
        $up.targetHitTest == true and
        $down.sequence > $coordinates[0].mouseDeliveryCountBefore and
        $up.sequence > $down.sequence and
        $appKit.mouseDeliveryCount >= $up.sequence and
        $down.logicalPoint.x >= ($point.x - 0.5) and
        $down.logicalPoint.x <= ($point.x + 0.5) and
        $down.logicalPoint.y >= ($point.y - 0.5) and
        $down.logicalPoint.y <= ($point.y + 0.5) and
        $up.logicalPoint.x >= ($point.x - 0.5) and
        $up.logicalPoint.x <= ($point.x + 0.5) and
        $up.logicalPoint.y >= ($point.y - 0.5) and
        $up.logicalPoint.y <= ($point.y + 0.5)
      ' "$RUN_DIR/${case_name}_delivery_evidence.stdout" >/dev/null; then
    fail_gate "$case_name lacks exact tagged AppKit down/up delivery evidence"
  fi
  printf '%s\n' "$event_token" >"$RUN_DIR/${case_name}_event-token"
  printf '%s\t%s\t%s\t%s\n' \
    "${case_name}_coordinates" \
    "$coordinates_file" \
    "$coordinates_file" \
    "$(
      /usr/bin/shasum -a 256 "$coordinates_file" |
        /usr/bin/awk '{print $1}'
    )" >>"$ARTIFACT_INDEX"
  printf '%s\t%s\t%s\t%s\n' \
    "${case_name}_mouse" \
    "$stdout_file" \
    "$stdout_file" \
    "$(
      /usr/bin/shasum -a 256 "$stdout_file" |
        /usr/bin/awk '{print $1}'
    )" >>"$ARTIFACT_INDEX"
  : "$logical_x" "$logical_y"
}

global_select_tab() {
  local case_name="$1"
  local tab_label="$2"
  run_cli \
    "${case_name}_before" \
    screenshot --name "${case_name}-before" --json
  assert_screenshot "${case_name}_before"
  retain_screenshot "${case_name}_before"
  local before_image="$RETAINED_SCREENSHOT"
  local before_hash
  before_hash="$(
    /usr/bin/shasum -a 256 "$before_image" |
      /usr/bin/awk '{print $1}'
  )"

  # The helper coordinates are deliberately derived after the pre-click
  # screenshot so the DOM frame and AppKit window bounds are the last
  # observations before the physical event is posted.
  derive_mouse_coordinates "$case_name" "$tab_label" bottom-tab
  run_mouse_helper "$case_name" tab-selected

  run_cli \
    "${case_name}_after" \
    screenshot --name "${case_name}-after" --json
  assert_screenshot "${case_name}_after"
  retain_screenshot "${case_name}_after"
  local after_image="$RETAINED_SCREENSHOT"
  local after_hash
  after_hash="$(
    /usr/bin/shasum -a 256 "$after_image" |
      /usr/bin/awk '{print $1}'
  )"
  if [[ "$before_hash" == "$after_hash" ]]; then
    fail_gate "$case_name global mouse produced no visible screenshot change"
  fi
}

global_dismiss_recovery_dialog() {
  local case_name="restore_global_cancel"
  run_cli \
    "${case_name}_before" \
    screenshot --name "${case_name}-before" --json
  assert_screenshot "${case_name}_before"
  retain_screenshot "${case_name}_before"
  local before_image="$RETAINED_SCREENSHOT"
  local before_hash
  before_hash="$(
    /usr/bin/shasum -a 256 "$before_image" |
      /usr/bin/awk '{print $1}'
  )"

  derive_mouse_coordinates \
    "$case_name" \
    "$RESTORE_CANCEL" \
    dialog-action
  run_mouse_helper "$case_name" delivery-only
  run_cli \
    restore_wait_gone \
    waitFor "$RESTORE_DIALOG" --gone --timeout 10s --json

  run_cli \
    "${case_name}_after" \
    screenshot --name "${case_name}-after" --json
  assert_screenshot "${case_name}_after"
  retain_screenshot "${case_name}_after"
  local after_image="$RETAINED_SCREENSHOT"
  local after_hash
  after_hash="$(
    /usr/bin/shasum -a 256 "$after_image" |
      /usr/bin/awk '{print $1}'
  )"
  if [[ "$before_hash" == "$after_hash" ]]; then
    fail_gate \
      "global recovery-dialog mouse action produced no visible screenshot change"
  fi
}

derive_canvas_corner_coordinates() {
  local case_name="$1"
  local corner="$2"
  local status_case="${case_name}_fresh_status"
  run_cli "$status_case" status --json
  assert_status "$status_case"
  if ! jq -e -n \
      --arg corner "$corner" \
      --slurpfile status "$RUN_DIR/${status_case}.stdout" '
        ($status[0].data.driver.runtime) as $runtime |
        ($runtime.diagnostics.runtime.window) as $window |
        ($window.canvasCapture.canvasCGWindowRect) as $canvas |
        12 as $inset |
        (
          if $corner == "top-left" then
            {x: $inset, y: $inset}
          elif $corner == "top-right" then
            {x: ($runtime.logicalWidth - $inset), y: $inset}
          elif $corner == "bottom-left" then
            {x: $inset, y: ($runtime.logicalHeight - $inset)}
          elif $corner == "bottom-right" then
            {
              x: ($runtime.logicalWidth - $inset),
              y: ($runtime.logicalHeight - $inset)
            }
          else
            error("unknown canvas corner " + $corner)
          end
        ) as $logical |
        ($canvas.x + ($logical.x * $canvas.width / 430)) as $globalX |
        ($canvas.y + ($logical.y * $canvas.height / 932)) as $globalY |
        (($globalX - $canvas.x) * 430 / $canvas.width) as $inverseX |
        (($globalY - $canvas.y) * 932 / $canvas.height) as $inverseY |
        if (
          (($inverseX - $logical.x) | abs) > 0.5 or
          (($inverseY - $logical.y) | abs) > 0.5
        ) then
          error("canvas corner inverse transform exceeds 0.5pt")
        else
          {
            label: $corner,
            role: "canvas-corner",
            logicalPoint: $logical,
            globalPoint: {x: $globalX, y: $globalY},
            canvasCGWindowRect: $canvas,
            runnerPID: $status[0].data.driver.runnerPid,
            mouseDeliveryCountBefore: 0
          }
        end
      ' >"$RUN_DIR/${case_name}_coordinates.json"; then
    fail_gate \
      "could not derive $corner delivery coordinates from native canvas"
  fi
}

deliver_canvas_corner() {
  local case_name="$1"
  local corner="$2"
  derive_canvas_corner_coordinates "$case_name" "$corner"
  run_mouse_helper "$case_name" delivery-only
}


run_external_app_ui_workflow() {
  run_cli \
    restore_wait_present \
    waitFor "$RESTORE_DIALOG" --timeout 15s --json
  run_cli restore_dom_before dom --json
  if ! jq -e \
      --arg dialog "$RESTORE_DIALOG" \
      --arg cancel "$RESTORE_CANCEL" \
      --arg continue "$RESTORE_CONTINUE" '
        any(.data.elements[];
          .label == $dialog and .state.visible == true) and
        any(.data.elements[];
          .label == $cancel and .state.visible == true) and
        any(.data.elements[];
          .label == $continue and .state.visible == true)
      ' "$RUN_DIR/restore_dom_before.stdout" >/dev/null; then
    fail_gate "fresh external App DOM lacks the seeded recovery dialog/actions"
  fi

  run_cli native_host_status status --json
  assert_status native_host_status
  run_cli \
    native_dialog_screenshot \
    screenshot --name external-app-native-dialog --json
  assert_screenshot native_dialog_screenshot
  retain_screenshot native_dialog_screenshot
  run_cli native_dialog_dom dom --json
  if ! jq -e \
      --arg dialog "$RESTORE_DIALOG" \
      --arg cancel "$RESTORE_CANCEL" \
      --arg continue "$RESTORE_CONTINUE" '
        any(.data.elements[];
          .label == $dialog and .state.visible == true) and
        any(.data.elements[];
          .label == $cancel and .state.visible == true) and
        any(.data.elements[];
          .label == $continue and .state.visible == true)
      ' "$RUN_DIR/native_dialog_dom.stdout" >/dev/null; then
    fail_gate \
      "native Catalyst presentation lost the seeded recovery dialog/actions"
  fi

  global_dismiss_recovery_dialog
  run_cli \
    home_wait \
    waitFor "$HOME_ANCHOR" --timeout 15s --json
  run_cli home_dom dom --json
  if ! jq -e \
      --arg anchor "$HOME_ANCHOR" \
      --arg first "${TAB_LABELS[0]}" \
      --arg second "${TAB_LABELS[1]}" \
      --arg third "${TAB_LABELS[2]}" '
        . as $root |
        any(.data.elements[];
          .label == $anchor and .state.visible == true) and
        all([$first, $second, $third][];
          . as $tab |
          any($root.data.elements[];
            .label == $tab and .state.visible == true))
      ' "$RUN_DIR/home_dom.stdout" >/dev/null; then
    fail_gate "external App home does not expose all three stable bottom tabs"
  fi

  runtime_select_tab runtime_tab_inspiration "${TAB_LABELS[1]}"
  runtime_select_tab runtime_tab_profile "${TAB_LABELS[2]}"
  runtime_select_tab runtime_tab_home "${TAB_LABELS[0]}"

  deliver_canvas_corner native_top_left top-left
  deliver_canvas_corner native_bottom_right bottom-right
  deliver_canvas_corner native_top_right top-right
  deliver_canvas_corner native_bottom_left bottom-left
  runtime_select_tab native_corner_return_home "${TAB_LABELS[0]}"

  local index
  for index in 0 1 2; do
    local target="${TAB_LABELS[$index]}"
    local away="${TAB_LABELS[$(((index + 1) % 3))]}"
    runtime_select_tab "mouse_${index}_away" "$away"
    global_select_tab "mouse_${index}_${target}" "$target"
  done
  runtime_select_tab runtime_return_home "${TAB_LABELS[0]}"

  run_cli \
    native_home_screenshot \
    screenshot --name external-app-native-home --json
  assert_screenshot native_home_screenshot
  retain_screenshot native_home_screenshot

  run_cli workflow_status status --json
  assert_status workflow_status
  local runner_pid
  runner_pid="$(
    jq -er '.data.driver.runnerPid' \
      "$RUN_DIR/workflow_status.stdout"
  )"
  run_cli \
    oslog_exact \
    oslog --pid "$runner_pid" \
      --pattern 'ios-use-runtime' --timeout 1s
  if ! rg -q -- '\[ios-use-runtime\]' \
      "$RUN_DIR/oslog_exact.stdout" ||
    ! rg -Fq -- \
      "\"bundleIdentifier\":\"$LIVE_BUNDLE_ID\"" \
      "$RUN_DIR/oslog_exact.stdout"; then
    fail_gate "external App oslog lacks exact Runtime evidence"
  fi

  run_cli \
    capture_short \
    capture --duration 500ms --fps 4 --name external-app-live
  local capture_manifest
  capture_manifest="$(
    /usr/bin/sed -nE \
      's/^Manifest: (.*)$/\1/p' \
      "$RUN_DIR/capture_short.stdout"
  )"
  if [[ ! -f "$capture_manifest" ]]; then
    fail_gate "external App capture manifest is unavailable"
  fi
  if ! jq -e '
      .schemaVersion == 2 and
      .status == "complete" and
      .sampledFrames >= 1 and
      .keptFrames >= 1 and
      ([.frames[].captureGeneration] as $generations |
        all($generations[];
          . != null and . > 0) and
        all(range(1; ($generations | length));
          $generations[.] > $generations[. - 1])) and
      ([.frames[].snapshotGeneration] as $generations |
        all($generations[];
          . != null and . > 0) and
        all(range(1; ($generations | length));
          $generations[.] >= $generations[. - 1])) and
      all(.frames[];
        .pixelSize == [1290,2796] and
        .logicalSize == [430,932] and
        .scale == 3 and
        .geometrySource == "screenshot-rect+driver-scale")
    ' "$capture_manifest" >/dev/null; then
    fail_gate "external App capture manifest contract failed"
  fi
  local retained_capture="$RUN_DIR/capture"
  /usr/bin/ditto "$(dirname "$capture_manifest")" "$retained_capture" ||
    fail_gate "could not retain external App capture evidence"
  printf '%s\t%s\t%s\t%s\n' \
    "capture_manifest" \
    "$capture_manifest" \
    "$retained_capture/$(basename "$capture_manifest")" \
    "$(
      /usr/bin/shasum -a 256 \
        "$retained_capture/$(basename "$capture_manifest")" |
        /usr/bin/awk '{print $1}'
    )" >>"$ARTIFACT_INDEX"
}

write_redacted_attestation() {
  if [[ -z "$ATTESTATION_ROOT" ]]; then
    return 0
  fi
  mkdir -p "$ATTESTATION_ROOT"
  ATTESTATION_ROOT="$(
    cd "$ATTESTATION_ROOT" && pwd -P
  )"
  local leaf_commit
  leaf_commit="$(git -C "$ROOT_DIR" rev-parse HEAD)"
  local tree_clean=true
  if [[ -n "$(
    git -C "$ROOT_DIR" status --porcelain --untracked-files=normal
  )" ]]; then
    tree_clean=false
  fi
  if [[ "$tree_clean" != "true" ]]; then
    fail_gate \
      "redacted attestation requires a clean exact-commit public checkout"
  fi
  local bundle_digest
  bundle_digest="$(
    printf '%s' "$LIVE_BUNDLE_ID" |
      /usr/bin/shasum -a 256 |
      /usr/bin/awk '{print $1}'
  )"
  local install_revision_digest
  install_revision_digest="$(
    printf '%s' "$INSTALL_REVISION" |
      /usr/bin/shasum -a 256 |
      /usr/bin/awk '{print $1}'
  )"
  local manifest_digest
  manifest_digest="$(
    /usr/bin/shasum -a 256 "$MANIFEST" |
      /usr/bin/awk '{print $1}'
  )"
  local artifact_index_digest
  artifact_index_digest="$(
    /usr/bin/shasum -a 256 "$ARTIFACT_INDEX" |
      /usr/bin/awk '{print $1}'
  )"
  local cycle_index_digest
  cycle_index_digest="$(
    /usr/bin/shasum -a 256 "$CYCLE_INDEX" |
      /usr/bin/awk '{print $1}'
  )"
  local lifecycle_scope_digest
  lifecycle_scope_digest="$(
    /usr/bin/shasum -a 256 "$RUN_DIR/lifecycle-scope.txt" |
      /usr/bin/awk '{print $1}'
  )"
  local attestation_path="$ATTESTATION_ROOT/external-app-live-v2.json"
  if [[ -e "$attestation_path" ]]; then
    config_fail "the redacted attestation output already exists"
  fi
  jq -n \
    --arg leafCommit "$leaf_commit" \
    --arg scenarioDigest "$SCENARIO_DIGEST" \
    --arg bundleDigest "$bundle_digest" \
    --arg installRevisionDigest "$install_revision_digest" \
    --arg manifestDigest "$manifest_digest" \
    --arg artifactIndexDigest "$artifact_index_digest" \
    --arg cycleIndexDigest "$cycle_index_digest" \
    --arg lifecycleScopeDigest "$lifecycle_scope_digest" \
    --argjson treeClean "$tree_clean" \
    --argjson cycleCount "$CYCLE_COUNT" \
    --argjson uniqueRunnerPIDCount "$UNIQUE_RUNNER_PID_COUNT" \
    --argjson pidReuseObserved "$PID_REUSE_OBSERVED" '
      {
        schemaVersion: 2,
        backend: "mac",
        gate: "external-app-live",
        result: "pass",
        leafCommit: $leafCommit,
        treeClean: $treeClean,
        scenarioDigest: $scenarioDigest,
        bundleIdentifierDigest: $bundleDigest,
        installRevisionDigest: $installRevisionDigest,
        cycleCount: $cycleCount,
        uniqueSessionCount: $cycleCount,
        uniqueRunnerPIDCount: $uniqueRunnerPIDCount,
        pidReuseObserved: $pidReuseObserved,
        sourceExecutableUnchanged: true,
        nativeHost: {
          logicalCanvas: [430, 932],
          resizable: false,
          catalystManagedBacking: true,
          exactWindowNumberRequired: true
        },
        faultCoverageOwners: {
          runtimeCrashAndStale:
            "test_playcover_runtime_stress_live.sh",
          syntheticPIDReuse:
            "PlayCoverSessionTests.testTerminateRefusesPIDWhoseExecutableChanged"
        },
        caseIDs: [
          "clean-lifecycle-20",
          "native-host-status",
          "native-screenshot-dom",
          "recovery-dialog",
          "runtime-tabs",
          "global-mouse-dialog",
          "global-mouse-tabs",
          "native-canvas-corners",
          "complete-screenshot",
          "complete-capture",
          "pid-scoped-oslog",
          "source-immutable"
        ],
        privateEvidenceDigests: {
          manifest: $manifestDigest,
          artifactIndex: $artifactIndexDigest,
          cycleIndex: $cycleIndexDigest,
          lifecycleScope: $lifecycleScopeDigest
        }
      }
    ' >"$attestation_path"
}

if [[ "$EVIDENCE_SCHEMA" != "2" ]]; then
  config_fail \
    "IOS_USE_PLAYCOVER_LIVE_EVIDENCE_SCHEMA must be 2"
fi
if [[ "$(uname -s)" != "Darwin" || "$(uname -m)" != "arm64" ]]; then
  config_fail "Apple-silicon macOS is required"
fi
for required_command in jq rg xcrun; do
  command -v "$required_command" >/dev/null 2>&1 ||
    config_fail "$required_command is required"
done
if [[ ! -x "$CLI" ]]; then
  config_fail "workspace CLI is not executable: $CLI"
fi
if [[
  ! -f "$ROOT_DIR/playcover-fixtures/appkit_mouse_event.swift"
]]; then
  config_fail "the repository AppKit mouse helper is unavailable"
fi
if [[ ! -d "$LIVE_APP" || ! -f "$LIVE_APP/Info.plist" ]]; then
  config_fail "the scenario App is unavailable"
fi

console_state="$(
  /usr/sbin/ioreg -n Root -d1 2>/dev/null
)" || config_fail "the macOS console-session state is unavailable"
if rg -q -- \
    'CGSSessionScreenIsLocked"=(Yes|true|1)' \
    <<<"$console_state"; then
  printf '%s\n' "locked" >"$RUN_DIR/console-session-state"
  config_fail \
    "the macOS console session is locked; global mouse evidence cannot run"
fi
printf '%s\n' "unlocked-preflight" >"$RUN_DIR/console-session-state"
unset console_state

post_event_stdout="$RUN_DIR/post-event-preflight.stdout"
post_event_stderr="$RUN_DIR/post-event-preflight.stderr"
record_command \
  "post_event_preflight" \
  "$post_event_stdout" \
  "$post_event_stderr" \
  xcrun swift -e \
  'import CoreGraphics; import Darwin; if !CGPreflightPostEventAccess() { exit(78) }'
if xcrun swift -e \
    'import CoreGraphics; import Darwin; if !CGPreflightPostEventAccess() { exit(78) }' \
    >"$post_event_stdout" 2>"$post_event_stderr"; then
  printf '%s\n' "granted" >"$RUN_DIR/post-event-access"
else
  post_event_status=$?
  if [[ "$post_event_status" -eq 78 ]]; then
    printf '%s\n' "not-granted" >"$RUN_DIR/post-event-access"
    config_fail \
      "PostEvent access is not granted to the external App live gate"
  fi
  printf '%s\n' "preflight-error-$post_event_status" \
    >"$RUN_DIR/post-event-access"
  config_fail "PostEvent access could not be preflighted"
fi

executable_name="$(
  /usr/bin/plutil -extract CFBundleExecutable raw \
    "$LIVE_APP/Info.plist" 2>/dev/null
)" || config_fail "external App.app has no readable CFBundleExecutable"
if [[
  -z "$executable_name" ||
  "$executable_name" == */* ||
  "$executable_name" == "." ||
  "$executable_name" == ".."
]]; then
  config_fail "external App.app has an invalid CFBundleExecutable"
fi
SOURCE_EXECUTABLE="$LIVE_APP/$executable_name"
if [[ ! -f "$SOURCE_EXECUTABLE" || -L "$SOURCE_EXECUTABLE" ]]; then
  config_fail \
    "external App source executable must be a regular non-symlink file"
fi
bundle_identifier="$(
  /usr/bin/plutil -extract CFBundleIdentifier raw \
    "$LIVE_APP/Info.plist" 2>/dev/null
)" || config_fail "external App.app has no readable CFBundleIdentifier"
if [[ "$bundle_identifier" != "$LIVE_BUNDLE_ID" ]]; then
  config_fail "the scenario bundle identifier does not match the App"
fi
EXPECTED_HOST_TITLE="$(expected_host_title_for_app "$LIVE_APP")" ||
  config_fail "external App has no readable title-bar fallback metadata"
printf '%s\n' "$EXPECTED_HOST_TITLE" >"$RUN_DIR/expected-host-title"
printf '%s\n' "$SOURCE_EXECUTABLE" >"$RUN_DIR/source-executable-path"
if ! SOURCE_HASH_BEFORE="$(source_executable_hash)"; then
  config_fail "could not hash the external App source executable"
fi
if [[ ! "$SOURCE_HASH_BEFORE" =~ ^[0-9a-f]{64}$ ]]; then
  config_fail "could not hash the external App source executable"
fi
printf '%s\n' "$SOURCE_HASH_BEFORE" \
  >"$RUN_DIR/source-executable-sha256-before"

SESSION_HOME="$(mktemp -d /tmp/iupr.XXXXXX)"
if [[
  "$SESSION_HOME" != /tmp/iupr.* ||
  ! -d "$SESSION_HOME" ||
  -L "$SESSION_HOME"
]]; then
  config_fail "could not create a safe temporary logical IOS_USE_HOME"
fi
printf '%s\n' "$SESSION_HOME" >"$RUN_DIR/session-home"
export IOS_USE_HOME="$SESSION_HOME"

echo \
  "[playcover-external-live] Running $CYCLE_COUNT exact external App start/status/screenshot/stop cycles..." \
  >&2
for cycle in $(seq 1 "$CYCLE_COUNT"); do
  printf -v cycle_name 'cycle_%02d' "$cycle"
  if [[ "$cycle" -eq 1 ]]; then
    run_cli \
      "${cycle_name}_start" \
      start --mac --app "$LIVE_APP"
    if ! rg -q -- \
        '^Mac App slot (installed|reused): .+\/App\.app$' \
        "$RUN_DIR/${cycle_name}_start.stdout"; then
      fail_gate "the first external App start did not resolve its Bundle slot"
    fi
  else
    run_cli \
      "${cycle_name}_start" \
      start --mac
    if ! rg -q -- \
        '^Mac App slot reused: .+\.app$' \
        "$RUN_DIR/${cycle_name}_start.stdout"; then
      fail_gate \
        "$cycle_name did not reuse the current installed App slot"
    fi
  fi
  if ! rg -Fq -- \
      "IOS_USE_HOME: $SESSION_HOME" \
      "$RUN_DIR/${cycle_name}_start.stdout"; then
    fail_gate "$cycle_name did not report the temporary logical IOS_USE_HOME"
  fi

  run_cli "${cycle_name}_status" status --json
  if [[ "$cycle" -eq 1 ]]; then
    INSTALL_REVISION="$(
      jq -er '.data.driver.macInstallRevision' \
        "$RUN_DIR/${cycle_name}_status.stdout"
    )"
    if [[ ! "$INSTALL_REVISION" =~ ^[0-9a-f]{64}$ ]]; then
      fail_gate "could not read the installed App revision"
    fi
    printf '%s\n' "$INSTALL_REVISION" >"$RUN_DIR/install-revision"
  fi
  assert_status "${cycle_name}_status"
  assert_cycle_identity "${cycle_name}_status" "$cycle"
  cycle_session_identifier="$(
    jq -er '.data.driver.sessionIdentifier' \
      "$RUN_DIR/${cycle_name}_status.stdout"
  )"
  cycle_runner_pid="$(
    jq -er '.data.driver.runnerPid' \
      "$RUN_DIR/${cycle_name}_status.stdout"
  )"
  if /usr/bin/awk -F '\t' \
      -v session="$cycle_session_identifier" '
        NR > 1 && $2 == session {
          found = 1
        }
        END {
          exit !found
        }
  ' "$CYCLE_INDEX"; then
    fail_gate \
      "$cycle_name reused an earlier session identifier"
  fi
  jq -er --argjson cycle "$cycle" '
      [
        $cycle,
        .data.driver.sessionIdentifier,
        .data.driver.runnerPid,
        .data.driver.macInstallRevision
      ] |
      @tsv
    ' "$RUN_DIR/${cycle_name}_status.stdout" >>"$CYCLE_INDEX" ||
    fail_gate "$cycle_name has incomplete lifecycle identity"
  run_cli \
    "${cycle_name}_screenshot" \
    screenshot --name "${cycle_name}-external-app" --json
  assert_screenshot "${cycle_name}_screenshot"
  retain_screenshot "${cycle_name}_screenshot"

  if [[ "$cycle" -eq 1 ]]; then
    run_external_app_ui_workflow
  fi

  run_cli "${cycle_name}_stop" stop
  run_cli "${cycle_name}_stopped_status" status --json
  assert_clean_cycle_stopped \
    "${cycle_name}_stopped_status" \
    "$cycle_runner_pid"
done

if ! cycle_pid_summary="$(
  /usr/bin/awk -F '\t' \
    -v expected="$CYCLE_COUNT" \
    -v expectedRevision="$INSTALL_REVISION" '
    NR == 1 { next }
    {
      if (
        $1 != rows + 1 ||
        length($2) != 36 ||
        $3 !~ /^[0-9]+$/ ||
        $3 <= 1 ||
        $4 != expectedRevision
      ) {
        invalid = 1
      }
      rows += 1
      sessions[$2] = 1
      runners[$3] = 1
      revisions[$4] = 1
    }
    END {
      if (invalid || rows != expected) {
        exit 1
      }
      sessionCount = 0
      for (session in sessions) {
        sessionCount += 1
      }
      runnerCount = 0
      for (runner in runners) {
        runnerCount += 1
      }
      revisionCount = 0
      for (revision in revisions) {
        revisionCount += 1
      }
      if (sessionCount != expected || revisionCount != 1) {
        exit 1
      }
      printf "%d\t%s\n", runnerCount,
        (runnerCount < expected ? "true" : "false")
    }
  ' "$CYCLE_INDEX"
)"; then
  fail_gate \
    "the 20 cycles did not bind 20 unique sessions to one install revision"
fi
IFS=$'\t' read -r UNIQUE_RUNNER_PID_COUNT PID_REUSE_OBSERVED \
  <<<"$cycle_pid_summary"
if [[
  ! "$UNIQUE_RUNNER_PID_COUNT" =~ ^[1-9][0-9]*$ ||
  "$UNIQUE_RUNNER_PID_COUNT" -gt "$CYCLE_COUNT" ||
  ("$PID_REUSE_OBSERVED" != "true" && "$PID_REUSE_OBSERVED" != "false")
]]; then
  fail_gate "could not summarize observed runner PID reuse"
fi

if ! SOURCE_HASH_AFTER="$(source_executable_hash)"; then
  fail_gate "could not re-hash the external App source executable"
fi
printf '%s\n' "$SOURCE_HASH_AFTER" \
  >"$RUN_DIR/source-executable-sha256-after"
if [[ "$SOURCE_HASH_AFTER" != "$SOURCE_HASH_BEFORE" ]]; then
  fail_gate "external App source executable changed during the live gate"
fi

write_redacted_attestation
GATE_PASSED=1
echo \
  "[playcover-external-live] PASS: native Catalyst host, external App UI/global mouse, evidence, exact reuse, and $CYCLE_COUNT clean cycles" \
  >&2
