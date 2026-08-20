#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
GLOBAL_STATE_GUARD="$ROOT_DIR/scripts/test_playcover_global_state_guard.sh"
MATRIX_VERSION="2"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
EVIDENCE_ROOT="${IOS_USE_PLAYCOVER_EVIDENCE_ROOT:-$ROOT_DIR/.ios-use/live-evidence}"
RUN_DIR="$EVIDENCE_ROOT/playcover-fixture-v${MATRIX_VERSION}/$RUN_ID"
SESSION_HOME=""
CANONICAL_SESSION_HOME=""
SESSION_HOME_ID=""
SESSION_LOG_DIR=""
ARCHIVED_SESSION_HOME="$RUN_DIR/session-home"
MANIFEST="$RUN_DIR/manifest.tsv"
FIXTURE_APP="${IOS_USE_PLAYCOVER_FIXTURE_APP:-}"
ORIGINAL_FRONTMOST_PID=""
ORIGINAL_FRONTMOST_BUNDLE=""
FRONTMOST_CAPTURED=0
FOCUS_RESTORE_MANIFESTED=0
MOUSE_SEQUENCE=0
EXPECTED_HOST_TITLE=""

usage() {
  cat <<'USAGE'
Usage: scripts/test_playcover_fixture_live.sh --live

--live    Run the fixture acceptance gate against a real unlocked macOS GUI
          session. Live evidence and global input are intentionally never the
          default. The documented disposable-account ACK and expected passwd
          Home are mandatory.
USAGE
}

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
  echo \
    "[playcover-fixture-live] EX_CONFIG: the account-global PlayCover safety guard is unavailable." \
    >&2
  exit 78
fi
# shellcheck source=scripts/test_playcover_global_state_guard.sh
source "$GLOBAL_STATE_GUARD"
playcover_require_disposable_account_contract "playcover-fixture-live"

mkdir -p "$RUN_DIR"
printf 'matrixVersion\tcase\tcommand\tstdout\tstderr\n' >"$MANIFEST"

if [[ "$(uname -s)" != "Darwin" || "$(uname -m)" != "arm64" ]]; then
  echo "[playcover-fixture-live] Apple-silicon macOS is required." >&2
  exit 78
fi
if ! command -v rg >/dev/null 2>&1; then
  echo "[playcover-fixture-live] rg is required." >&2
  exit 78
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "[playcover-fixture-live] jq is required." >&2
  exit 78
fi
if ! command -v xcrun >/dev/null 2>&1; then
  echo "[playcover-fixture-live] xcrun is required." >&2
  exit 78
fi
if [[
  ! -f "$ROOT_DIR/playcover-fixtures/appkit_mouse_event.swift"
]]; then
  echo \
    "[playcover-fixture-live] AppKit mouse helper is unavailable." \
    >&2
  exit 78
fi
console_session_state="$(/usr/sbin/ioreg -n Root -d1)"
if rg -q '"CGSSessionScreenIsLocked"=(Yes|true|1)' \
    <<<"$console_session_state"; then
  echo \
    "[playcover-fixture-live] EX_CONFIG: the macOS console session is locked." \
    >&2
  exit 78
fi

SESSION_HOME="$(mktemp -d /tmp/iupf.XXXXXX)"
CANONICAL_SESSION_HOME="$(cd "$SESSION_HOME" && pwd -P)"
SESSION_HOME_ID="$(
  printf '%s' "$CANONICAL_SESSION_HOME" |
    /usr/bin/shasum -a 256 |
    /usr/bin/awk '{ print $1 }'
)"
if [[ ! "$SESSION_HOME_ID" =~ ^[0-9a-f]{64}$ ]]; then
  echo \
    "[playcover-fixture-live] EX_CONFIG: could not derive the logical Home identity." \
    >&2
  exit 78
fi
SESSION_LOG_DIR="$SESSION_HOME/logs/mac"
printf '%s\n' "$SESSION_HOME" >"$RUN_DIR/session-home-origin"

archive_session_home() {
  if [[ ! -d "$SESSION_HOME" ]]; then
    return 0
  fi
  if [[ -e "$ARCHIVED_SESSION_HOME" ]]; then
    echo \
      "[playcover-fixture-live] Refusing to replace archived session home: $ARCHIVED_SESSION_HOME" \
      >&2
    return 1
  fi
  /usr/bin/ditto "$SESSION_HOME" "$ARCHIVED_SESSION_HOME"

  local evidence_text
  for evidence_text in \
    "$RUN_DIR"/*.stdout \
    "$RUN_DIR"/*.stderr \
    "$RUN_DIR"/*.tsv; do
    if [[ ! -f "$evidence_text" ]]; then
      continue
    fi
    IOS_USE_SOURCE_HOME="$SESSION_HOME" \
      IOS_USE_CANONICAL_SOURCE_HOME="/private$SESSION_HOME" \
      IOS_USE_ARCHIVED_HOME="$ARCHIVED_SESSION_HOME" \
      /usr/bin/perl -pi -e \
        's/\Q$ENV{IOS_USE_CANONICAL_SOURCE_HOME}\E/$ENV{IOS_USE_ARCHIVED_HOME}/g; s/\Q$ENV{IOS_USE_SOURCE_HOME}\E/$ENV{IOS_USE_ARCHIVED_HOME}/g' \
        "$evidence_text"
  done

  if [[ "$SESSION_HOME" != /tmp/iupf.* || -L "$SESSION_HOME" ]]; then
    echo \
      "[playcover-fixture-live] Refusing to remove unexpected session home: $SESSION_HOME" \
      >&2
    return 1
  fi
  /bin/rm -rf "$SESSION_HOME"
}

query_frontmost_application() {
  /usr/bin/osascript -l JavaScript -e '
    ObjC.import("AppKit");
    const application =
      $.NSWorkspace.sharedWorkspace.frontmostApplication;
    if (application.isNil()) {
      throw new Error("NSWorkspace has no frontmost application");
    }
    function stringValue(value) {
      return value.isNil() ? "" : ObjC.unwrap(value);
    }
    JSON.stringify({
      pid: Number(application.processIdentifier),
      bundleIdentifier: stringValue(application.bundleIdentifier),
      localizedName: stringValue(application.localizedName)
    });
  '
}

record_frontmost_snapshot() {
  local case_name="$1"
  local stdout_file="$RUN_DIR/${case_name}.stdout"
  local stderr_file="$RUN_DIR/${case_name}.stderr"
  printf '%s\t%s\t%s\t%s\t%s\n' \
    "$MATRIX_VERSION" \
    "$case_name" \
    "NSWorkspace frontmostApplication" \
    "$stdout_file" \
    "$stderr_file" >>"$MANIFEST"
  if ! query_frontmost_application \
      >"$stdout_file" 2>"$stderr_file"; then
    echo \
      "[playcover-fixture-live] FAIL: cannot observe the frontmost host App" \
      >&2
    return 1
  fi
}

capture_original_frontmost_application() {
  record_frontmost_snapshot focus_original
  ORIGINAL_FRONTMOST_PID="$(
    jq -er '.pid | select(. > 0)' \
      "$RUN_DIR/focus_original.stdout"
  )"
  ORIGINAL_FRONTMOST_BUNDLE="$(
    jq -r '.bundleIdentifier // ""' \
      "$RUN_DIR/focus_original.stdout"
  )"
  FRONTMOST_CAPTURED=1
}

restore_original_frontmost_application() {
  if [[ "$FRONTMOST_CAPTURED" != "1" ]]; then
    return 0
  fi
  local stdout_file="$RUN_DIR/focus_restore.stdout"
  local stderr_file="$RUN_DIR/focus_restore.stderr"
  if [[ "$FOCUS_RESTORE_MANIFESTED" != "1" ]]; then
    printf '%s\t%s\t%s\t%s\t%s\n' \
      "$MATRIX_VERSION" \
      "focus_restore" \
      "reactivate original frontmost PID $ORIGINAL_FRONTMOST_PID ($ORIGINAL_FRONTMOST_BUNDLE)" \
      "$stdout_file" \
      "$stderr_file" >>"$MANIFEST"
    FOCUS_RESTORE_MANIFESTED=1
  fi
  if ! /usr/bin/osascript -l JavaScript -e '
      ObjC.import("AppKit");
      function run(arguments) {
        const requestedPID = Number(arguments[0]);
        const requestedBundleIdentifier = arguments[1];
        const application =
          $.NSRunningApplication
            .runningApplicationWithProcessIdentifier(requestedPID);
        const runningBundleIdentifier =
          application.isNil() || application.bundleIdentifier.isNil()
            ? ""
            : ObjC.unwrap(application.bundleIdentifier);
        if (
          application.isNil() ||
          application.terminated ||
          runningBundleIdentifier !== requestedBundleIdentifier
        ) {
          return JSON.stringify({
            requestedPID: requestedPID,
            requestedBundleIdentifier: requestedBundleIdentifier,
            running: false,
            restored: true,
            reason: "original-application-exited-or-pid-reused"
          });
        }
        const options =
          Number($.NSApplicationActivateAllWindows) |
          Number($.NSApplicationActivateIgnoringOtherApps);
        const activationRequested = Boolean(
          application.activateWithOptions(options)
        );
        delay(0.2);
        const frontmost =
          $.NSWorkspace.sharedWorkspace.frontmostApplication;
        const frontmostPID = frontmost.isNil()
          ? 0
          : Number(frontmost.processIdentifier);
        return JSON.stringify({
          requestedPID: requestedPID,
          requestedBundleIdentifier: requestedBundleIdentifier,
          running: true,
          activationRequested: activationRequested,
          frontmostPID: frontmostPID,
          restored: frontmostPID === requestedPID
        });
      }
    ' "$ORIGINAL_FRONTMOST_PID" "$ORIGINAL_FRONTMOST_BUNDLE" \
      >"$stdout_file" 2>"$stderr_file"; then
    echo \
      "[playcover-fixture-live] FAIL: could not restore the original host App" \
      >&2
    return 1
  fi
  if ! jq -e \
      --arg bundle "$ORIGINAL_FRONTMOST_BUNDLE" \
      --argjson pid "$ORIGINAL_FRONTMOST_PID" '
        .requestedPID == $pid and
        .requestedBundleIdentifier == $bundle and
        .restored == true and
        (
          .running == false or
          (
            .activationRequested == true and
            .frontmostPID == $pid
          )
        )
      ' "$stdout_file" >/dev/null; then
    echo \
      "[playcover-fixture-live] FAIL: original host App was not restored" \
      >&2
    return 1
  fi
}

cleanup() {
  # Cleanup failures are retained as evidence, but cannot mask the live gate.
  local original_exit_status=$?
  IOS_USE_HOME="$SESSION_HOME" "$ROOT_DIR/ios-use" stop \
    >"$RUN_DIR/cleanup.stdout" 2>"$RUN_DIR/cleanup.stderr" || true
  archive_session_home || true
  restore_original_frontmost_application || true
  exit "$original_exit_status"
}
trap cleanup EXIT
on_error() {
  echo "[playcover-fixture-live] Evidence retained at $RUN_DIR" >&2
}
trap on_error ERR

record_case() {
  local case_name="$1"
  shift
  local stdout_file="$RUN_DIR/${case_name}.stdout"
  local stderr_file="$RUN_DIR/${case_name}.stderr"
  printf '%s\t%s\t%s\t%s\t%s\n' \
    "$MATRIX_VERSION" \
    "$case_name" \
    "$*" \
    "$stdout_file" \
    "$stderr_file" >>"$MANIFEST"
  if ! IOS_USE_HOME="$SESSION_HOME" "$ROOT_DIR/ios-use" "$@" \
      >"$stdout_file" 2>"$stderr_file"; then
    echo "[playcover-fixture-live] FAIL: $case_name" >&2
    echo "[playcover-fixture-live] Evidence retained at $RUN_DIR" >&2
    return 1
  fi
}

record_host_case() {
  local case_name="$1"
  shift
  local stdout_file="$RUN_DIR/${case_name}.stdout"
  local stderr_file="$RUN_DIR/${case_name}.stderr"
  printf '%s\t%s\t%s\t%s\t%s\n' \
    "$MATRIX_VERSION" \
    "$case_name" \
    "$*" \
    "$stdout_file" \
    "$stderr_file" >>"$MANIFEST"
  if ! "$@" >"$stdout_file" 2>"$stderr_file"; then
    echo "[playcover-fixture-live] FAIL: $case_name" >&2
    if rg -q -- \
        'console session is locked|PostEvent access is not granted' \
        "$stderr_file"; then
      echo \
        "[playcover-fixture-live] An unlocked console and PostEvent permission are required." \
        >&2
    fi
    echo "[playcover-fixture-live] Evidence retained at $RUN_DIR" >&2
    return 1
  fi
}

assert_evidence() {
  local case_name="$1"
  local pattern="$2"
  if ! rg -q -- "$pattern" "$RUN_DIR/${case_name}.stdout"; then
    echo "[playcover-fixture-live] FAIL: $case_name lacks $pattern" >&2
    echo "[playcover-fixture-live] Evidence retained at $RUN_DIR" >&2
    return 1
  fi
}

assert_json() {
  local case_name="$1"
  local expression="$2"
  if ! jq -e "$expression" \
      "$RUN_DIR/${case_name}.stdout" >/dev/null; then
    echo \
      "[playcover-fixture-live] FAIL: $case_name JSON contract failed" \
      >&2
    echo "[playcover-fixture-live] jq: $expression" >&2
    echo "[playcover-fixture-live] Evidence retained at $RUN_DIR" >&2
    return 1
  fi
}

assert_cli_refresh_timing_log() {
  local command="$1"
  local cli_log="$SESSION_HOME/logs/cli.log"
  if ! rg -q \
      "\\[cli\\] command=${command} ok=true commandElapsedMs=[0-9.]+ alertRefreshElapsedMs=[0-9.]+" \
      "$cli_log"; then
    echo \
      "[playcover-fixture-live] FAIL: cli.log lacks compact refresh timing for $command" \
      >&2
    return 1
  fi
  if rg -q \
      'runtimeRoundTrip|runtimeRequest|ElapsedCount|RefreshCount' \
      "$cli_log"; then
    echo \
      "[playcover-fixture-live] FAIL: cli.log retained removed nested/count timing" \
      >&2
    return 1
  fi
}

assert_failure_json() {
  local case_name="$1"
  local expression="$2"
  local suffix
  for suffix in stdout stderr; do
    if jq -e "$expression" \
        "$RUN_DIR/${case_name}.${suffix}" >/dev/null 2>&1; then
      return 0
    fi
  done
  echo \
    "[playcover-fixture-live] FAIL: $case_name failure JSON contract failed" \
    >&2
  echo "[playcover-fixture-live] Evidence retained at $RUN_DIR" >&2
  return 1
}

assert_window_overlay_dom() {
  local case_name="$1"
  local expected_state="$2"
  local expected_count="$3"
  local expected_cover_label="${4:-}"
  local expected_cover_count=0
  if [[ -n "$expected_cover_label" ]]; then
    expected_cover_count=1
  fi
  if ! jq -e \
      --arg state "$expected_state" \
      --arg count "Count $expected_count" \
      --arg cover "$expected_cover_label" \
      --argjson coverCount "$expected_cover_count" '
        .ok == true and
        (.data.elements as $elements |
          ([
            $elements[] |
            select(
              .identifier ==
                "fixture.uikit.window-overlay.show" and
              .value == $state
            )
          ] | length) == 1 and
          ([
            $elements[] |
            select(
              .identifier == "fixture.uikit.count" and
              .label == $count
            )
          ] | length) == 1 and
          ([
            $elements[] |
            select(
              .identifier ==
                "fixture.uikit.window-overlay.cover"
            )
          ] | length) == $coverCount and
          ($coverCount == 0 or
            ([
              $elements[] |
              select(
                .identifier ==
                  "fixture.uikit.window-overlay.cover" and
                .label == $cover
              )
            ] | length) == 1) and
          ([
            $elements[] |
            select(
              .identifier ==
                "fixture.uikit.window-overlay.dismiss"
            )
          ] | length) == $coverCount)
      ' "$RUN_DIR/${case_name}.stdout" >/dev/null; then
    echo \
      "[playcover-fixture-live] FAIL: $case_name window overlay DOM state is invalid" \
      >&2
    echo "[playcover-fixture-live] Evidence retained at $RUN_DIR" >&2
    return 1
  fi
}

assert_semantic_tap_blocked_by_window() {
  local case_name="$1"
  local expected_state="$2"
  local expected_count="$3"
  local expected_cover_label="$4"
  local stdout_file="$RUN_DIR/${case_name}.stdout"
  local stderr_file="$RUN_DIR/${case_name}.stderr"
  printf '%s\t%s\t%s\t%s\t%s\n' \
    "$MATRIX_VERSION" \
    "$case_name" \
    'tap Increment --json (expected element_not_hittable at hit-test)' \
    "$stdout_file" \
    "$stderr_file" >>"$MANIFEST"
  if IOS_USE_HOME="$SESSION_HOME" "$ROOT_DIR/ios-use" \
      tap "Increment" --json \
      >"$stdout_file" 2>"$stderr_file"; then
    echo \
      "[playcover-fixture-live] FAIL: $case_name delivered through a blocking UIWindow" \
      >&2
    return 1
  fi
  assert_failure_json "$case_name" '
    .ok == false and
    .error.category == "interaction" and
    .error.code == "element_not_hittable" and
    .error.phase == "hit-test"
  '

  local post_case="${case_name}_post_dom"
  record_case "$post_case" dom --json
  assert_window_overlay_dom \
    "$post_case" \
    "$expected_state" \
    "$expected_count" \
    "$expected_cover_label"
}

assert_swiftui_overlap_blocks_increment() {
  local case_name="$1"
  local expected_state="$2"
  local expected_enabled="$3"
  local stdout_file="$RUN_DIR/${case_name}.stdout"
  local stderr_file="$RUN_DIR/${case_name}.stderr"
  printf '%s\t%s\t%s\t%s\t%s\n' \
    "$MATRIX_VERSION" \
    "$case_name" \
    'tap SwiftUI Increment --json (expected overlapping semantic failure)' \
    "$stdout_file" \
    "$stderr_file" >>"$MANIFEST"
  if IOS_USE_HOME="$SESSION_HOME" "$ROOT_DIR/ios-use" \
      tap "SwiftUI Increment" --json \
      >"$stdout_file" 2>"$stderr_file"; then
    echo \
      "[playcover-fixture-live] FAIL: $case_name delivered through an overlapping SwiftUI node" \
      >&2
    return 1
  fi
  assert_failure_json "$case_name" '
    .ok == false and
    .error.category == "interaction" and
    .error.code == "element_not_hittable" and
    .error.phase == "hit-test"
  '

  local post_case="${case_name}_post_dom"
  record_case "$post_case" dom --json
  assert_json "$post_case" "
    .data.elements as \\$elements |
    ([ \\$elements[] |
       select(
         .identifier == \"fixture.swiftui.overlay.advance\" and
         .value == \"$expected_state\"
       ) ] | length) == 1 and
    ([ \\$elements[] |
       select(
         .identifier == \"fixture.swiftui.increment-overlay\" and
         .state.enabled == $expected_enabled
       ) ] | length) == 1 and
    ([ \\$elements[] |
       select(
         .identifier == \"fixture.swiftui.count\" and
         .label == \"SwiftUI Count 1\"
       ) ] | length) == 1 and
    ([ \\$elements[] |
       select(
         .identifier == \"fixture.swiftui.overlay.count\" and
         .label == \"SwiftUI Overlay Count 0\"
       ) ] | length) == 1
  "
}

assert_native_alert_blocks_command() {
  local case_name="$1"
  shift
  local stdout_file="$RUN_DIR/${case_name}.stdout"
  local stderr_file="$RUN_DIR/${case_name}.stderr"
  printf '%s\t%s\t%s\t%s\t%s\n' \
    "$MATRIX_VERSION" \
    "$case_name" \
    "$*" \
    "$stdout_file" \
    "$stderr_file" >>"$MANIFEST"
  if IOS_USE_HOME="$SESSION_HOME" "$ROOT_DIR/ios-use" \
      "$@" --json >"$stdout_file" 2>"$stderr_file"; then
    echo \
      "[playcover-fixture-live] FAIL: $case_name mutated through a visible native alert" \
      >&2
    return 1
  fi
  assert_failure_json "$case_name" "
    .ok == false and
    .error.category == \"interaction\" and
    .error.code == \"preexisting_alert\" and
    .error.phase == \"precondition\" and
    .error.mutationMayHaveApplied == false and
    (has(\"performance\") | not) and
    .interaction.blocking == true and
    ([.interaction.interactions[].type] |
      index(\"inProcessAlert\")) != null
  "
}

expected_host_title_for_app() {
  local app_path="$1"
  local info_path="$app_path/Info.plist"
  local key
  local value
  for key in CFBundleDisplayName CFBundleName CFBundleIdentifier; do
    if value="$(
        /usr/bin/plutil -extract "$key" raw "$info_path" 2>/dev/null
      )" &&
      [[ -n "$value" && "$value" != "(null)" ]]; then
      printf '%s\n' "$value"
      return 0
    fi
  done
  return 1
}

assert_canonical_host_status() {
  local case_name="$1"
  if [[ -z "$EXPECTED_HOST_TITLE" ]]; then
    echo "[playcover-fixture-live] FAIL: expected host title is unset" >&2
    return 1
  fi
  if ! jq -e --arg title "$EXPECTED_HOST_TITLE" '
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
      .data.driver.runtime as $runtime |
      ($runtime.diagnostics.runtime.hookRegistry) as $hookRegistry |
      ($runtime.diagnostics.runtime.window) as $window |
      ($runtime.host) as $host |
      ($host.capture) as $capture |
      $runtime.status == "healthy" and
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
      $hookRegistry.requiredReady == true and
      ([ $hookRegistry.entries[] |
        select(.required == true and .ready != true) ] | length) == 0 and
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
      $host.canvasBounds ==
        {"x":0,"y":0,"width":430,"height":932} and
      ($host.contentBounds | rectangle) and
      $capture.ready == true and
      $capture.error == null and
      ($capture.canvasCGWindowRect | rectangle) and
      ($capture.hostContentCGWindowRect | rectangle) and
      rects_agree(
        $capture.canvasCGWindowRect;
        $capture.hostContentCGWindowRect
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
    echo \
      "[playcover-fixture-live] FAIL: $case_name does not prove the native Catalyst host contract" \
      >&2
    return 1
  fi
}

assert_canvas_only_screenshot() {
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
    echo \
      "[playcover-fixture-live] FAIL: $case_name is not a complete native-canvas 1290x2796 capture" \
      >&2
    return 1
  fi
}

assert_canvas_only_capture_manifest() {
  local manifest_path="$1"
  if ! jq -e '
      .schemaVersion == 2 and
      .status == "complete" and
      .sampledFrames >= 1 and
      .keptFrames >= 1 and
      ([.frames[].captureGeneration] as $generations |
        all($generations[]; . != null and . > 0) and
        all(range(1; ($generations | length));
          $generations[.] > $generations[. - 1])) and
      ([.frames[].snapshotGeneration] as $generations |
        all($generations[]; . != null and . > 0) and
        all(range(1; ($generations | length));
          $generations[.] >= $generations[. - 1])) and
      all(.frames[];
        .pixelSize == [1290,2796] and
        .logicalSize == [430,932] and
        .scale == 3 and
        .geometrySource == "screenshot-rect+driver-scale")
    ' "$manifest_path" >/dev/null; then
    echo \
      "[playcover-fixture-live] FAIL: capture manifest is not fixed canvas-only evidence" \
      >&2
    return 1
  fi
}

assert_ocr_evidence() {
  local case_name="$1"
  shift
  local ocr_path
  ocr_path="$(
    sed -nE \
      's/.*"ocrPath"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' \
      "$RUN_DIR/${case_name}.stdout"
  )"
  if [[ ! -f "$ocr_path" ]]; then
    echo "[playcover-fixture-live] FAIL: missing OCR for $case_name" >&2
    return 1
  fi
  local pattern
  for pattern in "$@"; do
    if ! rg -q -- "$pattern" "$ocr_path"; then
      echo "[playcover-fixture-live] FAIL: $case_name OCR lacks $pattern" >&2
      return 1
    fi
  done
}

assert_metal_pixel() {
  local case_name="$1"
  local image_path
  image_path="$(
    sed -nE \
      's/.*"imagePath"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' \
      "$RUN_DIR/${case_name}.stdout"
  )"
  if [[ ! -f "$image_path" ]]; then
    echo "[playcover-fixture-live] FAIL: missing image for $case_name" >&2
    return 1
  fi
  xcrun swift \
    "$ROOT_DIR/playcover-fixtures/assert_metal_pixel.swift" \
    "$image_path" \
    >"$RUN_DIR/${case_name}-pixel.stdout" \
    2>"$RUN_DIR/${case_name}-pixel.stderr"
}

activate_finder_for_screenshot() {
  local runner_pid="$1"
  record_frontmost_snapshot focus_target_before_diversion
  if ! jq -e \
      --argjson runner_pid "$runner_pid" '
        .pid == $runner_pid
      ' "$RUN_DIR/focus_target_before_diversion.stdout" >/dev/null; then
    echo \
      "[playcover-fixture-live] FAIL: fixture was not frontmost before the host-App diversion" \
      >&2
    return 1
  fi

  local stdout_file="$RUN_DIR/focus_divert_finder.stdout"
  local stderr_file="$RUN_DIR/focus_divert_finder.stderr"
  printf '%s\t%s\t%s\t%s\t%s\n' \
    "$MATRIX_VERSION" \
    "focus_divert_finder" \
    "activate already-running Finder by NSRunningApplication" \
    "$stdout_file" \
    "$stderr_file" >>"$MANIFEST"
  if ! /usr/bin/osascript -l JavaScript -e '
      ObjC.import("AppKit");
      const applications =
        $.NSRunningApplication
          .runningApplicationsWithBundleIdentifier("com.apple.finder");
      if (Number(applications.count) === 0) {
        throw new Error("Finder is not running");
      }
      const finder = applications.objectAtIndex(0);
      const options =
        Number($.NSApplicationActivateAllWindows) |
        Number($.NSApplicationActivateIgnoringOtherApps);
      const activationRequested = Boolean(
        finder.activateWithOptions(options)
      );
      delay(0.25);
      const frontmost =
        $.NSWorkspace.sharedWorkspace.frontmostApplication;
      function stringValue(value) {
        return value.isNil() ? "" : ObjC.unwrap(value);
      }
      JSON.stringify({
        finderPID: Number(finder.processIdentifier),
        activationRequested: activationRequested,
        frontmostPID: frontmost.isNil()
          ? 0
          : Number(frontmost.processIdentifier),
        frontmostBundleIdentifier: frontmost.isNil()
          ? ""
          : stringValue(frontmost.bundleIdentifier)
      });
    ' >"$stdout_file" 2>"$stderr_file"; then
    echo \
      "[playcover-fixture-live] FAIL: could not make Finder frontmost" \
      >&2
    return 1
  fi
  if ! jq -e \
      --argjson runner_pid "$runner_pid" '
        .activationRequested == true and
        .finderPID > 0 and
        .finderPID != $runner_pid and
        .frontmostPID == .finderPID and
        .frontmostBundleIdentifier == "com.apple.finder"
      ' "$stdout_file" >/dev/null; then
    echo \
      "[playcover-fixture-live] FAIL: Finder did not become the unrelated frontmost host App" \
      >&2
    return 1
  fi
}

poll_fixture_probe_status() {
  local case_name="$1"
  local identifier="$2"
  local stdout_file="$RUN_DIR/${case_name}.stdout"
  local stderr_file="$RUN_DIR/${case_name}.stderr"
  printf '%s\t%s\t%s\t%s\t%s\n' \
    "$MATRIX_VERSION" \
    "$case_name" \
    "dom --json (poll fixture.probe.status=$identifier)" \
    "$stdout_file" \
    "$stderr_file" >>"$MANIFEST"
  local observed=0
  local attempt
  for ((attempt = 1; attempt <= 30; attempt += 1)); do
    if IOS_USE_HOME="$SESSION_HOME" "$ROOT_DIR/ios-use" dom --json \
        >"$stdout_file" 2>"$stderr_file" &&
      jq -e \
        --arg identifier "$identifier" '
          (
            [.data.elements[] |
              select(
                .identifier == $identifier and
                .state.visible == true
              )
            ] | length
          ) == 1 and
          (
            [.data.elements[] |
              select(
                .identifier == "fixture.probe.status" and
                .label == ("Probe " + $identifier) and
                .value == $identifier
              )
            ] | length
          ) == 1
        ' "$stdout_file" >/dev/null; then
      observed=1
      break
    fi
    sleep 0.1
  done
  if [[ "$observed" != "1" ]]; then
    echo \
      "[playcover-fixture-live] FAIL: global mouse did not update fixture.probe.status to $identifier" \
      >&2
    return 1
  fi
}

run_global_mouse_probe() {
  local probe_case="$1"
  local probe_label="$2"
  local probe_identifier="$3"
  local case_prefix="mouse_probe_${probe_case}"
  local dom_case="${case_prefix}_before_dom"
  local status_case="${case_prefix}_before_status"
  local coordinates_file="$RUN_DIR/${case_prefix}_coordinates.json"
  local coordinates_stderr="$RUN_DIR/${case_prefix}_coordinates.stderr"

  record_case "$dom_case" dom --json
  record_case "$status_case" status --json
  assert_canonical_host_status "$status_case"
  printf '%s\t%s\t%s\t%s\t%s\n' \
    "$MATRIX_VERSION" \
    "${case_prefix}_coordinates" \
    "derive $probe_identifier logical point from fresh DOM and canonical canvas CG geometry" \
    "$coordinates_file" \
    "$coordinates_stderr" >>"$MANIFEST"
  if ! jq -e \
      --arg identifier "$probe_identifier" \
      --arg label "$probe_label" \
      --slurpfile status "$RUN_DIR/${status_case}.stdout" '
        . as $dom |
        ($status[0].data.driver.runtime) as $runtime |
        ($runtime.diagnostics.runtime.window) as $appKit |
        ($appKit.canvasCapture.canvasCGWindowRect) as $canvas |
        [
          $dom.data.elements[] |
          select(
            .identifier == $identifier and
            .label == $label and
            .state.visible == true and
            .state.enabled == true and
            (.frame | type) == "array" and
            (.frame | length) == 4 and
            .frame[2] > 0 and
            .frame[3] > 0 and
            .snapshotGeneration > 0
          )
        ] as $matches |
        if ($matches | length) != 1 then
          error("fresh DOM does not contain exactly one enabled probe")
        elif (
          [
            $dom.data.elements[] |
            select(
              .identifier == "fixture.probe.status" and
              .value != $identifier
            )
          ] | length
        ) != 1 then
          error("probe status was not fresh before the mouse event")
        elif (
          $runtime.status != "healthy" or
          $runtime.logicalWidth != 430 or
          $runtime.logicalHeight != 932 or
          $runtime.nativeWidth != 1290 or
          $runtime.nativeHeight != 2796 or
          $runtime.scale != 3 or
          $appKit.status != "configured" or
          $appKit.resizable != false or
          $appKit.nativeContentView != 1 or
          $appKit.canvasBounds !=
            {"x":0,"y":0,"width":430,"height":932} or
          ($canvas | type) != "object" or
          ($canvas.width | type) != "number" or
          $canvas.width <= 0 or
          ($canvas.height | type) != "number" or
          $canvas.height <= 0
        ) then
          error("canonical Runtime canvas geometry is not mouse-ready")
        else
          ($matches[0].frame) as $frame |
          ($frame[0] + ($frame[2] / 2)) as $logicalX |
          ($frame[1] + ($frame[3] / 2)) as $logicalY |
          if (
            $logicalX < 0 or
            $logicalX > $runtime.logicalWidth or
            $logicalY < 0 or
            $logicalY > $runtime.logicalHeight
          ) then
            error("probe center is outside the fixed device screen")
          else
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
              identifier: $identifier,
              label: $label,
              snapshotGeneration:
                $matches[0].snapshotGeneration,
              frame: $frame,
              logicalPoint: {
                x: $logicalX,
                y: $logicalY
              },
              globalPoint: {
                x: $globalX,
                y: $globalY
              },
              logicalSize: {
                width: $runtime.logicalWidth,
                height: $runtime.logicalHeight
              },
              runnerPID: $status[0].data.driver.runnerPid,
              canvasCGWindowRect: $canvas,
              mouseDeliveryCountBefore: 0
            }
            end
          end
        end
      ' "$RUN_DIR/${dom_case}.stdout" \
      >"$coordinates_file" 2>"$coordinates_stderr"; then
    echo \
      "[playcover-fixture-live] FAIL: could not derive $probe_identifier from fixed logical geometry" \
      >&2
    return 1
  fi

  local global_x
  local global_y
  local runner_pid
  read -r global_x global_y runner_pid < <(
    jq -r '
      [
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
  local mouse_case="${case_prefix}_event"
  record_host_case \
    "$mouse_case" \
    xcrun swift \
    "$ROOT_DIR/playcover-fixtures/appkit_mouse_event.swift" \
    "$global_x" \
    "$global_y" \
    "$event_token" \
    "$runner_pid"
  if ! jq -e \
      --argjson token "$event_token" \
      --argjson pid "$runner_pid" \
      --slurpfile coordinates "$coordinates_file" '
        ($coordinates[0].globalPoint) as $point |
        .operation == "click" and
        .token == $token and
        .targetPID == $pid and
        .targetWindowNumber > 0 and
        .postEventAccess == true and
        .globalPoint.x >= ($point.x - 0.5) and
        .globalPoint.x <= ($point.x + 0.5) and
        .globalPoint.y >= ($point.y - 0.5) and
        .globalPoint.y <= ($point.y + 0.5)
      ' "$RUN_DIR/${mouse_case}.stdout" >/dev/null; then
    echo \
      "[playcover-fixture-live] FAIL: $probe_identifier mouse helper evidence is not target-bound" \
      >&2
    return 1
  fi

  local post_dom_case="${case_prefix}_post_dom"
  poll_fixture_probe_status \
    "$post_dom_case" \
    "$probe_identifier"
  local delivery_evidence_case="${case_prefix}_delivery_evidence"
  record_case "$delivery_evidence_case" screenshot \
    --name "$delivery_evidence_case" --no-ocr --json
  assert_canvas_only_screenshot "$delivery_evidence_case"
  if ! jq -e \
      --argjson token "$event_token" \
      --slurpfile coordinates "$coordinates_file" \
      --slurpfile mouse "$RUN_DIR/${mouse_case}.stdout" \
      --slurpfile postDom "$RUN_DIR/${post_dom_case}.stdout" '
        ($coordinates[0]) as $coordinates |
        ($coordinates.logicalPoint) as $point |
        (.data.runtimeEvidence.appKitWindowEvidence) as $appKit |
        ($appKit.lastMouseDownDelivery) as $down |
        ($appKit.lastMouseUpDelivery) as $up |
        $appKit.status == "configured" and
        $down.token == $token and
        $up.token == $token and
        $down.targetPID == $coordinates.runnerPID and
        $up.targetPID == $coordinates.runnerPID and
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
        $down.sequence > $coordinates.mouseDeliveryCountBefore and
        $up.sequence > $down.sequence and
        $appKit.mouseDeliveryCount >= $up.sequence and
        $down.logicalPoint.x >= ($point.x - 0.5) and
        $down.logicalPoint.x <= ($point.x + 0.5) and
        $down.logicalPoint.y >= ($point.y - 0.5) and
        $down.logicalPoint.y <= ($point.y + 0.5) and
        $up.logicalPoint.x >= ($point.x - 0.5) and
        $up.logicalPoint.x <= ($point.x + 0.5) and
        $up.logicalPoint.y >= ($point.y - 0.5) and
        $up.logicalPoint.y <= ($point.y + 0.5) and
        (
          [$postDom[0].data.elements[] |
            select(
              .identifier == $coordinates.identifier and
              .state.visible == true and
              .snapshotGeneration >
                $coordinates.snapshotGeneration
            )
          ] | length
        ) == 1 and
        (
          [$postDom[0].data.elements[] |
            select(
              .identifier == "fixture.probe.status" and
              .label == ("Probe " + $coordinates.identifier) and
              .value == $coordinates.identifier and
              .snapshotGeneration >
                $coordinates.snapshotGeneration
            )
          ] | length
        ) == 1
      ' "$RUN_DIR/${delivery_evidence_case}.stdout" >/dev/null; then
    echo \
      "[playcover-fixture-live] FAIL: $probe_identifier lacks exact DOM/status/AppKit down-up evidence" \
      >&2
    return 1
  fi
}


assert_dom_unchanged() {
  local before_case="$1"
  local after_case="$2"
  if ! jq -e -n \
      --slurpfile before "$RUN_DIR/${before_case}.stdout" \
      --slurpfile after "$RUN_DIR/${after_case}.stdout" '
        def stableElements($document):
          [
            $document.data.elements[] |
            del(.nodeID, .snapshotGeneration, .zOrder,
              .hierarchy.parentID, .hierarchy.path, .hierarchy.index)
          ] | sort_by(
            [
              (.identifier // ""),
              (.label // ""),
              (.value // ""),
              (.frame | tostring),
              (.class // "")
            ] | tostring
          );
        stableElements($before[0]) == stableElements($after[0])
      ' >/dev/null; then
    echo \
      "[playcover-fixture-live] FAIL: system title-bar click changed the App DOM" \
      >&2
    return 1
  fi
}

click_titlebar_and_assert_app_unchanged() {
  local case_name="non_target_titlebar"
  local before_dom_case="${case_name}_before_dom"
  local before_status_case="${case_name}_before_status"
  local coordinates_file="$RUN_DIR/${case_name}_coordinates.json"
  record_case "$before_dom_case" dom --json
  record_case "$before_status_case" status --json
  assert_canonical_host_status "$before_status_case"
  if ! jq -e \
      --slurpfile status "$RUN_DIR/${before_status_case}.stdout" '
        ($status[0].data.driver.runtime.diagnostics.runtime.window) as $window |
        ($window.canvasCapture) as $capture |
        ($capture.hostCGWindowBounds) as $outer |
        ($capture.hostContentCGWindowRect) as $content |
        ($capture.canvasCGWindowRect) as $canvas |
        if (
          ($outer | type) != "object" or
          ($content | type) != "object" or
          ($canvas | type) != "object"
        ) then
          error("host/canvas global geometry is unavailable")
        elif $content.y <= ($outer.y + 2) then
          error("system title bar has no measurable global region")
        else
          {
            surface: "titlebar",
            globalPoint: {
              x: ($outer.x + ($outer.width * 0.70)),
              y: ($outer.y + (($content.y - $outer.y) / 2))
            }
          }
        end |
        . as $result |
        ($result.globalPoint) as $point |
        if (
          $point.x >= $canvas.x and
          $point.x <= ($canvas.x + $canvas.width) and
          $point.y >= $canvas.y and
          $point.y <= ($canvas.y + $canvas.height)
        ) then
          error("derived non-target point lies in the target canvas")
        else
          $result + {
            runnerPID: $status[0].data.driver.runnerPid,
            mouseDeliveryCountBefore: 0
          }
        end
      ' >"$coordinates_file"; then
    echo \
      "[playcover-fixture-live] FAIL: could not derive system title-bar click point" \
      >&2
    return 1
  fi
  local global_x
  local global_y
  local runner_pid
  read -r global_x global_y runner_pid < <(
    jq -r '[.globalPoint.x, .globalPoint.y, .runnerPID] | @tsv' \
      "$coordinates_file"
  )
  MOUSE_SEQUENCE="$((MOUSE_SEQUENCE + 1))"
  local event_token
  event_token="$(
    printf '%s%04d%02d' \
      "$(date +%s)" \
      "$(( $$ % 10000 ))" \
      "$MOUSE_SEQUENCE"
  )"
  record_host_case \
    "${case_name}_event" \
    xcrun swift \
    "$ROOT_DIR/playcover-fixtures/appkit_mouse_event.swift" \
    "$global_x" \
    "$global_y" \
    "$event_token" \
    "$runner_pid"
  local after_dom_case="${case_name}_after_dom"
  local after_evidence_case="${case_name}_after_evidence"
  record_case "$after_dom_case" dom --json
  record_case "$after_evidence_case" screenshot \
    --name "$after_evidence_case" --no-ocr --json
  assert_canvas_only_screenshot "$after_evidence_case"
  if ! jq -e \
      --argjson token "$event_token" \
      --slurpfile coordinates "$coordinates_file" \
      --slurpfile mouse "$RUN_DIR/${case_name}_event.stdout" '
        ($coordinates[0]) as $coordinates |
        (.data.runtimeEvidence.appKitWindowEvidence) as $window |
        ($window.lastMouseDownDelivery) as $down |
        ($window.lastMouseUpDelivery) as $up |
        $mouse[0].operation == "click" and
        $mouse[0].targetPID == $coordinates.runnerPID and
        $mouse[0].targetWindowNumber > 0 and
        $down.token == $token and
        $up.token == $token and
        $down.targetPID == $coordinates.runnerPID and
        $up.targetPID == $coordinates.runnerPID and
        $down.phase == "down" and
        $up.phase == "up" and
        $down.geometryReady == true and
        $up.geometryReady == true and
        $down.targetHitTest == false and
        $up.targetHitTest == false and
        $down.logicalPoint == null and
        $up.logicalPoint == null and
        $down.sequence > $coordinates.mouseDeliveryCountBefore and
        $up.sequence > $down.sequence
      ' "$RUN_DIR/${after_evidence_case}.stdout" >/dev/null; then
    echo \
      "[playcover-fixture-live] FAIL: system title-bar click was routed into the target canvas" \
      >&2
    return 1
  fi
  assert_dom_unchanged "$before_dom_case" "$after_dom_case"
}

bash "$ROOT_DIR/scripts/build_swift_cli.sh" \
  >"$RUN_DIR/build-cli.stdout" \
  2>"$RUN_DIR/build-cli.stderr"

if [[ -z "$FIXTURE_APP" ]]; then
  bash "$ROOT_DIR/playcover-fixtures/build.sh" \
    >"$RUN_DIR/build-fixture.stdout" \
    2>"$RUN_DIR/build-fixture.stderr"
  FIXTURE_APP="$ROOT_DIR/playcover-fixtures/.build/DerivedData/Build/Products/Release-iphoneos/IOSUsePlayFixture.app"
fi
if [[ ! -d "$FIXTURE_APP" ]]; then
  echo "[playcover-fixture-live] Fixture App unavailable: $FIXTURE_APP" >&2
  echo "[playcover-fixture-live] Evidence retained at $RUN_DIR" >&2
  exit 78
fi

printf '%s\n' "$MATRIX_VERSION" >"$RUN_DIR/matrix-version"
printf '%s\n' "$FIXTURE_APP" >"$RUN_DIR/fixture-app-path"
EXPECTED_HOST_TITLE="$(expected_host_title_for_app "$FIXTURE_APP")" || {
  echo \
    "[playcover-fixture-live] FAIL: Fixture App has no title-bar fallback metadata" \
    >&2
  exit 78
}
printf '%s\n' "$EXPECTED_HOST_TITLE" >"$RUN_DIR/expected-host-title"

capture_original_frontmost_application
record_case start start --mac --app "$FIXTURE_APP" --log
record_case status status --json
assert_evidence status \
  '"status"[[:space:]]*:[[:space:]]*"healthy"'
assert_evidence status '"diagnostics"'
assert_evidence status \
  '"logicalWidth"[[:space:]]*:[[:space:]]*430'
assert_evidence status \
  '"logicalHeight"[[:space:]]*:[[:space:]]*932'
assert_evidence status \
  '"scale"[[:space:]]*:[[:space:]]*3'
assert_json status '
  .data.driver.runtime as $runtime |
  $runtime.status == "healthy" and
  $runtime.identityVerified == true and
  $runtime.logicalWidth == 430 and
  $runtime.logicalHeight == 932 and
  $runtime.nativeWidth == 1290 and
  $runtime.nativeHeight == 2796 and
  $runtime.scale == 3 and
  $runtime.diagnostics.socket.transport == "unix-domain-socket" and
  $runtime.diagnostics.socket.status == "listening"
'
if ! jq -e \
    --arg appsRoot "$PLAYCOVER_APPS_ROOT" '
      .data.driver as $driver |
      $driver.macInstallRevision as $revision |
      ($revision |
        type == "string" and
        test("^[0-9a-f]{64}$")) and
      ($driver.macAppPath |
        startswith(
          $appsRoot + "/" + $driver.bundleId + "/"
        )) and
      ($driver.macExecutablePath |
        startswith($driver.macAppPath + "/"))
    ' "$RUN_DIR/status.stdout" >/dev/null; then
  echo \
    "[playcover-fixture-live] FAIL: status did not bind the account-global Bundle slot." \
    >&2
  exit 1
fi
assert_canonical_host_status status

runner_pid="$(jq -er '.data.driver.runnerPid' "$RUN_DIR/status.stdout")"
session_identifier="$(
  jq -er '.data.driver.sessionIdentifier' "$RUN_DIR/status.stdout"
)"
stdio_log_path="$(
  jq -er '.data.driver.macLogPath' "$RUN_DIR/status.stdout"
)"
lower_session_identifier="$(
  printf '%s' "$session_identifier" |
    /usr/bin/tr '[:upper:]' '[:lower:]'
)"
expected_stdio_log_path="$SESSION_LOG_DIR/stdio-$lower_session_identifier.log"
if [[
  "$stdio_log_path" != "$expected_stdio_log_path" ||
  ! -f "$stdio_log_path" ||
  -L "$stdio_log_path" ||
  "$(/usr/bin/stat -f '%u' "$stdio_log_path")" != "$(/usr/bin/id -u)" ||
  "$(/usr/bin/stat -f '%Lp' "$stdio_log_path")" != "600" ||
  "$(/usr/bin/stat -f '%l' "$stdio_log_path")" != "1"
]]; then
  echo \
    "[playcover-fixture-live] FAIL: start did not create the exact owner-only per-session stdio log" \
    >&2
  exit 1
fi
stdio_log_device="$(/usr/bin/stat -f '%d' "$stdio_log_path")"
stdio_log_inode="$(/usr/bin/stat -f '%i' "$stdio_log_path")"
stdio_log_identity="$(
  /usr/bin/stat -f '%d:%i:%u:%Lp:%l' "$stdio_log_path"
)"
if ! jq -e \
    --arg path "$stdio_log_path" \
    --arg device "$stdio_log_device" \
    --arg inode "$stdio_log_inode" '
      .data.driver.macLogPath == $path and
      .data.driver.runtime.stdio.status == "redirected" and
      .data.driver.runtime.stdio.path == $path and
      .data.driver.runtime.stdio.device == $device and
      .data.driver.runtime.stdio.inode == $inode and
      .data.driver.runtime.stdio.failureStage == null and
      .data.driver.runtime.stdio.errorNumber == null
    ' "$RUN_DIR/status.stdout" >/dev/null; then
  echo \
    "[playcover-fixture-live] FAIL: status omitted exact Runtime stdio identity" \
    >&2
  exit 1
fi
stdio_markers_observed=0
for _ in $(seq 1 100); do
  if rg -Fq \
      "[ios-use-play-fixture] stdout $session_identifier" \
      "$stdio_log_path" &&
    rg -Fq \
      "[ios-use-play-fixture] stderr $session_identifier" \
      "$stdio_log_path"; then
    stdio_markers_observed=1
    break
  fi
  sleep 0.05
done
if [[ "$stdio_markers_observed" != "1" ]]; then
  echo \
    "[playcover-fixture-live] FAIL: live stdio log omitted fixture stdout/stderr markers" \
    >&2
  exit 1
fi
runtime_socket_path="$(
  jq -er \
    '.data.driver.macRuntimeSocketPath' \
    "$RUN_DIR/status.stdout"
)"
case "$runtime_socket_path" in
  "$PLAYCOVER_SOCKET_ROOT"/s-*.sock) ;;
  *)
    echo \
      "[playcover-fixture-live] FAIL: Runtime socket escaped the fixed UID socket root." \
      >&2
    exit 1
    ;;
esac
record_case oslog_exact oslog --pid "$runner_pid" \
  --pattern 'ios-use-runtime' --timeout 1s
assert_evidence oslog_exact '\[ios-use-runtime\]'
assert_evidence oslog_exact \
  '"bundleIdentifier":"com.iosuse.playfixture.stablev1"'

oslog_wrong_pid_stdout="$RUN_DIR/oslog_wrong_pid.stdout"
oslog_wrong_pid_stderr="$RUN_DIR/oslog_wrong_pid.stderr"
wrong_pid="$((runner_pid + 1))"
printf '%s\t%s\t%s\t%s\t%s\n' \
  "$MATRIX_VERSION" \
  "oslog_wrong_pid" \
  "oslog --pid $wrong_pid --timeout 1s" \
  "$oslog_wrong_pid_stdout" \
  "$oslog_wrong_pid_stderr" >>"$MANIFEST"
if IOS_USE_HOME="$SESSION_HOME" "$ROOT_DIR/ios-use" \
    oslog --pid "$wrong_pid" --timeout 1s \
    >"$oslog_wrong_pid_stdout" 2>"$oslog_wrong_pid_stderr"; then
  echo \
    "[playcover-fixture-live] FAIL: oslog accepted a non-session PID" \
    >&2
  exit 1
fi
if ! rg -q -- "scoped to active PID $runner_pid" \
    "$oslog_wrong_pid_stdout" "$oslog_wrong_pid_stderr"; then
  echo \
    "[playcover-fixture-live] FAIL: oslog wrong-PID rejection is not exact" \
    >&2
  exit 1
fi

activate_finder_for_screenshot "$runner_pid"
record_case screenshot_initial screenshot \
  --name initial --json
assert_evidence screenshot_initial '"snapshotGeneration"'
assert_evidence screenshot_initial '"captureGeneration"'
assert_evidence screenshot_initial '"runtimeEvidence"'
assert_evidence screenshot_initial '"syntheticChrome"'
assert_evidence screenshot_initial '"fullFrame"'
assert_evidence screenshot_initial '"appKitWindowEvidence"'
assert_evidence screenshot_initial '"compositor"'
assert_canvas_only_screenshot screenshot_initial
initial_safe_area_evidence_generation="$(
  jq -er '
    .data.runtimeEvidence.appKitWindowEvidence
      .safeAreaCompatibility.compatibilityHook
      .targetFirstEligibleProviderInvocation.generation
  ' "$RUN_DIR/screenshot_initial.stdout"
)"

record_frontmost_snapshot focus_target_after_screenshot
if ! jq -e \
    --argjson runner_pid "$runner_pid" '
      .pid == $runner_pid
    ' "$RUN_DIR/focus_target_after_screenshot.stdout" >/dev/null; then
  echo \
    "[playcover-fixture-live] FAIL: screenshot did not restore the target as frontmost" \
    >&2
  exit 1
fi
record_case status_after_screenshot_refocus status --json
assert_canonical_host_status status_after_screenshot_refocus

record_case capture_short capture --duration 500ms --fps 4 \
  --name fixture-live
capture_manifest="$(
  sed -nE 's/^Manifest: (.*)$/\1/p' \
    "$RUN_DIR/capture_short.stdout"
)"
if [[ ! -f "$capture_manifest" ]]; then
  echo \
    "[playcover-fixture-live] FAIL: capture manifest is unavailable" \
    >&2
  exit 1
fi
assert_canvas_only_capture_manifest "$capture_manifest"

record_case dom_initial dom --json
assert_evidence dom_initial 'fixture.uikit.increment'
assert_evidence dom_initial 'fixture.full.top-left'
assert_evidence dom_initial 'fixture.safe-area.first-read-header'
assert_json dom_initial '
  ([.data.elements[] |
    select(
      .identifier == "fixture.safe-area.first-read-header"
    )][0]) as $header |
  $header.label == "First Read Header" and
  $header.value ==
    "height=129 safeTop=59 source=window-safe-area statusBar=59" and
  (($header.frame[3] - 129) | fabs) <= 0.5
'

missing_stdout="$RUN_DIR/missing_target.stdout"
missing_stderr="$RUN_DIR/missing_target.stderr"
printf '%s\t%s\t%s\t%s\t%s\n' \
  "$MATRIX_VERSION" \
  "missing_target" \
  'tap missing target --json (expected current-page diagnostics)' \
  "$missing_stdout" \
  "$missing_stderr" >>"$MANIFEST"
if IOS_USE_HOME="$SESSION_HOME" "$ROOT_DIR/ios-use" \
    tap "__ios_use_missing_fixture_target__" --json \
    >"$missing_stdout" 2>"$missing_stderr"; then
  echo \
    "[playcover-fixture-live] FAIL: missing target unexpectedly resolved" \
    >&2
  exit 1
fi
assert_failure_json missing_target '
  .ok == false and
  .error.category == "lookup" and
  .error.code == "element_not_found" and
  .error.phase == "lookup" and
  (.data.candidates | length) > 0 and
  (.data.candidates | length) <= 5 and
  .data.candidateCount >= (.data.candidates | length) and
  all(.data.candidates[]; .rejectedBy == ["label_mismatch"]) and
  (.data.suggestions | length) > 0
'

record_case ui_tree_navigation ui-tree \
  --target 'fixture.uikit.navigation-bar' --depth 5 --json
assert_json ui_tree_navigation '
  .data.target == "fixture.uikit.navigation-bar" and
  .data.nodeCount >= 1 and
  (.data.roots | length) == 1 and
  .data.roots[0].class == "UINavigationBar" and
  .data.roots[0].accessibilityIdentifier ==
    "fixture.uikit.navigation-bar" and
  ([.data.roots[0] | .. | objects |
    select(.class? == "UILabel")] | length) >= 1 and
  ([.data | .. | objects | select(has("address"))] | length) == 0
'

absolute_tap_x="$(
  jq -er '
    [.data.elements[] |
      select(.label == "No-op Target" and .state.visible == true)][0]
      .frame |
    .[0] + (.[2] * 0.25)
  ' "$RUN_DIR/dom_initial.stdout"
)"
absolute_tap_y="$(
  jq -er '
    [.data.elements[] |
      select(.label == "No-op Target" and .state.visible == true)][0]
      .frame |
    .[1] + (.[3] * 0.25)
  ' "$RUN_DIR/dom_initial.stdout"
)"
record_case absolute_tap tap \
  "$absolute_tap_x,$absolute_tap_y" --json
if ! jq -e \
    --argjson x "$absolute_tap_x" \
    --argjson y "$absolute_tap_y" '
      ((.data.finalState.point[0] - $x) | fabs) < 0.001 and
      ((.data.finalState.point[1] - $y) | fabs) < 0.001 and
      .data.finalState.phase == "ended"
    ' "$RUN_DIR/absolute_tap.stdout" >/dev/null; then
  echo \
    "[playcover-fixture-live] FAIL: absolute tap was remapped away from its logical point" \
    >&2
  exit 1
fi

record_case tap tap "Increment" --dom --json
assert_evidence tap 'Count 1'

record_case tap_explicit_exposed tap "Increment" \
  --offset-ratio 0.1,0.5 --dom --json
assert_evidence tap_explicit_exposed 'Count 2'

record_case tap_offset_top_left tap "Increment" \
  --offset 4,4 --dom --json
assert_evidence tap_offset_top_left 'Count 3'

covered_stdout="$RUN_DIR/tap_explicit_covered.stdout"
covered_stderr="$RUN_DIR/tap_explicit_covered.stderr"
printf '%s\t%s\t%s\t%s\t%s\n' \
  "$MATRIX_VERSION" \
  "tap_explicit_covered" \
  'tap Increment --offset-ratio 0.5,0.5 --json (expected element_not_hittable)' \
  "$covered_stdout" \
  "$covered_stderr" >>"$MANIFEST"
if IOS_USE_HOME="$SESSION_HOME" "$ROOT_DIR/ios-use" \
    tap "Increment" --offset-ratio 0.5,0.5 --json \
    >"$covered_stdout" 2>"$covered_stderr"; then
  echo \
    "[playcover-fixture-live] FAIL: covered explicit ratio was relocated" \
    >&2
  exit 1
fi
assert_failure_json tap_explicit_covered '
  .ok == false and
  .error.code == "element_not_hittable" and
  .error.phase == "hit-test" and
  .data.candidateCount == 1 and
  .data.candidates[0].label == "Increment" and
  .data.candidates[0].rejectedBy == ["explicit_point_not_owned"] and
  .data.suggestions ==
    ["remove the explicit offset and use automatic placement"]
'
record_case tap_covered_post_dom dom --json
assert_evidence tap_covered_post_dom 'Count 3'

record_case no_op tap "No-op Target" --json
assert_json no_op '
  .data.element.label == "No-op Target"
'

disabled_stdout="$RUN_DIR/disabled_target.stdout"
disabled_stderr="$RUN_DIR/disabled_target.stderr"
printf '%s\t%s\t%s\t%s\t%s\n' \
  "$MATRIX_VERSION" \
  "disabled_target" \
  'tap Disabled Target --json (expected element_not_hittable)' \
  "$disabled_stdout" \
  "$disabled_stderr" >>"$MANIFEST"
if IOS_USE_HOME="$SESSION_HOME" "$ROOT_DIR/ios-use" \
    tap "Disabled Target" --json \
    >"$disabled_stdout" 2>"$disabled_stderr"; then
  echo \
    "[playcover-fixture-live] FAIL: disabled target reported successful delivery" \
    >&2
  exit 1
fi
assert_failure_json disabled_target '
  .ok == false and
  .error.code == "element_not_hittable" and
  .error.phase == "identity" and
  .data.candidateCount == 1 and
  .data.candidates[0].label == "Disabled Target" and
  .data.candidates[0].rejectedBy == ["disabled"] and
  .data.suggestions == ["wait for the target to become enabled"]
'

record_case window_overlay_same_show \
  tap "Show Window Overlay" --json
record_case window_overlay_same_visible dom --json
assert_window_overlay_dom \
  window_overlay_same_visible \
  "same-level visible non-key" \
  3 \
  "Same-Level Non-Key Window Cover"
assert_semantic_tap_blocked_by_window \
  window_overlay_same_blocked \
  "same-level visible non-key" \
  3 \
  "Same-Level Non-Key Window Cover"
record_case window_overlay_same_dismiss \
  tap "Dismiss Window Overlay" --json
record_case window_overlay_same_dismissed dom --json
assert_window_overlay_dom \
  window_overlay_same_dismissed "none" 3

record_case window_overlay_high_show \
  tap "Show Window Overlay" --json
record_case window_overlay_high_visible dom --json
assert_window_overlay_dom \
  window_overlay_high_visible \
  "higher-level visible non-key" \
  3 \
  "Higher-Level Non-Key Window Cover"
assert_semantic_tap_blocked_by_window \
  window_overlay_high_blocked \
  "higher-level visible non-key" \
  3 \
  "Higher-Level Non-Key Window Cover"
record_case window_overlay_high_dismiss \
  tap "Dismiss Window Overlay" --json
record_case window_overlay_high_dismissed dom --json
assert_window_overlay_dom \
  window_overlay_high_dismissed "none" 3

record_case window_overlay_passthrough_show \
  tap "Show Window Overlay" --json
record_case window_overlay_passthrough_visible dom --json
assert_window_overlay_dom \
  window_overlay_passthrough_visible \
  "passthrough higher-level visible non-key" \
  3 \
  "Passthrough Higher-Level Window Cover"
record_case window_overlay_passthrough_tap \
  tap "Increment" --dom --json
assert_json window_overlay_passthrough_tap '
  .data.element.identifier == "fixture.uikit.increment" and
  (.data.postDom.elements as $elements |
    ([
      $elements[] |
      select(
        .identifier == "fixture.uikit.count" and
        .label == "Count 4"
      )
    ] | length) == 1 and
    ([
      $elements[] |
      select(
        .identifier ==
          "fixture.uikit.window-overlay.show" and
        .value == "passthrough higher-level visible non-key"
      )
    ] | length) == 1)
'
record_case window_overlay_passthrough_dismiss \
  tap "Dismiss Window Overlay" --json
record_case window_overlay_passthrough_dismissed dom --json
assert_window_overlay_dom \
  window_overlay_passthrough_dismissed "none" 4

record_case longpress longpress "Long Press Target" \
  --duration 500ms --dom --json
assert_evidence longpress 'Long press recognized'

popup_stdout="$RUN_DIR/uikit_popup.stdout"
popup_stderr="$RUN_DIR/uikit_popup.stderr"
printf '%s\t%s\t%s\t%s\t%s\n' \
  "$MATRIX_VERSION" \
  "uikit_popup" \
  "Runtime touch and global AppKit mouse hit Confirm and Close" \
  "$popup_stdout" \
  "$popup_stderr" >>"$MANIFEST"
if ! IOS_USE_HOME="$SESSION_HOME" \
    IOS_USE_POPUP_CLI="$ROOT_DIR/ios-use" \
    IOS_USE_POPUP_EVIDENCE_DIR="$RUN_DIR/uikit-popup-evidence" \
    bash "$ROOT_DIR/playcover-fixtures/test_uikit_popup_contract.sh" \
      --live >"$popup_stdout" 2>"$popup_stderr"; then
  echo \
    "[playcover-fixture-live] FAIL: UIKit popup touch/mouse contract" \
    >&2
  echo "[playcover-fixture-live] Evidence retained at $RUN_DIR" >&2
  exit 1
fi
assert_evidence uikit_popup \
  'live Runtime touch \+ global AppKit mouse contract passed'

record_case input_seed input --tap "Fixture Input" \
  --content "abcdef" --enter --dom --json
assert_evidence input_seed 'abcdef'
assert_evidence input_seed 'Input return 1 abcdef'
assert_evidence input_seed \
  '"enter"[[:space:]]*:[[:space:]]*true'
record_case input_delete input --tap "Fixture Input" --content "Z" \
  --delete 99 --dom --json
assert_evidence input_delete \
  '"deleteCount"[[:space:]]*:[[:space:]]*99'
assert_evidence input_delete \
  '"contentLength"[[:space:]]*:[[:space:]]*1'
assert_evidence input_delete \
  '"value"[[:space:]]*:[[:space:]]*"Z"'
assert_evidence input_delete 'Input value Z'
record_case input_unicode_seed input --tap "Fixture Input" \
  --content "👨‍👩‍👧‍👦" --delete 99 --dom --json
assert_evidence input_unicode_seed 'Input value 👨‍👩‍👧‍👦'
record_case input_unicode_delete input --tap "Fixture Input" \
  --content "U" --delete 1 --dom --json
assert_evidence input_unicode_delete \
  '"value"[[:space:]]*:[[:space:]]*"U"'
assert_evidence input_unicode_delete 'Input value U'

record_case alert_show_tap tap "Show Alert" --json
record_case alert_status status --json
assert_evidence alert_status '_NSAlertPanel'
assert_json alert_status '
  (has("performance") | not) and
  .interaction.blocking == true and
  ([.interaction.interactions[].type] |
    index("inProcessAlert")) != null and
  ([.warnings[] | select(contains("dismissAlert"))] |
    length) == 1
'
assert_cli_refresh_timing_log status
record_case alert_screenshot screenshot \
  --name native-alert --json
assert_evidence alert_screenshot '"compositorWindowNumbers"'
assert_canvas_only_screenshot alert_screenshot
assert_json alert_screenshot '
  (has("performance") | not) and
  .interaction.blocking == true and
  .data.runtimeEvidence.appKitWindowEvidence as $appkit |
  $appkit.nativeAlert as $alert |
  $alert.visible == 1 and
  $alert.frame == {"x":85,"y":356,"width":260,"height":219} and
  ([ $alert.actions[].label ] | sort) == ["Cancel","Confirm"] and
  all($alert.actions[];
    (.frame.x >= $alert.frame.x) and
    (.frame.y >= $alert.frame.y) and
    ((.frame.x + .frame.width) <=
      ($alert.frame.x + $alert.frame.width)) and
    ((.frame.y + .frame.height) <=
      ($alert.frame.y + $alert.frame.height))) and
  ([$appkit.allWindows[] |
      select(.class == "_NSAlertPanel" and .visible == true)] |
    length) == 1 and
  ((.data.runtimeEvidence.compositor.windows) as $windows |
    ([$windows[] | select(.class == "_NSAlertPanel")] |
      length) == 1 and
    ([$windows[] | select(.class == "_NSAlertPanel")][0] |
      .deviceLogicalRect ==
        {"x":85,"y":356,"width":260,"height":219}) and
    .data.runtimeEvidence.syntheticChrome == false and
    .data.runtimeEvidence.fullFrame.uncropped == true and
    .data.runtimeEvidence.fullFrame.safeAreaCropped == false)
'
assert_ocr_evidence alert_screenshot \
  "Fixture Alert" "Confirm" "Cancel"
record_case alert_dom dom --json
assert_evidence alert_dom 'Fixture Alert'
assert_evidence alert_dom 'Confirm'
assert_evidence alert_dom 'Cancel'
assert_json alert_dom '
  (has("performance") | not) and
  .interaction.blocking == true and
  ([.warnings[] | select(contains("dismissAlert"))] |
    length) == 1
'
assert_native_alert_blocks_command \
  alert_underlay_tap tap "Increment"
assert_native_alert_blocks_command \
  alert_absolute_outside tap 10,10
assert_native_alert_blocks_command \
  alert_underlay_longpress \
  longpress "Long Press Target" --duration 100ms
assert_native_alert_blocks_command \
  alert_underlay_swipe \
  swipe --from "Increment" --dir forth --distance 50
assert_native_alert_blocks_command \
  alert_underlay_input \
  input --tap "Fixture Input" --content blocked
assert_native_alert_blocks_command \
  alert_tap_confirm tap "Confirm"
assert_native_alert_blocks_command \
  alert_open_underlay open "iosusefixture://blocked"
record_case alert_dismiss_confirm \
  dismissAlert --label "Confirm" --json
assert_json alert_dismiss_confirm '
  .data.dismissed == true and
  .data.button == "Confirm" and
  .data.reason == "label" and
  (has("performance") | not)
'
record_case alert_confirmed waitFor "Alert Confirmed" \
  --timeout 10s --json

record_case alert_show_label tap "Show Alert" --json
alert_missing_stdout="$RUN_DIR/alert_label_missing.stdout"
alert_missing_stderr="$RUN_DIR/alert_label_missing.stderr"
printf '%s\t%s\t%s\t%s\t%s\n' \
  "$MATRIX_VERSION" \
  "alert_label_missing" \
  'dismissAlert --label Missing --json (expected exact-label failure)' \
  "$alert_missing_stdout" \
  "$alert_missing_stderr" >>"$MANIFEST"
if IOS_USE_HOME="$SESSION_HOME" "$ROOT_DIR/ios-use" \
    dismissAlert --label "Missing" --json \
    >"$alert_missing_stdout" 2>"$alert_missing_stderr"; then
  echo \
    "[playcover-fixture-live] FAIL: missing alert label fell back to another action" \
    >&2
  exit 1
fi
assert_failure_json alert_label_missing '
  .ok == false and
  .error.category == "lookup" and
  .error.code == "alert_action_not_found" and
  .error.phase == "lookup"
'
record_case alert_label_missing_still_visible status --json
assert_json alert_label_missing_still_visible '
  .data.driver.runtime.observed.appKit.nativeAlert as $alert |
  $alert.visible == 1 and
  ([ $alert.actions[].label ] | sort) == ["Cancel","Confirm"]
'
record_case alert_label dismissAlert --label "Confirm" --json
assert_json alert_label '
  .data.dismissed == true and
  .data.button == "Confirm" and
  .data.reason == "label"
'
record_case alert_label_gone waitFor "Fixture Alert" \
  --gone --timeout 10s --json

record_case alert_show_default tap "Show Alert" --json
for selection_case in alert_default alert_only_button; do
  selection_stdout="$RUN_DIR/${selection_case}.stdout"
  selection_stderr="$RUN_DIR/${selection_case}.stderr"
  if [[ "$selection_case" == "alert_default" ]]; then
    selection_args=()
  else
    selection_args=(--only-button)
  fi
  printf '%s\t%s\t%s\t%s\t%s\n' \
    "$MATRIX_VERSION" \
    "$selection_case" \
    "dismissAlert ${selection_args[*]} --json (expected guarded-selection failure)" \
    "$selection_stdout" \
    "$selection_stderr" >>"$MANIFEST"
  if IOS_USE_HOME="$SESSION_HOME" "$ROOT_DIR/ios-use" \
      dismissAlert "${selection_args[@]}" --json \
      >"$selection_stdout" 2>"$selection_stderr"; then
    echo \
      "[playcover-fixture-live] FAIL: only-button selection dismissed a two-button alert" \
      >&2
    exit 1
  fi
  assert_failure_json "$selection_case" '
    .ok == false and
    .error.category == "interaction" and
    .error.code == "alert_selection_required" and
    .error.phase == "selection" and
    .error.mutationMayHaveApplied == false and
    (has("performance") | not)
  '
done
record_case alert_default_still_visible status --json
assert_json alert_default_still_visible '
  .interaction.blocking == true and
  ([.interaction.interactions[].actions[].label] | sort) ==
    ["Cancel","Confirm"]
'
record_case alert_primary dismissAlert --primary --json
assert_json alert_primary '
  .data.dismissed == true and
  .data.button == "Confirm" and
  .data.reason == "visualPrimary" and
  (has("performance") | not)
'
record_case alert_primary_gone waitFor "Fixture Alert" \
  --gone --timeout 10s --json

record_case open_url open "iosusefixture://acceptance/v1" \
  --dom --json
assert_evidence open_url '"dom"'
assert_evidence open_url 'iosusefixture://acceptance/v1'
assert_json open_url '
  .data.schemeLookupVerified == true and
  .data.registeredHandlers == ["com.iosuse.playfixture.stablev1"] and
  .data.dom.app == "com.iosuse.playfixture.stablev1"
'

for probe in \
  "Full TL" "Full TR" "Full BL" "Full BR"; do
  probe_case="$(
    printf '%s' "$probe" |
      tr '[:upper:] ' '[:lower:]-'
  )"
  case "$probe" in
    "Full TL") probe_identifier="fixture.full.top-left" ;;
    "Full TR") probe_identifier="fixture.full.top-right" ;;
    "Full BL") probe_identifier="fixture.full.bottom-left" ;;
    "Full BR") probe_identifier="fixture.full.bottom-right" ;;
  esac
  record_case "probe_${probe_case}" tap "$probe" --dom --json
  assert_evidence "probe_${probe_case}" "$probe_identifier"
done

record_case native_host_status status --json
assert_canonical_host_status native_host_status
click_titlebar_and_assert_app_unchanged
run_global_mouse_probe \
  native_top_left \
  "Full TL" \
  "fixture.full.top-left"
run_global_mouse_probe \
  native_bottom_right \
  "Full BR" \
  "fixture.full.bottom-right"

record_case capture_native_host capture --duration 500ms --fps 4 \
  --name fixture-live-native-host
capture_native_host_manifest="$(
  sed -nE 's/^Manifest: (.*)$/\1/p' \
    "$RUN_DIR/capture_native_host.stdout"
)"
if [[ ! -f "$capture_native_host_manifest" ]]; then
  echo \
    "[playcover-fixture-live] FAIL: native-host capture manifest is unavailable" \
    >&2
  exit 1
fi
assert_canvas_only_capture_manifest "$capture_native_host_manifest"
run_global_mouse_probe \
  native_top_right \
  "Full TR" \
  "fixture.full.top-right"
run_global_mouse_probe \
  native_bottom_left \
  "Full BL" \
  "fixture.full.bottom-left"

record_case swipe_fixed swipe --dir forth --distance 300 \
  --dom --json
assert_evidence swipe_fixed 'Scroll y [1-9][0-9]*'

swipe_anchor_stdout="$RUN_DIR/swipe_anchor_required.stdout"
swipe_anchor_stderr="$RUN_DIR/swipe_anchor_required.stderr"
printf '%s\t%s\t%s\t%s\t%s\n' \
  "$MATRIX_VERSION" \
  "swipe_anchor_required" \
  'swipe --to Missing Semantic Target --json (expected anchor-required failure)' \
  "$swipe_anchor_stdout" \
  "$swipe_anchor_stderr" >>"$MANIFEST"
if IOS_USE_HOME="$SESSION_HOME" "$ROOT_DIR/ios-use" \
    swipe --to "Missing Semantic Target" --json \
    >"$swipe_anchor_stdout" 2>"$swipe_anchor_stderr"; then
  echo \
    "[playcover-fixture-live] FAIL: missing semantic target guessed a scroll container" \
    >&2
  exit 1
fi
assert_failure_json swipe_anchor_required '
  .ok == false and
  .error.category == "precondition" and
  .error.code == "scroll_anchor_required" and
  .error.phase == "lookup" and
  .error.mutationMayHaveApplied == false
'

record_case swipe_semantic_to_end swipe \
  --to "Scroll Target End" --from "Increment" --dom --json
assert_evidence swipe_semantic_to_end 'Scroll Target End'
assert_evidence swipe_semantic_to_end \
  '"scrolls"[[:space:]]*:[[:space:]]*[1-9][0-9]*'

swipe_boundary_stdout="$RUN_DIR/swipe_boundary.stdout"
swipe_boundary_stderr="$RUN_DIR/swipe_boundary.stderr"
printf '%s\t%s\t%s\t%s\t%s\n' \
  "$MATRIX_VERSION" \
  "swipe_boundary" \
  'swipe --to Missing Semantic Target --from Scroll Target End --dir forth --json (expected boundary failure)' \
  "$swipe_boundary_stdout" \
  "$swipe_boundary_stderr" >>"$MANIFEST"
if IOS_USE_HOME="$SESSION_HOME" "$ROOT_DIR/ios-use" \
    swipe --to "Missing Semantic Target" --from "Scroll Target End" \
    --dir forth --json \
    >"$swipe_boundary_stdout" 2>"$swipe_boundary_stderr"; then
  echo \
    "[playcover-fixture-live] FAIL: missing semantic target crossed the boundary" \
    >&2
  exit 1
fi
assert_failure_json swipe_boundary '
  .ok == false and
  .error.category == "action" and
  .error.code == "scroll_boundary" and
  .error.phase == "interaction" and
  .error.mutationMayHaveApplied == true
'

swipe_no_effect_stdout="$RUN_DIR/swipe_no_effect.stdout"
swipe_no_effect_stderr="$RUN_DIR/swipe_no_effect.stderr"
printf '%s\t%s\t%s\t%s\t%s\n' \
  "$MATRIX_VERSION" \
  "swipe_no_effect" \
  'swipe --from Scroll Target End --dir forth --distance 300 --json (expected no-effect failure)' \
  "$swipe_no_effect_stdout" \
  "$swipe_no_effect_stderr" >>"$MANIFEST"
if IOS_USE_HOME="$SESSION_HOME" "$ROOT_DIR/ios-use" \
    swipe --from "Scroll Target End" --dir forth --distance 300 --json \
    >"$swipe_no_effect_stdout" 2>"$swipe_no_effect_stderr"; then
  echo \
    "[playcover-fixture-live] FAIL: fixed swipe at the boundary reported success" \
    >&2
  exit 1
fi
assert_failure_json swipe_no_effect '
  .ok == false and
  .error.category == "action" and
  .error.code == "scroll_no_effect" and
  .error.phase == "postcondition" and
  .error.mutationMayHaveApplied == true
'

record_case swipe_semantic_back_to_top swipe \
  --to "UIKit Fixture" --from "Scroll Target End" --dir back \
  --dom --json
assert_evidence swipe_semantic_back_to_top 'UIKit Fixture'

record_case scene_replace tap "Replace Scene Window" \
  --dom --json
assert_evidence scene_replace 'Scene 2'
assert_json scene_replace '
  ([.data.postDom.elements[] |
    select(
      .identifier == "fixture.safe-area.first-read-header"
    )][0]) as $header |
  $header.label == "First Read Header" and
  $header.value ==
    "height=129 safeTop=59 source=window-safe-area statusBar=59" and
  (($header.frame[3] - 129) | fabs) <= 0.5
'
record_case scene_replace_status status --json
assert_canonical_host_status scene_replace_status
record_case scene_replace_diagnostics screenshot \
  --name scene-replace-diagnostics --json
assert_canvas_only_screenshot scene_replace_diagnostics
if ! jq -e \
    --argjson initialGeneration \
      "$initial_safe_area_evidence_generation" '
    .data.runtimeEvidence.appKitWindowEvidence
      .safeAreaCompatibility as $safeArea |
    ($safeArea.compatibilityHook
      .targetFirstEligibleProviderInvocation) as $firstRead |
    $firstRead.recorded == true and
    $firstRead.generation > $initialGeneration and
    $firstRead.evidenceKind ==
      "first-eligible-app-window-provider-hook-invocation" and
    $firstRead.businessInvocationProven == false and
    $firstRead.fixedGeometryApplied == true and
    $firstRead.resultMatchedExpected == true and
    $firstRead.expected ==
      {"top":59,"left":0,"bottom":34,"right":0} and
    $firstRead.result ==
      {"top":59,"left":0,"bottom":34,"right":0} and
    $safeArea.lifecycle.windowReplacements > 0
  ' "$RUN_DIR/scene_replace_diagnostics.stdout" >/dev/null; then
  echo \
    "[playcover-fixture-live] FAIL: Scene 2 lacks new first-read evidence" \
    >&2
  exit 1
fi

record_case absolute_bottom_tab_focus input --tap "Fixture Input" \
  --content "absolute-bottom-tab-focus" --delete 99 \
  --dom 100ms --json
assert_json absolute_bottom_tab_focus '
  .data.finalState.phase == "inserted" and
  (.data.finalState.firstResponderClass | type) == "string" and
  (.data.finalState.firstResponderClass | length) > 0 and
  ([
    .data.postDom.elements[] |
    select(
      .identifier == "fixture.uikit.input" and
      .state.visible == true and
      .state.focused == true
    )
  ] | length) == 1 and
  ([
    .data.postDom.elements[] |
    select(
      .identifier == "fixture.tab.swiftui" and
      .state.visible == true
    )
  ] | length) == 1
'
absolute_bottom_tab_generation="$(
  jq -er '.data.postDom.snapshotGeneration' \
    "$RUN_DIR/absolute_bottom_tab_focus.stdout"
)"
absolute_bottom_tab_x="$(
  jq -er '
    [.data.postDom.elements[] |
      select(
        .identifier == "fixture.tab.swiftui" and
        .state.visible == true
      )][0].frame |
    .[0] + (.[2] * 0.5)
  ' "$RUN_DIR/absolute_bottom_tab_focus.stdout"
)"
absolute_bottom_tab_y="$(
  jq -er '
    [.data.postDom.elements[] |
      select(
        .identifier == "fixture.tab.swiftui" and
        .state.visible == true
      )][0].frame |
    .[1] + (.[3] * 0.1)
  ' "$RUN_DIR/absolute_bottom_tab_focus.stdout"
)"
record_case swiftui_tab tap \
  "$absolute_bottom_tab_x,$absolute_bottom_tab_y" \
  --dom 100ms --json
if ! jq -e \
    --argjson x "$absolute_bottom_tab_x" \
    --argjson y "$absolute_bottom_tab_y" \
    --argjson generation "$absolute_bottom_tab_generation" '
      .data.finalState.phase == "ended" and
      ((.data.finalState.point[0] - $x) | fabs) < 0.001 and
      ((.data.finalState.point[1] - $y) | fabs) < 0.001 and
      .data.element.snapshotGeneration == ($generation + 2) and
      .data.postDom.snapshotGeneration == ($generation + 3) and
      ([
        .data.postDom.elements[] |
        select(
          .identifier == "fixture.tab.swiftui" and
          .state.selected == true
        )
      ] | length) == 1 and
      any(
        .data.postDom.elements[];
        .identifier == "fixture.swiftui.heading" and
        .state.visible == true
      ) and
      all(.data.postDom.elements[]; .state.focused != true)
    ' "$RUN_DIR/swiftui_tab.stdout" >/dev/null; then
  echo \
    "[playcover-fixture-live] FAIL: absolute bottom-tab tap did not release focus and re-resolve from a fresh DOM" \
    >&2
  exit 1
fi
assert_evidence swiftui_tab 'SwiftUI Fixture'
record_case swiftui_increment tap "SwiftUI Increment" \
  --dom --json
assert_evidence swiftui_increment 'SwiftUI Count 1'
assert_json swiftui_increment '
  . as $root |
  [
    "fixture.swiftui.heading",
    "fixture.swiftui.count",
    "fixture.swiftui.increment",
    "fixture.swiftui.input",
    "fixture.swiftui.value",
    "fixture.swiftui.submit"
  ] as $identifiers |
  all(
    $identifiers[];
    . as $identifier |
    [
      $root.data.postDom.elements[] |
      select(.identifier == $identifier)
    ] | length == 1
  )
'
record_case swiftui_overlap_enabled_show \
  tap "Advance SwiftUI Overlay" --dom --json
assert_swiftui_overlap_blocks_increment \
  swiftui_overlap_enabled_blocked enabled true

record_case swiftui_overlap_disabled_show \
  tap "Advance SwiftUI Overlay" --dom --json
assert_swiftui_overlap_blocks_increment \
  swiftui_overlap_disabled_blocked disabled false

record_case swiftui_overlap_clear \
  tap "Advance SwiftUI Overlay" --dom --json
assert_json swiftui_overlap_clear '
  .data.postDom.elements as $elements |
  ([
    $elements[] |
    select(
      .identifier == "fixture.swiftui.overlay.advance" and
      .value == "none"
    )
  ] | length) == 1 and
  ([
    $elements[] |
    select(
      .identifier == "fixture.swiftui.increment-overlay"
    )
  ] | length) == 0
'
record_case swiftui_input input --tap "SwiftUI Input" \
  --content "swift" --enter --dom --json
assert_evidence swiftui_input 'SwiftUI Value swift'
assert_evidence swiftui_input 'SwiftUI Submit 1'

record_case web_tab tap "Web" --dom --json
record_case web_wait waitFor "Web Increment" \
  --timeout 10s --json
assert_evidence web_wait 'Web Increment'
record_case web_increment tap "Web Increment" \
  --dom --json
assert_evidence web_increment 'Web Count 1'
record_case web_input input --tap "Web Input" \
  --content "web" --dom --json
assert_evidence web_input 'Web Value web'
assert_json web_input '
  . as $root |
  (
    [
      $root.data.postDom.elements[] |
      select(.class == "IOSUseDOMAppKitAccessibilityElement")
    ] | length == 0
  ) and
  (
    [
      "WKWebView Fixture",
      "Web Count 1",
      "Web Increment",
      "Web Value web",
      "Web Input"
    ] as $labels |
    all(
      $labels[];
      . as $label |
      [
        $root.data.postDom.elements[] |
        select(
          .label == $label and
          .class == "IOSUseDOMWebAccessibilityElement"
        )
      ] | length == 1
    )
  )
'

record_case metal_tab tap "Metal" --dom --json
assert_evidence metal_tab 'Metal opaque canvas active'
record_case metal_overlay tap "Metal Overlay" --dom --json
assert_evidence metal_overlay 'Metal Overlay Tapped'
record_case screenshot_metal screenshot \
  --name metal --json
assert_evidence screenshot_metal \
  '"complete"[[:space:]]*:[[:space:]]*true'
assert_evidence screenshot_metal '"compositorWindowNumbers"'
assert_evidence screenshot_metal \
  '"requestedCapturedCountMatch"[[:space:]]*:[[:space:]]*true'
assert_canvas_only_screenshot screenshot_metal
assert_ocr_evidence screenshot_metal \
  "Metal opaque canvas active" "Metal Overlay Tapped"
assert_metal_pixel screenshot_metal

record_case stop stop
if [[ ! -f "$stdio_log_path" || -L "$stdio_log_path" ]] ||
  [[
    "$(/usr/bin/stat -f '%d:%i:%u:%Lp:%l' "$stdio_log_path")" != "$stdio_log_identity"
  ]]; then
  echo \
    "[playcover-fixture-live] FAIL: normal stop did not retain the exact stdio log" \
    >&2
  exit 1
fi
if [[ -e "$runtime_socket_path" || -L "$runtime_socket_path" ]]; then
  echo \
    "[playcover-fixture-live] FAIL: normal stop left its Runtime-owned socket path" \
    >&2
  exit 1
fi
archive_session_home
restore_original_frontmost_application
trap - EXIT
trap - ERR
echo "[playcover-fixture-live] PASS native-host acceptance v$MATRIX_VERSION"
echo "[playcover-fixture-live] Evidence retained at $RUN_DIR"
