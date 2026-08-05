#!/bin/bash
set -euo pipefail

IOS_USE_POPUP_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

usage() {
  cat <<'USAGE'
Usage: playcover-fixtures/test_uikit_popup_contract.sh --live

--live    Exercise an already-active, isolated PlayCover fixture session:
          Runtime touch and a real global AppKit mouse event must activate the
          same popup confirmation button. IOS_USE_HOME must identify that
          session. IOS_USE_POPUP_CLI may override the workspace ./ios-use.
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

fail_contract() {
  echo "[uikit-popup-contract] FAIL: $*" >&2
  exit 1
}

if [[ "$(uname -s)" != "Darwin" || "$(uname -m)" != "arm64" ]]; then
  fail_contract "live mode requires Apple-silicon macOS"
fi
for command_name in jq rg xcrun shasum; do
  command -v "$command_name" >/dev/null 2>&1 ||
    fail_contract "$command_name is required for live mode"
done

IOS_USE_POPUP_SESSION_HOME="${IOS_USE_HOME:-}"
[[ -n "$IOS_USE_POPUP_SESSION_HOME" ]] ||
  fail_contract "live mode requires IOS_USE_HOME for an isolated active fixture session"
[[ -d "$IOS_USE_POPUP_SESSION_HOME" ]] ||
  fail_contract "IOS_USE_HOME does not exist: $IOS_USE_POPUP_SESSION_HOME"

IOS_USE_POPUP_CLI_PATH="${IOS_USE_POPUP_CLI:-$IOS_USE_POPUP_ROOT/ios-use}"
[[ -x "$IOS_USE_POPUP_CLI_PATH" ]] ||
  fail_contract "workspace CLI is not executable: $IOS_USE_POPUP_CLI_PATH"

IOS_USE_POPUP_OWNS_TEMP=1
if [[ -n "${IOS_USE_POPUP_EVIDENCE_DIR:-}" ]]; then
  IOS_USE_POPUP_TEMP="$IOS_USE_POPUP_EVIDENCE_DIR"
  if [[ -e "$IOS_USE_POPUP_TEMP" ]]; then
    fail_contract \
      "evidence directory already exists: $IOS_USE_POPUP_TEMP"
  fi
  mkdir -p "$IOS_USE_POPUP_TEMP"
  IOS_USE_POPUP_OWNS_TEMP=0
else
  IOS_USE_POPUP_TEMP="$(
    mktemp -d "${TMPDIR:-/tmp}/ios-use-uikit-popup.XXXXXX"
  )"
fi
cleanup_popup_contract() {
  if [[ "$IOS_USE_POPUP_OWNS_TEMP" != "1" ]]; then
    return
  fi
  if [[
    -n "${IOS_USE_POPUP_TEMP:-}" &&
    -d "$IOS_USE_POPUP_TEMP" &&
    "$(basename "$IOS_USE_POPUP_TEMP")" == ios-use-uikit-popup.*
  ]]; then
    rm -rf -- "$IOS_USE_POPUP_TEMP"
  fi
}
trap cleanup_popup_contract EXIT

run_cli() {
  local output_name="$1"
  shift
  IOS_USE_HOME="$IOS_USE_POPUP_SESSION_HOME" \
    "$IOS_USE_POPUP_CLI_PATH" "$@" \
    >"$IOS_USE_POPUP_TEMP/$output_name.json"
}

run_cli status status --json
rg -q -- "com.iosuse.playfixture" \
  "$IOS_USE_POPUP_TEMP/status.json" ||
  fail_contract "active session is not the PlayCover acceptance fixture"
jq -e '
  .data.driver.runtime as $runtime |
  ($runtime.diagnostics.runtime.window) as $window |
  ($window.canvasCapture) as $capture |
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
  $window.title == "IOSUsePlayFixture" and
  $window.canvasBounds == {"x":0,"y":0,"width":430,"height":932} and
  ($window.displayScale | type) == "number" and
  $window.displayScale > 0 and
  ($window.inverseDisplayScale | type) == "number" and
  (($window.displayScale * $window.inverseDisplayScale - 1) | abs) <= 0.0001 and
  ($window.hostContentBounds | type) == "object" and
  ($window.canvasRect | type) == "object" and
  (($window.canvasRect.width / $window.displayScale - 430) | abs) <= 0.5 and
  (($window.canvasRect.height / $window.displayScale - 932) | abs) <= 0.5 and
  ($capture.canvasCGWindowRect | type) == "object" and
  ($capture.hostContentCGWindowRect | type) == "object" and
  (($capture.canvasCGWindowRect.width / $window.displayScale - 430) | abs) <= 0.5 and
  (($capture.canvasCGWindowRect.height / $window.displayScale - 932) | abs) <= 0.5
' "$IOS_USE_POPUP_TEMP/status.json" >/dev/null ||
  fail_contract "active fixture lacks the canonical healthy Runtime host/canvas geometry"

run_cli initial-dom dom --json
jq -e '
  ([.data.elements[] |
    select(
      .identifier == "fixture.uikit.popup.open" and
      .state.visible == true
    )] | length) == 1 and
  all(.data.elements[];
      .identifier != "fixture.uikit.popup" and
      .identifier != "fixture.uikit.popup.confirm")
' "$IOS_USE_POPUP_TEMP/initial-dom.json" >/dev/null ||
  fail_contract "live mode requires a fresh UIKit fixture with the popup closed"

run_cli runtime-open \
  tap "Open UIKit Popup" --dom --json
jq -e --slurpfile status "$IOS_USE_POPUP_TEMP/status.json" '
  ($status[0].data.driver.runtime) as $runtime |
  ([.data.postDom.elements[] |
    select(.identifier == "fixture.uikit.popup")] |
    length) == 1 and
  ([.data.postDom.elements[] |
    select(
      .identifier == "fixture.uikit.popup.confirm" and
      .label == "Confirm and Close" and
      .state.visible == true
    )] | length) == 1 and
  ([.data.postDom.elements[] |
    select(.identifier == "fixture.uikit.popup.result")] |
    length) == 1 and
  (.data.postDom.elements[] |
    select(.identifier == "fixture.uikit.popup") |
    .frame as $frame |
    ($frame[0] >= 0) and
    ($frame[1] >= 0) and
    (($frame[0] + $frame[2]) <= $runtime.logicalWidth) and
    (($frame[1] + $frame[3]) <= $runtime.logicalHeight))
' "$IOS_USE_POPUP_TEMP/runtime-open.json" >/dev/null ||
  fail_contract "Runtime open did not expose the expected popup DOM"

run_cli runtime-confirm \
  tap "Confirm and Close" --dom --json
jq -e '
  .data.element.identifier == "fixture.uikit.popup.confirm" and
  ([.data.postDom.elements[] |
    select(.identifier == "fixture.uikit.popup.result" and
      (.value | test("^confirmed [0-9]+$")))] |
    length) == 1 and
  all(.data.postDom.elements[];
    .identifier != "fixture.uikit.popup" and
    .identifier != "fixture.uikit.popup.confirm")
' "$IOS_USE_POPUP_TEMP/runtime-confirm.json" >/dev/null ||
  fail_contract "Runtime touch did not confirm and close the popup"

IOS_USE_POPUP_RUNTIME_COUNT="$(
  jq -er '
    [.data.postDom.elements[] |
      select(.identifier == "fixture.uikit.popup.result") |
      .value |
      capture("^confirmed (?<count>[0-9]+)$").count |
      tonumber] |
    unique |
    if length == 1 then .[0] else error("ambiguous result") end
  ' "$IOS_USE_POPUP_TEMP/runtime-confirm.json"
)"
IOS_USE_POPUP_EXPECTED_GLOBAL_COUNT="$((IOS_USE_POPUP_RUNTIME_COUNT + 1))"

run_cli global-open \
  tap "Open UIKit Popup" --dom --json
jq -e '
  ([.data.postDom.elements[] |
    select(.identifier == "fixture.uikit.popup.confirm" and
      .state.visible == true)] |
    length) == 1
' "$IOS_USE_POPUP_TEMP/global-open.json" >/dev/null ||
  fail_contract "second popup open is not visible"

run_cli global-before \
  screenshot --name uikit-popup-global-before --json
IOS_USE_POPUP_BEFORE_IMAGE="$(
  jq -er '.data.imagePath' "$IOS_USE_POPUP_TEMP/global-before.json"
)"
[[ -f "$IOS_USE_POPUP_BEFORE_IMAGE" ]] ||
  fail_contract "pre-mouse popup screenshot is unavailable"

IOS_USE_POPUP_COORDINATES="$IOS_USE_POPUP_TEMP/global-coordinates.json"
if ! jq -e \
    -n \
    --slurpfile open "$IOS_USE_POPUP_TEMP/global-open.json" \
    --slurpfile status "$IOS_USE_POPUP_TEMP/status.json" '
      [
        $open[0].data.postDom.elements[] |
        select(
          .identifier == "fixture.uikit.popup.confirm" and
          .state.visible == true and
          .state.enabled == true and
          (.frame | type) == "array" and
          (.frame | length) == 4 and
          .frame[2] > 0 and
          .frame[3] > 0
        )
      ] as $buttons |
      ($status[0].data.driver.runtime) as $runtime |
      ($runtime.diagnostics.runtime.window) as $window |
      ($window.canvasCapture.canvasCGWindowRect) as $canvas |
      if ($buttons | length) != 1 then
        error("expected exactly one visible popup confirmation button")
      elif (
        $window.canvasBounds != {"x":0,"y":0,"width":430,"height":932} or
        ($window.displayScale | type) != "number" or
        $window.displayScale <= 0 or
        ($window.inverseDisplayScale | type) != "number" or
        (($window.displayScale * $window.inverseDisplayScale - 1) | abs) > 0.0001 or
        ($canvas | type) != "object" or
        (($canvas.width / $window.displayScale - 430) | abs) > 0.5 or
        (($canvas.height / $window.displayScale - 932) | abs) > 0.5
      ) then
        error("canonical canvas geometry is unavailable")
      else
        ($buttons[0].frame) as $button |
        ($button[0] + ($button[2] / 2)) as $logicalX |
        ($button[1] + ($button[3] / 2)) as $logicalY |
        if (
          $logicalX < 0 or $logicalX > 430 or
          $logicalY < 0 or $logicalY > 932
        ) then
          error("popup confirmation center is outside the fixed canvas")
        else
          ($canvas.x + ($logicalX * $window.displayScale)) as $globalX |
          ($canvas.y + ($logicalY * $window.displayScale)) as $globalY |
          (($globalX - $canvas.x) * $window.inverseDisplayScale) as $inverseX |
          (($globalY - $canvas.y) * $window.inverseDisplayScale) as $inverseY |
          if (
            (($inverseX - $logicalX) | abs) > 0.5 or
            (($inverseY - $logicalY) | abs) > 0.5
          ) then
            error("canonical canvas inverse transform exceeds 0.5pt")
          else
            {
              logicalPoint: {x: $logicalX, y: $logicalY},
              globalPoint: {x: $globalX, y: $globalY},
              displayScale: $window.displayScale,
              inverseDisplayScale: $window.inverseDisplayScale,
              canvasCGWindowRect: $canvas,
              runnerPID: $status[0].data.driver.runnerPid,
              snapshotGeneration: $buttons[0].snapshotGeneration
            }
          end
        end
      end
    ' >"$IOS_USE_POPUP_COORDINATES"; then
  fail_contract "could not map the popup button through canonical canvas geometry"
fi

read -r IOS_USE_POPUP_GLOBAL_X IOS_USE_POPUP_GLOBAL_Y < <(
  jq -r '[.globalPoint.x, .globalPoint.y] | @tsv' \
    "$IOS_USE_POPUP_COORDINATES"
)
[[ -n "$IOS_USE_POPUP_GLOBAL_X" && -n "$IOS_USE_POPUP_GLOBAL_Y" ]] ||
  fail_contract "could not read canonical popup global coordinates"

IOS_USE_POPUP_RUNNER_PID="$(
  jq -er '.runnerPID' "$IOS_USE_POPUP_COORDINATES"
)"
IOS_USE_POPUP_EVENT_TOKEN="$(
  printf '%s%03d\n' "$(date +%s)" "$(( $$ % 1000 ))"
)"
if ! xcrun swift \
    "$IOS_USE_POPUP_ROOT/playcover-fixtures/appkit_mouse_event.swift" \
    "$IOS_USE_POPUP_GLOBAL_X" \
    "$IOS_USE_POPUP_GLOBAL_Y" \
    "$IOS_USE_POPUP_EVENT_TOKEN" \
    "$IOS_USE_POPUP_RUNNER_PID" \
    >"$IOS_USE_POPUP_TEMP/global-mouse.json" \
    2>"$IOS_USE_POPUP_TEMP/global-mouse.stderr"; then
  cat "$IOS_USE_POPUP_TEMP/global-mouse.json" >&2
  cat "$IOS_USE_POPUP_TEMP/global-mouse.stderr" >&2
  fail_contract "global AppKit mouse event injection failed"
fi

jq -e \
  --argjson token "$IOS_USE_POPUP_EVENT_TOKEN" \
  --argjson runnerPID "$IOS_USE_POPUP_RUNNER_PID" \
  --slurpfile coordinates "$IOS_USE_POPUP_COORDINATES" '
    ($coordinates[0].globalPoint) as $point |
    .operation == "click" and
    .token == $token and
    .targetPID == $runnerPID and
    .targetWindowNumber > 0 and
    .postEventAccess == true and
    .globalPoint.x >= ($point.x - 0.5) and
    .globalPoint.x <= ($point.x + 0.5) and
    .globalPoint.y >= ($point.y - 0.5) and
    .globalPoint.y <= ($point.y + 0.5)
  ' "$IOS_USE_POPUP_TEMP/global-mouse.json" >/dev/null ||
  fail_contract "global mouse evidence is not bound to the canonical canvas point"

IOS_USE_POPUP_GLOBAL_CONFIRMED=0
for _ in $(seq 1 30); do
  run_cli global-dom dom --json
  if jq -e \
    --arg expected "confirmed $IOS_USE_POPUP_EXPECTED_GLOBAL_COUNT" '
      ([.data.elements[] |
        select(.identifier == "fixture.uikit.popup.result" and
          .value == $expected)] |
        length) == 1 and
      all(.data.elements[];
        .identifier != "fixture.uikit.popup" and
        .identifier != "fixture.uikit.popup.confirm")
    ' "$IOS_USE_POPUP_TEMP/global-dom.json" >/dev/null; then
    IOS_USE_POPUP_GLOBAL_CONFIRMED=1
    break
  fi
  sleep 0.1
done
[[ "$IOS_USE_POPUP_GLOBAL_CONFIRMED" == "1" ]] ||
  fail_contract "global AppKit mouse did not activate the popup confirmation button"

run_cli global-delivery-status status --json
jq -e \
  --argjson token "$IOS_USE_POPUP_EVENT_TOKEN" \
  --slurpfile coordinates "$IOS_USE_POPUP_COORDINATES" \
  --slurpfile mouse "$IOS_USE_POPUP_TEMP/global-mouse.json" '
    ($coordinates[0].logicalPoint) as $point |
    (.data.driver.runtime.diagnostics.runtime.window) as $window |
    ($window.lastMouseDownDelivery) as $down |
    ($window.lastMouseUpDelivery) as $up |
    $window.status == "configured" and
    $down.token == $token and
    $up.token == $token and
    $down.targetPID == $coordinates[0].runnerPID and
    $up.targetPID == $coordinates[0].runnerPID and
    $down.windowNumber == $mouse[0].targetWindowNumber and
    $up.windowNumber == $mouse[0].targetWindowNumber and
    $down.phase == "down" and
    $up.phase == "up" and
    $down.geometryReady == true and
    $up.geometryReady == true and
    $down.targetHitTest == true and
    $up.targetHitTest == true and
    (($down.logicalPoint.x - $point.x) | abs) <= 0.5 and
    (($down.logicalPoint.y - $point.y) | abs) <= 0.5 and
    (($up.logicalPoint.x - $point.x) | abs) <= 0.5 and
    (($up.logicalPoint.y - $point.y) | abs) <= 0.5
  ' "$IOS_USE_POPUP_TEMP/global-delivery-status.json" >/dev/null ||
  fail_contract "global popup mouse delivery did not round-trip through the canvas within 0.5pt"

run_cli global-after \
  screenshot --name uikit-popup-global-after --json
IOS_USE_POPUP_AFTER_IMAGE="$(
  jq -er '.data.imagePath' "$IOS_USE_POPUP_TEMP/global-after.json"
)"
[[ -f "$IOS_USE_POPUP_AFTER_IMAGE" ]] ||
  fail_contract "post-mouse popup screenshot is unavailable"
IOS_USE_POPUP_BEFORE_SHA="$(
  shasum -a 256 "$IOS_USE_POPUP_BEFORE_IMAGE" |
    awk '{print $1}'
)"
IOS_USE_POPUP_AFTER_SHA="$(
  shasum -a 256 "$IOS_USE_POPUP_AFTER_IMAGE" |
    awk '{print $1}'
)"
[[ "$IOS_USE_POPUP_BEFORE_SHA" != "$IOS_USE_POPUP_AFTER_SHA" ]] ||
  fail_contract "global mouse produced no visible screenshot change"

echo \
  "[uikit-popup-contract] live Runtime touch + global AppKit mouse contract passed"
