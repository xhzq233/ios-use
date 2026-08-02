#!/bin/bash
set -euo pipefail
umask 077

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd -P)"
if [[ "$#" -ne 1 || "$(basename "$1")" != "IOSUseFridaEngine.framework" ]]; then
  echo "Usage: scripts/test_playcover_frida_engine_live.sh <IOSUseFridaEngine.framework>" >&2
  exit 64
fi
FRAMEWORK="$(cd "$1" && pwd -P)"
FRAMEWORK_PARENT="$(dirname "$FRAMEWORK")"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
BUILD_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/ios-use-frida-live.XXXXXX")"
cleanup() { /bin/rm -rf -- "$BUILD_ROOT"; }
trap cleanup EXIT

clang -target arm64-apple-ios17.0-macabi -fobjc-arc \
  -isysroot "$SDK_PATH" \
  -I"$FRAMEWORK/Headers" \
  -F"$FRAMEWORK_PARENT" \
  -framework Foundation \
  -framework IOSUseFridaEngine \
  -Wl,-rpath,"$FRAMEWORK_PARENT" \
  "$ROOT_DIR/playcover-frida-engine/tests/IOSUseFridaEngineLiveHarness.m" \
  -o "$BUILD_ROOT/IOSUseFridaEngineLiveHarness"
/usr/bin/codesign --force --sign - --timestamp=none \
  "$BUILD_ROOT/IOSUseFridaEngineLiveHarness"
"$BUILD_ROOT/IOSUseFridaEngineLiveHarness"
