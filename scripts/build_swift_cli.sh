#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIGURATION="release"
BUILD_RUNTIME=true

for arg in "$@"; do
  case "$arg" in
    --skip-runtime)
      BUILD_RUNTIME=false
      ;;
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
SOURCE_PREFIX_MAP="$ROOT_DIR=/ios-use"
SWIFT_BUILD_ARGS=(--package-path "$ROOT_DIR/swift-cli" -c "$CONFIGURATION")
if [ "$(uname -s)" = "Linux" ] && [ "$CONFIGURATION" = "release" ]; then
  SWIFT_BUILD_ARGS+=(--static-swift-stdlib)
fi
swift build \
  "${SWIFT_BUILD_ARGS[@]}" \
  -Xswiftc -file-prefix-map \
  -Xswiftc "$SOURCE_PREFIX_MAP" \
  -Xswiftc -debug-prefix-map \
  -Xswiftc "$SOURCE_PREFIX_MAP" \
  -Xcc "-ffile-prefix-map=$SOURCE_PREFIX_MAP" \
  -Xcc "-fdebug-prefix-map=$SOURCE_PREFIX_MAP" \
  -Xcc "-fmacro-prefix-map=$SOURCE_PREFIX_MAP"

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
  for local_path in "/Users/" "$ROOT_DIR/" "$HOME/"; do
    if LC_ALL=C grep -aFq -- \
        "$local_path" "$TMP_BIN"; then
      echo \
        "[swift-cli] ERROR: release binary embeds local build path: $local_path" \
        >&2
      exit 1
    fi
  done
fi

mv "$TMP_BIN" "$ROOT_DIR/ios-use"
trap - EXIT

echo "[swift-cli] Built $ROOT_DIR/ios-use"

if [ "$BUILD_RUNTIME" = false ]; then
  exit 0
fi

PLAYCOVER_RUNTIME="$ROOT_DIR/.ios-use/playcover/IOSUsePlayRuntime.framework"
PLAYCOVER_RUNTIME_EXECUTABLE="$PLAYCOVER_RUNTIME/IOSUsePlayRuntime"
PLAYCOVER_RUNTIME_NEEDS_BUILD="false"

if [ "$(uname -s)" = "Darwin" ] && [ "$(uname -m)" = "arm64" ]; then
  if xcrun --sdk iphoneos --show-sdk-path >/dev/null 2>&1; then
    if [ ! -x "$PLAYCOVER_RUNTIME_EXECUTABLE" ]; then
      PLAYCOVER_RUNTIME_NEEDS_BUILD="true"
    else
      while IFS= read -r source; do
        if [ "$source" -nt "$PLAYCOVER_RUNTIME_EXECUTABLE" ]; then
          PLAYCOVER_RUNTIME_NEEDS_BUILD="true"
          break
        fi
      done < <(
        rg --files \
          "$ROOT_DIR/playcover-runtime" \
          "$ROOT_DIR/swift-cli/Sources/IOSUsePlayDevice" \
          "$ROOT_DIR/scripts/build_playcover_runtime.sh"
      )
    fi

    if [ "$PLAYCOVER_RUNTIME_NEEDS_BUILD" = "true" ]; then
      PLAYCOVER_RUNTIME_ARGS=("$ROOT_DIR/scripts/build_playcover_runtime.sh")
      if [ -e "$PLAYCOVER_RUNTIME" ]; then
        PLAYCOVER_RUNTIME_ARGS+=(--replace)
      fi
      bash "${PLAYCOVER_RUNTIME_ARGS[@]}"
    else
      echo "[swift-cli] PlayCover runtime is up to date: $PLAYCOVER_RUNTIME"
    fi
  else
    echo "[swift-cli] PlayCover runtime skipped: the iPhoneOS SDK is unavailable"
  fi
else
  echo "[swift-cli] PlayCover runtime skipped: Apple silicon is required"
fi
