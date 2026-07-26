#!/bin/bash
set -euo pipefail

IOS_USE_REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if [[ "$(uname -s)" != "Darwin" || "$(uname -m)" != "arm64" ]]; then
  echo "[system-chrome-test] Apple-silicon macOS is required." >&2
  exit 69
fi

IOS_USE_TEST_TEMP="$(mktemp -d "${TMPDIR:-/tmp}/ios-use-render-frame.XXXXXX")"
cleanup_system_chrome_test() {
  if [[ -n "${IOS_USE_TEST_TEMP:-}" &&
        -d "$IOS_USE_TEST_TEMP" &&
        "$(basename "$IOS_USE_TEST_TEMP")" == ios-use-render-frame.* ]]; then
    rm -rf "$IOS_USE_TEST_TEMP"
  fi
}
trap cleanup_system_chrome_test EXIT

echo "[system-chrome-test] Verifying removal of synthetic chrome and full-frame rendering contract..."
xcrun clang \
  -fobjc-arc \
  -Wall \
  -Wextra \
  -Werror \
  -framework Foundation \
  "$IOS_USE_REPO_ROOT/playcover-runtime/tests/SystemChromeContractTests.m" \
  -o "$IOS_USE_TEST_TEMP/SystemChromeContractTests"
"$IOS_USE_TEST_TEMP/SystemChromeContractTests" \
  "$IOS_USE_REPO_ROOT/playcover-runtime/IOSUsePlayRuntimeScreenshot.m" \
  "$IOS_USE_REPO_ROOT/playcover-runtime/IOSUsePlayRuntime.m" \
  "$IOS_USE_REPO_ROOT/playcover-runtime/IOSUsePlayRuntimeSocket.m" \
  "$IOS_USE_REPO_ROOT/playcover-runtime/IOSUsePlayRuntimeAutomation.m"

echo "[system-chrome-test] Building and analyzing the mixed Catalyst Runtime..."
bash "$IOS_USE_REPO_ROOT/scripts/build_playcover_runtime.sh" \
  --output "$IOS_USE_TEST_TEMP/IOSUsePlayRuntime.framework" \
  --analyze

echo "[system-chrome-test] passed"
