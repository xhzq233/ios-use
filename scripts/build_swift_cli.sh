#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIGURATION="release"

for arg in "$@"; do
  case "$arg" in
    --debug)
      CONFIGURATION="debug"
      ;;
    *)
      echo "[swift-cli] ERROR: unknown option $arg"
      exit 1
      ;;
  esac
done

echo "[swift-cli] Building ios-use ($CONFIGURATION)..."
swift build --package-path "$ROOT_DIR/swift-cli" -c "$CONFIGURATION"

TMP_BIN="$(mktemp "$ROOT_DIR/.ios-use.tmp.XXXXXX")"
cleanup() {
  rm -f "$TMP_BIN"
}
trap cleanup EXIT

cp "$ROOT_DIR/swift-cli/.build/$CONFIGURATION/ios-use-swift" "$TMP_BIN"
chmod +x "$TMP_BIN"

if [ "$CONFIGURATION" = "release" ]; then
  echo "[swift-cli] Stripping release binary..."
  strip "$TMP_BIN"
fi

mv "$TMP_BIN" "$ROOT_DIR/ios-use"
trap - EXIT

echo "[swift-cli] Built $ROOT_DIR/ios-use"

PLAYCOVER_RUNTIME="$ROOT_DIR/.ios-use/playcover/IOSUsePlayRuntime.framework"
PLAYCOVER_RUNTIME_EXECUTABLE="$PLAYCOVER_RUNTIME/IOSUsePlayRuntime"
PLAYCOVER_RUNTIME_NEEDS_BUILD="false"

if [ "$(uname -m)" = "arm64" ]; then
  if xcrun --sdk iphoneos --show-sdk-path >/dev/null 2>&1; then
    if [ ! -x "$PLAYCOVER_RUNTIME_EXECUTABLE" ]; then
      PLAYCOVER_RUNTIME_NEEDS_BUILD="true"
    else
      for source in \
        "$ROOT_DIR/playcover-runtime/IOSUsePlayRuntime.m" \
        "$ROOT_DIR/playcover-runtime/IOSUsePlayRuntime.h" \
        "$ROOT_DIR/playcover-runtime/IOSUsePlayRuntimeSocket.m" \
        "$ROOT_DIR/playcover-runtime/IOSUsePlayRuntimeSocket.h" \
        "$ROOT_DIR/playcover-runtime/Info.plist" \
        "$ROOT_DIR/scripts/build_playcover_runtime.sh"; do
        if [ "$source" -nt "$PLAYCOVER_RUNTIME_EXECUTABLE" ]; then
          PLAYCOVER_RUNTIME_NEEDS_BUILD="true"
          break
        fi
      done
    fi

    if [ "$PLAYCOVER_RUNTIME_NEEDS_BUILD" = "true" ]; then
      PLAYCOVER_RUNTIME_ARGS=()
      if [ -e "$PLAYCOVER_RUNTIME" ]; then
        PLAYCOVER_RUNTIME_ARGS+=(--replace)
      fi
      bash "$ROOT_DIR/scripts/build_playcover_runtime.sh" \
        "${PLAYCOVER_RUNTIME_ARGS[@]}"
    else
      echo "[swift-cli] PlayCover runtime is up to date: $PLAYCOVER_RUNTIME"
    fi
  else
    echo "[swift-cli] PlayCover runtime skipped: the iPhoneOS SDK is unavailable"
  fi
else
  echo "[swift-cli] PlayCover runtime skipped: Apple silicon is required"
fi
