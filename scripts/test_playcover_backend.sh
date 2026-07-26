#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MODE="non-live"

usage() {
  cat <<'USAGE'
Usage: scripts/test_playcover_backend.sh [--non-live|--live]

--non-live  Run the hermetic build, analysis, fixture, compositor, vendored
            Swift, release-install, and installed-execution gate. This is
            suitable for hosted CI.
--live      Run the versioned public fixture matrix, the isolated Runtime
            protocol/crash stress gate, and the generic external-App live gate.
            The latter requires a private scenario and raw evidence directory
            supplied by the dedicated Apple-silicon runner. Missing live
            prerequisites fail with EX_CONFIG (78); they are not reported as a
            passing or skipped live result.
USAGE
}

if [[ $# -eq 1 ]]; then
  case "$1" in
    --non-live) MODE="non-live" ;;
    --live) MODE="live" ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 64
      ;;
  esac
elif [[ $# -ne 0 ]]; then
  usage >&2
  exit 64
fi

require_apple_silicon_xcode() {
  local failure_code="${1:-69}"
  if [[ "$(uname -s)" != "Darwin" || "$(uname -m)" != "arm64" ]]; then
    echo "[playcover-gate] Apple-silicon macOS is required." >&2
    exit "$failure_code"
  fi
  command -v xcodegen >/dev/null 2>&1 || {
    echo "[playcover-gate] xcodegen is required." >&2
    exit "$failure_code"
  }
  if ! xcrun --sdk iphoneos --show-sdk-path >/dev/null; then
    echo "[playcover-gate] A full iPhoneOS Xcode SDK is required." >&2
    exit "$failure_code"
  fi
}

run_non_live() {
  require_apple_silicon_xcode
  echo "[playcover-gate] Auditing pinned upstreams and recorded local patches..."
  bash "$ROOT_DIR/scripts/audit_playcover_upstreams.sh" \
    --cache-dir "${IOS_USE_PLAYCOVER_UPSTREAM_CACHE:-${TMPDIR:-/tmp}/ios-use-playcover-upstream-audit}"
  echo "[playcover-gate] Building and analyzing the Runtime..."
  bash "$ROOT_DIR/scripts/build_playcover_runtime.sh" --replace --analyze
  echo "[playcover-gate] Rebuilding the workspace CLI used by all following checks..."
  bash "$ROOT_DIR/scripts/build_swift_cli.sh"
  echo "[playcover-gate] Building the UIKit/SwiftUI/WKWebView/Metal fixture..."
  bash "$ROOT_DIR/playcover-fixtures/build.sh"
  echo "[playcover-gate] Running compositor and PlayChain harnesses..."
  bash "$ROOT_DIR/scripts/test_playcover_cgshw_compositor.sh"
  bash "$ROOT_DIR/scripts/test_playcover_playchain.sh"
  echo "[playcover-gate] Building vendored inject and testing vendored PlayCover..."
  # inject is upstream library-only at the pinned revision and deliberately has
  # no XCTest target; `swift build` is its complete Swift gate.
  swift build --package-path "$ROOT_DIR/ThirdParty/inject"
  swift test --package-path "$ROOT_DIR/ThirdParty/PlayCover"
  echo "[playcover-gate] Verifying installer behavior and release-installed execution..."
  bash "$ROOT_DIR/scripts/test_install.sh"
  bash "$ROOT_DIR/scripts/test_playcover_installed_layout.sh"
  echo "[playcover-gate] non-live gate passed"
}

run_live() {
  require_apple_silicon_xcode 78
  bash "$ROOT_DIR/scripts/build_swift_cli.sh"
  echo "[playcover-live] Running versioned fixture acceptance matrix..."
  bash "$ROOT_DIR/scripts/test_playcover_fixture_live.sh" --live
  echo "[playcover-live] Running isolated Runtime protocol/crash stress matrix..."
  bash "$ROOT_DIR/scripts/test_playcover_runtime_stress_live.sh"
  echo "[playcover-live] Running configured external-App live/stress workflow..."
  bash "$ROOT_DIR/scripts/test_playcover_external_app_live.sh" --live
  echo "[playcover-live] external-App live/stress gate passed"
}

case "$MODE" in
  non-live) run_non_live ;;
  live) run_live ;;
esac
