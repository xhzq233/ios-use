#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BRIDGE_SOURCE="$ROOT_DIR/playcover-runtime/IOSUsePlayAppKitBridge.m"
COMPOSITOR_SOURCE="$ROOT_DIR/playcover-runtime/IOSUsePlayWindowCompositor.m"
COMPOSITOR_HEADER="$ROOT_DIR/playcover-runtime/IOSUsePlayWindowCompositor.h"
SCREENSHOT_SOURCE="$ROOT_DIR/playcover-runtime/IOSUsePlayRuntimeScreenshot.m"
FIXTURE_LIVE="$ROOT_DIR/scripts/test_playcover_fixture_live.sh"
EXTERNAL_LIVE="$ROOT_DIR/scripts/test_playcover_external_app_live.sh"
POPUP_CONTRACT="$ROOT_DIR/playcover-fixtures/test_uikit_popup_contract.sh"
MOUSE_HELPER="$ROOT_DIR/playcover-fixtures/appkit_mouse_event.swift"

usage() {
  cat <<'USAGE'
Usage: playcover-fixtures/test_simulator_scale_host_contract.sh [--static]

Verify the source-level ordinary NSWindow, fixed logical canvas, proportional
Simulator-scale resize, and canvas-only capture contracts. This check neither
launches an App nor posts input events, so it is safe on a non-GUI or locked
host. Live interaction remains in the explicitly selected fixture and
external-App gates.
USAGE
}

if [[ $# -gt 1 ]]; then
  usage >&2
  exit 64
fi
if [[ $# -eq 1 ]]; then
  case "$1" in
    --static) ;;
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
  echo "[simulator-scale-host-contract] FAIL: $*" >&2
  exit 1
}

require_file() {
  [[ -f "$1" ]] || fail_contract "missing source: $1"
}

require_text() {
  local file="$1"
  local expected="$2"
  local description="$3"
  rg -Fq -- "$expected" "$file" ||
    fail_contract "$description ($expected)"
}

reject_text() {
  local file="$1"
  local forbidden="$2"
  local description="$3"
  if rg -Fq -- "$forbidden" "$file"; then
    fail_contract "$description ($forbidden)"
  fi
}

require_order() {
  local file="$1"
  local first="$2"
  local second="$3"
  local description="$4"
  local first_line
  local second_line
  first_line="$(
    rg -n -m1 -F -- "$first" "$file" | cut -d: -f1 || true
  )"
  second_line="$(
    rg -n -m1 -F -- "$second" "$file" | cut -d: -f1 || true
  )"
  if [[ -z "$first_line" || -z "$second_line" ||
        "$first_line" -ge "$second_line" ]]; then
    fail_contract "$description"
  fi
}

assert_fixture_cleanup_exit_status() {
  local cleanup_definition
  cleanup_definition="$(
    sed -n '/^cleanup() {/,/^}/p' "$FIXTURE_LIVE"
  )"
  [[ -n "$cleanup_definition" ]] ||
    fail_contract "fixture live gate has no cleanup function"

  local regression_root
  regression_root="$(mktemp -d "${TMPDIR:-/tmp}/ios-use-fixture-cleanup.XXXXXX")" ||
    fail_contract "could not create fixture cleanup regression directory"

  local expected_exit
  for expected_exit in 0 1 23; do
    local case_dir="$regression_root/exit-$expected_exit"
    mkdir -p "$case_dir"

    local actual_exit=0
    if IOS_USE_FIXTURE_CLEANUP_TEST_ROOT="$regression_root/missing-root" \
      IOS_USE_FIXTURE_CLEANUP_TEST_RUN_DIR="$case_dir" \
      /bin/bash -c '
        set -euo pipefail
        SESSION_HOME=""
        ROOT_DIR="$IOS_USE_FIXTURE_CLEANUP_TEST_ROOT"
        RUN_DIR="$IOS_USE_FIXTURE_CLEANUP_TEST_RUN_DIR"
        archive_session_home() {
          touch "$RUN_DIR/archive-called"
          return 1
        }
        restore_original_frontmost_application() {
          touch "$RUN_DIR/restore-called"
          return 1
        }
        eval "$1"
        trap cleanup EXIT
        exit "$2"
      ' bash "$cleanup_definition" "$expected_exit"; then
      actual_exit=0
    else
      actual_exit=$?
    fi

    if [[ "$actual_exit" -ne "$expected_exit" ]]; then
      /bin/rm -rf "$regression_root"
      fail_contract \
        "fixture cleanup changed exit $expected_exit to $actual_exit"
    fi
    for cleanup_artifact in \
      cleanup.stdout \
      cleanup.stderr \
      archive-called \
      restore-called; do
      if [[ ! -f "$case_dir/$cleanup_artifact" ]]; then
        /bin/rm -rf "$regression_root"
        fail_contract \
          "fixture cleanup did not run $cleanup_artifact for exit $expected_exit"
      fi
    done
  done

  /bin/rm -rf "$regression_root"
}

command -v rg >/dev/null 2>&1 ||
  fail_contract "rg is required"
for required in \
  "$BRIDGE_SOURCE" \
  "$COMPOSITOR_SOURCE" \
  "$COMPOSITOR_HEADER" \
  "$SCREENSHOT_SOURCE" \
  "$FIXTURE_LIVE" \
  "$EXTERNAL_LIVE" \
  "$POPUP_CONTRACT" \
  "$MOUSE_HELPER"; do
  require_file "$required"
done

# Keep UIKit at the fixed logical device size. The ordinary system NSWindow
# adds only a resizable style, a 430:932 content aspect, and a bounded minimum.
for expected in \
  'IOSUseBridgeInstallSimulatorScaleResizeHook' \
  '_sizeForProposedSize:resizeEdges:' \
  'setContentAspectRatio:' \
  'setContentMinSize:' \
  'setStyleMask:' \
  'IOSUseBridgeLockSceneToFixedCanvas' \
  'scene.sizeRestrictions.minimumSize = fixed;' \
  'scene.sizeRestrictions.maximumSize = fixed;' \
  'IOSUseBridgeInstallHostCanvas' \
  'IOSUseBridgeUpdateHostCanvasLayout' \
  'NSWindowDidResizeNotification' \
  'IOSUsePlayMapHostContentPointToCanvas' \
  '@"publicTitleBar"' \
  '@"resizable"' \
  '@"hostPolicy"' \
  '@"hostContentBounds"' \
  '@"canvasRect"' \
  '@"canvasBounds"' \
  '@"displayScale"' \
  '@"inverseDisplayScale"' \
  '@"canvasCapture"' \
  '@"canvasCGWindowRect"' \
  '@"hostContentCGWindowRect"'; do
  require_text "$BRIDGE_SOURCE" "$expected" \
    "bridge no longer records the Simulator-scale host contract"
done
for forbidden in \
  'setTitlebarAppearsTransparent:' \
  '@"setOpaque:"' \
  '@"setBackgroundColor:"' \
  '@"setTitleVisibility:"' \
  '@"setTitle:"'; do
  reject_text "$BRIDGE_SOURCE" "$forbidden" \
    "bridge still mutates ordinary NSWindow appearance"
done
require_order \
  "$BRIDGE_SOURCE" \
  '@"setFrame:"' \
  '@"setBounds:"' \
  'render layout must set the physical frame before normalizing bounds'

for expected in \
  'IOSUsePlayHostCanvasLayout' \
  'IOSUsePlayResolveHostCanvasLayout' \
  'IOSUsePlayResolveCanvasCGWindowRect' \
  'IOSUsePlayMapHostContentPointToCanvas' \
  'IOSUsePlayCropAndNormalizeCanvasCapture'; do
  require_text "$COMPOSITOR_HEADER" "$expected" \
    "compositor header lacks fixed-canvas API"
done
require_text "$COMPOSITOR_SOURCE" \
  'IOSUsePlayHostCanvasSpacerPoints = 0.0' \
  'host canvas still reserves a synthetic spacer'
require_text "$COMPOSITOR_SOURCE" 'IOSUsePlayCropAndNormalizeCanvasCapture' \
  'compositor does not crop and normalize the canvas'
require_text "$SCREENSHOT_SOURCE" 'IOSUsePlayCropAndNormalizeCanvasCapture' \
  'screenshot path does not use canvas-only capture'
reject_text "$SCREENSHOT_SOURCE" 'transparent host' \
  'screenshot diagnostics still describe a transparent host'
reject_text "$SCREENSHOT_SOURCE" 'transparent spacer' \
  'screenshot diagnostics still describe a synthetic spacer'

# Runtime-facing gates use the canonical canvas rectangle and scale. They do
# not promote the outer titled NSWindow into target coordinates.
for gate in "$FIXTURE_LIVE" "$EXTERNAL_LIVE" "$POPUP_CONTRACT"; do
  require_text "$gate" 'canvasCGWindowRect' \
    'live gate does not consume canonical canvas CG geometry'
  require_text "$gate" 'displayScale' \
    'live gate does not consume canvas display scale'
  require_text "$gate" 'inverseDisplayScale' \
    'live gate does not check inverse canvas scale'
  reject_text "$gate" 'cgWindowBounds' \
    'live gate still treats the outer CG window as the target canvas'
done
for gate in "$FIXTURE_LIVE" "$EXTERNAL_LIVE"; do
  require_text "$gate" '--static' \
    'fixture/external gate lacks a non-GUI static mode'
  require_text "$gate" '--live' \
    'fixture/external gate lacks an explicit live mode'
  require_text "$gate" '$window.transparentHost == false' \
    'fixture/external gate does not require an opaque host'
  require_text "$gate" '$window.transparentSpacer == 0' \
    'fixture/external gate still permits a synthetic spacer'
done

require_text "$FIXTURE_LIVE" 'local original_exit_status=$?' \
  'fixture cleanup does not save the incoming exit status'
require_text "$FIXTURE_LIVE" 'exit "$original_exit_status"' \
  'fixture cleanup does not restore the incoming exit status'
assert_fixture_cleanup_exit_status

require_text "$FIXTURE_LIVE" 'targetHitTest' \
  'fixture gate does not prove the title bar misses the canvas'
require_text "$MOUSE_HELPER" '--drag' \
  'mouse helper cannot exercise a public resizable host'
require_text "$MOUSE_HELPER" 'leftMouseDragged' \
  'mouse helper does not send a resize drag'

echo \
  "[simulator-scale-host-contract] PASS ordinary NSWindow/fixed-canvas contract"
