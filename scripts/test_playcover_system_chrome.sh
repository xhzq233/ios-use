#!/bin/bash
set -euo pipefail

IOS_USE_REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if [[ "$(uname -s)" != "Darwin" || "$(uname -m)" != "arm64" ]]; then
  echo "[system-chrome-test] Apple-silicon macOS is required." >&2
  exit 69
fi

IOS_USE_TEST_SDK="$(xcrun --sdk macosx --show-sdk-path)"
IOS_USE_TEST_TEMP="$(mktemp -d "${TMPDIR:-/tmp}/ios-use-system-chrome.XXXXXX")"
cleanup_system_chrome_test() {
  if [[ -n "${IOS_USE_TEST_TEMP:-}" &&
        -d "$IOS_USE_TEST_TEMP" &&
        "$(basename "$IOS_USE_TEST_TEMP")" == ios-use-system-chrome.* ]]; then
    rm -rf "$IOS_USE_TEST_TEMP"
  fi
}
trap cleanup_system_chrome_test EXIT

echo "[system-chrome-test] Verifying selector ABI, source contract, and black/white pixel differentials..."
xcrun clang \
  -fobjc-arc \
  -Wall \
  -Wextra \
  -Werror \
  -target arm64-apple-ios13.1-macabi \
  -isysroot "$IOS_USE_TEST_SDK" \
  -iframework "$IOS_USE_TEST_SDK/System/iOSSupport/System/Library/Frameworks" \
  -I "$IOS_USE_REPO_ROOT/playcover-runtime" \
  -I "$IOS_USE_REPO_ROOT/swift-cli/Sources/IOSUsePlayDevice/include" \
  -framework Foundation \
  -framework CoreGraphics \
  -framework UIKit \
  "$IOS_USE_REPO_ROOT/playcover-runtime/IOSUsePlaySystemChrome.m" \
  "$IOS_USE_REPO_ROOT/playcover-runtime/tests/SystemChromeContractTests.m" \
  -o "$IOS_USE_TEST_TEMP/SystemChromeContractTests"
"$IOS_USE_TEST_TEMP/SystemChromeContractTests" \
  "$IOS_USE_REPO_ROOT/playcover-runtime/IOSUsePlaySystemChrome.m"

echo "[system-chrome-test] Building and analyzing the mixed Catalyst Runtime..."
bash "$IOS_USE_REPO_ROOT/scripts/build_playcover_runtime.sh" \
  --output "$IOS_USE_TEST_TEMP/IOSUsePlayRuntime.framework" \
  --analyze

echo "[system-chrome-test] passed"
