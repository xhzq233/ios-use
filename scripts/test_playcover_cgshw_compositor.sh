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
  -framework CoreGraphics \
  -I "$IOS_USE_REPO_ROOT/playcover-runtime" \
  -I "$IOS_USE_REPO_ROOT/swift-cli/Sources/IOSUsePlayDevice/include" \
  "$IOS_USE_REPO_ROOT/playcover-runtime/IOSUsePlayWindowCompositor.m" \
  "$IOS_USE_REPO_ROOT/playcover-runtime/tests/WindowCompositorBackingScaleTests.m" \
  -o "$IOS_USE_SMOKE_TEMP/WindowCompositorBackingScaleTests"

"$IOS_USE_SMOKE_TEMP/WindowCompositorBackingScaleTests"

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
  "$IOS_USE_REPO_ROOT/playcover-runtime/tests/HostCanvasContractTests.m" \
  -o "$IOS_USE_SMOKE_TEMP/HostCanvasContractTests"

"$IOS_USE_SMOKE_TEMP/HostCanvasContractTests"

IOS_USE_MACOS_SDK="$(xcrun --sdk macosx --show-sdk-path)"
xcrun --sdk macosx clang \
  -target arm64-apple-ios13.1-macabi \
  -D IOS_USE_PLAY_APPKIT_BRIDGE_TESTING \
  -fobjc-arc \
  -fblocks \
  -fmodules \
  -Wall \
  -Wextra \
  -Werror \
  -iframework "$IOS_USE_MACOS_SDK/System/iOSSupport/System/Library/Frameworks" \
  -F "$IOS_USE_MACOS_SDK/System/iOSSupport/System/Library/Frameworks" \
  -framework Foundation \
  -framework CoreGraphics \
  -framework UIKit \
  -I "$IOS_USE_REPO_ROOT/playcover-runtime" \
  -I "$IOS_USE_REPO_ROOT/swift-cli/Sources/IOSUsePlayDevice/include" \
  "$IOS_USE_REPO_ROOT/playcover-runtime/IOSUsePlayWindowCompositor.m" \
  "$IOS_USE_REPO_ROOT/playcover-runtime/IOSUsePlaySafeAreaCompatibility.m" \
  "$IOS_USE_REPO_ROOT/playcover-runtime/IOSUsePlayAppKitBridge.m" \
  "$IOS_USE_REPO_ROOT/playcover-runtime/tests/AppKitBridgeSnapshotTests.m" \
  -o "$IOS_USE_SMOKE_TEMP/AppKitBridgeSnapshotTests"

"$IOS_USE_SMOKE_TEMP/AppKitBridgeSnapshotTests"

xcrun --sdk macosx clang \
  -target arm64-apple-ios13.1-macabi \
  -D IOS_USE_PLAY_SAFE_AREA_TESTING \
  -fobjc-arc \
  -fblocks \
  -fmodules \
  -Wall \
  -Wextra \
  -Werror \
  -iframework "$IOS_USE_MACOS_SDK/System/iOSSupport/System/Library/Frameworks" \
  -F "$IOS_USE_MACOS_SDK/System/iOSSupport/System/Library/Frameworks" \
  -framework Foundation \
  -framework CoreGraphics \
  -framework UIKit \
  -I "$IOS_USE_REPO_ROOT/playcover-runtime" \
  -I "$IOS_USE_REPO_ROOT/swift-cli/Sources/IOSUsePlayDevice/include" \
  "$IOS_USE_REPO_ROOT/playcover-runtime/IOSUsePlaySafeAreaCompatibility.m" \
  "$IOS_USE_REPO_ROOT/playcover-runtime/tests/SafeAreaCompatibilityContractTests.m" \
  -o "$IOS_USE_SMOKE_TEMP/SafeAreaCompatibilityContractTests"

"$IOS_USE_SMOKE_TEMP/SafeAreaCompatibilityContractTests"

xcrun --sdk macosx clang \
  -target arm64-apple-ios13.1-macabi \
  -fobjc-arc \
  -fmodules \
  -Wall \
  -Wextra \
  -Werror \
  -iframework "$IOS_USE_MACOS_SDK/System/iOSSupport/System/Library/Frameworks" \
  -F "$IOS_USE_MACOS_SDK/System/iOSSupport/System/Library/Frameworks" \
  -framework Foundation \
  -framework UIKit \
  -I "$IOS_USE_REPO_ROOT/swift-cli/Sources/IOSUsePlayDevice/include" \
  "$IOS_USE_REPO_ROOT/playcover-runtime/tests/DeviceIdentityContractTests.m" \
  -o "$IOS_USE_SMOKE_TEMP/DeviceIdentityContractTests"

"$IOS_USE_SMOKE_TEMP/DeviceIdentityContractTests"

if rg -n \
  '\[\[[^]]*(UIWindow|UIView)[^]]*alloc|DynamicIsland|HomeIndicator|NSTimer|drawRect:|additionalSafeAreaInsets[[:space:]]*=' \
  "$IOS_USE_REPO_ROOT/playcover-runtime/IOSUsePlaySafeAreaCompatibility.m"
then
  echo \
    "[cgshw-smoke] FAIL: safe-area compatibility contains synthetic UI or writes App-owned insets" \
    >&2
  exit 1
fi

if [ "$IOS_USE_DETERMINISTIC_ONLY" = "true" ]; then
  echo "[cgshw-smoke] PASS deterministic compositor and bridge contracts"
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
