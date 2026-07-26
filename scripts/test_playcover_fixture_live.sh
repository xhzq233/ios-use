#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MATRIX_VERSION="1"
MATRIX_SOURCE="$ROOT_DIR/playcover-fixtures/live-matrix-v1.tsv"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
EVIDENCE_ROOT="${IOS_USE_PLAYCOVER_EVIDENCE_ROOT:-$ROOT_DIR/.ios-use/live-evidence}"
RUN_DIR="$EVIDENCE_ROOT/playcover-fixture-v${MATRIX_VERSION}/$RUN_ID"
SESSION_HOME=""
ARCHIVED_SESSION_HOME="$RUN_DIR/session-home"
MANIFEST="$RUN_DIR/manifest.tsv"
FIXTURE_APP="${IOS_USE_PLAYCOVER_FIXTURE_APP:-}"
ORIGINAL_FRONTMOST_PID=""
ORIGINAL_FRONTMOST_BUNDLE=""
FRONTMOST_CAPTURED=0
FOCUS_RESTORE_MANIFESTED=0
MOUSE_SEQUENCE=0

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

SESSION_HOME="$(mktemp -d /tmp/iupf.XXXXXX)"
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
  IOS_USE_HOME="$SESSION_HOME" "$ROOT_DIR/ios-use" stop \
    >"$RUN_DIR/cleanup.stdout" 2>"$RUN_DIR/cleanup.stderr" || true
  archive_session_home || true
  restore_original_frontmost_application || true
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
  printf '%s\t%s\t%s\t%s\t%s\n' \
    "$MATRIX_VERSION" \
    "${case_prefix}_coordinates" \
    "derive $probe_identifier logical point from fresh DOM and current CG window bounds" \
    "$coordinates_file" \
    "$coordinates_stderr" >>"$MANIFEST"
  if ! jq -e \
      --arg identifier "$probe_identifier" \
      --arg label "$probe_label" \
      --slurpfile status "$RUN_DIR/${status_case}.stdout" '
        . as $dom |
        ($status[0].data.driver.runtime) as $runtime |
        ($runtime.diagnostics.observed.appKit) as $appKit |
        ($appKit.cgWindowBounds) as $window |
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
          $appKit.contentViewBounds !=
            {"x":0,"y":0,"width":430,"height":932} or
          ($window | type) != "object" or
          $window.width != 430 or
          $window.height != 932
        ) then
          error("fixed Runtime/AppKit geometry is not mouse-ready")
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
                x: (
                  $window.x +
                  ($logicalX / $runtime.logicalWidth * $window.width)
                ),
                y: (
                  $window.y +
                  ($logicalY / $runtime.logicalHeight * $window.height)
                )
              },
              logicalSize: {
                width: $runtime.logicalWidth,
                height: $runtime.logicalHeight
              },
              runnerPID: $status[0].data.driver.runnerPid,
              cgWindowBounds: $window,
              mouseDeliveryCountBefore: $appKit.mouseDeliveryCount
            }
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
  if ! jq -e \
      --argjson token "$event_token" \
      --slurpfile coordinates "$coordinates_file" \
      --slurpfile mouse "$RUN_DIR/${mouse_case}.stdout" \
      --slurpfile postDom "$RUN_DIR/${post_dom_case}.stdout" '
        ($coordinates[0]) as $coordinates |
        ($coordinates.logicalPoint) as $point |
        (.data.driver.runtime.diagnostics.observed.appKit) as $appKit |
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

capture_original_frontmost_application
record_case start start --playcover --app "$FIXTURE_APP"
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
  $runtime.safeAreaTop == 59 and
  $runtime.safeAreaLeft == 0 and
  $runtime.safeAreaBottom == 34 and
  $runtime.safeAreaRight == 0 and
  $runtime.diagnostics.socket.transport == "unix-domain-socket" and
  $runtime.diagnostics.socket.status == "listening" and
  ($runtime.diagnostics.observed.appKit |
    .status == "configured" and
    .borderless == true and
    .hasShadow == false and
    .movable == false and
    .fixedSizePolicy == true and
    .minSize == {"width":430,"height":932} and
    .maxSize == {"width":430,"height":932} and
    .contentMinSize == {"width":430,"height":932} and
    .contentMaxSize == {"width":430,"height":932}) and
  ($runtime.diagnostics.runtime.systemChrome |
    .stage == "installed" and
    .windowAttached == 1 and
    .chromeWindowCount == 1 and
    .dynamicIslandSurface == true and
    .statusSurface == true and
    .homeIndicatorSurface == true)
'

runner_pid="$(jq -er '.data.driver.runnerPid' "$RUN_DIR/status.stdout")"
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
assert_evidence screenshot_initial '"systemChromeEvidence"'
assert_evidence screenshot_initial '"appKitWindowEvidence"'
assert_evidence screenshot_initial '"compositor"'
assert_json screenshot_initial '
  .data.pixelSize == [1290,2796] and
  .data.logicalSize == [430,932] and
  .data.runtimeEvidence.complete == true and
  .data.runtimeEvidence.captureGeneration > 0 and
  (.data.runtimeEvidence.compositor.completeness |
    .allVisibleNativeWindowsOrdered == true and
    .allVisibleUIKitWindowsMapped == true and
    .allWindowGeometryInsideDevice == true and
    .baseWindowCoversDevice == true and
    .requestedCapturedCountMatch == true and
    .systemChromeMapped == true and
    .windowSetStableDuringCapture == true) and
  (.data.runtimeEvidence.appKitWindowEvidence as $appKit |
    $appKit.status == "configured" and
    $appKit.applicationActive == true and
    $appKit.windowKey == true and
    $appKit.fixedSizePolicy == true and
    $appKit.identityTransform == true and
    $appKit.frame.width == 430 and
    $appKit.frame.height == 932 and
    $appKit.contentLayoutRect ==
      {"x":0,"y":0,"width":430,"height":932} and
    $appKit.contentViewBounds ==
      {"x":0,"y":0,"width":430,"height":932} and
    $appKit.cgWindowBounds.width == 430 and
    $appKit.cgWindowBounds.height == 932 and
    $appKit.cgWindowBounds.x >=
      ($appKit.expectedCGWindowBoundsFromAppKit.x - 0.5) and
    $appKit.cgWindowBounds.x <=
      ($appKit.expectedCGWindowBoundsFromAppKit.x + 0.5) and
    $appKit.cgWindowBounds.y >=
      ($appKit.expectedCGWindowBoundsFromAppKit.y - 0.5) and
    $appKit.cgWindowBounds.y <=
      ($appKit.expectedCGWindowBoundsFromAppKit.y + 0.5) and
    any(
      $appKit.scenes[];
      .activationState == 0 and
      any(
        .windows[];
        .key == true and
        .hidden == false and
        .frame == {"x":0,"y":0,"width":430,"height":932}
      )
    )) and
  (.data.runtimeEvidence.systemChromeEvidence |
    .lastImageEvidence.ready == true and
    .surfaceEvidence.dynamicIsland.ready == true and
    .surfaceEvidence.status.ready == true and
    .surfaceEvidence.homeIndicator.ready == true)
'

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
assert_json status_after_screenshot_refocus '
  .data.driver.runnerPid as $runnerPID |
  .data.driver.runtime as $runtime |
  $runnerPID > 0 and
  $runtime.status == "healthy" and
  $runtime.logicalWidth == 430 and
  $runtime.logicalHeight == 932 and
  $runtime.nativeWidth == 1290 and
  $runtime.nativeHeight == 2796 and
  $runtime.scale == 3 and
  ($runtime.diagnostics.observed.appKit as $appKit |
    $appKit.status == "configured" and
    $appKit.applicationActive == true and
    $appKit.windowKey == true and
    $appKit.fixedSizePolicy == true and
    $appKit.identityTransform == true and
    $appKit.contentLayoutRect ==
      {"x":0,"y":0,"width":430,"height":932} and
    $appKit.contentViewBounds ==
      {"x":0,"y":0,"width":430,"height":932} and
    $appKit.cgWindowBounds.width == 430 and
    $appKit.cgWindowBounds.height == 932 and
    any(
      $appKit.scenes[];
      .activationState == 0 and
      any(
        .windows[];
        .key == true and
        .hidden == false and
        .frame == {"x":0,"y":0,"width":430,"height":932}
      )
    ))
'

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
  ' "$capture_manifest" >/dev/null; then
  echo \
    "[playcover-fixture-live] FAIL: capture manifest contract failed" \
    >&2
  exit 1
fi

record_case dom_initial dom --json
assert_evidence dom_initial 'fixture.uikit.increment'
assert_evidence dom_initial 'fixture.safe.top-left'
assert_evidence dom_initial 'fixture.full.top-left'
assert_evidence dom_initial 'fixture.island.left'
assert_evidence dom_initial 'fixture.home.above'

record_case tap tap "Increment" --dom --json
assert_evidence tap 'Count 1'
assert_evidence tap \
  '"pixelEvidence"[[:space:]]*:[[:space:]]*\{'

no_op_stdout="$RUN_DIR/no_op.stdout"
no_op_stderr="$RUN_DIR/no_op.stderr"
printf '%s\t%s\t%s\t%s\t%s\n' \
  "$MATRIX_VERSION" \
  "no_op" \
  "tap No-op Target --json" \
  "$no_op_stdout" \
  "$no_op_stderr" >>"$MANIFEST"
if IOS_USE_HOME="$SESSION_HOME" "$ROOT_DIR/ios-use" \
    tap "No-op Target" --json \
    >"$no_op_stdout" 2>"$no_op_stderr"; then
  echo "[playcover-fixture-live] FAIL: no-op touch reported success" >&2
  exit 1
fi
if ! rg -q -- "postcondition_failed" \
    "$no_op_stdout" "$no_op_stderr"; then
  echo "[playcover-fixture-live] FAIL: no-op lacks postcondition_failed" >&2
  exit 1
fi

record_case longpress longpress "Long Press Target" \
  --duration 500ms --dom --json
assert_evidence longpress 'Long press recognized'
assert_evidence longpress \
  '"pixelEvidence"[[:space:]]*:[[:space:]]*\{'

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
  .data.driver.runtime.diagnostics.observed.appKit as $appkit |
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
assert_json alert_screenshot '
  .data.runtimeEvidence.compositor.windows as $windows |
  ([$windows[] | select(.class == "_NSAlertPanel")] |
    length) == 1 and
  ([$windows[] | select(.class == "_NSAlertPanel")][0] |
    .deviceLogicalRect ==
      {"x":85,"y":356,"width":260,"height":219}) and
  (.data.runtimeEvidence.systemChromeEvidence.lastImageEvidence |
    .ready == true and
    .nativeAlertVisible == true and
    .modalDimmedSignatures == true)
'
assert_ocr_evidence alert_screenshot \
  "Fixture Alert" "Confirm" "Cancel"
record_case alert_dom dom --json
assert_evidence alert_dom 'Fixture Alert'
assert_evidence alert_dom 'Confirm'
assert_evidence alert_dom 'Cancel'
record_case alert_tap_confirm tap "Confirm" --dom --json
assert_evidence alert_tap_confirm 'Alert Confirmed'
assert_evidence alert_tap_confirm \
  '"changed"[[:space:]]*:[[:space:]]*true'

record_case alert_show_default tap "Show Alert" --json
record_case alert_default dismissAlert --json
assert_evidence alert_default \
  '"button"[[:space:]]*:[[:space:]]*"Confirm"'
assert_evidence alert_default '"postcondition"'
assert_evidence alert_default \
  '"changed"[[:space:]]*:[[:space:]]*true'

record_case open_url open "iosusefixture://acceptance/v1" \
  --dom --json
assert_evidence open_url '"dom"'
assert_evidence open_url 'iosusefixture://acceptance/v1'

for probe in \
  "Full TL" "Full TR" "Full BL" "Full BR" \
  "Safe Top Left" "Safe Top Right" \
  "Safe Bottom Left" "Safe Bottom Right"; do
  probe_case="$(
    printf '%s' "$probe" |
      tr '[:upper:] ' '[:lower:]-'
  )"
  case "$probe" in
    "Full TL") probe_identifier="fixture.full.top-left" ;;
    "Full TR") probe_identifier="fixture.full.top-right" ;;
    "Full BL") probe_identifier="fixture.full.bottom-left" ;;
    "Full BR") probe_identifier="fixture.full.bottom-right" ;;
    "Safe Top Left") probe_identifier="fixture.safe.top-left" ;;
    "Safe Top Right") probe_identifier="fixture.safe.top-right" ;;
    "Safe Bottom Left")
      probe_identifier="fixture.safe.bottom-left"
      ;;
    "Safe Bottom Right")
      probe_identifier="fixture.safe.bottom-right"
      ;;
  esac
  record_case "probe_${probe_case}" tap "$probe" --dom --json
  assert_evidence "probe_${probe_case}" "$probe_identifier"
done
record_case island_probe tap "Island Left" --dom --json
assert_evidence island_probe 'fixture.island.left'
record_case island_probe_right tap "Island Right" --dom --json
assert_evidence island_probe_right 'fixture.island.right'
record_case home_probe tap "Above Home" --dom --json
assert_evidence home_probe 'fixture.home.above'

while IFS='|' read -r mouse_probe_case mouse_probe_label mouse_probe_identifier; do
  run_global_mouse_probe \
    "$mouse_probe_case" \
    "$mouse_probe_label" \
    "$mouse_probe_identifier"
done <<'MOUSE_PROBES'
full_top_left|Full TL|fixture.full.top-left
full_top_right|Full TR|fixture.full.top-right
full_bottom_left|Full BL|fixture.full.bottom-left
full_bottom_right|Full BR|fixture.full.bottom-right
safe_top_left|Safe Top Left|fixture.safe.top-left
safe_top_right|Safe Top Right|fixture.safe.top-right
safe_bottom_left|Safe Bottom Left|fixture.safe.bottom-left
safe_bottom_right|Safe Bottom Right|fixture.safe.bottom-right
island_left|Island Left|fixture.island.left
island_right|Island Right|fixture.island.right
home_above|Above Home|fixture.home.above
MOUSE_PROBES

record_case swipe_fixed swipe --dir forth --distance 300 \
  --dom --json
assert_evidence swipe_fixed 'Scroll y [1-9][0-9]*'
assert_evidence swipe_fixed \
  '"changed"[[:space:]]*:[[:space:]]*true'
assert_evidence swipe_fixed \
  '"pixelEvidence"[[:space:]]*:[[:space:]]*\{'

record_case scene_replace tap "Replace Scene Window" \
  --dom --json
assert_evidence scene_replace 'Scene 2'

record_case swiftui_tab tap "SwiftUI" --dom --json
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
assert_ocr_evidence screenshot_metal \
  "Metal opaque canvas active" "Metal Overlay Tapped"
assert_metal_pixel screenshot_metal

record_case stop stop
archive_session_home
restore_original_frontmost_application
trap - EXIT
trap - ERR
echo "[playcover-fixture-live] PASS matrix v$MATRIX_VERSION"
echo "[playcover-fixture-live] Evidence retained at $RUN_DIR"
