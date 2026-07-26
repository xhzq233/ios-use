#!/bin/bash
set -euo pipefail

IOS_USE_REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IOS_USE_SMOKE_TEMP="$(mktemp -d "${TMPDIR:-/tmp}/ios-use-cgshw-smoke.XXXXXX")"
IOS_USE_DETERMINISTIC_ONLY="false"

if [ "$#" -gt 1 ]; then
  echo "usage: $0 [--deterministic-only]" >&2
  exit 64
fi
if [ "$#" -eq 1 ]; then
  if [ "$1" != "--deterministic-only" ]; then
    echo "usage: $0 [--deterministic-only]" >&2
    exit 64
  fi
  IOS_USE_DETERMINISTIC_ONLY="true"
fi

cleanup_cgshw_smoke() {
  if [ -n "${IOS_USE_SMOKE_TEMP:-}" ] &&
     [ -d "$IOS_USE_SMOKE_TEMP" ] &&
     [ "$(basename "$IOS_USE_SMOKE_TEMP")" != "." ]; then
    rm -rf "$IOS_USE_SMOKE_TEMP"
  fi
}
trap cleanup_cgshw_smoke EXIT

xcrun clang \
  -fobjc-arc \
  -fmodules \
  -Wall \
  -Wextra \
  -Werror \
  -framework Foundation \
  "$IOS_USE_REPO_ROOT/playcover-runtime/tests/SystemChromeContractTests.m" \
  -o "$IOS_USE_SMOKE_TEMP/SyntheticChromeRemovalContract"

"$IOS_USE_SMOKE_TEMP/SyntheticChromeRemovalContract" \
  "$IOS_USE_REPO_ROOT/playcover-runtime/IOSUsePlayRuntimeScreenshot.m" \
  "$IOS_USE_REPO_ROOT/playcover-runtime/IOSUsePlayRuntime.m" \
  "$IOS_USE_REPO_ROOT/playcover-runtime/IOSUsePlayRuntimeSocket.m" \
  "$IOS_USE_REPO_ROOT/playcover-runtime/IOSUsePlayRuntimeAutomation.m"

xcrun clang \
  -fobjc-arc \
  -fmodules \
  -Wall \
  -Wextra \
  -Werror \
  -framework Foundation \
  -I "$IOS_USE_REPO_ROOT/swift-cli/Sources/IOSUsePlayDevice/include" \
  "$IOS_USE_REPO_ROOT/playcover-runtime/tests/RuntimeAutomationSourceContract.m" \
  -o "$IOS_USE_SMOKE_TEMP/RuntimeAutomationSourceContract"

"$IOS_USE_SMOKE_TEMP/RuntimeAutomationSourceContract" \
  "$IOS_USE_REPO_ROOT/playcover-runtime/IOSUsePlayRuntimeAutomation.m" \
  "$IOS_USE_REPO_ROOT/playcover-runtime/IOSUsePlayFixedAdapter.swift" \
  "$IOS_USE_REPO_ROOT/playcover-runtime/IOSUsePlayRuntimeDOM.m" \
  "$IOS_USE_REPO_ROOT/playcover-runtime/IOSUsePlayAppKitBridge.m"

xcrun clang \
  -fobjc-arc \
  -fmodules \
  -Wall \
  -Wextra \
  -Werror \
  -framework Foundation \
  "$IOS_USE_REPO_ROOT/playcover-runtime/tests/InputContractTests.m" \
  -o "$IOS_USE_SMOKE_TEMP/InputContractTests"

"$IOS_USE_SMOKE_TEMP/InputContractTests" \
  "$IOS_USE_REPO_ROOT/playcover-runtime/IOSUsePlayRuntimeAutomation.m"

xcrun clang \
  -fobjc-arc \
  -fmodules \
  -Wall \
  -Wextra \
  -Werror \
  -framework Foundation \
  "$IOS_USE_REPO_ROOT/playcover-runtime/tests/RuntimeScreenshotSourceContract.m" \
  -o "$IOS_USE_SMOKE_TEMP/RuntimeScreenshotSourceContract"

"$IOS_USE_SMOKE_TEMP/RuntimeScreenshotSourceContract" \
  "$IOS_USE_REPO_ROOT/playcover-runtime/IOSUsePlayRuntimeScreenshot.m" \
  "$IOS_USE_REPO_ROOT/playcover-runtime/IOSUsePlayWindowCompositor.m" \
  "$IOS_USE_REPO_ROOT/playcover-runtime/IOSUsePlayAppKitBridge.m"

xcrun clang \
  -fobjc-arc \
  -fmodules \
  -Wall \
  -Wextra \
  -Werror \
  -framework Foundation \
  -framework CoreGraphics \
  -I "$IOS_USE_REPO_ROOT/playcover-runtime" \
  -I "$IOS_USE_REPO_ROOT/swift-cli/Sources/IOSUsePlayDevice/include" \
  "$IOS_USE_REPO_ROOT/playcover-runtime/IOSUsePlayWindowCompositor.m" \
  "$IOS_USE_REPO_ROOT/playcover-runtime/tests/WindowCompositorBackingScaleTests.m" \
  -o "$IOS_USE_SMOKE_TEMP/WindowCompositorBackingScaleTests"

"$IOS_USE_SMOKE_TEMP/WindowCompositorBackingScaleTests"

if [ "$IOS_USE_DETERMINISTIC_ONLY" = "true" ]; then
  echo "[cgshw-smoke] PASS deterministic compositor contracts"
  exit 0
fi

xcrun clang \
  -fobjc-arc \
  -fmodules \
  -Wall \
  -Wextra \
  -Werror \
  -framework AppKit \
  -framework CoreGraphics \
  -framework Metal \
  -framework MetalKit \
  -I "$IOS_USE_REPO_ROOT/playcover-runtime" \
  -I "$IOS_USE_REPO_ROOT/swift-cli/Sources/IOSUsePlayDevice/include" \
  "$IOS_USE_REPO_ROOT/playcover-runtime/IOSUsePlayWindowCompositor.m" \
  "$IOS_USE_REPO_ROOT/playcover-runtime/tests/CGSHWCompositorSmoke.m" \
  -o "$IOS_USE_SMOKE_TEMP/CGSHWCompositorSmoke"

IOS_USE_SCREEN_RECORDING_GATE="${IOS_USE_REQUIRE_SCREEN_RECORDING_DENIED:-1}"
IOS_USE_REQUIRE_SCREEN_RECORDING_DENIED="$IOS_USE_SCREEN_RECORDING_GATE" \
  "$IOS_USE_SMOKE_TEMP/CGSHWCompositorSmoke"
