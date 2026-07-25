#!/bin/bash
set -euo pipefail

IOS_USE_REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IOS_USE_RUNTIME_OUTPUT="$IOS_USE_REPO_ROOT/.ios-use/playcover/IOSUsePlayRuntime.framework"
IOS_USE_RUNTIME_REPLACE="false"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --output)
      if [ "$#" -lt 2 ]; then
        echo "[playcover-runtime] ERROR: --output requires a path"
        exit 64
      fi
      IOS_USE_RUNTIME_OUTPUT="$2"
      shift 2
      ;;
    --replace)
      IOS_USE_RUNTIME_REPLACE="true"
      shift
      ;;
    *)
      echo "[playcover-runtime] ERROR: unknown option $1"
      exit 64
      ;;
  esac
done

if [ "$(basename "$IOS_USE_RUNTIME_OUTPUT")" != "IOSUsePlayRuntime.framework" ]; then
  echo "[playcover-runtime] ERROR: output must end in IOSUsePlayRuntime.framework"
  exit 64
fi

IOS_USE_RUNTIME_PARENT="$(cd "$(dirname "$IOS_USE_RUNTIME_OUTPUT")" 2>/dev/null && pwd || true)"
if [ -z "$IOS_USE_RUNTIME_PARENT" ]; then
  mkdir -p "$(dirname "$IOS_USE_RUNTIME_OUTPUT")"
  IOS_USE_RUNTIME_PARENT="$(cd "$(dirname "$IOS_USE_RUNTIME_OUTPUT")" && pwd)"
fi
IOS_USE_RUNTIME_OUTPUT="$IOS_USE_RUNTIME_PARENT/IOSUsePlayRuntime.framework"

if [ -e "$IOS_USE_RUNTIME_OUTPUT" ] && [ "$IOS_USE_RUNTIME_REPLACE" != "true" ]; then
  echo "[playcover-runtime] ERROR: output exists; pass --replace to replace this generated framework"
  exit 1
fi

IOS_USE_RUNTIME_TEMP="$(mktemp -d "$IOS_USE_RUNTIME_PARENT/.ios-use-play-runtime.XXXXXX")"
cleanup_runtime_build() {
  if [ -n "${IOS_USE_RUNTIME_TEMP:-}" ] &&
     [ -d "$IOS_USE_RUNTIME_TEMP" ] &&
     [ "$(dirname "$IOS_USE_RUNTIME_TEMP")" = "$IOS_USE_RUNTIME_PARENT" ]; then
    rm -rf "$IOS_USE_RUNTIME_TEMP"
  fi
}
trap cleanup_runtime_build EXIT

IOS_USE_RUNTIME_SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
IOS_USE_RUNTIME_CLANG="$(xcrun --find clang)"
IOS_USE_RUNTIME_VTOOL="$(xcrun --find vtool)"
IOS_USE_RUNTIME_RAW="$IOS_USE_RUNTIME_TEMP/IOSUsePlayRuntime.iphoneos"
IOS_USE_RUNTIME_FRAMEWORK="$IOS_USE_RUNTIME_TEMP/IOSUsePlayRuntime.framework"

mkdir -p "$IOS_USE_RUNTIME_FRAMEWORK"

echo "[playcover-runtime] Building iPhoneOS arm64 dylib..."
"$IOS_USE_RUNTIME_CLANG" \
  -dynamiclib \
  -arch arm64 \
  -isysroot "$IOS_USE_RUNTIME_SDK" \
  -miphoneos-version-min=13.0 \
  -fobjc-arc \
  -fmodules \
  -Wall \
  -Wextra \
  -Werror \
  -framework Foundation \
  -framework UIKit \
  -install_name "@rpath/IOSUsePlayRuntime.framework/IOSUsePlayRuntime" \
  -current_version 1.0.0 \
  -compatibility_version 1.0.0 \
  "$IOS_USE_REPO_ROOT/playcover-runtime/IOSUsePlayRuntime.m" \
  "$IOS_USE_REPO_ROOT/playcover-runtime/IOSUsePlayRuntimeDOM.m" \
  "$IOS_USE_REPO_ROOT/playcover-runtime/IOSUsePlayRuntimeScreenshot.m" \
  "$IOS_USE_REPO_ROOT/playcover-runtime/IOSUsePlayRuntimeSocket.m" \
  -o "$IOS_USE_RUNTIME_RAW"

echo "[playcover-runtime] Rewriting platform to Mac Catalyst..."
"$IOS_USE_RUNTIME_VTOOL" \
  -set-build-version maccatalyst 11.0 14.0 \
  -replace \
  -output "$IOS_USE_RUNTIME_FRAMEWORK/IOSUsePlayRuntime" \
  "$IOS_USE_RUNTIME_RAW"

cp "$IOS_USE_REPO_ROOT/playcover-runtime/Info.plist" \
  "$IOS_USE_RUNTIME_FRAMEWORK/Info.plist"
chmod 755 "$IOS_USE_RUNTIME_FRAMEWORK/IOSUsePlayRuntime"
plutil -lint "$IOS_USE_RUNTIME_FRAMEWORK/Info.plist" >/dev/null
/usr/bin/codesign \
  --force \
  --sign - \
  --timestamp=none \
  "$IOS_USE_RUNTIME_FRAMEWORK"
/usr/bin/codesign --verify --strict "$IOS_USE_RUNTIME_FRAMEWORK"

if [ -e "$IOS_USE_RUNTIME_OUTPUT" ]; then
  rm -rf "$IOS_USE_RUNTIME_OUTPUT"
fi
mv "$IOS_USE_RUNTIME_FRAMEWORK" "$IOS_USE_RUNTIME_OUTPUT"

echo "[playcover-runtime] Built $IOS_USE_RUNTIME_OUTPUT"
