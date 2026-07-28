#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MATRIX_VERSION="2"
MATRIX_SOURCE="$ROOT_DIR/playcover-fixtures/live-matrix-v2.tsv"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
EVIDENCE_ROOT="${IOS_USE_PLAYCOVER_EVIDENCE_ROOT:-$ROOT_DIR/.ios-use/live-evidence}"
RUN_DIR="$EVIDENCE_ROOT/playcover-fixture-v${MATRIX_VERSION}/$RUN_ID"
SESSION_HOME=""
CANONICAL_SESSION_HOME=""
ARCHIVED_SESSION_HOME="$RUN_DIR/session-home"
MANIFEST="$RUN_DIR/manifest.tsv"
FIXTURE_APP="${IOS_USE_PLAYCOVER_FIXTURE_APP:-}"
ORIGINAL_FRONTMOST_PID=""
ORIGINAL_FRONTMOST_BUNDLE=""
FRONTMOST_CAPTURED=0
FOCUS_RESTORE_MANIFESTED=0
MOUSE_SEQUENCE=0
EXPECTED_HOST_TITLE=""
DISPLAY_TOPOLOGY="$RUN_DIR/display-topology.json"
DISPLAY_SELECTION="$RUN_DIR/display-selection.json"

usage() {
  cat <<'USAGE'
Usage: scripts/test_playcover_fixture_live.sh --live

--live    Run the fixture acceptance matrix against a real unlocked macOS GUI
          session. Live evidence and global input are intentionally never the
          default.
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

mkdir -p "$RUN_DIR"
if [[ ! -f "$MATRIX_SOURCE" ]]; then
  echo "[playcover-fixture-live] Missing matrix: $MATRIX_SOURCE" >&2
  exit 78
fi
cp "$MATRIX_SOURCE" "$RUN_DIR/"
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
if ! xcrun swift \
    "$ROOT_DIR/playcover-fixtures/appkit_mouse_event.swift" \
    --screens >"$DISPLAY_TOPOLOGY"; then
  echo \
    "[playcover-fixture-live] EX_CONFIG: display topology is unavailable." \
    >&2
  exit 78
fi
if ! jq -e '
    .operation == "screens" and
    .postEventAccessRequired == false and
    .lockedSessionAllowed == true and
    ([.screens[] | select(.screenIsMain == true)] | length) == 1 and
    (.screens as $screens |
      ($screens | map(.screenDisplayID)) ==
        ($screens | map(.screenDisplayID) | sort | unique))
  ' "$DISPLAY_TOPOLOGY" >/dev/null; then
  echo \
    "[playcover-fixture-live] EX_CONFIG: topology must expose exactly one main display." \
    >&2
  exit 78
fi
if ! jq -e '
    ([.screens[] | select(.screenIsMain == true)][0]) as $main |
    ([
      .screens[] |
      select(
        .screenIsMain == false and
        .hasNSScreen == true and
        .active == true and
        .online == true and
        .mirrored == false and
        (.backingScaleFactor | type) == "number" and
        .backingScaleFactor != $main.backingScaleFactor and
        (.visibleFrame.width | type) == "number" and
        .visibleFrame.width >= 430 and
        (.visibleFrame.height | type) == "number" and
        .visibleFrame.height >= 970
      )
    ]) as $extended |
    if (
      $main.hasNSScreen == true and
      $main.active == true and
      $main.online == true and
      $main.mirrored == false and
      ($main.backingScaleFactor | type) == "number" and
      ($extended | length) == 1
    ) then
      {
        main: $main,
        extended: $extended[0],
        eligibleExtendedCount: ($extended | length)
      }
    else
      error("display topology is not eligible")
    end
  ' "$DISPLAY_TOPOLOGY" >"$DISPLAY_SELECTION"; then
  echo \
    "[playcover-fixture-live] EX_CONFIG: exactly one active extended non-main display with different backing scale and sufficient visible frame is required." \
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
  local expected_phase="$2"
  shift 2
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
    .error.code == \"element_not_hittable\" and
    .error.phase == \"$expected_phase\"
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
      def scalar_max($lhs; $rhs):
        if $lhs > $rhs then $lhs else $rhs end;
      def scalar_min($lhs; $rhs):
        if $lhs < $rhs then $lhs else $rhs end;
      def fixed_logical_canvas($rect; $tolerance):
        ($rect | rectangle) and
        (($rect.x | abs) <= $tolerance) and
        (($rect.y | abs) <= $tolerance) and
        ((($rect.width - 430) | abs) <= $tolerance) and
        ((($rect.height - 932) | abs) <= $tolerance);
      def private_logical_canvas(
        $rect;
        $originTolerance;
        $widthTolerance;
        $heightTolerance
      ):
        ($rect | rectangle) and
        (($rect.x | abs) <= $originTolerance) and
        (($rect.y | abs) <= $originTolerance) and
        ($rect.width - 430 >= -$originTolerance) and
        ($rect.width - 430 <= $widthTolerance + 0.000001) and
        ($rect.height - 932 >= -$originTolerance) and
        ($rect.height - 932 <= $heightTolerance + 0.000001) and
        ($rect.x + $rect.width - 430 >= -$originTolerance) and
        ($rect.x + $rect.width - 430 <=
          $widthTolerance + 0.000001) and
        ($rect.y + $rect.height - 932 >= -$originTolerance) and
        ($rect.y + $rect.height - 932 <=
          $heightTolerance + 0.000001);
      def rects_agree($lhs; $rhs):
        (($lhs.x - $rhs.x) | abs) <= 0.01 and
        (($lhs.y - $rhs.y) | abs) <= 0.01 and
        (($lhs.width - $rhs.width) | abs) <= 0.01 and
        (($lhs.height - $rhs.height) | abs) <= 0.01;
      .data.driver.runtime as $runtime |
      ($runtime.diagnostics.runtime.window) as $window |
      ($window.safeAreaCompatibility) as $safeArea |
      ($window.canvasCapture) as $capture |
      ($window.hostContentBounds) as $host |
      ($window.canvasRect) as $canvas |
      ($capture.hostContentCGWindowRect) as $hostCG |
      ($capture.canvasCGWindowRect) as $canvasCG |
      ($window.halfPixelTolerance / $window.displayScale) as
        $logicalEdgeTolerance |
      ($logicalEdgeTolerance * 2) as $logicalExtentTolerance |
      ($canvas.x - $host.x) as $leftMargin |
      ($host.x + $host.width - $canvas.x - $canvas.width) as
        $rightMargin |
      ($canvas.y - $host.y) as $bottomMargin |
      ($host.y + $host.height - $canvas.y - $canvas.height) as
        $topMargin |
      scalar_max(
        $logicalEdgeTolerance;
        scalar_min(
          scalar_max(0; $leftMargin + $rightMargin) /
            $window.displayScale;
          $logicalExtentTolerance
        )
      ) as $privateWidthTolerance |
      scalar_max(
        $logicalEdgeTolerance;
        scalar_min(
          scalar_max(0; $bottomMargin + $topMargin) /
            $window.displayScale;
          $logicalExtentTolerance
        )
      ) as $privateHeightTolerance |
      $runtime.status == "healthy" and
      $runtime.logicalWidth == 430 and
      $runtime.logicalHeight == 932 and
      $runtime.nativeWidth == 1290 and
      $runtime.nativeHeight == 2796 and
      $runtime.scale == 3 and
      $runtime.host.opaque == true and
      $window.status == "configured" and
      $window.opaque == true and
      $window.publicTitleBar == true and
      $window.resizable == true and
      $window.hostPolicy == true and
      $safeArea.stage == "ready" and
      $safeArea.safeAreaCompatibilityReady == true and
      $safeArea.safeAreaReady == true and
      $safeArea.deviceContractReady == true and
      $safeArea.safeAreaLayoutGuideReady == true and
      $safeArea.additionalSafeAreaPreserved == true and
      $safeArea.deviceSafeArea ==
        {"top":59,"left":0,"bottom":34,"right":0} and
      $safeArea.windowSafeArea ==
        {"top":59,"left":0,"bottom":34,"right":0} and
      $safeArea.expectedWindowSafeArea ==
        {"top":59,"left":0,"bottom":34,"right":0} and
      $safeArea.safeArea ==
        {"top":59,"left":0,"bottom":34,"right":0} and
      $safeArea.additionalSafeArea ==
        {"top":0,"left":0,"bottom":0,"right":0} and
      $safeArea.safeAreaLayoutFrame ==
        {"x":0,"y":59,"width":430,"height":839} and
      $safeArea.runtimeAdditionalSafeAreaWriteCount == 0 and
      $window.title == $title and
      $capture.title == $title and
      $window.mouseMonitorReady == true and
      $window.identityTransform == true and
      $window.borderless == false and
      $window.hasShadow == true and
      $window.movable == true and
      ($window.resizeEdges | type) == "object" and
      ($window.resizeEdges.available | type) == "number" and
      $window.resizeEdges.available >= 0 and
      (($window.resizeEdges.available % 16) == 15) and
      ($window.resizeEdges.growing | type) == "number" and
      $window.resizeEdges.growing >= 0 and
      (($window.resizeEdges.growing % 16) == 15) and
      ($window.resizeEdges.shrinking | type) == "number" and
      $window.resizeEdges.shrinking >= 0 and
      (($window.resizeEdges.shrinking % 16) == 15) and
      $window.canvasBounds ==
        {"x":0,"y":0,"width":430,"height":932} and
      fixed_logical_canvas(
        $window.renderViewBounds;
        $logicalEdgeTolerance
      ) and
      private_logical_canvas(
        $window.sceneRenderViewBounds;
        $logicalEdgeTolerance;
        $privateWidthTolerance;
        $privateHeightTolerance
      ) and
      private_logical_canvas(
        $window.sceneRenderViewFrame;
        $logicalEdgeTolerance;
        $privateWidthTolerance;
        $privateHeightTolerance
      ) and
      private_logical_canvas(
        $window.inputRenderViewFrame;
        $logicalEdgeTolerance;
        $privateWidthTolerance;
        $privateHeightTolerance
      ) and
      private_logical_canvas(
        $window.inputRenderViewBounds;
        $logicalEdgeTolerance;
        $privateWidthTolerance;
        $privateHeightTolerance
      ) and
      rects_agree(
        $window.sceneRenderViewFrame;
        $window.sceneRenderViewBounds
      ) and
      rects_agree(
        $window.sceneRenderViewFrame;
        $window.inputRenderViewFrame
      ) and
      rects_agree(
        $window.sceneRenderViewFrame;
        $window.inputRenderViewBounds
      ) and
      ($window.sceneScale.idiom | type) == "number" and
      (($window.sceneScale.idiom - 1) | abs) <= 0.01 and
      (($window.sceneScale.windows - 1) | abs) <= 0.01 and
      $window.sceneScale.downscaleWindowIfNecessary == false and
      $window.sceneMinimumSize == {"width":430,"height":932} and
      $window.sceneMaximumSize == {"width":430,"height":932} and
      ($window.displayScale | type) == "number" and
      $window.displayScale > 0 and
      ($window.backingScaleFactor | type) == "number" and
      $window.backingScaleFactor > 0 and
      $window.backingScaleFactor <= 4 and
      ($window.halfPixelTolerance | type) == "number" and
      (($window.halfPixelTolerance -
        (0.5 / $window.backingScaleFactor)) | abs) <= 0.000001 and
      ($window.inverseDisplayScale | type) == "number" and
      (($window.displayScale * $window.inverseDisplayScale - 1) | abs) <=
        0.0001 and
      ($host | rectangle) and
      ($canvas | rectangle) and
      ($hostCG | rectangle) and
      ($canvasCG | rectangle) and
      (($canvas.width / $window.displayScale - 430) | abs) <=
        $logicalExtentTolerance and
      (($canvas.height / $window.displayScale - 932) | abs) <=
        $logicalExtentTolerance and
      (($canvasCG.width / $window.displayScale - 430) | abs) <=
        $logicalExtentTolerance and
      (($canvasCG.height / $window.displayScale - 932) | abs) <=
        $logicalExtentTolerance and
      (($canvasCG.width - $canvas.width) | abs) <=
        ($window.halfPixelTolerance * 2) and
      (($canvasCG.height - $canvas.height) | abs) <=
        ($window.halfPixelTolerance * 2) and
      (($canvas.x - $host.x) | abs) <=
        $window.halfPixelTolerance and
      (($canvas.y - $host.y) | abs) <=
        $window.halfPixelTolerance and
      (($canvas.width - $host.width) | abs) <=
        ($window.halfPixelTolerance * 2) and
      (($canvas.height - $host.height) | abs) <=
        ($window.halfPixelTolerance * 2) and
      (($canvasCG.x -
        ($hostCG.x + $canvas.x - $host.x)) | abs) <=
        $window.halfPixelTolerance and
      (($canvasCG.y -
        ($hostCG.y + $host.y + $host.height -
          $canvas.y - $canvas.height)) | abs) <=
        $window.halfPixelTolerance and
      (($canvasCG.x - $hostCG.x) | abs) <=
        $window.halfPixelTolerance and
      (($canvasCG.y - $hostCG.y) | abs) <=
        $window.halfPixelTolerance and
      (($canvasCG.width - $hostCG.width) | abs) <=
        ($window.halfPixelTolerance * 2) and
      (($canvasCG.height - $hostCG.height) | abs) <=
        ($window.halfPixelTolerance * 2)
    ' "$RUN_DIR/${case_name}.stdout" >/dev/null; then
    echo \
      "[playcover-fixture-live] FAIL: $case_name does not prove the canonical Simulator-scale host/canvas contract" \
      >&2
    return 1
  fi
}

assert_canvas_only_screenshot() {
  local case_name="$1"
  if ! jq -e --arg title "$EXPECTED_HOST_TITLE" '
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
          "identityMapping":true
        } and
        .data.runtimeEvidence.compositor.syntheticChrome == false and
        .data.runtimeEvidence.compositor.fullFrame == $fullFrame) and
      (.data.runtimeEvidence.compositor.completeness |
        .allVisibleNativeWindowsOrdered == true and
        .allVisibleUIKitWindowsMapped == true and
        .allWindowGeometryInsideDevice == true and
        .baseWindowCoversDevice == true and
        .requestedCapturedCountMatch == true and
        .windowSetStableDuringCapture == true) and
      (.data.runtimeEvidence.appKitWindowEvidence as $window |
        ($window.canvasCapture) as $capture |
        $window.status == "configured" and
        $window.opaque == true and
        $window.publicTitleBar == true and
        $window.resizable == true and
        $window.hostPolicy == true and
        $window.title == $title and
        $capture.title == $title and
        $window.canvasBounds ==
          {"x":0,"y":0,"width":430,"height":932} and
        ($window.displayScale | type) == "number" and
        $window.displayScale > 0 and
        (($window.canvasRect.width / $window.displayScale - 430) | abs) <=
          0.5 and
        (($window.canvasRect.height / $window.displayScale - 932) | abs) <=
          0.5 and
        (($capture.canvasCGWindowRect.width /
          $window.displayScale - 430) | abs) <= 0.5 and
        (($capture.canvasCGWindowRect.height /
          $window.displayScale - 932) | abs) <= 0.5 and
        (($capture.canvasCGWindowRect.x -
          $capture.hostContentCGWindowRect.x) | abs) <= 0.5 and
        (($capture.canvasCGWindowRect.y -
          $capture.hostContentCGWindowRect.y) | abs) <= 0.5 and
        (($capture.canvasCGWindowRect.width -
          $capture.hostContentCGWindowRect.width) | abs) <= 0.5 and
        (($capture.canvasCGWindowRect.height -
          $capture.hostContentCGWindowRect.height) | abs) <= 0.5)
    ' "$RUN_DIR/${case_name}.stdout" >/dev/null; then
    echo \
      "[playcover-fixture-live] FAIL: $case_name is not a complete canvas-only 1290x2796 capture" \
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
          $appKit.applicationActive != true or
          $appKit.windowKey != true or
          $appKit.mouseMonitorReady != true or
          $appKit.identityTransform != true or
          $appKit.canvasBounds !=
            {"x":0,"y":0,"width":430,"height":932} or
          ($appKit.displayScale | type) != "number" or
          $appKit.displayScale <= 0 or
          ($appKit.inverseDisplayScale | type) != "number" or
          (($appKit.displayScale * $appKit.inverseDisplayScale - 1) | abs) >
            0.0001 or
          ($canvas | type) != "object" or
          (($canvas.width / $appKit.displayScale - 430) | abs) > 0.5 or
          (($canvas.height / $appKit.displayScale - 932) | abs) > 0.5
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
            ($canvas.x + ($logicalX * $appKit.displayScale)) as $globalX |
            ($canvas.y + ($logicalY * $appKit.displayScale)) as $globalY |
            (($globalX - $canvas.x) * $appKit.inverseDisplayScale) as $inverseX |
            (($globalY - $canvas.y) * $appKit.inverseDisplayScale) as $inverseY |
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
              displayScale: $appKit.displayScale,
              inverseDisplayScale: $appKit.inverseDisplayScale,
              mouseDeliveryCountBefore: $appKit.mouseDeliveryCount
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
  local delivery_status_case="${case_prefix}_delivery_status"
  record_case "$delivery_status_case" status --json
  assert_canonical_host_status "$delivery_status_case"
  if ! jq -e \
      --argjson token "$event_token" \
      --slurpfile coordinates "$coordinates_file" \
      --slurpfile mouse "$RUN_DIR/${mouse_case}.stdout" \
      --slurpfile postDom "$RUN_DIR/${post_dom_case}.stdout" '
        ($coordinates[0]) as $coordinates |
        ($coordinates.logicalPoint) as $point |
        (.data.driver.runtime.diagnostics.runtime.window) as $appKit |
        ($appKit.lastMouseDownDelivery) as $down |
        ($appKit.lastMouseUpDelivery) as $up |
        .data.driver.runnerPid == $coordinates.runnerPID and
        .data.driver.runtime.status == "healthy" and
        $appKit.status == "configured" and
        $appKit.applicationActive == true and
        $appKit.windowKey == true and
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
      ' "$RUN_DIR/${delivery_status_case}.stdout" >/dev/null; then
    echo \
      "[playcover-fixture-live] FAIL: $probe_identifier lacks exact DOM/status/AppKit down-up evidence" \
      >&2
    return 1
  fi
}

write_host_resize_plan() {
  local case_name="$1"
  local phase="$2"
  local status_case="$3"
  local plan_file="$RUN_DIR/${case_name}_plan.json"
  local initial_arg=(--argjson initial '[]')
  if [[ "$phase" == "second" ]]; then
    initial_arg=(--slurpfile initial "$RUN_DIR/host_resize_initial.json")
  fi
  if ! jq -e -n \
      --arg phase "$phase" \
      --slurpfile status "$RUN_DIR/${status_case}.stdout" \
      "${initial_arg[@]}" '
        ($status[0].data.driver.runtime.diagnostics.runtime.window) as $window |
        ($window.canvasCapture.hostCGWindowBounds) as $host |
        ($window.canvasCapture.hostContentCGWindowRect) as $content |
        ($host.width - $content.width) as $decorationWidth |
        ($host.height - $content.height) as $decorationHeight |
        if (
          ($host | type) != "object" or
          ($content | type) != "object" or
          ($window.minSize.width | type) != "number" or
          ($window.minSize.height | type) != "number" or
          $decorationWidth < -0.5 or
          $decorationHeight < -0.5
        ) then
          error("host resize diagnostics are incomplete")
        elif $phase == "first" then
          ([
            0.72,
            (($window.minSize.width + 12 - $decorationWidth) /
              $content.width),
            (($window.minSize.height + 12 - $decorationHeight) /
              $content.height)
          ] | max) as $targetScale |
          ($content.width * $targetScale + $decorationWidth) as $targetWidth |
          ($content.height * $targetScale + $decorationHeight) as $targetHeight |
          if (
            $targetScale >= 0.94 or
            $targetWidth >= ($host.width - 8) or
            $targetHeight >= ($host.height - 8)
          ) then
            error("host cannot be reduced to a distinct first resize")
          else
            {
              phase: $phase,
              beforeHost: $host,
              beforeContent: $content,
              beforeDisplayScale: $window.displayScale,
              anchoredOppositeCorner: "topLeft",
              targetContentScale: $targetScale,
              targetHostSize: {
                width: $targetWidth,
                height: $targetHeight
              },
              drag: {
                start: {
                  x: ($host.x + $host.width - 2),
                  y: ($host.y + $host.height - 2)
                },
                end: {
                  x: ($host.x + $targetWidth - 2),
                  y: ($host.y + $targetHeight - 2)
                }
              },
              runnerPID: $status[0].data.driver.runnerPid
            }
          end
        elif $phase == "second" then
          ($initial[0].host) as $initialHost |
          ($initial[0].content) as $initialContent |
          ($content.width / $initialContent.width) as $currentScale |
          ((1 + $currentScale) / 2) as $targetScale |
          ($initialContent.width * $targetScale +
            $decorationWidth) as $targetWidth |
          ($initialContent.height * $targetScale +
            $decorationHeight) as $targetHeight |
          if (
            $targetWidth <= ($host.width + 8) or
            $targetHeight <= ($host.height + 8) or
            $targetWidth > ($initialHost.width + 0.5) or
            $targetHeight > ($initialHost.height + 0.5)
          ) then
            error("host cannot be increased to a distinct second resize")
          else
            {
              phase: $phase,
              beforeHost: $host,
              beforeContent: $content,
              beforeDisplayScale: $window.displayScale,
              anchoredOppositeCorner: "bottomRight",
              targetContentScale: $targetScale,
              targetHostSize: {
                width: $targetWidth,
                height: $targetHeight
              },
              drag: {
                start: {
                  x: ($host.x + 2),
                  y: ($host.y + 2)
                },
                end: {
                  x: ($host.x + $host.width - $targetWidth + 2),
                  y: ($host.y + $host.height - $targetHeight + 2)
                }
              },
              runnerPID: $status[0].data.driver.runnerPid
            }
          end
        else
          error("unknown resize phase")
        end
      ' >"$plan_file"; then
    echo \
      "[playcover-fixture-live] FAIL: could not plan $phase host resize" \
      >&2
    return 1
  fi
}

wait_for_host_resize() {
  local case_name="$1"
  local plan_file="$RUN_DIR/${case_name}_plan.json"
  local stdout_file="$RUN_DIR/${case_name}_after_status.stdout"
  local stderr_file="$RUN_DIR/${case_name}_after_status.stderr"
  printf '%s\t%s\t%s\t%s\t%s\n' \
    "$MATRIX_VERSION" \
    "${case_name}_after_status" \
    "status --json (wait for public host resize)" \
    "$stdout_file" \
    "$stderr_file" >>"$MANIFEST"
  local observed=0
  local attempt
  for ((attempt = 1; attempt <= 30; attempt += 1)); do
    if IOS_USE_HOME="$SESSION_HOME" "$ROOT_DIR/ios-use" status --json \
        >"$stdout_file" 2>"$stderr_file" &&
      jq -e --slurpfile plan "$plan_file" '
        ($plan[0]) as $plan |
        (.data.driver.runtime.diagnostics.runtime.window) as $window |
        ($window.canvasCapture.hostCGWindowBounds) as $actual |
        ($plan.beforeHost) as $before |
        ($plan.targetHostSize) as $target |
        $window.status == "configured" and
        (($actual.width - $target.width) | abs) <= 10 and
        (($actual.height - $target.height) | abs) <= 10 and
        if $plan.anchoredOppositeCorner == "topLeft" then
          (($actual.x - $before.x) | abs) <= 4 and
          (($actual.y - $before.y) | abs) <= 4
        elif $plan.anchoredOppositeCorner == "bottomRight" then
          (($actual.x + $actual.width -
            ($before.x + $before.width)) | abs) <= 4 and
          (($actual.y + $actual.height -
            ($before.y + $before.height)) | abs) <= 4
        else
          false
        end and
        if $plan.phase == "first" then
          $actual.width < ($before.width - 4) and
          $actual.height < ($before.height - 4)
        else
          $actual.width > ($before.width + 4) and
          $actual.height > ($before.height + 4)
        end
      ' "$stdout_file" >/dev/null; then
      observed=1
      break
    fi
    sleep 0.1
  done
  if [[ "$observed" != "1" ]]; then
    echo \
      "[playcover-fixture-live] FAIL: $case_name did not reach its requested public host size" \
      >&2
    return 1
  fi
  assert_canonical_host_status "${case_name}_after_status"
}

resize_public_host() {
  local case_name="$1"
  local phase="$2"
  local before_status_case="${case_name}_before_status"
  record_case "$before_status_case" status --json
  assert_canonical_host_status "$before_status_case"
  if [[ "$phase" == "first" ]]; then
    jq -e '
      .data.driver.runtime.diagnostics.runtime.window as $window |
      {
        host: $window.canvasCapture.hostCGWindowBounds,
        content: $window.canvasCapture.hostContentCGWindowRect,
        displayScale: $window.displayScale,
        resizeEdges: $window.resizeEdges,
        canvasBounds: $window.canvasBounds,
        canvasRect: $window.canvasRect
      }
    ' "$RUN_DIR/${before_status_case}.stdout" \
      >"$RUN_DIR/host_resize_initial.json"
  fi
  write_host_resize_plan "$case_name" "$phase" "$before_status_case"

  local drag_start_x
  local drag_start_y
  local drag_end_x
  local drag_end_y
  local runner_pid
  read -r drag_start_x drag_start_y drag_end_x drag_end_y runner_pid < <(
    jq -r '
      [
        .drag.start.x,
        .drag.start.y,
        .drag.end.x,
        .drag.end.y,
        .runnerPID
      ] | @tsv
    ' "$RUN_DIR/${case_name}_plan.json"
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
    "${case_name}_drag" \
    xcrun swift \
    "$ROOT_DIR/playcover-fixtures/appkit_mouse_event.swift" \
    --drag \
    "$drag_start_x" \
    "$drag_start_y" \
    "$drag_end_x" \
    "$drag_end_y" \
    "$event_token" \
    "$runner_pid"
  if ! jq -e \
      --argjson token "$event_token" \
      --argjson pid "$runner_pid" \
      --slurpfile plan "$RUN_DIR/${case_name}_plan.json" '
        ($plan[0].drag.end) as $end |
        .operation == "drag" and
        .token == $token and
        .targetPID == $pid and
        .targetWindowNumber > 0 and
        .postEventAccess == true and
        .endPoint.x >= ($end.x - 0.5) and
        .endPoint.x <= ($end.x + 0.5) and
        .endPoint.y >= ($end.y - 0.5) and
        .endPoint.y <= ($end.y + 0.5)
      ' "$RUN_DIR/${case_name}_drag.stdout" >/dev/null; then
    echo \
      "[playcover-fixture-live] FAIL: $case_name drag helper evidence is not target-bound" \
      >&2
    return 1
  fi
  wait_for_host_resize "$case_name"
}

assert_two_uniform_host_resizes() {
  if ! jq -e -n \
      --slurpfile initial "$RUN_DIR/host_resize_initial.json" \
      --slurpfile first "$RUN_DIR/host_resize_first_after_status.stdout" \
      --slurpfile second "$RUN_DIR/host_resize_second_after_status.stdout" '
        ($initial[0]) as $initial |
        ($first[0].data.driver.runtime.diagnostics.runtime.window) as $first |
        ($second[0].data.driver.runtime.diagnostics.runtime.window) as $second |
        ($first.canvasCapture.hostCGWindowBounds) as $firstHost |
        ($second.canvasCapture.hostCGWindowBounds) as $secondHost |
        ($first.canvasCapture.hostContentCGWindowRect) as $firstContent |
        ($second.canvasCapture.hostContentCGWindowRect) as $secondContent |
        ($firstContent.width / $initial.content.width) as $firstScale |
        ($secondContent.width / $initial.content.width) as $secondScale |
        $initial.canvasBounds == {"x":0,"y":0,"width":430,"height":932} and
        $first.canvasBounds == {"x":0,"y":0,"width":430,"height":932} and
        $second.canvasBounds == {"x":0,"y":0,"width":430,"height":932} and
        (($initial.resizeEdges.available % 16) == 15) and
        (($initial.resizeEdges.growing % 16) == 15) and
        (($first.resizeEdges.available % 16) == 15) and
        (($first.resizeEdges.growing % 16) == 15) and
        (($second.resizeEdges.available % 16) == 15) and
        (($second.resizeEdges.growing % 16) == 15) and
        $firstHost.width < ($initial.host.width - 4) and
        $firstHost.height < ($initial.host.height - 4) and
        $secondHost.width > ($firstHost.width + 4) and
        $secondHost.height > ($firstHost.height + 4) and
        (($first.displayScale - $initial.displayScale) | abs) > 0.01 and
        (($second.displayScale - $first.displayScale) | abs) > 0.01 and
        (($firstContent.height / $initial.content.height -
          $firstScale) | abs) <= 0.002 and
        (($secondContent.height / $initial.content.height -
          $secondScale) | abs) <= 0.002 and
        (($first.displayScale / $initial.displayScale -
          $firstScale) | abs) <= 0.002 and
        (($second.displayScale / $initial.displayScale -
          $secondScale) | abs) <= 0.002 and
        (($firstHost.height - $firstContent.height -
          ($initial.host.height - $initial.content.height)) | abs) <= 1 and
        (($secondHost.height - $secondContent.height -
          ($initial.host.height - $initial.content.height)) | abs) <= 1 and
        (($first.canvasRect.width / $first.displayScale - 430) | abs) <= 0.5 and
        (($first.canvasRect.height / $first.displayScale - 932) | abs) <= 0.5 and
        (($second.canvasRect.width / $second.displayScale - 430) | abs) <= 0.5 and
        (($second.canvasRect.height / $second.displayScale - 932) | abs) <= 0.5 and
        (($first.canvasRect.x -
          $first.hostContentBounds.x) | abs) <= 0.5 and
        (($first.canvasRect.y -
          $first.hostContentBounds.y) | abs) <= 0.5 and
        (($first.canvasRect.width -
          $first.hostContentBounds.width) | abs) <= 0.5 and
        (($first.canvasRect.height -
          $first.hostContentBounds.height) | abs) <= 0.5 and
        (($second.canvasRect.x -
          $second.hostContentBounds.x) | abs) <= 0.5 and
        (($second.canvasRect.y -
          $second.hostContentBounds.y) | abs) <= 0.5 and
        (($second.canvasRect.width -
          $second.hostContentBounds.width) | abs) <= 0.5 and
        (($second.canvasRect.height -
          $second.hostContentBounds.height) | abs) <= 0.5
      ' /dev/null >/dev/null; then
    echo \
      "[playcover-fixture-live] FAIL: two proportional host resizes did not preserve one fixed UIKit canvas and one display scale" \
      >&2
    return 1
  fi
}

display_matrix_row() {
  local case_name="$1"
  /usr/bin/awk -F '\t' -v requested="$case_name" '
    NR == 1 {
      if (
        $1 != "matrixVersion" ||
        $2 != "case" ||
        $3 != "targetScreen" ||
        $4 != "displayScale" ||
        $5 != "crossDisplay"
      ) {
        exit 2
      }
      next
    }
    $2 == requested {
      if (found || $1 != "2") {
        exit 2
      }
      print $3 "\t" $4 "\t" $5
      found = 1
    }
    END {
      if (!found) {
        exit 2
      }
    }
  ' "$MATRIX_SOURCE"
}

write_display_move_plan() {
  local case_name="$1"
  local target_role="$2"
  local target_scale="$3"
  local cross_display="$4"
  local status_case="$5"
  jq -e -n \
    --arg role "$target_role" \
    --argjson targetScale "$target_scale" \
    --argjson crossDisplay "$cross_display" \
    --slurpfile topology "$DISPLAY_SELECTION" \
    --slurpfile status "$RUN_DIR/${status_case}.stdout" '
      ($status[0].data.driver) as $driver |
      ($driver.runtime.diagnostics.runtime.window) as $window |
      ($window.canvasCapture.hostCGWindowBounds) as $host |
      ($window.canvasCapture.hostContentCGWindowRect) as $content |
      ($topology[0][$role]) as $target |
      ($topology[0].main) as $main |
      ($target.visibleFrame) as $visible |
      {
        x: $visible.x,
        y: ($main.cgBounds.y + $main.cgBounds.height -
          $visible.y - $visible.height),
        width: $visible.width,
        height: $visible.height
      } as $visibleCG |
      ($host.width - $content.width) as $decorationWidth |
      ($host.height - $content.height) as $decorationHeight |
      (430 * $targetScale + $decorationWidth) as $targetWidth |
      (932 * $targetScale + $decorationHeight) as $targetHeight |
      (($visibleCG.x + (($visibleCG.width - $targetWidth) / 2))) as
        $targetX |
      (($visibleCG.y + (($visibleCG.height - $targetHeight) / 2))) as
        $targetY |
      if (
        ($window.windowNumber | type) != "number" or
        $window.windowNumber <= 0 or
        ($window.screenDisplayID | type) != "number" or
        ($targetWidth > $visibleCG.width) or
        ($targetHeight > $visibleCG.height) or
        ($content.y - $host.y) <= 4 or
        ($crossDisplay and
          $window.screenDisplayID == $target.screenDisplayID) or
        (($crossDisplay | not) and
          $window.screenDisplayID != $target.screenDisplayID)
      ) then
        error("display move preconditions are not exact")
      else
        {
          targetRole: $role,
          targetScale: $targetScale,
          crossDisplay: $crossDisplay,
          targetScreen: $target,
          targetVisibleFrameCG: $visibleCG,
          targetHostSize: {
            width: $targetWidth,
            height: $targetHeight
          },
          beforeScreenDisplayID: $window.screenDisplayID,
          expectedWindowNumber: $window.windowNumber,
          runnerPID: $driver.runnerPid,
          sessionIdentifier: $driver.sessionIdentifier,
          generation: $driver.playcoverGenerationKey,
          drag: {
            start: {
              x: ($host.x + ($host.width / 2)),
              y: ($host.y + (($content.y - $host.y) / 2))
            },
            end: {
              x: ($host.x + ($host.width / 2) + $targetX - $host.x),
              y: ($host.y + (($content.y - $host.y) / 2) +
                $targetY - $host.y)
            }
          }
        }
      end
    ' >"$RUN_DIR/${case_name}_move_plan.json"
}

wait_for_display_phase_status() {
  local case_name="$1"
  local plan_file="$2"
  local require_scale="$3"
  local stdout_file="$RUN_DIR/${case_name}.stdout"
  local stderr_file="$RUN_DIR/${case_name}.stderr"
  printf '%s\t%s\t%s\t%s\t%s\n' \
    "$MATRIX_VERSION" \
    "$case_name" \
    "status --json (wait for exact display matrix phase)" \
    "$stdout_file" \
    "$stderr_file" >>"$MANIFEST"
  local observed=0
  local attempt
  for ((attempt = 1; attempt <= 50; attempt += 1)); do
    if IOS_USE_HOME="$SESSION_HOME" "$ROOT_DIR/ios-use" status --json \
        >"$stdout_file" 2>"$stderr_file" &&
      jq -e \
        --argjson requireScale "$require_scale" \
        --slurpfile plan "$plan_file" '
          ($plan[0]) as $plan |
          (.data.driver) as $driver |
          ($driver.runtime.diagnostics.runtime.window) as $window |
          $driver.runnerPid == $plan.runnerPID and
          $driver.sessionIdentifier == $plan.sessionIdentifier and
          $driver.playcoverGenerationKey == $plan.generation and
          $window.windowNumber == $plan.expectedWindowNumber and
          $window.screenDisplayID ==
            $plan.targetScreen.screenDisplayID and
          $window.screenIsMain ==
            $plan.targetScreen.screenIsMain and
          $window.backingScaleFactor ==
            $plan.targetScreen.backingScaleFactor and
          $window.screenVisibleFrame ==
            $plan.targetScreen.visibleFrame and
          (($requireScale | not) or
            (($window.displayScale - $plan.targetScale) | abs) <= 0.01)
        ' "$stdout_file" >/dev/null; then
      observed=1
      break
    fi
    sleep 0.1
  done
  if [[ "$observed" != "1" ]]; then
    echo \
      "[playcover-fixture-live] FAIL: $case_name did not preserve exact process/window/display identity" \
      >&2
    return 1
  fi
  assert_canonical_host_status "$case_name"
}

run_display_matrix_phase() {
  local case_name="$1"
  local target_role
  local target_scale
  local cross_display
  IFS=$'\t' read -r target_role target_scale cross_display < <(
    display_matrix_row "$case_name"
  ) || {
    echo \
      "[playcover-fixture-live] FAIL: invalid display matrix row $case_name" \
      >&2
    return 1
  }
  local before_case="${case_name}_before_status"
  record_case "$before_case" status --json
  assert_canonical_host_status "$before_case"
  write_display_move_plan \
    "$case_name" \
    "$target_role" \
    "$target_scale" \
    "$cross_display" \
    "$before_case"
  local move_plan="$RUN_DIR/${case_name}_move_plan.json"
  if [[ "$cross_display" == "true" ]]; then
    local move_start_x
    local move_start_y
    local move_end_x
    local move_end_y
    local runner_pid
    local window_number
    read -r \
      move_start_x move_start_y move_end_x move_end_y \
      runner_pid window_number < <(
      jq -r '[
        .drag.start.x,
        .drag.start.y,
        .drag.end.x,
        .drag.end.y,
        .runnerPID,
        .expectedWindowNumber
      ] | @tsv' "$move_plan"
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
      "${case_name}_move_drag" \
      xcrun swift \
      "$ROOT_DIR/playcover-fixtures/appkit_mouse_event.swift" \
      --drag \
      "$move_start_x" \
      "$move_start_y" \
      "$move_end_x" \
      "$move_end_y" \
      "$event_token" \
      "$runner_pid" \
      "$window_number"
    if ! jq -e \
        --argjson token "$event_token" \
        --slurpfile plan "$move_plan" '
          ($plan[0]) as $plan |
          .operation == "drag" and
          .token == $token and
          .targetPID == $plan.runnerPID and
          .targetWindowNumber == $plan.expectedWindowNumber and
          .expectedWindowNumber == $plan.expectedWindowNumber and
          .windowNumberMatched == true and
          .startDisplayID == $plan.beforeScreenDisplayID and
          .endDisplayID == $plan.targetScreen.screenDisplayID and
          .crossDisplayDrag == true and
          .interpolationEventCount >= 2 and
          .endPointReached == true
        ' "$RUN_DIR/${case_name}_move_drag.stdout" >/dev/null; then
      echo \
        "[playcover-fixture-live] FAIL: $case_name lacks exact cross-display window drag evidence" \
        >&2
      return 1
    fi
    wait_for_display_phase_status \
      "${case_name}_move_status" \
      "$move_plan" \
      false
  else
    cp "$RUN_DIR/${before_case}.stdout" \
      "$RUN_DIR/${case_name}_move_status.stdout"
  fi

  local moved_status="$RUN_DIR/${case_name}_move_status.stdout"
  local resize_plan="$RUN_DIR/${case_name}_resize_plan.json"
  jq -e -n \
    --slurpfile move "$move_plan" \
    --slurpfile status "$moved_status" '
      ($move[0]) as $plan |
      ($status[0].data.driver.runtime.diagnostics.runtime.window) as $window |
      ($window.canvasCapture.hostCGWindowBounds) as $host |
      $plan + {
        beforeResizeHost: $host,
        drag: {
          start: {
            x: ($host.x + $host.width - 2),
            y: ($host.y + $host.height - 2)
          },
          end: {
            x: ($host.x + $plan.targetHostSize.width - 2),
            y: ($host.y + $plan.targetHostSize.height - 2)
          }
        }
      }
    ' >"$resize_plan"
  local resize_start_x
  local resize_start_y
  local resize_end_x
  local resize_end_y
  local runner_pid
  local window_number
  read -r \
    resize_start_x resize_start_y resize_end_x resize_end_y \
    runner_pid window_number < <(
    jq -r '[
      .drag.start.x,
      .drag.start.y,
      .drag.end.x,
      .drag.end.y,
      .runnerPID,
      .expectedWindowNumber
    ] | @tsv' "$resize_plan"
  )
  MOUSE_SEQUENCE="$((MOUSE_SEQUENCE + 1))"
  local resize_token
  resize_token="$(
    printf '%s%04d%02d' \
      "$(date +%s)" \
      "$(( $$ % 10000 ))" \
      "$MOUSE_SEQUENCE"
  )"
  record_host_case \
    "${case_name}_resize_drag" \
    xcrun swift \
    "$ROOT_DIR/playcover-fixtures/appkit_mouse_event.swift" \
    --drag \
    "$resize_start_x" \
    "$resize_start_y" \
    "$resize_end_x" \
    "$resize_end_y" \
    "$resize_token" \
    "$runner_pid" \
    "$window_number"
  if ! jq -e \
      --argjson token "$resize_token" \
      --slurpfile plan "$resize_plan" '
        ($plan[0]) as $plan |
        .operation == "drag" and
        .token == $token and
        .targetPID == $plan.runnerPID and
        .targetWindowNumber == $plan.expectedWindowNumber and
        .expectedWindowNumber == $plan.expectedWindowNumber and
        .windowNumberMatched == true and
        .startDisplayID == $plan.targetScreen.screenDisplayID and
        .endDisplayID == $plan.targetScreen.screenDisplayID and
        .crossDisplayDrag == false and
        .interpolationEventCount >= 2 and
        .endPointReached == true
      ' "$RUN_DIR/${case_name}_resize_drag.stdout" >/dev/null; then
    echo \
      "[playcover-fixture-live] FAIL: $case_name lacks exact window resize evidence" \
      >&2
    return 1
  fi
  wait_for_display_phase_status \
    "${case_name}_after_status" \
    "$resize_plan" \
    true
}

assert_display_matrix_identity() {
  if ! jq -e -n \
      --slurpfile main075 \
        "$RUN_DIR/host_main_075_after_status.stdout" \
      --slurpfile extended100 \
        "$RUN_DIR/host_extended_100_after_status.stdout" \
      --slurpfile main0875 \
        "$RUN_DIR/host_main_0875_after_status.stdout" \
      --slurpfile topology "$DISPLAY_SELECTION" '
        ($main075[0].data.driver) as $first |
        ($extended100[0].data.driver) as $second |
        ($main0875[0].data.driver) as $third |
        ($first.runtime.diagnostics.runtime.window) as $firstWindow |
        ($second.runtime.diagnostics.runtime.window) as $secondWindow |
        ($third.runtime.diagnostics.runtime.window) as $thirdWindow |
        $first.runnerPid == $second.runnerPid and
        $second.runnerPid == $third.runnerPid and
        $first.sessionIdentifier == $second.sessionIdentifier and
        $second.sessionIdentifier == $third.sessionIdentifier and
        $first.playcoverGenerationKey == $second.playcoverGenerationKey and
        $second.playcoverGenerationKey == $third.playcoverGenerationKey and
        $firstWindow.windowNumber == $secondWindow.windowNumber and
        $secondWindow.windowNumber == $thirdWindow.windowNumber and
        $firstWindow.screenDisplayID ==
          $topology[0].main.screenDisplayID and
        $secondWindow.screenDisplayID ==
          $topology[0].extended.screenDisplayID and
        $thirdWindow.screenDisplayID ==
          $topology[0].main.screenDisplayID and
        $firstWindow.screenVisibleFrame ==
          $topology[0].main.visibleFrame and
        $secondWindow.screenVisibleFrame ==
          $topology[0].extended.visibleFrame and
        $thirdWindow.screenVisibleFrame ==
          $topology[0].main.visibleFrame and
        $firstWindow.backingScaleFactor ==
          $topology[0].main.backingScaleFactor and
        $secondWindow.backingScaleFactor ==
          $topology[0].extended.backingScaleFactor and
        $thirdWindow.backingScaleFactor ==
          $topology[0].main.backingScaleFactor and
        (($firstWindow.displayScale - 0.75) | abs) <= 0.01 and
        (($secondWindow.displayScale - 1.0) | abs) <= 0.01 and
        (($thirdWindow.displayScale - 0.875) | abs) <= 0.01
      ' >/dev/null; then
    echo \
      "[playcover-fixture-live] FAIL: v2 display matrix changed PID/session/generation/window identity" \
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
          ($canvas | type) != "object" or
          ($window.displayScale | type) != "number" or
          $window.displayScale <= 0
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
            mouseDeliveryCountBefore: $window.mouseDeliveryCount
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
  local after_status_case="${case_name}_after_status"
  record_case "$after_dom_case" dom --json
  record_case "$after_status_case" status --json
  assert_canonical_host_status "$after_status_case"
  if ! jq -e \
      --argjson token "$event_token" \
      --slurpfile coordinates "$coordinates_file" \
      --slurpfile mouse "$RUN_DIR/${case_name}_event.stdout" '
        ($coordinates[0]) as $coordinates |
        (.data.driver.runtime.diagnostics.runtime.window) as $window |
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
      ' "$RUN_DIR/${after_status_case}.stdout" >/dev/null; then
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
record_case start start --playcover --app "$FIXTURE_APP" --log
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
  $runtime.diagnostics.socket.status == "listening" and
  ($runtime.diagnostics.runtime.rendering |
    .syntheticChrome == false and
    .safeAreaOverride == true and
    (.fullFrame |
      .logicalRect == {"x":0,"y":0,"width":430,"height":932} and
      .pixelWidth == 1290 and
      .pixelHeight == 2796 and
      .scale == 3 and
      .uncropped == true and
      .safeAreaCropped == false and
      .identityMapping == true))
'
assert_canonical_host_status status

runner_pid="$(jq -er '.data.driver.runnerPid' "$RUN_DIR/status.stdout")"
session_identifier="$(
  jq -er '.data.driver.sessionIdentifier' "$RUN_DIR/status.stdout"
)"
stdio_log_path="$(
  jq -er '.data.driver.playcoverLogPath' "$RUN_DIR/status.stdout"
)"
lower_session_identifier="$(
  printf '%s' "$session_identifier" |
    /usr/bin/tr '[:upper:]' '[:lower:]'
)"
expected_stdio_log_path="$CANONICAL_SESSION_HOME/playcover/logs/stdio-$lower_session_identifier.log"
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
      .data.driver.playcoverLogPath == $path and
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
    '.data.driver.playcoverRuntimeSocketPath' \
    "$RUN_DIR/status.stdout"
)"
record_case oslog_exact oslog --pid "$runner_pid" \
  --pattern 'ios-use-runtime' --timeout 1s
assert_evidence oslog_exact '\[ios-use-runtime\]'
assert_evidence oslog_exact '"bundleIdentifier":"com.iosuse.playfixture"'

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
  .error.phase == "hit-test"
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
  .error.phase == "identity"
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
  .data.driver.runtime.diagnostics.runtime.window as $appkit |
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
    length) == 1
'
record_case alert_screenshot screenshot \
  --name native-alert --json
assert_evidence alert_screenshot '"compositorWindowNumbers"'
assert_canvas_only_screenshot alert_screenshot
assert_json alert_screenshot '
  .data.runtimeEvidence.compositor.windows as $windows |
  ([$windows[] | select(.class == "_NSAlertPanel")] |
    length) == 1 and
  ([$windows[] | select(.class == "_NSAlertPanel")][0] |
    .deviceLogicalRect ==
      {"x":85,"y":356,"width":260,"height":219}) and
  .data.runtimeEvidence.syntheticChrome == false and
  .data.runtimeEvidence.fullFrame.uncropped == true and
  .data.runtimeEvidence.fullFrame.safeAreaCropped == false
'
assert_ocr_evidence alert_screenshot \
  "Fixture Alert" "Confirm" "Cancel"
record_case alert_dom dom --json
assert_evidence alert_dom 'Fixture Alert'
assert_evidence alert_dom 'Confirm'
assert_evidence alert_dom 'Cancel'
assert_native_alert_blocks_command \
  alert_underlay_tap identity tap "Increment"
assert_native_alert_blocks_command \
  alert_absolute_outside hit-test tap 10,10
assert_native_alert_blocks_command \
  alert_underlay_longpress identity \
  longpress "Long Press Target" --duration 100ms
assert_native_alert_blocks_command \
  alert_underlay_swipe identity \
  swipe --from "Increment" --dir forth --distance 50
assert_native_alert_blocks_command \
  alert_underlay_input identity \
  input --tap "Fixture Input" --content blocked
record_case alert_tap_confirm tap "Confirm" --dom --json
assert_json alert_tap_confirm '
  .data.finalState.phase == "native-ended" and
  .data.finalState.touchID == -1
'
assert_evidence alert_tap_confirm 'Alert Confirmed'

record_case alert_show_default tap "Show Alert" --json
record_case alert_default dismissAlert --json
assert_evidence alert_default \
  '"button"[[:space:]]*:[[:space:]]*"Confirm"'
record_case alert_default_gone waitFor "Fixture Alert" \
  --gone --timeout 10s --json

record_case open_url open "iosusefixture://acceptance/v1" \
  --dom --json
assert_evidence open_url '"dom"'
assert_evidence open_url 'iosusefixture://acceptance/v1'

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

run_display_matrix_phase host_main_075
click_titlebar_and_assert_app_unchanged
run_global_mouse_probe \
  resize_first_top_left \
  "Full TL" \
  "fixture.full.top-left"
run_global_mouse_probe \
  resize_first_bottom_right \
  "Full BR" \
  "fixture.full.bottom-right"

run_display_matrix_phase host_extended_100
record_case capture_after_resize capture --duration 500ms --fps 4 \
  --name fixture-live-resized
capture_after_resize_manifest="$(
  sed -nE 's/^Manifest: (.*)$/\1/p' \
    "$RUN_DIR/capture_after_resize.stdout"
)"
if [[ ! -f "$capture_after_resize_manifest" ]]; then
  echo \
    "[playcover-fixture-live] FAIL: resized capture manifest is unavailable" \
    >&2
  exit 1
fi
assert_canvas_only_capture_manifest "$capture_after_resize_manifest"
run_global_mouse_probe \
  resize_second_top_right \
  "Full TR" \
  "fixture.full.top-right"
run_global_mouse_probe \
  resize_second_bottom_left \
  "Full BL" \
  "fixture.full.bottom-left"
run_display_matrix_phase host_main_0875
assert_display_matrix_identity

record_case swipe_fixed swipe --dir forth --distance 300 \
  --dom --json
assert_evidence swipe_fixed 'Scroll y [1-9][0-9]*'

record_case scene_replace tap "Replace Scene Window" \
  --dom --json
assert_evidence scene_replace 'Scene 2'
record_case scene_replace_status status --json
assert_canonical_host_status scene_replace_status

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
echo "[playcover-fixture-live] PASS matrix v$MATRIX_VERSION"
echo "[playcover-fixture-live] Evidence retained at $RUN_DIR"
