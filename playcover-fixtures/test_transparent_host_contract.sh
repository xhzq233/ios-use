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
Usage: playcover-fixtures/test_transparent_host_contract.sh [--static]

Verify source-level Simulator-style transparent-host and fixed-canvas
contracts. This check neither launches an App nor posts input events, so it is
safe on a non-GUI or locked host. Live interaction remains in the explicitly
selected fixture and external-App gates.
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
  echo "[transparent-host-contract] FAIL: $*" >&2
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

# The host must be a public title-bar window. The title itself must come from
# the target bundle rather than a simulated phone chrome surface.
for expected in \
  'IOSUseBridgeHostTitle' \
  'CFBundleDisplayName' \
  'CFBundleName' \
  'bundle.bundleIdentifier' \
  'setTitlebarAppearsTransparent:' \
  'setTitle:' \
  'setContentMinSize:' \
  'setContentMaxSize:' \
  'setStyleMask:' \
  'IOSUseBridgeInstallHostCanvas' \
  'IOSUseBridgeUpdateHostCanvasLayout' \
  'IOSUsePlayResolveHostCanvasLayout' \
  'IOSUsePlayMapHostContentPointToCanvas' \
  '@"transparentHost"' \
  '@"publicTitleBar"' \
  '@"resizable"' \
  '@"hostPolicy"' \
  '@"hostContentBounds"' \
  '@"canvasRect"' \
  '@"canvasBounds"' \
  '@"displayScale"' \
  '@"inverseDisplayScale"' \
  '@"transparentSpacer"' \
  '@"canvasCapture"' \
  '@"canvasCGWindowRect"' \
  '@"hostContentCGWindowRect"'; do
  require_text "$BRIDGE_SOURCE" "$expected" \
    "bridge no longer records the transparent-host contract"
done

for expected in \
  'IOSUsePlayHostCanvasLayout' \
  'IOSUsePlayResolveHostCanvasLayout' \
  'IOSUsePlayResolveCanvasCGWindowRect' \
  'IOSUsePlayMapHostContentPointToCanvas' \
  'IOSUsePlayCropAndNormalizeCanvasCapture'; do
  require_text "$COMPOSITOR_HEADER" "$expected" \
    "compositor header lacks fixed-canvas API"
done
require_text "$COMPOSITOR_SOURCE" 'IOSUsePlayCropAndNormalizeCanvasCapture' \
  'compositor does not crop and normalize the canvas'
require_text "$SCREENSHOT_SOURCE" 'IOSUsePlayCropAndNormalizeCanvasCapture' \
  'screenshot path does not use canvas-only capture'

# Runtime-facing gates must use the canonical global canvas rectangle rather
# than promoting the outer CGWindow bounds into a target coordinate system.
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
  require_text "$gate" 'targetHitTest' \
    'fixture/external gate does not prove decoration clicks miss the canvas'
done

require_text "$MOUSE_HELPER" '--drag' \
  'mouse helper cannot exercise a public resizable host'
require_text "$MOUSE_HELPER" 'leftMouseDragged' \
  'mouse helper does not send a resize drag'

echo "[transparent-host-contract] PASS static transparent-host contract"
