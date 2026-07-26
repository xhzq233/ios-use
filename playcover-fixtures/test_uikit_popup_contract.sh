#!/bin/bash
set -euo pipefail

IOS_USE_POPUP_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IOS_USE_POPUP_SOURCE="$IOS_USE_POPUP_ROOT/playcover-fixtures/Sources/FixtureTabBarController.swift"
IOS_USE_POPUP_MODE="source"

usage() {
  cat <<'USAGE'
Usage: playcover-fixtures/test_uikit_popup_contract.sh [--source|--live]

--source  Verify the deterministic in-window popup source contract (default).
--live    Also exercise an already-active, isolated PlayCover fixture session:
          Runtime touch and a real global AppKit mouse event must activate the
          same popup confirmation button. IOS_USE_HOME must identify that
          session. IOS_USE_POPUP_CLI may override the workspace ./ios-use.
USAGE
}

if [[ $# -gt 1 ]]; then
  usage >&2
  exit 64
fi
if [[ $# -eq 1 ]]; then
  case "$1" in
    --source) IOS_USE_POPUP_MODE="source" ;;
    --live) IOS_USE_POPUP_MODE="live" ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 64
      ;;
  esac
fi

fail_contract() {
  echo "[uikit-popup-contract] FAIL: $*" >&2
  exit 1
}

require_source() {
  local expected="$1"
  rg -Fq -- "$expected" "$IOS_USE_POPUP_SOURCE" ||
    fail_contract "source lacks: $expected"
}

require_identifier_once() {
  local identifier="$1"
  local count
  count="$(
    (rg -Fo -- "\"$identifier\"" "$IOS_USE_POPUP_SOURCE" || true) |
      wc -l |
      tr -d '[:space:]'
  )"
  [[ "$count" == "1" ]] ||
    fail_contract \
      "identifier $identifier must have one source-of-truth declaration; found $count"
}

[[ -f "$IOS_USE_POPUP_SOURCE" ]] ||
  fail_contract "missing fixture source: $IOS_USE_POPUP_SOURCE"
command -v rg >/dev/null 2>&1 ||
  fail_contract "rg is required"

for identifier in \
  fixture.uikit.popup.open \
  fixture.uikit.popup \
  fixture.uikit.popup.confirm \
  fixture.uikit.popup.result; do
  require_identifier_once "$identifier"
done

for semantic_label in \
  "Open UIKit Popup" \
  "UIKit In-Window Popup" \
  "Confirm and Close" \
  "UIKit Popup Result"; do
  require_source "$semantic_label"
done

require_source "private var popupOverlay: UIControl?"
require_source "let hostWindow = view.window"
require_source "hostWindow.addSubview(overlay)"
require_source "overlay.accessibilityViewIsModal = true"
require_source "greaterThanOrEqualTo: overlay.topAnchor"
require_source "lessThanOrEqualTo: overlay.bottomAnchor"
require_source "UIColor.black.withAlphaComponent(0.58)"
require_source "#selector(confirmFixturePopup)"
require_source '"confirmed \(popupConfirmationCount)"'
require_source "UIColor.systemGreen.withAlphaComponent(0.34)"
require_source "overrideUserInterfaceStyle = .light"

# The native UIAlertController remains an independent Catalyst/AppKit gate.
require_source 'showAlert.accessibilityIdentifier = "fixture.uikit.alert"'
require_source "let alert = UIAlertController("
require_source "present(alert, animated: false)"

echo "[uikit-popup-contract] source contract passed"

if [[ "$IOS_USE_POPUP_MODE" != "live" ]]; then
  exit 0
fi

if [[ "$(uname -s)" != "Darwin" || "$(uname -m)" != "arm64" ]]; then
  fail_contract "live mode requires Apple-silicon macOS"
fi
for command_name in jq xcrun shasum; do
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
  .data.driver.runtime.status == "healthy" and
  .data.driver.runtime.logicalWidth > 0 and
  .data.driver.runtime.logicalHeight > 0 and
  .data.driver.runtime.diagnostics.observed.appKit.cgWindowBounds != null
' "$IOS_USE_POPUP_TEMP/status.json" >/dev/null ||
  fail_contract "active fixture lacks healthy Runtime/AppKit geometry"

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
    (($frame[1] + $frame[3]) <= $runtime.logicalHeight)) and
  .data.postcondition.changed == true and
  .data.postcondition.pixelEvidence.changed == true
' "$IOS_USE_POPUP_TEMP/runtime-open.json" >/dev/null ||
  fail_contract "Runtime open lacks popup DOM, full-frame, or pixel evidence"

run_cli runtime-confirm \
  tap "Confirm and Close" --dom --json
jq -e '
  .data.element.identifier == "fixture.uikit.popup.confirm" and
  .data.postcondition.changed == true and
  .data.postcondition.pixelEvidence.changed == true and
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
    length) == 1 and
  .data.postcondition.pixelEvidence.changed == true
' "$IOS_USE_POPUP_TEMP/global-open.json" >/dev/null ||
  fail_contract "second popup open is not visible"

run_cli global-before \
  screenshot --name uikit-popup-global-before --json
IOS_USE_POPUP_BEFORE_IMAGE="$(
  jq -er '.data.imagePath' "$IOS_USE_POPUP_TEMP/global-before.json"
)"
[[ -f "$IOS_USE_POPUP_BEFORE_IMAGE" ]] ||
  fail_contract "pre-mouse popup screenshot is unavailable"

read -r IOS_USE_POPUP_GLOBAL_X IOS_USE_POPUP_GLOBAL_Y < <(
  jq -r \
    -n \
    --slurpfile open "$IOS_USE_POPUP_TEMP/global-open.json" \
    --slurpfile status "$IOS_USE_POPUP_TEMP/status.json" '
      ($open[0].data.postDom.elements[] |
        select(.identifier == "fixture.uikit.popup.confirm") |
        .frame) as $button |
      ($status[0].data.driver.runtime) as $runtime |
      ($runtime.diagnostics.observed.appKit.cgWindowBounds) as $window |
      [
        ($window.x +
          (($button[0] + ($button[2] / 2)) /
            $runtime.logicalWidth * $window.width)),
        ($window.y +
          (($button[1] + ($button[3] / 2)) /
            $runtime.logicalHeight * $window.height))
      ] |
      @tsv
    '
)
[[ -n "$IOS_USE_POPUP_GLOBAL_X" && -n "$IOS_USE_POPUP_GLOBAL_Y" ]] ||
  fail_contract "could not map the popup confirmation frame to global AppKit coordinates"

IOS_USE_POPUP_RUNNER_PID="$(
  jq -er '.data.driver.runnerPid' "$IOS_USE_POPUP_TEMP/status.json"
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
